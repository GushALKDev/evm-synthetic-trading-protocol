import { useConnection, useWatchAsset } from 'wagmi'
import { chain, links } from '../config/chain'
import { useActions } from '../hooks/useActions'
import { formatFixed } from '../lib/format'
import type { Model } from '../lib/model'
import { Dialog } from './Wallet'

export function FaucetDialog({ model, onClose, onConnect }: { model: Model; onClose: () => void; onConnect: () => void }) {
  const { address } = useConnection()
  const actions = useActions(model)
  const watch = useWatchAsset()
  const acc = model.account
  const next = acc ? acc.data.nextClaimAt : 0n
  // Against the chain's clock, which is what claim checks
  const canClaim = !!acc && model.chainTime >= next
  const noGas = !!acc && acc.data.eth === 0n

  return (
    <Dialog title="Test USDC" onClose={onClose}>
      <p className="muted">
        The faucet hands out 10,000 testnet USDC, once every 24 hours per address. It has no value. Transactions also need a little {chain.name} ETH
        for gas.
      </p>

      {!address ? (
        <button className="btn btn-primary btn-block" style={{ marginTop: 18 }} onClick={onConnect}>
          Connect wallet
        </button>
      ) : (
        <div className="steps" style={{ marginTop: 18 }}>
          {noGas ? (
            <div className="callout" data-tone="warn">
              Your wallet has no {chain.name} ETH. Get some from a{' '}
              <a href={links.ethFaucet} target="_blank" rel="noreferrer">
                {chain.name} faucet
              </a>{' '}
              first, then come back.
            </div>
          ) : null}
          <button className="btn btn-primary btn-block" disabled={!canClaim || !!actions.busy} onClick={() => actions.claimFaucet()}>
            {actions.busy ? 'Claiming…' : 'Claim 10,000 test USDC'}
          </button>
          {!canClaim && acc ? (
            <p className="hint">You claimed in the last 24 hours. Next claim after {new Date(Number(next) * 1000).toLocaleString()}.</p>
          ) : null}
        </div>
      )}

      {address && acc ? (
        <dl className="rows" style={{ marginTop: 18 }}>
          <div className="row">
            <dt>Your USDC</dt>
            <dd>
              {formatFixed(acc.data.usdc, 6, 2)}{' '}
              <button
                className="link-button"
                style={{ marginLeft: 8, fontSize: 13 }}
                onClick={() => watch.mutate({ type: 'ERC20', options: { address: model.deployment.usdc, symbol: 'USDC', decimals: 6 } })}
              >
                Add to wallet
              </button>
            </dd>
          </div>
        </dl>
      ) : null}
    </Dialog>
  )
}
