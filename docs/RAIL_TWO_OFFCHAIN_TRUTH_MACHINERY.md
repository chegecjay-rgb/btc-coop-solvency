# Rail Two Offchain Truth Machinery

## Purpose

This document defines the offchain truth machinery required before Rail Two can be treated as production native Bitcoin enforcement.

Rail Two already has a Solidity-side receiving architecture:

1. native pledge identity
2. finality state
3. enforcement state
4. proof-pack reference
5. observed recovery
6. verifier approval
7. native settlement adapter
8. Luna accounting finalization

That architecture is necessary, but it is not enough for production.

The missing production layer is the machinery that observes Bitcoin, constructs evidence, verifies that evidence, and handles disputes safely.

## Core rule

Agents may observe, assemble, compare, alert, and coordinate.

Agents must not be the final source of truth.

The production target is:

> Watchers observe Bitcoin. Builders assemble proof packs. Verifiers validate evidence. Governance manages bounded upgrades. Luna accounting finalizes only after deterministic verification.

## Required components

Rail Two production readiness requires:

- Bitcoin watcher service
- finality service
- proof-pack builder
- proof-pack registry integration
- verifier implementation
- dispute monitor
- emergency response procedure
- verifier upgrade policy
- audit log system

## Honest status

Rail Two is not yet production Bitcoin enforcement.

The current repo proves that Luna can receive proof-gated native BTC settlement evidence and route Rail Two accounting through the native adapter.

It does not yet prove that Bitcoin-side evidence is trustlessly produced or cryptographically verified in production.
