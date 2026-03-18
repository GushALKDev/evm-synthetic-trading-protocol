// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title MockSpreadManager
 * @notice Simplified SpreadManager mock for TradingEngine tests — returns preset spread BPS
 */
contract MockSpreadManager {
    uint256 private _spreadBps;

    constructor(uint256 spreadBps_) {
        _spreadBps = spreadBps_;
    }

    function setSpreadBps(uint256 spreadBps_) external {
        _spreadBps = spreadBps_;
    }

    function getSpreadBps(uint256, uint256) external view returns (uint256) {
        return _spreadBps;
    }
}
