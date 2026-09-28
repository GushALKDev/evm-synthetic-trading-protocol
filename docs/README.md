# Documentation Index: Synthetic Trading Protocol

**Status:** Proof of concept. Not audited and not deployed. Educational project, not for use with real
funds.

The root [README](../README.md) has the implementation status table, trust assumptions and the measured
test results. These guides go into more detail. Where a guide describes something that is not in the
code, it says so.

---

## Guides

1. **[Fundamentals](./01-fundamentals.md)**
    - The single-vault counterparty model
    - Actors and trade lifecycle
    - Solvency layers at a glance

2. **[Mathematics](./02-mathematics.md)**
    - PnL, payout cap, fees
    - Execution price with dynamic spread
    - Liquidation condition and reward
    - Funding index
    - Conservative NAV, open PnL aggregates and their biases
    - LP principal coverage ratio, realised ratio and bonding math

3. **[Architecture and data flow](./03-architecture.md)**
    - Component diagram
    - Oracle (Pyth pull updates with a Chainlink deviation check) and the oracle design note
    - Contract descriptions
    - Execution flows

4. **[Trade-offs and risks](./04-tradeoffs.md)**
    - Latency arbitrage
    - LP solvency
    - Liquidations
    - Oracle failure and manipulation
    - Stablecoin risk

5. **[Implementation](./05-implementation.md)**
    - Tech stack and dependencies
    - Structs and storage packing
    - Interfaces
    - Numerical precision and rounding

6. **[Future improvements](./06-improvements.md)**
    - Ideas that are not implemented

7. **[Vault and solvency](./07-vault-ssl.md)**
    - ERC-4626 vault and withdrawal requests
    - Conservative NAV, PnL snapshot and the deposit freeze
    - Layer 1: payout cap, static OI cap, dynamic spread
    - Layer 2: AssistantFund
    - Layer 3: BondDepository and $SYNTH

8. **[Security](./08-security.md)**
    - Threat model
    - Access control as implemented
    - Invariants present in the test suite
    - Known limitations

9. **[Test suite](./tests/README.md)**
    - Test groups and counts
    - Regression tests for the round 2 and 2b findings
    - Invariants, handler call distribution and tolerances
    - Fork tests (Arbitrum One, pinned block) and gas benchmarks
    - Coverage and static analysis counts

**[ROADMAP](./ROADMAP.md)**: build log by phase.

---

## Structure

```
docs/
├── README.md              This file
├── ROADMAP.md             Build log
├── 01-fundamentals.md
├── 02-mathematics.md
├── 03-architecture.md
├── 04-tradeoffs.md
├── 05-implementation.md
├── 06-improvements.md
├── 07-vault-ssl.md
├── 08-security.md
└── tests/
    └── README.md          Test suite
```

---

## Suggested reading order

- **Developers:** 01, 02, 03, 05, 08.
- **Reviewers:** 03, 07, 08, tests/README, 04, 02.

---

## License

MIT, see [LICENSE](../LICENSE).

## External references

GMX and Gains Network are architectural references, not code this repository reuses.

- Foundry: https://book.getfoundry.sh/
- ERC-4626: https://eips.ethereum.org/EIPS/eip-4626
- Pyth: https://docs.pyth.network/ (price source)
- Chainlink data feeds: https://docs.chain.link/data-feeds (deviation anchor)
- GMX: https://gmx-docs.io/ (architectural reference)
- Gains Network (gTrade): https://gains-network.gitbook.io/ (architectural reference)
