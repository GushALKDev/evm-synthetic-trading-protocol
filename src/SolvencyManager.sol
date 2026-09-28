// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ISolvencyVault, IAssistantFund, IBondDepository} from "./interfaces/ISolvency.sol";

/**
 * @title SolvencyManager
 * @author GushALKDev
 * @notice Orchestrates the protocol's solvency response: reads the Vault ratios and, when they drop,
 *         recapitalizes the Vault, first from the AssistantFund reserve (Layer 2), then via the BondDepository
 *         (Layer 3) when the reserve is insufficient and the realised deficit is critical.
 * @dev Two ratios (WAD, 1e18 == 100%):
 *        NAV ratio (collateralizationRatio): conservative NAV per share against 1.0, with unrealised trader
 *        profit from the Vault's PnL snapshot subtracted. Drives the reserve injection, and only while the
 *        snapshot is fresh.
 *        Realised ratio (realisedCollateralizationRatio): USDC balance per share against 1.0, open PnL
 *        ignored. Drives bonding (open, size and close), so $SYNTH is not sold at a discount for an
 *        unrealised move that can reverse.
 *      The realised ratio is always at least the NAV ratio (NAV = balance minus a non-negative liability), so
 *      at a NAV ratio of 100% or more neither layer has anything to do.
 *      Thresholds: NAV ratio >= SAFE_CR healthy, DEFICIT_CR <= NAV ratio < SAFE_CR warning (no action),
 *      NAV ratio < DEFICIT_CR inject reserve up to the NAV deficit; realised ratio < CRITICAL_CR activate
 *      bonding for the realised deficit left after the injection. At a realised ratio >= DEFICIT_CR an open
 *      round is closed: bond() is clamped to the realised deficit, so the round has nothing left to raise.
 *      checkAndAct and refreshAndCheckAndAct are permissionless. The manager holds no funds; it routes calls
 *      to the AssistantFund and BondDepository, which enforce their own access control.
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
    event BondingClosed(uint256 cr);
    event ReserveInjectionSkipped(uint256 cr);

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

    /**
     * @dev Accept the Vault's refund of the oracle fee surplus
     */
    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                            CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Assess the Vault ratios and act to recapitalize it if under-collateralized
     * @dev Permissionless. With a stale PnL snapshot the injection is skipped (ReserveInjectionSkipped) and
     *      bonding still runs on the realised ratio; refreshAndCheckAndAct refreshes the snapshot first.
     */
    function checkAndAct() external {
        _checkAndAct();
    }

    /**
     * @notice Refresh the Vault's PnL snapshot, then run checkAndAct
     * @dev msg.value funds the oracle fee; the Vault refunds the surplus here and it is passed on to the caller.
     * @param priceUpdate Pyth update data for every pair with open interest
     */
    function refreshAndCheckAndAct(bytes[] calldata priceUpdate) external payable {
        uint256 baseline = address(this).balance - msg.value;
        VAULT.refreshPnlSnapshot{value: msg.value}(priceUpdate);
        _checkAndAct();
        uint256 surplus = address(this).balance - baseline;
        if (surplus > 0) SafeTransferLib.safeTransferETH(msg.sender, surplus);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice USDC needed to restore the Vault from its current NAV ratio back to DEFICIT_CR (100%)
     * @dev The injection target. Returns 0 when the NAV ratio is already at or above 100%.
     * @return deficit USDC amount (6 decimals) required to reach 100% collateralization
     */
    function deficitToTarget() external view returns (uint256 deficit) {
        return _deficitToTarget();
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _checkAndAct() internal {
        uint256 realisedCr = VAULT.realisedCollateralizationRatio();
        if (realisedCr >= DEFICIT_CR && BOND_DEPOSITORY.isActive()) {
            BOND_DEPOSITORY.closeBonding();
            emit BondingClosed(realisedCr);
        }

        // realisedCr >= cr, so these early returns never skip a bonding the realised ratio would need
        uint256 cr = VAULT.collateralizationRatio();
        if (cr >= SAFE_CR) {
            emit Healthy(cr);
            return;
        }
        if (cr >= DEFICIT_CR) {
            emit Warning(cr);
            return;
        }

        // Layer 2: inject whatever the reserve can cover, up to the NAV deficit, only on a fresh snapshot
        if (VAULT.isPnlSnapshotFresh()) {
            uint256 deficit = _deficitToTarget();
            uint256 reserve = ASSISTANT_FUND.balance();
            uint256 injected = reserve < deficit ? reserve : deficit;
            if (injected != 0) {
                ASSISTANT_FUND.injectFunds(injected);
                emit ReserveInjected(cr, injected);
            }
        } else {
            emit ReserveInjectionSkipped(cr);
        }

        // Layer 3: on a critical realised ratio, activate bonding for the realised deficit left after the injection
        if (realisedCr < CRITICAL_CR && !BOND_DEPOSITORY.isActive()) {
            uint256 shortfall = VAULT.realisedCollateralizationDeficit();
            if (shortfall != 0) {
                BOND_DEPOSITORY.activateBonding(shortfall);
                emit BondingTriggered(realisedCr, shortfall);
            }
        }
    }

    /**
     * @dev Delegated to the Vault, which derives it from the nominal deposit basis. Computing it as
     *      `totalAssets * (WAD - cr) / cr` is equivalent while the Vault holds assets, but panics on
     *      a fully drained Vault (totalAssets == 0 with shares outstanding makes CR == 0) — exactly
     *      the total-insolvency case the rescue must remain callable in.
     */
    function _deficitToTarget() internal view returns (uint256) {
        return VAULT.collateralizationDeficit();
    }
}
