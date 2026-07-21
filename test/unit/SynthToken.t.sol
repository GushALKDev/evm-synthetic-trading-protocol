// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {SynthToken} from "../../src/SynthToken.sol";

contract SynthTokenTest is Test {
    SynthToken token;

    address owner = makeAddr("owner");
    address minter = makeAddr("minter");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    event MinterUpdated(address indexed newMinter);
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function setUp() public {
        token = new SynthToken(owner);
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_SetsOwner() public view {
        assertEq(token.owner(), owner);
    }

    function test_Constructor_Metadata() public view {
        assertEq(token.name(), "Synth Token");
        assertEq(token.symbol(), "SYNTH");
        assertEq(token.decimals(), 18);
    }

    function test_Constructor_ZeroOwnerReverts() public {
        vm.expectRevert(SynthToken.ZeroAddress.selector);
        new SynthToken(address(0));
    }

    function test_Constructor_MinterUnset() public view {
        assertEq(token.minter(), address(0));
        assertEq(token.totalSupply(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                            SET MINTER
    //////////////////////////////////////////////////////////////*/

    function test_SetMinter_UpdatesMinter() public {
        vm.prank(owner);
        token.setMinter(minter);
        assertEq(token.minter(), minter);
    }

    function test_SetMinter_EmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit MinterUpdated(minter);
        vm.prank(owner);
        token.setMinter(minter);
    }

    function test_SetMinter_ZeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert(SynthToken.ZeroAddress.selector);
        token.setMinter(address(0));
    }

    function test_SetMinter_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        token.setMinter(minter);
    }

    /*//////////////////////////////////////////////////////////////
                                MINT
    //////////////////////////////////////////////////////////////*/

    function test_Mint_ByMinter() public {
        vm.prank(owner);
        token.setMinter(minter);

        vm.prank(minter);
        token.mint(alice, 100e18);

        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.totalSupply(), 100e18);
    }

    function test_Mint_EmitsTransferFromZero() public {
        vm.prank(owner);
        token.setMinter(minter);

        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), alice, 100e18);
        vm.prank(minter);
        token.mint(alice, 100e18);
    }

    function test_Mint_MinterNotSetReverts() public {
        vm.prank(minter);
        vm.expectRevert(SynthToken.MinterNotSet.selector);
        token.mint(alice, 100e18);
    }

    function test_Mint_NonMinterReverts() public {
        vm.prank(owner);
        token.setMinter(minter);

        vm.prank(alice);
        vm.expectRevert(SynthToken.CallerNotMinter.selector);
        token.mint(alice, 100e18);
    }

    function test_Mint_OwnerCannotMint() public {
        vm.prank(owner);
        token.setMinter(minter);

        vm.prank(owner);
        vm.expectRevert(SynthToken.CallerNotMinter.selector);
        token.mint(alice, 100e18);
    }

    /*//////////////////////////////////////////////////////////////
                                BURN
    //////////////////////////////////////////////////////////////*/

    function test_Burn_ReducesSupply() public {
        _mintTo(alice, 100e18);

        vm.prank(alice);
        token.burn(40e18);

        assertEq(token.balanceOf(alice), 60e18);
        assertEq(token.totalSupply(), 60e18);
    }

    function test_Burn_MoreThanBalanceReverts() public {
        _mintTo(alice, 100e18);

        vm.prank(alice);
        vm.expectRevert(); // Solady InsufficientBalance
        token.burn(101e18);
    }

    function test_BurnFrom_WithAllowance() public {
        _mintTo(alice, 100e18);

        vm.prank(alice);
        token.approve(bob, 40e18);

        vm.prank(bob);
        token.burnFrom(alice, 40e18);

        assertEq(token.balanceOf(alice), 60e18);
        assertEq(token.totalSupply(), 60e18);
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_BurnFrom_WithoutAllowanceReverts() public {
        _mintTo(alice, 100e18);

        vm.prank(bob);
        vm.expectRevert(); // Solady InsufficientAllowance
        token.burnFrom(alice, 40e18);
    }

    function test_BurnFrom_InfiniteAllowanceNotReduced() public {
        _mintTo(alice, 100e18);

        vm.prank(alice);
        token.approve(bob, type(uint256).max);

        vm.prank(bob);
        token.burnFrom(alice, 40e18);

        assertEq(token.allowance(alice, bob), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                                FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_MintBurn_SupplyConsistent(uint256 mintAmount, uint256 burnAmount) public {
        mintAmount = bound(mintAmount, 0, type(uint128).max);
        burnAmount = bound(burnAmount, 0, mintAmount);

        _mintTo(alice, mintAmount);
        assertEq(token.totalSupply(), mintAmount);

        vm.prank(alice);
        token.burn(burnAmount);

        assertEq(token.totalSupply(), mintAmount - burnAmount);
        assertEq(token.balanceOf(alice), mintAmount - burnAmount);
    }

    /*//////////////////////////////////////////////////////////////
                            HELPERS
    //////////////////////////////////////////////////////////////*/

    function _mintTo(address to, uint256 amount) internal {
        vm.prank(owner);
        token.setMinter(minter);
        vm.prank(minter);
        token.mint(to, amount);
    }
}
