# Rail Two Watcher and Finality Service

## Purpose

The watcher and finality service is responsible for observing Bitcoin state and producing finality records for Rail Two native BTC pledges and recoveries.

## Watcher responsibilities

The watcher should monitor:

- pledge funding transactions
- pledge output index
- script or spending condition
- confirmation depth
- reorg risk
- enforcement transactions
- recovery transactions
- settlement outputs
- conflicting spends
- partial recovery events

## Finality responsibilities

The finality service should determine when a Bitcoin observation is safe enough to be used by Luna.

It should track:

- block height
- block hash
- transaction ID
- output index
- confirmation count
- observed amount
- script commitment
- reorg status
- invalidation status

## Reorg handling

If a reorg invalidates a pledge, enforcement transaction, or recovery transaction, the watcher must produce an invalidation record.

Luna accounting should not finalize disputed Rail Two recovery while the finality state is unresolved.

## Agent boundary

An AI agent may help monitor logs, compare observations, summarize risk, or alert operators.

The finality result must come from deterministic watcher logic and verifiable Bitcoin evidence, not from an AI opinion.
