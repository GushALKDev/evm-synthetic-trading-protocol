# 🔮 Synthetic Trading Protocol

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.24-363636.svg)](https://docs.soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg)](https://getfoundry.sh/)

A **decentralized synthetic leverage trading protocol** with single-sided liquidity. Trade crypto, forex, and commodities with up to 100x leverage — no order books, no counterparty matching.

> ⚠️ **DISCLAIMER:** This is a **Proof of Concept with an educational purpose**, demonstrating advanced
> smart contract development. **All code is written from scratch.** It has **not been audited by an
> external firm** and **must not be used in production** or with real funds.

**Status:** Complete — Phases 0–12 (87/87 items). 553 tests, 100% line coverage on all `src/` contracts.

---

## 🎯 What is this?

A DeFi protocol where:

- **Traders** open leveraged Long/Short positions on any asset
- **LPs (Liquidity Providers)** deposit USDC and act as the counterparty ("The House")
- **Off-chain bots** (via EOAs) execute liquidations and automated operations

No order books. No AMM curves. Just oracle-priced synthetic exposure.

```
┌─────────────────────────────────────────────────────────────────┐
│                            THE MODEL                            │
│                                                                 │
│   TRADERS ──────┐                                               │
│   (Bet on       │         ┌──────────────────┐                  │
│    price)       ├────────►│                  │                  │
│                 └◄────────┤   VAULT (USDC)   │◄────── LPs       │
│   Win = Payout            │   "The House"    │        (Provide  │
│   Lose = Loss             │                  │         USDC)    │
│   to Vault                └──────────────────┘                  │
│                                    │                            │
│                                    ▼                            │
│                           Traders lose → LPs profit             │
│                           Traders win  → LPs pay                │
└─────────────────────────────────────────────────────────────────┘
```

---

## ✨ Key Features

| Feature                          | Description                                                      |
| :------------------------------- | :--------------------------------------------------------------- |
| **Single-Sided Liquidity (SSL)** | LPs only deposit USDC. No impermanent loss from pair imbalance.   |
| **ERC-4626 Vault**               | Tokenized vault shares (sUSDC), with a 3-epoch withdrawal lock.   |
| **Pyth + Chainlink Oracle**      | Pyth pull oracle as the price source, Chainlink as deviation anchor. |
| **Dynamic Spread**               | Spread grows with open interest and volatility to protect the Vault. |
| **Funding Rates**                | Cumulative index charged between longs and shorts by OI imbalance. |
| **Liquidations**                 | Permissionless, 90% loss threshold, 10% liquidator reward.        |
| **Limit Orders (TP/SL)**         | Permissionless execution with a reward carved from the payout.    |
| **3-Layer Solvency**             | Profit caps → Assistant Fund reserve → $SYNTH bonding.            |

---

## 🏗️ Architecture

```
                    ┌────────────────────────────────────────┐
                    │             TRADING ENGINE             │
                    │  openTrade · closeTrade · liquidate    │
                    │  executeLimit · fees · funding         │
                    └───────────────────┬────────────────────┘
                                        │
        ┌───────────────┬───────────────┼───────────────┬───────────────┐
        ▼               ▼               ▼               ▼               │
┌───────────────┐ ┌───────────┐ ┌──────────────┐ ┌──────────────┐       │
│   TRADING     │ │   VAULT   │ │ PYTH+CHAINLNK│ │    SPREAD    │       │
│   STORAGE     │ │ (ERC-4626)│ │    ORACLE    │ │   MANAGER    │       │
│               │ │           │ │              │ │              │       │
│ • Trades      │ │ • LP USDC │ │ • Pyth pull  │ │ • OI impact  │       │
│ • Collateral  │ │ • sUSDC   │ │ • Chainlink  │ │ • Volatility │       │
│ • Open Intrst │ │ • Payouts │ │   deviation  │ │ • Capped BPS │       │
│ • Funding idx │ │ • 3-epoch │ │ • Confidence │ │              │       │
└───────────────┘ └─────┬─────┘ └──────────────┘ └──────────────┘       │
                        │                                               │
                        │            20% of fees ────────────────────────┘
                        │                    │
                        ▼                    ▼
              ┌─────────────────────────────────────────────┐
              │              SOLVENCY MANAGER               │
              │      checkAndAct (permissionless)           │
              │   CR < 100% → inject · CR < 95% → bond      │
              └──────────────┬───────────────┬──────────────┘
                             ▼               ▼
                   ┌──────────────────┐ ┌──────────────────┐
                   │  ASSISTANT FUND  │ │ BOND DEPOSITORY  │
                   │    (Layer 2)     │ │    (Layer 3)     │
                   │                  │ │                  │
                   │ • USDC reserve   │ │ • Discounted     │
                   │ • injectFunds    │ │   $SYNTH sale    │
                   │ • skim overflow  │ │ • Linear vesting │
                   └──────────────────┘ └────────┬─────────┘
                                                 ▼
                                        ┌──────────────────┐
                                        │   SYNTH TOKEN    │
                                        │  minter-gated    │
                                        └──────────────────┘
```

---

## 📚 Documentation

Comprehensive documentation is available in [`/docs`](./docs/):

### English Documentation

| Document                                                      | Description                                 |
| :------------------------------------------------------------ | :------------------------------------------ |
| **[📋 Complete Index](./docs/README.md)**                     | Master index - start here                   |
| **[🗺️ Roadmap](./docs/ROADMAP.md)**                           | Implementation phases & progress (87 items) |
| **[📖 Guide 1: Fundamentals](./docs/01-fundamentals.md)**     | Core concepts & SSL model                   |
| **[🔢 Guide 2: Mathematics](./docs/02-mathematics.md)**       | PnL, funding rates, spreads                 |
| **[⚙️ Guide 3: Architecture](./docs/03-architecture.md)**     | Contracts, oracle design, data flows        |
| **[⚖️ Guide 4: Trade-offs](./docs/04-tradeoffs.md)**          | Risks & mitigations                         |
| **[💻 Guide 5: Implementation](./docs/05-implementation.md)** | Solidity patterns & code                    |
| **[🚀 Guide 6: Improvements](./docs/06-improvements.md)**     | Future features (V2)                        |
| **[🏦 Guide 7: Vault SSL](./docs/07-vault-ssl.md)**           | ERC-4626 & 3-layer solvency                 |
| **[🔒 Guide 8: Security](./docs/08-security.md)**             | Threat model & invariants                   |
| **[🧪 Test Suite](./docs/tests/README.md)**                   | Tests, invariants, static analysis          |

## 🛠️ Tech Stack

| Component           | Technology                    |
| :------------------ | :---------------------------- |
| **Smart Contracts** | Solidity 0.8.24                             |
| **Framework**       | Foundry                                     |
| **Testing**         | Forge (unit, fuzz, invariant, integration, fork) |
| **Libraries**       | Solady                                      |
| **Oracles**         | Pyth (price source) + Chainlink (deviation anchor) |
| **Static analysis** | Slither, Aderyn                             |
| **Standards**       | ERC-4626, ERC-20                            |

---

## 🚀 Getting Started

### Prerequisites

- [Foundry](https://getfoundry.sh/)
- Git

### Installation

```bash
# Clone the repository
git clone https://github.com/GushALKDev/evm-synthetic-trading-protocol.git
cd evm-synthetic-trading-protocol

# Install dependencies
forge install

# Build
forge build

# Run tests
forge test

# Run tests with coverage
forge coverage
```

### Local Development

```bash
# Start local node
anvil

# Deploy to local node (deploys all 9 contracts and wires every permission)
export PRIVATE_KEY=0x...      # deployer key
export USDC_ADDRESS=0x...     # collateral token
export PYTH_ADDRESS=0x...     # Pyth contract for the chain
forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast
```

`OWNER_ADDRESS` and `KEEPER_ADDRESS` are optional (both default to the deployer). Pair feeds are left
as explicit owner actions afterwards, since `oracle.setPairFeed` and `tradingStorage.addPair` need
per-chain Pyth feed IDs and Chainlink aggregators.

---

## 🧪 Testing

```bash
# Unit tests
forge test

# Fuzz tests (more runs)
forge test --fuzz-runs 10000

# Invariant tests
forge test --match-path "test/invariant/*"

# Integration tests (full wired system)
forge test --match-path "test/integration/*"

# Coverage report
forge coverage --report lcov
```

**553 tests** — 474 unit, 36 fuzz, 23 integration, 11 invariant, 13 fork. 100% line coverage on all
`src/` contracts.

See **[docs/tests/](./docs/tests/README.md)** for what each test covers, the invariants and their
rationale, and the Slither/Aderyn findings review.

### Key Invariants

Asserted after every step of ~128,000 randomized calls per invariant:

| Invariant | Guarantees |
| :-------- | :--------- |
| `invariant_TotalAssetsBackedByBalance` | Vault `totalAssets` always matches its real USDC balance |
| `invariant_OpenInterestWithinMax` | Long and short OI never exceed the pair cap |
| `invariant_SharePricePositive` | Share price never falls to zero while shares exist |
| `invariant_StorageCoversOpenCollateral` | Trader collateral is always fully custodied and payable |
| `invariant_EscrowCoversUnclaimedSynth` | Every unclaimed vesting position can always be honoured |

---

## 📁 Project Structure

```
evm-synthetic-trading-protocol/
├── docs/                       # Comprehensive documentation
│   ├── README.md               # Master index
│   ├── ROADMAP.md              # Implementation roadmap
│   ├── 01-fundamentals.md      # Guide 1: Core concepts
│   ├── 02-mathematics.md       # Guide 2: Protocol math
│   ├── 03-architecture.md      # Guide 3: System design
│   ├── 04-tradeoffs.md         # Guide 4: Risks & solutions
│   ├── 05-implementation.md    # Guide 5: Solidity code
│   ├── 06-improvements.md      # Guide 6: Future features
│   ├── 07-vault-ssl.md         # Guide 7: Vault architecture
│   ├── 08-security.md          # Guide 8: Security analysis
│   └── tests/                  # Test suite documentation
├── src/                        # Smart contracts
│   ├── Vault.sol               # ERC-4626 LP liquidity vault
│   ├── TradingStorage.sol      # Trade data + collateral custody
│   ├── TradingEngine.sol       # Controller: open/close/liquidate/limit
│   ├── PythChainlinkOracle.sol # Pyth price source + Chainlink anchor
│   ├── SpreadManager.sol       # Dynamic spread (OI + volatility)
│   ├── AssistantFund.sol       # Solvency Layer 2: USDC reserve
│   ├── SolvencyManager.sol     # Solvency orchestration (checkAndAct)
│   ├── BondDepository.sol      # Solvency Layer 3: discounted bonding
│   ├── SynthToken.sol          # $SYNTH governance token
│   ├── interfaces/             # IOracle, ISolvency, ISynthToken
│   └── libraries/              # FundingLib
├── test/
│   ├── unit/                   # Per-contract tests (incl. fuzz)
│   ├── integration/            # Full wired system + its invariants
│   ├── invariant/              # Protocol and bonding invariants
│   ├── fork/                   # Live Pyth + Chainlink feeds
│   └── mocks/                  # Test doubles
├── script/
│   └── Deploy.s.sol            # Deploys and wires all 9 contracts
├── LICENSE                     # MIT License
└── README.md
```

---

## 🎓 What This Project Demonstrates

This project showcases advanced smart contract development skills through **original implementation from scratch**:

**Documentation:**

- [x] ERC-4626 tokenized vault architecture
- [x] Complex DeFi math (PnL, funding rates, liquidations, dynamic pricing)
- [x] Oracle design (pull-based Pyth with a Chainlink deviation anchor)
- [x] Risk management (OI caps, dynamic spread, 3-layer solvency)
- [x] Security patterns (CEI, access control, circuit breakers)
- [x] Production-grade architecture documentation (~8,200 lines)

**Implementation — complete (Phases 0–12, 87/87 items):**

- [x] Core contracts (Vault, TradingStorage, TradingEngine)
- [x] Oracle abstraction (`IOracle` + PythChainlinkOracle, confidence-aware)
- [x] Fee system, funding rates, dynamic spread (SpreadManager)
- [x] Liquidations (permissionless, funding-adjusted, conf-based conservative pricing)
- [x] Limit orders / automatic TP/SL (permissionless `executeLimit`, executor reward)
- [x] Solvency Layer 2 (AssistantFund reserve, skimmable overflow)
- [x] Solvency Layer 3 (SolvencyManager, BondDepository, $SYNTH with linear vesting)
- [x] Testing: 553 tests — unit, fuzz, invariant, integration and fork
- [x] Static analysis (Slither, Aderyn) with findings reviewed and remediated
- [x] Deployment script wiring the full protocol

Phase 13 is a backlog of theoretical V2 improvements, deliberately out of scope for this PoC.

---

## 🤝 Contributing

This is a portfolio project, but contributions are welcome! Feel free to:

- Open issues for bugs or suggestions
- Submit PRs for improvements
- Fork and adapt for your own learning

---

## 📜 License

This project is licensed under the **MIT License** - see the [LICENSE](./LICENSE) file for details.

---

## 👤 Author

**[GushALKDev]**

- GitHub: [@GushALKDev](https://github.com/GushALKDev)
- LinkedIn: [Gustavo Martín](https://www.linkedin.com/in/gustavomaral/)

---

## 🙏 Acknowledgments

- [OpenZeppelin](https://openzeppelin.com/) - Security standards and contract libraries
- [Foundry](https://getfoundry.sh/) - Development framework and testing suite
- [Chainlink](https://chain.link/) - Oracle infrastructure reference
- [Solady](https://github.com/Vectorized/solady) - Gas-optimized libraries
- [Gains Network](https://gains.trade/) - Architectural inspiration

---

<p align="center">
  <i>Built with ❤️ to demonstrate what's possible in DeFi</i>
</p>
