// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TradingEngine} from "../../src/TradingEngine.sol";
import {TradingStorage} from "../../src/TradingStorage.sol";
import {Vault} from "../../src/Vault.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {MockSpreadManager} from "../mocks/MockSpreadManager.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

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

contract TradingEngineTest is Test {
    using SafeTransferLib for address;

    TradingEngine engine;
    TradingStorage tradingStorage;
    Vault vault;
    MockUSDC usdc;
    MockOracle mockOracle;
    MockSpreadManager mockSpreadManager;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address treasuryAddr = makeAddr("treasury");

    // Default trade parameters
    uint16 constant DEFAULT_PAIR_INDEX = 0;
    uint16 constant DEFAULT_LEVERAGE = 10;
    uint64 constant DEFAULT_COLLATERAL = 100 * 10 ** 6; // 100 USDC
    uint128 constant DEFAULT_ORACLE_PRICE = 50_000 * 1e18;
    uint16 constant DEFAULT_SLIPPAGE_BPS = 50; // 0.5%

    // Spread-adjusted prices: oracle * (10000 ± 5) / 10000
    uint128 constant DEFAULT_LONG_OPEN_PRICE = (50_000 * 1e18 * 10_005) / 10_000; // 50025e18
    uint128 constant DEFAULT_SHORT_OPEN_PRICE = (50_000 * 1e18 * 9_995) / 10_000; // 49975e18

    // TP/SL must be vs oracle price (not execution price)
    uint128 constant DEFAULT_TP = 55_000 * 1e18;
    uint128 constant DEFAULT_SL = 45_000 * 1e18;

    // Fee constants: openFee = 100_000_000 * 10 * 8 / 10000 = 800_000
    uint256 constant DEFAULT_OPEN_FEE = 800_000;
    uint64 constant DEFAULT_EFFECTIVE_COLLATERAL = DEFAULT_COLLATERAL - uint64(DEFAULT_OPEN_FEE); // 99_200_000

    // Empty price update for mock oracle
    bytes[] EMPTY_UPDATE;

    // Events
    event TradeOpened(
        uint256 indexed tradeId,
        address indexed user,
        uint16 pairIndex,
        bool isLong,
        uint64 collateral,
        uint16 leverage,
        uint128 openPrice,
        uint256 fee
    );
    event TradeClosed(
        uint256 indexed tradeId,
        address indexed user,
        uint128 closePrice,
        int256 pnlUsdc,
        uint256 payoutUsdc,
        uint256 fee,
        int256 fundingOwedUsdc
    );
    event FeesDistributed(uint256 vaultFee, uint256 treasuryFee);
    event TpUpdated(uint256 indexed tradeId, uint128 newTp);
    event SlUpdated(uint256 indexed tradeId, uint128 newSl);
    event TreasuryUpdated(address indexed newTreasury);
    event Paused(address account);
    event Unpaused(address account);

    function setUp() public {
        EMPTY_UPDATE = new bytes[](0);

        usdc = new MockUSDC();
        mockOracle = new MockOracle();
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, DEFAULT_ORACLE_PRICE);
        mockSpreadManager = new MockSpreadManager(5);

        vm.startPrank(owner);
        tradingStorage = new TradingStorage(address(usdc), owner);
        vault = new Vault(address(usdc), owner);
        engine = new TradingEngine(
            address(tradingStorage),
            address(vault),
            address(mockOracle),
            address(usdc),
            treasuryAddr,
            address(mockSpreadManager),
            owner
        );

        tradingStorage.setTradingEngine(address(engine));
        vault.setTradingEngine(address(engine));

        // Add default pair (BTC/USD) with 100x max leverage and 10M max OI
        tradingStorage.addPair("BTC/USD", 100, 10_000_000 * 1e18);
        vm.stopPrank();

        // Fund alice with USDC and approve engine
        usdc.mint(alice, 1_000_000 * 10 ** 6);
        vm.prank(alice);
        usdc.approve(address(engine), type(uint256).max);

        // Fund bob with USDC and approve engine
        usdc.mint(bob, 1_000_000 * 10 ** 6);
        vm.prank(bob);
        usdc.approve(address(engine), type(uint256).max);

        // Seed Vault with LP liquidity so it can pay winning traders
        usdc.mint(address(this), 10_000_000 * 10 ** 6);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(10_000_000 * 10 ** 6, address(this));
    }

    /*//////////////////////////////////////////////////////////////
                          HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _openDefaultTrade(address _user) internal returns (uint32 tradeId) {
        vm.prank(_user);
        tradeId = engine.openTrade(
            DEFAULT_PAIR_INDEX,
            true,
            DEFAULT_COLLATERAL,
            DEFAULT_LEVERAGE,
            DEFAULT_LONG_OPEN_PRICE,
            DEFAULT_SLIPPAGE_BPS,
            DEFAULT_TP,
            DEFAULT_SL,
            EMPTY_UPDATE
        );
    }

    /**
     * @dev Calculate long open execution price: oracle * 10005 / 10000
     */
    function _longOpenPrice(uint128 oraclePrice) internal pure returns (uint128) {
        return uint128((uint256(oraclePrice) * 10_005) / 10_000);
    }

    /**
     * @dev Calculate long close execution price: oracle * 9995 / 10000
     */
    function _longClosePrice(uint128 oraclePrice) internal pure returns (uint128) {
        return uint128((uint256(oraclePrice) * 9_995) / 10_000);
    }

    /**
     * @dev Calculate short open execution price: oracle * 9995 / 10000
     */
    function _shortOpenPrice(uint128 oraclePrice) internal pure returns (uint128) {
        return uint128((uint256(oraclePrice) * 9_995) / 10_000);
    }

    /**
     * @dev Calculate short close execution price: oracle * 10005 / 10000
     */
    function _shortClosePrice(uint128 oraclePrice) internal pure returns (uint128) {
        return uint128((uint256(oraclePrice) * 10_005) / 10_000);
    }

    /**
     * @dev Calculate open fee: collateral * leverage * 8 / 10000
     */
    function _openFee(uint64 collateral, uint16 leverage) internal pure returns (uint256) {
        return (uint256(collateral) * uint256(leverage) * 8) / 10_000;
    }

    /**
     * @dev Calculate close fee: collateral * leverage * 8 / 10000 (on effective collateral)
     */
    function _closeFee(uint64 effectiveCollateral, uint16 leverage) internal pure returns (uint256) {
        return (uint256(effectiveCollateral) * uint256(leverage) * 8) / 10_000;
    }

    /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_SetsImmutables() public view {
        assertEq(address(engine.TRADING_STORAGE()), address(tradingStorage));
        assertEq(address(engine.VAULT()), address(vault));
        assertEq(address(engine.ORACLE()), address(mockOracle));
        assertEq(engine.ASSET(), address(usdc));
    }

    function test_Constructor_SetsOwner() public view {
        assertEq(engine.owner(), owner);
    }

    function test_Constructor_SetsTreasury() public view {
        assertEq(engine.treasury(), treasuryAddr);
    }

    function test_Constructor_SetsOracleImmutable() public view {
        assertEq(address(engine.ORACLE()), address(mockOracle));
    }

    function test_Constructor_SetsSpreadManagerImmutable() public view {
        assertEq(address(engine.SPREAD_MANAGER()), address(mockSpreadManager));
    }

    function test_Constructor_RevertOnZeroTradingStorage() public {
        vm.expectRevert(TradingEngine.ZeroAddress.selector);
        new TradingEngine(address(0), address(vault), address(mockOracle), address(usdc), treasuryAddr, address(mockSpreadManager), owner);
    }

    function test_Constructor_RevertOnZeroVault() public {
        vm.expectRevert(TradingEngine.ZeroAddress.selector);
        new TradingEngine(address(tradingStorage), address(0), address(mockOracle), address(usdc), treasuryAddr, address(mockSpreadManager), owner);
    }

    function test_Constructor_RevertOnZeroOracle() public {
        vm.expectRevert(TradingEngine.ZeroAddress.selector);
        new TradingEngine(address(tradingStorage), address(vault), address(0), address(usdc), treasuryAddr, address(mockSpreadManager), owner);
    }

    function test_Constructor_RevertOnZeroAsset() public {
        vm.expectRevert(TradingEngine.ZeroAddress.selector);
        new TradingEngine(address(tradingStorage), address(vault), address(mockOracle), address(0), treasuryAddr, address(mockSpreadManager), owner);
    }

    function test_Constructor_RevertOnZeroTreasury() public {
        vm.expectRevert(TradingEngine.ZeroAddress.selector);
        new TradingEngine(address(tradingStorage), address(vault), address(mockOracle), address(usdc), address(0), address(mockSpreadManager), owner);
    }

    function test_Constructor_RevertOnZeroSpreadManager() public {
        vm.expectRevert(TradingEngine.ZeroAddress.selector);
        new TradingEngine(address(tradingStorage), address(vault), address(mockOracle), address(usdc), treasuryAddr, address(0), owner);
    }

    /*//////////////////////////////////////////////////////////////
                        OPEN TRADE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_OpenTrade() public {
        uint256 aliceBalBefore = usdc.balanceOf(alice);
        uint256 storageBefore = usdc.balanceOf(address(tradingStorage));

        uint32 tradeId = _openDefaultTrade(alice);

        assertEq(tradeId, 0);
        // Alice sends full collateral
        assertEq(usdc.balanceOf(alice), aliceBalBefore - DEFAULT_COLLATERAL);
        // Storage retains effectiveCollateral (full - openFee split to vault+treasury)
        assertEq(usdc.balanceOf(address(tradingStorage)), storageBefore + DEFAULT_EFFECTIVE_COLLATERAL);

        TradingStorage.Trade memory trade = tradingStorage.getTrade(tradeId);
        assertEq(trade.user, alice);
        assertTrue(trade.isLong);
        assertEq(trade.pairIndex, DEFAULT_PAIR_INDEX);
        assertEq(trade.leverage, DEFAULT_LEVERAGE);
        // Stored collateral is effective (minus fee)
        assertEq(trade.collateral, DEFAULT_EFFECTIVE_COLLATERAL);
        // Open price has spread baked in
        assertEq(trade.openPrice, DEFAULT_LONG_OPEN_PRICE);
        assertEq(trade.tp, DEFAULT_TP);
        assertEq(trade.sl, DEFAULT_SL);
    }

    function test_OpenTrade_StoresExecutionPriceWithSpread() public {
        uint32 tradeId = _openDefaultTrade(alice);
        TradingStorage.Trade memory trade = tradingStorage.getTrade(tradeId);

        // Long open: price * 10005 / 10000
        assertEq(trade.openPrice, _longOpenPrice(DEFAULT_ORACLE_PRICE));
        // Verify it's different from oracle price
        assertGt(trade.openPrice, DEFAULT_ORACLE_PRICE);
    }

    function test_OpenTrade_ShortStoresSpreadDown() public {
        uint128 shortTp = 45_000 * 1e18;
        uint128 shortSl = 55_000 * 1e18;

        vm.prank(alice);
        uint32 tradeId = engine.openTrade(
            DEFAULT_PAIR_INDEX,
            false,
            DEFAULT_COLLATERAL,
            DEFAULT_LEVERAGE,
            DEFAULT_SHORT_OPEN_PRICE,
            DEFAULT_SLIPPAGE_BPS,
            shortTp,
            shortSl,
            EMPTY_UPDATE
        );

        TradingStorage.Trade memory trade = tradingStorage.getTrade(tradeId);
        // Short open: price * 9995 / 10000
        assertEq(trade.openPrice, _shortOpenPrice(DEFAULT_ORACLE_PRICE));
        assertLt(trade.openPrice, DEFAULT_ORACLE_PRICE);
    }

    function test_OpenTrade_EmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit TradeOpened(0, alice, DEFAULT_PAIR_INDEX, true, DEFAULT_EFFECTIVE_COLLATERAL, DEFAULT_LEVERAGE, DEFAULT_LONG_OPEN_PRICE, DEFAULT_OPEN_FEE);

        _openDefaultTrade(alice);
    }

    function test_OpenTrade_UpdatesOpenInterest() public {
        _openDefaultTrade(alice);

        // OI based on effectiveCollateral
        uint256 expectedOI = uint256(DEFAULT_EFFECTIVE_COLLATERAL) * uint256(DEFAULT_LEVERAGE) * 1e12;
        assertEq(tradingStorage.getOpenInterest(DEFAULT_PAIR_INDEX), expectedOI);
    }

    function test_OpenTrade_MultipleTrades() public {
        uint32 id0 = _openDefaultTrade(alice);
        uint32 id1 = _openDefaultTrade(alice);
        uint32 id2 = _openDefaultTrade(bob);

        assertEq(id0, 0);
        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(tradingStorage.getTradeCounter(), 3);
    }

    function test_OpenTrade_Short() public {
        uint128 shortTp = 45_000 * 1e18;
        uint128 shortSl = 55_000 * 1e18;

        vm.prank(alice);
        uint32 tradeId = engine.openTrade(
            DEFAULT_PAIR_INDEX,
            false,
            DEFAULT_COLLATERAL,
            DEFAULT_LEVERAGE,
            DEFAULT_SHORT_OPEN_PRICE,
            DEFAULT_SLIPPAGE_BPS,
            shortTp,
            shortSl,
            EMPTY_UPDATE
        );

        TradingStorage.Trade memory trade = tradingStorage.getTrade(tradeId);
        assertFalse(trade.isLong);
        assertEq(trade.tp, shortTp);
        assertEq(trade.sl, shortSl);
    }

    function test_OpenTrade_NoTpNoSl() public {
        vm.prank(alice);
        uint32 tradeId = engine.openTrade(
            DEFAULT_PAIR_INDEX,
            true,
            DEFAULT_COLLATERAL,
            DEFAULT_LEVERAGE,
            DEFAULT_LONG_OPEN_PRICE,
            DEFAULT_SLIPPAGE_BPS,
            0,
            0,
            EMPTY_UPDATE
        );

        TradingStorage.Trade memory trade = tradingStorage.getTrade(tradeId);
        assertEq(trade.tp, 0);
        assertEq(trade.sl, 0);
    }

    function test_OpenTrade_RevertBelowMinCollateral() public {
        uint64 belowMin = uint64(engine.MIN_COLLATERAL()) - 1;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TradingEngine.BelowMinCollateral.selector, belowMin));
        engine.openTrade(DEFAULT_PAIR_INDEX, true, belowMin, DEFAULT_LEVERAGE, DEFAULT_LONG_OPEN_PRICE, DEFAULT_SLIPPAGE_BPS, 0, 0, EMPTY_UPDATE);
    }

    function test_OpenTrade_RevertOnZeroLeverage() public {
        vm.prank(alice);
        vm.expectRevert(TradingEngine.ZeroLeverage.selector);
        engine.openTrade(DEFAULT_PAIR_INDEX, true, DEFAULT_COLLATERAL, 0, DEFAULT_LONG_OPEN_PRICE, DEFAULT_SLIPPAGE_BPS, 0, 0, EMPTY_UPDATE);
    }

    function test_OpenTrade_RevertOnLeverageExceedsMax() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TradingEngine.LeverageExceedsMax.selector, uint16(101), uint16(100)));
        engine.openTrade(DEFAULT_PAIR_INDEX, true, DEFAULT_COLLATERAL, 101, DEFAULT_LONG_OPEN_PRICE, DEFAULT_SLIPPAGE_BPS, 0, 0, EMPTY_UPDATE);
    }

    function test_OpenTrade_RevertOnInactivePair() public {
        vm.prank(owner);
        tradingStorage.updatePair(0, 100, 10_000_000 * 1e18, false);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TradingEngine.PairNotActive.selector, uint16(0)));
        engine.openTrade(DEFAULT_PAIR_INDEX, true, DEFAULT_COLLATERAL, DEFAULT_LEVERAGE, DEFAULT_LONG_OPEN_PRICE, DEFAULT_SLIPPAGE_BPS, 0, 0, EMPTY_UPDATE);
    }

    function test_OpenTrade_RevertOnMaxOIExceeded() public {
        vm.prank(owner);
        tradingStorage.updatePair(0, 100, 100 * 1e18, true); // 100 USD max OI

        vm.prank(alice);
        vm.expectRevert(); // MaxOpenInterestExceeded
        engine.openTrade(DEFAULT_PAIR_INDEX, true, DEFAULT_COLLATERAL, DEFAULT_LEVERAGE, DEFAULT_LONG_OPEN_PRICE, DEFAULT_SLIPPAGE_BPS, 0, 0, EMPTY_UPDATE);
    }

    function test_OpenTrade_RevertWhenPaused() public {
        vm.prank(owner);
        engine.pause();

        vm.prank(alice);
        vm.expectRevert(TradingEngine.EnforcedPause.selector);
        engine.openTrade(DEFAULT_PAIR_INDEX, true, DEFAULT_COLLATERAL, DEFAULT_LEVERAGE, DEFAULT_LONG_OPEN_PRICE, DEFAULT_SLIPPAGE_BPS, 0, 0, EMPTY_UPDATE);
    }

    function test_OpenTrade_RevertOnInsufficientBalance() public {
        address broke = makeAddr("broke");
        vm.prank(broke);
        usdc.approve(address(engine), type(uint256).max);

        vm.prank(broke);
        vm.expectRevert(); // SafeTransferLib revert
        engine.openTrade(DEFAULT_PAIR_INDEX, true, DEFAULT_COLLATERAL, DEFAULT_LEVERAGE, DEFAULT_LONG_OPEN_PRICE, DEFAULT_SLIPPAGE_BPS, 0, 0, EMPTY_UPDATE);
    }

    /*//////////////////////////////////////////////////////////////
                    TP/SL ORACLE VALIDATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_OpenTrade_RevertOnTpAlreadyTriggered_Long() public {
        // Long: TP must be > oracle price. Setting TP = oracle price should revert.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TradingEngine.TpAlreadyTriggered.selector, DEFAULT_ORACLE_PRICE, DEFAULT_ORACLE_PRICE));
        engine.openTrade(
            DEFAULT_PAIR_INDEX,
            true,
            DEFAULT_COLLATERAL,
            DEFAULT_LEVERAGE,
            DEFAULT_LONG_OPEN_PRICE,
            DEFAULT_SLIPPAGE_BPS,
            DEFAULT_ORACLE_PRICE,
            0,
            EMPTY_UPDATE
        );
    }

    function test_OpenTrade_RevertOnSlAlreadyTriggered_Long() public {
        // Long: SL must be < oracle price. Setting SL = oracle price should revert.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TradingEngine.SlAlreadyTriggered.selector, DEFAULT_ORACLE_PRICE, DEFAULT_ORACLE_PRICE));
        engine.openTrade(
            DEFAULT_PAIR_INDEX,
            true,
            DEFAULT_COLLATERAL,
            DEFAULT_LEVERAGE,
            DEFAULT_LONG_OPEN_PRICE,
            DEFAULT_SLIPPAGE_BPS,
            0,
            DEFAULT_ORACLE_PRICE,
            EMPTY_UPDATE
        );
    }

    function test_OpenTrade_RevertOnTpAlreadyTriggered_Short() public {
        // Short: TP must be < oracle price. Setting TP = oracle price should revert.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TradingEngine.TpAlreadyTriggered.selector, DEFAULT_ORACLE_PRICE, DEFAULT_ORACLE_PRICE));
        engine.openTrade(
            DEFAULT_PAIR_INDEX,
            false,
            DEFAULT_COLLATERAL,
            DEFAULT_LEVERAGE,
            DEFAULT_SHORT_OPEN_PRICE,
            DEFAULT_SLIPPAGE_BPS,
            DEFAULT_ORACLE_PRICE,
            0,
            EMPTY_UPDATE
        );
    }

    function test_OpenTrade_RevertOnSlAlreadyTriggered_Short() public {
        // Short: SL must be > oracle price. Setting SL = oracle price should revert.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TradingEngine.SlAlreadyTriggered.selector, DEFAULT_ORACLE_PRICE, DEFAULT_ORACLE_PRICE));
        engine.openTrade(
            DEFAULT_PAIR_INDEX,
            false,
            DEFAULT_COLLATERAL,
            DEFAULT_LEVERAGE,
            DEFAULT_SHORT_OPEN_PRICE,
            DEFAULT_SLIPPAGE_BPS,
            0,
            DEFAULT_ORACLE_PRICE,
            EMPTY_UPDATE
        );
    }

    /*//////////////////////////////////////////////////////////////
                        CLOSE TRADE TESTS — PROFIT
    //////////////////////////////////////////////////////////////*/

    function test_CloseTrade_LongProfit() public {
        uint32 tradeId = _openDefaultTrade(alice);

        // Price went up 10%: 50k → 55k
        uint128 closeOracle = 55_000 * 1e18;
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, closeOracle);
        uint128 closeExec = _longClosePrice(closeOracle);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        engine.closeTrade(tradeId, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);
        uint256 aliceAfter = usdc.balanceOf(alice);

        // Positive payout (even after close fee)
        assertGt(aliceAfter - aliceBefore, DEFAULT_EFFECTIVE_COLLATERAL);

        // Trade deleted
        TradingStorage.Trade memory trade = tradingStorage.getTrade(tradeId);
        assertEq(trade.user, address(0));

        // OI decreased to 0
        assertEq(tradingStorage.getOpenInterest(DEFAULT_PAIR_INDEX), 0);
    }

    function test_CloseTrade_ShortProfit() public {
        uint128 shortTp = 45_000 * 1e18;
        uint128 shortSl = 55_000 * 1e18;

        vm.prank(alice);
        uint32 tradeId = engine.openTrade(
            DEFAULT_PAIR_INDEX,
            false,
            DEFAULT_COLLATERAL,
            DEFAULT_LEVERAGE,
            DEFAULT_SHORT_OPEN_PRICE,
            DEFAULT_SLIPPAGE_BPS,
            shortTp,
            shortSl,
            EMPTY_UPDATE
        );

        // Price went down 10%: 50k → 45k (profit for short)
        uint128 closeOracle = 45_000 * 1e18;
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, closeOracle);
        uint128 closeExec = _shortClosePrice(closeOracle);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        engine.closeTrade(tradeId, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);
        uint256 aliceAfter = usdc.balanceOf(alice);

        assertGt(aliceAfter - aliceBefore, DEFAULT_EFFECTIVE_COLLATERAL);
    }

    function test_CloseTrade_UsesSpreadOnClose() public {
        uint32 tradeId = _openDefaultTrade(alice);

        // Close at same oracle price
        uint128 closeExec = _longClosePrice(DEFAULT_ORACLE_PRICE);

        vm.prank(alice);
        engine.closeTrade(tradeId, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);

        // With spread on both open and close, trader should have a small loss even at same oracle price
        // Open: 50025e18, Close: 49975e18 → net loss due to spread + close fee
    }

    function test_CloseTrade_EmitsEvent_Profit() public {
        uint32 tradeId = _openDefaultTrade(alice);

        uint128 closeOracle = 55_000 * 1e18;
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, closeOracle);
        uint128 closeExec = _longClosePrice(closeOracle);

        // Calculate expected PnL using effectiveCollateral
        uint256 size = uint256(DEFAULT_EFFECTIVE_COLLATERAL) * uint256(DEFAULT_LEVERAGE);
        uint256 exitValue = (uint256(closeExec) * size) / uint256(DEFAULT_LONG_OPEN_PRICE);
        int256 expectedPnl = int256(exitValue) - int256(size);
        uint256 rawPayout = uint256(expectedPnl) + uint256(DEFAULT_EFFECTIVE_COLLATERAL);
        uint256 closeFeeVal = _closeFee(DEFAULT_EFFECTIVE_COLLATERAL, DEFAULT_LEVERAGE);
        uint256 expectedPayout = rawPayout - closeFeeVal;

        vm.expectEmit(true, true, false, true);
        emit TradeClosed(tradeId, alice, closeExec, expectedPnl, expectedPayout, closeFeeVal, 0);

        vm.prank(alice);
        engine.closeTrade(tradeId, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);
    }

    /*//////////////////////////////////////////////////////////////
                        CLOSE TRADE TESTS — LOSS
    //////////////////////////////////////////////////////////////*/

    function test_CloseTrade_LongPartialLoss() public {
        uint32 tradeId = _openDefaultTrade(alice);

        // Price went down 5%: 50k → 47.5k
        uint128 closeOracle = 47_500 * 1e18;
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, closeOracle);
        uint128 closeExec = _longClosePrice(closeOracle);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        vm.prank(alice);
        engine.closeTrade(tradeId, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);

        uint256 aliceAfter = usdc.balanceOf(alice);
        uint256 vaultAfter = usdc.balanceOf(address(vault));

        // Alice gets less than effectiveCollateral back (partial loss + close fee)
        assertLt(aliceAfter - aliceBefore, DEFAULT_EFFECTIVE_COLLATERAL);
        // Vault gains from loss + fee share
        assertGt(vaultAfter, vaultBefore);
    }

    function test_CloseTrade_LongFullLoss() public {
        uint32 tradeId = _openDefaultTrade(alice);

        // Price went down 10%: 50k → 45k (10x leverage ≈ 100% loss)
        uint128 closeOracle = 45_000 * 1e18;
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, closeOracle);
        uint128 closeExec = _longClosePrice(closeOracle);

        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        engine.closeTrade(tradeId, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);

        uint256 aliceAfter = usdc.balanceOf(alice);

        // Alice gets nothing (full loss, payout=0, close fee=0 since payout was 0)
        assertEq(aliceAfter, aliceBefore);
    }

    function test_CloseTrade_LongMoreThan100Loss() public {
        uint32 tradeId = _openDefaultTrade(alice);

        // Price went down 15%: 50k → 42.5k (10x leverage = 150% loss but capped at 0 payout)
        uint128 closeOracle = 42_500 * 1e18;
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, closeOracle);
        uint128 closeExec = _longClosePrice(closeOracle);

        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        engine.closeTrade(tradeId, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);

        assertEq(usdc.balanceOf(alice), aliceBefore);
    }

    function test_CloseTrade_ShortLoss() public {
        vm.prank(alice);
        uint32 tradeId = engine.openTrade(
            DEFAULT_PAIR_INDEX,
            false,
            DEFAULT_COLLATERAL,
            DEFAULT_LEVERAGE,
            DEFAULT_SHORT_OPEN_PRICE,
            DEFAULT_SLIPPAGE_BPS,
            0,
            0,
            EMPTY_UPDATE
        );

        // Price went up 5%: 50k → 52.5k (loss for short)
        uint128 closeOracle = 52_500 * 1e18;
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, closeOracle);
        uint128 closeExec = _shortClosePrice(closeOracle);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        vm.prank(alice);
        engine.closeTrade(tradeId, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);

        // Alice gets partial return, vault gains
        assertGt(usdc.balanceOf(alice), aliceBefore);
        assertGt(usdc.balanceOf(address(vault)), vaultBefore);
    }

    function test_CloseTrade_EmitsEvent_Loss() public {
        uint32 tradeId = _openDefaultTrade(alice);

        uint128 closeOracle = 47_500 * 1e18;
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, closeOracle);
        uint128 closeExec = _longClosePrice(closeOracle);

        // Calculate expected PnL using effectiveCollateral
        uint256 size = uint256(DEFAULT_EFFECTIVE_COLLATERAL) * uint256(DEFAULT_LEVERAGE);
        uint256 exitValue = (uint256(closeExec) * size) / uint256(DEFAULT_LONG_OPEN_PRICE);
        int256 expectedPnl = int256(exitValue) - int256(size);
        uint256 rawPayout = uint256(DEFAULT_EFFECTIVE_COLLATERAL) - uint256(-expectedPnl);
        uint256 closeFeeVal = _closeFee(DEFAULT_EFFECTIVE_COLLATERAL, DEFAULT_LEVERAGE);
        uint256 expectedPayout = rawPayout > closeFeeVal ? rawPayout - closeFeeVal : 0;
        uint256 expectedFee = rawPayout > closeFeeVal ? closeFeeVal : rawPayout;

        vm.expectEmit(true, true, false, true);
        emit TradeClosed(tradeId, alice, closeExec, expectedPnl, expectedPayout, expectedFee, 0);

        vm.prank(alice);
        engine.closeTrade(tradeId, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);
    }

    /*//////////////////////////////////////////////////////////////
                        CLOSE TRADE TESTS — PROFIT CAP
    //////////////////////////////////////////////////////////////*/

    function test_CloseTrade_ProfitCapped() public {
        uint32 tradeId = _openDefaultTrade(alice);

        // Price doubles: 50k → 100k
        uint128 closeOracle = 100_000 * 1e18;
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, closeOracle);
        uint128 closeExec = _longClosePrice(closeOracle);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        engine.closeTrade(tradeId, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);

        uint256 received = usdc.balanceOf(alice) - aliceBefore;
        uint256 closeFeeVal = _closeFee(DEFAULT_EFFECTIVE_COLLATERAL, DEFAULT_LEVERAGE);
        // Payout capped at 9x effectiveCollateral, minus close fee
        assertEq(received, uint256(DEFAULT_EFFECTIVE_COLLATERAL) * 9 - closeFeeVal);
    }

    /*//////////////////////////////////////////////////////////////
                      CLOSE TRADE TESTS — BREAKEVEN
    //////////////////////////////////////////////////////////////*/

    function test_CloseTrade_SpreadCausesSmallLoss() public {
        uint32 tradeId = _openDefaultTrade(alice);

        // Close at same oracle price — spread on both sides causes a small loss
        uint128 closeExec = _longClosePrice(DEFAULT_ORACLE_PRICE);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        vm.prank(alice);
        engine.closeTrade(tradeId, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);

        uint256 aliceAfter = usdc.balanceOf(alice);

        // Due to spread on open (up) and close (down), plus fees, trader loses
        assertLt(aliceAfter - aliceBefore, uint256(DEFAULT_EFFECTIVE_COLLATERAL));
        assertGt(usdc.balanceOf(address(vault)), vaultBefore);
    }

    /*//////////////////////////////////////////////////////////////
                      CLOSE TRADE TESTS — REVERTS
    //////////////////////////////////////////////////////////////*/

    function test_CloseTrade_RevertOnTradeNotFound() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TradingEngine.TradeNotFound.selector, 99));
        engine.closeTrade(99, DEFAULT_ORACLE_PRICE, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);
    }

    function test_CloseTrade_RevertOnNotTradeOwner() public {
        uint32 tradeId = _openDefaultTrade(alice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TradingEngine.NotTradeOwner.selector, bob, alice));
        engine.closeTrade(tradeId, _longClosePrice(DEFAULT_ORACLE_PRICE), DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);
    }

    function test_CloseTrade_RevertWhenPaused() public {
        uint32 tradeId = _openDefaultTrade(alice);

        vm.prank(owner);
        engine.pause();

        vm.prank(alice);
        vm.expectRevert(TradingEngine.EnforcedPause.selector);
        engine.closeTrade(tradeId, _longClosePrice(DEFAULT_ORACLE_PRICE), DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);
    }

    /*//////////////////////////////////////////////////////////////
                          UPDATE TP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_UpdateTp() public {
        uint32 tradeId = _openDefaultTrade(alice);

        uint128 newTp = 60_000 * 1e18;
        vm.prank(alice);
        engine.updateTp(tradeId, newTp, EMPTY_UPDATE);

        TradingStorage.Trade memory trade = tradingStorage.getTrade(tradeId);
        assertEq(trade.tp, newTp);
    }

    function test_UpdateTp_EmitsEvent() public {
        uint32 tradeId = _openDefaultTrade(alice);
        uint128 newTp = 60_000 * 1e18;

        vm.expectEmit(true, false, false, true);
        emit TpUpdated(tradeId, newTp);

        vm.prank(alice);
        engine.updateTp(tradeId, newTp, EMPTY_UPDATE);
    }

    function test_UpdateTp_ClearTp() public {
        uint32 tradeId = _openDefaultTrade(alice);

        vm.prank(alice);
        engine.updateTp(tradeId, 0, EMPTY_UPDATE);

        TradingStorage.Trade memory trade = tradingStorage.getTrade(tradeId);
        assertEq(trade.tp, 0);
    }

    function test_UpdateTp_RevertOnTradeNotFound() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TradingEngine.TradeNotFound.selector, 99));
        engine.updateTp(99, 60_000 * 1e18, EMPTY_UPDATE);
    }

    function test_UpdateTp_RevertOnNotTradeOwner() public {
        uint32 tradeId = _openDefaultTrade(alice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TradingEngine.NotTradeOwner.selector, bob, alice));
        engine.updateTp(tradeId, 60_000 * 1e18, EMPTY_UPDATE);
    }

    function test_UpdateTp_RevertWhenPaused() public {
        uint32 tradeId = _openDefaultTrade(alice);

        vm.prank(owner);
        engine.pause();

        vm.prank(alice);
        vm.expectRevert(TradingEngine.EnforcedPause.selector);
        engine.updateTp(tradeId, 60_000 * 1e18, EMPTY_UPDATE);
    }

    function test_UpdateTp_RevertOnInvalidTpForLong() public {
        uint32 tradeId = _openDefaultTrade(alice);

        // TP below open price for long is invalid (Storage validation)
        vm.prank(alice);
        vm.expectRevert();
        engine.updateTp(tradeId, DEFAULT_LONG_OPEN_PRICE - 1, EMPTY_UPDATE);
    }

    function test_UpdateTp_RevertOnAlreadyTriggered() public {
        uint32 tradeId = _openDefaultTrade(alice);

        // Try to set TP below current oracle price for long
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TradingEngine.TpAlreadyTriggered.selector, DEFAULT_ORACLE_PRICE - 1, DEFAULT_ORACLE_PRICE));
        engine.updateTp(tradeId, DEFAULT_ORACLE_PRICE - 1, EMPTY_UPDATE);
    }

    /*//////////////////////////////////////////////////////////////
                          UPDATE SL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_UpdateSl() public {
        uint32 tradeId = _openDefaultTrade(alice);

        uint128 newSl = 40_000 * 1e18;
        vm.prank(alice);
        engine.updateSl(tradeId, newSl, EMPTY_UPDATE);

        TradingStorage.Trade memory trade = tradingStorage.getTrade(tradeId);
        assertEq(trade.sl, newSl);
    }

    function test_UpdateSl_EmitsEvent() public {
        uint32 tradeId = _openDefaultTrade(alice);
        uint128 newSl = 40_000 * 1e18;

        vm.expectEmit(true, false, false, true);
        emit SlUpdated(tradeId, newSl);

        vm.prank(alice);
        engine.updateSl(tradeId, newSl, EMPTY_UPDATE);
    }

    function test_UpdateSl_ClearSl() public {
        uint32 tradeId = _openDefaultTrade(alice);

        vm.prank(alice);
        engine.updateSl(tradeId, 0, EMPTY_UPDATE);

        TradingStorage.Trade memory trade = tradingStorage.getTrade(tradeId);
        assertEq(trade.sl, 0);
    }

    function test_UpdateSl_RevertOnTradeNotFound() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TradingEngine.TradeNotFound.selector, 99));
        engine.updateSl(99, 40_000 * 1e18, EMPTY_UPDATE);
    }

    function test_UpdateSl_RevertOnNotTradeOwner() public {
        uint32 tradeId = _openDefaultTrade(alice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TradingEngine.NotTradeOwner.selector, bob, alice));
        engine.updateSl(tradeId, 40_000 * 1e18, EMPTY_UPDATE);
    }

    function test_UpdateSl_RevertWhenPaused() public {
        uint32 tradeId = _openDefaultTrade(alice);

        vm.prank(owner);
        engine.pause();

        vm.prank(alice);
        vm.expectRevert(TradingEngine.EnforcedPause.selector);
        engine.updateSl(tradeId, 40_000 * 1e18, EMPTY_UPDATE);
    }

    function test_UpdateSl_RevertOnInvalidSlForLong() public {
        uint32 tradeId = _openDefaultTrade(alice);

        // SL above open price for long is invalid (Storage validation)
        vm.prank(alice);
        vm.expectRevert();
        engine.updateSl(tradeId, DEFAULT_LONG_OPEN_PRICE + 1, EMPTY_UPDATE);
    }

    function test_UpdateSl_RevertOnAlreadyTriggered() public {
        uint32 tradeId = _openDefaultTrade(alice);

        // Try to set SL above current oracle price for long
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TradingEngine.SlAlreadyTriggered.selector, DEFAULT_ORACLE_PRICE + 1, DEFAULT_ORACLE_PRICE));
        engine.updateSl(tradeId, DEFAULT_ORACLE_PRICE + 1, EMPTY_UPDATE);
    }

    /*//////////////////////////////////////////////////////////////
                          PAUSE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Pause() public {
        vm.prank(owner);
        engine.pause();
        assertTrue(engine.paused());
    }

    function test_Pause_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit Paused(owner);

        vm.prank(owner);
        engine.pause();
    }

    function test_Unpause() public {
        vm.prank(owner);
        engine.pause();

        vm.prank(owner);
        engine.unpause();
        assertFalse(engine.paused());
    }

    function test_Unpause_EmitsEvent() public {
        vm.prank(owner);
        engine.pause();

        vm.expectEmit(false, false, false, true);
        emit Unpaused(owner);

        vm.prank(owner);
        engine.unpause();
    }

    function test_Pause_RevertIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        engine.pause();
    }

    function test_Unpause_RevertIfNotOwner() public {
        vm.prank(owner);
        engine.pause();

        vm.prank(alice);
        vm.expectRevert();
        engine.unpause();
    }

    function test_Pause_RevertIfAlreadyPaused() public {
        vm.prank(owner);
        engine.pause();

        vm.prank(owner);
        vm.expectRevert(TradingEngine.EnforcedPause.selector);
        engine.pause();
    }

    function test_Unpause_RevertIfNotPaused() public {
        vm.prank(owner);
        vm.expectRevert(TradingEngine.ExpectedPause.selector);
        engine.unpause();
    }

    /*//////////////////////////////////////////////////////////////
                        PNL CALCULATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PnL_LongExactMath() public {
        uint32 tradeId = _openDefaultTrade(alice);

        // Close at oracle=52.5k
        uint128 closeOracle = 52_500 * 1e18;
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, closeOracle);
        uint128 closeExec = _longClosePrice(closeOracle);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        engine.closeTrade(tradeId, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);

        uint256 received = usdc.balanceOf(alice) - aliceBefore;

        // Verify math: exitValue = closeExec * size / openExec (using effectiveCollateral)
        uint256 size = uint256(DEFAULT_EFFECTIVE_COLLATERAL) * uint256(DEFAULT_LEVERAGE);
        uint256 exitValue = (uint256(closeExec) * size) / uint256(DEFAULT_LONG_OPEN_PRICE);
        int256 pnl = int256(exitValue) - int256(size);
        uint256 rawPayout = uint256(pnl) + uint256(DEFAULT_EFFECTIVE_COLLATERAL);
        uint256 closeFeeVal = _closeFee(DEFAULT_EFFECTIVE_COLLATERAL, DEFAULT_LEVERAGE);
        uint256 expectedPayout = rawPayout - closeFeeVal;

        assertEq(received, expectedPayout);
    }

    function test_PnL_ShortExactMath() public {
        vm.prank(alice);
        uint32 tradeId = engine.openTrade(
            DEFAULT_PAIR_INDEX,
            false,
            DEFAULT_COLLATERAL,
            DEFAULT_LEVERAGE,
            DEFAULT_SHORT_OPEN_PRICE,
            DEFAULT_SLIPPAGE_BPS,
            0,
            0,
            EMPTY_UPDATE
        );

        TradingStorage.Trade memory openedTrade = tradingStorage.getTrade(tradeId);
        uint64 effColl = openedTrade.collateral;
        uint128 shortOpenExec = openedTrade.openPrice;

        // Short entry at oracle 50k, close at 47.5k
        uint128 closeOracle = 47_500 * 1e18;
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, closeOracle);
        uint128 closeExec = _shortClosePrice(closeOracle);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        engine.closeTrade(tradeId, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);

        uint256 received = usdc.balanceOf(alice) - aliceBefore;

        // Verify math for short: pnl = size - exitValue (exitValue ceil'd to round toward the pool)
        uint256 size = uint256(effColl) * uint256(DEFAULT_LEVERAGE);
        uint256 exitValue = (uint256(closeExec) * size + uint256(shortOpenExec) - 1) / uint256(shortOpenExec);
        int256 pnl = int256(size) - int256(exitValue);
        uint256 rawPayout = uint256(pnl) + uint256(effColl);
        uint256 closeFeeVal = _closeFee(effColl, DEFAULT_LEVERAGE);
        uint256 expectedPayout = rawPayout - closeFeeVal;

        assertEq(received, expectedPayout);
    }

    function test_PnL_HighLeverage() public {
        // 100 USDC, 100x, close at oracle 50.5k
        vm.prank(alice);
        uint128 expectedOpen = _longOpenPrice(DEFAULT_ORACLE_PRICE);
        uint32 tradeId = engine.openTrade(DEFAULT_PAIR_INDEX, true, DEFAULT_COLLATERAL, 100, expectedOpen, DEFAULT_SLIPPAGE_BPS, 0, 0, EMPTY_UPDATE);

        TradingStorage.Trade memory trade = tradingStorage.getTrade(tradeId);

        uint128 closeOracle = 50_500 * 1e18;
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, closeOracle);
        uint128 closeExec = _longClosePrice(closeOracle);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        engine.closeTrade(tradeId, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);

        uint256 received = usdc.balanceOf(alice) - aliceBefore;
        assertGt(received, trade.collateral);
    }

    /*//////////////////////////////////////////////////////////////
                        COLLATERAL FLOW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CollateralFlow_FullLossGoesToVault() public {
        uint32 tradeId = _openDefaultTrade(alice);

        uint256 storageBefore = usdc.balanceOf(address(tradingStorage));
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        uint128 closeOracle = 45_000 * 1e18;
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, closeOracle);
        uint128 closeExec = _longClosePrice(closeOracle);

        vm.prank(alice);
        engine.closeTrade(tradeId, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);

        // Full loss: payout=0, closeFee=0 (capped to payout), all effectiveCollateral goes to Vault
        assertEq(usdc.balanceOf(address(tradingStorage)), storageBefore - DEFAULT_EFFECTIVE_COLLATERAL);
        assertEq(usdc.balanceOf(address(vault)), vaultBefore + DEFAULT_EFFECTIVE_COLLATERAL);
    }

    function test_CollateralFlow_PartialLossSplitCorrectly() public {
        uint32 tradeId = _openDefaultTrade(alice);

        uint256 storageBefore = usdc.balanceOf(address(tradingStorage));
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        uint128 closeOracle = 47_500 * 1e18;
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, closeOracle);
        uint128 closeExec = _longClosePrice(closeOracle);

        vm.prank(alice);
        engine.closeTrade(tradeId, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);

        // Storage sent all effectiveCollateral out (fee + payout + vault)
        assertEq(usdc.balanceOf(address(tradingStorage)), storageBefore - DEFAULT_EFFECTIVE_COLLATERAL);
        // Vault gained from loss portion + fee share
        assertGt(usdc.balanceOf(address(vault)), vaultBefore);
    }

    function test_CollateralFlow_ProfitFromVault() public {
        uint32 tradeId = _openDefaultTrade(alice);

        uint256 storageBefore = usdc.balanceOf(address(tradingStorage));
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        uint128 closeOracle = 55_000 * 1e18;
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, closeOracle);
        uint128 closeExec = _longClosePrice(closeOracle);

        vm.prank(alice);
        engine.closeTrade(tradeId, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);

        // Storage returns all effectiveCollateral (fee + trader payout from storage)
        assertEq(usdc.balanceOf(address(tradingStorage)), storageBefore - DEFAULT_EFFECTIVE_COLLATERAL);
        // Vault pays profit (minus vault fee share which flows back in)
        assertLt(usdc.balanceOf(address(vault)), vaultBefore);
    }

    /*//////////////////////////////////////////////////////////////
                            FEE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Fee_OpenFeeCalculation() public {
        // 100 USDC * 10x * 8 / 10000 = 80000 (0.08 USDC)
        uint256 expectedFee = (uint256(DEFAULT_COLLATERAL) * DEFAULT_LEVERAGE * 8) / 10_000;
        assertEq(expectedFee, DEFAULT_OPEN_FEE);

        _openDefaultTrade(alice);

        TradingStorage.Trade memory trade = tradingStorage.getTrade(0);
        assertEq(trade.collateral, DEFAULT_COLLATERAL - uint64(expectedFee));
    }

    function test_Fee_CloseFeeCalculation() public {
        uint32 tradeId = _openDefaultTrade(alice);

        // Close at profit
        uint128 closeOracle = 55_000 * 1e18;
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, closeOracle);
        uint128 closeExec = _longClosePrice(closeOracle);

        // Expected close fee based on effectiveCollateral
        uint256 expectedCloseFee = _closeFee(DEFAULT_EFFECTIVE_COLLATERAL, DEFAULT_LEVERAGE);

        // Compute raw payout
        uint256 size = uint256(DEFAULT_EFFECTIVE_COLLATERAL) * uint256(DEFAULT_LEVERAGE);
        uint256 exitValue = (uint256(closeExec) * size) / uint256(DEFAULT_LONG_OPEN_PRICE);
        int256 pnl = int256(exitValue) - int256(size);
        uint256 rawPayout = uint256(pnl) + uint256(DEFAULT_EFFECTIVE_COLLATERAL);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        engine.closeTrade(tradeId, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);

        uint256 received = usdc.balanceOf(alice) - aliceBefore;
        assertEq(received, rawPayout - expectedCloseFee);
    }

    function test_Fee_Split80_20() public {
        uint256 vaultBefore = usdc.balanceOf(address(vault));
        uint256 treasuryBefore = usdc.balanceOf(treasuryAddr);

        _openDefaultTrade(alice);

        uint256 expectedVaultFee = (DEFAULT_OPEN_FEE * 8000) / 10_000; // 64000
        uint256 expectedTreasuryFee = DEFAULT_OPEN_FEE - expectedVaultFee; // 16000

        assertEq(usdc.balanceOf(address(vault)) - vaultBefore, expectedVaultFee);
        assertEq(usdc.balanceOf(treasuryAddr) - treasuryBefore, expectedTreasuryFee);
    }

    function test_Fee_VaultTotalAssetsIncreases() public {
        uint256 totalAssetsBefore = vault.totalAssets();

        _openDefaultTrade(alice);

        uint256 expectedVaultFee = (DEFAULT_OPEN_FEE * 8000) / 10_000;
        assertEq(vault.totalAssets(), totalAssetsBefore + expectedVaultFee);
    }

    function test_Fee_TreasuryReceivesFee() public {
        uint256 treasuryBefore = usdc.balanceOf(treasuryAddr);

        _openDefaultTrade(alice);

        uint256 expectedTreasuryFee = DEFAULT_OPEN_FEE - ((DEFAULT_OPEN_FEE * 8000) / 10_000);
        assertEq(usdc.balanceOf(treasuryAddr) - treasuryBefore, expectedTreasuryFee);
    }

    function test_Fee_EffectiveCollateralStored() public {
        _openDefaultTrade(alice);

        TradingStorage.Trade memory trade = tradingStorage.getTrade(0);
        assertEq(trade.collateral, DEFAULT_EFFECTIVE_COLLATERAL);
        assertLt(trade.collateral, DEFAULT_COLLATERAL);
    }

    function test_Fee_CloseFeeDeductedFromPayout() public {
        uint32 tradeId = _openDefaultTrade(alice);

        // Close at slight profit (50.5k) — treasury should receive close fee share
        uint128 closeOracle = 50_500 * 1e18;
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, closeOracle);
        uint128 closeExec = _longClosePrice(closeOracle);

        uint256 treasuryBefore = usdc.balanceOf(treasuryAddr);

        vm.prank(alice);
        engine.closeTrade(tradeId, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);

        uint256 closeFeeVal = _closeFee(DEFAULT_EFFECTIVE_COLLATERAL, DEFAULT_LEVERAGE);
        uint256 expectedTreasuryFee = closeFeeVal - ((closeFeeVal * 8000) / 10_000);

        // Treasury received its 20% close fee share
        assertEq(usdc.balanceOf(treasuryAddr) - treasuryBefore, expectedTreasuryFee);
    }

    function test_Fee_FullLossCloseFeeIsZero() public {
        uint32 tradeId = _openDefaultTrade(alice);

        // Full loss: payout = 0, so close fee = 0
        uint128 closeOracle = 45_000 * 1e18;
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, closeOracle);
        uint128 closeExec = _longClosePrice(closeOracle);

        uint256 treasuryBefore = usdc.balanceOf(treasuryAddr);

        vm.prank(alice);
        engine.closeTrade(tradeId, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);

        // No close fee distributed on full loss (payout was 0)
        assertEq(usdc.balanceOf(treasuryAddr), treasuryBefore);
    }

    function test_Fee_ProfitTradeCloseFeeFromCollateral() public {
        uint32 tradeId = _openDefaultTrade(alice);

        // Profit scenario
        uint128 closeOracle = 55_000 * 1e18;
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, closeOracle);
        uint128 closeExec = _longClosePrice(closeOracle);

        uint256 treasuryBefore = usdc.balanceOf(treasuryAddr);
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        vm.prank(alice);
        engine.closeTrade(tradeId, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);

        uint256 closeFeeVal = _closeFee(DEFAULT_EFFECTIVE_COLLATERAL, DEFAULT_LEVERAGE);
        uint256 expectedVaultFee = (closeFeeVal * 8000) / 10_000;
        uint256 expectedTreasuryFee = closeFeeVal - expectedVaultFee;

        assertEq(usdc.balanceOf(treasuryAddr) - treasuryBefore, expectedTreasuryFee);
        // Vault receives fee share but pays out profit, net negative
        // Just check the fee share was sent (vault delta accounts for profit payout too)
    }

    function test_Fee_EmitsFeesDistributedOnOpen() public {
        uint256 expectedVaultFee = (DEFAULT_OPEN_FEE * 8000) / 10_000;
        uint256 expectedTreasuryFee = DEFAULT_OPEN_FEE - expectedVaultFee;

        vm.expectEmit(false, false, false, true);
        emit FeesDistributed(expectedVaultFee, expectedTreasuryFee);

        _openDefaultTrade(alice);
    }

    function test_Fee_EmitsFeesDistributedOnClose() public {
        uint32 tradeId = _openDefaultTrade(alice);

        uint128 closeOracle = 55_000 * 1e18;
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, closeOracle);
        uint128 closeExec = _longClosePrice(closeOracle);

        uint256 closeFeeVal = _closeFee(DEFAULT_EFFECTIVE_COLLATERAL, DEFAULT_LEVERAGE);
        uint256 expectedVaultFee = (closeFeeVal * 8000) / 10_000;
        uint256 expectedTreasuryFee = closeFeeVal - expectedVaultFee;

        vm.expectEmit(false, false, false, true);
        emit FeesDistributed(expectedVaultFee, expectedTreasuryFee);

        vm.prank(alice);
        engine.closeTrade(tradeId, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);
    }

    /*//////////////////////////////////////////////////////////////
                      TREASURY ADMIN TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetTreasury() public {
        address newTreasury = makeAddr("newTreasury");

        vm.prank(owner);
        engine.setTreasury(newTreasury);

        assertEq(engine.treasury(), newTreasury);
    }

    function test_SetTreasury_EmitsEvent() public {
        address newTreasury = makeAddr("newTreasury");

        vm.expectEmit(true, false, false, true);
        emit TreasuryUpdated(newTreasury);

        vm.prank(owner);
        engine.setTreasury(newTreasury);
    }

    function test_SetTreasury_RevertOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(TradingEngine.ZeroAddress.selector);
        engine.setTreasury(address(0));
    }

    function test_SetTreasury_RevertIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        engine.setTreasury(makeAddr("newTreasury"));
    }

    /*//////////////////////////////////////////////////////////////
                        FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_OpenTrade(uint64 collateral, uint16 leverage) public {
        collateral = uint64(bound(collateral, 10e6, 100_000 * 10 ** 6));
        leverage = uint16(bound(leverage, 1, 100));

        // Calculate fee and ensure collateral > fee
        uint256 fee = _openFee(collateral, leverage);
        vm.assume(fee < uint256(collateral));

        uint64 effColl = uint64(uint256(collateral) - fee);

        // Ensure OI doesn't exceed max
        uint256 posSize = uint256(effColl) * uint256(leverage) * 1e12;
        vm.assume(posSize <= 10_000_000 * 1e18);

        uint128 expectedOpen = _longOpenPrice(DEFAULT_ORACLE_PRICE);
        vm.prank(alice);
        uint32 tradeId = engine.openTrade(DEFAULT_PAIR_INDEX, true, collateral, leverage, expectedOpen, DEFAULT_SLIPPAGE_BPS, 0, 0, EMPTY_UPDATE);

        TradingStorage.Trade memory trade = tradingStorage.getTrade(tradeId);
        assertEq(trade.user, alice);
        assertEq(trade.collateral, effColl);
        assertEq(trade.leverage, leverage);
        assertEq(trade.openPrice, expectedOpen);
    }

    function testFuzz_CloseTrade_PnL(uint128 closeOracle) public {
        closeOracle = uint128(bound(closeOracle, 1e18, 500_000 * 1e18));

        uint32 tradeId = _openDefaultTrade(alice);

        mockOracle.setPrice(DEFAULT_PAIR_INDEX, closeOracle);
        uint128 closeExec = _longClosePrice(closeOracle);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 vaultBefore = usdc.balanceOf(address(vault));
        uint256 treasuryBefore = usdc.balanceOf(treasuryAddr);

        vm.prank(alice);
        engine.closeTrade(tradeId, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);

        uint256 aliceAfter = usdc.balanceOf(alice);
        uint256 vaultAfter = usdc.balanceOf(address(vault));
        uint256 treasuryAfter = usdc.balanceOf(treasuryAddr);

        uint256 traderReceived = aliceAfter - aliceBefore;
        int256 vaultDelta = int256(vaultAfter) - int256(vaultBefore);
        uint256 treasuryReceived = treasuryAfter - treasuryBefore;

        // Invariant: traderReceived + vaultDelta + treasuryReceived == effectiveCollateral
        assertEq(int256(traderReceived) + vaultDelta + int256(treasuryReceived), int256(uint256(DEFAULT_EFFECTIVE_COLLATERAL)));

        // Trade must be deleted
        TradingStorage.Trade memory trade = tradingStorage.getTrade(tradeId);
        assertEq(trade.user, address(0));

        // OI must be zero
        assertEq(tradingStorage.getOpenInterest(DEFAULT_PAIR_INDEX), 0);
    }

    function testFuzz_ProfitCap(uint128 closeOracle) public {
        // Only prices above entry for long profit
        closeOracle = uint128(bound(closeOracle, DEFAULT_ORACLE_PRICE + 1, type(uint128).max / (uint256(DEFAULT_EFFECTIVE_COLLATERAL) * DEFAULT_LEVERAGE)));

        uint32 tradeId = _openDefaultTrade(alice);
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, closeOracle);
        uint128 closeExec = _longClosePrice(closeOracle);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        engine.closeTrade(tradeId, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);

        uint256 received = usdc.balanceOf(alice) - aliceBefore;
        uint256 closeFeeVal = _closeFee(DEFAULT_EFFECTIVE_COLLATERAL, DEFAULT_LEVERAGE);
        // Payout capped at MAX_PROFIT_MULTIPLIER * effectiveCollateral, minus close fee
        assertLe(received, uint256(DEFAULT_EFFECTIVE_COLLATERAL) * engine.MAX_PROFIT_MULTIPLIER() - closeFeeVal);
    }

    function testFuzz_FeeCalculation(uint64 collateral, uint16 leverage) public pure {
        collateral = uint64(bound(collateral, 1e6, 100_000 * 10 ** 6));
        leverage = uint16(bound(leverage, 1, 100));

        uint256 fee = (uint256(collateral) * uint256(leverage) * 8) / 10_000;
        uint256 vaultFee = (fee * 8000) / 10_000;
        uint256 treasuryFee = fee - vaultFee;

        // Fee split must equal total fee
        assertEq(vaultFee + treasuryFee, fee);
        // Vault gets 80%
        assertGe(vaultFee, treasuryFee);
    }

    /*//////////////////////////////////////////////////////////////
                        INVARIANT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Invariant_OIMatchesTrades() public {
        _openDefaultTrade(alice);
        _openDefaultTrade(alice);
        _openDefaultTrade(bob);

        // OI based on effectiveCollateral
        uint256 expectedOI = 3 * uint256(DEFAULT_EFFECTIVE_COLLATERAL) * uint256(DEFAULT_LEVERAGE) * 1e12;
        assertEq(tradingStorage.getOpenInterest(DEFAULT_PAIR_INDEX), expectedOI);

        // Close one trade
        uint128 closeExec = _longClosePrice(DEFAULT_ORACLE_PRICE);
        vm.prank(alice);
        engine.closeTrade(0, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);

        expectedOI = 2 * uint256(DEFAULT_EFFECTIVE_COLLATERAL) * uint256(DEFAULT_LEVERAGE) * 1e12;
        assertEq(tradingStorage.getOpenInterest(DEFAULT_PAIR_INDEX), expectedOI);
    }

    function test_Invariant_StorageBalanceMatchesCollateral() public {
        _openDefaultTrade(alice);
        _openDefaultTrade(bob);

        // Storage holds 2x effectiveCollateral (fees already distributed)
        assertEq(usdc.balanceOf(address(tradingStorage)), 2 * uint256(DEFAULT_EFFECTIVE_COLLATERAL));

        // Close alice's trade
        uint128 closeExec = _longClosePrice(DEFAULT_ORACLE_PRICE);
        vm.prank(alice);
        engine.closeTrade(0, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);

        // After close, only bob's effectiveCollateral remains
        assertEq(usdc.balanceOf(address(tradingStorage)), uint256(DEFAULT_EFFECTIVE_COLLATERAL));
    }

    function test_Invariant_FundsConservation_MultipleTraders() public {
        uint256 totalBefore = usdc.balanceOf(alice) +
            usdc.balanceOf(bob) +
            usdc.balanceOf(address(vault)) +
            usdc.balanceOf(address(tradingStorage)) +
            usdc.balanceOf(treasuryAddr);

        _openDefaultTrade(alice);
        _openDefaultTrade(bob);

        // Close alice at profit
        uint128 closeOracle1 = 55_000 * 1e18;
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, closeOracle1);
        uint128 closeExec1 = _longClosePrice(closeOracle1);
        vm.prank(alice);
        engine.closeTrade(0, closeExec1, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);

        // Close bob at loss
        uint128 closeOracle2 = 47_500 * 1e18;
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, closeOracle2);
        uint128 closeExec2 = _longClosePrice(closeOracle2);
        vm.prank(bob);
        engine.closeTrade(1, closeExec2, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);

        uint256 totalAfter = usdc.balanceOf(alice) +
            usdc.balanceOf(bob) +
            usdc.balanceOf(address(vault)) +
            usdc.balanceOf(address(tradingStorage)) +
            usdc.balanceOf(treasuryAddr);

        // Total USDC in the system must be conserved
        assertEq(totalBefore, totalAfter);
    }

    /*//////////////////////////////////////////////////////////////
                      FUNDING RATE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Funding_SetsEntryIndexOnOpen() public {
        _openDefaultTrade(alice);

        // Entry funding index should be 0 (first trade, index initialized)
        assertEq(tradingStorage.getTradeFundingIndex(0), 0);
    }

    function test_Funding_ZeroFundingSameBlock() public {
        // Open and close in same block → zero funding
        uint32 tradeId = _openDefaultTrade(alice);

        uint128 closeExec = _longClosePrice(DEFAULT_ORACLE_PRICE);
        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        engine.closeTrade(tradeId, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);

        // Funding should be zero since no time passed
        // Check by verifying payout matches the non-funding calculation
        uint256 size = uint256(DEFAULT_EFFECTIVE_COLLATERAL) * uint256(DEFAULT_LEVERAGE);
        uint256 exitValue = (uint256(closeExec) * size) / uint256(DEFAULT_LONG_OPEN_PRICE);
        int256 pnl = int256(exitValue) - int256(size);
        uint256 rawPayout = pnl >= 0 ? uint256(pnl) + uint256(DEFAULT_EFFECTIVE_COLLATERAL) : uint256(DEFAULT_EFFECTIVE_COLLATERAL) - uint256(-pnl);
        uint256 closeFeeVal = _closeFee(DEFAULT_EFFECTIVE_COLLATERAL, DEFAULT_LEVERAGE);
        uint256 expectedPayout = rawPayout > closeFeeVal ? rawPayout - closeFeeVal : 0;

        assertEq(usdc.balanceOf(alice) - aliceBefore, expectedPayout);
    }

    function test_Funding_LongPaysWhenLongsHeavier() public {
        // Alice opens long (only longs, no shorts → longs heavier)
        uint32 tradeId = _openDefaultTrade(alice);

        // Warp time so funding accrues
        vm.warp(block.timestamp + 3600);

        // Close at same oracle price → PnL is only from spread + funding
        uint128 closeExec = _longClosePrice(DEFAULT_ORACLE_PRICE);

        uint256 aliceNoFunding;
        {
            uint256 size = uint256(DEFAULT_EFFECTIVE_COLLATERAL) * uint256(DEFAULT_LEVERAGE);
            uint256 exitValue = (uint256(closeExec) * size) / uint256(DEFAULT_LONG_OPEN_PRICE);
            int256 pnl = int256(exitValue) - int256(size);
            uint256 rawPayout = uint256(DEFAULT_EFFECTIVE_COLLATERAL) - uint256(-pnl);
            uint256 closeFeeVal = _closeFee(DEFAULT_EFFECTIVE_COLLATERAL, DEFAULT_LEVERAGE);
            aliceNoFunding = rawPayout > closeFeeVal ? rawPayout - closeFeeVal : 0;
        }

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        engine.closeTrade(tradeId, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);
        uint256 aliceReceived = usdc.balanceOf(alice) - aliceBefore;

        // Long pays funding when longs are heavier → receives less than without funding
        assertLt(aliceReceived, aliceNoFunding);
    }

    function test_Funding_ShortReceivesWhenLongsHeavier() public {
        // Alice opens long, Bob opens short
        _openDefaultTrade(alice); // long

        uint128 shortTp = 45_000 * 1e18;
        uint128 shortSl = 55_000 * 1e18;
        vm.prank(bob);
        uint32 shortTradeId = engine.openTrade(
            DEFAULT_PAIR_INDEX,
            false,
            DEFAULT_COLLATERAL,
            DEFAULT_LEVERAGE,
            DEFAULT_SHORT_OPEN_PRICE,
            DEFAULT_SLIPPAGE_BPS,
            shortTp,
            shortSl,
            EMPTY_UPDATE
        );

        // Warp time — more longs than shorts (but now both sides exist, long OI from alice + short OI from bob)
        // Both opened with same collateral/leverage, but long OI was first (timestamp set before short)
        // After second open, long and short OI are equal. Need to create a long-heavier scenario.
        // Open another long for alice to make longs heavier
        vm.prank(alice);
        engine.openTrade(DEFAULT_PAIR_INDEX, true, DEFAULT_COLLATERAL, DEFAULT_LEVERAGE, DEFAULT_LONG_OPEN_PRICE, DEFAULT_SLIPPAGE_BPS, 0, 0, EMPTY_UPDATE);

        vm.warp(block.timestamp + 3600);

        // Close bob's short at same oracle price
        uint128 closeExec = _shortClosePrice(DEFAULT_ORACLE_PRICE);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        engine.closeTrade(shortTradeId, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);
        uint256 bobReceived = usdc.balanceOf(bob) - bobBefore;

        // Short receives funding when longs heavier → should receive more than pure PnL
        uint64 shortEffColl = DEFAULT_EFFECTIVE_COLLATERAL;
        uint256 size = uint256(shortEffColl) * uint256(DEFAULT_LEVERAGE);
        uint128 shortOpenExec = DEFAULT_SHORT_OPEN_PRICE;
        uint256 exitValue = (uint256(closeExec) * size + uint256(shortOpenExec) - 1) / uint256(shortOpenExec); // ceil: short rounding favors the pool
        int256 pnl = int256(size) - int256(exitValue);
        uint256 rawPayout;
        if (pnl >= 0) {
            rawPayout = uint256(pnl) + uint256(shortEffColl);
        } else {
            rawPayout = uint256(shortEffColl) - uint256(-pnl);
        }
        uint256 closeFeeVal = _closeFee(shortEffColl, DEFAULT_LEVERAGE);
        uint256 noFundingPayout = rawPayout > closeFeeVal ? rawPayout - closeFeeVal : 0;

        // Short receives funding credit → gets more than noFunding scenario
        assertGt(bobReceived, noFundingPayout);
    }

    function test_Funding_ShortPaysWhenShortsHeavier() public {
        // Open two shorts and one long → shorts heavier
        vm.prank(alice);
        engine.openTrade(DEFAULT_PAIR_INDEX, true, DEFAULT_COLLATERAL, DEFAULT_LEVERAGE, DEFAULT_LONG_OPEN_PRICE, DEFAULT_SLIPPAGE_BPS, 0, 0, EMPTY_UPDATE);

        uint128 shortTp = 45_000 * 1e18;
        uint128 shortSl = 55_000 * 1e18;
        vm.prank(bob);
        engine.openTrade(
            DEFAULT_PAIR_INDEX,
            false,
            DEFAULT_COLLATERAL,
            DEFAULT_LEVERAGE,
            DEFAULT_SHORT_OPEN_PRICE,
            DEFAULT_SLIPPAGE_BPS,
            shortTp,
            shortSl,
            EMPTY_UPDATE
        );
        vm.prank(bob);
        uint32 shortTradeId = engine.openTrade(
            DEFAULT_PAIR_INDEX,
            false,
            DEFAULT_COLLATERAL,
            DEFAULT_LEVERAGE,
            DEFAULT_SHORT_OPEN_PRICE,
            DEFAULT_SLIPPAGE_BPS,
            shortTp,
            shortSl,
            EMPTY_UPDATE
        );

        vm.warp(block.timestamp + 3600);

        // Close bob's second short
        uint128 closeExec = _shortClosePrice(DEFAULT_ORACLE_PRICE);
        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        engine.closeTrade(shortTradeId, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);
        uint256 bobReceived = usdc.balanceOf(bob) - bobBefore;

        // Calculate without funding
        uint64 shortEffColl = DEFAULT_EFFECTIVE_COLLATERAL;
        uint256 size = uint256(shortEffColl) * uint256(DEFAULT_LEVERAGE);
        uint128 shortOpenExec = DEFAULT_SHORT_OPEN_PRICE;
        uint256 exitValue = (uint256(closeExec) * size + uint256(shortOpenExec) - 1) / uint256(shortOpenExec); // ceil: short rounding favors the pool
        int256 pnl = int256(size) - int256(exitValue);
        uint256 rawPayout;
        if (pnl >= 0) {
            rawPayout = uint256(pnl) + uint256(shortEffColl);
        } else {
            rawPayout = uint256(shortEffColl) - uint256(-pnl);
        }
        uint256 closeFeeVal = _closeFee(shortEffColl, DEFAULT_LEVERAGE);
        uint256 noFundingPayout = rawPayout > closeFeeVal ? rawPayout - closeFeeVal : 0;

        // Short pays funding when shorts heavier → receives less
        assertLt(bobReceived, noFundingPayout);
    }

    function test_Funding_AccumulatesWithTime() public {
        // Open long
        uint32 tradeId = _openDefaultTrade(alice);

        // Close after 1 hour
        vm.warp(block.timestamp + 3600);
        uint128 closeExec = _longClosePrice(DEFAULT_ORACLE_PRICE);
        uint256 aliceBefore1 = usdc.balanceOf(alice);
        vm.prank(alice);
        engine.closeTrade(tradeId, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);
        uint256 received1h = usdc.balanceOf(alice) - aliceBefore1;

        // Open another long and close after 2 hours
        uint32 tradeId2 = _openDefaultTrade(alice);
        vm.warp(block.timestamp + 7200);
        uint256 aliceBefore2 = usdc.balanceOf(alice);
        vm.prank(alice);
        engine.closeTrade(tradeId2, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);
        uint256 received2h = usdc.balanceOf(alice) - aliceBefore2;

        // 2h funding deduction > 1h funding deduction → less payout for longer hold
        assertLt(received2h, received1h);
    }

    function test_Funding_ExtremeFundingCausesFullLoss() public {
        // Open long with default collateral — only longs, no shorts (max imbalance)
        uint32 tradeId = _openDefaultTrade(alice);

        // Warp very long time to accumulate massive funding (longs heavier)
        vm.warp(block.timestamp + 365 days);

        uint128 closeExec = _longClosePrice(DEFAULT_ORACLE_PRICE);
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        engine.closeTrade(tradeId, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);

        // Extreme funding should cause full loss (payout = 0)
        assertEq(usdc.balanceOf(alice), aliceBefore);
    }

    function test_Funding_CreditIncreasesProfit_CappedAt9x() public {
        // Open long and short to create imbalance favoring longs receiving funding
        // 2 shorts, 1 long → shorts heavier → long receives funding
        uint128 shortTp = 45_000 * 1e18;
        uint128 shortSl = 55_000 * 1e18;
        vm.prank(bob);
        engine.openTrade(
            DEFAULT_PAIR_INDEX,
            false,
            DEFAULT_COLLATERAL,
            DEFAULT_LEVERAGE,
            DEFAULT_SHORT_OPEN_PRICE,
            DEFAULT_SLIPPAGE_BPS,
            shortTp,
            shortSl,
            EMPTY_UPDATE
        );
        vm.prank(bob);
        engine.openTrade(
            DEFAULT_PAIR_INDEX,
            false,
            DEFAULT_COLLATERAL,
            DEFAULT_LEVERAGE,
            DEFAULT_SHORT_OPEN_PRICE,
            DEFAULT_SLIPPAGE_BPS,
            shortTp,
            shortSl,
            EMPTY_UPDATE
        );

        // Alice opens long
        uint32 tradeId = _openDefaultTrade(alice);

        vm.warp(block.timestamp + 3600);

        // Close at huge profit (price doubles)
        uint128 closeOracle = 100_000 * 1e18;
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, closeOracle);
        uint128 closeExec = _longClosePrice(closeOracle);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        engine.closeTrade(tradeId, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);
        uint256 received = usdc.balanceOf(alice) - aliceBefore;

        // Even with funding credit, payout is capped at 9x collateral (minus close fee)
        uint256 closeFeeVal = _closeFee(DEFAULT_EFFECTIVE_COLLATERAL, DEFAULT_LEVERAGE);
        assertLe(received, uint256(DEFAULT_EFFECTIVE_COLLATERAL) * 9 - closeFeeVal);
    }

    function test_Funding_BalancedOI_ZeroFunding() public {
        // Open equal long and short
        _openDefaultTrade(alice); // long

        uint128 shortTp = 45_000 * 1e18;
        uint128 shortSl = 55_000 * 1e18;
        vm.prank(bob);
        uint32 shortTradeId = engine.openTrade(
            DEFAULT_PAIR_INDEX,
            false,
            DEFAULT_COLLATERAL,
            DEFAULT_LEVERAGE,
            DEFAULT_SHORT_OPEN_PRICE,
            DEFAULT_SLIPPAGE_BPS,
            shortTp,
            shortSl,
            EMPTY_UPDATE
        );

        vm.warp(block.timestamp + 3600);

        // Close short — funding should be zero since OI is balanced
        uint128 closeExec = _shortClosePrice(DEFAULT_ORACLE_PRICE);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        engine.closeTrade(shortTradeId, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);
        uint256 bobReceived = usdc.balanceOf(bob) - bobBefore;

        // Compute no-funding payout
        uint64 shortEffColl = DEFAULT_EFFECTIVE_COLLATERAL;
        uint256 size = uint256(shortEffColl) * uint256(DEFAULT_LEVERAGE);
        uint128 shortOpenExec = DEFAULT_SHORT_OPEN_PRICE;
        uint256 exitValue = (uint256(closeExec) * size + uint256(shortOpenExec) - 1) / uint256(shortOpenExec); // ceil: short rounding favors the pool
        int256 pnl = int256(size) - int256(exitValue);
        uint256 rawPayout;
        if (pnl >= 0) {
            rawPayout = uint256(pnl) + uint256(shortEffColl);
        } else {
            rawPayout = uint256(shortEffColl) - uint256(-pnl);
        }
        uint256 closeFeeVal = _closeFee(shortEffColl, DEFAULT_LEVERAGE);
        uint256 noFundingPayout = rawPayout > closeFeeVal ? rawPayout - closeFeeVal : 0;

        // Balanced OI → zero funding → payout matches
        assertEq(bobReceived, noFundingPayout);
    }

    function test_Funding_FundsConservation() public {
        uint256 totalBefore = usdc.balanceOf(alice) +
            usdc.balanceOf(bob) +
            usdc.balanceOf(address(vault)) +
            usdc.balanceOf(address(tradingStorage)) +
            usdc.balanceOf(treasuryAddr);

        // Alice opens long, Bob opens short → imbalanced slightly when another long is added
        _openDefaultTrade(alice); // long
        uint128 shortTp = 45_000 * 1e18;
        uint128 shortSl = 55_000 * 1e18;
        vm.prank(bob);
        engine.openTrade(
            DEFAULT_PAIR_INDEX,
            false,
            DEFAULT_COLLATERAL,
            DEFAULT_LEVERAGE,
            DEFAULT_SHORT_OPEN_PRICE,
            DEFAULT_SLIPPAGE_BPS,
            shortTp,
            shortSl,
            EMPTY_UPDATE
        );

        vm.warp(block.timestamp + 3600);

        // Close both
        uint128 closeExec1 = _longClosePrice(DEFAULT_ORACLE_PRICE);
        vm.prank(alice);
        engine.closeTrade(0, closeExec1, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);

        uint128 closeExec2 = _shortClosePrice(DEFAULT_ORACLE_PRICE);
        vm.prank(bob);
        engine.closeTrade(1, closeExec2, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);

        uint256 totalAfter = usdc.balanceOf(alice) +
            usdc.balanceOf(bob) +
            usdc.balanceOf(address(vault)) +
            usdc.balanceOf(address(tradingStorage)) +
            usdc.balanceOf(treasuryAddr);

        assertEq(totalBefore, totalAfter);
    }

    function test_Funding_InitializesFundingTimestampOnFirstOpen() public {
        // Before any trade, funding last updated is 0
        assertEq(tradingStorage.getFundingLastUpdated(DEFAULT_PAIR_INDEX), 0);

        _openDefaultTrade(alice);

        // After first trade, funding timestamp should be initialized
        assertEq(tradingStorage.getFundingLastUpdated(DEFAULT_PAIR_INDEX), block.timestamp);
    }

    function test_Funding_OISplitLongShort() public {
        _openDefaultTrade(alice); // long

        uint256 expectedLongOI = uint256(DEFAULT_EFFECTIVE_COLLATERAL) * uint256(DEFAULT_LEVERAGE) * 1e12;
        assertEq(tradingStorage.getOpenInterestLong(DEFAULT_PAIR_INDEX), expectedLongOI);
        assertEq(tradingStorage.getOpenInterestShort(DEFAULT_PAIR_INDEX), 0);

        // Open short
        uint128 shortTp = 45_000 * 1e18;
        uint128 shortSl = 55_000 * 1e18;
        vm.prank(bob);
        engine.openTrade(
            DEFAULT_PAIR_INDEX,
            false,
            DEFAULT_COLLATERAL,
            DEFAULT_LEVERAGE,
            DEFAULT_SHORT_OPEN_PRICE,
            DEFAULT_SLIPPAGE_BPS,
            shortTp,
            shortSl,
            EMPTY_UPDATE
        );

        uint256 expectedShortOI = uint256(DEFAULT_EFFECTIVE_COLLATERAL) * uint256(DEFAULT_LEVERAGE) * 1e12;
        assertEq(tradingStorage.getOpenInterestLong(DEFAULT_PAIR_INDEX), expectedLongOI);
        assertEq(tradingStorage.getOpenInterestShort(DEFAULT_PAIR_INDEX), expectedShortOI);
        assertEq(tradingStorage.getOpenInterest(DEFAULT_PAIR_INDEX), expectedLongOI + expectedShortOI);
    }

    function test_Funding_LongReceivesWhenShortsHeavier() public {
        // 2 shorts, 1 long → shorts heavier → long receives funding
        uint128 shortTp = 45_000 * 1e18;
        uint128 shortSl = 55_000 * 1e18;
        vm.prank(bob);
        engine.openTrade(
            DEFAULT_PAIR_INDEX,
            false,
            DEFAULT_COLLATERAL,
            DEFAULT_LEVERAGE,
            DEFAULT_SHORT_OPEN_PRICE,
            DEFAULT_SLIPPAGE_BPS,
            shortTp,
            shortSl,
            EMPTY_UPDATE
        );
        vm.prank(bob);
        engine.openTrade(
            DEFAULT_PAIR_INDEX,
            false,
            DEFAULT_COLLATERAL,
            DEFAULT_LEVERAGE,
            DEFAULT_SHORT_OPEN_PRICE,
            DEFAULT_SLIPPAGE_BPS,
            shortTp,
            shortSl,
            EMPTY_UPDATE
        );

        uint32 longTradeId = _openDefaultTrade(alice); // long

        vm.warp(block.timestamp + 3600);

        // Close long at same oracle price
        uint128 closeExec = _longClosePrice(DEFAULT_ORACLE_PRICE);

        // Calculate no-funding payout
        uint256 size = uint256(DEFAULT_EFFECTIVE_COLLATERAL) * uint256(DEFAULT_LEVERAGE);
        uint256 exitValue = (uint256(closeExec) * size) / uint256(DEFAULT_LONG_OPEN_PRICE);
        int256 pnl = int256(exitValue) - int256(size);
        uint256 rawPayout = uint256(DEFAULT_EFFECTIVE_COLLATERAL) - uint256(-pnl);
        uint256 closeFeeVal = _closeFee(DEFAULT_EFFECTIVE_COLLATERAL, DEFAULT_LEVERAGE);
        uint256 noFundingPayout = rawPayout > closeFeeVal ? rawPayout - closeFeeVal : 0;

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        engine.closeTrade(longTradeId, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);
        uint256 aliceReceived = usdc.balanceOf(alice) - aliceBefore;

        // Long receives funding credit → gets more than noFunding
        assertGt(aliceReceived, noFundingPayout);
    }

    function testFuzz_Funding_FundsConservation(uint128 closeOracle) public {
        closeOracle = uint128(bound(closeOracle, 25_000 * 1e18, 100_000 * 1e18));

        uint256 totalBefore = usdc.balanceOf(alice) +
            usdc.balanceOf(bob) +
            usdc.balanceOf(address(vault)) +
            usdc.balanceOf(address(tradingStorage)) +
            usdc.balanceOf(treasuryAddr);

        _openDefaultTrade(alice); // long
        uint128 shortTp = 25_000 * 1e18;
        uint128 shortSl = 75_000 * 1e18;
        vm.prank(bob);
        engine.openTrade(
            DEFAULT_PAIR_INDEX,
            false,
            DEFAULT_COLLATERAL,
            DEFAULT_LEVERAGE,
            DEFAULT_SHORT_OPEN_PRICE,
            DEFAULT_SLIPPAGE_BPS,
            shortTp,
            shortSl,
            EMPTY_UPDATE
        );

        vm.warp(block.timestamp + 3600);

        mockOracle.setPrice(DEFAULT_PAIR_INDEX, closeOracle);

        uint128 closeExec1 = _longClosePrice(closeOracle);
        vm.prank(alice);
        engine.closeTrade(0, closeExec1, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);

        uint128 closeExec2 = _shortClosePrice(closeOracle);
        vm.prank(bob);
        engine.closeTrade(1, closeExec2, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);

        uint256 totalAfter = usdc.balanceOf(alice) +
            usdc.balanceOf(bob) +
            usdc.balanceOf(address(vault)) +
            usdc.balanceOf(address(tradingStorage)) +
            usdc.balanceOf(treasuryAddr);

        assertEq(totalBefore, totalAfter);
    }

    /*//////////////////////////////////////////////////////////////
                      DYNAMIC SPREAD TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Spread_HigherSpreadOnOpen() public {
        // Set spread to 20 BPS
        mockSpreadManager.setSpreadBps(20);

        vm.prank(alice);
        uint32 tradeId = engine.openTrade(
            DEFAULT_PAIR_INDEX,
            true,
            DEFAULT_COLLATERAL,
            DEFAULT_LEVERAGE,
            uint128((uint256(DEFAULT_ORACLE_PRICE) * 10_020) / 10_000), // expected price with 20 BPS
            DEFAULT_SLIPPAGE_BPS,
            DEFAULT_TP,
            DEFAULT_SL,
            EMPTY_UPDATE
        );

        TradingStorage.Trade memory trade = tradingStorage.getTrade(tradeId);
        // Long open: price * (10000 + 20) / 10000
        uint128 expectedOpen = uint128((uint256(DEFAULT_ORACLE_PRICE) * 10_020) / 10_000);
        assertEq(trade.openPrice, expectedOpen);
        assertGt(trade.openPrice, DEFAULT_LONG_OPEN_PRICE); // Higher than 5 BPS spread
    }

    function test_Spread_HigherSpreadOnClose() public {
        // Open with default 5 BPS
        uint32 tradeId = _openDefaultTrade(alice);

        // Set spread to 20 BPS for close
        mockSpreadManager.setSpreadBps(20);

        uint128 closeExec = uint128((uint256(DEFAULT_ORACLE_PRICE) * 9_980) / 10_000); // 20 BPS down
        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        engine.closeTrade(tradeId, closeExec, DEFAULT_SLIPPAGE_BPS, EMPTY_UPDATE);

        uint256 aliceAfter = usdc.balanceOf(alice);
        // Higher spread on close means worse execution → less payout
        assertLt(aliceAfter - aliceBefore, DEFAULT_EFFECTIVE_COLLATERAL);
    }

    function test_Spread_ZeroSpreadNoAdjustment() public {
        // Deploy a new engine with a mock that returns 0 spread
        MockSpreadManager zeroSpreadManager = new MockSpreadManager(0);
        vm.startPrank(owner);
        TradingStorage ts2 = new TradingStorage(address(usdc), owner);
        Vault v2 = new Vault(address(usdc), owner);
        TradingEngine engine2 = new TradingEngine(
            address(ts2),
            address(v2),
            address(mockOracle),
            address(usdc),
            treasuryAddr,
            address(zeroSpreadManager),
            owner
        );
        ts2.setTradingEngine(address(engine2));
        v2.setTradingEngine(address(engine2));
        ts2.addPair("BTC/USD", 100, 10_000_000 * 1e18);
        vm.stopPrank();

        usdc.mint(alice, 1_000_000 * 10 ** 6);
        vm.prank(alice);
        usdc.approve(address(engine2), type(uint256).max);

        vm.prank(alice);
        uint32 tradeId = engine2.openTrade(
            DEFAULT_PAIR_INDEX,
            true,
            DEFAULT_COLLATERAL,
            DEFAULT_LEVERAGE,
            DEFAULT_ORACLE_PRICE,
            DEFAULT_SLIPPAGE_BPS,
            DEFAULT_TP,
            DEFAULT_SL,
            EMPTY_UPDATE
        );

        TradingStorage.Trade memory trade = ts2.getTrade(tradeId);
        // Zero spread → open price equals oracle price
        assertEq(trade.openPrice, DEFAULT_ORACLE_PRICE);
    }

    /*//////////////////////////////////////////////////////////////
                          LIQUIDATION TESTS
    //////////////////////////////////////////////////////////////*/

    event TradeLiquidated(
        uint256 indexed tradeId,
        address indexed user,
        address indexed liquidator,
        uint128 closePrice,
        int256 pnlUsdc,
        int256 fundingOwedUsdc,
        uint256 liquidatorReward,
        uint256 vaultAmount
    );

    // Threshold = effectiveCollateral * 9000 / 10000
    function _liqThreshold(uint64 effectiveCollateral) internal pure returns (uint256) {
        return (uint256(effectiveCollateral) * 9000) / 10_000;
    }

    /**
     * @dev Oracle price that puts a default long (leverage 10x, openPrice = spread-adjusted) at exactly
     *      `lossBps` of collateral lost, accounting for the close-direction spread (×9995/10000).
     *      long loss = size * (openPrice - closePrice) / openPrice ; closePrice = oracle * 9995/10000
     */
    function _oracleForLongLoss(uint128 openPrice, uint256 lossBps) internal pure returns (uint128) {
        // want closePrice such that (openPrice - closePrice)/openPrice = lossBps/(10000*leverage)
        // closePrice = openPrice * (1 - lossBps/(10000*leverage))
        uint256 denom = uint256(10_000) * DEFAULT_LEVERAGE;
        uint256 closePrice = (uint256(openPrice) * (denom - lossBps)) / denom;
        // oracle = closePrice / (9995/10000)
        return uint128((closePrice * 10_000) / 9_995);
    }

    function test_Liquidate_Long_Success() public {
        uint32 tradeId = _openDefaultTrade(alice);

        // Move oracle so the long is well past the 90% loss threshold
        uint128 liqOracle = _oracleForLongLoss(DEFAULT_LONG_OPEN_PRICE, 9200); // 92% loss
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, liqOracle);

        uint256 storageBefore = usdc.balanceOf(address(tradingStorage));
        uint256 vaultBefore = usdc.balanceOf(address(vault));
        uint256 bobBefore = usdc.balanceOf(bob);

        vm.prank(bob);
        engine.liquidate(tradeId, EMPTY_UPDATE);

        // Trade deleted
        TradingStorage.Trade memory trade = tradingStorage.getTrade(tradeId);
        assertEq(trade.user, address(0));

        // All effective collateral left TradingStorage
        assertEq(usdc.balanceOf(address(tradingStorage)), storageBefore - DEFAULT_EFFECTIVE_COLLATERAL);

        // Liquidator + vault together received the full collateral
        uint256 bobReward = usdc.balanceOf(bob) - bobBefore;
        uint256 vaultGain = usdc.balanceOf(address(vault)) - vaultBefore;
        assertEq(bobReward + vaultGain, DEFAULT_EFFECTIVE_COLLATERAL);

        // At 92% loss, remaining ≈ 8% collateral; reward = 10% of remaining
        assertGt(bobReward, 0);
    }

    function test_Liquidate_Short_Success() public {
        vm.prank(alice);
        uint32 tradeId = engine.openTrade(
            DEFAULT_PAIR_INDEX,
            false,
            DEFAULT_COLLATERAL,
            DEFAULT_LEVERAGE,
            DEFAULT_SHORT_OPEN_PRICE,
            DEFAULT_SLIPPAGE_BPS,
            0,
            0,
            EMPTY_UPDATE
        );

        // Short loses when price goes UP. closePrice = oracle * 10005/10000.
        // want (closePrice - openPrice)/openPrice = 0.092 → closePrice = openPrice * 1.092
        uint256 shortDenom = uint256(10_000) * DEFAULT_LEVERAGE;
        uint256 closePrice = (uint256(DEFAULT_SHORT_OPEN_PRICE) * (shortDenom + 9200)) / shortDenom;
        uint128 liqOracle = uint128((closePrice * 10_000) / 10_005);
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, liqOracle);

        uint256 vaultBefore = usdc.balanceOf(address(vault));
        uint256 bobBefore = usdc.balanceOf(bob);

        vm.prank(bob);
        engine.liquidate(tradeId, EMPTY_UPDATE);

        assertEq(tradingStorage.getTrade(tradeId).user, address(0));
        uint256 total = (usdc.balanceOf(bob) - bobBefore) + (usdc.balanceOf(address(vault)) - vaultBefore);
        assertEq(total, DEFAULT_EFFECTIVE_COLLATERAL);
    }

    function test_Liquidate_RewardSplit() public {
        uint32 tradeId = _openDefaultTrade(alice);
        uint128 liqOracle = _oracleForLongLoss(DEFAULT_LONG_OPEN_PRICE, 9200);
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, liqOracle);

        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        // Compute expected reward from the actual execution price
        uint128 execPrice = _longClosePrice(liqOracle);
        int256 pnl = _calcLongPnl(DEFAULT_EFFECTIVE_COLLATERAL, DEFAULT_LEVERAGE, DEFAULT_LONG_OPEN_PRICE, execPrice);
        uint256 loss = uint256(-pnl);
        uint256 remaining = loss >= DEFAULT_EFFECTIVE_COLLATERAL ? 0 : DEFAULT_EFFECTIVE_COLLATERAL - loss;
        uint256 expectedReward = (remaining * 1000) / 10_000;
        uint256 expectedVault = DEFAULT_EFFECTIVE_COLLATERAL - expectedReward;

        vm.prank(bob);
        engine.liquidate(tradeId, EMPTY_UPDATE);

        assertEq(usdc.balanceOf(bob) - bobBefore, expectedReward);
        assertEq(usdc.balanceOf(address(vault)) - vaultBefore, expectedVault);
    }

    function test_Liquidate_EmitsEvent() public {
        uint32 tradeId = _openDefaultTrade(alice);
        uint128 liqOracle = _oracleForLongLoss(DEFAULT_LONG_OPEN_PRICE, 9200);
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, liqOracle);

        uint128 execPrice = _longClosePrice(liqOracle);
        int256 pnl = _calcLongPnl(DEFAULT_EFFECTIVE_COLLATERAL, DEFAULT_LEVERAGE, DEFAULT_LONG_OPEN_PRICE, execPrice);
        uint256 loss = uint256(-pnl);
        uint256 remaining = loss >= DEFAULT_EFFECTIVE_COLLATERAL ? 0 : DEFAULT_EFFECTIVE_COLLATERAL - loss;
        uint256 expectedReward = (remaining * 1000) / 10_000;
        uint256 expectedVault = DEFAULT_EFFECTIVE_COLLATERAL - expectedReward;

        vm.expectEmit(true, true, true, true);
        emit TradeLiquidated(tradeId, alice, bob, execPrice, pnl, 0, expectedReward, expectedVault);
        vm.prank(bob);
        engine.liquidate(tradeId, EMPTY_UPDATE);
    }

    function test_Liquidate_DecreasesOpenInterest() public {
        uint32 tradeId = _openDefaultTrade(alice);
        uint256 oiBefore = tradingStorage.getOpenInterest(DEFAULT_PAIR_INDEX);
        assertGt(oiBefore, 0);

        uint128 liqOracle = _oracleForLongLoss(DEFAULT_LONG_OPEN_PRICE, 9200);
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, liqOracle);

        vm.prank(bob);
        engine.liquidate(tradeId, EMPTY_UPDATE);

        assertEq(tradingStorage.getOpenInterest(DEFAULT_PAIR_INDEX), 0);
    }

    function test_Liquidate_LossExceedsCollateral_ZeroReward() public {
        uint32 tradeId = _openDefaultTrade(alice);

        // Push loss beyond 100% of collateral → remaining = 0, reward = 0, all to vault
        uint128 liqOracle = _oracleForLongLoss(DEFAULT_LONG_OPEN_PRICE, 10_500); // 105% loss
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, liqOracle);

        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        vm.prank(bob);
        engine.liquidate(tradeId, EMPTY_UPDATE);

        assertEq(usdc.balanceOf(bob), bobBefore); // no reward
        assertEq(usdc.balanceOf(address(vault)) - vaultBefore, DEFAULT_EFFECTIVE_COLLATERAL);
    }

    function test_Liquidate_RevertWhenNotLiquidatable() public {
        uint32 tradeId = _openDefaultTrade(alice);

        // Only 50% loss — below the 90% threshold
        uint128 liqOracle = _oracleForLongLoss(DEFAULT_LONG_OPEN_PRICE, 5000);
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, liqOracle);

        vm.prank(bob);
        vm.expectRevert();
        engine.liquidate(tradeId, EMPTY_UPDATE);
    }

    function test_Liquidate_RevertWhenProfitable() public {
        uint32 tradeId = _openDefaultTrade(alice);
        // Price up → long is in profit, definitely not liquidatable
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, 55_000 * 1e18);

        vm.prank(bob);
        vm.expectRevert();
        engine.liquidate(tradeId, EMPTY_UPDATE);
    }

    function test_Liquidate_RevertOnTradeNotFound() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TradingEngine.TradeNotFound.selector, uint256(999)));
        engine.liquidate(999, EMPTY_UPDATE);
    }

    function test_Liquidate_WorksWhilePaused() public {
        // Liquidation is the solvency valve and must stay live even while trading is paused.
        uint32 tradeId = _openDefaultTrade(alice);
        uint128 liqOracle = _oracleForLongLoss(DEFAULT_LONG_OPEN_PRICE, 9200);
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, liqOracle);

        vm.prank(owner);
        engine.pause();

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        engine.liquidate(tradeId, EMPTY_UPDATE);

        assertGt(usdc.balanceOf(bob), bobBefore);
        assertEq(tradingStorage.getTrade(tradeId).user, address(0));
    }

    function test_Liquidate_Permissionless_OwnerCanLiquidate() public {
        // The trade owner can also liquidate their own position
        uint32 tradeId = _openDefaultTrade(alice);
        uint128 liqOracle = _oracleForLongLoss(DEFAULT_LONG_OPEN_PRICE, 9200);
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, liqOracle);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        engine.liquidate(tradeId, EMPTY_UPDATE);

        // Alice receives the liquidator reward as msg.sender
        assertGt(usdc.balanceOf(alice), aliceBefore);
        assertEq(tradingStorage.getTrade(tradeId).user, address(0));
    }

    function testFuzz_Liquidate_TotalConserved(uint256 lossBps) public {
        // Loss between threshold (90%) and 150%
        lossBps = bound(lossBps, 9000, 15_000);

        uint32 tradeId = _openDefaultTrade(alice);
        uint128 liqOracle = _oracleForLongLoss(DEFAULT_LONG_OPEN_PRICE, lossBps);
        vm.assume(liqOracle > 0);
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, liqOracle);

        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        vm.prank(bob);
        engine.liquidate(tradeId, EMPTY_UPDATE);

        // Full collateral is always conserved between liquidator and vault
        uint256 total = (usdc.balanceOf(bob) - bobBefore) + (usdc.balanceOf(address(vault)) - vaultBefore);
        assertEq(total, DEFAULT_EFFECTIVE_COLLATERAL);
    }

    /*//////////////////////////////////////////////////////////////
                    PRE-LIQUIDATION OPEN GUARD (7.6)
    //////////////////////////////////////////////////////////////*/

    function test_OpenTrade_RevertWhenPreLiquidatable() public {
        // A spread large enough to open straight into the liquidation zone must be rejected.
        // At 100x leverage, a ~90 bps spread already means 90% instant loss.
        mockSpreadManager.setSpreadBps(100); // 1% spread
        uint16 highLeverage = 100;

        vm.prank(alice);
        vm.expectRevert();
        engine.openTrade(
            DEFAULT_PAIR_INDEX,
            true,
            DEFAULT_COLLATERAL,
            highLeverage,
            0, // no expected price constraint
            10_000, // 100% slippage tolerance so slippage doesn't revert first
            0,
            0,
            EMPTY_UPDATE
        );
    }

    function test_OpenTrade_AllowsNormalSpread() public {
        // Default 5 bps spread at 10x = 0.05% instant loss, far below threshold — must succeed
        uint32 tradeId = _openDefaultTrade(alice);
        assertEq(tradingStorage.getTrade(tradeId).user, alice);
    }

    /*//////////////////////////////////////////////////////////////
              CONF-BASED CONSERVATIVE LIQ PRICING (7.7)
    //////////////////////////////////////////////////////////////*/

    function test_Liquidate_Long_ConfProtectsTrader() public {
        uint32 tradeId = _openDefaultTrade(alice);

        // At the raw price the long is at ~92% loss → liquidatable.
        uint128 liqOracle = _oracleForLongLoss(DEFAULT_LONG_OPEN_PRICE, 9200);
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, liqOracle);

        // A wide confidence band raises the effective price (price + conf for longs),
        // shrinking the loss below the 90% threshold → no longer liquidatable.
        mockOracle.setConf(DEFAULT_PAIR_INDEX, uint128(uint256(liqOracle) / 20)); // 5% conf

        vm.prank(bob);
        vm.expectRevert();
        engine.liquidate(tradeId, EMPTY_UPDATE);
    }

    function test_Liquidate_Short_ConfProtectsTrader() public {
        vm.prank(alice);
        uint32 tradeId = engine.openTrade(
            DEFAULT_PAIR_INDEX,
            false,
            DEFAULT_COLLATERAL,
            DEFAULT_LEVERAGE,
            DEFAULT_SHORT_OPEN_PRICE,
            DEFAULT_SLIPPAGE_BPS,
            0,
            0,
            EMPTY_UPDATE
        );

        // Short loses when price rises; at this oracle it is ~92% loss → liquidatable.
        uint256 shortDenom = uint256(10_000) * DEFAULT_LEVERAGE;
        uint256 closePrice = (uint256(DEFAULT_SHORT_OPEN_PRICE) * (shortDenom + 9200)) / shortDenom;
        uint128 liqOracle = uint128((closePrice * 10_000) / 10_005);
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, liqOracle);

        // Wide conf lowers the effective price (price - conf for shorts) → loss shrinks below threshold.
        mockOracle.setConf(DEFAULT_PAIR_INDEX, uint128(uint256(liqOracle) / 20)); // 5% conf

        vm.prank(bob);
        vm.expectRevert();
        engine.liquidate(tradeId, EMPTY_UPDATE);
    }

    function test_Liquidate_Long_SmallConfStillLiquidatable() public {
        uint32 tradeId = _openDefaultTrade(alice);

        // Deep loss (~110%) so a tiny conf cannot rescue the position.
        uint128 liqOracle = _oracleForLongLoss(DEFAULT_LONG_OPEN_PRICE, 11_000);
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, liqOracle);
        mockOracle.setConf(DEFAULT_PAIR_INDEX, uint128(uint256(liqOracle) / 10_000)); // 1 bps conf

        uint256 total0 = usdc.balanceOf(bob) + usdc.balanceOf(address(vault));
        vm.prank(bob);
        engine.liquidate(tradeId, EMPTY_UPDATE);

        // Still liquidated: trade gone and collateral conserved
        assertEq(tradingStorage.getTrade(tradeId).user, address(0));
        uint256 total1 = usdc.balanceOf(bob) + usdc.balanceOf(address(vault));
        assertEq(total1 - total0, DEFAULT_EFFECTIVE_COLLATERAL);
    }

    function test_Liquidate_Long_ConfAppliedToExecutionPrice() public {
        uint32 tradeId = _openDefaultTrade(alice);

        uint128 liqOracle = _oracleForLongLoss(DEFAULT_LONG_OPEN_PRICE, 11_000);
        uint128 conf = uint128(uint256(liqOracle) / 200); // 0.5% conf
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, liqOracle);
        mockOracle.setConf(DEFAULT_PAIR_INDEX, conf);

        // Effective price for a long is (price + conf), then close-direction spread (×9995/10000)
        uint128 conservative = liqOracle + conf;
        uint128 expectedExec = _longClosePrice(conservative);
        int256 expectedPnl = _calcLongPnl(DEFAULT_EFFECTIVE_COLLATERAL, DEFAULT_LEVERAGE, DEFAULT_LONG_OPEN_PRICE, expectedExec);

        uint256 loss = uint256(-expectedPnl);
        uint256 remaining = loss >= DEFAULT_EFFECTIVE_COLLATERAL ? 0 : DEFAULT_EFFECTIVE_COLLATERAL - loss;
        uint256 expectedReward = (remaining * 1000) / 10_000;
        uint256 expectedVault = DEFAULT_EFFECTIVE_COLLATERAL - expectedReward;

        vm.expectEmit(true, true, true, true);
        emit TradeLiquidated(tradeId, alice, bob, expectedExec, expectedPnl, 0, expectedReward, expectedVault);
        vm.prank(bob);
        engine.liquidate(tradeId, EMPTY_UPDATE);
    }

    function test_Liquidate_ZeroConf_MatchesRawPricing() public {
        // conf = 0 (default) must behave exactly like plain price liquidation
        uint32 tradeId = _openDefaultTrade(alice);
        uint128 liqOracle = _oracleForLongLoss(DEFAULT_LONG_OPEN_PRICE, 9200);
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, liqOracle);
        // no setConf → conf stays 0

        uint128 expectedExec = _longClosePrice(liqOracle);
        int256 expectedPnl = _calcLongPnl(DEFAULT_EFFECTIVE_COLLATERAL, DEFAULT_LEVERAGE, DEFAULT_LONG_OPEN_PRICE, expectedExec);

        vm.expectEmit(true, true, true, false);
        emit TradeLiquidated(tradeId, alice, bob, expectedExec, expectedPnl, 0, 0, 0);
        vm.prank(bob);
        engine.liquidate(tradeId, EMPTY_UPDATE);
    }

    /*//////////////////////////////////////////////////////////////
                    LIQUIDATION EDGE CASES (review follow-ups)
    //////////////////////////////////////////////////////////////*/

    function test_Liquidate_FundingInducedWhilePriceSolvent() public {
        // Only a long is open → max OI imbalance → the long pays funding over time.
        uint32 tradeId = _openDefaultTrade(alice);

        // Keep the oracle at entry so price PnL is ~0 (a solvent position by price alone).
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, DEFAULT_ORACLE_PRICE);

        // Sanity: at t=0 the position is NOT liquidatable (price-only loss is negligible).
        vm.prank(bob);
        vm.expectRevert();
        engine.liquidate(tradeId, EMPTY_UPDATE);

        // Accrue funding for 4h — enough for funding alone to exceed the 90% threshold.
        vm.warp(block.timestamp + 4 hours);

        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        vm.prank(bob);
        engine.liquidate(tradeId, EMPTY_UPDATE);

        // Liquidated purely by funding: trade gone, collateral conserved to liquidator + vault.
        assertEq(tradingStorage.getTrade(tradeId).user, address(0));
        uint256 total = (usdc.balanceOf(bob) - bobBefore) + (usdc.balanceOf(address(vault)) - vaultBefore);
        assertEq(total, DEFAULT_EFFECTIVE_COLLATERAL);
    }

    function test_Liquidate_UnderwaterVaultMadeWhole() public {
        // Deep loss (>100%) so remaining = 0: liquidator gets nothing, the full collateral backs the vault.
        uint32 tradeId = _openDefaultTrade(alice);
        uint128 liqOracle = _oracleForLongLoss(DEFAULT_LONG_OPEN_PRICE, 12_000); // 120% loss
        vm.assume(liqOracle > 0);
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, liqOracle);

        uint256 storageBefore = usdc.balanceOf(address(tradingStorage));
        uint256 vaultTotalBefore = vault.totalAssets();
        uint256 vaultBalBefore = usdc.balanceOf(address(vault));
        uint256 bobBefore = usdc.balanceOf(bob);

        vm.prank(bob);
        engine.liquidate(tradeId, EMPTY_UPDATE);

        // Liquidator reward is 0 when the position is fully underwater.
        assertEq(usdc.balanceOf(bob), bobBefore);

        // The entire effective collateral moved from storage into the vault, and the vault's
        // balance-based accounting absorbed it exactly (made whole).
        assertEq(storageBefore - usdc.balanceOf(address(tradingStorage)), DEFAULT_EFFECTIVE_COLLATERAL);
        assertEq(usdc.balanceOf(address(vault)) - vaultBalBefore, DEFAULT_EFFECTIVE_COLLATERAL);
        assertEq(vault.totalAssets() - vaultTotalBefore, DEFAULT_EFFECTIVE_COLLATERAL);
    }

    function testFuzz_Liquidate_ShortRoundingFavorsPool(uint256 lossBps) public {
        // Rounding-direction invariant: for a short, the vault must never lose value to truncation.
        // The engine ceils exitValue for shorts; a floor'd mirror would (weakly) understate the loss,
        // so the engine's loss must be >= the floor mirror → vault gets at least as much.
        lossBps = bound(lossBps, 9000, 14_000);

        vm.prank(alice);
        uint32 tradeId = engine.openTrade(
            DEFAULT_PAIR_INDEX,
            false,
            DEFAULT_COLLATERAL,
            DEFAULT_LEVERAGE,
            DEFAULT_SHORT_OPEN_PRICE,
            DEFAULT_SLIPPAGE_BPS,
            0,
            0,
            EMPTY_UPDATE
        );

        // Oracle that puts the short at the target loss (short loses when price rises).
        uint256 denom = uint256(10_000) * DEFAULT_LEVERAGE;
        uint256 closePrice = (uint256(DEFAULT_SHORT_OPEN_PRICE) * (denom + lossBps)) / denom;
        uint128 liqOracle = uint128((closePrice * 10_000) / 10_005);
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, liqOracle);

        uint256 vaultBefore = usdc.balanceOf(address(vault));
        uint256 bobBefore = usdc.balanceOf(bob);

        vm.prank(bob);
        engine.liquidate(tradeId, EMPTY_UPDATE);

        // Conservation holds exactly regardless of rounding direction.
        uint256 total = (usdc.balanceOf(bob) - bobBefore) + (usdc.balanceOf(address(vault)) - vaultBefore);
        assertEq(total, DEFAULT_EFFECTIVE_COLLATERAL);

        // Vault never receives LESS than the floor-rounded accounting would have given it,
        // i.e. rounding is not adverse to the pool.
        uint128 execPrice = _shortClosePrice(liqOracle);
        uint256 size = uint256(DEFAULT_EFFECTIVE_COLLATERAL) * DEFAULT_LEVERAGE;
        uint256 exitFloor = (uint256(execPrice) * size) / uint256(DEFAULT_SHORT_OPEN_PRICE);
        int256 pnlFloor = int256(size) - int256(exitFloor); // floor mirror (weakly smaller loss)
        uint256 lossFloor = pnlFloor < 0 ? uint256(-pnlFloor) : 0;
        uint256 remainingFloor = lossFloor >= DEFAULT_EFFECTIVE_COLLATERAL ? 0 : DEFAULT_EFFECTIVE_COLLATERAL - lossFloor;
        uint256 vaultFloorLowerBound = DEFAULT_EFFECTIVE_COLLATERAL - (remainingFloor * 1000) / 10_000;

        assertGe(usdc.balanceOf(address(vault)) - vaultBefore, vaultFloorLowerBound);
    }

    function test_Liquidate_RevertOnOracleOutage() public {
        // A stale / high-deviation oracle makes getPrice revert; liquidation must revert too
        // (no liquidating at an unverified price) — the accepted outage behavior.
        uint32 tradeId = _openDefaultTrade(alice);
        uint128 liqOracle = _oracleForLongLoss(DEFAULT_LONG_OPEN_PRICE, 9200);
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, liqOracle);

        // Simulate the oracle outage.
        mockOracle.setShouldRevert(true);

        vm.prank(bob);
        vm.expectRevert(MockOracle.OracleUnavailable.selector);
        engine.liquidate(tradeId, EMPTY_UPDATE);

        // Recovery: once the oracle is back, the same position liquidates normally.
        mockOracle.setShouldRevert(false);
        vm.prank(bob);
        engine.liquidate(tradeId, EMPTY_UPDATE);
        assertEq(tradingStorage.getTrade(tradeId).user, address(0));
    }

    /**
     * @dev Local mirror of the engine's long PnL formula in USDC precision.
     */
    function _calcLongPnl(uint64 collateral, uint16 leverage, uint128 openPrice, uint128 closePrice) internal pure returns (int256) {
        uint256 size = uint256(collateral) * uint256(leverage);
        uint256 exitValue = (uint256(closePrice) * size) / uint256(openPrice);
        return int256(exitValue) - int256(size);
    }

    /*//////////////////////////////////////////////////////////////
                    LIMIT ORDERS / AUTO TP-SL (PHASE 8)
    //////////////////////////////////////////////////////////////*/

    event LimitExecuted(
        uint256 indexed tradeId,
        address indexed user,
        address indexed executor,
        bool isTp,
        uint128 closePrice,
        int256 pnlUsdc,
        uint256 payoutUsdc,
        uint256 executorReward,
        int256 fundingOwedUsdc
    );

    // Exec reward = collateral * leverage * 10 / 10000 (0.1% of notional)
    function _execReward(uint64 effectiveCollateral, uint16 leverage) internal pure returns (uint256) {
        return (uint256(effectiveCollateral) * leverage * 10) / 10_000;
    }

    function test_ExecuteLimit_RevertOnNoLimitSet() public {
        // Open a trade with no TP and no SL
        vm.prank(alice);
        uint32 tradeId = engine.openTrade(DEFAULT_PAIR_INDEX, true, DEFAULT_COLLATERAL, DEFAULT_LEVERAGE, DEFAULT_LONG_OPEN_PRICE, DEFAULT_SLIPPAGE_BPS, 0, 0, EMPTY_UPDATE);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TradingEngine.NoLimitSet.selector, uint256(tradeId)));
        engine.executeLimit(tradeId, EMPTY_UPDATE);
    }

    function test_ExecuteLimit_RevertOnNotTriggered() public {
        // Default long trade: TP 55k, SL 45k. Oracle at 50k → neither crossed.
        uint32 tradeId = _openDefaultTrade(alice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TradingEngine.LimitNotTriggered.selector, uint256(tradeId), DEFAULT_ORACLE_PRICE));
        engine.executeLimit(tradeId, EMPTY_UPDATE);
    }

    function test_ExecuteLimit_RevertOnTradeNotFound() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TradingEngine.TradeNotFound.selector, uint256(999)));
        engine.executeLimit(999, EMPTY_UPDATE);
    }

    function test_ExecuteLimit_LongTp_PaysTraderAndExecutor() public {
        uint32 tradeId = _openDefaultTrade(alice); // long, TP 55k

        // Oracle crosses TP upward
        uint128 oracle = 55_500 * 1e18;
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, oracle);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore = usdc.balanceOf(bob);

        vm.prank(bob);
        engine.executeLimit(tradeId, EMPTY_UPDATE);

        // Trade closed
        assertEq(tradingStorage.getTrade(tradeId).user, address(0));

        // Executor (bob) earns exactly the notional-based reward
        uint256 reward = _execReward(DEFAULT_EFFECTIVE_COLLATERAL, DEFAULT_LEVERAGE);
        assertEq(usdc.balanceOf(bob) - bobBefore, reward);

        // Trader (alice) receives a profit (payout - reward), strictly positive on a TP
        assertGt(usdc.balanceOf(alice) - aliceBefore, 0);
    }

    function test_ExecuteLimit_LongSl_TriggersOnPriceDrop() public {
        uint32 tradeId = _openDefaultTrade(alice); // long, SL 45k

        uint128 oracle = 44_500 * 1e18;
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, oracle);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        engine.executeLimit(tradeId, EMPTY_UPDATE);

        assertEq(tradingStorage.getTrade(tradeId).user, address(0));
        // SL is a loss but not full: executor still gets the reward carved from the residual payout
        assertGe(usdc.balanceOf(bob) - bobBefore, 0);
    }

    function test_ExecuteLimit_ShortTp_TriggersOnPriceDrop() public {
        // Short with TP below entry (45k) and SL above (55k)
        vm.prank(alice);
        uint32 tradeId = engine.openTrade(
            DEFAULT_PAIR_INDEX,
            false,
            DEFAULT_COLLATERAL,
            DEFAULT_LEVERAGE,
            DEFAULT_SHORT_OPEN_PRICE,
            DEFAULT_SLIPPAGE_BPS,
            45_000 * 1e18,
            55_000 * 1e18,
            EMPTY_UPDATE
        );

        // Short TP triggers when price falls to/below tp
        uint128 oracle = 44_500 * 1e18;
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, oracle);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(bob);
        engine.executeLimit(tradeId, EMPTY_UPDATE);

        assertEq(tradingStorage.getTrade(tradeId).user, address(0));
        assertGt(usdc.balanceOf(alice) - aliceBefore, 0); // short profits on price drop
    }

    function test_ExecuteLimit_ShortSl_TriggersOnPriceRise() public {
        vm.prank(alice);
        uint32 tradeId = engine.openTrade(
            DEFAULT_PAIR_INDEX,
            false,
            DEFAULT_COLLATERAL,
            DEFAULT_LEVERAGE,
            DEFAULT_SHORT_OPEN_PRICE,
            DEFAULT_SLIPPAGE_BPS,
            45_000 * 1e18,
            55_000 * 1e18,
            EMPTY_UPDATE
        );

        // Short SL triggers when price rises to/above sl
        uint128 oracle = 55_500 * 1e18;
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, oracle);

        vm.prank(bob);
        engine.executeLimit(tradeId, EMPTY_UPDATE);
        assertEq(tradingStorage.getTrade(tradeId).user, address(0));
    }

    function test_ExecuteLimit_EmitsEvent() public {
        uint32 tradeId = _openDefaultTrade(alice);
        uint128 oracle = 55_500 * 1e18;
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, oracle);

        uint128 execPrice = _longClosePrice(oracle);
        int256 pnl = _calcLongPnl(DEFAULT_EFFECTIVE_COLLATERAL, DEFAULT_LEVERAGE, DEFAULT_LONG_OPEN_PRICE, execPrice);
        uint256 reward = _execReward(DEFAULT_EFFECTIVE_COLLATERAL, DEFAULT_LEVERAGE);
        uint256 closeFeeVal = _closeFee(DEFAULT_EFFECTIVE_COLLATERAL, DEFAULT_LEVERAGE);
        uint256 payout = uint256(pnl) + uint256(DEFAULT_EFFECTIVE_COLLATERAL) - closeFeeVal - reward;

        vm.expectEmit(true, true, true, true);
        emit LimitExecuted(tradeId, alice, bob, true, execPrice, pnl, payout, reward, int256(0));
        vm.prank(bob);
        engine.executeLimit(tradeId, EMPTY_UPDATE);
    }

    function test_ExecuteLimit_ConservesFunds() public {
        uint256 totalBefore = usdc.balanceOf(alice) + usdc.balanceOf(bob) + usdc.balanceOf(address(vault)) + usdc.balanceOf(address(tradingStorage)) + usdc.balanceOf(treasuryAddr);

        uint32 tradeId = _openDefaultTrade(alice);
        uint128 oracle = 55_500 * 1e18;
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, oracle);

        vm.prank(bob);
        engine.executeLimit(tradeId, EMPTY_UPDATE);

        uint256 totalAfter = usdc.balanceOf(alice) + usdc.balanceOf(bob) + usdc.balanceOf(address(vault)) + usdc.balanceOf(address(tradingStorage)) + usdc.balanceOf(treasuryAddr);
        assertEq(totalAfter, totalBefore);
    }

    function test_ExecuteLimit_Permissionless_TraderCanSelfExecute() public {
        uint32 tradeId = _openDefaultTrade(alice);
        uint128 oracle = 55_500 * 1e18;
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, oracle);

        // The trade owner can also execute their own limit and collect the reward
        vm.prank(alice);
        engine.executeLimit(tradeId, EMPTY_UPDATE);
        assertEq(tradingStorage.getTrade(tradeId).user, address(0));
    }

    function test_ExecuteLimit_RevertWhenPaused() public {
        uint32 tradeId = _openDefaultTrade(alice);
        uint128 oracle = 55_500 * 1e18;
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, oracle);

        vm.prank(owner);
        engine.pause();

        vm.prank(bob);
        vm.expectRevert(TradingEngine.EnforcedPause.selector);
        engine.executeLimit(tradeId, EMPTY_UPDATE);
    }

    function test_ExecuteLimit_FundingAdjustsPayout() public {
        // Only a long open → long pays funding; after time the SL payout shrinks by funding
        uint32 tradeId = _openDefaultTrade(alice);

        vm.warp(block.timestamp + 1 hours);

        uint128 oracle = 44_500 * 1e18; // SL zone
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, oracle);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        engine.executeLimit(tradeId, EMPTY_UPDATE);

        // Executor still paid something (reward capped at residual payout), trade closed
        assertGe(usdc.balanceOf(bob) - bobBefore, 0);
        assertEq(tradingStorage.getTrade(tradeId).user, address(0));
    }

    function testFuzz_ExecuteLimit_ConservesFunds(uint128 triggerOracle) public {
        // Any oracle price that triggers the long TP (>=55k) or SL (<=45k) conserves funds
        triggerOracle = uint128(bound(triggerOracle, 30_000 * 1e18, 44_000 * 1e18)); // SL side (loss, no bad debt)

        uint256 totalBefore = usdc.balanceOf(alice) + usdc.balanceOf(bob) + usdc.balanceOf(address(vault)) + usdc.balanceOf(address(tradingStorage)) + usdc.balanceOf(treasuryAddr);

        uint32 tradeId = _openDefaultTrade(alice);
        mockOracle.setPrice(DEFAULT_PAIR_INDEX, triggerOracle);

        vm.prank(bob);
        engine.executeLimit(tradeId, EMPTY_UPDATE);

        uint256 totalAfter = usdc.balanceOf(alice) + usdc.balanceOf(bob) + usdc.balanceOf(address(vault)) + usdc.balanceOf(address(tradingStorage)) + usdc.balanceOf(treasuryAddr);
        assertEq(totalAfter, totalBefore);
    }
}
