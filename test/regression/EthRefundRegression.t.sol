// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RegressionBase} from "./RegressionBase.sol";

/**
 * @title EthRefundRegressionTest
 * @author GushALKDev
 * @notice Round 1 finding: _refundEth swept the engine's whole ETH balance to the caller, so ETH force-sent
 *         to the engine (selfdestruct or a coinbase payment, which bypass receive) went to the next caller.
 *         The refund is now limited to msg.value minus the oracle fee actually paid.
 * @dev vm.deal sets the engine balance without a call, which is what force-sent ETH looks like.
 */
contract EthRefundRegressionTest is RegressionBase {
    address alice = makeAddr("alice");

    uint256 constant FORCED_ETH = 1 ether;
    uint256 constant ORACLE_FEE = 0.01 ether;
    uint256 constant SENT = 0.1 ether;

    function setUp() public override {
        super.setUp();
        _fund(alice, 1_000 * 10 ** 6);
        vm.deal(alice, 1 ether);
        mockOracle.setFee(ORACLE_FEE);
    }

    function test_Regression_EthRefund_OpenDoesNotPayOutForcedEth() public {
        vm.deal(address(engine), FORCED_ETH);
        uint128 price = mockOracle.peekPrice(PAIR);
        uint256 aliceBefore = alice.balance;

        vm.prank(alice);
        engine.openTrade{value: SENT}(PAIR, true, 100 * 10 ** 6, 10, price, 100, 0, 0, EMPTY_UPDATE);

        assertEq(alice.balance, aliceBefore - ORACLE_FEE, "caller did not pay exactly the oracle fee");
        assertEq(address(engine).balance, FORCED_ETH, "forced ETH left the engine");
    }

    /// @notice updateTp with a zero TP makes no oracle call, so the whole msg.value comes back
    function test_Regression_EthRefund_NoOracleCallRefundsMsgValueOnly() public {
        uint128 price = mockOracle.peekPrice(PAIR);
        vm.prank(alice);
        uint32 tradeId = engine.openTrade{value: ORACLE_FEE}(PAIR, true, 100 * 10 ** 6, 10, price, 100, 0, 0, EMPTY_UPDATE);
        vm.deal(address(engine), FORCED_ETH);
        uint256 aliceBefore = alice.balance;

        vm.prank(alice);
        engine.updateTp{value: SENT}(tradeId, 0, EMPTY_UPDATE);

        assertEq(alice.balance, aliceBefore, "msg.value not refunded in full");
        assertEq(address(engine).balance, FORCED_ETH, "forced ETH left the engine");
    }
}
