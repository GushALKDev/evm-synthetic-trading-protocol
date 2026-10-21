// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

import {DemoPyth} from "../DemoPyth.sol";
import {MockChainlinkFeed} from "../../../test/mocks/MockChainlinkFeed.sol";

/**
 * @title DemoPythTest
 * @notice The testnet Pyth stand-in: fee, the Chainlink mirror check, last-write-wins storage, the future
 *         publishTime guard and the owner-only feed registry
 * @dev Run with FOUNDRY_PROFILE=testnet. Kept out of test/ so the protocol suite figures stay unchanged.
 */
contract DemoPythTest is Test {
    bytes32 internal constant ID = bytes32(uint256(1));
    address internal constant OWNER = address(0xA11CE);
    address internal constant STRANGER = address(0xBAD);
    int256 internal constant ANSWER = 2_000e8;
    uint64 internal constant CONF = 1e8; // 2_000e8 * 5 / 10_000

    DemoPyth internal pyth;
    MockChainlinkFeed internal feed;

    function setUp() public {
        vm.warp(1_800_000_000);
        feed = new MockChainlinkFeed(8);
        feed.setAnswer(ANSWER);
        pyth = new DemoPyth(1 wei, OWNER);
        vm.prank(OWNER);
        pyth.setChainlinkFeed(ID, address(feed));
    }

    function _update(int64 _price, uint64 _conf, int32 _expo, uint64 _publishTime) internal view returns (bytes[] memory update) {
        update = new bytes[](1);
        update[0] = pyth.createPriceFeedUpdateData(ID, _price, _conf, _expo, _publishTime);
    }

    function _mirrored(uint64 _publishTime) internal view returns (bytes[] memory) {
        return _update(int64(ANSWER), CONF, -8, _publishTime);
    }

    function test_getUpdateFee_oneFeePerEntryAndAnEmptyUpdateIsFree() public view {
        assertEq(pyth.getUpdateFee(_mirrored(uint64(block.timestamp))), 1 wei, "one wei per entry");
        assertEq(pyth.getUpdateFee(new bytes[](0)), 0, "the Vault's later pairs pass an empty update");
    }

    function test_update_storesTheMirroredPrice() public {
        pyth.updatePriceFeeds{value: 1 wei}(_mirrored(uint64(block.timestamp)));

        PythStructs.Price memory p = pyth.getPriceUnsafe(ID);
        assertEq(p.price, ANSWER, "price");
        assertEq(p.conf, CONF, "conf");
        assertEq(p.expo, -8, "expo");
        assertEq(p.publishTime, block.timestamp, "publishTime");
    }

    function test_update_revertsBelowTheFee() public {
        bytes[] memory update = _mirrored(uint64(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(DemoPyth.InsufficientFee.selector, 0, 1));
        pyth.updatePriceFeeds{value: 0}(update);
    }

    /// @dev The check that keeps a stranger from choosing a price inside the oracle's 3% band
    function test_update_rejectsAPriceOneUnitOffTheChainlinkAnswer() public {
        bytes[] memory update = _update(int64(ANSWER) + 1, CONF, -8, uint64(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(DemoPyth.PriceNotChainlinkAnswer.selector, ID, int64(ANSWER) + 1, ANSWER));
        pyth.updatePriceFeeds{value: 1 wei}(update);
    }

    /// @dev The documented "sign again" case: Chainlink publishes between the read and the landing
    function test_update_rejectsAnUpdateBuiltBeforeChainlinkMoved() public {
        bytes[] memory update = _mirrored(uint64(block.timestamp));
        feed.setAnswer(2_001e8);
        vm.expectRevert(abi.encodeWithSelector(DemoPyth.PriceNotChainlinkAnswer.selector, ID, int64(ANSWER), int256(2_001e8)));
        pyth.updatePriceFeeds{value: 1 wei}(update);
    }

    function test_update_rejectsAnotherExponent() public {
        bytes[] memory update = _update(int64(ANSWER), CONF, -6, uint64(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(DemoPyth.ExponentMismatch.selector, ID, int32(-6), int32(-8)));
        pyth.updatePriceFeeds{value: 1 wei}(update);
    }

    /// @dev A wider band would move the liquidation price and the Vault's snapshot in the caller's favour
    function test_update_rejectsAnotherConfidence() public {
        bytes[] memory update = _update(int64(ANSWER), CONF + 1, -8, uint64(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(DemoPyth.ConfidenceMismatch.selector, ID, CONF + 1, uint256(CONF)));
        pyth.updatePriceFeeds{value: 1 wei}(update);
    }

    function test_update_rejectsAnUnregisteredFeedId() public {
        bytes[] memory update = new bytes[](1);
        update[0] = pyth.createPriceFeedUpdateData(bytes32(uint256(2)), int64(ANSWER), CONF, -8, uint64(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(DemoPyth.FeedNotRegistered.selector, bytes32(uint256(2))));
        pyth.updatePriceFeeds{value: 1 wei}(update);
    }

    /// @dev Regression guard for the griefing case: with newer-wins, a price stamped one block ahead of the app's
    ///      would always be the one read. The last write must win, whatever its publishTime.
    function test_update_lastWriteWinsWhateverItsPublishTime() public {
        pyth.updatePriceFeeds{value: 1 wei}(_mirrored(uint64(block.timestamp)));
        pyth.updatePriceFeeds{value: 1 wei}(_mirrored(uint64(block.timestamp - 1)));

        assertEq(pyth.getPriceUnsafe(ID).publishTime, block.timestamp - 1, "the older write replaced the newer one");
    }

    /// @dev A future publishTime would let a stored price pass the oracle's age check for as long as nobody overwrites it
    function test_update_rejectsAFuturePublishTime() public {
        uint64 future = uint64(block.timestamp + 1);
        bytes[] memory update = _mirrored(future);
        vm.expectRevert(abi.encodeWithSelector(DemoPyth.FuturePublishTime.selector, ID, future, block.timestamp));
        pyth.updatePriceFeeds{value: 1 wei}(update);
    }

    /// @dev Regression: a call that brings no update read the previous answer for up to the oracle's price age after
    ///      Chainlink published, which let anyone open at the old price and close at the new one
    function test_getPriceUnsafe_revertsOnceChainlinkHasMoved() public {
        pyth.updatePriceFeeds{value: 1 wei}(_mirrored(uint64(block.timestamp)));
        feed.setAnswer(2_001e8);
        vm.expectRevert(abi.encodeWithSelector(DemoPyth.PriceNotChainlinkAnswer.selector, ID, int64(ANSWER), int256(2_001e8)));
        pyth.getPriceUnsafe(ID);
    }

    function test_getPriceUnsafe_revertsForAFeedNeverUpdated() public {
        vm.expectRevert(abi.encodeWithSelector(DemoPyth.PriceFeedNotFound.selector, ID));
        pyth.getPriceUnsafe(ID);
    }

    function test_setChainlinkFeed_ownerOnly() public {
        vm.prank(STRANGER);
        vm.expectRevert(Ownable.Unauthorized.selector);
        pyth.setChainlinkFeed(ID, address(0xDEAD));
        assertEq(pyth.chainlinkFeedOf(ID), address(feed), "registry unchanged");
    }

    function test_setChainlinkFeed_rejectsTheZeroAddress() public {
        vm.prank(OWNER);
        vm.expectRevert(DemoPyth.ZeroAddress.selector);
        pyth.setChainlinkFeed(ID, address(0));
    }
}
