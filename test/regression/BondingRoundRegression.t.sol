// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployLib, DeployConfig, Deployed} from "../../script/Deploy.s.sol";
import {BondDepository} from "../../src/BondDepository.sol";
import {RegressionUSDC} from "./RegressionBase.sol";

/**
 * @title BondingRoundRegressionTest
 * @author GushALKDev
 * @notice Round 1 finding: a bonding round only closed when its cap was exhausted, so after the Vault
 *         recovered by other means (trader losses, fees, reserve) bonders could keep buying discounted
 *         $SYNTH for a deficit that no longer existed.
 * @dev Runs on the wired deployment from DeployLib. Close condition: the round is open while its remaining
 *      cap and the Vault's collateralization deficit are both non-zero; bond() takes at most the current
 *      deficit, and checkAndAct closes the round once CR is back at 100% (DEFICIT_CR).
 */
contract BondingRoundRegressionTest is Test {
    Deployed d;
    RegressionUSDC usdc;

    address owner = makeAddr("owner");
    address lp = makeAddr("lp");
    address winner = makeAddr("winner");
    address bonder = makeAddr("bonder");

    uint256 constant LP_DEPOSIT = 1_000_000 * 10 ** 6;
    uint256 constant DRAIN = 100_000 * 10 ** 6; // CR 90%, below the 95% bonding threshold

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

        // Winning traders drain the Vault to 90% CR; with an empty reserve, checkAndAct opens a round
        vm.prank(address(d.engine));
        d.vault.sendPayout(winner, DRAIN);
        d.solvencyManager.checkAndAct();
        assertTrue(d.bondDepository.isActive(), "round not opened");

        usdc.mint(bonder, 1_000_000 * 10 ** 6);
        vm.prank(bonder);
        usdc.approve(address(d.bondDepository), type(uint256).max);
    }

    /// @dev Trader losses flowing into the Vault, which is how CR recovers without bonding
    function _recover(uint256 _amount) internal {
        usdc.mint(address(d.vault), _amount);
    }

    /// @notice Once CR is back at 100%, bonding into the stale round reverts
    function test_Regression_BondingRound_NoBondAfterRecovery() public {
        _recover(DRAIN);
        assertEq(d.vault.collateralizationDeficit(), 0);

        vm.prank(bonder);
        vm.expectRevert(BondDepository.NoActiveRound.selector);
        d.bondDepository.bond(1_000 * 10 ** 6);
    }

    /// @notice checkAndAct closes the round when CR has recovered to 100%
    function test_Regression_BondingRound_CheckAndActClosesRoundAfterRecovery() public {
        _recover(DRAIN);
        d.solvencyManager.checkAndAct();
        assertFalse(d.bondDepository.isActive(), "round still open after recovery");
        assertEq(d.bondDepository.remainingCap(), 0);
    }

    /// @notice A bond never raises more than the current deficit, and the bond that covers it closes the round
    function test_Regression_BondingRound_BondClampedToCurrentDeficit() public {
        _recover(60_000 * 10 ** 6); // deficit down to 40,000 USDC while the round cap is still 100,000
        uint256 vaultBefore = usdc.balanceOf(address(d.vault));

        vm.prank(bonder);
        d.bondDepository.bond(100_000 * 10 ** 6);

        assertEq(usdc.balanceOf(address(d.vault)) - vaultBefore, 40_000 * 10 ** 6, "raised more than the deficit");
        assertEq(d.vault.collateralizationRatio(), 1e18, "CR not exactly 100%");
        assertFalse(d.bondDepository.isActive(), "round still open at 100% CR");
    }
}
