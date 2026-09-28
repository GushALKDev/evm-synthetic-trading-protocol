// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RegressionBase} from "./RegressionBase.sol";
import {TradingEngine} from "../../src/TradingEngine.sol";
import {TradingStorage} from "../../src/TradingStorage.sol";

/**
 * @title LeverageRegressionTest
 * @author GushALKDev
 * @notice Round 1 finding: leverage had no global cap in code; the owner could add pairs with any
 *         maxLeverage up to 65,535. MAX_LEVERAGE = 100 is now enforced on pair configuration and on open.
 */
contract LeverageRegressionTest is RegressionBase {
    address alice = makeAddr("alice");

    /// @dev Storage slot of TradingStorage._pairs (see `forge inspect TradingStorage storage-layout`)
    uint256 constant PAIRS_SLOT = 9;

    function test_Regression_Leverage_AddPairAboveGlobalCapReverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(TradingStorage.MaxLeverageTooHigh.selector, uint16(101), uint16(100)));
        tradingStorage.addPair("ETH/USD", 101, 1_000_000 * 1e18);
    }

    function test_Regression_Leverage_UpdatePairAboveGlobalCapReverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(TradingStorage.MaxLeverageTooHigh.selector, uint16(500), uint16(100)));
        tradingStorage.updatePair(PAIR, 500, 1_000_000 * 1e18, true);
    }

    /// @notice The engine enforces the cap on open even if a pair limit above it reached storage
    function test_Regression_Leverage_OpenAboveGlobalCapReverts() public {
        _setPairMaxLeverage(PAIR, 200);
        assertEq(tradingStorage.getPair(PAIR).maxLeverage, 200);

        _fund(alice, 100 * 10 ** 6);
        uint128 price = mockOracle.peekPrice(PAIR);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TradingEngine.LeverageExceedsMax.selector, uint16(150), uint16(100)));
        engine.openTrade(PAIR, true, 100 * 10 ** 6, 150, price, 100, 0, 0, EMPTY_UPDATE);
    }

    /// @dev Pair struct slot 1 packs maxOI (16 bytes), maxLeverage (2 bytes) and isActive (1 byte)
    function _setPairMaxLeverage(uint256 _pairIndex, uint16 _maxLeverage) internal {
        bytes32 slot = bytes32(uint256(keccak256(abi.encode(PAIRS_SLOT))) + _pairIndex * 2 + 1);
        uint256 word = uint256(vm.load(address(tradingStorage), slot));
        word = (word & ~(uint256(0xffff) << 128)) | (uint256(_maxLeverage) << 128);
        vm.store(address(tradingStorage), slot, bytes32(word));
    }
}
