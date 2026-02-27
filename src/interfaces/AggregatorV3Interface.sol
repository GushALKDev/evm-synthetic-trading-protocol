// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title AggregatorV3Interface
 * @notice Minimal Chainlink AggregatorV3 interface used by PythChainlinkOracle as deviation anchor.
 */
interface AggregatorV3Interface {
    /// @notice Number of decimals in the price answer (typically 8)
    function decimals() external view returns (uint8);

    /// @notice Get data from the latest completed round
    /// @return roundId The round ID
    /// @return answer The price answer
    /// @return startedAt Timestamp when the round started
    /// @return updatedAt Timestamp when the answer was last updated
    /// @return answeredInRound Deprecated — included for interface compatibility
    function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
