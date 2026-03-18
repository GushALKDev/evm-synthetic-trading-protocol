// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {FundingLib} from "../../src/libraries/FundingLib.sol";

contract FundingLibTest is Test {
    /*//////////////////////////////////////////////////////////////
                      INDEX DELTA TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CalculateIndexDelta_LongsHeavier() public pure {
        // OI long > OI short → positive delta
        int256 delta = FundingLib.calculateIndexDelta(2_000 * 1e18, 1_000 * 1e18, 3600);
        assertGt(delta, 0);
    }

    function test_CalculateIndexDelta_ShortsHeavier() public pure {
        // OI short > OI long → negative delta
        int256 delta = FundingLib.calculateIndexDelta(1_000 * 1e18, 2_000 * 1e18, 3600);
        assertLt(delta, 0);
    }

    function test_CalculateIndexDelta_Balanced() public pure {
        // Equal OI → zero delta
        int256 delta = FundingLib.calculateIndexDelta(1_000 * 1e18, 1_000 * 1e18, 3600);
        assertEq(delta, 0);
    }

    function test_CalculateIndexDelta_ZeroTime() public pure {
        // No time elapsed → zero delta regardless of imbalance
        int256 delta = FundingLib.calculateIndexDelta(2_000 * 1e18, 1_000 * 1e18, 0);
        assertEq(delta, 0);
    }

    function test_CalculateIndexDelta_ZeroOI() public pure {
        // No OI on either side → zero delta
        int256 delta = FundingLib.calculateIndexDelta(0, 0, 3600);
        assertEq(delta, 0);
    }

    function test_CalculateIndexDelta_ExactMath() public pure {
        // (2000e18 - 1000e18) * 1e10 * 3600 / 1e18
        // = 1000e18 * 1e10 * 3600 / 1e18
        // = 1000 * 1e10 * 3600
        // = 36_000_000_000_000 (3.6e13)
        int256 delta = FundingLib.calculateIndexDelta(2_000 * 1e18, 1_000 * 1e18, 3600);
        assertEq(delta, int256(1_000) * 1e10 * 3600);
    }

    /*//////////////////////////////////////////////////////////////
                      FUNDING OWED TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CalculateFundingOwed_LongPays() public pure {
        // Long pays when index moved up (positive delta)
        int256 entryIndex = 0;
        int256 currentIndex = 36_000_000_000_000; // positive delta
        uint256 posSize = 1_000 * 1e18; // 1000 USD position in 18 dec

        int256 owed = FundingLib.calculateFundingOwed(posSize, true, currentIndex, entryIndex);
        // rawFunding = 1000e18 * 36e12 / 1e18 = 36_000_000_000_000_000 (3.6e16)
        // Long: fundingOwedUsdc = rawFunding / 1e12 = 36_000 (0.036 USDC)
        assertGt(owed, 0);
        assertEq(owed, 36_000);
    }

    function test_CalculateFundingOwed_ShortReceives() public pure {
        // Short receives when index moved up (longs heavier)
        int256 entryIndex = 0;
        int256 currentIndex = 36_000_000_000_000;
        uint256 posSize = 1_000 * 1e18;

        int256 owed = FundingLib.calculateFundingOwed(posSize, false, currentIndex, entryIndex);
        assertLt(owed, 0); // Negative = receives
        assertEq(owed, -36_000);
    }

    function test_CalculateFundingOwed_LongReceives() public pure {
        // Long receives when index moved down (shorts heavier)
        int256 entryIndex = 0;
        int256 currentIndex = -36_000_000_000_000;
        uint256 posSize = 1_000 * 1e18;

        int256 owed = FundingLib.calculateFundingOwed(posSize, true, currentIndex, entryIndex);
        assertLt(owed, 0); // Long receives when shorts are heavier
    }

    function test_CalculateFundingOwed_ShortPays() public pure {
        // Short pays when index moved down (shorts heavier)
        int256 entryIndex = 0;
        int256 currentIndex = -36_000_000_000_000;
        uint256 posSize = 1_000 * 1e18;

        int256 owed = FundingLib.calculateFundingOwed(posSize, false, currentIndex, entryIndex);
        assertGt(owed, 0); // Positive = pays
    }

    function test_CalculateFundingOwed_NoChange() public pure {
        // No index change → zero funding
        int256 owed = FundingLib.calculateFundingOwed(1_000 * 1e18, true, 100, 100);
        assertEq(owed, 0);
    }

    function test_CalculateFundingOwed_PrecisionConversion() public pure {
        // Verify 18dec → 6dec conversion via /1e12
        // posSize = 100_000e18 (100k USD), index delta = 1e12
        int256 owed = FundingLib.calculateFundingOwed(100_000 * 1e18, true, 1e12, 0);
        // rawFunding = 100_000e18 * 1e12 / 1e18 = 100_000e12
        // / 1e12 = 100_000 (0.1 USDC)
        assertEq(owed, 100_000);
    }

    /*//////////////////////////////////////////////////////////////
                          FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_IndexDelta_Symmetry(uint256 oiLong, uint256 oiShort, uint256 deltaTime) public pure {
        oiLong = bound(oiLong, 0, 100_000_000 * 1e18);
        oiShort = bound(oiShort, 0, 100_000_000 * 1e18);
        deltaTime = bound(deltaTime, 0, 365 days);

        int256 delta = FundingLib.calculateIndexDelta(oiLong, oiShort, deltaTime);
        int256 deltaSwapped = FundingLib.calculateIndexDelta(oiShort, oiLong, deltaTime);

        // Symmetric: swapping long/short negates the delta
        assertEq(delta, -deltaSwapped);
    }

    function testFuzz_FundingOwed_LongShortOpposite(uint256 posSize, int256 currentIndex, int256 entryIndex) public pure {
        posSize = bound(posSize, 1e18, 100_000_000 * 1e18);
        currentIndex = bound(currentIndex, -1e30, 1e30);
        entryIndex = bound(entryIndex, -1e30, 1e30);

        int256 longOwed = FundingLib.calculateFundingOwed(posSize, true, currentIndex, entryIndex);
        int256 shortOwed = FundingLib.calculateFundingOwed(posSize, false, currentIndex, entryIndex);

        // Long and short always pay opposite
        assertEq(longOwed, -shortOwed);
    }

    function testFuzz_IndexDelta_MonotonicWithTime(uint256 oiLong, uint256 oiShort, uint256 t1, uint256 t2) public pure {
        oiLong = bound(oiLong, 0, 100_000_000 * 1e18);
        oiShort = bound(oiShort, 0, 100_000_000 * 1e18);
        t1 = bound(t1, 0, 365 days);
        t2 = bound(t2, t1, 365 days);

        int256 delta1 = FundingLib.calculateIndexDelta(oiLong, oiShort, t1);
        int256 delta2 = FundingLib.calculateIndexDelta(oiLong, oiShort, t2);

        // More time → larger absolute delta (or equal)
        if (oiLong >= oiShort) {
            assertGe(delta2, delta1);
        } else {
            assertLe(delta2, delta1);
        }
    }

    function testFuzz_FundingOwed_LinearWithSize(uint256 posSize, int256 currentIndex, int256 entryIndex) public pure {
        posSize = bound(posSize, 1e18, 50_000_000 * 1e18);
        currentIndex = bound(currentIndex, -1e25, 1e25);
        entryIndex = bound(entryIndex, -1e25, 1e25);

        int256 owedSingle = FundingLib.calculateFundingOwed(posSize, true, currentIndex, entryIndex);
        int256 owedDouble = FundingLib.calculateFundingOwed(posSize * 2, true, currentIndex, entryIndex);

        // Double position size → double funding (within ±1 for integer division rounding)
        assertApproxEqAbs(owedDouble, owedSingle * 2, 1);
    }
}
