# Recovery EA Ultimate V8 — จรวจนำวิถี

A production-grade MQL5 Expert Advisor for **BTCUSD on MetaTrader 5**, designed for a $500 account with prop-desk compliance (~10% max drawdown).

## Strategy Overview

**Dual-timeframe trend-following** with Zone Recovery Hedging (ZRH):

1. **H4 Trend Lock** — EMA50 vs EMA200 determines directional bias (buy-only / sell-only)
2. **M5 Entry Engine** — Triple EMA alignment (8/13/21) + RSI reversal confirmation
3. **Zone Recovery Hedging** — Fibonacci-scaled hedge layers when price moves against the position
4. **Smart Shaving** — Closes profitable + losing legs in pairs to reduce exposure
5. **Dynamic TP + Trailing** — Volume-based profit target with trailing basket protection

## Key Features

- **Auto Lot Sizing** — Scales position size to account equity ($500 per 0.01 lot)
- **Fibonacci Lot Scaling** — Recovery layers use Fib sequence: 1, 1, 2, 3, 5, 8, 13, 21
- **Equity Kill Switch** — Closes all positions at configurable drawdown % (default 10%)
- **State Persistence** — Cycle state survives EA restart via GlobalVariables
- **Margin Safety** — Pre-trade margin check rejects orders if free margin < 20% of equity
- **Spread Filter** — Blocks new entries during high-spread conditions
- **On-Chart Dashboard** — Real-time display of trend, RSI, cycle status, P&L, and margin

## Input Parameters

| Parameter | Default | Description |
|---|---|---|
| MagicNumber | 88888 | Position identification |
| AutoLot | true | Auto-calculate lot from equity |
| BaseLot | 0.01 | Manual lot (if AutoLot=false) |
| AutoLotEquityStep | 500.0 | Equity per 0.01 lot |
| MaxLayers | 8 | Max recovery hedge layers |
| ZoneRecoveryPoints | 8000 | Distance to trigger hedge (points) |
| MaxSpread | 500 | Max allowed spread (points) |
| EquityCutoffPercent | 10.0 | Kill switch drawdown % |
| H4_EMA_Fast / Slow | 50 / 200 | H4 trend EMA periods |
| M5_EMA1 / EMA2 / EMA3 | 8 / 13 / 21 | M5 entry EMA periods |
| RSI_Period | 14 | RSI period on M5 |
| RSI_Oversold / Overbought | 25 / 75 | RSI thresholds |
| ProfitPerVolume | 50.0 | Target USD per 0.01 lot volume |
| TrailingActivation | 0.8 | Trailing activates at 80% of target |
| TrailingStep | 10.0 | Trailing step in USD |
| ShowDashboard | true | Enable on-chart dashboard |

## Installation

1. Copy `RecoveryEA_Ultimate.mq5` to `MQL5/Experts/` in your MT5 data folder
2. Compile in MetaEditor (0 errors, 0 warnings expected)
3. Attach to a BTCUSD M5 chart
4. Ensure "Allow Algo Trading" is enabled

## Risk Warning

This EA uses hedging and martingale-like lot scaling. While safety systems are built in (equity cutoff, max layers, margin checks), all trading involves risk. Test thoroughly on a demo account before live deployment.
