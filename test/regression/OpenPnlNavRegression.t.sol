// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TradingEngine} from "../../src/TradingEngine.sol";
import {TradingStorage} from "../../src/TradingStorage.sol";
import {Vault} from "../../src/Vault.sol";
import {OpenPnlLib} from "../../src/libraries/OpenPnlLib.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {MockSpreadManager} from "../mocks/MockSpreadManager.sol";
import {RegressionUSDC} from "./RegressionBase.sol";

/**
 * @title OpenPnlNavRegressionTest
 * @author GushALKDev
 * @notice Round 1 LP timing finding (share price without open PnL), closed in round 2b: totalAssets is the Vault
 *         balance minus the positive net unrealised trader PnL from a snapshot, and actions that price shares
 *         need a fresh snapshot.
 * @dev Written to compile against the code before the change: the Vault is deployed with deployCode (extra
 *      constructor arguments are ignored by the older constructor) and the new functions are called with
 *      low-level calls or matched by selector literal.
 */
contract OpenPnlNavRegressionTest is Test {
    TradingEngine engine;
    TradingStorage tradingStorage;
    Vault vault;
    RegressionUSDC usdc;
    MockOracle mockOracle;

    address owner = makeAddr("owner");
    address lp = makeAddr("lp");
    address lp2 = makeAddr("lp2");
    address trader = makeAddr("trader");

    uint16 constant PAIR = 0;
    uint128 constant PRICE = 50_000 * 1e18;
    bytes4 constant STALE_PNL_SNAPSHOT = bytes4(keccak256("StalePnlSnapshot(uint256)"));
    bytes[] EMPTY;

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new RegressionUSDC();
        mockOracle = new MockOracle();
        mockOracle.setPrice(PAIR, PRICE);

        vm.startPrank(owner);
        tradingStorage = new TradingStorage(address(usdc), owner);
        vault = Vault(payable(deployCode("Vault.sol:Vault", abi.encode(address(usdc), owner, address(tradingStorage), address(mockOracle)))));
        engine = new TradingEngine(
            address(tradingStorage), address(vault), address(mockOracle), address(usdc), makeAddr("treasury"), address(new MockSpreadManager(5)), owner
        );
        tradingStorage.setTradingEngine(address(engine));
        vault.setTradingEngine(address(engine));
        tradingStorage.addPair("BTC/USD", 100, 100_000_000 * 1e18);
        vm.stopPrank();

        _depositFor(lp, 1_000_000 * 10 ** 6);
        usdc.mint(trader, 100_000 * 10 ** 6);
        vm.prank(trader);
        usdc.approve(address(engine), type(uint256).max);
        usdc.mint(lp2, 100_000 * 10 ** 6);
        vm.prank(lp2);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _depositFor(address _lp, uint256 _assets) internal {
        usdc.mint(_lp, _assets);
        vm.startPrank(_lp);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(_assets, _lp);
        vm.stopPrank();
    }

    function _openLong(uint64 _collateral, uint16 _leverage) internal returns (uint32 tradeId) {
        uint128 price = mockOracle.peekPrice(PAIR);
        vm.prank(trader);
        tradeId = engine.openTrade(PAIR, true, _collateral, _leverage, price, 100, 0, 0, EMPTY);
    }

    /// @dev refreshPnlSnapshot does not exist before the change; the low-level call then fails and is ignored
    function _refresh() internal returns (bool ok) {
        (ok,) = address(vault).call(abi.encodeWithSignature("refreshPnlSnapshot(bytes[])", EMPTY));
    }

    /// @dev Positive net trader PnL at the oracle price, from the aggregates (the conservative liability)
    function _liability() internal view returns (uint256) {
        int256 pnl = OpenPnlLib.toUsdcUp(OpenPnlLib.pairPnl(mockOracle.peekPrice(PAIR), 0, tradingStorage.getPairOpenTotals(PAIR)));
        return pnl > 0 ? uint256(pnl) : 0;
    }

    /**
     * @notice An LP withdrawing while traders hold a large unrealised profit is paid at balance minus that profit
     * @dev Before the change the payout used the USDC balance only, so the leaving LP took a share of the profit
     *      that traders were about to realise, at the expense of the LPs who stay.
     */
    function test_Regression_Nav_WithdrawalPaidAtConservativeNav() public {
        uint256 half = vault.balanceOf(lp) / 2;
        vm.prank(lp);
        vault.requestWithdrawal(half);
        _openLong(5_000 * 10 ** 6, 100);
        mockOracle.setPrice(PAIR, 52_500 * 1e18); // +5% on 460,000 USD of notional

        vm.warp(block.timestamp + 3 days);
        _refresh();

        uint256 liability = _liability();
        assertGt(liability, 20_000 * 10 ** 6, "setup: expected a large unrealised profit");
        (uint256 shares,,) = vault.withdrawalRequests(lp);
        uint256 expected = (shares * (usdc.balanceOf(address(vault)) - liability + 1)) / (vault.totalSupply() + 1e12);

        uint256 before = usdc.balanceOf(lp);
        vm.prank(lp);
        vault.executeWithdrawal();
        assertEq(usdc.balanceOf(lp) - before, expected, "withdrawal not priced at the conservative NAV");
    }

    /// @notice With an open position and no snapshot since it changed, deposit reverts
    function test_Regression_Nav_StaleSnapshotBlocksDeposit() public {
        _openLong(1_000 * 10 ** 6, 10);
        vm.prank(lp2);
        vm.expectPartialRevert(STALE_PNL_SNAPSHOT);
        vault.deposit(1_000 * 10 ** 6, lp2);
    }

    function test_Regression_Nav_StaleSnapshotBlocksMint() public {
        _openLong(1_000 * 10 ** 6, 10);
        vm.prank(lp2);
        vm.expectPartialRevert(STALE_PNL_SNAPSHOT);
        vault.mint(1_000 * 1e18, lp2);
    }

    function test_Regression_Nav_StaleSnapshotBlocksExecuteWithdrawal() public {
        vm.prank(lp);
        vault.requestWithdrawal(1_000 * 1e18);
        _openLong(1_000 * 10 ** 6, 10);
        vm.warp(block.timestamp + 3 days);

        vm.prank(lp);
        vm.expectPartialRevert(STALE_PNL_SNAPSHOT);
        vault.executeWithdrawal();
    }

    /// @notice maxDeposit and maxMint report 0 while the snapshot is stale, since deposit and mint revert
    function test_Regression_Nav_MaxDepositAndMaxMintZeroWhenStale() public {
        _openLong(1_000 * 10 ** 6, 10);
        assertEq(vault.maxDeposit(lp2), 0, "maxDeposit not 0 with a stale snapshot");
        assertEq(vault.maxMint(lp2), 0, "maxMint not 0 with a stale snapshot");
    }

    /// @notice The refresh-and-act entry points work when the snapshot is stale
    function test_Regression_Nav_RefreshAndActEntryPointsWork() public {
        vm.prank(lp);
        vault.requestWithdrawal(1_000 * 1e18);
        _openLong(1_000 * 10 ** 6, 10);
        vm.warp(block.timestamp + 3 days);

        vm.prank(lp2);
        (bool deposited,) = address(vault).call(abi.encodeWithSignature("refreshAndDeposit(uint256,address,bytes[])", 1_000 * 10 ** 6, lp2, EMPTY));
        assertTrue(deposited, "refreshAndDeposit failed");
        vm.prank(lp2);
        (bool minted,) = address(vault).call(abi.encodeWithSignature("refreshAndMint(uint256,address,bytes[])", 1_000 * 1e18, lp2, EMPTY));
        assertTrue(minted, "refreshAndMint failed");
        vm.prank(lp);
        (bool withdrawn,) = address(vault).call(abi.encodeWithSignature("refreshAndExecuteWithdrawal(bytes[])", EMPTY));
        assertTrue(withdrawn, "refreshAndExecuteWithdrawal failed");
    }

    /**
     * @notice A winning close is not blocked by the snapshot counting that same profit as a liability
     * @dev sendPayout must compare with the USDC balance: totalAssets already subtracts the unrealised profit
     *      being paid, so comparing with it would refuse a payout the Vault holds the USDC for. A second small
     *      position stays open so totalAssets keeps using the snapshot during the close.
     */
    function test_Regression_Nav_WinningCloseNotBlockedBySnapshotLiability() public {
        uint128 openPrice = mockOracle.peekPrice(PAIR);
        vm.prank(trader);
        engine.openTrade(PAIR, false, 100 * 10 ** 6, 2, openPrice, 100, 0, 0, EMPTY);
        uint32 tradeId = _openLong(5_000 * 10 ** 6, 100);
        mockOracle.setPrice(PAIR, 52_500 * 1e18);
        _refresh();
        // Drain the Vault so its USDC covers the profit but not twice the profit
        uint256 drain = usdc.balanceOf(address(vault)) - 30_000 * 10 ** 6;
        address sink = makeAddr("sink");
        vm.prank(address(engine));
        vault.sendPayout(sink, drain);

        uint256 before = usdc.balanceOf(trader);
        uint128 price = mockOracle.peekPrice(PAIR);
        vm.prank(trader);
        engine.closeTrade(tradeId, price, 100, EMPTY);
        assertGt(usdc.balanceOf(trader) - before, 5_000 * 10 ** 6, "winning close not paid");
    }
}
