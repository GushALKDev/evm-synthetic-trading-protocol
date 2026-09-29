# Guide 10: Review Notes

**Prerequisites:** [Guide 9: Implementation Status](./09-implementation-status.md)
**Next:** [Test suite](./tests/README.md)

**Status:** Proof of concept. Not audited and not deployed.

---

Findings from the round 1 review, fixed in round 2 on branch `fix/review-findings` (entries 1 to 14) and in
round 2b on branch `fix/open-pnl-nav` (entries 15 and 16), the round 3 hardening on branch
`hardening/final` (entries 17 to 25) and round 3b on branch `fix/pause-flags` (entries 26 to 28). The tests named `test_Regression_*` (and `testFuzz_Regression_*`)
failed against the code before their fix; the other tests in the same files pass before and after.

1. **Funding paid by the vault, not normalised (High).** Cause: the index moved by the absolute USD
   imbalance (a 1,000 USD imbalance gave 3.6% of notional per hour) and settled against the vault, so a
   10 USDC x100 short next to a 1,000 USDC x100 long closed with 57.82 USDC after 60 seconds at a flat
   price, and one account holding a long and 50 shorts drained 2,294.14 USDC in 160 seconds. Fix: rate
   proportional to the relative skew, capped at 0.01% per hour, per-side indexes, the lighter side
   receives what the heavier side pays, payers round up and receivers down, funding settled after the 9x
   cap. Tests: `test/regression/FundingRegression.t.sol`, `test/unit/FundingLib.t.sol`,
   `testFuzz_Funding_FundsConservation`. Commit `2dcf3ff`.
2. **Withdrawal requests without expiry or escrow; `max*` functions (Medium).** Cause: a request stayed
   executable forever after 3 epochs and its shares stayed transferable; `maxWithdraw`/`maxRedeem` and
   `maxDeposit`/`maxMint` did not match what the vault accepts. Fix: shares escrowed in the vault, a
   1-epoch execution window, `max*` aligned with the actions. Tests:
   `test/regression/WithdrawalRegression.t.sol`, `Vault.t.sol` max* and window tests. Commit `ad38b4f`.
3. **Oracle latency (Medium).** Cause: any update up to 30 seconds old was accepted, so a trade could open
   on a 25 second old price and close on the current one; a future `publishTime` underflowed. Fix:
   `maxPriceAge` (default 5 s, owner-set up to 30 s) and `PriceFromFuture`. Tests:
   `test/regression/OracleLatencyRegression.t.sol`. Commit `b62e786`.
4. **No L2 sequencer uptime check; fork suite not reproducible.** Cause: no sequencer check; the fork tests
   targeted HyperEVM at the latest block and called Hermes through `ffi`. Fix: Chainlink sequencer uptime
   feed with a 1 hour grace period (constructor parameter, `address(0)` disables it); fork suite on
   Arbitrum One at a pinned block without Hermes, `ffi = false`. Tests:
   `test/regression/SequencerRegression.t.sol`, `test/fork/PythChainlinkOracle.fork.t.sol`. Commits
   `b657eb9`, `2aa12c2`.
5. **No global leverage cap.** Cause: leverage was limited only by each pair's owner-set `maxLeverage`. Fix: `MAX_LEVERAGE = 100` in pair configuration and on open. Tests:
   `test/regression/LeverageRegression.t.sol`. Commit `c7e702f`.
6. **Opening guard (Low).** Cause: the guard used the open spread and the gross collateral, so with a
   50 BPS spread a 100x position could be liquidated in the block it opened. Fix: close spread at the
   post-open OI and collateral net of the open fee. Tests: `test/regression/OpenGuardRegression.t.sol`,
   and `test_OpenTrade_RevertWhenPreLiquidatable`, which reverted on slippage instead of the guard. Commit
   `dc027f8`.
7. **Zero liquidator reward past 100% loss (Medium).** Cause: the reward was 10% of the collateral left
   after the loss, which is zero once the loss reaches the collateral, so nobody was paid to liquidate
   positions past 100% loss. Fix: reward `max(10% of remaining, 0.5% of
   collateral)`, paid from the position's collateral. Tests:
   `test/regression/LiquidationRewardRegression.t.sol`. Commit `977ba1e`.
8. **Linear `deleteTrade` (Low).** Cause: `deleteTrade` searched the user's trade list, so a user with
   many open trades made each of its liquidations more expensive. Fix: swap and pop with the position stored in `Trade.userIndex`. Tests:
   `test/regression/DeleteTradeRegression.t.sol`. Commit `7475469`.
9. **Force-sent ETH paid to the next caller (Low).** Cause: the engine refunded its whole ETH balance, so
   ETH sent to it outside a call went to the next caller. Fix: refund `msg.value` minus the fee actually paid,
   with the entry balance kept in transient storage. Tests: `test/regression/EthRefundRegression.t.sol`.
   Commit `52aa4ee`.
10. **`updateTp`/`updateSl` without `nonReentrant` (Low).** Cause: both call the oracle and refund ETH
    without the guard the other entry points have. Fix: guard added. Tests:
    `test/regression/ReentrancyRegression.t.sol`. Commit `a236103`.
11. **Bonding round not closed when CR recovers (Low).** Cause: a round closed only when its cap was used
    up, so after the vault recovered by other means bonders could keep buying discounted $SYNTH. Fix: a bond takes at most the current deficit and
    closes the round when it covers it; `checkAndAct` closes the round at CR >= 100%. Tests:
    `test/regression/BondingRoundRegression.t.sol`. Commit `6668365`.
12. **Stale NatSpec and unused error (Info).** Cause: comments described earlier designs. Fix: `TradingEngine` header (fixed spread), `IOracle` (custom
    DON example), `BondDepository` header (keeper-maintained price); `ZeroFeeRecipient` removed. Commits
    `e42bd1b`, `6668365`, `8726c55`.
13. **A winning close reverts when the vault is short of USDC (Info).** Cause: `sendPayout` needs the USDC
    in the vault. No code change; documented under Known limitations.
14. **Test suite (Info).** Weak or tautological invariants replaced, call summaries moved to
    `afterInvariant`, tolerances tightened, `test_CloseTrade_UsesSpreadOnClose` given an assertion,
    compiler warnings removed. Commits `37119cf`, `7a51384`, `857580a`, `0577333`, `aaceb08`.
15. **LP timing, part c: the share price ignored unrealised PnL.** Cause: `totalAssets` was the USDC
    balance, so withdrawals, deposits and previews were priced without the open trader PnL; an LP could exit
    ahead of a large unrealised trader profit and leave it to the LPs who stayed
    (`test_Regression_Nav_WithdrawalPaidAtConservativeNav`, run against the `src/` of commit `c359a1b`, paid
    500,159.999999 USDC instead of 488,780.689655 at the NAV). Fix: per pair and side aggregates in `TradingStorage` (size, collateral, quantity, removal
    exact), a PnL snapshot refreshed permissionlessly through the oracle checks (confidence edge that shows
    the most trader profit, at most `MAX_PAIRS` = 20 pairs), `totalAssets` = balance minus the positive
    snapshot, a maximum snapshot age for `deposit`, `mint` and `executeWithdrawal` with refresh-and-act entry
    points, and `sendPayout` checked against the balance. Tests: `test/regression/OpenPnlNavRegression.t.sol`,
    `test/regression/MaxPairsRegression.t.sol`, `test/unit/VaultNav.t.sol`, `test/unit/OpenPnlLib.t.sol`, the
    aggregate tests in `test/unit/TradingStorage.t.sol`. Commits `c359a1b`, `e225c14`.
16. **LP timing, the ratio: deposits below 100% and solvency triggers on the balance.** Cause: the
    collateralization ratio ignored open PnL, a deposit below 1.0 took part of the next injection (in
    `test_Regression_DepositBelowPar_InjectionSettledFirst`, run against commit
    `e225c14`, a 1,000,000 USDC deposit at a 90% ratio was worth 1,052,631.578947 USDC after a 100,000 USDC
    injection), and once the ratio included open PnL, an unrealised move could have opened a discounted
    $SYNTH round. Fix: the ratio (LP
    principal coverage ratio) uses the NAV; deposits and mints reverted below 100% (`CoverageBelowPar`,
    replaced in round 3 by entry 18); the injection follows the NAV ratio with a fresh snapshot; bonding
    opens, sizes, clamps and closes on the realised ratio. Tests:
    `test/regression/DepositCoverageRegression.t.sol`, `test/regression/SolvencySplitRegression.t.sol`,
    `test/unit/SolvencyManager.t.sol`. Commits `1ccbe10`, `d83c52b`.
17. **The sequencer grace period blocked closes and liquidations (Medium).** Cause: for one hour after the
    L2 sequencer came back, `getPrice` reverted for every caller, so closes, TP/SL execution, liquidations,
    snapshot refreshes, LP withdrawals and `checkAndAct` were blocked; a position cannot be topped up, so a
    blocked liquidation could let it run past 100% loss at the vault's expense. Fix: `getPrice` reverts only
    while the sequencer is down; `IOracle.checkOpenAllowed`, called by `openTrade` only, reverts during the
    grace period. Tests: `test/regression/SequencerGraceScopeRegression.t.sol` (six tests failed before with
    `SequencerGracePeriodNotOver`), `test_Fork_TradingEngine_GracePeriodClosesButDoesNotOpen` (failed before
    on the fork). Commit `16baf19`.
18. **Deposits frozen below 100% coverage with no rescue left (Medium).** Cause: round 2b reverted every
    deposit and mint below a 100% coverage ratio; with the AssistantFund empty and no bonding round due,
    nothing lifted the ratio, so deposits stayed closed with no time limit. Fix: every deposit path first calls
    `SolvencyManager.checkAndActBeforeDeposit`, so the pending AssistantFund injection lands and shares are
    minted at the post-injection NAV; the deposit reverts with `BondingRoundOpen` only while a bonding round is
    open or due; `maxDeposit` and `maxMint` follow a view mirror of that check. Tests:
    `test/regression/DepositRuleRegression.t.sol` (six tests failed before with `CoverageBelowPar`),
    `test/regression/DepositCoverageRegression.t.sol` (rewritten; five failed before),
    `test/unit/VaultDepositRule.t.sol`, invariant `DepositsFollowRescueRule`. Commit `21d9361`.
19. **`setFundingFactor` wrote state after external calls (Slither `reentrancy-no-eth`, Aderyn H-2).**
    Cause: it accrued every pair through `TradingStorage` and then wrote the factor. Fix: it writes the factor
    first and accrues at the old factor passed as a parameter; no behaviour change,
    `test_SetFundingFactor_AccruesElapsedTimeAtOldFactor` passes before and after and neither tool reports it.
    Commit `52d7c2b`.
20. **Unreachable `FeeExceedsCollateral` check (Info).** Cause: the open fee rate is a constant and leverage
    above 100 reverts before the fee is computed, so the fee is at most 8% of the collateral. Fix: check and
    error removed. Test: `testFuzz_OpenFee_BelowCollateralForEveryAcceptedLeverage`. Commit `0dcdd6c`.
21. **Entry funding index left after a delete (Info).** Cause: `deleteTrade` kept `_tradeFundingIndex`;
    trade IDs are never reused, so no trade could read another's value. Fix: cleared on delete. Test:
    `test_DeleteTrade_ClearsTradeFundingIndex` (failed before: `42000000000000000000 != 0`). Commit
    `6d99400`.
22. **Downcasts that truncated (Low).** Cause: three casts truncated instead of reverting: the oracle's
    normalized price for a feed with a positive exponent, a bond's $SYNTH above 2^128, and the open-direction
    spread price near 2^128. Fix: `SafeCastLib` for those three; every other downcast or signed cast carries
    a one-line comment with its bound and the `file:line` that enforces it. Tests:
    `test/unit/TypecastBounds.t.sol` (three tests failed before). Commit `4145744`.
23. **`msg.value` inside the snapshot refresh loop (Slither `msg-value-loop`, 4 results).** Cause: flagged
    because `msg.value` appears in a loop. Checked: it is sent to the first priced pair only. No code change.
    Test: `test/unit/VaultRefreshFee.t.sol`. Commit `2d88c2d`.
24. **`maxWithdraw` and `maxRedeem` reported as not covered (Info).** Cause: forge coverage attributed no
    hits to their `return 0;` lines although the functions ran. Fix: empty bodies returning the default 0.
    Commit `120adca`.
25. **`collateralizationRatio` public without internal use (Aderyn L-9, Info).** Fix: `external`. Commit
    `2dd5562`.
26. **One pause per contract blocked the wrong combinations (Medium).** Cause, from the round 3 pause
    review: `TradingEngine.pause` blocked closes and TP/SL execution but not `liquidate`, so a trader who
    could not close could still be liquidated and pay the reward, and funding kept accruing; `Vault.pause`
    blocked withdrawal requests together with deposits, a pause longer than the one-epoch execution window
    let pending requests expire, and it did not stop settlements. Fix: independent flags (`PAUSE_OPEN`,
    `PAUSE_SETTLE` on the engine, with `liquidate` under `PAUSE_SETTLE` and no funding accrual while it is
    set; `PAUSE_DEPOSIT`, `PAUSE_WITHDRAW` on the vault, with the expiry clock stopped under
    `PAUSE_WITHDRAW`); `updateTp` and `updateSl` are never paused. Tests:
    `test/regression/PauseFlagsRegression.t.sol` (five tests failed before: the liquidation went through,
    `EnforcedPause()` on a close and on a withdrawal request, `WithdrawalExpired(4)`, and funding of
    19718181818181621 instead of 81818181818181 index units), invariants `NoSettlementWhileSettlePaused`,
    `WithdrawPauseDoesNotExpireRequests` and `NoFundingAccruesWhileSettlePaused`. Commit `3422f8e`.
27. **Reverts never taken in coverage (Info).** Round 3 coverage listed nine branches never taken, all
    reverts. Fix: tests for eight of them in `BondDepository.t.sol`, `TradingEngine.t.sol` and `Vault.t.sol`
    (commit `1a7442c`); the ninth was the unreachable check of entry 28.
28. **Unreachable `ReferencePriceUnset` check (Info).** Cause: `referencePrice` starts at 2 USDC and
    `setReferencePrice` rejects 0, so the check in `activateBonding` could not revert. Fix: check and error
    removed. Commit `b5e0f1a`.

---

**See also:**

- [Test suite](./tests/README.md): the regression tests of each round
- [ROADMAP](./ROADMAP.md): changelog by round
