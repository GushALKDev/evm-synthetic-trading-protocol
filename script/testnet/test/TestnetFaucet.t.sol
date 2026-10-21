// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";

import {TestnetFaucet, TestnetUSDC} from "../TestnetFaucet.sol";

/**
 * @title TestnetFaucetTest
 * @notice Daily claims, owner minting, and that only the faucet can mint the token
 * @dev Run with FOUNDRY_PROFILE=testnet.
 */
contract TestnetFaucetTest is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant VISITOR = address(0xB0B);
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    TestnetFaucet internal faucet;
    TestnetUSDC internal usdc;

    function setUp() public {
        vm.warp(1_800_000_000);
        faucet = new TestnetFaucet(OWNER);
        usdc = faucet.USDC();
    }

    function test_token_isA6DecimalTestnetUsdc() public view {
        assertEq(usdc.decimals(), 6, "decimals");
        assertEq(usdc.symbol(), "USDC", "symbol");
        assertEq(usdc.name(), "Testnet USD Coin", "name");
        assertEq(usdc.allowance(VISITOR, PERMIT2), 0, "no implicit Permit2 allowance");
    }

    function test_claim_sendsTheDrip() public {
        vm.prank(VISITOR);
        faucet.claim();

        assertEq(usdc.balanceOf(VISITOR), 10_000e6, "USDC drip");
        assertEq(faucet.nextClaimAt(VISITOR), block.timestamp + 1 days, "next claim in a day");
    }

    function test_claim_revertsUntilTheCooldownHasPassed() public {
        vm.prank(VISITOR);
        faucet.claim();
        uint256 next = block.timestamp + 1 days;

        vm.warp(next - 1);
        vm.prank(VISITOR);
        vm.expectRevert(abi.encodeWithSelector(TestnetFaucet.ClaimTooSoon.selector, VISITOR, next));
        faucet.claim();

        vm.warp(next);
        vm.prank(VISITOR);
        faucet.claim();
        assertEq(usdc.balanceOf(VISITOR), 20_000e6, "second drip");
    }

    function test_nextClaimAt_isZeroBeforeTheFirstClaim() public view {
        assertEq(faucet.nextClaimAt(VISITOR), 0, "never claimed");
    }

    function test_mint_ownerOnly() public {
        vm.prank(OWNER);
        faucet.mint(VISITOR, 1_000_000e6);
        assertEq(usdc.balanceOf(VISITOR), 1_000_000e6, "owner mint");

        vm.prank(VISITOR);
        vm.expectRevert(Ownable.Unauthorized.selector);
        faucet.mint(VISITOR, 1);
    }

    function test_token_onlyTheFaucetCanMint() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(TestnetUSDC.OnlyMinter.selector, OWNER));
        usdc.mint(OWNER, 1);
    }
}
