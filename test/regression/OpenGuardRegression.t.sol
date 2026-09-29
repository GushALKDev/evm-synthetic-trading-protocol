// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RegressionBase} from "./RegressionBase.sol";
import {TradingEngine} from "../../src/TradingEngine.sol";
import {SpreadManager} from "../../src/SpreadManager.sol";

/**
 * @title OpenGuardRegressionTest
 * @author GushALKDev
 * @notice Round 1 Low finding: the opening guard measured the instant loss with the open spread only and
 *         against the gross collateral, while liquidation uses the close spread and the collateral net of
 *         the open fee. At 50 bps spread and 100x a position opened straight into the liquidation zone.
 * @dev Every test only uses openTrade and liquidate, so it compiles against the pre-fix engine too.
 */
contract OpenGuardRegressionTest is RegressionBase {
    address alice = makeAddr("alice");
    address liquidator = makeAddr("liquidator");

    function setUp() public override {
        super.setUp();
        _fund(alice, 1_000_000 * 10 ** 6);
    }

    /// @notice Round 1 PoC: 50 bps spread, 100x long, liquidatable in the same block at the same price
    function test_Regression_OpenGuard_RejectsPositionLiquidatableInSameBlock() public {
        mockSpreadManager.setSpreadBps(50);
        uint128 price = mockOracle.peekPrice(PAIR);

        vm.prank(alice);
        vm.expectPartialRevert(TradingEngine.NotLiquidatable.selector);
        engine.openTrade(PAIR, true, 100 * 10 ** 6, 100, price, 100, 0, 0, EMPTY_UPDATE);
    }

    /**
     * @notice Property: no position that opens can be liquidated in the same block at an unchanged price
     * @dev Covers both directions, the whole leverage range and spreads up to 1%.
     */
    function testFuzz_Regression_OpenGuard_NoSameBlockLiquidation(uint256 _spreadBps, uint256 _leverage, uint256 _collateral, bool _isLong) public {
        mockSpreadManager.setSpreadBps(bound(_spreadBps, 0, 100));
        uint16 leverage = uint16(bound(_leverage, 1, 100));
        uint64 collateral = uint64(bound(_collateral, 10 * 10 ** 6, 100_000 * 10 ** 6));
        uint128 price = mockOracle.peekPrice(PAIR);

        vm.prank(alice);
        try engine.openTrade(PAIR, _isLong, collateral, leverage, price, 10_000, 0, 0, EMPTY_UPDATE) returns (uint32 tradeId) {
            vm.prank(liquidator);
            try engine.liquidate(tradeId, EMPTY_UPDATE) {
                fail("position opened straight into the liquidation zone");
            } catch (bytes memory reason) {
                assertEq(bytes4(reason), TradingEngine.NotLiquidatable.selector, "unexpected liquidation revert");
            }
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), TradingEngine.NotLiquidatable.selector, "open rejected for another reason");
        }
    }

    /**
     * @notice The close spread is measured at the OI after the open, which includes the new position
     * @dev With impactFactor 1e11 a 920 USD position adds 92 bps to the spread: 5 bps to open, 97 bps to close.
     */
    function test_Regression_OpenGuard_UsesPostOpenOIForCloseSpread() public {
        SpreadManager spreadManager = new SpreadManager(5, 1e11, 0, 100, 5000, owner, owner);
        vm.startPrank(owner);
        TradingEngine impactEngine =
            new TradingEngine(address(tradingStorage), address(vault), address(mockOracle), address(usdc), treasuryAddr, address(spreadManager), owner);
        tradingStorage.setTradingEngine(address(impactEngine));
        vault.setTradingEngine(address(impactEngine));
        vm.stopPrank();

        vm.prank(alice);
        usdc.approve(address(impactEngine), type(uint256).max);
        uint128 price = mockOracle.peekPrice(PAIR);

        vm.prank(alice);
        vm.expectPartialRevert(TradingEngine.NotLiquidatable.selector);
        impactEngine.openTrade(PAIR, true, 10 * 10 ** 6, 100, price, 10_000, 0, 0, EMPTY_UPDATE);
    }
}
