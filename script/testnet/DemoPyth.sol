// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

/**
 * @title DemoPyth
 * @author GushALKDev
 * @notice Testnet-only stand-in for the Pyth pull oracle. Never deploy it on a network with real value.
 * @dev Pyth's Hermes service serves price updates only with an API key since the Pyth Core upgrade (26 Aug 2026),
 *      so the public demo cannot fetch signed updates. This contract takes unsigned updates in MockPyth's encoding
 *      (one abi-encoded PythStructs.PriceFeed per entry), and the demo app fills each entry with the Chainlink
 *      answer of the same chain right before the call that needs it.
 *
 *      What it checks, for every entry, when the update lands:
 *      - the feed id has a Chainlink aggregator registered by the owner;
 *      - price equals that aggregator's latest answer, expo equals minus its decimals, and conf equals
 *        answer * DEMO_CONF_BPS / BPS_DENOMINATOR. Nobody can store a price of their choosing: with up to 100x
 *        leverage, a free choice inside the oracle's 3% Chainlink band would let anyone open at one edge of the
 *        band, close at the other and take the profit cap from the Vault, again and again;
 *      - publishTime is not in the future, so a stored price cannot dodge the oracle's age check.
 *      What it does not check: whether the Chainlink answer is fresh (PythChainlinkOracle checks the anchor's
 *      heartbeat), whether a testnet feed tracks the market, or the emaPrice field (the oracle reads only the spot
 *      price, so it is not stored).
 *
 *      Consequences on a deployment that uses it:
 *      - the oracle's 3% deviation check still runs, but cannot fire, since the price equals the anchor;
 *      - an update built from a Chainlink answer that changes before it lands reverts with
 *        PriceNotChainlinkAnswer; building it again from the new answer succeeds;
 *      - the last write wins, whatever its publishTime: the update a call carries is the price that call reads.
 *        Pyth keeps the newest publishTime instead, which with unsigned updates would let anyone store a price
 *        stamped one block ahead of the app's and make every call read theirs.
 */
contract DemoPyth is Ownable {
    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Confidence half-width every entry must carry, in basis points of the Chainlink answer
    uint256 public constant DEMO_CONF_BPS = 5;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Fee charged per update entry, in wei
    uint256 public immutable SINGLE_UPDATE_FEE;

    /// @notice Chainlink aggregator each feed id must mirror
    mapping(bytes32 id => address feed) public chainlinkFeedOf;

    /// @dev Latest stored price per feed id
    mapping(bytes32 id => PythStructs.Price price) private _prices;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Same shape as IPythEvents.PriceFeedUpdate, emitted when a stored price is replaced
    event PriceFeedUpdate(bytes32 indexed id, uint64 publishTime, int64 price, uint64 conf);
    event ChainlinkFeedSet(bytes32 indexed id, address feed);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error InsufficientFee(uint256 provided, uint256 required);
    error FeedNotRegistered(bytes32 id);
    error PriceNotChainlinkAnswer(bytes32 id, int64 price, int256 answer);
    error ExponentMismatch(bytes32 id, int32 expo, int32 expected);
    error ConfidenceMismatch(bytes32 id, uint64 conf, uint256 expected);
    error FuturePublishTime(bytes32 id, uint256 publishTime, uint256 blockTimestamp);
    error PriceFeedNotFound(bytes32 id);
    error ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param _singleUpdateFee Fee per update entry, in wei. The demo uses 1 wei, like the repo's tests
     * @param _owner Account that registers the Chainlink aggregator of each feed id
     */
    constructor(uint256 _singleUpdateFee, address _owner) {
        _initializeOwner(_owner);
        SINGLE_UPDATE_FEE = _singleUpdateFee;
    }

    /*//////////////////////////////////////////////////////////////
                                PYTH API
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Fee for a batch of updates: one SINGLE_UPDATE_FEE per entry, so an empty batch is free
     */
    function getUpdateFee(bytes[] calldata _updateData) public view returns (uint256) {
        return SINGLE_UPDATE_FEE * _updateData.length;
    }

    /**
     * @notice Stores every entry of the update after checking it mirrors its Chainlink aggregator (see the notes)
     * @dev Keeps the whole msg.value, like Pyth: PythChainlinkOracle sends exactly the fee.
     * @param _updateData One abi-encoded PythStructs.PriceFeed per entry
     */
    function updatePriceFeeds(bytes[] calldata _updateData) external payable {
        uint256 fee = getUpdateFee(_updateData);
        if (msg.value < fee) revert InsufficientFee(msg.value, fee);

        for (uint256 i; i < _updateData.length; ++i) {
            PythStructs.PriceFeed memory feed = abi.decode(_updateData[i], (PythStructs.PriceFeed));
            PythStructs.Price memory price = feed.price;
            if (price.publishTime > block.timestamp) revert FuturePublishTime(feed.id, price.publishTime, block.timestamp);
            _requireChainlinkMirror(feed.id, price);

            _prices[feed.id] = price;
            // Safe cast: publishTime is at most block.timestamp here
            emit PriceFeedUpdate(feed.id, uint64(price.publishTime), price.price, price.conf);
        }
    }

    /**
     * @notice Latest stored price, with no freshness check: the caller applies its own
     * @param _id Feed id
     * @return The stored price. Reverts if the feed has never been updated, like Pyth
     */
    function getPriceUnsafe(bytes32 _id) external view returns (PythStructs.Price memory) {
        PythStructs.Price memory price = _prices[_id];
        if (price.publishTime == 0) revert PriceFeedNotFound(_id);
        return price;
    }

    /**
     * @notice Encodes one update entry, for scripts and tests. The app encodes the same struct itself
     * @param _id Feed id
     * @param _price Price mantissa
     * @param _conf Confidence half-width, same exponent as the price
     * @param _expo Exponent shared by price and conf
     * @param _publishTime Unix timestamp of the price, at most the timestamp of the block it lands in
     * @return One update entry for updatePriceFeeds
     */
    function createPriceFeedUpdateData(bytes32 _id, int64 _price, uint64 _conf, int32 _expo, uint64 _publishTime) external pure returns (bytes memory) {
        PythStructs.PriceFeed memory feed;
        feed.id = _id;
        feed.price = PythStructs.Price({price: _price, conf: _conf, expo: _expo, publishTime: _publishTime});
        feed.emaPrice = feed.price;
        return abi.encode(feed);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Register the Chainlink aggregator a feed id must mirror; the deployer sets the same aggregator as the
     *         oracle's anchor for the pair
     * @param _id Feed id
     * @param _feed Chainlink aggregator
     */
    function setChainlinkFeed(bytes32 _id, address _feed) external onlyOwner {
        if (_feed == address(0)) revert ZeroAddress();
        chainlinkFeedOf[_id] = _feed;
        emit ChainlinkFeedSet(_id, _feed);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Revert unless the entry carries the registered aggregator's current answer, its exponent and the demo
     *      confidence. A non-positive answer can only match a non-positive price, which the oracle rejects.
     */
    function _requireChainlinkMirror(bytes32 _id, PythStructs.Price memory _price) internal view {
        address aggregator = chainlinkFeedOf[_id];
        if (aggregator == address(0)) revert FeedNotRegistered(_id);

        (, int256 answer,,,) = AggregatorV3Interface(aggregator).latestRoundData();
        if (int256(_price.price) != answer) revert PriceNotChainlinkAnswer(_id, _price.price, answer);

        // Safe cast: Chainlink aggregators report at most 18 decimals
        int32 expectedExpo = -int32(uint32(AggregatorV3Interface(aggregator).decimals()));
        if (_price.expo != expectedExpo) revert ExponentMismatch(_id, _price.expo, expectedExpo);

        // forge-lint: disable-next-line(unsafe-typecast) safe: cast only when the answer is positive
        uint256 expectedConf = answer > 0 ? (uint256(answer) * DEMO_CONF_BPS) / BPS_DENOMINATOR : 0;
        if (uint256(_price.conf) != expectedConf) revert ConfidenceMismatch(_id, _price.conf, expectedConf);
    }
}
