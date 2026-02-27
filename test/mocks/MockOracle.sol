// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IOracle} from "../../src/interfaces/IOracle.sol";

/**
 * @title MockOracle
 * @notice Simplified IOracle mock for TradingEngine tests — returns preset prices without Pyth encoding
 */
contract MockOracle is IOracle {
    mapping(uint256 => uint128) private _prices;

    function setPrice(uint256 pairIndex, uint128 price) external {
        _prices[pairIndex] = price;
    }

    function getPrice(uint256 pairIndex, bytes[] calldata) external returns (uint128) {
        return _prices[pairIndex];
    }
}
