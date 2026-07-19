// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/**
 * @title AssistantFund
 * @author GushALKDev
 * @notice Layer 2 of the solvency system: a USDC reserve that accumulates a share of trading fees
 *         and can be injected into the Vault to cover deficits without diluting the governance token.
 * @dev Fees arrive as plain USDC transfers (the TradingEngine treasury is pointed at this contract),
 *      so there is no per-transfer hook. Overflow above targetCap is skimmed to the Vault lazily via
 *      the permissionless skim(). Injection into the Vault is restricted to the SolvencyManager
 *      (Phase 10); until it is deployed, the owner sets the address via setSolvencyManager.
 */
contract AssistantFund is Ownable {
    using SafeTransferLib for address;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public immutable ASSET; // USDC (6 decimals)
    address public immutable VAULT;

    address public solvencyManager;
    uint256 public targetCap;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event FundsInjected(uint256 amount);
    event Skimmed(uint256 amount);
    event SolvencyManagerUpdated(address indexed newSolvencyManager);
    event TargetCapUpdated(uint256 newTargetCap);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error CallerNotSolvencyManager();
    error SolvencyManagerNotSet();
    error InsufficientFunds(uint256 requested, uint256 available);

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlySolvencyManager() {
        _requireSolvencyManager();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _requireSolvencyManager() internal view {
        if (solvencyManager == address(0)) revert SolvencyManagerNotSet();
        if (msg.sender != solvencyManager) revert CallerNotSolvencyManager();
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _asset, address _vault, uint256 _targetCap, address _owner) {
        if (_asset == address(0) || _vault == address(0)) revert ZeroAddress();
        _initializeOwner(_owner);
        ASSET = _asset;
        VAULT = _vault;
        targetCap = _targetCap;
    }

    /*//////////////////////////////////////////////////////////////
                            CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Inject reserve USDC into the Vault to cover a deficit
     * @dev Only the SolvencyManager may call. Reverts if the fund holds less than requested.
     * @param _amount USDC amount to inject into the Vault
     */
    function injectFunds(uint256 _amount) external onlySolvencyManager {
        uint256 available = balance();
        if (_amount > available) revert InsufficientFunds(_amount, available);

        ASSET.safeTransfer(VAULT, _amount);
        emit FundsInjected(_amount);
    }

    /**
     * @notice Send any reserve above targetCap to the Vault (LPs)
     * @dev Permissionless: anyone (or a keeper) can trigger the skim. No-op when balance <= targetCap.
     *      Keeps the reserve from over-accumulating fees at the LPs' expense.
     * @return skimmed The amount transferred to the Vault (0 if under cap)
     */
    function skim() external returns (uint256 skimmed) {
        uint256 bal = balance();
        if (bal <= targetCap) return 0;

        skimmed = bal - targetCap;
        ASSET.safeTransfer(VAULT, skimmed);
        emit Skimmed(skimmed);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Current USDC balance held by the fund
     */
    function balance() public view returns (uint256) {
        return SafeTransferLib.balanceOf(ASSET, address(this));
    }

    /**
     * @notice Whether the reserve has reached its target cap
     */
    function isFunded() external view returns (bool) {
        return balance() >= targetCap;
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set the SolvencyManager allowed to inject funds (Phase 10 orchestrator)
     * @param _solvencyManager The SolvencyManager address
     */
    function setSolvencyManager(address _solvencyManager) external onlyOwner {
        if (_solvencyManager == address(0)) revert ZeroAddress();
        solvencyManager = _solvencyManager;
        emit SolvencyManagerUpdated(_solvencyManager);
    }

    /**
     * @notice Set the reserve target cap; overflow above it is skimmable to the Vault
     * @param _targetCap New target cap in USDC (6 decimals)
     */
    function setTargetCap(uint256 _targetCap) external onlyOwner {
        targetCap = _targetCap;
        emit TargetCapUpdated(_targetCap);
    }
}
