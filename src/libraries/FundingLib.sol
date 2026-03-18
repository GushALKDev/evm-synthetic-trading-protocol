// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title FundingLib
 * @author GushALKDev
 * @notice Stateless library for funding rate calculations
 * @dev Funding rates balance long/short OI imbalance. The majority side pays the minority side.
 *      FundingRate = (OI_long - OI_short) * FUNDING_FACTOR
 *      cumulativeIndex_new = cumulativeIndex_old + FundingRate * deltaTime
 *      FundingOwed = PositionSize * (currentIndex - entryIndex)
 */
library FundingLib {
    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // ~0.003% per hour per unit of OI imbalance
    int256 public constant FUNDING_FACTOR = 1e10;

    /*//////////////////////////////////////////////////////////////
                            CALCULATIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculate the funding index delta for a given time period
     * @param _oiLongWad Long open interest (18 decimals)
     * @param _oiShortWad Short open interest (18 decimals)
     * @param _deltaTime Seconds elapsed since last update
     * @return indexDelta The change in cumulative funding index
     */
    function calculateIndexDelta(uint256 _oiLongWad, uint256 _oiShortWad, uint256 _deltaTime) internal pure returns (int256 indexDelta) {
        indexDelta = ((int256(_oiLongWad) - int256(_oiShortWad)) * FUNDING_FACTOR * int256(_deltaTime)) / 1e18;
    }

    /**
     * @notice Calculate funding owed by a position in USDC (6 decimals)
     * @dev Positive result = trader pays funding, negative = trader receives funding
     *      Long pays when index moved up (longs heavier), short pays when index moved down (shorts heavier)
     * @param _positionSizeWad Position size in 18 decimals
     * @param _isLong Whether the position is long
     * @param _currentIndex Current cumulative funding index
     * @param _entryIndex Entry cumulative funding index at trade open
     * @return fundingOwedUsdc Funding owed in USDC (6 decimals), positive = pays, negative = receives
     */
    function calculateFundingOwed(
        uint256 _positionSizeWad,
        bool _isLong,
        int256 _currentIndex,
        int256 _entryIndex
    ) internal pure returns (int256 fundingOwedUsdc) {
        int256 rawFunding = (int256(_positionSizeWad) * (_currentIndex - _entryIndex)) / 1e18;
        // Long: positive index delta means longs pay → fundingOwed is positive
        // Short: opposite direction
        if (_isLong) {
            fundingOwedUsdc = rawFunding / 1e12;
        } else {
            fundingOwedUsdc = -rawFunding / 1e12;
        }
    }
}
