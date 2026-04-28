# Rail Two Finality and Reorg Policy

## Purpose

This document defines the production finality and reorg policy required for Rail Two.

Bitcoin finality is probabilistic. Rail Two must avoid treating observed transactions as final too early.

## Current status

The current Solidity implementation can record finality state for a native pledge.

The production watcher and finality service are not yet implemented.

## Finality states

Rail Two should distinguish observed, included, confirming, finalized, reorged, disputed, and invalidated states.

A transaction should not be treated as credit-ready or settlement-ready until it satisfies the required finality policy.

## Pledge finality

The finality service should verify that the funding transaction exists, the funding output exists, the output amount is correct, the output script matches the pledge commitment, the funding transaction is included in a Bitcoin block, the block is part of the accepted chain, the confirmation depth satisfies policy, and the output is unspent at credit activation time.

Conservative initial policy: minimum confirmations 6, reorg monitoring required, stale proof rejection required, and network binding required.

## Recovery finality

Recovery finality determines whether Luna accounting can finalize after enforcement.

The finality service should verify that the recovery transaction exists, spends the correct pledge path, pays the expected destination, reports the recovered amount correctly, has required confirmations, remains canonical after reorg monitoring, and has not expired.

## Reorg handling before credit activation

Downgrade pledge finality, block credit-ready status, and prevent borrowing activation.

## Reorg handling after credit activation

Freeze the affected position, pause new Rail Two borrowing if needed, mark the pledge disputed, require fresh proof, trigger emergency review, and restrict settlement until resolved.

## Reorg handling after recovery observation but before Luna finalization

Invalidate observed recovery, reject the proof pack, block finalization, and keep enforcement pending or disputed.

## Reorg handling after Luna finalization

Treat as severe settlement failure, define whether recapitalization or insurance absorbs loss, trigger governance review, consider pausing affected Rail Two paths, and review finality service and verifier correctness.

## Watcher responsibilities

Watchers should monitor funding transaction confirmations, funding output spend status, reorgs affecting funding transactions, enforcement transaction broadcast, recovery transaction confirmations, recovery destination correctness, double-spend attempts, conflicting proof packs, stale proofs, and chain reorganizations.

Watchers may be AI-assisted, but they should produce evidence for verification.

## Finality service output

A finality claim should include bitcoinNetwork, txid, blockHash, blockHeight, confirmationDepth, observedTipHash, observedTipHeight, policyVersion, createdAt, and expiry.

## Emergency behavior

During finality disputes, new Rail Two borrowing may be paused, affected positions may be frozen, finalization may be blocked, Rail One should remain unaffected unless a wider emergency exists, governance may activate emergency review, and verifier upgrades should be restricted or timelocked unless emergency policy allows otherwise.

## Current honest status

The Solidity system can record finality state.

Production Bitcoin finality verification is not yet implemented.
