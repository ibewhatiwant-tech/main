//+------------------------------------------------------------------+
//|                                      RecoveryTradeEngine.mq5     |
//|                          Recovery Trade Engine — Single-File EA  |
//|                                                                  |
//|  Architecture: 16 sections, single file                         |
//|  Phase 10 Final Integration — all sections complete              |
//|  Architecture constraint: only CExecutionEngine calls CTrade     |
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
#define RTE_DEFAULT_ATR_AVG_BARS   20     // Bars used to compute ATR average for ratio
#define RTE_DEFAULT_SLOPE_PTS      50.0   // Min absolute SMA slope in points for trend point
#define RTE_DEFAULT_BB_WIDTH       0.002  // Min BB width ratio (upper-lower)/middle for trend point
#define RTE_DEFAULT_ATR_RATIO      1.1    // Min ATR/ATR-avg ratio for trend point

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
// SECTION 5 — CRiskGuard
//  Responsibilities:
//    • Spread filter (IsSpreadAcceptable)
//    • Lot size computation (ComputeLot)
//    • Per-request validation (ValidateRequest)
//    • Hard stop flag management (CheckAndSetHardStop / IsHardStopBreached)
//══════════════════════════════════════════════════════════════════════

class CRiskGuard
{
private:
   CLogger*  m_logger;
   double    m_maxSpreadPoints;   // Max acceptable spread in broker points
   double    m_maxLot;            // Absolute lot cap regardless of risk calc
   double    m_riskPercent;       // % of account balance risked per trade
   double    m_hardStopUSD;       // Basket loss that triggers forced close
   bool      m_hardStopBreached;  // Sticky flag; cleared only on ClearHardStop()

   //--- Clamp and normalise a raw lot to broker constraints
   double NormaliseLot(const string symbol, double rawLot) const
   {
      double lotMin  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
      double lotMax  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
      double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
      if(lotStep <= 0.0) lotStep = 0.01;

      double capped = MathMin(m_maxLot, MathMin(lotMax, MathMax(lotMin, rawLot)));
      double steps  = MathRound(capped / lotStep);
      return NormalizeDouble(steps * lotStep, 2);
   }

public:
   CRiskGuard(CLogger* logger)
      : m_logger(logger),
        m_maxSpreadPoints(RTE_DEFAULT_MAX_SPREAD),
        m_maxLot(RTE_DEFAULT_MAX_LOT),
        m_riskPercent(RTE_DEFAULT_RISK_PERCENT),
        m_hardStopUSD(RTE_DEFAULT_HARD_STOP_USD),
        m_hardStopBreached(false) {}

   //--- Called from OnInit() after input parameters are available
   void Init(double maxSpreadPoints, double maxLot,
             double riskPercent,     double hardStopUSD)
   {
      m_maxSpreadPoints = maxSpreadPoints;
      m_maxLot          = maxLot;
      m_riskPercent     = riskPercent;
      m_hardStopUSD     = hardStopUSD;
      m_logger.Info("RiskGuard",
         StringFormat("Init — MaxSpread:%.0f pts  MaxLot:%.2f  Risk:%.2f%%  HardStop:%.2f USD",
         maxSpreadPoints, maxLot, riskPercent, hardStopUSD));
   }

   //--- Returns true when current spread is within the configured limit
   bool IsSpreadAcceptable(const string symbol) const
   {
      long spreadPts = SymbolInfoInteger(symbol, SYMBOL_SPREAD);
      return (spreadPts <= (long)m_maxSpreadPoints);
   }

   //--- Compute risk-based lot size given a stop distance (in MT5 points).
   //    Returns the broker-normalised lot, never exceeding m_maxLot.
   //    Falls back to SYMBOL_VOLUME_MIN if stop distance is zero.
   double ComputeLot(const string symbol, double stopDistancePoints) const
   {
      double lotMin = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
      if(stopDistancePoints <= 0.0)
      {
         m_logger.Warn("RiskGuard", "ComputeLot: stopDistancePoints <= 0; returning min lot");
         return lotMin;
      }

      double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
      double risk     = balance * m_riskPercent / 100.0;

      // Monetary value of one tick move for 1 standard lot (account currency)
      double tickVal  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickVal <= 0.0 || tickSize <= 0.0)
      {
         m_logger.Error("RiskGuard",
            StringFormat("ComputeLot: invalid tick info tickVal=%.6f tickSize=%.6f",
            tickVal, tickSize));
         return lotMin;
      }

      // How many ticks is the stop distance?  Then monetary cost per lot.
      double stopInTicks  = (stopDistancePoints * _Point) / tickSize;
      double riskPerLot   = stopInTicks * tickVal;
      if(riskPerLot <= 0.0) return lotMin;

      double rawLot = risk / riskPerLot;
      double lot    = NormaliseLot(symbol, rawLot);

      m_logger.Debug("RiskGuard",
         StringFormat("ComputeLot — balance:%.2f risk:%.2f stop:%.1f pts rawLot:%.4f lot:%.2f",
         balance, risk, stopDistancePoints, rawLot, lot));
      return lot;
   }

   //--- Full pre-flight validation called by CExecutionEngine before every order.
   //    Checks spread and broker lot bounds; may return an adjusted (clamped) lot.
   ValidationResult ValidateRequest(const TradeRequest& req) const
   {
      ValidationResult vr;

      // Spread check
      if(!IsSpreadAcceptable(req.symbol))
      {
         long sp = SymbolInfoInteger(req.symbol, SYMBOL_SPREAD);
         m_logger.Warn("RiskGuard",
            StringFormat("Spread rejected — current:%d pts  max:%.0f pts  tag:%s",
            sp, m_maxSpreadPoints, req.contextTag));
         vr.isValid    = false;
         vr.failReason = REJECT_SPREAD_TOO_HIGH;
         return vr;
      }

      // Lot bounds check
      double lotMin  = SymbolInfoDouble(req.symbol, SYMBOL_VOLUME_MIN);
      double lotMax  = SymbolInfoDouble(req.symbol, SYMBOL_VOLUME_MAX);
      double lotStep = SymbolInfoDouble(req.symbol, SYMBOL_VOLUME_STEP);
      if(lotStep <= 0.0) lotStep = 0.01;

      if(req.lotSize < lotMin || req.lotSize > MathMin(m_maxLot, lotMax))
      {
         m_logger.Warn("RiskGuard",
            StringFormat("Lot rejected — lot:%.2f  min:%.2f  max:%.2f  cap:%.2f  tag:%s",
            req.lotSize, lotMin, lotMax, m_maxLot, req.contextTag));
         vr.isValid    = false;
         vr.failReason = REJECT_LOT_INVALID;
         return vr;
      }

      // Normalise (clamp to step) and surface adjusted value
      vr.isValid     = true;
      vr.failReason  = REJECT_NONE;
      vr.adjustedLot = NormaliseLot(req.symbol, req.lotSize);
      return vr;
   }

   //--- Called every tick by CBasketMonitor/CRecoveryEngine with live P&L.
   //    Once breached the flag is sticky until ClearHardStop() is called.
   void CheckAndSetHardStop(double basketPnlUSD)
   {
      if(m_hardStopBreached) return;   // Already set; no need to re-log
      if(basketPnlUSD < 0.0 && MathAbs(basketPnlUSD) >= m_hardStopUSD)
      {
         m_hardStopBreached = true;
         m_logger.Fatal("RiskGuard",
            StringFormat("HARD STOP BREACHED — basket P&L: %.2f USD  threshold: %.2f USD",
            basketPnlUSD, m_hardStopUSD));
      }
   }

   bool IsHardStopBreached() const { return m_hardStopBreached; }

   void ClearHardStop()
   {
      if(m_hardStopBreached)
         m_logger.Info("RiskGuard", "Hard stop flag cleared for new basket cycle.");
      m_hardStopBreached = false;
   }
};

//══════════════════════════════════════════════════════════════════════
// SECTION 6 — CExecutionEngine
//  *** SOLE TRADE GATEWAY — only class that calls CTrade ***
//  Responsibilities:
//    • Accept TradeRequest, run validation chain, dispatch via CTrade
//    • Maintain dedupe registry (parallel arrays, fixed capacity)
//    • Return TradeResult on every call
//    • ClearRegistry() resets state for the next basket lifecycle
//══════════════════════════════════════════════════════════════════════

#include <Trade\Trade.mqh>   // ← only #include of Trade lib in the entire file

class CExecutionEngine
{
private:
   CTrade      m_trade;
   CRiskGuard* m_riskGuard;
   CLogger*    m_logger;

   //--- Dedupe registry: fixed-capacity parallel arrays
   //    Entries are added on successful dispatch only.
   //    Cleared on CLOSE → IDLE via ClearRegistry().
   string      m_regKeys   [RTE_MAX_REGISTRY_SIZE];
   ulong       m_regTickets[RTE_MAX_REGISTRY_SIZE];
   datetime    m_regTimes  [RTE_MAX_REGISTRY_SIZE];
   int         m_regCount;

   //--- Monotonic counter used to tag each unique request internally
   ulong       m_requestCounter;

   // ── Dedupe helpers ────────────────────────────────────────────────

   //--- Build a deterministic key from fields that uniquely identify
   //    the trading intent within one basket lifecycle.
   //    Format: {Symbol}|{OrderType}|{Direction}|{LotNorm}|{ContextTag}
   string BuildDedupeKey(const TradeRequest& req) const
   {
      return StringFormat("%s|%d|%d|%.2f|%s",
         req.symbol,
         (int)req.orderType,
         (int)req.direction,
         req.lotSize,
         req.contextTag);
   }

   bool IsInRegistry(const string key) const
   {
      for(int i = 0; i < m_regCount; i++)
         if(m_regKeys[i] == key) return true;
      return false;
   }

   void AddToRegistry(const string key, ulong ticket)
   {
      if(m_regCount >= RTE_MAX_REGISTRY_SIZE)
      {
         m_logger.Error("ExecEngine",
            "Registry full — cannot register key: " + key);
         return;
      }
      m_regKeys   [m_regCount] = key;
      m_regTickets[m_regCount] = ticket;
      m_regTimes  [m_regCount] = TimeCurrent();
      m_regCount++;
      m_logger.Debug("ExecEngine",
         StringFormat("Registry add [%d/%d] key=%s ticket=%I64u",
         m_regCount, RTE_MAX_REGISTRY_SIZE, key, ticket));
   }

   // ── Validation chain ──────────────────────────────────────────────

   //--- Returns REJECT_NONE on pass; populates res on any failure
   ENUM_REJECTION_REASON RunValidationChain(const TradeRequest& req,
                                             TradeResult&        res,
                                             string&             dedupeKey)
   {
      // 1. Lot must have been validated by CRiskGuard before calling Submit()
      if(!req.isLotValidated)
      {
         m_logger.Error("ExecEngine",
            "REJECT_LOT_NOT_VALIDATED — contextTag: " + req.contextTag);
         return REJECT_LOT_NOT_VALIDATED;
      }

      // 2. Context tag is mandatory (dedupe key requires it)
      if(req.contextTag == "")
      {
         m_logger.Error("ExecEngine", "REJECT_EMPTY_CONTEXT_TAG");
         return REJECT_EMPTY_CONTEXT_TAG;
      }

      // 3. Symbol must match the EA's configured symbol
      if(req.symbol != _Symbol)
      {
         m_logger.Error("ExecEngine",
            StringFormat("REJECT_SYMBOL_MISMATCH — req:%s ea:%s",
            req.symbol, _Symbol));
         return REJECT_SYMBOL_MISMATCH;
      }

      // 4. Hard stop blocks all new orders
      if(m_riskGuard.IsHardStopBreached())
      {
         m_logger.Warn("ExecEngine",
            "REJECT_HARD_STOP_ACTIVE — tag: " + req.contextTag);
         return REJECT_HARD_STOP_ACTIVE;
      }

      // 5. Dedupe check — reject if this exact intent was already dispatched
      dedupeKey = BuildDedupeKey(req);
      if(IsInRegistry(dedupeKey))
      {
         m_logger.Warn("ExecEngine",
            "REJECT_DUPLICATE — key: " + dedupeKey);
         return REJECT_DUPLICATE;
      }

      // 6. CRiskGuard validates spread and lot bounds
      ValidationResult vr = m_riskGuard.ValidateRequest(req);
      if(!vr.isValid)
         return vr.failReason;

      return REJECT_NONE;
   }

   // ── Order dispatch ────────────────────────────────────────────────

   bool DispatchMarketOrder(const TradeRequest& req, TradeResult& res)
   {
      double price = (req.direction == ORDER_TYPE_BUY)
                     ? SymbolInfoDouble(req.symbol, SYMBOL_ASK)
                     : SymbolInfoDouble(req.symbol, SYMBOL_BID);

      bool sent = m_trade.PositionOpen(
         req.symbol,
         req.orderType,   // ORDER_TYPE_BUY or ORDER_TYPE_SELL
         req.lotSize,
         price,
         req.stopLoss,
         req.takeProfit,
         req.contextTag   // comment carries semantic tag for MT5 journal
      );

      if(sent && m_trade.ResultRetcode() == TRADE_RETCODE_DONE)
      {
         res.ticket        = m_trade.ResultOrder();   // = position ticket in hedging mode
         res.executedPrice = m_trade.ResultPrice();
         res.executedLot   = m_trade.ResultVolume();
         res.success       = true;
         return true;
      }

      // Transient broker failures are NOT registered — next tick can retry
      res.errorCode       = (int)m_trade.ResultRetcode();
      res.rejectionReason = REJECT_BROKER_REJECT;
      m_logger.Error("ExecEngine",
         StringFormat("Broker reject retcode:%u tag:%s",
         m_trade.ResultRetcode(), req.contextTag));
      return false;
   }

   bool DispatchPendingOrder(const TradeRequest& req, TradeResult& res)
   {
      bool sent = false;
      switch(req.orderType)
      {
         case ORDER_TYPE_BUY_LIMIT:
            sent = m_trade.BuyLimit(req.lotSize, req.takeProfit,
                                    req.symbol, req.stopLoss, 0, 0, 0, req.contextTag);
            break;
         case ORDER_TYPE_SELL_LIMIT:
            sent = m_trade.SellLimit(req.lotSize, req.takeProfit,
                                     req.symbol, req.stopLoss, 0, 0, 0, req.contextTag);
            break;
         case ORDER_TYPE_BUY_STOP:
            sent = m_trade.BuyStop(req.lotSize, req.takeProfit,
                                   req.symbol, req.stopLoss, 0, 0, 0, req.contextTag);
            break;
         case ORDER_TYPE_SELL_STOP:
            sent = m_trade.SellStop(req.lotSize, req.takeProfit,
                                    req.symbol, req.stopLoss, 0, 0, 0, req.contextTag);
            break;
         default:
            m_logger.Error("ExecEngine",
               StringFormat("DispatchPending: unsupported orderType %d", (int)req.orderType));
            res.rejectionReason = REJECT_BROKER_REJECT;
            return false;
      }

      if(sent && m_trade.ResultRetcode() == TRADE_RETCODE_PLACED)
      {
         res.ticket  = m_trade.ResultOrder();
         res.success = true;
         return true;
      }

      res.errorCode       = (int)m_trade.ResultRetcode();
      res.rejectionReason = REJECT_BROKER_REJECT;
      m_logger.Error("ExecEngine",
         StringFormat("Pending order broker reject retcode:%u tag:%s",
         m_trade.ResultRetcode(), req.contextTag));
      return false;
   }

   bool IsMarketOrder(ENUM_ORDER_TYPE t) const
   {
      return (t == ORDER_TYPE_BUY || t == ORDER_TYPE_SELL);
   }

public:
   CExecutionEngine(CRiskGuard* riskGuard, CLogger* logger)
      : m_riskGuard(riskGuard),
        m_logger(logger),
        m_regCount(0),
        m_requestCounter(0) {}

   //--- Called from OnInit() after CTrade parameters are known
   void Init(int magicNumber, int slippagePoints,
             ENUM_ORDER_TYPE_FILLING fillingMode = ORDER_FILLING_FOK)
   {
      m_trade.SetExpertMagicNumber(magicNumber);
      m_trade.SetDeviationInPoints(slippagePoints);
      m_trade.SetTypeFilling(fillingMode);
      m_trade.LogLevel(LOG_LEVEL_ERRORS);          // Internal CTrade logging
      m_logger.Info("ExecEngine",
         StringFormat("Init — magic:%d slippage:%d pts filling:%s",
         magicNumber, slippagePoints, EnumToString(fillingMode)));
   }

   //--- Primary public interface.  All modules call ONLY this method.
   //    Returns true when the order was successfully dispatched.
   bool Submit(TradeRequest& req, TradeResult& res)
   {
      // Populate result defaults
      res           = TradeResult();
      res.requestId = req.requestId;

      // Auto-assign requestId if caller left it zero
      if(req.requestId == 0)
         req.requestId = res.requestId = ++m_requestCounter;

      m_logger.Debug("ExecEngine",
         StringFormat("Submit — tag:%s type:%d dir:%d lot:%.2f",
         req.contextTag, (int)req.orderType, (int)req.direction, req.lotSize));

      string dedupeKey = "";
      ENUM_REJECTION_REASON reason = RunValidationChain(req, res, dedupeKey);
      if(reason != REJECT_NONE)
      {
         res.success         = false;
         res.rejectionReason = reason;
         return false;
      }

      // Dispatch
      bool ok = IsMarketOrder(req.orderType)
                ? DispatchMarketOrder(req, res)
                : DispatchPendingOrder(req, res);

      if(ok)
      {
         // Only successful dispatches enter the registry
         AddToRegistry(dedupeKey, res.ticket);
         m_logger.Info("ExecEngine",
            StringFormat("Filled — tag:%s ticket:%I64u price:%.5f lot:%.2f",
            req.contextTag, res.ticket, res.executedPrice, res.executedLot));
      }

      return ok;
   }

   //--- Called on CLOSE → IDLE transition.
   //    Wipes registry so the next basket lifecycle starts clean.
   void ClearRegistry()
   {
      m_logger.Info("ExecEngine",
         StringFormat("ClearRegistry — flushing %d entries.", m_regCount));
      for(int i = 0; i < m_regCount; i++)
      {
         m_regKeys   [i] = "";
         m_regTickets[i] = 0;
         m_regTimes  [i] = 0;
      }
      m_regCount = 0;
   }

   int   GetRegistryCount() const { return m_regCount; }
   ulong GetRegistryTicket(int idx) const
   {
      return (idx >= 0 && idx < m_regCount) ? m_regTickets[idx] : 0;
   }

   //--- Close an existing position by ticket.
   //    Closes bypass the dedupe registry — reduces risk, always allowed.
   //    Hard stop does NOT block closes (we need to exit, not enter).
   bool SubmitClose(ulong ticket, const string contextTag, TradeResult& res)
   {
      res           = TradeResult();
      res.requestId = ++m_requestCounter;

      if(ticket == 0)
      {
         m_logger.Error("ExecEngine", "SubmitClose: invalid ticket 0 tag:" + contextTag);
         res.rejectionReason = REJECT_BROKER_REJECT;
         return false;
      }

      m_logger.Debug("ExecEngine",
         StringFormat("SubmitClose — ticket:%I64u tag:%s", ticket, contextTag));

      bool ok = m_trade.PositionClose(ticket);

      uint retcode = m_trade.ResultRetcode();
      if(ok && retcode == TRADE_RETCODE_DONE)
      {
         res.ticket  = ticket;
         res.success = true;
         m_logger.Info("ExecEngine",
            StringFormat("Closed — ticket:%I64u tag:%s", ticket, contextTag));
         return true;
      }

      res.errorCode       = (int)retcode;
      res.rejectionReason = REJECT_BROKER_REJECT;
      m_logger.Error("ExecEngine",
         StringFormat("Close failed — ticket:%I64u retcode:%u tag:%s",
         ticket, retcode, contextTag));
      return false;
   }
   //--- Modify SL/TP of an existing position.
   //    Used by CTrendRecovery for ATR trailing stops.
   //    Bypasses dedupe registry — modifications never add exposure.
   bool SubmitModify(ulong ticket, double sl, double tp,
                     const string contextTag, TradeResult& res)
   {
      res           = TradeResult();
      res.requestId = ++m_requestCounter;

      if(ticket == 0)
      {
         m_logger.Error("ExecEngine",
            "SubmitModify: invalid ticket 0 tag:" + contextTag);
         res.rejectionReason = REJECT_BROKER_REJECT;
         return false;
      }

      m_logger.Debug("ExecEngine",
         StringFormat("SubmitModify — ticket:%I64u sl:%.5f tp:%.5f tag:%s",
         ticket, sl, tp, contextTag));

      bool ok = m_trade.PositionModify(ticket, sl, tp);

      uint retcode = m_trade.ResultRetcode();
      if(ok && retcode == TRADE_RETCODE_DONE)
      {
         res.ticket  = ticket;
         res.success = true;
         m_logger.Debug("ExecEngine",
            StringFormat("Modified — ticket:%I64u newSL:%.5f tag:%s",
            ticket, sl, contextTag));
         return true;
      }

      res.errorCode       = (int)retcode;
      res.rejectionReason = REJECT_BROKER_REJECT;
      m_logger.Error("ExecEngine",
         StringFormat("Modify failed — ticket:%I64u retcode:%u tag:%s",
         ticket, retcode, contextTag));
      return false;
   }
};
//  Responsibilities:
//    • Authoritative registry of every basket position (PositionRecord[])
//    • Reconcile against MT5 live positions each tick
//    • Compute basket-level aggregates (BasketSnapshot)
//    • Close all tracked positions via CExecutionEngine::SubmitClose()
//    • Reset for next basket lifecycle
//══════════════════════════════════════════════════════════════════════

class COrderManager
{
private:
   CExecutionEngine*  m_execEngine;
   CLogger*           m_logger;
   int                m_magic;

   PositionRecord     m_positions[RTE_MAX_BASKET_POSITIONS];
   int                m_posCount;

   //--- Linear search by ticket; returns index or -1
   int FindByTicket(ulong ticket) const
   {
      for(int i = 0; i < m_posCount; i++)
         if(m_positions[i].ticket == ticket) return i;
      return -1;
   }

   //--- Remove entry at index by shifting array left
   void RemoveAt(int idx)
   {
      for(int i = idx; i < m_posCount - 1; i++)
         m_positions[i] = m_positions[i + 1];
      m_posCount--;
   }

public:
   COrderManager(CExecutionEngine* exec, CLogger* logger)
      : m_execEngine(exec), m_logger(logger), m_magic(0), m_posCount(0) {}

   void Init(int magic)
   {
      m_magic = magic;
      m_logger.Info("OrderMgr", StringFormat("Init — magic:%d", magic));
   }

   //--- Called by CRecoveryEngine immediately after CExecutionEngine::Submit() succeeds.
   //    Reads live position data from MT5 and stores in registry.
   void RegisterTicket(ulong ticket, const string contextTag)
   {
      if(m_posCount >= RTE_MAX_BASKET_POSITIONS)
      {
         m_logger.Error("OrderMgr",
            StringFormat("Registry full (%d). Cannot register ticket:%I64u",
            RTE_MAX_BASKET_POSITIONS, ticket));
         return;
      }
      if(FindByTicket(ticket) >= 0)
      {
         m_logger.Warn("OrderMgr",
            StringFormat("Ticket %I64u already registered.", ticket));
         return;
      }
      if(!PositionSelectByTicket(ticket))
      {
         m_logger.Error("OrderMgr",
            StringFormat("PositionSelectByTicket failed for %I64u tag:%s",
            ticket, contextTag));
         return;
      }

      PositionRecord rec;
      rec.ticket     = ticket;
      rec.direction  = (ENUM_ORDER_TYPE)PositionGetInteger(POSITION_TYPE);
      rec.openPrice  = PositionGetDouble(POSITION_OPEN_PRICE);
      rec.lotSize    = PositionGetDouble(POSITION_VOLUME);
      rec.openTime   = (datetime)PositionGetInteger(POSITION_TIME);
      rec.contextTag = contextTag;
      rec.currentPnL = PositionGetDouble(POSITION_PROFIT);

      m_positions[m_posCount++] = rec;
      m_logger.Info("OrderMgr",
         StringFormat("Registered ticket:%I64u dir:%s lot:%.2f tag:%s  [basket size:%d]",
         ticket,
         (rec.direction == ORDER_TYPE_BUY ? "BUY" : "SELL"),
         rec.lotSize, contextTag, m_posCount));
   }

   //--- Diff internal registry against live MT5 positions.
   //    Removes positions closed externally; refreshes P&L for remaining ones.
   //    Must be called at the start of every MONITOR / RECOVERY tick.
   void ReconcileWithBroker()
   {
      int i = 0;
      while(i < m_posCount)
      {
         if(!PositionSelectByTicket(m_positions[i].ticket))
         {
            // Position no longer exists — closed externally or by broker
            m_logger.Warn("OrderMgr",
               StringFormat("Ticket %I64u gone (external close). Removing from basket.",
               m_positions[i].ticket));
            RemoveAt(i);
            // Do not advance i — recheck the slot that just shifted into place
         }
         else
         {
            m_positions[i].currentPnL = PositionGetDouble(POSITION_PROFIT);
            i++;
         }
      }
   }

   //--- Aggregate all basket positions into a flat snapshot struct.
   BasketSnapshot GetBasketSnapshot() const
   {
      BasketSnapshot snap;
      snap.snapshotTime = TimeCurrent();

      double buyLots  = 0.0;
      double sellLots = 0.0;

      for(int i = 0; i < m_posCount; i++)
      {
         snap.positionCount++;
         snap.totalLots += m_positions[i].lotSize;
         snap.netPnlUSD += m_positions[i].currentPnL;

         if(m_positions[i].direction == ORDER_TYPE_BUY)
            buyLots  += m_positions[i].lotSize;
         else
            sellLots += m_positions[i].lotSize;

         if(snap.oldestOpenTime == 0 ||
            m_positions[i].openTime < snap.oldestOpenTime)
            snap.oldestOpenTime = m_positions[i].openTime;
      }

      if     (buyLots  > sellLots) snap.netDirection =  1;
      else if(sellLots > buyLots)  snap.netDirection = -1;
      else                          snap.netDirection =  0;

      return snap;
   }

   //--- Submit a close request for every registered position.
   //    Partial failures are logged; caller (CRecoveryEngine in CLOSE state)
   //    should call ReconcileWithBroker() afterwards to confirm.
   void CloseAll()
   {
      m_logger.Info("OrderMgr",
         StringFormat("CloseAll — closing %d position(s).", m_posCount));

      // Iterate over a snapshot of tickets since ReconcileWithBroker
      // may alter m_posCount during the loop
      ulong tickets[RTE_MAX_BASKET_POSITIONS];
      string tags  [RTE_MAX_BASKET_POSITIONS];
      int    count = m_posCount;
      for(int i = 0; i < count; i++)
      {
         tickets[i] = m_positions[i].ticket;
         tags[i]    = m_positions[i].contextTag;
      }

      for(int i = 0; i < count; i++)
      {
         TradeResult res;
         string closeTag = StringFormat("CLOSE_%I64u", tickets[i]);
         if(!m_execEngine.SubmitClose(tickets[i], closeTag, res))
         {
            m_logger.Error("OrderMgr",
               StringFormat("CloseAll: failed to close ticket:%I64u — retcode:%d",
               tickets[i], res.errorCode));
         }
      }
   }

   //--- Reset internal state for a new basket lifecycle.
   //    Call after all positions are confirmed closed (CLOSE→IDLE).
   void Reset()
   {
      m_logger.Info("OrderMgr",
         StringFormat("Reset — clearing %d record(s).", m_posCount));
      for(int i = 0; i < m_posCount; i++)
         m_positions[i] = PositionRecord();
      m_posCount = 0;
   }

   int  GetPositionCount() const { return m_posCount; }
   bool HasOpenPositions()  const { return m_posCount > 0; }

   //--- Read-only access to a specific record (used by recovery modules)
   bool GetRecord(int idx, PositionRecord& rec) const
   {
      if(idx < 0 || idx >= m_posCount) return false;
      rec = m_positions[idx];
      return true;
   }
};

//══════════════════════════════════════════════════════════════════════
// SECTION 8 — CBasketMonitor
//  Responsibilities:
//    • Receive a BasketSnapshot, compute ENUM_BASKET_STATUS
//    • Signal RECOVERY_TRIGGER when P_net < 0 AND
//      abs(P_net) >= RecoveryActivationUSD
//    • Feed basket P&L to CRiskGuard for hard stop evaluation
//══════════════════════════════════════════════════════════════════════

class CBasketMonitor
{
private:
   CLogger*    m_logger;
   CRiskGuard* m_riskGuard;
   double      m_recoveryActivationUSD;

   //--- Threshold hysteresis: once RECOVERY_TRIGGER fires we stay in that
   //    state until the basket recovers past zero, preventing rapid toggling
   //    back and forth when P&L hovers near the threshold.
   bool        m_triggerLatched;

public:
   CBasketMonitor(CRiskGuard* riskGuard, CLogger* logger)
      : m_riskGuard(riskGuard),
        m_logger(logger),
        m_recoveryActivationUSD(RTE_DEFAULT_RECOVERY_USD),
        m_triggerLatched(false) {}

   void Init(double recoveryActivationUSD)
   {
      m_recoveryActivationUSD = recoveryActivationUSD;
      m_logger.Info("BasketMon",
         StringFormat("Init — RecoveryActivationUSD: %.2f", recoveryActivationUSD));
   }

   //--- Primary evaluation called every MONITOR state tick.
   //    Also drives CRiskGuard hard stop check as a side effect.
   ENUM_BASKET_STATUS Evaluate(const BasketSnapshot& snap)
   {
      double pnl = snap.netPnlUSD;

      // Always feed current P&L to the hard stop guard
      m_riskGuard.CheckAndSetHardStop(pnl);

      // Healthy — basket is flat or profitable
      if(pnl >= 0.0)
      {
         if(m_triggerLatched)
         {
            m_logger.Info("BasketMon",
               StringFormat("Basket recovered to +%.2f USD — latch cleared.", pnl));
            m_triggerLatched = false;
         }
         return BASKET_HEALTHY;
      }

      double loss = MathAbs(pnl);

      // Recovery trigger: loss has reached the configured activation threshold
      if(loss >= m_recoveryActivationUSD)
      {
         if(!m_triggerLatched)
         {
            m_triggerLatched = true;
            m_logger.Warn("BasketMon",
               StringFormat("RECOVERY_TRIGGER — P&L: %.2f USD  threshold: %.2f USD  positions: %d",
               pnl, m_recoveryActivationUSD, snap.positionCount));
         }
         return BASKET_RECOVERY_TRIGGER;
      }

      // Minor drawdown — below threshold, no action yet
      m_logger.Debug("BasketMon",
         StringFormat("Minor drawdown — P&L: %.2f USD  (threshold: %.2f)",
         pnl, m_recoveryActivationUSD));
      return BASKET_DRAWDOWN_MINOR;
   }

   //--- Reset latch on CLOSE→IDLE so the next basket cycle starts fresh
   void Reset()
   {
      m_triggerLatched = false;
      m_logger.Debug("BasketMon", "Trigger latch reset for new basket cycle.");
   }

   bool IsTriggered()              const { return m_triggerLatched; }
   double GetActivationUSD()       const { return m_recoveryActivationUSD; }
};

//══════════════════════════════════════════════════════════════════════
// SECTION 9 — CEntryEngine
//  Responsibilities:
//    • Create and manage two EMA indicator handles (fast + slow)
//    • Detect crossover on last two COMPLETED bars (skips bar 0 — forming)
//    • Return SIGNAL_BUY / SIGNAL_SELL / SIGNAL_NONE each tick
//    • Release handles on Deinit()
//══════════════════════════════════════════════════════════════════════

class CEntryEngine
{
private:
   CLogger*         m_logger;
   int              m_handleFast;
   int              m_handleSlow;
   int              m_fastPeriod;
   int              m_slowPeriod;
   string           m_symbol;
   ENUM_TIMEFRAMES  m_timeframe;

   //--- Session filter (0/0 = disabled)
   int              m_sessionStartHour;
   int              m_sessionEndHour;
   bool             m_blockSundayRollover;

   //--- Returns true when server time is within the configured trading window.
   //    Passes-through when start==end==0 (filter disabled).
   bool IsWithinSession() const
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);

      // Block Sunday rollover window (17:00–18:00 server time, day-of-week 0 = Sunday)
      if(m_blockSundayRollover && dt.day_of_week == 0 &&
         dt.hour >= 17 && dt.hour < 18)
         return false;

      // Pass-through when session filter is disabled
      if(m_sessionStartHour == 0 && m_sessionEndHour == 0)
         return true;

      // Wrap-around sessions (e.g. 22:00–06:00) handled via OR
      if(m_sessionStartHour < m_sessionEndHour)
         return (dt.hour >= m_sessionStartHour && dt.hour < m_sessionEndHour);
      else
         return (dt.hour >= m_sessionStartHour || dt.hour < m_sessionEndHour);
   }

   //--- Read 3 values from a handle into a time-series buffer.
   //    buf[0] = bar 0 (forming), buf[1] = bar 1 (last closed),
   //    buf[2] = bar 2 (prior closed).
   //    Returns false if data unavailable.
   bool ReadBuffer(int handle, double& buf[]) const
   {
      ArraySetAsSeries(buf, true);
      return CopyBuffer(handle, 0, 0, 3, buf) == 3;
   }

public:
   CEntryEngine(CLogger* logger)
      : m_logger(logger),
        m_handleFast(INVALID_HANDLE),
        m_handleSlow(INVALID_HANDLE),
        m_fastPeriod(RTE_DEFAULT_FAST_EMA),
        m_slowPeriod(RTE_DEFAULT_SLOW_EMA),
        m_symbol(""),
        m_timeframe(PERIOD_CURRENT),
        m_sessionStartHour(0),
        m_sessionEndHour(0),
        m_blockSundayRollover(true) {}

   //--- Configure trading-hours filter.  Call before first OnTick().
   void SetSessionFilter(int startHour, int endHour, bool blockSunday)
   {
      m_sessionStartHour   = startHour;
      m_sessionEndHour     = endHour;
      m_blockSundayRollover = blockSunday;
      m_logger.Info("EntryEng",
         StringFormat("SessionFilter — start:%02d:00  end:%02d:00  blockSunday:%s",
         startHour, endHour, (blockSunday ? "true" : "false")));
   }

   //--- Creates indicator handles.  Returns false on failure.
   bool Init(const string symbol, ENUM_TIMEFRAMES tf,
             int fastPeriod, int slowPeriod)
   {
      m_symbol     = symbol;
      m_timeframe  = tf;
      m_fastPeriod = fastPeriod;
      m_slowPeriod = slowPeriod;

      m_handleFast = iMA(symbol, tf, fastPeriod, 0, MODE_EMA, PRICE_CLOSE);
      m_handleSlow = iMA(symbol, tf, slowPeriod, 0, MODE_EMA, PRICE_CLOSE);

      if(m_handleFast == INVALID_HANDLE || m_handleSlow == INVALID_HANDLE)
      {
         m_logger.Fatal("EntryEng",
            StringFormat("Failed to create EMA handles — fast:%d slow:%d err:%d",
            fastPeriod, slowPeriod, GetLastError()));
         return false;
      }

      m_logger.Info("EntryEng",
         StringFormat("Init — %s %s  EMA(%d) x EMA(%d)",
         symbol, EnumToString(tf), fastPeriod, slowPeriod));
      return true;
   }

   //--- Evaluate crossover using bars 1 and 2 (both completed, not forming).
   //    BUY  signal: fast was <= slow on bar 2, fast > slow on bar 1.
   //    SELL signal: fast was >= slow on bar 2, fast < slow on bar 1.
   ENUM_ENTRY_SIGNAL Evaluate() const
   {
      if(m_handleFast == INVALID_HANDLE || m_handleSlow == INVALID_HANDLE)
         return SIGNAL_NONE;

      if(!IsWithinSession())
         return SIGNAL_NONE;

      double fastBuf[3], slowBuf[3];

      if(!ReadBuffer(m_handleFast, fastBuf) ||
         !ReadBuffer(m_handleSlow, slowBuf))
      {
         m_logger.Warn("EntryEng", "Evaluate: insufficient indicator data.");
         return SIGNAL_NONE;
      }

      //--- bars[2] = older bar, bars[1] = last closed bar
      double fast2 = fastBuf[2], slow2 = slowBuf[2];   // prior bar
      double fast1 = fastBuf[1], slow1 = slowBuf[1];   // last closed bar

      bool crossedUp   = (fast2 <= slow2) && (fast1 > slow1);
      bool crossedDown = (fast2 >= slow2) && (fast1 < slow1);

      if(crossedUp)
      {
         m_logger.Info("EntryEng",
            StringFormat("BUY crossover — fast:%.5f > slow:%.5f", fast1, slow1));
         return SIGNAL_BUY;
      }
      if(crossedDown)
      {
         m_logger.Info("EntryEng",
            StringFormat("SELL crossover — fast:%.5f < slow:%.5f", fast1, slow1));
         return SIGNAL_SELL;
      }
      return SIGNAL_NONE;
   }

   //--- Release MT5 indicator handles on EA deinit
   void Deinit()
   {
      if(m_handleFast != INVALID_HANDLE)
      {
         IndicatorRelease(m_handleFast);
         m_handleFast = INVALID_HANDLE;
      }
      if(m_handleSlow != INVALID_HANDLE)
      {
         IndicatorRelease(m_handleSlow);
         m_handleSlow = INVALID_HANDLE;
      }
      m_logger.Debug("EntryEng", "Handles released.");
   }
};

//══════════════════════════════════════════════════════════════════════
// SECTION 10 — CRegimeDetector
//  Scoring model — each indicator awards 1 "trend point":
//    1. ADX (bar 1) > adxThreshold
//    2. |SMA slope bar1–bar2| in points > slopePtsThreshold
//    3. BB width (upper–lower)/middle at bar 1 > bbWidthThreshold
//    4. ATR[bar1] / mean(ATR[1..atrAvgBars]) > atrRatioThreshold
//
//  trendPoints 3-4 → TREND | 0-1 → RANGE | 2 → UNDETERMINED
//  UNDETERMINED returns last valid classification (hysteresis).
//══════════════════════════════════════════════════════════════════════

class CRegimeDetector
{
private:
   CLogger*         m_logger;
   string           m_symbol;
   ENUM_TIMEFRAMES  m_timeframe;

   //--- Indicator handles
   int  m_handleADX;   // iADX  — buffer 0 = ADX main line
   int  m_handleSMA;   // iMA   — SMA for slope (buffer 0)
   int  m_handleBB;    // iBands — buf 0=middle, 1=upper, 2=lower
   int  m_handleATR;   // iATR  — buffer 0 = ATR value

   //--- Score thresholds
   double m_adxThreshold;
   double m_slopePtsThreshold;   // Abs SMA change in MT5 points
   double m_bbWidthThreshold;    // (upper-lower)/middle ratio
   double m_atrRatioThreshold;   // ATR[1] / ATR_average
   int    m_atrAvgBars;          // How many bars for ATR average

   ENUM_REGIME m_lastRegime;     // Fallback for UNDETERMINED

   // ── Buffer helpers ───────────────────────────────────────────────

   //--- Read a single value from buffer at bar startBar (1 = last closed)
   bool ReadOne(int handle, int buffer, int startBar, double& val) const
   {
      double arr[1];
      if(CopyBuffer(handle, buffer, startBar, 1, arr) != 1) return false;
      val = arr[0];
      return true;
   }

   //--- Read count values starting at bar startBar into a time-series array
   bool ReadMany(int handle, int buffer, int startBar,
                 int count, double& arr[]) const
   {
      ArraySetAsSeries(arr, true);
      return CopyBuffer(handle, buffer, startBar, count, arr) == count;
   }

   // ── Individual scorers ───────────────────────────────────────────

   //--- Returns true (trend point) if ADX at bar 1 > threshold
   bool ScoreADX(double& adxVal) const
   {
      if(!ReadOne(m_handleADX, 0, 1, adxVal)) return false;
      return adxVal > m_adxThreshold;
   }

   //--- Returns true if absolute SMA slope (bar1 minus bar2) in points
   //    exceeds the threshold (steepness regardless of direction)
   bool ScoreSMASlope(double& slopeVal) const
   {
      double sma1, sma2;
      if(!ReadOne(m_handleSMA, 0, 1, sma1)) return false;
      if(!ReadOne(m_handleSMA, 0, 2, sma2)) return false;
      slopeVal = MathAbs(sma1 - sma2) / _Point;   // In MT5 points
      return slopeVal > m_slopePtsThreshold;
   }

   //--- Returns true if BB width ratio (upper-lower)/middle at bar 1
   //    exceeds threshold — wide bands signal trending volatility
   bool ScoreBBWidth(double& bbWidth) const
   {
      double mid, upper, lower;
      if(!ReadOne(m_handleBB, 0, 1, mid))   return false;
      if(!ReadOne(m_handleBB, 1, 1, upper)) return false;
      if(!ReadOne(m_handleBB, 2, 1, lower)) return false;
      if(mid <= 0.0) return false;
      bbWidth = (upper - lower) / mid;
      return bbWidth > m_bbWidthThreshold;
   }

   //--- Returns true if ATR at bar 1 is elevated relative to its
   //    rolling average — expanding range signals trend momentum
   bool ScoreATRRatio(double& atrRatio) const
   {
      double atrBuf[];
      if(!ReadMany(m_handleATR, 0, 1, m_atrAvgBars, atrBuf)) return false;

      double atrCurrent = atrBuf[0];   // bar 1 (most recent in series array)
      double atrSum     = 0.0;
      for(int i = 0; i < m_atrAvgBars; i++) atrSum += atrBuf[i];
      double atrAvg = atrSum / m_atrAvgBars;

      if(atrAvg <= 0.0) return false;
      atrRatio = atrCurrent / atrAvg;
      return atrRatio > m_atrRatioThreshold;
   }

public:
   CRegimeDetector(CLogger* logger)
      : m_logger(logger),
        m_symbol(""),
        m_timeframe(PERIOD_CURRENT),
        m_handleADX(INVALID_HANDLE),
        m_handleSMA(INVALID_HANDLE),
        m_handleBB(INVALID_HANDLE),
        m_handleATR(INVALID_HANDLE),
        m_adxThreshold(RTE_DEFAULT_ADX_THRESHOLD),
        m_slopePtsThreshold(RTE_DEFAULT_SLOPE_PTS),
        m_bbWidthThreshold(RTE_DEFAULT_BB_WIDTH),
        m_atrRatioThreshold(RTE_DEFAULT_ATR_RATIO),
        m_atrAvgBars(RTE_DEFAULT_ATR_AVG_BARS),
        m_lastRegime(REGIME_UNDETERMINED) {}

   //--- Creates all four indicator handles.  Returns false on any failure.
   bool Init(const string symbol, ENUM_TIMEFRAMES tf,
             int adxPeriod,  double adxThreshold,
             int smaPeriod,  double slopePtsThreshold,
             int bbPeriod,   double bbDeviation,  double bbWidthThreshold,
             int atrPeriod,  double atrRatioThreshold)
   {
      m_symbol             = symbol;
      m_timeframe          = tf;
      m_adxThreshold       = adxThreshold;
      m_slopePtsThreshold  = slopePtsThreshold;
      m_bbWidthThreshold   = bbWidthThreshold;
      m_atrRatioThreshold  = atrRatioThreshold;

      m_handleADX = iADX  (symbol, tf, adxPeriod);
      m_handleSMA = iMA   (symbol, tf, smaPeriod, 0, MODE_SMA, PRICE_CLOSE);
      m_handleBB  = iBands(symbol, tf, bbPeriod, 0, bbDeviation, PRICE_CLOSE);
      m_handleATR = iATR  (symbol, tf, atrPeriod);

      if(m_handleADX == INVALID_HANDLE || m_handleSMA == INVALID_HANDLE ||
         m_handleBB  == INVALID_HANDLE || m_handleATR == INVALID_HANDLE)
      {
         m_logger.Fatal("RegimeDet",
            StringFormat("Handle creation failed — ADX:%d SMA:%d BB:%d ATR:%d err:%d",
            m_handleADX, m_handleSMA, m_handleBB, m_handleATR, GetLastError()));
         return false;
      }

      m_logger.Info("RegimeDet",
         StringFormat("Init — %s ADX(%d/%.1f) SMA(%d/%.0fpts) BB(%d/%.1f/%.4f) ATR(%d/%.2f)",
         symbol, adxPeriod, adxThreshold, smaPeriod, slopePtsThreshold,
         bbPeriod, bbDeviation, bbWidthThreshold, atrPeriod, atrRatioThreshold));
      return true;
   }

   //--- Compute full regime score.  Call each tick while in STATE_DETECTING.
   RegimeScore Detect()
   {
      RegimeScore score;
      score.detectionTime = TimeCurrent();

      bool adxTrend   = ScoreADX     (score.adxValue);
      bool slopeTrend = ScoreSMASlope(score.smaSlope);
      bool bbTrend    = ScoreBBWidth (score.bbWidth);
      bool atrTrend   = ScoreATRRatio(score.atrRatio);

      score.trendPoints = (adxTrend ? 1 : 0) + (slopeTrend ? 1 : 0)
                        + (bbTrend  ? 1 : 0) + (atrTrend   ? 1 : 0);

      if     (score.trendPoints >= 3) score.classification = REGIME_TREND;
      else if(score.trendPoints <= 1) score.classification = REGIME_RANGE;
      else
      {
         //--- Tie (2/4): fall back to last known regime to avoid flip-flopping
         score.classification = (m_lastRegime != REGIME_UNDETERMINED)
                                 ? m_lastRegime
                                 : REGIME_UNDETERMINED;
      }

      if(score.classification != REGIME_UNDETERMINED)
         m_lastRegime = score.classification;

      m_logger.Info("RegimeDet",
         StringFormat("Score:%d/4 [ADX:%s SLP:%s BB:%s ATR:%s] → %s  "
                      "adx=%.1f slp=%.1f bbW=%.4f atrR=%.2f",
         score.trendPoints,
         (adxTrend   ? "1" : "0"), (slopeTrend ? "1" : "0"),
         (bbTrend    ? "1" : "0"), (atrTrend   ? "1" : "0"),
         EnumToString(score.classification),
         score.adxValue, score.smaSlope, score.bbWidth, score.atrRatio));

      return score;
   }

   void Deinit()
   {
      if(m_handleADX != INVALID_HANDLE) { IndicatorRelease(m_handleADX); m_handleADX = INVALID_HANDLE; }
      if(m_handleSMA != INVALID_HANDLE) { IndicatorRelease(m_handleSMA); m_handleSMA = INVALID_HANDLE; }
      if(m_handleBB  != INVALID_HANDLE) { IndicatorRelease(m_handleBB);  m_handleBB  = INVALID_HANDLE; }
      if(m_handleATR != INVALID_HANDLE) { IndicatorRelease(m_handleATR); m_handleATR = INVALID_HANDLE; }
      m_logger.Debug("RegimeDet", "Handles released.");
   }
};

//══════════════════════════════════════════════════════════════════════
// SECTION 11 — CTrendRecovery
//  Triggered when STATE_RECOVERY + regime == TREND.
//
//  Per-basket-cycle sequence (dedup ensures single execution):
//    Tick 1+: PlaceHedge()        — trade opposite to basket net direction
//    Tick 1+: PlaceContinuation() — second trade riding the same trend
//    Every tick: UpdateATRTrail() — trail SL of both recovery positions
//
//  Lots: basket.totalLots × hedgeRatio and contRatio (clamped by maxLot)
//  Trail distance: ATR[bar1] × atrMultiplier
//══════════════════════════════════════════════════════════════════════

class CTrendRecovery
{
private:
   CExecutionEngine*  m_execEngine;
   CRiskGuard*        m_riskGuard;
   CLogger*           m_logger;

   string             m_symbol;
   int                m_atrHandle;
   double             m_atrMultiplier;
   double             m_hedgeRatio;
   double             m_contRatio;
   double             m_maxLot;

   //--- State within one basket lifecycle
   bool   m_hedgePlaced;
   bool   m_contPlaced;
   ulong  m_hedgeTicket;
   ulong  m_contTicket;

   // ── Helpers ──────────────────────────────────────────────────────

   double ReadATR() const
   {
      double buf[1];
      if(CopyBuffer(m_atrHandle, 0, 1, 1, buf) != 1) return 0.0;
      return buf[0];
   }

   //--- Clamp a raw lot to broker limits and the configured cap
   double ClampLot(double rawLot) const
   {
      double lotMin  = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
      double lotMax  = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MAX);
      double lotStep = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);
      if(lotStep <= 0.0) lotStep = 0.01;
      double capped = MathMax(lotMin, MathMin(m_maxLot, MathMin(lotMax, rawLot)));
      return NormalizeDouble(MathRound(capped / lotStep) * lotStep, 2);
   }

   //--- Direction opposite to basket net → hedge rides the trend
   ENUM_ORDER_TYPE RecoveryDirection(const BasketSnapshot& snap) const
   {
      return (snap.netDirection >= 0) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   }

   // ── Trade placement ───────────────────────────────────────────────

   void PlaceHedge(const BasketSnapshot& snap)
   {
      if(m_hedgePlaced) return;
      if(!m_riskGuard.IsSpreadAcceptable(m_symbol))
      {
         m_logger.Warn("TrendRec", "PlaceHedge: spread too high — skipping.");
         return;
      }

      ENUM_ORDER_TYPE dir = RecoveryDirection(snap);
      double lot = ClampLot(snap.totalLots * m_hedgeRatio);

      TradeRequest req;
      req.symbol         = m_symbol;
      req.direction      = dir;
      req.orderType      = dir;
      req.lotSize        = lot;
      req.isLotValidated = true;
      req.contextTag     = "HEDGE_TREND";
      req.magicNumber    = RTE_MAGIC_NUMBER;

      TradeResult res;
      if(m_execEngine.Submit(req, res))
      {
         m_hedgeTicket = res.ticket;
         m_hedgePlaced = true;
         m_logger.Info("TrendRec",
            StringFormat("Hedge placed — %s %.2f lot  ticket:%I64u",
            (dir == ORDER_TYPE_BUY ? "BUY" : "SELL"), lot, res.ticket));
      }
   }

   void PlaceContinuation(const BasketSnapshot& snap)
   {
      if(m_contPlaced) return;
      if(!m_hedgePlaced) return;   // Continuation only after hedge is confirmed
      if(!m_riskGuard.IsSpreadAcceptable(m_symbol))
      {
         m_logger.Warn("TrendRec", "PlaceCont: spread too high — skipping.");
         return;
      }

      ENUM_ORDER_TYPE dir = RecoveryDirection(snap);
      double lot = ClampLot(snap.totalLots * m_contRatio);

      TradeRequest req;
      req.symbol         = m_symbol;
      req.direction      = dir;
      req.orderType      = dir;
      req.lotSize        = lot;
      req.isLotValidated = true;
      req.contextTag     = "CONT_TREND";
      req.magicNumber    = RTE_MAGIC_NUMBER;

      TradeResult res;
      if(m_execEngine.Submit(req, res))
      {
         m_contTicket = res.ticket;
         m_contPlaced = true;
         m_logger.Info("TrendRec",
            StringFormat("Continuation placed — %s %.2f lot  ticket:%I64u",
            (dir == ORDER_TYPE_BUY ? "BUY" : "SELL"), lot, res.ticket));
      }
   }

   // ── ATR trailing stop ─────────────────────────────────────────────

   void TrailPosition(ulong ticket, const string tag)
   {
      if(ticket == 0) return;
      if(!PositionSelectByTicket(ticket)) return;   // Already closed

      double atr = ReadATR();
      if(atr <= 0.0) return;

      ENUM_POSITION_TYPE posType =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      double trailDist = atr * m_atrMultiplier;

      double newSL;
      if(posType == POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
         newSL = bid - trailDist;
         // Only trail upward — never widen the stop
         if(currentSL > 0.0 && newSL <= currentSL) return;
      }
      else
      {
         double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
         newSL = ask + trailDist;
         // Only trail downward
         if(currentSL > 0.0 && newSL >= currentSL) return;
      }

      // Normalise to tick size
      double tickSize = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_SIZE);
      newSL = NormalizeDouble(MathRound(newSL / tickSize) * tickSize,
                              (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS));

      TradeResult res;
      m_execEngine.SubmitModify(ticket, newSL, currentTP, tag, res);
   }

   void UpdateATRTrail()
   {
      if(m_hedgePlaced) TrailPosition(m_hedgeTicket, "TRAIL_HEDGE");
      if(m_contPlaced)  TrailPosition(m_contTicket,  "TRAIL_CONT");
   }

public:
   CTrendRecovery(CExecutionEngine* exec, CRiskGuard* riskGuard, CLogger* logger)
      : m_execEngine(exec),
        m_riskGuard(riskGuard),
        m_logger(logger),
        m_symbol(""),
        m_atrHandle(INVALID_HANDLE),
        m_atrMultiplier(2.0),
        m_hedgeRatio(1.0),
        m_contRatio(0.5),
        m_maxLot(RTE_DEFAULT_MAX_LOT),
        m_hedgePlaced(false),
        m_contPlaced(false),
        m_hedgeTicket(0),
        m_contTicket(0) {}

   bool Init(const string symbol, ENUM_TIMEFRAMES tf, int atrPeriod,
             double atrMultiplier, double hedgeRatio,
             double contRatio,    double maxLot)
   {
      m_symbol        = symbol;
      m_atrMultiplier = atrMultiplier;
      m_hedgeRatio    = hedgeRatio;
      m_contRatio     = contRatio;
      m_maxLot        = maxLot;

      m_atrHandle = iATR(symbol, tf, atrPeriod);
      if(m_atrHandle == INVALID_HANDLE)
      {
         m_logger.Fatal("TrendRec",
            StringFormat("Failed to create ATR handle — period:%d err:%d",
            atrPeriod, GetLastError()));
         return false;
      }

      m_logger.Info("TrendRec",
         StringFormat("Init — ATR(%d) mult:%.1f hedgeR:%.2f contR:%.2f maxLot:%.2f",
         atrPeriod, atrMultiplier, hedgeRatio, contRatio, maxLot));
      return true;
   }

   //--- Called every tick while STATE_RECOVERY + REGIME_TREND.
   //    Places recovery trades on first pass; trails stops on all passes.
   void Process(const BasketSnapshot& snap)
   {
      PlaceHedge(snap);
      PlaceContinuation(snap);
      UpdateATRTrail();
   }

   //--- Reset state for next basket lifecycle
   void Reset()
   {
      m_hedgePlaced = false;
      m_contPlaced  = false;
      m_hedgeTicket = 0;
      m_contTicket  = 0;
      m_logger.Debug("TrendRec", "Reset for new basket cycle.");
   }

   void Deinit()
   {
      if(m_atrHandle != INVALID_HANDLE)
      {
         IndicatorRelease(m_atrHandle);
         m_atrHandle = INVALID_HANDLE;
      }
      m_logger.Debug("TrendRec", "Handle released.");
   }
};

//══════════════════════════════════════════════════════════════════════
// SECTION 12 — CRangeRecovery
//  Triggered when STATE_RECOVERY + regime == RANGE.
//
//  Strategy per basket cycle (dedup ensures single execution):
//    Wait until RSI confirms counter-direction exhaustion, then:
//    PlaceHedge() — trade opposite basket direction
//      TP  = hedge_entry ± (rangeSize × fibTPRatio)
//      SL  = 0.0 (hard stop from CRiskGuard is the safety net)
//    No further action; fixed TP manages exit automatically.
//
//  RSI filter:
//    Net LONG basket (losing)  → sell hedge when RSI[bar1] >= rsiSellThresh
//    Net SHORT basket (losing) → buy  hedge when RSI[bar1] <= rsiBuyThresh
//══════════════════════════════════════════════════════════════════════

class CRangeRecovery
{
private:
   CExecutionEngine*  m_execEngine;
   CRiskGuard*        m_riskGuard;
   CLogger*           m_logger;

   string             m_symbol;
   ENUM_TIMEFRAMES    m_timeframe;
   int                m_rsiHandle;
   int                m_rangeLookback;   // Bars for swing high/low range
   double             m_fibTPRatio;      // TP = rangeSize × ratio
   double             m_rsiSellThresh;   // RSI >= this → sell hedge allowed
   double             m_rsiBuyThresh;    // RSI <= this → buy  hedge allowed
   double             m_lotRatio;        // Hedge lot = totalLots × ratio
   double             m_maxLot;

   bool   m_hedgePlaced;
   ulong  m_hedgeTicket;

   // ── Helpers ──────────────────────────────────────────────────────

   double ReadRSI() const
   {
      double buf[1];
      if(CopyBuffer(m_rsiHandle, 0, 1, 1, buf) != 1) return 50.0;
      return buf[0];
   }

   //--- Compute swing high and low over m_rangeLookback completed bars.
   //    Returns false if data unavailable.
   bool ComputeRange(double& rangeHigh, double& rangeLow) const
   {
      double highs[], lows[];
      int copied = (int)MathMin(m_rangeLookback,
                                Bars(m_symbol, m_timeframe) - 1);
      if(copied < 2) return false;

      if(CopyHigh(m_symbol, m_timeframe, 1, copied, highs) != copied) return false;
      if(CopyLow (m_symbol, m_timeframe, 1, copied, lows)  != copied) return false;

      rangeHigh = highs[ArrayMaximum(highs, 0, copied)];
      rangeLow  = lows [ArrayMinimum(lows,  0, copied)];
      return (rangeHigh > rangeLow);
   }

   //--- Returns true when RSI confirms the hedge direction
   bool RSIConfirms(ENUM_ORDER_TYPE hedgeDir) const
   {
      double rsi = ReadRSI();
      if(hedgeDir == ORDER_TYPE_SELL) return rsi >= m_rsiSellThresh;
      return rsi <= m_rsiBuyThresh;
   }

   double ClampLot(double rawLot) const
   {
      double lotMin  = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
      double lotMax  = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MAX);
      double lotStep = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);
      if(lotStep <= 0.0) lotStep = 0.01;
      double capped = MathMax(lotMin, MathMin(m_maxLot, MathMin(lotMax, rawLot)));
      return NormalizeDouble(MathRound(capped / lotStep) * lotStep, 2);
   }

   // ── Trade placement ───────────────────────────────────────────────

   void PlaceHedge(const BasketSnapshot& snap)
   {
      if(m_hedgePlaced) return;

      ENUM_ORDER_TYPE dir = (snap.netDirection >= 0)
                            ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;

      // RSI must confirm before placing
      if(!RSIConfirms(dir))
      {
         m_logger.Debug("RangeRec",
            StringFormat("RSI not ready — rsi:%.1f sellThr:%.1f buyThr:%.1f",
            ReadRSI(), m_rsiSellThresh, m_rsiBuyThresh));
         return;
      }

      if(!m_riskGuard.IsSpreadAcceptable(m_symbol))
      {
         m_logger.Warn("RangeRec", "PlaceHedge: spread too high — waiting.");
         return;
      }

      double rangeHigh, rangeLow;
      if(!ComputeRange(rangeHigh, rangeLow))
      {
         m_logger.Error("RangeRec", "PlaceHedge: cannot compute range.");
         return;
      }

      double rangeSize = rangeHigh - rangeLow;
      int    digits    = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
      double tickSize  = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_SIZE);

      //--- Entry price and Fibonacci TP
      double entryPrice, tp;
      if(dir == ORDER_TYPE_SELL)
      {
         entryPrice = SymbolInfoDouble(m_symbol, SYMBOL_BID);
         tp = NormalizeDouble(
              MathRound((entryPrice - rangeSize * m_fibTPRatio) / tickSize)
              * tickSize, digits);
      }
      else
      {
         entryPrice = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
         tp = NormalizeDouble(
              MathRound((entryPrice + rangeSize * m_fibTPRatio) / tickSize)
              * tickSize, digits);
      }

      // Sanity: TP must be on the right side of entry
      if(dir == ORDER_TYPE_SELL && tp >= entryPrice) return;
      if(dir == ORDER_TYPE_BUY  && tp <= entryPrice) return;

      double lot = ClampLot(snap.totalLots * m_lotRatio);

      // Fallback SL: 50% of range size away from entry (caps unchecked adverse move)
      double sl;
      if(dir == ORDER_TYPE_SELL)
         sl = NormalizeDouble(
              MathRound((entryPrice + rangeSize * 0.5) / tickSize) * tickSize, digits);
      else
         sl = NormalizeDouble(
              MathRound((entryPrice - rangeSize * 0.5) / tickSize) * tickSize, digits);

      TradeRequest req;
      req.symbol         = m_symbol;
      req.direction      = dir;
      req.orderType      = dir;
      req.lotSize        = lot;
      req.takeProfit     = tp;
      req.stopLoss       = sl;
      req.isLotValidated = true;
      req.contextTag     = "HEDGE_RANGE";
      req.magicNumber    = RTE_MAGIC_NUMBER;

      TradeResult res;
      if(m_execEngine.Submit(req, res))
      {
         m_hedgeTicket = res.ticket;
         m_hedgePlaced = true;
         m_logger.Info("RangeRec",
            StringFormat("Hedge placed — %s %.2f lot  TP:%.5f  rangeSize:%.5f  "
                         "fibR:%.3f  ticket:%I64u",
            (dir == ORDER_TYPE_BUY ? "BUY" : "SELL"),
            lot, tp, rangeSize, m_fibTPRatio, res.ticket));
      }
   }

public:
   CRangeRecovery(CExecutionEngine* exec, CRiskGuard* riskGuard, CLogger* logger)
      : m_execEngine(exec),
        m_riskGuard(riskGuard),
        m_logger(logger),
        m_symbol(""),
        m_timeframe(PERIOD_CURRENT),
        m_rsiHandle(INVALID_HANDLE),
        m_rangeLookback(50),
        m_fibTPRatio(RTE_DEFAULT_FIB_TP_RATIO),
        m_rsiSellThresh(RTE_DEFAULT_RSI_OB),
        m_rsiBuyThresh(RTE_DEFAULT_RSI_OS),
        m_lotRatio(1.0),
        m_maxLot(RTE_DEFAULT_MAX_LOT),
        m_hedgePlaced(false),
        m_hedgeTicket(0) {}

   bool Init(const string symbol, ENUM_TIMEFRAMES tf,
             int rsiPeriod,     double rsiSellThresh, double rsiBuyThresh,
             int rangeLookback, double fibTPRatio,
             double lotRatio,   double maxLot)
   {
      m_symbol        = symbol;
      m_timeframe     = tf;
      m_rangeLookback = rangeLookback;
      m_fibTPRatio    = fibTPRatio;
      m_rsiSellThresh = rsiSellThresh;
      m_rsiBuyThresh  = rsiBuyThresh;
      m_lotRatio      = lotRatio;
      m_maxLot        = maxLot;

      m_rsiHandle = iRSI(symbol, tf, rsiPeriod, PRICE_CLOSE);
      if(m_rsiHandle == INVALID_HANDLE)
      {
         m_logger.Fatal("RangeRec",
            StringFormat("RSI handle failed — period:%d err:%d",
            rsiPeriod, GetLastError()));
         return false;
      }

      m_logger.Info("RangeRec",
         StringFormat("Init — RSI(%d) sellThr:%.1f buyThr:%.1f "
                      "range:%d bars  fibTP:%.3f  lotRatio:%.2f",
         rsiPeriod, rsiSellThresh, rsiBuyThresh,
         rangeLookback, fibTPRatio, lotRatio));
      return true;
   }

   //--- Called every tick while STATE_RECOVERY + REGIME_RANGE.
   //    Waits for RSI confirmation then places a single fixed-TP hedge.
   void Process(const BasketSnapshot& snap)
   {
      PlaceHedge(snap);
      // No trailing logic — fixed TP manages exit
   }

   void Reset()
   {
      m_hedgePlaced = false;
      m_hedgeTicket = 0;
      m_logger.Debug("RangeRec", "Reset for new basket cycle.");
   }

   void Deinit()
   {
      if(m_rsiHandle != INVALID_HANDLE)
      {
         IndicatorRelease(m_rsiHandle);
         m_rsiHandle = INVALID_HANDLE;
      }
      m_logger.Debug("RangeRec", "Handle released.");
   }
};

//══════════════════════════════════════════════════════════════════════
// SECTION 13 — CDashboardViewModel
//  Responsibilities:
//    • Aggregate EA state + basket metrics into one DashboardSnapshot
//    • Zero MT5 API calls inside CRecoveryEngine — state passed in
//    • Called by OnTick() AFTER g_recovEng.OnTick(); avoids circular dep
//══════════════════════════════════════════════════════════════════════

class CDashboardViewModel
{
private:
   COrderManager*  m_orderMgr;
   CRiskGuard*     m_riskGuard;
   CLogger*        m_logger;

public:
   CDashboardViewModel(COrderManager* orderMgr,
                       CRiskGuard*    riskGuard,
                       CLogger*       logger)
      : m_orderMgr(orderMgr),
        m_riskGuard(riskGuard),
        m_logger(logger) {}

   //--- Build a fresh DashboardSnapshot.
   //    state and regime come from CRecoveryEngine::GetState/GetRegime()
   //    so this class never needs to hold a back-pointer to CRecoveryEngine.
   DashboardSnapshot Refresh(ENUM_ENGINE_STATE state, ENUM_REGIME regime)
   {
      DashboardSnapshot snap;
      snap.engineState          = state;
      snap.regimeClassification = regime;
      snap.tickTime             = TimeCurrent();
      snap.lastLogMessage       = m_logger.GetLastMessage();
      snap.hardStopBreached     = m_riskGuard.IsHardStopBreached();
      snap.recoveryActive       = (state == STATE_RECOVERY);

      BasketSnapshot basket     = m_orderMgr.GetBasketSnapshot();
      snap.basketNetPnL         = basket.netPnlUSD;
      snap.positionCount        = basket.positionCount;

      // Spread stored as raw broker points (SYMBOL_SPREAD integer)
      snap.spreadCurrentPips    = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

      return snap;
   }
};

//══════════════════════════════════════════════════════════════════════
// SECTION 14 — CDashboardRenderer
//  Responsibilities:
//    • Create OBJ_LABEL chart objects on Init()
//    • Update text + colour each tick via Render(DashboardSnapshot)
//    • Fall back to Comment() if ObjectCreate fails
//    • Remove all chart objects on Deinit()
//
//  Layout (top-left corner, Consolas 9pt):
//    Row 0 — title bar
//    Row 1 — State
//    Row 2 — Regime
//    Row 3 — Basket P&L + position count
//    Row 4 — Spread
//    Row 5 — Hard Stop flag
//    Row 6 — Last log message (truncated)
//══════════════════════════════════════════════════════════════════════

class CDashboardRenderer
{
private:
   CLogger*  m_logger;
   string    m_prefix;        // Unique per EA instance: "RTE_{magic}_"
   bool      m_useObjects;    // Falls to Comment() when false
   int       m_xBase;
   int       m_yBase;
   int       m_rowH;          // Vertical gap between rows (pixels)
   int       m_fontSize;

   //--- Object name builder
   string N(const string suffix) const { return m_prefix + suffix; }

   // ── Label lifecycle ───────────────────────────────────────────────

   bool CreateLabel(const string name, int row) const
   {
      if(!ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0))
      {
         // Object may already exist from a previous attach — try resetting
         if(ObjectFind(0, name) < 0) return false;
      }
      ObjectSetInteger(0, name, OBJPROP_CORNER,    CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, m_xBase);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, m_yBase + row * m_rowH);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE,  m_fontSize);
      ObjectSetString (0, name, OBJPROP_FONT,      "Consolas");
      ObjectSetInteger(0, name, OBJPROP_BACK,      false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN,    true);
      return true;
   }

   void SetLabel(const string name, const string text, color clr) const
   {
      if(ObjectFind(0, name) >= 0)
      {
         ObjectSetString (0, name, OBJPROP_TEXT,  text);
         ObjectSetInteger(0, name, OBJPROP_COLOR, (long)clr);
      }
   }

   // ── Colour helpers ────────────────────────────────────────────────

   color StateColor(ENUM_ENGINE_STATE s) const
   {
      switch(s)
      {
         case STATE_IDLE:      return clrSilver;
         case STATE_ENTRY:     return clrYellow;
         case STATE_MONITOR:   return clrCyan;
         case STATE_DETECTING: return clrOrange;
         case STATE_RECOVERY:  return clrTomato;
         case STATE_CLOSE:     return clrOrchid;
         default:              return clrWhite;
      }
   }

   color RegimeColor(ENUM_REGIME r) const
   {
      switch(r)
      {
         case REGIME_TREND:        return clrLime;
         case REGIME_RANGE:        return clrDeepSkyBlue;
         case REGIME_UNDETERMINED: return clrSilver;
         default:                  return clrWhite;
      }
   }

   // ── String helpers ────────────────────────────────────────────────

   string StateName(ENUM_ENGINE_STATE s) const
   {
      switch(s)
      {
         case STATE_IDLE:      return "IDLE";
         case STATE_ENTRY:     return "ENTRY";
         case STATE_MONITOR:   return "MONITOR";
         case STATE_DETECTING: return "DETECTING";
         case STATE_RECOVERY:  return "RECOVERY";
         case STATE_CLOSE:     return "CLOSE";
         default:              return "?";
      }
   }

   string RegimeName(ENUM_REGIME r) const
   {
      switch(r)
      {
         case REGIME_TREND:        return "TREND";
         case REGIME_RANGE:        return "RANGE";
         case REGIME_UNDETERMINED: return "---";
         default:                  return "?";
      }
   }

   //--- Build the Comment() fallback string
   string BuildCommentText(const DashboardSnapshot& s) const
   {
      return StringFormat(
         "═══ RecoveryTradeEngine v%s ═══\n"
         "State  : %-10s\n"
         "Regime : %-10s\n"
         "P&L    : %+.2f USD  [%d pos]\n"
         "Spread : %.0f pts\n"
         "HStop  : %s\n"
         "Log    : %s",
         RTE_VERSION_STRING,
         StateName(s.engineState),
         RegimeName(s.regimeClassification),
         s.basketNetPnL, s.positionCount,
         s.spreadCurrentPips,
         (s.hardStopBreached ? "*** BREACHED ***" : "OK"),
         StringSubstr(s.lastLogMessage, 0, 80));
   }

public:
   CDashboardRenderer(CLogger* logger)
      : m_logger(logger),
        m_prefix(""),
        m_useObjects(true),
        m_xBase(10),
        m_yBase(20),
        m_rowH(18),
        m_fontSize(9) {}

   //--- Create all label objects.  Falls back to Comment() silently on failure.
   void Init(int magicNumber)
   {
      m_prefix = StringFormat("RTE_%d_", magicNumber);

      bool ok = CreateLabel(N("TITLE"),  0)
             && CreateLabel(N("STATE"),  1)
             && CreateLabel(N("REGIME"), 2)
             && CreateLabel(N("PNL"),    3)
             && CreateLabel(N("SPREAD"), 4)
             && CreateLabel(N("HSTOP"),  5)
             && CreateLabel(N("LOG"),    6);

      if(!ok)
      {
         m_useObjects = false;
         m_logger.Warn("Renderer",
            "Failed to create chart objects — using Comment() fallback.");
      }
      else
      {
         // Initialise title (static)
         SetLabel(N("TITLE"),
            StringFormat("═══ RecoveryTradeEngine v%s  [%s] ═══",
            RTE_VERSION_STRING, _Symbol),
            clrGold);
         m_logger.Info("Renderer", "Chart labels created.");
      }

      ChartRedraw(0);
   }

   //--- Update all labels with the latest snapshot.  Called every tick.
   void Render(const DashboardSnapshot& snap)
   {
      if(!m_useObjects)
      {
         Comment(BuildCommentText(snap));
         return;
      }

      //--- State
      SetLabel(N("STATE"),
         StringFormat("State  : %-10s", StateName(snap.engineState)),
         StateColor(snap.engineState));

      //--- Regime
      SetLabel(N("REGIME"),
         StringFormat("Regime : %-10s", RegimeName(snap.regimeClassification)),
         RegimeColor(snap.regimeClassification));

      //--- P&L
      color pnlClr = (snap.basketNetPnL >= 0.0) ? clrLime : clrTomato;
      SetLabel(N("PNL"),
         StringFormat("P&L    : %+.2f USD   [%d pos]",
         snap.basketNetPnL, snap.positionCount),
         pnlClr);

      //--- Spread
      color spClr = (snap.spreadCurrentPips <= RTE_DEFAULT_MAX_SPREAD)
                    ? clrSilver : clrOrange;
      SetLabel(N("SPREAD"),
         StringFormat("Spread : %.0f pts", snap.spreadCurrentPips),
         spClr);

      //--- Hard stop
      color hsClr  = snap.hardStopBreached ? clrRed    : clrSilver;
      string hsTxt = snap.hardStopBreached ? "HStop  : *** BREACHED ***"
                                           : "HStop  : OK";
      SetLabel(N("HSTOP"), hsTxt, hsClr);

      //--- Last log (strip timestamp prefix, truncate to 70 chars)
      string logTxt = StringSubstr(snap.lastLogMessage, 0, 70);
      SetLabel(N("LOG"), logTxt, clrDarkGray);

      ChartRedraw(0);
   }

   //--- Remove all EA label objects from the chart
   void Deinit()
   {
      string names[] = {"TITLE","STATE","REGIME","PNL","SPREAD","HSTOP","LOG"};
      for(int i = 0; i < ArraySize(names); i++)
         ObjectDelete(0, N(names[i]));
      Comment("");
      m_logger.Debug("Renderer", "Chart labels removed.");
   }
};

//══════════════════════════════════════════════════════════════════════
// SECTION 15 — CRecoveryEngine
//  State machine orchestrator.  The ONLY class that writes m_state.
//  Phases 5 : IDLE, ENTRY, MONITOR, CLOSE fully wired.
//  Phases 6+ : DETECTING and RECOVERY filled in progressively.
//══════════════════════════════════════════════════════════════════════

class CRecoveryEngine
{
private:
   //--- Module references (set in constructor; never NULL after Init)
   CExecutionEngine*  m_execEngine;
   COrderManager*     m_orderMgr;
   CEntryEngine*      m_entryEngine;
   CRiskGuard*        m_riskGuard;
   CBasketMonitor*    m_basketMon;
   CRegimeDetector*   m_regimeDetector;   // Set via SetRegimeDetector() — Phase 6
   CTrendRecovery*    m_trendRecovery;    // Set via SetTrendRecovery()  — Phase 7
   CRangeRecovery*    m_rangeRecovery;    // Set via SetRangeRecovery()  — Phase 8
   CLogger*           m_logger;

   //--- State machine — private; only methods of this class write it
   ENUM_ENGINE_STATE  m_state;

   //--- Entry parameters passed from OnInit
   string             m_symbol;
   double             m_entryStopPoints;  // For lot calculation
   bool               m_entryUseSL;       // Whether to place a hard SL on entry order
   int                m_magic;

   //--- Tracks the ticket submitted in IDLE so ENTRY can confirm it
   ulong              m_pendingTicket;

   //--- Regime selected in DETECTING, consumed by RECOVERY (Phases 6/7)
   ENUM_REGIME        m_activeRegime;

   //--- Counters reset per basket cycle
   int                m_closeAttempts;    // Ticks spent in STATE_CLOSE with positions still open
   int                m_detectingTicks;   // Ticks spent in STATE_DETECTING with REGIME_UNDETERMINED

   // ─── State transition helper ─────────────────────────────────────

   void SetState(ENUM_ENGINE_STATE next)
   {
      if(next == m_state) return;
      m_logger.Info("RecovEng",
         StringFormat("State: %s → %s",
         EnumToString(m_state), EnumToString(next)));
      m_state = next;
   }

   // ─── IDLE ────────────────────────────────────────────────────────
   //  Evaluate EMA crossover.  On signal: size lot, build TradeRequest,
   //  submit via ExecutionEngine, register ticket, move to ENTRY.

   void OnIdle()
   {
      ENUM_ENTRY_SIGNAL sig = m_entryEngine.Evaluate();
      if(sig == SIGNAL_NONE) return;

      // Spread guard before sizing
      if(!m_riskGuard.IsSpreadAcceptable(m_symbol))
      {
         m_logger.Warn("RecovEng", "IDLE: spread too high — skipping entry.");
         return;
      }

      double lot = m_riskGuard.ComputeLot(m_symbol, m_entryStopPoints);

      TradeRequest req;
      req.symbol         = m_symbol;
      req.direction      = (sig == SIGNAL_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      req.orderType      = req.direction;
      req.lotSize        = lot;
      req.isLotValidated = true;
      req.magicNumber    = m_magic;
      req.contextTag     = (sig == SIGNAL_BUY) ? "ENTRY_BUY" : "ENTRY_SELL";

      if(m_entryUseSL)
      {
         double price  = (sig == SIGNAL_BUY)
                        ? SymbolInfoDouble(m_symbol, SYMBOL_ASK)
                        : SymbolInfoDouble(m_symbol, SYMBOL_BID);
         double slDist = m_entryStopPoints * _Point;
         req.stopLoss  = (sig == SIGNAL_BUY) ? price - slDist : price + slDist;
      }

      TradeResult res;
      if(!m_execEngine.Submit(req, res))
      {
         m_logger.Warn("RecovEng",
            StringFormat("IDLE: entry submit failed reason:%d",
            (int)res.rejectionReason));
         return;
      }

      m_pendingTicket = res.ticket;
      m_orderMgr.RegisterTicket(res.ticket, req.contextTag);
      SetState(STATE_ENTRY);
   }

   // ─── ENTRY ───────────────────────────────────────────────────────
   //  One-tick confirmation that the position is live.
   //  Market orders fill synchronously, so this is almost always
   //  a single tick.  Falls back to IDLE if position disappeared.

   void OnEntry()
   {
      m_orderMgr.ReconcileWithBroker();
      if(m_orderMgr.GetPositionCount() > 0)
      {
         SetState(STATE_MONITOR);
         return;
      }
      m_logger.Warn("RecovEng",
         "ENTRY: pending position not found after fill — returning to IDLE.");
      m_pendingTicket = 0;
      SetState(STATE_IDLE);
   }

   // ─── MONITOR ─────────────────────────────────────────────────────
   //  Watch basket P&L every tick.
   //  Hard stop  → CLOSE
   //  Trigger    → DETECTING (Phase 6 fills this in)
   //  No positions remain → IDLE (externally closed)

   void OnMonitor()
   {
      m_orderMgr.ReconcileWithBroker();

      // All positions gone (SL hit, manual close, etc.)
      if(!m_orderMgr.HasOpenPositions())
      {
         m_logger.Info("RecovEng",
            "MONITOR: no open positions — resetting to IDLE.");
         ResetCycle();
         SetState(STATE_IDLE);
         return;
      }

      BasketSnapshot snap = m_orderMgr.GetBasketSnapshot();
      ENUM_BASKET_STATUS status = m_basketMon.Evaluate(snap);

      // Hard stop check (set inside CBasketMonitor::Evaluate as side-effect)
      if(m_riskGuard.IsHardStopBreached())
      {
         m_logger.Fatal("RecovEng",
            StringFormat("MONITOR: hard stop breached at %.2f USD — forcing CLOSE.",
            snap.netPnlUSD));
         SetState(STATE_CLOSE);
         return;
      }

      if(status == BASKET_RECOVERY_TRIGGER)
      {
         SetState(STATE_DETECTING);   // Phase 6 implements OnDetecting()
         return;
      }
   }

   // ─── DETECTING ───────────────────────────────────────────────────
   //  Score the market via CRegimeDetector.  Transition to RECOVERY once
   //  a definitive TREND or RANGE classification is returned.
   //  Stay in DETECTING if result is UNDETERMINED (retries each tick).

   void OnDetecting()
   {
      if(m_regimeDetector == NULL)
      {
         m_logger.Error("RecovEng",
            "DETECTING: CRegimeDetector not wired — cannot classify regime.");
         return;
      }

      // Hard stop re-check: basket may have deepened while detecting
      if(m_riskGuard.IsHardStopBreached())
      {
         m_logger.Fatal("RecovEng",
            "DETECTING: hard stop breached — aborting to CLOSE.");
         SetState(STATE_CLOSE);
         return;
      }

      RegimeScore score = m_regimeDetector.Detect();

      if(score.classification == REGIME_UNDETERMINED)
      {
         m_detectingTicks++;
         m_logger.Warn("RecovEng",
            StringFormat("DETECTING: regime undetermined (score 2/4) — tick %d/%d.",
            m_detectingTicks, Inp_MaxDetectingTicks));

         if(m_detectingTicks >= Inp_MaxDetectingTicks)
         {
            m_logger.Fatal("RecovEng",
               StringFormat("DETECTING: regime still undetermined after %d ticks — "
                            "forcing CLOSE to protect basket.", Inp_MaxDetectingTicks));
            SetState(STATE_CLOSE);
         }
         return;   // Stay in DETECTING (or just transitioned to CLOSE)
      }

      m_activeRegime = score.classification;
      m_logger.Info("RecovEng",
         StringFormat("DETECTING complete → %s  (trendPts:%d/4)",
         EnumToString(m_activeRegime), score.trendPoints));
      SetState(STATE_RECOVERY);
   }

   // ─── RECOVERY ────────────────────────────────────────────────────
   //  Route to CTrendRecovery (Phase 7) or CRangeRecovery (Phase 8)
   //  based on m_activeRegime.  Checks hard stop and recovery goal
   //  each tick.  Transitions to CLOSE on success or hard stop.

   void OnRecovery()
   {
      // Hard stop: forced exit regardless of recovery progress
      if(m_riskGuard.IsHardStopBreached())
      {
         m_logger.Fatal("RecovEng",
            "RECOVERY: hard stop breached — forcing CLOSE.");
         SetState(STATE_CLOSE);
         return;
      }

      m_orderMgr.ReconcileWithBroker();
      BasketSnapshot snap = m_orderMgr.GetBasketSnapshot();

      // Side-effect: feeds P&L to CRiskGuard hard stop check
      m_basketMon.Evaluate(snap);

      // Goal: basket P_net >= 0 → close everything
      if(snap.netPnlUSD >= 0.0)
      {
         m_logger.Info("RecovEng",
            StringFormat("RECOVERY complete — basket P&L: +%.2f USD → CLOSE.",
            snap.netPnlUSD));
         SetState(STATE_CLOSE);
         return;
      }

      // Dispatch to regime-specific recovery module
      if(m_activeRegime == REGIME_TREND)
      {
         if(m_trendRecovery != NULL)
            m_trendRecovery.Process(snap);
         else
            m_logger.Warn("RecovEng",
               "RECOVERY(TREND): CTrendRecovery not wired (Phase 7).");
      }
      else if(m_activeRegime == REGIME_RANGE)
      {
         if(m_rangeRecovery != NULL)
            m_rangeRecovery.Process(snap);
         else
            m_logger.Warn("RecovEng",
               "RECOVERY(RANGE): CRangeRecovery not wired (Phase 8).");
      }
      else
      {
         m_logger.Error("RecovEng",
            "RECOVERY: active regime is UNDETERMINED — cannot dispatch.");
      }
   }

   // ─── CLOSE ───────────────────────────────────────────────────────
   //  Close all basket positions.  Retry each tick until empty.
   //  Then reset everything and return to IDLE.

   void OnClose()
   {
      m_orderMgr.CloseAll();
      m_orderMgr.ReconcileWithBroker();

      if(!m_orderMgr.HasOpenPositions())
      {
         m_logger.Info("RecovEng", "CLOSE: all positions confirmed closed.");
         ResetCycle();
         SetState(STATE_IDLE);
         return;
      }

      m_closeAttempts++;
      m_logger.Warn("RecovEng",
         StringFormat("CLOSE: %d position(s) still open — attempt %d/%d.",
         m_orderMgr.GetPositionCount(), m_closeAttempts, Inp_MaxCloseAttempts));

      if(m_closeAttempts >= Inp_MaxCloseAttempts)
      {
         m_logger.Fatal("RecovEng",
            StringFormat("CLOSE: max close attempts (%d) reached — forcing cycle reset. "
                         "Manual position check required!", Inp_MaxCloseAttempts));
         Alert(StringFormat("RecoveryTradeEngine: CloseAll failed after %d attempts on %s. "
                            "Check open positions manually.", Inp_MaxCloseAttempts, m_symbol));
         ResetCycle();
         SetState(STATE_IDLE);
      }
   }

   // ─── Cycle reset ─────────────────────────────────────────────────

   void ResetCycle()
   {
      m_execEngine.ClearRegistry();
      m_orderMgr.Reset();
      m_basketMon.Reset();
      m_riskGuard.ClearHardStop();
      if(m_trendRecovery != NULL) m_trendRecovery.Reset();
      if(m_rangeRecovery != NULL) m_rangeRecovery.Reset();
      m_pendingTicket  = 0;
      m_activeRegime   = REGIME_UNDETERMINED;
      m_closeAttempts  = 0;
      m_detectingTicks = 0;
      m_logger.Info("RecovEng", "Basket cycle reset complete.");
   }

public:
   CRecoveryEngine(CExecutionEngine* exec,
                   COrderManager*    orderMgr,
                   CEntryEngine*     entryEng,
                   CRiskGuard*       riskGuard,
                   CBasketMonitor*   basketMon,
                   CLogger*          logger)
      : m_execEngine(exec),
        m_orderMgr(orderMgr),
        m_entryEngine(entryEng),
        m_riskGuard(riskGuard),
        m_basketMon(basketMon),
        m_regimeDetector(NULL),
        m_trendRecovery(NULL),
        m_rangeRecovery(NULL),
        m_logger(logger),
        m_state(STATE_IDLE),
        m_symbol(""),
        m_entryStopPoints(200),
        m_entryUseSL(false),
        m_magic(RTE_MAGIC_NUMBER),
        m_pendingTicket(0),
        m_activeRegime(REGIME_UNDETERMINED),
        m_closeAttempts(0),
        m_detectingTicks(0) {}

   void Init(const string symbol, double entryStopPoints,
             bool entryUseSL, int magic)
   {
      m_symbol          = symbol;
      m_entryStopPoints = entryStopPoints;
      m_entryUseSL      = entryUseSL;
      m_magic           = magic;
      m_logger.Info("RecovEng",
         StringFormat("Init — symbol:%s stopPts:%.0f useSL:%s magic:%d",
         symbol, entryStopPoints,
         (entryUseSL ? "true" : "false"), magic));
   }

   //--- Called exclusively from OnTick() in Section 16
   void OnTick()
   {
      switch(m_state)
      {
         case STATE_IDLE:      OnIdle();      break;
         case STATE_ENTRY:     OnEntry();     break;
         case STATE_MONITOR:   OnMonitor();   break;
         case STATE_DETECTING: OnDetecting(); break;
         case STATE_RECOVERY:  OnRecovery();  break;
         case STATE_CLOSE:     OnClose();     break;
      }
   }

   //--- Phase 6: inject CRegimeDetector after construction
   void SetRegimeDetector(CRegimeDetector* d)
   {
      m_regimeDetector = d;
      m_logger.Info("RecovEng", "CRegimeDetector wired.");
   }

   //--- Phase 7: inject CTrendRecovery after construction
   void SetTrendRecovery(CTrendRecovery* t)
   {
      m_trendRecovery = t;
      m_logger.Info("RecovEng", "CTrendRecovery wired.");
   }

   //--- Phase 8: inject CRangeRecovery after construction
   void SetRangeRecovery(CRangeRecovery* r)
   {
      m_rangeRecovery = r;
      m_logger.Info("RecovEng", "CRangeRecovery wired.");
   }

   ENUM_ENGINE_STATE GetState()   const { return m_state; }
   ENUM_REGIME       GetRegime()  const { return m_activeRegime; }
};

//══════════════════════════════════════════════════════════════════════
// SECTION 16 — INPUT PARAMETERS & EA ENTRY POINTS
//══════════════════════════════════════════════════════════════════════

//--- Entry
input group              "════ Entry Settings ════"
input int              Inp_FastEMA         = RTE_DEFAULT_FAST_EMA;    // Fast EMA period
input int              Inp_SlowEMA         = RTE_DEFAULT_SLOW_EMA;    // Slow EMA period
input ENUM_TIMEFRAMES  Inp_Timeframe       = PERIOD_CURRENT;          // EMA timeframe (0 = chart TF)
input int              Inp_EntryStopPoints = 200;                     // Stop distance (points) for lot sizing
input bool             Inp_EntryUseSL      = false;                   // Place hard SL on entry order

//--- Session Filter
input group              "════ Session Filter ════"
input int              Inp_SessionStartHour    = 0;     // Trading session start (server hour, 0=disabled)
input int              Inp_SessionEndHour      = 0;     // Trading session end   (server hour, 0=disabled)
input bool             Inp_BlockSundayRollover = true;  // Block entries 17:00–18:00 Sunday (server time)

//--- Recovery
input group              "════ Recovery Settings ════"
input double Inp_RecoveryActivationUSD = RTE_DEFAULT_RECOVERY_USD;    // USD drawdown to trigger recovery
input double Inp_HardStopUSD           = RTE_DEFAULT_HARD_STOP_USD;   // USD loss → force close all
input int    Inp_MaxCloseAttempts      = 10;                          // Ticks in STATE_CLOSE before forced reset + alert
input int    Inp_MaxDetectingTicks     = 20;                          // Ticks in STATE_DETECTING before forcing CLOSE

//--- Risk
input group              "════ Risk Settings ════"
input double Inp_RiskPercent           = RTE_DEFAULT_RISK_PERCENT;    // % of balance per trade
input double Inp_MaxLot                = RTE_DEFAULT_MAX_LOT;         // Hard lot cap
input double Inp_MaxSpreadPoints       = RTE_DEFAULT_MAX_SPREAD;      // Max spread in points
input ENUM_ORDER_TYPE_FILLING Inp_FillingMode = ORDER_FILLING_FOK;    // Order filling mode (FOK/IOC/Return)

//--- Regime Detection
input group              "════ Regime Detection ════"
input int    Inp_ADXPeriod             = RTE_DEFAULT_ADX_PERIOD;
input double Inp_ADXThreshold          = RTE_DEFAULT_ADX_THRESHOLD;   // ADX above = trend point
input int    Inp_SMAPeriod             = RTE_DEFAULT_SMA_PERIOD;      // For slope calculation
input double Inp_SlopePtsThreshold     = RTE_DEFAULT_SLOPE_PTS;       // Min |SMA slope| in points
input int    Inp_BBPeriod              = RTE_DEFAULT_BB_PERIOD;
input double Inp_BBDeviation           = RTE_DEFAULT_BB_DEVIATION;
input double Inp_BBWidthThreshold      = RTE_DEFAULT_BB_WIDTH;        // Min (upper-lower)/middle
input int    Inp_ATRPeriod             = RTE_DEFAULT_ATR_PERIOD;
input double Inp_ATRRatioThreshold     = RTE_DEFAULT_ATR_RATIO;       // Min ATR/ATR-avg ratio

//--- Trend Recovery
input group              "════ Trend Recovery ════"
input double Inp_TrendHedgeRatio       = 1.0;    // Hedge lot = basket lots × ratio
input double Inp_TrendContRatio        = 0.5;    // Continuation lot = basket lots × ratio
input double Inp_TrendATRMultiplier    = 2.0;    // Trailing stop distance = ATR × multiplier

//--- Range Recovery
input group              "════ Range Recovery ════"
input int    Inp_RangeLookback         = 50;                          // Bars for swing H/L range
input double Inp_RangeFibTPRatio       = RTE_DEFAULT_FIB_TP_RATIO;   // TP = rangeSize × ratio
input double Inp_RangeLotRatio         = 1.0;                        // Hedge lot = basket lots × ratio

//--- RSI (Range Recovery filter)
input group              "════ RSI Settings ════"
input int    Inp_RSIPeriod             = RTE_DEFAULT_RSI_PERIOD;
input double Inp_RSI_OB                = RTE_DEFAULT_RSI_OB;          // Overbought → sell hedge
input double Inp_RSI_OS                = RTE_DEFAULT_RSI_OS;          // Oversold   → buy hedge

//--- Logging
input group              "════ Logging ════"
input ENUM_LOG_LEVEL Inp_LogLevel      = LOG_INFO;                    // Minimum log level to display

//--- Global instances — constructed bottom-up: CLogger first, CRecoveryEngine last
CLogger*          g_logger      = NULL;
CRiskGuard*       g_riskGuard   = NULL;
CExecutionEngine* g_execEngine  = NULL;
COrderManager*    g_orderMgr    = NULL;
CBasketMonitor*   g_basketMon   = NULL;
CEntryEngine*     g_entryEng    = NULL;
CRegimeDetector*  g_regimeDet   = NULL;
CTrendRecovery*      g_trendRec    = NULL;
CRangeRecovery*      g_rangeRec    = NULL;
CDashboardViewModel* g_dashVM      = NULL;
CDashboardRenderer*  g_dashRend    = NULL;
CRecoveryEngine*     g_recovEng    = NULL;

//+------------------------------------------------------------------+
int OnInit()
{
   //--- 1. Logger always first
   g_logger = new CLogger();
   g_logger.SetMinLevel(Inp_LogLevel);
   g_logger.Info("EA", StringFormat("RecoveryTradeEngine v%s starting on %s",
                                     RTE_VERSION_STRING, _Symbol));

   //--- 2. Input validation
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
   if(Inp_EntryStopPoints <= 0)
   {
      g_logger.Fatal("EA", "EntryStopPoints must be > 0");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(Inp_TrendHedgeRatio <= 0.0)
   {
      g_logger.Fatal("EA", "TrendHedgeRatio must be > 0");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(Inp_TrendContRatio <= 0.0)
   {
      g_logger.Fatal("EA", "TrendContRatio must be > 0");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(Inp_RangeLookback < 10)
   {
      g_logger.Fatal("EA", "RangeLookback must be >= 10");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(Inp_RangeFibTPRatio <= 0.0)
   {
      g_logger.Fatal("EA", "RangeFibTPRatio must be > 0");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(Inp_ATRRatioThreshold <= 0.0)
   {
      g_logger.Fatal("EA", "ATRRatioThreshold must be > 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   //--- 3. Log validated configuration
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

   //--- 4. CRiskGuard
   g_riskGuard = new CRiskGuard(g_logger);
   g_riskGuard.Init(Inp_MaxSpreadPoints, Inp_MaxLot,
                    Inp_RiskPercent,     Inp_HardStopUSD);

   //--- 5. CExecutionEngine (depends on CRiskGuard)
   g_execEngine = new CExecutionEngine(g_riskGuard, g_logger);
   g_execEngine.Init(RTE_MAGIC_NUMBER, RTE_DEFAULT_SLIPPAGE, Inp_FillingMode);

   //--- 6. COrderManager (depends on CExecutionEngine)
   g_orderMgr = new COrderManager(g_execEngine, g_logger);
   g_orderMgr.Init(RTE_MAGIC_NUMBER);

   //--- 7. CBasketMonitor (depends on CRiskGuard)
   g_basketMon = new CBasketMonitor(g_riskGuard, g_logger);
   g_basketMon.Init(Inp_RecoveryActivationUSD);

   //--- 8. CEntryEngine
   g_entryEng = new CEntryEngine(g_logger);
   if(!g_entryEng.Init(_Symbol, Inp_Timeframe, Inp_FastEMA, Inp_SlowEMA))
      return INIT_FAILED;
   g_entryEng.SetSessionFilter(Inp_SessionStartHour, Inp_SessionEndHour,
                                Inp_BlockSundayRollover);

   //--- 9. CRegimeDetector
   g_regimeDet = new CRegimeDetector(g_logger);
   if(!g_regimeDet.Init(_Symbol, Inp_Timeframe,
                        Inp_ADXPeriod,   Inp_ADXThreshold,
                        Inp_SMAPeriod,   Inp_SlopePtsThreshold,
                        Inp_BBPeriod,    Inp_BBDeviation, Inp_BBWidthThreshold,
                        Inp_ATRPeriod,   Inp_ATRRatioThreshold))
      return INIT_FAILED;

   //--- 10. CTrendRecovery (depends on CExecutionEngine + CRiskGuard)
   g_trendRec = new CTrendRecovery(g_execEngine, g_riskGuard, g_logger);
   if(!g_trendRec.Init(_Symbol, Inp_Timeframe, Inp_ATRPeriod,
                       Inp_TrendATRMultiplier, Inp_TrendHedgeRatio,
                       Inp_TrendContRatio, Inp_MaxLot))
      return INIT_FAILED;

   //--- 11. CRangeRecovery (depends on CExecutionEngine + CRiskGuard)
   g_rangeRec = new CRangeRecovery(g_execEngine, g_riskGuard, g_logger);
   if(!g_rangeRec.Init(_Symbol, Inp_Timeframe,
                       Inp_RSIPeriod,    Inp_RSI_OB,     Inp_RSI_OS,
                       Inp_RangeLookback, Inp_RangeFibTPRatio,
                       Inp_RangeLotRatio, Inp_MaxLot))
      return INIT_FAILED;

   //--- 12. CDashboardViewModel (depends on COrderManager + CRiskGuard)
   g_dashVM = new CDashboardViewModel(g_orderMgr, g_riskGuard, g_logger);

   //--- 13. CDashboardRenderer
   g_dashRend = new CDashboardRenderer(g_logger);
   g_dashRend.Init(RTE_MAGIC_NUMBER);

   //--- 14. CRecoveryEngine (constructed last — depends on all modules above)
   g_recovEng = new CRecoveryEngine(
      g_execEngine, g_orderMgr, g_entryEng,
      g_riskGuard,  g_basketMon, g_logger);
   g_recovEng.Init(_Symbol, Inp_EntryStopPoints, Inp_EntryUseSL, RTE_MAGIC_NUMBER);
   g_recovEng.SetRegimeDetector(g_regimeDet);
   g_recovEng.SetTrendRecovery(g_trendRec);
   g_recovEng.SetRangeRecovery(g_rangeRec);

   g_logger.Info("EA", "RecoveryTradeEngine v" RTE_VERSION_STRING " ready — all modules active.");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(g_recovEng != NULL)
      g_recovEng.OnTick();

   // Dashboard refreshed every tick after state machine runs
   if(g_dashVM != NULL && g_dashRend != NULL && g_recovEng != NULL)
   {
      DashboardSnapshot snap = g_dashVM.Refresh(
         g_recovEng.GetState(),
         g_recovEng.GetRegime());
      g_dashRend.Render(snap);
   }
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_logger != NULL)
      g_logger.Info("EA", StringFormat("OnDeinit. Reason: %d", reason));

   //--- Delete in reverse construction order (14 → 1)
   if(g_recovEng  != NULL) { delete g_recovEng;                          g_recovEng  = NULL; }
   if(g_dashRend  != NULL) { g_dashRend.Deinit();  delete g_dashRend;    g_dashRend  = NULL; }
   if(g_dashVM    != NULL) { delete g_dashVM;                            g_dashVM    = NULL; }
   if(g_trendRec  != NULL) { g_trendRec.Deinit();  delete g_trendRec;   g_trendRec  = NULL; }
   if(g_rangeRec  != NULL) { g_rangeRec.Deinit();  delete g_rangeRec;   g_rangeRec  = NULL; }
   if(g_regimeDet != NULL) { g_regimeDet.Deinit(); delete g_regimeDet;  g_regimeDet = NULL; }
   if(g_entryEng  != NULL) { g_entryEng.Deinit();  delete g_entryEng;   g_entryEng  = NULL; }
   if(g_basketMon != NULL) { delete g_basketMon;   g_basketMon = NULL; }
   if(g_orderMgr  != NULL) { delete g_orderMgr;    g_orderMgr  = NULL; }
   if(g_execEngine!= NULL) { delete g_execEngine;  g_execEngine= NULL; }
   if(g_riskGuard != NULL) { delete g_riskGuard;   g_riskGuard = NULL; }

   if(g_logger != NULL) { delete g_logger; g_logger = NULL; }
}
