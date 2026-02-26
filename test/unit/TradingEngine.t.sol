// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TradingEngine} from "../../src/TradingEngine.sol";
import {TradingStorage} from "../../src/TradingStorage.sol";
import {Vault} from "../../src/Vault.sol";
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

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    // Default trade parameters
    uint16 constant DEFAULT_PAIR_INDEX = 0;
    uint16 constant DEFAULT_LEVERAGE = 10;
    uint64 constant DEFAULT_COLLATERAL = 100 * 10 ** 6; // 100 USDC
    uint128 constant DEFAULT_OPEN_PRICE = 50_000 * 1e18;
    uint16 constant DEFAULT_SLIPPAGE_BPS = 50; // 0.5%
    uint128 constant DEFAULT_TP = 55_000 * 1e18;
    uint128 constant DEFAULT_SL = 45_000 * 1e18;

    // Events
    event TradeOpened(
        uint256 indexed tradeId,
        address indexed user,
        uint16 pairIndex,
        bool isLong,
        uint64 collateral,
        uint16 leverage,
        uint128 openPrice
    );
    event TradeClosed(uint256 indexed tradeId, address indexed user, uint128 closePrice, int256 pnlUsdc, uint256 payoutUsdc);
    event TpUpdated(uint256 indexed tradeId, uint128 newTp);
    event SlUpdated(uint256 indexed tradeId, uint128 newSl);
    event Paused(address account);
    event Unpaused(address account);

    function setUp() public {
        usdc = new MockUSDC();

        vm.startPrank(owner);
        tradingStorage = new TradingStorage(address(usdc), owner);
        vault = new Vault(address(usdc), owner);
        engine = new TradingEngine(address(tradingStorage), address(vault), address(usdc), owner);

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
        tradeId = engine.openTrade(DEFAULT_PAIR_INDEX, true, DEFAULT_COLLATERAL, DEFAULT_LEVERAGE, DEFAULT_OPEN_PRICE, DEFAULT_SLIPPAGE_BPS, DEFAULT_TP, DEFAULT_SL);
    }

    /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_SetsImmutables() public view {
        assertEq(address(engine.TRADING_STORAGE()), address(tradingStorage));
        assertEq(address(engine.VAULT()), address(vault));
        assertEq(engine.ASSET(), address(usdc));
    }

    function test_Constructor_SetsOwner() public view {
        assertEq(engine.owner(), owner);
    }

    function test_Constructor_RevertOnZeroTradingStorage() public {
        vm.expectRevert(TradingEngine.ZeroAddress.selector);
        new TradingEngine(address(0), address(vault), address(usdc), owner);
    }

    function test_Constructor_RevertOnZeroVault() public {
        vm.expectRevert(TradingEngine.ZeroAddress.selector);
        new TradingEngine(address(tradingStorage), address(0), address(usdc), owner);
    }

    function test_Constructor_RevertOnZeroAsset() public {
        vm.expectRevert(TradingEngine.ZeroAddress.selector);
        new TradingEngine(address(tradingStorage), address(vault), address(0), owner);
    }

    /*//////////////////////////////////////////////////////////////
                        OPEN TRADE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_OpenTrade() public {
        uint256 aliceBalBefore = usdc.balanceOf(alice);
        uint256 storageBefore = usdc.balanceOf(address(tradingStorage));

        uint32 tradeId = _openDefaultTrade(alice);

        assertEq(tradeId, 0);
        assertEq(usdc.balanceOf(alice), aliceBalBefore - DEFAULT_COLLATERAL);
        assertEq(usdc.balanceOf(address(tradingStorage)), storageBefore + DEFAULT_COLLATERAL);

        TradingStorage.Trade memory trade = tradingStorage.getTrade(tradeId);
        assertEq(trade.user, alice);
        assertTrue(trade.isLong);
        assertEq(trade.pairIndex, DEFAULT_PAIR_INDEX);
        assertEq(trade.leverage, DEFAULT_LEVERAGE);
        assertEq(trade.collateral, DEFAULT_COLLATERAL);
        assertEq(trade.openPrice, DEFAULT_OPEN_PRICE);
        assertEq(trade.tp, DEFAULT_TP);
        assertEq(trade.sl, DEFAULT_SL);
    }

    function test_OpenTrade_EmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit TradeOpened(0, alice, DEFAULT_PAIR_INDEX, true, DEFAULT_COLLATERAL, DEFAULT_LEVERAGE, DEFAULT_OPEN_PRICE);

        _openDefaultTrade(alice);
    }

    function test_OpenTrade_UpdatesOpenInterest() public {
        _openDefaultTrade(alice);

        // positionSize = 100e6 * 10 * 1e12 = 1_000e18
        uint256 expectedOI = uint256(DEFAULT_COLLATERAL) * uint256(DEFAULT_LEVERAGE) * 1e12;
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
        uint32 tradeId = engine.openTrade(DEFAULT_PAIR_INDEX, false, DEFAULT_COLLATERAL, DEFAULT_LEVERAGE, DEFAULT_OPEN_PRICE, DEFAULT_SLIPPAGE_BPS, shortTp, shortSl);

        TradingStorage.Trade memory trade = tradingStorage.getTrade(tradeId);
        assertFalse(trade.isLong);
        assertEq(trade.tp, shortTp);
        assertEq(trade.sl, shortSl);
    }

    function test_OpenTrade_NoTpNoSl() public {
        vm.prank(alice);
        uint32 tradeId = engine.openTrade(DEFAULT_PAIR_INDEX, true, DEFAULT_COLLATERAL, DEFAULT_LEVERAGE, DEFAULT_OPEN_PRICE, DEFAULT_SLIPPAGE_BPS, 0, 0);

        TradingStorage.Trade memory trade = tradingStorage.getTrade(tradeId);
        assertEq(trade.tp, 0);
        assertEq(trade.sl, 0);
    }

    function test_OpenTrade_RevertOnZeroPrice() public {
        vm.prank(alice);
        vm.expectRevert(TradingEngine.ZeroPrice.selector);
        engine.openTrade(DEFAULT_PAIR_INDEX, true, DEFAULT_COLLATERAL, DEFAULT_LEVERAGE, 0, DEFAULT_SLIPPAGE_BPS, 0, 0);
    }

    function test_OpenTrade_RevertBelowMinCollateral() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TradingEngine.BelowMinCollateral.selector, uint64(999_999)));
        engine.openTrade(DEFAULT_PAIR_INDEX, true, 999_999, DEFAULT_LEVERAGE, DEFAULT_OPEN_PRICE, DEFAULT_SLIPPAGE_BPS, 0, 0);
    }

    function test_OpenTrade_RevertOnZeroLeverage() public {
        vm.prank(alice);
        vm.expectRevert(TradingEngine.ZeroLeverage.selector);
        engine.openTrade(DEFAULT_PAIR_INDEX, true, DEFAULT_COLLATERAL, 0, DEFAULT_OPEN_PRICE, DEFAULT_SLIPPAGE_BPS, 0, 0);
    }

    function test_OpenTrade_RevertOnLeverageExceedsMax() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TradingEngine.LeverageExceedsMax.selector, uint16(101), uint16(100)));
        engine.openTrade(DEFAULT_PAIR_INDEX, true, DEFAULT_COLLATERAL, 101, DEFAULT_OPEN_PRICE, DEFAULT_SLIPPAGE_BPS, 0, 0);
    }

    function test_OpenTrade_RevertOnInactivePair() public {
        vm.prank(owner);
        tradingStorage.updatePair(0, 100, 10_000_000 * 1e18, false);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TradingEngine.PairNotActive.selector, uint16(0)));
        engine.openTrade(DEFAULT_PAIR_INDEX, true, DEFAULT_COLLATERAL, DEFAULT_LEVERAGE, DEFAULT_OPEN_PRICE, DEFAULT_SLIPPAGE_BPS, 0, 0);
    }

    function test_OpenTrade_RevertOnMaxOIExceeded() public {
        // Set a very small maxOI
        vm.prank(owner);
        tradingStorage.updatePair(0, 100, 100 * 1e18, true); // 100 USD max OI

        // position size = 100e6 * 10 * 1e12 = 1_000e18 which exceeds 100e18
        vm.prank(alice);
        vm.expectRevert(); // MaxOpenInterestExceeded
        engine.openTrade(DEFAULT_PAIR_INDEX, true, DEFAULT_COLLATERAL, DEFAULT_LEVERAGE, DEFAULT_OPEN_PRICE, DEFAULT_SLIPPAGE_BPS, 0, 0);
    }

    function test_OpenTrade_RevertWhenPaused() public {
        vm.prank(owner);
        engine.pause();

        vm.prank(alice);
        vm.expectRevert(TradingEngine.EnforcedPause.selector);
        engine.openTrade(DEFAULT_PAIR_INDEX, true, DEFAULT_COLLATERAL, DEFAULT_LEVERAGE, DEFAULT_OPEN_PRICE, DEFAULT_SLIPPAGE_BPS, 0, 0);
    }

    function test_OpenTrade_RevertOnInsufficientBalance() public {
        address broke = makeAddr("broke");
        vm.prank(broke);
        usdc.approve(address(engine), type(uint256).max);

        vm.prank(broke);
        vm.expectRevert(); // SafeTransferLib revert
        engine.openTrade(DEFAULT_PAIR_INDEX, true, DEFAULT_COLLATERAL, DEFAULT_LEVERAGE, DEFAULT_OPEN_PRICE, DEFAULT_SLIPPAGE_BPS, 0, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        CLOSE TRADE TESTS — PROFIT
    //////////////////////////////////////////////////////////////*/

    function test_CloseTrade_LongProfit() public {
        uint32 tradeId = _openDefaultTrade(alice);

        // Price went up 10%: 50k → 55k
        uint128 closePrice = 55_000 * 1e18;
        // PnL = (55000/50000 - 1) * 100 * 10 = +100 USDC
        // payout = 100 (collateral) + 100 (profit) = 200 USDC

        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        engine.closeTrade(tradeId, closePrice, DEFAULT_SLIPPAGE_BPS);

        uint256 aliceAfter = usdc.balanceOf(alice);
        // Alice gets back collateral (100 USDC) from TradingStorage + profit (100 USDC) from Vault
        assertEq(aliceAfter - aliceBefore, 200 * 10 ** 6);

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
        uint32 tradeId = engine.openTrade(DEFAULT_PAIR_INDEX, false, DEFAULT_COLLATERAL, DEFAULT_LEVERAGE, DEFAULT_OPEN_PRICE, DEFAULT_SLIPPAGE_BPS, shortTp, shortSl);

        // Price went down 10%: 50k → 45k (profit for short)
        uint128 closePrice = 45_000 * 1e18;
        // PnL = (1 - 45000/50000) * 100 * 10 = +100 USDC
        // payout = 100 + 100 = 200 USDC

        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        engine.closeTrade(tradeId, closePrice, DEFAULT_SLIPPAGE_BPS);

        uint256 aliceAfter = usdc.balanceOf(alice);
        assertEq(aliceAfter - aliceBefore, 200 * 10 ** 6);
    }

    function test_CloseTrade_EmitsEvent_Profit() public {
        uint32 tradeId = _openDefaultTrade(alice);
        uint128 closePrice = 55_000 * 1e18;

        // pnl = +100 USDC (100e6), payout = 200 USDC (200e6)
        vm.expectEmit(true, true, false, true);
        emit TradeClosed(tradeId, alice, closePrice, int256(100 * 10 ** 6), 200 * 10 ** 6);

        vm.prank(alice);
        engine.closeTrade(tradeId, closePrice, DEFAULT_SLIPPAGE_BPS);
    }

    /*//////////////////////////////////////////////////////////////
                        CLOSE TRADE TESTS — LOSS
    //////////////////////////////////////////////////////////////*/

    function test_CloseTrade_LongPartialLoss() public {
        uint32 tradeId = _openDefaultTrade(alice);

        // Price went down 5%: 50k → 47.5k
        uint128 closePrice = 47_500 * 1e18;
        // PnL = (47500/50000 - 1) * 100 * 10 = -50 USDC
        // payout = 100 - 50 = 50 USDC

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        vm.prank(alice);
        engine.closeTrade(tradeId, closePrice, DEFAULT_SLIPPAGE_BPS);

        uint256 aliceAfter = usdc.balanceOf(alice);
        uint256 vaultAfter = usdc.balanceOf(address(vault));

        assertEq(aliceAfter - aliceBefore, 50 * 10 ** 6); // Alice gets 50 USDC back
        assertEq(vaultAfter - vaultBefore, 50 * 10 ** 6); // Vault gets 50 USDC profit
    }

    function test_CloseTrade_LongFullLoss() public {
        uint32 tradeId = _openDefaultTrade(alice);

        // Price went down 10%: 50k → 45k (10x leverage = 100% loss)
        uint128 closePrice = 45_000 * 1e18;
        // PnL = (45000/50000 - 1) * 100 * 10 = -100 USDC
        // payout = max(0, 100 - 100) = 0

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        vm.prank(alice);
        engine.closeTrade(tradeId, closePrice, DEFAULT_SLIPPAGE_BPS);

        uint256 aliceAfter = usdc.balanceOf(alice);
        uint256 vaultAfter = usdc.balanceOf(address(vault));

        assertEq(aliceAfter, aliceBefore); // Alice gets nothing
        assertEq(vaultAfter - vaultBefore, 100 * 10 ** 6); // Vault gets all collateral
    }

    function test_CloseTrade_LongMoreThan100Loss() public {
        uint32 tradeId = _openDefaultTrade(alice);

        // Price went down 15%: 50k → 42.5k (10x leverage = 150% loss but capped at 0 payout)
        uint128 closePrice = 42_500 * 1e18;

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        vm.prank(alice);
        engine.closeTrade(tradeId, closePrice, DEFAULT_SLIPPAGE_BPS);

        assertEq(usdc.balanceOf(alice), aliceBefore); // Alice gets nothing
        assertEq(usdc.balanceOf(address(vault)) - vaultBefore, 100 * 10 ** 6); // Vault gets all collateral
    }

    function test_CloseTrade_ShortLoss() public {
        vm.prank(alice);
        uint32 tradeId = engine.openTrade(DEFAULT_PAIR_INDEX, false, DEFAULT_COLLATERAL, DEFAULT_LEVERAGE, DEFAULT_OPEN_PRICE, DEFAULT_SLIPPAGE_BPS, 0, 0);

        // Price went up 5%: 50k → 52.5k (loss for short)
        uint128 closePrice = 52_500 * 1e18;
        // PnL = (1 - 52500/50000) * 100 * 10 = -50 USDC

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        vm.prank(alice);
        engine.closeTrade(tradeId, closePrice, DEFAULT_SLIPPAGE_BPS);

        assertEq(usdc.balanceOf(alice) - aliceBefore, 50 * 10 ** 6);
        assertEq(usdc.balanceOf(address(vault)) - vaultBefore, 50 * 10 ** 6);
    }

    function test_CloseTrade_EmitsEvent_Loss() public {
        uint32 tradeId = _openDefaultTrade(alice);
        uint128 closePrice = 47_500 * 1e18;

        // pnl = -50 USDC (-50e6), payout = 50 USDC (50e6)
        vm.expectEmit(true, true, false, true);
        emit TradeClosed(tradeId, alice, closePrice, -int256(50 * 10 ** 6), 50 * 10 ** 6);

        vm.prank(alice);
        engine.closeTrade(tradeId, closePrice, DEFAULT_SLIPPAGE_BPS);
    }

    /*//////////////////////////////////////////////////////////////
                        CLOSE TRADE TESTS — PROFIT CAP
    //////////////////////////////////////////////////////////////*/

    function test_CloseTrade_ProfitCapped() public {
        uint32 tradeId = _openDefaultTrade(alice);

        // Price doubles: 50k → 100k (100% increase, 10x leverage = +1000% raw)
        // Raw PnL = (100000/50000 - 1) * 100 * 10 = +1000 USDC
        // But profit cap = 9x collateral = 900 USDC max payout
        uint128 closePrice = 100_000 * 1e18;

        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        engine.closeTrade(tradeId, closePrice, DEFAULT_SLIPPAGE_BPS);

        uint256 aliceAfter = usdc.balanceOf(alice);
        // Payout capped at 900 USDC (9x)
        assertEq(aliceAfter - aliceBefore, 900 * 10 ** 6);
    }

    function test_CloseTrade_ProfitJustBelowCap() public {
        uint32 tradeId = _openDefaultTrade(alice);

        // 80% price increase: 50k → 90k
        // PnL = (90000/50000 - 1) * 100 * 10 = +800 USDC
        // Payout = 100 + 800 = 900 USDC = exactly 9x (at cap)
        uint128 closePrice = 90_000 * 1e18;

        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        engine.closeTrade(tradeId, closePrice, DEFAULT_SLIPPAGE_BPS);

        assertEq(usdc.balanceOf(alice) - aliceBefore, 900 * 10 ** 6);
    }

    /*//////////////////////////////////////////////////////////////
                      CLOSE TRADE TESTS — BREAKEVEN
    //////////////////////////////////////////////////////////////*/

    function test_CloseTrade_Breakeven() public {
        uint32 tradeId = _openDefaultTrade(alice);

        // Same price: no PnL
        uint128 closePrice = DEFAULT_OPEN_PRICE;

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        vm.prank(alice);
        engine.closeTrade(tradeId, closePrice, DEFAULT_SLIPPAGE_BPS);

        // Alice gets full collateral back (from TradingStorage), Vault untouched
        assertEq(usdc.balanceOf(alice) - aliceBefore, DEFAULT_COLLATERAL);
        assertEq(usdc.balanceOf(address(vault)), vaultBefore);
    }

    /*//////////////////////////////////////////////////////////////
                      CLOSE TRADE TESTS — REVERTS
    //////////////////////////////////////////////////////////////*/

    function test_CloseTrade_RevertOnZeroPrice() public {
        uint32 tradeId = _openDefaultTrade(alice);

        vm.prank(alice);
        vm.expectRevert(TradingEngine.ZeroPrice.selector);
        engine.closeTrade(tradeId, 0, DEFAULT_SLIPPAGE_BPS);
    }

    function test_CloseTrade_RevertOnTradeNotFound() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TradingEngine.TradeNotFound.selector, 99));
        engine.closeTrade(99, DEFAULT_OPEN_PRICE, DEFAULT_SLIPPAGE_BPS);
    }

    function test_CloseTrade_RevertOnNotTradeOwner() public {
        uint32 tradeId = _openDefaultTrade(alice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TradingEngine.NotTradeOwner.selector, bob, alice));
        engine.closeTrade(tradeId, DEFAULT_OPEN_PRICE, DEFAULT_SLIPPAGE_BPS);
    }

    function test_CloseTrade_RevertWhenPaused() public {
        uint32 tradeId = _openDefaultTrade(alice);

        vm.prank(owner);
        engine.pause();

        vm.prank(alice);
        vm.expectRevert(TradingEngine.EnforcedPause.selector);
        engine.closeTrade(tradeId, DEFAULT_OPEN_PRICE, DEFAULT_SLIPPAGE_BPS);
    }

    /*//////////////////////////////////////////////////////////////
                          UPDATE TP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_UpdateTp() public {
        uint32 tradeId = _openDefaultTrade(alice);

        uint128 newTp = 60_000 * 1e18;
        vm.prank(alice);
        engine.updateTp(tradeId, newTp);

        TradingStorage.Trade memory trade = tradingStorage.getTrade(tradeId);
        assertEq(trade.tp, newTp);
    }

    function test_UpdateTp_EmitsEvent() public {
        uint32 tradeId = _openDefaultTrade(alice);
        uint128 newTp = 60_000 * 1e18;

        vm.expectEmit(true, false, false, true);
        emit TpUpdated(tradeId, newTp);

        vm.prank(alice);
        engine.updateTp(tradeId, newTp);
    }

    function test_UpdateTp_ClearTp() public {
        uint32 tradeId = _openDefaultTrade(alice);

        vm.prank(alice);
        engine.updateTp(tradeId, 0);

        TradingStorage.Trade memory trade = tradingStorage.getTrade(tradeId);
        assertEq(trade.tp, 0);
    }

    function test_UpdateTp_RevertOnTradeNotFound() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TradingEngine.TradeNotFound.selector, 99));
        engine.updateTp(99, 60_000 * 1e18);
    }

    function test_UpdateTp_RevertOnNotTradeOwner() public {
        uint32 tradeId = _openDefaultTrade(alice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TradingEngine.NotTradeOwner.selector, bob, alice));
        engine.updateTp(tradeId, 60_000 * 1e18);
    }

    function test_UpdateTp_RevertWhenPaused() public {
        uint32 tradeId = _openDefaultTrade(alice);

        vm.prank(owner);
        engine.pause();

        vm.prank(alice);
        vm.expectRevert(TradingEngine.EnforcedPause.selector);
        engine.updateTp(tradeId, 60_000 * 1e18);
    }

    function test_UpdateTp_RevertOnInvalidTpForLong() public {
        uint32 tradeId = _openDefaultTrade(alice);

        // TP below open price for long is invalid
        vm.prank(alice);
        vm.expectRevert();
        engine.updateTp(tradeId, DEFAULT_OPEN_PRICE - 1);
    }

    /*//////////////////////////////////////////////////////////////
                          UPDATE SL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_UpdateSl() public {
        uint32 tradeId = _openDefaultTrade(alice);

        uint128 newSl = 40_000 * 1e18;
        vm.prank(alice);
        engine.updateSl(tradeId, newSl);

        TradingStorage.Trade memory trade = tradingStorage.getTrade(tradeId);
        assertEq(trade.sl, newSl);
    }

    function test_UpdateSl_EmitsEvent() public {
        uint32 tradeId = _openDefaultTrade(alice);
        uint128 newSl = 40_000 * 1e18;

        vm.expectEmit(true, false, false, true);
        emit SlUpdated(tradeId, newSl);

        vm.prank(alice);
        engine.updateSl(tradeId, newSl);
    }

    function test_UpdateSl_ClearSl() public {
        uint32 tradeId = _openDefaultTrade(alice);

        vm.prank(alice);
        engine.updateSl(tradeId, 0);

        TradingStorage.Trade memory trade = tradingStorage.getTrade(tradeId);
        assertEq(trade.sl, 0);
    }

    function test_UpdateSl_RevertOnTradeNotFound() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TradingEngine.TradeNotFound.selector, 99));
        engine.updateSl(99, 40_000 * 1e18);
    }

    function test_UpdateSl_RevertOnNotTradeOwner() public {
        uint32 tradeId = _openDefaultTrade(alice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TradingEngine.NotTradeOwner.selector, bob, alice));
        engine.updateSl(tradeId, 40_000 * 1e18);
    }

    function test_UpdateSl_RevertWhenPaused() public {
        uint32 tradeId = _openDefaultTrade(alice);

        vm.prank(owner);
        engine.pause();

        vm.prank(alice);
        vm.expectRevert(TradingEngine.EnforcedPause.selector);
        engine.updateSl(tradeId, 40_000 * 1e18);
    }

    function test_UpdateSl_RevertOnInvalidSlForLong() public {
        uint32 tradeId = _openDefaultTrade(alice);

        // SL above open price for long is invalid
        vm.prank(alice);
        vm.expectRevert();
        engine.updateSl(tradeId, DEFAULT_OPEN_PRICE + 1);
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
        // 100 USDC, 10x, entry 50k, exit 52.5k (+5%)
        // PnL = (52500 * 1000 / 50000) - 1000 = 1050 - 1000 = +50 USDC
        uint32 tradeId = _openDefaultTrade(alice);
        uint128 closePrice = 52_500 * 1e18;

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        engine.closeTrade(tradeId, closePrice, DEFAULT_SLIPPAGE_BPS);

        assertEq(usdc.balanceOf(alice) - aliceBefore, 150 * 10 ** 6); // 100 collateral + 50 profit
    }

    function test_PnL_ShortExactMath() public {
        vm.prank(alice);
        uint32 tradeId = engine.openTrade(DEFAULT_PAIR_INDEX, false, DEFAULT_COLLATERAL, DEFAULT_LEVERAGE, DEFAULT_OPEN_PRICE, DEFAULT_SLIPPAGE_BPS, 0, 0);

        // Short entry 50k, exit 47.5k (-5% price, profit for short)
        // PnL = 1000 - (47500 * 1000 / 50000) = 1000 - 950 = +50 USDC
        uint128 closePrice = 47_500 * 1e18;

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        engine.closeTrade(tradeId, closePrice, DEFAULT_SLIPPAGE_BPS);

        assertEq(usdc.balanceOf(alice) - aliceBefore, 150 * 10 ** 6);
    }

    function test_PnL_HighLeverage() public {
        // 100 USDC, 100x, entry 50k, exit 50.5k (+1% price)
        // size = 100 * 100 = 10,000 USDC
        // PnL = (50500 * 10000 / 50000) - 10000 = 10100 - 10000 = +100 USDC
        // payout = 100 + 100 = 200 USDC
        vm.prank(alice);
        uint32 tradeId = engine.openTrade(DEFAULT_PAIR_INDEX, true, DEFAULT_COLLATERAL, 100, DEFAULT_OPEN_PRICE, DEFAULT_SLIPPAGE_BPS, 0, 0);

        uint128 closePrice = 50_500 * 1e18;
        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        engine.closeTrade(tradeId, closePrice, DEFAULT_SLIPPAGE_BPS);

        assertEq(usdc.balanceOf(alice) - aliceBefore, 200 * 10 ** 6);
    }

    /*//////////////////////////////////////////////////////////////
                        COLLATERAL FLOW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CollateralFlow_FullLossGoesToVault() public {
        uint32 tradeId = _openDefaultTrade(alice);

        uint256 storageBefore = usdc.balanceOf(address(tradingStorage));
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        vm.prank(alice);
        engine.closeTrade(tradeId, 45_000 * 1e18, DEFAULT_SLIPPAGE_BPS); // 100% loss

        // TradingStorage should have sent all collateral to Vault
        assertEq(usdc.balanceOf(address(tradingStorage)), storageBefore - DEFAULT_COLLATERAL);
        assertEq(usdc.balanceOf(address(vault)), vaultBefore + DEFAULT_COLLATERAL);
    }

    function test_CollateralFlow_PartialLossSplitCorrectly() public {
        uint32 tradeId = _openDefaultTrade(alice);

        uint256 storageBefore = usdc.balanceOf(address(tradingStorage));
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        vm.prank(alice);
        engine.closeTrade(tradeId, 47_500 * 1e18, DEFAULT_SLIPPAGE_BPS); // 50% loss

        // Storage sent all 100 USDC out (50 to alice, 50 to vault)
        assertEq(usdc.balanceOf(address(tradingStorage)), storageBefore - DEFAULT_COLLATERAL);
        assertEq(usdc.balanceOf(address(vault)), vaultBefore + 50 * 10 ** 6);
    }

    function test_CollateralFlow_ProfitFromVault() public {
        uint32 tradeId = _openDefaultTrade(alice);

        uint256 storageBefore = usdc.balanceOf(address(tradingStorage));
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        vm.prank(alice);
        engine.closeTrade(tradeId, 55_000 * 1e18, DEFAULT_SLIPPAGE_BPS); // +100 USDC profit

        // Storage returns full collateral to trader
        assertEq(usdc.balanceOf(address(tradingStorage)), storageBefore - DEFAULT_COLLATERAL);
        // Vault pays profit
        assertEq(usdc.balanceOf(address(vault)), vaultBefore - 100 * 10 ** 6);
    }

    /*//////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_OpenTrade(uint64 collateral, uint16 leverage) public {
        collateral = uint64(bound(collateral, 1e6, 100_000 * 10 ** 6));
        leverage = uint16(bound(leverage, 1, 100));

        // Ensure OI doesn't exceed max
        uint256 posSize = uint256(collateral) * uint256(leverage) * 1e12;
        vm.assume(posSize <= 10_000_000 * 1e18);

        vm.prank(alice);
        uint32 tradeId = engine.openTrade(DEFAULT_PAIR_INDEX, true, collateral, leverage, DEFAULT_OPEN_PRICE, DEFAULT_SLIPPAGE_BPS, 0, 0);

        TradingStorage.Trade memory trade = tradingStorage.getTrade(tradeId);
        assertEq(trade.user, alice);
        assertEq(trade.collateral, collateral);
        assertEq(trade.leverage, leverage);
        assertEq(usdc.balanceOf(address(tradingStorage)), collateral);
    }

    function testFuzz_CloseTrade_PnL(uint128 closePrice) public {
        closePrice = uint128(bound(closePrice, 1e18, 500_000 * 1e18));

        uint32 tradeId = _openDefaultTrade(alice);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        vm.prank(alice);
        engine.closeTrade(tradeId, closePrice, DEFAULT_SLIPPAGE_BPS);

        uint256 aliceAfter = usdc.balanceOf(alice);
        uint256 vaultAfter = usdc.balanceOf(address(vault));

        // Total collateral should be fully accounted for
        uint256 traderReceived = aliceAfter - aliceBefore;
        int256 vaultDelta = int256(vaultAfter) - int256(vaultBefore);

        // Invariant: traderReceived + vaultDelta == collateral (conservation of funds)
        // When profit: traderReceived > collateral, vaultDelta < 0 → traderReceived + vaultDelta = collateral
        // When loss: traderReceived < collateral, vaultDelta > 0 → traderReceived + vaultDelta = collateral
        assertEq(int256(traderReceived) + vaultDelta, int256(uint256(DEFAULT_COLLATERAL)));

        // Trade must be deleted
        TradingStorage.Trade memory trade = tradingStorage.getTrade(tradeId);
        assertEq(trade.user, address(0));

        // OI must be zero
        assertEq(tradingStorage.getOpenInterest(DEFAULT_PAIR_INDEX), 0);
    }

    function testFuzz_ProfitCap(uint128 closePrice) public {
        // Only test prices where there's profit (above entry for long)
        closePrice = uint128(bound(closePrice, DEFAULT_OPEN_PRICE + 1, type(uint128).max / (uint256(DEFAULT_COLLATERAL) * DEFAULT_LEVERAGE)));

        uint32 tradeId = _openDefaultTrade(alice);

        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        engine.closeTrade(tradeId, closePrice, DEFAULT_SLIPPAGE_BPS);

        uint256 received = usdc.balanceOf(alice) - aliceBefore;
        // Payout should never exceed MAX_PROFIT_MULTIPLIER * collateral
        assertLe(received, uint256(DEFAULT_COLLATERAL) * engine.MAX_PROFIT_MULTIPLIER());
    }

    /*//////////////////////////////////////////////////////////////
                        INVARIANT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Invariant_OIMatchesTrades() public {
        _openDefaultTrade(alice);
        _openDefaultTrade(alice);
        _openDefaultTrade(bob);

        uint256 expectedOI = 3 * uint256(DEFAULT_COLLATERAL) * uint256(DEFAULT_LEVERAGE) * 1e12;
        assertEq(tradingStorage.getOpenInterest(DEFAULT_PAIR_INDEX), expectedOI);

        // Close one trade
        vm.prank(alice);
        engine.closeTrade(0, DEFAULT_OPEN_PRICE, DEFAULT_SLIPPAGE_BPS);

        expectedOI = 2 * uint256(DEFAULT_COLLATERAL) * uint256(DEFAULT_LEVERAGE) * 1e12;
        assertEq(tradingStorage.getOpenInterest(DEFAULT_PAIR_INDEX), expectedOI);
    }

    function test_Invariant_StorageBalanceMatchesCollateral() public {
        _openDefaultTrade(alice);
        _openDefaultTrade(bob);

        assertEq(usdc.balanceOf(address(tradingStorage)), 2 * uint256(DEFAULT_COLLATERAL));

        // Close alice's trade at breakeven
        vm.prank(alice);
        engine.closeTrade(0, DEFAULT_OPEN_PRICE, DEFAULT_SLIPPAGE_BPS);

        assertEq(usdc.balanceOf(address(tradingStorage)), uint256(DEFAULT_COLLATERAL));
    }

    function test_Invariant_FundsConservation_MultipleTraders() public {
        uint256 totalBefore = usdc.balanceOf(alice) + usdc.balanceOf(bob) + usdc.balanceOf(address(vault)) + usdc.balanceOf(address(tradingStorage));

        _openDefaultTrade(alice);
        _openDefaultTrade(bob);

        // Close alice at profit
        vm.prank(alice);
        engine.closeTrade(0, 55_000 * 1e18, DEFAULT_SLIPPAGE_BPS);

        // Close bob at loss
        vm.prank(bob);
        engine.closeTrade(1, 47_500 * 1e18, DEFAULT_SLIPPAGE_BPS);

        uint256 totalAfter = usdc.balanceOf(alice) + usdc.balanceOf(bob) + usdc.balanceOf(address(vault)) + usdc.balanceOf(address(tradingStorage));

        // Total USDC in the system must be conserved
        assertEq(totalBefore, totalAfter);
    }
}
