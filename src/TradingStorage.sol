// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/**
 * @title TradingStorage
 * @author GushALKDev
 * @notice Custodies trader collateral and stores all trade/pair data for the Synthetic Trading Protocol
 * @dev State and custody layer — only TradingEngine can mutate trade data and move funds
 */
contract TradingStorage is Ownable {
    using SafeTransferLib for address;

    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Represents an open trading position
     * @dev Packed into 3 storage slots (down from 10)
     */
    struct Trade {
        address user; // 20 bytes ─┐
        bool isLong; //  1 byte   │
        uint16 pairIndex; //  2 bytes  │  Slot 0 (31 bytes)
        uint16 leverage; //  2 bytes  │
        uint48 timestamp; //  6 bytes ─┘
        uint32 index; //  4 bytes ─┐
        uint64 collateral; //  8 bytes  │  Slot 1 (28 bytes)
        uint128 openPrice; // 16 bytes ─┘
        uint128 tp; // 16 bytes ─┐  Slot 2 (32 bytes)
        uint128 sl; // 16 bytes ─┘
    }

    /**
     * @notice Configuration for a trading pair
     */
    struct Pair {
        string name; // Slot 0 (pointer)
        uint128 maxOI; // 16 bytes ─┐
        uint16 maxLeverage; //  2 bytes  │  Slot 1 (19 bytes)
        bool isActive; //  1 byte  ─┘
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The underlying asset (USDC)
     */
    address public immutable ASSET;

    /**
     * @notice The TradingEngine address authorized to mutate state and move funds
     */
    address public tradingEngine;

    /**
     * @notice Auto-incrementing trade ID counter
     */
    uint32 private _tradeCounter;

    /**
     * @notice Trade data by ID
     */
    mapping(uint256 => Trade) private _trades;

    /**
     * @notice Active trade IDs per user
     */
    mapping(address => uint256[]) private _userTrades;

    /**
     * @notice Total open interest per pair (18 decimals)
     */
    mapping(uint256 => uint256) private _openInterest;

    /**
     * @notice Trading pair configurations
     */
    Pair[] private _pairs;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event TradeStored(uint256 indexed tradeId, address indexed user, uint16 pairIndex);
    event TradeDeleted(uint256 indexed tradeId, address indexed user);
    event TradeTpUpdated(uint256 indexed tradeId, uint128 newTp);
    event TradeSlUpdated(uint256 indexed tradeId, uint128 newSl);
    event OpenInterestUpdated(uint256 indexed pairIndex, uint256 newOI);
    event CollateralSent(address indexed to, uint256 amount);
    event PairAdded(uint256 indexed pairIndex, string name);
    event PairUpdated(uint256 indexed pairIndex);
    event TradingEngineUpdated(address indexed newEngine);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error CallerNotTradingEngine();
    error ZeroAddress();
    error TradeNotFound(uint256 tradeId);
    error PairNotFound(uint256 pairIndex);
    error InsufficientBalance(uint256 requested, uint256 available);
    error EmptyPairName();
    error ZeroMaxLeverage();
    error ZeroMaxOI();

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyTradingEngine() {
        _requireTradingEngine();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _requireTradingEngine() internal view {
        if (msg.sender != tradingEngine) revert CallerNotTradingEngine();
    }

    /**
     * @dev Removes a trade ID from the user's trade array using swap-and-pop
     */
    function _removeFromUserTrades(address _user, uint256 _tradeId) internal {
        uint256[] storage trades = _userTrades[_user];
        uint256 len = trades.length;
        for (uint256 i; i < len; ) {
            if (trades[i] == _tradeId) {
                trades[i] = trades[len - 1];
                trades.pop();
                return;
            }
            unchecked {
                ++i;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _asset, address _owner) {
        if (_asset == address(0)) revert ZeroAddress();
        _initializeOwner(_owner);
        ASSET = _asset;
    }

    /*//////////////////////////////////////////////////////////////
                        TRADING ENGINE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Store a new trade and assign an auto-incremented ID
     * @param _user Position owner
     * @param _isLong true = LONG, false = SHORT
     * @param _pairIndex Trading pair index
     * @param _leverage Leverage multiplier
     * @param _collateral USDC amount (6 decimals)
     * @param _openPrice Entry price (18 decimals)
     * @param _tp Take profit price (0 = not set)
     * @param _sl Stop loss price (0 = not set)
     * @return tradeId The assigned trade ID
     */
    function storeTrade(
        address _user,
        bool _isLong,
        uint16 _pairIndex,
        uint16 _leverage,
        uint64 _collateral,
        uint128 _openPrice,
        uint128 _tp,
        uint128 _sl
    ) external onlyTradingEngine returns (uint32 tradeId) {
        if (_pairIndex >= _pairs.length) revert PairNotFound(_pairIndex);

        tradeId = _tradeCounter++;

        _trades[tradeId] = Trade({
            user: _user,
            isLong: _isLong,
            pairIndex: _pairIndex,
            leverage: _leverage,
            timestamp: uint48(block.timestamp),
            index: tradeId,
            collateral: _collateral,
            openPrice: _openPrice,
            tp: _tp,
            sl: _sl
        });

        _userTrades[_user].push(tradeId);

        emit TradeStored(tradeId, _user, _pairIndex);
    }

    /**
     * @notice Delete a trade from storage
     * @param _tradeId The trade ID to delete
     */
    function deleteTrade(uint256 _tradeId) external onlyTradingEngine {
        Trade storage trade = _trades[_tradeId];
        if (trade.user == address(0)) revert TradeNotFound(_tradeId);

        address user = trade.user;

        _removeFromUserTrades(user, _tradeId);
        delete _trades[_tradeId];

        emit TradeDeleted(_tradeId, user);
    }

    /**
     * @notice Update the take profit price of a trade
     * @param _tradeId The trade ID
     * @param _newTp The new take profit price (0 to clear)
     */
    function updateTradeTp(uint256 _tradeId, uint128 _newTp) external onlyTradingEngine {
        Trade storage trade = _trades[_tradeId];
        if (trade.user == address(0)) revert TradeNotFound(_tradeId);
        trade.tp = _newTp;
        emit TradeTpUpdated(_tradeId, _newTp);
    }

    /**
     * @notice Update the stop loss price of a trade
     * @param _tradeId The trade ID
     * @param _newSl The new stop loss price (0 to clear)
     */
    function updateTradeSl(uint256 _tradeId, uint128 _newSl) external onlyTradingEngine {
        Trade storage trade = _trades[_tradeId];
        if (trade.user == address(0)) revert TradeNotFound(_tradeId);
        trade.sl = _newSl;
        emit TradeSlUpdated(_tradeId, _newSl);
    }

    /**
     * @notice Increase open interest for a pair
     * @param _pairIndex The pair index
     * @param _amount The amount to add (18 decimals)
     */
    function increaseOpenInterest(uint256 _pairIndex, uint256 _amount) external onlyTradingEngine {
        if (_pairIndex >= _pairs.length) revert PairNotFound(_pairIndex);
        uint256 newOI = _openInterest[_pairIndex] + _amount;
        _openInterest[_pairIndex] = newOI;
        emit OpenInterestUpdated(_pairIndex, newOI);
    }

    /**
     * @notice Decrease open interest for a pair
     * @param _pairIndex The pair index
     * @param _amount The amount to subtract (18 decimals)
     */
    function decreaseOpenInterest(uint256 _pairIndex, uint256 _amount) external onlyTradingEngine {
        if (_pairIndex >= _pairs.length) revert PairNotFound(_pairIndex);
        uint256 newOI = _openInterest[_pairIndex] - _amount;
        _openInterest[_pairIndex] = newOI;
        emit OpenInterestUpdated(_pairIndex, newOI);
    }

    /**
     * @notice Transfer collateral out to any address (trader or Vault)
     * @param _to The recipient address
     * @param _amount The amount of USDC to send
     */
    function sendCollateral(address _to, uint256 _amount) external onlyTradingEngine {
        uint256 balance = ASSET.balanceOf(address(this));
        if (_amount > balance) revert InsufficientBalance(_amount, balance);

        ASSET.safeTransfer(_to, _amount);

        emit CollateralSent(_to, _amount);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get a trade by ID
     * @param _tradeId The trade ID
     * @return The trade data
     */
    function getTrade(uint256 _tradeId) external view returns (Trade memory) {
        return _trades[_tradeId];
    }

    /**
     * @notice Get all active trade IDs for a user
     * @param _user The user address
     * @return Array of trade IDs
     */
    function getUserTrades(address _user) external view returns (uint256[] memory) {
        return _userTrades[_user];
    }

    /**
     * @notice Get the number of active trades for a user
     * @param _user The user address
     * @return The trade count
     */
    function getUserActiveTradesCount(address _user) external view returns (uint256) {
        return _userTrades[_user].length;
    }

    /**
     * @notice Get the total open interest for a pair
     * @param _pairIndex The pair index
     * @return The total OI (18 decimals)
     */
    function getOpenInterest(uint256 _pairIndex) external view returns (uint256) {
        return _openInterest[_pairIndex];
    }

    /**
     * @notice Get a pair configuration
     * @param _pairIndex The pair index
     * @return The pair data
     */
    function getPair(uint256 _pairIndex) external view returns (Pair memory) {
        if (_pairIndex >= _pairs.length) revert PairNotFound(_pairIndex);
        return _pairs[_pairIndex];
    }

    /**
     * @notice Get the total number of pairs
     * @return The pair count
     */
    function getPairsCount() external view returns (uint256) {
        return _pairs.length;
    }

    /**
     * @notice Get the current trade counter (next trade ID)
     * @return The trade counter
     */
    function getTradeCounter() external view returns (uint32) {
        return _tradeCounter;
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set the TradingEngine address
     * @param _tradingEngine The new TradingEngine address
     */
    function setTradingEngine(address _tradingEngine) external onlyOwner {
        if (_tradingEngine == address(0)) revert ZeroAddress();
        tradingEngine = _tradingEngine;
        emit TradingEngineUpdated(_tradingEngine);
    }

    /**
     * @notice Add a new trading pair
     * @param _name The pair name (e.g., "BTC/USD")
     * @param _maxLeverage The maximum leverage allowed
     * @param _maxOI The maximum open interest (18 decimals)
     * @return pairIndex The index of the new pair
     */
    function addPair(string calldata _name, uint16 _maxLeverage, uint128 _maxOI) external onlyOwner returns (uint256 pairIndex) {
        if (bytes(_name).length == 0) revert EmptyPairName();
        if (_maxLeverage == 0) revert ZeroMaxLeverage();
        if (_maxOI == 0) revert ZeroMaxOI();

        pairIndex = _pairs.length;
        _pairs.push(Pair({name: _name, maxLeverage: _maxLeverage, maxOI: _maxOI, isActive: true}));

        emit PairAdded(pairIndex, _name);
    }

    /**
     * @notice Update an existing trading pair configuration
     * @param _pairIndex The pair index to update
     * @param _maxLeverage The new maximum leverage
     * @param _maxOI The new maximum open interest (18 decimals)
     * @param _isActive Whether the pair is active
     */
    function updatePair(uint256 _pairIndex, uint16 _maxLeverage, uint128 _maxOI, bool _isActive) external onlyOwner {
        if (_pairIndex >= _pairs.length) revert PairNotFound(_pairIndex);
        if (_maxLeverage == 0) revert ZeroMaxLeverage();
        if (_maxOI == 0) revert ZeroMaxOI();

        Pair storage pair = _pairs[_pairIndex];
        pair.maxLeverage = _maxLeverage;
        pair.maxOI = _maxOI;
        pair.isActive = _isActive;

        emit PairUpdated(_pairIndex);
    }
}
