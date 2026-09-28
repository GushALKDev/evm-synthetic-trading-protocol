// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {TradingEngine} from "../../src/TradingEngine.sol";
import {TradingStorage} from "../../src/TradingStorage.sol";
import {Vault} from "../../src/Vault.sol";
import {AssistantFund} from "../../src/AssistantFund.sol";
import {SolvencyManager} from "../../src/SolvencyManager.sol";
import {BondDepository} from "../../src/BondDepository.sol";
import {SynthToken} from "../../src/SynthToken.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {MockSpreadManager} from "../mocks/MockSpreadManager.sol";
import {ProtocolHandler} from "./handlers/ProtocolHandler.sol";
import {LiquidityHandler} from "./handlers/LiquidityHandler.sol";
import {OpenPnlLib} from "../../src/libraries/OpenPnlLib.sol";
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
 * @title ProtocolInvariantTest
 * @author GushALKDev
 * @notice Stateful invariants over the whole protocol with MockOracle and MockSpreadManager: trading,
 *         LP deposits and withdrawals, the AssistantFund as treasury, the SolvencyManager and bonding.
 * @dev Two handlers drive the system: ProtocolHandler (trading on three pairs, with a settlement model, target
 *      selection and PnL snapshot refreshes checked against a brute-force valuation) and LiquidityHandler (LP
 *      flows with and without a snapshot refresh, time, price moves in both directions with a confidence band of
 *      0% to 2%, the four pause flags, solvency actions). The Vault starts with 1,000,000 USDC from an LP that never withdraws.
 *      ProtocolKeeperLatencyInvariantTest runs the same invariants with a one-day keeper latency.
 */
contract ProtocolInvariantTest is StdInvariant, Test {
    TradingEngine engine;
    TradingStorage tradingStorage;
    Vault vault;
    AssistantFund assistantFund;
    SolvencyManager solvencyManager;
    BondDepository bondDepository;
    SynthToken synth;
    MockUSDC usdc;
    MockOracle oracle;
    ProtocolHandler handler;
    LiquidityHandler liquidity;

    address owner = makeAddr("owner");
    address lp = makeAddr("lp");

    uint256 constant SEED = 1_000_000 * 10 ** 6;

    function setUp() public {
        vm.warp(1_000_000);

        usdc = new MockUSDC();
        oracle = new MockOracle();
        uint128[3] memory prices = [uint128(50_000 * 1e18), uint128(3_000 * 1e18), uint128(150 * 1e18)];
        for (uint256 i; i < prices.length; ++i) {
            oracle.setPrice(i, prices[i]);
            oracle.setConf(i, prices[i] / 200); // 0.5%, inside the real oracle's 2% cap
        }

        vm.startPrank(owner);
        tradingStorage = new TradingStorage(address(usdc), owner);
        vault = new Vault(address(usdc), owner, address(tradingStorage), address(oracle));
        assistantFund = new AssistantFund(address(usdc), address(vault), 50_000 * 10 ** 6, owner);
        synth = new SynthToken(owner);
        bondDepository = new BondDepository(address(usdc), address(vault), address(synth), 500, owner);
        engine = new TradingEngine(
            address(tradingStorage), address(vault), address(oracle), address(usdc), address(assistantFund), address(new MockSpreadManager(5)), owner
        );
        solvencyManager = new SolvencyManager(address(vault), address(assistantFund), address(bondDepository), owner);
        tradingStorage.setTradingEngine(address(engine));
        vault.setTradingEngine(address(engine));
        vault.setSolvencyManager(address(solvencyManager));
        synth.setMinter(address(bondDepository));
        assistantFund.setSolvencyManager(address(solvencyManager));
        bondDepository.setSolvencyManager(address(solvencyManager));
        tradingStorage.addPair("BTC/USD", 100, 50_000_000 * 1e18);
        tradingStorage.addPair("ETH/USD", 100, 50_000_000 * 1e18);
        tradingStorage.addPair("SOL/USD", 100, 50_000_000 * 1e18);
        vm.stopPrank();

        usdc.mint(lp, SEED);
        vm.startPrank(lp);
        usdc.approve(address(vault), SEED);
        vault.deposit(SEED, lp);
        vm.stopPrank();

        handler = new ProtocolHandler(engine, tradingStorage, vault, oracle, usdc, _keeperLatency());
        address[] memory actors = new address[](handler.actorsLength());
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = handler.actors(i);
        }
        liquidity = new LiquidityHandler(engine, vault, oracle, usdc, assistantFund, solvencyManager, bondDepository, owner, actors);

        targetContract(address(handler));
        targetContract(address(liquidity));
        _seedPositions();
    }

    /// @dev Keeper latency of the handler, in seconds; 0 here (liquidate as soon as a position qualifies)
    function _keeperLatency() internal pure virtual returns (uint256) {
        return 0;
    }

    /// @dev Positions opened before the campaign starts; none here
    function _seedPositions() internal virtual {}

    /*//////////////////////////////////////////////////////////////
                           VAULT ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The Vault's USDC balance equals the sum of every modelled flow into and out of it
     * @dev vault USDC = SEED + LP deposits - LP withdrawals
     *                   + Vault fee share (80% of open and close fees)
     *                   + realised trader losses (collateral kept on close, TP/SL or liquidation)
     *                   - realised trader profits (paid with sendPayout)
     *                   + AssistantFund injections + AssistantFund skims + bond proceeds
     *      Trader losses and profits are computed by the handler's settlement model, not measured, so any
     *      settlement that moves Vault USDC differently from the documented formulas breaks the equation.
     */
    function invariant_VaultBalanceMatchesModelledFlows() public view {
        uint256 inflows = SEED + liquidity.ghostDeposits() + handler.ghostVaultFees() + handler.ghostTraderLosses() + liquidity.ghostInjections()
            + liquidity.ghostSkims() + liquidity.ghostBondProceeds();
        uint256 outflows = liquidity.ghostWithdrawals() + handler.ghostTraderProfits();
        assertEq(usdc.balanceOf(address(vault)), inflows - outflows, "vault balance diverged from modelled flows");
    }

    /**
     * @notice totalAssets is the USDC balance minus the positive part of the latest snapshot, floored at 0, and the
     *         balance itself while no trade is open
     * @dev The snapshot is used even when stale, so totalAssets and the previews never revert.
     */
    function invariant_TotalAssetsIsBalanceMinusSnapshotLiability() public view {
        uint256 balance = usdc.balanceOf(address(vault));
        (uint32 openTrades,) = tradingStorage.getPositionState();
        (int128 netPnl,,) = vault.pnlSnapshot();
        uint256 liability = openTrades == 0 || netPnl <= 0 ? 0 : uint256(int256(netPnl));
        assertEq(vault.totalAssets(), balance > liability ? balance - liability : 0, "totalAssets differs from balance minus liability");
    }

    /**
     * @notice The AssistantFund (the treasury) holds exactly the treasury fee share minus what it sent to the Vault
     * @dev AssistantFund USDC = 20% of open and close fees - injections - skims
     */
    function invariant_AssistantFundBalanceMatchesModelledFlows() public view {
        assertEq(
            assistantFund.balance(), handler.ghostTreasuryFees() - liquidity.ghostInjections() - liquidity.ghostSkims(), "reserve diverged from modelled flows"
        );
    }

    /// @notice Every settlement, withdrawal, injection, skim and bond moved exactly the modelled amount
    function invariant_FlowsMatchModel() public view {
        assertEq(handler.ghostMismatches(), 0, "trader or keeper payout differs from the model");
        assertEq(liquidity.ghostMismatches(), 0, "LP or solvency flow differs from the model");
    }

    /*//////////////////////////////////////////////////////////////
                               FUNDING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Funding credited to receivers never exceeds funding charged to payers, summed over the pairs
     * @dev S = sum of fundingOwed over settled positions + fundingOwed accrued by open positions at the stored
     *      side indexes (payer positive, receiver negative). Zero sum up to rounding per pair, so over all
     *      pairs: 0 <= S <= N, where N is the number of positions counted, because each amount rounds by less
     *      than one unit in the protocol's favour and index-level rounding stays far below one unit.
     */
    function invariant_FundingCreditsNeverExceedCharges() public view {
        int256 total = handler.ghostFundingSettled() + handler.openAccruedFunding();
        assertGe(total, 0, "credits exceed charges");
        assertLe(total, int256(handler.ghostSettled() + handler.openTradeCount()), "funding surplus above rounding");
    }

    /**
     * @notice The Vault does not pay funding except for the documented bad-debt residual
     * @dev collected - credited + accrued(open) + badDebt >= 0, where collected is what payers actually paid
     *      at settlement, credited what receivers actually got, accrued what open positions owe (+) or are owed
     *      (-), and badDebt the funding payers could not pay because their loss exceeded their collateral.
     *      Receivers can be credited before payers settle; the accrued term carries that timing difference.
     */
    function invariant_VaultFundingExposureBoundedByBadDebt() public view {
        int256 exposure = int256(handler.ghostFundingCollected()) - int256(handler.ghostFundingCredited()) + handler.openAccruedFunding()
            + int256(handler.ghostFundingBadDebt());
        assertGe(exposure, 0, "vault paid funding beyond the bad-debt residual");
    }

    /*//////////////////////////////////////////////////////////////
                          CUSTODY AND LIMITS
    //////////////////////////////////////////////////////////////*/

    /// @notice TradingStorage holds exactly the collateral of the open positions, no more and no less
    function invariant_StorageHoldsExactlyOpenCollateral() public view {
        assertEq(usdc.balanceOf(address(tradingStorage)), handler.ghostOpenCollateral(), "storage balance differs from open collateral");
    }

    /**
     * @notice On every pair, open interest equals the open positions on each side, and long + short stays within maxOI
     * @dev TradingStorage.increaseOpenInterest checks the cap against long + short OI of the pair.
     */
    function invariant_OpenInterestMatchesPositionsAndCap() public view {
        for (uint256 pair; pair < handler.PAIRS(); ++pair) {
            uint256 longOI = tradingStorage.getOpenInterestLong(pair);
            uint256 shortOI = tradingStorage.getOpenInterestShort(pair);
            assertEq(longOI, handler.ghostOpenLongSize(pair), "long OI differs from open longs");
            assertEq(shortOI, handler.ghostOpenShortSize(pair), "short OI differs from open shorts");
            assertLe(longOI + shortOI, tradingStorage.getPair(pair).maxOI, "long + short OI above maxOI");
        }
    }

    /// @notice Shares held by the Vault equal the shares of all pending withdrawal requests
    function invariant_EscrowedSharesMatchRequests() public view {
        uint256 requested;
        uint256 count = liquidity.actorsLength();
        for (uint256 i; i < count; ++i) {
            (uint256 shares,,) = vault.withdrawalRequests(liquidity.actors(i));
            requested += shares;
        }
        assertEq(vault.balanceOf(address(vault)), requested, "escrow differs from pending requests");
    }

    /**
     * @notice A rescue never lifts its own ratio above 100%: an injection the NAV ratio, a bond the realised ratio
     * @dev The injection is sized off collateralizationDeficit = totalSupply / 1e12 - totalAssets (NAV), a bond
     *      off realisedCollateralizationDeficit = totalSupply / 1e12 - balance, so the resulting ratio is
     *      floor(totalSupply / 1e12) * 1e30 / totalSupply <= 1e18. Tolerance 0.
     */
    function invariant_RescueNeverOvershootsTarget() public view {
        assertLe(liquidity.ghostMaxNavCrAfterInjection(), 1e18, "injection lifted the NAV ratio above 100%");
        assertLe(liquidity.ghostMaxRealisedCrAfterBond(), 1e18, "bond lifted the realised ratio above 100%");
    }

    /*//////////////////////////////////////////////////////////////
                          OPEN PNL AND NAV
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The open position aggregates equal the open positions rebuilt one by one, per pair and side, exactly
     * @dev Sizes, collateral and quantities (quantity rounded up for longs, down for shorts per position).
     */
    function invariant_OpenTotalsMatchPositions() public view {
        for (uint256 pair; pair < handler.PAIRS(); ++pair) {
            OpenPnlLib.PairTotals memory agg = tradingStorage.getPairOpenTotals(pair);
            OpenPnlLib.PairTotals memory brute = handler.bruteForceTotals(pair);
            assertEq(agg.longSize, brute.longSize, "long size");
            assertEq(agg.longCollateral, brute.longCollateral, "long collateral");
            assertEq(agg.longQuantity, brute.longQuantity, "long quantity");
            assertEq(agg.shortSize, brute.shortSize, "short size");
            assertEq(agg.shortCollateral, brute.shortCollateral, "short collateral");
            assertEq(agg.shortQuantity, brute.shortQuantity, "short quantity");
        }
        (uint32 openTrades,) = tradingStorage.getPositionState();
        assertEq(openTrades, handler.openTradeCount(), "open trade count");
    }

    /**
     * @notice Every refresh stored the brute-force valuation, and snapshot + excess loss was never below the
     *         exact per-position clamped PnL (checked in ProtocolHandler.refreshSnapshot at each refresh)
     */
    function invariant_SnapshotMatchesBruteForceAndIsConservative() public view {
        assertEq(handler.ghostSnapshotMismatches(), 0, "snapshot differs from the brute-force valuation");
        assertEq(handler.ghostSnapshotNotConservative(), 0, "snapshot + excess loss below exact trader PnL");
    }

    /**
     * @notice Deposits follow the round 3 rule (replaces NoDepositBelowParOrStaleAction): none on a stale snapshot,
     *         none while a bonding round is open after the check, each deposit injects exactly the AssistantFund
     *         injection pending before it (so the depositor buys after it), minted shares worth at most the assets paid in,
     *         and no withdrawal execution on a stale snapshot. The outcome of each deposit also matches maxDeposit
     *         (counted in the handler's mismatches, invariant_FlowsMatchModel).
     */
    function invariant_DepositsFollowRescueRule() public view {
        assertEq(liquidity.ghostStaleActions(), 0, "deposit or withdrawal on a stale snapshot");
        assertEq(liquidity.ghostDepositsDuringBonding(), 0, "deposit while a bonding round was open");
        assertEq(liquidity.ghostDepositsWithPendingInjection(), 0, "deposit did not settle the pending injection first");
        assertEq(liquidity.ghostDepositsOverValued(), 0, "minted shares worth more than the assets paid in");
    }

    /// @notice checkAndAct never opened a bonding round with the realised ratio at or above 95%
    function invariant_BondingNeverStartsAboveCriticalRealisedRatio() public view {
        assertEq(liquidity.ghostBondingAboveCritical(), 0, "bonding opened at a realised ratio >= 95%");
    }

    /// @notice No close, TP/SL execution or liquidation succeeded while the engine's PAUSE_SETTLE was set
    function invariant_NoSettlementWhileSettlePaused() public view {
        assertEq(handler.ghostSettledWhileSettlePaused(), 0, "settlement succeeded under PAUSE_SETTLE");
    }

    /**
     * @notice No withdrawal request expires because of time spent under the vault's PAUSE_WITHDRAW: while the flag
     *         is clear, a request inside its window by the model (unlocked, before the unextended expiry plus the
     *         exact seconds paused since the request) can be executed
     */
    function invariant_WithdrawPauseDoesNotExpireRequests() public view {
        uint256 count = liquidity.actorsLength();
        for (uint256 i; i < count; ++i) {
            assertFalse(liquidity.expiredByPause(liquidity.actors(i)), "request expired by time spent under PAUSE_WITHDRAW");
        }
    }

    /**
     * @notice No funding accrues for time spent under PAUSE_SETTLE: while it is set the funding indexes of every pair
     *         equal those right after it was set, clearing it left them unchanged, and no pair's accrual interval
     *         starts before the last time it was cleared
     */
    function invariant_NoFundingAccruesWhileSettlePaused() public view {
        assertEq(liquidity.ghostFundingAccruedWhileSettlePaused(), 0, "funding index changed across a settlement pause");
        bool paused = engine.pauseFlags() & engine.PAUSE_SETTLE() != 0;
        for (uint256 pair; pair < handler.PAIRS(); ++pair) {
            if (paused) {
                assertEq(tradingStorage.getCumulativeFundingIndex(pair, true), liquidity.ghostIndexAtSettlePauseLong(pair), "long index moved while paused");
                assertEq(tradingStorage.getCumulativeFundingIndex(pair, false), liquidity.ghostIndexAtSettlePauseShort(pair), "short index moved while paused");
            }
            uint256 lastUpdated = tradingStorage.getFundingLastUpdated(pair);
            if (lastUpdated != 0) assertGe(lastUpdated, liquidity.ghostLastSettleUnpause(), "accrual interval starts inside a pause");
        }
    }

    /// @notice Share price is strictly positive while shares are outstanding
    function invariant_SharePricePositive() public view {
        if (vault.totalSupply() == 0) return;
        assertGt(vault.convertToAssets(1e18), 0, "share price fell to zero");
    }

    /**
     * @notice Shares are never outstanding without assets backing them
     * @dev Zero assets against live shares is the insolvency end-state and would let the next depositor mint
     *      against an empty Vault.
     */
    function invariant_SharesBackedByAssets() public view {
        if (vault.totalSupply() == 0) return;
        assertGt(vault.totalAssets(), 0, "shares outstanding with zero backing assets");
    }

    /**
     * @notice Run summary, logged after each run (forge shows the last run's logs with -vv); the forge metrics
     *         table gives the call distribution over all runs. Also checks the settlement counters are consistent.
     */
    function afterInvariant() public view {
        assertLe(handler.ghostSettled() + handler.openTradeCount(), handler.ghostOpened(), "settled or open positions never opened");
        assertLe(handler.ghostLiquidated(), handler.ghostSettled(), "more liquidations than settlements");
        console.log("opened / settled / liquidated:", handler.ghostOpened(), handler.ghostSettled(), handler.ghostLiquidated());
        console.log("open positions left:", handler.openTradeCount());
        console.log("funding bad debt (USDC units):", handler.ghostFundingBadDebt());
        console.log("refreshes / refreshes with E > 0 / max E (18 dec):", handler.ghostRefreshes(), handler.ghostExcessStates(), handler.ghostMaxExcessLoss());
        console.log("deposits / withdrawals executed:", liquidity.ghostDepositCount(), liquidity.ghostWithdrawalCount());
    }
}
