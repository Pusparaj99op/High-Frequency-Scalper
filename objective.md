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

## Implementation Blueprint (MT5)
### Core Structure
- Files: single EA `.mq5` with `OnInit`, `OnDeinit`, `OnTick`, `OnTimer`, helper functions; optional include for utils.
- Global state: configuration inputs, indicator handles (fast EMA, slow EMA, VWAP/MA band, ATR), rolling slippage stats, per-symbol cooldowns, daily P/L and breaker flags (Global Variables).
- Timers: 1–5s `OnTimer` for health checks, gate recalculation, and circuit-breaker logic; `OnTick` is lean for signal + execution.

### Inputs (examples, defaults tuned for XAUUSD XM360)
- `input string InpSymbol="XAUUSD";`
- `input ENUM_TIMEFRAMES InpTF=PERIOD_M1;`
- `input ENUM_STRATEGY_MODE InpMode=MODE_AUTO_TOGGLE; // BREAKOUT | MEAN_REVERSION | AUTO_TOGGLE`
- `input double InpFixedLot=0.01;`
- `input bool InpUseDynamicRisk=true;`
- `input double InpRiskPerTradePct=0.3; // 0.25–0.5% suggested`
- `input int InpMaxTradesPerDay=20;`
- `input int InpMaxConcurrent=2;`
- `input double InpDailyLossPct=3.0;`
- `input double InpSpreadCapPts=30; // 25–35`
- `input double InpSlippageCapPts=12; // 10–15`
- `input double InpMarginBufferPct=30; // keep >=30–40% free margin after entry`
- `input int InpCooldownSec=90;`
- `input int InpTimeStopBars=15;`
- `input int InpATRPeriod=14;`
- `input double InpATRMin=50; input double InpATRMax=400;`
- `input int InpTPpts=150; input int InpSLpts=120;`
- `input bool InpUseBE=true; input int InpBETrigger=60; input int InpBEOffset=10;`
- `input bool InpUseTrail=true; input int InpTrailATRMult=2;`
- `input int InpMaxRetries=2; input int InpRetryDelayMs=150;`
- `input int InpTimerSeconds=2;`
- Logging toggles and webhook URL (optional).

### State and Helpers
- `struct TradeStats { double dailyPnL; int tradesToday; datetime dayStamp; int errorStreak; double slippageMedian; }`
- `struct Cooldown { datetime nextAllowed; }`
- Functions: `LoadHandles()`, `UpdateIndicators()`, `CheckMarketGate()`, `SelectMode()`, `HasOpenPositions()`, `ComputeLot()`, `BuildSignalBreakout()`, `BuildSignalMeanRev()`, `PlaceOrder()`, `ManageOpenPositions()`, `UpdateStatsOnTrade()`, `CircuitBreakerTriggered()`.
- Rolling median slippage: keep deque of last N (e.g., 20) fills (requested - filled in points); compute median/95th quickly (simple sort small N).
- Persist breaker/daily PnL via `GlobalVariableSet`, keyed by symbol+day.

### OnInit
- Validate symbol availability; subscribe to ticks.
- Create indicators: fast/slow EMA, ATR; prepare buffers.
- Set timer to `InpTimerSeconds`.
- Load persisted daily P/L and breaker state; reset if day changed.

### OnTimer (health + gates)
- Recalculate spread/slippage gates and ATR band.
- Refresh margin rates, leverage, lot step/min/max.
- Reset daily counters if day rolled.
- Evaluate circuit-breaker (daily loss, error streak, max trades/day).
- Pre-compute lot ceiling given margin buffer.

### OnTick (signal + execution)
1) If circuit-breaker active or cooldown in effect → return.
2) Compute/refresh indicator values minimally (pull latest handles).
3) Run `CheckMarketGate`: spread <= cap, slippage median <= cap, ATR within [min, max], not in blackout (rollover/news).
4) Determine active mode: `InpMode` or auto-toggle (e.g., ATR regime or recent mode win rate).
5) Build signal:
   - Breakout: recent high/low break (lookback L), momentum via fast EMA slope or RSI delta, price > fast EMA for longs, spread healthy.
   - Mean-reversion: z-score of price vs EMA/VWAP band; enter back to mean when z-score exceeds threshold and momentum fading.
6) If signal passes and no conflicting open position count > limits:
   - Compute lot: fixed 0.01; if dynamic risk enabled, lot = risk% * balance / (SL pts * tickValue/point), then clamp to min/max and margin buffer.
   - Send order with deviation tied to `max(InpSpreadCapPts, spread*1.2)` but bounded; filling FOK, fallback IOC if unsupported.
   - Retry on requote/off-quotes up to `InpMaxRetries` with `InpRetryDelayMs`.
   - On success, set SL/TP server-side immediately; record entry time for time-stop; store requested vs filled for slippage stats; set cooldown.

### Trade Management (per tick/per timer)
- Break-even: when profit >= `InpBETrigger`, move SL to entry + `InpBEOffset`.
- Trailing: ATR-based trail behind price; only tighten.
- Time-stop: close if bars since entry > `InpTimeStopBars`.
- Partial take-profit (optional): close fraction at RR milestone; tighten SL.
- Close on circuit-breaker trigger.

### Risk Controls
- Daily loss breaker: if daily P/L <= -`InpDailyLossPct`% balance → halt new trades.
- Max trades/day and max concurrent enforced before entry.
- Error-streak breaker: consecutive trade errors > threshold → pause until timer resets.
- Cooldown per symbol after close or failed attempt.

### Adaptivity
- Adjust allowed deviation using recent slippage percentile; widen only within cap.
- Increase minimum TP if spread widens (ensure TP covers spread + expected slippage).
- Auto-toggle: choose breakout when ATR high and spreads tight; mean-reversion when ATR mid and no trend; disable entries when ATR too low/high.

### Logging/Telemetry
- Per trade: signal type, spread, ATR, requested/fill, slippage pts, lot, SL/TP, outcome.
- Periodic summary (timer): equity, daily P/L, slippage median/95th, spread avg/max, gate status, breaker status.
- Optional webhook on breaker events and large losses.

### Testing Checklist
- Strategy Tester: tick-by-tick with spread 20–60 pts, slippage 0–20 pts; confirm gates block bad conditions.
- Stress: widened spread, high ATR; ensure breaker halts; ensure retries bounded.
- Forward demo: compare requested vs fill, slippage distribution; verify cooldown and time-stop behavior.

### Minimal Pseudocode Sketch (structure)
```
int OnInit() { LoadHandles(); SetTimer(InpTimerSeconds); LoadState(); return INIT_SUCCEEDED; }
void OnDeinit(const int) { KillTimer(); ReleaseHandles(); }
void OnTimer() { RefreshSymbolInfo(); UpdateGates(); ResetIfNewDay(); if (Breaker()) disable=true; }
void OnTick() {
  if (disable || CooldownActive()) return;
  if (!CheckMarketGate()) return;
  Mode m = SelectMode();
  Signal s = (m==BREAKOUT) ? BuildBreakout() : BuildMeanRev();
  if (!s.valid) return;
  if (PositionLimitHit()) return;
  double lot = ComputeLot(s.slPoints);
  if (!PlaceOrder(s.dir, lot, s.sl, s.tp)) { RecordError(); return; }
  RecordFill(); SetCooldown(); }
```

## EA Skeleton Implemented
- Added `HighFrequencyScalper.mq5` with:
  - Inputs per plan (symbol, mode toggle, risk, gating, TP/SL, BE, trailing, retries, timers).
  - OnInit/OnDeinit/OnTimer/OnTick scaffolding.
  - Market gate (spread, ATR band, slippage median).
  - Strategy modes: breakout vs mean-reversion selection with auto toggle.
  - Lot sizing with optional dynamic risk, margin buffer, volume step clamping.
  - Order placement with FOK, bounded retries, slippage recording, cooldown.
  - Daily state persistence via Global Variables, circuit breaker (daily loss, trades/day, error streak).
  - Simple signal logic placeholders; extend with richer entry logic and management (BE/trail/time-stop hooks to add).
