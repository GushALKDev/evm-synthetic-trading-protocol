// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IOracle
 * @notice Technology-agnostic oracle interface for the Synthetic Trading Protocol.
 *         The protocol uses PythChainlinkOracle (Pyth pull prices anchored to Chainlink); another
 *         implementation, pull- or push-based, can replace it by deploying a new contract and pointing
 *         TradingEngine at it. A custom oracle network was considered early on and dropped.
 * @dev `priceData` is opaque calldata for pull-based oracles (e.g. Pyth signed updates).
 *      Push-based oracles can ignore it. The caller funds any required fee via msg.value;
 *      the oracle refunds the surplus to msg.sender.
 */
interface IOracle {
    /**
     * @notice Get a validated price for a trading pair, together with its confidence band
     * @dev conf18 is the price uncertainty (publisher disagreement for Pyth) normalized to 18 decimals.
     *      Push-based oracles that do not expose a confidence interval should return conf18 = 0.
     *      Callers use conf18 for conservative pricing (e.g. liquidation checks): the trader-favorable
     *      band edge — price + conf for longs, price - conf for shorts — to avoid unfair liquidation
     *      during volatility.
     * @param pairIndex The pair index to get price for
     * @param priceData Opaque price update data (used by pull-based oracles, ignored by push-based)
     * @return price18 Validated price normalized to 18 decimals
     * @return conf18 Confidence band (price uncertainty) normalized to 18 decimals
     */
    function getPrice(uint256 pairIndex, bytes[] calldata priceData) external payable returns (uint128 price18, uint128 conf18);

    /**
     * @notice Revert when conditions outside the price itself do not allow opening new positions
     * @dev Called by TradingEngine.openTrade only. PythChainlinkOracle reverts here during the grace period after
     *      the L2 sequencer comes back up; getPrice keeps serving closes, liquidations and the vault meanwhile.
     *      Oracles without such a condition implement it as a no-op.
     */
    function checkOpenAllowed() external view;
}
