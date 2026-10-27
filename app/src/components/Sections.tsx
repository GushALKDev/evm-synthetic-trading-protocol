import type { ComponentProps } from 'react'
import { chain, explorerAddress, links } from '../config/chain'
import { LEGAL_PATH, navigate, pages, type Page } from '../hooks/useRoute'
import { formatBps, formatCompact, formatFixed, formatPct } from '../lib/format'
import type { Model } from '../lib/model'
import { CLOSE_FEE_BPS, EXEC_REWARD_BPS, FEE_VAULT_SPLIT_BPS, LIQUIDATION_THRESHOLD_BPS, LIQUIDATOR_MIN_REWARD_BPS, LIQUIDATOR_REWARD_BPS, MAX_FUNDING_RATE_PER_HOUR, MAX_PROFIT_MULTIPLIER, OI_PRECISION, OPEN_FEE_BPS } from '../lib/trading'
import { CRITICAL_CR, DEFICIT_CR, SAFE_CR } from '../lib/vault'
import { Mark } from './icons'
import { WalletButton } from './Wallet'

/** Link to a page of this app: a plain click switches page without a reload, a modified click keeps the browser's behavior. */
export function Link({ href, ...rest }: ComponentProps<'a'> & { href: string }) {
  return (
    <a
      href={href}
      {...rest}
      onClick={(e) => {
        if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return
        e.preventDefault()
        navigate(href)
      }}
    />
  )
}

/** The trade page is a wider terminal; the header, notice and footer line up with it there */
const wrapFor = (page: Page) => (page === 'trade' ? 'wrap wrap-wide' : 'wrap')

export function Header({ page, onConnect, onFaucet }: { page: Page; onConnect: () => void; onFaucet: () => void }) {
  return (
    <header className="site-header">
      <div className={wrapFor(page)}>
        <Link className="wordmark" href="/">
          <Mark />
          Synthetic Trading
        </Link>
        <span className="network">{chain.name}</span>
        <nav className="page-nav" aria-label="Pages">
          {pages.map((p) => (
            <Link key={p.page} className="page-link" href={p.path} aria-current={p.page === page ? 'page' : undefined}>
              {p.label}
            </Link>
          ))}
        </nav>
        <div className="header-actions">
          <button className="btn btn-faucet" onClick={onFaucet} aria-label="Get test USDC">
            <span>Test USDC</span>
            <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true">
              <path d="M8 2.5c2 2.6 3.5 4.6 3.5 6.6a3.5 3.5 0 0 1-7 0c0-2 1.5-4 3.5-6.6z" fill="none" stroke="currentColor" strokeWidth="1.4" />
            </svg>
          </button>
          <WalletButton onConnect={onConnect} />
        </div>
      </div>
    </header>
  )
}

export function Notice({ page }: { page: Page }) {
  return (
    <div className="notice">
      <div className={wrapFor(page)}>
        Testnet proof of concept for educational purposes, with tokens that have no value. Not audited. Prices are Chainlink's, mirrored through a Pyth stand-in:{' '}
        <Link href="/how-it-works#oracle">how and why</Link>.
      </div>
    </div>
  )
}

const bps = (x: bigint) => formatBps(x)

/** The anchors' staleness windows, one figure when every pair shares it */
function formatHeartbeats(model: Model): string {
  const windows = [...new Set(model.pairs.map((p) => p.heartbeat.toString()))]
  return windows.map((w) => `${Number(w).toLocaleString('en-US')} s`).join(', ')
}

export function HowItWorks({ model }: { model: Model }) {
  const c = model.config
  const s = c.spread
  const volatilities = model.pairs.map((p) => p.volatility)
  const noVolatility = volatilities.every((v) => v === 0n)
  // 10M of open interest at 18 decimals, in bps through the impact factor
  const impactPer10M = (10_000_000n * 10n ** 18n * s.impactFactor) / OI_PRECISION
  const discountedPrice = (c.referencePrice * (10_000n - c.discountBps)) / 10_000n
  const vestingHours = c.vestingPeriod / 3_600n
  return (
    <section className="section" id="how">
      <div className="wrap">
        <div className="section-head">
          <h2>How this protocol works</h2>
          <p>
            Eight mechanics shape every number on these pages. Each one is written up in the repository's{' '}
            <a href={links.docs} target="_blank" rel="noreferrer">
              docs
            </a>
            .
          </p>
        </div>
        <div className="mechanics">
          <div className="mechanic">
            <h3>The vault takes the other side</h3>
            <p>
              Every trade is opened against one USDC vault. A winning trade is paid from the vault's USDC and a losing trade's collateral goes to
              it. Trader collateral is held apart, in TradingStorage, so liquidity providers cannot withdraw it. Price PnL is capped at{' '}
              {(MAX_PROFIT_MULTIPLIER - 1n).toString()} times the collateral, so a position returns at most {MAX_PROFIT_MULTIPLIER.toString()} times
              what it put up, before funding and the closing fee.
            </p>
          </div>
          <div className="mechanic">
            <h3>A conservative NAV</h3>
            <p>
              The share price is the vault's USDC balance minus the traders' net open profit, when it is positive: winners minus losers across
              every pair, at the edge of the oracle's confidence band that is highest for them, before closing costs and the payout cap. A net open
              loss is not counted until it settles. That value is a snapshot stored on chain: deposits and withdrawals refresh it in the same call,
              at the prices they carry.
            </p>
          </div>
          <div className="mechanic">
            <h3>Fees and spread</h3>
            <p>
              {OPEN_FEE_BPS === CLOSE_FEE_BPS
                ? `Opening and closing each cost ${bps(OPEN_FEE_BPS)} of the notional, `
                : `Opening costs ${bps(OPEN_FEE_BPS)} of the notional and closing ${bps(CLOSE_FEE_BPS)}, `}
              {bps(FEE_VAULT_SPLIT_BPS)} to the vault and the rest to the reserve fund. The execution price also moves against the trader by a
              spread of at most {bps(s.maxSpreadBps)}: {bps(s.baseSpreadBps)} plus {bps(impactPer10M)} for every 10 million USD of the pair's open
              interest, plus a volatility term a keeper sets{noVolatility ? ' (no keeper updates it on this deployment, so it is zero here)' : ''}.
            </p>
          </div>
          <div className="mechanic">
            <h3>Funding between traders</h3>
            <p>
              When one side of a pair carries more open interest, it pays the other side, pro rata. The rate is the funding factor, currently{' '}
              {formatPct(c.fundingFactor, 4)} per hour, times the skew (the gap between the two sides over their total), and never above{' '}
              {formatPct(MAX_FUNDING_RATE_PER_HOUR, 2)} of the heavy side's notional per hour. Nothing accrues while either side is empty. It accrues
              every second and settles when the position closes. It is a transfer between traders: the vault only carries what a payer cannot
              cover once its loss exceeds its collateral.
            </p>
          </div>
          <div className="mechanic">
            <h3>Liquidation</h3>
            <p>
              Anyone can liquidate a position once its loss, after funding, reaches {bps(LIQUIDATION_THRESHOLD_BPS)} of its collateral. The check
              takes the edge of the confidence band that favours the trader, then the closing spread. The liquidator earns{' '}
              {bps(LIQUIDATOR_REWARD_BPS)} of what is left of the collateral, at least {bps(LIQUIDATOR_MIN_REWARD_BPS)} of it, and the rest goes to the
              vault. A new position the spread alone would put at that threshold is refused.
            </p>
          </div>
          <div className="mechanic">
            <h3>Take profit and stop loss</h3>
            <p>
              Levels are stored with the position. Once the oracle price reaches one, anyone can execute it and earn {bps(EXEC_REWARD_BPS)} of the
              notional, taken from the trader's payout and never more than it. It settles like a close: closing spread, funding and the{' '}
              {bps(CLOSE_FEE_BPS)} fee.
            </p>
          </div>
          <div className="mechanic">
            <h3>Withdrawals wait</h3>
            <p>
              Days are counted in epochs from the deployment. A withdrawal request hands its shares to the vault, unlocks at the start of the third
              epoch after the one it was made in, and can be executed during that epoch only, at the NAV of that moment. After that it can be
              cancelled or replaced. The wait keeps liquidity providers from leaving just ahead of a payout they can see coming.
            </p>
          </div>
          <div className="mechanic">
            <h3>Three solvency layers</h3>
            <p>
              The vault is the first. Below a {formatPct(DEFICIT_CR, 0)} NAV ratio, a permissionless check moves USDC from the reserve fund, up to the
              deficit, as long as the snapshot is fresh (the check can refresh it first). The fund receives the reserve share of every fee, and
              anyone can move what it holds above {formatCompact(c.reserveTargetCap, 6)} USDC to the vault. Below a {formatPct(CRITICAL_CR, 0)} realised ratio
              (USDC balance per share, open PnL ignored), a bonding round opens: anyone can buy SYNTH at {formatFixed(discountedPrice, 6, 2)} USDC,{' '}
              {bps(c.discountBps)} under its {formatFixed(c.referencePrice, 6, 2)} reference, vested over {vestingHours.toString()} hours, and the USDC
              goes to the vault until it is back at {formatPct(DEFICIT_CR, 0)}. Deposits are closed while a round is open or due. From{' '}
              {formatPct(SAFE_CR, 0)} the vault counts as healthy.
            </p>
          </div>
        </div>

        <div className="oracle-note" id="oracle">
          <div>
            <h3>Where the prices come from</h3>
            <p>
              In the production configuration (script/Deploy.s.sol) the oracle reads Pyth, a pull oracle, and checks every price against a Chainlink
              anchor. Since the Pyth Core upgrade of 26 August 2026, Pyth's Hermes API serves price updates only with an API key (
              <a href={links.pythUpgrade} target="_blank" rel="noreferrer">
                Pyth's notice
              </a>
              ), and a key in a public static page would be readable by every visitor. So this deployment swaps Pyth for{' '}
              <a href={explorerAddress(model.deployment.pyth)} target="_blank" rel="noreferrer">
                DemoPyth
              </a>
              , a testnet-only stand-in.
            </p>
            <p>
              DemoPyth checks no signatures, but it only stores a price equal to the current answer of the Chainlink feed registered for it, with a
              fixed {bps(c.confBps)} confidence half-width, and checks it again when the oracle reads it, so nobody can pick a price. A call that
              brings no update reverts once Chainlink has moved, so no call reads a previous answer. The oracle contract is the repository's own,
              unchanged: it still rejects a price stamped more than {c.maxPriceAge.toString()} seconds before the call lands (raised from its 5
              second default to the most the contract allows), a confidence above 2%, or a Chainlink answer older than its window,{' '}
              {formatHeartbeats(model)} on this deployment. Its 3% deviation check still runs but cannot fire here, since the price is the anchor.
              If Chainlink publishes a new answer while your transaction is pending, DemoPyth refuses the old one and the call reverts; sending it
              again works.
            </p>
            <p>{chain.name} has no Chainlink sequencer uptime feed, so the oracle's sequencer checks are off on this deployment.</p>
          </div>
          <div className="flow" aria-label="What happens in a call that needs a price">
            <p className="muted" style={{ marginBottom: 4 }}>
              In every call that needs a price, such as opening a position:
            </p>
            <div className="flow-step">
              <b>1</b>
              <span>The app reads the latest Chainlink answer for the pair on {chain.name}.</span>
            </div>
            <div className="flow-step">
              <b>2</b>
              <span>It encodes it as a Pyth price with a {bps(c.confBps)} confidence half-width, timestamped with the latest block.</span>
            </div>
            <div className="flow-step">
              <b>3</b>
              <span>The engine forwards it to the oracle, which stores it in DemoPyth (refused unless it equals the Chainlink answer) and validates it.</span>
            </div>
            <div className="flow-step">
              <b>4</b>
              <span>Only then does the engine price the trade, all inside the same transaction.</span>
            </div>
          </div>
        </div>
      </div>
    </section>
  )
}

export function Footer({ model, page }: { model: Model | null; page: Page }) {
  return (
    <footer className="site-footer">
      <div className={wrapFor(page)}>
        <p>Proof of concept, not audited, for educational purposes. Testnet tokens have no value.</p>
        <nav className="footer-links" aria-label="Links">
          <a href={links.repo} target="_blank" rel="noreferrer">
            Source code
          </a>
          <a href={links.docs} target="_blank" rel="noreferrer">
            Documentation
          </a>
          {model ? (
            <a href={explorerAddress(model.deployment.engine)} target="_blank" rel="noreferrer">
              Contract
            </a>
          ) : null}
          <span>
            Built by{' '}
            <a href={links.author} target="_blank" rel="noreferrer">
              Gustavo Martín
            </a>{' '}
            at{' '}
            <a href={links.tesselium} target="_blank" rel="noopener">
              Tesselium Labs
            </a>
          </span>
          <Link href={LEGAL_PATH}>Legal</Link>
        </nav>
      </div>
    </footer>
  )
}
