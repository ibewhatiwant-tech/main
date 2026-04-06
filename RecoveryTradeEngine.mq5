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
   void Init(int magicNumber, int slippagePoints)
   {
      m_trade.SetExpertMagicNumber(magicNumber);
      m_trade.SetDeviationInPoints(slippagePoints);
      m_trade.SetTypeFilling(ORDER_FILLING_FOK);   // Adjust per broker if needed
      m_trade.LogLevel(LOG_LEVEL_ERRORS);          // Internal CTrade logging
      m_logger.Info("ExecEngine",
         StringFormat("Init — magic:%d slippage:%d pts", magicNumber, slippagePoints));
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
};

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

//--- Global instances — constructed bottom-up: CLogger first, CRecoveryEngine last
CLogger*          g_logger    = NULL;
CRiskGuard*       g_riskGuard = NULL;
CExecutionEngine* g_execEngine = NULL;
// Further pointers added per phase

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
   g_execEngine.Init(RTE_MAGIC_NUMBER, RTE_DEFAULT_SLIPPAGE);

   //--- Phases 4-10: COrderManager, CBasketMonitor, CEntryEngine,
   //    CRegimeDetector, CTrendRecovery, CRangeRecovery,
   //    CDashboardViewModel, CDashboardRenderer, CRecoveryEngine
   //    — instantiated as each phase is implemented.

   g_logger.Info("EA", "Phase 3 ready — RiskGuard + ExecutionEngine online.");
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
      g_logger.Info("EA", StringFormat("OnDeinit. Reason: %d", reason));

   //--- Delete in reverse construction order
   if(g_execEngine != NULL) { delete g_execEngine; g_execEngine = NULL; }
   if(g_riskGuard  != NULL) { delete g_riskGuard;  g_riskGuard  = NULL; }
   // Phases 4-10 pointers deleted here as they are added

   if(g_logger != NULL) { delete g_logger; g_logger = NULL; }
}
