// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {DeployLib, DeployConfig, Deployed} from "../../script/Deploy.s.sol";
import {SolvencyManager} from "../../src/SolvencyManager.sol";
import {BondDepository} from "../../src/BondDepository.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {MockSpreadManager} from "../mocks/MockSpreadManager.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

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

/**
 * @title SolvencyIntegrationTest
 * @author GushALKDev
 * @notice End-to-end tests of the 3-layer solvency system against the REAL contracts, deployed and
 *         wired exactly as `script/Deploy.s.sol` does in production.
 * @dev The unit suites test each solvency contract against mocks (`SolvencyManager` in particular
 *      uses a MockVault), so nothing there proves the layers actually compose. These tests drive the
 *      full path: Vault drained by trader payouts → SolvencyManager reads the real CR → AssistantFund
 *      injects → BondDepository opens a round → bonders recapitalize → CR restored.
 */
contract SolvencyIntegrationTest is Test {
    Deployed d;
    MockUSDC usdc;

    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address lp = makeAddr("lp");
    address winner = makeAddr("winner");
    address bonder = makeAddr("bonder");

    uint256 constant LP_DEPOSIT = 1_000_000 * 10 ** 6;
    uint256 constant WAD = 1e18;

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockUSDC();

        DeployConfig memory cfg = DeployConfig({
            asset: address(usdc),
            pyth: makeAddr("pyth"), // never called: these tests do not price trades
            owner: owner,
            keeper: keeper,
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

        // Seed LP liquidity: the Vault starts fully collateralized at 100%
        usdc.mint(lp, LP_DEPOSIT);
        vm.startPrank(lp);
        usdc.approve(address(d.vault), type(uint256).max);
        d.vault.deposit(LP_DEPOSIT, lp);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                WIRING
    //////////////////////////////////////////////////////////////*/

    function test_Deploy_WiresEveryPermission() public view {
        assertEq(d.tradingStorage.tradingEngine(), address(d.engine), "storage engine");
        assertEq(d.vault.tradingEngine(), address(d.engine), "vault engine");
        assertEq(d.synth.minter(), address(d.bondDepository), "synth minter");
        assertEq(d.assistantFund.solvencyManager(), address(d.solvencyManager), "fund manager");
        assertEq(d.bondDepository.solvencyManager(), address(d.solvencyManager), "bond manager");
    }

    /// @dev The fee split only funds the reserve if treasury points at the AssistantFund
    function test_Deploy_TreasuryIsAssistantFund() public view {
        assertEq(d.engine.treasury(), address(d.assistantFund), "treasury must be the AssistantFund");
    }

    /*//////////////////////////////////////////////////////////////
                            HEALTHY / WARNING
    //////////////////////////////////////////////////////////////*/

    function test_Healthy_CheckAndActIsNoop() public {
        assertEq(d.vault.collateralizationRatio(), WAD);

        uint256 vaultBefore = usdc.balanceOf(address(d.vault));
        d.solvencyManager.checkAndAct();

        assertEq(usdc.balanceOf(address(d.vault)), vaultBefore, "vault touched while healthy");
        assertFalse(d.bondDepository.isActive(), "bonding opened while healthy");
    }

    /// @dev Between DEFICIT_CR (100%) and SAFE_CR (110%) the manager warns but must not spend reserve
    function test_Warning_DoesNotInject() public {
        usdc.mint(address(d.assistantFund), 50_000 * 10 ** 6);
        // Trading fees landing in the Vault put CR at 103%: above target, below "safe"
        usdc.mint(address(d.vault), 30_000 * 10 ** 6);

        uint256 cr = d.vault.collateralizationRatio();
        assertGt(cr, WAD, "not above DEFICIT_CR");
        assertLt(cr, d.solvencyManager.SAFE_CR(), "not below SAFE_CR");

        uint256 reserveBefore = d.assistantFund.balance();
        d.solvencyManager.checkAndAct();
        assertEq(d.assistantFund.balance(), reserveBefore, "reserve spent while above 100%");
    }

    /*//////////////////////////////////////////////////////////////
                        LAYER 2: RESERVE INJECTION
    //////////////////////////////////////////////////////////////*/

    /// @dev CR between 95% and 100%: the reserve covers it and bonding must NOT open
    function test_Deficit_ReserveCoversWithoutBonding() public {
        usdc.mint(address(d.assistantFund), 50_000 * 10 ** 6);
        _drain(20_000 * 10 ** 6); // CR = 98%

        uint256 deficit = d.solvencyManager.deficitToTarget();
        d.solvencyManager.checkAndAct();

        assertApproxEqAbs(d.vault.collateralizationRatio(), WAD, 1e12, "CR not restored to ~100%");
        assertFalse(d.bondDepository.isActive(), "bonding opened while reserve sufficed");
        assertEq(d.assistantFund.balance(), 50_000 * 10 ** 6 - deficit, "wrong amount drawn from reserve");
    }

    function test_Deficit_EmitsReserveInjected() public {
        usdc.mint(address(d.assistantFund), 50_000 * 10 ** 6);
        _drain(20_000 * 10 ** 6);

        uint256 cr = d.vault.collateralizationRatio();
        uint256 deficit = d.solvencyManager.deficitToTarget();

        vm.expectEmit(false, false, false, true);
        emit SolvencyManager.ReserveInjected(cr, deficit);
        d.solvencyManager.checkAndAct();
    }

    /*//////////////////////////////////////////////////////////////
                          LAYER 3: BONDING
    //////////////////////////////////////////////////////////////*/

    /// @dev CR below 95% with an empty reserve: bonding opens for the whole deficit
    function test_Critical_EmptyReserveOpensBondingForFullDeficit() public {
        _drain(100_000 * 10 ** 6); // CR = 90%

        uint256 deficit = d.solvencyManager.deficitToTarget();
        d.solvencyManager.checkAndAct();

        assertTrue(d.bondDepository.isActive(), "bonding not activated at critical CR");
        assertEq(d.bondDepository.remainingCap(), deficit, "round cap != deficit");
    }

    /// @dev Reserve absorbs part, bonding covers the remaining shortfall
    function test_Critical_ReservePartiallyCoversThenBonds() public {
        usdc.mint(address(d.assistantFund), 20_000 * 10 ** 6);
        _drain(100_000 * 10 ** 6); // CR = 90%

        uint256 deficit = d.solvencyManager.deficitToTarget();
        d.solvencyManager.checkAndAct();

        assertEq(d.assistantFund.balance(), 0, "reserve not fully drawn");
        assertTrue(d.bondDepository.isActive(), "bonding not activated for shortfall");
        assertEq(d.bondDepository.remainingCap(), deficit - 20_000 * 10 ** 6, "cap != remaining shortfall");
    }

    /// @dev The whole point of Layer 3: bonding actually restores the Vault to 100%
    function test_FullCycle_BondingRestoresSolvency() public {
        usdc.mint(address(d.assistantFund), 20_000 * 10 ** 6);
        _drain(100_000 * 10 ** 6);

        d.solvencyManager.checkAndAct();
        uint256 cap = d.bondDepository.remainingCap();

        _bond(bonder, cap);

        assertGe(d.vault.collateralizationRatio(), WAD, "vault not restored to 100%");
        assertFalse(d.bondDepository.isActive(), "round did not close when cap was exhausted");
        // The bonder holds a vesting position, not loose tokens
        assertEq(d.synth.balanceOf(bonder), 0, "SYNTH released before vesting");
        assertEq(d.bondDepository.bondCount(bonder), 1, "no vesting position created");
    }

    /// @dev Bonded SYNTH vests linearly and is fully claimable at the end of the window
    function test_FullCycle_BonderClaimsAfterVesting() public {
        _drain(100_000 * 10 ** 6);
        d.solvencyManager.checkAndAct();

        uint256 cap = d.bondDepository.remainingCap();
        (, uint256 synthOut) = _bond(bonder, cap);

        vm.warp(block.timestamp + d.bondDepository.vestingPeriod());
        vm.prank(bonder);
        uint256 claimed = d.bondDepository.claim(0);

        assertEq(claimed, synthOut, "did not vest the full amount");
        assertEq(d.synth.balanceOf(bonder), synthOut, "SYNTH not delivered");
    }

    /// @dev A second checkAndAct must not stack rounds while one is already open
    function test_Critical_DoesNotOpenSecondRound() public {
        _drain(100_000 * 10 ** 6);
        d.solvencyManager.checkAndAct();
        uint256 cap = d.bondDepository.remainingCap();

        d.solvencyManager.checkAndAct(); // second call, same critical state
        assertEq(d.bondDepository.remainingCap(), cap, "a second round was opened");
    }

    /*//////////////////////////////////////////////////////////////
                          TOTAL INSOLVENCY
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Regression: a fully drained Vault (totalAssets == 0 with shares outstanding) makes CR == 0.
     *      The deficit used to be computed as `totalAssets * (WAD - cr) / cr`, which panicked (0x12)
     *      on that exact state — the rescue was uncallable precisely when it was most needed.
     */
    function test_TotalInsolvency_RescueStillCallable() public {
        _drain(usdc.balanceOf(address(d.vault))); // drain everything

        assertEq(d.vault.totalAssets(), 0, "vault not drained");
        assertEq(d.vault.collateralizationRatio(), 0, "CR should be zero");

        // Must not revert, and must size the round to the full nominal liability
        d.solvencyManager.checkAndAct();

        assertTrue(d.bondDepository.isActive(), "bonding not opened on total insolvency");
        assertEq(d.bondDepository.remainingCap(), LP_DEPOSIT, "round cap != full deposit basis");
    }

    function test_TotalInsolvency_DeficitEqualsNominalLiabilities() public {
        _drain(usdc.balanceOf(address(d.vault)));
        assertEq(d.solvencyManager.deficitToTarget(), LP_DEPOSIT, "deficit != nominal liabilities");
    }

    /// @dev Bonding can fully recapitalize even from zero assets
    function test_TotalInsolvency_BondingRestoresFromZero() public {
        _drain(usdc.balanceOf(address(d.vault)));
        d.solvencyManager.checkAndAct();

        _bond(bonder, d.bondDepository.remainingCap());
        assertGe(d.vault.collateralizationRatio(), WAD, "not restored from total insolvency");
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev Whatever the drain and reserve, checkAndAct never reverts nor leaves the Vault worse off
    function testFuzz_CheckAndAct_NeverWorsensCR(uint256 _drainAmount, uint256 _reserve) public {
        // Upper bound is the FULL deposit: the rescue must survive total insolvency, not just a dip
        uint256 drainAmount = bound(_drainAmount, 1 * 10 ** 6, LP_DEPOSIT);
        uint256 reserve = bound(_reserve, 0, 200_000 * 10 ** 6);

        if (reserve > 0) usdc.mint(address(d.assistantFund), reserve);
        _drain(drainAmount);

        uint256 crBefore = d.vault.collateralizationRatio();
        d.solvencyManager.checkAndAct();
        uint256 crAfter = d.vault.collateralizationRatio();

        assertGe(crAfter, crBefore, "CR decreased after a rescue");
        assertLe(crAfter, WAD + 1e12, "rescue overshot past 100%");
    }

    /// @dev The reserve is never drawn beyond the deficit, nor beyond what it holds
    function testFuzz_Injection_BoundedByDeficitAndReserve(uint256 _drainAmount, uint256 _reserve) public {
        uint256 drainAmount = bound(_drainAmount, 1 * 10 ** 6, LP_DEPOSIT / 2);
        uint256 reserve = bound(_reserve, 0, 200_000 * 10 ** 6);

        if (reserve > 0) usdc.mint(address(d.assistantFund), reserve);
        _drain(drainAmount);

        uint256 deficit = d.solvencyManager.deficitToTarget();
        d.solvencyManager.checkAndAct();

        uint256 injected = reserve - d.assistantFund.balance();
        assertLe(injected, reserve, "drew more than the reserve held");
        assertLe(injected, deficit, "drew more than the deficit required");
    }

    /// @dev Bonding a full round always restores the Vault to at least 100%
    function testFuzz_Bonding_AlwaysRestoresToTarget(uint256 _drainAmount) public {
        // Lower bound puts CR at 94% — always under CRITICAL_CR (95%), so bonding always opens
        uint256 drainAmount = bound(_drainAmount, 60_000 * 10 ** 6, LP_DEPOSIT / 2);
        _drain(drainAmount);

        d.solvencyManager.checkAndAct();
        assertTrue(d.bondDepository.isActive(), "bonding did not open below critical CR");

        _bond(bonder, d.bondDepository.remainingCap());
        assertGe(d.vault.collateralizationRatio(), WAD, "full round did not restore solvency");
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Simulate winning traders being paid out of the Vault, which is what drops CR
    function _drain(uint256 _amount) internal {
        vm.prank(address(d.engine));
        d.vault.sendPayout(winner, _amount);
    }

    function _bond(address _bonder, uint256 _usdcAmount) internal returns (uint256 bondId, uint256 synthOut) {
        usdc.mint(_bonder, _usdcAmount);
        vm.startPrank(_bonder);
        usdc.approve(address(d.bondDepository), _usdcAmount);
        (bondId, synthOut) = d.bondDepository.bond(_usdcAmount);
        vm.stopPrank();
    }
}
