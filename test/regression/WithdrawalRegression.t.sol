// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../../src/Vault.sol";
import {RegressionUSDC} from "./RegressionBase.sol";

/**
 * @title WithdrawalRegressionTest
 * @author GushALKDev
 * @notice Round 1 Medium finding: a withdrawal request never expired and its shares were not escrowed, so
 *         after one 3-epoch wait an LP kept a standing option to exit at any later time, and could still
 *         move the requested shares. The ERC-4626 max* functions also did not match what the vault accepts.
 * @dev Uses only functions that existed before the fix; new errors are matched by selector literal.
 */
contract WithdrawalRegressionTest is Test {
    Vault vault;
    RegressionUSDC usdc;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant DEPOSIT = 1_000 * 10 ** 6;
    bytes4 constant WITHDRAWAL_EXPIRED = bytes4(keccak256("WithdrawalExpired(uint256)"));

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new RegressionUSDC();
        vault = new Vault(address(usdc), owner);
        usdc.mint(alice, DEPOSIT);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(DEPOSIT, alice);
        vm.stopPrank();
    }

    function _warpEpochs(uint256 _epochs) internal {
        vm.warp(block.timestamp + _epochs * vault.EPOCH_LENGTH());
    }

    /// @notice A request unlocked 3 epochs after it was made can no longer be executed after the window
    function test_Regression_Withdrawal_RequestExpiresAfterWindow() public {
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestWithdrawal(shares);

        _warpEpochs(4); // unlock at +3, one-epoch window, so +4 is past it
        vm.prank(alice);
        vm.expectPartialRevert(WITHDRAWAL_EXPIRED);
        vault.executeWithdrawal();
    }

    /// @notice Requested shares leave the LP's balance and cannot be transferred while the request is pending
    function test_Regression_Withdrawal_RequestedSharesAreEscrowed() public {
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestWithdrawal(shares);

        assertEq(vault.balanceOf(address(vault)), shares, "shares not escrowed in the vault");
        assertEq(vault.balanceOf(alice), 0, "requested shares still in the LP balance");

        vm.prank(alice);
        vm.expectRevert();
        vault.transfer(bob, shares);
    }

    /// @notice Cancelling, including after expiry, returns the escrowed shares
    function test_Withdrawal_CancelAfterExpiryReturnsShares() public {
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestWithdrawal(shares);
        _warpEpochs(10);

        vm.prank(alice);
        vault.cancelWithdrawal();
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.balanceOf(address(vault)), 0);
    }

    /// @notice withdraw and redeem always revert, so their max* functions report 0
    function test_Regression_MaxWithdrawAndMaxRedeemAreZero() public {
        assertEq(vault.maxWithdraw(alice), 0, "maxWithdraw not 0");
        assertEq(vault.maxRedeem(alice), 0, "maxRedeem not 0");
    }

    /// @notice While paused, deposit and mint revert, so maxDeposit and maxMint report 0
    function test_Regression_MaxDepositAndMaxMintZeroWhenPaused() public {
        vm.prank(owner);
        vault.pause();
        assertEq(vault.maxDeposit(alice), 0, "maxDeposit not 0 while paused");
        assertEq(vault.maxMint(alice), 0, "maxMint not 0 while paused");
    }
}
