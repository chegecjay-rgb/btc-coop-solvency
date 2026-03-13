# LUNAR-COOP

**LUNAR-COOP** is a working prototype of a cooperative leverage-preservation protocol designed to reduce liquidation dependence in crypto-backed borrowing.

Instead of treating liquidation as the primary risk-management mechanism, LUNAR-COOP explores a different architecture: structured rescue, controlled terminal resolution, optional buyback cover, and recapitalization flows that aim to preserve solvency while keeping protocol accounting explicit.

This repository contains a **test-backed research-stage prototype** of the protocol’s core contracts.

## Summary

LUNAR-COOP is a modular solvency architecture for BTC-collateralized leverage.

The current prototype includes:

- asset and parameter registries
- borrower collateral custody
- lender liquidity vaults
- stabilization capital pools
- insurance reserve logic
- debt and collateral accounting
- oracle validation
- expected loss and health factor modeling
- interest rate logic
- risk evaluation
- remote liquidity intent routing
- rescue execution
- buyback cover and claim issuance
- recapitalization waterfall logic
- liquidation fallback
- circuit breaker controls
- flash-close routing primitives

The core thesis is simple:

> DeFi lending systems are usually optimized for efficient liquidation.  
> LUNAR-COOP is being designed as a system for **cooperative leverage preservation**, where rescue, controlled resolution, and explicit capital recovery come before forced failure wherever possible.

---

## Why this exists

Liquidation-first lending systems are efficient, but they are often hostile to borrowers during volatility and can create abrupt failure dynamics.

LUNAR-COOP explores a different model built around these ideas:

- **borrower collateral is ring-fenced**
- **lender liquidity is separated from rescue capital**
- **insurance is explicit, not hidden**
- **rescue capital usage is accounted for**
- **buyback claims recover all protocol capital used on a position**
- **remote liquidity can be used as a pre-insolvency escalation layer**
- **liquidation remains a last resort, not the default first response**

This repository is the implementation prototype of that architecture.

---

## Current status

This codebase is currently a **prototype / research-stage implementation**.

It is:

- modular
- extensively unit tested
- suitable for architecture review
- suitable for early technical diligence
- suitable for continued integration testing and design iteration

It is **not**:

- audited
- production-ready
- deployed to mainnet
- presented as final economic policy

### Current test status

At the time of writing:

- **26 test suites**
- **373 passing tests**
- **0 failing tests**

Run locally with:

```bash
forge test -vv

