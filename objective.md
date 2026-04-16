# MT5 High-Frequency Scalper Implementation Plan (XAUUSD, VPS ~2ms)

## Goals and Constraints
- Platform: MetaTrader 5 (XM360, no commission).
- Symbol: XAUUSD; low-latency VPS (~2 ms).
- Lot: fixed baseline 0.01; optional dynamic sizing that respects margin, leverage, spread, slippage.
- Style: toggleable breakout / mean-reversion; dynamic holding time.
- Risk controls: configurable (daily loss, max trades, max concurrent), even if user may set high values.
- Market conditions: gate on spread and slippage; adapt parameters as conditions change.

## Operating Defaults (tunable)
- Spread cap: 30 points (range 25–35).
- Slippage cap: 12 points (range 10–15).
- Baseline lot: 0.01.
- Risk-per-trade (if dynamic sizing on): default 0.25–0.5% balance/equity.
- Max trades/day: default 20. Max concurrent: default 2.
- Daily loss breaker: default 3–5% of balance/equity.
- Cooldown per symbol: e.g., 60–120 seconds after exit.
- Time stop: close after N bars (e.g., 10–20 M1 bars) if neither TP nor SL hits.
- Sessions: avoid rollover; optional news blackout windows.

## Inputs (suggested set)
- Symbol(s) (default XAUUSD), timeframe (M1/M5).
- Strategy mode: `breakout`, `mean_reversion`, `auto_toggle`.
- Risk settings: fixed lot (0.01), dynamic risk %, max lot, margin buffer %, max concurrent, max trades/day, daily loss %.
- Market gates: spread cap, slippage cap, ATR band thresholds, news/rollover windows.
- Execution: max deviation (points, tied to spread/ATR), retry count/backoff, filling type preference (FOK then IOC fallback).
- Trade management: TP/SL (points), break-even trigger/offset, trailing mode (volatility-scaled), partial take-profit levels (optional), time stop (bars).
- Cooldowns: per-symbol cooldown, error-streak circuit breaker.
- Logging: verbosity, summary interval, optional webhook/alerts.

## Market Condition Gating
- Block entries if:
  - Current spread > spread cap.
  - Median slippage over last N fills > slippage cap.
  - ATR outside configured band (too low: no movement; too high: avoid extreme volatility).
  - Within rollover or news blackout windows.
- Recompute margin requirements, leverage, lot step each tick and on timer.

## Signal Logic
- Breakout: recent high/low break with momentum confirmation (fast MA slope + RSI/price impulse), only if spread and slippage healthy.
- Mean-reversion: z-score of short returns or distance from VWAP/EMA band; enter toward mean when volatility stable and spread healthy.
- Per-symbol cooldown and confidence scoring; allow `auto_toggle` to select the mode based on recent performance or volatility regime.

## Execution & Slippage Control
- Pre-check free margin and lot step compliance; compute lot = max(0.01, risk-based lot) with margin buffer (e.g., keep 60–70% free margin).
- Send orders with FOK and bounded deviation; if symbol enforces IOC, fall back gracefully.
- Retry on requote/off-quotes with capped attempts and backoff; record slippage per fill.
- Deviation dynamically tied to current spread and recent slippage stats.

## Risk & Exposure
- Even if “no limits,” keep configurable guardrails: daily loss breaker, max trades/day, max concurrent trades, error-streak breaker.
- Server-side SL/TP placed immediately; time-stop exit to prevent drift.
- Persist daily P/L and breaker state via Global Variables of Terminal.

## Trade Management
- Spread-adjusted SL/TP (wider for buys on wide spreads).
- Break-even shift after X points; volatility-scaled trailing stop.
- Optional partial close at RR milestones; time-stop after N bars.

## Adaptivity
- Continuously adjust:
  - Allowed deviation (points) based on live spread and recent slippage.
  - Lot ceiling based on margin, leverage changes, and free-margin buffer.
  - Minimum target profit (ensure TP covers spread + typical slippage + fee buffer).
- Pause trading when conditions degrade; auto-resume when healthy.

## Performance & Reliability
- Cache indicator handles; O(1) incremental updates per tick.
- Lean logging in live mode; richer logging in debug.
- Heartbeat via OnTimer: revalidate trading conditions, broker settings, and margin; detect stale ticks.
- Circuit breaker on repeated trade errors; require cool-off or manual re-enable.

## Testing & Validation
- Strategy Tester: tick-by-tick with variable spread/slippage; stress tests with widened spreads and leverage changes.
- Walk-forward: changing spread/slippage caps and volatility regimes.
- Forward demo on XM360 VPS; collect fill quality, slippage distribution, latency.
- Monte Carlo on trade sequences for drawdown resilience.

## Observability
- Log: signal reason, spread at entry, requested vs filled price, slippage, P/L, RR, circuit-breaker events.
- Periodic summaries to Experts tab/file; optional webhook/alerts for breakers and large losses.
