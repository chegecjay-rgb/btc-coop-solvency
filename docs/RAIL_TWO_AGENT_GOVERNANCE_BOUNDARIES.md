# Rail Two Agent Governance Boundaries

## Purpose

This document defines what AI agents may and may not do in Rail Two.

The goal is to use agents for operational leverage without turning them into trusted governance, custody, or settlement authorities.

## Core Boundary

Agents may recommend, observe, assemble, simulate, and alert.

Agents must not become the source of truth for settlement.

The source of truth must be:

- protocol state
- cryptographic verification
- deterministic verifier logic
- governance-controlled parameters
- timelocked upgrades
- emergency pause rules

## Permitted Agent Actions

Agents may:

- monitor Bitcoin transactions
- monitor Luna position state
- build proof-pack candidates
- simulate verifier outcomes
- detect replay attempts
- detect stale finality
- detect partial recovery risk
- recommend Rail Two pause
- recommend risk parameter review
- prepare governance proposals
- summarize disputed enforcement cases
- alert operators

## Restricted Agent Actions

Agents must not independently:

- finalize settlement
- mark recovery as valid without proof
- upgrade verifier logic
- change risk parameters
- bypass timelocks
- bypass emergency pause
- control borrower collateral
- control protocol treasury
- suppress dispute warnings
- decide policy outcomes

## AI-Assisted Multisig

AI agents may assist a multisig, but should not replace accountable human or institutional signers for critical actions.

Acceptable uses:

- transaction simulation
- risk report generation
- parameter diff explanation
- verifier upgrade review
- emergency alerting
- proposal drafting

Not acceptable for production:

- agents as the only multisig signers
- agents executing verifier upgrades without human review
- agents controlling emergency pause alone
- agents deciding disputed settlement alone

## Technical-Agent Departments

Good candidates for agent assistance:

- watcher operations
- proof-pack construction
- verifier simulation
- risk monitoring
- invariant monitoring
- documentation consistency
- test generation
- audit checklist generation

Poor candidates for full automation:

- final governance approval
- treasury spending
- verifier upgrades
- emergency settlement disputes
- policy decisions affecting users

## Emergency Pause During Disputed Enforcement

During disputed Rail Two enforcement, the protocol should support a conservative emergency posture:

1. pause new Rail Two borrowing
2. block disputed settlement finalization
3. allow evidence submission
4. allow proof-pack review
5. allow governance to choose resolver path
6. preserve Rail One operations where safe

Emergency pause should not erase evidence. It should prevent unsafe finalization.

## Governance Upgrade Boundaries

Verifier and enforcement upgrades should require:

- timelock
- versioning
- event emission
- review window
- rollback plan
- documented migration path
- test suite update
- proof-pack compatibility statement

Agents can prepare the review. Governance must approve the change.

## Production Readiness Checklist

Rail Two is not production-ready until the following exist:

- watcher and finality service
- proof-pack builder
- verifier implementation
- Bitcoin enforcement transaction design
- reorg handling rules
- disputed enforcement process
- verifier upgrade governance
- emergency pause runbook
- external review of verifier assumptions

## Honest Claim

Luna can say that Rail Two uses agent-assisted operations for monitoring and proof construction, while agents remain bounded by verifier checks, adapter rules, replay protection, governance controls, and emergency pause boundaries.

Luna should not say that AI agents control native BTC settlement.
