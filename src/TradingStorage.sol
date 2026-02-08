// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title TradingStorage
/// @author GushALKDev
/// @notice Custodies trader collateral and stores all trade/pair data for the Synthetic Trading Protocol
/// @dev State and custody layer — only TradingEngine can mutate trade data and move funds
contract TradingStorage is Ownable, ReentrancyGuard {
    using SafeTransferLib for address;

    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Represents an open trading position
    struct Trade {
        address user; // Position owner (20 bytes) ─┐ packed
        bool isLong; //  true = LONG (1 byte)       ─┘
        uint256 pairIndex; // Trading pair index
        uint256 index; // Unique trade ID (auto-assigned)
        uint256 collateral; // USDC, 6 decimals
        uint256 leverage; // Integer multiplier (e.g., 10 = 10x)
        uint256 openPrice; // Entry price, 18 decimals
        uint256 tp; // Take profit price, 18 decimals (0 = not set)
        uint256 sl; // Stop loss price, 18 decimals (0 = not set)
        uint256 timestamp; // Block timestamp at open
    }

    /// @notice Configuration for a trading pair
    struct Pair {
        string name; // e.g., "BTC/USD"
        uint256 maxLeverage; // Maximum leverage for this pair
        uint256 maxOI; // Maximum open interest (18 decimals)
        bool isActive; // Can be paused independently
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
    uint256 private _tradeCounter;

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

    event TradeStored(uint256 indexed tradeId, address indexed user, uint256 pairIndex);
    event TradeDeleted(uint256 indexed tradeId, address indexed user);
    event TradeTpUpdated(uint256 indexed tradeId, uint256 newTp);
    event TradeSlUpdated(uint256 indexed tradeId, uint256 newSl);
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

    /// @dev Removes a trade ID from the user's trade array using swap-and-pop
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

    /// @notice Store a new trade and assign an auto-incremented ID
    /// @param _trade The trade data (index field will be overwritten)
    /// @return tradeId The assigned trade ID
    function storeTrade(Trade memory _trade) external onlyTradingEngine returns (uint256 tradeId) {
        if (_trade.pairIndex >= _pairs.length) revert PairNotFound(_trade.pairIndex);

        tradeId = _tradeCounter++;
        _trade.index = tradeId;
        _trades[tradeId] = _trade;
        _userTrades[_trade.user].push(tradeId);

        emit TradeStored(tradeId, _trade.user, _trade.pairIndex);
    }

    /// @notice Delete a trade from storage
    /// @param _tradeId The trade ID to delete
    function deleteTrade(uint256 _tradeId) external onlyTradingEngine {
        Trade storage trade = _trades[_tradeId];
        if (trade.user == address(0)) revert TradeNotFound(_tradeId);

        address user = trade.user;

        _removeFromUserTrades(user, _tradeId);
        delete _trades[_tradeId];

        emit TradeDeleted(_tradeId, user);
    }

    /// @notice Update the take profit price of a trade
    /// @param _tradeId The trade ID
    /// @param _newTp The new take profit price (0 to clear)
    function updateTradeTp(uint256 _tradeId, uint256 _newTp) external onlyTradingEngine {
        if (_trades[_tradeId].user == address(0)) revert TradeNotFound(_tradeId);
        _trades[_tradeId].tp = _newTp;
        emit TradeTpUpdated(_tradeId, _newTp);
    }

    /// @notice Update the stop loss price of a trade
    /// @param _tradeId The trade ID
    /// @param _newSl The new stop loss price (0 to clear)
    function updateTradeSl(uint256 _tradeId, uint256 _newSl) external onlyTradingEngine {
        if (_trades[_tradeId].user == address(0)) revert TradeNotFound(_tradeId);
        _trades[_tradeId].sl = _newSl;
        emit TradeSlUpdated(_tradeId, _newSl);
    }

    /// @notice Increase open interest for a pair
    /// @param _pairIndex The pair index
    /// @param _amount The amount to add (18 decimals)
    function increaseOpenInterest(uint256 _pairIndex, uint256 _amount) external onlyTradingEngine {
        if (_pairIndex >= _pairs.length) revert PairNotFound(_pairIndex);
        _openInterest[_pairIndex] += _amount;
        emit OpenInterestUpdated(_pairIndex, _openInterest[_pairIndex]);
    }

    /// @notice Decrease open interest for a pair
    /// @param _pairIndex The pair index
    /// @param _amount The amount to subtract (18 decimals)
    function decreaseOpenInterest(uint256 _pairIndex, uint256 _amount) external onlyTradingEngine {
        if (_pairIndex >= _pairs.length) revert PairNotFound(_pairIndex);
        _openInterest[_pairIndex] -= _amount;
        emit OpenInterestUpdated(_pairIndex, _openInterest[_pairIndex]);
    }

    /// @notice Transfer collateral out to any address (trader or Vault)
    /// @param _to The recipient address
    /// @param _amount The amount of USDC to send
    function sendCollateral(address _to, uint256 _amount) external onlyTradingEngine nonReentrant {
        uint256 balance = ASSET.balanceOf(address(this));
        if (_amount > balance) revert InsufficientBalance(_amount, balance);

        ASSET.safeTransfer(_to, _amount);

        emit CollateralSent(_to, _amount);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get a trade by ID
    /// @param _tradeId The trade ID
    /// @return The trade data
    function getTrade(uint256 _tradeId) external view returns (Trade memory) {
        return _trades[_tradeId];
    }

    /// @notice Get all active trade IDs for a user
    /// @param _user The user address
    /// @return Array of trade IDs
    function getUserTrades(address _user) external view returns (uint256[] memory) {
        return _userTrades[_user];
    }

    /// @notice Get the number of active trades for a user
    /// @param _user The user address
    /// @return The trade count
    function getUserTradesCount(address _user) external view returns (uint256) {
        return _userTrades[_user].length;
    }

    /// @notice Get the total open interest for a pair
    /// @param _pairIndex The pair index
    /// @return The total OI (18 decimals)
    function getOpenInterest(uint256 _pairIndex) external view returns (uint256) {
        return _openInterest[_pairIndex];
    }

    /// @notice Get a pair configuration
    /// @param _pairIndex The pair index
    /// @return The pair data
    function getPair(uint256 _pairIndex) external view returns (Pair memory) {
        if (_pairIndex >= _pairs.length) revert PairNotFound(_pairIndex);
        return _pairs[_pairIndex];
    }

    /// @notice Get the total number of pairs
    /// @return The pair count
    function getPairsCount() external view returns (uint256) {
        return _pairs.length;
    }

    /// @notice Get the current trade counter (next trade ID)
    /// @return The trade counter
    function getTradeCounter() external view returns (uint256) {
        return _tradeCounter;
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the TradingEngine address
    /// @param _tradingEngine The new TradingEngine address
    function setTradingEngine(address _tradingEngine) external onlyOwner {
        if (_tradingEngine == address(0)) revert ZeroAddress();
        tradingEngine = _tradingEngine;
        emit TradingEngineUpdated(_tradingEngine);
    }

    /// @notice Add a new trading pair
    /// @param _name The pair name (e.g., "BTC/USD")
    /// @param _maxLeverage The maximum leverage allowed
    /// @param _maxOI The maximum open interest (18 decimals)
    /// @return pairIndex The index of the new pair
    function addPair(string calldata _name, uint256 _maxLeverage, uint256 _maxOI) external onlyOwner returns (uint256 pairIndex) {
        if (bytes(_name).length == 0) revert EmptyPairName();
        if (_maxLeverage == 0) revert ZeroMaxLeverage();
        if (_maxOI == 0) revert ZeroMaxOI();

        pairIndex = _pairs.length;
        _pairs.push(Pair({name: _name, maxLeverage: _maxLeverage, maxOI: _maxOI, isActive: true}));

        emit PairAdded(pairIndex, _name);
    }

    /// @notice Update an existing trading pair configuration
    /// @param _pairIndex The pair index to update
    /// @param _maxLeverage The new maximum leverage
    /// @param _maxOI The new maximum open interest (18 decimals)
    /// @param _isActive Whether the pair is active
    function updatePair(uint256 _pairIndex, uint256 _maxLeverage, uint256 _maxOI, bool _isActive) external onlyOwner {
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
