// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title ISolvencyVault
 * @notice Minimal Vault interface the SolvencyManager and BondDepository read to assess collateralization
 * @dev collateralizationRatio/Deficit use the conservative NAV (balance minus unrealised trader profit from the
 *      PnL snapshot); the realised variants use the USDC balance only.
 */
interface ISolvencyVault {
    function totalAssets() external view returns (uint256);

    function collateralizationRatio() external view returns (uint256);

    function collateralizationDeficit() external view returns (uint256);

    function realisedCollateralizationRatio() external view returns (uint256);

    function realisedCollateralizationDeficit() external view returns (uint256);

    function isPnlSnapshotFresh() external view returns (bool);

    function refreshPnlSnapshot(bytes[] calldata priceUpdate) external payable;
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

    function closeBonding() external;
}
