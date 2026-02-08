// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TradingStorage} from "../../src/TradingStorage.sol";
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

contract TradingStorageTest is Test {
    using SafeTransferLib for address;

    TradingStorage tradingStorage;
    MockUSDC usdc;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    address tradingEngine = makeAddr("tradingEngine");
    address vaultAddr = makeAddr("vault");

    event TradeStored(uint256 indexed tradeId, address indexed user, uint16 pairIndex);
    event TradeDeleted(uint256 indexed tradeId, address indexed user);
    event TradeTpUpdated(uint256 indexed tradeId, uint128 newTp);
    event TradeSlUpdated(uint256 indexed tradeId, uint128 newSl);
    event OpenInterestUpdated(uint256 indexed pairIndex, uint256 newOI);
    event CollateralSent(address indexed to, uint256 amount);
    event PairAdded(uint256 indexed pairIndex, string name);
    event PairUpdated(uint256 indexed pairIndex);
    event TradingEngineUpdated(address indexed newEngine);

    // Default trade parameters
    uint16 constant DEFAULT_PAIR_INDEX = 0;
    uint16 constant DEFAULT_LEVERAGE = 10;
    uint64 constant DEFAULT_COLLATERAL = 100 * 10 ** 6;
    uint128 constant DEFAULT_OPEN_PRICE = 50_000 * 1e18;
    uint128 constant DEFAULT_TP = 55_000 * 1e18;
    uint128 constant DEFAULT_SL = 45_000 * 1e18;

    function setUp() public {
        usdc = new MockUSDC();

        vm.prank(owner);
        tradingStorage = new TradingStorage(address(usdc), owner);

        vm.prank(owner);
        tradingStorage.setTradingEngine(tradingEngine);

        // Add a default pair (BTC/USD)
        vm.prank(owner);
        tradingStorage.addPair("BTC/USD", 100, 10_000_000 * 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                          HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _storeTrade(address _user) internal returns (uint32) {
        return tradingStorage.storeTrade(_user, true, DEFAULT_PAIR_INDEX, DEFAULT_LEVERAGE, DEFAULT_COLLATERAL, DEFAULT_OPEN_PRICE, DEFAULT_TP, DEFAULT_SL);
    }

    function _depositCollateral(uint256 _amount) internal {
        usdc.mint(address(tradingStorage), _amount);
    }

    /*//////////////////////////////////////////////////////////////
                          CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_SetsAsset() public view {
        assertEq(tradingStorage.ASSET(), address(usdc));
    }

    function test_Constructor_SetsOwner() public view {
        assertEq(tradingStorage.owner(), owner);
    }

    function test_Constructor_RevertOnZeroAsset() public {
        vm.expectRevert(TradingStorage.ZeroAddress.selector);
        new TradingStorage(address(0), owner);
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetTradingEngine() public {
        address newEngine = makeAddr("newEngine");

        vm.prank(owner);
        tradingStorage.setTradingEngine(newEngine);

        assertEq(tradingStorage.tradingEngine(), newEngine);
    }

    function test_SetTradingEngine_EmitsEvent() public {
        address newEngine = makeAddr("newEngine");

        vm.expectEmit(true, false, false, false);
        emit TradingEngineUpdated(newEngine);

        vm.prank(owner);
        tradingStorage.setTradingEngine(newEngine);
    }

    function test_SetTradingEngine_RevertOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(TradingStorage.ZeroAddress.selector);
        tradingStorage.setTradingEngine(address(0));
    }

    function test_SetTradingEngine_RevertIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        tradingStorage.setTradingEngine(makeAddr("newEngine"));
    }

    function test_AddPair() public {
        vm.prank(owner);
        uint256 pairIndex = tradingStorage.addPair("ETH/USD", 50, 5_000_000 * 1e18);

        assertEq(pairIndex, 1);

        TradingStorage.Pair memory pair = tradingStorage.getPair(pairIndex);
        assertEq(pair.name, "ETH/USD");
        assertEq(pair.maxLeverage, 50);
        assertEq(pair.maxOI, 5_000_000 * 1e18);
        assertTrue(pair.isActive);
    }

    function test_AddPair_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit PairAdded(1, "ETH/USD");

        vm.prank(owner);
        tradingStorage.addPair("ETH/USD", 50, 5_000_000 * 1e18);
    }

    function test_AddPair_MultiplePairs() public {
        vm.startPrank(owner);
        uint256 idx1 = tradingStorage.addPair("ETH/USD", 50, 5_000_000 * 1e18);
        uint256 idx2 = tradingStorage.addPair("SOL/USD", 20, 1_000_000 * 1e18);
        vm.stopPrank();

        assertEq(idx1, 1);
        assertEq(idx2, 2);
        assertEq(tradingStorage.getPairsCount(), 3);
    }

    function test_AddPair_RevertOnEmptyName() public {
        vm.prank(owner);
        vm.expectRevert(TradingStorage.EmptyPairName.selector);
        tradingStorage.addPair("", 100, 10_000_000 * 1e18);
    }

    function test_AddPair_RevertOnZeroMaxLeverage() public {
        vm.prank(owner);
        vm.expectRevert(TradingStorage.ZeroMaxLeverage.selector);
        tradingStorage.addPair("ETH/USD", 0, 10_000_000 * 1e18);
    }

    function test_AddPair_RevertOnZeroMaxOI() public {
        vm.prank(owner);
        vm.expectRevert(TradingStorage.ZeroMaxOI.selector);
        tradingStorage.addPair("ETH/USD", 50, 0);
    }

    function test_AddPair_RevertIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        tradingStorage.addPair("ETH/USD", 50, 5_000_000 * 1e18);
    }

    function test_UpdatePair() public {
        vm.prank(owner);
        tradingStorage.updatePair(0, 50, 5_000_000 * 1e18, false);

        TradingStorage.Pair memory pair = tradingStorage.getPair(0);
        assertEq(pair.maxLeverage, 50);
        assertEq(pair.maxOI, 5_000_000 * 1e18);
        assertFalse(pair.isActive);
    }

    function test_UpdatePair_EmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit PairUpdated(0);

        vm.prank(owner);
        tradingStorage.updatePair(0, 50, 5_000_000 * 1e18, true);
    }

    function test_UpdatePair_RevertOnInvalidIndex() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(TradingStorage.PairNotFound.selector, 99));
        tradingStorage.updatePair(99, 50, 5_000_000 * 1e18, true);
    }

    function test_UpdatePair_RevertOnZeroMaxLeverage() public {
        vm.prank(owner);
        vm.expectRevert(TradingStorage.ZeroMaxLeverage.selector);
        tradingStorage.updatePair(0, 0, 5_000_000 * 1e18, true);
    }

    function test_UpdatePair_RevertOnZeroMaxOI() public {
        vm.prank(owner);
        vm.expectRevert(TradingStorage.ZeroMaxOI.selector);
        tradingStorage.updatePair(0, 50, 0, true);
    }

    function test_UpdatePair_RevertIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        tradingStorage.updatePair(0, 50, 5_000_000 * 1e18, true);
    }

    function test_UpdatePair_CanDeactivatePair() public {
        vm.prank(owner);
        tradingStorage.updatePair(0, 100, 10_000_000 * 1e18, false);

        TradingStorage.Pair memory pair = tradingStorage.getPair(0);
        assertFalse(pair.isActive);
    }

    /*//////////////////////////////////////////////////////////////
                          STORE TRADE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_StoreTrade() public {
        vm.prank(tradingEngine);
        uint32 tradeId = _storeTrade(alice);

        assertEq(tradeId, 0);

        TradingStorage.Trade memory stored = tradingStorage.getTrade(tradeId);
        assertEq(stored.user, alice);
        assertTrue(stored.isLong);
        assertEq(stored.pairIndex, 0);
        assertEq(stored.index, 0);
        assertEq(stored.collateral, 100 * 10 ** 6);
        assertEq(stored.leverage, 10);
        assertEq(stored.openPrice, 50_000 * 1e18);
        assertEq(stored.tp, 55_000 * 1e18);
        assertEq(stored.sl, 45_000 * 1e18);
        assertEq(stored.timestamp, block.timestamp);
    }

    function test_StoreTrade_EmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit TradeStored(0, alice, 0);

        vm.prank(tradingEngine);
        _storeTrade(alice);
    }

    function test_StoreTrade_SetsCorrectIndex() public {
        vm.prank(tradingEngine);
        uint32 tradeId = _storeTrade(alice);

        TradingStorage.Trade memory stored = tradingStorage.getTrade(tradeId);
        assertEq(stored.index, 0);
    }

    function test_StoreTrade_AddsToUserTrades() public {
        vm.prank(tradingEngine);
        _storeTrade(alice);

        uint256[] memory userTrades = tradingStorage.getUserTrades(alice);
        assertEq(userTrades.length, 1);
        assertEq(userTrades[0], 0);
    }

    function test_StoreTrade_MultipleTradesSequentialIds() public {
        vm.startPrank(tradingEngine);

        uint32 id0 = _storeTrade(alice);
        uint32 id1 = _storeTrade(alice);
        uint32 id2 = _storeTrade(bob);

        vm.stopPrank();

        assertEq(id0, 0);
        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(tradingStorage.getTradeCounter(), 3);
    }

    function test_StoreTrade_StructFieldsPreserved() public {
        vm.prank(tradingEngine);
        uint32 tradeId = tradingStorage.storeTrade(bob, false, 0, 50, 500 * 10 ** 6, 2_000 * 1e18, 0, 1_800 * 1e18);

        TradingStorage.Trade memory stored = tradingStorage.getTrade(tradeId);
        assertEq(stored.user, bob);
        assertFalse(stored.isLong);
        assertEq(stored.collateral, 500 * 10 ** 6);
        assertEq(stored.leverage, 50);
        assertEq(stored.openPrice, 2_000 * 1e18);
        assertEq(stored.tp, 0);
        assertEq(stored.sl, 1_800 * 1e18);
        assertEq(stored.timestamp, block.timestamp);
    }

    function test_StoreTrade_RevertIfNotTradingEngine() public {
        vm.prank(alice);
        vm.expectRevert(TradingStorage.CallerNotTradingEngine.selector);
        _storeTrade(alice);
    }

    function test_StoreTrade_RevertIfPairNotFound() public {
        vm.prank(tradingEngine);
        vm.expectRevert(abi.encodeWithSelector(TradingStorage.PairNotFound.selector, 99));
        tradingStorage.storeTrade(alice, true, 99, DEFAULT_LEVERAGE, DEFAULT_COLLATERAL, DEFAULT_OPEN_PRICE, DEFAULT_TP, DEFAULT_SL);
    }

    /*//////////////////////////////////////////////////////////////
                          DELETE TRADE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_DeleteTrade() public {
        vm.startPrank(tradingEngine);
        uint32 tradeId = _storeTrade(alice);
        tradingStorage.deleteTrade(tradeId);
        vm.stopPrank();

        TradingStorage.Trade memory stored = tradingStorage.getTrade(tradeId);
        assertEq(stored.user, address(0));
    }

    function test_DeleteTrade_EmitsEvent() public {
        vm.prank(tradingEngine);
        uint32 tradeId = _storeTrade(alice);

        vm.expectEmit(true, true, false, false);
        emit TradeDeleted(tradeId, alice);

        vm.prank(tradingEngine);
        tradingStorage.deleteTrade(tradeId);
    }

    function test_DeleteTrade_RemovesFromUserTrades() public {
        vm.startPrank(tradingEngine);
        _storeTrade(alice);
        uint32 tradeId1 = _storeTrade(alice);

        tradingStorage.deleteTrade(tradeId1);
        vm.stopPrank();

        uint256[] memory userTrades = tradingStorage.getUserTrades(alice);
        assertEq(userTrades.length, 1);
        assertEq(userTrades[0], 0);
    }

    function test_DeleteTrade_MultipleTradesSwapAndPop() public {
        vm.startPrank(tradingEngine);
        _storeTrade(alice); // id 0
        _storeTrade(alice); // id 1
        _storeTrade(alice); // id 2

        // Delete middle trade (id 1) — should swap with last (id 2) and pop
        tradingStorage.deleteTrade(1);
        vm.stopPrank();

        uint256[] memory userTrades = tradingStorage.getUserTrades(alice);
        assertEq(userTrades.length, 2);
        assertEq(userTrades[0], 0);
        assertEq(userTrades[1], 2);
    }

    function test_DeleteTrade_RevertIfNotTradingEngine() public {
        vm.prank(tradingEngine);
        uint32 tradeId = _storeTrade(alice);

        vm.prank(alice);
        vm.expectRevert(TradingStorage.CallerNotTradingEngine.selector);
        tradingStorage.deleteTrade(tradeId);
    }

    function test_DeleteTrade_RevertIfTradeNotFound() public {
        vm.prank(tradingEngine);
        vm.expectRevert(abi.encodeWithSelector(TradingStorage.TradeNotFound.selector, 99));
        tradingStorage.deleteTrade(99);
    }

    /*//////////////////////////////////////////////////////////////
                          UPDATE TP/SL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_UpdateTradeTp() public {
        vm.prank(tradingEngine);
        uint32 tradeId = _storeTrade(alice);

        vm.prank(tradingEngine);
        tradingStorage.updateTradeTp(tradeId, 60_000 * 1e18);

        TradingStorage.Trade memory stored = tradingStorage.getTrade(tradeId);
        assertEq(stored.tp, 60_000 * 1e18);
    }

    function test_UpdateTradeTp_EmitsEvent() public {
        vm.prank(tradingEngine);
        uint32 tradeId = _storeTrade(alice);

        vm.expectEmit(true, false, false, true);
        emit TradeTpUpdated(tradeId, 60_000 * 1e18);

        vm.prank(tradingEngine);
        tradingStorage.updateTradeTp(tradeId, 60_000 * 1e18);
    }

    function test_UpdateTradeTp_SetToZero() public {
        vm.prank(tradingEngine);
        uint32 tradeId = _storeTrade(alice);

        vm.prank(tradingEngine);
        tradingStorage.updateTradeTp(tradeId, 0);

        TradingStorage.Trade memory stored = tradingStorage.getTrade(tradeId);
        assertEq(stored.tp, 0);
    }

    function test_UpdateTradeTp_RevertIfTradeNotFound() public {
        vm.prank(tradingEngine);
        vm.expectRevert(abi.encodeWithSelector(TradingStorage.TradeNotFound.selector, 99));
        tradingStorage.updateTradeTp(99, 60_000 * 1e18);
    }

    function test_UpdateTradeTp_RevertIfNotTradingEngine() public {
        vm.prank(tradingEngine);
        uint32 tradeId = _storeTrade(alice);

        vm.prank(alice);
        vm.expectRevert(TradingStorage.CallerNotTradingEngine.selector);
        tradingStorage.updateTradeTp(tradeId, 60_000 * 1e18);
    }

    function test_UpdateTradeSl() public {
        vm.prank(tradingEngine);
        uint32 tradeId = _storeTrade(alice);

        vm.prank(tradingEngine);
        tradingStorage.updateTradeSl(tradeId, 40_000 * 1e18);

        TradingStorage.Trade memory stored = tradingStorage.getTrade(tradeId);
        assertEq(stored.sl, 40_000 * 1e18);
    }

    function test_UpdateTradeSl_EmitsEvent() public {
        vm.prank(tradingEngine);
        uint32 tradeId = _storeTrade(alice);

        vm.expectEmit(true, false, false, true);
        emit TradeSlUpdated(tradeId, 40_000 * 1e18);

        vm.prank(tradingEngine);
        tradingStorage.updateTradeSl(tradeId, 40_000 * 1e18);
    }

    function test_UpdateTradeSl_RevertIfTradeNotFound() public {
        vm.prank(tradingEngine);
        vm.expectRevert(abi.encodeWithSelector(TradingStorage.TradeNotFound.selector, 99));
        tradingStorage.updateTradeSl(99, 40_000 * 1e18);
    }

    function test_UpdateTradeSl_RevertIfNotTradingEngine() public {
        vm.prank(tradingEngine);
        uint32 tradeId = _storeTrade(alice);

        vm.prank(alice);
        vm.expectRevert(TradingStorage.CallerNotTradingEngine.selector);
        tradingStorage.updateTradeSl(tradeId, 40_000 * 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                        OPEN INTEREST TESTS
    //////////////////////////////////////////////////////////////*/

    function test_IncreaseOpenInterest() public {
        vm.prank(tradingEngine);
        tradingStorage.increaseOpenInterest(0, 1_000 * 1e18);

        assertEq(tradingStorage.getOpenInterest(0), 1_000 * 1e18);
    }

    function test_IncreaseOpenInterest_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit OpenInterestUpdated(0, 1_000 * 1e18);

        vm.prank(tradingEngine);
        tradingStorage.increaseOpenInterest(0, 1_000 * 1e18);
    }

    function test_IncreaseOpenInterest_Cumulative() public {
        vm.startPrank(tradingEngine);
        tradingStorage.increaseOpenInterest(0, 1_000 * 1e18);
        tradingStorage.increaseOpenInterest(0, 2_000 * 1e18);
        vm.stopPrank();

        assertEq(tradingStorage.getOpenInterest(0), 3_000 * 1e18);
    }

    function test_IncreaseOpenInterest_RevertIfNotTradingEngine() public {
        vm.prank(alice);
        vm.expectRevert(TradingStorage.CallerNotTradingEngine.selector);
        tradingStorage.increaseOpenInterest(0, 1_000 * 1e18);
    }

    function test_IncreaseOpenInterest_RevertIfPairNotFound() public {
        vm.prank(tradingEngine);
        vm.expectRevert(abi.encodeWithSelector(TradingStorage.PairNotFound.selector, 99));
        tradingStorage.increaseOpenInterest(99, 1_000 * 1e18);
    }

    function test_DecreaseOpenInterest() public {
        vm.startPrank(tradingEngine);
        tradingStorage.increaseOpenInterest(0, 3_000 * 1e18);
        tradingStorage.decreaseOpenInterest(0, 1_000 * 1e18);
        vm.stopPrank();

        assertEq(tradingStorage.getOpenInterest(0), 2_000 * 1e18);
    }

    function test_DecreaseOpenInterest_EmitsEvent() public {
        vm.prank(tradingEngine);
        tradingStorage.increaseOpenInterest(0, 3_000 * 1e18);

        vm.expectEmit(true, false, false, true);
        emit OpenInterestUpdated(0, 2_000 * 1e18);

        vm.prank(tradingEngine);
        tradingStorage.decreaseOpenInterest(0, 1_000 * 1e18);
    }

    function test_DecreaseOpenInterest_RevertOnUnderflow() public {
        vm.prank(tradingEngine);
        vm.expectRevert();
        tradingStorage.decreaseOpenInterest(0, 1_000 * 1e18);
    }

    function test_DecreaseOpenInterest_RevertIfPairNotFound() public {
        vm.prank(tradingEngine);
        vm.expectRevert(abi.encodeWithSelector(TradingStorage.PairNotFound.selector, 99));
        tradingStorage.decreaseOpenInterest(99, 1_000 * 1e18);
    }

    function test_DecreaseOpenInterest_RevertIfNotTradingEngine() public {
        vm.prank(alice);
        vm.expectRevert(TradingStorage.CallerNotTradingEngine.selector);
        tradingStorage.decreaseOpenInterest(0, 1_000 * 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                      COLLATERAL MOVEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SendCollateral() public {
        _depositCollateral(1000 * 10 ** 6);

        uint256 bobBefore = usdc.balanceOf(bob);

        vm.prank(tradingEngine);
        tradingStorage.sendCollateral(bob, 500 * 10 ** 6);

        assertEq(usdc.balanceOf(bob), bobBefore + 500 * 10 ** 6);
        assertEq(usdc.balanceOf(address(tradingStorage)), 500 * 10 ** 6);
    }

    function test_SendCollateral_EmitsEvent() public {
        _depositCollateral(1000 * 10 ** 6);

        vm.expectEmit(true, false, false, true);
        emit CollateralSent(bob, 500 * 10 ** 6);

        vm.prank(tradingEngine);
        tradingStorage.sendCollateral(bob, 500 * 10 ** 6);
    }

    function test_SendCollateral_FullBalance() public {
        _depositCollateral(1000 * 10 ** 6);

        vm.prank(tradingEngine);
        tradingStorage.sendCollateral(bob, 1000 * 10 ** 6);

        assertEq(usdc.balanceOf(address(tradingStorage)), 0);
    }

    function test_SendCollateral_RevertIfNotTradingEngine() public {
        _depositCollateral(1000 * 10 ** 6);

        vm.prank(alice);
        vm.expectRevert(TradingStorage.CallerNotTradingEngine.selector);
        tradingStorage.sendCollateral(bob, 500 * 10 ** 6);
    }

    function test_SendCollateral_RevertIfInsufficientBalance() public {
        _depositCollateral(100 * 10 ** 6);

        vm.prank(tradingEngine);
        vm.expectRevert(abi.encodeWithSelector(TradingStorage.InsufficientBalance.selector, 500 * 10 ** 6, 100 * 10 ** 6));
        tradingStorage.sendCollateral(bob, 500 * 10 ** 6);
    }

    function test_ReceiveCollateral_ViaTransferFrom() public {
        usdc.mint(alice, 1000 * 10 ** 6);

        // Alice approves TradingEngine (the real flow: user approves proxy, proxy moves funds)
        vm.prank(alice);
        usdc.approve(tradingEngine, 1000 * 10 ** 6);

        // TradingEngine transfers collateral from alice to TradingStorage
        vm.prank(tradingEngine);
        address(usdc).safeTransferFrom(alice, address(tradingStorage), 1000 * 10 ** 6);

        assertEq(usdc.balanceOf(address(tradingStorage)), 1000 * 10 ** 6);
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetTrade() public {
        vm.prank(tradingEngine);
        uint32 tradeId = _storeTrade(alice);

        TradingStorage.Trade memory stored = tradingStorage.getTrade(tradeId);
        assertEq(stored.user, alice);
        assertEq(stored.index, tradeId);
    }

    function test_GetTrade_DeletedTradeReturnsZero() public {
        vm.startPrank(tradingEngine);
        uint32 tradeId = _storeTrade(alice);
        tradingStorage.deleteTrade(tradeId);
        vm.stopPrank();

        TradingStorage.Trade memory stored = tradingStorage.getTrade(tradeId);
        assertEq(stored.user, address(0));
        assertEq(stored.collateral, 0);
    }

    function test_GetUserTrades() public {
        vm.startPrank(tradingEngine);
        _storeTrade(alice);
        _storeTrade(alice);
        _storeTrade(bob);
        vm.stopPrank();

        uint256[] memory aliceTrades = tradingStorage.getUserTrades(alice);
        uint256[] memory bobTrades = tradingStorage.getUserTrades(bob);

        assertEq(aliceTrades.length, 2);
        assertEq(aliceTrades[0], 0);
        assertEq(aliceTrades[1], 1);
        assertEq(bobTrades.length, 1);
        assertEq(bobTrades[0], 2);
    }

    function test_GetUserTradesCount() public {
        vm.startPrank(tradingEngine);
        _storeTrade(alice);
        _storeTrade(alice);
        vm.stopPrank();

        assertEq(tradingStorage.getUserActiveTradesCount(alice), 2);
        assertEq(tradingStorage.getUserActiveTradesCount(bob), 0);
    }

    function test_GetOpenInterest() public {
        assertEq(tradingStorage.getOpenInterest(0), 0);

        vm.prank(tradingEngine);
        tradingStorage.increaseOpenInterest(0, 1_000 * 1e18);

        assertEq(tradingStorage.getOpenInterest(0), 1_000 * 1e18);
    }

    function test_GetPair() public view {
        TradingStorage.Pair memory pair = tradingStorage.getPair(0);
        assertEq(pair.name, "BTC/USD");
        assertEq(pair.maxLeverage, 100);
        assertEq(pair.maxOI, 10_000_000 * 1e18);
        assertTrue(pair.isActive);
    }

    function test_GetPair_RevertIfNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(TradingStorage.PairNotFound.selector, 99));
        tradingStorage.getPair(99);
    }

    function test_GetPairsCount() public view {
        assertEq(tradingStorage.getPairsCount(), 1);
    }

    function test_GetTradeCounter() public {
        assertEq(tradingStorage.getTradeCounter(), 0);

        vm.prank(tradingEngine);
        _storeTrade(alice);

        assertEq(tradingStorage.getTradeCounter(), 1);
    }

    /*//////////////////////////////////////////////////////////////
                        OWNERSHIP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_OwnershipHandover_TwoStep() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(newOwner);
        tradingStorage.requestOwnershipHandover();

        assertEq(tradingStorage.owner(), owner);

        vm.prank(owner);
        tradingStorage.completeOwnershipHandover(newOwner);

        assertEq(tradingStorage.owner(), newOwner);
    }

    function test_OwnershipHandover_OnlyOwnerCanComplete() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(newOwner);
        tradingStorage.requestOwnershipHandover();

        vm.prank(alice);
        vm.expectRevert();
        tradingStorage.completeOwnershipHandover(newOwner);
    }

    function test_RenounceOwnership() public {
        vm.prank(owner);
        tradingStorage.renounceOwnership();

        assertEq(tradingStorage.owner(), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_StoreTrade(uint64 collateral, uint16 leverage) public {
        collateral = uint64(bound(collateral, 1, 10_000_000 * 10 ** 6));
        leverage = uint16(bound(leverage, 1, 100));

        vm.prank(tradingEngine);
        uint32 tradeId = tradingStorage.storeTrade(alice, true, DEFAULT_PAIR_INDEX, leverage, collateral, DEFAULT_OPEN_PRICE, DEFAULT_TP, DEFAULT_SL);

        TradingStorage.Trade memory stored = tradingStorage.getTrade(tradeId);
        assertEq(stored.collateral, collateral);
        assertEq(stored.leverage, leverage);
        assertEq(stored.user, alice);
    }

    function testFuzz_SendCollateral(uint256 depositAmount, uint256 sendAmount) public {
        depositAmount = bound(depositAmount, 1, 10_000_000 * 10 ** 6);
        sendAmount = bound(sendAmount, 0, depositAmount);

        _depositCollateral(depositAmount);

        uint256 bobBefore = usdc.balanceOf(bob);

        vm.prank(tradingEngine);
        tradingStorage.sendCollateral(bob, sendAmount);

        assertEq(usdc.balanceOf(bob), bobBefore + sendAmount);
        assertEq(usdc.balanceOf(address(tradingStorage)), depositAmount - sendAmount);
    }

    function testFuzz_OpenInterest(uint256 increaseAmount, uint256 decreaseAmount) public {
        increaseAmount = bound(increaseAmount, 1, type(uint128).max);
        decreaseAmount = bound(decreaseAmount, 0, increaseAmount);

        vm.startPrank(tradingEngine);
        tradingStorage.increaseOpenInterest(0, increaseAmount);
        tradingStorage.decreaseOpenInterest(0, decreaseAmount);
        vm.stopPrank();

        assertEq(tradingStorage.getOpenInterest(0), increaseAmount - decreaseAmount);
    }

    function testFuzz_MultipleTradesUserArray(uint8 numTrades) public {
        numTrades = uint8(bound(numTrades, 1, 20));

        vm.startPrank(tradingEngine);
        for (uint8 i; i < numTrades; i++) {
            _storeTrade(alice);
        }
        vm.stopPrank();

        assertEq(tradingStorage.getUserActiveTradesCount(alice), numTrades);
        assertEq(tradingStorage.getTradeCounter(), numTrades);

        // Delete the first trade
        vm.prank(tradingEngine);
        tradingStorage.deleteTrade(0);

        assertEq(tradingStorage.getUserActiveTradesCount(alice), numTrades - 1);

        // Verify all remaining trade IDs point to valid trades
        uint256[] memory userTrades = tradingStorage.getUserTrades(alice);
        for (uint256 i; i < userTrades.length; i++) {
            TradingStorage.Trade memory t = tradingStorage.getTrade(userTrades[i]);
            assertEq(t.user, alice);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        INVARIANT HELPERS
    //////////////////////////////////////////////////////////////*/

    function test_Invariant_TradeCounterNeverDecreases() public {
        vm.startPrank(tradingEngine);

        uint32 counter0 = tradingStorage.getTradeCounter();
        _storeTrade(alice);
        uint32 counter1 = tradingStorage.getTradeCounter();
        _storeTrade(bob);
        uint32 counter2 = tradingStorage.getTradeCounter();

        // Delete a trade — counter should NOT decrease
        tradingStorage.deleteTrade(0);
        uint32 counter3 = tradingStorage.getTradeCounter();

        vm.stopPrank();

        assertEq(counter0, 0);
        assertEq(counter1, 1);
        assertEq(counter2, 2);
        assertEq(counter3, 2);
    }

    function test_Invariant_UserTradesConsistency() public {
        vm.startPrank(tradingEngine);
        _storeTrade(alice);
        _storeTrade(alice);
        _storeTrade(alice);

        // Delete middle
        tradingStorage.deleteTrade(1);
        vm.stopPrank();

        // Every tradeId in userTrades should point to a valid trade with that user
        uint256[] memory userTrades = tradingStorage.getUserTrades(alice);
        for (uint256 i; i < userTrades.length; i++) {
            TradingStorage.Trade memory t = tradingStorage.getTrade(userTrades[i]);
            assertEq(t.user, alice);
        }

        // Deleted trade should have zero user
        TradingStorage.Trade memory deleted = tradingStorage.getTrade(1);
        assertEq(deleted.user, address(0));
    }

    function test_Invariant_OIRoundTrip() public {
        vm.startPrank(tradingEngine);

        uint256 oiBefore = tradingStorage.getOpenInterest(0);

        tradingStorage.increaseOpenInterest(0, 5_000 * 1e18);
        tradingStorage.increaseOpenInterest(0, 3_000 * 1e18);
        tradingStorage.decreaseOpenInterest(0, 5_000 * 1e18);
        tradingStorage.decreaseOpenInterest(0, 3_000 * 1e18);

        uint256 oiAfter = tradingStorage.getOpenInterest(0);

        vm.stopPrank();

        assertEq(oiBefore, oiAfter);
        assertEq(oiAfter, 0);
    }
}
