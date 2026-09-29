// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployLib, DeployConfig, Deployed} from "../../script/Deploy.s.sol";
import {PythChainlinkOracle} from "../../src/PythChainlinkOracle.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {MockChainlinkFeed} from "../mocks/MockChainlinkFeed.sol";
import {RegressionUSDC} from "./RegressionBase.sol";

/**
 * @title SequencerGraceScopeRegressionTest
 * @author GushALKDev
 * @notice Round 3: during the grace period after the L2 sequencer comes back up, only opening new positions is
 *         blocked. Closes, TP/SL execution, liquidations, snapshot refreshes, LP withdrawals and checkAndAct keep
 *         working. There is no way to add collateral, so a liquidation realises the same loss as a close, and
 *         blocking liquidations would let positions run past 100% loss at the Vault's expense.
 * @dev Mock mode on the wired DeployLib stack with the real PythChainlinkOracle on MockPyth; MockChainlinkFeed
 *      plays the BTC/USD feed and the sequencer uptime feed. Before the change every price read reverted with
 *      SequencerGracePeriodNotOver during the grace period.
 */
contract SequencerGraceScopeRegressionTest is Test {
    Deployed d;
    RegressionUSDC usdc;
    MockPyth mockPyth;
    MockChainlinkFeed priceFeed;
    MockChainlinkFeed sequencerFeed;

    address owner = makeAddr("owner");
    address lp = makeAddr("lp");
    address trader = makeAddr("trader");
    address keeper = makeAddr("keeper");

    bytes32 constant FEED_ID = bytes32(uint256(1));
    uint16 constant PAIR = 0;
    int64 constant PRICE = 50_000 * 1e8;
    uint128 constant PRICE18 = 50_000 * 1e18;

    uint32 closeId;
    uint32 liquidateId;
    uint32 limitId;
    uint256 upSince;

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new RegressionUSDC();
        mockPyth = new MockPyth(60, 0);
        priceFeed = new MockChainlinkFeed(8);
        sequencerFeed = new MockChainlinkFeed(0);
        sequencerFeed.setStartedAt(block.timestamp - 1 days);

        DeployConfig memory cfg = DeployConfig({
            asset: address(usdc),
            pyth: address(mockPyth),
            sequencerUptimeFeed: address(sequencerFeed),
            owner: owner,
            keeper: keeper,
            assistantFundTargetCap: 1_000_000 * 10 ** 6,
            bondDiscountBps: 500,
            baseSpreadBps: 5,
            impactFactor: 3e5,
            volFactor: 100,
            maxSpreadBps: 100,
            maxVolatilityChangeBps: 5000
        });
        vm.startPrank(owner);
        d = DeployLib.deploy(cfg);
        DeployLib.wire(d);
        d.tradingStorage.addPair("BTC/USD", 100, 100_000_000 * 1e18);
        d.oracle.setPairFeed(PAIR, FEED_ID, address(priceFeed), 3600);
        vm.stopPrank();

        usdc.mint(lp, 1_000_000 * 10 ** 6);
        vm.startPrank(lp);
        usdc.approve(address(d.vault), type(uint256).max);
        d.vault.deposit(1_000_000 * 10 ** 6, lp);
        d.vault.requestWithdrawal(d.vault.balanceOf(lp) / 10);
        vm.stopPrank();

        usdc.mint(trader, 100_000 * 10 ** 6);
        vm.prank(trader);
        usdc.approve(address(d.engine), type(uint256).max);

        // Three open positions at 50,000: one to close, a 100x long to liquidate, one with a TP to execute
        _setPrice(PRICE);
        vm.startPrank(trader);
        closeId = d.engine.openTrade(PAIR, true, 1_000 * 10 ** 6, 10, PRICE18, 100, 0, 0, _update(PRICE));
        liquidateId = d.engine.openTrade(PAIR, true, 1_000 * 10 ** 6, 100, PRICE18, 100, 0, 0, _update(PRICE));
        limitId = d.engine.openTrade(PAIR, false, 1_000 * 10 ** 6, 10, PRICE18 * 9995 / 10_000, 100, 49_000 * 1e18, 0, _update(PRICE));
        vm.stopPrank();

        // Three epochs later the sequencer goes down, comes back, and the price has fallen 2%
        vm.warp(block.timestamp + 3 days);
        sequencerFeed.setAnswer(0);
        upSince = block.timestamp - 60;
        sequencerFeed.setStartedAt(upSince);
        _setPrice(49_000 * 1e8);
    }

    function _update(int64 _price) internal view returns (bytes[] memory data) {
        data = new bytes[](1);
        data[0] = mockPyth.createPriceFeedUpdateData(FEED_ID, _price, 10 * 1e8, -8, _price, 10 * 1e8, uint64(block.timestamp), uint64(block.timestamp - 1));
    }

    function _setPrice(int64 _price) internal {
        priceFeed.setAnswer(_price);
        priceFeed.setUpdatedAt(block.timestamp);
        mockPyth.updatePriceFeeds(_update(_price));
    }

    function test_Regression_Grace_CloseTradeWorks() public {
        bytes[] memory data = _update(49_000 * 1e8);
        vm.prank(trader);
        d.engine.closeTrade(closeId, 49_000 * 1e18, 100, data);
        assertEq(d.tradingStorage.getTrade(closeId).user, address(0), "trade still open");
    }

    function test_Regression_Grace_LiquidateWorks() public {
        bytes[] memory data = _update(49_000 * 1e8);
        vm.prank(keeper);
        d.engine.liquidate(liquidateId, data);
        assertEq(d.tradingStorage.getTrade(liquidateId).user, address(0), "position not liquidated");
    }

    function test_Regression_Grace_ExecuteLimitWorks() public {
        bytes[] memory data = _update(49_000 * 1e8);
        vm.prank(keeper);
        d.engine.executeLimit(limitId, data);
        assertEq(d.tradingStorage.getTrade(limitId).user, address(0), "TP not executed");
    }

    function test_Regression_Grace_RefreshPnlSnapshotWorks() public {
        d.vault.refreshPnlSnapshot(_update(49_000 * 1e8));
        assertTrue(d.vault.isPnlSnapshotFresh(), "snapshot not refreshed");
    }

    function test_Regression_Grace_LpWithdrawalWorks() public {
        uint256 before = usdc.balanceOf(lp);
        bytes[] memory data = _update(49_000 * 1e8);
        vm.prank(lp);
        d.vault.refreshAndExecuteWithdrawal(data);
        assertGt(usdc.balanceOf(lp), before, "withdrawal not paid");
    }

    function test_Regression_Grace_RefreshAndCheckAndActWorks() public {
        d.solvencyManager.refreshAndCheckAndAct(_update(49_000 * 1e8));
        assertTrue(d.vault.isPnlSnapshotFresh(), "snapshot not refreshed");
    }

    /// @notice Opening stays blocked during the grace period, with the same named error as before
    function test_Grace_OpenTradeReverts() public {
        bytes[] memory data = _update(49_000 * 1e8);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(PythChainlinkOracle.SequencerGracePeriodNotOver.selector, upSince, block.timestamp));
        d.engine.openTrade(PAIR, true, 1_000 * 10 ** 6, 10, 49_000 * 1e18, 100, 0, 0, data);
    }

    /// @notice While the sequencer is down, every price read still reverts
    function test_Down_CloseAndLiquidateRevert() public {
        sequencerFeed.setAnswer(1);
        bytes[] memory data = _update(49_000 * 1e8);
        vm.prank(trader);
        vm.expectRevert(PythChainlinkOracle.SequencerDown.selector);
        d.engine.closeTrade(closeId, 49_000 * 1e18, 100, data);
        vm.prank(keeper);
        vm.expectRevert(PythChainlinkOracle.SequencerDown.selector);
        d.engine.liquidate(liquidateId, data);
    }
}
