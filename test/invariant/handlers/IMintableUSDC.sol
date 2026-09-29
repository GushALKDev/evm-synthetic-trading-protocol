// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IMintableUSDC
 * @notice Mint function of the suite's MockUSDC. The handlers mint instead of calling StdCheats.deal, whose
 *         stdStorage code pushed ProtocolHandler over the EIP-170 limit that forge build --sizes (run in CI) checks.
 */
interface IMintableUSDC {
    function mint(address to, uint256 amount) external;
}
