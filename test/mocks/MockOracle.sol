// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IOracle} from "../../src/interfaces/IOracle.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/**
 * @title MockOracle
 * @notice Simplified IOracle mock for TradingEngine tests — returns preset prices without Pyth encoding.
 *         Charges a configurable fee (default 0) from msg.value and refunds the surplus, mirroring the
 *         real oracle's payable fee flow.
 */
contract MockOracle is IOracle {
    using SafeTransferLib for address;

    error OracleUnavailable();

    mapping(uint256 => uint128) private _prices;
    mapping(uint256 => uint128) private _confs;
    uint256 public fee;
    bool public shouldRevert;

    function setPrice(uint256 pairIndex, uint128 price) external {
        _prices[pairIndex] = price;
    }

    function setConf(uint256 pairIndex, uint128 conf) external {
        _confs[pairIndex] = conf;
    }

    function setFee(uint256 _fee) external {
        fee = _fee;
    }

    /// @notice Simulate an oracle outage (stale/deviation) so getPrice reverts, like the real oracle.
    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function getPrice(uint256 pairIndex, bytes[] calldata) external payable returns (uint128, uint128) {
        if (shouldRevert) revert OracleUnavailable();
        uint256 surplus = msg.value - fee;
        if (surplus > 0) msg.sender.safeTransferETH(surplus);
        return (_prices[pairIndex], _confs[pairIndex]);
    }
}
