// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";

/**
 * @title SpreadManager
 * @author GushALKDev
 * @notice Computes dynamic spread BPS based on OI impact and per-pair volatility
 * @dev Spread = BaseSpread + (OI × ImpactFactor / OI_PRECISION) + (Volatility × VolFactor / VOL_PRECISION), capped at maxSpreadBps.
 *      Keeper updates per-pair volatility on-chain; OI is passed by the caller (TradingEngine reads from TradingStorage).
 */
contract SpreadManager is Ownable {
    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant OI_PRECISION = 1e30;
    uint256 public constant VOL_PRECISION = 1e18;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    uint256 public baseSpreadBps;
    uint256 public impactFactor;
    uint256 public volFactor;
    uint256 public maxSpreadBps;
    uint256 public maxVolatilityChangeBps;
    address public keeper;

    mapping(uint256 => uint256) private _pairVolatility;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event VolatilityUpdated(uint256 indexed pairIndex, uint256 newVolatility);
    event BaseSpreadBpsUpdated(uint256 newBaseSpreadBps);
    event ImpactFactorUpdated(uint256 newImpactFactor);
    event VolFactorUpdated(uint256 newVolFactor);
    event MaxSpreadBpsUpdated(uint256 newMaxSpreadBps);
    event MaxVolatilityChangeBpsUpdated(uint256 newMaxVolatilityChangeBps);
    event KeeperUpdated(address indexed newKeeper);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error ZeroBaseSpread();
    error MaxSpreadBelowBase(uint256 maxSpread, uint256 baseSpread);
    error MaxSpreadTooHigh(uint256 maxSpread);
    error CallerNotKeeper();
    error VolatilityChangeExceeded(uint256 delta, uint256 maxDelta);

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _requireKeeper() internal view {
        if (msg.sender != keeper) revert CallerNotKeeper();
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        uint256 _baseSpreadBps,
        uint256 _impactFactor,
        uint256 _volFactor,
        uint256 _maxSpreadBps,
        uint256 _maxVolatilityChangeBps,
        address _keeper,
        address _owner
    ) {
        if (_keeper == address(0)) revert ZeroAddress();
        if (_baseSpreadBps == 0) revert ZeroBaseSpread();
        if (_maxSpreadBps < _baseSpreadBps) revert MaxSpreadBelowBase(_maxSpreadBps, _baseSpreadBps);
        if (_maxSpreadBps >= BPS_DENOMINATOR) revert MaxSpreadTooHigh(_maxSpreadBps);
        _initializeOwner(_owner);
        baseSpreadBps = _baseSpreadBps;
        impactFactor = _impactFactor;
        volFactor = _volFactor;
        maxSpreadBps = _maxSpreadBps;
        maxVolatilityChangeBps = _maxVolatilityChangeBps;
        keeper = _keeper;
    }

    /*//////////////////////////////////////////////////////////////
                            CORE VIEW
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculate total spread in BPS for a pair given its current OI
     * @param _pairIndex Trading pair index
     * @param _currentOI Current total open interest (18 decimals)
     * @return spreadBps Total spread in basis points, capped at maxSpreadBps
     */
    function getSpreadBps(uint256 _pairIndex, uint256 _currentOI) external view returns (uint256 spreadBps) {
        uint256 oiImpact = (_currentOI * impactFactor) / OI_PRECISION;
        uint256 volImpact = (_pairVolatility[_pairIndex] * volFactor) / VOL_PRECISION;
        spreadBps = baseSpreadBps + oiImpact + volImpact;
        if (spreadBps > maxSpreadBps) spreadBps = maxSpreadBps;
    }

    /*//////////////////////////////////////////////////////////////
                          KEEPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Update per-pair volatility (18 decimals). First update skips bounds check.
     */
    function updateVolatility(uint256 _pairIndex, uint256 _newVolatility) external {
        _requireKeeper();
        uint256 current = _pairVolatility[_pairIndex];
        if (current != 0) {
            uint256 delta = _newVolatility > current ? _newVolatility - current : current - _newVolatility;
            uint256 maxDelta = (current * maxVolatilityChangeBps) / BPS_DENOMINATOR;
            if (delta > maxDelta) revert VolatilityChangeExceeded(delta, maxDelta);
        }
        _pairVolatility[_pairIndex] = _newVolatility;
        emit VolatilityUpdated(_pairIndex, _newVolatility);
    }

    /*//////////////////////////////////////////////////////////////
                          ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setBaseSpreadBps(uint256 _baseSpreadBps) external onlyOwner {
        if (_baseSpreadBps == 0) revert ZeroBaseSpread();
        if (maxSpreadBps < _baseSpreadBps) revert MaxSpreadBelowBase(maxSpreadBps, _baseSpreadBps);
        baseSpreadBps = _baseSpreadBps;
        emit BaseSpreadBpsUpdated(_baseSpreadBps);
    }

    function setImpactFactor(uint256 _impactFactor) external onlyOwner {
        impactFactor = _impactFactor;
        emit ImpactFactorUpdated(_impactFactor);
    }

    function setVolFactor(uint256 _volFactor) external onlyOwner {
        volFactor = _volFactor;
        emit VolFactorUpdated(_volFactor);
    }

    function setMaxSpreadBps(uint256 _maxSpreadBps) external onlyOwner {
        if (_maxSpreadBps < baseSpreadBps) revert MaxSpreadBelowBase(_maxSpreadBps, baseSpreadBps);
        if (_maxSpreadBps >= BPS_DENOMINATOR) revert MaxSpreadTooHigh(_maxSpreadBps);
        maxSpreadBps = _maxSpreadBps;
        emit MaxSpreadBpsUpdated(_maxSpreadBps);
    }

    function setMaxVolatilityChangeBps(uint256 _maxVolatilityChangeBps) external onlyOwner {
        maxVolatilityChangeBps = _maxVolatilityChangeBps;
        emit MaxVolatilityChangeBpsUpdated(_maxVolatilityChangeBps);
    }

    function setKeeper(address _keeper) external onlyOwner {
        if (_keeper == address(0)) revert ZeroAddress();
        keeper = _keeper;
        emit KeeperUpdated(_keeper);
    }

    /*//////////////////////////////////////////////////////////////
                              GETTERS
    //////////////////////////////////////////////////////////////*/

    function getPairVolatility(uint256 _pairIndex) external view returns (uint256) {
        return _pairVolatility[_pairIndex];
    }
}
