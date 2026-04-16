# High-Frequency Scalper (MT5)

MetaTrader 5 Expert Advisor focused on XAUUSD scalping with breakout / mean-reversion toggle, low-latency execution, and adaptive risk controls.

## Features
- Strategy toggle: breakout, mean-reversion, or auto-toggle based on regime.
- Market gating: spread cap, ATR band, rolling slippage median.
- Risk sizing: fixed 0.01 lot baseline, optional dynamic risk %, margin buffer check, volume step clamping.
- Execution: FOK with bounded retries and deviation cap; cooldown and error streak breaker.
- Trade management: time-stop, break-even shift, ATR trailing stop; daily loss/trade limits and circuit breaker.
- Persistence: daily P/L and trade counts stored via MT5 Global Variables.

## Key Inputs (defaults tuned for XAUUSD XM360)
- `InpSymbol` = XAUUSD, `InpTF` = M1.
- `InpMode` = AUTO toggle (BREAKOUT/MEAN_REVERSION/AUTO).
- `InpFixedLot` = 0.01; `InpUseDynamicRisk` (risk % 0.3 default).
- Limits: `InpMaxTradesPerDay`=20, `InpMaxConcurrent`=2, `InpDailyLossPct`=3.
- Gating: `InpSpreadCapPts`=30, `InpSlippageCapPts`=12, `InpATRMin`/`Max`=50/400 points.
- TP/SL: 150/120 pts; BE trigger/offset 60/10; ATR trailing x2; time-stop 15 bars.
- Retries: max 2, delay 150ms; timer 2s; cooldown 90s.

## How It Works
1) `OnTimer`: resets daily state, checks circuit breaker.
2) `OnTick`: manages open positions (time-stop, BE, trailing) then gates on spread/ATR/slippage; builds signal; enforces trade limits; sizes lot; sends order with retries; records slippage and cooldown.
3) `OnTradeTransaction`: records realized P/L into daily totals.

## Usage
1) Copy `HighFrequencyScalper.mq5` into your MT5 `MQL5/Experts` folder and compile.
2) Attach to XAUUSD on M1 (or M5) chart on your low-latency VPS.
3) Adjust inputs for your broker conditions (spread/slippage caps, risk %, TP/SL).
4) Run Strategy Tester tick-by-tick with variable spread/slippage; forward-test on demo before live.

## Notes
- Broker must support FOK; EA falls back only by retries, not IOC in this skeleton.
- Parameters are exposed as inputs; tune caps and risk for your account leverage and latency.
- Extend signals and management logic in `HighFrequencyScalper.mq5` for production use.
