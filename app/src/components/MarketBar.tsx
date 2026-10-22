import { useEffect, useRef, useState } from 'react'
import { formatBps, formatCompact, formatPrice, formatRatePerHour, relativeTime } from '../lib/format'
import type { Model, PairView } from '../lib/model'
import { PairIcon } from './icons'

function Chevron() {
  return (
    <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true">
      <path d="M3.5 5.5L7 9l3.5-3.5" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
    </svg>
  )
}

function PairSelector({ pairs, selected, onSelect }: { pairs: PairView[]; selected: PairView; onSelect: (index: number) => void }) {
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!open) return
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && setOpen(false)
    const onClick = (e: MouseEvent) => !ref.current?.contains(e.target as Node) && setOpen(false)
    window.addEventListener('keydown', onKey)
    window.addEventListener('mousedown', onClick)
    return () => {
      window.removeEventListener('keydown', onKey)
      window.removeEventListener('mousedown', onClick)
    }
  }, [open])
  return (
    <div className="pair-select" ref={ref}>
      <button className="pair-button" aria-haspopup="listbox" aria-expanded={open} onClick={() => setOpen((o) => !o)}>
        <PairIcon symbol={selected.symbol} />
        <span className="pair-name">{selected.name}</span>
        <Chevron />
      </button>
      {open ? (
        <ul className="card pair-menu" role="listbox" aria-label="Pairs">
          {pairs.map((p) => (
            <li key={p.index} role="option" aria-selected={p.index === selected.index}>
              <button
                onClick={() => {
                  onSelect(p.index)
                  setOpen(false)
                }}
              >
                <span className="asset">
                  <PairIcon symbol={p.symbol} />
                  {p.name}
                </span>
                <span>{formatPrice(p.price)}</span>
                <span className="faint">up to {p.maxLeverage.toString()}x</span>
              </button>
            </li>
          ))}
        </ul>
      ) : null}
    </div>
  )
}

function fundingText(pair: PairView): string {
  const { long, short } = pair.rates
  if (long === 0n && short === 0n) return pair.oiLong === 0n || pair.oiShort === 0n ? 'None while a side is empty' : 'None, balanced'
  return long > 0n ? `Longs pay ${formatRatePerHour(long).replace('+', '')}` : `Shorts pay ${formatRatePerHour(short).replace('+', '')}`
}

export function MarketBar({ model, pair, change, onSelect }: { model: Model; pair: PairView; change: number | null; onSelect: (index: number) => void }) {
  return (
    <section className="market-bar" aria-label="Market">
      <PairSelector pairs={model.pairs} selected={pair} onSelect={onSelect} />
      <dl className="market-stats">
        <div>
          <dt>Oracle price</dt>
          <dd className="market-price">{formatPrice(pair.price)}</dd>
        </div>
        <div>
          <dt>24h change</dt>
          <dd className={change === null ? 'faint' : change > 0 ? 'tone-up' : change < 0 ? 'tone-down' : undefined}>
            {change === null ? 'Not enough history' : `${change > 0 ? '+' : ''}${(change * 100).toFixed(2)}%`}
          </dd>
        </div>
        <div>
          <dt>Long OI, USD</dt>
          <dd>
            <span className="oi-text" data-side="long">
              {formatCompact(pair.oiLong, 18)}
            </span>
          </dd>
        </div>
        <div>
          <dt>Short OI, USD</dt>
          <dd>
            <span className="oi-text" data-side="short">
              {formatCompact(pair.oiShort, 18)}
            </span>
          </dd>
        </div>
        <div>
          {/* The cap applies to both sides together */}
          <dt>OI cap, both sides</dt>
          <dd>
            {formatCompact(pair.oiLong + pair.oiShort, 18)} <span className="faint">of {formatCompact(pair.maxOI, 18)}</span>
          </dd>
        </div>
        <div>
          <dt>Funding</dt>
          <dd>{fundingText(pair)}</dd>
        </div>
        <div>
          <dt>Spread</dt>
          <dd>{formatBps(pair.spread)}</dd>
        </div>
        <div>
          <dt>Max leverage</dt>
          <dd>{pair.maxLeverage.toString()}x</dd>
        </div>
        <div>
          <dt>Chainlink round</dt>
          <dd className={pair.anchorFresh ? undefined : 'tone-warn'}>
            {pair.anchorFresh ? `${relativeTime(Number(pair.anchorAge))} ago` : `Stale for ${relativeTime(Number(pair.anchorAge))}`}
          </dd>
        </div>
      </dl>
    </section>
  )
}
