// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployLib, DeployConfig, Deployed} from "../../script/Deploy.s.sol";
import {SolvencyHandler} from "./handlers/SolvencyHandler.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

contract MockUSDC is ERC20 {
    function name() public pure override returns (string memory) {
        return "USDC";
    }

    function symbol() public pure override returns (string memory) {
        return "USDC";
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title SolvencyIntegrationInvariantTest
 * @author GushALKDev
 * @notice Invariants over the FULL wired protocol: properties that only exist once the Vault, the
 *         AssistantFund, the BondDepository and the SolvencyManager operate together.
 * @dev The per-contract invariant suites cannot see these — `SolvencyManager` is unit-tested against
 *      a MockVault, and trading and bonding live in separate suites. Here a single sequence can
 *      interleave payouts, rescues, bonding, claims and skims against the real deployment.
 */
contract SolvencyIntegrationInvariantTest is StdInvariant, Test {
    Deployed d;
    MockUSDC usdc;
    SolvencyHandler handler;

    address owner = makeAddr("owner");
    address lp = makeAddr("lp");

    uint256 constant WAD = 1e18;
    uint256 constant LP_SEED = 1_000_000 * 10 ** 6;

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockUSDC();

        DeployConfig memory cfg = DeployConfig({
            asset: address(usdc),
            pyth: makeAddr("pyth"),
            sequencerUptimeFeed: address(0),
            owner: owner,
            keeper: makeAddr("keeper"),
            assistantFundTargetCap: 100_000 * 10 ** 6,
            bondDiscountBps: 500,
            baseSpreadBps: 5,
            impactFactor: 3e5,
            volFactor: 100,
            maxSpreadBps: 100,
            maxVolatilityChangeBps: 5000
        });

        vm.startPrank(owner);
        d = DeployLib.deploy(cfg);
        DeployLib.wire(d);
        vm.stopPrank();

        usdc.mint(lp, LP_SEED);
        vm.startPrank(lp);
        usdc.approve(address(d.vault), type(uint256).max);
        d.vault.deposit(LP_SEED, lp);
        vm.stopPrank();

        handler = new SolvencyHandler(d, usdc);
        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                              INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice A rescue (injection or bond) never lifts CR above 100%
     * @dev Replaces the round 1 bound (CR < 100x). checkAndAct injects min(reserve, deficit) and a bond takes
     *      at most the deficit, where deficit = totalSupply / 1e12 - totalAssets, so the resulting CR is
     *      floor(totalSupply / 1e12) * 1e30 / totalSupply <= 1e18. Tolerance 0: fees and skims can lift CR
     *      above 100%, but they are not rescue actions and are not tracked here.
     */
    function invariant_RescueNeverOvershootsTarget() public view {
        assertLe(handler.ghostMaxCrAfterRescue(), WAD, "rescue lifted CR above 100%");
    }

    /**
     * @notice The Vault's USDC balance equals the sum of the modelled flows
     * @dev vault USDC = LP seed + deposits - trader payouts + Vault fees + AssistantFund injections
     *                   + AssistantFund skims + bond proceeds
     *      Trading is simulated here by sendPayout (profits) and fee deals; the protocol suite covers real trades.
     */
    function invariant_VaultBalanceMatchesModelledFlows() public view {
        uint256 inflows =
            LP_SEED + handler.ghostDeposits() + handler.ghostVaultFees() + handler.ghostInjections() + handler.ghostSkims() + handler.ghostBondProceeds();
        assertEq(usdc.balanceOf(address(d.vault)), inflows - handler.ghostPayouts(), "vault balance diverged from modelled flows");
    }

    /// @notice AssistantFund USDC = reserve fees - injections - skims
    function invariant_AssistantFundBalanceMatchesModelledFlows() public view {
        assertEq(
            d.assistantFund.balance(), handler.ghostReserveFees() - handler.ghostInjections() - handler.ghostSkims(), "reserve diverged from modelled flows"
        );
    }

    /// @notice Every injection, bond and skim moved exactly the modelled amount
    function invariant_FlowsMatchModel() public view {
        assertEq(handler.ghostMismatches(), 0, "solvency flow differs from the model");
    }

    /**
     * @notice The bonding escrow always covers every unclaimed vesting position
     * @dev Same property as the isolated bonding suite, but asserted while rescues, payouts and
     *      skims are interleaved — the escrow must survive the whole system moving around it.
     */
    function invariant_EscrowSolventUnderFullSystem() public view {
        assertGe(d.synth.balanceOf(address(d.bondDepository)), handler.outstandingSynth(), "escrow cannot cover unclaimed");
    }

    /**
     * @notice $SYNTH is only ever minted by bonding, even across rescue cycles
     * @dev The depository is the sole minter; supply must equal what the handler observed being sold.
     */
    function invariant_SynthSupplyOnlyFromBonding() public view {
        assertEq(d.synth.totalSupply(), handler.ghostPromised(), "SYNTH minted outside bonding");
    }

    /**
     * @notice The AssistantFund never holds more than its target cap after a skim is available
     * @dev Overflow above targetCap belongs to the Vault; `skim` is permissionless so the excess is
     *      always recoverable. This pins the reserve to its configured role.
     */
    function invariant_ReserveNeverExceedsCapAfterSkim() public {
        uint256 cap = d.assistantFund.targetCap();
        if (d.assistantFund.balance() <= cap) return;

        // Checked on a snapshot so the skim does not change the state the handler's ghosts describe
        uint256 snapshot = vm.snapshotState();
        d.assistantFund.skim();
        assertLe(d.assistantFund.balance(), cap, "skim failed to return overflow to the Vault");
        vm.revertToState(snapshot);
    }

    /**
     * @notice The rescue path is always callable, including from total insolvency
     * @dev Total insolvency (shares outstanding, zero assets) is a state the protocol must survive,
     *      not one it can prevent — a large enough payout run reaches it. What must never break is
     *      the ability to recapitalize: `deficitToTarget` must stay well-defined and `checkAndAct`
     *      must not revert, no matter how drained the Vault is. (A prior implementation divided by
     *      the CR here and panicked at exactly this point.)
     */
    function invariant_RescueAlwaysCallable() public {
        uint256 deficit = d.solvencyManager.deficitToTarget();
        if (d.vault.totalSupply() == 0) return;

        // Deficit must never exceed the nominal basis of outstanding shares
        assertLe(deficit, d.vault.totalSupply() / 1e12, "deficit exceeds nominal liabilities");

        // The permissionless rescue must remain callable in every reachable state (checked on a snapshot so it
        // does not change the state the handler's ghosts describe)
        uint256 snapshot = vm.snapshotState();
        d.solvencyManager.checkAndAct();
        vm.revertToState(snapshot);
    }

    /// @notice Run summary, logged after each run (forge shows the last run's logs with -vv)
    function afterInvariant() public view {
        assertLe(handler.ghostClaimed(), handler.ghostPromised(), "claimed more than promised");
        console.log("checkAndAct / bond / skim:", handler.calls("checkAndAct"), handler.calls("bond"), handler.calls("skim"));
        console.log("effective rescues:", handler.ghostRescues());
        console.log("SYNTH promised:", handler.ghostPromised());
    }
}
