// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TradingEngine} from "../../src/TradingEngine.sol";
import {TradingStorage} from "../../src/TradingStorage.sol";
import {Vault} from "../../src/Vault.sol";
import {PythChainlinkOracle} from "../../src/PythChainlinkOracle.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {MockChainlinkFeed} from "../mocks/MockChainlinkFeed.sol";
import {MockSpreadManager} from "../mocks/MockSpreadManager.sol";
import {RegressionUSDC} from "./RegressionBase.sol";

/**
 * @title OracleLatencyRegressionTest
 * @author GushALKDev
 * @notice Round 1 Medium finding: trades executed on any Pyth update up to 30 s old, so a trader could open
 *         on a 25 s old price after seeing the current one and close at the current price.
 * @dev TradingEngine wired to the real PythChainlinkOracle on MockPyth, so the oracle checks run in full.
 */
contract OracleLatencyRegressionTest is Test {
    TradingEngine engine;
    TradingStorage tradingStorage;
    Vault vault;
    PythChainlinkOracle oracle;
    MockPyth mockPyth;
    MockChainlinkFeed mockChainlink;
    RegressionUSDC usdc;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");

    bytes32 constant FEED_ID = bytes32(uint256(1));
    uint16 constant PAIR = 0;
    int64 constant PRICE_THEN = 50_000 * 1e8;
    int64 constant PRICE_NOW = 51_000 * 1e8;
    uint64 constant CONF = 10 * 1e8;

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new RegressionUSDC();
        mockPyth = new MockPyth(60, 1);
        mockChainlink = new MockChainlinkFeed(8);
        mockChainlink.setAnswer(PRICE_NOW);

        vm.startPrank(owner);
        oracle = new PythChainlinkOracle(address(mockPyth), address(0), owner);
        oracle.setPairFeed(PAIR, FEED_ID, address(mockChainlink), 3600);
        tradingStorage = new TradingStorage(address(usdc), owner);
        vault = new Vault(address(usdc), owner);
        engine = new TradingEngine(
            address(tradingStorage), address(vault), address(oracle), address(usdc), makeAddr("treasury"), address(new MockSpreadManager(5)), owner
        );
        tradingStorage.setTradingEngine(address(engine));
        vault.setTradingEngine(address(engine));
        tradingStorage.addPair("BTC/USD", 100, 10_000_000 * 1e18);
        vm.stopPrank();

        usdc.mint(address(this), 1_000_000 * 10 ** 6);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1_000_000 * 10 ** 6, address(this));

        usdc.mint(alice, 1_000 * 10 ** 6);
        vm.prank(alice);
        usdc.approve(address(engine), type(uint256).max);
        vm.deal(alice, 1 ether);
    }

    function _update(int64 _price, uint64 _publishTime) internal view returns (bytes[] memory data) {
        data = new bytes[](1);
        data[0] = mockPyth.createPriceFeedUpdateData(FEED_ID, _price, CONF, -8, _price, CONF, _publishTime, _publishTime - 1);
    }

    /**
     * @notice Round 1 scenario: at time t the trader submits an update published at t - 25 s to open, planning
     *         to close at t on the current price. The open must now be rejected.
     */
    function test_Regression_OracleLatency_OpenOnUpdateAged25sReverts() public {
        uint64 staleTime = uint64(block.timestamp - 25);
        bytes[] memory stale = _update(PRICE_THEN, staleTime);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PythChainlinkOracle.StalePrice.selector, FEED_ID, uint256(staleTime), block.timestamp));
        engine.openTrade{value: 1}(PAIR, true, 100 * 10 ** 6, 100, 50_025 * 1e18, 100, 0, 0, stale);
    }

    /// @notice An update aged exactly the default maximum (5 s) is still accepted, 6 s is not
    function test_Regression_OracleLatency_DefaultMaxPriceAgeBoundary() public {
        bytes[] memory fiveSeconds = _update(PRICE_NOW, uint64(block.timestamp - 5));
        vm.prank(alice);
        engine.openTrade{value: 1}(PAIR, true, 100 * 10 ** 6, 10, 51_025 * 1e18, 100, 0, 0, fiveSeconds);

        vm.warp(block.timestamp + 1);
        bytes[] memory sixSeconds = _update(PRICE_NOW, uint64(block.timestamp - 6));
        vm.prank(alice);
        vm.expectPartialRevert(PythChainlinkOracle.StalePrice.selector);
        engine.openTrade{value: 1}(PAIR, true, 100 * 10 ** 6, 10, 51_025 * 1e18, 100, 0, 0, sixSeconds);
    }

    /// @notice A publishTime after block.timestamp reverts with a named error instead of an arithmetic underflow
    function test_Regression_OracleLatency_FuturePublishTimeRevertsWithNamedError() public {
        uint64 future = uint64(block.timestamp + 2);
        bytes[] memory data = _update(PRICE_NOW, future);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PythChainlinkOracle.PriceFromFuture.selector, FEED_ID, uint256(future), block.timestamp));
        engine.openTrade{value: 1}(PAIR, true, 100 * 10 ** 6, 10, 51_025 * 1e18, 100, 0, 0, data);
    }
}
