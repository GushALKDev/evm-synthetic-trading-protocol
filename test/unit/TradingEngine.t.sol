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
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TradingEngine.BelowMinCollateral.selector, uint64(999_999)));
        engine.openTrade(DEFAULT_PAIR_INDEX, true, 999_999, DEFAULT_LEVERAGE, DEFAULT_LONG_OPEN_PRICE, DEFAULT_SLIPPAGE_BPS, 0, 0, EMPTY_UPDATE);
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

        // Verify math for short: pnl = size - exitValue
        uint256 size = uint256(effColl) * uint256(DEFAULT_LEVERAGE);
        uint256 exitValue = (uint256(closeExec) * size) / uint256(shortOpenExec);
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
        collateral = uint64(bound(collateral, 1e6, 100_000 * 10 ** 6));
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
        uint256 exitValue = (uint256(closeExec) * size) / uint256(shortOpenExec);
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
        uint256 exitValue = (uint256(closeExec) * size) / uint256(shortOpenExec);
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
        uint256 exitValue = (uint256(closeExec) * size) / uint256(shortOpenExec);
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
}
