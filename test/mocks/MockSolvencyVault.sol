// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title MockSolvencyVault
 * @notice Stands in for the Vault where BondDepository reads collateralizationDeficit and receives USDC.
 * @dev The deficit defaults to a value no test round reaches, so bonds are bounded by the round cap only
 *      unless a test sets it.
 */
contract MockSolvencyVault {
    uint256 public collateralizationDeficit = type(uint128).max;

    function setDeficit(uint256 _deficit) external {
        collateralizationDeficit = _deficit;
    }
}
