// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TradingStorage} from "../../src/TradingStorage.sol";
import {RegressionUSDC} from "./RegressionBase.sol";

/**
 * @title DeleteTradeRegressionTest
 * @author GushALKDev
 * @notice Round 1 Low finding: deleteTrade searched the user's trade array linearly, so closing the most
 *         recent of N open trades cost O(N) storage reads. Removal is now swap-and-pop with a stored index.
 * @dev Calls TradingStorage directly as the engine; uses only functions that existed before the fix.
 */
contract DeleteTradeRegressionTest is Test {
    TradingStorage tradingStorage;
    address owner = makeAddr("owner");
    address engine = makeAddr("engine");
    address alice = makeAddr("alice");

    uint256 constant MANY = 500;

    function setUp() public {
        tradingStorage = new TradingStorage(address(new RegressionUSDC()), owner);
        vm.startPrank(owner);
        tradingStorage.setTradingEngine(engine);
        tradingStorage.addPair("BTC/USD", 100, type(uint128).max);
        vm.stopPrank();
    }

    function _store(uint256 _count) internal returns (uint32 lastId) {
        vm.startPrank(engine);
        for (uint256 i; i < _count; ++i) {
            lastId = tradingStorage.storeTrade(alice, true, 0, 10, 100 * 10 ** 6, 50_000 * 1e18, 0, 0);
        }
        vm.stopPrank();
    }

    function _gasToDelete(uint256 _tradeId) internal returns (uint256 gasUsed) {
        vm.prank(engine);
        uint256 before = gasleft();
        tradingStorage.deleteTrade(_tradeId);
        gasUsed = before - gasleft();
    }

    /// @notice Deleting the newest of 500 open trades costs the same as deleting the newest of 2
    function test_Regression_DeleteTrade_CostIndependentOfOpenTrades() public {
        uint256 snapshot = vm.snapshotState();
        uint32 lastOfTwo = _store(2);
        uint256 gasWithTwo = _gasToDelete(lastOfTwo);
        vm.revertToState(snapshot);

        uint32 lastOfMany = _store(MANY);
        uint256 gasWithMany = _gasToDelete(lastOfMany);

        emit log_named_uint("gas to delete the newest of 2 trades", gasWithTwo);
        emit log_named_uint("gas to delete the newest of 500 trades", gasWithMany);
        assertLe(gasWithMany, gasWithTwo + 2_000, "deletion cost grows with the number of open trades");
    }

    /// @notice After deleting trades in an arbitrary order the user's list holds exactly the open trades
    function testFuzz_DeleteTrade_UserListStaysConsistent(uint256 _seed) public {
        _store(40);
        bool[40] memory deleted;
        for (uint256 k; k < 25; ++k) {
            uint256 id = uint256(keccak256(abi.encode(_seed, k))) % 40;
            if (deleted[id]) continue;
            vm.prank(engine);
            tradingStorage.deleteTrade(id);
            deleted[id] = true;
        }

        uint256[] memory list = tradingStorage.getUserTrades(alice);
        uint256 open;
        for (uint256 id; id < 40; ++id) {
            if (!deleted[id]) ++open;
        }
        assertEq(list.length, open, "list length");
        for (uint256 i; i < list.length; ++i) {
            assertFalse(deleted[list[i]], "deleted trade still listed");
            assertEq(tradingStorage.getTrade(list[i]).user, alice, "listed trade not open");
            for (uint256 j; j < i; ++j) {
                assertTrue(list[i] != list[j], "trade listed twice");
            }
        }
    }
}
