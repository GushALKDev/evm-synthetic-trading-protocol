// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {LocalChainlinkFeed} from "../LocalChainlinkFeed.sol";

/**
 * @title LocalChainlinkFeedTest
 * @notice The local-only aggregator the anvil rehearsal deploys: rounds, the stale switch, the seeded history
 * @dev Run with FOUNDRY_PROFILE=testnet.
 */
contract LocalChainlinkFeedTest is Test {
    LocalChainlinkFeed internal feed;

    function setUp() public {
        vm.warp(1_800_000_000);
        feed = new LocalChainlinkFeed(8);
    }

    function test_setAnswer_publishesANewRoundAtTheCurrentBlock() public {
        feed.setAnswer(100e8);
        vm.warp(block.timestamp + 60);
        feed.setAnswer(101e8);

        (uint80 id, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(id, 2, "second round");
        assertEq(answer, 101e8, "latest answer");
        assertEq(updatedAt, block.timestamp, "stamped now");
        (, int256 first,, uint256 firstAt,) = feed.getRoundData(1);
        assertEq(first, 100e8, "first answer kept");
        assertEq(firstAt, block.timestamp - 60, "first time kept");
    }

    function test_setUpdatedAt_movesOnlyTheLatestRound() public {
        feed.setAnswer(100e8);
        feed.setUpdatedAt(block.timestamp - 4_000);
        (,,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(updatedAt, block.timestamp - 4_000, "aged");
    }

    function test_getRoundData_revertsForARoundThatDoesNotExist() public {
        vm.expectRevert(abi.encodeWithSelector(LocalChainlinkFeed.NoDataPresent.selector, 0));
        feed.latestRoundData();
        feed.setAnswer(100e8);
        vm.expectRevert(abi.encodeWithSelector(LocalChainlinkFeed.NoDataPresent.selector, 0));
        feed.getRoundData(0);
        vm.expectRevert(abi.encodeWithSelector(LocalChainlinkFeed.NoDataPresent.selector, 2));
        feed.getRoundData(2);
    }

    /// @dev The rehearsal seeds 600 rounds, 1,200 s apart, in one transaction under anvil's 30M block gas limit
    function test_seedHistory_writesAnOrderedWalkThatEndsAtTheCurrentAnswer() public {
        uint256 gasStart = gasleft();
        feed.seedHistory(100_000e8, 600, 1_200, 25);
        uint256 used = gasStart - gasleft();
        emit log_named_uint("seedHistory gas, 600 rounds", used);
        assertLt(used, 30_000_000, "fits one anvil block");
        feed.setAnswer(100_000e8);

        uint256 previous;
        for (uint80 id = 1; id <= 600; ++id) {
            (,,, uint256 updatedAt,) = feed.getRoundData(id);
            assertGt(updatedAt, previous, "ascending times");
            previous = updatedAt;
        }
        (, int256 last,, uint256 lastAt,) = feed.getRoundData(600);
        assertEq(lastAt, block.timestamp - 1_200, "one interval before now");
        // The last seeded round is one step of at most 0.25% away from the current answer
        assertApproxEqRel(last, 100_000e8, 0.0025e18, "joins the current answer");
        (uint80 id_,,,,) = feed.latestRoundData();
        assertEq(id_, 601, "current round after the history");
    }

    function test_seedRounds_writesTheGivenRoundsInOrder() public {
        int256[] memory answers = new int256[](3);
        uint256[] memory times = new uint256[](3);
        (answers[0], answers[1], answers[2]) = (81_000e8, 81_500e8, 81_200e8);
        (times[0], times[1], times[2]) = (block.timestamp - 3_600, block.timestamp - 2_400, block.timestamp - 1_200);
        feed.seedRounds(answers, times);
        feed.setAnswer(81_300e8);

        for (uint80 id = 1; id <= 3; ++id) {
            (, int256 answer,, uint256 updatedAt,) = feed.getRoundData(id);
            assertEq(answer, answers[id - 1], "answer");
            assertEq(updatedAt, times[id - 1], "time");
        }
        (uint80 latest, int256 current,,,) = feed.latestRoundData();
        assertEq(latest, 4, "current round after the history");
        assertEq(current, 81_300e8, "current answer");
    }

    function test_seedRounds_rejectsTimesOutOfOrderOrNotInThePast() public {
        int256[] memory answers = new int256[](2);
        uint256[] memory times = new uint256[](2);
        (times[0], times[1]) = (block.timestamp - 60, block.timestamp - 60);
        vm.expectRevert(abi.encodeWithSelector(LocalChainlinkFeed.RoundTimeOutOfOrder.selector, 1, block.timestamp - 60));
        feed.seedRounds(answers, times);

        (times[0], times[1]) = (block.timestamp - 60, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(LocalChainlinkFeed.RoundTimeOutOfOrder.selector, 1, block.timestamp));
        feed.seedRounds(answers, times);

        vm.expectRevert(abi.encodeWithSelector(LocalChainlinkFeed.LengthMismatch.selector, 2, 1));
        feed.seedRounds(answers, new uint256[](1));

        feed.setAnswer(100e8);
        vm.expectRevert(abi.encodeWithSelector(LocalChainlinkFeed.HistoryAlreadySeeded.selector, 1));
        feed.seedRounds(new int256[](0), new uint256[](0));
    }

    function test_seedHistory_onlyOnAnEmptyFeed() public {
        feed.setAnswer(100e8);
        vm.expectRevert(abi.encodeWithSelector(LocalChainlinkFeed.HistoryAlreadySeeded.selector, 1));
        feed.seedHistory(100e8, 10, 60, 25);
    }
}
