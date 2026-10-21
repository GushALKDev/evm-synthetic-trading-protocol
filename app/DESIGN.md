# Design notes

## Accent and data colors

This app is the Mulberry member of the demo family. The accent replaces the family's verdigris everywhere it appears:
primary buttons, links styled as buttons, selected chips, focus rings, the NAV ratio headline figure, the success toast
icon, and the mark and favicon.

| Role | Light | Dark |
| :-- | :-- | :-- |
| Accent | #78506A | #C399B4 |
| Accent hover | #613F56 | #D1ABC3 |
| Accent soft | #EEE2EA | #3B2935 |
| Text on accent | #FFFFFF | #0E1412 |

Data colors this app adds, each distinct from the accent, danger and warn:

| Role | Light | Dark | Used for |
| :-- | :-- | :-- | :-- |
| Long | #1D6E68 | #6CB8B0 | Long side tags, long open interest |
| Short | #46668A | #8AA6C7 | Short side tags, short open interest |
| Vault holdings | #4B5753 | #A6B1AC | The ledger's "the vault holds" bar |
| Owed to liquidity providers | #7C8883 | #6E7B76 | The ledger's "it owes" bar |

Long and short never rely on color alone: every side tag carries the word Long or Short and an arrow, open interest bars
are labelled with the side and amount, and PnL figures carry an explicit sign. Traders' open profit is drawn as a hatch
of the holdings grey rather than a fill of its own.

Contrast against the backgrounds, from `node scripts/contrast.mjs`:

| Token | Light: ground, surface, sunken | Dark: ground, surface, sunken |
| :-- | :-- | :-- |
| accent | 5.80, 6.66, 6.13 | 7.57, 7.04, 7.32 |
| long | 5.25, 6.03, 5.56 | 8.09, 7.52, 7.82 |
| short | 5.19, 5.95, 5.48 | 7.41, 6.89, 7.17 |
| seg-held | 6.57, 7.53, 6.94 | 8.43, 7.84, 8.15 |
| seg-lp | 3.21, 3.68, 3.39 | 4.22, 3.92, 4.08 |

Only the holdings and surplus segments carry a label inside the bar, since the other fills do not give small text enough
contrast; the legend under the bars names every segment.

## Subject

A synthetic perpetuals proof of concept on a testnet. Visitors are protocol founders, CTOs and engineers judging the
engineering, plus anyone who wants to open a position. The pages have two jobs: let them trade and provide liquidity
without friction, and make visible what makes the protocol hold together: the vault as the counterparty, its
conservative NAV, funding between traders, liquidations and the solvency layers.

## The one memorable element

The vault against every open trade, drawn as two bars on one scale: what the vault holds (its USDC) against what it owes
(liquidity providers at 1.0 per share, plus the profit traders would take if every position closed now). The remainder is
the liquidity providers' surplus, or a hatched shortfall when the vault holds less than it owes. Under the bars, the NAV
ratio and the realised ratio sit on one scale with the three thresholds the SolvencyManager acts on: 95% on the realised
ratio (bonding), 100% and 110% on the NAV ratio (reserve top-up, healthy). It is the protocol's own accounting, valued at
the current Chainlink prices the way a snapshot refresh values it, so a move in BTC or a closed trade moves it.
Everything else stays quiet.

## Shared system

Unchanged from the family: IBM Plex Sans with tabular figures for everything, IBM Plex Mono only for addresses; the
neutral greys for ground, surface, sunken, ink and rules; card and control radii; spacing; danger and warn; sentence case
with no all-caps labels.

## Layout

```
header        wordmark, network, pages, test USDC, wallet
              pages: Trade, Vault, All positions, How it works; on a second header row below 1024 px
notice        one line: testnet, tokens without value, not audited, where prices come from

/              hero: headline + the vault ledger
               grid: open a position, your positions (left, wider) | markets (right)
/vault         hero: headline + the vault ledger
               grid: your liquidity (deposit, request, cancel, withdraw) | solvency layers, bonds
/positions     every open position, with liquidate and execute buttons and the caller's reward
/how-it-works  eight mechanics + the oracle note

footer
```

Two columns from 1024 px, one below. Every page fits a 360 px screen without horizontal scrolling; the positions table
scrolls inside its own frame (`e2e/layout.spec.ts`).

## Rules

- Copy names what the user does: Open long, Close position, Liquidate, Deposit USDC, Request withdrawal, Bond USDC. The
  toast says what happened: Long opened, Position closed, USDC deposited.
- Every preview shows the numbers the contract will use, with its own rounding: entry price with the spread, fee, size,
  liquidation price, funding for the side, the payout cap, the balance before and after.
- Every write is simulated before the wallet asks for a signature, and a revert arrives as one sentence that says what
  happened and what to do.
- Numbered markers only for a real sequence (the four steps of a priced call). Status pills only where an action
  depends on them (liquidatable, take profit reached).
- Motion only where something changed: ledger bars and open interest ease to new widths, the ratio markers slide. All of
  it stops under reduced motion.
