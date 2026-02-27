// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {PythChainlinkOracle} from "../../src/PythChainlinkOracle.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {MockChainlinkFeed} from "../mocks/MockChainlinkFeed.sol";

contract PythChainlinkOracleTest is Test {
    PythChainlinkOracle oracle;
    MockPyth mockPyth;
    MockChainlinkFeed mockChainlink;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");

    bytes32 constant BTC_FEED_ID = bytes32(uint256(1));
    uint32 constant CHAINLINK_HEARTBEAT = 3600; // 1 hour
    uint256 constant PAIR_INDEX = 0;

    // BTC price: $50,000 with expo -8 (Pyth standard for crypto)
    int64 constant BTC_PRICE = 50_000 * 1e8;
    int32 constant BTC_EXPO = -8;
    uint64 constant BTC_CONF = 50 * 1e8; // $50 confidence (0.1%)

    // Chainlink BTC price: $50,000 with 8 decimals
    int256 constant CL_BTC_PRICE = 50_000 * 1e8;

    // Events
    event PairFeedSet(uint256 indexed pairIndex, bytes32 pythFeedId, address chainlinkFeed, uint32 heartbeat);

    function setUp() public {
        // Warp to a realistic timestamp so staleness tests don't underflow
        vm.warp(1_000_000);

        // validTimePeriod=60s, singleUpdateFee=1 wei
        mockPyth = new MockPyth(60, 1);
        mockChainlink = new MockChainlinkFeed(8);
        mockChainlink.setAnswer(CL_BTC_PRICE);

        vm.prank(owner);
        oracle = new PythChainlinkOracle(address(mockPyth), owner);

        vm.prank(owner);
        oracle.setPairFeed(PAIR_INDEX, BTC_FEED_ID, address(mockChainlink), CHAINLINK_HEARTBEAT);

        // Fund oracle with ETH for Pyth fees
        vm.deal(address(oracle), 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                          HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _createPriceUpdate(int64 price, uint64 conf, int32 expo) internal view returns (bytes[] memory) {
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = mockPyth.createPriceFeedUpdateData(
            BTC_FEED_ID, price, conf, expo, price, conf, uint64(block.timestamp), uint64(block.timestamp - 1)
        );
        return updateData;
    }

    function _createPriceUpdateWithTime(int64 price, uint64 conf, int32 expo, uint64 publishTime) internal view returns (bytes[] memory) {
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = mockPyth.createPriceFeedUpdateData(
            BTC_FEED_ID, price, conf, expo, price, conf, publishTime, publishTime > 0 ? publishTime - 1 : 0
        );
        return updateData;
    }

    function _getPrice(bytes[] memory updateData) internal returns (uint128) {
        return oracle.getPrice(PAIR_INDEX, updateData);
    }

    /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_SetsPyth() public view {
        assertEq(address(oracle.PYTH()), address(mockPyth));
    }

    function test_Constructor_SetsOwner() public view {
        assertEq(oracle.owner(), owner);
    }

    function test_Constructor_RevertOnZeroPyth() public {
        vm.expectRevert(PythChainlinkOracle.InvalidPairFeed.selector);
        new PythChainlinkOracle(address(0), owner);
    }

    /*//////////////////////////////////////////////////////////////
                        RECEIVE ETH TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Oracle_ReceiveEth() public {
        uint256 balBefore = address(oracle).balance;
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(oracle).call{value: 0.5 ether}("");
        assertTrue(ok);
        assertEq(address(oracle).balance, balBefore + 0.5 ether);
    }

    /*//////////////////////////////////////////////////////////////
                        SET PAIR FEED TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetPairFeed() public {
        bytes32 feedId = bytes32(uint256(99));
        MockChainlinkFeed newFeed = new MockChainlinkFeed(8);

        vm.prank(owner);
        oracle.setPairFeed(5, feedId, address(newFeed), 7200);

        PythChainlinkOracle.PairFeed memory pf = oracle.getPairFeed(5);
        assertEq(pf.pythFeedId, feedId);
        assertEq(pf.chainlinkFeed, address(newFeed));
        assertEq(pf.chainlinkHeartbeat, 7200);
        assertTrue(pf.active);
    }

    function test_SetPairFeed_EmitsEvent() public {
        bytes32 feedId = bytes32(uint256(99));
        MockChainlinkFeed newFeed = new MockChainlinkFeed(8);

        vm.expectEmit(true, false, false, true);
        emit PairFeedSet(5, feedId, address(newFeed), 7200);

        vm.prank(owner);
        oracle.setPairFeed(5, feedId, address(newFeed), 7200);
    }

    function test_SetPairFeed_RevertOnZeroFeedId() public {
        vm.prank(owner);
        vm.expectRevert(PythChainlinkOracle.InvalidPairFeed.selector);
        oracle.setPairFeed(0, bytes32(0), address(mockChainlink), CHAINLINK_HEARTBEAT);
    }

    function test_SetPairFeed_RevertOnZeroChainlinkFeed() public {
        vm.prank(owner);
        vm.expectRevert(PythChainlinkOracle.InvalidPairFeed.selector);
        oracle.setPairFeed(0, BTC_FEED_ID, address(0), CHAINLINK_HEARTBEAT);
    }

    function test_SetPairFeed_RevertOnZeroHeartbeat() public {
        vm.prank(owner);
        vm.expectRevert(PythChainlinkOracle.InvalidPairFeed.selector);
        oracle.setPairFeed(0, BTC_FEED_ID, address(mockChainlink), 0);
    }

    function test_SetPairFeed_RevertOnNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        oracle.setPairFeed(0, BTC_FEED_ID, address(mockChainlink), CHAINLINK_HEARTBEAT);
    }

    /*//////////////////////////////////////////////////////////////
                        FEED NOT SET TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetPrice_RevertOnFeedNotSet() public {
        bytes[] memory updateData = _createPriceUpdate(BTC_PRICE, BTC_CONF, BTC_EXPO);

        vm.expectRevert(abi.encodeWithSelector(PythChainlinkOracle.PairFeedNotSet.selector, 999));
        oracle.getPrice(999, updateData);
    }

    /*//////////////////////////////////////////////////////////////
                        HAPPY PATH TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetPrice_ReturnsNormalized18Dec() public {
        bytes[] memory updateData = _createPriceUpdate(BTC_PRICE, BTC_CONF, BTC_EXPO);

        uint128 price = _getPrice(updateData);

        // BTC_PRICE=50000e8 with expo=-8 → 50000e18
        assertEq(price, 50_000 * 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                        STALENESS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetPrice_RevertOnStalePythPrice() public {
        // Publish time 31 seconds ago (> MAX_STALENESS of 30)
        uint64 staleTime = uint64(block.timestamp) - 31;
        bytes[] memory updateData = _createPriceUpdateWithTime(BTC_PRICE, BTC_CONF, BTC_EXPO, staleTime);

        vm.expectRevert(abi.encodeWithSelector(PythChainlinkOracle.StalePrice.selector, BTC_FEED_ID, staleTime, block.timestamp));
        oracle.getPrice(PAIR_INDEX, updateData);
    }

    function test_GetPrice_FreshPricePasses() public {
        // Publish time exactly now
        bytes[] memory updateData = _createPriceUpdate(BTC_PRICE, BTC_CONF, BTC_EXPO);

        uint128 price = _getPrice(updateData);
        assertGt(price, 0);
    }

    function test_GetPrice_EdgeStaleness30Seconds() public {
        // Publish time exactly 30 seconds ago (= MAX_STALENESS, should pass)
        uint64 edgeTime = uint64(block.timestamp) - 30;
        bytes[] memory updateData = _createPriceUpdateWithTime(BTC_PRICE, BTC_CONF, BTC_EXPO, edgeTime);

        uint128 price = _getPrice(updateData);
        assertGt(price, 0);
    }

    function test_GetPrice_RevertOnStaleChainlink() public {
        // Set Chainlink updatedAt to be older than heartbeat
        mockChainlink.setUpdatedAt(block.timestamp - CHAINLINK_HEARTBEAT - 1);

        bytes[] memory updateData = _createPriceUpdate(BTC_PRICE, BTC_CONF, BTC_EXPO);

        vm.expectRevert(
            abi.encodeWithSelector(
                PythChainlinkOracle.ChainlinkStalePrice.selector,
                address(mockChainlink),
                block.timestamp - CHAINLINK_HEARTBEAT - 1,
                block.timestamp
            )
        );
        oracle.getPrice(PAIR_INDEX, updateData);
    }

    /*//////////////////////////////////////////////////////////////
                        CONFIDENCE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetPrice_RevertOnWideConfidence() public {
        // Confidence = 3% of price (> MAX_CONFIDENCE_BPS of 2%)
        uint64 wideConf = uint64(uint256(uint64(BTC_PRICE)) * 3 / 100);
        bytes[] memory updateData = _createPriceUpdate(BTC_PRICE, wideConf, BTC_EXPO);

        vm.expectRevert(abi.encodeWithSelector(PythChainlinkOracle.ConfidenceTooWide.selector, wideConf, BTC_PRICE));
        oracle.getPrice(PAIR_INDEX, updateData);
    }

    function test_GetPrice_NarrowConfidencePasses() public {
        // Confidence = 0.5% of price (< MAX_CONFIDENCE_BPS of 2%)
        uint64 narrowConf = uint64(uint256(uint64(BTC_PRICE)) * 5 / 1000);
        bytes[] memory updateData = _createPriceUpdate(BTC_PRICE, narrowConf, BTC_EXPO);

        uint128 price = _getPrice(updateData);
        assertGt(price, 0);
    }

    function test_GetPrice_EdgeConfidence2Percent() public {
        // Confidence = exactly 2% of price (= MAX_CONFIDENCE_BPS, should pass)
        uint64 edgeConf = uint64(uint256(uint64(BTC_PRICE)) * 2 / 100);
        bytes[] memory updateData = _createPriceUpdate(BTC_PRICE, edgeConf, BTC_EXPO);

        uint128 price = _getPrice(updateData);
        assertGt(price, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        DEVIATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetPrice_RevertOnExcessiveDeviation() public {
        // Set Chainlink 5% higher than Pyth (> MAX_DEVIATION_BPS of 3%)
        mockChainlink.setAnswer(int256(CL_BTC_PRICE * 105 / 100));

        bytes[] memory updateData = _createPriceUpdate(BTC_PRICE, BTC_CONF, BTC_EXPO);

        vm.expectRevert(); // PriceDeviationTooHigh
        oracle.getPrice(PAIR_INDEX, updateData);
    }

    function test_GetPrice_WithinBoundsDeviation() public {
        // Set Chainlink 2% higher (< MAX_DEVIATION_BPS of 3%)
        mockChainlink.setAnswer(int256(CL_BTC_PRICE * 102 / 100));

        bytes[] memory updateData = _createPriceUpdate(BTC_PRICE, BTC_CONF, BTC_EXPO);

        uint128 price = _getPrice(updateData);
        assertGt(price, 0);
    }

    function test_GetPrice_SymmetricDeviation() public {
        // Chainlink 2% lower than Pyth
        mockChainlink.setAnswer(int256(CL_BTC_PRICE * 98 / 100));

        bytes[] memory updateData = _createPriceUpdate(BTC_PRICE, BTC_CONF, BTC_EXPO);

        uint128 price = _getPrice(updateData);
        assertGt(price, 0);
    }

    function test_GetPrice_EdgeDeviation3Percent() public {
        // Exactly 3% deviation (= MAX_DEVIATION_BPS, should pass)
        mockChainlink.setAnswer(int256(CL_BTC_PRICE * 103 / 100));

        bytes[] memory updateData = _createPriceUpdate(BTC_PRICE, BTC_CONF, BTC_EXPO);

        uint128 price = _getPrice(updateData);
        assertGt(price, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        ZERO PRICE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetPrice_RevertOnZeroPythPrice() public {
        bytes[] memory updateData = _createPriceUpdate(0, 0, BTC_EXPO);

        vm.expectRevert(); // ZeroPrice or PythUtils revert
        oracle.getPrice(PAIR_INDEX, updateData);
    }

    function test_GetPrice_RevertOnZeroChainlinkPrice() public {
        mockChainlink.setAnswer(0);

        bytes[] memory updateData = _createPriceUpdate(BTC_PRICE, BTC_CONF, BTC_EXPO);

        vm.expectRevert(PythChainlinkOracle.ZeroPrice.selector);
        oracle.getPrice(PAIR_INDEX, updateData);
    }

    function test_GetPrice_RevertOnNegativePythPrice() public {
        bytes[] memory updateData = _createPriceUpdate(-1, 0, BTC_EXPO);

        vm.expectRevert(); // ZeroPrice (price <= 0)
        oracle.getPrice(PAIR_INDEX, updateData);
    }

    function test_GetPrice_RevertOnNegativeChainlinkPrice() public {
        mockChainlink.setAnswer(-1);

        bytes[] memory updateData = _createPriceUpdate(BTC_PRICE, BTC_CONF, BTC_EXPO);

        vm.expectRevert(PythChainlinkOracle.ZeroPrice.selector);
        oracle.getPrice(PAIR_INDEX, updateData);
    }

    /*//////////////////////////////////////////////////////////////
                    NORMALIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetPrice_CryptoExpoMinus8() public {
        // Standard crypto: price=50000e8, expo=-8 → 50000e18
        bytes[] memory updateData = _createPriceUpdate(BTC_PRICE, BTC_CONF, BTC_EXPO);

        uint128 price = _getPrice(updateData);
        assertEq(price, 50_000 * 1e18);
    }

    function test_GetPrice_ForexExpoMinus5() public {
        // Forex-like: price=130500 (1.305 with expo=-5), expo=-5 → 1.305e18
        int64 forexPrice = 130_500;
        int32 forexExpo = -5;
        uint64 forexConf = 100; // small confidence

        // Chainlink at 1.305 with 8 decimals
        mockChainlink.setAnswer(int256(130_500_000));

        vm.prank(owner);
        oracle.setPairFeed(1, bytes32(uint256(2)), address(mockChainlink), CHAINLINK_HEARTBEAT);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = mockPyth.createPriceFeedUpdateData(
            bytes32(uint256(2)), forexPrice, forexConf, forexExpo, forexPrice, forexConf, uint64(block.timestamp), uint64(block.timestamp - 1)
        );

        uint128 price = oracle.getPrice(1, updateData);
        // 130500 * 10^(18-5) = 130500 * 1e13 = 1.305e18
        assertEq(price, 1_305_000_000_000_000_000);
    }

    /*//////////////////////////////////////////////////////////////
                    INSUFFICIENT ETH TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetPrice_RevertOnInsufficientEthForFee() public {
        // Deploy a fresh oracle with no ETH
        vm.prank(owner);
        PythChainlinkOracle emptyOracle = new PythChainlinkOracle(address(mockPyth), owner);

        vm.prank(owner);
        emptyOracle.setPairFeed(PAIR_INDEX, BTC_FEED_ID, address(mockChainlink), CHAINLINK_HEARTBEAT);

        bytes[] memory updateData = _createPriceUpdate(BTC_PRICE, BTC_CONF, BTC_EXPO);

        vm.expectRevert(abi.encodeWithSelector(PythChainlinkOracle.InsufficientEthForFee.selector, 0, 1));
        emptyOracle.getPrice(PAIR_INDEX, updateData);
    }

    /*//////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_PriceNormalization(int64 rawPrice, int32 expo) public {
        // Bound to realistic ranges
        rawPrice = int64(bound(rawPrice, 1_000, type(int64).max));
        expo = int32(bound(expo, -12, -4));

        // Compute expected 18-decimal value
        uint256 pyth18 = uint256(uint64(rawPrice)) * 10 ** uint256(uint32(18 + expo));

        // Skip if price too large for uint128 or zero
        vm.assume(pyth18 <= type(uint128).max);
        vm.assume(pyth18 > 0);

        // Chainlink 8-decimal value matching the same price
        uint256 cl8 = pyth18 / 1e10;
        // Skip if too small for 8 decimals or too large for int256
        vm.assume(cl8 > 0);
        vm.assume(cl8 <= uint256(type(uint128).max));

        // Verify round-trip deviation is within bounds (truncation can cause >3% for tiny prices)
        uint256 clReconstructed = cl8 * 1e10;
        uint256 diff = pyth18 > clReconstructed ? pyth18 - clReconstructed : clReconstructed - pyth18;
        vm.assume(diff * 10_000 <= clReconstructed * 300);

        mockChainlink.setAnswer(int256(cl8));

        // Low confidence to pass check
        uint64 conf = uint64(uint256(uint64(rawPrice)) / 1000);
        if (conf == 0) conf = 1;

        bytes[] memory updateData = _createPriceUpdate(rawPrice, conf, expo);

        uint128 price = oracle.getPrice(PAIR_INDEX, updateData);
        assertEq(uint256(price), pyth18);
    }

    receive() external payable {}
}
