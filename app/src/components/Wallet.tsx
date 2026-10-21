import { useEffect, useRef, useState, type ReactNode } from 'react'
import { useConnect, useConnection, useConnectors, useDisconnect, useSwitchChain } from 'wagmi'
import { chain } from '../config/chain'
import { describeError, noErrorContext } from '../lib/errors'
import { shortAddress } from '../lib/format'
import { CloseIcon } from './icons'

export function Dialog({ title, onClose, children }: { title: string; onClose: () => void; children: ReactNode }) {
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onClose()
    window.addEventListener('keydown', onKey)
    ref.current?.focus()
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])
  return (
    <div className="dialog-backdrop" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="dialog" role="dialog" aria-modal="true" aria-label={title} tabIndex={-1} ref={ref}>
        <div className="dialog-head">
          <h2>{title}</h2>
          <button className="btn btn-quiet" onClick={onClose} aria-label="Close">
            <CloseIcon />
          </button>
        </div>
        {children}
      </div>
    </div>
  )
}

export function ConnectDialog({ onClose }: { onClose: () => void }) {
  const connectors = useConnectors()
  const connect = useConnect()
  // The generic injected connector duplicates the EIP-6963 entries when a wallet announces itself.
  const options = connectors.length > 1 ? connectors.filter((c) => c.id !== 'injected') : connectors
  return (
    <Dialog title="Connect a wallet" onClose={onClose}>
      {options.length === 0 ? (
        <p className="muted">No browser wallet found. Install one such as MetaMask or Rabby, or open this page in your wallet's browser.</p>
      ) : (
        <div className="wallet-list">
          {options.map((c) => (
            <button
              key={c.uid}
              className="wallet-option"
              disabled={connect.isPending}
              onClick={() => connect.mutate({ connector: c, chainId: chain.id }, { onSuccess: onClose })}
            >
              {c.icon ? <img src={c.icon} alt="" /> : null}
              {c.id === 'injected' ? 'Browser wallet' : c.name}
            </button>
          ))}
        </div>
      )}
      {connect.error ? (
        <p className="hint" data-tone="danger" style={{ marginTop: 12 }}>
          {describeError(connect.error, noErrorContext)}
        </p>
      ) : null}
      <p className="hint" style={{ marginTop: 16 }}>
        The protocol runs on {chain.name}. Your wallet will be asked to add or switch to it.
      </p>
    </Dialog>
  )
}

export function WalletButton({ onConnect }: { onConnect: () => void }) {
  const { address, chainId, status } = useConnection()
  const disconnect = useDisconnect()
  const switchChain = useSwitchChain()
  const [open, setOpen] = useState(false)

  if (status !== 'connected' || !address) {
    return (
      <button className="btn btn-primary" onClick={onConnect} disabled={status === 'connecting'}>
        {status === 'connecting' || status === 'reconnecting' ? 'Connecting…' : 'Connect wallet'}
      </button>
    )
  }
  if (chainId !== chain.id) {
    return (
      <button className="btn btn-primary" onClick={() => switchChain.mutate({ chainId: chain.id })}>
        Switch to {chain.name}
      </button>
    )
  }
  return (
    <div style={{ position: 'relative' }}>
      <button className="btn" onClick={() => setOpen((o) => !o)} aria-expanded={open}>
        <span className="mono">{shortAddress(address)}</span>
      </button>
      {open ? (
        <div className="card menu" onMouseLeave={() => setOpen(false)}>
          <button className="btn btn-quiet menu-item" onClick={() => navigator.clipboard?.writeText(address).then(() => setOpen(false))}>
            Copy address
          </button>
          <button
            className="btn btn-quiet menu-item"
            onClick={() => {
              disconnect.mutate()
              setOpen(false)
            }}
          >
            Disconnect
          </button>
        </div>
      ) : null}
    </div>
  )
}
