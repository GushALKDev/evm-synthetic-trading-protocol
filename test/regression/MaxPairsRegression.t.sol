// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TradingStorage} from "../../src/TradingStorage.sol";
import {RegressionUSDC} from "./RegressionBase.sol";

/**
 * @title MaxPairsRegressionTest
 * @author GushALKDev
 * @notice Round 2b: the Vault's PnL snapshot loops over every pair, so the number of pairs is bounded at 20.
 *         Before, addPair accepted any number of pairs.
 * @dev Uses a selector literal so it compiles against the code before the bound.
 */
contract MaxPairsRegressionTest is Test {
    address owner = makeAddr("owner");

    function test_Regression_MaxPairs_AddPairAboveBoundReverts() public {
        TradingStorage tradingStorage = new TradingStorage(address(new RegressionUSDC()), owner);
        vm.startPrank(owner);
        for (uint256 i; i < 20; ++i) {
            tradingStorage.addPair("PAIR", 100, 1e24);
        }
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("TooManyPairs(uint256)")), uint256(20)));
        tradingStorage.addPair("PAIR", 100, 1e24);
        vm.stopPrank();
    }
}
