// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title MockChainlinkFeed
 * @notice Minimal Chainlink aggregator mock for OracleAggregator tests
 */
contract MockChainlinkFeed {
    int256 private _answer;
    uint256 private _updatedAt;
    uint8 private _decimals;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
        _updatedAt = block.timestamp;
    }

    function setAnswer(int256 answer) external {
        _answer = answer;
    }

    function setUpdatedAt(uint256 updatedAt) external {
        _updatedAt = updatedAt;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, _answer, block.timestamp, _updatedAt, 1);
    }
}
