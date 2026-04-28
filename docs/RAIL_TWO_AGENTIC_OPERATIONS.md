# Rail Two Agentic Operations

## Status

Rail Two is Luna's enforceable native BTC collateral rail.

Current status:

- rail-aware kernel exists
- native pledge identity layer exists
- BTC-side enforcement skeleton exists
- native settlement adapter exists
- liquidation and terminal settlement routing are wired to the adapter path

Rail Two is not yet production Bitcoin enforcement.

The remaining production-critical pieces are:

- Bitcoin watcher service
- Bitcoin finality service
- proof-pack builder
- proof verifier implementation
- Bitcoin transaction, script, multisig, or covenant enforcement design
- operational runbook for disputed enforcement

## Core Principle

Agents may operate the system, but cryptography must verify the system.

Unsafe model:

    Agent says BTC was recovered -> Luna finalizes accounting

Correct model:

    Agent observes Bitcoin data
    -> proof-pack builder assembles evidence
    -> verifier checks evidence
    -> NativeSettlementAdapter finalizes Luna accounting

Agents are useful because they automate observation, packaging, monitoring, escalation, and review.

Agents are not trusted because they are intelligent.

## Agent Roles

### Bitcoin Watcher Agent

The watcher agent monitors pledged BTC addresses, scripts, UTXOs, funding transactions, spend transactions, confirmations, chain tips, and reorg risk.

It must not finalize Luna accounting or decide that recovery is valid by itself.

### Finality Agent

The finality agent determines whether Bitcoin evidence has reached the required confirmation depth and whether reorg risk remains.

It must not treat zero-confirmation evidence as final.

### Proof-Pack Builder Agent

The proof-pack builder agent assembles Bitcoin evidence and binds it to a Luna position, pledge commitment, finality metadata, observed recovered amount, and proof-pack reference.

It must not invent missing evidence, reuse proof packs, or mutate proof-pack contents after submission.

### Verifier Agent / Verifier Service

The verifier service pre-checks proof packs, simulates verifier acceptance, and detects malformed, stale, replayed, or incomplete proof packs.

It must not replace deterministic or cryptographic verification.

### Enforcement Coordinator Agent

The enforcement coordinator agent monitors enforcement lifecycle, tracks progress, coordinates operator alerts, and prepares adapter calls after proof verification is available.

It must not mark Luna settlement complete without adapter execution.

### Risk Control Agent

The risk control agent monitors Rail Two exposure, borrow caps, concentration risk, and evidence-quality risk.

It may recommend pause or parameter review, but must not change critical parameters without governance authorization.

## Evidence Flow

    Native pledge commitment created
    -> pledge registered against Luna position
    -> BTC-side pledge funded or activated
    -> watcher observes BTC evidence
    -> finality service confirms maturity
    -> proof-pack builder assembles evidence
    -> proof-pack registry stores reference
    -> verifier validates proof
    -> NativeSettlementAdapter finalizes accounting

## Failure Model

Agents can fail through stale Bitcoin data, missed reorgs, wrong transaction attribution, wrong amount attribution, duplicate proof submission, partial recovery presented as full recovery, or malicious/disputed evidence.

The protocol must assume agents can fail.

The protocol should require:

- deterministic proof-pack references
- replay protection
- position binding
- pledge binding
- observed recovery checks
- finality checks
- verifier approval
- emergency pause
- governance delay for verifier upgrades

## Honest Claim

Luna can honestly claim that Rail Two is designed for enforceable native BTC collateral with agent-assisted observation and proof construction.

Luna should not claim that native BTC liquidation is production-ready until the Bitcoin-side enforcement design, watcher, finality service, proof-pack builder, and verifier implementation are complete.
