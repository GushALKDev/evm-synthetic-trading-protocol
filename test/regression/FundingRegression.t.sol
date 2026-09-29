// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RegressionBase} from "./RegressionBase.sol";

/**
 * @title FundingRegressionTest
 * @author GushALKDev
 * @notice Round 1 funding PoCs (High finding). Before the fix the rate scaled with the absolute USD
 *         imbalance and credits were paid by the Vault, so a small position on the light side could
 *         collect far more than the heavy side paid.
 * @dev Both scenarios run at a flat oracle price, so any gain can only come from funding.
 */
contract FundingRegressionTest is RegressionBase {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address attacker = makeAddr("attacker");

    function setUp() public override {
        super.setUp();
        _fund(alice, 1_000 * 10 ** 6);
        _fund(bob, 10_000 * 10 ** 6);
        _fund(attacker, 10_000 * 10 ** 6);
    }

    /**
     * @notice PoC 1: a 10 USDC x100 short next to a 1,000 USDC x100 long, closed 60 s later at the same price
     * @dev Pre-fix the short was paid 57.82 USDC for a 10 USDC deposit. After the fix the credit is bounded
     *      by what the long pays, which in 60 s is far below the round-trip spread and fees.
     */
    function test_Regression_Funding_SmallShortCannotProfitAtFlatPrice() public {
        _open(bob, true, 1_000 * 10 ** 6, 100);
        uint32 shortId = _open(alice, false, 10 * 10 ** 6, 100);

        vm.warp(block.timestamp + 60);

        uint256 aliceBefore = usdc.balanceOf(alice);
        _close(alice, shortId);
        uint256 payout = usdc.balanceOf(alice) - aliceBefore;

        emit log_named_decimal_uint("short payout (USDC) for a 10 USDC deposit", payout, 6);
        assertLt(payout, 10 * 10 ** 6, "short profited from funding alone at a flat price");
    }

    /**
     * @notice PoC 2: one 1,000 USDC x100 long plus 50 shorts of 10 USDC x100, all owned by one account
     * @dev Pre-fix the shorts collected more from the Vault than the bankrupt long paid in, draining
     *      2,294.14 USDC in 160 s. The same positions are replayed with no elapsed time as the baseline:
     *      funding must not lower the Vault result or raise the attacker result against that baseline.
     */
    function test_Regression_Funding_CannotDrainVaultWithOffsettingPositions() public {
        uint256 snapshot = vm.snapshotState();
        (int256 vaultNoTime, int256 attackerNoTime) = _runOffsettingPositions(0);
        vm.revertToState(snapshot);
        (int256 vaultAfter160s, int256 attackerAfter160s) = _runOffsettingPositions(160);

        emit log_named_decimal_int("vault delta, no elapsed time (USDC)", vaultNoTime, 6);
        emit log_named_decimal_int("vault delta, 160 s (USDC)", vaultAfter160s, 6);
        emit log_named_decimal_int("attacker delta, no elapsed time (USDC)", attackerNoTime, 6);
        emit log_named_decimal_int("attacker delta, 160 s (USDC)", attackerAfter160s, 6);

        assertGe(vaultAfter160s, vaultNoTime, "funding lowered the vault balance");
        assertLe(attackerAfter160s, attackerNoTime, "attacker profited from funding");
        assertLt(attackerAfter160s, 0, "attacker profited at a flat price");
    }

    function _runOffsettingPositions(uint256 _elapsed) internal returns (int256 vaultDelta, int256 attackerDelta) {
        uint256 vaultBefore = usdc.balanceOf(address(vault));
        uint256 attackerBefore = usdc.balanceOf(attacker);

        uint32 longId = _open(attacker, true, 1_000 * 10 ** 6, 100);
        uint32[] memory shortIds = new uint32[](50);
        for (uint256 i; i < 50; ++i) {
            shortIds[i] = _open(attacker, false, 10 * 10 ** 6, 100);
        }

        vm.warp(block.timestamp + _elapsed);

        for (uint256 i; i < 50; ++i) {
            _close(attacker, shortIds[i]);
        }
        _close(attacker, longId);

        vaultDelta = int256(usdc.balanceOf(address(vault))) - int256(vaultBefore);
        attackerDelta = int256(usdc.balanceOf(attacker)) - int256(attackerBefore);
    }
}
