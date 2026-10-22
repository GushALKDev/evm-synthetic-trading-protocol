import { useMemo, useState } from 'react'
import { usePriceHistory } from '../hooks/usePriceHistory'
import { TIMEFRAMES, candlesFromRounds, change24h, type Timeframe } from '../lib/chart'
import type { HistoryEntry } from '../lib/history'
import type { Model } from '../lib/model'
import { AccountPanel } from './AccountPanel'
import { MarketBar } from './MarketBar'
import { PriceChart, type ChartLine } from './PriceChart'
import { TradeBox, type OpenPreview } from './TradeBox'

export function TradePage({ model, history, onConnect, onFaucet }: { model: Model; history: HistoryEntry[]; onConnect: () => void; onFaucet: () => void }) {
  const [pairIndex, setPairIndex] = useState(0)
  const [timeframe, setTimeframe] = useState<Timeframe>(TIMEFRAMES[0])
  const [preview, setPreview] = useState<OpenPreview | null>(null)
  const pair = model.pairs[pairIndex] ?? model.pairs[0]
  const rounds = usePriceHistory(pair.chainlinkFeed, timeframe, model.chainTime)
  const now = Number(model.chainTime)

  // The live reads carry the latest round between two history refreshes
  const allRounds = useMemo(
    () => [...(rounds.data ?? []), { answer: pair.answer, updatedAt: pair.updatedAt }],
    [rounds.data, pair.answer, pair.updatedAt],
  )
  const candles = useMemo(
    () => (rounds.data ? candlesFromRounds(allRounds, pair.decimals, timeframe.bucket, now - timeframe.horizon, now) : []),
    [rounds.data, allRounds, pair.decimals, timeframe, now],
  )
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
          lines={lines}
          timeframe={timeframe}
          onTimeframe={setTimeframe}
          loading={rounds.isLoading}
          failed={!!rounds.error && !rounds.data}
        />
        <TradeBox model={model} pair={pair} onPreview={setPreview} onConnect={onConnect} onFaucet={onFaucet} />
      </div>
      <AccountPanel model={model} history={history} onConnect={onConnect} />
    </div>
  )
}
