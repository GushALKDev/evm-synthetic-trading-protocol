// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title OpenPnlLib
 * @author GushALKDev
 * @notice Stateless math for the unrealised PnL of the open positions of a pair, from O(1) aggregates
 * @dev Each position contributes a quantity q = size / openPrice (asset units, WAD). For a side with total
 *      size S and total quantity Q:
 *        longs:  pnl = price * Q - S
 *        shorts: pnl = S - price * Q
 *      clamped at minus the side's total collateral. Every rounding step overstates trader profit, so the
 *      result is a conservative liability for the Vault:
 *        q rounds up for longs and down for shorts; price * Q rounds up for longs and down for shorts;
 *        the conversion to USDC rounds toward +infinity.
 */
library OpenPnlLib {
    uint256 internal constant WAD = 1e18;
    /// @dev 18-decimal USD to USDC (6 decimals)
    uint256 internal constant WAD_PER_USDC = 1e12;

    /**
     * @notice Open totals of one pair, both sides
     * @dev Sizes are the pair's open interest (18 decimals), collateral is USDC (6 decimals), quantity is WAD.
     */
    struct PairTotals {
        uint256 longSize;
        uint256 longCollateral;
        uint256 longQuantity;
        uint256 shortSize;
        uint256 shortCollateral;
        uint256 shortQuantity;
    }

    /**
     * @notice Quantity contributed by one position: sizeWad * 1e18 / openPrice
     * @dev Rounded up for longs and down for shorts. The same inputs always give the same value, so removing a
     *      position subtracts exactly what adding it added.
     */
    function quantity(uint256 _sizeWad, uint256 _openPrice, bool _isLong) internal pure returns (uint256) {
        uint256 numerator = _sizeWad * WAD;
        if (_isLong) return (numerator + _openPrice - 1) / _openPrice;
        return numerator / _openPrice;
    }

    /**
     * @notice Unrealised PnL of one side at a price (18 decimals), clamped at minus the side's collateral
     */
    function sidePnl(uint256 _price, uint256 _size, uint256 _quantity, uint256 _collateral, bool _isLong) internal pure returns (int256 pnl) {
        uint256 product = _price * _quantity;
        if (_isLong) pnl = int256((product + WAD - 1) / WAD) - int256(_size);
        else pnl = int256(_size) - int256(product / WAD);
        int256 floor = -int256(_collateral * WAD_PER_USDC);
        if (pnl < floor) pnl = floor;
    }

    /**
     * @notice Net unrealised PnL of a pair (18 decimals) at the edge of the price band [price - conf, price + conf]
     *         that is highest for the traders
     * @dev Each clamped side is a convex function of the price, so their sum is convex and its maximum over the
     *      band is at one of the two edges.
     */
    function pairPnl(uint256 _price, uint256 _conf, PairTotals memory _t) internal pure returns (int256) {
        uint256 low = _conf >= _price ? 0 : _price - _conf;
        uint256 high = _price + _conf;
        int256 atLow =
            sidePnl(low, _t.longSize, _t.longQuantity, _t.longCollateral, true) + sidePnl(low, _t.shortSize, _t.shortQuantity, _t.shortCollateral, false);
        int256 atHigh =
            sidePnl(high, _t.longSize, _t.longQuantity, _t.longCollateral, true) + sidePnl(high, _t.shortSize, _t.shortQuantity, _t.shortCollateral, false);
        return atLow > atHigh ? atLow : atHigh;
    }

    /**
     * @notice 18-decimal USD to USDC, rounded toward +infinity (overstates trader profit for both signs)
     */
    function toUsdcUp(int256 _wad) internal pure returns (int256) {
        if (_wad >= 0) return int256((uint256(_wad) + WAD_PER_USDC - 1) / WAD_PER_USDC);
        return -int256(uint256(-_wad) / WAD_PER_USDC);
    }
}
