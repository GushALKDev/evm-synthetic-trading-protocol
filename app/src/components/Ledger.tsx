import { chain, explorerAddress } from '../config/chain'
import { formatCompact, formatFixed, formatPct, relativeTime } from '../lib/format'
import type { Model } from '../lib/model'
import { CRITICAL_CR, DEFICIT_CR, SAFE_CR, SHARE_OFFSET, assetsForShares } from '../lib/vault'
import { Link } from './Sections'

interface Segment {
  key: string
  label: string
  value: bigint
  className: string
  /** Only fills with enough contrast for text carry their label inside; the legend names them all */
  text?: boolean
}

function Bar({ segments, scale, label }: { segments: Segment[]; scale: bigint; label: string }) {
  return (
    <div className="bar" role="img" aria-label={label}>
      {segments.map((s) => {
        const share = scale > 0n ? Number((s.value * 10_000n) / scale) / 100 : 0
        if (share <= 0) return null
        return (
          <div key={s.key} className={`seg ${s.className}`} style={{ flex: `0 0 ${Math.max(share, 0.8)}%` }} title={`${s.label}: ${formatCompact(s.value, 6)} USDC`}>
            {s.text && share > 18 ? <span className="seg-text">{s.label}</span> : null}
          </div>
        )
      })}
    </div>
  )
}

const SCALE_LOW = 90n * 10n ** 16n
const SCALE_HIGH = 115n * 10n ** 16n

/** Position of a ratio on the 90% to 115% scale, clamped to its ends */
function at(ratio: bigint): number {
  const clamped = ratio < SCALE_LOW ? SCALE_LOW : ratio > SCALE_HIGH ? SCALE_HIGH : ratio
  return Number(((clamped - SCALE_LOW) * 10_000n) / (SCALE_HIGH - SCALE_LOW)) / 100
}

function RatioScale({ nav, realised }: { nav: bigint | null; realised: bigint | null }) {
  if (nav === null || realised === null) return null
  const ticks = [CRITICAL_CR, DEFICIT_CR, SAFE_CR].map((ratio) => ({ ratio, label: formatPct(ratio, 0) }))
  return (
    <div className="ratio-scale">
      <div className="ratio-track" role="img" aria-label={`NAV ratio ${formatPct(nav, 2)}, realised ratio ${formatPct(realised, 2)}`}>
        <div className="ratio-zone" data-zone="critical" style={{ left: 0, width: `${at(CRITICAL_CR)}%` }} />
        <div className="ratio-zone" data-zone="deficit" style={{ left: `${at(CRITICAL_CR)}%`, width: `${at(DEFICIT_CR) - at(CRITICAL_CR)}%` }} />
        {ticks.map((t) => (
          <div key={t.label} className="ratio-tick" style={{ left: `${at(t.ratio)}%` }} />
        ))}
        <div className="ratio-marker" data-kind="realised" style={{ left: `${at(realised)}%` }} title={`Realised ratio ${formatPct(realised, 2)}`} />
        <div className="ratio-marker" data-kind="nav" style={{ left: `${at(nav)}%` }} title={`NAV ratio ${formatPct(nav, 2)}`} />
      </div>
      <div className="ratio-labels">
        {ticks.map((t) => (
          <span key={t.label} style={{ left: `${at(t.ratio)}%` }}>
            {t.label}
          </span>
        ))}
      </div>
      <p className="ratio-rules">
        Below {formatPct(CRITICAL_CR, 0)} realised: bonding. Below {formatPct(DEFICIT_CR, 0)} NAV: reserve top-up. From {formatPct(SAFE_CR, 0)} NAV: healthy.
      </p>
      <div className="ratio-legend">
        <span>
          <i data-kind="nav" /> NAV ratio {formatPct(nav, 2)}
        </span>
        <span>
          <i data-kind="realised" /> Realised ratio {formatPct(realised, 2)}
        </span>
      </div>
    </div>
  )
}

export function Ledger({ model }: { model: Model }) {
  const v = model.vault
  const held = v.balance
  const lp = v.supply / SHARE_OFFSET
  const profit = v.liveLiability
  const owed = lp + profit
  const surplus = held > owed ? held - owed : 0n
  const shortfall = owed > held ? owed - held : 0n
  const scale = held + shortfall
  const openInterest = model.pairs.reduce((sum, p) => sum + p.oi, 0n)
  // USDC per whole sUSDC at the NAV a refresh would store now
  const sharePrice = v.supply > 0n ? assetsForShares(10n ** 18n, v.supply, v.liveNav) : 10n ** 6n
  const traderLoss = v.liveNetPnl < 0n ? -v.liveNetPnl : 0n

  const heldSegs: Segment[] = [
    { key: 'held', label: 'USDC in the vault', value: held, className: 'seg-held', text: true },
    { key: 'short', label: 'Shortfall', value: shortfall, className: 'seg-shortfall' },
  ]
  const owedSegs: Segment[] = [
    { key: 'lp', label: 'Liquidity providers at 1.0', value: lp, className: 'seg-lp' },
    { key: 'profit', label: "Traders' net open profit", value: profit, className: 'seg-profit' },
    { key: 'surplus', label: 'Surplus for liquidity providers', value: surplus, className: 'seg-surplus', text: true },
  ]

  return (
    <div className="sheet">
      <div className="sheet-top">
        <h2>The vault against every open trade</h2>
        <a className="card-sub" href={explorerAddress(model.deployment.vault)} target="_blank" rel="noreferrer">
          Read live from {chain.name}
        </a>
      </div>
      {scale === 0n ? (
        <p className="muted">Nothing deposited yet. The first deposit will appear here.</p>
      ) : (
        <>
          <div className="sheet-rows">
            <span className="sheet-label">The vault holds</span>
            <Bar segments={heldSegs} scale={scale} label="USDC in the vault, and any shortfall" />
            <span className="sheet-total">{formatCompact(held, 6)}</span>
            <span className="sheet-label">It owes</span>
            <Bar segments={owedSegs} scale={scale} label="Liquidity providers at 1.0 per share, traders' net open profit, and the surplus" />
            <span className="sheet-total">{formatCompact(owed + surplus, 6)}</span>
          </div>
          <div className="legend" style={{ marginTop: 14, marginBottom: 0 }}>
            {[...heldSegs, ...owedSegs]
              .filter((s) => s.value > 0n || s.key === 'profit')
              .map((s) => (
                <span key={s.key}>
                  <i className={s.className} style={{ height: 10, width: 10, borderRadius: 3 }} />
                  {s.label} <strong style={{ fontWeight: 500 }}>{formatCompact(s.value, 6)}</strong>
                </span>
              ))}
          </div>
        </>
      )}
      <RatioScale nav={v.navRatio} realised={v.realisedRatio} />
      <p className="sheet-note">
        Amounts in USDC, valued at the current Chainlink prices the way a snapshot refresh would value them. Trader collateral sits in TradingStorage,
        not here.{' '}
        {traderLoss > 0n
          ? `Traders are down ${formatCompact(traderLoss, 6)} USDC net on their open positions; the vault counts none of it until those trades settle.`
          : 'Winning and losing positions offset each other, and a net open loss is not counted until it settles.'}{' '}
        {v.openTrades > 0n && v.snapshot.timestamp > 0n
          ? `The snapshot stored on chain is ${relativeTime(Number(v.snapshotAge))} old; deposits and withdrawals refresh it in the same call.`
          : null}
      </p>
      {v.bondActive || v.roundDue ? (
        <div className="callout" data-tone="danger" style={{ marginTop: 14 }}>
          {v.bondActive
            ? 'A bonding round is open: deposits are closed until bonds bring the realised ratio back to 100%. '
            : 'The realised ratio is below 95%, so a bonding round is due and deposits are closed. '}
          <Link href="/earn#solvency">See the solvency layers</Link>.
        </div>
      ) : null}
      {model.pairs.some((p) => !p.anchorFresh) ? (
        <div className="callout" data-tone="warn" style={{ marginTop: 14 }}>
          {model.pairs
            .filter((p) => !p.anchorFresh)
            .map((p) => p.name)
            .join(', ')}{' '}
          {model.pairs.filter((p) => !p.anchorFresh).length > 1 ? 'Chainlink feeds have' : 'Chainlink feed has'} not updated within the oracle's
          window, so the oracle refuses those prices until they do.
        </div>
      ) : null}
      <div className="figures">
        <div className="figure">
          <div className="figure-value tone-accent">{v.navRatio === null ? 'None yet' : formatPct(v.navRatio, 2)}</div>
          <div className="figure-label">NAV ratio</div>
        </div>
        <div className="figure">
          <div className="figure-value">{formatFixed(sharePrice, 6, 4)}</div>
          <div className="figure-label">USDC per sUSDC share</div>
        </div>
        <div className="figure">
          <div className="figure-value">{formatCompact(v.reserve, 6)}</div>
          <div className="figure-label">Reserve fund, cap {formatCompact(v.reserveTargetCap, 6)}</div>
        </div>
        <div className="figure">
          <div className="figure-value">{formatCompact(openInterest, 18)}</div>
          <div className="figure-label">Open interest, USD</div>
        </div>
      </div>
    </div>
  )
}
