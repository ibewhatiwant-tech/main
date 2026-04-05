//+------------------------------------------------------------------+
//|                                      RecoveryTradeEngine.mq5     |
//|                          Recovery Trade Engine — Single-File EA  |
//|                                                                  |
//|  Architecture: 16 sections, single file                         |
//|  Sections 1-4 + EA skeleton implemented in Phase 2              |
//|  All remaining sections stubbed; filled phase-by-phase           |
//+------------------------------------------------------------------+
#property copyright   "Recovery Trade Engine"
#property version     "1.00"
#property description "Production-grade MT5 Recovery Trade Engine"

//══════════════════════════════════════════════════════════════════════
// SECTION 1 — ENUMS
//══════════════════════════════════════════════════════════════════════

enum ENUM_ENGINE_STATE
{
   STATE_IDLE       = 0,  // No open basket; waiting for entry signal
   STATE_ENTRY      = 1,  // Signal confirmed; trade submitted to ExecutionEngine
   STATE_MONITOR    = 2,  // Basket open; watching P&L each tick
   STATE_DETECTING  = 3,  // Drawdown threshold hit; running regime detection
   STATE_RECOVERY   = 4,  // Recovery strategy active (trend or range path)
   STATE_CLOSE      = 5   // Closing all positions; resetting for next cycle
};

enum ENUM_REGIME
{
   REGIME_TREND        = 0,  // ADX/slope scoring >= 3 of 4 indicators
   REGIME_RANGE        = 1,  // ADX/slope scoring <= 1 of 4 indicators
   REGIME_UNDETERMINED = 2   // Score = 2; defer to previous or retry
};

enum ENUM_BASKET_STATUS
{
   BASKET_HEALTHY            = 0,  // P_net >= 0
   BASKET_DRAWDOWN_MINOR     = 1,  // P_net < 0 but below threshold
   BASKET_RECOVERY_TRIGGER   = 2   // P_net < 0 AND abs(P_net) >= RecoveryActivationUSD
};

enum ENUM_ENTRY_SIGNAL
{
   SIGNAL_NONE = 0,
   SIGNAL_BUY  = 1,
   SIGNAL_SELL = 2
};

enum ENUM_REJECTION_REASON
{
   REJECT_NONE              = 0,
   REJECT_DUPLICATE         = 1,  // Dedupe key already in registry
   REJECT_SPREAD_TOO_HIGH   = 2,  // Spread exceeds MaxSpreadPoints
   REJECT_LOT_INVALID       = 3,  // Lot < broker min or > broker max
   REJECT_LOT_NOT_VALIDATED = 4,  // isLotValidated == false
   REJECT_HARD_STOP_ACTIVE  = 5,  // CRiskGuard hard stop flag is set
   REJECT_BROKER_REJECT     = 6,  // MT5 returned a trade error
   REJECT_SYMBOL_MISMATCH   = 7,  // Request symbol != EA symbol
   REJECT_EMPTY_CONTEXT_TAG = 8   // contextTag is "" — required for dedup key
};

enum ENUM_LOG_LEVEL
{
   LOG_DEBUG = 0,
   LOG_INFO  = 1,
   LOG_WARN  = 2,
   LOG_ERROR = 3,
   LOG_FATAL = 4
};

//══════════════════════════════════════════════════════════════════════
// SECTION 2 — STRUCTS
//══════════════════════════════════════════════════════════════════════

//--- All trade requests MUST pass through CExecutionEngine::Submit().
//    No module may place orders except via this struct contract.
struct TradeRequest
{
   string           symbol;          // Must match EA's _Symbol
   ENUM_ORDER_TYPE  direction;        // ORDER_TYPE_BUY or ORDER_TYPE_SELL (net direction)
   double           lotSize;          // Pre-computed by CRiskGuard
   ENUM_ORDER_TYPE  orderType;        // Execution type (market, limit, stop)
   double           stopLoss;         // Absolute price; 0.0 = no SL
   double           takeProfit;       // Absolute price; 0.0 = no TP
   string           contextTag;       // Caller identity: e.g. "ENTRY_BUY", "HEDGE_TREND_1"
   ulong            requestId;        // Monotonic ID assigned by caller
   bool             isLotValidated;   // MUST be true; CExecutionEngine rejects false
   int              magicNumber;

   TradeRequest()
   {
      symbol         = "";
      direction      = ORDER_TYPE_BUY;
      lotSize        = 0.0;
      orderType      = ORDER_TYPE_BUY;
      stopLoss       = 0.0;
      takeProfit     = 0.0;
      contextTag     = "";
      requestId      = 0;
      isLotValidated = false;
      magicNumber    = 0;
   }
};

struct TradeResult
{
   ulong                  requestId;        // Echo of TradeRequest.requestId
   ulong                  ticket;           // MT5 position ticket on success
   bool                   success;
   int                    errorCode;        // MT5 GetLastError() on failure
   ENUM_REJECTION_REASON  rejectionReason;
   double                 executedPrice;
   double                 executedLot;

   TradeResult()
   {
      requestId       = 0;
      ticket          = 0;
      success         = false;
      errorCode       = 0;
      rejectionReason = REJECT_NONE;
      executedPrice   = 0.0;
      executedLot     = 0.0;
   }
};

//--- Internal record kept by COrderManager for each basket position
struct PositionRecord
{
   ulong            ticket;
   ENUM_ORDER_TYPE  direction;
   double           openPrice;
   double           lotSize;
   datetime         openTime;
   string           contextTag;   // Inherited from TradeRequest that created it
   double           currentPnL;   // Updated each reconciliation cycle

   PositionRecord()
   {
      ticket     = 0;
      direction  = ORDER_TYPE_BUY;
      openPrice  = 0.0;
      lotSize    = 0.0;
      openTime   = 0;
      contextTag = "";
      currentPnL = 0.0;
   }
};

//--- Read-only snapshot of the entire open basket; computed by COrderManager
struct BasketSnapshot
{
   int      positionCount;
   double   totalLots;
   double   netPnlUSD;       // Total floating P&L in account currency
   int      netDirection;    // +1 net long, -1 net short, 0 neutral/mixed
   datetime oldestOpenTime;
   datetime snapshotTime;

   BasketSnapshot()
   {
      positionCount  = 0;
      totalLots      = 0.0;
      netPnlUSD      = 0.0;
      netDirection   = 0;
      oldestOpenTime = 0;
      snapshotTime   = 0;
   }
};

//--- Regime scoring result from CRegimeDetector
struct RegimeScore
{
   ENUM_REGIME  classification;
   int          trendPoints;    // Count of trend-scoring indicators (0–4)
   double       adxValue;
   double       smaSlope;
   double       bbWidth;
   double       atrRatio;       // ATR / ATR-SMA ratio
   datetime     detectionTime;

   RegimeScore()
   {
      classification = REGIME_UNDETERMINED;
      trendPoints    = 0;
      adxValue       = 0.0;
      smaSlope       = 0.0;
      bbWidth        = 0.0;
      atrRatio       = 0.0;
      detectionTime  = 0;
   }
};

//--- Result returned by CRiskGuard::ValidateRequest()
struct ValidationResult
{
   bool                  isValid;
   ENUM_REJECTION_REASON failReason;
   double                adjustedLot;   // CRiskGuard may clamp lot; returned here

   ValidationResult()
   {
      isValid     = false;
      failReason  = REJECT_NONE;
      adjustedLot = 0.0;
   }
};

//--- Flat snapshot consumed by CDashboardRenderer; no MT5 API calls inside renderer
struct DashboardSnapshot
{
   ENUM_ENGINE_STATE  engineState;
   ENUM_REGIME        regimeClassification;
   double             basketNetPnL;
   int                positionCount;
   bool               hardStopBreached;
   bool               recoveryActive;
   string             lastLogMessage;
   datetime           tickTime;
   double             spreadCurrentPips;

   DashboardSnapshot()
   {
      engineState           = STATE_IDLE;
      regimeClassification  = REGIME_UNDETERMINED;
      basketNetPnL          = 0.0;
      positionCount         = 0;
      hardStopBreached      = false;
      recoveryActive        = false;
      lastLogMessage        = "";
      tickTime              = 0;
      spreadCurrentPips     = 0.0;
   }
};

//══════════════════════════════════════════════════════════════════════
// SECTION 3 — CONSTANTS
//══════════════════════════════════════════════════════════════════════

#define RTE_MAGIC_NUMBER           20260405
#define RTE_VERSION_STRING         "1.0.0"
#define RTE_MAX_REGISTRY_SIZE      50     // Max dedupe entries per basket lifecycle
#define RTE_MAX_BASKET_POSITIONS   20     // Hard cap on open positions in one basket
#define RTE_DEFAULT_SLIPPAGE       10     // Points

// Default input thresholds (all overridable via input parameters)
#define RTE_DEFAULT_FAST_EMA       8
#define RTE_DEFAULT_SLOW_EMA       21
#define RTE_DEFAULT_RECOVERY_USD   50.0
#define RTE_DEFAULT_HARD_STOP_USD  200.0
#define RTE_DEFAULT_MAX_SPREAD     30.0   // In points
#define RTE_DEFAULT_MAX_LOT        5.0
#define RTE_DEFAULT_RISK_PERCENT   1.0
#define RTE_DEFAULT_ADX_PERIOD     14
#define RTE_DEFAULT_ADX_THRESHOLD  25.0
#define RTE_DEFAULT_ATR_PERIOD     14
#define RTE_DEFAULT_BB_PERIOD      20
#define RTE_DEFAULT_BB_DEVIATION   2.0
#define RTE_DEFAULT_SMA_PERIOD     50
#define RTE_DEFAULT_RSI_PERIOD     14
#define RTE_DEFAULT_RSI_OB         70.0
#define RTE_DEFAULT_RSI_OS         30.0
#define RTE_DEFAULT_FIB_TP_RATIO   1.618  // Fibonacci extension for range TP

//══════════════════════════════════════════════════════════════════════
// SECTION 4 — CLogger
//══════════════════════════════════════════════════════════════════════

class CLogger
{
private:
   ENUM_LOG_LEVEL  m_minLevel;
   string          m_lastMessage;

   string LevelToString(ENUM_LOG_LEVEL level) const
   {
      switch(level)
      {
         case LOG_DEBUG: return "DEBUG";
         case LOG_INFO:  return "INFO ";
         case LOG_WARN:  return "WARN ";
         case LOG_ERROR: return "ERROR";
         case LOG_FATAL: return "FATAL";
         default:        return "?????";
      }
   }

public:
   CLogger() : m_minLevel(LOG_DEBUG), m_lastMessage("") {}

   void SetMinLevel(ENUM_LOG_LEVEL level) { m_minLevel = level; }
   string GetLastMessage() const          { return m_lastMessage; }

   void Log(ENUM_LOG_LEVEL level, const string module, const string message)
   {
      if(level < m_minLevel) return;

      string entry = StringFormat("[%s][%s][%s] %s",
         TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
         LevelToString(level),
         module,
         message);

      Print(entry);
      m_lastMessage = entry;
   }

   void Debug(const string module, const string msg) { Log(LOG_DEBUG, module, msg); }
   void Info (const string module, const string msg) { Log(LOG_INFO,  module, msg); }
   void Warn (const string module, const string msg) { Log(LOG_WARN,  module, msg); }
   void Error(const string module, const string msg) { Log(LOG_ERROR, module, msg); }
   void Fatal(const string module, const string msg) { Log(LOG_FATAL, module, msg); }
};

//══════════════════════════════════════════════════════════════════════
// SECTION 5 — CRiskGuard  [Phase 3]
//══════════════════════════════════════════════════════════════════════

// Implemented in Phase 3

//══════════════════════════════════════════════════════════════════════
// SECTION 6 — CExecutionEngine  [Phase 3]
//      NOTE: Only this section may use CTrade / OrderSend.
//            #include <Trade\Trade.mqh> will be added here in Phase 3.
//══════════════════════════════════════════════════════════════════════

// Implemented in Phase 3

//══════════════════════════════════════════════════════════════════════
// SECTION 7 — COrderManager  [Phase 4]
//══════════════════════════════════════════════════════════════════════

// Implemented in Phase 4

//══════════════════════════════════════════════════════════════════════
// SECTION 8 — CBasketMonitor  [Phase 4]
//══════════════════════════════════════════════════════════════════════

// Implemented in Phase 4

//══════════════════════════════════════════════════════════════════════
// SECTION 9 — CEntryEngine  [Phase 5]
//══════════════════════════════════════════════════════════════════════

// Implemented in Phase 5

//══════════════════════════════════════════════════════════════════════
// SECTION 10 — CRegimeDetector  [Phase 6]
//══════════════════════════════════════════════════════════════════════

// Implemented in Phase 6

//══════════════════════════════════════════════════════════════════════
// SECTION 11 — CTrendRecovery  [Phase 7]
//══════════════════════════════════════════════════════════════════════

// Implemented in Phase 7

//══════════════════════════════════════════════════════════════════════
// SECTION 12 — CRangeRecovery  [Phase 8]
//══════════════════════════════════════════════════════════════════════

// Implemented in Phase 8

//══════════════════════════════════════════════════════════════════════
// SECTION 13 — CDashboardViewModel  [Phase 9]
//══════════════════════════════════════════════════════════════════════

// Implemented in Phase 9

//══════════════════════════════════════════════════════════════════════
// SECTION 14 — CDashboardRenderer  [Phase 9]
//══════════════════════════════════════════════════════════════════════

// Implemented in Phase 9

//══════════════════════════════════════════════════════════════════════
// SECTION 15 — CRecoveryEngine  [Phase 10 — integration]
//══════════════════════════════════════════════════════════════════════

// Implemented in Phase 10

//══════════════════════════════════════════════════════════════════════
// SECTION 16 — INPUT PARAMETERS & EA ENTRY POINTS
//══════════════════════════════════════════════════════════════════════

//--- Entry
input group              "════ Entry Settings ════"
input int    Inp_FastEMA               = RTE_DEFAULT_FAST_EMA;        // Fast EMA period
input int    Inp_SlowEMA               = RTE_DEFAULT_SLOW_EMA;        // Slow EMA period

//--- Recovery
input group              "════ Recovery Settings ════"
input double Inp_RecoveryActivationUSD = RTE_DEFAULT_RECOVERY_USD;    // USD drawdown to trigger recovery
input double Inp_HardStopUSD           = RTE_DEFAULT_HARD_STOP_USD;   // USD loss → force close all

//--- Risk
input group              "════ Risk Settings ════"
input double Inp_RiskPercent           = RTE_DEFAULT_RISK_PERCENT;    // % of balance per trade
input double Inp_MaxLot                = RTE_DEFAULT_MAX_LOT;         // Hard lot cap
input double Inp_MaxSpreadPoints       = RTE_DEFAULT_MAX_SPREAD;      // Max spread in points

//--- Regime Detection
input group              "════ Regime Detection ════"
input int    Inp_ADXPeriod             = RTE_DEFAULT_ADX_PERIOD;
input double Inp_ADXThreshold          = RTE_DEFAULT_ADX_THRESHOLD;   // ADX above = trend point
input int    Inp_ATRPeriod             = RTE_DEFAULT_ATR_PERIOD;
input int    Inp_BBPeriod              = RTE_DEFAULT_BB_PERIOD;
input double Inp_BBDeviation           = RTE_DEFAULT_BB_DEVIATION;
input int    Inp_SMAPeriod             = RTE_DEFAULT_SMA_PERIOD;      // For slope calculation

//--- RSI (Range Recovery filter)
input group              "════ RSI Settings ════"
input int    Inp_RSIPeriod             = RTE_DEFAULT_RSI_PERIOD;
input double Inp_RSI_OB                = RTE_DEFAULT_RSI_OB;          // Overbought threshold
input double Inp_RSI_OS                = RTE_DEFAULT_RSI_OS;          // Oversold threshold

//--- Logging
input group              "════ Logging ════"
input ENUM_LOG_LEVEL Inp_LogLevel      = LOG_INFO;                    // Minimum log level to display

//--- Global instances (only CLogger active in Phase 2)
CLogger* g_logger = NULL;

//+------------------------------------------------------------------+
int OnInit()
{
   //--- Logger is always first
   g_logger = new CLogger();
   g_logger.SetMinLevel(Inp_LogLevel);
   g_logger.Info("EA", StringFormat("RecoveryTradeEngine v%s starting on %s",
                                     RTE_VERSION_STRING, _Symbol));

   //--- Input validation
   if(Inp_FastEMA >= Inp_SlowEMA)
   {
      g_logger.Fatal("EA", StringFormat(
         "FastEMA (%d) must be less than SlowEMA (%d)", Inp_FastEMA, Inp_SlowEMA));
      return INIT_PARAMETERS_INCORRECT;
   }
   if(Inp_RecoveryActivationUSD <= 0.0)
   {
      g_logger.Fatal("EA", "RecoveryActivationUSD must be > 0");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(Inp_HardStopUSD <= Inp_RecoveryActivationUSD)
   {
      g_logger.Fatal("EA", StringFormat(
         "HardStopUSD (%.2f) must exceed RecoveryActivationUSD (%.2f)",
         Inp_HardStopUSD, Inp_RecoveryActivationUSD));
      return INIT_PARAMETERS_INCORRECT;
   }
   if(Inp_MaxLot <= 0.0)
   {
      g_logger.Fatal("EA", "MaxLot must be > 0");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(Inp_RiskPercent <= 0.0 || Inp_RiskPercent > 10.0)
   {
      g_logger.Fatal("EA", "RiskPercent must be in range (0, 10]");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(Inp_RSI_OS >= Inp_RSI_OB)
   {
      g_logger.Fatal("EA", "RSI_OS must be less than RSI_OB");
      return INIT_PARAMETERS_INCORRECT;
   }

   //--- Log validated configuration
   g_logger.Info("EA", StringFormat(
      "Entry  — FastEMA: %d  SlowEMA: %d",
      Inp_FastEMA, Inp_SlowEMA));
   g_logger.Info("EA", StringFormat(
      "Risk   — RiskPct: %.2f%%  MaxLot: %.2f  MaxSpread: %.0f pts",
      Inp_RiskPercent, Inp_MaxLot, Inp_MaxSpreadPoints));
   g_logger.Info("EA", StringFormat(
      "Levels — RecoveryUSD: %.2f  HardStopUSD: %.2f",
      Inp_RecoveryActivationUSD, Inp_HardStopUSD));
   g_logger.Info("EA", StringFormat(
      "Regime — ADX(%d) thr=%.1f  ATR(%d)  BB(%d/%.1f)  SMA(%d)",
      Inp_ADXPeriod, Inp_ADXThreshold, Inp_ATRPeriod,
      Inp_BBPeriod, Inp_BBDeviation, Inp_SMAPeriod));

   //--- Modules will be instantiated here in later phases
   //    (CRiskGuard, CExecutionEngine, COrderManager, ... CRecoveryEngine)

   g_logger.Info("EA", "Phase 2 skeleton ready — awaiting Phase 3 modules.");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnTick()
{
   // CRecoveryEngine::OnTick() will be the sole call here (Phase 10)
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_logger != NULL)
   {
      g_logger.Info("EA", StringFormat(
         "OnDeinit called. Reason: %d", reason));
      delete g_logger;
      g_logger = NULL;
   }
}
