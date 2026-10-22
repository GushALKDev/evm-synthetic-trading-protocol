# Design notes

## Accent and data colors

The accent is a green in the manner of Hyperliquid's mint (`#97FCE3` on hyperliquid.xyz, read from its page source),
the one change from the demo family's palette, chosen by the owner over the family's Mulberry. In the dark theme it is
that mint; in the light theme a deep green of the same hue, since the mint on white falls far under 3:1. The accent
replaces the family's verdigris everywhere it appears:
primary buttons (as text on the accent soft fill with a faint accent border, the fill of the selected pair in the pair
menu, rather than a solid accent fill), links styled as buttons, selected chips, focus rings, the NAV ratio headline figure, the success toast
icon, and the mark and favicon.

| Role | Light | Dark |
| :-- | :-- | :-- |
| Accent | #0A7566 | #97FCE4 |
| Accent hover | #08665A | #B5FDEC |
| Accent soft | #DCF1EC | #10322C |
| Text on accent | #FFFFFF | #03211C |

Data colors this app adds. Long shares the accent, as on Hyperliquid, where buying is the brand green; the others are
distinct from the accent, danger and warn:

| Role | Light | Dark | Used for |
| :-- | :-- | :-- | :-- |
| Long | #0A7566 | #97FCE4 | Long side tags, long open interest, rising candles |
| Short | #46668A | #8AA6C7 | Short side tags, short open interest |
| Vault holdings | #4B5753 | #A6B1AC | The ledger's "the vault holds" bar |
| Owed to liquidity providers | #7C8883 | #6E7B76 | The ledger's "it owes" bar |

Long and short never rely on color alone: every side tag carries the word Long or Short and an arrow, open interest
figures and bars are labelled with the side, and PnL figures carry an explicit sign. Traders' net open profit is drawn as a hatch
of the holdings grey rather than a fill of its own.

The price chart uses the same tokens: rising candles in the long color and falling ones in danger, with a legend under
the chart that says so. Price lines carry their own label (Entry #4, Liq #4, TP #4, SL #4): entry in ink-2, liquidation
in danger, take profit in accent, stop loss in warn; dashed for the position being typed.

Contrast against the backgrounds, from `node scripts/contrast.mjs`:

| Token | Light: ground, surface, sunken | Dark: ground, surface, sunken |
| :-- | :-- | :-- |
| accent | 4.88, 5.60, 5.16 | 15.40, 14.31, 14.89 |
| long | 4.88, 5.60, 5.16 | 15.40, 14.31, 14.89 |
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

It lives on the Earn page, where liquidity providers decide. The vault against every open trade, drawn as two bars on
one scale: what the vault holds (its USDC) against what it owes
(liquidity providers at 1.0 per share, plus the traders' net open profit when it is positive, winners minus losers, the
amount the share price subtracts). The remainder is
the liquidity providers' surplus, or a hatched shortfall when the vault holds less than it owes. Under the bars, the NAV
ratio and the realised ratio sit on one scale with the three thresholds the SolvencyManager acts on: 95% on the realised
ratio (bonding), 100% and 110% on the NAV ratio (reserve top-up, healthy). It is the protocol's own accounting, valued at
the current Chainlink prices the way a snapshot refresh values it, so a move in BTC or a closed trade moves it.
Everything else stays quiet: the trade page follows the layout traders already know from perpetuals exchanges, and the
only thing it adds to that layout is the protocol's own prices and levels on the chart.

## Shared system

Unchanged from the family: IBM Plex Sans with tabular figures for everything, IBM Plex Mono only for addresses; the
neutral greys for ground, surface, sunken, ink and rules; card and control radii; spacing; danger and warn; sentence case
with no all-caps labels.

## Layout

```
header        wordmark, network, pages, test USDC, wallet
              pages: Trade, Earn, Liquidations, How it works; on a second header row below 1024 px
notice        one line: testnet, for educational purposes, tokens without value, not audited, where prices come from

/              trading terminal, up to 1480 px wide:
               market bar: pair selector (left) | oracle price, 24h change, long OI, short OI, OI cap, funding, spread, leverage
               chart: market candles with the account's levels (left) | trade box (right, 360 px)
               account panel: Positions, Orders (TP and SL), History
/earn          hero: headline + the vault ledger
               grid: your liquidity (deposit, request, cancel, withdraw) | solvency layers, bonds
/liquidations  every open position, with liquidate and execute buttons and the caller's reward
/how-it-works  eight mechanics + the oracle note

footer
```

Two columns from 1024 px, one below; on a phone the terminal stacks as market bar, chart, trade box, account panel.
Every page fits a 360 px screen without horizontal scrolling; tables scroll inside their own frame
(`e2e/layout.spec.ts`).

## Rules

- Copy names what the user does: Open long, Close position, Liquidate, Deposit USDC, Request withdrawal, Bond USDC. The
  toast says what happened: Long opened, Position closed, USDC deposited.
- Every preview shows the numbers the contract will use, with its own rounding: entry price with the spread, fee, size,
  liquidation price, funding for the side, the payout cap, the balance before and after.
- Every write is simulated before the wallet asks for a signature, and a revert arrives as one sentence that says what
  happened and what to do.
- Numbered markers only for a real sequence (the four steps of a priced call). Status pills only where an action
  depends on them (liquidatable, take profit reached).
- Motion only where something changed: ledger bars ease to new widths, the ratio markers slide. All of it stops under
  reduced motion.
- The chart says what it is: market candles from Coinbase, live, while the protocol executes at the oracle price in the
  market bar, which moves when the feed publishes. It keeps TradingView's attribution logo, as the Lightweight Charts
  licence asks (`NOTICE`).
