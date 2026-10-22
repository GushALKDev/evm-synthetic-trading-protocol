import { useEffect, useState } from 'react'
import { useConnection, useSwitchChain } from 'wagmi'
import { chain, links } from '../config/chain'
import { useActions } from '../hooks/useActions'
import { formatBps, formatFixed, formatPrice, formatRatePerHour, formatUsd, parseAmount, toInput } from '../lib/format'
import type { Model, PairView } from '../lib/model'
import { MAX_PROFIT_MULTIPLIER, MIN_COLLATERAL, fundingRates, liquidationAnswer, quoteOpen } from '../lib/trading'
import { SideTag } from './icons'

const SLIPPAGES = [10n, 50n, 100n]
const LEVERAGE_CHIPS = [2n, 5n, 10n, 25n, 50n, 100n]
const UINT64_MAX = 2n ** 64n - 1n

/** Entry and liquidation of the position being typed, drawn on the chart as a preview */
export interface OpenPreview {
  entry: bigint
  liquidation: bigint | null
}

export function TradeBox({ model, pair, onPreview, onConnect, onFaucet }: { model: Model; pair: PairView; onPreview: (p: OpenPreview | null) => void; onConnect: () => void; onFaucet: () => void }) {
  const { status, chainId } = useConnection()
  const switchChain = useSwitchChain()
  const actions = useActions(model)
  const [isLong, setIsLong] = useState(true)
  const [input, setInput] = useState('')
  const [leverage, setLeverage] = useState(10n)
  const [slippage, setSlippage] = useState(50n)
  const [showLevels, setShowLevels] = useState(false)
  const [tpInput, setTpInput] = useState('')
  const [slInput, setSlInput] = useState('')

  const acc = model.account
  const wallet = acc?.data.usdc ?? 0n
  const collateral = parseAmount(input, 6)
  const tp = tpInput.trim() ? parseAmount(tpInput, 18) : 0n
  const sl = slInput.trim() ? parseAmount(slInput, 18) : 0n
  const lev = leverage > pair.maxLeverage ? pair.maxLeverage : leverage

  const quote = collateral ? quoteOpen({ isLong, collateral, leverage: lev, tp: tp ?? 0n, sl: sl ?? 0n }, pair.price, pair.spreadAt, pair.oi, pair.maxOI) : null
  const liqAnswer = quote
    ? liquidationAnswer(
        { isLong, collateral: quote.effectiveCollateral, leverage: lev, openPrice: quote.executionPrice, tp: 0n, sl: 0n },
        0n,
        pair.spreadAt(quote.oiAfter),
        pair.decimals,
        model.config.confBps,
        pair.answer,
      )
    : null
  const liqPrice = liqAnswer === null ? null : liqAnswer * 10n ** BigInt(18 - pair.decimals)
  const ratesAfter = quote
    ? fundingRates(pair.oiLong + (isLong ? quote.sizeWad : 0n), pair.oiShort + (isLong ? 0n : quote.sizeWad), model.activeFundingFactor)
    : null
  const myRate = ratesAfter ? (isLong ? ratesAfter.long : ratesAfter.short) : 0n

  let error: string | undefined
  if (!pair.isActive) error = `${pair.name} is closed to new trades.`
  else if (model.openPaused) error = 'Opening positions is paused by the protocol owner.'
  else if (!pair.anchorFresh) error = `The Chainlink ${pair.name} feed has not updated within its window, so the oracle refuses the price.`
  else if (collateral !== null && collateral > 0n) {
    if (collateral < MIN_COLLATERAL) error = 'Collateral must be at least 10 USDC.'
    else if (collateral > UINT64_MAX) error = 'That amount is too large.'
    else if (acc && collateral > wallet) error = 'More than your wallet balance.'
    else if (quote?.preLiquidatable) error = 'At this leverage the spread alone would put the position at its liquidation threshold. Lower the leverage.'
    else if (quote?.exceedsMaxOI) error = `This would take ${pair.name} open interest past its ${formatUsd(pair.maxOI, 0)} limit.`
    else if (tp === null || sl === null) error = 'Enter take profit and stop loss as prices in USD.'
    else if (quote?.tpError) error = quote.tpError
    else if (quote?.slError) error = quote.slError
  }
  const invalidInput = input.trim() !== '' && collateral === null

  const previewEntry = quote && !error ? quote.executionPrice : null
  useEffect(() => {
    onPreview(previewEntry === null ? null : { entry: previewEntry, liquidation: liqPrice })
  }, [previewEntry, liqPrice, onPreview])

  const connected = status === 'connected' && chainId === chain.id
  const noGas = !!acc && acc.data.eth === 0n
  const needsApproval = !!acc && !!collateral && acc.data.allowance.engine < collateral
  const canSubmit = connected && !!acc && !!collateral && collateral > 0n && !error && !actions.busy && !noGas
  const verb = `Open ${isLong ? 'long' : 'short'}`

  const submit = async () => {
    if (!quote || !collateral || !acc) return
    const ok = await actions.open(
      { pair, isLong, collateral, leverage: lev, expectedPrice: quote.executionPrice, slippageBps: slippage, tp: tp ?? 0n, sl: sl ?? 0n },
      acc.data.allowance.engine,
    )
    if (ok) {
      setInput('')
      setTpInput('')
      setSlInput('')
    }
  }

  return (
    <div className="card tradebox" id="trade">
      <div className="sides" role="group" aria-label="Side">
        <button className="side" data-side="long" aria-pressed={isLong} onClick={() => setIsLong(true)}>
          <SideTag isLong />
          <span className="side-sub">Gains if {pair.symbol} rises</span>
        </button>
        <button className="side" data-side="short" aria-pressed={!isLong} onClick={() => setIsLong(false)}>
          <SideTag isLong={false} />
          <span className="side-sub">Gains if {pair.symbol} falls</span>
        </button>
      </div>

      <div className="action">
        <div className="tradebox-head">
          <span className="muted">Market order on {pair.name}</span>
          {connected && acc && wallet === 0n ? (
            <button className="link-button" onClick={onFaucet}>
              Get test USDC
            </button>
          ) : null}
        </div>

        <div className="field">
          <label className="field-label" htmlFor="collateral">
            <span>Collateral</span>
            <span>{acc ? `Wallet ${formatFixed(wallet, 6, 2)} USDC` : 'At least 10 USDC'}</span>
          </label>
          <div className="input-wrap" data-invalid={invalidInput || (!!collateral && !!error)}>
            <input
              id="collateral"
              className="amount-input"
              inputMode="decimal"
              autoComplete="off"
              placeholder="0.00"
              value={input}
              onChange={(e) => setInput(e.target.value)}
            />
            <span className="unit">USDC</span>
            <button className="max" disabled={!acc || wallet === 0n} onClick={() => setInput(toInput(wallet, 6))}>
              Max
            </button>
          </div>
          {invalidInput ? (
            <span className="hint" data-tone="danger">
              Enter a number with at most 6 decimals.
            </span>
          ) : null}
        </div>

        <div className="field">
          <label className="field-label" htmlFor="leverage">
            <span>Leverage</span>
            <strong className="leverage-value">{lev.toString()}x</strong>
          </label>
          <input
            id="leverage"
            className="slider"
            type="range"
            min={1}
            max={Number(pair.maxLeverage)}
            step={1}
            value={Number(lev)}
            onChange={(e) => setLeverage(BigInt(e.target.value))}
          />
          <div className="choice" aria-label="Leverage presets">
            {LEVERAGE_CHIPS.filter((x) => x <= pair.maxLeverage).map((x) => (
              <button key={x.toString()} className="chip chip-small" aria-pressed={lev === x} onClick={() => setLeverage(x)}>
                {x.toString()}x
              </button>
            ))}
          </div>
        </div>

        {showLevels ? (
          <div className="levels">
            <div className="field">
              <label className="field-label" htmlFor="tp">
                <span>Take profit (optional)</span>
                <span>{isLong ? 'Above' : 'Below'} the entry price</span>
              </label>
              <div className="input-wrap input-small">
                <span className="unit">$</span>
                <input id="tp" className="amount-input" inputMode="decimal" autoComplete="off" placeholder="None" value={tpInput} onChange={(e) => setTpInput(e.target.value)} />
              </div>
            </div>
            <div className="field">
              <label className="field-label" htmlFor="sl">
                <span>Stop loss (optional)</span>
                <span>{isLong ? 'Below' : 'Above'} the current price</span>
              </label>
              <div className="input-wrap input-small">
                <span className="unit">$</span>
                <input id="sl" className="amount-input" inputMode="decimal" autoComplete="off" placeholder="None" value={slInput} onChange={(e) => setSlInput(e.target.value)} />
              </div>
            </div>
          </div>
        ) : (
          <button className="link-button" style={{ justifySelf: 'start' }} onClick={() => setShowLevels(true)}>
            Add a take profit or stop loss
          </button>
        )}

        <div className="field">
          <span className="field-label">
            <span>Slippage tolerance</span>
          </span>
          <div className="choice" aria-label="Slippage tolerance">
            {SLIPPAGES.map((s) => (
              <button key={s.toString()} className="chip chip-small" aria-pressed={slippage === s} onClick={() => setSlippage(s)}>
                {formatBps(s)}
              </button>
            ))}
          </div>
        </div>

        {error && (collateral || !pair.isActive || model.openPaused || !pair.anchorFresh) ? (
          <span className="hint" data-tone="danger">
            {error}
          </span>
        ) : null}

        {quote && !error ? (
          <dl className="rows">
            <div className="row">
              <dt>Entry price</dt>
              <dd>
                {formatPrice(quote.executionPrice)}{' '}
                <span className="faint">
                  {formatPrice(pair.price)} {isLong ? 'plus' : 'minus'} {formatBps(quote.spread)} spread
                </span>
              </dd>
            </div>
            <div className="row">
              <dt>Position size</dt>
              <dd>{formatUsd(quote.sizeWad)}</dd>
            </div>
            <div className="row">
              <dt>Open fee</dt>
              <dd>
                {formatFixed(quote.fee, 6, 2)} USDC <span className="faint">0.08% of collateral times leverage</span>
              </dd>
            </div>
            <div className="row">
              <dt>Liquidation price</dt>
              <dd>
                {liqPrice === null ? 'Out of range' : `About ${formatPrice(liqPrice)}`} <span className="faint">moves with funding</span>
              </dd>
            </div>
            <div className="row">
              <dt>Funding, after this open</dt>
              <dd>{myRate === 0n ? 'None' : myRate > 0n ? `You pay ${formatRatePerHour(myRate).replace('+', '')}` : `You receive ${formatRatePerHour(-myRate)}`}</dd>
            </div>
            <div className="row">
              <dt>Most it can pay out</dt>
              <dd>
                {formatFixed(quote.effectiveCollateral * MAX_PROFIT_MULTIPLIER, 6, 2)} USDC <span className="faint">9x collateral, before funding and fee</span>
              </dd>
            </div>
            {acc ? (
              <div className="row">
                <dt>Your USDC</dt>
                <dd>
                  <span className="faint">{formatFixed(wallet, 6, 2)}</span>
                  <span className="arrow">to</span>
                  {formatFixed(wallet - (collateral ?? 0n), 6, 2)}
                </dd>
              </div>
            ) : null}
            <div className="row">
              <dt>Price check</dt>
              <dd style={{ fontWeight: 400 }} className="muted">
                Latest Chainlink price pushed in the same call
              </dd>
            </div>
          </dl>
        ) : null}

        {noGas ? (
          <div className="callout" data-tone="warn">
            Your wallet has no {chain.name} ETH for gas. Get some from a{' '}
            <a href={links.ethFaucet} target="_blank" rel="noreferrer">
              faucet
            </a>
            .
          </div>
        ) : null}

        {!connected ? (
          <button
            className="btn btn-primary btn-block"
            onClick={() => (status === 'connected' ? switchChain.mutate({ chainId: chain.id }) : onConnect())}
          >
            {status === 'connected' ? `Switch to ${chain.name} to trade` : 'Connect wallet to trade'}
          </button>
        ) : (
          <button className="btn btn-primary btn-block" disabled={!canSubmit} onClick={submit}>
            {actions.busy ?? (needsApproval ? `Approve and ${verb.toLowerCase()}` : verb)}
          </button>
        )}
        {needsApproval && canSubmit ? <p className="hint">Two transactions: an approval for this amount, then the open itself.</p> : null}
      </div>
    </div>
  )
}
