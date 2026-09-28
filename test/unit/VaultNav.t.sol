// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../../src/Vault.sol";
import {TradingStorage} from "../../src/TradingStorage.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

contract MockUSDC is ERC20 {
    function name() public pure override returns (string memory) {
        return "USDC";
    }

    function symbol() public pure override returns (string memory) {
        return "USDC";
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title VaultNavTest
 * @author GushALKDev
 * @notice Conservative NAV of the Vault: the PnL snapshot, totalAssets, snapshot freshness, the refresh-and-act
 *         entry points and the ETH refund.
 * @dev Positions are written straight into TradingStorage from a pranked engine address, so each test controls
 *      the open totals exactly. 1,000 USDC at 10x on 50,000 is 10,000 USD of size and 0.2 asset units.
 */
contract VaultNavTest is Test {
    Vault vault;
    TradingStorage tradingStorage;
    MockOracle mockOracle;
    MockUSDC usdc;

    address owner = makeAddr("owner");
    address lp = makeAddr("lp");
    address trader = makeAddr("trader");
    address engine = makeAddr("engine");

    uint16 constant PAIR = 0;
    uint128 constant PRICE = 50_000 * 1e18;
    uint256 constant LP_DEPOSIT = 100_000 * 10 ** 6;
    bytes[] EMPTY;

    event PnlSnapshotRefreshed(int256 netPnl, uint256 timestamp);
    event MaxPnlSnapshotAgeUpdated(uint256 maxPnlSnapshotAge);

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockUSDC();
        mockOracle = new MockOracle();
        mockOracle.setPrice(PAIR, PRICE);

        vm.startPrank(owner);
        tradingStorage = new TradingStorage(address(usdc), owner);
        vault = new Vault(address(usdc), owner, address(tradingStorage), address(mockOracle));
        tradingStorage.setTradingEngine(engine);
        vault.setTradingEngine(engine);
        tradingStorage.addPair("BTC/USD", 100, 100_000_000 * 1e18);
        vm.stopPrank();

        usdc.mint(lp, 10 * LP_DEPOSIT);
        vm.prank(lp);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(lp);
        vault.deposit(LP_DEPOSIT, lp);
    }

    function _open(uint16 _pair, bool _isLong, uint64 _collateral, uint16 _leverage, uint128 _openPrice) internal returns (uint32 tradeId) {
        vm.startPrank(engine);
        tradeId = tradingStorage.storeTrade(trader, _isLong, _pair, _leverage, _collateral, _openPrice, 0, 0);
        tradingStorage.increaseOpenInterest(_pair, uint256(_collateral) * _leverage * 1e12, _isLong);
        vm.stopPrank();
    }

    function _close(uint32 _tradeId) internal {
        TradingStorage.Trade memory trade = tradingStorage.getTrade(_tradeId);
        vm.startPrank(engine);
        tradingStorage.decreaseOpenInterest(trade.pairIndex, uint256(trade.collateral) * trade.leverage * 1e12, trade.isLong);
        tradingStorage.deleteTrade(_tradeId);
        vm.stopPrank();
    }

    function _balance() internal view returns (uint256) {
        return usdc.balanceOf(address(vault));
    }

    /*//////////////////////////////////////////////////////////////
                              TOTAL ASSETS
    //////////////////////////////////////////////////////////////*/

    function test_TotalAssets_EqualsBalanceWithNoOpenTrade() public view {
        assertEq(vault.totalAssets(), _balance());
    }

    /// @notice +10% on a 10,000 USD long is +1,000 USD of trader profit, subtracted from the balance
    function test_TotalAssets_SubtractsSnapshotProfit() public {
        _open(PAIR, true, 1_000 * 10 ** 6, 10, PRICE);
        mockOracle.setPrice(PAIR, 55_000 * 1e18);
        vault.refreshPnlSnapshot(EMPTY);
        assertEq(vault.totalAssets(), _balance() - 1_000 * 10 ** 6);
    }

    /// @notice A net trader loss is not added to the NAV
    function test_TotalAssets_IgnoresNetTraderLoss() public {
        _open(PAIR, true, 1_000 * 10 ** 6, 10, PRICE);
        mockOracle.setPrice(PAIR, 45_000 * 1e18);
        vault.refreshPnlSnapshot(EMPTY);
        (int128 netPnl,,) = vault.pnlSnapshot();
        assertEq(netPnl, -1_000 * 10 ** 6);
        assertEq(vault.totalAssets(), _balance());
    }

    /// @notice Trader profit above the balance floors the NAV at zero instead of reverting
    function test_TotalAssets_FloorsAtZero() public {
        _open(PAIR, true, 50_000 * 10 ** 6, 100, PRICE);
        mockOracle.setPrice(PAIR, 150_000 * 1e18);
        vault.refreshPnlSnapshot(EMPTY);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.convertToAssets(1e18), 0);
    }

    /// @notice A stale snapshot still counts: totalAssets and the previews never revert
    function test_TotalAssets_UsesStaleSnapshot() public {
        _open(PAIR, true, 1_000 * 10 ** 6, 10, PRICE);
        mockOracle.setPrice(PAIR, 55_000 * 1e18);
        vault.refreshPnlSnapshot(EMPTY);
        vm.warp(block.timestamp + vault.maxPnlSnapshotAge() + 1);
        assertFalse(vault.isPnlSnapshotFresh());
        assertEq(vault.totalAssets(), _balance() - 1_000 * 10 ** 6);
        assertEq(vault.previewDeposit(1_000 * 10 ** 6), vault.convertToShares(1_000 * 10 ** 6));
    }

    /**
     * @notice Documented optimistic bias: a position past 100% loss offsets a winner on the same side
     * @dev Long A: 1,000 USDC at 100x from 50,000 (2 units). Long B: 10,000 USDC at 1x from 40,000 (0.25 units).
     *      At 48,000: A is -4,000 (3,000 beyond its collateral, not yet liquidated), B is +2,000.
     *      Per-position clamped: -1,000 + 2,000 = +1,000 owed to traders. Side aggregate: 2.25 * 48,000 -
     *      110,000 = -2,000, so the snapshot shows no liability. The gap (1,000) is at most the excess loss
     *      E = 3,000, and it lasts until A is liquidated.
     */
    function test_TotalAssets_UnderwaterPositionOffsetsWinnerWithinSide() public {
        _open(PAIR, true, 1_000 * 10 ** 6, 100, PRICE);
        _open(PAIR, true, 10_000 * 10 ** 6, 1, 40_000 * 1e18);
        mockOracle.setPrice(PAIR, 48_000 * 1e18);
        vault.refreshPnlSnapshot(EMPTY);

        (int128 netPnl,,) = vault.pnlSnapshot();
        assertEq(netPnl, -2_000 * 10 ** 6);
        assertEq(vault.totalAssets(), _balance(), "no liability recorded");
        int256 perPositionClamped = 1_000 * 10 ** 6;
        int256 excessLoss = 3_000 * 10 ** 6;
        assertGe(int256(netPnl) + excessLoss, perPositionClamped);
    }

    /// @notice The snapshot stops counting once no trade is open, even before the next refresh
    function test_TotalAssets_IgnoresSnapshotWhenNoTradeOpen() public {
        uint32 tradeId = _open(PAIR, true, 1_000 * 10 ** 6, 10, PRICE);
        mockOracle.setPrice(PAIR, 55_000 * 1e18);
        vault.refreshPnlSnapshot(EMPTY);
        _close(tradeId);
        assertEq(vault.totalAssets(), _balance());
    }

    /*//////////////////////////////////////////////////////////////
                               SNAPSHOT
    //////////////////////////////////////////////////////////////*/

    function test_Refresh_StoresSnapshotAndEmits() public {
        _open(PAIR, true, 1_000 * 10 ** 6, 10, PRICE);
        mockOracle.setPrice(PAIR, 55_000 * 1e18);
        vm.expectEmit(address(vault));
        emit PnlSnapshotRefreshed(1_000 * 10 ** 6, block.timestamp);
        vault.refreshPnlSnapshot(EMPTY);

        (int128 netPnl, uint48 timestamp, uint32 nonce) = vault.pnlSnapshot();
        (, uint32 positionsNonce) = tradingStorage.getPositionState();
        assertEq(netPnl, 1_000 * 10 ** 6);
        assertEq(timestamp, block.timestamp);
        assertEq(nonce, positionsNonce);
    }

    /// @notice A long-heavy book is valued at price + conf, the edge that is worst for the Vault
    function test_Refresh_UsesConfidenceEdge() public {
        _open(PAIR, true, 1_000 * 10 ** 6, 10, PRICE);
        mockOracle.setPrice(PAIR, 55_000 * 1e18);
        mockOracle.setConf(PAIR, 500 * 1e18);
        vault.refreshPnlSnapshot(EMPTY);
        (int128 netPnl,,) = vault.pnlSnapshot();
        // 0.2 * 55,500 - 10,000
        assertEq(netPnl, 1_100 * 10 ** 6);
    }

    /// @notice Pairs with open interest are summed; a pair without open interest is not priced
    function test_Refresh_SumsPairsWithOpenInterest() public {
        vm.startPrank(owner);
        tradingStorage.addPair("ETH/USD", 100, 100_000_000 * 1e18);
        tradingStorage.addPair("SOL/USD", 100, 100_000_000 * 1e18);
        vm.stopPrank();
        _open(PAIR, true, 1_000 * 10 ** 6, 10, PRICE); // +1,000 at 55,000
        _open(2, false, 1_000 * 10 ** 6, 10, 100 * 1e18); // 100 units short at 100
        mockOracle.setPrice(PAIR, 55_000 * 1e18);
        mockOracle.setPrice(2, 103 * 1e18); // short loses 300
        vm.expectCall(address(mockOracle), abi.encodeCall(MockOracle.getPrice, (1, EMPTY)), 0);
        vault.refreshPnlSnapshot(EMPTY);
        (int128 netPnl,,) = vault.pnlSnapshot();
        assertEq(netPnl, 700 * 10 ** 6);
    }

    /// @notice Only the ETH this call added beyond the oracle fee is refunded; ETH already held stays
    function test_Refresh_RefundsOnlySurplus() public {
        _open(PAIR, true, 1_000 * 10 ** 6, 10, PRICE);
        mockOracle.setFee(0.1 ether);
        vm.deal(address(vault), 5 ether);
        vm.deal(lp, 1 ether);

        vm.prank(lp);
        vault.refreshPnlSnapshot{value: 1 ether}(EMPTY);

        assertEq(lp.balance, 0.9 ether);
        assertEq(address(vault).balance, 5 ether);
        assertEq(address(mockOracle).balance, 0.1 ether);
    }

    /// @notice With no open interest nothing is priced and the whole msg.value is refunded
    function test_Refresh_NoOpenInterestRefundsAll() public {
        mockOracle.setFee(0.1 ether);
        vm.deal(lp, 1 ether);
        vm.prank(lp);
        vault.refreshPnlSnapshot{value: 1 ether}(EMPTY);
        assertEq(lp.balance, 1 ether);
        (int128 netPnl,,) = vault.pnlSnapshot();
        assertEq(netPnl, 0);
    }

    function test_Refresh_RevertsWhenOracleReverts() public {
        _open(PAIR, true, 1_000 * 10 ** 6, 10, PRICE);
        mockOracle.setShouldRevert(true);
        vm.expectRevert(MockOracle.OracleUnavailable.selector);
        vault.refreshPnlSnapshot(EMPTY);
    }

    /*//////////////////////////////////////////////////////////////
                              FRESHNESS
    //////////////////////////////////////////////////////////////*/

    function test_Freshness_Transitions() public {
        assertTrue(vault.isPnlSnapshotFresh(), "no trade open");
        _open(PAIR, true, 1_000 * 10 ** 6, 10, PRICE);
        assertFalse(vault.isPnlSnapshotFresh(), "open since the last refresh");

        vault.refreshPnlSnapshot(EMPTY);
        assertTrue(vault.isPnlSnapshotFresh(), "just refreshed");
        vm.warp(block.timestamp + vault.maxPnlSnapshotAge());
        assertTrue(vault.isPnlSnapshotFresh(), "at the maximum age");
        vm.warp(block.timestamp + 1);
        assertFalse(vault.isPnlSnapshotFresh(), "past the maximum age");

        vault.refreshPnlSnapshot(EMPTY);
        _open(PAIR, false, 1_000 * 10 ** 6, 10, PRICE);
        assertFalse(vault.isPnlSnapshotFresh(), "a position opened since the refresh");
    }

    function test_Freshness_CloseInvalidatesSnapshot() public {
        _open(PAIR, true, 1_000 * 10 ** 6, 10, PRICE);
        uint32 second = _open(PAIR, true, 1_000 * 10 ** 6, 10, PRICE);
        vault.refreshPnlSnapshot(EMPTY);
        _close(second);
        assertFalse(vault.isPnlSnapshotFresh());
    }

    function test_MaxDepositAndMaxMint_OpenWhenFresh() public {
        _open(PAIR, true, 1_000 * 10 ** 6, 10, PRICE);
        vault.refreshPnlSnapshot(EMPTY);
        assertEq(vault.maxDeposit(lp), type(uint256).max);
        assertEq(vault.maxMint(lp), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                    ERC-4626 PREVIEWS AT THE NAV
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice With a fresh snapshot and a trader profit, deposit and mint match their previews
     * @dev 20,000 USDC of fee income keeps the ratio above 100% for any trader profit in range (at most 10,000)
     */
    function testFuzz_PreviewsMatchActionsAtNav(uint256 _assets, uint256 _priceBps) public {
        usdc.mint(address(vault), 20_000 * 10 ** 6);
        _open(PAIR, true, 1_000 * 10 ** 6, 10, PRICE);
        mockOracle.setPrice(PAIR, uint128((uint256(PRICE) * bound(_priceBps, 5_000, 20_000)) / 10_000));
        vault.refreshPnlSnapshot(EMPTY);
        uint256 assets = bound(_assets, 1, LP_DEPOSIT);

        uint256 previewShares = vault.previewDeposit(assets);
        vm.prank(lp);
        assertEq(vault.deposit(assets, lp), previewShares, "deposit differs from previewDeposit");

        uint256 shares = previewShares == 0 ? 1e12 : previewShares;
        uint256 previewAssets = vault.previewMint(shares);
        vm.prank(lp);
        assertEq(vault.mint(shares, lp), previewAssets, "mint differs from previewMint");
    }

    /// @notice Shares are priced at the NAV: the same assets buy more shares when traders hold a profit
    function test_Deposit_PricedAtNav() public {
        usdc.mint(address(vault), 5_000 * 10 ** 6); // fee income keeps the ratio above 100%
        _open(PAIR, true, 1_000 * 10 ** 6, 10, PRICE);
        mockOracle.setPrice(PAIR, 55_000 * 1e18);
        vault.refreshPnlSnapshot(EMPTY);
        uint256 supply = vault.totalSupply();
        uint256 expected = (1_000 * 10 ** 6 * (supply + 1e12)) / (_balance() - 1_000 * 10 ** 6 + 1);
        vm.prank(lp);
        assertEq(vault.deposit(1_000 * 10 ** 6, lp), expected);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSITS BELOW PAR
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposits stay open at exactly 100%
    function test_Deposit_AllowedAtExactlyPar() public {
        assertEq(vault.collateralizationRatio(), 1e18);
        assertEq(vault.maxDeposit(lp), type(uint256).max);
        vm.prank(lp);
        vault.deposit(1_000 * 10 ** 6, lp);
    }

    /// @notice The first deposit into an empty Vault is not blocked (no shares, ratio reported as max)
    function test_Deposit_AllowedIntoEmptyVault() public {
        Vault empty = new Vault(address(usdc), owner, address(tradingStorage), address(mockOracle));
        vm.startPrank(lp);
        usdc.approve(address(empty), type(uint256).max);
        empty.deposit(1_000 * 10 ** 6, lp);
        vm.stopPrank();
        assertEq(empty.balanceOf(lp), 1_000 * 1e18);
    }

    /**
     * @notice With open trader profit pushing the ratio below 100% and no SolvencyManager set (no rescue to
     *         capture), deposits go through at the conservative NAV
     */
    function test_Deposit_AllowedBelowParAtNavWithoutSolvencyManager() public {
        _open(PAIR, true, 1_000 * 10 ** 6, 10, PRICE);
        mockOracle.setPrice(PAIR, 55_000 * 1e18);
        vault.refreshPnlSnapshot(EMPTY);
        assertEq(vault.collateralizationRatio(), 0.99e18);
        assertEq(address(vault.solvencyManager()), address(0));
        assertEq(vault.maxDeposit(lp), type(uint256).max);
        assertEq(vault.maxMint(lp), type(uint256).max);

        uint256 supply = vault.totalSupply();
        uint256 expected = (1_000 * 10 ** 6 * (supply + 1e12)) / (_balance() - 1_000 * 10 ** 6 + 1);
        vm.prank(lp);
        assertEq(vault.deposit(1_000 * 10 ** 6, lp), expected, "shares not minted at the NAV");
    }

    /// @notice Withdrawals are not blocked below 100%: they pay the NAV, which already carries the loss
    function test_ExecuteWithdrawal_AllowedBelowPar() public {
        uint256 shares = vault.balanceOf(lp) / 2;
        vm.prank(lp);
        vault.requestWithdrawal(shares);
        vm.prank(engine);
        vault.sendPayout(trader, 10_000 * 10 ** 6);
        vm.warp(block.timestamp + 3 * vault.EPOCH_LENGTH());
        assertLt(vault.collateralizationRatio(), 1e18);
        vm.prank(lp);
        vault.executeWithdrawal();
        assertEq(vault.balanceOf(address(vault)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                       REFRESH AND ACT ENTRY POINTS
    //////////////////////////////////////////////////////////////*/

    function test_RefreshAndDeposit_RefundsSurplus() public {
        _open(PAIR, true, 1_000 * 10 ** 6, 10, PRICE);
        mockOracle.setFee(0.1 ether);
        vm.deal(lp, 1 ether);
        vm.prank(lp);
        vault.refreshAndDeposit{value: 1 ether}(1_000 * 10 ** 6, lp, EMPTY);
        assertEq(lp.balance, 0.9 ether);
        assertTrue(vault.isPnlSnapshotFresh());
    }

    function test_RefreshAndDeposit_RevertsWhenPaused() public {
        vm.prank(owner);
        vault.pause();
        vm.prank(lp);
        vm.expectRevert(Vault.EnforcedPause.selector);
        vault.refreshAndDeposit(1_000 * 10 ** 6, lp, EMPTY);
    }

    function test_RefreshAndMint_RevertsWhenPaused() public {
        vm.prank(owner);
        vault.pause();
        vm.prank(lp);
        vm.expectRevert(Vault.EnforcedPause.selector);
        vault.refreshAndMint(1_000 * 1e18, lp, EMPTY);
    }

    /// @notice refreshAndExecuteWithdrawal pays at the NAV of the snapshot it takes
    function test_RefreshAndExecuteWithdrawal_PaysAtNav() public {
        uint256 shares = vault.balanceOf(lp) / 2;
        vm.prank(lp);
        vault.requestWithdrawal(shares);
        _open(PAIR, true, 1_000 * 10 ** 6, 10, PRICE);
        mockOracle.setPrice(PAIR, 55_000 * 1e18);
        vm.warp(block.timestamp + 3 * vault.EPOCH_LENGTH());

        uint256 expected = (shares * (_balance() - 1_000 * 10 ** 6 + 1)) / (vault.totalSupply() + 1e12);
        uint256 before = usdc.balanceOf(lp);
        vm.prank(lp);
        vault.refreshAndExecuteWithdrawal(EMPTY);
        assertEq(usdc.balanceOf(lp) - before, expected);
    }

    /*//////////////////////////////////////////////////////////////
                       REALISED AND NAV RATIOS
    //////////////////////////////////////////////////////////////*/

    /// @notice The realised ratio ignores open PnL; the coverage ratio uses the NAV
    function test_Ratios_RealisedIgnoresOpenPnl() public {
        _open(PAIR, true, 1_000 * 10 ** 6, 10, PRICE);
        mockOracle.setPrice(PAIR, 55_000 * 1e18);
        vault.refreshPnlSnapshot(EMPTY);
        uint256 supply = vault.totalSupply();
        assertEq(vault.realisedCollateralizationRatio(), (_balance() * 1e12 * 1e18) / supply);
        assertEq(vault.collateralizationRatio(), ((_balance() - 1_000 * 10 ** 6) * 1e12 * 1e18) / supply);
        assertEq(vault.realisedCollateralizationDeficit(), 0);
        assertEq(vault.collateralizationDeficit(), 1_000 * 10 ** 6);
    }

    /**
     * @notice The realised ratio is at least the NAV ratio and the realised deficit at most the NAV deficit
     * @dev NAV = balance minus a non-negative liability. The SolvencyManager relies on this to return early on a
     *      NAV ratio of 100% or more without skipping a bonding the realised ratio would need.
     */
    function testFuzz_Ratios_RealisedAtLeastNav(uint256 _priceBps, uint256 _payout, bool _isLong) public {
        _open(PAIR, _isLong, 1_000 * 10 ** 6, 100, PRICE);
        vm.prank(engine);
        vault.sendPayout(trader, bound(_payout, 0, LP_DEPOSIT));
        mockOracle.setPrice(PAIR, uint128((uint256(PRICE) * bound(_priceBps, 5_000, 20_000)) / 10_000));
        vault.refreshPnlSnapshot(EMPTY);
        assertGe(vault.realisedCollateralizationRatio(), vault.collateralizationRatio());
        assertLe(vault.realisedCollateralizationDeficit(), vault.collateralizationDeficit());
    }

    function test_Ratios_RealisedDeficitAfterPayout() public {
        vm.prank(engine);
        vault.sendPayout(trader, 4_000 * 10 ** 6);
        assertEq(vault.realisedCollateralizationDeficit(), 4_000 * 10 ** 6);
        assertEq(vault.realisedCollateralizationRatio(), 0.96e18);
    }

    function test_Ratios_RealisedMaxWithNoShares() public {
        Vault empty = new Vault(address(usdc), owner, address(tradingStorage), address(mockOracle));
        assertEq(empty.realisedCollateralizationRatio(), type(uint256).max);
        assertEq(empty.realisedCollateralizationDeficit(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/

    function test_MaxPnlSnapshotAge_Default() public view {
        assertEq(vault.maxPnlSnapshotAge(), vault.DEFAULT_MAX_PNL_SNAPSHOT_AGE());
    }

    function test_SetMaxPnlSnapshotAge() public {
        uint256 ceiling = vault.MAX_PNL_SNAPSHOT_AGE_CEILING();
        vm.expectEmit(address(vault));
        emit MaxPnlSnapshotAgeUpdated(ceiling);
        vm.prank(owner);
        vault.setMaxPnlSnapshotAge(ceiling);
        assertEq(vault.maxPnlSnapshotAge(), ceiling);
    }

    function test_SetMaxPnlSnapshotAge_RevertsOutOfBounds() public {
        uint256 ceiling = vault.MAX_PNL_SNAPSHOT_AGE_CEILING();
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(Vault.InvalidMaxPnlSnapshotAge.selector, 0));
        vault.setMaxPnlSnapshotAge(0);
        vm.expectRevert(abi.encodeWithSelector(Vault.InvalidMaxPnlSnapshotAge.selector, ceiling + 1));
        vault.setMaxPnlSnapshotAge(ceiling + 1);
        vm.stopPrank();
    }

    function test_SetMaxPnlSnapshotAge_OnlyOwner() public {
        vm.prank(lp);
        vm.expectRevert();
        vault.setMaxPnlSnapshotAge(120);
    }

    function test_Constructor_RevertOnZeroStorageOrOracle() public {
        vm.expectRevert(Vault.ZeroAddress.selector);
        new Vault(address(usdc), owner, address(0), address(mockOracle));
        vm.expectRevert(Vault.ZeroAddress.selector);
        new Vault(address(usdc), owner, address(tradingStorage), address(0));
    }
}
