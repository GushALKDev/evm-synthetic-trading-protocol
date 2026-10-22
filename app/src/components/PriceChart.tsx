// Drawn with TradingView Lightweight Charts, Apache License 2.0. Its attribution notice is in app/NOTICE, and the chart
// keeps the library's attribution logo, which links to https://www.tradingview.com/.
import { useEffect, useRef, useState } from 'react'
import { CandlestickSeries, ColorType, LineStyle, createChart, type IChartApi, type IPriceLine, type ISeriesApi, type UTCTimestamp } from 'lightweight-charts'
import { chain } from '../config/chain'
import type { Candle, Timeframe } from '../lib/chart'
import { priceDecimals } from '../lib/format'
import type { PairView } from '../lib/model'

export interface ChartLine {
  price: bigint
  title: string
  kind: 'entry' | 'liquidation' | 'tp' | 'sl'
  preview?: boolean
}

const token = (name: string) => getComputedStyle(document.documentElement).getPropertyValue(name).trim()

const lineToken: Record<ChartLine['kind'], string> = { entry: '--ink-2', liquidation: '--danger', tp: '--accent', sl: '--warn' }

function themeOptions() {
  return {
    layout: {
      background: { type: ColorType.Solid, color: token('--surface') },
      textColor: token('--ink-2'),
      fontFamily: "'IBM Plex Sans', system-ui, sans-serif",
      attributionLogo: true,
    },
    grid: { vertLines: { color: token('--rule') }, horzLines: { color: token('--rule') } },
    rightPriceScale: { borderColor: token('--rule') },
    timeScale: { borderColor: token('--rule'), timeVisible: true, secondsVisible: false },
  }
}

function seriesColors() {
  const up = token('--long')
  const down = token('--danger')
  return { upColor: up, downColor: down, wickUpColor: up, wickDownColor: down, borderVisible: false }
}

// The chart takes numbers; 18-decimal prices lose nothing visible on the way
const toNumber = (price18: bigint) => Number(price18) / 1e18

export function PriceChart({
  pair,
  candles,
  product,
  lines,
  timeframes,
  timeframe,
  onTimeframe,
  loading,
  failed,
}: {
  pair: PairView
  candles: Candle[]
  /** The market product the candles come from, or null when they are the oracle's own rounds */
  product: string | null
  lines: ChartLine[]
  timeframes: Timeframe[]
  timeframe: Timeframe
  onTimeframe: (t: Timeframe) => void
  loading: boolean
  failed: boolean
}) {
  const box = useRef<HTMLDivElement>(null)
  const chartRef = useRef<IChartApi | null>(null)
  const seriesRef = useRef<ISeriesApi<'Candlestick'> | null>(null)
  const linesRef = useRef<IPriceLine[]>([])
  // Bumped when the color scheme changes, so the price lines are redrawn in the new colors
  const [scheme, setScheme] = useState(0)

  useEffect(() => {
    const chart = createChart(box.current!, { autoSize: true, ...themeOptions() })
    const series = chart.addSeries(CandlestickSeries, seriesColors())
    chartRef.current = chart
    seriesRef.current = series
    const media = window.matchMedia('(prefers-color-scheme: dark)')
    const onScheme = () => {
      chart.applyOptions(themeOptions())
      series.applyOptions(seriesColors())
      setScheme((n) => n + 1)
    }
    media.addEventListener('change', onScheme)
    return () => {
      media.removeEventListener('change', onScheme)
      chart.remove()
      chartRef.current = null
      seriesRef.current = null
      linesRef.current = []
    }
  }, [])

  const precision = priceDecimals(pair.price)
  useEffect(() => {
    seriesRef.current?.applyOptions({ priceFormat: { type: 'price', precision, minMove: 10 ** -precision } })
    // Grouped like every other price on the page
    const format = (p: number) => p.toLocaleString('en-US', { minimumFractionDigits: precision, maximumFractionDigits: precision })
    chartRef.current?.applyOptions({ localization: { priceFormatter: format } })
  }, [precision])

  useEffect(() => {
    seriesRef.current?.setData(candles.map((c) => ({ ...c, time: c.time as UTCTimestamp })))
  }, [candles])

  // Fit the view when the pair or the timeframe changes, once candles are there
  const hasCandles = candles.length > 0
  useEffect(() => {
    if (hasCandles) chartRef.current?.timeScale().fitContent()
  }, [pair.index, timeframe.label, hasCandles])

  useEffect(() => {
    const series = seriesRef.current
    if (!series) return
    for (const line of linesRef.current) series.removePriceLine(line)
    linesRef.current = lines.map((l) =>
      series.createPriceLine({
        price: toNumber(l.price),
        color: token(lineToken[l.kind]),
        lineWidth: 1,
        lineStyle: l.preview ? LineStyle.Dashed : l.kind === 'entry' ? LineStyle.Solid : LineStyle.Dotted,
        axisLabelVisible: true,
        title: l.title,
      }),
    )
  }, [lines, scheme])

  const kinds = new Set(lines.map((l) => l.kind))
  return (
    <section className="card chart-card" aria-label={`${pair.name} price chart`}>
      <div className="chart-head">
        <div className="choice" role="group" aria-label="Candle width">
          {timeframes.map((t) => (
            <button key={t.label} className="chip chip-small" aria-pressed={t.label === timeframe.label} onClick={() => onTimeframe(t)}>
              {t.label}
            </button>
          ))}
        </div>
        <div className="chart-legend">
          {(['entry', 'liquidation', 'tp', 'sl'] as const)
            .filter((k) => kinds.has(k))
            .map((k) => (
              <span key={k} data-kind={k}>
                <i />
                {k === 'entry' ? 'Entry' : k === 'liquidation' ? 'Liquidation' : k === 'tp' ? 'Take profit' : 'Stop loss'}
              </span>
            ))}
        </div>
      </div>
      {/* The library owns the box's children, so the state message is a sibling laid over it */}
      <div
        className="chart-frame"
        role="img"
        aria-label={
          product
            ? `${pair.name}, ${timeframe.label} market candles from Coinbase ${product}`
            : `${pair.name}, ${timeframe.label} candles of the Chainlink price`
        }
      >
        <div className="chart-box" ref={box} />
        {loading || failed || !hasCandles ? (
          <div className="chart-state">
            {failed
              ? `The price history could not be read from ${product ? 'Coinbase' : 'the RPC'}. The page retries on its own.`
              : loading
                ? 'Reading the price history…'
                : 'No price history yet.'}
          </div>
        ) : null}
      </div>
      {product ? (
        <p className="chart-note">
          Candles: {product} trades on Coinbase Exchange, live. The protocol executes at the Chainlink {pair.name} price on {chain.name},
          shown above the chart as the oracle price. The feed publishes a round when the price moves past its deviation threshold or its
          heartbeat passes, so your fill can differ from the last candle. Rising candles are teal and falling ones red; dashed lines preview
          the position you are typing.
        </p>
      ) : (
        <p className="chart-note">
          Chainlink {pair.name} on {chain.name}, the price the protocol executes at. It moves when the feed publishes a new round, not every
          second. Rising candles are teal and falling ones red; dashed lines preview the position you are typing.
        </p>
      )}
    </section>
  )
}
