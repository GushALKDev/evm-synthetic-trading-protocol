import { formatBps, formatCompact, formatPrice, formatRatePerHour, relativeTime } from '../lib/format'
import type { Model, PairView } from '../lib/model'
import { PairIcon } from './icons'

function OpenInterestBar({ pair }: { pair: PairView }) {
  const scale = pair.maxOI > 0n ? pair.maxOI : 1n
  const pct = (x: bigint) => Number((x * 10_000n) / scale) / 100
  return (
    <div>
      <div className="oi-track" role="img" aria-label={`Open interest: long ${formatCompact(pair.oiLong, 18)}, short ${formatCompact(pair.oiShort, 18)}, limit ${formatCompact(pair.maxOI, 18)} USD`}>
        {pair.oiLong > 0n ? <div className="oi-seg" data-side="long" style={{ width: `${Math.max(pct(pair.oiLong), 0.6)}%` }} /> : null}
        {pair.oiShort > 0n ? <div className="oi-seg" data-side="short" style={{ width: `${Math.max(pct(pair.oiShort), 0.6)}%` }} /> : null}
      </div>
      <div className="oi-legend">
        <span data-side="long">Long {formatCompact(pair.oiLong, 18)}</span>
        <span data-side="short">Short {formatCompact(pair.oiShort, 18)}</span>
        <span className="faint">of {formatCompact(pair.maxOI, 18)} USD</span>
      </div>
    </div>
  )
}

function fundingLine(pair: PairView): string {
  const { long, short } = pair.rates
  if (long === 0n && short === 0n) return pair.oiLong === 0n || pair.oiShort === 0n ? 'No funding while a side is empty' : 'Balanced, no funding'
  const payer = long > 0n ? 'Longs' : 'Shorts'
  const paid = long > 0n ? long : short
  const received = long > 0n ? -short : -long
  return `${payer} pay ${formatRatePerHour(paid).replace('+', '')}, the other side receives ${formatRatePerHour(received).replace('+', '')}`
}

export function Markets({ model, selected, onSelect }: { model: Model; selected?: number; onSelect?: (index: number) => void }) {
  return (
    <div className="card">
      <div className="card-title">
        <h2>Markets</h2>
        <span className="card-sub">Chainlink prices on the chain</span>
      </div>
      <div className="markets">
        {model.pairs.map((p) => (
          <div key={p.index} className="market" data-selected={selected === p.index}>
            <div className="market-head">
              <span className="asset">
                <PairIcon symbol={p.symbol} />
                {onSelect ? (
                  <button className="link-button market-name" onClick={() => onSelect(p.index)}>
                    {p.name}
                  </button>
                ) : (
                  p.name
                )}
              </span>
              <span className="market-price">{formatPrice(p.price)}</span>
            </div>
            <div className="hint" data-tone={p.anchorFresh ? undefined : 'warn'}>
              {p.anchorFresh ? `Chainlink updated ${relativeTime(Number(p.anchorAge))} ago` : `Chainlink feed stale for ${relativeTime(Number(p.anchorAge))}`}
              {' · '}spread {formatBps(p.spread)} · up to {p.maxLeverage.toString()}x{p.isActive ? '' : ' · closed to new trades'}
            </div>
            <OpenInterestBar pair={p} />
            <div className="hint">{fundingLine(p)}</div>
          </div>
        ))}
      </div>
    </div>
  )
}
