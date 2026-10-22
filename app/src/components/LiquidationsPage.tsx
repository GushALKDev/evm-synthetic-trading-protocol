import { useMemo } from 'react'
import { useConnection } from 'wagmi'
import { chain, explorerAddress } from '../config/chain'
import { useActions } from '../hooks/useActions'
import { TRADE_WINDOW, useTrades } from '../hooks/useProtocolData'
import { formatFixed, formatPrice, formatSigned, formatUsd, relativeTime, shortAddress } from '../lib/format'
import { buildTrade, type Model, type TradeView } from '../lib/model'
import { SideTag } from './icons'

const tone = (x: bigint) => (x > 0n ? 'tone-up' : x < 0n ? 'tone-down' : undefined)

function Owner({ model, t }: { model: Model; t: TradeView }) {
  if (model.account && t.user.toLowerCase() === model.account.address.toLowerCase()) return <span>You</span>
  return (
    <a className="mono" href={explorerAddress(t.user)} target="_blank" rel="noreferrer">
      {shortAddress(t.user)}
      {t.isSeed ? <span className="sub">seed trade</span> : null}
    </a>
  )
}

export function LiquidationsPage({ model, onConnect }: { model: Model; onConnect: () => void }) {
  const { status } = useConnection()
  const actions = useActions(model)
  const counter = model.tradeCounter
  const from = counter > BigInt(TRADE_WINDOW) ? counter - BigInt(TRADE_WINDOW) : 0n
  const ids = useMemo(() => Array.from({ length: Number(counter - from) }, (_, i) => counter - 1n - BigInt(i)), [counter, from])
  const raw = useTrades(ids)
  const trades = useMemo(
    () => (raw.data ?? []).map((r) => buildTrade(r, model.pairs, model.deployment, model.config.confBps)).filter((t): t is TradeView => t !== null),
    [raw.data, model.pairs, model.deployment, model.config.confBps],
  )
  const actionable = trades.filter((t) => t.liquidation.liquidatable || t.limit).length
  const connected = status === 'connected'

  return (
    <section className="section">
      <div className="wrap">
        <div className="section-head">
          <h1 className="page-title">Liquidations</h1>
          <p>
            Every open position, with the ones a keeper can act on. Here liquidations and take profit or stop loss executions are manual, as a
            teaching device: anyone can call them from this page and earn the caller's reward. In production a keeper or a liquidation bot
            watches every position and calls them as soon as they qualify, and whoever runs one earns the same reward.
          </p>
          <p>
            A liquidation pays its caller at least 0.5% of the position's collateral; an execution pays up to 0.1% of the notional, out of the
            trader's payout. The status below is computed at the current Chainlink price, with funding projected to the latest block, and the
            call checks it again on chain. Results compare the payout if closed now with the collateral left after the open fee.
          </p>
        </div>
        <div className="card">
          <div className="card-title">
            <h3>{raw.data === undefined ? 'Reading positions…' : `${trades.length} open, ${actionable} ready for a keeper`}</h3>
            <span className="card-sub">
              {from > 0n ? `Scanning the latest ${TRADE_WINDOW} trade ids of ${counter.toString()}` : `Scanning all ${counter.toString()} trade ids`}
            </span>
          </div>
          {trades.length === 0 && raw.data !== undefined ? (
            <p className="muted">No open positions right now.</p>
          ) : (
            <div className="table-wrap">
              <table>
                <thead>
                  <tr>
                    <th>Position</th>
                    <th>Trader</th>
                    <th className="num">Size</th>
                    <th className="num">Entry</th>
                    <th className="num">Liquidation</th>
                    <th className="num">Result if closed</th>
                    <th>Status</th>
                    <th />
                  </tr>
                </thead>
                <tbody>
                  {trades.map((t) => (
                    <tr key={t.id.toString()} data-testid={`row-${t.id}`}>
                      <td>
                        <span className="asset">
                          #{t.id.toString()} {t.pair.name}
                        </span>
                        <span className="sub">
                          <SideTag isLong={t.position.isLong} leverage={t.position.leverage} /> opened {relativeTime(Math.max(0, Date.now() / 1000 - Number(t.openedAt)))} ago
                        </span>
                      </td>
                      <td>
                        <Owner model={model} t={t} />
                      </td>
                      <td className="num">{formatUsd(t.sizeWad, 0)}</td>
                      <td className="num">{formatPrice(t.position.openPrice)}</td>
                      <td className="num">{t.liquidationPrice === null ? 'Out of range' : formatPrice(t.liquidationPrice)}</td>
                      <td className={`num ${tone(t.netResult) ?? ''}`}>{formatSigned(t.netResult, 6, 2)}</td>
                      <td>
                        {t.liquidation.liquidatable ? (
                          <span className="status" data-tone="danger">
                            Liquidatable
                          </span>
                        ) : t.limit ? (
                          <span className="status" data-tone="ok">
                            {t.limit === 'tp' ? 'Take profit reached' : 'Stop loss reached'}
                          </span>
                        ) : (
                          <span className="status">Open</span>
                        )}
                      </td>
                      <td>
                        {t.liquidation.liquidatable ? (
                          <button className="btn" disabled={!connected || !!actions.busy || model.settlePaused} onClick={() => actions.liquidate(t)}>
                            Liquidate, earn {formatFixed(t.liquidation.reward, 6, 2)}
                          </button>
                        ) : t.limit && t.limitResult ? (
                          <button className="btn" disabled={!connected || !!actions.busy || model.settlePaused} onClick={() => actions.executeLimit(t)}>
                            Execute, earn {formatFixed(t.limitResult.executorReward, 6, 2)}
                          </button>
                        ) : null}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
          {!connected && actionable > 0 ? (
            <p className="hint" style={{ marginTop: 12 }}>
              <button className="link-button" onClick={onConnect}>
                Connect a wallet
              </button>{' '}
              on {chain.name} to call these; rewards are paid in USDC to the caller.
            </p>
          ) : null}
        </div>
      </div>
    </section>
  )
}
