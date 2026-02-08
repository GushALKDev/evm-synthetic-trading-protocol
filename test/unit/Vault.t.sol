// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../../src/Vault.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

contract MockUSDC is ERC20 {
    function name() public pure override returns (string memory) {
        return "USDC";
    }

    function symbol() public pure override returns (string memory) {
        return "USDC";
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract VaultTest is Test {
    using SafeTransferLib for address;

    Vault vault;
    MockUSDC usdc;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address tradingEngine = makeAddr("tradingEngine");

    event WithdrawalRequested(address indexed owner, uint256 shares, uint256 requestEpoch, uint256 unlockEpoch);
    event WithdrawalExecuted(address indexed owner, uint256 shares, uint256 assets);
    event WithdrawalCancelled(address indexed owner);
    event PayoutSent(address indexed receiver, uint256 amount);
    event TradingEngineUpdated(address indexed newEngine);
    event Paused(address account);
    event Unpaused(address account);

    function setUp() public {
        vm.warp(1 days);

        usdc = new MockUSDC();

        vm.prank(owner);
        vault = new Vault(address(usdc), owner);

        vm.prank(owner);
        vault.setTradingEngine(tradingEngine);

        usdc.mint(alice, 10_000 * 10 ** 6);
        usdc.mint(bob, 10_000 * 10 ** 6);
    }

    /*//////////////////////////////////////////////////////////////
                            BASIC DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Deposit() public {
        vm.startPrank(alice);

        uint256 amount = 1000 * 10 ** 6;
        usdc.approve(address(vault), amount);

        uint256 shares = vault.deposit(amount, alice);

        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 9000 * 10 ** 6);
        assertEq(usdc.balanceOf(address(vault)), 1000 * 10 ** 6);
        assertEq(shares, 1000 * 1e18);
        assertEq(vault.balanceOf(alice), 1000 * 1e18);
    }

    function test_Deposit_ToAnotherReceiver() public {
        vm.startPrank(alice);

        uint256 amount = 1000 * 10 ** 6;
        usdc.approve(address(vault), amount);

        uint256 shares = vault.deposit(amount, bob);

        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), shares);
    }

    function test_Mint() public {
        vm.startPrank(alice);

        uint256 sharesToMint = 1000 * 1e18;
        usdc.approve(address(vault), type(uint256).max);

        uint256 assets = vault.mint(sharesToMint, alice);

        vm.stopPrank();

        assertEq(vault.balanceOf(alice), sharesToMint);
        assertEq(assets, 1000 * 10 ** 6);
        assertEq(usdc.balanceOf(address(vault)), 1000 * 10 ** 6);
    }

    function test_MultipleDeposits_ShareAccounting() public {
        // Alice deposits 1000 USDC
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000 * 10 ** 6);
        vault.deposit(1000 * 10 ** 6, alice);
        vm.stopPrank();

        // Bob deposits 2000 USDC
        vm.startPrank(bob);
        usdc.approve(address(vault), 2000 * 10 ** 6);
        vault.deposit(2000 * 10 ** 6, bob);
        vm.stopPrank();

        // Verify shares proportional to deposits
        assertEq(vault.balanceOf(alice), 1000 * 1e18);
        assertEq(vault.balanceOf(bob), 2000 * 1e18);
        assertEq(vault.totalSupply(), 3000 * 1e18);
        assertEq(vault.totalAssets(), 3000 * 10 ** 6);
    }

    /*//////////////////////////////////////////////////////////////
                        WITHDRAWAL LOCK TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RequestWithdrawal() public {
        vm.startPrank(alice);

        uint256 amount = 1000 * 10 ** 6;
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);

        uint256 shares = vault.balanceOf(alice);
        vault.requestWithdrawal(shares);

        vm.stopPrank();

        (uint256 reqShares, uint256 reqEpoch) = vault.withdrawalRequests(alice);

        assertEq(reqShares, shares);
        assertEq(reqEpoch, 0);
    }

    function test_RequestWithdrawal_EmitsEvent() public {
        vm.startPrank(alice);

        uint256 amount = 1000 * 10 ** 6;
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);

        uint256 shares = vault.balanceOf(alice);

        vm.expectEmit(true, false, false, true);
        emit WithdrawalRequested(alice, shares, 0, 3);

        vault.requestWithdrawal(shares);

        vm.stopPrank();
    }

    function test_RequestWithdrawal_RevertIfInsufficientShares() public {
        vm.startPrank(alice);

        uint256 amount = 1000 * 10 ** 6;
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);

        uint256 tooManyShares = vault.balanceOf(alice) + 1;

        vm.expectRevert();
        vault.requestWithdrawal(tooManyShares);

        vm.stopPrank();
    }

    function test_RequestWithdrawal_OverwritesPreviousRequest() public {
        vm.startPrank(alice);

        usdc.approve(address(vault), 2000 * 10 ** 6);
        vault.deposit(2000 * 10 ** 6, alice);

        // First request for 1000 shares
        vault.requestWithdrawal(1000 * 1e18);

        (uint256 reqShares1, ) = vault.withdrawalRequests(alice);
        assertEq(reqShares1, 1000 * 1e18);

        // Second request for 500 shares overwrites
        vault.requestWithdrawal(500 * 1e18);

        (uint256 reqShares2, ) = vault.withdrawalRequests(alice);
        assertEq(reqShares2, 500 * 1e18);

        vm.stopPrank();
    }

    function test_CannotWithdrawBeforeTime() public {
        vm.startPrank(alice);

        uint256 amount = 1000 * 10 ** 6;
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vault.requestWithdrawal(vault.balanceOf(alice));

        vm.expectRevert(abi.encodeWithSelector(Vault.WithdrawalLocked.selector, 3));
        vault.executeWithdrawal();

        vm.stopPrank();
    }

    function test_CanWithdrawAfterTime() public {
        vm.startPrank(alice);

        uint256 amount = 1000 * 10 ** 6;
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vault.requestWithdrawal(vault.balanceOf(alice));

        vm.stopPrank();

        vm.warp(1 days + 3 days);

        vm.prank(alice);
        vault.executeWithdrawal();

        assertEq(usdc.balanceOf(alice), 10_000 * 10 ** 6);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_ExecuteWithdrawal_EmitsEvent() public {
        vm.startPrank(alice);

        uint256 amount = 1000 * 10 ** 6;
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);

        uint256 shares = vault.balanceOf(alice);
        vault.requestWithdrawal(shares);

        vm.stopPrank();

        vm.warp(1 days + 3 days);

        vm.expectEmit(true, false, false, true);
        emit WithdrawalExecuted(alice, shares, amount);

        vm.prank(alice);
        vault.executeWithdrawal();
    }

    function test_ExecuteWithdrawal_RevertIfNoRequest() public {
        vm.prank(alice);
        vm.expectRevert(Vault.NoWithdrawalRequest.selector);
        vault.executeWithdrawal();
    }

    function test_ExecuteWithdrawal_ClearsRequest() public {
        vm.startPrank(alice);

        usdc.approve(address(vault), 1000 * 10 ** 6);
        vault.deposit(1000 * 10 ** 6, alice);
        vault.requestWithdrawal(vault.balanceOf(alice));

        vm.stopPrank();

        vm.warp(1 days + 3 days);

        vm.prank(alice);
        vault.executeWithdrawal();

        (uint256 reqShares, ) = vault.withdrawalRequests(alice);
        assertEq(reqShares, 0);

        // Cannot execute again
        vm.prank(alice);
        vm.expectRevert(Vault.NoWithdrawalRequest.selector);
        vault.executeWithdrawal();
    }

    /*//////////////////////////////////////////////////////////////
                        CANCEL WITHDRAWAL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CancelWithdrawal() public {
        vm.startPrank(alice);

        uint256 amount = 1000 * 10 ** 6;
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);

        uint256 shares = vault.balanceOf(alice);
        vault.requestWithdrawal(shares);

        (uint256 reqShares, ) = vault.withdrawalRequests(alice);
        assertEq(reqShares, shares);

        vault.cancelWithdrawal();

        (reqShares, ) = vault.withdrawalRequests(alice);
        assertEq(reqShares, 0);

        assertEq(vault.balanceOf(alice), shares);

        vm.stopPrank();
    }

    function test_CancelWithdrawal_EmitsEvent() public {
        vm.startPrank(alice);

        usdc.approve(address(vault), 1000 * 10 ** 6);
        vault.deposit(1000 * 10 ** 6, alice);
        vault.requestWithdrawal(vault.balanceOf(alice));

        vm.expectEmit(true, false, false, false);
        emit WithdrawalCancelled(alice);

        vault.cancelWithdrawal();

        vm.stopPrank();
    }

    function test_CancelWithdrawal_RevertIfNoRequest() public {
        vm.prank(alice);
        vm.expectRevert(Vault.NoWithdrawalRequest.selector);
        vault.cancelWithdrawal();
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW HELPERS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetWithdrawalUnlockEpoch() public {
        vm.startPrank(alice);

        uint256 amount = 1000 * 10 ** 6;
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vault.requestWithdrawal(vault.balanceOf(alice));

        vm.stopPrank();

        assertEq(vault.getWithdrawalUnlockEpoch(alice), 3);
        assertEq(vault.getWithdrawalUnlockEpoch(bob), 0);
    }

    function test_CanExecuteWithdrawal() public {
        vm.startPrank(alice);

        uint256 amount = 1000 * 10 ** 6;
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vault.requestWithdrawal(vault.balanceOf(alice));

        vm.stopPrank();

        assertFalse(vault.canExecuteWithdrawal(alice));

        vm.warp(1 days + 3 days);

        assertTrue(vault.canExecuteWithdrawal(alice));
        assertFalse(vault.canExecuteWithdrawal(bob));
    }

    function test_TimeUntilWithdrawal() public {
        // Deploy was at 1 days, we warp to 2 days (epoch 1) to request
        vm.warp(1 days + 1 days);

        vm.startPrank(alice);

        uint256 amount = 1000 * 10 ** 6;
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vault.requestWithdrawal(vault.balanceOf(alice));

        vm.stopPrank();

        // Request at epoch 1, unlock at epoch 4 → 3 days remaining
        assertEq(vault.timeUntilWithdrawal(alice), 3 days);

        vm.warp(1 days + 2 days);
        assertEq(vault.timeUntilWithdrawal(alice), 2 days);

        vm.warp(1 days + 4 days);
        assertEq(vault.timeUntilWithdrawal(alice), 0);

        assertEq(vault.timeUntilWithdrawal(bob), 0);
    }

    function test_CurrentEpoch() public {
        assertEq(vault.currentEpoch(), 0);

        vm.warp(1 days + 1 days);
        assertEq(vault.currentEpoch(), 1);

        vm.warp(1 days + 10 days);
        assertEq(vault.currentEpoch(), 10);
    }

    /*//////////////////////////////////////////////////////////////
                            PROTOCOL ACTIONS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SendPayout() public {
        // Setup: Alice deposits
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000 * 10 ** 6);
        vault.deposit(1000 * 10 ** 6, alice);
        vm.stopPrank();

        uint256 bobBalanceBefore = usdc.balanceOf(bob);

        // Trading engine sends payout to Bob
        vm.prank(tradingEngine);
        vault.sendPayout(bob, 500 * 10 ** 6);

        assertEq(usdc.balanceOf(bob), bobBalanceBefore + 500 * 10 ** 6);
        assertEq(vault.totalAssets(), 500 * 10 ** 6);
    }

    function test_SendPayout_EmitsEvent() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000 * 10 ** 6);
        vault.deposit(1000 * 10 ** 6, alice);
        vm.stopPrank();

        vm.expectEmit(true, false, false, true);
        emit PayoutSent(bob, 500 * 10 ** 6);

        vm.prank(tradingEngine);
        vault.sendPayout(bob, 500 * 10 ** 6);
    }

    function test_SendPayout_RevertIfNotTradingEngine() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000 * 10 ** 6);
        vault.deposit(1000 * 10 ** 6, alice);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(Vault.CallerNotTradingEngine.selector);
        vault.sendPayout(bob, 500 * 10 ** 6);
    }

    function test_SendPayout_RevertIfInsufficientBalance() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000 * 10 ** 6);
        vault.deposit(1000 * 10 ** 6, alice);
        vm.stopPrank();

        vm.prank(tradingEngine);
        vm.expectRevert();
        vault.sendPayout(bob, 2000 * 10 ** 6);
    }

    function test_DirectTransfer_IncreasesShareValue() public {
        // Alice deposits 1000 USDC, gets 1000 shares
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000 * 10 ** 6);
        vault.deposit(1000 * 10 ** 6, alice);
        vm.stopPrank();

        uint256 sharesBefore = vault.balanceOf(alice);
        uint256 assetsBefore = vault.previewRedeem(sharesBefore);

        // Direct USDC transfer to vault (donation) doubles the assets
        usdc.mint(bob, 1000 * 10 ** 6);
        vm.prank(bob);
        address(usdc).safeTransfer(address(vault), 1000 * 10 ** 6);

        uint256 assetsAfter = vault.previewRedeem(sharesBefore);

        // Same shares now worth ~2x assets (allow 1 wei rounding)
        assertApproxEqAbs(assetsAfter, assetsBefore * 2, 1);
    }

    /*//////////////////////////////////////////////////////////////
                            PAUSE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Pause_BlocksDeposit() public {
        vm.prank(owner);
        vault.pause();

        vm.startPrank(alice);
        usdc.approve(address(vault), 1000 * 10 ** 6);

        vm.expectRevert(Vault.EnforcedPause.selector);
        vault.deposit(1000 * 10 ** 6, alice);

        vm.stopPrank();
    }

    function test_Pause_BlocksMint() public {
        vm.prank(owner);
        vault.pause();

        vm.startPrank(alice);
        usdc.approve(address(vault), 1000 * 10 ** 6);

        vm.expectRevert(Vault.EnforcedPause.selector);
        vault.mint(1000 * 1e18, alice);

        vm.stopPrank();
    }

    function test_Pause_BlocksRequestWithdrawal() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000 * 10 ** 6);
        vault.deposit(1000 * 10 ** 6, alice);
        uint256 shares = vault.balanceOf(alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert(Vault.EnforcedPause.selector);
        vault.requestWithdrawal(shares);
    }

    function test_Pause_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit Paused(owner);

        vm.prank(owner);
        vault.pause();
    }

    function test_Pause_RevertIfAlreadyPaused() public {
        vm.prank(owner);
        vault.pause();

        vm.prank(owner);
        vm.expectRevert(Vault.EnforcedPause.selector);
        vault.pause();
    }

    function test_Pause_RevertIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.pause();
    }

    function test_Unpause_AllowsOperations() public {
        vm.prank(owner);
        vault.pause();

        vm.prank(owner);
        vault.unpause();

        vm.startPrank(alice);
        usdc.approve(address(vault), 1000 * 10 ** 6);
        vault.deposit(1000 * 10 ** 6, alice);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 1000 * 1e18);
    }

    function test_Unpause_EmitsEvent() public {
        vm.prank(owner);
        vault.pause();

        vm.expectEmit(false, false, false, true);
        emit Unpaused(owner);

        vm.prank(owner);
        vault.unpause();
    }

    function test_Unpause_RevertIfNotPaused() public {
        vm.prank(owner);
        vm.expectRevert(Vault.ExpectedPause.selector);
        vault.unpause();
    }

    function test_Unpause_RevertIfNotOwner() public {
        vm.prank(owner);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert();
        vault.unpause();
    }

    function test_Paused_ReturnsCorrectState() public {
        assertFalse(vault.paused());

        vm.prank(owner);
        vault.pause();

        assertTrue(vault.paused());

        vm.prank(owner);
        vault.unpause();

        assertFalse(vault.paused());
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetTradingEngine() public {
        address newEngine = makeAddr("newEngine");

        vm.prank(owner);
        vault.setTradingEngine(newEngine);

        assertEq(vault.tradingEngine(), newEngine);
    }

    function test_SetTradingEngine_EmitsEvent() public {
        address newEngine = makeAddr("newEngine");

        vm.expectEmit(true, false, false, false);
        emit TradingEngineUpdated(newEngine);

        vm.prank(owner);
        vault.setTradingEngine(newEngine);
    }

    function test_SetTradingEngine_RevertOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(Vault.ZeroAddress.selector);
        vault.setTradingEngine(address(0));
    }

    function test_SetTradingEngine_RevertIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setTradingEngine(makeAddr("newEngine"));
    }

    /*//////////////////////////////////////////////////////////////
                        CUSTOM ERROR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Withdraw_RevertsWithCustomError() public {
        vm.prank(alice);
        vm.expectRevert(Vault.UseRequestWithdrawalFlow.selector);
        vault.withdraw(100, alice, alice);
    }

    function test_Redeem_RevertsWithCustomError() public {
        vm.prank(alice);
        vm.expectRevert(Vault.UseRequestWithdrawalFlow.selector);
        vault.redeem(100, alice, alice);
    }

    /*//////////////////////////////////////////////////////////////
                        TWO-STEP OWNERSHIP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_OwnershipHandover_TwoStep() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(newOwner);
        vault.requestOwnershipHandover();

        assertEq(vault.owner(), owner);

        vm.prank(owner);
        vault.completeOwnershipHandover(newOwner);

        assertEq(vault.owner(), newOwner);
    }

    function test_OwnershipHandover_OnlyOwnerCanComplete() public {
        address newOwner = makeAddr("newOwner");
        address randomUser = makeAddr("randomUser");

        vm.prank(newOwner);
        vault.requestOwnershipHandover();

        vm.prank(randomUser);
        vm.expectRevert();
        vault.completeOwnershipHandover(newOwner);
    }

    function test_OwnershipHandover_CanCancelRequest() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(newOwner);
        vault.requestOwnershipHandover();

        vm.prank(newOwner);
        vault.cancelOwnershipHandover();

        // Owner cannot complete cancelled handover
        vm.prank(owner);
        vm.expectRevert();
        vault.completeOwnershipHandover(newOwner);
    }

    function test_RenounceOwnership() public {
        vm.prank(owner);
        vault.renounceOwnership();

        assertEq(vault.owner(), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                            ERC4626 VIEW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Asset() public view {
        assertEq(vault.asset(), address(usdc));
    }

    function test_Name() public view {
        assertEq(vault.name(), "Synthetic Liquidity Token");
    }

    function test_Symbol() public view {
        assertEq(vault.symbol(), "sUSDC");
    }

    function test_Decimals() public view {
        assertEq(vault.decimals(), 18);
    }

    function test_TotalAssets_EqualsUSDCBalance() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000 * 10 ** 6);
        vault.deposit(1000 * 10 ** 6, alice);
        vm.stopPrank();

        assertEq(vault.totalAssets(), usdc.balanceOf(address(vault)));
    }

    /*//////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_Deposit(uint256 amount) public {
        // Bound to reasonable USDC amounts (1 to 10M USDC)
        amount = bound(amount, 1, 10_000_000 * 10 ** 6);

        usdc.mint(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(vault), amount);

        uint256 shares = vault.deposit(amount, alice);

        vm.stopPrank();

        assertEq(vault.balanceOf(alice), shares);
        assertEq(usdc.balanceOf(address(vault)), amount);
        assertGt(shares, 0);
    }

    function testFuzz_DepositAndWithdraw(uint256 amount) public {
        amount = bound(amount, 1, 10_000_000 * 10 ** 6);

        usdc.mint(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);

        uint256 shares = vault.balanceOf(alice);
        vault.requestWithdrawal(shares);
        vm.stopPrank();

        vm.warp(1 days + 3 days);

        uint256 balanceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        vault.executeWithdrawal();

        uint256 balanceAfter = usdc.balanceOf(alice);

        // Should get back the same amount (no profit/loss scenario)
        assertEq(balanceAfter - balanceBefore, amount);
        assertEq(vault.balanceOf(alice), 0);
    }

    function testFuzz_SendPayout(uint256 depositAmount, uint256 payoutAmount) public {
        depositAmount = bound(depositAmount, 1, 10_000_000 * 10 ** 6);
        payoutAmount = bound(payoutAmount, 0, depositAmount);

        usdc.mint(alice, depositAmount);

        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        uint256 bobBalanceBefore = usdc.balanceOf(bob);

        vm.prank(tradingEngine);
        vault.sendPayout(bob, payoutAmount);

        assertEq(usdc.balanceOf(bob), bobBalanceBefore + payoutAmount);
        assertEq(vault.totalAssets(), depositAmount - payoutAmount);
    }

    /*//////////////////////////////////////////////////////////////
                            INVARIANT HELPERS
    //////////////////////////////////////////////////////////////*/

    function test_Invariant_TotalAssetsEqualsBalance() public {
        // Multiple operations
        vm.startPrank(alice);
        usdc.approve(address(vault), 5000 * 10 ** 6);
        vault.deposit(1000 * 10 ** 6, alice);
        vault.deposit(2000 * 10 ** 6, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(vault), 3000 * 10 ** 6);
        vault.deposit(3000 * 10 ** 6, bob);
        vm.stopPrank();

        // Invariant: totalAssets == USDC balance
        assertEq(vault.totalAssets(), usdc.balanceOf(address(vault)));

        // Payout
        vm.prank(tradingEngine);
        vault.sendPayout(bob, 500 * 10 ** 6);

        // Invariant still holds
        assertEq(vault.totalAssets(), usdc.balanceOf(address(vault)));
    }

    function test_Invariant_SharesMintedEqualsBurned() public {
        // Alice deposits
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000 * 10 ** 6);
        vault.deposit(1000 * 10 ** 6, alice);
        uint256 aliceShares = vault.balanceOf(alice);
        vm.stopPrank();

        // Bob deposits
        vm.startPrank(bob);
        usdc.approve(address(vault), 2000 * 10 ** 6);
        vault.deposit(2000 * 10 ** 6, bob);
        uint256 bobShares = vault.balanceOf(bob);
        vm.stopPrank();

        uint256 totalSharesMinted = aliceShares + bobShares;
        assertEq(vault.totalSupply(), totalSharesMinted);

        // Both withdraw
        vm.prank(alice);
        vault.requestWithdrawal(aliceShares);

        vm.prank(bob);
        vault.requestWithdrawal(bobShares);

        vm.warp(1 days + 3 days);

        vm.prank(alice);
        vault.executeWithdrawal();

        vm.prank(bob);
        vault.executeWithdrawal();

        // All shares burned
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), 0);
    }
}
