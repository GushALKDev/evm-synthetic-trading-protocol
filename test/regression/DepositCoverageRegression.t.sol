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
 *         the LPs who carried the loss. Round 2b reverted deposits below 100%; round 3 runs the pending injection
 *         inside the deposit before minting and reverts only while bonding is open or due
 *         (DepositRuleRegression.t.sol). These tests check the capture is gone under the round 3 rule.
 * @dev Runs on the wired deployment from DeployLib with no open trade, so the PnL snapshot is fresh and the
 *      ratio is the realised one. At 90% the reserve holds the whole deficit, so no bonding round is due.
 */
contract DepositCoverageRegressionTest is Test {
    Deployed d;
    RegressionUSDC usdc;

    address owner = makeAddr("owner");
    address lp = makeAddr("lp");
    address late = makeAddr("late");

    uint256 constant LP_DEPOSIT = 1_000_000 * 10 ** 6;
    uint256 constant DRAIN = 100_000 * 10 ** 6; // ratio 90%
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

    /// @dev Value of the original and the late LP's shares after the late deposit
    function _values() internal view returns (uint256 original, uint256 lateValue) {
        original = d.vault.convertToAssets(d.vault.balanceOf(lp));
        lateValue = d.vault.convertToAssets(d.vault.balanceOf(late));
    }

    /**
     * @notice A deposit at a 90% ratio does not take part of the injection meant for the LPs who carried the loss
     * @dev Round 3 rule: the deposit runs the pending injection first (here it covers the whole deficit, so no
     *      bonding round is due) and mints at the post-injection NAV of 1.0. Round 2b reverted the deposit instead.
     *      The deposit is a low-level call so the test runs to the end against every earlier rule.
     */
    function test_Regression_DepositBelowPar_InjectionSettledFirst() public {
        assertEq(d.vault.collateralizationRatio(), 0.9e18);

        vm.prank(late);
        (bool deposited,) = address(d.vault).call(abi.encodeCall(d.vault.deposit, (LP_DEPOSIT, late)));
        d.solvencyManager.checkAndAct();

        (uint256 original, uint256 lateValue) = _values();
        assertLe(lateValue, LP_DEPOSIT, "late LP captured part of the injection");
        assertTrue(deposited, "deposit reverted although the injection covers the deficit");
        assertEq(d.vault.collateralizationRatio(), 1e18, "injection did not restore 100%");
        assertEq(original, LP_DEPOSIT, "injection not credited to the original LP");
    }

    function test_Regression_MintBelowPar_InjectionSettledFirst() public {
        vm.prank(late);
        d.vault.mint(1_000 * 1e18, late);
        (uint256 original,) = _values();
        assertEq(original, LP_DEPOSIT, "injection not credited to the original LP");
    }

    function test_Regression_RefreshAndDepositBelowPar_InjectionSettledFirst() public {
        vm.prank(late);
        d.vault.refreshAndDeposit(1_000 * 10 ** 6, late, EMPTY);
        (uint256 original,) = _values();
        assertEq(original, LP_DEPOSIT, "injection not credited to the original LP");
    }

    function test_Regression_RefreshAndMintBelowPar_InjectionSettledFirst() public {
        vm.prank(late);
        d.vault.refreshAndMint(1_000 * 1e18, late, EMPTY);
        (uint256 original,) = _values();
        assertEq(original, LP_DEPOSIT, "injection not credited to the original LP");
    }

    /// @notice maxDeposit and maxMint stay open: the pending injection covers the realised deficit, so no round is due
    function test_Regression_MaxDepositAndMaxMintOpenWhenInjectionCoversDeficit() public view {
        assertEq(d.vault.maxDeposit(late), type(uint256).max, "maxDeposit closed although no round is due");
        assertEq(d.vault.maxMint(late), type(uint256).max, "maxMint closed although no round is due");
    }
}
