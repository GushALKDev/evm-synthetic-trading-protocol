// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IOracle
 * @notice Technology-agnostic oracle interface for the Synthetic Trading Protocol.
 *         Any oracle implementation (Pyth+Chainlink, Chainlink-only, custom DON, etc.)
 *         conforms to this interface. Swapping providers = deploy new contract + update address.
 * @dev `priceData` is opaque calldata for pull-based oracles (e.g. Pyth signed updates).
 *      Push-based oracles can ignore it. The oracle pays any required fees from its own balance.
 */
interface IOracle {
    /**
     * @notice Get a validated price for a trading pair
     * @param pairIndex The pair index to get price for
     * @param priceData Opaque price update data (used by pull-based oracles, ignored by push-based)
     * @return price18 Validated price normalized to 18 decimals
     */
    function getPrice(uint256 pairIndex, bytes[] calldata priceData) external returns (uint128 price18);
}
