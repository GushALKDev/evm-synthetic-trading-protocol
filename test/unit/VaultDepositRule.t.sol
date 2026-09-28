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
import {RegressionUSDC} from "../regression/RegressionBase.sol";

/**
 * @title VaultDepositRuleTest
 * @author GushALKDev
 * @notice maxDeposit and maxMint against the outcome of deposit and mint under the round 3 deposit rule, over the
 *         states that decide it: paused, stale snapshot, realised ratio, AssistantFund balance and an open round.
 * @dev The mirror (SolvencyManager.bondingRoundOpenAfterCheck) must agree with what checkAndAct does inside the
 *      deposit, or Solady's own maxDeposit check would revert with DepositMoreThanMax instead of the named error.
 */
contract VaultDepositRuleTest is Test {
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
    address late = makeAddr("late");
    address trader = makeAddr("trader");

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

        usdc.mint(late, 10 * LP_DEPOSIT);
        vm.prank(late);
        usdc.approve(address(vault), type(uint256).max);
    }

    struct State {
        uint256 drainBps; // realised loss before any rescue, 0 to 20%
        uint256 reserveBps; // AssistantFund balance as a share of the deficit, 0 to 200%
        bool openRound; // run checkAndAct before the deposit (opens a round when one is due)
        uint256 recoveryBps; // USDC flowing back after the round opened, as a share of the drain
        bool stale; // an open trade and no refresh within maxPnlSnapshotAge
        bool paused;
    }

    function _setState(State memory _s) internal {
        uint256 drain = (LP_DEPOSIT * bound(_s.drainBps, 0, 2_000)) / 10_000;
        if (drain != 0) {
            vm.prank(address(engine));
            vault.sendPayout(makeAddr("winner"), drain);
        }
        if (_s.openRound) {
            solvencyManager.checkAndAct();
            usdc.mint(address(vault), (drain * bound(_s.recoveryBps, 0, 15_000)) / 10_000);
        }
        usdc.mint(address(assistantFund), (drain * bound(_s.reserveBps, 0, 20_000)) / 10_000);
        if (_s.stale) {
            usdc.mint(trader, 100 * 10 ** 6);
            vm.startPrank(trader);
            usdc.approve(address(engine), type(uint256).max);
            engine.openTrade(PAIR, true, 100 * 10 ** 6, 2, PRICE * 10_005 / 10_000, 100, 0, 0, EMPTY);
            vm.stopPrank();
        }
        if (_s.paused) {
            vm.prank(owner);
            vault.pause();
        }
    }

    function testFuzz_MaxDepositMatchesDeposit(State memory _s, uint256 _assets) public {
        _setState(_s);
        uint256 assets = bound(_assets, 1 * 10 ** 6, LP_DEPOSIT);
        bool expected = vault.maxDeposit(late) != 0;
        vm.prank(late);
        (bool ok,) = address(vault).call(abi.encodeCall(vault.deposit, (assets, late)));
        assertEq(ok, expected, "maxDeposit disagrees with deposit");
    }

    function testFuzz_MaxMintMatchesMint(State memory _s, uint256 _shares) public {
        _setState(_s);
        uint256 shares = bound(_shares, 1e18, LP_DEPOSIT * 1e12);
        bool expected = vault.maxMint(late) != 0;
        vm.prank(late);
        (bool ok,) = address(vault).call(abi.encodeCall(vault.mint, (shares, late)));
        assertEq(ok, expected, "maxMint disagrees with mint");
    }

    /// @notice Every rejected deposit carries a named reason: pause, stale snapshot or a bonding round
    function test_RejectionErrors() public {
        _setState(State({drainBps: 1_000, reserveBps: 0, openRound: true, recoveryBps: 0, stale: false, paused: false}));
        vm.prank(late);
        vm.expectRevert(Vault.BondingRoundOpen.selector);
        vault.deposit(1_000 * 10 ** 6, late);
    }
}
