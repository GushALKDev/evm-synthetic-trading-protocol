// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployLib, DeployConfig, Deployed} from "../../script/Deploy.s.sol";
import {PythChainlinkOracle} from "../../src/PythChainlinkOracle.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {MockChainlinkFeed} from "../mocks/MockChainlinkFeed.sol";
import {RegressionUSDC} from "../regression/RegressionBase.sol";

/**
 * @title VaultRefreshFeeTest
 * @author GushALKDev
 * @notice ETH accounting of the PnL snapshot refresh with a nonzero Pyth update fee and several pairs (Slither
 *         msg-value-loop on Vault._refreshPnlSnapshot): the fee for one update blob is paid once, by the caller,
 *         and everything else is refunded.
 * @dev Real PythChainlinkOracle on MockPyth with FEE wei per update; one blob carries every feed. The first pair
 *      with open interest receives msg.value and pays FEE times the number of feeds; later pairs read stored
 *      prices with empty update data, which costs 0.
 */
contract VaultRefreshFeeTest is Test {
    Deployed d;
    RegressionUSDC usdc;
    MockPyth mockPyth;
    MockChainlinkFeed priceFeed;

    address owner = makeAddr("owner");
    address lp = makeAddr("lp");
    address trader = makeAddr("trader");
    address caller = makeAddr("caller");

    uint256 constant FEE = 0.001 ether;
    uint256 constant PAIRS = 4;
    int64 constant PRICE = 50_000 * 1e8;
    uint128 constant PRICE18 = 50_000 * 1e18;

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new RegressionUSDC();
        mockPyth = new MockPyth(60, FEE);
        priceFeed = new MockChainlinkFeed(8);
        priceFeed.setAnswer(PRICE);

        DeployConfig memory cfg = DeployConfig({
            asset: address(usdc),
            pyth: address(mockPyth),
            sequencerUptimeFeed: address(0),
            owner: owner,
            keeper: owner,
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
        for (uint256 i; i < PAIRS; ++i) {
            d.tradingStorage.addPair("PAIR", 100, 100_000_000 * 1e18);
            d.oracle.setPairFeed(i, bytes32(i + 1), address(priceFeed), 3600);
        }
        vm.stopPrank();

        usdc.mint(lp, 1_000_000 * 10 ** 6);
        vm.startPrank(lp);
        usdc.approve(address(d.vault), type(uint256).max);
        d.vault.deposit(1_000_000 * 10 ** 6, lp);
        vm.stopPrank();
        usdc.mint(trader, 100_000 * 10 ** 6);
        vm.prank(trader);
        usdc.approve(address(d.engine), type(uint256).max);
        vm.deal(caller, 1 ether);
    }

    /// @dev One update blob with a fresh price for every feed
    function _blob() internal view returns (bytes[] memory data) {
        data = new bytes[](PAIRS);
        for (uint256 i; i < PAIRS; ++i) {
            data[i] =
                mockPyth.createPriceFeedUpdateData(bytes32(i + 1), PRICE, 10 * 1e8, -8, PRICE, 10 * 1e8, uint64(block.timestamp), uint64(block.timestamp - 1));
        }
    }

    /// @dev Open a long and a short on every pair from _firstPair on, at stored prices (empty update data, no fee)
    function _openPositions(uint256 _firstPair) internal {
        mockPyth.updatePriceFeeds{value: FEE * PAIRS}(_blob());
        bytes[] memory none;
        vm.startPrank(trader);
        for (uint256 i = _firstPair; i < PAIRS; ++i) {
            d.engine.openTrade(uint16(i), true, 1_000 * 10 ** 6, 10, PRICE18 * 10_005 / 10_000, 100, 0, 0, none);
            d.engine.openTrade(uint16(i), false, 1_000 * 10 ** 6, 10, PRICE18 * 9_995 / 10_000, 100, 0, 0, none);
        }
        vm.stopPrank();
        vm.warp(block.timestamp + 1);
        priceFeed.setUpdatedAt(block.timestamp);
    }

    struct Balances {
        uint256 caller;
        uint256 pyth;
        uint256 oracle;
        uint256 vault;
        uint256 manager;
    }

    function _balances() internal view returns (Balances memory b) {
        b = Balances(caller.balance, address(mockPyth).balance, address(d.oracle).balance, address(d.vault).balance, address(d.solvencyManager).balance);
    }

    function _assertFeePaidOnce(Balances memory _before, uint256 _feeds) internal view {
        Balances memory a = _balances();
        assertEq(_before.caller - a.caller, FEE * _feeds, "caller paid more than one blob");
        assertEq(a.pyth - _before.pyth, FEE * _feeds, "Pyth fee not paid once");
        assertEq(a.oracle, _before.oracle, "ETH left in the oracle");
        assertEq(a.vault, _before.vault, "ETH left in the Vault");
        assertEq(a.manager, _before.manager, "ETH left in the SolvencyManager");
    }

    /// @notice Four pairs with open interest: the caller sends 1 ether and pays exactly one four-feed blob
    function test_Refresh_FeePaidOnceAcrossPairs() public {
        _openPositions(0);
        bytes[] memory data = _blob();
        Balances memory before = _balances();
        vm.prank(caller);
        d.vault.refreshPnlSnapshot{value: 1 ether}(data);
        _assertFeePaidOnce(before, PAIRS);
        assertTrue(d.vault.isPnlSnapshotFresh());
    }

    /// @notice Pair 0 has no open interest: msg.value goes to the first priced pair and is still used once
    function test_Refresh_FirstPairWithoutOpenInterest() public {
        _openPositions(1);
        bytes[] memory data = _blob();
        Balances memory before = _balances();
        vm.prank(caller);
        d.vault.refreshPnlSnapshot{value: 1 ether}(data);
        _assertFeePaidOnce(before, PAIRS);
    }

    /// @notice Sending exactly the fee works and leaves nothing to refund
    function test_Refresh_ExactFee() public {
        _openPositions(0);
        bytes[] memory data = _blob();
        Balances memory before = _balances();
        vm.prank(caller);
        d.vault.refreshPnlSnapshot{value: FEE * PAIRS}(data);
        _assertFeePaidOnce(before, PAIRS);
    }

    /// @notice Less than the fee reverts in the oracle
    function test_Refresh_InsufficientFeeReverts() public {
        _openPositions(0);
        bytes[] memory data = _blob();
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(PythChainlinkOracle.InsufficientFee.selector, FEE * PAIRS - 1, FEE * PAIRS));
        d.vault.refreshPnlSnapshot{value: FEE * PAIRS - 1}(data);
    }

    /// @notice The same accounting through refreshAndDeposit
    function test_RefreshAndDeposit_FeePaidOnce() public {
        _openPositions(0);
        bytes[] memory data = _blob();
        usdc.mint(caller, 1_000 * 10 ** 6);
        vm.prank(caller);
        usdc.approve(address(d.vault), type(uint256).max);
        Balances memory before = _balances();
        vm.prank(caller);
        d.vault.refreshAndDeposit{value: 1 ether}(1_000 * 10 ** 6, caller, data);
        _assertFeePaidOnce(before, PAIRS);
    }

    /// @notice The same accounting through SolvencyManager.refreshAndCheckAndAct, which forwards the Vault's refund
    function test_RefreshAndCheckAndAct_FeePaidOnce() public {
        _openPositions(0);
        bytes[] memory data = _blob();
        Balances memory before = _balances();
        vm.prank(caller);
        d.solvencyManager.refreshAndCheckAndAct{value: 1 ether}(data);
        _assertFeePaidOnce(before, PAIRS);
    }
}
