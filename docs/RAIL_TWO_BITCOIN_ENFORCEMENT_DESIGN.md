# Rail Two Bitcoin Enforcement Design

## Purpose

This document records the remaining Bitcoin-side design work required for Rail Two to become production native BTC enforcement.

The Solidity kernel can receive Rail Two enforcement evidence, but the actual Bitcoin enforcement structure must still be designed and implemented.

## Required enforcement property

For Rail Two to support credit safely, pledged native BTC must have an enforceable settlement path.

The system must not merely observe a user BTC balance and hope the user cooperates later.

Production target: if the borrower defaults or the position becomes terminal, Luna has a predefined, verifiable, and operationally executable path to recover value from the pledged native BTC.

## Candidate models

### Model 1: multisig enforcement path

The pledged BTC is held in a script where spending requires a defined signer set. Possible paths include a healthy borrower path, an enforcement quorum path, and an emergency recovery path under strict policy.

Advantages: practical today and compatible with current Bitcoin tooling. Risks: signer trust, key management, governance capture, and borrower-protection complexity.

### Model 2: timelocked script path

The pledged BTC is locked with time-based recovery paths. Advantages: objective timing constraints. Risks: hard to encode Luna-side credit conditions directly in Bitcoin script.

### Model 3: pre-signed transaction package

The borrower pre-signs transactions that allow settlement under defined conditions. Advantages: practical with current Bitcoin. Risks: fee management, package validity, pinning, replacement, and conflicting spends.

### Model 4: covenant-like construction

If covenant-like functionality becomes available or can be safely emulated, pledged BTC may be constrained to specific settlement paths. Advantages: stronger enforceability and less signer discretion. Risks: higher complexity and possible dependence on future Bitcoin functionality.

### Model 5: hybrid model

A practical launch path may combine multisig custody or co-signing, timelocked fallback, watcher monitoring, proof-pack verification, and emergency governance controls.

## Minimum production requirements

The final design must define who controls the funding output, who can spend during healthy state, who can spend during enforcement, what triggers enforcement, what prevents unauthorized borrower withdrawal, what prevents unauthorized protocol seizure, how the recovery destination is fixed, how partial recovery is handled, how Bitcoin fees are handled, how change outputs are handled, how disputes are opened, how emergency pause interacts with enforcement, and what evidence proves recovery was valid.

## Pledge transaction requirements

The pledge funding transaction should bind a position commitment, borrower identity commitment, pledge amount, script commitment, enforcement policy, recovery destination commitment, and expiry or timeout policy.

The key requirement is that Luna can bind the Bitcoin output to the Luna position.

## Recovery transaction requirements

The recovery transaction must prove that it spends the pledged output or authorized enforcement path, pays the expected recovery destination, measures recovered amount correctly, has sufficient confirmations, is not invalidated by reorg, is not reused across positions, and maps correctly into Luna accounting.

## Fee and change policy

Production policy must specify who pays enforcement transaction fees, whether fees reduce recovered amount, whether change belongs to borrower or protocol or settlement pool, how dust is handled, whether fee bumping is allowed, who authorizes CPFP or RBF actions, and whether fee-bump transactions need separate proof packs.

## Current honest status

Rail Two currently has the receiving architecture for Bitcoin enforcement evidence.

Rail Two does not yet have the final production Bitcoin enforcement design.

Until this design is implemented and reviewed, Rail Two should be described as architecturally prepared for enforceable native BTC collateral, but not yet production native BTC enforcement.
