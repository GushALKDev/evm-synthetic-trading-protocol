// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TradingEngine} from "../../src/TradingEngine.sol";
import {TradingStorage} from "../../src/TradingStorage.sol";
import {Vault} from "../../src/Vault.sol";
import {AssistantFund} from "../../src/AssistantFund.sol";
import {SolvencyManager} from "../../src/SolvencyManager.sol";
import {BondDepository} from "../../src/BondDepository.sol";
import {SynthToken} from "../../src/SynthToken.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {MockSpreadManager} from "../mocks/MockSpreadManager.sol";
import {RegressionUSDC} from "../regression/RegressionBase.sol";

/**
 * @title EdgeCasesTest
 * @author GushALKDev
 * @notice Griefing and edge cases on the wired protocol (MockOracle, 5 BPS spread): a trade between a separate
 *         refresh and an LP action, many open trades per user, MAX_PAIRS pairs with no open interest, withdrawal
 *         epochs at their exact boundaries, the first deposit and donations with the decimals offset and an open
 *         PnL liability, and a minimum-collateral position liquidated past 100% loss.
 */
contract EdgeCasesTest is Test {
    TradingEngine engine;
    TradingStorage tradingStorage;
    Vault vault;
    AssistantFund assistantFund;
    SolvencyManager solvencyManager;
    RegressionUSDC usdc;
    MockOracle mockOracle;

    address owner = makeAddr("owner");
    address lp = makeAddr("lp");
    address lp2 = makeAddr("lp2");
    address trader = makeAddr("trader");
    address keeper = makeAddr("keeper");

    uint16 constant PAIR = 0;
    uint128 constant PRICE = 50_000 * 1e18;
    uint256 constant LP_DEPOSIT = 1_000_000 * 10 ** 6;
    bytes[] EMPTY;

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new RegressionUSDC();
        mockOracle = new MockOracle();
        mockOracle.setPrice(PAIR, PRICE);

        vm.startPrank(owner);
        tradingStorage = new TradingStorage(address(usdc), owner);
        vault = new Vault(address(usdc), owner, address(tradingStorage), address(mockOracle));
        assistantFund = new AssistantFund(address(usdc), address(vault), 1_000_000 * 10 ** 6, owner);
        SynthToken synth = new SynthToken(owner);
        BondDepository bondDepository = new BondDepository(address(usdc), address(vault), address(synth), 500, owner);
        engine = new TradingEngine(
            address(tradingStorage), address(vault), address(mockOracle), address(usdc), address(assistantFund), address(new MockSpreadManager(5)), owner
        );
        solvencyManager = new SolvencyManager(address(vault), address(assistantFund), address(bondDepository), owner);
        tradingStorage.setTradingEngine(address(engine));
        vault.setTradingEngine(address(engine));
        vault.setSolvencyManager(address(solvencyManager));
        synth.setMinter(address(bondDepository));
        assistantFund.setSolvencyManager(address(solvencyManager));
        bondDepository.setSolvencyManager(address(solvencyManager));
        tradingStorage.addPair("BTC/USD", 100, 100_000_000 * 1e18);
        vm.stopPrank();

        _fund(lp, LP_DEPOSIT);
        vm.prank(lp);
        vault.deposit(LP_DEPOSIT, lp);
        _fund(lp2, LP_DEPOSIT);
        usdc.mint(trader, 10_000_000 * 10 ** 6);
        vm.prank(trader);
        usdc.approve(address(engine), type(uint256).max);
    }

    function _fund(address _who, uint256 _amount) internal {
        usdc.mint(_who, _amount);
        vm.prank(_who);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _open(bool _isLong, uint64 _collateral, uint16 _leverage) internal returns (uint32) {
        uint128 price = mockOracle.peekPrice(PAIR);
        uint128 expected = uint128((uint256(price) * (_isLong ? 10_005 : 9_995)) / 10_000);
        vm.prank(trader);
        return engine.openTrade(PAIR, _isLong, _collateral, _leverage, expected, 100, 0, 0, EMPTY);
    }

    /*//////////////////////////////////////////////////////////////
                 TRADE BETWEEN A REFRESH AND AN LP ACTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice A trade that lands between a separate refresh and a deposit makes the deposit revert (the snapshot
     *         nonce changed); refreshAndDeposit refreshes and deposits in one transaction, so nothing can land between
     */
    function test_TradeBetweenRefreshAndDeposit() public {
        _open(true, 1_000 * 10 ** 6, 10);
        vault.refreshPnlSnapshot(EMPTY);
        _open(false, 1_000 * 10 ** 6, 10);

        vm.prank(lp2);
        vm.expectPartialRevert(Vault.StalePnlSnapshot.selector);
        vault.deposit(1_000 * 10 ** 6, lp2);

        vm.prank(lp2);
        vault.refreshAndDeposit(1_000 * 10 ** 6, lp2, EMPTY);
        assertGt(vault.balanceOf(lp2), 0);
    }

    /*//////////////////////////////////////////////////////////////
                      MANY OPEN TRADES PER USER
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The refresh reads per-pair aggregates, so its cost does not grow with the number of open trades, and
     *         closing a user's first or last trade among 152 stays below 150,000 gas (deleteTrade swaps and pops;
     *         DeleteTradeRegression.t.sol checks the cost does not depend on the number of trades)
     */
    function test_ManyOpenTradesPerUser() public {
        uint32 first = _open(true, 100 * 10 ** 6, 10);
        vault.refreshPnlSnapshot(EMPTY); // first write of the snapshot slot, not measured
        _open(false, 100 * 10 ** 6, 10);
        uint256 gasOne = gasleft();
        vault.refreshPnlSnapshot(EMPTY);
        gasOne -= gasleft();

        uint32 last;
        for (uint256 i; i < 150; ++i) {
            last = _open(i % 2 == 0, 100 * 10 ** 6, 10);
        }
        assertEq(tradingStorage.getUserTrades(trader).length, 152);
        uint256 gasMany = gasleft();
        vault.refreshPnlSnapshot(EMPTY);
        gasMany -= gasleft();
        assertApproxEqAbs(gasMany, gasOne, 5_000, "refresh cost grows with open trades");

        uint128 price = mockOracle.peekPrice(PAIR);
        uint128 closeLong = uint128((uint256(price) * 9_995) / 10_000);
        vm.prank(trader);
        uint256 gasFirst = gasleft();
        engine.closeTrade(first, closeLong, 100, EMPTY);
        gasFirst = gasFirst - gasleft();
        vm.prank(trader);
        uint256 gasLast = gasleft();
        engine.closeTrade(last, closeLong, 100, EMPTY);
        gasLast = gasLast - gasleft();
        assertLt(gasFirst, 150_000, "closing the first of many trades");
        assertLt(gasLast, 150_000, "closing the last of many trades");
    }

    /*//////////////////////////////////////////////////////////////
                  MAX_PAIRS WITH NO OPEN INTEREST
    //////////////////////////////////////////////////////////////*/

    /// @notice With MAX_PAIRS pairs and open interest on the last one only, the refresh prices that pair alone
    function test_RefreshSkipsPairsWithoutOpenInterestUpToMaxPairs() public {
        uint256 maxPairs = tradingStorage.MAX_PAIRS();
        vm.startPrank(owner);
        for (uint256 i = 1; i < maxPairs; ++i) {
            tradingStorage.addPair("PAIR", 100, 100_000_000 * 1e18);
        }
        vm.stopPrank();
        uint16 lastPair = uint16(maxPairs - 1);
        mockOracle.setPrice(lastPair, PRICE);
        vm.prank(trader);
        engine.openTrade(lastPair, true, 1_000 * 10 ** 6, 10, uint128((uint256(PRICE) * 10_005) / 10_000), 100, 0, 0, EMPTY);

        for (uint256 i; i < maxPairs - 1; ++i) {
            vm.expectCall(address(mockOracle), abi.encodeCall(IOracle.getPrice, (i, EMPTY)), 0);
        }
        vm.expectCall(address(mockOracle), abi.encodeCall(IOracle.getPrice, (uint256(lastPair), EMPTY)), 1);
        vault.refreshPnlSnapshot(EMPTY);
        assertTrue(vault.isPnlSnapshotFresh());
    }

    /*//////////////////////////////////////////////////////////////
                     WITHDRAWAL EPOCH BOUNDARIES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice A request made in the last second of an epoch unlocks exactly WITHDRAWAL_DELAY_EPOCHS epochs after that
     *         epoch starts: one second earlier it is locked, at the boundary it executes
     */
    function test_WithdrawalUnlocksAtExactEpochBoundary() public {
        uint256 epochLength = vault.EPOCH_LENGTH();
        uint256 epoch = vault.currentEpoch();
        uint256 epochEnd = vault.DEPLOY_TIMESTAMP() + (epoch + 1) * epochLength;
        vm.warp(epochEnd - 1);
        vm.prank(lp);
        vault.requestWithdrawal(1_000 * 1e18);
        uint256 unlockEpoch = epoch + vault.WITHDRAWAL_DELAY_EPOCHS();
        uint256 unlockTime = vault.DEPLOY_TIMESTAMP() + unlockEpoch * epochLength;

        vm.warp(unlockTime - 1);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(Vault.WithdrawalLocked.selector, unlockEpoch));
        vault.executeWithdrawal();

        vm.warp(unlockTime);
        vm.prank(lp);
        vault.executeWithdrawal();
        assertEq(vault.balanceOf(address(vault)), 0);
    }

    /*//////////////////////////////////////////////////////////////
          FIRST DEPOSIT, DONATIONS AND AN OPEN PNL LIABILITY
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Donation (inflation) attack against the next depositor: the 12-decimal virtual share offset gives half
     *         of the donation to the virtual shares, so the attacker loses and the victim keeps its deposit
     */
    function test_DonationAttackOnFirstDepositUnprofitable() public {
        Vault fresh = new Vault(address(usdc), owner, address(tradingStorage), address(mockOracle));
        address attacker = makeAddr("attacker");
        address victim = makeAddr("victim");
        usdc.mint(attacker, LP_DEPOSIT + 1);
        usdc.mint(victim, 1_000 * 10 ** 6);
        vm.startPrank(attacker);
        usdc.approve(address(fresh), type(uint256).max);
        fresh.deposit(1, attacker);
        usdc.transfer(address(fresh), LP_DEPOSIT);
        vm.stopPrank();
        vm.startPrank(victim);
        usdc.approve(address(fresh), type(uint256).max);
        fresh.deposit(1_000 * 10 ** 6, victim);
        vm.stopPrank();

        assertGe(fresh.convertToAssets(fresh.balanceOf(victim)), 1_000 * 10 ** 6 - 1, "victim lost part of its deposit");
        assertLt(fresh.convertToAssets(fresh.balanceOf(attacker)), LP_DEPOSIT + 1, "attacker gained from the donation");
    }

    /**
     * @notice After every LP has left with trader profit still open, the balance left covers the snapshot liability,
     *         and a new first depositor gets shares worth what it deposits
     */
    function test_FirstDepositAfterAllLpsLeftWithOpenLiability() public {
        uint256 shares = vault.balanceOf(lp);
        vm.prank(lp);
        vault.requestWithdrawal(shares);
        _open(true, 5_000 * 10 ** 6, 10);
        vm.warp(block.timestamp + 3 * vault.EPOCH_LENGTH());
        mockOracle.setPrice(PAIR, (PRICE * 105) / 100);
        vm.prank(lp);
        vault.refreshAndExecuteWithdrawal(EMPTY);
        assertEq(vault.totalSupply(), 0, "shares left");
        (int128 netPnl,,) = vault.pnlSnapshot();
        assertGt(netPnl, 0, "setup: no trader profit");
        assertGe(usdc.balanceOf(address(vault)), uint256(int256(netPnl)), "balance below the liability");

        vm.prank(lp2);
        vault.refreshAndDeposit(1_000 * 10 ** 6, lp2, EMPTY);
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(lp2)), 1_000 * 10 ** 6, 1, "first depositor not at par");
    }

    /*//////////////////////////////////////////////////////////////
             MINIMUM COLLATERAL AND THE REWARD FLOOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice A 10 USDC (MIN_COLLATERAL) 100x long liquidated at about 200% loss pays the liquidator the 0.5% floor of
     *         its collateral and sends the rest to the Vault
     */
    function test_MinCollateralLiquidatedPastFullLossPaysRewardFloor() public {
        uint32 tradeId = _open(true, uint64(engine.MIN_COLLATERAL()), 100);
        uint64 collateral = tradingStorage.getTrade(tradeId).collateral;
        mockOracle.setPrice(PAIR, (PRICE * 98) / 100);

        uint256 vaultBefore = usdc.balanceOf(address(vault));
        vm.prank(keeper);
        engine.liquidate(tradeId, EMPTY);
        uint256 reward = usdc.balanceOf(keeper);
        assertEq(reward, (uint256(collateral) * engine.LIQUIDATOR_MIN_REWARD_BPS()) / engine.BPS_DENOMINATOR(), "reward is not the floor");
        assertGt(reward, 0);
        assertEq(usdc.balanceOf(address(vault)) - vaultBefore, collateral - reward, "rest not sent to the Vault");
    }
}
