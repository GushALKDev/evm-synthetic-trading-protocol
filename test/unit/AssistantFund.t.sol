// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {AssistantFund} from "../../src/AssistantFund.sol";

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

contract AssistantFundTest is Test {
    AssistantFund fund;
    MockUSDC usdc;

    address owner = makeAddr("owner");
    address vault = makeAddr("vault");
    address solvencyManager = makeAddr("solvencyManager");
    address alice = makeAddr("alice");

    uint256 constant DEFAULT_TARGET_CAP = 1_000_000 * 10 ** 6; // 1M USDC

    event FundsInjected(uint256 amount);
    event Skimmed(uint256 amount);
    event SolvencyManagerUpdated(address indexed newSolvencyManager);
    event TargetCapUpdated(uint256 newTargetCap);

    function setUp() public {
        usdc = new MockUSDC();
        vm.prank(owner);
        fund = new AssistantFund(address(usdc), vault, DEFAULT_TARGET_CAP, owner);
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_SetsState() public view {
        assertEq(fund.ASSET(), address(usdc));
        assertEq(fund.VAULT(), vault);
        assertEq(fund.targetCap(), DEFAULT_TARGET_CAP);
        assertEq(fund.owner(), owner);
        assertEq(fund.solvencyManager(), address(0));
    }

    function test_Constructor_RevertOnZeroAsset() public {
        vm.expectRevert(AssistantFund.ZeroAddress.selector);
        new AssistantFund(address(0), vault, DEFAULT_TARGET_CAP, owner);
    }

    function test_Constructor_RevertOnZeroVault() public {
        vm.expectRevert(AssistantFund.ZeroAddress.selector);
        new AssistantFund(address(usdc), address(0), DEFAULT_TARGET_CAP, owner);
    }

    /*//////////////////////////////////////////////////////////////
                            FEE RECEPTION
    //////////////////////////////////////////////////////////////*/

    function test_ReceivesFeesAsPlainTransfer() public {
        // Fees arrive as a plain USDC transfer (treasury pointed here) — no hook needed
        usdc.mint(address(fund), 500 * 10 ** 6);
        assertEq(fund.balance(), 500 * 10 ** 6);
    }

    function test_IsFunded() public {
        assertFalse(fund.isFunded());
        usdc.mint(address(fund), DEFAULT_TARGET_CAP);
        assertTrue(fund.isFunded());
    }

    /*//////////////////////////////////////////////////////////////
                            INJECT FUNDS
    //////////////////////////////////////////////////////////////*/

    function test_InjectFunds() public {
        usdc.mint(address(fund), 1000 * 10 ** 6);
        vm.prank(owner);
        fund.setSolvencyManager(solvencyManager);

        vm.expectEmit(false, false, false, true);
        emit FundsInjected(400 * 10 ** 6);
        vm.prank(solvencyManager);
        fund.injectFunds(400 * 10 ** 6);

        assertEq(usdc.balanceOf(vault), 400 * 10 ** 6);
        assertEq(fund.balance(), 600 * 10 ** 6);
    }

    function test_InjectFunds_RevertIfNotSolvencyManager() public {
        usdc.mint(address(fund), 1000 * 10 ** 6);
        vm.prank(owner);
        fund.setSolvencyManager(solvencyManager);

        vm.prank(alice);
        vm.expectRevert(AssistantFund.CallerNotSolvencyManager.selector);
        fund.injectFunds(100 * 10 ** 6);
    }

    function test_InjectFunds_RevertIfManagerNotSet() public {
        usdc.mint(address(fund), 1000 * 10 ** 6);
        // solvencyManager still address(0)
        vm.prank(alice);
        vm.expectRevert(AssistantFund.SolvencyManagerNotSet.selector);
        fund.injectFunds(100 * 10 ** 6);
    }

    function test_InjectFunds_RevertOnInsufficientFunds() public {
        usdc.mint(address(fund), 100 * 10 ** 6);
        vm.prank(owner);
        fund.setSolvencyManager(solvencyManager);

        vm.prank(solvencyManager);
        vm.expectRevert(abi.encodeWithSelector(AssistantFund.InsufficientFunds.selector, 200 * 10 ** 6, 100 * 10 ** 6));
        fund.injectFunds(200 * 10 ** 6);
    }

    /*//////////////////////////////////////////////////////////////
                                SKIM
    //////////////////////////////////////////////////////////////*/

    function test_Skim_OverflowGoesToVault() public {
        // Balance above cap → excess skimmed to Vault
        usdc.mint(address(fund), DEFAULT_TARGET_CAP + 300 * 10 ** 6);

        vm.expectEmit(false, false, false, true);
        emit Skimmed(300 * 10 ** 6);
        vm.prank(alice); // permissionless
        uint256 skimmed = fund.skim();

        assertEq(skimmed, 300 * 10 ** 6);
        assertEq(usdc.balanceOf(vault), 300 * 10 ** 6);
        assertEq(fund.balance(), DEFAULT_TARGET_CAP);
    }

    function test_Skim_NoOverflowIsNoOp() public {
        usdc.mint(address(fund), DEFAULT_TARGET_CAP - 1);
        uint256 vaultBefore = usdc.balanceOf(vault);

        vm.prank(alice);
        uint256 skimmed = fund.skim();

        assertEq(skimmed, 0);
        assertEq(usdc.balanceOf(vault), vaultBefore);
        assertEq(fund.balance(), DEFAULT_TARGET_CAP - 1);
    }

    function test_Skim_ExactlyAtCapIsNoOp() public {
        usdc.mint(address(fund), DEFAULT_TARGET_CAP);
        vm.prank(alice);
        assertEq(fund.skim(), 0);
        assertEq(fund.balance(), DEFAULT_TARGET_CAP);
    }

    function testFuzz_Skim_ConservesFunds(uint256 minted, uint256 cap) public {
        minted = bound(minted, 0, 1e18);
        cap = bound(cap, 0, 1e18);

        vm.prank(owner);
        fund.setTargetCap(cap);
        usdc.mint(address(fund), minted);

        vm.prank(alice);
        uint256 skimmed = fund.skim();

        // Conservation: what's skimmed + what remains == what was minted
        assertEq(skimmed + fund.balance(), minted);
        // Never skims below the cap
        assertGe(fund.balance(), minted > cap ? cap : minted);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN
    //////////////////////////////////////////////////////////////*/

    function test_SetSolvencyManager() public {
        vm.expectEmit(true, false, false, false);
        emit SolvencyManagerUpdated(solvencyManager);
        vm.prank(owner);
        fund.setSolvencyManager(solvencyManager);
        assertEq(fund.solvencyManager(), solvencyManager);
    }

    function test_SetSolvencyManager_RevertOnZero() public {
        vm.prank(owner);
        vm.expectRevert(AssistantFund.ZeroAddress.selector);
        fund.setSolvencyManager(address(0));
    }

    function test_SetSolvencyManager_RevertIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        fund.setSolvencyManager(solvencyManager);
    }

    function test_SetTargetCap() public {
        vm.expectEmit(false, false, false, true);
        emit TargetCapUpdated(500 * 10 ** 6);
        vm.prank(owner);
        fund.setTargetCap(500 * 10 ** 6);
        assertEq(fund.targetCap(), 500 * 10 ** 6);
    }

    function test_SetTargetCap_RevertIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        fund.setTargetCap(500 * 10 ** 6);
    }

    function test_SetTargetCap_LoweringEnablesSkim() public {
        usdc.mint(address(fund), 800 * 10 ** 6);
        // Lower cap below balance → the excess becomes skimmable
        vm.prank(owner);
        fund.setTargetCap(500 * 10 ** 6);

        vm.prank(alice);
        uint256 skimmed = fund.skim();
        assertEq(skimmed, 300 * 10 ** 6);
        assertEq(fund.balance(), 500 * 10 ** 6);
    }
}
