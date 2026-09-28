// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {TradingEngine} from "../../../src/TradingEngine.sol";
import {Vault} from "../../../src/Vault.sol";
import {AssistantFund} from "../../../src/AssistantFund.sol";
import {SolvencyManager} from "../../../src/SolvencyManager.sol";
import {BondDepository} from "../../../src/BondDepository.sol";
import {MockOracle} from "../../mocks/MockOracle.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

/**
 * @title LiquidityHandler
 * @author GushALKDev
 * @notice LP and environment side of the protocol invariant suite: deposits, withdrawal requests, executions
 *         and cancellations, epoch advances, time, price moves in both directions, pause and unpause, and the
 *         solvency actions (checkAndAct, bond, skim).
 * @dev Each flow into or out of the Vault is modelled before the call from the documented rules and recorded
 *      in a ghost variable; the measured amount is compared with the model (ghostMismatches).
 */
contract LiquidityHandler is CommonBase, StdCheats, StdUtils {
    TradingEngine public immutable ENGINE;
    Vault public immutable VAULT;
    MockOracle public immutable ORACLE;
    ERC20 public immutable USDC;
    AssistantFund public immutable ASSISTANT_FUND;
    SolvencyManager public immutable SOLVENCY_MANAGER;
    BondDepository public immutable BOND_DEPOSITORY;
    address public immutable OWNER;

    uint16 internal constant PAIR_INDEX = 0;
    uint128 public constant INITIAL_PRICE = 50_000 * 1e18;
    uint256 internal constant DEFICIT_CR = 1e18;

    address[] public actors;

    mapping(bytes32 => uint256) public calls;

    uint256 public ghostDeposits;
    uint256 public ghostWithdrawals;
    uint256 public ghostInjections;
    uint256 public ghostSkims;
    uint256 public ghostBondProceeds;
    uint256 public ghostMismatches;
    /// @notice Highest CR observed right after a rescue action (checkAndAct or bond) that raised the CR
    uint256 public ghostMaxCrAfterRescue;

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
    }

    /*//////////////////////////////////////////////////////////////
                              LP ACTIONS
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 _actorSeed, uint256 _assets) external countCall("deposit") {
        if (VAULT.paused()) return;
        address lp = _actor(_actorSeed);
        uint256 assets = bound(_assets, 1 * 10 ** 6, 100_000 * 10 ** 6);
        deal(address(USDC), lp, assets);
        vm.prank(lp);
        USDC.approve(address(VAULT), assets);
        vm.prank(lp);
        VAULT.deposit(assets, lp);
        ghostDeposits += assets;
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

    function executeWithdrawal(uint256 _actorSeed) external countCall("executeWithdrawal") {
        address lp = _actor(_actorSeed);
        if (!VAULT.canExecuteWithdrawal(lp)) return;
        (uint256 shares,) = VAULT.withdrawalRequests(lp);
        uint256 expected = VAULT.previewRedeem(shares);
        uint256 before = USDC.balanceOf(lp);
        vm.prank(lp);
        VAULT.executeWithdrawal();
        uint256 received = USDC.balanceOf(lp) - before;
        if (received != expected) ghostMismatches++;
        ghostWithdrawals += received;
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
     * @notice Move the oracle price up or down by up to 5% per call, kept within 60% to 140% of the start
     * @dev Steps up to 5% are larger than the 0.9% move that liquidates a 100x position, so some positions
     *      gap through 100% loss and exercise the bad-debt paths.
     */
    function movePrice(uint256 _stepBps, bool _up) external countCall("movePrice") {
        uint256 price = ORACLE.peekPrice(PAIR_INDEX);
        uint256 step = (price * bound(_stepBps, 1, 500)) / 10_000;
        price = _up ? price + step : price - step;
        uint256 lower = (uint256(INITIAL_PRICE) * 60) / 100;
        uint256 upper = (uint256(INITIAL_PRICE) * 140) / 100;
        if (price < lower) price = lower;
        if (price > upper) price = upper;
        ORACLE.setPrice(PAIR_INDEX, uint128(price));
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

    /// @notice Anyone runs the solvency check: reserve injection below 100% CR, bonding below 95%
    function checkAndAct() external countCall("checkAndAct") {
        uint256 crBefore = VAULT.collateralizationRatio();
        uint256 expectedInjection;
        if (crBefore < DEFICIT_CR) {
            uint256 deficit = VAULT.collateralizationDeficit();
            uint256 reserve = ASSISTANT_FUND.balance();
            expectedInjection = reserve < deficit ? reserve : deficit;
        }
        uint256 vaultBefore = USDC.balanceOf(address(VAULT));

        SOLVENCY_MANAGER.checkAndAct();

        if (USDC.balanceOf(address(VAULT)) - vaultBefore != expectedInjection) ghostMismatches++;
        ghostInjections += expectedInjection;
        _trackRescue(crBefore);
    }

    /// @notice A bonder buys into the open round, never above the remaining cap or the Vault deficit
    function bond(uint256 _actorSeed, uint256 _amount) external countCall("bond") {
        uint256 cap = BOND_DEPOSITORY.remainingCap();
        uint256 deficit = VAULT.collateralizationDeficit();
        uint256 available = deficit < cap ? deficit : cap;
        if (available == 0) return;

        address bonder = _actor(_actorSeed);
        uint256 amount = bound(_amount, 1 * 10 ** 6, 200_000 * 10 ** 6);
        uint256 expected = amount < available ? amount : available;
        uint256 crBefore = VAULT.collateralizationRatio();
        uint256 vaultBefore = USDC.balanceOf(address(VAULT));

        deal(address(USDC), bonder, amount);
        vm.prank(bonder);
        USDC.approve(address(BOND_DEPOSITORY), amount);
        vm.prank(bonder);
        BOND_DEPOSITORY.bond(amount);

        if (USDC.balanceOf(address(VAULT)) - vaultBefore != expected) ghostMismatches++;
        ghostBondProceeds += expected;
        _trackRescue(crBefore);
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

    function _actor(uint256 _seed) internal view returns (address) {
        return actors[bound(_seed, 0, actors.length - 1)];
    }

    function _trackRescue(uint256 _crBefore) internal {
        uint256 crAfter = VAULT.collateralizationRatio();
        if (crAfter > _crBefore && crAfter > ghostMaxCrAfterRescue) ghostMaxCrAfterRescue = crAfter;
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }
}
