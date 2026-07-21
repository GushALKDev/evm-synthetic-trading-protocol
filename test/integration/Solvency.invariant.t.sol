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

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockUSDC();

        DeployConfig memory cfg = DeployConfig({
            asset: address(usdc),
            pyth: makeAddr("pyth"),
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

        usdc.mint(lp, 1_000_000 * 10 ** 6);
        vm.startPrank(lp);
        usdc.approve(address(d.vault), type(uint256).max);
        d.vault.deposit(1_000_000 * 10 ** 6, lp);
        vm.stopPrank();

        handler = new SolvencyHandler(d, usdc);
        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                              INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice A rescue never overshoots: the manager stops at DEFICIT_CR, it does not over-mint
     * @dev checkAndAct sizes the injection and the bonding round off the deficit to 100%. If a rescue
     *      could push CR far above target it would be diluting $SYNTH holders (or draining the
     *      reserve) for solvency the Vault already had.
     */
    function invariant_RescueNeverOvershootsWildly() public view {
        uint256 cr = d.vault.collateralizationRatio();
        if (cr == type(uint256).max) return; // empty Vault, trivially solvent
        // Fees and skims legitimately push CR up, so this only guards against a runaway rescue
        assertLt(cr, 100 * WAD, "CR exploded past any plausible rescue target");
    }

    /**
     * @notice The bonding escrow always covers every unclaimed vesting position
     * @dev Same property as the isolated bonding suite, but asserted while rescues, payouts and
     *      skims are interleaved — the escrow must survive the whole system moving around it.
     */
    function invariant_EscrowSolventUnderFullSystem() public view {
        assertGe(
            d.synth.balanceOf(address(d.bondDepository)), handler.outstandingSynth(), "escrow cannot cover unclaimed"
        );
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

        d.assistantFund.skim();
        assertLe(d.assistantFund.balance(), cap, "skim failed to return overflow to the Vault");
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

        // The permissionless rescue must remain callable in every reachable state
        d.solvencyManager.checkAndAct();
    }

    /// @notice Surfaces action coverage so a silently idle suite is visible
    function invariant_CallSummary() public view {
        console.log("deposit     :", handler.calls("deposit"));
        console.log("payoutTrader:", handler.calls("payoutTrader"));
        console.log("accrueFees  :", handler.calls("accrueFees"));
        console.log("checkAndAct :", handler.calls("checkAndAct"));
        console.log("bond        :", handler.calls("bond"));
        console.log("claim       :", handler.calls("claim"));
        console.log("skim        :", handler.calls("skim"));
        console.log("-- effective rescues:", handler.ghostRescues());
        console.log("-- SYNTH promised   :", handler.ghostPromised());
    }
}
