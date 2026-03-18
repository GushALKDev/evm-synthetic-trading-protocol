// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SpreadManager} from "../../src/SpreadManager.sol";

contract SpreadManagerTest is Test {
    SpreadManager sm;

    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice");

    // Default constructor params
    uint256 constant DEFAULT_BASE_SPREAD_BPS = 5;
    uint256 constant DEFAULT_IMPACT_FACTOR = 3e5;
    uint256 constant DEFAULT_VOL_FACTOR = 100;
    uint256 constant DEFAULT_MAX_SPREAD_BPS = 100; // 1%
    uint256 constant DEFAULT_MAX_VOL_CHANGE_BPS = 200; // 2%

    // Events
    event VolatilityUpdated(uint256 indexed pairIndex, uint256 newVolatility);
    event BaseSpreadBpsUpdated(uint256 newBaseSpreadBps);
    event ImpactFactorUpdated(uint256 newImpactFactor);
    event VolFactorUpdated(uint256 newVolFactor);
    event MaxSpreadBpsUpdated(uint256 newMaxSpreadBps);
    event MaxVolatilityChangeBpsUpdated(uint256 newMaxVolatilityChangeBps);
    event KeeperUpdated(address indexed newKeeper);

    function setUp() public {
        sm = new SpreadManager(
            DEFAULT_BASE_SPREAD_BPS,
            DEFAULT_IMPACT_FACTOR,
            DEFAULT_VOL_FACTOR,
            DEFAULT_MAX_SPREAD_BPS,
            DEFAULT_MAX_VOL_CHANGE_BPS,
            keeper,
            owner
        );
    }

    /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_SetsParams() public view {
        assertEq(sm.baseSpreadBps(), DEFAULT_BASE_SPREAD_BPS);
        assertEq(sm.impactFactor(), DEFAULT_IMPACT_FACTOR);
        assertEq(sm.volFactor(), DEFAULT_VOL_FACTOR);
        assertEq(sm.maxSpreadBps(), DEFAULT_MAX_SPREAD_BPS);
        assertEq(sm.maxVolatilityChangeBps(), DEFAULT_MAX_VOL_CHANGE_BPS);
        assertEq(sm.keeper(), keeper);
        assertEq(sm.owner(), owner);
    }

    function test_Constructor_RevertOnZeroKeeper() public {
        vm.expectRevert(SpreadManager.ZeroAddress.selector);
        new SpreadManager(
            DEFAULT_BASE_SPREAD_BPS,
            DEFAULT_IMPACT_FACTOR,
            DEFAULT_VOL_FACTOR,
            DEFAULT_MAX_SPREAD_BPS,
            DEFAULT_MAX_VOL_CHANGE_BPS,
            address(0),
            owner
        );
    }

    function test_Constructor_RevertOnZeroBaseSpread() public {
        vm.expectRevert(SpreadManager.ZeroBaseSpread.selector);
        new SpreadManager(0, DEFAULT_IMPACT_FACTOR, DEFAULT_VOL_FACTOR, DEFAULT_MAX_SPREAD_BPS, DEFAULT_MAX_VOL_CHANGE_BPS, keeper, owner);
    }

    function test_Constructor_RevertOnMaxSpreadBelowBase() public {
        vm.expectRevert(abi.encodeWithSelector(SpreadManager.MaxSpreadBelowBase.selector, 3, 5));
        new SpreadManager(5, DEFAULT_IMPACT_FACTOR, DEFAULT_VOL_FACTOR, 3, DEFAULT_MAX_VOL_CHANGE_BPS, keeper, owner);
    }

    function test_Constructor_RevertOnMaxSpreadTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(SpreadManager.MaxSpreadTooHigh.selector, 10_000));
        new SpreadManager(DEFAULT_BASE_SPREAD_BPS, DEFAULT_IMPACT_FACTOR, DEFAULT_VOL_FACTOR, 10_000, DEFAULT_MAX_VOL_CHANGE_BPS, keeper, owner);
    }

    /*//////////////////////////////////////////////////////////////
                      GET SPREAD BPS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetSpreadBps_BaseOnly() public view {
        // Zero OI, zero volatility → base spread only
        uint256 spread = sm.getSpreadBps(0, 0);
        assertEq(spread, DEFAULT_BASE_SPREAD_BPS);
    }

    function test_GetSpreadBps_OIImpact() public view {
        // 10M OI (18 decimals) = 1e25 → oiImpact = 1e25 * 3e5 / 1e30 = 3
        uint256 oi = 10_000_000 * 1e18;
        uint256 spread = sm.getSpreadBps(0, oi);
        assertEq(spread, DEFAULT_BASE_SPREAD_BPS + 3); // 5 + 3 = 8
    }

    function test_GetSpreadBps_VolImpact() public {
        // Set 3% volatility = 3e16 → volImpact = 3e16 * 100 / 1e18 = 3
        vm.prank(keeper);
        sm.updateVolatility(0, 3e16);

        uint256 spread = sm.getSpreadBps(0, 0);
        assertEq(spread, DEFAULT_BASE_SPREAD_BPS + 3); // 5 + 3 = 8
    }

    function test_GetSpreadBps_Combined() public {
        // OI = 10M, vol = 3%
        vm.prank(keeper);
        sm.updateVolatility(0, 3e16);

        uint256 oi = 10_000_000 * 1e18;
        uint256 spread = sm.getSpreadBps(0, oi);
        // 5 (base) + 3 (OI) + 3 (vol) = 11
        assertEq(spread, 11);
    }

    function test_GetSpreadBps_CappedAtMax() public {
        // Very high OI to push spread above max
        uint256 hugeOI = 1_000_000_000 * 1e18; // 1B
        uint256 spread = sm.getSpreadBps(0, hugeOI);
        assertEq(spread, DEFAULT_MAX_SPREAD_BPS);
    }

    function test_GetSpreadBps_DifferentPairs() public {
        // Set vol only on pair 1
        vm.prank(keeper);
        sm.updateVolatility(1, 5e16); // 5%

        uint256 oi = 10_000_000 * 1e18;

        uint256 spread0 = sm.getSpreadBps(0, oi); // pair 0: no vol
        uint256 spread1 = sm.getSpreadBps(1, oi); // pair 1: 5% vol

        assertLt(spread0, spread1);
    }

    function test_GetSpreadBps_ZeroFactors() public {
        // Deploy with zero impact and vol factors
        SpreadManager sm2 = new SpreadManager(5, 0, 0, 100, DEFAULT_MAX_VOL_CHANGE_BPS, keeper, owner);
        uint256 spread = sm2.getSpreadBps(0, 1_000_000_000 * 1e18);
        assertEq(spread, 5); // Only base
    }

    /*//////////////////////////////////////////////////////////////
                    UPDATE VOLATILITY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_UpdateVolatility_FirstTime() public {
        vm.prank(keeper);
        sm.updateVolatility(0, 3e16);

        assertEq(sm.getPairVolatility(0), 3e16);
    }

    function test_UpdateVolatility_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit VolatilityUpdated(0, 3e16);

        vm.prank(keeper);
        sm.updateVolatility(0, 3e16);
    }

    function test_UpdateVolatility_WithinBounds() public {
        vm.startPrank(keeper);
        sm.updateVolatility(0, 1e17); // 10%

        // 2% change of 1e17 = 2e15
        uint256 newVol = 1e17 + 2e15; // 10.2%
        sm.updateVolatility(0, newVol);
        assertEq(sm.getPairVolatility(0), newVol);
        vm.stopPrank();
    }

    function test_UpdateVolatility_WithinBoundsDecrease() public {
        vm.startPrank(keeper);
        sm.updateVolatility(0, 1e17); // 10%

        uint256 newVol = 1e17 - 2e15; // 9.8%
        sm.updateVolatility(0, newVol);
        assertEq(sm.getPairVolatility(0), newVol);
        vm.stopPrank();
    }

    function test_UpdateVolatility_RevertExceedsBounds() public {
        vm.startPrank(keeper);
        sm.updateVolatility(0, 1e17); // 10%

        uint256 maxDelta = (1e17 * DEFAULT_MAX_VOL_CHANGE_BPS) / 10_000; // 2e15
        uint256 tooHigh = 1e17 + maxDelta + 1;
        uint256 delta = tooHigh - 1e17;

        vm.expectRevert(abi.encodeWithSelector(SpreadManager.VolatilityChangeExceeded.selector, delta, maxDelta));
        sm.updateVolatility(0, tooHigh);
        vm.stopPrank();
    }

    function test_UpdateVolatility_RevertNotKeeper() public {
        vm.prank(alice);
        vm.expectRevert(SpreadManager.CallerNotKeeper.selector);
        sm.updateVolatility(0, 3e16);
    }

    function test_UpdateVolatility_OwnerNotKeeper() public {
        vm.prank(owner);
        vm.expectRevert(SpreadManager.CallerNotKeeper.selector);
        sm.updateVolatility(0, 3e16);
    }

    function test_UpdateVolatility_FirstTimeSkipsBoundsCheck() public {
        // First update can set any value (no bounds check)
        vm.prank(keeper);
        sm.updateVolatility(0, 50e16); // 50% — would fail bounds if current was non-zero
        assertEq(sm.getPairVolatility(0), 50e16);
    }

    /*//////////////////////////////////////////////////////////////
                      ADMIN SETTER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetBaseSpreadBps() public {
        vm.prank(owner);
        sm.setBaseSpreadBps(10);
        assertEq(sm.baseSpreadBps(), 10);
    }

    function test_SetBaseSpreadBps_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit BaseSpreadBpsUpdated(10);

        vm.prank(owner);
        sm.setBaseSpreadBps(10);
    }

    function test_SetBaseSpreadBps_RevertOnZero() public {
        vm.prank(owner);
        vm.expectRevert(SpreadManager.ZeroBaseSpread.selector);
        sm.setBaseSpreadBps(0);
    }

    function test_SetBaseSpreadBps_RevertAboveMax() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SpreadManager.MaxSpreadBelowBase.selector, DEFAULT_MAX_SPREAD_BPS, 200));
        sm.setBaseSpreadBps(200);
    }

    function test_SetBaseSpreadBps_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        sm.setBaseSpreadBps(10);
    }

    function test_SetImpactFactor() public {
        vm.prank(owner);
        sm.setImpactFactor(5e5);
        assertEq(sm.impactFactor(), 5e5);
    }

    function test_SetImpactFactor_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit ImpactFactorUpdated(5e5);

        vm.prank(owner);
        sm.setImpactFactor(5e5);
    }

    function test_SetImpactFactor_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        sm.setImpactFactor(5e5);
    }

    function test_SetVolFactor() public {
        vm.prank(owner);
        sm.setVolFactor(200);
        assertEq(sm.volFactor(), 200);
    }

    function test_SetVolFactor_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit VolFactorUpdated(200);

        vm.prank(owner);
        sm.setVolFactor(200);
    }

    function test_SetVolFactor_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        sm.setVolFactor(200);
    }

    function test_SetMaxSpreadBps() public {
        vm.prank(owner);
        sm.setMaxSpreadBps(200);
        assertEq(sm.maxSpreadBps(), 200);
    }

    function test_SetMaxSpreadBps_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit MaxSpreadBpsUpdated(200);

        vm.prank(owner);
        sm.setMaxSpreadBps(200);
    }

    function test_SetMaxSpreadBps_RevertBelowBase() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SpreadManager.MaxSpreadBelowBase.selector, 3, DEFAULT_BASE_SPREAD_BPS));
        sm.setMaxSpreadBps(3);
    }

    function test_SetMaxSpreadBps_RevertTooHigh() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SpreadManager.MaxSpreadTooHigh.selector, 10_000));
        sm.setMaxSpreadBps(10_000);
    }

    function test_SetMaxSpreadBps_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        sm.setMaxSpreadBps(200);
    }

    function test_SetMaxVolatilityChangeBps() public {
        vm.prank(owner);
        sm.setMaxVolatilityChangeBps(500);
        assertEq(sm.maxVolatilityChangeBps(), 500);
    }

    function test_SetMaxVolatilityChangeBps_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit MaxVolatilityChangeBpsUpdated(500);

        vm.prank(owner);
        sm.setMaxVolatilityChangeBps(500);
    }

    function test_SetMaxVolatilityChangeBps_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        sm.setMaxVolatilityChangeBps(500);
    }

    function test_SetKeeper() public {
        address newKeeper = makeAddr("newKeeper");
        vm.prank(owner);
        sm.setKeeper(newKeeper);
        assertEq(sm.keeper(), newKeeper);
    }

    function test_SetKeeper_EmitsEvent() public {
        address newKeeper = makeAddr("newKeeper");

        vm.expectEmit(true, false, false, true);
        emit KeeperUpdated(newKeeper);

        vm.prank(owner);
        sm.setKeeper(newKeeper);
    }

    function test_SetKeeper_RevertOnZero() public {
        vm.prank(owner);
        vm.expectRevert(SpreadManager.ZeroAddress.selector);
        sm.setKeeper(address(0));
    }

    function test_SetKeeper_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        sm.setKeeper(makeAddr("newKeeper"));
    }

    /*//////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_GetSpreadBps_NeverExceedsMax(uint256 oi, uint256 vol) public {
        oi = bound(oi, 0, 1e36);
        vol = bound(vol, 0, 1e20);

        // Set volatility (first time, skips bounds)
        vm.prank(keeper);
        sm.updateVolatility(0, vol);

        uint256 spread = sm.getSpreadBps(0, oi);
        assertLe(spread, sm.maxSpreadBps());
    }

    function testFuzz_GetSpreadBps_MonotonicInOI(uint256 oi1, uint256 oi2) public view {
        oi1 = bound(oi1, 0, 1e36);
        oi2 = bound(oi2, oi1, 1e36);

        uint256 spread1 = sm.getSpreadBps(0, oi1);
        uint256 spread2 = sm.getSpreadBps(0, oi2);
        assertGe(spread2, spread1);
    }

    function testFuzz_GetSpreadBps_MonotonicInVol(uint256 vol1, uint256 vol2) public {
        vol1 = bound(vol1, 0, 1e20);
        vol2 = bound(vol2, vol1, 1e20);

        // Use two different pairs to avoid bounds check
        vm.startPrank(keeper);
        sm.updateVolatility(0, vol1);
        sm.updateVolatility(1, vol2);
        vm.stopPrank();

        uint256 spread1 = sm.getSpreadBps(0, 0);
        uint256 spread2 = sm.getSpreadBps(1, 0);
        assertGe(spread2, spread1);
    }

    function testFuzz_VolatilityBoundsEnforcement(uint256 initial, uint256 change) public {
        initial = bound(initial, 1e15, 1e19); // Non-zero starting vol
        change = bound(change, 0, 1e19);

        vm.startPrank(keeper);
        sm.updateVolatility(0, initial);

        uint256 maxDelta = (initial * DEFAULT_MAX_VOL_CHANGE_BPS) / 10_000;
        uint256 newVol = initial + change;
        uint256 delta = change;

        if (delta > maxDelta) {
            vm.expectRevert(abi.encodeWithSelector(SpreadManager.VolatilityChangeExceeded.selector, delta, maxDelta));
            sm.updateVolatility(0, newVol);
        } else {
            sm.updateVolatility(0, newVol);
            assertEq(sm.getPairVolatility(0), newVol);
        }
        vm.stopPrank();
    }

    function testFuzz_GetSpreadBps_AlwaysAtLeastBase(uint256 oi) public view {
        oi = bound(oi, 0, 1e36);
        uint256 spread = sm.getSpreadBps(0, oi);
        assertGe(spread, sm.baseSpreadBps());
    }
}
