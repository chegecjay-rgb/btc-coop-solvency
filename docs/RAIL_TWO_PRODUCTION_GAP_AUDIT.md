# Rail Two Production Gap Audit

## Purpose

This document records the current architectural status of Luna Rail Two and the remaining work required before Rail Two can be described as production-ready native Bitcoin enforcement.

Rail Two is the enforceable native BTC collateral rail. It represents native BTC collateral without wrapping while preserving an enforceable liquidation and settlement path.

## Current status

The Solidity-side Rail Two receiving architecture is integrated.

Completed phases:

- Phase A: rail-aware kernel
- Phase B: native collateral identity layer
- Phase C: BTC-side enforcement skeleton
- Phase D.1: native settlement adapter
- Phase D.2: Rail Two liquidation routing through the adapter
- Phase D.3: Rail Two terminal settlement routing through the adapter
- Phase E.1: end-to-end native enforcement lifecycle integration test

The current implementation supports rail-aware positions, rail-aware risk parameters, rail-aware borrow caps, native pledge registration, pledge finality state, pledge enforcement state, deterministic pledge commitments, proof-pack storage with replay protection, enforcement lifecycle tracking, proof-gated Luna accounting finalization, wrong-rail protection, bypass protection, replay protection, and double-finalization protection.

## Honest current claim

Luna can honestly claim that it has a rail-aware collateral architecture where native BTC positions can be represented, tracked, moved through an enforcement lifecycle, and finalized into Luna accounting through a dedicated proof-gated native settlement adapter.

Luna can also claim that Rail Two settlement accounting is not finalized by a generic admin call. It requires a proof-pack reference, observed recovery, verifier approval, replay protection, and correct rail routing.

## Claims that must not be made yet

Luna must not yet claim:

- production native BTC enforcement is live
- native BTC liquidation is trust-minimized in production
- Luna can independently enforce Bitcoin collateral today
- proof packs are cryptographically verified against Bitcoin today
- Bitcoin finality is verified onchain today
- recovery evidence is fully trustless today
- the current Rail Two design eliminates all offchain trust

## Remaining production-critical gaps

Rail Two is not production Bitcoin enforcement yet.

The missing pieces are: Bitcoin watcher service, Bitcoin finality service, proof-pack builder, production proof verifier, Bitcoin transaction or script or multisig or covenant enforcement design, reorg handling policy, partial recovery accounting policy, disputed enforcement procedure, verifier upgrade governance policy, emergency pause behavior during disputed enforcement, and an operational runbook for Rail Two enforcement.

## Core trust boundary

The central remaining question is how Luna knows that native BTC was actually pledged, finalized, enforced, and recovered.

The current Solidity architecture can receive and enforce proof-gated state transitions, but production readiness depends on making the proof source reliable.

## Agent role

Agents may observe Bitcoin, assemble evidence, monitor confirmations, detect reorgs, compare recovery claims, flag disputes, recommend emergency actions, and produce audit logs.

Agents must not be the root source of truth for final settlement.

Production target: agents build evidence, cryptography verifies evidence, and governance manages bounded upgrades and emergency response.

## Reviewer checklist

- Rail One paths remain preserved.
- Rail Two paths cannot accidentally use Rail One accounting.
- Rail Two positions cannot finalize without the native adapter.
- Native adapter requires a proof-pack reference.
- Native adapter requires observed recovery.
- Native adapter requires verifier approval.
- Proof packs cannot be replayed.
- Positions cannot finalize twice.
- Wrong-rail positions cannot use the native adapter.
- Pledge finality is separate from enforcement state.
- Enforcement progress is separate from Luna accounting finality.
- Documentation clearly states that production Bitcoin enforcement is not complete.

## Audit judgment

Rail Two is coherent and materially advanced on the Solidity side.

Rail One is production-closer because Luna controls escrowed wrapped BTC inside smart-contract accounting.

Rail Two is architecturally ready to receive native BTC enforcement evidence, but the production reliability of that evidence remains the next major workstream.
