#property copyright "Codex"
#property link      "https://github.com/Pusparaj99op/High-Frequency-Scalper"
#property version   "1.00"
#property strict

enum StrategyMode { MODE_BREAKOUT=0, MODE_MEAN_REVERSION=1, MODE_AUTO_TOGGLE=2 };
enum TrailMode { TRAIL_NONE=0, TRAIL_ATR=1 };

input string        InpSymbol            = "XAUUSD";
input ENUM_TIMEFRAMES InpTF              = PERIOD_M1;
input StrategyMode  InpMode              = MODE_AUTO_TOGGLE; // BREAKOUT | MEAN_REVERSION | AUTO_TOGGLE
input double        InpFixedLot          = 0.01;
input bool          InpUseDynamicRisk    = true;
input double        InpRiskPerTradePct   = 0.3;   // suggested 0.25–0.5
input int           InpMaxTradesPerDay   = 20;
input int           InpMaxConcurrent     = 2;
input double        InpDailyLossPct      = 3.0;
input double        InpSpreadCapPts      = 30;    // 25–35 suggested
input double        InpSlippageCapPts    = 12;    // 10–15 suggested
input double        InpMarginBufferPct   = 30;    // keep >=30–40% free margin
input int           InpCooldownSec       = 90;
input int           InpTimeStopBars      = 15;
input int           InpATRPeriod         = 14;
input double        InpATRMin            = 50;
input double        InpATRMax            = 400;
input int           InpTPpts             = 150;
input int           InpSLpts             = 120;
input bool          InpUseBE             = true;
input int           InpBETrigger         = 60;
input int           InpBEOffset          = 10;
input TrailMode     InpTrailMode         = TRAIL_ATR;
input double        InpTrailATRMult      = 2.0;
input int           InpMaxRetries        = 2;
input int           InpRetryDelayMs      = 150;
input int           InpTimerSeconds      = 2;
input bool          InpDebugLogging      = false;

//--- handles
int hFastEma = INVALID_HANDLE;
int hSlowEma = INVALID_HANDLE;
int hAtr     = INVALID_HANDLE;

//--- state
datetime gNextAllowed = 0;
double   gLastSlippage[20];
int      gSlipCount = 0;
double   gDailyPnL = 0.0;
int      gTradesToday = 0;
int      gErrorStreak = 0;
datetime gDayStamp = 0;
bool     gBreaker = false;

//--- constants
const string GV_KEY_BASE = "HFS_XAUUSD_DAILY";

struct Signal
{
  bool   valid;
  int    dir;       // ORDER_TYPE_BUY/SELL
  double sl;
  double tp;
  double slPoints;
};

int OnInit()
{
  if(!SymbolSelect(InpSymbol,true))
    return INIT_FAILED;

  hFastEma = iMA(InpSymbol,InpTF,9,0,MODE_EMA,PRICE_CLOSE);
  hSlowEma = iMA(InpSymbol,InpTF,21,0,MODE_EMA,PRICE_CLOSE);
  hAtr     = iATR(InpSymbol,InpTF,InpATRPeriod);
  if(hFastEma==INVALID_HANDLE || hSlowEma==INVALID_HANDLE || hAtr==INVALID_HANDLE)
    return INIT_FAILED;

  gDayStamp = iTime(InpSymbol,PERIOD_D1,0);
  LoadDailyState();

  EventSetTimer(InpTimerSeconds);
  return INIT_SUCCEEDED;
}

void OnDeinit(const int)
{
  EventKillTimer();
  if(hFastEma!=INVALID_HANDLE) IndicatorRelease(hFastEma);
  if(hSlowEma!=INVALID_HANDLE) IndicatorRelease(hSlowEma);
  if(hAtr!=INVALID_HANDLE)     IndicatorRelease(hAtr);
}

void OnTradeTransaction(const MqlTradeTransaction& trans,const MqlTradeRequest& req,const MqlTradeResult& res)
{
  if(trans.type==TRADE_TRANSACTION_DEAL_ADD && trans.deal_entry==DEAL_ENTRY_OUT)
  {
    gDailyPnL += trans.profit;
    SaveDailyState();
  }
}

void OnTimer()
{
  if(NewDay())
    ResetDaily();
  CheckBreaker();
}

void OnTick()
{
  if(gBreaker) return;
  ManagePositions();
  if(TimeCurrent() < gNextAllowed) return;
  if(!MarketGate()) return;

  Signal sig = BuildSignal();
  if(!sig.valid) return;
  if(!CheckPositionLimits()) return;

  double lot = ComputeLot(sig.slPoints);
  if(lot <= 0) return;

  if(PlaceOrder(sig,lot))
  {
    gTradesToday++;
    gErrorStreak = 0;
    gNextAllowed = TimeCurrent() + InpCooldownSec;
  }
  else
  {
    gErrorStreak++;
  }
}

//--- helpers
bool NewDay()
{
  datetime today = iTime(InpSymbol,PERIOD_D1,0);
  return today != gDayStamp;
}

void ResetDaily()
{
  gDayStamp = iTime(InpSymbol,PERIOD_D1,0);
  gDailyPnL = 0;
  gTradesToday = 0;
  gErrorStreak = 0;
  gBreaker = false;
  SaveDailyState();
}

void LoadDailyState()
{
  string keyPnL = GV_KEY_BASE + "_PNL";
  string keyTrades = GV_KEY_BASE + "_TRADES";
  if(GlobalVariableCheck(keyPnL)) gDailyPnL = GlobalVariableGet(keyPnL);
  if(GlobalVariableCheck(keyTrades)) gTradesToday = (int)GlobalVariableGet(keyTrades);
}

void SaveDailyState()
{
  string keyPnL = GV_KEY_BASE + "_PNL";
  string keyTrades = GV_KEY_BASE + "_TRADES";
  GlobalVariableSet(keyPnL,gDailyPnL);
  GlobalVariableSet(keyTrades,gTradesToday);
}

bool MarketGate()
{
  double spreadPts = (SymbolInfoDouble(InpSymbol,SYMBOL_ASK) - SymbolInfoDouble(InpSymbol,SYMBOL_BID)) / _Point;
  if(spreadPts > InpSpreadCapPts) return false;

  double atr[];
  if(CopyBuffer(hAtr,0,0,1,atr)!=1) return false;
  if(atr[0] < InpATRMin*_Point || atr[0] > InpATRMax*_Point) return false;

  double medianSlip = MedianSlippage();
  if(medianSlip > InpSlippageCapPts) return false;
  return true;
}

Signal BuildSignal()
{
  Signal s; s.valid=false;
  double fast[], slow[], atr[];
  if(CopyBuffer(hFastEma,0,0,3,fast)!=3) return s;
  if(CopyBuffer(hSlowEma,0,0,3,slow)!=3) return s;
  if(CopyBuffer(hAtr,0,0,1,atr)!=1) return s;

  double price = SymbolInfoDouble(InpSymbol,SYMBOL_BID);
  double atrPts = atr[0]/_Point;

  StrategyMode mode = SelectMode(atrPts,fast,slow);
  if(mode==MODE_BREAKOUT)
    s = BuildBreakout(price,fast,slow,atrPts);
  else
    s = BuildMeanReversion(price,fast,slow,atrPts);
  return s;
}

StrategyMode SelectMode(double atrPts,const double &fast[],const double &slow[])
{
  if(InpMode!=MODE_AUTO_TOGGLE) return InpMode;
  bool trending = MathAbs(fast[0]-slow[0]) > 0.2*atrPts*_Point;
  if(trending) return MODE_BREAKOUT;
  return MODE_MEAN_REVERSION;
}

Signal BuildBreakout(double price,const double &fast[],const double &slow[],double atrPts)
{
  Signal s; s.valid=false;
  double high = iHigh(InpSymbol,InpTF,1);
  double low  = iLow(InpSymbol,InpTF,1);
  if(price > high && fast[0] > slow[0])
  {
    s.dir = ORDER_TYPE_BUY;
    s.slPoints = InpSLpts;
    s.sl = price - InpSLpts*_Point;
    s.tp = price + InpTPpts*_Point;
    s.valid = true;
  }
  else if(price < low && fast[0] < slow[0])
  {
    s.dir = ORDER_TYPE_SELL;
    s.slPoints = InpSLpts;
    s.sl = price + InpSLpts*_Point;
    s.tp = price - InpTPpts*_Point;
    s.valid = true;
  }
  return s;
}

Signal BuildMeanReversion(double price,const double &fast[],const double &slow[],double atrPts)
{
  Signal s; s.valid=false;
  double band = 0.5*atrPts*_Point;
  double mid = slow[0];
  if(price < mid - band)
  {
    s.dir = ORDER_TYPE_BUY;
    s.slPoints = InpSLpts;
    s.sl = price - InpSLpts*_Point;
    s.tp = price + InpTPpts*_Point;
    s.valid = true;
  }
  else if(price > mid + band)
  {
    s.dir = ORDER_TYPE_SELL;
    s.slPoints = InpSLpts;
    s.sl = price + InpSLpts*_Point;
    s.tp = price - InpTPpts*_Point;
    s.valid = true;
  }
  return s;
}

bool CheckPositionLimits()
{
  int total = PositionsTotal();
  if(total >= InpMaxConcurrent) return false;
  if(gTradesToday >= InpMaxTradesPerDay) return false;
  return true;
}

double ComputeLot(double slPoints)
{
  double lot = InpFixedLot;
  if(InpUseDynamicRisk)
  {
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double tickVal = SymbolInfoDouble(InpSymbol,SYMBOL_TRADE_TICK_VALUE);
    double riskValue = balance * InpRiskPerTradePct / 100.0;
    if(slPoints <= 0 || tickVal <= 0) return 0;
    double perLotRisk = slPoints * _Point / SymbolInfoDouble(InpSymbol,SYMBOL_TRADE_TICK_SIZE) * tickVal;
    lot = MathMax(InpFixedLot, riskValue / perLotRisk);
  }
  double minLot = SymbolInfoDouble(InpSymbol,SYMBOL_VOLUME_MIN);
  double maxLot = SymbolInfoDouble(InpSymbol,SYMBOL_VOLUME_MAX);
  double step   = SymbolInfoDouble(InpSymbol,SYMBOL_VOLUME_STEP);
  lot = MathMin(maxLot, MathMax(minLot, lot));
  lot = NormalizeDouble(MathFloor(lot/step)*step, (int)SymbolInfoInteger(InpSymbol,SYMBOL_VOLUME_DIGITS));

  double marginNeeded = 0;
  if(!OrderCalcMargin(ORDER_TYPE_BUY,InpSymbol,lot,SymbolInfoDouble(InpSymbol,SYMBOL_ASK),marginNeeded))
    return 0;
  double freeMargin = AccountInfoDouble(ACCOUNT_FREEMARGIN);
  double buffer = freeMargin * InpMarginBufferPct / 100.0;
  if(freeMargin - marginNeeded < buffer) return 0;
  return lot;
}

bool PlaceOrder(const Signal &s,double lot)
{
  double price = (s.dir==ORDER_TYPE_BUY) ? SymbolInfoDouble(InpSymbol,SYMBOL_ASK) : SymbolInfoDouble(InpSymbol,SYMBOL_BID);
  MqlTradeRequest req;
  MqlTradeResult  res;
  ZeroMemory(req);
  ZeroMemory(res);
  req.action   = TRADE_ACTION_DEAL;
  req.symbol   = InpSymbol;
  req.volume   = lot;
  req.type     = (ENUM_ORDER_TYPE)s.dir;
  req.price    = price;
  req.sl       = s.sl;
  req.tp       = s.tp;
  req.deviation= (int)MathMax(InpSpreadCapPts, InpSlippageCapPts);
  req.type_filling = ORDER_FILLING_FOK;
  for(int i=0;i<=InpMaxRetries;i++)
  {
    if(!OrderSend(req,res) || res.retcode!=TRADE_RETCODE_DONE)
    {
      if(res.retcode==TRADE_RETCODE_REQUOTE || res.retcode==TRADE_RETCODE_OFF_QUOTES)
      {
        Sleep(InpRetryDelayMs);
        continue;
      }
      if(InpDebugLogging) Print("OrderSend failed: ",res.retcode);
      return false;
    }
    double slipPts = MathAbs(res.price - req.price)/_Point;
    RecordSlippage(slipPts);
    return true;
  }
  return false;
}

void RecordSlippage(double pts)
{
  gLastSlippage[gSlipCount % ArraySize(gLastSlippage)] = pts;
  gSlipCount++;
}

double MedianSlippage()
{
  int n = MathMin(gSlipCount, ArraySize(gLastSlippage));
  if(n==0) return 0;
  double tmp[];
  ArrayResize(tmp,n);
  for(int i=0;i<n;i++) tmp[i]=gLastSlippage[i];
  ArraySort(tmp,WHOLE_ARRAY,0,MODE_ASCEND);
  return tmp[n/2];
}

void CheckBreaker()
{
  double equity = AccountInfoDouble(ACCOUNT_EQUITY);
  double balance = AccountInfoDouble(ACCOUNT_BALANCE);
  double ddPct = (equity - balance) / balance * 100.0;
  if(ddPct <= -InpDailyLossPct) gBreaker = true;
  if(gTradesToday >= InpMaxTradesPerDay) gBreaker = true;
  if(gErrorStreak >= 3) gBreaker = true;
}

//--- position management
double CurrentAtrPoints()
{
  double atr[];
  if(CopyBuffer(hAtr,0,0,1,atr)!=1) return 0;
  return atr[0]/_Point;
}

void ManagePositions()
{
  double atrPts = CurrentAtrPoints();
  for(int i=PositionsTotal()-1;i>=0;i--)
  {
    if(!PositionSelectByIndex(i)) continue;
    string sym = PositionGetString(POSITION_SYMBOL);
    if(sym!=InpSymbol) continue;
    long ticket = PositionGetInteger(POSITION_TICKET);
    int type = (int)PositionGetInteger(POSITION_TYPE);
    double entry = PositionGetDouble(POSITION_PRICE_OPEN);
    double sl    = PositionGetDouble(POSITION_SL);
    double tp    = PositionGetDouble(POSITION_TP);
    datetime opentime = (datetime)PositionGetInteger(POSITION_TIME);
    double price = (type==POSITION_TYPE_BUY) ? SymbolInfoDouble(InpSymbol,SYMBOL_BID) : SymbolInfoDouble(InpSymbol,SYMBOL_ASK);

    // Time stop
    if(InpTimeStopBars>0)
    {
      int bars = (int)((TimeCurrent() - opentime)/PeriodSeconds(InpTF));
      if(bars > InpTimeStopBars)
      {
        ClosePosition(ticket,type);
        continue;
      }
    }

    // Break-even
    if(InpUseBE && InpBETrigger>0)
    {
      double profitPts = (type==POSITION_TYPE_BUY) ? (price - entry)/_Point : (entry - price)/_Point;
      if(profitPts >= InpBETrigger)
      {
        double newSL = (type==POSITION_TYPE_BUY) ? entry + InpBEOffset*_Point : entry - InpBEOffset*_Point;
        bool better = (type==POSITION_TYPE_BUY && (sl==0 || newSL>sl)) || (type==POSITION_TYPE_SELL && (sl==0 || newSL<sl));
        if(better)
        {
          ModifySLTP(ticket,newSL,tp);
          sl = newSL;
        }
      }
    }

    // Trailing
    if(InpTrailMode==TRAIL_ATR && atrPts>0 && InpTrailATRMult>0)
    {
      double trailPts = atrPts * InpTrailATRMult;
      double desiredSL = (type==POSITION_TYPE_BUY) ? price - trailPts*_Point : price + trailPts*_Point;
      bool improve = (type==POSITION_TYPE_BUY && (sl==0 || desiredSL>sl)) || (type==POSITION_TYPE_SELL && (sl==0 || desiredSL<sl));
      if(improve)
      {
        ModifySLTP(ticket,desiredSL,tp);
      }
    }
  }
}

bool ModifySLTP(long ticket,double newSL,double newTP)
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
  if(!OrderSend(req,res))
  {
    if(InpDebugLogging) Print("SLTP modify failed: ",res.retcode);
    return false;
  }
  return res.retcode==TRADE_RETCODE_DONE;
}

bool ClosePosition(long ticket,int type)
{
  MqlTradeRequest req;
  MqlTradeResult  res;
  ZeroMemory(req);
  ZeroMemory(res);
  req.action   = TRADE_ACTION_DEAL;
  req.position = ticket;
  req.symbol   = InpSymbol;
  req.volume   = PositionGetDouble(POSITION_VOLUME);
  req.type     = (type==POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
  req.price    = (req.type==ORDER_TYPE_BUY) ? SymbolInfoDouble(InpSymbol,SYMBOL_ASK) : SymbolInfoDouble(InpSymbol,SYMBOL_BID);
  req.deviation= (int)MathMax(InpSpreadCapPts, InpSlippageCapPts);
  if(!OrderSend(req,res))
  {
    if(InpDebugLogging) Print("Close failed: ",res.retcode);
    return false;
  }
  return res.retcode==TRADE_RETCODE_DONE;
}
