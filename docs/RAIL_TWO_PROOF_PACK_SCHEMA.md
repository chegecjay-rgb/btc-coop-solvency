# Rail Two Proof-Pack Schema

## Purpose

This document defines the intended production shape of Rail Two proof packs.

A proof pack is the evidence bundle used to justify a Rail Two accounting transition inside Luna.

The current Solidity implementation stores proof-pack references and uses them as settlement gates. Production verification must bind those references to real Bitcoin evidence.

## Design principle

A proof pack should be machine-readable, deterministic, versioned, replay-resistant, and independently verifiable.

Agents may build proof packs, but agents should not be trusted as the final source of truth.

The verifier must check whether the proof pack corresponds to real Bitcoin state and the correct Luna position.

## Proof-pack categories

Rail Two may require pledge funding proofs, pledge finality proofs, enforcement transaction proofs, recovery transaction proofs, settlement output proofs, reorg or invalidation proofs, dispute proofs, and partial recovery proofs.

## Common fields

Every proof pack should include proofPackVersion, proofPackKind, positionId, railId, pledgeId, bitcoinNetwork, createdAtBitcoinHeight, createdAtLunaBlock, expiryBitcoinHeight, expiryLunaBlock, verifierVersion, builderId, evidenceRoot, domainSeparator, and nonce.

## Pledge funding proof

A pledge funding proof should include positionId, pledgeId, btcFundingTxId, fundingOutputIndex, fundingOutputAmountSats, fundingScriptPubKey, fundingScriptCommitment, fundingMerkleProof, fundingBlockHash, fundingBlockHeight, and confirmationDepth.

Verifier checks should prove that the funding transaction exists, the output exists, the amount matches the registered pledge, the script commitment matches the registered pledge, the transaction is included in the claimed block, the block belongs to the accepted Bitcoin chain view, the confirmation depth satisfies policy, and the output is not reused for another active position.

## Recovery proof

A recovery proof should include positionId, pledgeId, recoveryTxId, recoveryOutputIndex, recoveryAmountSats, recoveryDestination, recoveryScriptPubKey, recoveryMerkleProof, recoveryBlockHash, recoveryBlockHeight, confirmationDepth, bitcoinFeesPaid, changeOutputs, and unrecoveredAmountSats.

Verifier checks should prove that the recovery transaction exists, spends the pledged outpoint or authorized enforcement path, pays the correct Luna recovery destination, does not inflate the recovered amount, handles fees and change according to policy, has sufficient confirmations, has not been used for another finalized position, and is not stale or replayed.

## Partial recovery

If recovery is partial, the proof pack should include expectedRecoverableAmountSats, actualRecoveredAmountSats, shortfallAmountSats, shortfallReason, feeAmountSats, badDebtAmount, recapitalizationAmount, and remainingClaimState.

The protocol must define whether partial recovery finalizes the position, leaves it pending, allows supplemental proofs, triggers recapitalization, triggers insurance usage, or recognizes bad debt.

## Replay resistance

Proof packs must include domain separation over protocolId, chainId, Luna deployment, positionId, pledgeId, proofPackKind, proofPackVersion, verifierVersion, nonce, and sourceBitcoinNetwork.

A Bitcoin transaction must not be reusable to finalize unrelated positions unless an explicit protocol rule allows it.

## Verifier output

A production verifier should return structured output including valid, proofPackRef, positionId, pledgeId, proofPackKind, recoveredAmountSats, settlementCost, bitcoinHeight, confirmationDepth, verifierVersion, and failureCode.

## Open design question

The current adapter accepts recovered amount and settlement cost as inputs. Before production, Luna should decide whether those values are passed as inputs and checked by the verifier, decoded from verifier output, committed inside the proof-pack reference, or derived entirely from verified Bitcoin evidence.

The strongest model is for the verifier to bind recovered amount and settlement cost to the proof pack.
