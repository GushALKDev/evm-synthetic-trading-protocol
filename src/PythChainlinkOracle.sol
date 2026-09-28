// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {PythUtils} from "@pythnetwork/pyth-sdk-solidity/PythUtils.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IOracle} from "./interfaces/IOracle.sol";

/**
 * @title PythChainlinkOracle
 * @author GushALKDev
 * @notice IOracle implementation: Pyth Network (primary) with Chainlink as deviation anchor
 * @dev Pyth is pull-based: callers submit signed priceData bytes, verified on-chain.
 *      Chainlink is ONLY used as a deviation anchor — if Pyth is stale, we REVERT (no fallback).
 *      Validation pipeline: Feed active → Sequencer up → Pyth age → Non-zero → Confidence → Normalize → Chainlink staleness → Deviation
 *      Sequencer up: on L2s with a Chainlink sequencer uptime feed, prices are refused while the sequencer is
 *      down. For SEQUENCER_GRACE_PERIOD after it comes back, checkOpenAllowed reverts, so no new position opens
 *      on prices traders could not react to; closes, TP/SL, liquidations and the vault keep reading prices,
 *      because a position cannot be topped up and blocking its liquidation would let it run past 100% loss.
 *      The feed is a constructor parameter; address(0) disables both checks.
 *      Pyth age: publishTime must not be after block.timestamp and must be at most maxPriceAge old. Every
 *      getPrice call is a trade execution or a TP/SL validation, so the same limit applies to all of them.
 *      The caller funds the Pyth fee via msg.value on getPrice; any surplus is refunded to the caller.
 */
contract PythChainlinkOracle is IOracle, Ownable {
    using SafeTransferLib for address;

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant MAX_STALENESS = 30; // seconds, immutable ceiling for maxPriceAge
    uint256 public constant DEFAULT_MAX_PRICE_AGE = 5; // seconds
    uint256 public constant SEQUENCER_GRACE_PERIOD = 3600; // seconds after the sequencer comes back up
    uint256 public constant MAX_CONFIDENCE_BPS = 200; // 2%
    uint256 public constant MAX_DEVIATION_BPS = 300; // 3%
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint8 public constant TARGET_DECIMALS = 18;

    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    struct PairFeed {
        bytes32 pythFeedId; //       32 bytes -── Slot 0 (full)
        address chainlinkFeed; //    20 bytes -┐
        uint32 chainlinkHeartbeat; // 4 bytes  │  Slot 1 (25/32)
        bool active; //               1 byte  -┘
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    IPyth public immutable PYTH;

    /**
     * @notice Chainlink L2 sequencer uptime feed (answer 0 = up, 1 = down); address(0) disables the check
     */
    AggregatorV3Interface public immutable SEQUENCER_UPTIME_FEED;

    /**
     * @notice Maximum age of the Pyth price used by getPrice, in seconds (1 to MAX_STALENESS)
     */
    uint256 public maxPriceAge;

    mapping(uint256 => PairFeed) private _pairFeeds;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event PairFeedSet(uint256 indexed pairIndex, bytes32 pythFeedId, address chainlinkFeed, uint32 heartbeat);
    event MaxPriceAgeSet(uint256 maxPriceAge);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error PairFeedNotSet(uint256 pairIndex);
    error StalePrice(bytes32 feedId, uint256 publishTime, uint256 blockTime);
    error PriceFromFuture(bytes32 feedId, uint256 publishTime, uint256 blockTime);
    error InvalidMaxPriceAge(uint256 maxPriceAge);
    error SequencerDown();
    error SequencerGracePeriodNotOver(uint256 upSince, uint256 blockTime);
    error ConfidenceTooWide(uint64 confidence, int64 price);
    error ZeroPrice();
    error PriceDeviationTooHigh(uint256 pythPrice18, uint256 chainlinkPrice18);
    error ChainlinkStalePrice(address feed, uint256 updatedAt, uint256 blockTime);
    error InvalidPairFeed();
    error InsufficientFee(uint256 provided, uint256 required);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param _pyth Pyth contract
     * @param _sequencerUptimeFeed Chainlink L2 sequencer uptime feed, or address(0) on chains without one
     * @param _owner Contract owner
     */
    constructor(address _pyth, address _sequencerUptimeFeed, address _owner) {
        if (_pyth == address(0)) revert InvalidPairFeed();
        _initializeOwner(_owner);
        PYTH = IPyth(_pyth);
        SEQUENCER_UPTIME_FEED = AggregatorV3Interface(_sequencerUptimeFeed);
        maxPriceAge = DEFAULT_MAX_PRICE_AGE;
    }

    /*//////////////////////////////////////////////////////////////
                          CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get a validated price for a trading pair
     * @dev Pipeline: Feed active → Sequencer up → Update Pyth → Age → Non-zero → Confidence → Normalize → Chainlink check → Deviation.
     *      The caller funds the Pyth fee via msg.value; any surplus is refunded to msg.sender.
     * @param pairIndex The pair index to get price for
     * @param priceData Pyth-signed price update data (submitted by user, verified on-chain)
     * @return price18 Validated price normalized to 18 decimals
     * @return conf18 Pyth confidence band normalized to 18 decimals
     */
    function getPrice(uint256 pairIndex, bytes[] calldata priceData) external payable returns (uint128 price18, uint128 conf18) {
        PairFeed storage feed = _pairFeeds[pairIndex];
        if (!feed.active) revert PairFeedNotSet(pairIndex);
        _checkSequencerUp();

        // Caller funds the fee; require enough and refund the surplus at the end
        uint256 fee = PYTH.getUpdateFee(priceData);
        if (msg.value < fee) revert InsufficientFee(msg.value, fee);

        PYTH.updatePriceFeeds{value: fee}(priceData);

        // Get latest Pyth price (unsafe = no staleness check, we do our own)
        PythStructs.Price memory pythPrice = PYTH.getPriceUnsafe(feed.pythFeedId);

        // Age check. A publishTime after block.timestamp was never observed on Arbitrum (see docs), so it
        // is rejected with a named error rather than accepted with a skew or left to underflow.
        if (pythPrice.publishTime > block.timestamp) revert PriceFromFuture(feed.pythFeedId, pythPrice.publishTime, block.timestamp);
        if (block.timestamp - pythPrice.publishTime > maxPriceAge) {
            revert StalePrice(feed.pythFeedId, pythPrice.publishTime, block.timestamp);
        }

        // Non-zero check
        if (pythPrice.price <= 0) revert ZeroPrice();

        // Confidence check: conf / |price| <= MAX_CONFIDENCE_BPS / BPS_DENOMINATOR
        // Safe cast: the price is positive here (PythChainlinkOracle.sol:149)
        uint64 absPrice = uint64(pythPrice.price);
        if (uint256(pythPrice.conf) * BPS_DENOMINATOR > uint256(absPrice) * MAX_CONFIDENCE_BPS) {
            revert ConfidenceTooWide(pythPrice.conf, pythPrice.price);
        }

        // Normalize Pyth price and confidence band to 18 decimals (conf shares the price exponent)
        uint256 pythNormalized = PythUtils.convertToUint(pythPrice.price, pythPrice.expo, TARGET_DECIMALS);
        // Safe cast: conf is at most 2% of the price, a positive int64 (PythChainlinkOracle.sol:154)
        uint256 confNormalized = PythUtils.convertToUint(int64(pythPrice.conf), pythPrice.expo, TARGET_DECIMALS);

        // Chainlink deviation anchor
        uint256 chainlinkNormalized = _getChainlinkPrice18(feed.chainlinkFeed, feed.chainlinkHeartbeat);

        // Deviation check: |pyth - chainlink| / chainlink <= MAX_DEVIATION_BPS / BPS_DENOMINATOR
        uint256 diff = pythNormalized > chainlinkNormalized ? pythNormalized - chainlinkNormalized : chainlinkNormalized - pythNormalized;
        if (diff * BPS_DENOMINATOR > chainlinkNormalized * MAX_DEVIATION_BPS) {
            revert PriceDeviationTooHigh(pythNormalized, chainlinkNormalized);
        }

        // SafeCastLib: the normalized price has no enforced bound, it depends on the feed exponent
        price18 = SafeCastLib.toUint128(pythNormalized);
        conf18 = SafeCastLib.toUint128(confNormalized);

        // Refund any ETH sent above the fee
        uint256 surplus = msg.value - fee;
        if (surplus > 0) msg.sender.safeTransferETH(surplus);
    }

    /**
     * @notice Revert while the L2 sequencer is down or within SEQUENCER_GRACE_PERIOD of coming back up
     * @dev Called by TradingEngine.openTrade only; see the contract header for why other actions are not blocked.
     */
    function checkOpenAllowed() external view {
        uint256 startedAt = _checkSequencerUp();
        if (startedAt != 0 && block.timestamp - startedAt <= SEQUENCER_GRACE_PERIOD) revert SequencerGracePeriodNotOver(startedAt, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Revert while the L2 sequencer is down. startedAt is the time of the last status change; Chainlink
     *      documents startedAt == 0 as an uninitialized feed on Arbitrum, which is treated as down.
     * @return startedAt Time the sequencer came back up, or 0 when the check is disabled
     */
    function _checkSequencerUp() internal view returns (uint256 startedAt) {
        if (address(SEQUENCER_UPTIME_FEED) == address(0)) return 0;
        int256 answer;
        (, answer, startedAt,,) = SEQUENCER_UPTIME_FEED.latestRoundData();
        if (answer != 0 || startedAt == 0) revert SequencerDown();
    }

    /**
     * @dev Fetch Chainlink price, check heartbeat staleness, normalize to 18 decimals
     */
    function _getChainlinkPrice18(address _feed, uint32 _heartbeat) internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(_feed).latestRoundData();

        if (block.timestamp - updatedAt > uint256(_heartbeat)) {
            revert ChainlinkStalePrice(_feed, updatedAt, block.timestamp);
        }

        if (answer <= 0) revert ZeroPrice();

        // Chainlink feeds typically use 8 decimals → normalize to 18
        uint8 feedDecimals = AggregatorV3Interface(_feed).decimals();
        // forge-lint: disable-next-line(unsafe-typecast) safe: the answer is positive here (PythChainlinkOracle.sol:216)
        return uint256(answer) * 10 ** (TARGET_DECIMALS - feedDecimals);
    }

    /*//////////////////////////////////////////////////////////////
                          ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Configure the price feeds for a trading pair
     * @param pairIndex The pair index
     * @param pythFeedId The Pyth price feed ID
     * @param chainlinkFeed The Chainlink aggregator address
     * @param heartbeat The Chainlink heartbeat interval (seconds)
     */
    function setPairFeed(uint256 pairIndex, bytes32 pythFeedId, address chainlinkFeed, uint32 heartbeat) external onlyOwner {
        if (pythFeedId == bytes32(0) || chainlinkFeed == address(0) || heartbeat == 0) revert InvalidPairFeed();

        _pairFeeds[pairIndex] = PairFeed({pythFeedId: pythFeedId, chainlinkFeed: chainlinkFeed, chainlinkHeartbeat: heartbeat, active: true});

        emit PairFeedSet(pairIndex, pythFeedId, chainlinkFeed, heartbeat);
    }

    /**
     * @notice Set the maximum age of the Pyth price accepted by getPrice
     * @param _maxPriceAge Seconds, from 1 to MAX_STALENESS
     */
    function setMaxPriceAge(uint256 _maxPriceAge) external onlyOwner {
        if (_maxPriceAge == 0 || _maxPriceAge > MAX_STALENESS) revert InvalidMaxPriceAge(_maxPriceAge);
        maxPriceAge = _maxPriceAge;
        emit MaxPriceAgeSet(_maxPriceAge);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get the feed configuration for a pair
     * @param pairIndex The pair index
     * @return The PairFeed configuration
     */
    function getPairFeed(uint256 pairIndex) external view returns (PairFeed memory) {
        return _pairFeeds[pairIndex];
    }
}
