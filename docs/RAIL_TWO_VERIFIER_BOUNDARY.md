# Rail Two Verifier Boundary

## Purpose

The verifier is the boundary between offchain Bitcoin evidence and Luna accounting.

The verifier must answer one question:

> Does this proof pack validly prove the Bitcoin-side event required for this Rail Two settlement transition?

## Verifier responsibilities

The verifier should validate:

- proof-pack format
- proof-pack version
- proof-pack kind
- position binding
- rail binding
- pledge binding
- finality evidence
- recovery amount
- transaction inclusion
- output correctness
- replay protection
- verifier version compatibility

## What the verifier must not do

The verifier should not make discretionary policy judgments such as:

- whether a borrower deserves rescue
- whether governance should pause the protocol
- whether a disputed event is socially acceptable
- whether an operator acted honestly

Those questions belong to governance or emergency policy.

The verifier should remain narrow and deterministic.

## ZK path

A future ZK verifier may be used to compress Bitcoin evidence into a succinct proof.

Even with ZK, the trust boundary remains the same:

> Agents build evidence. Cryptography verifies evidence. Luna accounting finalizes only after verification.
