// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {TradingEngine} from "../../../src/TradingEngine.sol";
import {Vault} from "../../../src/Vault.sol";
import {AssistantFund} from "../../../src/AssistantFund.sol";
import {SolvencyManager} from "../../../src/SolvencyManager.sol";
import {BondDepository} from "../../../src/BondDepository.sol";
import {MockOracle} from "../../mocks/MockOracle.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {IMintableUSDC} from "./IMintableUSDC.sol";

/**
 * @title LiquidityHandler
 * @author GushALKDev
 * @notice LP and environment side of the protocol invariant suite: deposits, withdrawal requests, executions
 *         and cancellations, epoch advances, time, price moves in both directions, pause and unpause, and the
 *         solvency actions (checkAndAct, bond, skim).
 * @dev Each flow into or out of the Vault is modelled before the call from the documented rules and recorded
 *      in a ghost variable; the measured amount is compared with the model (ghostMismatches).
 *      deposit, executeWithdrawal and checkAndAct take a mode seed: 0 acts on the current snapshot (possibly
 *      stale), 1 refreshes the snapshot first, 2 goes through the refresh-and-act entry point. Deposits and
 *      executions are wrapped in try/catch so the handler can count what succeeded against the rules: an
 *      unexpected revert is a mismatch; an expected one (paused, stale snapshot, ratio below 100%, nothing to
 *      execute) ends the call with NotExecuted, so in the forge metrics table calls - reverts is the number of
 *      deposits and executions that went through.
 */
contract LiquidityHandler is CommonBase, StdUtils {
    TradingEngine public immutable ENGINE;
    Vault public immutable VAULT;
    MockOracle public immutable ORACLE;
    ERC20 public immutable USDC;
    AssistantFund public immutable ASSISTANT_FUND;
    SolvencyManager public immutable SOLVENCY_MANAGER;
    BondDepository public immutable BOND_DEPOSITORY;
    address public immutable OWNER;

    uint256 public constant PAIRS = 3;
    uint256 internal constant MAX_CONF_BPS = 200; // the real oracle rejects a confidence band above 2% of the price
    /// @notice Oracle price of each pair when the handler was deployed; moves stay within 60% to 140% of it
    uint128[PAIRS] public initialPrices;
    uint256 internal constant DEFICIT_CR = 1e18;
    uint256 internal constant CRITICAL_CR = 95e16;

    bytes[] internal EMPTY_UPDATE;

    address[] public actors;

    mapping(bytes32 => uint256) public calls;

    uint256 public ghostDeposits;
    uint256 public ghostWithdrawals;
    uint256 public ghostInjections;
    uint256 public ghostSkims;
    uint256 public ghostBondProceeds;
    uint256 public ghostMismatches;
    /// @notice Highest NAV ratio right after a checkAndAct that raised it (an injection)
    uint256 public ghostMaxNavCrAfterInjection;
    /// @notice Highest realised ratio right after a bond that raised it
    uint256 public ghostMaxRealisedCrAfterBond;

    uint256 public ghostDepositCount;
    uint256 public ghostWithdrawalCount;
    /// @notice Deposits that went through while a bonding round was open afterwards
    uint256 public ghostDepositsDuringBonding;
    /// @notice Deposits that did not inject exactly the AssistantFund injection pending before the call
    uint256 public ghostDepositsWithPendingInjection;
    /// @notice Deposits whose minted shares were worth more than the assets paid in
    uint256 public ghostDepositsOverValued;
    /// @notice Deposits or withdrawal executions that succeeded on a stale snapshot
    uint256 public ghostStaleActions;
    /// @notice Bonding rounds opened while the realised ratio was at or above CRITICAL_CR
    uint256 public ghostBondingAboveCritical;

    /// @dev The action was rejected for a documented reason or had nothing to do
    error NotExecuted();

    modifier countCall(bytes32 _key) {
        calls[_key]++;
        _;
    }

    constructor(
        TradingEngine _engine,
        Vault _vault,
        MockOracle _oracle,
        ERC20 _usdc,
        AssistantFund _assistantFund,
        SolvencyManager _solvencyManager,
        BondDepository _bondDepository,
        address _owner,
        address[] memory _actors
    ) {
        ENGINE = _engine;
        VAULT = _vault;
        ORACLE = _oracle;
        USDC = _usdc;
        ASSISTANT_FUND = _assistantFund;
        SOLVENCY_MANAGER = _solvencyManager;
        BOND_DEPOSITORY = _bondDepository;
        OWNER = _owner;
        actors = _actors;
        for (uint256 i; i < PAIRS; ++i) {
            initialPrices[i] = _oracle.peekPrice(i);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              LP ACTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice An LP deposits. The Vault runs the pending AssistantFund injection first and refuses on a stale
     *         snapshot or while a bonding round is open or due; the outcome must match maxDeposit
     * @dev The injection made inside the deposit is recorded like one from checkAndAct.
     */
    function deposit(uint256 _actorSeed, uint256 _assets, uint256 _mode) external countCall("deposit") {
        if (VAULT.paused()) revert NotExecuted();
        address lp = _actor(_actorSeed);
        uint256 assets = bound(_assets, 1 * 10 ** 6, 100_000 * 10 ** 6);
        _mode %= 3;
        if (_mode != 0) VAULT.refreshPnlSnapshot(EMPTY_UPDATE);
        bool fresh = VAULT.isPnlSnapshotFresh();
        bool expected = VAULT.maxDeposit(lp) != 0;
        uint256 reserveBefore = ASSISTANT_FUND.balance();
        uint256 pending = _pendingInjection(fresh);
        uint256 sharesBefore = VAULT.balanceOf(lp);
        IMintableUSDC(address(USDC)).mint(lp, assets);
        vm.prank(lp);
        USDC.approve(address(VAULT), assets);

        bool ok;
        vm.prank(lp);
        if (_mode == 2) {
            try VAULT.refreshAndDeposit(assets, lp, EMPTY_UPDATE) {
                ok = true;
            } catch {}
        } else {
            try VAULT.deposit(assets, lp) {
                ok = true;
            } catch {}
        }
        if (!ok) {
            if (expected) {
                ghostMismatches++;
                return;
            }
            revert NotExecuted();
        }
        if (!expected) ghostMismatches++;
        if (!fresh) ghostStaleActions++;
        if (BOND_DEPOSITORY.isActive()) ghostDepositsDuringBonding++;
        if (reserveBefore - ASSISTANT_FUND.balance() != pending) ghostDepositsWithPendingInjection++;
        if (VAULT.convertToAssets(VAULT.balanceOf(lp) - sharesBefore) > assets) ghostDepositsOverValued++;
        ghostInjections += reserveBefore - ASSISTANT_FUND.balance();
        ghostDeposits += assets;
        ghostDepositCount++;
    }

    /// @notice Request a withdrawal of a fraction of the LP's shares (replaces any pending request)
    function requestWithdrawal(uint256 _actorSeed, uint256 _bps) external countCall("requestWithdrawal") {
        if (VAULT.paused()) return;
        address lp = _actor(_actorSeed);
        (uint256 escrowed,) = VAULT.withdrawalRequests(lp);
        uint256 shares = ((VAULT.balanceOf(lp) + escrowed) * bound(_bps, 1, 10_000)) / 10_000;
        if (shares == 0) return;
        vm.prank(lp);
        VAULT.requestWithdrawal(shares);
    }

    /// @notice An LP executes an unlocked request; succeeds only with a fresh snapshot, paid at the NAV
    function executeWithdrawal(uint256 _actorSeed, uint256 _mode) external countCall("executeWithdrawal") {
        address lp = _actor(_actorSeed);
        if (!VAULT.canExecuteWithdrawal(lp)) revert NotExecuted();
        _mode %= 3;
        if (_mode != 0) VAULT.refreshPnlSnapshot(EMPTY_UPDATE);
        bool fresh = VAULT.isPnlSnapshotFresh();
        (uint256 shares,) = VAULT.withdrawalRequests(lp);
        uint256 expected = VAULT.previewRedeem(shares);
        uint256 before = USDC.balanceOf(lp);

        bool ok;
        vm.prank(lp);
        if (_mode == 2) {
            try VAULT.refreshAndExecuteWithdrawal(EMPTY_UPDATE) {
                ok = true;
            } catch {}
        } else {
            try VAULT.executeWithdrawal() {
                ok = true;
            } catch {}
        }
        if (!ok) {
            if (fresh) {
                ghostMismatches++;
                return;
            }
            revert NotExecuted();
        }
        if (!fresh) ghostStaleActions++;
        uint256 received = USDC.balanceOf(lp) - before;
        if (received != expected) ghostMismatches++;
        ghostWithdrawals += received;
        ghostWithdrawalCount++;
    }

    function cancelWithdrawal(uint256 _actorSeed) external countCall("cancelWithdrawal") {
        address lp = _actor(_actorSeed);
        (uint256 shares,) = VAULT.withdrawalRequests(lp);
        if (shares == 0) return;
        vm.prank(lp);
        VAULT.cancelWithdrawal();
    }

    /*//////////////////////////////////////////////////////////////
                            ENVIRONMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Advance exactly one withdrawal epoch
    function advanceEpoch() external countCall("advanceEpoch") {
        vm.warp(block.timestamp + VAULT.EPOCH_LENGTH());
    }

    /// @notice Advance between one minute and one day, so funding accrues between actions
    function warp(uint256 _seconds) external countCall("warp") {
        vm.warp(block.timestamp + bound(_seconds, 1 minutes, 1 days));
    }

    /**
     * @notice Move one pair's oracle price up or down by up to 5% per call, kept within 60% to 140% of its start,
     *         and set its confidence band to 0% to 2% of the new price
     * @dev Steps up to 5% are larger than the 0.9% move that liquidates a 100x position, so some positions
     *      gap through 100% loss and exercise the bad-debt paths. The 2% band cap is the real oracle's.
     */
    function movePrice(uint256 _pairSeed, uint256 _stepBps, bool _up, uint256 _confBps) external countCall("movePrice") {
        uint256 pair = bound(_pairSeed, 0, PAIRS - 1);
        uint256 price = ORACLE.peekPrice(pair);
        uint256 step = (price * bound(_stepBps, 1, 500)) / 10_000;
        price = _up ? price + step : price - step;
        uint256 lower = (uint256(initialPrices[pair]) * 60) / 100;
        uint256 upper = (uint256(initialPrices[pair]) * 140) / 100;
        if (price < lower) price = lower;
        if (price > upper) price = upper;
        ORACLE.setPrice(pair, uint128(price));
        ORACLE.setConf(pair, uint128((price * bound(_confBps, 0, MAX_CONF_BPS)) / 10_000));
    }

    /**
     * @notice Pause or unpause the engine or the Vault
     * @dev Unpauses whenever the target is paused, pauses only one call in four, so most of a run is live.
     */
    function togglePause(uint256 _seed) external countCall("togglePause") {
        bool engine = _seed % 2 == 0;
        bool isPaused = engine ? ENGINE.paused() : VAULT.paused();
        if (!isPaused && _seed % 8 >= 2) return;
        vm.startPrank(OWNER);
        if (engine) isPaused ? ENGINE.unpause() : ENGINE.pause();
        else isPaused ? VAULT.unpause() : VAULT.pause();
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                           SOLVENCY ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Anyone runs the solvency check: reserve injection below a 100% NAV ratio with a fresh snapshot,
    ///         bonding below a 95% realised ratio
    function checkAndAct(uint256 _mode) external countCall("checkAndAct") {
        _mode %= 3;
        if (_mode != 0) VAULT.refreshPnlSnapshot(EMPTY_UPDATE);
        uint256 crBefore = VAULT.collateralizationRatio();
        uint256 realisedBefore = VAULT.realisedCollateralizationRatio();
        bool activeBefore = BOND_DEPOSITORY.isActive();
        uint256 expectedInjection;
        if (crBefore < DEFICIT_CR && VAULT.isPnlSnapshotFresh()) {
            uint256 deficit = VAULT.collateralizationDeficit();
            uint256 reserve = ASSISTANT_FUND.balance();
            expectedInjection = reserve < deficit ? reserve : deficit;
        }
        uint256 vaultBefore = USDC.balanceOf(address(VAULT));

        if (_mode == 2) SOLVENCY_MANAGER.refreshAndCheckAndAct(EMPTY_UPDATE);
        else SOLVENCY_MANAGER.checkAndAct();

        if (USDC.balanceOf(address(VAULT)) - vaultBefore != expectedInjection) ghostMismatches++;
        if (!activeBefore && BOND_DEPOSITORY.isActive() && realisedBefore >= CRITICAL_CR) ghostBondingAboveCritical++;
        ghostInjections += expectedInjection;
        uint256 crAfter = VAULT.collateralizationRatio();
        if (crAfter > crBefore && crAfter > ghostMaxNavCrAfterInjection) ghostMaxNavCrAfterInjection = crAfter;
    }

    /// @notice A bonder buys into the open round, never above the remaining cap or the Vault realised deficit
    function bond(uint256 _actorSeed, uint256 _amount) external countCall("bond") {
        uint256 cap = BOND_DEPOSITORY.remainingCap();
        uint256 deficit = VAULT.realisedCollateralizationDeficit();
        uint256 available = deficit < cap ? deficit : cap;
        if (available == 0) return;

        address bonder = _actor(_actorSeed);
        uint256 amount = bound(_amount, 1 * 10 ** 6, 200_000 * 10 ** 6);
        uint256 expected = amount < available ? amount : available;
        uint256 realisedBefore = VAULT.realisedCollateralizationRatio();
        uint256 vaultBefore = USDC.balanceOf(address(VAULT));

        IMintableUSDC(address(USDC)).mint(bonder, amount);
        vm.prank(bonder);
        USDC.approve(address(BOND_DEPOSITORY), amount);
        vm.prank(bonder);
        BOND_DEPOSITORY.bond(amount);

        if (USDC.balanceOf(address(VAULT)) - vaultBefore != expected) ghostMismatches++;
        ghostBondProceeds += expected;
        uint256 realisedAfter = VAULT.realisedCollateralizationRatio();
        if (realisedAfter > realisedBefore && realisedAfter > ghostMaxRealisedCrAfterBond) ghostMaxRealisedCrAfterBond = realisedAfter;
    }

    /// @notice Anyone sends the reserve above the target cap to the Vault
    function skim() external countCall("skim") {
        uint256 reserve = ASSISTANT_FUND.balance();
        uint256 cap = ASSISTANT_FUND.targetCap();
        uint256 expected = reserve > cap ? reserve - cap : 0;
        uint256 vaultBefore = USDC.balanceOf(address(VAULT));
        ASSISTANT_FUND.skim();
        if (USDC.balanceOf(address(VAULT)) - vaultBefore != expected) ghostMismatches++;
        ghostSkims += expected;
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Injection checkAndAct would make now: min(reserve, NAV deficit) below a 100% NAV ratio with a fresh snapshot
    function _pendingInjection(bool _fresh) internal view returns (uint256) {
        if (!_fresh || VAULT.collateralizationRatio() >= DEFICIT_CR) return 0;
        uint256 deficit = VAULT.collateralizationDeficit();
        uint256 reserve = ASSISTANT_FUND.balance();
        return reserve < deficit ? reserve : deficit;
    }

    function _actor(uint256 _seed) internal view returns (address) {
        return actors[bound(_seed, 0, actors.length - 1)];
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }
}
