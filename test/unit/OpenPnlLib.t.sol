// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {OpenPnlLib} from "../../src/libraries/OpenPnlLib.sol";

contract OpenPnlLibTest is Test {
    uint256 constant PRICE = 50_000 * 1e18;

    function _totals(uint256 _longSize, uint256 _longQ, uint256 _longColl, uint256 _shortSize, uint256 _shortQ, uint256 _shortColl)
        internal
        pure
        returns (OpenPnlLib.PairTotals memory)
    {
        return OpenPnlLib.PairTotals(_longSize, _longColl, _longQ, _shortSize, _shortColl, _shortQ);
    }

    /*//////////////////////////////////////////////////////////////
                              QUANTITY
    //////////////////////////////////////////////////////////////*/

    /// @notice 1,000 USD at 50,000 is 0.02 asset units, exactly
    function test_Quantity_Exact() public pure {
        assertEq(OpenPnlLib.quantity(1_000 * 1e18, PRICE, true), 2e16);
        assertEq(OpenPnlLib.quantity(1_000 * 1e18, PRICE, false), 2e16);
    }

    /// @notice A non-exact quantity rounds up for longs and down for shorts (both overstate trader profit)
    function test_Quantity_RoundsTowardTraderProfit() public pure {
        // 1 USD at 3 USD per unit = 0.333... units
        assertEq(OpenPnlLib.quantity(1e18, 3e18, true), 333_333_333_333_333_334);
        assertEq(OpenPnlLib.quantity(1e18, 3e18, false), 333_333_333_333_333_333);
    }

    function testFuzz_Quantity_LongAtMostOneAboveShort(uint256 _size, uint256 _price) public pure {
        _size = bound(_size, 1e18, 1e32);
        _price = bound(_price, 1e6, 1e30);
        uint256 longQ = OpenPnlLib.quantity(_size, _price, true);
        uint256 shortQ = OpenPnlLib.quantity(_size, _price, false);
        assertGe(longQ, shortQ);
        assertLe(longQ - shortQ, 1);
    }

    /*//////////////////////////////////////////////////////////////
                              SIDE PNL
    //////////////////////////////////////////////////////////////*/

    /// @notice 0.02 units bought for 1,000 USD are worth 1,100 USD at 55,000: +100 USD for longs, -100 for shorts
    function test_SidePnl_LongAndShort() public pure {
        assertEq(OpenPnlLib.sidePnl(55_000 * 1e18, 1_000 * 1e18, 2e16, 100 * 1e6, true), 100 * 1e18);
        assertEq(OpenPnlLib.sidePnl(55_000 * 1e18, 1_000 * 1e18, 2e16, 100 * 1e6, false), -100 * 1e18);
    }

    /// @notice A side never loses more than its total collateral
    function test_SidePnl_ClampedAtMinusCollateral() public pure {
        // Long loses 50% of 1,000 USD notional with 100 USDC of collateral: clamped at -100 USD
        assertEq(OpenPnlLib.sidePnl(25_000 * 1e18, 1_000 * 1e18, 2e16, 100 * 1e6, true), -100 * 1e18);
        // Short loses 50%: clamped as well
        assertEq(OpenPnlLib.sidePnl(75_000 * 1e18, 1_000 * 1e18, 2e16, 100 * 1e6, false), -100 * 1e18);
    }

    function test_SidePnl_EmptySideIsZero() public pure {
        assertEq(OpenPnlLib.sidePnl(PRICE, 0, 0, 0, true), 0);
        assertEq(OpenPnlLib.sidePnl(PRICE, 0, 0, 0, false), 0);
    }

    /**
     * @notice The aggregate overstates the sum of exact per-position PnL (no clamp involved)
     * @dev Per position exact PnL: longs price * size / openPrice - size, shorts size - price * size / openPrice,
     *      computed here with the floor/ceil that understates trader profit, so any rounding in the aggregate
     *      shows up as aggregate >= reference.
     */
    function testFuzz_SidePnl_OverstatesPerPositionSum(uint256[4] memory _sizes, uint256[4] memory _openPrices, uint256 _price, bool _isLong) public pure {
        _price = bound(_price, 1e20, 1e24);
        uint256 size;
        uint256 q;
        int256 expected;
        for (uint256 i; i < 4; ++i) {
            uint256 s = bound(_sizes[i], 10 * 1e18, 1_000_000 * 1e18);
            uint256 p = bound(_openPrices[i], 1e20, 1e24);
            size += s;
            q += OpenPnlLib.quantity(s, p, _isLong);
            if (_isLong) expected += int256((_price * s) / p) - int256(s);
            else expected += int256(s) - int256((_price * s + p - 1) / p);
        }
        // Collateral large enough that the clamp does not bind
        int256 aggregate = OpenPnlLib.sidePnl(_price, size, q, type(uint64).max, _isLong);
        assertGe(aggregate, expected);
    }

    /*//////////////////////////////////////////////////////////////
                          CONFIDENCE BAND CHOICE
    //////////////////////////////////////////////////////////////*/

    /// @notice Long-heavy book: the upper band edge is the one that is worst for the vault
    function test_PairPnl_LongHeavyUsesUpperEdge() public pure {
        OpenPnlLib.PairTotals memory t = _totals(1_000 * 1e18, 2e16, 1_000 * 1e6, 0, 0, 0);
        uint256 conf = 500 * 1e18;
        assertEq(OpenPnlLib.pairPnl(PRICE, conf, t), OpenPnlLib.sidePnl(PRICE + conf, 1_000 * 1e18, 2e16, 1_000 * 1e6, true));
    }

    /// @notice Short-heavy book: the lower band edge
    function test_PairPnl_ShortHeavyUsesLowerEdge() public pure {
        OpenPnlLib.PairTotals memory t = _totals(0, 0, 0, 1_000 * 1e18, 2e16, 1_000 * 1e6);
        uint256 conf = 500 * 1e18;
        assertEq(OpenPnlLib.pairPnl(PRICE, conf, t), OpenPnlLib.sidePnl(PRICE - conf, 1_000 * 1e18, 2e16, 1_000 * 1e6, false));
    }

    /**
     * @notice The chosen value is at least the net PnL at any price inside the band, within 2 wei
     * @dev The clamped net is convex in the price, so the maximum over the band is at an edge. Tolerance of 2 wei
     *      (18 decimals, 2e-18 USD) justified: each side rounds price * quantity once, so the integer function can
     *      sit one wei per side above the line between the edges.
     */
    function testFuzz_PairPnl_AtLeastAnyPriceInBand(
        uint256 _longSize,
        uint256 _longOpen,
        uint256 _shortSize,
        uint256 _shortOpen,
        uint256 _conf,
        uint256 _offset
    ) public pure {
        _longSize = bound(_longSize, 0, 1_000_000 * 1e18);
        _shortSize = bound(_shortSize, 0, 1_000_000 * 1e18);
        uint256 longQ = OpenPnlLib.quantity(_longSize, bound(_longOpen, 1e22, 1e23), true);
        uint256 shortQ = OpenPnlLib.quantity(_shortSize, bound(_shortOpen, 1e22, 1e23), false);
        // Collateral 10% of notional so the clamp can bind
        OpenPnlLib.PairTotals memory t = _totals(_longSize, longQ, _longSize / 10 / 1e12, _shortSize, shortQ, _shortSize / 10 / 1e12);
        _conf = bound(_conf, 0, PRICE / 50);
        uint256 inside = PRICE - _conf + bound(_offset, 0, 2 * _conf);

        int256 chosen = OpenPnlLib.pairPnl(PRICE, _conf, t);
        int256 atInside = OpenPnlLib.sidePnl(inside, t.longSize, t.longQuantity, t.longCollateral, true)
            + OpenPnlLib.sidePnl(inside, t.shortSize, t.shortQuantity, t.shortCollateral, false);
        assertGe(chosen + 2, atInside);
    }

    /*//////////////////////////////////////////////////////////////
                          USDC CONVERSION
    //////////////////////////////////////////////////////////////*/

    function test_ToUsdcUp_RoundsTowardPlusInfinity() public pure {
        assertEq(OpenPnlLib.toUsdcUp(1), 1);
        assertEq(OpenPnlLib.toUsdcUp(1e12), 1);
        assertEq(OpenPnlLib.toUsdcUp(1e12 + 1), 2);
        assertEq(OpenPnlLib.toUsdcUp(-1), 0);
        assertEq(OpenPnlLib.toUsdcUp(-(1e12 + 1)), -1);
        assertEq(OpenPnlLib.toUsdcUp(0), 0);
    }
}
