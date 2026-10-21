import { useMemo, useState } from 'react'
import { useConnection } from 'wagmi'
import { chain, explorerAddress } from '../config/chain'
import { useActions } from '../hooks/useActions'
import { TRADE_WINDOW, useTrades } from '../hooks/useProtocolData'
import { formatFixed, formatPrice, formatSigned, formatUsd, parseAmount, relativeTime, shortAddress, toInput } from '../lib/format'
import { buildTrade, type Model, type TradeView } from '../lib/model'
import { levelError } from '../lib/trading'
import { PairIcon, SideTag } from './icons'

const CLOSE_SLIPPAGE_BPS = 50n

function tone(x: bigint) {
  return x > 0n ? 'tone-up' : x < 0n ? 'tone-down' : undefined
}

function LevelEditor({ model, t, onDone }: { model: Model; t: TradeView; onDone: () => void }) {
  const actions = useActions(model)
  const [tpInput, setTpInput] = useState(t.position.tp > 0n ? toInput(t.position.tp, 18) : '')
  const [slInput, setSlInput] = useState(t.position.sl > 0n ? toInput(t.position.sl, 18) : '')
  const tp = tpInput.trim() ? parseAmount(tpInput, 18) : 0n
  const sl = slInput.trim() ? parseAmount(slInput, 18) : 0n
  const tpError = tp === null ? 'Enter a price in USD.' : levelError(t.position, 'tp', tp, t.pair.price)
  const slError = sl === null ? 'Enter a price in USD.' : levelError(t.position, 'sl', sl, t.pair.price)

  const field = (kind: 'tp' | 'sl') => {
    const isTp = kind === 'tp'
    const value = isTp ? tp : sl
    const current = isTp ? t.position.tp : t.position.sl
    const err = isTp ? tpError : slError
    const name = isTp ? 'Take profit' : 'Stop loss'
    return (
      <div className="field">
        <label className="field-label" htmlFor={`${kind}-${t.id}`}>
          <span>{name}</span>
          <span>{current > 0n ? `Now ${formatPrice(current)}` : 'Not set'}</span>
        </label>
        <div className="inline-form">
          <div className="input-wrap input-small" data-invalid={!!err && value !== 0n} style={{ flex: 1 }}>
            <span className="unit">$</span>
            <input
              id={`${kind}-${t.id}`}
              className="amount-input"
              inputMode="decimal"
              autoComplete="off"
              placeholder="None"
              value={isTp ? tpInput : slInput}
              onChange={(e) => (isTp ? setTpInput(e.target.value) : setSlInput(e.target.value))}
            />
          </div>
          <button
            className="btn"
            disabled={!!actions.busy || !!err || value === null || value === 0n || value === current}
            onClick={async () => (await actions.setLevel(t, kind, value!)) && onDone()}
          >
            Set
          </button>
          <button className="btn btn-quiet" disabled={!!actions.busy || current === 0n} onClick={async () => (await actions.setLevel(t, kind, 0n)) && onDone()}>
            Clear
          </button>
        </div>
        {err && value !== 0n ? (
          <span className="hint" data-tone="danger">
            {err}
          </span>
        ) : null}
      </div>
    )
  }

  return (
    <div className="levels" style={{ marginTop: 12 }}>
      {field('tp')}
      {field('sl')}
    </div>
  )
}

function PositionCard({ model, t }: { model: Model; t: TradeView }) {
  const actions = useActions(model)
  const [editing, setEditing] = useState(false)
  const { close } = t
  const paysFunding = t.fundingOwed > 0n
  return (
    <div className="position" data-testid={`position-${t.id}`}>
      <div className="position-head">
        <span className="asset">
          <PairIcon symbol={t.pair.symbol} />
          {t.pair.name}
        </span>
        <SideTag isLong={t.position.isLong} leverage={t.position.leverage} />
        <span className="faint">#{t.id.toString()}</span>
        {t.liquidation.liquidatable ? (
          <span className="status" data-tone="danger">
            Liquidatable
          </span>
        ) : t.limit ? (
          <span className="status" data-tone="ok">
            {t.limit === 'tp' ? 'Take profit reached' : 'Stop loss reached'}
          </span>
        ) : null}
      </div>
      <dl className="position-grid">
        <div>
          <dt>Size</dt>
          <dd>{formatUsd(t.sizeWad)}</dd>
        </div>
        <div>
          <dt>Entry</dt>
          <dd>{formatPrice(t.position.openPrice)}</dd>
        </div>
        <div>
          <dt>Price now</dt>
          <dd>{formatPrice(t.pair.price)}</dd>
        </div>
        <div>
          <dt>Liquidation</dt>
          <dd>{t.liquidationPrice === null ? 'Out of range' : `About ${formatPrice(t.liquidationPrice)}`}</dd>
        </div>
        <div>
          <dt>Price PnL</dt>
          <dd className={tone(close.pnl)}>{formatSigned(close.pnl, 6, 2)}</dd>
        </div>
        <div>
          <dt>Funding</dt>
          <dd className={tone(-t.fundingOwed)}>
            {formatSigned(-t.fundingOwed, 6, 2)} <span className="faint">{paysFunding ? 'paid' : t.fundingOwed < 0n ? 'received' : ''}</span>
          </dd>
        </div>
        <div>
          <dt>Take profit</dt>
          <dd>{t.position.tp > 0n ? formatPrice(t.position.tp) : <span className="faint">None</span>}</dd>
        </div>
        <div>
          <dt>Stop loss</dt>
          <dd>{t.position.sl > 0n ? formatPrice(t.position.sl) : <span className="faint">None</span>}</dd>
        </div>
      </dl>
      <p className="position-outcome">
        If closed now: <strong>{formatFixed(close.payout, 6, 2)} USDC</strong> back for {formatFixed(t.position.collateral, 6, 2)} posted,{' '}
        <span className={tone(t.netResult)}>{formatSigned(t.netResult, 6, 2)}</span> after the {formatFixed(close.closeFee, 6, 2)} USDC close fee.
      </p>
      <div className="position-actions">
        <button
          className="btn btn-primary"
          disabled={!!actions.busy || model.settlePaused}
          onClick={() => actions.close(t, close.executionPrice, CLOSE_SLIPPAGE_BPS)}
        >
          {actions.busy ?? 'Close position'}
        </button>
        <button className="btn" aria-expanded={editing} onClick={() => setEditing((e) => !e)}>
          Take profit and stop loss
        </button>
      </div>
      {editing ? <LevelEditor model={model} t={t} onDone={() => setEditing(false)} /> : null}
    </div>
  )
}

export function YourPositions({ model }: { model: Model }) {
  const { status } = useConnection()
  const acc = model.account
  if (status !== 'connected' || !acc) return null
  return (
    <div className="card" id="positions">
      <div className="card-title">
        <h2>Your positions</h2>
        <span className="card-sub">{acc.trades.length === 0 ? 'None open' : `${acc.trades.length} open`}</span>
      </div>
      {acc.trades.length === 0 ? (
        <p className="muted">Positions you open appear here, with their PnL, funding and liquidation price at the current Chainlink price.</p>
      ) : (
        <div className="stack" style={{ gap: 12 }}>
          {acc.trades.map((t) => (
            <PositionCard key={t.id.toString()} model={model} t={t} />
          ))}
        </div>
      )}
      {model.settlePaused ? (
        <div className="callout" data-tone="warn" style={{ marginTop: 14 }}>
          Closing, liquidations and TP/SL are paused by the protocol owner, and no funding accrues meanwhile.
        </div>
      ) : null}
    </div>
  )
}

/* ------------------------------------------------------------------ */
/* All positions                                                       */
/* ------------------------------------------------------------------ */

function Owner({ model, t }: { model: Model; t: TradeView }) {
  if (model.account && t.user.toLowerCase() === model.account.address.toLowerCase()) return <span>You</span>
  return (
    <a className="mono" href={explorerAddress(t.user)} target="_blank" rel="noreferrer">
      {shortAddress(t.user)}
      {t.isSeed ? <span className="sub">seed trade</span> : null}
    </a>
  )
}

export function AllPositions({ model, onConnect }: { model: Model; onConnect: () => void }) {
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
          <h2>Every open position</h2>
          <p>
            Liquidations and take profit or stop loss executions are open to anyone, and each one pays its caller. The status below is computed at the
            current Chainlink price, with funding projected to the latest block; the call itself checks it again on chain.
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
