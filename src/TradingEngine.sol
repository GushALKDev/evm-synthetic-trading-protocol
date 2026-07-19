// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {TradingStorage} from "./TradingStorage.sol";
import {Vault} from "./Vault.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {FundingLib} from "./libraries/FundingLib.sol";
import {SpreadManager} from "./SpreadManager.sol";

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
    uint256 public constant MIN_COLLATERAL = 10e6; // 10 USDC — floor keeps the liquidator reward above L2 gas
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant OPEN_FEE_BPS = 8; // 0.08% of position size
    uint256 public constant CLOSE_FEE_BPS = 8; // 0.08% of position size
    uint256 public constant FEE_VAULT_SPLIT_BPS = 8000; // 80% to Vault, 20% to treasury
    uint256 public constant LIQUIDATION_THRESHOLD_BPS = 9000; // liquidatable when loss >= 90% of collateral
    uint256 public constant LIQUIDATOR_REWARD_BPS = 1000; // 10% of remaining collateral to liquidator
    uint256 public constant EXEC_REWARD_BPS = 10; // 0.1% of position size to the TP/SL executor

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    TradingStorage public immutable TRADING_STORAGE;
    Vault public immutable VAULT;
    IOracle public immutable ORACLE;
    address public immutable ASSET;
    SpreadManager public immutable SPREAD_MANAGER;

    bool private _paused;
    address public treasury;

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
        uint128 openPrice,
        uint256 fee
    );
    event TradeClosed(
        uint256 indexed tradeId,
        address indexed user,
        uint128 closePrice,
        int256 pnlUsdc,
        uint256 payoutUsdc,
        uint256 fee,
        int256 fundingOwedUsdc
    );
    event FeesDistributed(uint256 vaultFee, uint256 treasuryFee);
    event TpUpdated(uint256 indexed tradeId, uint128 newTp);
    event SlUpdated(uint256 indexed tradeId, uint128 newSl);
    event TradeLiquidated(
        uint256 indexed tradeId,
        address indexed user,
        address indexed liquidator,
        uint128 closePrice,
        int256 pnlUsdc,
        int256 fundingOwedUsdc,
        uint256 liquidatorReward,
        uint256 vaultAmount
    );
    event LimitExecuted(
        uint256 indexed tradeId,
        address indexed user,
        address indexed executor,
        bool isTp,
        uint128 closePrice,
        int256 pnlUsdc,
        uint256 payoutUsdc,
        uint256 executorReward,
        int256 fundingOwedUsdc
    );
    event TreasuryUpdated(address indexed newTreasury);
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
    error FeeExceedsCollateral(uint256 fee, uint64 collateral);
    error ZeroFeeRecipient();
    error NotLiquidatable(uint256 tradeId, uint256 loss, uint256 threshold);
    error LimitNotTriggered(uint256 tradeId, uint128 oraclePrice);
    error NoLimitSet(uint256 tradeId);

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
     * @dev Sweep any ETH left on the contract back to the caller. The oracle refunds the fee
     *      surplus here; this returns it to the trader/liquidator. The engine never holds ETH.
     */
    function _refundEth() internal {
        uint256 balance = address(this).balance;
        if (balance > 0) msg.sender.safeTransferETH(balance);
    }

    /**
     * @dev Get oracle-validated price via the IOracle interface. Confidence band is discarded.
     *      Forwards msg.value to fund the oracle fee; the oracle refunds any surplus to this contract,
     *      which is swept back to the trader by _refundEth.
     */
    function _getOraclePrice(uint256 _pairIndex, bytes[] calldata _priceUpdate) internal returns (uint128 price18) {
        (price18, ) = ORACLE.getPrice{value: msg.value}(_pairIndex, _priceUpdate);
    }

    /**
     * @dev Get oracle price with confidence band, then apply conservative pricing for liquidation checks.
     *      Uses the most trader-favorable end of the [price - conf, price + conf] band so a noisy,
     *      high-uncertainty tick cannot force an unfair liquidation:
     *        Long  (liquidates when price falls) → price + conf (higher price → smaller loss)
     *        Short (liquidates when price rises) → price - conf (lower price → smaller loss)
     *      Floors at 0 for the short case if conf ever exceeds price.
     */
    function _getConservativeLiqPrice(uint256 _pairIndex, bytes[] calldata _priceUpdate, bool _isLong) internal returns (uint128) {
        (uint128 price18, uint128 conf18) = ORACLE.getPrice{value: msg.value}(_pairIndex, _priceUpdate);
        if (_isLong) {
            return price18 + conf18;
        }
        return conf18 >= price18 ? 0 : price18 - conf18;
    }

    /**
     * @dev Apply spread to oracle price. Spread makes execution worse for the trader.
     *      Long open / Short close: price goes UP → price * (10000 + spread) / 10000
     *      Long close / Short open: price goes DOWN → price * (10000 - spread) / 10000
     */
    function _applySpread(uint128 _oraclePrice, bool _isLong, bool _isOpen, uint16 _pairIndex) internal view returns (uint128) {
        uint256 currentOI = TRADING_STORAGE.getOpenInterest(_pairIndex);
        uint256 spreadBps = SPREAD_MANAGER.getSpreadBps(_pairIndex, currentOI);
        bool spreadUp = (_isLong && _isOpen) || (!_isLong && !_isOpen);
        if (spreadUp) {
            return uint128((uint256(_oraclePrice) * (BPS_DENOMINATOR + spreadBps)) / BPS_DENOMINATOR);
        } else {
            return uint128((uint256(_oraclePrice) * (BPS_DENOMINATOR - spreadBps)) / BPS_DENOMINATOR);
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

        if (_isLong) {
            // Floor exitValue → larger loss for the trader → rounding favors the pool
            uint256 exitValue = (uint256(_closePrice) * size) / uint256(_openPrice);
            pnlUsdc = int256(exitValue) - int256(size);
        } else {
            // Ceil exitValue → larger loss for the trader → rounding favors the pool (short PnL = size - exitValue)
            uint256 num = uint256(_closePrice) * size;
            uint256 exitValue = (num + uint256(_openPrice) - 1) / uint256(_openPrice);
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
     * @dev Calculate fee in USDC (6 decimals) from collateral and leverage.
     */
    function _calculateFee(uint64 _collateral, uint16 _leverage, uint256 _feeBps) internal pure returns (uint256) {
        return (uint256(_collateral) * uint256(_leverage) * _feeBps) / BPS_DENOMINATOR;
    }

    /**
     * @dev Split and distribute fee: 80% to Vault, 20% to treasury via TradingStorage.sendCollateral.
     */
    function _distributeFees(uint256 _fee) internal {
        if (_fee == 0) return;
        uint256 vaultFee = (_fee * FEE_VAULT_SPLIT_BPS) / BPS_DENOMINATOR;
        uint256 treasuryFee = _fee - vaultFee;
        TRADING_STORAGE.sendCollateral(address(VAULT), vaultFee);
        TRADING_STORAGE.sendCollateral(treasury, treasuryFee);
        emit FeesDistributed(vaultFee, treasuryFee);
    }

    /**
     * @dev Update cumulative funding index for a pair based on time elapsed and OI imbalance.
     *      Called before any OI change (open/close) to materialize accrued funding.
     */
    function _updateFundingIndex(uint256 _pairIndex) internal {
        uint256 lastUpdated = TRADING_STORAGE.getFundingLastUpdated(_pairIndex);
        if (lastUpdated == 0) {
            // First interaction — initialize timestamp, index stays at 0
            TRADING_STORAGE.updateFundingState(_pairIndex, 0, block.timestamp);
            return;
        }
        uint256 deltaTime = block.timestamp - lastUpdated;
        if (deltaTime == 0) return;

        uint256 oiLong = TRADING_STORAGE.getOpenInterestLong(_pairIndex);
        uint256 oiShort = TRADING_STORAGE.getOpenInterestShort(_pairIndex);
        int256 indexDelta = FundingLib.calculateIndexDelta(oiLong, oiShort, deltaTime);
        int256 newIndex = TRADING_STORAGE.getCumulativeFundingIndex(_pairIndex) + indexDelta;
        TRADING_STORAGE.updateFundingState(_pairIndex, newIndex, block.timestamp);
    }

    /**
     * @dev Calculate funding owed for a trade. Extracted to avoid stack-too-deep.
     */
    function _calculateFunding(uint256 _tradeId, uint256 _posSizeWad, bool _isLong, uint256 _pairIndex) internal view returns (int256) {
        int256 currentIndex = TRADING_STORAGE.getCumulativeFundingIndex(_pairIndex);
        int256 entryIndex = TRADING_STORAGE.getTradeFundingIndex(_tradeId);
        return FundingLib.calculateFundingOwed(_posSizeWad, _isLong, currentIndex, entryIndex);
    }

    /**
     * @dev Transfer collateral, deduct fee, store trade, track OI, emit event.
     *      Extracted to a separate function to avoid stack-too-deep in openTrade.
     */
    function _executeOpen(
        address _user,
        uint16 _pairIndex,
        bool _isLong,
        uint64 _collateral,
        uint16 _leverage,
        uint128 _executionPrice,
        uint128 _tp,
        uint128 _sl
    ) internal returns (uint32 tradeId) {
        uint256 fee = _calculateFee(_collateral, _leverage, OPEN_FEE_BPS);
        if (fee >= uint256(_collateral)) revert FeeExceedsCollateral(fee, _collateral);
        ASSET.safeTransferFrom(_user, address(TRADING_STORAGE), uint256(_collateral));
        uint64 effectiveCollateral = uint64(uint256(_collateral) - fee);
        _distributeFees(fee);

        tradeId = TRADING_STORAGE.storeTrade(_user, _isLong, _pairIndex, _leverage, effectiveCollateral, _executionPrice, _tp, _sl);
        TRADING_STORAGE.setTradeFundingIndex(tradeId, TRADING_STORAGE.getCumulativeFundingIndex(_pairIndex));
        TRADING_STORAGE.increaseOpenInterest(_pairIndex, _positionSizeWad(effectiveCollateral, _leverage), _isLong);
        emit TradeOpened(tradeId, _user, _pairIndex, _isLong, effectiveCollateral, _leverage, _executionPrice, fee);
    }

    /**
     * @dev Reject positions that would already be liquidatable right after opening.
     *      The applied spread creates an instant unrealized loss (openPrice vs fair oraclePrice).
     *      If that loss already reaches the liquidation threshold, the trade is rejected so it
     *      cannot be opened straight into the liquidation zone.
     */
    function _validateNotPreLiquidatable(uint64 _collateral, uint16 _leverage, uint128 _openPrice, uint128 _oraclePrice, bool _isLong) internal pure {
        int256 instantPnl = _calculatePnl(_collateral, _leverage, _openPrice, _oraclePrice, _isLong);
        uint256 threshold = (uint256(_collateral) * LIQUIDATION_THRESHOLD_BPS) / BPS_DENOMINATOR;
        uint256 loss = instantPnl < 0 ? uint256(-instantPnl) : 0;
        if (loss >= threshold) revert NotLiquidatable(0, loss, threshold);
    }

    /**
     * @dev Apply open-direction spread to the oracle price and validate slippage and pre-liquidation.
     *      Extracted to keep openTrade below the stack-too-deep limit.
     * @return executionPrice The spread-adjusted price the trade opens at.
     */
    function _computeOpenPrice(
        uint16 _pairIndex,
        bool _isLong,
        uint64 _collateral,
        uint16 _leverage,
        uint128 _oraclePrice,
        uint128 _expectedPrice,
        uint16 _slippageBps
    ) internal view returns (uint128 executionPrice) {
        executionPrice = _applySpread(_oraclePrice, _isLong, true, _pairIndex);
        _validateSlippage(executionPrice, _expectedPrice, _slippageBps);
        _validateNotPreLiquidatable(_collateral, _leverage, executionPrice, _oraclePrice, _isLong);
    }

    /**
     * @dev Determine whether the trade's TP or SL is triggered at the given oracle price.
     *      Long TP: price >= tp | Long SL: price <= sl
     *      Short TP: price <= tp | Short SL: price >= sl
     *      TP is checked before SL; a trade with neither set can never trigger.
     * @return triggered Whether any limit condition is met
     * @return isTp True if the triggered limit is the take profit (false = stop loss)
     */
    function _isLimitTriggered(TradingStorage.Trade memory _trade, uint128 _oraclePrice) internal pure returns (bool triggered, bool isTp) {
        if (_trade.tp != 0) {
            if (_trade.isLong ? _oraclePrice >= _trade.tp : _oraclePrice <= _trade.tp) return (true, true);
        }
        if (_trade.sl != 0) {
            if (_trade.isLong ? _oraclePrice <= _trade.sl : _oraclePrice >= _trade.sl) return (true, false);
        }
        return (false, false);
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

    constructor(address _tradingStorage, address _vault, address _oracle, address _asset, address _treasury, address _spreadManager, address _owner) {
        if (
            _tradingStorage == address(0) ||
            _vault == address(0) ||
            _oracle == address(0) ||
            _asset == address(0) ||
            _treasury == address(0) ||
            _spreadManager == address(0)
        ) revert ZeroAddress();
        _initializeOwner(_owner);
        TRADING_STORAGE = TradingStorage(_tradingStorage);
        VAULT = Vault(_vault);
        ORACLE = IOracle(_oracle);
        ASSET = _asset;
        SPREAD_MANAGER = SpreadManager(_spreadManager);
        treasury = _treasury;
    }

    /**
     * @dev Accept ETH refunds from the oracle. Any residual is swept back to the caller via _refundEth.
     */
    receive() external payable {}

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
    ) external payable nonReentrant whenNotPaused returns (uint32 tradeId) {
        // --- CHECKS ---
        if (_collateral < MIN_COLLATERAL) revert BelowMinCollateral(_collateral);
        if (_leverage == 0) revert ZeroLeverage();
        _validatePair(_pairIndex, _leverage);

        uint128 oraclePrice = _getOraclePrice(_pairIndex, priceUpdate);
        _validateTpSlAgainstOraclePrice(_tp, _sl, oraclePrice, _isLong);

        // Apply spread, validate slippage and pre-liquidation; oraclePrice becomes the execution price.
        oraclePrice = _computeOpenPrice(_pairIndex, _isLong, _collateral, _leverage, oraclePrice, _expectedPrice, _slippageBps);

        // --- EFFECTS ---
        _updateFundingIndex(_pairIndex);

        // --- INTERACTIONS ---
        tradeId = _executeOpen(msg.sender, _pairIndex, _isLong, _collateral, _leverage, oraclePrice, _tp, _sl);

        _refundEth();
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
    function closeTrade(
        uint256 _tradeId,
        uint128 _expectedPrice,
        uint16 _slippageBps,
        bytes[] calldata priceUpdate
    ) external payable nonReentrant whenNotPaused {
        TradingStorage.Trade memory trade = TRADING_STORAGE.getTrade(_tradeId);
        if (trade.user == address(0)) revert TradeNotFound(_tradeId);
        if (trade.user != msg.sender) revert NotTradeOwner(msg.sender, trade.user);

        uint128 oraclePrice = _getOraclePrice(trade.pairIndex, priceUpdate);
        uint128 executionPrice = _applySpread(oraclePrice, trade.isLong, false, trade.pairIndex);
        _validateSlippage(executionPrice, _expectedPrice, _slippageBps);

        // Update funding index before computing funding owed
        _updateFundingIndex(trade.pairIndex);

        int256 pnlUsdc = _calculatePnl(trade.collateral, trade.leverage, trade.openPrice, executionPrice, trade.isLong);
        uint256 positionSize = _positionSizeWad(trade.collateral, trade.leverage);

        // Calculate funding owed and adjust PnL
        int256 fundingOwedUsdc = _calculateFunding(_tradeId, positionSize, trade.isLong, trade.pairIndex);
        int256 adjustedPnl = pnlUsdc - fundingOwedUsdc;
        uint256 payoutUsdc = _calculatePayout(trade.collateral, adjustedPnl);

        // Close fee deducted from payout
        uint256 closeFee = _calculateFee(trade.collateral, trade.leverage, CLOSE_FEE_BPS);
        if (closeFee >= payoutUsdc) {
            closeFee = payoutUsdc;
            payoutUsdc = 0;
        } else {
            payoutUsdc -= closeFee;
        }

        // --- EFFECTS ---
        TRADING_STORAGE.deleteTrade(_tradeId);
        TRADING_STORAGE.decreaseOpenInterest(trade.pairIndex, positionSize, trade.isLong);
        emit TradeClosed(_tradeId, msg.sender, executionPrice, pnlUsdc, payoutUsdc, closeFee, fundingOwedUsdc);

        // --- INTERACTIONS ---
        // Distribute close fee from collateral in TradingStorage
        _distributeFees(closeFee);

        if (payoutUsdc == 0) {
            // Full loss (or fee consumed payout): remaining collateral goes to Vault
            uint256 remaining = uint256(trade.collateral) - closeFee;
            if (remaining > 0) TRADING_STORAGE.sendCollateral(address(VAULT), remaining);
        } else if (payoutUsdc <= uint256(trade.collateral) - closeFee) {
            // Partial loss: payout to trader, rest to Vault
            TRADING_STORAGE.sendCollateral(msg.sender, payoutUsdc);
            uint256 toVault = uint256(trade.collateral) - closeFee - payoutUsdc;
            if (toVault > 0) TRADING_STORAGE.sendCollateral(address(VAULT), toVault);
        } else {
            // Profit: return remaining collateral to trader from Storage, profit from Vault
            uint256 storageToTrader = uint256(trade.collateral) - closeFee;
            TRADING_STORAGE.sendCollateral(msg.sender, storageToTrader);
            uint256 profitFromVault = payoutUsdc - storageToTrader;
            VAULT.sendPayout(msg.sender, profitFromVault);
        }

        _refundEth();
    }

    /**
     * @notice Liquidate a position whose loss has reached the liquidation threshold
     * @dev Permissionless. Loss is computed on adjustedPnl (price PnL minus funding owed),
     *      evaluated at the spread-adjusted execution price (close direction), exactly like closeTrade.
     *      Reverts with NotLiquidatable if the position is still solvent.
     *      Remaining collateral (collateral - loss) is split: 10% to the liquidator, 90% to the Vault.
     *      The loss portion is also sent to the Vault. No close fee is charged on liquidation.
     *      Collateral flow: TradingStorage → Vault (rest) + TradingStorage → liquidator (reward).
     *
     *      Not gated by whenNotPaused: liquidation is the protocol's solvency valve and must stay live
     *      even while trading is paused. During a Pyth outage the oracle reverts (stale/deviation), so
     *      liquidation is unavailable by design — see docs/03-architecture.md for the accepted risk.
     * @param _tradeId The trade ID to liquidate
     * @param priceUpdate Pyth price update data
     */
    function liquidate(uint256 _tradeId, bytes[] calldata priceUpdate) external payable nonReentrant {
        TradingStorage.Trade memory trade = TRADING_STORAGE.getTrade(_tradeId);
        if (trade.user == address(0)) revert TradeNotFound(_tradeId);

        // Conservative pricing: price + conf (long) / price - conf (short) makes liquidation harder,
        // protecting the trader from unfair liquidation during high-uncertainty periods.
        uint128 conservativePrice = _getConservativeLiqPrice(trade.pairIndex, priceUpdate, trade.isLong);
        uint128 executionPrice = _applySpread(conservativePrice, trade.isLong, false, trade.pairIndex);

        _updateFundingIndex(trade.pairIndex);

        int256 pnlUsdc = _calculatePnl(trade.collateral, trade.leverage, trade.openPrice, executionPrice, trade.isLong);
        uint256 positionSize = _positionSizeWad(trade.collateral, trade.leverage);
        int256 fundingOwedUsdc = _calculateFunding(_tradeId, positionSize, trade.isLong, trade.pairIndex);
        int256 adjustedPnl = pnlUsdc - fundingOwedUsdc;

        // Position is liquidatable only when the loss reaches the threshold
        uint256 threshold = (uint256(trade.collateral) * LIQUIDATION_THRESHOLD_BPS) / BPS_DENOMINATOR;
        uint256 loss = adjustedPnl < 0 ? uint256(-adjustedPnl) : 0;
        if (loss < threshold) revert NotLiquidatable(_tradeId, loss, threshold);

        // Remaining collateral after covering the loss (0 if loss exceeds collateral)
        uint256 remaining = loss >= uint256(trade.collateral) ? 0 : uint256(trade.collateral) - loss;
        uint256 liquidatorReward = (remaining * LIQUIDATOR_REWARD_BPS) / BPS_DENOMINATOR;

        _executeLiquidation(trade, _tradeId, positionSize, executionPrice, pnlUsdc, fundingOwedUsdc, liquidatorReward);

        _refundEth();
    }

    /**
     * @dev Settle a liquidation: delete trade, decrease OI, emit, and distribute collateral.
     *      Extracted to keep liquidate below the stack-too-deep limit.
     */
    function _executeLiquidation(
        TradingStorage.Trade memory _trade,
        uint256 _tradeId,
        uint256 _positionSize,
        uint128 _executionPrice,
        int256 _pnlUsdc,
        int256 _fundingOwedUsdc,
        uint256 _liquidatorReward
    ) internal {
        uint256 vaultAmount = uint256(_trade.collateral) - _liquidatorReward;

        // --- EFFECTS ---
        TRADING_STORAGE.deleteTrade(_tradeId);
        TRADING_STORAGE.decreaseOpenInterest(_trade.pairIndex, _positionSize, _trade.isLong);
        emit TradeLiquidated(_tradeId, _trade.user, msg.sender, _executionPrice, _pnlUsdc, _fundingOwedUsdc, _liquidatorReward, vaultAmount);

        // --- INTERACTIONS ---
        // Vault first, liquidator reward after: a blacklisted liquidator only blocks their own reward payout.
        TRADING_STORAGE.sendCollateral(address(VAULT), vaultAmount);
        if (_liquidatorReward > 0) TRADING_STORAGE.sendCollateral(msg.sender, _liquidatorReward);
    }

    /**
     * @notice Execute a triggered take-profit or stop-loss on behalf of the trade owner
     * @dev Permissionless: anyone can call once the oracle price crosses the trade's TP or SL.
     *      Settlement mirrors closeTrade (funding-adjusted PnL, close direction spread, close fee,
     *      same 3-branch payout), but the payout goes to the trade owner (not the caller). The caller
     *      earns a fixed reward (EXEC_REWARD_BPS of notional) carved out of the trader's payout, capped
     *      so the trader is never pushed negative — on a full-loss stop the executor simply earns 0.
     *      Reverts NoLimitSet if neither TP nor SL is set, LimitNotTriggered if not yet crossed.
     *      Collateral flow: same as closeTrade, plus payout split (trader gets payout - reward, executor
     *      gets reward). Gated by whenNotPaused like closeTrade.
     * @param _tradeId The trade ID to execute
     * @param priceUpdate Pyth price update data
     */
    function executeLimit(uint256 _tradeId, bytes[] calldata priceUpdate) external payable nonReentrant whenNotPaused {
        TradingStorage.Trade memory trade = TRADING_STORAGE.getTrade(_tradeId);
        if (trade.user == address(0)) revert TradeNotFound(_tradeId);
        if (trade.tp == 0 && trade.sl == 0) revert NoLimitSet(_tradeId);

        uint128 oraclePrice = _getOraclePrice(trade.pairIndex, priceUpdate);
        (bool triggered, bool isTp) = _isLimitTriggered(trade, oraclePrice);
        if (!triggered) revert LimitNotTriggered(_tradeId, oraclePrice);

        uint128 executionPrice = _applySpread(oraclePrice, trade.isLong, false, trade.pairIndex);

        _updateFundingIndex(trade.pairIndex);

        _executeLimit(trade, _tradeId, executionPrice, isTp);

        _refundEth();
    }

    /**
     * @dev Settle a triggered limit order: compute payout, carve the executor reward, delete trade,
     *      decrease OI, emit, and distribute collateral. Extracted to avoid stack-too-deep.
     *      Payout branches follow closeTrade; the executor reward reduces the trader's net payout only.
     */
    function _executeLimit(TradingStorage.Trade memory _trade, uint256 _tradeId, uint128 _executionPrice, bool _isTp) internal {
        uint256 positionSize = _positionSizeWad(_trade.collateral, _trade.leverage);
        int256 pnlUsdc = _calculatePnl(_trade.collateral, _trade.leverage, _trade.openPrice, _executionPrice, _trade.isLong);
        int256 fundingOwedUsdc = _calculateFunding(_tradeId, positionSize, _trade.isLong, _trade.pairIndex);
        uint256 payoutUsdc = _calculatePayout(_trade.collateral, pnlUsdc - fundingOwedUsdc);

        // Close fee deducted from payout (same as closeTrade)
        uint256 closeFee = _calculateFee(_trade.collateral, _trade.leverage, CLOSE_FEE_BPS);
        if (closeFee >= payoutUsdc) {
            closeFee = payoutUsdc;
            payoutUsdc = 0;
        } else {
            payoutUsdc -= closeFee;
        }

        // Executor reward carved out of the trader's payout, capped so payout never goes negative
        uint256 execReward = (uint256(_trade.collateral) * _trade.leverage * EXEC_REWARD_BPS) / BPS_DENOMINATOR;
        if (execReward > payoutUsdc) execReward = payoutUsdc;
        uint256 traderPayout = payoutUsdc - execReward;

        // --- EFFECTS ---
        TRADING_STORAGE.deleteTrade(_tradeId);
        TRADING_STORAGE.decreaseOpenInterest(_trade.pairIndex, positionSize, _trade.isLong);
        emit LimitExecuted(_tradeId, _trade.user, msg.sender, _isTp, _executionPrice, pnlUsdc, traderPayout, execReward, fundingOwedUsdc);

        // --- INTERACTIONS ---
        _distributeFees(closeFee);
        _settleLimitPayout(_trade, closeFee, traderPayout, execReward);
    }

    /**
     * @dev Distribute a limit-order settlement: trader payout (payout - reward) and executor reward.
     *      Mirrors closeTrade's collateral/Vault split; the executor reward is always funded from
     *      collateral held in TradingStorage (it is carved out of the payout, so it is <= collateral).
     */
    function _settleLimitPayout(TradingStorage.Trade memory _trade, uint256 _closeFee, uint256 _traderPayout, uint256 _execReward) internal {
        uint256 collateralAfterFee = uint256(_trade.collateral) - _closeFee;
        uint256 fromStorage = _traderPayout + _execReward; // total owed out of the position

        if (fromStorage <= collateralAfterFee) {
            // Loss or breakeven: everything paid from collateral, rest to Vault
            if (_traderPayout > 0) TRADING_STORAGE.sendCollateral(_trade.user, _traderPayout);
            if (_execReward > 0) TRADING_STORAGE.sendCollateral(msg.sender, _execReward);
            uint256 toVault = collateralAfterFee - fromStorage;
            if (toVault > 0) TRADING_STORAGE.sendCollateral(address(VAULT), toVault);
        } else {
            // Profit: pay executor reward + remaining collateral from Storage, top up trader profit from Vault
            if (_execReward > 0) TRADING_STORAGE.sendCollateral(msg.sender, _execReward);
            uint256 traderFromStorage = collateralAfterFee - _execReward;
            if (traderFromStorage > 0) TRADING_STORAGE.sendCollateral(_trade.user, traderFromStorage);
            uint256 profitFromVault = fromStorage - collateralAfterFee;
            VAULT.sendPayout(_trade.user, profitFromVault);
        }
    }

    /**
     * @notice Update the take profit price of a trade
     * @param _tradeId The trade ID
     * @param _newTp The new take profit price (0 to clear)
     * @param priceUpdate Pyth price update data
     */
    function updateTp(uint256 _tradeId, uint128 _newTp, bytes[] calldata priceUpdate) external payable whenNotPaused {
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

        _refundEth();
    }

    /**
     * @notice Update the stop loss price of a trade
     * @param _tradeId The trade ID
     * @param _newSl The new stop loss price (0 to clear)
     * @param priceUpdate Pyth price update data
     */
    function updateSl(uint256 _tradeId, uint128 _newSl, bytes[] calldata priceUpdate) external payable whenNotPaused {
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

        _refundEth();
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

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
