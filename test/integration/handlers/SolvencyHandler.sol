// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Deployed} from "../../../script/Deploy.s.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

/**
 * @title SolvencyHandler
 * @author GushALKDev
 * @notice Stateful handler driving the full solvency system: LP flows, trader payouts draining the
 *         Vault, fee income, permissionless rescues, bonding and claims.
 * @dev Unlike the per-contract handlers, this one operates the REAL wired deployment, so a sequence
 *      can interleave a rescue with new deposits, further payouts and vesting claims — the ordering
 *      that unit tests never reach.
 */
contract SolvencyHandler is CommonBase, StdCheats, StdUtils {
    Deployed internal d;
    ERC20 public immutable USDC;
    address public immutable ENGINE;

    address[] public actors;
    address internal currentActor;

    /// @notice Total $SYNTH promised to bonders across all rounds
    uint256 public ghostPromised;
    /// @notice Total $SYNTH claimed by bonders
    uint256 public ghostClaimed;
    /// @notice Number of rescues that actually moved reserve funds or opened a round
    uint256 public ghostRescues;

    // Modelled flows into and out of the Vault and the AssistantFund
    uint256 public ghostDeposits;
    uint256 public ghostPayouts;
    uint256 public ghostVaultFees;
    uint256 public ghostReserveFees;
    uint256 public ghostInjections;
    uint256 public ghostSkims;
    uint256 public ghostBondProceeds;
    /// @notice Flows whose measured amount differed from the model
    uint256 public ghostMismatches;
    /// @notice Highest CR observed right after a rescue action (checkAndAct or bond) that raised the CR
    uint256 public ghostMaxCrAfterRescue;

    mapping(bytes32 => uint256) public calls;

    modifier countCall(bytes32 _key) {
        calls[_key]++;
        _;
    }

    constructor(Deployed memory _d, ERC20 _usdc) {
        d = _d;
        USDC = _usdc;
        ENGINE = address(_d.engine);

        for (uint256 i; i < 3; ++i) {
            actors.push(address(uint160(uint256(keccak256(abi.encode("solvActor", i))))));
        }
    }

    /*//////////////////////////////////////////////////////////////
                               ACTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice An LP deposits into the Vault
     * @dev The Vault runs the pending AssistantFund injection first and refuses while a bonding round is open or
     *      due; the outcome must match maxDeposit, and the injection is recorded like one from checkAndAct.
     */
    function deposit(uint256 _actorSeed, uint256 _assets) external countCall("deposit") {
        currentActor = actors[bound(_actorSeed, 0, actors.length - 1)];
        uint256 assets = bound(_assets, 1 * 10 ** 6, 200_000 * 10 ** 6);
        bool expected = d.vault.maxDeposit(currentActor) != 0;
        uint256 reserveBefore = d.assistantFund.balance();

        deal(address(USDC), currentActor, assets);
        vm.startPrank(currentActor);
        USDC.approve(address(d.vault), assets);
        bool ok;
        try d.vault.deposit(assets, currentActor) {
            ok = true;
        } catch {}
        vm.stopPrank();

        if (ok != expected) ghostMismatches++;
        if (!ok) return;
        ghostInjections += reserveBefore - d.assistantFund.balance();
        ghostDeposits += assets;
    }

    /**
     * @notice A winning trader is paid out of the Vault, dropping CR
     * @dev Bounded to the Vault's own balance: sendPayout would revert on more, and this is the only
     *      mechanism that can make the protocol insolvent.
     */
    function payoutTrader(uint256 _amount) external countCall("payoutTrader") {
        uint256 available = USDC.balanceOf(address(d.vault));
        if (available == 0) return;

        uint256 amount = bound(_amount, 1, available);
        vm.startPrank(ENGINE);
        d.vault.sendPayout(actors[0], amount);
        vm.stopPrank();
        ghostPayouts += amount;
    }

    /// @notice Protocol fees accrue to the Vault (LP side) and the AssistantFund (reserve side)
    function accrueFees(uint256 _vaultFee, uint256 _reserveFee) external countCall("accrueFees") {
        uint256 vaultFee = bound(_vaultFee, 0, 10_000 * 10 ** 6);
        uint256 reserveFee = bound(_reserveFee, 0, 10_000 * 10 ** 6);
        deal(address(USDC), address(d.vault), USDC.balanceOf(address(d.vault)) + vaultFee);
        deal(address(USDC), address(d.assistantFund), USDC.balanceOf(address(d.assistantFund)) + reserveFee);
        ghostVaultFees += vaultFee;
        ghostReserveFees += reserveFee;
    }

    /// @notice Anyone triggers the permissionless solvency check
    function checkAndAct() external countCall("checkAndAct") {
        uint256 reserveBefore = d.assistantFund.balance();
        bool activeBefore = d.bondDepository.isActive();
        uint256 crBefore = d.vault.collateralizationRatio();
        uint256 expected;
        if (crBefore < 1e18) {
            uint256 deficit = d.vault.collateralizationDeficit();
            expected = reserveBefore < deficit ? reserveBefore : deficit;
        }

        d.solvencyManager.checkAndAct();

        if (reserveBefore - d.assistantFund.balance() != expected) ghostMismatches++;
        ghostInjections += expected;
        _trackRescue(crBefore);
        if (d.assistantFund.balance() != reserveBefore || d.bondDepository.isActive() != activeBefore) {
            ghostRescues++;
        }
    }

    /// @notice A bonder buys into an open round (no-op when none is active)
    function bond(uint256 _actorSeed, uint256 _amount) external countCall("bond") {
        uint256 cap = d.bondDepository.remainingCap();
        uint256 deficit = d.vault.realisedCollateralizationDeficit();
        uint256 available = deficit < cap ? deficit : cap;
        if (available == 0) return; // bond() reverts NoActiveRound
        currentActor = actors[bound(_actorSeed, 0, actors.length - 1)];

        uint256 amount = bound(_amount, 1 * 10 ** 6, 100_000 * 10 ** 6);
        uint256 expected = amount < available ? amount : available;
        uint256 crBefore = d.vault.collateralizationRatio();
        uint256 vaultBefore = USDC.balanceOf(address(d.vault));
        deal(address(USDC), currentActor, amount);

        vm.startPrank(currentActor);
        USDC.approve(address(d.bondDepository), amount);
        (, uint256 synthOut) = d.bondDepository.bond(amount);
        vm.stopPrank();

        if (USDC.balanceOf(address(d.vault)) - vaultBefore != expected) ghostMismatches++;
        ghostBondProceeds += expected;
        ghostPromised += synthOut;
        _trackRescue(crBefore);
    }

    /// @notice A bonder claims vested $SYNTH (no-op when nothing is claimable)
    function claim(uint256 _actorSeed, uint256 _bondSeed) external countCall("claim") {
        address bonder = actors[bound(_actorSeed, 0, actors.length - 1)];
        uint256 count = d.bondDepository.bondCount(bonder);
        if (count == 0) return;

        uint256 bondId = bound(_bondSeed, 0, count - 1);
        if (d.bondDepository.claimable(bonder, bondId) == 0) return;

        vm.startPrank(bonder);
        ghostClaimed += d.bondDepository.claim(bondId);
        vm.stopPrank();
    }

    /// @notice Anyone skims reserve overflow above the target cap back into the Vault
    function skim() external countCall("skim") {
        uint256 reserve = d.assistantFund.balance();
        uint256 cap = d.assistantFund.targetCap();
        uint256 expected = reserve > cap ? reserve - cap : 0;
        d.assistantFund.skim();
        if (reserve - d.assistantFund.balance() != expected) ghostMismatches++;
        ghostSkims += expected;
    }

    /// @notice Advance time so vesting progresses
    function warp(uint256 _timeSeed) external countCall("warp") {
        vm.warp(block.timestamp + bound(_timeSeed, 1 minutes, 5 days));
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    function _trackRescue(uint256 _crBefore) internal {
        uint256 crAfter = d.vault.collateralizationRatio();
        if (crAfter > _crBefore && crAfter > ghostMaxCrAfterRescue) ghostMaxCrAfterRescue = crAfter;
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function outstandingSynth() external view returns (uint256) {
        return ghostPromised - ghostClaimed;
    }
}
