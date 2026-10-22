import { useEffect, useState } from 'react'
import { EarnPage } from './components/EarnPage'
import { FaucetDialog } from './components/FaucetDialog'
import { LiquidationsPage } from './components/LiquidationsPage'
import { Footer, Header, HowItWorks, Notice } from './components/Sections'
import { Toasts } from './components/Toasts'
import { TradePage } from './components/TradePage'
import { ConnectDialog } from './components/Wallet'
import { chain, deployment, links } from './config/chain'
import { useHistory } from './hooks/useHistory'
import { useModel } from './hooks/useModel'
import { scrollToTarget, useRoute } from './hooks/useRoute'

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

function Protocol() {
  const { model, error } = useModel()
  // Mounted on every page, so a settlement sent from any of them reaches the history
  const history = useHistory(model)
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
      <Notice page={page} />
      {model ? (
        <main>
          {page === 'trade' ? <TradePage model={model} history={history} onConnect={openConnect} onFaucet={openFaucet} /> : null}
          {page === 'earn' ? <EarnPage model={model} onConnect={openConnect} onFaucet={openFaucet} /> : null}
          {page === 'liquidations' ? <LiquidationsPage model={model} onConnect={openConnect} /> : null}
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
      <Footer model={model} page={page} />
      {connectOpen ? <ConnectDialog onClose={() => setConnectOpen(false)} /> : null}
      {faucetOpen && model ? <FaucetDialog model={model} onClose={() => setFaucetOpen(false)} onConnect={openConnect} /> : null}
      <Toasts />
    </>
  )
}

export function App() {
  return deployment ? <Protocol /> : <NotDeployed />
}
