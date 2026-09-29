// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RegressionBase} from "./RegressionBase.sol";
import {FundingLib} from "../../src/libraries/FundingLib.sol";

/**
 * @title PauseFlagsRegression
 * @author GushALKDev
 * @notice Round 3b: a single pause per contract blocked closes but not liquidations, blocked LP withdrawal
 *         requests together with deposits, let pending requests expire while paused, and let funding accrue while
 *         traders could not close. Each contract now has independent flags.
 * @dev The flags are set through setPauseFlags(uint8) with a low-level call; when that function does not exist
 *      (the code before the fix) the helpers fall back to pause() and unpause(), so the file compiles and runs
 *      against both versions. Actions that must work are checked before the one that must revert.
 */
contract PauseFlagsRegressionTest is RegressionBase {
    uint8 constant PAUSE_OPEN = 1;
    uint8 constant PAUSE_SETTLE = 2;
    uint8 constant PAUSE_DEPOSIT = 1;
    uint8 constant PAUSE_WITHDRAW = 2;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address keeper = makeAddr("keeper");

    function _setFlags(address _target, uint8 _flags) internal {
        vm.prank(owner);
        (bool ok,) = _target.call(abi.encodeWithSignature("setPauseFlags(uint8)", _flags));
        if (ok) return;
        vm.prank(owner);
        (ok,) = _target.call(abi.encodeWithSignature(_flags == 0 ? "unpause()" : "pause()"));
        require(ok, "no pause entry point");
    }

    function _movePrice(int256 _bps) internal {
        uint256 price = mockOracle.peekPrice(PAIR);
        mockOracle.setPrice(PAIR, uint128(uint256(int256(price) * (10_000 + _bps) / 10_000)));
    }

    /*//////////////////////////////////////////////////////////////
                              ENGINE
    //////////////////////////////////////////////////////////////*/

    /// @notice With settlement paused, a position whose owner cannot close it cannot be liquidated either
    function test_Regression_Pause_SettleBlocksLiquidation() public {
        _fund(alice, 1_000 * 10 ** 6);
        uint32 tradeId = _open(alice, true, 1_000 * 10 ** 6, 100);
        _movePrice(-200);
        _setFlags(address(engine), PAUSE_SETTLE);

        uint128 price = mockOracle.peekPrice(PAIR);
        vm.prank(alice);
        (bool closed,) = address(engine).call(abi.encodeCall(engine.closeTrade, (tradeId, price, 100, EMPTY_UPDATE)));
        assertFalse(closed, "close went through while settlement is paused");

        vm.prank(keeper);
        (bool liquidated,) = address(engine).call(abi.encodeCall(engine.liquidate, (tradeId, EMPTY_UPDATE)));
        assertFalse(liquidated, "liquidation went through while the owner could not close");
    }

    /// @notice With only openings paused, closes, TP/SL execution and liquidations work and an open reverts
    function test_Regression_Pause_OpenOnlyKeepsSettlementOpen() public {
        _fund(alice, 1_000 * 10 ** 6);
        _fund(bob, 1_000 * 10 ** 6);
        _fund(carol, 2_000 * 10 ** 6);
        uint128 price = mockOracle.peekPrice(PAIR);
        vm.prank(alice);
        uint32 withTp = engine.openTrade(PAIR, true, 1_000 * 10 ** 6, 10, price, 100, (price * 101) / 100, 0, EMPTY_UPDATE);
        uint32 shortTrade = _open(bob, false, 1_000 * 10 ** 6, 100);
        uint32 plain = _open(carol, true, 1_000 * 10 ** 6, 10);
        _movePrice(200);
        _setFlags(address(engine), PAUSE_OPEN);

        _close(carol, plain);
        assertEq(tradingStorage.getTrade(plain).user, address(0), "close did not settle");
        vm.prank(keeper);
        engine.executeLimit(withTp, EMPTY_UPDATE);
        assertEq(tradingStorage.getTrade(withTp).user, address(0), "TP not executed");
        vm.prank(keeper);
        engine.liquidate(shortTrade, EMPTY_UPDATE);
        assertEq(tradingStorage.getTrade(shortTrade).user, address(0), "liquidation did not settle");

        price = mockOracle.peekPrice(PAIR);
        vm.prank(carol);
        (bool opened,) = address(engine).call(abi.encodeCall(engine.openTrade, (PAIR, true, 1_000 * 10 ** 6, 10, price, 100, 0, 0, EMPTY_UPDATE)));
        assertFalse(opened, "open went through while openings are paused");
    }

    /// @notice No funding accrues while settlement is paused: after the pause only the hour before it counts
    function test_Regression_Pause_SettleFreezesFunding() public {
        _fund(alice, 10_000 * 10 ** 6);
        _fund(bob, 1_000 * 10 ** 6);
        _open(alice, true, 10_000 * 10 ** 6, 10);
        uint32 bobTrade = _open(bob, false, 1_000 * 10 ** 6, 10);
        uint256 oiLong = tradingStorage.getOpenInterestLong(PAIR);
        uint256 oiShort = tradingStorage.getOpenInterestShort(PAIR);
        (int256 expectedLong,) = FundingLib.calculateIndexDeltas(oiLong, oiShort, 1 hours, engine.fundingFactor());
        int256 indexBefore = tradingStorage.getCumulativeFundingIndex(PAIR, true);

        vm.warp(block.timestamp + 1 hours);
        _setFlags(address(engine), PAUSE_SETTLE);
        vm.warp(block.timestamp + 10 days);
        _setFlags(address(engine), 0);
        _close(bob, bobTrade);

        assertEq(tradingStorage.getCumulativeFundingIndex(PAIR, true) - indexBefore, expectedLong, "funding accrued while settlement was paused");
    }

    /*//////////////////////////////////////////////////////////////
                               VAULT
    //////////////////////////////////////////////////////////////*/

    /// @notice With only deposits paused, an LP can request and execute a withdrawal
    function test_Regression_Pause_DepositOnlyKeepsWithdrawalsOpen() public {
        _setFlags(address(vault), PAUSE_DEPOSIT);
        uint256 shares = vault.balanceOf(lp) / 10;

        vm.prank(lp);
        vault.requestWithdrawal(shares);
        vm.warp(block.timestamp + 3 * vault.EPOCH_LENGTH());
        uint256 before = usdc.balanceOf(lp);
        vm.prank(lp);
        vault.executeWithdrawal();
        assertGt(usdc.balanceOf(lp), before, "withdrawal paid nothing");

        usdc.mint(lp, 1_000 * 10 ** 6);
        vm.prank(lp);
        (bool deposited,) = address(vault).call(abi.encodeCall(vault.deposit, (1_000 * 10 ** 6, lp)));
        assertFalse(deposited, "deposit went through while deposits are paused");
    }

    /// @notice A request pending when withdrawals are paused, paused for longer than the execution window, can be executed after
    function test_Regression_Pause_WithdrawPauseDoesNotExpireRequest() public {
        uint256 shares = vault.balanceOf(lp) / 10;
        vm.prank(lp);
        vault.requestWithdrawal(shares);
        vm.warp(block.timestamp + 3 * vault.EPOCH_LENGTH());

        _setFlags(address(vault), PAUSE_WITHDRAW);
        vm.warp(block.timestamp + 2 * vault.EPOCH_LENGTH());
        _setFlags(address(vault), 0);

        uint256 before = usdc.balanceOf(lp);
        vm.prank(lp);
        vault.executeWithdrawal();
        assertGt(usdc.balanceOf(lp), before, "withdrawal paid nothing");
    }
}
