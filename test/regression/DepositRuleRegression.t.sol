// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployLib, DeployConfig, Deployed} from "../../script/Deploy.s.sol";
import {RegressionUSDC} from "./RegressionBase.sol";

/**
 * @title DepositRuleRegressionTest
 * @author GushALKDev
 * @notice Round 3 deposit rule. Round 2b reverted every deposit below a 100% coverage ratio, which froze deposits
 *         when no rescue was left (AssistantFund empty, no bonding due). Now a deposit first runs the pending
 *         AssistantFund injection in the same transaction and mints at the post-injection NAV; it reverts only
 *         while a bonding round is open or due, because that rescue is not instantaneous.
 * @dev Runs on the wired DeployLib stack with no open trade, so the PnL snapshot is fresh and the NAV is the
 *      balance. The new error is matched by selector literal and the new functions are not called, so the file
 *      compiles against the code before the change.
 */
contract DepositRuleRegressionTest is Test {
    Deployed d;
    RegressionUSDC usdc;

    address owner = makeAddr("owner");
    address lp = makeAddr("lp");
    address late = makeAddr("late");

    uint256 constant LP_DEPOSIT = 1_000_000 * 10 ** 6;
    uint256 constant DEPOSIT = 100_000 * 10 ** 6;
    bytes4 constant BONDING_ROUND_OPEN = bytes4(keccak256("BondingRoundOpen()"));
    bytes[] EMPTY;

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new RegressionUSDC();
        DeployConfig memory cfg = DeployConfig({
            asset: address(usdc),
            pyth: makeAddr("pyth"),
            sequencerUptimeFeed: address(0),
            owner: owner,
            keeper: makeAddr("keeper"),
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
        vm.stopPrank();

        usdc.mint(lp, LP_DEPOSIT);
        vm.startPrank(lp);
        usdc.approve(address(d.vault), type(uint256).max);
        d.vault.deposit(LP_DEPOSIT, lp);
        vm.stopPrank();

        usdc.mint(late, 10 * DEPOSIT);
        vm.prank(late);
        usdc.approve(address(d.vault), type(uint256).max);
    }

    /// @dev Winning traders take _amount of the Vault's USDC
    function _drain(uint256 _amount) internal {
        vm.prank(address(d.engine));
        d.vault.sendPayout(makeAddr("winner"), _amount);
    }

    function _depositLate() internal returns (bool ok, bytes memory revertData) {
        vm.prank(late);
        (ok, revertData) = address(d.vault).call(abi.encodeCall(d.vault.deposit, (DEPOSIT, late)));
    }

    /**
     * @notice At 97% with an empty AssistantFund and a realised ratio above 95%, a deposit goes through at the NAV
     * @dev Before the change it reverted with CoverageBelowPar: nothing could rescue the Vault, so deposits stayed
     *      blocked until the ratio recovered by itself.
     */
    function test_Regression_DepositRule_BelowParWithoutRescueAllowed() public {
        _drain(30_000 * 10 ** 6);
        uint256 supply = d.vault.totalSupply();
        uint256 expectedShares = (DEPOSIT * (supply + 1e12)) / (970_000 * 10 ** 6 + 1);

        (bool ok, bytes memory revertData) = _depositLate();
        assertTrue(ok, string.concat("deposit below par reverted: ", vm.toString(revertData)));
        assertEq(d.vault.balanceOf(late), expectedShares, "shares not minted at the NAV");
    }

    /**
     * @notice At 97% with a funded AssistantFund, the deposit runs the injection first and does not capture it
     * @dev The original LP gets the whole 10,000 USDC injection: 970,000 + 10,000.
     */
    function test_Regression_DepositRule_InjectionSettledBeforeDeposit() public {
        _drain(30_000 * 10 ** 6);
        usdc.mint(address(d.assistantFund), 10_000 * 10 ** 6);

        (bool ok, bytes memory revertData) = _depositLate();
        assertTrue(ok, string.concat("deposit below par reverted: ", vm.toString(revertData)));
        assertEq(d.assistantFund.balance(), 0, "injection not run before the deposit");
        assertLe(d.vault.convertToAssets(d.vault.balanceOf(late)), DEPOSIT, "late LP captured part of the injection");
        assertApproxEqAbs(d.vault.convertToAssets(d.vault.balanceOf(lp)), 980_000 * 10 ** 6, 1, "injection not credited to the original LP");
    }

    /// @notice refreshAndMint follows the same rule
    function test_Regression_DepositRule_RefreshAndMintSettlesInjectionFirst() public {
        _drain(30_000 * 10 ** 6);
        usdc.mint(address(d.assistantFund), 10_000 * 10 ** 6);

        vm.prank(late);
        (bool ok, bytes memory revertData) = address(d.vault).call(abi.encodeCall(d.vault.refreshAndMint, (DEPOSIT * 1e12, late, EMPTY)));
        assertTrue(ok, string.concat("mint below par reverted: ", vm.toString(revertData)));
        assertEq(d.assistantFund.balance(), 0, "injection not run before the mint");
        assertApproxEqAbs(d.vault.convertToAssets(d.vault.balanceOf(lp)), 980_000 * 10 ** 6, 1, "injection not credited to the original LP");
    }

    /// @notice With a bonding round open, deposits revert: bond proceeds are not instantaneous
    function test_Regression_DepositRule_RevertsWhileRoundOpen() public {
        _drain(100_000 * 10 ** 6);
        d.solvencyManager.checkAndAct();
        assertTrue(d.bondDepository.isActive(), "setup: round not opened");

        vm.prank(late);
        vm.expectPartialRevert(BONDING_ROUND_OPEN);
        d.vault.deposit(DEPOSIT, late);
    }

    /**
     * @notice With bonding due (realised ratio below 95% and a deficit the reserve does not cover), deposits revert
     *         and the round the check would open is unwound with them
     */
    function test_Regression_DepositRule_RevertsWhileBondingDue() public {
        _drain(100_000 * 10 ** 6);
        usdc.mint(address(d.assistantFund), 10_000 * 10 ** 6);

        vm.prank(late);
        vm.expectPartialRevert(BONDING_ROUND_OPEN);
        d.vault.deposit(DEPOSIT, late);
        assertFalse(d.bondDepository.isActive(), "round left open by a reverted deposit");
        assertEq(d.assistantFund.balance(), 10_000 * 10 ** 6, "injection left behind by a reverted deposit");
    }

    /// @notice maxDeposit and maxMint follow the rule: open below par without a rescue, zero while bonding is due
    function test_Regression_DepositRule_MaxDepositFollowsRule() public {
        _drain(30_000 * 10 ** 6);
        assertEq(d.vault.maxDeposit(late), type(uint256).max, "maxDeposit zero below par without a rescue");
        assertEq(d.vault.maxMint(late), type(uint256).max, "maxMint zero below par without a rescue");

        _drain(70_000 * 10 ** 6);
        assertEq(d.vault.maxDeposit(late), 0, "maxDeposit not zero while bonding is due");
        assertEq(d.vault.maxMint(late), 0, "maxMint not zero while bonding is due");
    }
}
