// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {PythChainlinkOracle} from "../../src/PythChainlinkOracle.sol";
import {DemoPyth} from "./DemoPyth.sol";

/**
 * @title TestnetPrices
 * @author GushALKDev
 * @notice The DemoPyth update the demo app sends, built the same way for the testnet scripts and tests: the pair's
 *         Chainlink anchor (read from the oracle) becomes a Pyth price with DemoPyth.DEMO_CONF_BPS of confidence
 *         half-width, published at the current block's timestamp
 */
abstract contract TestnetPrices {
    /// @dev Pyth feed ids, the same as on mainnet (Hermes /v2/price_feeds), so DemoPyth stores each price under its real id
    bytes32 internal constant BTC_USD_FEED_ID = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    bytes32 internal constant ETH_USD_FEED_ID = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    bytes32 internal constant LINK_USD_FEED_ID = 0x8ac0c70fff57e9aefdf5edf44b51d62c2d433653cbb2cf5cc06bb115af04d221;

    /**
     * @dev One DemoPyth entry for a pair: its Chainlink anchor's latest answer, published now
     */
    function _mirrorPair(PythChainlinkOracle _oracle, DemoPyth _pyth, uint256 _pairIndex) internal view returns (bytes memory) {
        PythChainlinkOracle.PairFeed memory feed = _oracle.getPairFeed(_pairIndex);
        (, int256 answer,,,) = AggregatorV3Interface(feed.chainlinkFeed).latestRoundData();
        uint8 feedDecimals = AggregatorV3Interface(feed.chainlinkFeed).decimals();
        // forge-lint: disable-next-line(unsafe-typecast) safe: testnet answers are positive and far inside int64; DemoPyth rejects any mismatch
        int64 price = int64(answer);
        // forge-lint: disable-next-line(unsafe-typecast) safe: same bound as the line above
        uint64 conf = uint64((uint256(answer) * _pyth.DEMO_CONF_BPS()) / _pyth.BPS_DENOMINATOR());
        // forge-lint: disable-next-line(unsafe-typecast) safe: Chainlink aggregators report at most 18 decimals
        return _pyth.createPriceFeedUpdateData(feed.pythFeedId, price, conf, -int32(uint32(feedDecimals)), uint64(block.timestamp));
    }

    /**
     * @dev A pair's Chainlink anchor answer at 18 decimals, the oracle price DemoPyth will store for it
     */
    function _anchorPrice18(PythChainlinkOracle _oracle, uint256 _pairIndex) internal view returns (uint128) {
        PythChainlinkOracle.PairFeed memory feed = _oracle.getPairFeed(_pairIndex);
        (, int256 answer,,,) = AggregatorV3Interface(feed.chainlinkFeed).latestRoundData();
        uint8 feedDecimals = AggregatorV3Interface(feed.chainlinkFeed).decimals();
        // forge-lint: disable-next-line(unsafe-typecast) safe: testnet answers are positive and far inside uint128 at 18 decimals
        return uint128(uint256(answer) * 10 ** (18 - feedDecimals));
    }

    /**
     * @dev The update for a set of pairs, one entry each, in the order given
     */
    function _mirrorPairs(PythChainlinkOracle _oracle, DemoPyth _pyth, uint256[] memory _pairIndexes) internal view returns (bytes[] memory update) {
        update = new bytes[](_pairIndexes.length);
        for (uint256 i; i < _pairIndexes.length; ++i) {
            update[i] = _mirrorPair(_oracle, _pyth, _pairIndexes[i]);
        }
    }
}
