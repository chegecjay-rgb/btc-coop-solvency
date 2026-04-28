# Rail Two ZK Verifier Model

## Purpose

This document describes the intended verifier model for Rail Two native BTC settlement.

The goal is not to trust an AI agent, watcher, or operator.

The goal is to verify that a submitted proof pack correctly represents Bitcoin-side enforcement evidence for a Luna position.

## Current Status

Current implementation status:

- proof-pack storage exists
- proof-pack replay protection exists
- NativeSettlementAdapter requires a proof-pack reference
- NativeSettlementAdapter requires observed native recovery
- NativeSettlementAdapter blocks wrong-rail settlement
- NativeSettlementAdapter blocks double finalization

Missing production components:

- real Bitcoin proof verifier
- finality proof model
- Bitcoin transaction or script enforcement design
- proof-pack builder service
- watcher and finality service
- dispute and emergency runbook

## Verification Target

A valid Rail Two proof should establish:

1. the proof pack is bound to the Luna position
2. the proof pack is bound to the native pledge commitment
3. the relevant Bitcoin transaction exists
4. the transaction is sufficiently confirmed
5. the transaction spends or controls the expected pledge collateral
6. the recovered amount is correctly computed
7. the recovered amount is not overstated
8. the evidence has not already been used
9. the proof pack has not been replayed
10. the settlement path matches the position rail

## ZK Verifier Role

A ZK verifier may be used to prove Bitcoin-side facts without putting all raw Bitcoin data onchain.

Possible verified facts include:

- transaction inclusion
- confirmation depth
- output or script match
- spend path match
- recovered amount
- pledge commitment binding
- position binding
- no replay reference
- finality window satisfaction

The ZK verifier should verify factual claims. It should not decide business policy.

## Proof-Pack Structure

A production proof pack should eventually include:

- positionId
- pledgeCommitment
- btcTxid
- btcBlockHeader
- merkleProof
- confirmationDepth
- observedRecoveredAmount
- recoveryOutputRef
- enforcementPathId
- finalityCheckpoint
- proofNonce
- proofPackHash
- verifierVersion

## Adapter Acceptance Rule

The NativeSettlementAdapter should only finalize Luna accounting when:

- the position is Rail Two
- the proof pack exists
- the proof pack is bound to the position
- the proof pack is not replayed
- native recovery was observed
- recovered amount is greater than zero
- verifier accepts the proof
- position is not already finalized

## Preventing Fake Recovery Evidence

Fake recovery evidence is prevented by requiring Bitcoin transaction evidence, pledge commitment binding, output or script validation, finality confirmation, amount verification, replay protection, and adapter-side position finalization locks.

An AI agent report alone is never sufficient.

## Preventing Partial Recovery Manipulation

Partial recovery manipulation is prevented by checking the exact recovered amount, expected pledged amount, settlement type, shortfall accounting, and whether the proof claims full or partial recovery.

The system should never allow partial recovery to be presented as full recovery.

## Reorg Handling

The finality model should define:

- minimum Bitcoin confirmations
- deeper confirmation requirement for high-value positions
- reorg detection window
- disputed-finality state
- pause behavior during disputed finality
- proof invalidation rules if a recovery transaction is reorged out

## Verifier Upgrades

Verifier upgrades are high-risk.

Recommended controls:

- timelocked upgrades
- versioned verifier registry
- event emission on verifier change
- old proof-pack compatibility rules
- emergency pause
- governance review period
- optional external audit before production verifier upgrade

## Honest Claim

Rail Two can support cryptographically verified native BTC settlement once the verifier, watcher, finality service, proof-pack builder, and Bitcoin-side enforcement design are implemented.

AI agents do not make native BTC settlement safe by themselves.
