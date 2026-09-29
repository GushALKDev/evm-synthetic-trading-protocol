// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ProtocolInvariantTest} from "./Protocol.invariant.t.sol";

/**
 * @title ProtocolKeeperLatencyInvariantTest
 * @author GushALKDev
 * @notice The protocol invariants with a slow keeper: the handler liquidates a position only one day after it
 *         first sees it liquidatable, so positions can pass 100% loss before liquidation and the snapshot's
 *         conservativeness bound is checked with a nonzero excess loss E.
 * @dev Every pair starts with a 1,000 USDC 100x long and a 1,000 USDC 100x short without TP or SL, so any 1% move
 *      puts one side past 100% loss. afterInvariant logs the refreshes with E > 0 and the largest E of the last
 *      run of each campaign.
 */
contract ProtocolKeeperLatencyInvariantTest is ProtocolInvariantTest {
    function _keeperLatency() internal pure override returns (uint256) {
        return 1 days;
    }

    function _seedPositions() internal override {
        for (uint256 pair; pair < handler.PAIRS(); ++pair) {
            handler.openTrade(0, pair, 1_000 * 10 ** 6, 100, true, 0, 0);
            handler.openTrade(1, pair, 1_000 * 10 ** 6, 100, false, 0, 0);
        }
    }
}
