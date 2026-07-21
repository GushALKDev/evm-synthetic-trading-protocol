// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";
import {ISolvencyVault, IAssistantFund, IBondDepository} from "./interfaces/ISolvency.sol";

/**
 * @title SolvencyManager
 * @author GushALKDev
 * @notice Orchestrates the protocol's solvency response: reads the Vault collateralization ratio and,
 *         when it drops, recapitalizes it — first from the AssistantFund reserve (Layer 2), then via
 *         the BondDepository (Layer 3) when the reserve is insufficient and the deficit is critical.
 * @dev The response targets bringing the Vault back to DEFICIT_CR (100%). `checkAndAct` is
 *      permissionless so a keeper or arbitrageur can trigger it. The manager holds no funds; it only
 *      routes calls to the AssistantFund and BondDepository, which enforce their own access control
 *      (both are pointed at this contract as their solvencyManager).
 *      Thresholds (WAD): CR >= SAFE_CR healthy, DEFICIT_CR <= CR < SAFE_CR warning (no action),
 *      CRITICAL_CR <= CR < DEFICIT_CR inject reserve, CR < CRITICAL_CR activate bonding.
 */
contract SolvencyManager is Ownable {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant WAD = 1e18;
    uint256 public constant SAFE_CR = 110e16; // 110%
    uint256 public constant DEFICIT_CR = 100e16; // 100% (recapitalization target)
    uint256 public constant CRITICAL_CR = 95e16; // 95%

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    ISolvencyVault public immutable VAULT;
    IAssistantFund public immutable ASSISTANT_FUND;
    IBondDepository public immutable BOND_DEPOSITORY;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Healthy(uint256 cr);
    event Warning(uint256 cr);
    event ReserveInjected(uint256 cr, uint256 amount);
    event BondingTriggered(uint256 cr, uint256 neededUsdc);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _vault, address _assistantFund, address _bondDepository, address _owner) {
        if (_vault == address(0) || _assistantFund == address(0) || _bondDepository == address(0)) {
            revert ZeroAddress();
        }
        _initializeOwner(_owner);
        VAULT = ISolvencyVault(_vault);
        ASSISTANT_FUND = IAssistantFund(_assistantFund);
        BOND_DEPOSITORY = IBondDepository(_bondDepository);
    }

    /*//////////////////////////////////////////////////////////////
                            CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Assess the Vault CR and act to recapitalize it if under-collateralized
     * @dev Permissionless. Injects from the AssistantFund reserve first; if the reserve cannot fully
     *      cover the deficit and the CR is critical, opens a bonding round for the shortfall. The
     *      deficit is the USDC needed to restore the Vault to DEFICIT_CR (100%).
     */
    function checkAndAct() external {
        uint256 cr = VAULT.collateralizationRatio();

        if (cr >= SAFE_CR) {
            emit Healthy(cr);
            return;
        }
        if (cr >= DEFICIT_CR) {
            emit Warning(cr);
            return;
        }

        uint256 deficit = _deficitToTarget(cr);

        // Layer 2: inject whatever the reserve can cover, up to the deficit
        uint256 reserve = ASSISTANT_FUND.balance();
        uint256 injected = reserve < deficit ? reserve : deficit;
        if (injected != 0) {
            ASSISTANT_FUND.injectFunds(injected);
            emit ReserveInjected(cr, injected);
        }

        // Layer 3: if a critical shortfall remains, activate bonding for it
        uint256 shortfall = deficit - injected;
        if (cr < CRITICAL_CR && shortfall != 0 && !BOND_DEPOSITORY.isActive()) {
            BOND_DEPOSITORY.activateBonding(shortfall);
            emit BondingTriggered(cr, shortfall);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice USDC needed to restore the Vault from its current CR back to DEFICIT_CR (100%)
     * @dev Since totalAssets = nominalLiabilities * cr / WAD, the shortfall to reach 100% is
     *      totalAssets * (WAD - cr) / cr. Returns 0 when the Vault is already at or above 100%.
     * @return deficit USDC amount (6 decimals) required to reach 100% collateralization
     */
    function deficitToTarget() external view returns (uint256 deficit) {
        uint256 cr = VAULT.collateralizationRatio();
        if (cr >= DEFICIT_CR) return 0;
        return _deficitToTarget(cr);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _deficitToTarget(uint256 _cr) internal view returns (uint256) {
        // _cr is guaranteed < DEFICIT_CR (< WAD) by callers, so cr != 0 as long as totalSupply > 0
        return (VAULT.totalAssets() * (DEFICIT_CR - _cr)) / _cr;
    }
}
