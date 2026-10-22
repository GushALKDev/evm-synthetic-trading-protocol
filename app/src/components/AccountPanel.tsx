import { useState } from 'react'
import { useConnection } from 'wagmi'
import { chain, explorerAddress, explorerTx } from '../config/chain'
import { useActions } from '../hooks/useActions'
import { formatBps, formatFixed, formatPrice, formatSigned, formatUsd, parseAmount, toInput } from '../lib/format'
import type { HistoryEntry } from '../lib/history'
import type { Model, TradeView } from '../lib/model'
import { CLOSE_FEE_BPS, levelError } from '../lib/trading'
import { SideTag } from './icons'
import { Dialog } from './Wallet'

const CLOSE_SLIPPAGE_BPS = 50n

const tone = (x: bigint) => (x > 0n ? 'tone-up' : x < 0n ? 'tone-down' : undefined)

function Market({ t }: { t: TradeView }) {
  return (
    <>
      <span className="asset">{t.pair.name}</span>
      <span className="sub">
        <SideTag isLong={t.position.isLong} leverage={t.position.leverage} /> #{t.id.toString()}
      </span>
    </>
  )
}

/* ------------------------------------------------------------------ */
/* Take profit and stop loss                                           */
/* ------------------------------------------------------------------ */

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
    return (
      <div className="field">
        <label className="field-label" htmlFor={`${kind}-${t.id}`}>
          <span>{isTp ? 'Take profit' : 'Stop loss'}</span>
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
    <div className="stack" style={{ gap: 14 }}>
      <p className="hint">
        {t.pair.name} {t.position.isLong ? 'long' : 'short'} #{t.id.toString()}, entry {formatPrice(t.position.openPrice)}, price now{' '}
        {formatPrice(t.pair.price)}. Once the oracle price reaches a level, anyone can execute it, for 0.1% of the notional out of your payout.
      </p>
      {field('tp')}
      {field('sl')}
    </div>
  )
}

/* ------------------------------------------------------------------ */
/* Tabs                                                                */
/* ------------------------------------------------------------------ */

function PositionsTab({ model, onEdit }: { model: Model; onEdit: (t: TradeView) => void }) {
  const actions = useActions(model)
  const trades = model.account?.trades ?? []
  if (trades.length === 0) return <p className="muted panel-empty">No open positions. Positions you open show here with their result at the current price.</p>
  return (
    <>
      <div className="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Market</th>
              <th className="num">Size</th>
              <th className="num">Collateral</th>
              <th className="num">Entry</th>
              <th className="num">Price</th>
              <th className="num">Liquidation</th>
              <th className="num">Result if closed</th>
              <th className="num">Funding</th>
              <th className="num">TP / SL</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {trades.map((t) => (
              <tr key={t.id.toString()} data-testid={`position-${t.id}`}>
                <td>
                  <Market t={t} />
                </td>
                <td className="num">{formatUsd(t.sizeWad)}</td>
                <td className="num">{formatFixed(t.position.collateral, 6, 2)}</td>
                <td className="num">{formatPrice(t.position.openPrice)}</td>
                <td className="num">{formatPrice(t.pair.price)}</td>
                <td className="num">
                  {t.liquidationPrice === null ? 'Out of range' : formatPrice(t.liquidationPrice)}
                  {t.liquidation.liquidatable ? (
                    <span className="sub tone-down">Liquidatable now</span>
                  ) : null}
                </td>
                <td className="num">
                  <span className={tone(t.netResult)}>{formatSigned(t.netResult, 6, 2)}</span>
                  <span className="sub">
                    {formatFixed(t.close.payout, 6, 2)} back on {formatFixed(t.position.collateral, 6, 2)} USDC of collateral after the open fee
                  </span>
                </td>
                <td className={`num ${tone(-t.fundingOwed) ?? ''}`}>
                  {formatSigned(-t.fundingOwed, 6, 2)}
                  <span className="sub">{t.fundingOwed > 0n ? 'paid' : t.fundingOwed < 0n ? 'received' : ''}</span>
                </td>
                <td className="num">
                  {t.position.tp > 0n ? formatPrice(t.position.tp) : <span className="faint">None</span>}
                  <span className="sub">{t.position.sl > 0n ? formatPrice(t.position.sl) : 'None'}</span>
                </td>
                <td>
                  <div className="row-actions">
                    <button className="btn btn-small" onClick={() => onEdit(t)}>
                      TP / SL
                    </button>
                    <button
                      className="btn btn-small btn-primary"
                      disabled={!!actions.busy || model.settlePaused}
                      onClick={() => actions.close(t, t.close.executionPrice, CLOSE_SLIPPAGE_BPS)}
                    >
                      Close
                    </button>
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="hint panel-note">
        Results compare the payout if closed now, after funding and the {formatBps(CLOSE_FEE_BPS)} close fee, with the collateral left after the open
        fee. Closing sells at the oracle price less the spread.
      </p>
    </>
  )
}

interface Order {
  t: TradeView
  kind: 'tp' | 'sl'
  trigger: bigint
}

function OrdersTab({ model, onEdit }: { model: Model; onEdit: (t: TradeView) => void }) {
  const actions = useActions(model)
  const orders: Order[] = (model.account?.trades ?? []).flatMap((t) => [
    ...(t.position.tp > 0n ? [{ t, kind: 'tp' as const, trigger: t.position.tp }] : []),
    ...(t.position.sl > 0n ? [{ t, kind: 'sl' as const, trigger: t.position.sl }] : []),
  ])
  const note = (
    <p className="hint panel-note">
      The protocol has no limit orders to open a position. These are the take profit and stop loss levels of your open positions: once the oracle
      price reaches one, anyone can execute it, for 0.1% of the notional out of your payout, and it settles like a close.
    </p>
  )
  if (orders.length === 0)
    return (
      <>
        <p className="muted panel-empty">No take profit or stop loss set. Add one from the trade box or from a position's TP / SL button.</p>
        {note}
      </>
    )
  return (
    <>
      <div className="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Market</th>
              <th>Type</th>
              <th className="num">Trigger</th>
              <th className="num">Price</th>
              <th className="num">Distance</th>
              <th>Status</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {orders.map((o) => {
              const reached = o.t.limit === o.kind
              const distance = ((Number(o.trigger) - Number(o.t.pair.price)) / Number(o.t.pair.price)) * 100
              return (
                <tr key={`${o.t.id}-${o.kind}`} data-testid={`order-${o.t.id}-${o.kind}`}>
                  <td>
                    <Market t={o.t} />
                  </td>
                  <td>{o.kind === 'tp' ? 'Take profit' : 'Stop loss'}</td>
                  <td className="num">{formatPrice(o.trigger)}</td>
                  <td className="num">{formatPrice(o.t.pair.price)}</td>
                  <td className="num">{`${distance > 0 ? '+' : ''}${distance.toFixed(2)}%`}</td>
                  <td>
                    {reached ? (
                      <span className="status" data-tone="ok">
                        Reached, executable by anyone
                      </span>
                    ) : (
                      <span className="status">Waiting</span>
                    )}
                  </td>
                  <td>
                    <div className="row-actions">
                      {reached ? (
                        <button className="btn btn-small btn-primary" disabled={!!actions.busy || model.settlePaused} onClick={() => actions.executeLimit(o.t)}>
                          Execute
                        </button>
                      ) : null}
                      <button className="btn btn-small" onClick={() => onEdit(o.t)}>
                        Edit
                      </button>
                      <button className="btn btn-small btn-quiet" disabled={!!actions.busy} onClick={() => actions.setLevel(o.t, o.kind, 0n)}>
                        Cancel
                      </button>
                    </div>
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
      {note}
    </>
  )
}

const kindLabel: Record<HistoryEntry['kind'], string> = {
  closed: 'Closed',
  'take profit': 'Take profit',
  'stop loss': 'Stop loss',
  liquidated: 'Liquidated',
  'closed while away': 'Closed while away',
}

function HistoryTab({ model, history }: { model: Model; history: HistoryEntry[] }) {
  const note = (
    <p className="hint panel-note">
      History is kept in this browser. As a proof of concept this app runs no indexer, and the public RPC answers log queries over 200 blocks at
      most (about 40 seconds on {chain.name}), so it records the settlements of the calls you send from here and the positions that close while
      this page is open. A position that closed while the page was closed shows without amounts; the{' '}
      <a href={explorerAddress(model.account?.address ?? '')} target="_blank" rel="noreferrer">
        explorer
      </a>{' '}
      has the full record.
    </p>
  )
  if (history.length === 0)
    return (
      <>
        <p className="muted panel-empty">No closed positions recorded in this browser yet.</p>
        {note}
      </>
    )
  return (
    <>
      <div className="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Closed</th>
              <th>Market</th>
              <th>How</th>
              <th className="num">Exit price</th>
              <th className="num">Price PnL</th>
              <th className="num">Funding</th>
              <th className="num">Received</th>
              <th className="num">Result</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {history.map((h) => {
              const net = h.payout !== undefined ? BigInt(h.payout) - BigInt(h.collateral) : null
              return (
                <tr key={h.tradeId} data-testid={`history-${h.tradeId}`}>
                  <td>{new Date(h.time * 1000).toLocaleString()}</td>
                  <td>
                    <span className="asset">{h.pair}</span>
                    <span className="sub">
                      <SideTag isLong={h.isLong} leverage={BigInt(h.leverage)} /> #{h.tradeId}
                    </span>
                  </td>
                  <td>{kindLabel[h.kind]}</td>
                  {h.payout === undefined ? (
                    <td className="num faint" colSpan={5}>
                      Not recorded
                    </td>
                  ) : (
                    <>
                      <td className="num">{formatPrice(BigInt(h.closePrice!))}</td>
                      <td className={`num ${tone(BigInt(h.pnl!)) ?? ''}`}>{formatSigned(BigInt(h.pnl!), 6, 2)}</td>
                      <td className="num">{formatSigned(-BigInt(h.funding!), 6, 2)}</td>
                      <td className="num">{formatFixed(BigInt(h.payout), 6, 2)}</td>
                      <td className={`num ${tone(net!) ?? ''}`}>{formatSigned(net!, 6, 2)}</td>
                    </>
                  )}
                  <td>
                    {h.txHash ? (
                      <a href={explorerTx(h.txHash)} target="_blank" rel="noreferrer">
                        Transaction
                      </a>
                    ) : null}
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
      {note}
    </>
  )
}

/* ------------------------------------------------------------------ */
/* Panel                                                               */
/* ------------------------------------------------------------------ */

type Tab = 'positions' | 'orders' | 'history'

export function AccountPanel({ model, history, onConnect }: { model: Model; history: HistoryEntry[]; onConnect: () => void }) {
  const { status, chainId } = useConnection()
  const [tab, setTab] = useState<Tab>('positions')
  const [editing, setEditing] = useState<TradeView | null>(null)
  const trades = model.account?.trades ?? []
  const orders = trades.reduce((n, t) => n + (t.position.tp > 0n ? 1 : 0) + (t.position.sl > 0n ? 1 : 0), 0)
  const connected = status === 'connected' && chainId === chain.id && !!model.account
  // The editor follows the position as the model refreshes, and closes if the position is gone
  const editingNow = editing ? trades.find((t) => t.id === editing.id) : undefined

  const tabs: { id: Tab; label: string }[] = [
    { id: 'positions', label: `Positions${connected ? ` (${trades.length})` : ''}` },
    { id: 'orders', label: `Orders${connected ? ` (${orders})` : ''}` },
    { id: 'history', label: `History${connected ? ` (${history.length})` : ''}` },
  ]

  return (
    <section className="card panel" aria-label="Your account">
      <div className="panel-tabs" role="tablist" aria-label="Your account">
        {tabs.map((t) => (
          <button key={t.id} role="tab" className="panel-tab" aria-selected={tab === t.id} onClick={() => setTab(t.id)}>
            {t.label}
          </button>
        ))}
      </div>
      <div role="tabpanel">
        {!connected ? (
          <div className="panel-empty empty">
            <p>
              <strong>Connect a wallet to see your positions, orders and history.</strong> Everything else on this page reads from the chain without
              one.
            </p>
            <button className="btn btn-primary" onClick={onConnect}>
              Connect wallet
            </button>
          </div>
        ) : tab === 'positions' ? (
          <PositionsTab model={model} onEdit={setEditing} />
        ) : tab === 'orders' ? (
          <OrdersTab model={model} onEdit={setEditing} />
        ) : (
          <HistoryTab model={model} history={history} />
        )}
      </div>
      {editingNow ? (
        <Dialog title="Take profit and stop loss" onClose={() => setEditing(null)}>
          <LevelEditor model={model} t={editingNow} onDone={() => setEditing(null)} />
        </Dialog>
      ) : null}
    </section>
  )
}
