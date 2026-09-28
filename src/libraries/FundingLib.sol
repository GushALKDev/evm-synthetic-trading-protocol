// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title FundingLib
 * @author GushALKDev
 * @notice Stateless library for funding rate calculations
 * @dev Funding is a transfer between traders on the same pair; the Vault is not a party to it.
 *      skew = (heavyOI - lightOI) / (heavyOI + lightOI)
 *      ratePerHour = min(fundingFactor * skew, MAX_FUNDING_RATE_PER_HOUR)
 *      The heavier side pays ratePerHour * heavyOI per hour. The lighter side receives exactly that
 *      total, pro rata to its OI, so its per-unit rate is ratePerHour * heavyOI / lightOI.
 *      Each side has its own cumulative index (funding per unit of notional, WAD, positive = paid).
 *      No funding accrues while either side has zero OI.
 *      Rounding: payer index deltas and payer amounts round up, receiver index deltas and receiver
 *      amounts round down, so the total credited never exceeds the total charged.
 */
library FundingLib {
    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant WAD = 1e18;
    uint256 internal constant SECONDS_PER_HOUR = 3600;
    /// @dev size (18 decimals) * index delta (WAD) / 1e30 = USDC (6 decimals)
    uint256 internal constant INDEX_TO_USDC = 1e30;

    /// @notice Immutable ceiling on the rate paid by the heavier side: 0.01% of its notional per hour (WAD)
    uint256 public constant MAX_FUNDING_RATE_PER_HOUR = 1e14;
    /// @notice Lowest settable factor (rate per hour at 100% skew, WAD): 0.0001% per hour
    uint256 public constant MIN_FUNDING_FACTOR = 1e12;
    /// @notice Highest settable factor: 0.1% per hour at 100% skew, which reaches the ceiling at 10% skew
    uint256 public constant MAX_FUNDING_FACTOR = 1e15;
    /// @notice Factor used at deployment: reaches the ceiling only at 100% skew
    uint256 public constant DEFAULT_FUNDING_FACTOR = 1e14;

    /*//////////////////////////////////////////////////////////////
                            CALCULATIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Index deltas for both sides of a pair over one accrual interval with constant OI
     * @param _oiLongWad Long open interest (18 decimals)
     * @param _oiShortWad Short open interest (18 decimals)
     * @param _deltaTime Seconds elapsed since the last update
     * @param _fundingFactor Rate per hour at 100% skew (WAD)
     * @return longDelta Change of the long index (positive = longs pay)
     * @return shortDelta Change of the short index (positive = shorts pay)
     */
    function calculateIndexDeltas(uint256 _oiLongWad, uint256 _oiShortWad, uint256 _deltaTime, uint256 _fundingFactor)
        internal
        pure
        returns (int256 longDelta, int256 shortDelta)
    {
        if (_oiLongWad == 0 || _oiShortWad == 0 || _oiLongWad == _oiShortWad) return (0, 0);

        bool longsHeavy = _oiLongWad > _oiShortWad;
        (uint256 heavy, uint256 light) = longsHeavy ? (_oiLongWad, _oiShortWad) : (_oiShortWad, _oiLongWad);

        uint256 ratePerHour = (_fundingFactor * (heavy - light)) / (heavy + light);
        if (ratePerHour > MAX_FUNDING_RATE_PER_HOUR) ratePerHour = MAX_FUNDING_RATE_PER_HOUR;

        uint256 payerDelta = _ceilDiv(ratePerHour * _deltaTime, SECONDS_PER_HOUR);
        // light * receiverDelta <= heavy * payerDelta: receivers are never credited more than payers owe
        uint256 receiverDelta = (payerDelta * heavy) / light;

        // forge-lint: disable-next-line(unsafe-typecast) safe: deltas are capped per hour and scaled by heavy / light OI, both below 2^128 (FundingLib.sol:61)
        if (longsHeavy) return (int256(payerDelta), -int256(receiverDelta));
        // forge-lint: disable-next-line(unsafe-typecast) safe: same bound as the line above (FundingLib.sol:61)
        return (-int256(receiverDelta), int256(payerDelta));
    }

    /**
     * @notice Funding owed by a position in USDC (6 decimals)
     * @dev Uses the index of the position's own side. Net payers round up, net receivers round down.
     * @param _positionSizeWad Position size in 18 decimals
     * @param _currentIndex Current cumulative index of the position's side
     * @param _entryIndex Index of the position's side when it opened
     * @return fundingOwedUsdc Positive = the trader pays, negative = the trader receives
     */
    function calculateFundingOwed(uint256 _positionSizeWad, int256 _currentIndex, int256 _entryIndex) internal pure returns (int256 fundingOwedUsdc) {
        int256 delta = _currentIndex - _entryIndex;
        // forge-lint: disable-next-line(unsafe-typecast) safe: delta >= 0 here, and size * delta stays below 2^255 for OI below 2^128 (TradingStorage.sol:396)
        if (delta >= 0) return int256(_ceilDiv(_positionSizeWad * uint256(delta), INDEX_TO_USDC));
        // forge-lint: disable-next-line(unsafe-typecast) safe: delta < 0 here and far from type(int256).min (TradingStorage.sol:396)
        return -int256((_positionSizeWad * uint256(-delta)) / INDEX_TO_USDC);
    }

    function _ceilDiv(uint256 _a, uint256 _b) private pure returns (uint256) {
        return _a == 0 ? 0 : (_a - 1) / _b + 1;
    }
}
