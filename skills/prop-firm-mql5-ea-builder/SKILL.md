---
name: prop-firm-mql5-ea-builder
description: Generate or update production-ready MetaTrader 5 Expert Advisors (MQL5) for XAUUSD under prop-firm constraints. Use when requests involve algorithmic trading EA architecture, signal/risk/order/session/grid/recovery modules, execution microstructure hardening, prop-firm rule compliance, grid and recovery risk controls, or backtest validation protocols for live-like hostile broker conditions.
---

# Prop Firm MQL5 EA Builder

## Overview
Build deterministic, modular MQL5 EAs for XAUUSD with strict prop-firm risk governance and execution realism. Reuse bundled framework references and assets instead of recreating architecture from scratch.

## Workflow
1. Parse the user request into module scope: `Signals`, `Risk`, `Orders`, `Sessions`, `Grid`, `Recovery`, plus optional `Regime`, `PortfolioRisk`, `PropRules`, `Validation`.
2. Select only relevant references from `references/`:
- `EA_ARCHITECTURE_TEMPLATE.md` for baseline module layout and state orchestration.
- `PROP_FIRM_RULE_ENGINE.md` for hard limits and compliance gates.
- `PORTFOLIO_RISK_ENGINE.md`, `GRID_RISK_MODEL.md`, `ADVANCED_RECOVERY_ENGINE.md` for exposure and containment.
- `EXECUTION_MICROSTRUCTURE_ENGINE.md` for slippage/spread/fill/freeze handling.
- `MARKET_REGIME_ENGINE.md` for regime gating and strategy switching.
- `BACKTEST_VALIDATION_PROTOCOL.md` and `MONTE_CARLO_TEST_GUIDE.md` for robustness validation requirements.
3. Start from `assets/prop-trading-ea-framework/code/EA_CODE_SKELETON.mq5` when creating a new EA; preserve modular sections and deterministic state transitions.
4. Enforce execution safety before every state transition:
- Verify symbol trading permissions, spread ceilings, freeze/stops levels, margin headroom, and pending order constraints.
- Handle rejection, requote, partial fill, and retry paths explicitly.
5. Enforce risk governance as code, not commentary:
- Hardcode daily and total drawdown guards.
- Cap aggregate lots, grid depth, and recovery escalation.
- Block new risk when latency, spread, or slippage exceed thresholds.
6. Emit final code in one complete `.mq5` block with production-ready functions and inputs; avoid pseudocode or placeholders.

## Implementation Rules
- Keep logic modular with dedicated functions per engine and deterministic state enums.
- Prefer constant-time checks inside `OnTick`; avoid heavy loops and repeated indicator handle churn.
- Use symbol-specific precision (`_Point`, `_Digits`, `SYMBOL_TRADE_TICK_SIZE`, `SYMBOL_VOLUME_STEP`) for all prices and volumes.
- Guard all trade operations with return-code checks and structured recovery branches.
- Persist critical runtime state needed after terminal restart (sequence IDs, session guards, recovery stage).
- Default to conservative fail-safe behavior when data is missing or market conditions degrade.

## Output Contract
- Return full single-block MQL5 code only when asked to generate code.
- Omit narrative and setup text in code-generation responses.
- Target MetaTrader 5 compliance and prop-firm execution constraints for XAUUSD.

## Resources
- `references/`: domain engines, risk models, architecture template, and validation protocols.
- `assets/prop-trading-ea-framework/`: reusable framework scaffold and templates.
