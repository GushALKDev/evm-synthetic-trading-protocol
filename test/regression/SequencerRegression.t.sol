// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {PythChainlinkOracle} from "../../src/PythChainlinkOracle.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {MockChainlinkFeed} from "../mocks/MockChainlinkFeed.sol";

/**
 * @title SequencerRegressionTest
 * @author GushALKDev
 * @notice Round 1 finding: the oracle had no L2 sequencer uptime check. Prices are now refused while the
 *         Chainlink sequencer uptime feed reports the sequencer down, and opening new positions is refused for one
 *         hour after it comes back (round 3 narrowed the grace period to openings, see
 *         SequencerGraceScopeRegression.t.sol).
 * @dev Mock mode: MockChainlinkFeed plays the uptime feed (answer 0 = up, 1 = down, startedAt = last change).
 *      The fork suite runs the same checks against the Arbitrum One feed.
 */
contract SequencerRegressionTest is Test {
    PythChainlinkOracle oracle;
    MockPyth mockPyth;
    MockChainlinkFeed priceFeed;
    MockChainlinkFeed sequencerFeed;

    address owner = makeAddr("owner");
    bytes32 constant FEED_ID = bytes32(uint256(1));
    int64 constant PRICE = 50_000 * 1e8;

    function setUp() public {
        vm.warp(1_000_000);
        mockPyth = new MockPyth(60, 0);
        priceFeed = new MockChainlinkFeed(8);
        priceFeed.setAnswer(PRICE);
        sequencerFeed = new MockChainlinkFeed(0);
        sequencerFeed.setAnswer(0);
        sequencerFeed.setStartedAt(block.timestamp - 1 days);

        vm.startPrank(owner);
        oracle = new PythChainlinkOracle(address(mockPyth), address(sequencerFeed), owner);
        oracle.setPairFeed(0, FEED_ID, address(priceFeed), 3600);
        vm.stopPrank();
    }

    function _update() internal view returns (bytes[] memory data) {
        data = new bytes[](1);
        data[0] = mockPyth.createPriceFeedUpdateData(FEED_ID, PRICE, 10 * 1e8, -8, PRICE, 10 * 1e8, uint64(block.timestamp), uint64(block.timestamp - 1));
    }

    function test_Sequencer_UpPastGracePeriod_PriceAccepted() public {
        (uint128 price,) = oracle.getPrice(0, _update());
        assertEq(price, 50_000 * 1e18);
    }

    function test_Regression_Sequencer_DownReverts() public {
        sequencerFeed.setAnswer(1);
        bytes[] memory data = _update();
        vm.expectRevert(PythChainlinkOracle.SequencerDown.selector);
        oracle.getPrice(0, data);
    }

    /// @notice During the grace period opening is refused; prices for other actions are served
    function test_Regression_Sequencer_GracePeriodBlocksOpening() public {
        uint256 upSince = block.timestamp - 3600; // exactly the grace period: still refused
        sequencerFeed.setStartedAt(upSince);
        vm.expectRevert(abi.encodeWithSelector(PythChainlinkOracle.SequencerGracePeriodNotOver.selector, upSince, block.timestamp));
        oracle.checkOpenAllowed();
        (uint128 price,) = oracle.getPrice(0, _update());
        assertGt(price, 0, "price refused during the grace period");

        vm.warp(block.timestamp + 1);
        oracle.checkOpenAllowed();
    }

    function test_Sequencer_DownBlocksOpening() public {
        sequencerFeed.setAnswer(1);
        vm.expectRevert(PythChainlinkOracle.SequencerDown.selector);
        oracle.checkOpenAllowed();
    }

    function test_Regression_Sequencer_UninitializedFeedTreatedAsDown() public {
        sequencerFeed.setStartedAt(0);
        bytes[] memory data = _update();
        vm.expectRevert(PythChainlinkOracle.SequencerDown.selector);
        oracle.getPrice(0, data);
    }

    function test_Sequencer_ZeroAddressDisablesCheck() public {
        vm.prank(owner);
        PythChainlinkOracle noSequencer = new PythChainlinkOracle(address(mockPyth), address(0), owner);
        vm.prank(owner);
        noSequencer.setPairFeed(0, FEED_ID, address(priceFeed), 3600);
        sequencerFeed.setAnswer(1); // ignored: noSequencer has no feed

        assertEq(address(noSequencer.SEQUENCER_UPTIME_FEED()), address(0));
        (uint128 price,) = noSequencer.getPrice(0, _update());
        assertGt(price, 0);
        noSequencer.checkOpenAllowed();
    }
}
