// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RegressionBase} from "./RegressionBase.sol";

/**
 * @title LiquidationRewardRegressionTest
 * @author GushALKDev
 * @notice Round 1 Medium finding: the liquidator reward was 10% of the collateral left after the loss, so
 *         it dropped to zero once the loss reached the collateral and nobody was paid to close the position.
 * @dev Uses only openTrade and liquidate, so it compiles against the pre-fix engine.
 */
contract LiquidationRewardRegressionTest is RegressionBase {
    address alice = makeAddr("alice");
    address liquidator = makeAddr("liquidator");

    uint64 constant COLLATERAL = 100 * 10 ** 6;
    uint16 constant LEVERAGE = 10;

    function setUp() public override {
        super.setUp();
        _fund(alice, COLLATERAL);
    }

    /// @notice Liquidating a long at a 105% loss pays a positive reward out of the position's collateral only
    function test_Regression_LiquidationReward_PositiveAtLossAboveCollateral() public {
        uint32 tradeId = _open(alice, true, COLLATERAL, LEVERAGE);
        uint64 collateral = tradingStorage.getTrade(tradeId).collateral;
        uint128 openPrice = tradingStorage.getTrade(tradeId).openPrice;

        // 10x long: a 10.5% drop of the close execution price is a 105% loss; close spread is 5 bps
        uint128 oracleAtLoss = uint128((uint256(openPrice) * 8950 * 10_000) / (10_000 * 9995));
        mockOracle.setPrice(PAIR, oracleAtLoss);

        uint256 vaultBefore = usdc.balanceOf(address(vault));
        vm.prank(liquidator);
        engine.liquidate(tradeId, EMPTY_UPDATE);

        uint256 reward = usdc.balanceOf(liquidator);
        uint256 toVault = usdc.balanceOf(address(vault)) - vaultBefore;
        emit log_named_decimal_uint("liquidator reward (USDC)", reward, 6);

        assertGt(reward, 0, "no reward for a position past 100% loss");
        assertEq(reward + toVault, collateral, "reward not funded from the position's collateral");
    }
}
