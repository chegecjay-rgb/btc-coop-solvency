# Rail Two Proof-Pack Builder

## Purpose

The proof-pack builder assembles Bitcoin-side evidence into a deterministic evidence bundle that can be submitted to Luna.

A proof pack should be versioned, replay-resistant, position-bound, rail-bound, and independently verifiable.

## Builder inputs

The builder may consume:

- Bitcoin block headers
- transaction proofs
- pledge funding transaction data
- output proofs
- confirmation data
- enforcement transaction data
- recovery transaction data
- script or policy commitments
- reorg invalidation evidence
- watcher signatures or attestations where applicable

## Required proof-pack properties

A production proof pack should include:

- proof pack version
- proof pack kind
- position ID
- rail ID
- pledge ID
- Bitcoin network
- relevant transaction IDs
- relevant output indexes
- amount recovered
- finality evidence
- evidence root
- verifier version
- replay-protection nonce or commitment

## Replay protection

A proof pack must not be reusable across:

- positions
- rails
- pledge IDs
- recovery events
- verifier versions
- settlement attempts

## Agent boundary

Agents may help assemble candidate proof packs.

Agents must not be trusted as proof.

A proof pack becomes settlement-relevant only after verifier approval.
