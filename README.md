# LUNA-COOP / BTC-Coop Solvency

LUNA-COOP is an experimental BTC-first credit protocol architecture focused on solvency-aware borrowing, rescue-before-liquidation, and controlled settlement.

The protocol is being developed around a simple principle:

> Bitcoin-backed credit should have a clear solvency path before it has a liquidation path.

This repository contains the Solidity-side prototype for Luna collateral, debt, rescue, liquidation, settlement, and Rail Two native BTC enforcement architecture.

## Current status

This repository is a research and development prototype. It is not production software.

The current implementation has a green Foundry test suite and includes:

- core position, collateral, debt, vault, and parameter registries
- risk-adjusted health factor classification
- rescue-before-liquidation accounting
- insurance reserve and stabilization pool components
- buyback cover, claim, and flash close routing
- remote liquidity routing and settlement adapter flow
- Rail One escrowed wrapped BTC collateral path
- Rail Two enforceable native BTC collateral architecture
- Rail Two native pledge registration
- Rail Two enforcement lifecycle tracking
- Rail Two proof-pack registry
- Rail Two native settlement adapter
- Rail Two liquidation and terminal settlement routing tests
- Rail Two end-to-end native enforcement lifecycle integration test
- Rail Two offchain truth machinery specifications

## Rail model

Luna separates BTC collateral into two serious rails.

### Rail One: protocol-controlled escrowed wrapped BTC

Rail One is the stronger current execution rail. Collateral is deposited into protocol-controlled escrow, so Luna can liquidate, settle, and close positions through smart-contract accounting.

### Rail Two: enforceable native BTC

Rail Two is designed for native BTC collateral without wrapping. The user keeps BTC in native Bitcoin form, but Luna requires an explicit enforcement architecture before the position can be treated as credit-ready.

Rail Two currently supports the Solidity-side receiving architecture:

- native pledge commitment
- pledge registration against a Luna position
- Bitcoin finality state recording
- enforceable / credit-ready pledge state
- enforcement lifecycle tracking
- observed native BTC recovery
- proof-pack submission
- proof-gated Luna accounting finalization through NativeSettlementAdapter
- replay, bypass, and wrong-rail rejection paths

## Important Rail Two limitation

Rail Two is not yet production Bitcoin enforcement.

The current Solidity architecture can receive and enforce proof-gated accounting transitions, but production readiness still depends on the offchain Bitcoin-side truth machinery.

The missing production-critical pieces are:

- Bitcoin watcher service
- Bitcoin finality service
- proof-pack builder
- production verifier implementation
- Bitcoin transaction / script / multisig / covenant enforcement design
- reorg handling policy
- fake recovery prevention
- partial recovery accounting policy
- disputed enforcement procedure
- verifier upgrade governance
- emergency pause behavior during enforcement disputes
- operational runbook for native BTC liquidation and settlement

The intended trust boundary is:

> Agents may observe, assemble, compare, alert, and coordinate. Cryptography and deterministic verifier logic must validate evidence before Luna accounting finalizes.

## Repository map

- src/core/ — core Luna accounting, rescue, liquidation, settlement, routing, and risk modules
- src/native/ — Rail Two native BTC pledge, proof-pack, enforcement, and settlement components
- src/libraries/ — shared protocol type helpers
- src/types/ — shared protocol rail types
- test/unit/ — unit tests for individual modules
- test/integration/ — integration tests for Rail Two routing and lifecycle behavior
- docs/ — Rail Two production-readiness, verifier, agent, and offchain truth specifications

## Development

Install Foundry, then run:

```bash
forge fmt
forge test
```

The repository should remain green before any new patching work.

## Honest claim boundary

Luna can currently claim:

> Luna has a rail-aware collateral architecture where native BTC positions can be represented, tracked, moved through an enforcement lifecycle, and finalized into Luna accounting through a dedicated proof-gated native settlement adapter.

Luna must not yet claim production native BTC enforcement, trust-minimized native BTC liquidation, onchain Bitcoin finality verification, or fully trustless recovery evidence.

## License

MIT
