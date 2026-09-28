// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployLib, DeployConfig, Deployed} from "../../script/Deploy.s.sol";
import {RegressionUSDC} from "./RegressionBase.sol";

/**
 * @title DepositCoverageRegressionTest
 * @author GushALKDev
 * @notice Round 1 LP timing finding, ratio part: an LP could deposit while the LP principal coverage ratio was
 *         below 100% and then take a share of the AssistantFund injection (or bond proceeds) meant to restore
 *         the LPs who carried the loss. Deposits and mints now revert while the ratio is below 100%.
 * @dev Runs on the wired deployment from DeployLib with no open trade, so the PnL snapshot is fresh and the
 *      ratio is the realised one. The new error is matched by selector literal.
 */
contract DepositCoverageRegressionTest is Test {
    Deployed d;
    RegressionUSDC usdc;

    address owner = makeAddr("owner");
    address lp = makeAddr("lp");
    address late = makeAddr("late");

    uint256 constant LP_DEPOSIT = 1_000_000 * 10 ** 6;
    uint256 constant DRAIN = 100_000 * 10 ** 6; // ratio 90%
    bytes4 constant COVERAGE_BELOW_PAR = bytes4(keccak256("CoverageBelowPar(uint256)"));
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

        usdc.mint(late, LP_DEPOSIT);
        vm.prank(late);
        usdc.approve(address(d.vault), type(uint256).max);

        // Winning traders take 10% of the Vault: ratio 90%
        vm.prank(address(d.engine));
        d.vault.sendPayout(makeAddr("winner"), DRAIN);
        // The reserve holds enough to restore 100%
        usdc.mint(address(d.assistantFund), DRAIN);
    }

    /**
     * @notice A deposit at a 90% ratio reverts, so the later injection goes to the LPs who carried the loss
     * @dev The deposit is a low-level call so the test runs to the end before the change: there the late LP
     *      bought shares at 0.9 and the injection lifted them above what it paid, which the first assertion
     *      reports.
     */
    function test_Regression_DepositRevertsBelowFullCoverage_ThenInjectionRestoresPar() public {
        assertEq(d.vault.collateralizationRatio(), 0.9e18);

        vm.prank(late);
        (bool deposited, bytes memory revertData) = address(d.vault).call(abi.encodeCall(d.vault.deposit, (LP_DEPOSIT, late)));
        d.solvencyManager.checkAndAct();

        assertLe(d.vault.convertToAssets(d.vault.balanceOf(late)), LP_DEPOSIT, "late LP captured part of the injection");
        assertFalse(deposited, "deposit below 100% did not revert");
        assertEq(bytes4(revertData), COVERAGE_BELOW_PAR, "wrong revert");
        assertEq(d.vault.collateralizationRatio(), 1e18, "injection did not restore 100%");
        assertEq(d.vault.convertToAssets(d.vault.balanceOf(lp)), LP_DEPOSIT, "injection not credited to the original LP");
    }

    function test_Regression_MintRevertsBelowFullCoverage() public {
        vm.prank(late);
        vm.expectPartialRevert(COVERAGE_BELOW_PAR);
        d.vault.mint(1_000 * 1e18, late);
    }

    function test_Regression_RefreshAndDepositRevertsBelowFullCoverage() public {
        vm.prank(late);
        vm.expectPartialRevert(COVERAGE_BELOW_PAR);
        d.vault.refreshAndDeposit(1_000 * 10 ** 6, late, EMPTY);
    }

    function test_Regression_RefreshAndMintRevertsBelowFullCoverage() public {
        vm.prank(late);
        vm.expectPartialRevert(COVERAGE_BELOW_PAR);
        d.vault.refreshAndMint(1_000 * 1e18, late, EMPTY);
    }

    /// @notice maxDeposit and maxMint report 0 below 100%, since deposit and mint revert
    function test_Regression_MaxDepositAndMaxMintZeroBelowFullCoverage() public view {
        assertEq(d.vault.maxDeposit(late), 0, "maxDeposit not 0 below 100%");
        assertEq(d.vault.maxMint(late), 0, "maxMint not 0 below 100%");
    }
}
