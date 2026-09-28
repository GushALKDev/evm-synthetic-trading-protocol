// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TradingEngine} from "../../src/TradingEngine.sol";
import {TradingStorage} from "../../src/TradingStorage.sol";
import {Vault} from "../../src/Vault.sol";
import {AssistantFund} from "../../src/AssistantFund.sol";
import {SolvencyManager} from "../../src/SolvencyManager.sol";
import {BondDepository} from "../../src/BondDepository.sol";
import {SynthToken} from "../../src/SynthToken.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {MockSpreadManager} from "../mocks/MockSpreadManager.sol";
import {RegressionUSDC} from "./RegressionBase.sol";

/**
 * @title SolvencySplitRegressionTest
 * @author GushALKDev
 * @notice Round 2b: once the coverage ratio includes unrealised trader profit, a move that can reverse must not
 *         sell discounted $SYNTH. The reserve injection follows the NAV ratio (with a fresh snapshot only);
 *         bonding opens, sizes, clamps and closes on the realised ratio (USDC balance per share).
 * @dev Full stack with MockOracle. 10,000 USDC at 100x on BTC is about 1,000,000 USD of long notional against
 *      a 1,000,000 USDC Vault, so a +8% move is about 80,000 USDC of unrealised trader profit. The new function
 *      refreshAndCheckAndAct is called with a low-level call so the file compiles before the change.
 */
contract SolvencySplitRegressionTest is Test {
    TradingEngine engine;
    TradingStorage tradingStorage;
    Vault vault;
    AssistantFund assistantFund;
    SolvencyManager solvencyManager;
    BondDepository bondDepository;
    RegressionUSDC usdc;
    MockOracle mockOracle;

    address owner = makeAddr("owner");
    address lp = makeAddr("lp");
    address trader = makeAddr("trader");
    address bonder = makeAddr("bonder");

    uint16 constant PAIR = 0;
    uint128 constant PRICE = 50_000 * 1e18;
    uint256 constant LP_DEPOSIT = 1_000_000 * 10 ** 6;
    bytes[] EMPTY;

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new RegressionUSDC();
        mockOracle = new MockOracle();
        mockOracle.setPrice(PAIR, PRICE);

        vm.startPrank(owner);
        tradingStorage = new TradingStorage(address(usdc), owner);
        vault = new Vault(address(usdc), owner, address(tradingStorage), address(mockOracle));
        assistantFund = new AssistantFund(address(usdc), address(vault), 1_000_000 * 10 ** 6, owner);
        SynthToken synth = new SynthToken(owner);
        bondDepository = new BondDepository(address(usdc), address(vault), address(synth), 500, owner);
        engine = new TradingEngine(
            address(tradingStorage), address(vault), address(mockOracle), address(usdc), address(assistantFund), address(new MockSpreadManager(5)), owner
        );
        solvencyManager = new SolvencyManager(address(vault), address(assistantFund), address(bondDepository), owner);
        tradingStorage.setTradingEngine(address(engine));
        vault.setTradingEngine(address(engine));
        vault.setSolvencyManager(address(solvencyManager));
        synth.setMinter(address(bondDepository));
        assistantFund.setSolvencyManager(address(solvencyManager));
        bondDepository.setSolvencyManager(address(solvencyManager));
        tradingStorage.addPair("BTC/USD", 100, 100_000_000 * 1e18);
        vm.stopPrank();

        usdc.mint(lp, LP_DEPOSIT);
        vm.startPrank(lp);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(LP_DEPOSIT, lp);
        vm.stopPrank();

        usdc.mint(trader, 10_000 * 10 ** 6);
        vm.prank(trader);
        usdc.approve(address(engine), type(uint256).max);
        vm.prank(trader);
        engine.openTrade(PAIR, true, 10_000 * 10 ** 6, 100, PRICE, 100, 0, 0, EMPTY);

        usdc.mint(bonder, 1_000_000 * 10 ** 6);
        vm.prank(bonder);
        usdc.approve(address(bondDepository), type(uint256).max);
    }

    function _setPriceAndRefresh(uint128 _price) internal {
        mockOracle.setPrice(PAIR, _price);
        vault.refreshPnlSnapshot(EMPTY);
    }

    /// @dev Winning traders take _amount of realised USDC out of the Vault
    function _drain(uint256 _amount) internal {
        vm.prank(address(engine));
        vault.sendPayout(makeAddr("winner"), _amount);
    }

    /**
     * @notice A reversible unrealised profit pushes the NAV ratio below 95%: the reserve is injected, bonding
     *         does not open
     * @dev Before the change bonding opened on the NAV ratio for the shortfall left after the injection.
     */
    function test_Regression_Solvency_UnrealisedTraderProfitInjectsButDoesNotBond() public {
        usdc.mint(address(assistantFund), 10_000 * 10 ** 6);
        _setPriceAndRefresh(54_000 * 1e18);
        assertLt(vault.collateralizationRatio(), 0.95e18, "setup: NAV ratio not below 95%");
        assertGe(vault.realisedCollateralizationRatio(), 0.95e18, "setup: realised ratio below 95%");

        solvencyManager.checkAndAct();

        assertEq(assistantFund.balance(), 0, "reserve not injected");
        assertFalse(bondDepository.isActive(), "bonding opened on an unrealised move");
    }

    /**
     * @notice A bond is clamped to the realised deficit, not to the larger NAV deficit
     * @dev Round opened at a realised ratio of about 90%; the Vault then recovers 40,000 USDC and traders hold an
     *      unrealised profit. Before the change bond() took min(cap, NAV deficit), which was the whole cap.
     */
    function test_Regression_Solvency_BondClampedToRealisedDeficit() public {
        _drain(100_000 * 10 ** 6);
        vault.refreshPnlSnapshot(EMPTY);
        solvencyManager.checkAndAct();
        assertTrue(bondDepository.isActive(), "setup: round not opened");
        uint256 cap = bondDepository.remainingCap();

        usdc.mint(address(vault), 40_000 * 10 ** 6); // realised trader losses
        _setPriceAndRefresh(54_000 * 1e18);
        uint256 realisedDeficit = vault.realisedCollateralizationDeficit();
        assertEq(realisedDeficit, cap - 40_000 * 10 ** 6, "setup: realised deficit");
        assertGt(vault.collateralizationDeficit(), cap, "setup: NAV deficit not above the cap");

        uint256 vaultBefore = usdc.balanceOf(address(vault));
        vm.prank(bonder);
        bondDepository.bond(1_000_000 * 10 ** 6);
        assertEq(usdc.balanceOf(address(vault)) - vaultBefore, realisedDeficit, "bond not clamped to the realised deficit");
    }

    /**
     * @notice An open round closes once the realised ratio is back at 100%, even if the NAV ratio is lower
     * @dev Before the change the round stayed open while the NAV ratio was below 100%, with nothing left to
     *      restore in realised terms.
     */
    function test_Regression_Solvency_RoundClosesOnRealisedRecovery() public {
        _drain(100_000 * 10 ** 6);
        vault.refreshPnlSnapshot(EMPTY);
        solvencyManager.checkAndAct();
        assertTrue(bondDepository.isActive(), "setup: round not opened");

        usdc.mint(address(vault), 110_000 * 10 ** 6);
        _setPriceAndRefresh(54_000 * 1e18);
        assertGe(vault.realisedCollateralizationRatio(), 1e18, "setup: realised ratio below 100%");
        assertLt(vault.collateralizationRatio(), 1e18, "setup: NAV ratio not below 100%");

        solvencyManager.checkAndAct();
        assertFalse(bondDepository.isActive(), "round still open after realised recovery");
    }

    /**
     * @notice A stale snapshot never drives an injection; refreshAndCheckAndAct values the book first
     * @dev The snapshot saw +8%, the price then went back to the open price and the snapshot aged past its
     *      limit. Before the change checkAndAct injected the reserve against the old profit.
     */
    function test_Regression_Solvency_StaleSnapshotDoesNotInject() public {
        usdc.mint(address(assistantFund), 10_000 * 10 ** 6);
        _setPriceAndRefresh(54_000 * 1e18);
        mockOracle.setPrice(PAIR, PRICE);
        vm.warp(block.timestamp + vault.maxPnlSnapshotAge() + 1);
        assertLt(vault.collateralizationRatio(), 1e18, "setup: stale NAV ratio not below 100%");
        uint256 reserve = assistantFund.balance();

        solvencyManager.checkAndAct();
        assertEq(assistantFund.balance(), reserve, "injected against a stale snapshot");

        (bool ok,) = address(solvencyManager).call(abi.encodeWithSignature("refreshAndCheckAndAct(bytes[])", EMPTY));
        assertTrue(ok, "refreshAndCheckAndAct failed");
        assertGe(vault.collateralizationRatio(), 1e18, "refreshed NAV ratio below 100%");
        assertEq(assistantFund.balance(), reserve, "injected with the NAV ratio at 100%");
    }
}
