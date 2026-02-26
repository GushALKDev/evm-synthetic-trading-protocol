// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {TradingStorage} from "./TradingStorage.sol";
import {Vault} from "./Vault.sol";

/**
 * @title TradingEngine
 * @author GushALKDev
 * @notice Main controller for opening/closing leveraged trades in the Synthetic Trading Protocol
 * @dev Orchestrates TradingStorage (state + collateral custody) and Vault (LP liquidity + payouts).
 *      Price is passed as parameter for now — will be replaced by OracleAggregator in Phase 3.
 */
contract TradingEngine is Ownable, ReentrancyGuard {
    using SafeTransferLib for address;

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant MAX_PROFIT_MULTIPLIER = 9;
    uint256 public constant MIN_COLLATERAL = 1e6; // 1 USDC

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    TradingStorage public immutable TRADING_STORAGE;
    Vault public immutable VAULT;
    address public immutable ASSET;

    bool private _paused;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event TradeOpened(
        uint256 indexed tradeId,
        address indexed user,
        uint16 pairIndex,
        bool isLong,
        uint64 collateral,
        uint16 leverage,
        uint128 openPrice
    );
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
    error ZeroPrice();
    error BelowMinCollateral(uint64 collateral);
    error ZeroLeverage();
    error LeverageExceedsMax(uint16 leverage, uint16 maxLeverage);
    error PairNotActive(uint16 pairIndex);
    error NotTradeOwner(address caller, address owner);
    error TradeNotFound(uint256 tradeId);
    error SlippageExceeded(uint128 oraclePrice, uint128 expectedPrice, uint16 slippageBps);

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
     * @dev Validate that oracle price is within the trader's slippage tolerance.
     *      |oraclePrice - expectedPrice| * 10000 / expectedPrice <= slippageBps
     */
    function _validateSlippage(uint128 _oraclePrice, uint128 _expectedPrice, uint16 _slippageBps) internal pure {
        uint256 diff = _oraclePrice > _expectedPrice ? uint256(_oraclePrice - _expectedPrice) : uint256(_expectedPrice - _oraclePrice);
        if (diff * 10_000 > uint256(_expectedPrice) * uint256(_slippageBps)) {
            revert SlippageExceeded(_oraclePrice, _expectedPrice, _slippageBps);
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

    constructor(address _tradingStorage, address _vault, address _asset, address _owner) {
        if (_tradingStorage == address(0) || _vault == address(0) || _asset == address(0)) revert ZeroAddress();
        _initializeOwner(_owner);
        TRADING_STORAGE = TradingStorage(_tradingStorage);
        VAULT = Vault(_vault);
        ASSET = _asset;
    }

    /*//////////////////////////////////////////////////////////////
                          TRADING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Open a new leveraged position
     * @dev Trader submits their expected price + slippage tolerance. The oracle price is validated
     *      against these before execution. Currently oraclePrice = _openPrice (placeholder for Phase 3).
     *      Collateral flow: User → TradingStorage (via transferFrom)
     * @param _pairIndex Trading pair index
     * @param _isLong true = LONG, false = SHORT
     * @param _collateral USDC amount (6 decimals)
     * @param _leverage Leverage multiplier
     * @param _openPrice Expected entry price (18 decimals) from trader
     * @param _slippageBps Maximum allowed slippage in basis points (e.g. 50 = 0.5%)
     * @param _tp Take profit price (0 = not set)
     * @param _sl Stop loss price (0 = not set)
     * @return tradeId The assigned trade ID
     */
    function openTrade(uint16 _pairIndex, bool _isLong, uint64 _collateral, uint16 _leverage, uint128 _openPrice, uint16 _slippageBps, uint128 _tp, uint128 _sl) external nonReentrant whenNotPaused returns (uint32 tradeId) {
        // --- CHECKS ---
        if (_openPrice == 0) revert ZeroPrice();
        if (_collateral < MIN_COLLATERAL) revert BelowMinCollateral(_collateral);
        if (_leverage == 0) revert ZeroLeverage();

        // TODO: Replace with oracle price from OracleAggregator
        uint128 oraclePrice = _openPrice;
        _validateSlippage(oraclePrice, _openPrice, _slippageBps);

        _validatePair(_pairIndex, _leverage);

        // --- INTERACTIONS ---
        // Event emitted after storeTrade because tradeId is assigned by TradingStorage
        uint256 positionSize = _positionSizeWad(_collateral, _leverage);
        ASSET.safeTransferFrom(msg.sender, address(TRADING_STORAGE), uint256(_collateral));
        tradeId = TRADING_STORAGE.storeTrade(msg.sender, _isLong, _pairIndex, _leverage, _collateral, oraclePrice, _tp, _sl);
        emit TradeOpened(tradeId, msg.sender, _pairIndex, _isLong, _collateral, _leverage, oraclePrice);
        TRADING_STORAGE.increaseOpenInterest(_pairIndex, positionSize);
    }

    /**
     * @notice Close an open position and settle PnL
     * @dev Trader submits their expected close price + slippage tolerance. The oracle price is validated
     *      against these before execution. Currently oraclePrice = _closePrice (placeholder for Phase 3).
     *      Collateral flow on win:  TradingStorage → Trader (collateral) + Vault → Trader (profit via sendPayout)
     *      Collateral flow on loss: TradingStorage → Vault (loss portion) + TradingStorage → Trader (remaining)
     *      Collateral flow on full loss: TradingStorage → Vault (all collateral)
     * @param _tradeId The trade ID to close
     * @param _closePrice Expected exit price (18 decimals) from trader
     * @param _slippageBps Maximum allowed slippage in basis points (e.g. 50 = 0.5%)
     */
    function closeTrade(uint256 _tradeId, uint128 _closePrice, uint16 _slippageBps) external nonReentrant whenNotPaused {
        // --- CHECKS ---
        if (_closePrice == 0) revert ZeroPrice();

        // TODO: Replace with oracle price from OracleAggregator
        uint128 oraclePrice = _closePrice;
        _validateSlippage(oraclePrice, _closePrice, _slippageBps);

        TradingStorage.Trade memory trade = TRADING_STORAGE.getTrade(_tradeId);
        if (trade.user == address(0)) revert TradeNotFound(_tradeId);
        if (trade.user != msg.sender) revert NotTradeOwner(msg.sender, trade.user);

        int256 pnlUsdc = _calculatePnl(trade.collateral, trade.leverage, trade.openPrice, oraclePrice, trade.isLong);
        uint256 payoutUsdc = _calculatePayout(trade.collateral, pnlUsdc);
        uint256 positionSize = _positionSizeWad(trade.collateral, trade.leverage);

        // --- EFFECTS ---
        TRADING_STORAGE.deleteTrade(_tradeId);
        TRADING_STORAGE.decreaseOpenInterest(trade.pairIndex, positionSize);
        emit TradeClosed(_tradeId, msg.sender, oraclePrice, pnlUsdc, payoutUsdc);

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
     */
    function updateTp(uint256 _tradeId, uint128 _newTp) external whenNotPaused {
        TradingStorage.Trade memory trade = TRADING_STORAGE.getTrade(_tradeId);
        if (trade.user == address(0)) revert TradeNotFound(_tradeId);
        if (trade.user != msg.sender) revert NotTradeOwner(msg.sender, trade.user);

        TRADING_STORAGE.updateTradeTp(_tradeId, _newTp);
        emit TpUpdated(_tradeId, _newTp);
    }

    /**
     * @notice Update the stop loss price of a trade
     * @param _tradeId The trade ID
     * @param _newSl The new stop loss price (0 to clear)
     */
    function updateSl(uint256 _tradeId, uint128 _newSl) external whenNotPaused {
        TradingStorage.Trade memory trade = TRADING_STORAGE.getTrade(_tradeId);
        if (trade.user == address(0)) revert TradeNotFound(_tradeId);
        if (trade.user != msg.sender) revert NotTradeOwner(msg.sender, trade.user);

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
