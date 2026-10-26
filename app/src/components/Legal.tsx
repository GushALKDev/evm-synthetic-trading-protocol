const OWNER_EMAIL = 'info@tesselium.com'

/**
 * The owner's details required by Article 10 of the Spanish LSSI-CE. The demo is linked from the Tesselium website,
 * so it identifies the same owner, and the rest of the notice states what a testnet proof of concept is not.
 */
export function LegalNotice() {
  return (
    <main>
      <section className="section legal" aria-labelledby="legal-title">
        <div className="wrap">
          <h1 id="legal-title">Legal notice</h1>

          <h2>1. Website owner</h2>
          <p>
            In compliance with Article 10 of Spanish Law 34/2002 on Information Society Services and Electronic Commerce
            (LSSI-CE), the owner of this website is identified below.
          </p>
          <dl>
            <dt>Trade name</dt>
            <dd>Tesselium Labs</dd>
            <dt>Owner</dt>
            <dd>Gustavo Martín, self-employed professional (autónomo) established in Spain</dd>
            <dt>Email</dt>
            <dd>
              <a href={`mailto:${OWNER_EMAIL}`}>{OWNER_EMAIL}</a>
            </dd>
          </dl>
          <p>Tesselium Labs is a trade name, not a registered company.</p>

          <h2>2. Purpose</h2>
          <p>
            This website is a proof of concept for educational purposes that shows how a synthetic trading protocol
            works, deployed on Base Sepolia, a test network. It is not a financial or commercial service: it does not
            handle real funds, testnet tokens have no value, and no services can be hired through it.
          </p>

          <h2>3. Conditions of use</h2>
          <p>
            Using this website implies acceptance of this legal notice. Users agree to use the website lawfully and not
            to damage it or interfere with its operation. Transactions are signed from the user's own wallet, and the
            user is solely responsible for its keys.
          </p>

          <h2>4. Intellectual property</h2>
          <p>
            The texts, design and graphics of this website belong to its owner unless stated otherwise. The source code
            of the smart contracts and of this website is published under the MIT licence in its repository. Third-party
            names and trademarks, such as Base, Chainlink, Pyth, Coinbase and TradingView, belong to their owners and
            are mentioned only to describe how the proof of concept works.
          </p>

          <h2>5. Liability</h2>
          <p>
            The smart contracts are not audited and are provided as is, without warranties, for educational purposes
            only. They must not be used with real funds or deployed on a mainnet without an independent audit. The
            content of this website does not constitute technical, legal, financial or investment advice. We are not
            responsible for the availability of the test network, for the third-party services the website relies on
            (wallets, RPC nodes, oracles, market data and block explorers), or for the content of external websites
            linked from this one.
          </p>

          <h2>6. Personal data and cookies</h2>
          <p>
            This website has no forms, sets no cookies of its own, uses no analytics and does not collect personal data.
            It keeps your wallet connection and your trade history in your browser's local storage, which you can clear
            at any time. To read the network, your browser connects directly to the public Base Sepolia RPC node, and to
            Coinbase's public market data API for the price chart. Addresses and transactions are recorded publicly on
            the test network. Cloudflare, the hosting provider, may set strictly necessary security cookies.
          </p>

          <h2>7. Applicable law and jurisdiction</h2>
          <p>
            This legal notice is governed by Spanish law. Any dispute will be submitted to the courts that have
            jurisdiction under the applicable law.
          </p>

          <p className="legal-updated">Last updated: 26 October 2026</p>
        </div>
      </section>
    </main>
  )
}
