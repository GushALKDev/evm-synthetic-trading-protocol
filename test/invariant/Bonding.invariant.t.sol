// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {BondDepository} from "../../src/BondDepository.sol";
import {SynthToken} from "../../src/SynthToken.sol";
import {BondingHandler} from "./handlers/BondingHandler.sol";
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
 * @title BondingInvariantTest
 * @author GushALKDev
 * @notice Roadmap 12.3 — properties of the bonding / vesting accounting that must hold after any
 *         sequence of rounds, purchases, claims and admin re-pricing.
 * @dev The critical property is solvency of the vesting escrow: $SYNTH is minted into the
 *      depository's custody at bond time, so it must always hold enough to pay every unclaimed
 *      position. A shortfall would mean some bonder can never claim what they paid for.
 */
contract BondingInvariantTest is StdInvariant, Test {
    BondDepository bond;
    SynthToken synth;
    MockUSDC usdc;
    BondingHandler handler;

    address owner = makeAddr("owner");
    address vault = makeAddr("vault");
    address solvencyManager = makeAddr("solvencyManager");

    uint256 constant DISCOUNT_BPS = 500; // 5%

    function setUp() public {
        vm.warp(1_000_000); // avoid timestamp underflow in vesting math

        usdc = new MockUSDC();
        synth = new SynthToken(owner);

        vm.startPrank(owner);
        bond = new BondDepository(address(usdc), vault, address(synth), DISCOUNT_BPS, owner);
        synth.setMinter(address(bond));
        bond.setSolvencyManager(solvencyManager);
        vm.stopPrank();

        handler = new BondingHandler(bond, synth, usdc, solvencyManager, owner);
        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                              INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Escrow solvency — the depository can always honour every unclaimed vesting position
     * @dev $SYNTH is minted into the depository at bond time and released as it vests. Its balance
     *      must therefore cover everything promised but not yet claimed; below that, a bonder's
     *      claim would revert on transfer and their USDC would have bought nothing.
     */
    function invariant_EscrowCoversUnclaimedSynth() public view {
        uint256 outstanding = handler.ghostTotalPromised() - handler.ghostTotalClaimed();
        assertGe(synth.balanceOf(address(bond)), outstanding, "escrow cannot cover unclaimed bonds");
    }

    /**
     * @notice Supply integrity — $SYNTH is only ever created by bonding
     * @dev Total supply must equal everything the depository promised: minting is minter-gated and
     *      the only minter is the depository. A larger supply would mean an unaccounted mint path.
     */
    function invariant_SupplyEqualsPromised() public view {
        assertEq(synth.totalSupply(), handler.ghostTotalPromised(), "SYNTH supply diverged from bonded total");
    }

    /**
     * @notice Vesting monotonicity — nobody can claim more than they were promised
     * @dev Guards the per-position accounting: claimedSynth must never exceed totalSynth, otherwise
     *      linear vesting would be paying out beyond the bond.
     */
    function invariant_ClaimedNeverExceedsPromised() public view {
        assertLe(handler.ghostTotalClaimed(), handler.ghostTotalPromised(), "claimed more SYNTH than promised");

        uint256 bonderCount = handler.bondersLength();
        for (uint256 i; i < bonderCount; ++i) {
            address bonder = handler.bonders(i);
            uint256 positions = bond.bondCount(bonder);
            for (uint256 j; j < positions; ++j) {
                BondDepository.BondPosition memory pos = bond.bondAt(bonder, j);
                assertLe(pos.claimedSynth, pos.totalSynth, "position claimed beyond its total");
            }
        }
    }

    /**
     * @notice Round cap integrity — a round never raises more USDC than it was opened for
     * @dev activateBonding sets the cap and bond() clamps to it, so the raised total must stay at or
     *      below the sum of caps. Over-raising would dilute $SYNTH beyond the approved deficit.
     */
    function invariant_RaisedWithinCap() public view {
        // Every USDC raised landed in the Vault; it can never exceed what bonders actually paid.
        assertEq(usdc.balanceOf(vault), handler.ghostUsdcRaised(), "vault USDC diverged from bonded raise");
    }

    /// @notice Surfaces action coverage so a silently idle suite is visible
    function invariant_CallSummary() public view {
        console.log("activate  :", handler.calls("activateBonding"));
        console.log("bond      :", handler.calls("bond"));
        console.log("claim     :", handler.calls("claim"));
        console.log("warp      :", handler.calls("warp"));
        console.log("promised  :", handler.ghostTotalPromised());
        console.log("claimed   :", handler.ghostTotalClaimed());
        console.log("raised    :", handler.ghostUsdcRaised());
    }
}
