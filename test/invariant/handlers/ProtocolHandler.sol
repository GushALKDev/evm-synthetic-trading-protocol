// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {TradingEngine} from "../../../src/TradingEngine.sol";
import {TradingStorage} from "../../../src/TradingStorage.sol";
import {Vault} from "../../../src/Vault.sol";
import {FundingLib} from "../../../src/libraries/FundingLib.sol";
import {MockOracle} from "../../mocks/MockOracle.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

/**
 * @title ProtocolHandler
 * @author GushALKDev
 * @notice Trading side of the protocol invariant suite: opens, closes, liquidations, TP/SL execution and
 *         TP/SL updates, with an independent model of every settlement.
 * @dev The model recomputes each settlement from the documented formulas (spread, PnL rounding, 9x cap on
 *      price PnL, funding after the cap, close fee, executor reward, liquidator reward) and the funding the
 *      engine reports for the position, then records the Vault's side of it in ghost variables. The suite
 *      compares those ghosts with the real balances, so a settlement that deviates from the model breaks an
 *      invariant. The trader and keeper payouts are also compared one by one (ghostMismatches).
 *      closeTrade, liquidate and executeLimit revert whenever they settle nothing (engine paused, no open
 *      position, not liquidatable, not triggered, or a winning close the Vault cannot pay), so in the forge
 *      metrics table calls - reverts is the number of settlements of each kind.
 */
contract ProtocolHandler is CommonBase, StdCheats, StdUtils {
    TradingEngine public immutable ENGINE;
    TradingStorage public immutable TRADING_STORAGE;
    Vault public immutable VAULT;
    MockOracle public immutable ORACLE;
    ERC20 public immutable USDC;

    uint16 public constant PAIR_INDEX = 0;
    uint256 public constant MAX_OI = 50_000_000 * 1e18;
    address public constant KEEPER = address(uint160(uint256(keccak256("keeper"))));

    // Documented protocol parameters, restated so the model does not read them from the code under test
    uint256 internal constant SPREAD_BPS = 5; // MockSpreadManager(5)
    uint256 internal constant BPS = 10_000;
    uint256 internal constant OPEN_FEE_BPS = 8;
    uint256 internal constant CLOSE_FEE_BPS = 8;
    uint256 internal constant VAULT_FEE_SHARE_BPS = 8000;
    uint256 internal constant EXEC_REWARD_BPS = 10;
    uint256 internal constant LIQ_REWARD_BPS = 1000;
    uint256 internal constant LIQ_MIN_REWARD_BPS = 50;
    uint256 internal constant MAX_PROFIT_MULTIPLE = 8; // payout cap 9x collateral = collateral + 8x profit

    uint8 internal constant CLOSE = 0;
    uint8 internal constant LIMIT = 1;
    uint8 internal constant LIQUIDATION = 2;

    bytes[] internal EMPTY_UPDATE;
    address[] public actors;
    uint256[] internal openTradeIds;

    struct Settlement {
        uint256 traderGets;
        uint256 keeperGets;
        uint256 fee;
        int256 vaultNet; // Vault's side, excluding its fee share: positive = trader loss, negative = profit paid
        uint256 collected; // funding collected from a payer
        uint256 credited; // funding credited to a receiver
        uint256 unpaid; // funding a payer could not pay (bad debt carried by the Vault)
    }

    /*//////////////////////////////////////////////////////////////
                            GHOST VARIABLES
    //////////////////////////////////////////////////////////////*/

    mapping(bytes32 => uint256) public calls;

    uint256 public ghostOpened;
    uint256 public ghostSettled;
    uint256 public ghostLiquidated;
    uint256 public ghostMismatches;

    uint256 public ghostOpenCollateral;
    uint256 public ghostOpenLongSize;
    uint256 public ghostOpenShortSize;

    uint256 public ghostVaultFees; // Vault share of open and close fees
    uint256 public ghostTreasuryFees; // treasury share of open and close fees
    uint256 public ghostTraderLosses;
    uint256 public ghostTraderProfits;

    int256 public ghostFundingSettled; // sum of fundingOwed over settled positions (payer +, receiver -)
    uint256 public ghostFundingCollected;
    uint256 public ghostFundingCredited;
    uint256 public ghostFundingBadDebt;

    /// @dev A settlement action that settles nothing reverts, so in the forge metrics table calls - reverts = settlements
    error NotSettled();

    modifier countCall(bytes32 _key) {
        calls[_key]++;
        _;
    }

    constructor(TradingEngine _engine, TradingStorage _storage, Vault _vault, MockOracle _oracle, ERC20 _usdc) {
        ENGINE = _engine;
        TRADING_STORAGE = _storage;
        VAULT = _vault;
        ORACLE = _oracle;
        USDC = _usdc;
        for (uint256 i; i < 4; ++i) {
            actors.push(address(uint160(uint256(keccak256(abi.encode("actor", i))))));
        }
    }

    /*//////////////////////////////////////////////////////////////
                               ACTIONS
    //////////////////////////////////////////////////////////////*/

    struct OpenParams {
        address trader;
        uint64 collateral;
        uint16 leverage;
        uint256 fee;
        uint256 sizeWad;
        uint128 exec;
        uint128 tp;
        uint128 sl;
    }

    /// @notice A trader opens a position, with a TP and an SL when the seeds ask for one
    function openTrade(uint256 _actorSeed, uint256 _collateral, uint256 _leverage, bool _isLong, uint256 _tpSeed, uint256 _slSeed)
        external
        countCall("openTrade")
    {
        if (ENGINE.paused()) return;
        OpenParams memory p = _openParams(_actorSeed, _collateral, _leverage, _isLong, _tpSeed, _slSeed);
        if (TRADING_STORAGE.getOpenInterest(PAIR_INDEX) + p.sizeWad > MAX_OI) return;

        deal(address(USDC), p.trader, p.collateral);
        vm.prank(p.trader);
        USDC.approve(address(ENGINE), p.collateral);
        vm.prank(p.trader);
        uint32 tradeId = ENGINE.openTrade(PAIR_INDEX, _isLong, p.collateral, p.leverage, p.exec, 1, p.tp, p.sl, EMPTY_UPDATE);

        uint256 vaultFee = (p.fee * VAULT_FEE_SHARE_BPS) / BPS;
        ghostVaultFees += vaultFee;
        ghostTreasuryFees += p.fee - vaultFee;
        ghostOpenCollateral += p.collateral - p.fee;
        if (_isLong) ghostOpenLongSize += p.sizeWad;
        else ghostOpenShortSize += p.sizeWad;
        openTradeIds.push(tradeId);
        ghostOpened++;
    }

    function _openParams(uint256 _actorSeed, uint256 _collateral, uint256 _leverage, bool _isLong, uint256 _tpSeed, uint256 _slSeed)
        internal
        view
        returns (OpenParams memory p)
    {
        p.trader = actors[bound(_actorSeed, 0, actors.length - 1)];
        p.collateral = uint64(bound(_collateral, 10 * 10 ** 6, 5_000 * 10 ** 6));
        p.leverage = uint16(bound(_leverage, 1, 100));
        p.fee = (uint256(p.collateral) * p.leverage * OPEN_FEE_BPS) / BPS;
        p.sizeWad = (p.collateral - p.fee) * p.leverage * 1e12;
        uint128 oracle = ORACLE.peekPrice(PAIR_INDEX);
        p.exec = uint128((uint256(oracle) * (_isLong ? BPS + SPREAD_BPS : BPS - SPREAD_BPS)) / BPS);
        p.tp = _limitPrice(_isLong, true, oracle, p.exec, _tpSeed);
        p.sl = _limitPrice(_isLong, false, oracle, p.exec, _slSeed);
    }

    /// @notice The owner of an open position closes it at the oracle price
    function closeTrade(uint256 _tradeSeed) external countCall("closeTrade") {
        if (ENGINE.paused()) revert NotSettled();
        (uint256 tradeId, TradingStorage.Trade memory trade) = _pick(_tradeSeed);
        if (trade.user == address(0)) revert NotSettled();

        uint128 exec = _closeExec(ORACLE.peekPrice(PAIR_INDEX), trade.isLong);
        uint256 traderBefore = USDC.balanceOf(trade.user);

        // Reverts with InsufficientVaultBalance when a winning close exceeds the Vault's USDC (documented limitation)
        vm.prank(trade.user);
        ENGINE.closeTrade(tradeId, exec, 1, EMPTY_UPDATE);
        _record(tradeId, trade, exec, CLOSE, USDC.balanceOf(trade.user) - traderBefore, 0);
    }

    /// @notice A keeper liquidates a position; reverts (and is discarded) when it is not liquidatable
    function liquidate(uint256 _tradeSeed) external countCall("liquidate") {
        (uint256 tradeId, TradingStorage.Trade memory trade) = _pick(_tradeSeed);
        if (trade.user == address(0)) revert NotSettled();

        // MockOracle conf is 0, so the conservative liquidation price is the oracle price
        uint128 exec = _closeExec(ORACLE.peekPrice(PAIR_INDEX), trade.isLong);
        uint256 keeperBefore = USDC.balanceOf(KEEPER);
        uint256 traderBefore = USDC.balanceOf(trade.user);

        vm.prank(KEEPER);
        ENGINE.liquidate(tradeId, EMPTY_UPDATE);
        _record(tradeId, trade, exec, LIQUIDATION, USDC.balanceOf(trade.user) - traderBefore, USDC.balanceOf(KEEPER) - keeperBefore);
        ghostLiquidated++;
    }

    /// @notice A keeper executes a triggered TP or SL; reverts (and is discarded) when nothing is triggered
    function executeLimit(uint256 _tradeSeed) external countCall("executeLimit") {
        if (ENGINE.paused()) revert NotSettled();
        (uint256 tradeId, TradingStorage.Trade memory trade) = _pick(_tradeSeed);
        if (trade.user == address(0)) revert NotSettled();

        uint128 exec = _closeExec(ORACLE.peekPrice(PAIR_INDEX), trade.isLong);
        uint256 keeperBefore = USDC.balanceOf(KEEPER);
        uint256 traderBefore = USDC.balanceOf(trade.user);

        vm.prank(KEEPER);
        ENGINE.executeLimit(tradeId, EMPTY_UPDATE);
        _record(tradeId, trade, exec, LIMIT, USDC.balanceOf(trade.user) - traderBefore, USDC.balanceOf(KEEPER) - keeperBefore);
    }

    /// @notice The owner moves the TP of an open position (seed 0 clears it)
    function updateTp(uint256 _tradeSeed, uint256 _tpSeed) external countCall("updateTp") {
        if (ENGINE.paused()) return;
        (uint256 tradeId, TradingStorage.Trade memory trade) = _pick(_tradeSeed);
        if (trade.user == address(0)) return;
        uint128 tp = _limitPrice(trade.isLong, true, ORACLE.peekPrice(PAIR_INDEX), trade.openPrice, _tpSeed);
        vm.prank(trade.user);
        ENGINE.updateTp(tradeId, tp, EMPTY_UPDATE);
    }

    /// @notice The owner moves the SL of an open position (seed 0 clears it)
    function updateSl(uint256 _tradeSeed, uint256 _slSeed) external countCall("updateSl") {
        if (ENGINE.paused()) return;
        (uint256 tradeId, TradingStorage.Trade memory trade) = _pick(_tradeSeed);
        if (trade.user == address(0)) return;
        uint128 sl = _limitPrice(trade.isLong, false, ORACLE.peekPrice(PAIR_INDEX), trade.openPrice, _slSeed);
        vm.prank(trade.user);
        ENGINE.updateSl(tradeId, sl, EMPTY_UPDATE);
    }

    /*//////////////////////////////////////////////////////////////
                          SETTLEMENT MODEL
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Model one settlement and record it. The funding amount is the one the engine used: the position's
     *      side index after the call (the engine accrues before settling) minus its entry index.
     */
    function _record(uint256 _tradeId, TradingStorage.Trade memory _trade, uint128 _exec, uint8 _kind, uint256 _traderGot, uint256 _keeperGot) internal {
        uint256 size = uint256(_trade.collateral) * _trade.leverage;
        int256 pnl = _pnl(size, _trade.openPrice, _exec, _trade.isLong);
        int256 funding = FundingLib.calculateFundingOwed(
            size * 1e12, TRADING_STORAGE.getCumulativeFundingIndex(PAIR_INDEX, _trade.isLong), TRADING_STORAGE.getTradeFundingIndex(_tradeId)
        );
        Settlement memory s = _model(_trade.collateral, _trade.leverage, pnl, funding, _kind);

        if (s.traderGets != _traderGot || s.keeperGets != _keeperGot) ghostMismatches++;

        uint256 vaultFee = (s.fee * VAULT_FEE_SHARE_BPS) / BPS;
        ghostVaultFees += vaultFee;
        ghostTreasuryFees += s.fee - vaultFee;
        if (s.vaultNet >= 0) ghostTraderLosses += uint256(s.vaultNet);
        else ghostTraderProfits += uint256(-s.vaultNet);

        ghostFundingSettled += funding;
        ghostFundingCollected += s.collected;
        ghostFundingCredited += s.credited;
        ghostFundingBadDebt += s.unpaid;

        ghostOpenCollateral -= _trade.collateral;
        if (_trade.isLong) ghostOpenLongSize -= size * 1e12;
        else ghostOpenShortSize -= size * 1e12;
        _removeTradeId(_tradeId);
        ghostSettled++;
    }

    /**
     * @dev Documented settlement formulas.
     *      Close / limit: base = C + min(pnl, 8C); payoutBeforeFee = max(0, base - funding);
     *      fee = min(closeFee, payoutBeforeFee); executor reward (limit) = min(0.1% notional, payout after fee).
     *      Liquidation: loss = max(0, funding - pnl); reward = max(10% of (C - loss) floored at 0, 0.5% of C).
     */
    function _model(uint256 _collateral, uint256 _leverage, int256 _pricePnl, int256 _funding, uint8 _kind) internal pure returns (Settlement memory s) {
        if (_kind == LIQUIDATION) return _modelLiquidation(_collateral, _pricePnl, _funding);

        int256 maxProfit = int256(_collateral * MAX_PROFIT_MULTIPLE);
        int256 base = int256(_collateral) + (_pricePnl > maxProfit ? maxProfit : _pricePnl);
        uint256 payoutBeforeFee = _splitFunding(s, base, _funding);

        s.fee = (_collateral * _leverage * CLOSE_FEE_BPS) / BPS;
        if (s.fee > payoutBeforeFee) s.fee = payoutBeforeFee;
        uint256 payout = payoutBeforeFee - s.fee;
        if (_kind == LIMIT) {
            s.keeperGets = (_collateral * _leverage * EXEC_REWARD_BPS) / BPS;
            if (s.keeperGets > payout) s.keeperGets = payout;
        }
        s.traderGets = payout - s.keeperGets;
        s.vaultNet = int256(_collateral) - int256(s.fee) - int256(payout);
    }

    /// @dev payoutBeforeFee = max(0, base - funding); records what a payer paid or a receiver was credited
    function _splitFunding(Settlement memory _s, int256 _base, int256 _funding) internal pure returns (uint256 payoutBeforeFee) {
        int256 net = _base - _funding;
        payoutBeforeFee = net > 0 ? uint256(net) : 0;
        uint256 baseFloor = _base > 0 ? uint256(_base) : 0;
        if (_funding > 0) {
            _s.collected = baseFloor < uint256(_funding) ? baseFloor : uint256(_funding);
            _s.unpaid = uint256(_funding) - _s.collected;
        } else if (_funding < 0) {
            _s.credited = payoutBeforeFee - baseFloor;
        }
    }

    /// @dev Reward first, then price loss, then funding: the part of the funding the collateral cannot cover is unpaid
    function _modelLiquidation(uint256 _collateral, int256 _pricePnl, int256 _funding) internal pure returns (Settlement memory s) {
        int256 adjusted = _pricePnl - _funding;
        uint256 loss = adjusted < 0 ? uint256(-adjusted) : 0;
        uint256 remaining = loss >= _collateral ? 0 : _collateral - loss;
        uint256 reward = (remaining * LIQ_REWARD_BPS) / BPS;
        uint256 minReward = (_collateral * LIQ_MIN_REWARD_BPS) / BPS;
        if (reward < minReward) reward = minReward;
        s.keeperGets = reward;
        s.vaultNet = int256(_collateral) - int256(reward);
        if (_funding > 0) {
            int256 available = int256(_collateral) + _pricePnl - int256(reward);
            uint256 coverable = available > 0 ? uint256(available) : 0;
            s.collected = coverable < uint256(_funding) ? coverable : uint256(_funding);
            s.unpaid = uint256(_funding) - s.collected;
        }
    }

    function _pnl(uint256 _size, uint128 _open, uint128 _close, bool _isLong) internal pure returns (int256) {
        if (_isLong) return int256((uint256(_close) * _size) / _open) - int256(_size);
        uint256 exitValue = (uint256(_close) * _size + _open - 1) / _open;
        return int256(_size) - int256(exitValue);
    }

    function _closeExec(uint128 _oracle, bool _isLong) internal pure returns (uint128) {
        return uint128((uint256(_oracle) * (_isLong ? BPS - SPREAD_BPS : BPS + SPREAD_BPS)) / BPS);
    }

    /**
     * @dev A valid TP or SL 0.1% to 20% away from both the oracle price and the reference (open) price,
     *      on the side the engine and storage accept; seed 0 returns 0 (not set).
     */
    function _limitPrice(bool _isLong, bool _isTp, uint128 _oracle, uint128 _reference, uint256 _seed) internal pure returns (uint128) {
        if (_seed % 3 == 0) return 0;
        uint256 distanceBps = bound(_seed, 10, 2000);
        bool above = _isLong == _isTp; // long TP and short SL sit above both prices
        uint256 anchor = above ? (_oracle > _reference ? _oracle : _reference) : (_oracle < _reference ? _oracle : _reference);
        return uint128(above ? (anchor * (BPS + distanceBps)) / BPS + 1 : (anchor * (BPS - distanceBps)) / BPS - 1);
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _pick(uint256 _seed) internal view returns (uint256 tradeId, TradingStorage.Trade memory trade) {
        uint256 len = openTradeIds.length;
        if (len == 0) return (0, trade);
        tradeId = openTradeIds[bound(_seed, 0, len - 1)];
        trade = TRADING_STORAGE.getTrade(tradeId);
    }

    function _removeTradeId(uint256 _tradeId) internal {
        uint256 len = openTradeIds.length;
        for (uint256 i; i < len; ++i) {
            if (openTradeIds[i] == _tradeId) {
                openTradeIds[i] = openTradeIds[len - 1];
                openTradeIds.pop();
                return;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                               VIEWS
    //////////////////////////////////////////////////////////////*/

    function openTradeCount() external view returns (uint256) {
        return openTradeIds.length;
    }

    /// @notice Funding accrued by open positions at the stored side indexes (payer +, receiver -)
    function openAccruedFunding() external view returns (int256 accrued) {
        uint256 len = openTradeIds.length;
        for (uint256 i; i < len; ++i) {
            TradingStorage.Trade memory trade = TRADING_STORAGE.getTrade(openTradeIds[i]);
            uint256 sizeWad = uint256(trade.collateral) * trade.leverage * 1e12;
            accrued += FundingLib.calculateFundingOwed(
                sizeWad, TRADING_STORAGE.getCumulativeFundingIndex(PAIR_INDEX, trade.isLong), TRADING_STORAGE.getTradeFundingIndex(openTradeIds[i])
            );
        }
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }
}
