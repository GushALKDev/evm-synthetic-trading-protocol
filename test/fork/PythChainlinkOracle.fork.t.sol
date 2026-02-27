// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {PythChainlinkOracle} from "../../src/PythChainlinkOracle.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

/**
 * @title PythChainlinkOracleForkTest
 * @notice Fork tests against live HyperEVM — validates PythChainlinkOracle with real Pyth + Chainlink feeds
 * @dev Fetches Pyth price updates from Hermes API via ffi (hex-encoded, parsed with vm.parseBytes).
 *      Skipped when FORK_RPC_URL env is not set.
 *      Run: forge test --match-contract PythChainlinkOracleFork -vvv
 */
contract PythChainlinkOracleForkTest is Test {
    PythChainlinkOracle oracle;

    // HyperEVM deployed contracts
    address constant PYTH = 0xe9d69CdD6Fe41e7B621B4A688C5D1a68cB5c8ADc;
    address constant CHAINLINK_UBTC_USD = 0xd7752D8831a209F5177de52b3b32b5098A7B56b8;
    address constant CHAINLINK_UETH_USD = 0x54EdE484Bb0E589F5eE13e04c84f46eb787c9C6a;

    // Pyth feed IDs (universal across all chains)
    bytes32 constant PYTH_BTC_USD = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    bytes32 constant PYTH_ETH_USD = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

    uint256 constant PAIR_BTC = 0;
    uint256 constant PAIR_ETH = 1;
    uint32 constant CHAINLINK_HEARTBEAT = 86_400; // 24h — Chainlink on HyperEVM has wide heartbeat

    address owner = makeAddr("owner");
    string forkUrl;

    modifier skipIfNoFork() {
        forkUrl = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(forkUrl).length == 0) {
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        forkUrl = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(forkUrl).length == 0) return;

        vm.createSelectFork(forkUrl);

        vm.prank(owner);
        oracle = new PythChainlinkOracle(PYTH, owner);

        vm.startPrank(owner);
        oracle.setPairFeed(PAIR_BTC, PYTH_BTC_USD, CHAINLINK_UBTC_USD, CHAINLINK_HEARTBEAT);
        oracle.setPairFeed(PAIR_ETH, PYTH_ETH_USD, CHAINLINK_UETH_USD, CHAINLINK_HEARTBEAT);
        vm.stopPrank();

        // Fund oracle with ETH for Pyth fees
        vm.deal(address(oracle), 10 ether);
    }

    /*//////////////////////////////////////////////////////////////
                          HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Fetch fresh Pyth price update from Hermes API via ffi.
     *      Output starts with "0x" so vm.ffi auto-decodes hex → raw bytes.
     *      Warps block.timestamp forward so the fresh update passes staleness checks.
     */
    function _fetchHermesPriceUpdate(bytes32 feedId) internal returns (bytes[] memory) {
        string memory feedIdHex = vm.toString(feedId);

        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "-c";
        // "0x" prefix makes vm.ffi interpret stdout as hex-encoded bytes
        cmd[2] = string.concat(
            "curl -s 'https://hermes.pyth.network/v2/updates/price/latest?ids[]=",
            feedIdHex,
            "&encoding=hex' | python3 -c \"import sys, json; d=json.load(sys.stdin); print('0x' + d['binary']['data'][0], end='')\""
        );

        bytes memory updateData = vm.ffi(cmd);

        // Hermes returns a price with publishTime ≈ now, but fork block.timestamp may lag
        // Warp to current real time so staleness check passes
        vm.warp(block.timestamp + 5);

        bytes[] memory priceUpdate = new bytes[](1);
        priceUpdate[0] = updateData;
        return priceUpdate;
    }

    /*//////////////////////////////////////////////////////////////
                    LIVE PYTH PRICE FEED TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Fork_GetPrice_BTC() public skipIfNoFork {
        bytes[] memory priceUpdate = _fetchHermesPriceUpdate(PYTH_BTC_USD);

        uint128 price = oracle.getPrice(PAIR_BTC, priceUpdate);

        // BTC should be between $10k and $500k (18 decimals)
        assertGt(price, 10_000 * 1e18, "BTC price too low");
        assertLt(price, 500_000 * 1e18, "BTC price too high");

        console2.log("BTC/USD price (18 dec):", price);
        console2.log("BTC/USD price (USD):", price / 1e18);
    }

    function test_Fork_GetPrice_ETH() public skipIfNoFork {
        bytes[] memory priceUpdate = _fetchHermesPriceUpdate(PYTH_ETH_USD);

        uint128 price = oracle.getPrice(PAIR_ETH, priceUpdate);

        // ETH should be between $500 and $50k (18 decimals)
        assertGt(price, 500 * 1e18, "ETH price too low");
        assertLt(price, 50_000 * 1e18, "ETH price too high");

        console2.log("ETH/USD price (18 dec):", price);
        console2.log("ETH/USD price (USD):", price / 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                PYTH-CHAINLINK DEVIATION VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_Fork_PythChainlinkDeviation_BTC() public skipIfNoFork {
        bytes[] memory priceUpdate = _fetchHermesPriceUpdate(PYTH_BTC_USD);

        // If deviation exceeds 3%, this call reverts with PriceDeviationTooHigh
        uint128 price = oracle.getPrice(PAIR_BTC, priceUpdate);

        // Also read Chainlink directly for logging
        (, int256 clAnswer,,,) = AggregatorV3Interface(CHAINLINK_UBTC_USD).latestRoundData();
        uint256 chainlink18 = uint256(clAnswer) * 1e10; // 8 dec → 18 dec

        uint256 diff = price > uint128(chainlink18) ? price - uint128(chainlink18) : uint128(chainlink18) - price;
        uint256 deviationBps = diff * 10_000 / chainlink18;

        console2.log("BTC Pyth (18 dec):", price);
        console2.log("BTC Chainlink (18 dec):", chainlink18);
        console2.log("Deviation (bps):", deviationBps);

        assertLe(deviationBps, 300, "BTC deviation exceeds 3%");
    }

    function test_Fork_PythChainlinkDeviation_ETH() public skipIfNoFork {
        bytes[] memory priceUpdate = _fetchHermesPriceUpdate(PYTH_ETH_USD);

        uint128 price = oracle.getPrice(PAIR_ETH, priceUpdate);

        (, int256 clAnswer,,,) = AggregatorV3Interface(CHAINLINK_UETH_USD).latestRoundData();
        uint256 chainlink18 = uint256(clAnswer) * 1e10;

        uint256 diff = price > uint128(chainlink18) ? price - uint128(chainlink18) : uint128(chainlink18) - price;
        uint256 deviationBps = diff * 10_000 / chainlink18;

        console2.log("ETH Pyth (18 dec):", price);
        console2.log("ETH Chainlink (18 dec):", chainlink18);
        console2.log("Deviation (bps):", deviationBps);

        assertLe(deviationBps, 300, "ETH deviation exceeds 3%");
    }

    /*//////////////////////////////////////////////////////////////
                    PRICE NORMALIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Fork_PriceNormalization_18Decimals() public skipIfNoFork {
        bytes[] memory priceUpdate = _fetchHermesPriceUpdate(PYTH_BTC_USD);

        uint128 price = oracle.getPrice(PAIR_BTC, priceUpdate);

        // BTC at ~$90k = 90000e18 = 9e22 — much larger than 1e18
        assertGt(price, 1e18, "Price not normalized to 18 decimals");
    }

    function test_Fork_ChainlinkDecimals_Are8() public skipIfNoFork {
        uint8 btcDec = AggregatorV3Interface(CHAINLINK_UBTC_USD).decimals();
        uint8 ethDec = AggregatorV3Interface(CHAINLINK_UETH_USD).decimals();

        assertEq(btcDec, 8, "Chainlink UBTC/USD should have 8 decimals");
        assertEq(ethDec, 8, "Chainlink UETH/USD should have 8 decimals");
    }

    function test_Fork_PythExponent_IsMinus8() public skipIfNoFork {
        PythStructs.Price memory btcPrice = IPyth(PYTH).getPriceUnsafe(PYTH_BTC_USD);
        PythStructs.Price memory ethPrice = IPyth(PYTH).getPriceUnsafe(PYTH_ETH_USD);

        assertEq(btcPrice.expo, -8, "BTC Pyth expo should be -8");
        assertEq(ethPrice.expo, -8, "ETH Pyth expo should be -8");
    }

    /*//////////////////////////////////////////////////////////////
                    INSUFFICIENT ETH TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Fork_RevertOnInsufficientEthForFee() public skipIfNoFork {
        // Deploy a fresh oracle with no ETH
        vm.prank(owner);
        PythChainlinkOracle emptyOracle = new PythChainlinkOracle(PYTH, owner);

        vm.prank(owner);
        emptyOracle.setPairFeed(PAIR_BTC, PYTH_BTC_USD, CHAINLINK_UBTC_USD, CHAINLINK_HEARTBEAT);

        bytes[] memory priceUpdate = _fetchHermesPriceUpdate(PYTH_BTC_USD);

        vm.expectRevert();
        emptyOracle.getPrice(PAIR_BTC, priceUpdate);
    }

    /*//////////////////////////////////////////////////////////////
                        FEED CONFIGURATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Fork_RevertOnUnconfiguredPair() public skipIfNoFork {
        bytes[] memory priceUpdate = _fetchHermesPriceUpdate(PYTH_BTC_USD);

        vm.expectRevert(abi.encodeWithSelector(PythChainlinkOracle.PairFeedNotSet.selector, 999));
        oracle.getPrice(999, priceUpdate);
    }

    function test_Fork_PairFeedConfig_BTC() public skipIfNoFork {
        PythChainlinkOracle.PairFeed memory feed = oracle.getPairFeed(PAIR_BTC);

        assertEq(feed.pythFeedId, PYTH_BTC_USD);
        assertEq(feed.chainlinkFeed, CHAINLINK_UBTC_USD);
        assertEq(feed.chainlinkHeartbeat, CHAINLINK_HEARTBEAT);
        assertTrue(feed.active);
    }

    function test_Fork_PairFeedConfig_ETH() public skipIfNoFork {
        PythChainlinkOracle.PairFeed memory feed = oracle.getPairFeed(PAIR_ETH);

        assertEq(feed.pythFeedId, PYTH_ETH_USD);
        assertEq(feed.chainlinkFeed, CHAINLINK_UETH_USD);
        assertEq(feed.chainlinkHeartbeat, CHAINLINK_HEARTBEAT);
        assertTrue(feed.active);
    }

    /*//////////////////////////////////////////////////////////////
                    CONFIDENCE INTERVAL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Fork_ConfidenceWithinBounds() public skipIfNoFork {
        PythStructs.Price memory btcPrice = IPyth(PYTH).getPriceUnsafe(PYTH_BTC_USD);

        // Confidence should be < 2% of price (MAX_CONFIDENCE_BPS = 200)
        uint256 confBps = uint256(btcPrice.conf) * 10_000 / uint256(uint64(btcPrice.price));

        console2.log("BTC confidence (bps):", confBps);
        console2.log("BTC confidence ($):", btcPrice.conf);
        console2.log("BTC price:", uint64(btcPrice.price));

        assertLt(confBps, 200, "BTC confidence exceeds 2%");
    }

    /*//////////////////////////////////////////////////////////////
                    CONSECUTIVE CALLS TEST
    //////////////////////////////////////////////////////////////*/

    function test_Fork_ConsecutivePriceFetches() public skipIfNoFork {
        bytes[] memory btcUpdate = _fetchHermesPriceUpdate(PYTH_BTC_USD);
        uint128 btcPrice = oracle.getPrice(PAIR_BTC, btcUpdate);

        bytes[] memory ethUpdate = _fetchHermesPriceUpdate(PYTH_ETH_USD);
        uint128 ethPrice = oracle.getPrice(PAIR_ETH, ethUpdate);

        // BTC should always be more expensive than ETH
        assertGt(btcPrice, ethPrice, "BTC should be more expensive than ETH");

        // BTC/ETH ratio should be roughly 10-100x
        uint256 ratio = uint256(btcPrice) / uint256(ethPrice);
        assertGt(ratio, 5, "BTC/ETH ratio too low");
        assertLt(ratio, 200, "BTC/ETH ratio too high");

        console2.log("BTC/ETH ratio:", ratio);
    }

    /*//////////////////////////////////////////////////////////////
                    STALENESS DETECTION TEST
    //////////////////////////////////////////////////////////////*/

    function test_Fork_StalenessDetected_AfterWarp() public skipIfNoFork {
        // Fetch fresh update and validate it works
        bytes[] memory priceUpdate = _fetchHermesPriceUpdate(PYTH_BTC_USD);
        oracle.getPrice(PAIR_BTC, priceUpdate);

        // Warp 60s forward — exceeds MAX_STALENESS (30s)
        vm.warp(block.timestamp + 60);

        // Same update data is now stale — calling getPrice should revert
        // Note: updatePriceFeeds succeeds (Pyth accepts old data) but staleness check fails
        vm.expectRevert();
        oracle.getPrice(PAIR_BTC, priceUpdate);
    }

    receive() external payable {}
}
