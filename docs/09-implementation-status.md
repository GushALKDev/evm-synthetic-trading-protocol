# Guide 9: Implementation Status

**Prerequisites:** [Guide 8: Security](./08-security.md)
**Next:** [Guide 10: Review Notes](./10-review-notes.md)

**Status:** Proof of concept. Not audited and not deployed.

---

Status legend: **Implemented** (code and tests exist), **Partial** (implemented with limits described in
the row), **Designed only** (described in the docs, no code), **Not found**. File references point to
`src/`; test names point to `test/`.

| Feature | Status | Evidence |
| :------ | :----- | :------- |
| ERC-4626 vault, sUSDC shares (18 decimals, `_decimalsOffset() = 12`) | Implemented | `Vault.sol` (Solady `ERC4626`); `test/unit/Vault.t.sol` |
| 3-epoch withdrawal lock (1 epoch = 1 day) with escrow and a 1-epoch execution window | Implemented | `Vault.requestWithdrawal` escrows the shares in the vault; `executeWithdrawal` works only in the epoch after unlock, then reverts `WithdrawalExpired`; `cancelWithdrawal` returns the shares. `test/regression/WithdrawalRegression.t.sol`, `Vault.t.sol` |
| ERC-4626 conformity and `max*` functions | Implemented | `maxWithdraw` and `maxRedeem` return 0 (the actions always revert); `maxDeposit` and `maxMint` return 0 under `PAUSE_DEPOSIT`, with a stale PnL snapshot, or while a bonding round is open or due. Previews, rounding direction, non-reverting views and escrowed shares in `test/unit/VaultErc4626.t.sol`; `max*` against their actions in `Vault.t.sol` and `test/unit/VaultDepositRule.t.sol` |
| Share price at a conservative NAV with open trader PnL | Implemented | `Vault.totalAssets` = USDC balance minus the positive net unrealised trader PnL of the latest snapshot. Per pair and side aggregates in `TradingStorage` (`getPairOpenTotals`), math in `libraries/OpenPnlLib.sol`, snapshot in `Vault.refreshPnlSnapshot` (at most `MAX_PAIRS` = 20 pairs). `deposit`, `mint` and `executeWithdrawal` need a snapshot at most `maxPnlSnapshotAge` old (60 s by default) with no open or close since; `refreshAndDeposit`, `refreshAndMint`, `refreshAndExecuteWithdrawal` refresh in the same call. `test/unit/VaultNav.t.sol`, `test/regression/OpenPnlNavRegression.t.sol` |
| Deposit rule: pending AssistantFund injection first, no deposits while bonding is open or due | Implemented | Every deposit path calls `SolvencyManager.checkAndActBeforeDeposit` before minting and reverts with `BondingRoundOpen` when a round is open afterwards; below 100% coverage a deposit is otherwise allowed at the NAV. `test/regression/DepositRuleRegression.t.sol`, `test/unit/VaultDepositRule.t.sol` |
| Pyth pull integration: update data, caller-paid fee with refund, 5 s price age (owner-set up to 30 s), 2% confidence cap | Implemented | `PythChainlinkOracle.getPrice`; `test/unit/PythChainlinkOracle.t.sol` (MockPyth); fork suite on Arbitrum One at a pinned block, 21 tests |
| L2 sequencer uptime check (Chainlink feed, 1 hour grace period for openings) | Implemented | `PythChainlinkOracle` constructor parameter, `address(0)` disables it. While the sequencer is down every price read reverts; for one hour after it comes back only `openTrade` reverts (`IOracle.checkOpenAllowed`). `test/regression/SequencerRegression.t.sol`, `test/regression/SequencerGraceScopeRegression.t.sol` and the fork suite |
| Chainlink deviation anchor (3%) and Chainlink heartbeat check | Implemented | `PythChainlinkOracle.getPrice`, `_getChainlinkPrice18`. On disagreement above 3% or a stale Chainlink answer the call reverts; there is no fallback price |
| Dynamic spread: base + OI term + volatility term, capped | Implemented | `SpreadManager.getSpreadBps`; volatility is set by a keeper (`updateVolatility`); `test/unit/SpreadManager.t.sol` |
| Funding between traders | Implemented | `FundingLib`, `TradingEngine._updateFundingIndex`: rate proportional to the relative skew, capped at 0.01% of the heavier side's notional per hour; the lighter side receives what the heavier side pays, through per-side indexes; the vault only carries the bad-debt residual described below |
| Liquidations: 90% loss threshold, reward `max(10% of remaining collateral, 0.5% of collateral)` | Implemented | `TradingEngine.liquidate`; loss includes funding and uses the trader-favourable edge of the Pyth confidence band; the reward is paid from the position's collateral, also past 100% loss; blocked by `PAUSE_SETTLE` together with closes |
| Automatic TP/SL (`executeLimit`) with executor reward (0.1% of notional, taken from the trader payout) | Implemented | `TradingEngine.executeLimit`; permissionless. Limit orders that open positions are not implemented |
| Open interest limit | Partial | Static per-pair cap on long + short OI (`TradingStorage.increaseOpenInterest`), set by the owner. No global cap |
| Open interest limits that adapt to volatility | Designed only | Described in `docs/02-mathematics.md` and `docs/07-vault-ssl.md`; no code |
| Profit cap | Implemented | `TradingEngine._calculatePayout`: collateral plus price PnL capped at 9x collateral (maximum price profit 8x); funding is settled after the cap in both directions |
| Max leverage | Implemented | Global `MAX_LEVERAGE = 100`, checked in `addPair`/`updatePair` and on open; per-pair limits below it |
| Opening guard | Implemented | `_validateNotPreLiquidatable` rejects a position `liquidate` would accept in the same block at an unchanged price (close spread at the post-open OI, collateral net of the open fee) |
| Asset classes (crypto, forex, commodities) | Partial | Any pair with a Pyth feed ID and a Chainlink feed can be configured. No per-class logic (no market hours, no weekend handling). The fork suite uses BTC and ETH; the mock invariant suites run three pairs |
| Fee split: 0.08% open and close fee on notional, 80% vault / 20% treasury | Implemented | `TradingEngine._distributeFees`; `script/Deploy.s.sol` sets the treasury to the `AssistantFund` |
| `SolvencyManager.checkAndAct`: inject reserve below a 100% NAV ratio, open a bonding round below a 95% realised ratio, close it at 100% realised | Implemented | `SolvencyManager.sol`. The injection needs a fresh PnL snapshot (`refreshAndCheckAndAct` takes one); bonding uses the USDC balance per share, so an unrealised move does not sell discounted $SYNTH. `test/regression/SolvencySplitRegression.t.sol` |
| `AssistantFund.injectFunds` and permissionless `skim` | Implemented | `AssistantFund.sol`; `test/unit/AssistantFund.t.sol` |
| `BondDepository`: discounted $SYNTH sale with linear vesting | Implemented | `BondDepository.bond` / `claim`. A bond takes at most the current realised vault deficit and the round closes when the realised ratio is back at 100%. Price comes from an owner-set `referencePrice`, not from a market |
| `SynthToken` minter gating | Implemented | `SynthToken.mint` (`onlyMinter`); the owner can change the minter at any time |
| Surplus buyback of $SYNTH above 110% CR | Designed only | Described in `docs/02-mathematics.md`; no code |
| Independent pause flags | Implemented | `TradingEngine`: `PAUSE_OPEN`, `PAUSE_SETTLE` (closes, TP/SL and liquidations together; no funding accrues while set). `Vault`: `PAUSE_DEPOSIT`, `PAUSE_WITHDRAW` (the expiry clock of pending requests stops). `setPauseFlags`, owner only. `test/regression/PauseFlagsRegression.t.sol`; incident playbook in `docs/08-security.md` section 6 |
| Circuit breakers, emergency withdrawal, role-based access control, timelock | Designed only | Earlier design documents only. Every contract uses a single `Ownable` owner |
| Liquidation lookbacks | Designed only | Listed as V2 in `docs/ROADMAP.md` |
| Custom oracle network (DON) | Not found | Dropped in the design phase; no code remains |

---

**See also:**

- [ROADMAP](./ROADMAP.md): build log by phase
- [Guide 6: Future Improvements](./06-improvements.md): ideas that are not implemented
