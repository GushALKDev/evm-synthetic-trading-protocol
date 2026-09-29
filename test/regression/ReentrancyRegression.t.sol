// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RegressionBase} from "./RegressionBase.sol";
import {TradingEngine} from "../../src/TradingEngine.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

/**
 * @title ReentrantTrader
 * @notice Trader contract whose receive() re-enters the engine when the ETH refund arrives
 * @dev It never reverts from receive(), so the outer call completes and the test can read what the
 *      nested call did: `reentered` is true only if the nested call succeeded.
 */
contract ReentrantTrader {
    enum Target {
        None,
        UpdateTp,
        UpdateSl,
        CloseTrade,
        OpenTrade
    }

    TradingEngine public immutable ENGINE;
    Target public target;
    uint256 public tradeId;
    uint128 public price;
    bool public reentered;
    bytes public reentryError;
    bytes[] internal empty;

    constructor(TradingEngine _engine, ERC20 _usdc) {
        ENGINE = _engine;
        _usdc.approve(address(_engine), type(uint256).max);
    }

    function arm(Target _target, uint256 _tradeId, uint128 _price) external {
        target = _target;
        tradeId = _tradeId;
        price = _price;
    }

    function open(uint128 _price) external payable returns (uint32) {
        return ENGINE.openTrade{value: msg.value}(0, true, 100 * 10 ** 6, 10, _price, 100, 0, 0, empty);
    }

    function updateTp(uint256 _tradeId, uint128 _tp) external payable {
        ENGINE.updateTp{value: msg.value}(_tradeId, _tp, empty);
    }

    function updateSl(uint256 _tradeId, uint128 _sl) external payable {
        ENGINE.updateSl{value: msg.value}(_tradeId, _sl, empty);
    }

    function close(uint256 _tradeId, uint128 _price) external payable {
        ENGINE.closeTrade{value: msg.value}(_tradeId, _price, 100, empty);
    }

    receive() external payable {
        Target current = target;
        if (current == Target.None) return;
        target = Target.None; // one nested attempt per refund

        bytes memory data;
        if (current == Target.UpdateTp) data = abi.encodeCall(TradingEngine.updateTp, (tradeId, price, empty));
        else if (current == Target.UpdateSl) data = abi.encodeCall(TradingEngine.updateSl, (tradeId, price, empty));
        else if (current == Target.CloseTrade) data = abi.encodeCall(TradingEngine.closeTrade, (tradeId, price, 100, empty));
        else data = abi.encodeCall(TradingEngine.openTrade, (0, true, 100 * 10 ** 6, 10, price, 100, 0, 0, empty));

        (bool ok, bytes memory ret) = address(ENGINE).call(data);
        reentered = ok;
        if (!ok) reentryError = ret;
    }
}

/**
 * @title ReentrancyRegressionTest
 * @author GushALKDev
 * @notice Round 1 finding: updateTp and updateSl call the oracle and refund ETH to the caller without
 *         nonReentrant. These tests re-enter through the ETH refund of every refunding entry point.
 */
contract ReentrancyRegressionTest is RegressionBase {
    ReentrantTrader trader;
    uint32 tradeId;
    uint128 constant TP = 55_000 * 1e18;
    uint128 constant SL = 45_000 * 1e18;

    function setUp() public override {
        super.setUp();
        trader = new ReentrantTrader(engine, usdc);
        usdc.mint(address(trader), 1_000 * 10 ** 6);
        vm.deal(address(this), 10 ether);
        tradeId = trader.open(ORACLE_PRICE);
    }

    function test_Regression_Reentrancy_UpdateTpDuringUpdateSlRefund() public {
        trader.arm(ReentrantTrader.Target.UpdateTp, tradeId, TP);
        trader.updateSl{value: 0.1 ether}(tradeId, SL);
        _assertBlocked();
        assertEq(tradingStorage.getTrade(tradeId).tp, 0, "nested updateTp took effect");
    }

    function test_Regression_Reentrancy_UpdateSlDuringUpdateTpRefund() public {
        trader.arm(ReentrantTrader.Target.UpdateSl, tradeId, SL);
        trader.updateTp{value: 0.1 ether}(tradeId, TP);
        _assertBlocked();
        assertEq(tradingStorage.getTrade(tradeId).sl, 0, "nested updateSl took effect");
    }

    function test_Reentrancy_CloseTradeDuringCloseRefund() public {
        uint32 secondId = trader.open(ORACLE_PRICE);
        trader.arm(ReentrantTrader.Target.CloseTrade, secondId, mockOracle.peekPrice(PAIR));
        trader.close{value: 0.1 ether}(tradeId, mockOracle.peekPrice(PAIR));
        _assertBlocked();
        assertEq(tradingStorage.getTrade(secondId).user, address(trader), "nested close took effect");
    }

    function test_Reentrancy_OpenTradeDuringOpenRefund() public {
        uint32 counterBefore = tradingStorage.getTradeCounter();
        trader.arm(ReentrantTrader.Target.OpenTrade, 0, ORACLE_PRICE);
        trader.open{value: 0.1 ether}(ORACLE_PRICE);
        _assertBlocked();
        assertEq(tradingStorage.getTradeCounter(), counterBefore + 1, "nested open took effect");
    }

    function _assertBlocked() internal view {
        assertFalse(trader.reentered(), "nested call succeeded");
        assertEq(bytes4(trader.reentryError()), ReentrancyGuard.Reentrancy.selector, "nested call not stopped by the guard");
    }
}
