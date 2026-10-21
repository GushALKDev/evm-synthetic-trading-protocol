import { useEffect, useState } from 'react'
import { FaucetDialog } from './components/FaucetDialog'
import { Ledger } from './components/Ledger'
import { Markets } from './components/Markets'
import { AllPositions, YourPositions } from './components/Positions'
import { Footer, Header, HowItWorks, Notice } from './components/Sections'
import { Toasts } from './components/Toasts'
import { TradeTicket } from './components/TradeTicket'
import { VaultPage } from './components/VaultPage'
import { ConnectDialog } from './components/Wallet'
import { chain, deployment, links } from './config/chain'
import { useModel } from './hooks/useModel'
import { scrollToTarget, useRoute } from './hooks/useRoute'
import type { Model } from './lib/model'

function NotDeployed() {
  return (
    <main className="wrap hero">
      <div className="hero-head">
        <h1>The protocol is not deployed on {chain.name} yet.</h1>
        <p className="hero-sub">
          Run the testnet deployment script to create it; it writes the addresses this app reads. Until then, the <a href={links.repo}>source code</a> is
          the place to look.
        </p>
      </div>
    </main>
  )
}

function TradePage({ model, onConnect, onFaucet }: { model: Model; onConnect: () => void; onFaucet: () => void }) {
  const [pairIndex, setPairIndex] = useState(0)
  return (
    <>
      <section className="hero">
        <div className="wrap">
          <div className="hero-head">
            <h1>Go long or short on {model.pairs.map((p) => p.symbol).join(', ').replace(/, ([^,]*)$/, ' and $1')} against one USDC vault.</h1>
            <p className="hero-sub">
              Synthetic perpetuals with up to {model.pairs.reduce((m, p) => (p.maxLeverage > m ? p.maxLeverage : m), 0n).toString()}x leverage, running on{' '}
              {chain.name} with testnet USDC. The vault is the counterparty to every position, and every figure here is computed from the contracts'
              live state.
            </p>
          </div>
          <Ledger model={model} />
        </div>
      </section>
      <div className="wrap main-grid">
        <div className="stack">
          <TradeTicket model={model} pairIndex={pairIndex} onPair={setPairIndex} onConnect={onConnect} onFaucet={onFaucet} />
          <YourPositions model={model} />
        </div>
        <div className="stack">
          <Markets model={model} selected={pairIndex} onSelect={setPairIndex} />
        </div>
      </div>
    </>
  )
}

function Protocol() {
  const { model, error } = useModel()
  const { page, url } = useRoute()
  const ready = model !== null
  // A fragment's target only exists once the protocol has rendered, so a direct link waits for the first read.
  useEffect(scrollToTarget, [url, ready])
  const [connectOpen, setConnectOpen] = useState(false)
  const [faucetOpen, setFaucetOpen] = useState(false)
  const openConnect = () => {
    setFaucetOpen(false)
    setConnectOpen(true)
  }
  const openFaucet = () => setFaucetOpen(true)

  return (
    <>
      <Header page={page} onConnect={openConnect} onFaucet={openFaucet} />
      <Notice />
      {model ? (
        <main>
          {page === 'trade' ? <TradePage model={model} onConnect={openConnect} onFaucet={openFaucet} /> : null}
          {page === 'vault' ? <VaultPage model={model} onConnect={openConnect} onFaucet={openFaucet} /> : null}
          {page === 'positions' ? <AllPositions model={model} onConnect={openConnect} /> : null}
          {page === 'how' ? <HowItWorks model={model} /> : null}
        </main>
      ) : (
        <main className="wrap hero">
          {error ? (
            <div className="callout" data-tone="warn" role="alert">
              The protocol could not be read from {chain.name}. The RPC may be rate limiting requests; the page retries on its own.
            </div>
          ) : (
            <p className="muted">Reading the protocol from {chain.name}…</p>
          )}
        </main>
      )}
      <Footer model={model} />
      {connectOpen ? <ConnectDialog onClose={() => setConnectOpen(false)} /> : null}
      {faucetOpen && model ? <FaucetDialog model={model} onClose={() => setFaucetOpen(false)} onConnect={openConnect} /> : null}
      <Toasts />
    </>
  )
}

export function App() {
  return deployment ? <Protocol /> : <NotDeployed />
}
