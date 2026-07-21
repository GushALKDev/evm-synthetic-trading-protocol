// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {BondDepository} from "../../src/BondDepository.sol";
import {SynthToken} from "../../src/SynthToken.sol";

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

contract BondDepositoryTest is Test {
    BondDepository bond;
    SynthToken synth;
    MockUSDC usdc;

    address owner = makeAddr("owner");
    address vault = makeAddr("vault");
    address solvencyManager = makeAddr("solvencyManager");
    address alice = makeAddr("alice");

    uint256 constant DISCOUNT_BPS = 500; // 5%
    uint256 constant DEFAULT_REF_PRICE = 2 * 10 ** 6; // 2 USDC per SYNTH
    uint256 constant VESTING = 48 hours;

    event BondingActivated(uint256 neededUsdc);
    event Bonded(address indexed bonder, uint256 bondId, uint256 usdcIn, uint256 synthOut, uint256 vestingEnd);
    event Claimed(address indexed bonder, uint256 bondId, uint256 synthClaimed);
    event RoundClosed();
    event SolvencyManagerUpdated(address indexed newSolvencyManager);
    event ReferencePriceUpdated(uint256 newReferencePrice);
    event DiscountUpdated(uint256 newDiscountBps);
    event VestingPeriodUpdated(uint256 newVestingPeriod);

    function setUp() public {
        vm.warp(1_000_000); // avoid timestamp underflow in vesting math

        usdc = new MockUSDC();
        synth = new SynthToken(owner);
        vm.prank(owner);
        bond = new BondDepository(address(usdc), vault, address(synth), DISCOUNT_BPS, owner);

        // Wire the depository as the token minter and set the solvency manager
        vm.prank(owner);
        synth.setMinter(address(bond));
        vm.prank(owner);
        bond.setSolvencyManager(solvencyManager);

        usdc.mint(alice, 1_000_000 * 10 ** 6);
        vm.prank(alice);
        usdc.approve(address(bond), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_State() public view {
        assertEq(bond.ASSET(), address(usdc));
        assertEq(bond.VAULT(), vault);
        assertEq(address(bond.SYNTH()), address(synth));
        assertEq(bond.discountBps(), DISCOUNT_BPS);
        assertEq(bond.referencePrice(), DEFAULT_REF_PRICE);
        assertEq(bond.vestingPeriod(), VESTING);
        assertEq(bond.owner(), owner);
        assertEq(bond.remainingCap(), 0);
        assertFalse(bond.isActive());
    }

    function test_Constructor_ZeroAddressReverts() public {
        vm.expectRevert(BondDepository.ZeroAddress.selector);
        new BondDepository(address(0), vault, address(synth), DISCOUNT_BPS, owner);
        vm.expectRevert(BondDepository.ZeroAddress.selector);
        new BondDepository(address(usdc), address(0), address(synth), DISCOUNT_BPS, owner);
        vm.expectRevert(BondDepository.ZeroAddress.selector);
        new BondDepository(address(usdc), vault, address(0), DISCOUNT_BPS, owner);
    }

    function test_Constructor_DiscountTooHighReverts() public {
        vm.expectRevert(abi.encodeWithSelector(BondDepository.DiscountTooHigh.selector, 1001));
        new BondDepository(address(usdc), vault, address(synth), 1001, owner);
    }

    /*//////////////////////////////////////////////////////////////
                            ACTIVATE BONDING
    //////////////////////////////////////////////////////////////*/

    function test_ActivateBonding_SetsCap() public {
        vm.prank(solvencyManager);
        bond.activateBonding(100_000 * 10 ** 6);
        assertEq(bond.remainingCap(), 100_000 * 10 ** 6);
        assertTrue(bond.isActive());
    }

    function test_ActivateBonding_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit BondingActivated(100_000 * 10 ** 6);
        vm.prank(solvencyManager);
        bond.activateBonding(100_000 * 10 ** 6);
    }

    function test_ActivateBonding_OnlySolvencyManager() public {
        vm.prank(alice);
        vm.expectRevert(BondDepository.CallerNotSolvencyManager.selector);
        bond.activateBonding(100_000 * 10 ** 6);
    }

    function test_ActivateBonding_ZeroAmountReverts() public {
        vm.prank(solvencyManager);
        vm.expectRevert(BondDepository.ZeroAmount.selector);
        bond.activateBonding(0);
    }

    function test_ActivateBonding_AlreadyActiveReverts() public {
        vm.prank(solvencyManager);
        bond.activateBonding(100_000 * 10 ** 6);
        vm.prank(solvencyManager);
        vm.expectRevert(BondDepository.RoundAlreadyActive.selector);
        bond.activateBonding(50_000 * 10 ** 6);
    }

    /*//////////////////////////////////////////////////////////////
                                QUOTE
    //////////////////////////////////////////////////////////////*/

    function test_QuoteBond_AppliesDiscount() public view {
        // effectivePrice = 2e6 * 9500/10000 = 1.9e6; 1000 USDC → 1000e6 * 1e18 / 1.9e6
        uint256 effectivePrice = 1_900_000;
        uint256 expected = (uint256(1000 * 10 ** 6) * 1e18) / effectivePrice;
        assertEq(bond.quoteBond(1000 * 10 ** 6), expected);
    }

    function test_QuoteBond_ZeroDiscountIsRefPrice() public {
        vm.prank(owner);
        bond.setDiscountBps(0);
        // 2 USDC per SYNTH, no discount: 2 USDC → 1 SYNTH
        assertEq(bond.quoteBond(2 * 10 ** 6), 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                                BOND
    //////////////////////////////////////////////////////////////*/

    function test_Bond_InjectsVaultAndCustodiesSynth() public {
        vm.prank(solvencyManager);
        bond.activateBonding(100_000 * 10 ** 6);

        uint256 usdcIn = 1000 * 10 ** 6;
        uint256 expectedSynth = bond.quoteBond(usdcIn);

        vm.prank(alice);
        (uint256 bondId, uint256 synthOut) = bond.bond(usdcIn);

        assertEq(bondId, 0);
        assertEq(synthOut, expectedSynth);
        // $SYNTH is held by the depository for vesting, NOT sent to the bonder yet
        assertEq(synth.balanceOf(alice), 0);
        assertEq(synth.balanceOf(address(bond)), expectedSynth);
        assertEq(usdc.balanceOf(vault), usdcIn); // USDC injected into Vault
        assertEq(bond.remainingCap(), 100_000 * 10 ** 6 - usdcIn);

        // A vesting position is recorded
        assertEq(bond.bondCount(alice), 1);
        BondDepository.BondPosition memory pos = bond.bondAt(alice, 0);
        assertEq(pos.totalSynth, expectedSynth);
        assertEq(pos.claimedSynth, 0);
        assertEq(pos.start, block.timestamp);
        assertEq(pos.end, block.timestamp + VESTING);
    }

    function test_Bond_EmitsBonded() public {
        vm.prank(solvencyManager);
        bond.activateBonding(100_000 * 10 ** 6);

        uint256 usdcIn = 1000 * 10 ** 6;
        uint256 expectedSynth = bond.quoteBond(usdcIn);

        vm.expectEmit(true, false, false, true);
        emit Bonded(alice, 0, usdcIn, expectedSynth, block.timestamp + VESTING);
        vm.prank(alice);
        bond.bond(usdcIn);
    }

    function test_Bond_ClampsToRemainingCapAndCloses() public {
        vm.prank(solvencyManager);
        bond.activateBonding(1000 * 10 ** 6);

        uint256 expectedSynth = bond.quoteBond(1000 * 10 ** 6);

        vm.expectEmit(false, false, false, false);
        emit RoundClosed();
        vm.prank(alice);
        (, uint256 synthOut) = bond.bond(5000 * 10 ** 6);

        assertEq(synthOut, expectedSynth);
        assertEq(usdc.balanceOf(vault), 1000 * 10 ** 6);
        assertEq(bond.remainingCap(), 0);
        assertFalse(bond.isActive());
    }

    function test_Bond_NoActiveRoundReverts() public {
        vm.prank(alice);
        vm.expectRevert(BondDepository.NoActiveRound.selector);
        bond.bond(1000 * 10 ** 6);
    }

    function test_Bond_ZeroAmountReverts() public {
        vm.prank(solvencyManager);
        bond.activateBonding(100_000 * 10 ** 6);
        vm.prank(alice);
        vm.expectRevert(BondDepository.ZeroAmount.selector);
        bond.bond(0);
    }

    function test_Bond_MultipleSimultaneousPositions() public {
        vm.prank(solvencyManager);
        bond.activateBonding(10_000 * 10 ** 6);

        vm.prank(alice);
        (uint256 id0, ) = bond.bond(1000 * 10 ** 6);
        vm.prank(alice);
        (uint256 id1, ) = bond.bond(2000 * 10 ** 6);

        assertEq(id0, 0);
        assertEq(id1, 1);
        assertEq(bond.bondCount(alice), 2);
        assertEq(bond.bondAt(alice, 0).totalSynth, bond.quoteBond(1000 * 10 ** 6));
        assertEq(bond.bondAt(alice, 1).totalSynth, bond.quoteBond(2000 * 10 ** 6));
    }

    /*//////////////////////////////////////////////////////////////
                                VESTING / CLAIM
    //////////////////////////////////////////////////////////////*/

    function test_Claim_NothingBeforeVestingStarts() public {
        uint256 synthOut = _bond(1000 * 10 ** 6);
        assertEq(bond.claimable(alice, 0), 0);

        vm.prank(alice);
        vm.expectRevert(BondDepository.NothingToClaim.selector);
        bond.claim(0);
        assertEq(synthOut, bond.bondAt(alice, 0).totalSynth);
    }

    function test_Claim_HalfwayLinear() public {
        uint256 synthOut = _bond(1000 * 10 ** 6);

        vm.warp(block.timestamp + VESTING / 2);
        assertApproxEqAbs(bond.claimable(alice, 0), synthOut / 2, 1);

        vm.prank(alice);
        uint256 claimed = bond.claim(0);
        assertApproxEqAbs(claimed, synthOut / 2, 1);
        assertEq(synth.balanceOf(alice), claimed);
        assertEq(bond.bondAt(alice, 0).claimedSynth, claimed);
    }

    function test_Claim_FullAfterVesting() public {
        uint256 synthOut = _bond(1000 * 10 ** 6);

        vm.warp(block.timestamp + VESTING);
        assertEq(bond.claimable(alice, 0), synthOut);

        vm.prank(alice);
        uint256 claimed = bond.claim(0);
        assertEq(claimed, synthOut);
        assertEq(synth.balanceOf(alice), synthOut);
    }

    function test_Claim_Incremental() public {
        uint256 synthOut = _bond(1000 * 10 ** 6);

        vm.warp(block.timestamp + VESTING / 4);
        vm.prank(alice);
        uint256 c1 = bond.claim(0);

        vm.warp(block.timestamp + VESTING / 4);
        vm.prank(alice);
        uint256 c2 = bond.claim(0);

        vm.warp(block.timestamp + VESTING); // fully vested
        vm.prank(alice);
        uint256 c3 = bond.claim(0);

        assertEq(c1 + c2 + c3, synthOut);
        assertEq(synth.balanceOf(alice), synthOut);
        assertEq(bond.claimable(alice, 0), 0);
    }

    function test_Claim_ClosesExactlyDespiteRounding() public {
        // Coprime usdcIn (6 dec) and vesting window force non-exact division in _vested,
        // so intermediate claims floor. The final claim must still settle to totalSynth exactly
        // (no dust left in custody, none over-paid), because _vested returns totalSynth at end.
        vm.prank(owner);
        bond.setVestingPeriod(97 minutes); // odd, coprime with the warp offsets below

        uint256 synthOut = _bond(333_333 * 10 ** 3); // 333.333 USDC → not a round SYNTH amount

        uint256 total;
        uint64 start = bond.bondAt(alice, 0).start;
        // Claim at several irregular points inside the window (each floors)
        uint256[4] memory offsets = [uint256(13 minutes), 29 minutes, 61 minutes, 200 minutes];
        for (uint256 i = 0; i < offsets.length; i++) {
            vm.warp(start + offsets[i]);
            if (bond.claimable(alice, 0) == 0) continue;
            vm.prank(alice);
            total += bond.claim(0);
        }

        // Exact settlement: everything minted has been claimed, nothing stuck in custody
        assertEq(total, synthOut);
        assertEq(synth.balanceOf(alice), synthOut);
        assertEq(synth.balanceOf(address(bond)), 0);
        assertEq(bond.bondAt(alice, 0).claimedSynth, synthOut);
        assertEq(bond.claimable(alice, 0), 0);
    }

    function testFuzz_Claim_NoDustAfterFullVesting(uint256 usdcIn, uint256 period, uint256 midClaim) public {
        usdcIn = bound(usdcIn, 1 * 10 ** 6, 1_000_000 * 10 ** 6);
        period = bound(period, 1, 7 days);
        vm.prank(owner);
        bond.setVestingPeriod(period);

        uint256 synthOut = _bond(usdcIn);
        uint64 start = bond.bondAt(alice, 0).start;

        // One partial claim somewhere inside the window (may floor)
        midClaim = bound(midClaim, 1, period);
        vm.warp(uint256(start) + midClaim);
        if (bond.claimable(alice, 0) != 0) {
            vm.prank(alice);
            bond.claim(0);
        }

        // After full vesting, the remainder settles the position to exactly totalSynth
        vm.warp(uint256(start) + period);
        if (bond.claimable(alice, 0) != 0) {
            vm.prank(alice);
            bond.claim(0);
        }

        assertEq(synth.balanceOf(alice), synthOut);
        assertEq(synth.balanceOf(address(bond)), 0);
        assertEq(bond.claimable(alice, 0), 0);
    }

    function test_Claim_EmitsEvent() public {
        _bond(1000 * 10 ** 6);
        vm.warp(block.timestamp + VESTING);

        uint256 expected = bond.claimable(alice, 0);
        vm.expectEmit(true, false, false, true);
        emit Claimed(alice, 0, expected);
        vm.prank(alice);
        bond.claim(0);
    }

    function test_Claim_InvalidBondIdReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BondDepository.InvalidBondId.selector, 0));
        bond.claim(0);
    }

    function test_Claim_TwiceWithoutNewVestingReverts() public {
        _bond(1000 * 10 ** 6);
        vm.warp(block.timestamp + VESTING);

        vm.prank(alice);
        bond.claim(0);

        vm.prank(alice);
        vm.expectRevert(BondDepository.NothingToClaim.selector);
        bond.claim(0);
    }

    function test_Bond_ZeroVestingIsInstant() public {
        vm.prank(owner);
        bond.setVestingPeriod(0);

        uint256 synthOut = _bond(1000 * 10 ** 6);
        // Fully vested immediately
        assertEq(bond.claimable(alice, 0), synthOut);
        vm.prank(alice);
        assertEq(bond.claim(0), synthOut);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN SETTERS
    //////////////////////////////////////////////////////////////*/

    function test_SetSolvencyManager_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        bond.setSolvencyManager(alice);
    }

    function test_SetReferencePrice_Updates() public {
        vm.expectEmit(false, false, false, true);
        emit ReferencePriceUpdated(3 * 10 ** 6);
        vm.prank(owner);
        bond.setReferencePrice(3 * 10 ** 6);
        assertEq(bond.referencePrice(), 3 * 10 ** 6);
    }

    function test_SetReferencePrice_ZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(BondDepository.ZeroAmount.selector);
        bond.setReferencePrice(0);
    }

    function test_SetDiscountBps_Updates() public {
        vm.prank(owner);
        bond.setDiscountBps(1000);
        assertEq(bond.discountBps(), 1000);
    }

    function test_SetDiscountBps_TooHighReverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BondDepository.DiscountTooHigh.selector, 1001));
        bond.setDiscountBps(1001);
    }

    function test_SetVestingPeriod_Updates() public {
        vm.expectEmit(false, false, false, true);
        emit VestingPeriodUpdated(3 days);
        vm.prank(owner);
        bond.setVestingPeriod(3 days);
        assertEq(bond.vestingPeriod(), 3 days);
    }

    function test_SetVestingPeriod_TooLongReverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BondDepository.VestingPeriodTooLong.selector, 7 days + 1));
        bond.setVestingPeriod(7 days + 1);
    }

    function test_SetVestingPeriod_OnlyAffectsNewBonds() public {
        // First bond at 48h
        uint256 out0 = _bond(1000 * 10 ** 6);
        assertEq(bond.bondAt(alice, 0).end, block.timestamp + VESTING);

        // Shorten to 1 day; existing position keeps its 48h window
        vm.prank(owner);
        bond.setVestingPeriod(1 days);

        vm.prank(solvencyManager);
        bond.activateBonding(1000 * 10 ** 6);
        vm.prank(alice);
        bond.bond(1000 * 10 ** 6);

        assertEq(bond.bondAt(alice, 0).end, bond.bondAt(alice, 0).start + VESTING);
        assertEq(bond.bondAt(alice, 1).end, bond.bondAt(alice, 1).start + 1 days);
        assertGt(out0, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_Bond_ConservesCapAndInjects(uint256 cap, uint256 usdcIn) public {
        cap = bound(cap, 1 * 10 ** 6, 1_000_000 * 10 ** 6);
        usdcIn = bound(usdcIn, 1 * 10 ** 6, 1_000_000 * 10 ** 6);

        vm.prank(solvencyManager);
        bond.activateBonding(cap);

        uint256 clamped = usdcIn > cap ? cap : usdcIn;
        uint256 expectedSynth = bond.quoteBond(clamped);

        vm.prank(alice);
        (, uint256 synthOut) = bond.bond(usdcIn);

        assertEq(synthOut, expectedSynth);
        assertEq(usdc.balanceOf(vault), clamped);
        assertEq(bond.remainingCap(), cap - clamped);
        // Custodied by the depository, released via vesting
        assertEq(synth.balanceOf(address(bond)), expectedSynth);
        assertEq(bond.bondAt(alice, 0).totalSynth, expectedSynth);
    }

    function testFuzz_Vested_MonotonicAndBounded(uint256 elapsed) public {
        uint256 synthOut = _bond(1000 * 10 ** 6);
        elapsed = bound(elapsed, 0, 2 * VESTING);

        vm.warp(block.timestamp + elapsed);
        uint256 vested = bond.claimable(alice, 0);

        assertLe(vested, synthOut);
        if (elapsed >= VESTING) assertEq(vested, synthOut);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _bond(uint256 usdcIn) internal returns (uint256 synthOut) {
        vm.prank(solvencyManager);
        bond.activateBonding(usdcIn);
        vm.prank(alice);
        (, synthOut) = bond.bond(usdcIn);
    }
}
