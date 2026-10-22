import { useState } from 'react'
import { useConnection } from 'wagmi'
import { chain, links } from '../config/chain'
import { useActions } from '../hooks/useActions'
import { formatCompact, formatFixed, formatPct, parseAmount, relativeTime, toInput } from '../lib/format'
import type { Model } from '../lib/model'
import { CRITICAL_CR, DEFICIT_CR, SAFE_CR, assetsForShares, epochStart, quoteBond, sharesForAssets } from '../lib/vault'
import { Ledger } from './Ledger'

function when(model: Model, epoch: bigint) {
  const t = epochStart(epoch, model.config.deployTimestamp)
  const date = new Date(Number(t) * 1000).toLocaleString()
  const wait = t > model.chainTime ? `, in ${relativeTime(Number(t - model.chainTime))}` : ''
  return `${date}${wait}`
}

function AmountField({ id, label, aside, unit, decimals, value, onChange, max, invalid }: {
  id: string
  label: string
  aside: string
  unit: string
  decimals: number
  value: string
  onChange: (v: string) => void
  max: bigint
  invalid: boolean
}) {
  return (
    <div className="field">
      <label className="field-label" htmlFor={id}>
        <span>{label}</span>
        <span>{aside}</span>
      </label>
      <div className="input-wrap" data-invalid={invalid}>
        <input id={id} className="amount-input" inputMode="decimal" autoComplete="off" placeholder="0.00" value={value} onChange={(e) => onChange(e.target.value)} />
        <span className="unit">{unit}</span>
        <button className="max" disabled={max === 0n} onClick={() => onChange(toInput(max, decimals))}>
          Max
        </button>
      </div>
    </div>
  )
}

function Liquidity({ model, onConnect, onFaucet }: { model: Model; onConnect: () => void; onFaucet: () => void }) {
  const { status, chainId } = useConnection()
  const actions = useActions(model)
  const [tab, setTab] = useState<'deposit' | 'withdraw'>('deposit')
  const [input, setInput] = useState('')
  const v = model.vault
  const acc = model.account

  if (status !== 'connected' || chainId !== chain.id || !acc) {
    return (
      <div className="card">
        <div className="card-title">
          <h2>Your liquidity</h2>
        </div>
        <div className="empty">
          <p>
            <strong>Connect a wallet to deposit USDC into the vault.</strong> Liquidity providers own the vault: they earn what traders lose and the
            fees, and pay what traders win.
          </p>
          <button className="btn btn-primary" onClick={onConnect}>
            {status === 'connected' ? `Switch to ${chain.name}` : 'Connect wallet'}
          </button>
        </div>
      </div>
    )
  }

  const noGas = acc.data.eth === 0n
  const req = acc.request
  const closed = v.bondActive || v.roundDue

  // Deposit: shares at the NAV after the refresh and the pending reserve injection the deposit runs first
  const assets = parseAmount(input, 6)
  const navForDeposit = v.liveNav + v.pendingInjection
  const sharesOut = assets ? sharesForAssets(assets, v.supply, navForDeposit) : 0n
  let depositError: string | undefined
  if (closed) depositError = 'Deposits are closed while a bonding round is open or due.'
  else if (v.depositsPaused) depositError = 'Deposits are paused by the protocol owner.'
  else if (assets && assets > acc.data.usdc) depositError = 'More than your wallet balance.'

  // Withdrawal request: shares
  const shares = parseAmount(input, 18)
  const requestable = acc.data.shares + (req?.shares ?? 0n)
  let requestError: string | undefined
  if (v.withdrawalsPaused) requestError = 'Withdrawals are paused by the protocol owner.'
  else if (shares && shares > requestable) requestError = 'More than the shares you hold.'

  const expired = !!req && v.epoch >= req.expiryEpoch
  const locked = !!req && v.epoch < req.unlockEpoch
  const payout = req ? assetsForShares(req.shares, v.supply, v.liveNav) : 0n

  return (
    <div className="card">
      <div className="card-title">
        <h2>Your liquidity</h2>
        {acc.data.usdc === 0n && acc.data.shares === 0n ? (
          <button className="link-button" onClick={onFaucet}>
            Get test USDC
          </button>
        ) : null}
      </div>
      <div className="position-main">
        <span className="position-state">{acc.data.shares > 0n || req ? 'Providing liquidity' : 'No vault shares'}</span>
        <span className="position-amount">
          {formatFixed(acc.sharesValue, 6, 2)}
          <small>USDC</small>
        </span>
        <span className="hint">
          {formatFixed(acc.data.shares, 18, 4)} sUSDC in your wallet, valued at the NAV a refresh would store now
          {req ? `, plus ${formatFixed(req.shares, 18, 4)} sUSDC held by the vault for your withdrawal` : ''}.
        </span>
      </div>

      {req ? (
        <div className="callout" style={{ marginTop: 16 }} data-tone={expired ? 'warn' : undefined}>
          {locked
            ? `Withdrawal of ${formatFixed(req.shares, 18, 4)} sUSDC requested. It unlocks ${when(model, req.unlockEpoch)}, then stays executable for one day.`
            : expired
              ? 'Your withdrawal request passed the end of its window. Cancel it to get the shares back, or request again.'
              : `Your withdrawal is executable until ${when(model, req.expiryEpoch)}: about ${formatFixed(payout, 6, 2)} USDC at the current NAV.`}
        </div>
      ) : null}

      <div className="tabs" role="tablist" aria-label="Action" style={{ marginTop: 20 }}>
        {(['deposit', 'withdraw'] as const).map((t) => (
          <button
            key={t}
            role="tab"
            className="tab"
            aria-selected={tab === t}
            onClick={() => {
              setTab(t)
              setInput('')
            }}
          >
            {t === 'deposit' ? 'Deposit' : 'Withdraw'}
          </button>
        ))}
      </div>

      <div className="action" role="tabpanel">
        {tab === 'deposit' ? (
          <>
            <AmountField
              id="deposit"
              label="Amount"
              aside={`Wallet ${formatFixed(acc.data.usdc, 6, 2)} USDC`}
              unit="USDC"
              decimals={6}
              value={input}
              onChange={setInput}
              max={acc.data.usdc}
              invalid={(input.trim() !== '' && assets === null) || (!!assets && !!depositError)}
            />
            {depositError && (assets || closed || v.depositsPaused) ? (
              <span className="hint" data-tone="danger">
                {depositError}
              </span>
            ) : null}
            {assets && !depositError ? (
              <dl className="rows">
                <div className="row">
                  <dt>Shares received</dt>
                  <dd>{formatFixed(sharesOut, 18, 4)} sUSDC</dd>
                </div>
                <div className="row">
                  <dt>Your USDC</dt>
                  <dd>
                    <span className="faint">{formatFixed(acc.data.usdc, 6, 2)}</span>
                    <span className="arrow">to</span>
                    {formatFixed(acc.data.usdc - assets, 6, 2)}
                  </dd>
                </div>
                {v.pendingInjection > 0n ? (
                  <div className="row">
                    <dt>Reserve top-up first</dt>
                    <dd>{formatFixed(v.pendingInjection, 6, 2)} USDC</dd>
                  </div>
                ) : null}
                <div className="row">
                  <dt>Price check</dt>
                  <dd style={{ fontWeight: 400 }} className="muted">
                    The snapshot is refreshed in the same call, at the latest Chainlink prices
                  </dd>
                </div>
              </dl>
            ) : null}
            <button
              className="btn btn-primary btn-block"
              disabled={!assets || !!depositError || !!actions.busy || noGas}
              onClick={async () => (await actions.deposit(assets!, acc.address, acc.data.allowance.vault)) && setInput('')}
            >
              {actions.busy ?? (assets && acc.data.allowance.vault < assets ? 'Approve and deposit USDC' : 'Deposit USDC')}
            </button>
            <p className="hint">Withdrawing later takes a request and a wait of up to three days.</p>
          </>
        ) : req && !expired ? (
          <>
            <dl className="rows">
              <div className="row">
                <dt>Requested</dt>
                <dd>{formatFixed(req.shares, 18, 4)} sUSDC</dd>
              </div>
              <div className="row">
                <dt>Unlocks</dt>
                <dd>{when(model, req.unlockEpoch)}</dd>
              </div>
              <div className="row">
                <dt>Window closes</dt>
                <dd>{when(model, req.expiryEpoch)}</dd>
              </div>
              <div className="row">
                <dt>You would receive now</dt>
                <dd>About {formatFixed(payout, 6, 2)} USDC</dd>
              </div>
            </dl>
            <button className="btn btn-primary btn-block" disabled={!req.canExecute || !!actions.busy || noGas} onClick={() => actions.executeWithdrawal()}>
              {actions.busy ?? (locked ? 'Not unlocked yet' : 'Withdraw USDC')}
            </button>
            <button className="btn btn-block" disabled={!!actions.busy || noGas} onClick={() => actions.cancelWithdrawal()}>
              Cancel request
            </button>
          </>
        ) : (
          <>
            {expired ? (
              <button className="btn btn-block" disabled={!!actions.busy || noGas} onClick={() => actions.cancelWithdrawal()}>
                Cancel the expired request
              </button>
            ) : null}
            <AmountField
              id="withdraw"
              label="Shares to withdraw"
              aside={`You hold ${formatFixed(requestable, 18, 4)} sUSDC`}
              unit="sUSDC"
              decimals={18}
              value={input}
              onChange={setInput}
              max={requestable}
              invalid={(input.trim() !== '' && shares === null) || (!!shares && !!requestError)}
            />
            {requestError && shares ? (
              <span className="hint" data-tone="danger">
                {requestError}
              </span>
            ) : null}
            {shares && !requestError ? (
              <dl className="rows">
                <div className="row">
                  <dt>Worth now</dt>
                  <dd>About {formatFixed(assetsForShares(shares, v.supply, v.liveNav), 6, 2)} USDC</dd>
                </div>
                <div className="row">
                  <dt>Unlocks</dt>
                  <dd>{when(model, v.epoch + 3n)}</dd>
                </div>
                <div className="row">
                  <dt>Then executable until</dt>
                  <dd>{when(model, v.epoch + 4n)}</dd>
                </div>
              </dl>
            ) : null}
            <button className="btn btn-primary btn-block" disabled={!shares || !!requestError || !!actions.busy || noGas} onClick={async () => (await actions.requestWithdrawal(shares!)) && setInput('')}>
              {actions.busy ?? 'Request withdrawal'}
            </button>
            <p className="hint">The shares are held by the vault until you withdraw or cancel. The USDC amount is set by the NAV when you execute.</p>
          </>
        )}
        {noGas ? (
          <div className="callout" data-tone="warn">
            Your wallet has no {chain.name} ETH for gas. Get some from a{' '}
            <a href={links.ethFaucet} target="_blank" rel="noreferrer">
              faucet
            </a>
            .
          </div>
        ) : null}
      </div>
    </div>
  )
}

function Solvency({ model, onConnect }: { model: Model; onConnect: () => void }) {
  const { status } = useConnection()
  const actions = useActions(model)
  const [input, setInput] = useState('')
  const v = model.vault
  const c = model.config
  const acc = model.account
  const connected = status === 'connected' && !!acc

  const usdc = parseAmount(input, 6)
  const taken = usdc ? (usdc > v.bondCapacity ? v.bondCapacity : usdc) : 0n
  const synth = quoteBond(taken, c.referencePrice, c.discountBps)
  const bondError = usdc && acc && usdc > acc.data.usdc ? 'More than your wallet balance.' : undefined

  const levels = [
    { name: 'Healthy', at: `${formatPct(SAFE_CR, 0)} NAV ratio and above`, active: v.level === 'healthy' },
    { name: 'Warning', at: `${formatPct(DEFICIT_CR, 0)} to ${formatPct(SAFE_CR, 0)}, no action`, active: v.level === 'warning' },
    { name: 'Reserve top-up', at: `below ${formatPct(DEFICIT_CR, 0)} NAV ratio`, active: v.level === 'deficit' },
    { name: 'Bonding', at: `below ${formatPct(CRITICAL_CR, 0)} realised ratio`, active: v.level === 'critical' },
  ]

  return (
    <div className="card" id="solvency">
      <div className="card-title">
        <h2>Solvency layers</h2>
        <span className="card-sub">{v.navRatio === null ? 'No shares yet' : `NAV ratio ${formatPct(v.navRatio, 2)}`}</span>
      </div>
      <ol className="layers">
        {levels.map((l) => (
          <li key={l.name} data-active={l.active}>
            <strong>{l.name}</strong>
            <span>{l.at}</span>
          </li>
        ))}
      </ol>
      <dl className="rows" style={{ marginTop: 12 }}>
        <div className="row">
          <dt>Realised ratio</dt>
          <dd>{v.realisedRatio === null ? 'None yet' : formatPct(v.realisedRatio, 2)}</dd>
        </div>
        <div className="row">
          <dt>Reserve fund</dt>
          <dd>
            {formatFixed(v.reserve, 6, 2)} USDC <span className="faint">cap {formatCompact(v.reserveTargetCap, 6)}</span>
          </dd>
        </div>
        <div className="row">
          <dt>Bonding</dt>
          <dd>{v.bondActive ? `Open, ${formatFixed(v.bondCapacity, 6, 2)} USDC still needed` : v.roundDue ? 'Due, not opened yet' : 'No round'}</dd>
        </div>
      </dl>

      {v.roundDue && !v.bondActive ? (
        <div className="action">
          <p className="hint">
            The realised ratio is under {formatPct(CRITICAL_CR, 0)}, so the next solvency check opens a round. That check is permissionless: running it
            refreshes the snapshot, tops up from the reserve first, then opens the round for what is still missing.
          </p>
          <button className="btn btn-primary btn-block" disabled={!connected || !!actions.busy} onClick={() => actions.openBondingRound()}>
            {actions.busy ?? 'Open the bonding round'}
          </button>
          {!connected ? (
            <button className="link-button" style={{ justifySelf: 'start' }} onClick={onConnect}>
              Connect a wallet to run it
            </button>
          ) : null}
        </div>
      ) : null}

      {v.bondActive ? (
        <div className="action">
          <p className="hint">
            Buy SYNTH at {formatFixed((c.referencePrice * (10_000n - c.discountBps)) / 10_000n, 6, 2)} USDC, vested over {(c.vestingPeriod / 3_600n).toString()}{' '}
            hours. The USDC goes to the vault. A bond takes at most what the vault still needs.
          </p>
          <AmountField
            id="bond"
            label="USDC to bond"
            aside={acc ? `Wallet ${formatFixed(acc.data.usdc, 6, 2)} USDC` : ''}
            unit="USDC"
            decimals={6}
            value={input}
            onChange={setInput}
            max={acc ? (acc.data.usdc < v.bondCapacity ? acc.data.usdc : v.bondCapacity) : 0n}
            invalid={(input.trim() !== '' && usdc === null) || !!bondError}
          />
          {bondError ? (
            <span className="hint" data-tone="danger">
              {bondError}
            </span>
          ) : usdc ? (
            <dl className="rows">
              <div className="row">
                <dt>USDC taken</dt>
                <dd>{formatFixed(taken, 6, 2)}</dd>
              </div>
              <div className="row">
                <dt>SYNTH vesting to you</dt>
                <dd>{formatFixed(synth, 18, 4)}</dd>
              </div>
            </dl>
          ) : null}
          <button
            className="btn btn-primary btn-block"
            disabled={!connected || !usdc || taken === 0n || !!bondError || !!actions.busy}
            onClick={async () => (await actions.bond(taken, acc!.data.allowance.bond)) && setInput('')}
          >
            {actions.busy ?? (acc && usdc && acc.data.allowance.bond < taken ? 'Approve and bond USDC' : 'Bond USDC')}
          </button>
        </div>
      ) : null}

      {acc && acc.data.bonds.length > 0 ? (
        <div style={{ marginTop: 16 }}>
          <h3 className="subhead">Your bonds</h3>
          <dl className="rows">
            {acc.data.bonds.map((b) => (
              <div className="row" key={b.id.toString()}>
                <dt>
                  Bond #{b.id.toString()}: {formatFixed(b.totalSynth, 18, 2)} SYNTH,{' '}
                  {b.end > model.chainTime ? `vesting until ${new Date(Number(b.end) * 1000).toLocaleString()}` : 'fully vested'}
                </dt>
                <dd>
                  <button className="btn" disabled={b.claimable === 0n || !!actions.busy} onClick={() => actions.claimBond(b.id)}>
                    Claim {formatFixed(b.claimable, 18, 2)}
                  </button>
                </dd>
              </div>
            ))}
          </dl>
          <p className="hint">The claimable amount is as of the latest block; claiming takes what has vested when it lands.</p>
        </div>
      ) : null}
    </div>
  )
}

export function EarnPage({ model, onConnect, onFaucet }: { model: Model; onConnect: () => void; onFaucet: () => void }) {
  return (
    <>
      <section className="hero">
        <div className="wrap">
          <div className="hero-head">
            <h1>Earn with the vault that takes the other side of every trade.</h1>
            <p className="hero-sub">
              Liquidity providers deposit USDC and hold sUSDC shares. Their share price subtracts the traders' net open profit and never adds a net
              open loss. When it falls below 1.0 a reserve fund tops it up, and a bond sale follows if the realised ratio drops under 95%.
            </p>
          </div>
          <Ledger model={model} />
        </div>
      </section>
      <div className="wrap main-grid">
        <div className="stack">
          <Liquidity model={model} onConnect={onConnect} onFaucet={onFaucet} />
        </div>
        <div className="stack">
          <Solvency model={model} onConnect={onConnect} />
        </div>
      </div>
    </>
  )
}
