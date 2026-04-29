# Rail Two Dispute and Emergency Response

## Purpose

This document defines the operational response model for disputed Rail Two enforcement.

Rail Two introduces native Bitcoin enforcement risk. Disputes can arise from reorgs, conflicting watcher observations, partial recovery, invalid proof packs, verifier bugs, or governance upgrade risk.

## Dispute triggers

A Rail Two dispute may be triggered by:

- conflicting Bitcoin observations
- insufficient confirmations
- reorg detection
- partial recovery mismatch
- proof-pack rejection
- duplicate proof-pack attempt
- wrong-rail settlement attempt
- verifier version mismatch
- emergency pause activation

## Emergency behavior

During a disputed Rail Two enforcement event:

- new Rail Two finalizations may be paused
- existing Rail One paths should remain isolated where possible
- proof-pack submission may continue for evidence preservation
- accounting finalization should wait for verifier-safe resolution
- governance actions should be logged and bounded

## Agent role

Agents may:

- detect anomalies
- compare watcher outputs
- prepare incident summaries
- alert governance
- recommend pause or review
- assemble evidence for auditors

Agents must not:

- unilaterally finalize Luna accounting
- override verifier rejection
- upgrade verifier logic
- bypass proof-pack requirements
- decide disputed recovery amounts without deterministic evidence

## Production requirement

Before Rail Two can be treated as production native Bitcoin enforcement, Luna needs a complete operational runbook for disputed enforcement events.
