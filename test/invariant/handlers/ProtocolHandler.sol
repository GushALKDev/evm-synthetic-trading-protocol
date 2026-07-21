// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {TradingEngine} from "../../../src/TradingEngine.sol";
import {TradingStorage} from "../../../src/TradingStorage.sol";
import {Vault} from "../../../src/Vault.sol";
import {MockOracle} from "../../mocks/MockOracle.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

/**
 * @title ProtocolHandler
 * @author GushALKDev
 * @notice Stateful fuzzing handler driving the trading protocol through random but always-valid
 *         action sequences, so the invariant suite explores realistic states instead of reverting.
 * @dev Every action bounds its inputs and returns early when preconditions do not hold (`_bound` +
 *      guard clauses), because a reverting call would be silently discarded and waste a fuzz run.
 *      Actors are a fixed set of funded addresses so positions accumulate across calls. The oracle
 *      price is walked within a band rather than jumped randomly, so trades pass through profit,
 *      loss and liquidation territory instead of being instantly liquidatable.
 */
contract ProtocolHandler is CommonBase, StdCheats, StdUtils {
    TradingEngine public immutable ENGINE;
    TradingStorage public immutable TRADING_STORAGE;
    Vault public immutable VAULT;
    MockOracle public immutable ORACLE;
    ERC20 public immutable USDC;

    uint16 public constant PAIR_INDEX = 0;
    uint128 public constant INITIAL_PRICE = 50_000 * 1e18;
    uint64 public constant MIN_COLLATERAL = 10 * 10 ** 6;
    /// @dev Comfortably above the 5 bps mock spread, so opens/closes are never rejected on slippage
    uint16 public constant MAX_SLIPPAGE_BPS = 100;
    bytes[] internal EMPTY_UPDATE;

    address[] public actors;
    address internal currentActor;

    /// @notice Trade IDs opened by the handler and believed to still be open
    uint256[] public openTradeIds;

    /*//////////////////////////////////////////////////////////////
                            GHOST VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Sum of effective collateral (post open-fee) currently held for open trades
    uint256 public ghostOpenCollateral;
    /// @notice Number of times each action actually executed, for coverage introspection
    mapping(bytes32 => uint256) public calls;
    /// @notice Liquidations that actually settled (the rest found the position still solvent)
    uint256 public ghostLiquidations;

    modifier useActor(uint256 _actorSeed) {
        currentActor = actors[bound(_actorSeed, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

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

    /// @notice LP deposits USDC into the Vault
    function deposit(uint256 _actorSeed, uint256 _assets) external useActor(_actorSeed) countCall("deposit") {
        uint256 assets = bound(_assets, 1 * 10 ** 6, 100_000 * 10 ** 6);
        deal(address(USDC), currentActor, assets);
        USDC.approve(address(VAULT), assets);
        VAULT.deposit(assets, currentActor);
    }

    /// @notice Trader opens a leveraged position
    function openTrade(uint256 _actorSeed, uint256 _collateral, uint256 _leverage, bool _isLong)
        external
        useActor(_actorSeed)
        countCall("openTrade")
    {
        // Keep notional well inside maxOI so opens are not rejected en masse
        uint64 collateral = uint64(bound(_collateral, MIN_COLLATERAL, 5_000 * 10 ** 6));
        uint16 leverage = uint16(bound(_leverage, 1, 50));

        deal(address(USDC), currentActor, collateral);
        USDC.approve(address(ENGINE), collateral);

        // Slippage is validated against _expectedPrice, so it must be the live oracle price: passing 0
        // would make every deviation infinite and revert every open. No TP/SL — this handler
        // exercises the manual close and liquidation paths.
        uint128 expectedPrice = ORACLE.peekPrice(PAIR_INDEX);
        uint32 tradeId = ENGINE.openTrade(
            PAIR_INDEX, _isLong, collateral, leverage, expectedPrice, MAX_SLIPPAGE_BPS, 0, 0, EMPTY_UPDATE
        );
        openTradeIds.push(tradeId);
        ghostOpenCollateral += TRADING_STORAGE.getTrade(tradeId).collateral;
    }

    /// @notice Trader closes one of their own open positions
    function closeTrade(uint256 _tradeSeed) external countCall("closeTrade") {
        (uint256 tradeId, TradingStorage.Trade memory trade) = _pickOpenTrade(_tradeSeed);
        if (trade.user == address(0)) return;

        ghostOpenCollateral -= trade.collateral;
        // startPrank/stopPrank (not prank) because the fuzzer may already have a prank active here
        vm.startPrank(trade.user);
        ENGINE.closeTrade(tradeId, ORACLE.peekPrice(PAIR_INDEX), MAX_SLIPPAGE_BPS, EMPTY_UPDATE);
        vm.stopPrank();
        _removeTradeId(tradeId);
    }

    /// @notice Anyone liquidates an underwater position (no-op when it is not liquidatable)
    function liquidate(uint256 _tradeSeed, uint256 _actorSeed) external countCall("liquidate") {
        (uint256 tradeId, TradingStorage.Trade memory trade) = _pickOpenTrade(_tradeSeed);
        if (trade.user == address(0)) return;

        address liquidator = actors[bound(_actorSeed, 0, actors.length - 1)];
        vm.startPrank(liquidator);
        try ENGINE.liquidate(tradeId, EMPTY_UPDATE) {
            ghostOpenCollateral -= trade.collateral;
            ghostLiquidations++;
            _removeTradeId(tradeId);
        } catch {
            // Position is still solvent — expected for most calls
        }
        vm.stopPrank();
    }

    /**
     * @notice Move the oracle price within a bounded band around the initial price
     * @dev Bounded to ±30% so positions drift into profit/loss/liquidation gradually. An unbounded
     *      jump would make nearly every leveraged position instantly liquidatable and collapse the
     *      state space the invariants are meant to explore.
     */
    function movePrice(uint256 _priceSeed) external countCall("movePrice") {
        uint128 newPrice = uint128(bound(_priceSeed, (INITIAL_PRICE * 70) / 100, (INITIAL_PRICE * 130) / 100));
        ORACLE.setPrice(PAIR_INDEX, newPrice);
    }

    /// @notice Advance time so funding accrues between actions
    function warp(uint256 _timeSeed) external countCall("warp") {
        vm.warp(block.timestamp + bound(_timeSeed, 1 minutes, 7 days));
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Pick a still-open trade, pruning IDs that were closed or liquidated behind our back.
     *      Returns a zeroed trade (user == address(0)) when none is available.
     */
    function _pickOpenTrade(uint256 _seed) internal returns (uint256 tradeId, TradingStorage.Trade memory trade) {
        uint256 len = openTradeIds.length;
        if (len == 0) return (0, trade);

        uint256 idx = bound(_seed, 0, len - 1);
        tradeId = openTradeIds[idx];
        trade = TRADING_STORAGE.getTrade(tradeId);

        if (trade.user == address(0)) {
            openTradeIds[idx] = openTradeIds[len - 1];
            openTradeIds.pop();
        }
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

    function openTradeCount() external view returns (uint256) {
        return openTradeIds.length;
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }
}
