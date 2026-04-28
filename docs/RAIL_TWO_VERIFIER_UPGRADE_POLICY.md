# Rail Two Verifier Upgrade Policy

## Purpose

This document defines governance and safety policy for upgrading Rail Two proof verifier logic.

The verifier is a critical Rail Two trust boundary. If it can be replaced carelessly, Rail Two becomes governance-trusted instead of proof-trusted.

## Current status

Rail Two has an adapter-side verifier boundary.

The production verifier implementation is not complete.

## Core principle

Verifier upgrades must be explicit, delayed, observable, and versioned.

The verifier should not be silently changed in a way that changes which Bitcoin evidence is accepted for settlement.

## Why verifier upgrades are dangerous

A malicious or broken verifier could accept fake recovery evidence, accept wrong-chain evidence, accept unconfirmed transactions, accept reorged transactions, accept recovery to the wrong destination, inflate recovered amounts, ignore replay protection, finalize wrong-rail positions, or finalize disputed positions.

## Recommended upgrade flow

Propose verifier, publish verifier metadata, publish verifier scope, publish proof-pack compatibility, publish review evidence if available, start timelock, allow review period, activate verifier, emit activation event, and preserve old verifier history.

## Required verifier metadata

Verifier metadata should include verifierAddress, verifierVersion, supportedProofPackVersions, supportedProofPackKinds, supportedBitcoinNetworks, finalityPolicyVersion, deploymentChainId, activationTime, activationBlock, deprecationTime, metadataURI, and codeHash.

## Versioning rules

The system should define whether old proof packs remain valid after upgrade, whether pending enforcement cases use old or new verifier, whether emergency upgrades invalidate old proof packs, whether proof packs expire after verifier deprecation, and whether verifier downgrades are allowed.

## Timelock policy

Normal verifier upgrades should be timelocked. Recommended initial policy: normal verifier upgrade delay required, emergency verifier freeze allowed, instant verifier replacement discouraged, activation event required, and metadata event required.

## Emergency freeze

The protocol should support freezing verifier acceptance when fake proof acceptance is suspected, Bitcoin reorg invalidates accepted proofs, a proof-pack builder is compromised, a verifier bug is discovered, recovery destination logic is disputed, or governance detects active exploitation.

A freeze should prevent new Rail Two finalizations, but should not necessarily pause Rail One.

## Governance boundaries

Governance may upgrade verifier contracts, pause verifier acceptance, update finality policy, update supported proof-pack versions, and approve emergency recovery procedures.

Governance should not be able to directly declare fake Bitcoin recovery as valid, bypass proof-pack verification, finalize wrong-rail positions, replay old proof packs, override recovered amounts without proof, or silently change verifier semantics.

## Agent boundaries

AI agents may monitor verifier behavior, compare verifier outputs, flag suspicious proof packs, simulate verifier upgrades, prepare review summaries, recommend emergency freeze, and generate audit checklists.

AI agents must not unilaterally upgrade verifier logic, bypass governance delay, approve settlement without cryptographic verification, act as the sole signer for critical governance actions, or hide disputed enforcement evidence.

## Current honest status

Rail Two has the verifier boundary.

Rail Two does not yet have the final production verifier implementation or full verifier upgrade process.

Before production, the verifier policy should be implemented in contracts, governance process, and operational runbooks.
