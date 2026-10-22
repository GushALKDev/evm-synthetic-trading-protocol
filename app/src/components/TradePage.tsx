import { useMemo, useState } from 'react'
import { chartSource } from '../config/chain'
import { useMarketCandles } from '../hooks/useMarketCandles'
import { usePriceHistory } from '../hooks/usePriceHistory'
import { TIMEFRAMES, candlesFromRounds, change24h, type Timeframe } from '../lib/chart'
import type { HistoryEntry } from '../lib/history'
import { MARKET_TIMEFRAMES, productOf } from '../lib/market'
import type { Model } from '../lib/model'
import { AccountPanel } from './AccountPanel'
import { MarketBar } from './MarketBar'
import { PriceChart, type ChartLine } from './PriceChart'
import { TradeBox, type OpenPreview } from './TradeBox'

export function TradePage({ model, history, onConnect, onFaucet }: { model: Model; history: HistoryEntry[]; onConnect: () => void; onFaucet: () => void }) {
  const [pairIndex, setPairIndex] = useState(0)
  const market = chartSource === 'market'
  const timeframes = market ? MARKET_TIMEFRAMES : TIMEFRAMES
  const [timeframe, setTimeframe] = useState<Timeframe>(timeframes[0])
  const [preview, setPreview] = useState<OpenPreview | null>(null)
  const pair = model.pairs[pairIndex] ?? model.pairs[0]
  // Over market candles the rounds only serve the 24h change, so a day of them; oracle candles need the view's horizon too
  const rounds = usePriceHistory(pair.chainlinkFeed, { ...timeframe, horizon: market ? 86_400 : Math.max(timeframe.horizon, 86_400) }, model.chainTime)
  const product = productOf(pair.symbol)
  const marketCandles = useMarketCandles(product, timeframe, market)
  const now = Number(model.chainTime)

  // The live reads carry the latest round between two history refreshes
  const allRounds = useMemo(
    () => [...(rounds.data ?? []), { answer: pair.answer, updatedAt: pair.updatedAt }],
    [rounds.data, pair.answer, pair.updatedAt],
  )
  const oracleCandles = useMemo(
    () => (rounds.data && !market ? candlesFromRounds(allRounds, pair.decimals, timeframe.bucket, now - timeframe.horizon, now) : []),
    [rounds.data, market, allRounds, pair.decimals, timeframe, now],
  )
  const candles = market ? marketCandles.candles : oracleCandles
  const change = useMemo(() => (rounds.data ? change24h(allRounds, now) : null), [rounds.data, allRounds, now])

  const lines = useMemo((): ChartLine[] => {
    const own = (model.account?.trades ?? []).filter((t) => t.pair.index === pair.index)
    const out: ChartLine[] = own.flatMap((t) => [
      { price: t.position.openPrice, title: `Entry #${t.id}`, kind: 'entry' as const },
      ...(t.liquidationPrice !== null ? [{ price: t.liquidationPrice, title: `Liq #${t.id}`, kind: 'liquidation' as const }] : []),
      ...(t.position.tp > 0n ? [{ price: t.position.tp, title: `TP #${t.id}`, kind: 'tp' as const }] : []),
      ...(t.position.sl > 0n ? [{ price: t.position.sl, title: `SL #${t.id}`, kind: 'sl' as const }] : []),
    ])
    if (preview) {
      out.push({ price: preview.entry, title: 'Entry', kind: 'entry', preview: true })
      if (preview.liquidation !== null) out.push({ price: preview.liquidation, title: 'Liq', kind: 'liquidation', preview: true })
    }
    return out
  }, [model.account?.trades, pair.index, preview])

  return (
    <div className="terminal">
      <MarketBar model={model} pair={pair} change={change} onSelect={setPairIndex} />
      <div className="terminal-grid">
        <PriceChart
          pair={pair}
          candles={candles}
          product={market ? product : null}
          lines={lines}
          timeframes={timeframes}
          timeframe={timeframe}
          onTimeframe={setTimeframe}
          loading={market ? marketCandles.loading : rounds.isLoading}
          failed={market ? marketCandles.failed : !!rounds.error && !rounds.data}
        />
        <TradeBox model={model} pair={pair} onPreview={setPreview} onConnect={onConnect} onFaucet={onFaucet} />
      </div>
      <AccountPanel model={model} history={history} onConnect={onConnect} />
    </div>
  )
}
