// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title ISynthToken
 * @notice Minimal interface the BondDepository needs from the $SYNTH governance token
 */
interface ISynthToken {
    function mint(address to, uint256 amount) external;
}
