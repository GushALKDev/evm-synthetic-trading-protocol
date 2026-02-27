// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";
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
 *      Validation pipeline: Feed active → Pyth staleness → Non-zero → Confidence → Normalize → Chainlink staleness → Deviation
 *      The oracle pays Pyth fees from its own ETH balance (funded via receive()).
 */
contract PythChainlinkOracle is IOracle, Ownable {
    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant MAX_STALENESS = 30; // seconds
    uint256 public constant MAX_CONFIDENCE_BPS = 200; // 2%
    uint256 public constant MAX_DEVIATION_BPS = 300; // 3%
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint8 public constant TARGET_DECIMALS = 18;

    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    // prettier-ignore
    struct PairFeed {
        bytes32 pythFeedId;         // Slot 0 (32 bytes)
        address chainlinkFeed;      // 20 bytes ─┐
        uint32  chainlinkHeartbeat; //  4 bytes  │  Slot 1 (25 bytes)
        bool    active;             //  1 byte  ─┘
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    IPyth public immutable PYTH;

    mapping(uint256 => PairFeed) private _pairFeeds;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event PairFeedSet(uint256 indexed pairIndex, bytes32 pythFeedId, address chainlinkFeed, uint32 heartbeat);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error PairFeedNotSet(uint256 pairIndex);
    error StalePrice(bytes32 feedId, uint256 publishTime, uint256 blockTime);
    error ConfidenceTooWide(uint64 confidence, int64 price);
    error ZeroPrice();
    error PriceDeviationTooHigh(uint256 pythPrice18, uint256 chainlinkPrice18);
    error ChainlinkStalePrice(address feed, uint256 updatedAt, uint256 blockTime);
    error InvalidPairFeed();
    error InsufficientEthForFee(uint256 available, uint256 required);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _pyth, address _owner) {
        if (_pyth == address(0)) revert InvalidPairFeed();
        _initializeOwner(_owner);
        PYTH = IPyth(_pyth);
    }

    /*//////////////////////////////////////////////////////////////
                            RECEIVE ETH
    //////////////////////////////////////////////////////////////*/

    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                          CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get a validated price for a trading pair
     * @dev Pipeline: Feed active → Update Pyth → Staleness → Non-zero → Confidence → Normalize → Chainlink check → Deviation.
     *      Pyth fee paid from contract's own ETH balance.
     * @param pairIndex The pair index to get price for
     * @param priceData Pyth-signed price update data (submitted by user, verified on-chain)
     * @return price18 Validated price normalized to 18 decimals
     */
    function getPrice(uint256 pairIndex, bytes[] calldata priceData) external returns (uint128 price18) {
        PairFeed storage feed = _pairFeeds[pairIndex];
        if (!feed.active) revert PairFeedNotSet(pairIndex);

        // Compute fee and pay from own balance
        uint256 fee = PYTH.getUpdateFee(priceData);
        if (address(this).balance < fee) revert InsufficientEthForFee(address(this).balance, fee);

        PYTH.updatePriceFeeds{value: fee}(priceData);

        // Get latest Pyth price (unsafe = no staleness check, we do our own)
        PythStructs.Price memory pythPrice = PYTH.getPriceUnsafe(feed.pythFeedId);

        // Staleness check
        if (block.timestamp - pythPrice.publishTime > MAX_STALENESS) {
            revert StalePrice(feed.pythFeedId, pythPrice.publishTime, block.timestamp);
        }

        // Non-zero check
        if (pythPrice.price <= 0) revert ZeroPrice();

        // Confidence check: conf / |price| <= MAX_CONFIDENCE_BPS / BPS_DENOMINATOR
        uint64 absPrice = uint64(pythPrice.price);
        if (uint256(pythPrice.conf) * BPS_DENOMINATOR > uint256(absPrice) * MAX_CONFIDENCE_BPS) {
            revert ConfidenceTooWide(pythPrice.conf, pythPrice.price);
        }

        // Normalize Pyth price to 18 decimals
        uint256 pythNormalized = PythUtils.convertToUint(pythPrice.price, pythPrice.expo, TARGET_DECIMALS);

        // Chainlink deviation anchor
        uint256 chainlinkNormalized = _getChainlinkPrice18(feed.chainlinkFeed, feed.chainlinkHeartbeat);

        // Deviation check: |pyth - chainlink| / chainlink <= MAX_DEVIATION_BPS / BPS_DENOMINATOR
        uint256 diff = pythNormalized > chainlinkNormalized ? pythNormalized - chainlinkNormalized : chainlinkNormalized - pythNormalized;
        if (diff * BPS_DENOMINATOR > chainlinkNormalized * MAX_DEVIATION_BPS) {
            revert PriceDeviationTooHigh(pythNormalized, chainlinkNormalized);
        }

        price18 = uint128(pythNormalized);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Fetch Chainlink price, check heartbeat staleness, normalize to 18 decimals
     */
    function _getChainlinkPrice18(address _feed, uint32 _heartbeat) internal view returns (uint256) {
        (, int256 answer, , uint256 updatedAt, ) = AggregatorV3Interface(_feed).latestRoundData();

        if (block.timestamp - updatedAt > uint256(_heartbeat)) {
            revert ChainlinkStalePrice(_feed, updatedAt, block.timestamp);
        }

        if (answer <= 0) revert ZeroPrice();

        // Chainlink feeds typically use 8 decimals → normalize to 18
        uint8 feedDecimals = AggregatorV3Interface(_feed).decimals();
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
