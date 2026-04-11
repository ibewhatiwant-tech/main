#property strict
#property version   "1.00"
#property description "XAUUSD M5 Controlled Recovery EA"

#include <Trade/Trade.mqh>

//==================================================================
// SECTION: PROPERTIES / ENUMS / CORE TYPES
//==================================================================

enum ENUM_MARKET_STATE
{
   MARKET_RANGE = 0,
   MARKET_TREND,
   MARKET_BREAKOUT_EXPANSION,
   MARKET_UNSAFE
};

enum ENUM_BIAS_STATE
{
   BIAS_NEUTRAL = 0,
   BIAS_BULLISH,
   BIAS_BEARISH
};

enum ENUM_SETUP_DIRECTION
{
   DIR_NONE = 0,
   DIR_LONG,
   DIR_SHORT
};

enum ENUM_CYCLE_STATE
{
   CYCLE_IDLE = 0,
   CYCLE_SETUP_DETECTED,
   CYCLE_ENTRY_PLACED,
   CYCLE_ACTIVE,
   CYCLE_RECOVERY_ELIGIBLE,
   CYCLE_RECOVERY_PLACED,
   CYCLE_EXIT_PENDING,
   CYCLE_COOLDOWN,
   CYCLE_DAILY_LOCK
};

enum ENUM_ZONE_TYPE
{
   ZONE_NONE = 0,
   ZONE_PREV_DAY_HIGH,
   ZONE_PREV_DAY_LOW,
   ZONE_SESSION_HIGH,
   ZONE_SESSION_LOW,
   ZONE_ASIA_HIGH,
   ZONE_ASIA_LOW,
   ZONE_M15_SWING_HIGH,
   ZONE_M15_SWING_LOW,
   ZONE_H1_SWING_HIGH,
   ZONE_H1_SWING_LOW,
   ZONE_FVG_BULL,
   ZONE_FVG_BEAR,
   ZONE_OB_BULL,
   ZONE_OB_BEAR
};

enum ENUM_CONFIRMATION_TYPE
{
   CONFIRM_NONE = 0,
   CONFIRM_REJECTION,
   CONFIRM_ENGULFING,
   CONFIRM_CHOCH,
   CONFIRM_MOMENTUM_SHIFT
};

enum ENUM_EXIT_REASON
{
   EXIT_NONE = 0,
   EXIT_BASKET_TP,
   EXIT_STRUCTURE_INVALIDATION,
   EXIT_TIME_STOP,
   EXIT_CYCLE_RISK_STOP,
   EXIT_DAILY_LOCK,
   EXIT_MARGIN_PROTECTION,
   EXIT_NEWS_FLAT
};

enum ENUM_RECOVERY_SCOPE_MODE
{
   REC_SCOPE_OWN_MAGIC_SYMBOL = 0,
   REC_SCOPE_ANY_MAGIC_SYMBOL,
   REC_SCOPE_WHOLE_ACCOUNT
};

enum ENUM_INITIAL_LOT_MODE
{
   INITIAL_LOT_RISK_PERCENT = 0,
   INITIAL_LOT_FIXED,
   INITIAL_LOT_FIXED_STEP_EQUITY
};

struct BarData
{
   datetime time;
   double open;
   double high;
   double low;
   double close;
   long tick_volume;
   int spread;
};

struct SwingPoint
{
   int index;
   datetime time;
   double price;
   bool isHigh;
   bool valid;
};

struct ZoneInfo
{
   ENUM_ZONE_TYPE type;
   double upper;
   double lower;
   datetime created;
   bool bullish;
   bool bearish;
   bool active;
   string label;
};

struct SignalInfo
{
   bool valid;
   ENUM_SETUP_DIRECTION direction;
   ENUM_CONFIRMATION_TYPE confirmation;
   ENUM_ZONE_TYPE sourceZoneType;
   double entryPrice;
   double stopPrice;
   double referencePrice;
   datetime signalTime;
   string reason;
};

struct EntryPlan
{
   bool valid;
   ENUM_SETUP_DIRECTION direction;
   double lotSize;
   double entryPrice;
   double stopLoss;
   double takeProfit;
   double riskMoney;
   int entryNumber;
   string comment;
};

struct CycleStats
{
   bool active;
   ENUM_SETUP_DIRECTION direction;
   ENUM_CYCLE_STATE state;
   int cycleId;
   int entriesUsed;
   datetime startTime;
   datetime endTime;
   double avgEntryPrice;
   double totalLots;
   double floatingPnL;
   double closedPnL;
   double maxFloatingDD;
   double protectedInvalidationPrice;
   bool partialTaken;
   double partialRLevel;
   datetime lastTrailUpdateBar;
   ENUM_EXIT_REASON lastExitReason;
};

struct DailyStats
{
   datetime tradeDay;
   int cyclesTaken;
   int failedCycles;
   double closedPnL;
   double floatingPnL;
   double equityAtDayStart;
   bool dailyLockActive;
};

struct MarketSnapshot
{
   ENUM_MARKET_STATE marketState;
   ENUM_BIAS_STATE biasM15;
   ENUM_BIAS_STATE biasH1;
   ENUM_BIAS_STATE finalBias;
   double atrM5;
   double avgBodyM5;
   double currentSpreadPoints;
   bool sessionAllowed;
   bool newsLocked;
   bool spreadOk;
   bool marginOk;
};

//==================================================================
// SECTION: INPUT PARAMETERS
//==================================================================

input group "Trading Identity"
input string InpSymbol = "XAUUSD";
input long   InpMagicNumber = 86523158;

input group "Session Controls"
input bool   UseSessionFilter = true;
input string Session1Start = "14:00";
input string Session1End   = "18:00";
input string Session2Start = "19:00";
input string Session2End   = "22:00";

input group "Bias/Structure"
input bool   UseHTFBiasFilter = true;
input ENUM_TIMEFRAMES BiasTF1 = PERIOD_M15;
input ENUM_TIMEFRAMES BiasTF2 = PERIOD_H1;
input int    SwingStrength = 2;

input group "Zones"
input bool   UsePrevDayHighLow = true;
input bool   UseSessionHighLow = true;
input bool   UseAsiaBox = true;
input bool   UseFVG = false;
input bool   UseOrderBlock = false;
input double ZoneProximityPoints = 300;
input int    MaxZoneAgeBars = 288;

input group "Volatility and Filters"
input int    ATRPeriod = 14;
input double ATRRangeMax = 0.0;
input double ATRExpansionThreshold = 0.0;
input double ImpulseBodyFactor = 1.8;
input double MaxSpreadPoints = 80;

input group "Risk"
input bool   UseRiskPercent = true;
input double InitialRiskPct = 0.35;
input double CycleRiskPctMax = 1.00;
input double DailyLossPct = 3.00;
input int    MaxFailedCyclesPerDay = 2;

input group "Stops / Entries"
input double SLBufferPoints = 50;
input double MinSLPoints = 80;
input double MaxSLPoints = 1500;

input group "Recovery"
input bool   EnableRecovery = true;
input int    MaxEntriesPerCycle = 3;
input bool   UseATRRecoveryDistance = true;
input double RecoveryATRMultiplier = 0.5;
input double MinRecoveryDistancePoints = 250;
input double RecoveryMultiplier1 = 1.00;
input double RecoveryMultiplier2 = 1.00;
input double RecoveryMultiplier3 = 1.20;

input group "Recovery Scope / DD Trigger"
input ENUM_RECOVERY_SCOPE_MODE RecoveryScopeMode = REC_SCOPE_OWN_MAGIC_SYMBOL;
input double RecoveryStartDDMoney = 0.0;

input group "Initial Lot Mode"
input ENUM_INITIAL_LOT_MODE InitialLotMode = INITIAL_LOT_RISK_PERCENT;
input double InitialFixedLot = 0.01;
input double InitialStepLotPer1000Equity = 0.01;
input double InitialEquityStepSize = 1000.0;

input group "Basket Management"
input bool   UseBasketTP = true;
input double BasketTargetR = 0.40;
input bool   CloseBasketAtNetPositive = true;
input double MinNetProfitToClose = 5.0;
input int    MaxBarsInCycle = 18;

input group "News / Cooldown"
input bool   UseNewsFilter = false;
input int    NewsLockBeforeMinutes = 30;
input int    NewsLockAfterMinutes = 30;
input bool   ForceFlatBeforeNews = false;
input int    CooldownBars = 5;
input int    CooldownAfterLossBars = 8;

input group "EMA Layered Trade Module"
input bool   InpUseEMALayeredTrade = true;
input int    InpEMAFastPeriod = 20;
input int    InpEMAMidPeriod = 50;
input int    InpEMASlowPeriod = 100;
input int    InpEMASlopeLookbackBars = 3;
input double InpMaxExtendedATR = 0.60;
input double InpMinorBreakBufferPoints = 5.0;
input double InpNoTradeCompressionATR = 0.12;
input int    InpOverlapLookbackBars = 5;
input int    InpOverlapMinCount = 3;
input bool   InpEnablePartialTrail = true;
input double InpPartialClosePercent = 50.0;
input double InpTrailSwingBufferPoints = 20.0;

input group "Performance"
input bool   InpAggressiveTesterMode = true;
input bool   InpEnableOverlayLive = true;
input bool   InpEnableOverlayInTester = false;
input int    InpLogVerbosity = 1;

//==================================================================
// SECTION: GLOBAL CONSTANTS / VARIABLES
//==================================================================

#define MAX_ZONES 64
#define MAX_POS_TICKETS 64
#define OBJ_PREFIX "CR_EA_"

CTrade g_trade;

CycleStats      g_cycle;
DailyStats      g_day;
MarketSnapshot  g_snap;

ZoneInfo        g_zones[MAX_ZONES];
int             g_zoneCount = 0;

datetime        g_lastM5BarTime = 0;
datetime        g_lastTradeBarTime = 0;
int             g_cycleSequence = 0;
bool            g_newBarM5 = false;

string          g_symbol = "";
int             g_digits = 5;
double          g_point = 0.00001;

datetime        g_lastNewsCheck = 0;
bool            g_cachedNewsLock = false;
string          g_newsCurrencies[12];
int             g_newsCurrencyCount = 0;
bool            g_isTester = false;
bool            g_indicatorCacheReady = false;
string          g_statusMessage = "INIT";
string          g_lastStatusMessage = "";
datetime        g_lastStatusLogBar = 0;

double          g_scopeFloatingPnL = 0.0;
double          g_scopeDDMoney = 0.0;
double          g_scopeLongLots = 0.0;
double          g_scopeShortLots = 0.0;
int             g_scopeOrderCount = 0;
datetime        g_lastScopeRefresh = 0;

int             g_hEmaM15Fast = INVALID_HANDLE;
int             g_hEmaM15Mid  = INVALID_HANDLE;
int             g_hEmaM15Slow = INVALID_HANDLE;
int             g_hEmaM5Fast  = INVALID_HANDLE;
int             g_hEmaM5Mid   = INVALID_HANDLE;
int             g_hAtrM5      = INVALID_HANDLE;

datetime        g_cacheM5BarTime = 0;
datetime        g_cacheM15BarTime = 0;
double          g_cacheM15Fast_1 = 0.0;
double          g_cacheM15Mid_1  = 0.0;
double          g_cacheM15Slow_1 = 0.0;
double          g_cacheM15Fast_lb = 0.0;
double          g_cacheM15Mid_lb  = 0.0;
double          g_cacheM15Slow_lb = 0.0;
double          g_cacheM5Fast_1 = 0.0;
double          g_cacheM5Mid_1  = 0.0;
double          g_cacheAtrM5_1  = 0.0;

//==================================================================
// SECTION: FORWARD DECLARATIONS
//==================================================================

// lifecycle
int OnInit();
void OnTick();
void OnDeinit(const int reason);

// state
void ResetCycleState();
void ResetDailyStats();
void RestoreRuntimeStateFromTerminal();
void RefreshDailyState();
void RefreshMarketSnapshot();
void RefreshBiasAndState();
void UpdateRuntimeFlags();

// utility
double NormalizePrice(double price);
double NormalizeLots(double lots);
double PointsToPrice(double points);
double PriceToPoints(double priceDistance);
double GetPointValuePerLot();
datetime GetCurrentBarTime(ENUM_TIMEFRAMES tf);
bool IsNewBar(ENUM_TIMEFRAMES tf, datetime &lastBarTime);
int TimeToMinutes(string hhmm);
bool IsWithinTimeWindow(datetime t, string startHHMM, string endHHMM);
bool IsTradeAllowedNow();
double GetCurrentSpreadPoints();
double GetBid();
double GetAsk();
double GetMidPrice();
string RecoveryScopeModeToStr(ENUM_RECOVERY_SCOPE_MODE mode);
string InitialLotModeToStr(ENUM_INITIAL_LOT_MODE mode);
void SetStatusMessage(string msg, bool important=false);

// session/news
bool IsSessionAllowed();
bool IsBrokerRolloverWindow();
bool IsNewsLockActive();
bool ShouldForceFlatForNews();
bool IsPositionInScope(const string symbol, long magic);
bool IsPositionInScopeByMode(const string symbol, long magic, ENUM_RECOVERY_SCOPE_MODE mode);
bool IsChartSymbolInRecoveryScope(const string symbol, long magic);
int CountChartSymbolRecoveryScopePositions();
ENUM_SETUP_DIRECTION DetectChartSymbolRecoveryDirection();
void RefreshRecoveryScopeStats(bool force=false);
double CalcRecoveryScopeFloatingPnL();
double CalcRecoveryScopeDDMoney();

// data
bool GetBar(ENUM_TIMEFRAMES tf, int shift, BarData &bar);
bool GetBars(ENUM_TIMEFRAMES tf, int startShift, int count, MqlRates &rates[]);
double CalcATR(ENUM_TIMEFRAMES tf, int period, int shift=1);
double CalcAverageBody(ENUM_TIMEFRAMES tf, int bars, int startShift=1);
double CalcRangeHigh(ENUM_TIMEFRAMES tf, int bars, int startShift=1);
double CalcRangeLow(ENUM_TIMEFRAMES tf, int bars, int startShift=1);

// structure/bias
bool IsSwingHigh(ENUM_TIMEFRAMES tf, int shift, int strength);
bool IsSwingLow(ENUM_TIMEFRAMES tf, int shift, int strength);
bool GetLatestSwingHigh(ENUM_TIMEFRAMES tf, int lookback, SwingPoint &sp);
bool GetLatestSwingLow(ENUM_TIMEFRAMES tf, int lookback, SwingPoint &sp);
ENUM_BIAS_STATE DetectStructureBias(ENUM_TIMEFRAMES tf, int lookback);
bool IsBullishStructure(ENUM_TIMEFRAMES tf, int lookback);
bool IsBearishStructure(ENUM_TIMEFRAMES tf, int lookback);
ENUM_BIAS_STATE GetFinalBias();

// state classification
ENUM_MARKET_STATE DetectMarketState();
bool IsBreakoutExpansion();
bool IsRangeState();
bool IsTrendState();
bool IsMarketSafeForRecovery();

// zones
void RefreshZones();
void ClearZones();
void AddZone(ENUM_ZONE_TYPE type, double lower, double upper, bool bullish, bool bearish, string label);
void BuildPrevDayZones();
void BuildSessionZones();
void BuildAsiaBoxZones();
void BuildSwingZones();
void BuildFVGZones();
void BuildOrderBlockZones();
bool IsPriceNearZone(double price, const ZoneInfo &zone, double proximityPoints);
bool GetNearestValidZone(double price, ENUM_SETUP_DIRECTION dir, ZoneInfo &zoneOut);
bool GetBestZoneForDirection(ENUM_SETUP_DIRECTION dir, ZoneInfo &zoneOut);

// signals
bool DetectBullishLiquiditySweep(int shift, double &sweptPrice);
bool DetectBearishLiquiditySweep(int shift, double &sweptPrice);
bool IsBullishRejectionCandle(int shift);
bool IsBearishRejectionCandle(int shift);
bool IsBullishEngulfing(int shift);
bool IsBearishEngulfing(int shift);
bool DetectBullishCHOCH(int shift);
bool DetectBearishCHOCH(int shift);
bool DetectBullishMomentumShift(int shift);
bool DetectBearishMomentumShift(int shift);
SignalInfo EvaluateLongSetup(void);
SignalInfo EvaluateShortSetup(void);
SignalInfo EvaluateEntrySignal(void);
SignalInfo EvaluateRecoverySignal(void);

// risk
double CalcRiskMoney(double riskPct);
double CalcLotsByRisk(double riskMoney, double stopDistancePoints);
double CalcInitialLotsByMode(double stopDistancePoints, double &riskMoneyOut);
double GetRecoveryMultiplier(int entryNumber);
double CalcPlannedEntryLots(int entryNumber, double stopDistancePoints);
double CalcCurrentCycleRiskMoney();
double CalcProjectedCycleRiskMoney(const EntryPlan &plan);
bool WouldExceedCycleRisk(const EntryPlan &plan);
bool IsDailyLossLimitHit();
bool IsFailedCycleLimitHit();
void ActivateDailyLock(string reason);
bool IsMarginSafeForNewEntry(double lots);
bool IsSpreadAcceptable();

// plans/execution
EntryPlan BuildInitialEntryPlan(const SignalInfo &sig);
EntryPlan BuildRecoveryPlan(const SignalInfo &sig);
bool ValidateEntryPlan(const EntryPlan &plan);
bool PlaceMarketOrder(const EntryPlan &plan, ulong &ticketOut);
bool PlaceEntryOrder(const EntryPlan &plan, ulong &ticketOut);
bool ClosePositionByTicket(ulong ticket);
bool CloseAllCyclePositions(ENUM_EXIT_REASON reason);
bool ModifyPositionSLTP(ulong ticket, double sl, double tp);
bool ApplySharedBasketStop(double stopPrice);

// cycle
void StartNewCycle(const EntryPlan &plan);
void MarkCycleEntryPlaced(const EntryPlan &plan);
void SyncCycleFromOpenPositions();
bool IsRecoveryAllowed();
bool IsRecoveryPriceImproved(ENUM_SETUP_DIRECTION dir, double candidatePrice);
bool IsRecoveryDistanceSatisfied(ENUM_SETUP_DIRECTION dir, double candidatePrice);
bool IsRecoveryStillStructurallyValid();
void EvaluateNewCycleEntry();
void EvaluateRecoveryEntry();
void ManageActiveCycle();
void FinalizeClosedCycle(ENUM_EXIT_REASON reason);
bool IsCycleActive();
bool IsCycleInCooldown();

// position discovery
int CountOpenPositionsByMagicSymbol();
bool GetOpenPositionTickets(ulong &tickets[], int &count);
double CalcOpenLots();
double CalcBasketFloatingPnL();
double CalcBasketAvgEntryPrice();
double CalcBasketWorstSLDistancePoints();

// exits
bool IsBasketTargetHit();
bool IsNetPositiveCloseConditionHit();
bool IsCycleTimeStopHit();
bool IsStructureInvalidated();
bool IsCycleRiskStopHit();
bool ShouldExitCycle(ENUM_EXIT_REASON &reasonOut);

// logging/chart
string BiasToStr(ENUM_BIAS_STATE b);
string StateToStr(ENUM_CYCLE_STATE s);
void LogInfo(string msg);
void LogWarn(string msg);
void LogError(string msg);
void LogTrade(string msg);
void LogSignalDecision(const SignalInfo &sig);
void LogEntryPlan(const EntryPlan &plan);
void LogCycleSnapshot();
void RenderDiagnostics();
void DrawZoneObjects();
void DrawCycleInfoPanel();
void ClearChartObjectsByPrefix(string prefix);

// misc
bool ValidateInputs();
bool PrimeMarketData();
bool InitIndicatorHandles();
void ReleaseIndicatorHandles();
bool CopyBufferValue(int handle, int shift, double &value);
bool UpdateIndicatorCaches(bool force=false);
bool IsVisualDiagnosticsEnabled();
bool IsHTFLayerBiasLong();
bool IsHTFLayerBiasShort();
bool IsM5PullbackIntoEMAZone(bool isLong, double &zoneLow, double &zoneHigh);
bool IsNoTradeEMAState();
bool IsRejectionThenMinorBreakLong();
bool IsRejectionThenMinorBreakShort();
SignalInfo EvaluateLayeredLongSetup(void);
SignalInfo EvaluateLayeredShortSetup(void);
double CalcCycleRMultiple();
bool ClosePartialByTicket(ulong ticket, double closeLots);
bool ExecutePartialAt1R();
bool UpdateSwingTrailStop();
void MaybeHandlePartialAndTrail();

//==================================================================
// SECTION: UTILITY HELPERS
//==================================================================

double NormalizePrice(double price)
{
   return NormalizeDouble(price, g_digits);
}

double NormalizeLots(double lots)
{
   double vmin = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   double vstep = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
   if(vstep <= 0.0)
      vstep = 0.01;
   lots = MathMax(vmin, MathMin(vmax, lots));
   lots = MathFloor(lots / vstep) * vstep;
   int volDigits = 2;
   return NormalizeDouble(MathMax(vmin, lots), volDigits);
}

double PointsToPrice(double points)
{
   return points * g_point;
}

double PriceToPoints(double priceDistance)
{
   if(g_point <= 0.0)
      return 0.0;
   return priceDistance / g_point;
}

double GetPointValuePerLot()
{
   double tickValue = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0 || g_point <= 0.0)
      return 0.0;
   return tickValue * (g_point / tickSize);
}

datetime GetCurrentBarTime(ENUM_TIMEFRAMES tf)
{
   return iTime(g_symbol, tf, 0);
}

bool IsNewBar(ENUM_TIMEFRAMES tf, datetime &lastBarTime)
{
   datetime t = GetCurrentBarTime(tf);
   if(t <= 0)
      return false;
   if(t != lastBarTime)
   {
      lastBarTime = t;
      return true;
   }
   return false;
}

int TimeToMinutes(string hhmm)
{
   string parts[];
   int n = StringSplit(hhmm, ':', parts);
   if(n != 2)
      return -1;
   int h = (int)StringToInteger(parts[0]);
   int m = (int)StringToInteger(parts[1]);
   if(h < 0 || h > 23 || m < 0 || m > 59)
      return -1;
   return h * 60 + m;
}

bool IsWithinTimeWindow(datetime t, string startHHMM, string endHHMM)
{
   int s = TimeToMinutes(startHHMM);
   int e = TimeToMinutes(endHHMM);
   if(s < 0 || e < 0)
      return false;

   MqlDateTime dt;
   TimeToStruct(t, dt);
   int cur = dt.hour * 60 + dt.min;

   if(s == e)
      return true;
   if(s < e)
      return (cur >= s && cur < e);
   return (cur >= s || cur < e);
}

bool IsTradeAllowedNow()
{
   return TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) && MQLInfoInteger(MQL_TRADE_ALLOWED);
}

double GetCurrentSpreadPoints()
{
   double bid = GetBid();
   double ask = GetAsk();
   if(g_point <= 0.0 || bid <= 0.0 || ask <= 0.0)
      return 999999.0;
   return (ask - bid) / g_point;
}

double GetBid()
{
   return SymbolInfoDouble(g_symbol, SYMBOL_BID);
}

double GetAsk()
{
   return SymbolInfoDouble(g_symbol, SYMBOL_ASK);
}

double GetMidPrice()
{
   double b = GetBid();
   double a = GetAsk();
   if(a <= 0.0 || b <= 0.0)
      return 0.0;
   return (a + b) * 0.5;
}

string RecoveryScopeModeToStr(ENUM_RECOVERY_SCOPE_MODE mode)
{
   if(mode == REC_SCOPE_OWN_MAGIC_SYMBOL)
      return "OWN_MAGIC_SYMBOL";
   if(mode == REC_SCOPE_ANY_MAGIC_SYMBOL)
      return "ANY_MAGIC_SYMBOL";
   if(mode == REC_SCOPE_WHOLE_ACCOUNT)
      return "WHOLE_ACCOUNT";
   return "?";
}

string InitialLotModeToStr(ENUM_INITIAL_LOT_MODE mode)
{
   if(mode == INITIAL_LOT_RISK_PERCENT)
      return "RISK_PERCENT";
   if(mode == INITIAL_LOT_FIXED)
      return "FIXED";
   if(mode == INITIAL_LOT_FIXED_STEP_EQUITY)
      return "FIXED_STEP_EQUITY";
   return "?";
}

void SetStatusMessage(string msg, bool important=false)
{
   if(StringLen(msg) <= 0)
      return;

   if(!important && g_statusMessage == msg)
      return;

   g_statusMessage = msg;
   if(InpLogVerbosity < 1)
      return;

   datetime barTime = iTime(g_symbol, PERIOD_M5, 0);
   bool shouldLog = (important || g_lastStatusMessage != msg);

   if(shouldLog)
   {
      Print("[STATUS][", g_symbol, "][C", g_cycle.cycleId, "][", StateToStr(g_cycle.state), "] ", msg);
      g_lastStatusMessage = msg;
      g_lastStatusLogBar = barTime;
   }
}

bool IsPositionInScopeByMode(const string symbol, long magic, ENUM_RECOVERY_SCOPE_MODE mode)
{
   if(mode == REC_SCOPE_OWN_MAGIC_SYMBOL)
      return (symbol == g_symbol && magic == InpMagicNumber);
   if(mode == REC_SCOPE_ANY_MAGIC_SYMBOL)
      return (symbol == g_symbol);
   if(mode == REC_SCOPE_WHOLE_ACCOUNT)
      return true;
   return false;
}

bool IsPositionInScope(const string symbol, long magic)
{
   return IsPositionInScopeByMode(symbol, magic, RecoveryScopeMode);
}

bool IsChartSymbolInRecoveryScope(const string symbol, long magic)
{
   if(symbol != g_symbol)
      return false;
   if(RecoveryScopeMode == REC_SCOPE_OWN_MAGIC_SYMBOL)
      return (magic == InpMagicNumber);
   return true;
}

int CountChartSymbolRecoveryScopePositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(!IsChartSymbolInRecoveryScope(sym, magic))
         continue;
      count++;
   }
   return count;
}

ENUM_SETUP_DIRECTION DetectChartSymbolRecoveryDirection()
{
   double buyLots = 0.0;
   double sellLots = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(!IsChartSymbolInRecoveryScope(sym, magic))
         continue;

      long type = PositionGetInteger(POSITION_TYPE);
      double vol = PositionGetDouble(POSITION_VOLUME);
      if(type == POSITION_TYPE_BUY)
         buyLots += vol;
      else if(type == POSITION_TYPE_SELL)
         sellLots += vol;
   }

   if(buyLots > sellLots + 1e-9)
      return DIR_LONG;
   if(sellLots > buyLots + 1e-9)
      return DIR_SHORT;

   if(g_snap.finalBias == BIAS_BULLISH)
      return DIR_LONG;
   if(g_snap.finalBias == BIAS_BEARISH)
      return DIR_SHORT;
   return DIR_NONE;
}

void RefreshRecoveryScopeStats(bool force=false)
{
   datetime now = TimeCurrent();
   int throttleSeconds = (g_isTester && InpAggressiveTesterMode ? 60 : 2);
   if(!force && !g_newBarM5 && g_lastScopeRefresh > 0 && (now - g_lastScopeRefresh) < throttleSeconds)
      return;

   g_scopeFloatingPnL = 0.0;
   g_scopeDDMoney = 0.0;
   g_scopeLongLots = 0.0;
   g_scopeShortLots = 0.0;
   g_scopeOrderCount = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(!IsPositionInScope(sym, magic))
         continue;

      g_scopeOrderCount++;
      g_scopeFloatingPnL += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

      long type = PositionGetInteger(POSITION_TYPE);
      double vol = PositionGetDouble(POSITION_VOLUME);
      if(type == POSITION_TYPE_BUY)
         g_scopeLongLots += vol;
      else if(type == POSITION_TYPE_SELL)
         g_scopeShortLots += vol;
   }

   g_scopeDDMoney = MathMax(0.0, -g_scopeFloatingPnL);
   g_lastScopeRefresh = now;
}

double CalcRecoveryScopeFloatingPnL()
{
   RefreshRecoveryScopeStats(false);
   return g_scopeFloatingPnL;
}

double CalcRecoveryScopeDDMoney()
{
   RefreshRecoveryScopeStats(false);
   return g_scopeDDMoney;
}

bool InitIndicatorHandles()
{
   g_hEmaM15Fast = iMA(g_symbol, PERIOD_M15, InpEMAFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_hEmaM15Mid  = iMA(g_symbol, PERIOD_M15, InpEMAMidPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_hEmaM15Slow = iMA(g_symbol, PERIOD_M15, InpEMASlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_hEmaM5Fast  = iMA(g_symbol, PERIOD_M5, InpEMAFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_hEmaM5Mid   = iMA(g_symbol, PERIOD_M5, InpEMAMidPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_hAtrM5      = iATR(g_symbol, PERIOD_M5, ATRPeriod);

   return (g_hEmaM15Fast != INVALID_HANDLE &&
           g_hEmaM15Mid  != INVALID_HANDLE &&
           g_hEmaM15Slow != INVALID_HANDLE &&
           g_hEmaM5Fast  != INVALID_HANDLE &&
           g_hEmaM5Mid   != INVALID_HANDLE &&
            g_hAtrM5      != INVALID_HANDLE);
}

void ReleaseIndicatorHandles()
{
   if(g_hEmaM15Fast != INVALID_HANDLE) IndicatorRelease(g_hEmaM15Fast);
   if(g_hEmaM15Mid  != INVALID_HANDLE) IndicatorRelease(g_hEmaM15Mid);
   if(g_hEmaM15Slow != INVALID_HANDLE) IndicatorRelease(g_hEmaM15Slow);
   if(g_hEmaM5Fast  != INVALID_HANDLE) IndicatorRelease(g_hEmaM5Fast);
   if(g_hEmaM5Mid   != INVALID_HANDLE) IndicatorRelease(g_hEmaM5Mid);
   if(g_hAtrM5      != INVALID_HANDLE) IndicatorRelease(g_hAtrM5);

   g_hEmaM15Fast = INVALID_HANDLE;
   g_hEmaM15Mid  = INVALID_HANDLE;
   g_hEmaM15Slow = INVALID_HANDLE;
   g_hEmaM5Fast  = INVALID_HANDLE;
   g_hEmaM5Mid   = INVALID_HANDLE;
   g_hAtrM5      = INVALID_HANDLE;
}

bool CopyBufferValue(int handle, int shift, double &value)
{
   if(handle == INVALID_HANDLE)
      return false;
   double v[];
   ArraySetAsSeries(v, true);
   if(CopyBuffer(handle, 0, shift, 1, v) != 1)
      return false;
   value = v[0];
   return true;
}

bool UpdateIndicatorCaches(bool force=false)
{
   datetime barM5  = iTime(g_symbol, PERIOD_M5, 0);
   datetime barM15 = iTime(g_symbol, PERIOD_M15, 0);
   if(!force && barM5 == g_cacheM5BarTime && barM15 == g_cacheM15BarTime)
      return true;

   double v = 0.0;
   if(!CopyBufferValue(g_hEmaM15Fast, 1, v)) return false;
   g_cacheM15Fast_1 = v;
   if(!CopyBufferValue(g_hEmaM15Mid, 1, v)) return false;
   g_cacheM15Mid_1 = v;
   if(!CopyBufferValue(g_hEmaM15Slow, 1, v)) return false;
   g_cacheM15Slow_1 = v;

   int lb = MathMax(1, InpEMASlopeLookbackBars);
   if(!CopyBufferValue(g_hEmaM15Fast, 1 + lb, v)) return false;
   g_cacheM15Fast_lb = v;
   if(!CopyBufferValue(g_hEmaM15Mid, 1 + lb, v)) return false;
   g_cacheM15Mid_lb = v;
   if(!CopyBufferValue(g_hEmaM15Slow, 1 + lb, v)) return false;
   g_cacheM15Slow_lb = v;

   if(!CopyBufferValue(g_hEmaM5Fast, 1, v)) return false;
   g_cacheM5Fast_1 = v;
   if(!CopyBufferValue(g_hEmaM5Mid, 1, v)) return false;
   g_cacheM5Mid_1 = v;
   if(!CopyBufferValue(g_hAtrM5, 1, v)) return false;
   g_cacheAtrM5_1 = v;

   g_cacheM5BarTime = barM5;
   g_cacheM15BarTime = barM15;
   return true;
}

bool IsVisualDiagnosticsEnabled()
{
   if(g_isTester)
      return InpEnableOverlayInTester;
   return InpEnableOverlayLive;
}

//==================================================================
// SECTION: SESSION / NEWS MODULE
//==================================================================

bool IsSessionAllowed()
{
   if(!UseSessionFilter)
      return true;
   datetime now = TimeCurrent();
   bool s1 = IsWithinTimeWindow(now, Session1Start, Session1End);
   bool s2 = IsWithinTimeWindow(now, Session2Start, Session2End);
   return (s1 || s2);
}

bool IsBrokerRolloverWindow()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return (dt.hour == 23 && dt.min >= 55);
}

string ToUpperAscii(string s)
{
   StringToUpper(s);
   return s;
}

bool NewsCurrencyContains(string ccy)
{
   for(int i = 0; i < g_newsCurrencyCount; i++)
      if(g_newsCurrencies[i] == ccy)
         return true;
   return false;
}

void AddNewsCurrency(string ccy)
{
   ccy = ToUpperAscii(ccy);
   if(StringLen(ccy) != 3)
      return;
   if(NewsCurrencyContains(ccy))
      return;
   if(g_newsCurrencyCount >= ArraySize(g_newsCurrencies))
      return;
   g_newsCurrencies[g_newsCurrencyCount++] = ccy;
}

void BuildNewsCurrencyWatchlist()
{
   g_newsCurrencyCount = 0;
   string sym = ToUpperAscii(g_symbol);

   if(StringFind(sym, "XAU") >= 0 || StringFind(sym, "XAG") >= 0)
      AddNewsCurrency("USD");

   if(StringFind(sym, "US30") >= 0 || StringFind(sym, "NAS") >= 0 || StringFind(sym, "SPX") >= 0 || StringFind(sym, "DJ") >= 0)
      AddNewsCurrency("USD");
   if(StringFind(sym, "DE40") >= 0 || StringFind(sym, "GER") >= 0 || StringFind(sym, "EU") >= 0)
      AddNewsCurrency("EUR");
   if(StringFind(sym, "AUS") >= 0 || StringFind(sym, "ASX") >= 0)
      AddNewsCurrency("AUD");
   if(StringFind(sym, "UK") >= 0 || StringFind(sym, "FTSE") >= 0)
      AddNewsCurrency("GBP");
   if(StringFind(sym, "JP") >= 0 || StringFind(sym, "NIK") >= 0)
      AddNewsCurrency("JPY");

   if(StringLen(sym) >= 6)
   {
      string a = StringSubstr(sym, 0, 3);
      string b = StringSubstr(sym, 3, 3);
      AddNewsCurrency(a);
      AddNewsCurrency(b);
   }

   AddNewsCurrency("USD");
}

bool IsEventCurrencyWatched(ulong eventId)
{
   MqlCalendarEvent ev;
   if(!CalendarEventById(eventId, ev))
      return false;
   if(ev.importance != CALENDAR_IMPORTANCE_HIGH)
      return false;

   MqlCalendarCountry country;
   if(!CalendarCountryById(ev.country_id, country))
      return false;

   string ccy = ToUpperAscii(country.currency);
   return NewsCurrencyContains(ccy);
}

bool IsNewsLockActive()
{
   if(!UseNewsFilter)
      return false;

   datetime now = TimeTradeServer();
   if(now <= 0)
      now = TimeCurrent();

   int refreshSeconds = 20;
   if(g_isTester && InpAggressiveTesterMode)
      refreshSeconds = 60;
   if(g_lastNewsCheck != 0 && (now - g_lastNewsCheck) < refreshSeconds)
      return g_cachedNewsLock;

   g_lastNewsCheck = now;
   g_cachedNewsLock = false;

   datetime fromTime = now - (NewsLockAfterMinutes * 60) - 120;
   datetime toTime   = now + (NewsLockBeforeMinutes * 60) + 120;

   MqlCalendarValue values[];
   int count = CalendarValueHistory(values, fromTime, toTime, NULL, NULL);
   if(count <= 0)
      return false;

   for(int i = 0; i < count; i++)
   {
      datetime et = values[i].time;
      if(et <= 0)
         continue;
      if(!IsEventCurrencyWatched(values[i].event_id))
         continue;

      datetime lockStart = et - (NewsLockBeforeMinutes * 60);
      datetime lockEnd   = et + (NewsLockAfterMinutes * 60);
      if(now >= lockStart && now <= lockEnd)
      {
         g_cachedNewsLock = true;
         return true;
      }
   }

   return false;
}

bool ShouldForceFlatForNews()
{
   if(!UseNewsFilter || !ForceFlatBeforeNews)
      return false;
   return IsNewsLockActive();
}

//==================================================================
// SECTION: MARKET DATA MODULE
//==================================================================

bool GetBar(ENUM_TIMEFRAMES tf, int shift, BarData &bar)
{
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(g_symbol, tf, shift, 1, r) != 1)
      return false;
   bar.time = r[0].time;
   bar.open = r[0].open;
   bar.high = r[0].high;
   bar.low  = r[0].low;
   bar.close = r[0].close;
   bar.tick_volume = r[0].tick_volume;
   bar.spread = r[0].spread;
   return true;
}

bool GetBars(ENUM_TIMEFRAMES tf, int startShift, int count, MqlRates &rates[])
{
   ArraySetAsSeries(rates, true);
   return (CopyRates(g_symbol, tf, startShift, count, rates) == count);
}

double CalcATR(ENUM_TIMEFRAMES tf, int period, int shift=1)
{
   if(period <= 0)
      return 0.0;
   MqlRates rates[];
   int need = period + shift + 2;
   if(!GetBars(tf, 0, need, rates))
      return 0.0;

   double sumTr = 0.0;
   for(int i = shift; i < shift + period; i++)
   {
      double high = rates[i].high;
      double low = rates[i].low;
      double prevClose = rates[i + 1].close;
      double tr1 = high - low;
      double tr2 = MathAbs(high - prevClose);
      double tr3 = MathAbs(low - prevClose);
      sumTr += MathMax(tr1, MathMax(tr2, tr3));
   }
   return (sumTr / period);
}

double CalcAverageBody(ENUM_TIMEFRAMES tf, int bars, int startShift=1)
{
   if(bars <= 0)
      return 0.0;
   MqlRates rates[];
   int need = bars + startShift + 2;
   if(!GetBars(tf, 0, need, rates))
      return 0.0;

   double sum = 0.0;
   for(int i = startShift; i < startShift + bars; i++)
      sum += MathAbs(rates[i].close - rates[i].open);
   return sum / bars;
}

double CalcRangeHigh(ENUM_TIMEFRAMES tf, int bars, int startShift=1)
{
   if(bars <= 0)
      return 0.0;
   MqlRates rates[];
   int need = bars + startShift + 2;
   if(!GetBars(tf, 0, need, rates))
      return 0.0;

   double h = rates[startShift].high;
   for(int i = startShift + 1; i < startShift + bars; i++)
      h = MathMax(h, rates[i].high);
   return h;
}

double CalcRangeLow(ENUM_TIMEFRAMES tf, int bars, int startShift=1)
{
   if(bars <= 0)
      return 0.0;
   MqlRates rates[];
   int need = bars + startShift + 2;
   if(!GetBars(tf, 0, need, rates))
      return 0.0;

   double l = rates[startShift].low;
   for(int i = startShift + 1; i < startShift + bars; i++)
      l = MathMin(l, rates[i].low);
   return l;
}

//==================================================================
// SECTION: STRUCTURE / BIAS MODULE
//==================================================================

bool IsSwingHigh(ENUM_TIMEFRAMES tf, int shift, int strength)
{
   if(shift <= strength)
      return false;
   double center = iHigh(g_symbol, tf, shift);
   if(center <= 0.0)
      return false;

   for(int k = 1; k <= strength; k++)
   {
      double left = iHigh(g_symbol, tf, shift + k);
      double right = iHigh(g_symbol, tf, shift - k);
      if(left >= center || right > center)
         return false;
   }
   return true;
}

bool IsSwingLow(ENUM_TIMEFRAMES tf, int shift, int strength)
{
   if(shift <= strength)
      return false;
   double center = iLow(g_symbol, tf, shift);
   if(center <= 0.0)
      return false;

   for(int k = 1; k <= strength; k++)
   {
      double left = iLow(g_symbol, tf, shift + k);
      double right = iLow(g_symbol, tf, shift - k);
      if(left <= center || right < center)
         return false;
   }
   return true;
}

bool GetLatestSwingHigh(ENUM_TIMEFRAMES tf, int lookback, SwingPoint &sp)
{
   sp.valid = false;
   for(int i = SwingStrength + 1; i < lookback; i++)
   {
      if(IsSwingHigh(tf, i, SwingStrength))
      {
         sp.index = i;
         sp.time = iTime(g_symbol, tf, i);
         sp.price = iHigh(g_symbol, tf, i);
         sp.isHigh = true;
         sp.valid = true;
         return true;
      }
   }
   return false;
}

bool GetLatestSwingLow(ENUM_TIMEFRAMES tf, int lookback, SwingPoint &sp)
{
   sp.valid = false;
   for(int i = SwingStrength + 1; i < lookback; i++)
   {
      if(IsSwingLow(tf, i, SwingStrength))
      {
         sp.index = i;
         sp.time = iTime(g_symbol, tf, i);
         sp.price = iLow(g_symbol, tf, i);
         sp.isHigh = false;
         sp.valid = true;
         return true;
      }
   }
   return false;
}

ENUM_BIAS_STATE DetectStructureBias(ENUM_TIMEFRAMES tf, int lookback)
{
   SwingPoint highs[2];
   SwingPoint lows[2];
   int hc = 0;
   int lc = 0;

   for(int i = SwingStrength + 1; i < lookback && (hc < 2 || lc < 2); i++)
   {
      if(hc < 2 && IsSwingHigh(tf, i, SwingStrength))
      {
         highs[hc].index = i;
         highs[hc].price = iHigh(g_symbol, tf, i);
         highs[hc].time = iTime(g_symbol, tf, i);
         highs[hc].valid = true;
         hc++;
      }
      if(lc < 2 && IsSwingLow(tf, i, SwingStrength))
      {
         lows[lc].index = i;
         lows[lc].price = iLow(g_symbol, tf, i);
         lows[lc].time = iTime(g_symbol, tf, i);
         lows[lc].valid = true;
         lc++;
      }
   }

   if(hc < 2 || lc < 2)
      return BIAS_NEUTRAL;

   bool hh = highs[0].price > highs[1].price;
   bool llh = highs[0].price < highs[1].price;
   bool hl = lows[0].price > lows[1].price;
   bool lll = lows[0].price < lows[1].price;

   if(hh && hl)
      return BIAS_BULLISH;
   if(llh && lll)
      return BIAS_BEARISH;
   return BIAS_NEUTRAL;
}

bool IsBullishStructure(ENUM_TIMEFRAMES tf, int lookback)
{
   return DetectStructureBias(tf, lookback) == BIAS_BULLISH;
}

bool IsBearishStructure(ENUM_TIMEFRAMES tf, int lookback)
{
   return DetectStructureBias(tf, lookback) == BIAS_BEARISH;
}

ENUM_BIAS_STATE GetFinalBias()
{
   ENUM_BIAS_STATE b1 = g_snap.biasM15;
   ENUM_BIAS_STATE b2 = g_snap.biasH1;

   if(b1 == BIAS_BULLISH && b2 == BIAS_BULLISH)
      return BIAS_BULLISH;
   if(b1 == BIAS_BEARISH && b2 == BIAS_BEARISH)
      return BIAS_BEARISH;
   if((b1 == BIAS_BULLISH && b2 == BIAS_NEUTRAL) || (b2 == BIAS_BULLISH && b1 == BIAS_NEUTRAL))
      return BIAS_BULLISH;
   if((b1 == BIAS_BEARISH && b2 == BIAS_NEUTRAL) || (b2 == BIAS_BEARISH && b1 == BIAS_NEUTRAL))
      return BIAS_BEARISH;
   return BIAS_NEUTRAL;
}

void RefreshBiasAndState()
{
   if(InpUseEMALayeredTrade)
   {
      bool longBias = IsHTFLayerBiasLong();
      bool shortBias = IsHTFLayerBiasShort();
      g_snap.biasM15 = (longBias ? BIAS_BULLISH : (shortBias ? BIAS_BEARISH : BIAS_NEUTRAL));
      g_snap.biasH1 = g_snap.biasM15;
      g_snap.finalBias = g_snap.biasM15;
   }
   else
   {
      g_snap.biasM15 = DetectStructureBias(BiasTF1, 80);
      g_snap.biasH1 = DetectStructureBias(BiasTF2, 80);
      g_snap.finalBias = GetFinalBias();
   }
   g_snap.marketState = DetectMarketState();
}

//==================================================================
// SECTION: MARKET STATE MODULE
//==================================================================

bool IsBreakoutExpansion()
{
   double body = CalcAverageBody(PERIOD_M5, 8, 1);
   double atr = CalcATR(PERIOD_M5, ATRPeriod, 1);
   if(body <= 0.0 || atr <= 0.0)
      return false;

   BarData b;
   if(!GetBar(PERIOD_M5, 1, b))
      return false;
   double lastBody = MathAbs(b.close - b.open);

   bool bodyImpulse = lastBody >= body * ImpulseBodyFactor;
   bool atrExpansion = (ATRExpansionThreshold > 0.0 && atr >= ATRExpansionThreshold);
   return (bodyImpulse || atrExpansion);
}

bool IsRangeState()
{
   if(g_snap.marketState == MARKET_RANGE)
      return true;
   double h = CalcRangeHigh(PERIOD_M5, 24, 1);
   double l = CalcRangeLow(PERIOD_M5, 24, 1);
   double atr = CalcATR(PERIOD_M5, ATRPeriod, 1);
   if(h <= l || atr <= 0)
      return false;
   double r = h - l;
   return (r <= atr * 3.0);
}

bool IsTrendState()
{
   if(g_snap.finalBias == BIAS_NEUTRAL)
      return false;
   double atr = CalcATR(PERIOD_M5, ATRPeriod, 1);
   double body = CalcAverageBody(PERIOD_M5, 10, 1);
   if(atr <= 0.0)
      return false;
   return (body >= atr * 0.4);
}

ENUM_MARKET_STATE DetectMarketState()
{
   if(!g_snap.spreadOk || g_snap.newsLocked || !IsTradeAllowedNow())
      return MARKET_UNSAFE;

   if(ATRRangeMax > 0.0)
   {
      double atr = (g_snap.atrM5 > 0.0 ? g_snap.atrM5 : CalcATR(PERIOD_M5, ATRPeriod, 1));
      if(atr > ATRRangeMax)
         return MARKET_UNSAFE;
   }

   if(IsBreakoutExpansion())
      return MARKET_BREAKOUT_EXPANSION;
   if(IsTrendState())
      return MARKET_TREND;
   return MARKET_RANGE;
}

bool IsMarketSafeForRecovery()
{
   if(!g_snap.spreadOk || !g_snap.marginOk || g_snap.newsLocked)
      return false;
   if(g_snap.marketState == MARKET_UNSAFE)
      return false;
   if(g_snap.marketState == MARKET_BREAKOUT_EXPANSION)
      return false;
   return true;
}

//==================================================================
// SECTION: ZONE ENGINE
//==================================================================

void ClearZones()
{
   g_zoneCount = 0;
   for(int i = 0; i < MAX_ZONES; i++)
   {
      g_zones[i].active = false;
      g_zones[i].type = ZONE_NONE;
   }
}

void AddZone(ENUM_ZONE_TYPE type, double lower, double upper, bool bullish, bool bearish, string label)
{
   if(g_zoneCount >= MAX_ZONES)
      return;
   if(lower > upper)
   {
      double tmp = lower;
      lower = upper;
      upper = tmp;
   }

   g_zones[g_zoneCount].type = type;
   g_zones[g_zoneCount].lower = NormalizePrice(lower);
   g_zones[g_zoneCount].upper = NormalizePrice(upper);
   g_zones[g_zoneCount].created = TimeCurrent();
   g_zones[g_zoneCount].bullish = bullish;
   g_zones[g_zoneCount].bearish = bearish;
   g_zones[g_zoneCount].active = true;
   g_zones[g_zoneCount].label = label;
   g_zoneCount++;
}

void BuildPrevDayZones()
{
   if(!UsePrevDayHighLow)
      return;

   double pdh = iHigh(g_symbol, PERIOD_D1, 1);
   double pdl = iLow(g_symbol, PERIOD_D1, 1);
   if(pdh <= 0.0 || pdl <= 0.0)
      return;

   double half = PointsToPrice(MathMax(10.0, ZoneProximityPoints * 0.15));
   AddZone(ZONE_PREV_DAY_HIGH, pdh - half, pdh + half, false, true, "PDH");
   AddZone(ZONE_PREV_DAY_LOW,  pdl - half, pdl + half, true, false, "PDL");
}

bool BuildRangeZoneByWindow(string startHHMM, string endHHMM, ENUM_ZONE_TYPE highType, ENUM_ZONE_TYPE lowType, string tag)
{
   int sm = TimeToMinutes(startHHMM);
   int em = TimeToMinutes(endHHMM);
   if(sm < 0 || em < 0)
      return false;

   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   datetime day0 = StructToTime(dt);

   datetime s = day0 + sm * 60;
   datetime e = day0 + em * 60;
   if(sm >= em)
      e += 24 * 60 * 60;

   if(now < e)
   {
      s -= 24 * 60 * 60;
      e -= 24 * 60 * 60;
   }

   MqlRates rates[];
   int copied = CopyRates(g_symbol, PERIOD_M5, s, e, rates);
   if(copied <= 0)
      return false;

   double hi = rates[0].high;
   double lo = rates[0].low;
   for(int i = 1; i < copied; i++)
   {
      hi = MathMax(hi, rates[i].high);
      lo = MathMin(lo, rates[i].low);
   }

   double half = PointsToPrice(MathMax(10.0, ZoneProximityPoints * 0.10));
   AddZone(highType, hi - half, hi + half, false, true, tag + "_H");
   AddZone(lowType,  lo - half, lo + half, true, false, tag + "_L");
   return true;
}

void BuildSessionZones()
{
   if(!UseSessionHighLow)
      return;
   BuildRangeZoneByWindow(Session1Start, Session1End, ZONE_SESSION_HIGH, ZONE_SESSION_LOW, "S1");
}

void BuildAsiaBoxZones()
{
   if(!UseAsiaBox)
      return;
   BuildRangeZoneByWindow("00:00", "06:00", ZONE_ASIA_HIGH, ZONE_ASIA_LOW, "ASIA");
}

void BuildSwingZones()
{
   SwingPoint sh;
   SwingPoint sl;

   if(GetLatestSwingHigh(PERIOD_M15, 120, sh))
   {
      double half = PointsToPrice(MathMax(8.0, ZoneProximityPoints * 0.08));
      AddZone(ZONE_M15_SWING_HIGH, sh.price - half, sh.price + half, false, true, "M15_SH");
   }
   if(GetLatestSwingLow(PERIOD_M15, 120, sl))
   {
      double half = PointsToPrice(MathMax(8.0, ZoneProximityPoints * 0.08));
      AddZone(ZONE_M15_SWING_LOW, sl.price - half, sl.price + half, true, false, "M15_SL");
   }

   if(GetLatestSwingHigh(PERIOD_H1, 120, sh))
   {
      double half = PointsToPrice(MathMax(10.0, ZoneProximityPoints * 0.10));
      AddZone(ZONE_H1_SWING_HIGH, sh.price - half, sh.price + half, false, true, "H1_SH");
   }
   if(GetLatestSwingLow(PERIOD_H1, 120, sl))
   {
      double half = PointsToPrice(MathMax(10.0, ZoneProximityPoints * 0.10));
      AddZone(ZONE_H1_SWING_LOW, sl.price - half, sl.price + half, true, false, "H1_SL");
   }
}

void BuildFVGZones()
{
   if(!UseFVG)
      return;

   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(g_symbol, PERIOD_M15, 0, 30, r) < 5)
      return;

   for(int i = 2; i <= 12; i++)
   {
      if(r[i].low > r[i + 2].high)
         AddZone(ZONE_FVG_BULL, r[i + 2].high, r[i].low, true, false, "FVG_BULL");
      if(r[i].high < r[i + 2].low)
         AddZone(ZONE_FVG_BEAR, r[i].high, r[i + 2].low, false, true, "FVG_BEAR");
   }
}

void BuildOrderBlockZones()
{
   if(!UseOrderBlock)
      return;

   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(g_symbol, PERIOD_M15, 0, 20, r) < 6)
      return;

   for(int i = 2; i <= 8; i++)
   {
      double body = MathAbs(r[i].close - r[i].open);
      double avg = CalcAverageBody(PERIOD_M15, 10, i);
      if(avg <= 0)
         continue;
      if(body < avg * 1.2)
         continue;

      if(r[i].close > r[i].open)
         AddZone(ZONE_OB_BULL, MathMin(r[i].open, r[i].close), MathMax(r[i].open, r[i].close), true, false, "OB_BULL");
      else
         AddZone(ZONE_OB_BEAR, MathMin(r[i].open, r[i].close), MathMax(r[i].open, r[i].close), false, true, "OB_BEAR");
   }
}

bool IsPriceNearZone(double price, const ZoneInfo &zone, double proximityPoints)
{
   if(!zone.active)
      return false;
   double prox = PointsToPrice(proximityPoints);
   return (price >= zone.lower - prox && price <= zone.upper + prox);
}

bool GetNearestValidZone(double price, ENUM_SETUP_DIRECTION dir, ZoneInfo &zoneOut)
{
   bool found = false;
   double bestDist = DBL_MAX;
   datetime now = TimeCurrent();
   int maxAgeSec = MaxZoneAgeBars * PeriodSeconds(PERIOD_M5);

   for(int i = 0; i < g_zoneCount; i++)
   {
      ZoneInfo z = g_zones[i];
      if(!z.active)
         continue;
      if(maxAgeSec > 0 && (now - z.created) > maxAgeSec)
         continue;
      if(dir == DIR_LONG && !z.bullish)
         continue;
      if(dir == DIR_SHORT && !z.bearish)
         continue;

      double center = (z.lower + z.upper) * 0.5;
      double dist = MathAbs(price - center);
      if(dist < bestDist)
      {
         bestDist = dist;
         zoneOut = z;
         found = true;
      }
   }

   return found;
}

bool GetBestZoneForDirection(ENUM_SETUP_DIRECTION dir, ZoneInfo &zoneOut)
{
   double price = GetMidPrice();
   if(price <= 0.0)
      return false;
   return GetNearestValidZone(price, dir, zoneOut);
}

void RefreshZones()
{
   ClearZones();
   BuildPrevDayZones();
   BuildSessionZones();
   BuildAsiaBoxZones();
   BuildSwingZones();
   BuildFVGZones();
   BuildOrderBlockZones();
}

//==================================================================
// SECTION: SIGNAL ENGINE
//==================================================================

bool DetectBullishLiquiditySweep(int shift, double &sweptPrice)
{
   BarData b0;
   BarData b1;
   if(!GetBar(PERIOD_M5, shift, b0) || !GetBar(PERIOD_M5, shift + 1, b1))
      return false;

   bool swept = (b0.low < b1.low && b0.close > b1.low);
   if(swept)
   {
      sweptPrice = b0.low;
      return true;
   }
   return false;
}

bool DetectBearishLiquiditySweep(int shift, double &sweptPrice)
{
   BarData b0;
   BarData b1;
   if(!GetBar(PERIOD_M5, shift, b0) || !GetBar(PERIOD_M5, shift + 1, b1))
      return false;

   bool swept = (b0.high > b1.high && b0.close < b1.high);
   if(swept)
   {
      sweptPrice = b0.high;
      return true;
   }
   return false;
}

bool IsBullishRejectionCandle(int shift)
{
   BarData b;
   if(!GetBar(PERIOD_M5, shift, b))
      return false;
   double body = MathAbs(b.close - b.open);
   if(body <= 0.0)
      return false;
   double lowerWick = MathMin(b.open, b.close) - b.low;
   return (b.close > b.open && lowerWick >= body * 1.2);
}

bool IsBearishRejectionCandle(int shift)
{
   BarData b;
   if(!GetBar(PERIOD_M5, shift, b))
      return false;
   double body = MathAbs(b.close - b.open);
   if(body <= 0.0)
      return false;
   double upperWick = b.high - MathMax(b.open, b.close);
   return (b.close < b.open && upperWick >= body * 1.2);
}

bool IsBullishEngulfing(int shift)
{
   BarData b0;
   BarData b1;
   if(!GetBar(PERIOD_M5, shift, b0) || !GetBar(PERIOD_M5, shift + 1, b1))
      return false;
   return (b1.close < b1.open && b0.close > b0.open && b0.open <= b1.close && b0.close >= b1.open);
}

bool IsBearishEngulfing(int shift)
{
   BarData b0;
   BarData b1;
   if(!GetBar(PERIOD_M5, shift, b0) || !GetBar(PERIOD_M5, shift + 1, b1))
      return false;
   return (b1.close > b1.open && b0.close < b0.open && b0.open >= b1.close && b0.close <= b1.open);
}

bool DetectBullishCHOCH(int shift)
{
   double h = iHigh(g_symbol, PERIOD_M5, shift + 1);
   double c = iClose(g_symbol, PERIOD_M5, shift);
   return (c > h && h > 0.0);
}

bool DetectBearishCHOCH(int shift)
{
   double l = iLow(g_symbol, PERIOD_M5, shift + 1);
   double c = iClose(g_symbol, PERIOD_M5, shift);
   return (c < l && l > 0.0);
}

bool DetectBullishMomentumShift(int shift)
{
   BarData b;
   if(!GetBar(PERIOD_M5, shift, b))
      return false;
   double body = MathAbs(b.close - b.open);
   double avg = CalcAverageBody(PERIOD_M5, 10, shift + 1);
   return (b.close > b.open && avg > 0.0 && body >= avg * ImpulseBodyFactor);
}

bool DetectBearishMomentumShift(int shift)
{
   BarData b;
   if(!GetBar(PERIOD_M5, shift, b))
      return false;
   double body = MathAbs(b.close - b.open);
   double avg = CalcAverageBody(PERIOD_M5, 10, shift + 1);
   return (b.close < b.open && avg > 0.0 && body >= avg * ImpulseBodyFactor);
}

bool IsHTFLayerBiasLong()
{
   if(!InpUseEMALayeredTrade)
      return (g_snap.finalBias == BIAS_BULLISH);
   if(!UpdateIndicatorCaches(false))
      return false;

   bool stacked = (g_cacheM15Fast_1 > g_cacheM15Mid_1 && g_cacheM15Mid_1 > g_cacheM15Slow_1);
   bool rising  = (g_cacheM15Fast_1 > g_cacheM15Fast_lb &&
                   g_cacheM15Mid_1  > g_cacheM15Mid_lb &&
                   g_cacheM15Slow_1 > g_cacheM15Slow_lb);
   return (stacked && rising);
}

bool IsHTFLayerBiasShort()
{
   if(!InpUseEMALayeredTrade)
      return (g_snap.finalBias == BIAS_BEARISH);
   if(!UpdateIndicatorCaches(false))
      return false;

   bool stacked = (g_cacheM15Fast_1 < g_cacheM15Mid_1 && g_cacheM15Mid_1 < g_cacheM15Slow_1);
   bool falling = (g_cacheM15Fast_1 < g_cacheM15Fast_lb &&
                   g_cacheM15Mid_1  < g_cacheM15Mid_lb &&
                   g_cacheM15Slow_1 < g_cacheM15Slow_lb);
   return (stacked && falling);
}

bool IsM5PullbackIntoEMAZone(bool isLong, double &zoneLow, double &zoneHigh)
{
   zoneLow = MathMin(g_cacheM5Fast_1, g_cacheM5Mid_1);
   zoneHigh = MathMax(g_cacheM5Fast_1, g_cacheM5Mid_1);

   BarData b1;
   BarData b2;
   if(!GetBar(PERIOD_M5, 1, b1) || !GetBar(PERIOD_M5, 2, b2))
      return false;

   bool touchedZone = (b1.low <= zoneHigh && b1.high >= zoneLow);
   if(!touchedZone)
      return false;

   if(g_cacheAtrM5_1 <= 0.0)
      return false;

   double zoneMid = (zoneLow + zoneHigh) * 0.5;
   double extDist = MathAbs(b2.close - zoneMid);
   if(extDist > (g_cacheAtrM5_1 * InpMaxExtendedATR))
      return false;

   if(isLong)
      return (b2.close > zoneHigh);
   return (b2.close < zoneLow);
}

bool IsNoTradeEMAState()
{
   if(!UpdateIndicatorCaches(false))
      return true;
   if(g_cacheAtrM5_1 <= 0.0)
      return true;

   double d1 = MathAbs(g_cacheM5Fast_1 - g_cacheM5Mid_1);
   if(d1 <= g_cacheAtrM5_1 * InpNoTradeCompressionATR)
      return true;
   double slopeFast = MathAbs(g_cacheM15Fast_1 - g_cacheM15Fast_lb);
   double slopeMid  = MathAbs(g_cacheM15Mid_1 - g_cacheM15Mid_lb);
   double slopeSlow = MathAbs(g_cacheM15Slow_1 - g_cacheM15Slow_lb);
   if(slopeFast <= g_cacheAtrM5_1 * 0.04 &&
      slopeMid  <= g_cacheAtrM5_1 * 0.03 &&
      slopeSlow <= g_cacheAtrM5_1 * 0.02)
      return true;

   int look = MathMax(3, InpOverlapLookbackBars);
   int minCount = MathMax(1, InpOverlapMinCount);
   double zoneLow = MathMin(g_cacheM5Fast_1, g_cacheM5Mid_1);
   double zoneHigh = MathMax(g_cacheM5Fast_1, g_cacheM5Mid_1);
   int overlapCount = 0;
   for(int i = 1; i <= look; i++)
   {
      BarData b;
      if(!GetBar(PERIOD_M5, i, b))
         break;
      bool straddle = (b.low <= zoneLow && b.high >= zoneHigh);
      if(straddle)
         overlapCount++;
   }
   return (overlapCount >= minCount);
}

bool IsRejectionThenMinorBreakLong()
{
   BarData a;
   BarData b;
   if(!GetBar(PERIOD_M5, 2, a) || !GetBar(PERIOD_M5, 1, b))
      return false;

   double bodyA = MathAbs(a.close - a.open);
   if(bodyA <= 0.0)
      return false;
   double lowerWickA = MathMin(a.open, a.close) - a.low;
   bool rejectionA = (a.close > a.open && lowerWickA >= bodyA * 1.1);
   if(!rejectionA)
      return false;

   double breakPx = a.high + PointsToPrice(InpMinorBreakBufferPoints);
   return (b.close > breakPx && b.close > b.open);
}

bool IsRejectionThenMinorBreakShort()
{
   BarData a;
   BarData b;
   if(!GetBar(PERIOD_M5, 2, a) || !GetBar(PERIOD_M5, 1, b))
      return false;

   double bodyA = MathAbs(a.close - a.open);
   if(bodyA <= 0.0)
      return false;
   double upperWickA = a.high - MathMax(a.open, a.close);
   bool rejectionA = (a.close < a.open && upperWickA >= bodyA * 1.1);
   if(!rejectionA)
      return false;

   double breakPx = a.low - PointsToPrice(InpMinorBreakBufferPoints);
   return (b.close < breakPx && b.close < b.open);
}

SignalInfo EvaluateLayeredLongSetup()
{
   SignalInfo s;
   s.valid = false;
   s.direction = DIR_LONG;
   s.confirmation = CONFIRM_NONE;
   s.sourceZoneType = ZONE_NONE;
   s.signalTime = TimeCurrent();
   s.reason = "LAYER_LONG_REJECT";

   if(!UpdateIndicatorCaches(false))
   {
      s.reason = "INDICATOR_CACHE_FAIL";
      return s;
   }
   if(!IsHTFLayerBiasLong())
   {
      s.reason = "HTF_LAYER_BIAS_FAIL";
      return s;
   }
   if(IsNoTradeEMAState())
   {
      s.reason = "NO_TRADE_EMA_STATE";
      return s;
   }

   double zoneLow = 0.0;
   double zoneHigh = 0.0;
   if(!IsM5PullbackIntoEMAZone(true, zoneLow, zoneHigh))
   {
      s.reason = "PULLBACK_ZONE_FAIL";
      return s;
   }
   if(!IsRejectionThenMinorBreakLong())
   {
      s.reason = "TRIGGER_FAIL";
      return s;
   }

   double entry = GetAsk();
   if(entry <= 0.0)
      entry = iClose(g_symbol, PERIOD_M5, 1);
   SwingPoint sl;
   if(!GetLatestSwingLow(PERIOD_M5, 40, sl))
   {
      s.reason = "NO_SWING_LOW";
      return s;
   }

   double stop = sl.price - PointsToPrice(SLBufferPoints);
   double slPts = PriceToPoints(entry - stop);
   if(slPts < MinSLPoints || slPts > MaxSLPoints)
   {
      s.reason = "SL_INVALID";
      return s;
   }

   s.valid = true;
   s.confirmation = CONFIRM_REJECTION;
   s.sourceZoneType = ZONE_NONE;
   s.entryPrice = NormalizePrice(entry);
   s.stopPrice = NormalizePrice(stop);
   s.referencePrice = zoneLow;
   s.reason = "LAYER_LONG_OK";
   return s;
}

SignalInfo EvaluateLayeredShortSetup()
{
   SignalInfo s;
   s.valid = false;
   s.direction = DIR_SHORT;
   s.confirmation = CONFIRM_NONE;
   s.sourceZoneType = ZONE_NONE;
   s.signalTime = TimeCurrent();
   s.reason = "LAYER_SHORT_REJECT";

   if(!UpdateIndicatorCaches(false))
   {
      s.reason = "INDICATOR_CACHE_FAIL";
      return s;
   }
   if(!IsHTFLayerBiasShort())
   {
      s.reason = "HTF_LAYER_BIAS_FAIL";
      return s;
   }
   if(IsNoTradeEMAState())
   {
      s.reason = "NO_TRADE_EMA_STATE";
      return s;
   }

   double zoneLow = 0.0;
   double zoneHigh = 0.0;
   if(!IsM5PullbackIntoEMAZone(false, zoneLow, zoneHigh))
   {
      s.reason = "PULLBACK_ZONE_FAIL";
      return s;
   }
   if(!IsRejectionThenMinorBreakShort())
   {
      s.reason = "TRIGGER_FAIL";
      return s;
   }

   double entry = GetBid();
   if(entry <= 0.0)
      entry = iClose(g_symbol, PERIOD_M5, 1);
   SwingPoint sh;
   if(!GetLatestSwingHigh(PERIOD_M5, 40, sh))
   {
      s.reason = "NO_SWING_HIGH";
      return s;
   }

   double stop = sh.price + PointsToPrice(SLBufferPoints);
   double slPts = PriceToPoints(stop - entry);
   if(slPts < MinSLPoints || slPts > MaxSLPoints)
   {
      s.reason = "SL_INVALID";
      return s;
   }

   s.valid = true;
   s.confirmation = CONFIRM_REJECTION;
   s.sourceZoneType = ZONE_NONE;
   s.entryPrice = NormalizePrice(entry);
   s.stopPrice = NormalizePrice(stop);
   s.referencePrice = zoneHigh;
   s.reason = "LAYER_SHORT_OK";
   return s;
}

SignalInfo EvaluateLongSetup()
{
   SignalInfo s;
   s.valid = false;
   s.direction = DIR_LONG;
   s.confirmation = CONFIRM_NONE;
   s.sourceZoneType = ZONE_NONE;
   s.signalTime = TimeCurrent();
   s.reason = "LONG_REJECT";

   if(UseHTFBiasFilter && g_snap.finalBias != BIAS_BULLISH)
   {
      s.reason = "BIAS_NOT_BULL";
      return s;
   }

   ZoneInfo z;
   if(!GetBestZoneForDirection(DIR_LONG, z))
   {
      s.reason = "NO_LONG_ZONE";
      return s;
   }

   double price = iClose(g_symbol, PERIOD_M5, 1);
   if(!IsPriceNearZone(price, z, ZoneProximityPoints))
   {
      s.reason = "NOT_NEAR_LONG_ZONE";
      return s;
   }

   double swept = 0.0;
   if(!DetectBullishLiquiditySweep(1, swept))
   {
      s.reason = "NO_BULL_SWEEP";
      return s;
   }

   if(IsBullishRejectionCandle(1))
      s.confirmation = CONFIRM_REJECTION;
   else if(IsBullishEngulfing(1))
      s.confirmation = CONFIRM_ENGULFING;
   else if(DetectBullishCHOCH(1))
      s.confirmation = CONFIRM_CHOCH;
   else if(DetectBullishMomentumShift(1))
      s.confirmation = CONFIRM_MOMENTUM_SHIFT;
   else
   {
      s.reason = "NO_BULL_CONFIRM";
      return s;
   }

   double stop = swept - PointsToPrice(SLBufferPoints);
   double entry = GetAsk();
   if(entry <= 0.0)
      entry = iClose(g_symbol, PERIOD_M5, 1);
   double slPts = PriceToPoints(entry - stop);
   if(slPts < MinSLPoints || slPts > MaxSLPoints)
   {
      s.reason = "SL_INVALID";
      return s;
   }

   s.valid = true;
   s.sourceZoneType = z.type;
   s.entryPrice = NormalizePrice(entry);
   s.stopPrice = NormalizePrice(stop);
   s.referencePrice = swept;
   s.reason = "LONG_OK";
   return s;
}

SignalInfo EvaluateShortSetup()
{
   SignalInfo s;
   s.valid = false;
   s.direction = DIR_SHORT;
   s.confirmation = CONFIRM_NONE;
   s.sourceZoneType = ZONE_NONE;
   s.signalTime = TimeCurrent();
   s.reason = "SHORT_REJECT";

   if(UseHTFBiasFilter && g_snap.finalBias != BIAS_BEARISH)
   {
      s.reason = "BIAS_NOT_BEAR";
      return s;
   }

   ZoneInfo z;
   if(!GetBestZoneForDirection(DIR_SHORT, z))
   {
      s.reason = "NO_SHORT_ZONE";
      return s;
   }

   double price = iClose(g_symbol, PERIOD_M5, 1);
   if(!IsPriceNearZone(price, z, ZoneProximityPoints))
   {
      s.reason = "NOT_NEAR_SHORT_ZONE";
      return s;
   }

   double swept = 0.0;
   if(!DetectBearishLiquiditySweep(1, swept))
   {
      s.reason = "NO_BEAR_SWEEP";
      return s;
   }

   if(IsBearishRejectionCandle(1))
      s.confirmation = CONFIRM_REJECTION;
   else if(IsBearishEngulfing(1))
      s.confirmation = CONFIRM_ENGULFING;
   else if(DetectBearishCHOCH(1))
      s.confirmation = CONFIRM_CHOCH;
   else if(DetectBearishMomentumShift(1))
      s.confirmation = CONFIRM_MOMENTUM_SHIFT;
   else
   {
      s.reason = "NO_BEAR_CONFIRM";
      return s;
   }

   double stop = swept + PointsToPrice(SLBufferPoints);
   double entry = GetBid();
   if(entry <= 0.0)
      entry = iClose(g_symbol, PERIOD_M5, 1);
   double slPts = PriceToPoints(stop - entry);
   if(slPts < MinSLPoints || slPts > MaxSLPoints)
   {
      s.reason = "SL_INVALID";
      return s;
   }

   s.valid = true;
   s.sourceZoneType = z.type;
   s.entryPrice = NormalizePrice(entry);
   s.stopPrice = NormalizePrice(stop);
   s.referencePrice = swept;
   s.reason = "SHORT_OK";
   return s;
}

SignalInfo EvaluateEntrySignal()
{
   SignalInfo s;
   s.valid = false;
   s.direction = DIR_NONE;
   s.confirmation = CONFIRM_NONE;
   s.sourceZoneType = ZONE_NONE;
   s.signalTime = TimeCurrent();
   s.reason = "ENTRY_REJECT";

   if(!g_snap.sessionAllowed)
   {
      s.reason = "SESSION_BLOCK";
      return s;
   }
   if(g_snap.newsLocked)
   {
      s.reason = "NEWS_LOCK";
      return s;
   }
   if(!g_snap.spreadOk)
   {
      s.reason = "SPREAD_BLOCK";
      return s;
   }
   if(!g_snap.marginOk)
   {
      s.reason = "MARGIN_BLOCK";
      return s;
   }

   SignalInfo longSig;
   SignalInfo shortSig;
   if(InpUseEMALayeredTrade)
   {
      longSig = EvaluateLayeredLongSetup();
      shortSig = EvaluateLayeredShortSetup();
   }
   else
   {
      longSig = EvaluateLongSetup();
      shortSig = EvaluateShortSetup();
   }

   bool preferLong = InpUseEMALayeredTrade ? IsHTFLayerBiasLong() : (g_snap.finalBias == BIAS_BULLISH);
   bool preferShort = InpUseEMALayeredTrade ? IsHTFLayerBiasShort() : (g_snap.finalBias == BIAS_BEARISH);
   if(preferLong && longSig.valid)
      return longSig;
   if(preferShort && shortSig.valid)
      return shortSig;

   if(longSig.valid)
      return longSig;
   if(shortSig.valid)
      return shortSig;

   s.reason = longSig.reason + "|" + shortSig.reason;
   return s;
}

SignalInfo EvaluateRecoverySignal()
{
   SignalInfo s;
   s.valid = false;
   s.direction = DIR_NONE;
   s.reason = "RECOVERY_REJECT";

   if(!IsRecoveryAllowed())
   {
      s.reason = "RECOVERY_NOT_ALLOWED";
      return s;
   }

   if(g_cycle.direction == DIR_LONG)
      s = (InpUseEMALayeredTrade ? EvaluateLayeredLongSetup() : EvaluateLongSetup());
   else if(g_cycle.direction == DIR_SHORT)
      s = (InpUseEMALayeredTrade ? EvaluateLayeredShortSetup() : EvaluateShortSetup());

   if(!s.valid)
      return s;

   if(s.direction != g_cycle.direction)
   {
      s.valid = false;
      s.reason = "DIR_MISMATCH";
      return s;
   }

   if(!IsRecoveryPriceImproved(s.direction, s.entryPrice))
   {
      s.valid = false;
      s.reason = "NO_PRICE_IMPROVEMENT";
      return s;
   }

   if(!IsRecoveryDistanceSatisfied(s.direction, s.entryPrice))
   {
      s.valid = false;
      s.reason = "NO_RECOVERY_DISTANCE";
      return s;
   }

   if(!IsRecoveryStillStructurallyValid())
   {
      s.valid = false;
      s.reason = "STRUCTURE_INVALID_RECOVERY";
      return s;
   }

   s.reason = "RECOVERY_SIGNAL_OK";
   return s;
}

//==================================================================
// SECTION: RISK ENGINE
//==================================================================

double CalcRiskMoney(double riskPct)
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq <= 0.0 || riskPct <= 0.0)
      return 0.0;
   return eq * (riskPct / 100.0);
}

double CalcLotsByRisk(double riskMoney, double stopDistancePoints)
{
   if(riskMoney <= 0.0 || stopDistancePoints <= 0.0)
      return 0.0;
   double pointValue = GetPointValuePerLot();
   if(pointValue <= 0.0)
      return 0.0;
   double lots = riskMoney / (stopDistancePoints * pointValue);
   return NormalizeLots(lots);
}

double CalcInitialLotsByMode(double stopDistancePoints, double &riskMoneyOut)
{
   riskMoneyOut = 0.0;
   if(stopDistancePoints <= 0.0)
      return 0.0;

   if(InitialLotMode == INITIAL_LOT_RISK_PERCENT)
   {
      riskMoneyOut = CalcRiskMoney(InitialRiskPct);
      return CalcLotsByRisk(riskMoneyOut, stopDistancePoints);
   }

   double lots = InitialFixedLot;
   if(InitialLotMode == INITIAL_LOT_FIXED_STEP_EQUITY)
   {
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      double stepSize = MathMax(1.0, InitialEquityStepSize);
      int steps = (int)MathFloor(eq / stepSize);
      lots = InitialFixedLot + (steps * InitialStepLotPer1000Equity);
   }

   lots = NormalizeLots(lots);
   double pointValue = GetPointValuePerLot();
   if(pointValue > 0.0)
      riskMoneyOut = stopDistancePoints * pointValue * lots;
   return lots;
}

double GetRecoveryMultiplier(int entryNumber)
{
   if(entryNumber <= 1)
      return RecoveryMultiplier1;
   if(entryNumber == 2)
      return RecoveryMultiplier2;
   if(entryNumber == 3)
      return RecoveryMultiplier3;
   return RecoveryMultiplier3;
}

double CalcPlannedEntryLots(int entryNumber, double stopDistancePoints)
{
   double baseRisk = CalcRiskMoney(InitialRiskPct);
   double rm = baseRisk * GetRecoveryMultiplier(entryNumber);
   return CalcLotsByRisk(rm, stopDistancePoints);
}

double CalcCurrentCycleRiskMoney()
{
   if(!g_cycle.active)
      return 0.0;

   double pointValue = GetPointValuePerLot();
   if(pointValue <= 0.0)
      return 0.0;

   double risk = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(!IsPositionInScopeByMode(sym, magic, REC_SCOPE_OWN_MAGIC_SYMBOL))
         continue;

      double vol = PositionGetDouble(POSITION_VOLUME);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double refStop = g_cycle.protectedInvalidationPrice;
      if(refStop <= 0.0)
      {
         if(g_cycle.direction == DIR_LONG)
            refStop = open - PointsToPrice(MinSLPoints);
         else
            refStop = open + PointsToPrice(MinSLPoints);
      }
      double pts = PriceToPoints(MathAbs(open - refStop));
      risk += (pts * pointValue * vol);
   }

   return risk;
}

double CalcProjectedCycleRiskMoney(const EntryPlan &plan)
{
   return CalcCurrentCycleRiskMoney() + MathMax(0.0, plan.riskMoney);
}

bool WouldExceedCycleRisk(const EntryPlan &plan)
{
   double cap = CalcRiskMoney(CycleRiskPctMax);
   if(cap <= 0.0)
      return true;
   return (CalcProjectedCycleRiskMoney(plan) > cap);
}

bool IsDailyLossLimitHit()
{
   if(g_day.equityAtDayStart <= 0.0)
      return false;

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double loss = g_day.equityAtDayStart - eq;
   double lossPct = (loss / g_day.equityAtDayStart) * 100.0;
   return (lossPct >= DailyLossPct);
}

bool IsFailedCycleLimitHit()
{
   return (g_day.failedCycles >= MaxFailedCyclesPerDay);
}

void ActivateDailyLock(string reason)
{
   if(g_day.dailyLockActive)
      return;
   g_day.dailyLockActive = true;
   g_cycle.state = CYCLE_DAILY_LOCK;
   SetStatusMessage("DAILY_LOCK " + reason, true);
   LogWarn("DAILY_LOCK: " + reason);
}

bool IsMarginSafeForNewEntry(double lots)
{
   if(lots <= 0.0)
      return false;

   double price = GetAsk();
   if(price <= 0.0)
      return false;

   double margin = 0.0;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, g_symbol, lots, price, margin))
      return false;

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(freeMargin <= margin)
      return false;

   double marginLevel = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   if(marginLevel > 0.0 && marginLevel < 130.0)
      return false;

   return true;
}

bool IsSpreadAcceptable()
{
   return (GetCurrentSpreadPoints() <= MaxSpreadPoints);
}

//==================================================================
// SECTION: POSITION / CYCLE ENGINE
//==================================================================

void ResetCycleState()
{
   g_cycle.active = false;
   g_cycle.direction = DIR_NONE;
   g_cycle.state = CYCLE_IDLE;
   g_cycle.cycleId = 0;
   g_cycle.entriesUsed = 0;
   g_cycle.startTime = 0;
   g_cycle.endTime = 0;
   g_cycle.avgEntryPrice = 0.0;
   g_cycle.totalLots = 0.0;
   g_cycle.floatingPnL = 0.0;
   g_cycle.closedPnL = 0.0;
   g_cycle.maxFloatingDD = 0.0;
   g_cycle.protectedInvalidationPrice = 0.0;
   g_cycle.partialTaken = false;
   g_cycle.partialRLevel = 0.0;
   g_cycle.lastTrailUpdateBar = 0;
   g_cycle.lastExitReason = EXIT_NONE;
}

void StartNewCycle(const EntryPlan &plan)
{
   if(plan.direction == DIR_NONE)
      return;
   if(g_cycle.active)
   {
      LogWarn("START_CYCLE_REJECT_ALREADY_ACTIVE");
      return;
   }
   if(g_cycle.direction != DIR_NONE && g_cycle.direction != plan.direction)
   {
      ActivateDailyLock("CYCLE_DIRECTION_IMMUTABLE");
      return;
   }

   g_cycleSequence++;
   g_cycle.active = true;
   g_cycle.direction = plan.direction;
   g_cycle.state = CYCLE_ENTRY_PLACED;
   g_cycle.cycleId = g_cycleSequence;
   g_cycle.entriesUsed = 0;
   g_cycle.startTime = TimeCurrent();
   g_cycle.endTime = 0;
   g_cycle.avgEntryPrice = plan.entryPrice;
   g_cycle.totalLots = 0.0;
   g_cycle.floatingPnL = 0.0;
   g_cycle.closedPnL = 0.0;
   g_cycle.maxFloatingDD = 0.0;
   g_cycle.protectedInvalidationPrice = plan.stopLoss;
   g_cycle.partialTaken = false;
   g_cycle.partialRLevel = 0.0;
   g_cycle.lastTrailUpdateBar = 0;
   g_cycle.lastExitReason = EXIT_NONE;

   g_day.cyclesTaken++;
}

void MarkCycleEntryPlaced(const EntryPlan &plan)
{
   if(!g_cycle.active)
      StartNewCycle(plan);
   if(!g_cycle.active)
      return;
   if(plan.direction != g_cycle.direction)
   {
      ActivateDailyLock("ENTRY_DIRECTION_MISMATCH");
      return;
   }

   g_cycle.entriesUsed = MathMin(MaxEntriesPerCycle, MathMax(g_cycle.entriesUsed, plan.entryNumber));
   g_cycle.state = (plan.entryNumber <= 1 ? CYCLE_ACTIVE : CYCLE_RECOVERY_PLACED);
   if(plan.stopLoss > 0.0)
   {
      if(g_cycle.direction == DIR_LONG)
         g_cycle.protectedInvalidationPrice = (g_cycle.protectedInvalidationPrice <= 0.0 ? plan.stopLoss : MathMin(g_cycle.protectedInvalidationPrice, plan.stopLoss));
      else if(g_cycle.direction == DIR_SHORT)
         g_cycle.protectedInvalidationPrice = (g_cycle.protectedInvalidationPrice <= 0.0 ? plan.stopLoss : MathMax(g_cycle.protectedInvalidationPrice, plan.stopLoss));
   }
   g_lastTradeBarTime = iTime(g_symbol, PERIOD_M5, 0);
   SyncCycleFromOpenPositions();
}

void FinalizeClosedCycle(ENUM_EXIT_REASON reason)
{
   g_cycle.lastExitReason = reason;
   g_cycle.endTime = TimeCurrent();

   if(g_cycle.closedPnL + g_cycle.floatingPnL < 0.0)
      g_day.failedCycles++;

   g_cycle.active = false;
   int coolBars = (g_cycle.closedPnL < 0.0 ? CooldownAfterLossBars : CooldownBars);
   if(coolBars > 0)
      g_cycle.state = CYCLE_COOLDOWN;
   else
      g_cycle.state = CYCLE_IDLE;

   g_lastTradeBarTime = iTime(g_symbol, PERIOD_M5, 0);
}

bool IsCycleActive()
{
   return g_cycle.active;
}

bool IsCycleInCooldown()
{
   if(g_cycle.state != CYCLE_COOLDOWN)
      return false;

   if(g_lastTradeBarTime == 0)
      return false;

   int barsSince = iBarShift(g_symbol, PERIOD_M5, g_lastTradeBarTime, false);
   int need = (g_cycle.closedPnL < 0.0 ? CooldownAfterLossBars : CooldownBars);
   if(need <= 0)
      return false;
   return (barsSince >= 0 && barsSince < need);
}

int CountOpenPositionsByMagicSymbol()
{
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(!IsPositionInScopeByMode(sym, magic, REC_SCOPE_OWN_MAGIC_SYMBOL))
         continue;
      c++;
   }
   return c;
}

bool GetOpenPositionTickets(ulong &tickets[], int &count)
{
   ArrayResize(tickets, 0);
   count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(!IsPositionInScopeByMode(sym, magic, REC_SCOPE_OWN_MAGIC_SYMBOL))
         continue;

      int newSize = count + 1;
      ArrayResize(tickets, newSize);
      tickets[count] = ticket;
      count++;
      if(count >= MAX_POS_TICKETS)
         break;
   }

   return (count > 0);
}

double CalcOpenLots()
{
   double lots = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(!IsPositionInScopeByMode(sym, magic, REC_SCOPE_OWN_MAGIC_SYMBOL))
         continue;
      lots += PositionGetDouble(POSITION_VOLUME);
   }
   return lots;
}

double CalcBasketFloatingPnL()
{
   double p = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(!IsPositionInScopeByMode(sym, magic, REC_SCOPE_OWN_MAGIC_SYMBOL))
         continue;
      p += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return p;
}

double CalcBasketAvgEntryPrice()
{
   double volSum = 0.0;
   double pxVol = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(!IsPositionInScopeByMode(sym, magic, REC_SCOPE_OWN_MAGIC_SYMBOL))
         continue;

      long type = PositionGetInteger(POSITION_TYPE);
      double vol = PositionGetDouble(POSITION_VOLUME);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      int sign = (type == POSITION_TYPE_BUY ? 1 : -1);
      volSum += sign * vol;
      pxVol += sign * vol * open;
   }

   if(MathAbs(volSum) < 1e-9)
      return 0.0;
   return NormalizePrice(pxVol / volSum);
}

double CalcBasketWorstSLDistancePoints()
{
   double worst = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(!IsPositionInScopeByMode(sym, magic, REC_SCOPE_OWN_MAGIC_SYMBOL))
         continue;

      long type = PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      if(sl <= 0.0)
         continue;

      double pts = 0.0;
      if(type == POSITION_TYPE_BUY)
         pts = PriceToPoints(open - sl);
      else
         pts = PriceToPoints(sl - open);
      worst = MathMax(worst, pts);
   }

   return worst;
}

void SyncCycleFromOpenPositions()
{
   int count = CountOpenPositionsByMagicSymbol();
   if(count <= 0)
   {
      if(g_cycle.active)
      {
         g_cycle.floatingPnL = 0.0;
         g_cycle.totalLots = 0.0;
         g_cycle.avgEntryPrice = 0.0;
         g_cycle.entriesUsed = 0;
         g_cycle.active = false;
         g_cycle.direction = DIR_NONE;
         if(g_cycle.state != CYCLE_COOLDOWN && g_cycle.state != CYCLE_DAILY_LOCK)
            g_cycle.state = CYCLE_IDLE;
      }
      return;
   }

   double buyLots = 0.0;
   double sellLots = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(!IsPositionInScopeByMode(sym, magic, REC_SCOPE_OWN_MAGIC_SYMBOL))
         continue;

      long type = PositionGetInteger(POSITION_TYPE);
      double vol = PositionGetDouble(POSITION_VOLUME);
      if(type == POSITION_TYPE_BUY)
         buyLots += vol;
      else if(type == POSITION_TYPE_SELL)
         sellLots += vol;
   }

   g_cycle.totalLots = CalcOpenLots();
   g_cycle.avgEntryPrice = CalcBasketAvgEntryPrice();
   g_cycle.floatingPnL = CalcBasketFloatingPnL();

   if(!g_cycle.active)
   {
      g_cycleSequence++;
      g_cycle.active = true;
      g_cycle.cycleId = g_cycleSequence;
      g_cycle.startTime = TimeCurrent();
      g_cycle.state = CYCLE_ACTIVE;
      g_day.cyclesTaken++;
      g_cycle.partialTaken = false;
      g_cycle.partialRLevel = 0.0;
      g_cycle.lastTrailUpdateBar = 0;
   }

   ENUM_SETUP_DIRECTION detected = DIR_NONE;
   if(buyLots > sellLots)
      detected = DIR_LONG;
   else if(sellLots > buyLots)
      detected = DIR_SHORT;

   g_cycle.entriesUsed = MathMin(MaxEntriesPerCycle, count);
   if(detected == DIR_NONE)
   {
      ActivateDailyLock("MIXED_DIRECTION_POSITIONS");
      return;
   }
   if(g_cycle.direction == DIR_NONE)
      g_cycle.direction = detected;
   else if(g_cycle.direction != detected)
      ActivateDailyLock("CYCLE_DIRECTION_CONFLICT");
}

//==================================================================
// SECTION: RECOVERY ENGINE
//==================================================================

bool IsRecoveryAllowed()
{
   if(!EnableRecovery)
   {
      SetStatusMessage("RECOVERY_DISABLED");
      return false;
   }
   if(g_day.dailyLockActive)
   {
      SetStatusMessage("RECOVERY_BLOCK_DAILY_LOCK", true);
      return false;
   }

   RefreshRecoveryScopeStats(false);
   double trigger = MathMax(0.0, RecoveryStartDDMoney);
   if(trigger > 0.0 && g_scopeDDMoney < trigger)
   {
      SetStatusMessage("RECOVERY_WAIT_DD " + DoubleToString(g_scopeDDMoney, 2) + "/" + DoubleToString(trigger, 2));
      return false;
   }

   if(!g_cycle.active)
   {
      SetStatusMessage("RECOVERY_NEEDS_ACTIVE_CYCLE");
      return false;
   }

   int used = CountOpenPositionsByMagicSymbol();
   g_cycle.entriesUsed = MathMin(MaxEntriesPerCycle, used);
   if(used <= 0)
   {
      SetStatusMessage("RECOVERY_WAIT_ACTIVE_POSITIONS");
      return false;
   }

   double buyLots = 0.0;
   double sellLots = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(!IsPositionInScopeByMode(sym, magic, REC_SCOPE_OWN_MAGIC_SYMBOL))
         continue;
      long type = PositionGetInteger(POSITION_TYPE);
      double vol = PositionGetDouble(POSITION_VOLUME);
      if(type == POSITION_TYPE_BUY)
         buyLots += vol;
      else if(type == POSITION_TYPE_SELL)
         sellLots += vol;
   }

   ENUM_SETUP_DIRECTION liveDir = DIR_NONE;
   if(buyLots > sellLots)
      liveDir = DIR_LONG;
   else if(sellLots > buyLots)
      liveDir = DIR_SHORT;

   if(liveDir == DIR_NONE)
   {
      SetStatusMessage("RECOVERY_BLOCK_MIXED_DIRECTION");
      return false;
   }

   if(g_cycle.direction == DIR_NONE)
      g_cycle.direction = liveDir;
   else if(g_cycle.direction != liveDir)
   {
      ActivateDailyLock("RECOVERY_DIRECTION_CONFLICT");
      return false;
   }

   if(g_cycle.direction != DIR_LONG && g_cycle.direction != DIR_SHORT)
   {
      SetStatusMessage("RECOVERY_WAIT_SCOPE_DIRECTION");
      return false;
   }
   if(used >= MaxEntriesPerCycle)
   {
      SetStatusMessage("RECOVERY_BLOCK_MAX_ENTRIES");
      return false;
   }
   if(!IsMarketSafeForRecovery())
   {
      SetStatusMessage("RECOVERY_BLOCK_MARKET_UNSAFE");
      return false;
   }
   if(g_cycle.active && IsCycleInCooldown())
   {
      SetStatusMessage("RECOVERY_BLOCK_COOLDOWN");
      return false;
   }

   SetStatusMessage("RECOVERY_ALLOWED", true);
   return true;
}

bool IsRecoveryPriceImproved(ENUM_SETUP_DIRECTION dir, double candidatePrice)
{
   if(g_cycle.avgEntryPrice <= 0.0)
      return true;

   double minImprove = PointsToPrice(5.0);
   if(dir == DIR_LONG)
      return (candidatePrice < (g_cycle.avgEntryPrice - minImprove));
   if(dir == DIR_SHORT)
      return (candidatePrice > (g_cycle.avgEntryPrice + minImprove));
   return false;
}

bool IsRecoveryDistanceSatisfied(ENUM_SETUP_DIRECTION dir, double candidatePrice)
{
   if(g_cycle.avgEntryPrice <= 0.0)
      return true;

   double distPts = PriceToPoints(MathAbs(candidatePrice - g_cycle.avgEntryPrice));
   double required = MinRecoveryDistancePoints;

   if(UseATRRecoveryDistance)
   {
      double atr = g_snap.atrM5;
      if(atr <= 0.0)
         atr = CalcATR(PERIOD_M5, ATRPeriod, 1);
      if(atr > 0.0)
         required = MathMax(required, PriceToPoints(atr * RecoveryATRMultiplier));
   }

   return (distPts >= required);
}

bool IsRecoveryStillStructurallyValid()
{
   if(g_cycle.direction == DIR_LONG)
      return (g_snap.finalBias != BIAS_BEARISH && !IsStructureInvalidated());
   if(g_cycle.direction == DIR_SHORT)
      return (g_snap.finalBias != BIAS_BULLISH && !IsStructureInvalidated());
   return false;
}

void EvaluateRecoveryEntry()
{
   if(!IsRecoveryAllowed())
      return;

   SignalInfo sig = EvaluateRecoverySignal();
   LogSignalDecision(sig);
   if(!sig.valid)
   {
      SetStatusMessage("RECOVERY_SIGNAL_REJECT " + sig.reason);
      return;
   }

   EntryPlan plan = BuildRecoveryPlan(sig);
   if(!ValidateEntryPlan(plan))
   {
      SetStatusMessage("RECOVERY_PLAN_INVALID");
      return;
   }

   if(WouldExceedCycleRisk(plan))
   {
      LogWarn("RECOVERY_BLOCK_RISK_CAP");
      SetStatusMessage("RECOVERY_BLOCK_RISK_CAP");
      return;
   }

   ulong ticket = 0;
   if(PlaceEntryOrder(plan, ticket))
   {
      MarkCycleEntryPlaced(plan);
      g_cycle.state = CYCLE_RECOVERY_PLACED;
      LogTrade("RECOVERY_ENTRY ticket=" + (string)ticket);
      SetStatusMessage("RECOVERY_ENTRY_PLACED #" + (string)plan.entryNumber, true);
   }
}

//==================================================================
// SECTION: EXIT ENGINE
//==================================================================

double CalcCycleRMultiple()
{
   if(!g_cycle.active || g_cycle.totalLots <= 0.0 || g_cycle.protectedInvalidationPrice <= 0.0)
      return 0.0;

   double riskPts = PriceToPoints(MathAbs(g_cycle.avgEntryPrice - g_cycle.protectedInvalidationPrice));
   if(riskPts <= 0.0)
      return 0.0;

   double pointValue = GetPointValuePerLot();
   if(pointValue <= 0.0)
      return 0.0;

   double oneRMoney = riskPts * pointValue * g_cycle.totalLots;
   if(oneRMoney <= 0.0)
      return 0.0;

   return (g_cycle.floatingPnL + g_cycle.closedPnL) / oneRMoney;
}

bool ExecutePartialAt1R()
{
   if(!InpEnablePartialTrail || g_cycle.partialTaken || !g_cycle.active)
      return false;
   if(CalcCycleRMultiple() < 1.0)
      return false;

   ulong tickets[];
   int count = 0;
   if(!GetOpenPositionTickets(tickets, count))
      return false;

   bool did = false;
   double pct = MathMax(1.0, MathMin(99.0, InpPartialClosePercent)) * 0.01;
   for(int i = 0; i < count; i++)
   {
      if(!PositionSelectByTicket(tickets[i]))
         continue;
      double vol = PositionGetDouble(POSITION_VOLUME);
      double closeLots = vol * pct;
      if(ClosePartialByTicket(tickets[i], closeLots))
         did = true;
   }

   if(did)
   {
      g_cycle.partialTaken = true;
      g_cycle.partialRLevel = 1.0;
      SyncCycleFromOpenPositions();
      LogTrade("PARTIAL_1R_DONE");
      SetStatusMessage("PARTIAL_1R_DONE", true);
   }
   return did;
}

bool UpdateSwingTrailStop()
{
   if(!InpEnablePartialTrail || !g_cycle.active || !g_cycle.partialTaken)
      return false;
   if(!g_newBarM5)
      return false;

   datetime bar1 = iTime(g_symbol, PERIOD_M5, 1);
   if(bar1 <= 0 || g_cycle.lastTrailUpdateBar == bar1)
      return false;

   SwingPoint sp;
   double newStop = 0.0;
   if(g_cycle.direction == DIR_LONG)
   {
      if(!GetLatestSwingLow(PERIOD_M5, 60, sp))
         return false;
      newStop = sp.price - PointsToPrice(InpTrailSwingBufferPoints);
   }
   else if(g_cycle.direction == DIR_SHORT)
   {
      if(!GetLatestSwingHigh(PERIOD_M5, 60, sp))
         return false;
      newStop = sp.price + PointsToPrice(InpTrailSwingBufferPoints);
   }
   else
      return false;

   bool changed = false;
   ulong tickets[];
   int count = 0;
   if(!GetOpenPositionTickets(tickets, count))
      return false;

   for(int i = 0; i < count; i++)
   {
      if(!PositionSelectByTicket(tickets[i]))
         continue;
      long type = PositionGetInteger(POSITION_TYPE);
      double curSL = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);

      if(type == POSITION_TYPE_BUY && g_cycle.direction == DIR_LONG)
      {
         if(curSL <= 0.0 || newStop > curSL + PointsToPrice(2.0))
         {
            if(ModifyPositionSLTP(tickets[i], NormalizePrice(newStop), tp))
               changed = true;
         }
      }
      else if(type == POSITION_TYPE_SELL && g_cycle.direction == DIR_SHORT)
      {
         if(curSL <= 0.0 || newStop < curSL - PointsToPrice(2.0))
         {
            if(ModifyPositionSLTP(tickets[i], NormalizePrice(newStop), tp))
               changed = true;
         }
      }
   }

   if(changed)
   {
      g_cycle.lastTrailUpdateBar = bar1;
      LogTrade("TRAIL_SWING_UPDATED");
      SetStatusMessage("TRAIL_SWING_UPDATED");
   }
   return changed;
}

void MaybeHandlePartialAndTrail()
{
   if(!g_cycle.active || !InpEnablePartialTrail)
      return;
   ExecutePartialAt1R();
   UpdateSwingTrailStop();
}

bool IsBasketTargetHit()
{
   if(!UseBasketTP)
      return false;
   if(InpEnablePartialTrail)
      return false;

   double baseRisk = CalcRiskMoney(InitialRiskPct);
   double target = baseRisk * BasketTargetR;
   double net = g_cycle.floatingPnL + g_cycle.closedPnL;
   return (net >= target);
}

bool IsNetPositiveCloseConditionHit()
{
   if(!CloseBasketAtNetPositive)
      return false;
   return (g_cycle.floatingPnL >= MinNetProfitToClose);
}

bool IsCycleTimeStopHit()
{
   if(!g_cycle.active || g_cycle.startTime <= 0 || MaxBarsInCycle <= 0)
      return false;

   int bars = iBarShift(g_symbol, PERIOD_M5, g_cycle.startTime, false);
   return (bars >= MaxBarsInCycle);
}

bool IsStructureInvalidated()
{
   if(!g_cycle.active || g_cycle.protectedInvalidationPrice <= 0.0)
      return false;

   double close1 = iClose(g_symbol, PERIOD_M5, 1);
   if(g_cycle.direction == DIR_LONG)
      return (close1 < g_cycle.protectedInvalidationPrice);
   if(g_cycle.direction == DIR_SHORT)
      return (close1 > g_cycle.protectedInvalidationPrice);
   return false;
}

bool IsCycleRiskStopHit()
{
   double cap = CalcRiskMoney(CycleRiskPctMax);
   if(cap <= 0.0)
      return false;
   return (g_cycle.floatingPnL <= -cap);
}

bool ShouldExitCycle(ENUM_EXIT_REASON &reasonOut)
{
   reasonOut = EXIT_NONE;

   if(g_day.dailyLockActive)
   {
      reasonOut = EXIT_DAILY_LOCK;
      return true;
   }

   if(ShouldForceFlatForNews())
   {
      reasonOut = EXIT_NEWS_FLAT;
      return true;
   }

   if(!g_snap.marginOk)
   {
      reasonOut = EXIT_MARGIN_PROTECTION;
      return true;
   }

   if(IsCycleRiskStopHit())
   {
      reasonOut = EXIT_CYCLE_RISK_STOP;
      return true;
   }

   if(IsStructureInvalidated())
   {
      reasonOut = EXIT_STRUCTURE_INVALIDATION;
      return true;
   }

   if(IsCycleTimeStopHit())
   {
      reasonOut = EXIT_TIME_STOP;
      return true;
   }

   if(IsBasketTargetHit())
   {
      reasonOut = EXIT_BASKET_TP;
      return true;
   }

   if(IsNetPositiveCloseConditionHit())
   {
      reasonOut = EXIT_BASKET_TP;
      return true;
   }

   return false;
}

bool CloseAllCyclePositions(ENUM_EXIT_REASON reason)
{
   ulong tickets[];
   int count = 0;
   GetOpenPositionTickets(tickets, count);
   if(count <= 0)
      return true;

   bool ok = true;
   for(int i = 0; i < count; i++)
   {
      if(!ClosePositionByTicket(tickets[i]))
         ok = false;
   }

   if(ok)
      g_cycle.lastExitReason = reason;

   return ok;
}

void ManageActiveCycle()
{
   if(!g_cycle.active)
      return;

   SyncCycleFromOpenPositions();
   g_cycle.floatingPnL = CalcBasketFloatingPnL();
   if(g_cycle.floatingPnL < g_cycle.maxFloatingDD)
      g_cycle.maxFloatingDD = g_cycle.floatingPnL;
   MaybeHandlePartialAndTrail();

   ENUM_EXIT_REASON reason = EXIT_NONE;
   if(ShouldExitCycle(reason))
   {
      g_cycle.state = CYCLE_EXIT_PENDING;
      SetStatusMessage("EXIT_PENDING reason=" + (string)reason, true);
      if(CloseAllCyclePositions(reason))
      {
         SyncCycleFromOpenPositions();
         g_cycle.closedPnL += g_cycle.floatingPnL;
         FinalizeClosedCycle(reason);
         SetStatusMessage("CYCLE_EXIT_DONE reason=" + (string)reason, true);
      }
   }
}

//==================================================================
// SECTION: EXECUTION ENGINE
//==================================================================

EntryPlan BuildInitialEntryPlan(const SignalInfo &sig)
{
   EntryPlan p;
   p.valid = false;

   if(!sig.valid)
      return p;

   double slPts = 0.0;
   if(sig.direction == DIR_LONG)
      slPts = PriceToPoints(sig.entryPrice - sig.stopPrice);
   else if(sig.direction == DIR_SHORT)
      slPts = PriceToPoints(sig.stopPrice - sig.entryPrice);

   slPts = MathAbs(slPts);
   if(slPts < MinSLPoints || slPts > MaxSLPoints)
      return p;

   p.valid = true;
   p.direction = sig.direction;
   p.entryNumber = 1;
   p.lotSize = CalcInitialLotsByMode(slPts, p.riskMoney);
   p.entryPrice = sig.entryPrice;
   p.stopLoss = sig.stopPrice;

   double tpDist = slPts * MathMax(0.1, BasketTargetR);
   if(p.direction == DIR_LONG)
      p.takeProfit = NormalizePrice(p.entryPrice + PointsToPrice(tpDist));
   else
      p.takeProfit = NormalizePrice(p.entryPrice - PointsToPrice(tpDist));

   p.comment = "CR_INIT";
   return p;
}

EntryPlan BuildRecoveryPlan(const SignalInfo &sig)
{
   EntryPlan p;
   p.valid = false;

   if(!sig.valid)
      return p;

   int entryNumber = g_cycle.entriesUsed + 1;
   double slPts = 0.0;

   if(sig.direction == DIR_LONG)
      slPts = PriceToPoints(sig.entryPrice - sig.stopPrice);
   else if(sig.direction == DIR_SHORT)
      slPts = PriceToPoints(sig.stopPrice - sig.entryPrice);

   slPts = MathAbs(slPts);
   if(slPts < MinSLPoints || slPts > MaxSLPoints)
      return p;

   p.valid = true;
   p.direction = sig.direction;
   p.entryNumber = entryNumber;
   p.riskMoney = CalcRiskMoney(InitialRiskPct) * GetRecoveryMultiplier(entryNumber);
   p.lotSize = CalcPlannedEntryLots(entryNumber, slPts);
   p.entryPrice = sig.entryPrice;
   p.stopLoss = sig.stopPrice;

   double tpDist = slPts * MathMax(0.1, BasketTargetR);
   if(p.direction == DIR_LONG)
      p.takeProfit = NormalizePrice(p.entryPrice + PointsToPrice(tpDist));
   else
      p.takeProfit = NormalizePrice(p.entryPrice - PointsToPrice(tpDist));

   p.comment = "CR_REC_" + (string)entryNumber;
   return p;
}

bool ValidateEntryPlan(const EntryPlan &plan)
{
   if(!plan.valid)
      return false;
   if(plan.direction == DIR_NONE)
      return false;
   if(plan.lotSize <= 0.0)
      return false;
   if(plan.stopLoss <= 0.0)
      return false;
   if(!IsSpreadAcceptable())
      return false;
   if(!IsMarginSafeForNewEntry(plan.lotSize))
      return false;

   if(plan.direction == DIR_LONG && plan.stopLoss >= plan.entryPrice)
      return false;
   if(plan.direction == DIR_SHORT && plan.stopLoss <= plan.entryPrice)
      return false;

   double stopPts = MathAbs(PriceToPoints(plan.entryPrice - plan.stopLoss));
   if(stopPts < MinSLPoints || stopPts > MaxSLPoints)
      return false;

   int stopsLevel = (int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freezeLevel = (int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double minDist = MathMax(stopsLevel, freezeLevel) + 5;
   if(stopPts < minDist)
      return false;

   return true;
}

bool PlaceMarketOrder(const EntryPlan &plan, ulong &ticketOut)
{
   ticketOut = 0;
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(20);

   bool ok = false;
   if(plan.direction == DIR_LONG)
      ok = g_trade.Buy(plan.lotSize, g_symbol, 0.0, plan.stopLoss, plan.takeProfit, plan.comment);
   else if(plan.direction == DIR_SHORT)
      ok = g_trade.Sell(plan.lotSize, g_symbol, 0.0, plan.stopLoss, plan.takeProfit, plan.comment);

   if(!ok)
   {
      LogError("ORDER_FAIL ret=" + (string)g_trade.ResultRetcode() + " msg=" + g_trade.ResultRetcodeDescription());
      return false;
   }

   long rc = g_trade.ResultRetcode();
   if(rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_DONE_PARTIAL && rc != TRADE_RETCODE_PLACED)
   {
      LogError("ORDER_RETCODE_BAD=" + (string)rc);
      return false;
   }

   ticketOut = g_trade.ResultOrder();
   return true;
}

bool PlaceEntryOrder(const EntryPlan &plan, ulong &ticketOut)
{
   return PlaceMarketOrder(plan, ticketOut);
}

bool ClosePositionByTicket(ulong ticket)
{
   if(ticket == 0)
      return false;
   if(!PositionSelectByTicket(ticket))
      return false;

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(30);
   bool ok = g_trade.PositionClose(ticket);
   if(!ok)
      return false;

   long rc = g_trade.ResultRetcode();
   return (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL || rc == TRADE_RETCODE_PLACED);
}

bool ClosePartialByTicket(ulong ticket, double closeLots)
{
   if(ticket == 0 || closeLots <= 0.0)
      return false;
   if(!PositionSelectByTicket(ticket))
      return false;

   double volume = PositionGetDouble(POSITION_VOLUME);
   double minV = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   double step = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      step = minV;
   if(volume <= minV || closeLots >= volume)
      return false;

   closeLots = NormalizeLots(closeLots);
   if(closeLots < minV)
      return false;
   if((volume - closeLots) < minV)
      closeLots = NormalizeLots(volume - minV);
   if(closeLots < minV)
      return false;

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(30);
   bool ok = g_trade.PositionClosePartial(ticket, closeLots);
   if(!ok)
      return false;

   long rc = g_trade.ResultRetcode();
   return (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL || rc == TRADE_RETCODE_PLACED);
}

bool ModifyPositionSLTP(ulong ticket, double sl, double tp)
{
   if(ticket == 0)
      return false;
   if(!PositionSelectByTicket(ticket))
      return false;

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   return g_trade.PositionModify(ticket, sl, tp);
}

bool ApplySharedBasketStop(double stopPrice)
{
   ulong tickets[];
   int count = 0;
   if(!GetOpenPositionTickets(tickets, count))
      return false;

   bool ok = true;
   for(int i = 0; i < count; i++)
   {
      if(!PositionSelectByTicket(tickets[i]))
         continue;
      double tp = PositionGetDouble(POSITION_TP);
      if(!ModifyPositionSLTP(tickets[i], stopPrice, tp))
         ok = false;
   }

   return ok;
}

//==================================================================
// SECTION: DAILY STATE / MASTER CONTROL
//==================================================================

datetime DayStart(datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   return StructToTime(dt);
}

void ResetDailyStats()
{
   g_day.tradeDay = DayStart(TimeCurrent());
   g_day.cyclesTaken = 0;
   g_day.failedCycles = 0;
   g_day.closedPnL = 0.0;
   g_day.floatingPnL = 0.0;
   g_day.equityAtDayStart = AccountInfoDouble(ACCOUNT_EQUITY);
   g_day.dailyLockActive = false;
}

void RefreshDailyState()
{
   static int s_dailyScanCounter = 0;
   datetime today = DayStart(TimeCurrent());
   if(g_day.tradeDay != today)
   {
      ResetDailyStats();
      s_dailyScanCounter = 0;
   }

   g_day.floatingPnL = CalcBasketFloatingPnL();

   bool doFullScan = true;
   if(g_isTester && InpAggressiveTesterMode)
   {
      s_dailyScanCounter++;
      doFullScan = ((s_dailyScanCounter % 12) == 0);
   }

   if(doFullScan)
   {
      g_day.closedPnL = 0.0;
      if(HistorySelect(g_day.tradeDay, TimeCurrent()))
      {
         int deals = HistoryDealsTotal();
         for(int i = 0; i < deals; i++)
         {
            ulong deal = HistoryDealGetTicket(i);
            if(deal == 0)
               continue;

            string sym = HistoryDealGetString(deal, DEAL_SYMBOL);
            long magic = HistoryDealGetInteger(deal, DEAL_MAGIC);
            long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
            if(sym != g_symbol || magic != InpMagicNumber || entry != DEAL_ENTRY_OUT)
               continue;

            g_day.closedPnL += HistoryDealGetDouble(deal, DEAL_PROFIT);
            g_day.closedPnL += HistoryDealGetDouble(deal, DEAL_SWAP);
            g_day.closedPnL += HistoryDealGetDouble(deal, DEAL_COMMISSION);
         }
      }
   }

   if(IsDailyLossLimitHit())
      ActivateDailyLock("DAILY_LOSS_LIMIT");
   if(IsFailedCycleLimitHit())
      ActivateDailyLock("FAILED_CYCLE_LIMIT");
}

void UpdateRuntimeFlags()
{
   g_newBarM5 = IsNewBar(PERIOD_M5, g_lastM5BarTime);
   g_snap.currentSpreadPoints = GetCurrentSpreadPoints();
}

void RefreshMarketSnapshot()
{
   UpdateIndicatorCaches(g_newBarM5);
   g_snap.atrM5 = (g_cacheAtrM5_1 > 0.0 ? g_cacheAtrM5_1 : CalcATR(PERIOD_M5, ATRPeriod, 1));
   if(g_newBarM5 || g_snap.avgBodyM5 <= 0.0)
      g_snap.avgBodyM5 = CalcAverageBody(PERIOD_M5, 14, 1);
   g_snap.currentSpreadPoints = GetCurrentSpreadPoints();
   g_snap.sessionAllowed = IsSessionAllowed() && !IsBrokerRolloverWindow();
   g_snap.newsLocked = IsNewsLockActive();
   g_snap.spreadOk = IsSpreadAcceptable();
   g_snap.marginOk = IsMarginSafeForNewEntry(SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN));

   if(InpUseEMALayeredTrade)
   {
      bool longBias = IsHTFLayerBiasLong();
      bool shortBias = IsHTFLayerBiasShort();
      g_snap.biasM15 = (longBias ? BIAS_BULLISH : (shortBias ? BIAS_BEARISH : BIAS_NEUTRAL));
      g_snap.biasH1 = g_snap.biasM15;
      g_snap.finalBias = g_snap.biasM15;
   }
   else
   {
      if(g_newBarM5 || g_snap.finalBias == BIAS_NEUTRAL)
      {
         g_snap.biasM15 = DetectStructureBias(BiasTF1, 80);
         g_snap.biasH1 = DetectStructureBias(BiasTF2, 80);
         g_snap.finalBias = GetFinalBias();
      }
   }
   g_snap.marketState = DetectMarketState();
}

void EvaluateNewCycleEntry()
{
   if(g_day.dailyLockActive)
   {
      SetStatusMessage("ENTRY_BLOCK_DAILY_LOCK");
      return;
   }
   if(IsCycleInCooldown())
   {
      SetStatusMessage("ENTRY_BLOCK_COOLDOWN");
      return;
   }

   SignalInfo sig = EvaluateEntrySignal();
   LogSignalDecision(sig);
   if(!sig.valid)
   {
      SetStatusMessage("ENTRY_SIGNAL_REJECT " + sig.reason);
      return;
   }

   EntryPlan plan = BuildInitialEntryPlan(sig);
   LogEntryPlan(plan);

   if(!ValidateEntryPlan(plan))
   {
      LogWarn("ENTRY_PLAN_INVALID");
      SetStatusMessage("ENTRY_PLAN_INVALID");
      return;
   }

   if(WouldExceedCycleRisk(plan))
   {
      LogWarn("ENTRY_BLOCK_CYCLE_RISK");
      SetStatusMessage("ENTRY_BLOCK_CYCLE_RISK");
      return;
   }

   ulong ticket = 0;
   if(PlaceEntryOrder(plan, ticket))
   {
      StartNewCycle(plan);
      MarkCycleEntryPlaced(plan);
      LogTrade("ENTRY_PLACED ticket=" + (string)ticket);
      SetStatusMessage("ENTRY_PLACED " + (plan.direction == DIR_LONG ? "LONG" : "SHORT"), true);
   }
}

void RestoreRuntimeStateFromTerminal()
{
   SyncCycleFromOpenPositions();
   if(!g_cycle.active)
      ResetCycleState();
}

//==================================================================
// SECTION: LOGGING / DIAGNOSTICS / OVERLAY
//==================================================================

string BiasToStr(ENUM_BIAS_STATE b)
{
   if(b == BIAS_BULLISH)
      return "BULL";
   if(b == BIAS_BEARISH)
      return "BEAR";
   return "NEUTRAL";
}

string StateToStr(ENUM_CYCLE_STATE s)
{
   if(s == CYCLE_IDLE) return "IDLE";
   if(s == CYCLE_SETUP_DETECTED) return "SETUP";
   if(s == CYCLE_ENTRY_PLACED) return "ENTRY_PLACED";
   if(s == CYCLE_ACTIVE) return "ACTIVE";
   if(s == CYCLE_RECOVERY_ELIGIBLE) return "REC_ELIGIBLE";
   if(s == CYCLE_RECOVERY_PLACED) return "REC_PLACED";
   if(s == CYCLE_EXIT_PENDING) return "EXIT_PENDING";
   if(s == CYCLE_COOLDOWN) return "COOLDOWN";
   if(s == CYCLE_DAILY_LOCK) return "DAILY_LOCK";
   return "?";
}

void LogInfo(string msg)
{
   if(InpLogVerbosity < 2)
      return;
   Print("[INFO][", g_symbol, "][C", g_cycle.cycleId, "][", StateToStr(g_cycle.state), "] ", msg);
}

void LogWarn(string msg)
{
   if(InpLogVerbosity < 1)
      return;
   Print("[WARN][", g_symbol, "][C", g_cycle.cycleId, "][", StateToStr(g_cycle.state), "] ", msg);
}

void LogError(string msg)
{
   Print("[ERROR][", g_symbol, "][C", g_cycle.cycleId, "][", StateToStr(g_cycle.state), "] ", msg);
}

void LogTrade(string msg)
{
   if(InpLogVerbosity < 1)
      return;
   Print("[TRADE][", g_symbol, "][C", g_cycle.cycleId, "][", StateToStr(g_cycle.state), "] ", msg);
}

void LogSignalDecision(const SignalInfo &sig)
{
   if(InpLogVerbosity < 2)
      return;
   string d = (sig.direction == DIR_LONG ? "LONG" : (sig.direction == DIR_SHORT ? "SHORT" : "NONE"));
   Print("[SIGNAL][", g_symbol, "] valid=", sig.valid, " dir=", d, " reason=", sig.reason, " zone=", (int)sig.sourceZoneType, " conf=", (int)sig.confirmation);
}

void LogEntryPlan(const EntryPlan &plan)
{
   if(InpLogVerbosity < 2)
      return;
   string d = (plan.direction == DIR_LONG ? "LONG" : (plan.direction == DIR_SHORT ? "SHORT" : "NONE"));
   Print("[PLAN][", g_symbol, "] valid=", plan.valid, " #", plan.entryNumber, " dir=", d, " lots=", DoubleToString(plan.lotSize, 2), " SL=", DoubleToString(plan.stopLoss, g_digits), " TP=", DoubleToString(plan.takeProfit, g_digits));
}

void LogCycleSnapshot()
{
   if(InpLogVerbosity < 2)
      return;
   Print("[CYCLE][", g_symbol, "] active=", g_cycle.active, " entries=", g_cycle.entriesUsed, " lots=", DoubleToString(g_cycle.totalLots, 2), " avg=", DoubleToString(g_cycle.avgEntryPrice, g_digits), " flt=", DoubleToString(g_cycle.floatingPnL, 2), " dd=", DoubleToString(g_cycle.maxFloatingDD, 2));
}

void ClearChartObjectsByPrefix(string prefix)
{
   int total = ObjectsTotal(0, 0, -1);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, 0, -1);
      if(StringFind(name, prefix) == 0)
         ObjectDelete(0, name);
   }
}

void DrawZoneObjects()
{
   for(int i = 0; i < g_zoneCount; i++)
   {
      if(!g_zones[i].active)
         continue;

      string name = OBJ_PREFIX + "ZN_" + (string)i;
      datetime t1 = TimeCurrent() - PeriodSeconds(PERIOD_M5) * 30;
      datetime t2 = TimeCurrent() + PeriodSeconds(PERIOD_M5) * 30;

      if(ObjectFind(0, name) < 0)
         ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, g_zones[i].lower, t2, g_zones[i].upper);
      else
      {
         ObjectMove(0, name, 0, t1, g_zones[i].lower);
         ObjectMove(0, name, 1, t2, g_zones[i].upper);
      }

      color c = clrSilver;
      if(g_zones[i].bullish)
         c = clrSeaGreen;
      if(g_zones[i].bearish)
         c = clrIndianRed;

      ObjectSetInteger(0, name, OBJPROP_COLOR, c);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
   }
}

void DrawCycleInfoPanel()
{
   RefreshRecoveryScopeStats(false);

   string cycleDir = (g_cycle.direction == DIR_LONG ? "LONG" : (g_cycle.direction == DIR_SHORT ? "SHORT" : "NONE"));
   string scopeDir = "MIXED";
   if(g_scopeLongLots > g_scopeShortLots + 1e-9)
      scopeDir = "LONG";
   else if(g_scopeShortLots > g_scopeLongLots + 1e-9)
      scopeDir = "SHORT";
   else if(g_scopeOrderCount <= 0)
      scopeDir = "FLAT";

   string txt = "CR EA"
      + "\nState: " + StateToStr(g_cycle.state)
      + "\nBias: " + BiasToStr(g_snap.finalBias)
      + "\nSpread: " + DoubleToString(g_snap.currentSpreadPoints, 1)
      + "\nCycle#: " + (string)g_cycle.cycleId
      + "\nEntries: " + (string)g_cycle.entriesUsed
      + "\nCycleDir: " + cycleDir
      + "\nFloat: " + DoubleToString(g_cycle.floatingPnL, 2)
      + "\nDayClosed: " + DoubleToString(g_day.closedPnL, 2)
      + "\nDailyLock: " + (g_day.dailyLockActive ? "YES" : "NO")
      + "\nMktState: " + (string)g_snap.marketState
      + "\nRecScope: " + RecoveryScopeModeToStr(RecoveryScopeMode)
      + "\nScopeDD: " + DoubleToString(g_scopeDDMoney, 2) + "/" + DoubleToString(MathMax(0.0, RecoveryStartDDMoney), 2)
      + "\nOrders: " + (string)g_scopeOrderCount + " L:" + DoubleToString(g_scopeLongLots, 2) + " S:" + DoubleToString(g_scopeShortLots, 2)
      + "\nScopeDir: " + scopeDir
      + "\nInitLotMode: " + InitialLotModeToStr(InitialLotMode)
      + "\nStatus: " + g_statusMessage;

   int maxDetails = (g_isTester && InpAggressiveTesterMode ? 0 : 4);
   if(maxDetails > 0)
   {
      int details = 0;
      for(int i = PositionsTotal() - 1; i >= 0 && details < maxDetails; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket))
            continue;

         string sym = PositionGetString(POSITION_SYMBOL);
         long magic = PositionGetInteger(POSITION_MAGIC);
         if(!IsPositionInScope(sym, magic))
            continue;

         long type = PositionGetInteger(POSITION_TYPE);
         double vol = PositionGetDouble(POSITION_VOLUME);
         double pnl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         string dir = (type == POSITION_TYPE_BUY ? "B" : "S");
         txt += "\n#" + (string)ticket + " " + sym + " " + dir + " " + DoubleToString(vol, 2) + " PnL:" + DoubleToString(pnl, 2);
         details++;
      }
   }

   Comment(txt);
}

void RenderDiagnostics()
{
   if(!IsVisualDiagnosticsEnabled())
      return;
   DrawZoneObjects();
   DrawCycleInfoPanel();
}

//==================================================================
// SECTION: VALIDATION / PRIME
//==================================================================

bool ValidateInputs()
{
   if(SwingStrength < 1)
      return false;
   if(ATRPeriod < 2)
      return false;
   if(MaxEntriesPerCycle < 1)
      return false;
   if(MinSLPoints <= 0 || MaxSLPoints < MinSLPoints)
      return false;
   if(TimeToMinutes(Session1Start) < 0 || TimeToMinutes(Session1End) < 0)
      return false;
   if(TimeToMinutes(Session2Start) < 0 || TimeToMinutes(Session2End) < 0)
      return false;
   if(InpEMAFastPeriod <= 0 || InpEMAMidPeriod <= 0 || InpEMASlowPeriod <= 0)
      return false;
   if(!(InpEMAFastPeriod < InpEMAMidPeriod && InpEMAMidPeriod < InpEMASlowPeriod))
      return false;
   if(InpEMASlopeLookbackBars < 1)
      return false;
   if(InpPartialClosePercent <= 0.0 || InpPartialClosePercent >= 100.0)
      return false;
   if(RecoveryStartDDMoney < 0.0)
      return false;
   if(InitialFixedLot <= 0.0)
      return false;
   if(InitialStepLotPer1000Equity < 0.0)
      return false;
   if(InitialEquityStepSize <= 0.0)
      return false;
   if(InpLogVerbosity < 0 || InpLogVerbosity > 2)
      return false;
   return true;
}

bool PrimeMarketData()
{
   MqlRates r[];
   ArraySetAsSeries(r, true);
   return (CopyRates(g_symbol, PERIOD_M5, 0, 64, r) >= 32);
}

//==================================================================
// SECTION: LIFECYCLE
//==================================================================

int OnInit()
{
   g_symbol = _Symbol;
   g_isTester = (MQLInfoInteger(MQL_TESTER) != 0);
   g_digits = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
   g_point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(20);
   SetStatusMessage("INIT_START", true);

   if(!ValidateInputs())
   {
      LogError("INPUT_VALIDATION_FAILED");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(!PrimeMarketData())
   {
      LogError("PRIME_MARKET_DATA_FAILED");
      return INIT_FAILED;
   }
   if(!InitIndicatorHandles())
   {
      LogError("INIT_INDICATORS_FAILED");
      return INIT_FAILED;
   }
   g_indicatorCacheReady = UpdateIndicatorCaches(true);
   if(!g_indicatorCacheReady)
      LogWarn("INDICATOR_CACHE_WARMUP_DEFERRED");

   ResetCycleState();
   ResetDailyStats();
   BuildNewsCurrencyWatchlist();
   RestoreRuntimeStateFromTerminal();
   RefreshZones();
   RefreshMarketSnapshot();
   RefreshRecoveryScopeStats(true);

   LogInfo("INIT_OK symbol=" + g_symbol + " tf=M5");
   SetStatusMessage("READY", true);
   return INIT_SUCCEEDED;
}

void OnTick()
{
   UpdateRuntimeFlags();
   if(!g_indicatorCacheReady && UpdateIndicatorCaches(g_newBarM5))
      g_indicatorCacheReady = true;
   if(g_newBarM5)
   {
      RefreshDailyState();
      RefreshMarketSnapshot();
      RefreshRecoveryScopeStats(true);
   }
   else
   {
      g_snap.currentSpreadPoints = GetCurrentSpreadPoints();
      g_snap.spreadOk = (g_snap.currentSpreadPoints <= MaxSpreadPoints);
      g_snap.sessionAllowed = IsSessionAllowed() && !IsBrokerRolloverWindow();
      g_snap.newsLocked = IsNewsLockActive();
      double ml = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
      g_snap.marginOk = (ml <= 0.0 || ml > 130.0);
      RefreshRecoveryScopeStats(false);
   }

   if(g_cycle.active)
      ManageActiveCycle();

   if(g_day.dailyLockActive)
   {
      SetStatusMessage("DAILY_LOCK_ACTIVE");
      RenderDiagnostics();
      return;
   }

   if(g_newBarM5)
   {
      RefreshZones();
      RefreshBiasAndState();

      if(!g_cycle.active)
      {
         EvaluateNewCycleEntry();
         if(g_cycle.active)
            EvaluateRecoveryEntry();
      }
      else
         EvaluateRecoveryEntry();
   }

   RenderDiagnostics();
}

void OnDeinit(const int reason)
{
   ClearChartObjectsByPrefix(OBJ_PREFIX);
   if(IsVisualDiagnosticsEnabled())
      Comment("");
   ReleaseIndicatorHandles();
   LogInfo("DEINIT reason=" + (string)reason);
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   if(trans.deal == 0 || !HistoryDealSelect(trans.deal))
      return;

   string sym = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
   long magic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(sym != g_symbol || magic != InpMagicNumber || entry != DEAL_ENTRY_OUT)
      return;

   datetime dtime = (datetime)HistoryDealGetInteger(trans.deal, DEAL_TIME);
   if(DayStart(dtime) != g_day.tradeDay)
      return;

   g_day.closedPnL += HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
   g_day.closedPnL += HistoryDealGetDouble(trans.deal, DEAL_SWAP);
   g_day.closedPnL += HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
}
