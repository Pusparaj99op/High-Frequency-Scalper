#property copyright "Codex"
#property link      "https://github.com/Pusparaj99op/High-Frequency-Scalper"
#property version   "1.11"
#property strict

enum StrategyMode { MODE_BREAKOUT=0, MODE_MEAN_REVERSION=1, MODE_AUTO_TOGGLE=2 };
enum TrailMode    { TRAIL_NONE=0, TRAIL_ATR=1 };

//=============================================================================
// INPUTS
//=============================================================================
input string        InpSymbol            = "XAUUSD";
input ENUM_TIMEFRAMES InpTF              = PERIOD_M1;
input StrategyMode  InpMode              = MODE_AUTO_TOGGLE;

// --- Risk ---
input double        InpFixedLot          = 0.01;
input bool          InpUseDynamicRisk    = false;   // OFF by default for backtest safety
input double        InpRiskPerTradePct   = 1.0;     // % of balance per trade
input int           InpMaxTradesPerDay   = 50;
input int           InpMaxConcurrent     = 3;
input double        InpDailyLossPct      = 20.0;    // % daily loss to halt

// --- Gating (relaxed for backtesting) ---
input double        InpSpreadCapPts      = 80;      // raise to allow wider backtest spread
input double        InpSlippageCapPts    = 30;
input double        InpMarginBufferPct   = 10;      // min % free margin to keep

// --- Indicators ---
input int           InpATRPeriod         = 14;
input double        InpATRMin            = 3.0;     // ATR min in POINTS (not _Point units)
input double        InpATRMax            = 1500.0;  // ATR max in POINTS

// --- TP/SL ---
input int           InpTPpts             = 200;     // in raw points
input int           InpSLpts             = 100;
input double        InpRR                = 2.0;     // TP = SL * InpRR if using RR

// --- Trade management ---
input int           InpTimeStopBars      = 30;
input bool          InpUseBE             = true;
input int           InpBETrigger         = 50;      // points profit to trigger BE
input int           InpBEOffset          = 5;
input TrailMode     InpTrailMode         = TRAIL_ATR;
input double        InpTrailATRMult      = 1.5;

// --- Execution ---
input int           InpMaxRetries        = 1;
input int           InpTimerSeconds      = 5;
input bool          InpDebugLogging      = true;    // ON for backtest debugging

//=============================================================================
// GLOBALS
//=============================================================================
int      hFastEma = INVALID_HANDLE;
int      hSlowEma = INVALID_HANDLE;
int      hAtr     = INVALID_HANDLE;

datetime gLastTradeBarTime = 0;
double   gLastSlippage[20];
int      gSlipCount        = 0;
double   gDailyPnL         = 0.0;
int      gTradesToday      = 0;
int      gErrorStreak      = 0;
datetime gDayStamp         = 0;
bool     gBreaker          = false;
bool     gIsTesting        = false;   // true when Strategy Tester is active

//=============================================================================
// INIT / DEINIT
//=============================================================================
int OnInit()
{
   gIsTesting = MQLInfoInteger(MQL_TESTER);

   if(!SymbolSelect(InpSymbol, true))
   {
      Print("ERROR: Cannot select symbol ", InpSymbol);
      return INIT_FAILED;
   }

   hFastEma = iMA(InpSymbol, InpTF, 9,  0, MODE_EMA, PRICE_CLOSE);
   hSlowEma = iMA(InpSymbol, InpTF, 21, 0, MODE_EMA, PRICE_CLOSE);
   hAtr     = iATR(InpSymbol, InpTF, InpATRPeriod);

   if(hFastEma == INVALID_HANDLE || hSlowEma == INVALID_HANDLE || hAtr == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create indicator handles");
      return INIT_FAILED;
   }

   gDayStamp = iTime(InpSymbol, PERIOD_D1, 0);
   gDailyPnL = 0;
   gTradesToday = 0;
   gErrorStreak = 0;
   gBreaker = false;

   if(!gIsTesting)
   {
      LoadDailyState();
      EventSetTimer(InpTimerSeconds);
   }

   Print("HighFrequencyScalper v1.10 initialized | Testing=", gIsTesting);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   if(hFastEma != INVALID_HANDLE) IndicatorRelease(hFastEma);
   if(hSlowEma != INVALID_HANDLE) IndicatorRelease(hSlowEma);
   if(hAtr     != INVALID_HANDLE) IndicatorRelease(hAtr);
}

//=============================================================================
// EVENTS
//=============================================================================
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& req,
                        const MqlTradeResult& res)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      if(HistoryDealSelect(trans.deal))
      {
         if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY) == DEAL_ENTRY_OUT)
         {
            gDailyPnL += HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
            if(!gIsTesting) SaveDailyState();
         }
      }
   }
}

void OnTimer()
{
   if(NewDay()) ResetDaily();
   CheckBreaker();
}

void OnTick()
{
   // Day rollover check (needed in backtesting since OnTimer is unreliable)
   if(NewDay()) ResetDaily();
   CheckBreaker();

   if(gBreaker) return;

   // Manage open positions every tick
   ManagePositions();

   // Only evaluate new signals on new candle
   datetime currentBarTime = iTime(InpSymbol, InpTF, 0);
   if(currentBarTime == 0) return;
   if(currentBarTime == gLastTradeBarTime) return;

   // Market gate checks
   if(!MarketGate()) return;

   // Check limits before computing signal (saves CPU)
   if(!CheckPositionLimits()) return;

   // Build entry signal
   Signal sig = BuildSignal();
   if(!sig.valid) return;

   // Compute lot size
   double lot = ComputeLot(sig.slPoints);
   if(lot <= 0)
   {
      if(InpDebugLogging) Print("ComputeLot returned 0 — skipping");
      return;
   }

   // Place order
   if(PlaceOrder(sig, lot))
   {
      gTradesToday++;
      gErrorStreak = 0;
      gLastTradeBarTime = currentBarTime;
      if(InpDebugLogging)
         Print("Trade placed | Dir=", (sig.dir == ORDER_TYPE_BUY ? "BUY" : "SELL"),
               " Lot=", lot, " SL=", sig.sl, " TP=", sig.tp);
   }
   else
   {
      gErrorStreak++;
      if(InpDebugLogging) Print("Trade FAILED | ErrorStreak=", gErrorStreak);
   }
}

//=============================================================================
// DAY MANAGEMENT
//=============================================================================
bool NewDay()
{
   datetime today = iTime(InpSymbol, PERIOD_D1, 0);
   return (today != 0 && today != gDayStamp);
}

void ResetDaily()
{
   gDayStamp    = iTime(InpSymbol, PERIOD_D1, 0);
   gDailyPnL    = 0;
   gTradesToday = 0;
   gErrorStreak = 0;
   gBreaker     = false;
   if(!gIsTesting) SaveDailyState();
}

void LoadDailyState()
{
   string keyPnL    = "HFS_PNL_" + InpSymbol;
   string keyTrades = "HFS_TRD_" + InpSymbol;
   if(GlobalVariableCheck(keyPnL))    gDailyPnL    = GlobalVariableGet(keyPnL);
   if(GlobalVariableCheck(keyTrades)) gTradesToday = (int)GlobalVariableGet(keyTrades);
}

void SaveDailyState()
{
   GlobalVariableSet("HFS_PNL_" + InpSymbol, gDailyPnL);
   GlobalVariableSet("HFS_TRD_" + InpSymbol, gTradesToday);
}

//=============================================================================
// CIRCUIT BREAKER
//=============================================================================
void CheckBreaker()
{
   if(gBreaker) return;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0) return;

   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPct   = (balance - equity) / balance * 100.0;
   if(ddPct >= InpDailyLossPct)
   {
      gBreaker = true;
      Print("CIRCUIT BREAKER: Daily loss limit hit (", DoubleToString(ddPct, 2), "%)");
      return;
   }

   if(gTradesToday >= InpMaxTradesPerDay)
   {
      gBreaker = true;
      Print("CIRCUIT BREAKER: Max trades/day reached (", gTradesToday, ")");
      return;
   }

   if(gErrorStreak >= 5)
   {
      gBreaker = true;
      Print("CIRCUIT BREAKER: Error streak (", gErrorStreak, ")");
   }
}

//=============================================================================
// MARKET GATE
//=============================================================================
bool MarketGate()
{
   // --- ATR check (do this first as it's indicator-based, not price-feed based) ---
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(hAtr, 0, 1, 2, atr) < 2)
   {
      if(InpDebugLogging) Print("MarketGate: ATR buffer not ready");
      return false;
   }
   double atrPts = atr[0] / _Point;
   if(atrPts < InpATRMin)
   {
      if(InpDebugLogging)
         Print("MarketGate: ATR too low (", DoubleToString(atrPts, 1), " < ", InpATRMin, ")");
      return false;
   }
   if(atrPts > InpATRMax)
   {
      if(InpDebugLogging)
         Print("MarketGate: ATR too high (", DoubleToString(atrPts, 1), " > ", InpATRMax, ")");
      return false;
   }

   // --- Spread check ---
   double ask = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
   if(ask > 0 && bid > 0 && ask > bid)
   {
      double spreadPts = (ask - bid) / _Point;
      if(spreadPts > InpSpreadCapPts)
      {
         if(InpDebugLogging)
            Print("MarketGate: Spread too wide (", DoubleToString(spreadPts, 1), ")");
         return false;
      }
   }
   // If ask/bid are 0 (common in backtesting with open price only), skip spread check

   return true;
}

//=============================================================================
// SIGNAL LOGIC
//=============================================================================
struct Signal
{
   bool   valid;
   int    dir;
   double sl;
   double tp;
   double slPoints;
};

Signal BuildSignal()
{
   Signal s;
   s.valid = false;

   double fast[], slow[], atr[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);
   ArraySetAsSeries(atr,  true);

   if(CopyBuffer(hFastEma, 0, 0, 3, fast) < 3) { if(InpDebugLogging) Print("Signal: fast EMA not ready"); return s; }
   if(CopyBuffer(hSlowEma, 0, 0, 3, slow) < 3) { if(InpDebugLogging) Print("Signal: slow EMA not ready"); return s; }
   if(CopyBuffer(hAtr,     0, 1, 2, atr)  < 2) { if(InpDebugLogging) Print("Signal: ATR not ready");      return s; }

   double atrPts = atr[0] / _Point;
   StrategyMode mode = SelectMode(atrPts, fast, slow);

   if(mode == MODE_BREAKOUT)
      s = BuildBreakout(fast, slow, atrPts);
   else
      s = BuildMeanReversion(fast, slow, atrPts);

   return s;
}

StrategyMode SelectMode(double atrPts, const double& fast[], const double& slow[])
{
   if(InpMode != MODE_AUTO_TOGGLE) return InpMode;
   // Use EMA separation relative to ATR to decide trending vs ranging
   double separation = MathAbs(fast[0] - slow[0]) / _Point;
   if(separation > 0.15 * atrPts)
      return MODE_BREAKOUT;
   return MODE_MEAN_REVERSION;
}

Signal BuildBreakout(const double& fast[], const double& slow[], double atrPts)
{
   Signal s;
   s.valid = false;

   // Crossover on completed bars (index 1 vs 2)
   bool buyCross  = (fast[1] > slow[1] && fast[2] <= slow[2]);
   bool sellCross = (fast[1] < slow[1] && fast[2] >= slow[2]);

   // Also allow momentum continuation (fast above slow by meaningful margin)
   bool buyTrend  = (fast[0] > slow[0] && fast[1] > slow[1] && (fast[0] - slow[0]) / _Point > 0.1 * atrPts);
   bool sellTrend = (fast[0] < slow[0] && fast[1] < slow[1] && (slow[0] - fast[0]) / _Point > 0.1 * atrPts);

   double price = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
   if(price <= 0) price = iClose(InpSymbol, InpTF, 0);

   double slPts = MathMax((double)InpSLpts, atrPts * 0.8);
   double tpPts = slPts * InpRR;

   if(buyCross || buyTrend)
   {
      s.dir      = ORDER_TYPE_BUY;
      s.slPoints = slPts;
      s.sl       = price - slPts * _Point;
      s.tp       = price + tpPts * _Point;
      s.valid    = true;
   }
   else if(sellCross || sellTrend)
   {
      s.dir      = ORDER_TYPE_SELL;
      s.slPoints = slPts;
      s.sl       = price + slPts * _Point;
      s.tp       = price - tpPts * _Point;
      s.valid    = true;
   }
   return s;
}

Signal BuildMeanReversion(const double& fast[], const double& slow[], double atrPts)
{
   Signal s;
   s.valid = false;

   double price = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
   if(price <= 0) price = iClose(InpSymbol, InpTF, 0);

   double mid  = slow[0];
   double band = 0.4 * atrPts * _Point;

   double slPts = MathMax((double)InpSLpts, atrPts * 0.8);
   double tpPts = slPts * InpRR;

   // Price stretched below mid and fast EMA starting to turn back up (just crossed or about to)
   bool buySetup  = (price < mid - band && fast[0] >= slow[0] - 0.05 * atrPts * _Point);
   // Price stretched above mid and fast EMA starting to turn back down
   bool sellSetup = (price > mid + band && fast[0] <= slow[0] + 0.05 * atrPts * _Point);

   if(buySetup)
   {
      s.dir      = ORDER_TYPE_BUY;
      s.slPoints = slPts;
      s.sl       = price - slPts * _Point;
      s.tp       = mid + band * 0.5; // target back toward mean
      s.valid    = true;
   }
   else if(sellSetup)
   {
      s.dir      = ORDER_TYPE_SELL;
      s.slPoints = slPts;
      s.sl       = price + slPts * _Point;
      s.tp       = mid - band * 0.5;
      s.valid    = true;
   }
   return s;
}

//=============================================================================
// POSITION LIMITS
//=============================================================================
bool CheckPositionLimits()
{
   if(gTradesToday >= InpMaxTradesPerDay)
   {
      if(InpDebugLogging) Print("Limit: max trades/day reached");
      return false;
   }

   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetSymbol(i) == InpSymbol)
         count++;
   }
   if(count >= InpMaxConcurrent)
   {
      if(InpDebugLogging) Print("Limit: max concurrent (", count, "/", InpMaxConcurrent, ")");
      return false;
   }
   return true;
}

//=============================================================================
// LOT SIZING
//=============================================================================
double ComputeLot(double slPoints)
{
   double lot = InpFixedLot;

   if(InpUseDynamicRisk && slPoints > 0)
   {
      double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
      double tickVal  = SymbolInfoDouble(InpSymbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize = SymbolInfoDouble(InpSymbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickVal <= 0 || tickSize <= 0) return InpFixedLot;

      double riskVal     = balance * InpRiskPerTradePct / 100.0;
      double perLotLoss  = slPoints * _Point / tickSize * tickVal;
      if(perLotLoss <= 0) return InpFixedLot;
      lot = riskVal / perLotLoss;
   }

   double minLot = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_STEP);
   if(step <= 0) step = 0.01;

   lot = MathMin(maxLot, MathMax(minLot, lot));
   lot = MathFloor(lot / step) * step;
   lot = NormalizeDouble(lot, 2);

   // Margin check
   double marginNeeded = 0;
   double entryPrice   = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
   if(entryPrice <= 0) entryPrice = iClose(InpSymbol, InpTF, 0);

   if(OrderCalcMargin(ORDER_TYPE_BUY, InpSymbol, lot, entryPrice, marginNeeded))
   {
      double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      double buffer     = freeMargin * InpMarginBufferPct / 100.0;
      if(freeMargin - marginNeeded < buffer)
      {
         if(InpDebugLogging)
            Print("ComputeLot: insufficient margin (free=", freeMargin, " needed=", marginNeeded, ")");
         return 0;
      }
   }

   return lot;
}

//=============================================================================
// ORDER PLACEMENT
//=============================================================================
ENUM_ORDER_TYPE_FILLING GetFilling()
{
   int fillMode = (int)SymbolInfoInteger(InpSymbol, SYMBOL_FILLING_MODE);
   if((fillMode & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
   if((fillMode & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

bool PlaceOrder(const Signal& s, double lot)
{
   double price;
   if(s.dir == ORDER_TYPE_BUY)
      price = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
   else
      price = SymbolInfoDouble(InpSymbol, SYMBOL_BID);

   // Fallback for backtesting when ASK/BID may be 0
   if(price <= 0) price = iClose(InpSymbol, InpTF, 0);

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = InpSymbol;
   req.volume       = lot;
   req.type         = (ENUM_ORDER_TYPE)s.dir;
   req.price        = price;
   req.sl           = NormalizeDouble(s.sl, (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS));
   req.tp           = NormalizeDouble(s.tp, (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS));
   req.deviation    = (int)InpSpreadCapPts + 20;  // generous deviation for backtesting
   req.type_filling = GetFilling();
   req.magic        = 20260420;
   req.comment      = "HFS_v1.10";

   for(int attempt = 0; attempt <= InpMaxRetries; attempt++)
   {
      bool sent = OrderSend(req, res);

      if(sent && res.retcode == TRADE_RETCODE_DONE)
      {
         // Record slippage (skip Sleep in backtester)
         double slipPts = MathAbs(res.price - req.price) / _Point;
         RecordSlippage(slipPts);
         return true;
      }

      if(InpDebugLogging)
         Print("OrderSend attempt ", attempt + 1, " failed: retcode=", res.retcode,
               " price=", price, " sl=", req.sl, " tp=", req.tp, " lot=", lot);

      // Only retry on re-quote/price-off; no Sleep in backtesting
      if(res.retcode != TRADE_RETCODE_REQUOTE && res.retcode != TRADE_RETCODE_PRICE_OFF)
         break;

      if(!gIsTesting)
         Sleep(150);  // only wait in live/demo mode
   }
   return false;
}

//=============================================================================
// SLIPPAGE TRACKING
//=============================================================================
void RecordSlippage(double pts)
{
   gLastSlippage[gSlipCount % ArraySize(gLastSlippage)] = pts;
   gSlipCount++;
}

//=============================================================================
// POSITION MANAGEMENT
//=============================================================================
double CurrentAtrPoints()
{
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(hAtr, 0, 0, 1, atr) < 1) return 0;
   return atr[0] / _Point;
}

void ManagePositions()
{
   double atrPts = CurrentAtrPoints();
   int    digits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != InpSymbol) continue;

      ulong  ticket    = PositionGetInteger(POSITION_TICKET);
      int    type      = (int)PositionGetInteger(POSITION_TYPE);
      double entry     = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl        = PositionGetDouble(POSITION_SL);
      double tp        = PositionGetDouble(POSITION_TP);
      datetime openTime= (datetime)PositionGetInteger(POSITION_TIME);

      double price     = (type == POSITION_TYPE_BUY)
                         ? SymbolInfoDouble(InpSymbol, SYMBOL_BID)
                         : SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
      if(price <= 0) price = iClose(InpSymbol, InpTF, 0);

      // --- Time Stop ---
      if(InpTimeStopBars > 0)
      {
         int barsOpen = (int)((TimeCurrent() - openTime) / PeriodSeconds(InpTF));
         if(barsOpen >= InpTimeStopBars)
         {
            if(InpDebugLogging) Print("TimeStop: closing ticket ", ticket, " bars=", barsOpen);
            ClosePosition(ticket, type);
            continue;
         }
      }

      // --- Break-Even ---
      if(InpUseBE && InpBETrigger > 0)
      {
         double profitPts = (type == POSITION_TYPE_BUY)
                            ? (price - entry) / _Point
                            : (entry - price) / _Point;
         if(profitPts >= InpBETrigger)
         {
            double newSL = (type == POSITION_TYPE_BUY)
                           ? entry + InpBEOffset * _Point
                           : entry - InpBEOffset * _Point;
            newSL = NormalizeDouble(newSL, digits);
            bool betterBE = (type == POSITION_TYPE_BUY  && (sl == 0 || newSL > sl))
                         || (type == POSITION_TYPE_SELL && (sl == 0 || newSL < sl));
            if(betterBE)
            {
               ModifySLTP(ticket, newSL, tp);
               sl = newSL;
            }
         }
      }

      // --- ATR Trailing Stop ---
      if(InpTrailMode == TRAIL_ATR && atrPts > 0 && InpTrailATRMult > 0)
      {
         double trailDistance = atrPts * InpTrailATRMult * _Point;
         double desiredSL = (type == POSITION_TYPE_BUY)
                            ? price - trailDistance
                            : price + trailDistance;
         desiredSL = NormalizeDouble(desiredSL, digits);
         bool improve = (type == POSITION_TYPE_BUY  && (sl == 0 || desiredSL > sl))
                     || (type == POSITION_TYPE_SELL && (sl == 0 || desiredSL < sl));
         if(improve)
            ModifySLTP(ticket, desiredSL, tp);
      }
   }
}

//=============================================================================
// ORDER HELPERS
//=============================================================================
bool ModifySLTP(ulong ticket, double newSL, double newTP)
{
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);
   req.action   = TRADE_ACTION_SLTP;
   req.position = ticket;
   req.symbol   = InpSymbol;
   req.sl       = newSL;
   req.tp       = newTP;
   if(!OrderSend(req, res))
   {
      if(InpDebugLogging) Print("ModifySLTP failed: ", res.retcode);
      return false;
   }
   return (res.retcode == TRADE_RETCODE_DONE);
}

bool ClosePosition(ulong ticket, int type)
{
   // Re-select by ticket to ensure we have the right position
   if(!PositionSelectByTicket(ticket)) return false;

   double vol = PositionGetDouble(POSITION_VOLUME);
   ENUM_ORDER_TYPE closeType = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   double closePrice = (closeType == ORDER_TYPE_BUY)
                       ? SymbolInfoDouble(InpSymbol, SYMBOL_ASK)
                       : SymbolInfoDouble(InpSymbol, SYMBOL_BID);
   if(closePrice <= 0) closePrice = iClose(InpSymbol, InpTF, 0);

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);
   req.action       = TRADE_ACTION_DEAL;
   req.position     = ticket;
   req.symbol       = InpSymbol;
   req.volume       = vol;
   req.type         = closeType;
   req.price        = closePrice;
   req.deviation    = (int)InpSpreadCapPts + 20;
   req.type_filling = GetFilling();

   if(!OrderSend(req, res))
   {
      if(InpDebugLogging) Print("ClosePosition failed: ", res.retcode);
      return false;
   }
   return (res.retcode == TRADE_RETCODE_DONE);
}
