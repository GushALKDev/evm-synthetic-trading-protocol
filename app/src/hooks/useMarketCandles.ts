import { useQuery } from '@tanstack/react-query'
import { useEffect, useRef, useState } from 'react'
import type { Candle, Timeframe } from '../lib/chart'
import { MARKET_WS, applyTick, candlesUrl, mergeLive, parseCandles } from '../lib/market'

/** The ticker can send several trades a second; the chart redraws at most this often */
const FLUSH_MS = 1_000
const RECONNECT_MS = 5_000

async function fetchCandles(product: string, timeframe: Timeframe): Promise<Candle[]> {
  const res = await fetch(candlesUrl(product, timeframe, Math.floor(Date.now() / 1000)))
  if (!res.ok) throw new Error(`Market candles answered ${res.status}`)
  return parseCandles(await res.json())
}

/**
 * Market candles for a Coinbase product: the REST history, refreshed every minute (Coinbase asks not to poll it often),
 * with the websocket's trades folded into the candle in progress.
 */
export function useMarketCandles(product: string, timeframe: Timeframe, enabled: boolean) {
  const history = useQuery({
    queryKey: ['market-candles', product, timeframe.bucket],
    queryFn: () => fetchCandles(product, timeframe),
    enabled,
    staleTime: 60_000,
    refetchInterval: 60_000,
  })
  const [candles, setCandles] = useState<Candle[]>([])
  const live = useRef<Candle[]>([])
  // Live candles belong to one product and width; cached history of another must not merge with them
  const liveKey = useRef('')
  const key = `${product}:${timeframe.bucket}`

  useEffect(() => {
    const same = liveKey.current === key
    liveKey.current = key
    live.current = history.data ? (same ? mergeLive(history.data, live.current) : history.data) : []
    setCandles(live.current)
  }, [history.data, key])

  useEffect(() => {
    if (!enabled) return
    let ws: WebSocket | null = null
    let retry: ReturnType<typeof setTimeout> | undefined
    let dirty = false
    let closed = false
    const connect = () => {
      ws = new WebSocket(MARKET_WS)
      ws.onopen = () => ws?.send(JSON.stringify({ type: 'subscribe', product_ids: [product], channels: ['ticker'] }))
      ws.onmessage = (m) => {
        const msg = JSON.parse(String(m.data)) as { type?: string; product_id?: string; price?: string; time?: string }
        if (msg.type !== 'ticker' || msg.product_id !== product || !msg.price || !msg.time) return
        const price = Number(msg.price)
        const time = Math.floor(Date.parse(msg.time) / 1000)
        // Ticks before the history arrives have no candles to extend
        if (!Number.isFinite(price) || !Number.isFinite(time) || live.current.length === 0 || liveKey.current !== key) return
        live.current = applyTick(live.current, price, time, timeframe.bucket)
        dirty = true
      }
      ws.onclose = () => {
        if (!closed) retry = setTimeout(connect, RECONNECT_MS)
      }
    }
    connect()
    const flush = setInterval(() => {
      if (!dirty) return
      dirty = false
      setCandles(live.current)
    }, FLUSH_MS)
    return () => {
      closed = true
      clearTimeout(retry)
      clearInterval(flush)
      ws?.close()
    }
  }, [product, timeframe.bucket, key, enabled])

  return { candles, loading: history.isLoading, failed: !!history.error && !history.data }
}
