// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {FundingLib} from "../../src/libraries/FundingLib.sol";

contract FundingLibTest is Test {
    uint256 constant FACTOR = 1e14; // FundingLib.DEFAULT_FUNDING_FACTOR: 0.01% per hour at 100% skew
    uint256 constant CEILING = 1e14; // FundingLib.MAX_FUNDING_RATE_PER_HOUR

    /*//////////////////////////////////////////////////////////////
                      INDEX DELTA TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CalculateIndexDeltas_LongsHeavier_LongsPayShortsReceive() public pure {
        (int256 longDelta, int256 shortDelta) = FundingLib.calculateIndexDeltas(2_000 * 1e18, 1_000 * 1e18, 3600, FACTOR);
        assertGt(longDelta, 0);
        assertLt(shortDelta, 0);
    }

    function test_CalculateIndexDeltas_ShortsHeavier_ShortsPayLongsReceive() public pure {
        (int256 longDelta, int256 shortDelta) = FundingLib.calculateIndexDeltas(1_000 * 1e18, 2_000 * 1e18, 3600, FACTOR);
        assertLt(longDelta, 0);
        assertGt(shortDelta, 0);
    }

    function test_CalculateIndexDeltas_Balanced() public pure {
        (int256 longDelta, int256 shortDelta) = FundingLib.calculateIndexDeltas(1_000 * 1e18, 1_000 * 1e18, 3600, FACTOR);
        assertEq(longDelta, 0);
        assertEq(shortDelta, 0);
    }

    function test_CalculateIndexDeltas_ZeroTime() public pure {
        (int256 longDelta, int256 shortDelta) = FundingLib.calculateIndexDeltas(2_000 * 1e18, 1_000 * 1e18, 0, FACTOR);
        assertEq(longDelta, 0);
        assertEq(shortDelta, 0);
    }

    /// @notice With no counterparty on one side there is nobody to pay, so nothing accrues
    function test_CalculateIndexDeltas_OneSideEmpty_NoFunding() public pure {
        (int256 longDelta, int256 shortDelta) = FundingLib.calculateIndexDeltas(5_000 * 1e18, 0, 3600, FACTOR);
        assertEq(longDelta, 0);
        assertEq(shortDelta, 0);
        (longDelta, shortDelta) = FundingLib.calculateIndexDeltas(0, 5_000 * 1e18, 3600, FACTOR);
        assertEq(longDelta, 0);
        assertEq(shortDelta, 0);
    }

    /**
     * @notice skew = (3000 - 1000) / (3000 + 1000) = 0.5, rate = 1e14 * 0.5 = 5e13 per hour
     *         payer delta = 5e13 * 3600 / 3600 = 5e13; receiver delta = 5e13 * 3000 / 1000 = 1.5e14
     */
    function test_CalculateIndexDeltas_ExactMath() public pure {
        (int256 longDelta, int256 shortDelta) = FundingLib.calculateIndexDeltas(3_000 * 1e18, 1_000 * 1e18, 3600, FACTOR);
        assertEq(longDelta, 5e13);
        assertEq(shortDelta, -15e13);
    }

    /// @notice The rate depends on the relative skew, so scaling both sides leaves it unchanged
    function test_CalculateIndexDeltas_DependsOnRelativeSkewOnly() public pure {
        (int256 small,) = FundingLib.calculateIndexDeltas(3_000 * 1e18, 1_000 * 1e18, 3600, FACTOR);
        (int256 large,) = FundingLib.calculateIndexDeltas(3_000_000 * 1e18, 1_000_000 * 1e18, 3600, FACTOR);
        assertEq(small, large);
    }

    /// @notice The maximum factor reaches the ceiling at 10% skew and never exceeds it
    function test_CalculateIndexDeltas_CappedAtCeiling() public pure {
        uint256 maxFactor = FundingLib.MAX_FUNDING_FACTOR;
        (int256 fullSkew,) = FundingLib.calculateIndexDeltas(1_000_000 * 1e18, 1e18, 3600, maxFactor);
        assertEq(fullSkew, int256(CEILING));
        // skew = (55 - 45) / 100 = 10%: 1e15 * 0.1 = 1e14 = ceiling
        (int256 tenPercent,) = FundingLib.calculateIndexDeltas(55 * 1e18, 45 * 1e18, 3600, maxFactor);
        assertEq(tenPercent, int256(CEILING));
    }

    /// @notice Payer index deltas round up: one second at a tiny rate still charges one index unit
    function test_CalculateIndexDeltas_PayerDeltaRoundsUp() public pure {
        // rate = 1e12 * (2 - 1) / 3 = 333_333_333_333 per hour; 1 s = 92_592_592.59... -> 92_592_593
        (int256 longDelta,) = FundingLib.calculateIndexDeltas(2e18, 1e18, 1, 1e12);
        assertEq(longDelta, 92_592_593);
    }

    /*//////////////////////////////////////////////////////////////
                      FUNDING OWED TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice 1,000 USD notional, index moved by 1e14 (0.01%): owes 0.1 USDC
    function test_CalculateFundingOwed_Pays() public pure {
        int256 owed = FundingLib.calculateFundingOwed(1_000 * 1e18, 1e14, 0);
        assertEq(owed, 100_000);
    }

    function test_CalculateFundingOwed_Receives() public pure {
        int256 owed = FundingLib.calculateFundingOwed(1_000 * 1e18, -1e14, 0);
        assertEq(owed, -100_000);
    }

    function test_CalculateFundingOwed_NoChange() public pure {
        int256 owed = FundingLib.calculateFundingOwed(1_000 * 1e18, 100, 100);
        assertEq(owed, 0);
    }

    /// @notice A payer's fractional amount rounds up, a receiver's rounds down
    function test_CalculateFundingOwed_RoundsAgainstTheTrader() public pure {
        // 1 USD notional * 1 index unit = 1e18 / 1e30 of a USDC unit
        assertEq(FundingLib.calculateFundingOwed(1e18, 1, 0), 1);
        assertEq(FundingLib.calculateFundingOwed(1e18, -1, 0), 0);
    }

    /*//////////////////////////////////////////////////////////////
                          FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Swapping the sides swaps the deltas
    function testFuzz_IndexDeltas_Symmetry(uint256 oiLong, uint256 oiShort, uint256 deltaTime, uint256 factor) public pure {
        oiLong = bound(oiLong, 0, 100_000_000 * 1e18);
        oiShort = bound(oiShort, 0, 100_000_000 * 1e18);
        deltaTime = bound(deltaTime, 0, 365 days);
        factor = bound(factor, FundingLib.MIN_FUNDING_FACTOR, FundingLib.MAX_FUNDING_FACTOR);

        (int256 longDelta, int256 shortDelta) = FundingLib.calculateIndexDeltas(oiLong, oiShort, deltaTime, factor);
        (int256 longSwapped, int256 shortSwapped) = FundingLib.calculateIndexDeltas(oiShort, oiLong, deltaTime, factor);
        assertEq(longDelta, shortSwapped);
        assertEq(shortDelta, longSwapped);
    }

    /**
     * @notice Zero sum at the index level: the light side is credited at most what the heavy side is charged,
     *         and the heavy side pays at most the ceiling on its notional
     */
    function testFuzz_IndexDeltas_CreditsNeverExceedCharges(uint256 oiLong, uint256 oiShort, uint256 deltaTime, uint256 factor) public pure {
        oiLong = bound(oiLong, 1e18, 100_000_000 * 1e18);
        oiShort = bound(oiShort, 1e18, 100_000_000 * 1e18);
        deltaTime = bound(deltaTime, 0, 365 days);
        factor = bound(factor, FundingLib.MIN_FUNDING_FACTOR, FundingLib.MAX_FUNDING_FACTOR);

        (int256 longDelta, int256 shortDelta) = FundingLib.calculateIndexDeltas(oiLong, oiShort, deltaTime, factor);
        int256 charged = int256(oiLong) * longDelta + int256(oiShort) * shortDelta;
        assertGe(charged, 0, "credits exceed charges");

        uint256 payerDelta = uint256(longDelta > 0 ? longDelta : shortDelta > 0 ? shortDelta : int256(0));
        assertLe(payerDelta, (CEILING * deltaTime + 3599) / 3600, "rate above the ceiling");
    }

    function testFuzz_IndexDeltas_MonotonicWithTime(uint256 oiLong, uint256 oiShort, uint256 t1, uint256 t2) public pure {
        oiLong = bound(oiLong, 0, 100_000_000 * 1e18);
        oiShort = bound(oiShort, 0, 100_000_000 * 1e18);
        t1 = bound(t1, 0, 365 days);
        t2 = bound(t2, t1, 365 days);

        (int256 long1,) = FundingLib.calculateIndexDeltas(oiLong, oiShort, t1, FACTOR);
        (int256 long2,) = FundingLib.calculateIndexDeltas(oiLong, oiShort, t2, FACTOR);
        if (oiLong >= oiShort) assertGe(long2, long1);
        else assertLe(long2, long1);
    }

    /// @notice Doubling the size doubles the amount, within the one-unit rounding of each call
    function testFuzz_FundingOwed_LinearWithSize(uint256 posSize, int256 currentIndex, int256 entryIndex) public pure {
        posSize = bound(posSize, 1e18, 50_000_000 * 1e18);
        currentIndex = bound(currentIndex, -1e25, 1e25);
        entryIndex = bound(entryIndex, -1e25, 1e25);

        int256 owedSingle = FundingLib.calculateFundingOwed(posSize, currentIndex, entryIndex);
        int256 owedDouble = FundingLib.calculateFundingOwed(posSize * 2, currentIndex, entryIndex);

        // Each call rounds once (up for payers, down for receivers), so 2 * single and double differ by at most 1
        assertApproxEqAbs(owedDouble, owedSingle * 2, 1);
    }
}
