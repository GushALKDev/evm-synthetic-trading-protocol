// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title ISolvencyVault
 * @notice Minimal Vault interface the SolvencyManager reads to assess collateralization
 */
interface ISolvencyVault {
    function totalAssets() external view returns (uint256);

    function collateralizationRatio() external view returns (uint256);

    function collateralizationDeficit() external view returns (uint256);
}

/**
 * @title IAssistantFund
 * @notice Minimal AssistantFund interface the SolvencyManager calls to inject reserve USDC
 */
interface IAssistantFund {
    function balance() external view returns (uint256);

    function injectFunds(uint256 amount) external;
}

/**
 * @title IBondDepository
 * @notice Minimal BondDepository interface the SolvencyManager calls to open a bonding round
 */
interface IBondDepository {
    function isActive() external view returns (bool);

    function activateBonding(uint256 neededUsdc) external;
}
