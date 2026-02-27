// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {TradingStorage} from "./TradingStorage.sol";
import {Vault} from "./Vault.sol";
import {IOracle} from "./interfaces/IOracle.sol";

/**
 * @title TradingEngine
 * @author GushALKDev
 * @notice Main controller for opening/closing leveraged trades in the Synthetic Trading Protocol
 * @dev Orchestrates IOracle (prices), TradingStorage (state + collateral custody), and Vault (LP liquidity + payouts).
 *      Applies a fixed base spread on execution price and validates TP/SL against live oracle prices.
 */
contract TradingEngine is Ownable, ReentrancyGuard {
    using SafeTransferLib for address;

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant MAX_PROFIT_MULTIPLIER = 9;
    uint256 public constant MIN_COLLATERAL = 1e6; // 1 USDC
    uint256 public constant BASE_SPREAD_BPS = 5;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    TradingStorage public immutable TRADING_STORAGE;
    Vault public immutable VAULT;
    IOracle public immutable ORACLE;
    address public immutable ASSET;

    bool private _paused;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event TradeOpened(uint256 indexed tradeId, address indexed user, uint16 pairIndex, bool isLong, uint64 collateral, uint16 leverage, uint128 openPrice);
    event TradeClosed(uint256 indexed tradeId, address indexed user, uint128 closePrice, int256 pnlUsdc, uint256 payoutUsdc);
    event TpUpdated(uint256 indexed tradeId, uint128 newTp);
    event SlUpdated(uint256 indexed tradeId, uint128 newSl);
    event Paused(address account);
    event Unpaused(address account);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error EnforcedPause();
    error ExpectedPause();
    error ZeroAddress();
    error BelowMinCollateral(uint64 collateral);
    error ZeroLeverage();
    error LeverageExceedsMax(uint16 leverage, uint16 maxLeverage);
    error PairNotActive(uint16 pairIndex);
    error NotTradeOwner(address caller, address owner);
    error TradeNotFound(uint256 tradeId);
    error SlippageExceeded(uint128 executionPrice, uint128 expectedPrice, uint16 slippageBps);
    error TpAlreadyTriggered(uint128 tp, uint128 oraclePrice);
    error SlAlreadyTriggered(uint128 sl, uint128 oraclePrice);

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier whenNotPaused() {
        _requireNotPaused();
        _;
    }

    modifier whenPaused() {
        _requirePaused();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _requireNotPaused() internal view {
        if (_paused) revert EnforcedPause();
    }

    function _requirePaused() internal view {
        if (!_paused) revert ExpectedPause();
    }

    /**
     * @dev Get oracle-validated price via the IOracle interface.
     */
    function _getOraclePrice(uint256 _pairIndex, bytes[] calldata _priceUpdate) internal returns (uint128) {
        return ORACLE.getPrice(_pairIndex, _priceUpdate);
    }

    /**
     * @dev Apply spread to oracle price. Spread makes execution worse for the trader.
     *      Long open / Short close: price goes UP → price * (10000 + 5) / 10000
     *      Long close / Short open: price goes DOWN → price * (10000 - 5) / 10000
     */
    function _applySpread(uint128 _oraclePrice, bool _isLong, bool _isOpen) internal pure returns (uint128) {
        bool spreadUp = (_isLong && _isOpen) || (!_isLong && !_isOpen);
        if (spreadUp) {
            return uint128((uint256(_oraclePrice) * (BPS_DENOMINATOR + BASE_SPREAD_BPS)) / BPS_DENOMINATOR);
        } else {
            return uint128((uint256(_oraclePrice) * (BPS_DENOMINATOR - BASE_SPREAD_BPS)) / BPS_DENOMINATOR);
        }
    }

    /**
     * @dev Validate TP/SL are not already triggered at current oracle price.
     *      Long:  TP must be > oraclePrice, SL must be < oraclePrice
     *      Short: TP must be < oraclePrice, SL must be > oraclePrice
     */
    function _validateTpSlAgainstOraclePrice(uint128 _tp, uint128 _sl, uint128 _oraclePrice, bool _isLong) internal pure {
        if (_tp != 0) {
            if (_isLong && _tp <= _oraclePrice) revert TpAlreadyTriggered(_tp, _oraclePrice);
            if (!_isLong && _tp >= _oraclePrice) revert TpAlreadyTriggered(_tp, _oraclePrice);
        }
        if (_sl != 0) {
            if (_isLong && _sl >= _oraclePrice) revert SlAlreadyTriggered(_sl, _oraclePrice);
            if (!_isLong && _sl <= _oraclePrice) revert SlAlreadyTriggered(_sl, _oraclePrice);
        }
    }

    /**
     * @dev Calculate PnL in USDC (6 decimals) for a position.
     *      Long:  PnL = (exitPrice * size / entryPrice) - size
     *      Short: PnL = size - (exitPrice * size / entryPrice)
     *      where size = collateral * leverage (in USDC terms)
     *
     *      To avoid precision loss we compute:
     *        pnlUsdc = collateral * leverage * (exitPrice - entryPrice) / entryPrice  [for long]
     *      All intermediate math in uint256 to prevent overflow on the multiplication.
     */
    function _calculatePnl(uint64 _collateral, uint16 _leverage, uint128 _openPrice, uint128 _closePrice, bool _isLong) internal pure returns (int256 pnlUsdc) {
        // size in USDC precision (6 decimals)
        uint256 size = uint256(_collateral) * uint256(_leverage);
        // exitValue = closePrice * size / openPrice (USDC precision)
        uint256 exitValue = (uint256(_closePrice) * size) / uint256(_openPrice);

        if (_isLong) {
            pnlUsdc = int256(exitValue) - int256(size);
        } else {
            pnlUsdc = int256(size) - int256(exitValue);
        }
    }

    /**
     * @dev Calculate the final payout to the trader after applying profit cap.
     *      payout = collateral + pnl, capped at collateral * MAX_PROFIT_MULTIPLIER, floored at 0.
     */
    function _calculatePayout(uint64 _collateral, int256 _pnlUsdc) internal pure returns (uint256 payoutUsdc) {
        if (_pnlUsdc >= 0) {
            payoutUsdc = uint256(_pnlUsdc) + uint256(_collateral);
            uint256 maxPayout = uint256(_collateral) * MAX_PROFIT_MULTIPLIER;
            if (payoutUsdc > maxPayout) payoutUsdc = maxPayout;
        } else {
            uint256 loss = uint256(-_pnlUsdc);
            if (loss >= uint256(_collateral)) {
                payoutUsdc = 0;
            } else {
                payoutUsdc = uint256(_collateral) - loss;
            }
        }
    }

    /**
     * @dev Calculate position size in 18-decimal USD for OI tracking.
     *      positionSizeWad = collateral(6dec) * leverage * 1e12 = 18 decimals
     */
    function _positionSizeWad(uint64 _collateral, uint16 _leverage) internal pure returns (uint256) {
        return uint256(_collateral) * uint256(_leverage) * 1e12;
    }

    /**
     * @dev Validate that execution price is within the trader's slippage tolerance.
     *      |executionPrice - expectedPrice| * 10000 / expectedPrice <= slippageBps
     */
    function _validateSlippage(uint128 _executionPrice, uint128 _expectedPrice, uint16 _slippageBps) internal pure {
        uint256 diff = _executionPrice > _expectedPrice ? uint256(_executionPrice - _expectedPrice) : uint256(_expectedPrice - _executionPrice);
        if (diff * 10_000 > uint256(_expectedPrice) * uint256(_slippageBps)) {
            revert SlippageExceeded(_executionPrice, _expectedPrice, _slippageBps);
        }
    }

    /**
     * @dev Validate pair is active and leverage is within bounds.
     */
    function _validatePair(uint16 _pairIndex, uint16 _leverage) internal view {
        TradingStorage.Pair memory pair = TRADING_STORAGE.getPair(_pairIndex);
        if (!pair.isActive) revert PairNotActive(_pairIndex);
        if (_leverage > pair.maxLeverage) revert LeverageExceedsMax(_leverage, pair.maxLeverage);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _tradingStorage, address _vault, address _oracle, address _asset, address _owner) {
        if (_tradingStorage == address(0) || _vault == address(0) || _oracle == address(0) || _asset == address(0)) revert ZeroAddress();
        _initializeOwner(_owner);
        TRADING_STORAGE = TradingStorage(_tradingStorage);
        VAULT = Vault(_vault);
        ORACLE = IOracle(_oracle);
        ASSET = _asset;
    }

    /*//////////////////////////////////////////////////////////////
                          TRADING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Open a new leveraged position
     * @dev Gets oracle price, applies spread, validates slippage and TP/SL against oracle.
     *      Collateral flow: User → TradingStorage (via transferFrom)
     * @param _pairIndex Trading pair index
     * @param _isLong true = LONG, false = SHORT
     * @param _collateral USDC amount (6 decimals)
     * @param _leverage Leverage multiplier
     * @param _expectedPrice Expected entry price (18 decimals) from trader
     * @param _slippageBps Maximum allowed slippage in basis points (e.g. 50 = 0.5%)
     * @param _tp Take profit price (0 = not set)
     * @param _sl Stop loss price (0 = not set)
     * @param priceUpdate Pyth price update data
     * @return tradeId The assigned trade ID
     */
    function openTrade(
        uint16 _pairIndex,
        bool _isLong,
        uint64 _collateral,
        uint16 _leverage,
        uint128 _expectedPrice,
        uint16 _slippageBps,
        uint128 _tp,
        uint128 _sl,
        bytes[] calldata priceUpdate
    ) external nonReentrant whenNotPaused returns (uint32 tradeId) {
        // --- CHECKS ---
        if (_collateral < MIN_COLLATERAL) revert BelowMinCollateral(_collateral);
        if (_leverage == 0) revert ZeroLeverage();
        _validatePair(_pairIndex, _leverage);

        uint128 oraclePrice = _getOraclePrice(_pairIndex, priceUpdate);
        _validateTpSlAgainstOraclePrice(_tp, _sl, oraclePrice, _isLong);

        // Apply spread and validate slippage — reuse oraclePrice variable
        oraclePrice = _applySpread(oraclePrice, _isLong, true);
        _validateSlippage(oraclePrice, _expectedPrice, _slippageBps);

        // --- INTERACTIONS ---
        ASSET.safeTransferFrom(msg.sender, address(TRADING_STORAGE), uint256(_collateral));
        tradeId = TRADING_STORAGE.storeTrade(msg.sender, _isLong, _pairIndex, _leverage, _collateral, oraclePrice, _tp, _sl);
        emit TradeOpened(tradeId, msg.sender, _pairIndex, _isLong, _collateral, _leverage, oraclePrice);
        TRADING_STORAGE.increaseOpenInterest(_pairIndex, _positionSizeWad(_collateral, _leverage));
    }

    /**
     * @notice Close an open position and settle PnL
     * @dev Gets oracle price, applies spread (close direction), validates slippage.
     *      Collateral flow on win:  TradingStorage → Trader (collateral) + Vault → Trader (profit via sendPayout)
     *      Collateral flow on loss: TradingStorage → Vault (loss portion) + TradingStorage → Trader (remaining)
     *      Collateral flow on full loss: TradingStorage → Vault (all collateral)
     * @param _tradeId The trade ID to close
     * @param _expectedPrice Expected exit price (18 decimals) from trader
     * @param _slippageBps Maximum allowed slippage in basis points (e.g. 50 = 0.5%)
     * @param priceUpdate Pyth price update data
     */
    function closeTrade(uint256 _tradeId, uint128 _expectedPrice, uint16 _slippageBps, bytes[] calldata priceUpdate) external nonReentrant whenNotPaused {
        TradingStorage.Trade memory trade = TRADING_STORAGE.getTrade(_tradeId);
        if (trade.user == address(0)) revert TradeNotFound(_tradeId);
        if (trade.user != msg.sender) revert NotTradeOwner(msg.sender, trade.user);

        uint128 oraclePrice = _getOraclePrice(trade.pairIndex, priceUpdate);
        uint128 executionPrice = _applySpread(oraclePrice, trade.isLong, false);
        _validateSlippage(executionPrice, _expectedPrice, _slippageBps);

        int256 pnlUsdc = _calculatePnl(trade.collateral, trade.leverage, trade.openPrice, executionPrice, trade.isLong);
        uint256 payoutUsdc = _calculatePayout(trade.collateral, pnlUsdc);
        uint256 positionSize = _positionSizeWad(trade.collateral, trade.leverage);

        // --- EFFECTS ---
        TRADING_STORAGE.deleteTrade(_tradeId);
        TRADING_STORAGE.decreaseOpenInterest(trade.pairIndex, positionSize);
        emit TradeClosed(_tradeId, msg.sender, executionPrice, pnlUsdc, payoutUsdc);

        // --- INTERACTIONS ---
        if (payoutUsdc == 0) {
            // Full loss: all collateral goes to Vault as LP profit
            TRADING_STORAGE.sendCollateral(address(VAULT), uint256(trade.collateral));
        } else if (payoutUsdc <= uint256(trade.collateral)) {
            // Partial loss: remaining goes to trader, loss goes to Vault
            uint256 lossAmount = uint256(trade.collateral) - payoutUsdc;
            TRADING_STORAGE.sendCollateral(msg.sender, payoutUsdc);
            TRADING_STORAGE.sendCollateral(address(VAULT), lossAmount);
        } else {
            // Profit: return full collateral to trader from Storage, profit from Vault
            uint256 profitAmount = payoutUsdc - uint256(trade.collateral);
            TRADING_STORAGE.sendCollateral(msg.sender, uint256(trade.collateral));
            VAULT.sendPayout(msg.sender, profitAmount);
        }
    }

    /**
     * @notice Update the take profit price of a trade
     * @param _tradeId The trade ID
     * @param _newTp The new take profit price (0 to clear)
     * @param priceUpdate Pyth price update data
     */
    function updateTp(uint256 _tradeId, uint128 _newTp, bytes[] calldata priceUpdate) external whenNotPaused {
        TradingStorage.Trade memory trade = TRADING_STORAGE.getTrade(_tradeId);
        if (trade.user == address(0)) revert TradeNotFound(_tradeId);
        if (trade.user != msg.sender) revert NotTradeOwner(msg.sender, trade.user);

        if (_newTp != 0) {
            uint128 oraclePrice = _getOraclePrice(trade.pairIndex, priceUpdate);
            if (trade.isLong && _newTp <= oraclePrice) revert TpAlreadyTriggered(_newTp, oraclePrice);
            if (!trade.isLong && _newTp >= oraclePrice) revert TpAlreadyTriggered(_newTp, oraclePrice);
        }

        TRADING_STORAGE.updateTradeTp(_tradeId, _newTp);
        emit TpUpdated(_tradeId, _newTp);
    }

    /**
     * @notice Update the stop loss price of a trade
     * @param _tradeId The trade ID
     * @param _newSl The new stop loss price (0 to clear)
     * @param priceUpdate Pyth price update data
     */
    function updateSl(uint256 _tradeId, uint128 _newSl, bytes[] calldata priceUpdate) external whenNotPaused {
        TradingStorage.Trade memory trade = TRADING_STORAGE.getTrade(_tradeId);
        if (trade.user == address(0)) revert TradeNotFound(_tradeId);
        if (trade.user != msg.sender) revert NotTradeOwner(msg.sender, trade.user);

        if (_newSl != 0) {
            uint128 oraclePrice = _getOraclePrice(trade.pairIndex, priceUpdate);
            if (trade.isLong && _newSl >= oraclePrice) revert SlAlreadyTriggered(_newSl, oraclePrice);
            if (!trade.isLong && _newSl <= oraclePrice) revert SlAlreadyTriggered(_newSl, oraclePrice);
        }

        TRADING_STORAGE.updateTradeSl(_tradeId, _newSl);
        emit SlUpdated(_tradeId, _newSl);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function pause() external onlyOwner whenNotPaused {
        _paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner whenPaused {
        _paused = false;
        emit Unpaused(msg.sender);
    }

    function paused() external view returns (bool) {
        return _paused;
    }
}
