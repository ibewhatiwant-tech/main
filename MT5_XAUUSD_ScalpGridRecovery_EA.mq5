//+------------------------------------------------------------------+
//|                    MT5_XAUUSD_ScalpGridRecovery_EA.mq5           |
//|  Scalping + Grid + Recovery EA — Hedging account, XAUUSD          |
//|  Built from: MT5_XAUUSD_ScalpGridRecovery_EA_Architecture.md (SA) |
//|              MT5_XAUUSD_ScalpGridRecovery_EA_DetailedDesignSpec  |
//|              .md (DDS)                                            |
//|                                                                    |
//|  PHASE 1 of 6 — inputs + state only.                              |
//|  No signal generation, no risk permission logic, no order         |
//|  submission yet (Phase 2 adds orders; Phase 3 signals; Phase 4    |
//|  risk; Phase 5 grid/recovery; Phase 6 logging).                   |
//+------------------------------------------------------------------+
#property version   "0.1"
#property description "XAUUSD Scalp/Grid/Recovery EA (Hedging account) — Phase 1: inputs + state"

//+------------------------------------------------------------------+
//| INPUTS                                                            |
//| Fixed section order (DDS §1, §6.1): inputs -> state -> signals -> |
//| risk -> orders -> grid/recovery -> logging.                       |
//+------------------------------------------------------------------+

// REQ: INP-1
input group "Risk"
input double InpMaxDailyLossPct              = 3.0;   // % of balance, daily
input double InpMaxTotalDrawdownPct          = 10.0;  // % of balance/equity, cumulative
input double InpHardEquityStopPct            = 15.0;  // equity DD that forces flatten+disable
input double InpMaxBasketLossMoney           = 200.0; // account-currency floating loss per basket
input double InpMaxFloatingLossPct           = 5.0;   // % of equity, floating
input double InpMaxExposureLots              = 2.0;   // this instance, symbol+magic
input double InpMaxAccountExposureLots       = 5.0;   // shared across EA instances (§5.6.2)
input double InpMaxAccountFloatingLossMoney  = 1000.0;
input double InpMaxMarginUsagePct            = 50.0;
input double InpMinFreeMarginPct             = 40.0;
input double InpMaxAggregateRiskPercent      = 1.0;   // correlation-aware news exposure (§9.3)

// REQ: INP-2
input group "Execution"
input double InpMaxSpreadPoints              = 80.0;
input double InpMaxSlippagePoints            = 50.0;
input double InpMaxEntrySlippagePoints       = 50.0;
input int    InpMaxDeviationPoints           = 30;
input int    InpMaxOrderRetries              = 2;
input int    InpMaxPriceRetries              = 1;
input int    InpRetryBackoffMs               = 500;
input int    InpRetryCooldownSeconds         = 3;
input double InpFreezeSafetyPoints           = 20.0;
input long   InpMagicNumber                  = 26071101;

// REQ: INP-3
input group "Session"
input string InpEntrySessionStart            = "07:00"; // broker-server-time HH:MM (SIG-3)
input string InpEntrySessionEnd              = "19:00";
input string InpReduceOnlySessionStart       = "19:00";
input string InpReduceOnlySessionEnd         = "23:00";
input bool   InpForcedFlatBeforeWeekend      = true;
input int    InpWeekendFlattenEscalationMinutes = 5;

// REQ: INP-4
input group "Signal"
input ENUM_TIMEFRAMES InpSignalTimeframe     = PERIOD_M5;
input ENUM_TIMEFRAMES InpTrendTimeframe      = PERIOD_H1;
input int    InpAtrPeriod                    = 14;
input int    InpEmaFastPeriod                = 20;
input int    InpEmaSlowPeriod                = 50;
input int    InpEma200Period                 = 200;
input int    InpRsiPeriod                    = 14;
input int    InpAdxPeriod                    = 14;
input double InpMinSignalScore               = 0.6;
input int    InpMaxSignalAgeSeconds          = 60;

// REQ: INP-5
input group "Recovery"
input bool   InpEnableGrid                   = true;
input bool   InpEnableHedge                  = false;
input int    InpMaxRecoveryDepth             = 4;
input double InpGridStepATRMultiplier        = 1.5;
input double InpRecoveryLotMultiplier        = 1.5;
input double InpMaxRecoveryLots              = 1.0;
input double InpMinUnwindProfitMoney         = 5.0;
input double InpBaseLot                      = 0.01;

// REQ: INP-6
input group "News Governor"
input int    InpNewsPreLockSeconds           = 300;
input int    InpNewsShockSeconds             = 120;
input int    InpNewsStabilizeSeconds         = 600;

// REQ: INP-7
input group "Operational"
input bool   InpStrictPropRiskMode           = true;
input bool   InpAuditRequired                = true;
input string InpKillSwitchPrefix             = "XAUEA";

//+------------------------------------------------------------------+
//| STATE — enums (DDS §3.1)                                         |
//+------------------------------------------------------------------+

// REQ: FSM-1
enum EEAState
{
   EA_INIT, EA_LOAD_STATE, EA_SYNC_BROKER, EA_IDLE, EA_ENTRY_SCAN,
   EA_SIGNAL_READY, EA_RISK_CHECK, EA_BROKER_GATE, EA_ORDERCHECK, EA_ORDERSEND,
   EA_ORDER_PENDING, EA_POSITION_SYNC, EA_IN_POSITION, EA_EXIT_SCAN,
   EA_RECOVERY_CHECK, EA_RECOVERY_ACTIVE, EA_UNWIND_CHECK, EA_UNWIND,
   EA_NO_EXPANSION, EA_FORCE_REDUCE, EA_FLATTEN, EA_HALT, EA_EXECUTION_FAILED
};

// REQ: SIG-3, SIG-4
enum ESessionMode
{
   SESSION_ENTRY_ALLOWED, SESSION_RECOVERY_ONLY, SESSION_REDUCE_ONLY,
   SESSION_FLAT_ONLY, SESSION_CLOSED
};

// REQ: SIG-7
enum ERegimeState
{
   REGIME_UNKNOWN, REGIME_RANGE, REGIME_TREND_UP, REGIME_TREND_DOWN,
   REGIME_BREAKOUT_UP, REGIME_BREAKOUT_DOWN, REGIME_CHAOS, REGIME_NEWS_LOCK
};

// REQ: SIG-8
enum ESignalType
{
   SIGNAL_HOLD, SIGNAL_BUY, SIGNAL_SELL, SIGNAL_EXIT_BUY, SIGNAL_EXIT_SELL
};

// REQ: RISK-1
enum ERiskState
{
   RISK_NORMAL, RISK_CAUTION, RISK_RECOVERY_ONLY, RISK_NO_EXPANSION,
   RISK_FORCE_REDUCE, RISK_HARD_STOP, RISK_DISABLED
};

// REQ: GRD-1
enum ERecoveryMode
{
   RECOVERY_NONE, RECOVERY_GRID, RECOVERY_HEDGE,
   RECOVERY_REDUCE_ONLY, RECOVERY_UNWIND, RECOVERY_HARD_STOP
};

// REQ: ORD-3
enum EBrokerGateResult
{
   BROKER_PASS, BROKER_BLOCK_SPREAD, BROKER_BLOCK_SESSION_CLOSED,
   BROKER_BLOCK_STOP_LEVEL, BROKER_BLOCK_FREEZE_LEVEL, BROKER_BLOCK_VOLUME,
   BROKER_BLOCK_MARGIN, BROKER_BLOCK_TRADE_DISABLED, BROKER_BLOCK_STALE_PRICE,
   BROKER_BLOCK_DUPLICATE, BROKER_BLOCK_THROTTLED
};

// REQ: ORD-1
enum EIntentType
{
   INTENT_ENTRY, INTENT_GRID, INTENT_HEDGE, INTENT_PARTIAL_CLOSE,
   INTENT_FLATTEN, INTENT_MODIFY
};

// REQ: ORD-6
enum ETradeLifeState
{
   TLS_NONE = 0, TLS_INTENT_CREATED, TLS_SUBMITTED, TLS_ACCEPTED,
   TLS_PARTIAL_FILL, TLS_FILLED, TLS_EXIT_PENDING, TLS_REJECTED, TLS_CLOSED
};

// REQ: ORD-12
enum ERetryClass { RETRY_NONE = 0, RETRY_PRICE, RETRY_BACKOFF, RETRY_NEVER };

// REQ: ORD-13
enum EBrokerHealth
{
   BROKER_HEALTH_OK = 0, BROKER_HEALTH_THROTTLED, BROKER_HEALTH_DEGRADED,
   BROKER_HEALTH_DISCONNECTED, BROKER_HEALTH_LOCKED
};

// REQ: GOV-1
enum EGlobalRiskState
{
   GRS_NORMAL = 0, GRS_PRE_NEWS_LOCK, GRS_NEWS_SHOCK,
   GRS_STABILIZATION, GRS_DAILY_LOCK, GRS_EMERGENCY_FLATTEN
};

// REQ: GOV-1
enum ESymbolTradeState
{
   STS_IDLE = 0, STS_SIGNAL_QUALIFIED, STS_ORDER_PENDING,
   STS_PARTIAL_FILL, STS_PROTECTION_PENDING, STS_ACTIVE,
   STS_EXIT_PENDING, STS_COOLDOWN, STS_SYMBOL_LOCKED
};

//+------------------------------------------------------------------+
//| STATE — structs (DDS §3.2, §3.3)                                 |
//+------------------------------------------------------------------+

// REQ: SIG-1
struct SMarketSnapshot
{
   string   symbol;
   datetime time;
   double   bid, ask, mid;
   double   spread_points;
   int      digits;
   double   point, tick_size, tick_value, contract_size;
   double   volume_min, volume_max, volume_step;
   long     stops_level_points, freeze_level_points;
   ENUM_SYMBOL_TRADE_MODE trade_mode;
   int      filling_mode_flags;
   bool     session_trade_allowed;
};

// REQ: SIG-7
struct SRegimeSnapshot
{
   ERegimeState regime;
   double       confidence, volatility_bucket;
   int          trend_direction;
   double       trend_strength;
   bool         allow_mean_reversion, allow_breakout, allow_grid, allow_hedge;
};

// REQ: SIG-8
struct SSignalDecision
{
   ESignalType direction;
   double      score;
   string      reason;
   double      entry_price_reference, invalidation_price, target_price;
   datetime    signal_time;
   int         signal_age_seconds;
   ERegimeState regime_at_signal;
   bool        allow_entry;
};

// REQ: RISK-1
struct SRiskDecision
{
   ERiskState risk_state;
   bool       allow_entry, allow_recovery, allow_hedge, allow_partial_close, allow_flatten;
   double     max_new_lot, max_total_lot;
   string     block_reason;
   string     force_action;
};

// REQ: ORD-1
struct STradeIntent
{
   EIntentType            intent_type;
   ENUM_ORDER_TYPE        direction;
   double                 volume, price, sl, tp;
   int                    deviation;
   ENUM_ORDER_TYPE_FILLING filling_mode;
   long                   magic;
   string                 comment, reason;
   ulong                  targetPositionTicket;   // required for MODIFY/PARTIAL_CLOSE — ARCH-2
};

// REQ: RISK-12
struct SCurrencyContext
{
   string   account_currency, symbol_profit_currency;
   double   conversion_rate;
   bool     conversion_valid;
   datetime last_refresh;
};

// REQ: SIG-3, SIG-5
struct SBrokerTimeContext
{
   int      broker_gmt_offset_hours;
   bool     broker_dst_active;
   datetime last_offset_check_time;
};

// REQ: RISK-13
struct SSharedRiskLedger
{
   long     account_login;
   int      total_open_positions_all_magics;
   double   total_gross_lots_all_magics, total_floating_pl_all_magics;
   double   total_margin_usage_pct;
   double   per_magic_lots[];   // parallel array: magic -> lots, index-matched to per_magic_ids[]
   long     per_magic_ids[];
   datetime last_update_time;
};

// REQ: ORD-6 — carried over unchanged from SA §7.5
struct STradeLifecycle
{
   ulong           requestOrder, positionTicket, lastDealTicket;
   ENUM_ORDER_TYPE orderType;
   ETradeLifeState state;
   double          requestedVolume, filledVolume, requestedPrice, actualOpenPrice, stopLoss, takeProfit;
   datetime        createdAt, lastUpdateAt;
   uint            retryCount;
   bool            tp1Done;
   bool            seenInLastReconcile;   // required by ORD-15 reconciliation loop
};

// REQ: ORD-12 — carried over unchanged from SA §7.8
struct SPendingIntent
{
   bool            active;
   string          symbol;
   ENUM_ORDER_TYPE type;
   double          volume, intendedPrice, sl, tp;
   int             retries;
   datetime        retryAfter;
   string          tag;
};

// REQ: ORD-13 — carried over unchanged from SA §7.9
struct SBrokerRateState
{
   EBrokerHealth health;
   int           throttleStrikes;
   datetime      blockedUntil, lastAcceptedAt, lastThrottleAt;
};

// REQ: TEL-1 — carried over unchanged from SA §7.11
struct SExecutionStats
{
   ulong  clientRequestId, orderTicket, positionTicket, dealTicket;
   ulong  submitUs, sendReturnedUs, firstDealUs, fullFillUs;
   double intendedPrice, firstFillPrice, weightedFillPrice;
   double requestedVolume, filledVolume;
   double spreadAtIntentPoints, spreadAtFillPoints;
   uint   lastRetcode;
   int    retryCount;
   bool   complete;
};

// REQ: ORD-15 — carried over unchanged from SA §7.10
struct SLivePosition
{
   ulong ticket; string symbol; long magic; ENUM_POSITION_TYPE type;
   double volume, openPrice, sl, tp, profit; datetime openedAt;
};

// REQ: GOV-1 — carried over unchanged from SA §9
struct SSymbolActor
{
   string symbol; long magic; ESymbolTradeState state;
   uint   activeRequestId;
   ulong  activeOrderTicket, activePositionTicket;
   double intendedVolume, filledVolume, maxRiskMoney;
   datetime nextActionAt, cooldownUntil;
   bool   slConfirmed, isNewsSensitive;
};

//+------------------------------------------------------------------+
//| STATE — global declarations (DDS §3.4)                           |
//+------------------------------------------------------------------+

// REQ: FSM-1, STA-2
EEAState          g_eaState = EA_INIT;

// REQ: ORD-6, STA-1, STA-3, NN-6 — risk-authoritative; written only inside
// OnTradeTransaction()/reconciliation (added Phase 2). Only this store may
// be read by a risk or broker gate (STA-1) — code-review-enforced, not
// compiler-enforced.
STradeLifecycle   g_tradeState[];

// REQ: TEL-1, STA-4 — telemetry only, never a gate input.
SExecutionStats   g_exec[];

// REQ: ORD-12
SPendingIntent    g_pending;

// REQ: ORD-13, STA-5 — informs BrokerGate pre-check only, not risk sizing.
SBrokerRateState  g_broker;

// REQ: GOV-1, STA-6 — feeds Session/Risk Engine, does not gate directly.
SSymbolActor      g_actors[];

// REQ: GOV-2
EGlobalRiskState  g_globalRiskState = GRS_NORMAL;

// REQ: RISK-12
SCurrencyContext  g_currency;

// REQ: SIG-3, SIG-5
SBrokerTimeContext g_brokerTime;

// REQ: RISK-13 — this instance's write buffer for the shared exposure ledger.
SSharedRiskLedger g_sharedLedgerLocal;

// REQ: LOG-4
bool              g_killSwitchActive = false;

// REQ: FSM-3 (invariant INV-4: g_tradeLock == true implies no non-reduce-only
// ExecuteIntent() call occurs until lock is cleared by broker reconciliation)
bool              g_tradeLock = false;

// REQ: TEL-1
ulong             g_nextRequestId = 1;

//+------------------------------------------------------------------+
//| STATE — startup validation & capability discovery                |
//| (Phase 1 scope: input cross-checks and broker/account capability  |
//| probing only. No signal/risk/order logic runs from here.)         |
//+------------------------------------------------------------------+

// REQ: ARCH-1
// Hedging is load-bearing for this EA's entire lifecycle/risk/recovery
// model (ARCH-1, ARCH-2 — ticket-scoped state, ticket-scoped closes).
// Per SA §0 porting note, silently continuing on a Netting account would
// make every position-ticket assumption in this file wrong.
bool ValidateAccountIsHedging()
{
   ENUM_ACCOUNT_MARGIN_MODE mode = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(mode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      PrintFormat("FATAL: account margin mode=%d is not Hedging. This EA assumes independent, "
                  "ticket-keyed positions per symbol (ARCH-1) and must not run on a Netting account.",
                  (int)mode);
      return false;
   }
   return true;
}

// REQ: SIG-1 (OnInit capability probe only — reuses the SMarketSnapshot type
// to avoid a duplicate struct; the full per-cycle BuildMarketSnapshot()
// implementation arrives in Phase 3)
bool DiscoverSymbolCapabilities(const string symbol, SMarketSnapshot &out)
{
   ZeroMemory(out);
   out.symbol = symbol;

   if(!SymbolSelect(symbol, true))
   {
      PrintFormat("FATAL: SymbolSelect failed for %s.", symbol);
      return false;
   }

   out.digits              = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   out.point               = SymbolInfoDouble(symbol, SYMBOL_POINT);
   out.tick_size            = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   out.tick_value           = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   out.contract_size        = SymbolInfoDouble(symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   out.volume_min           = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   out.volume_max           = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   out.volume_step          = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   out.stops_level_points   = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   out.freeze_level_points  = SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   out.trade_mode           = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE);
   out.filling_mode_flags   = (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);

   MqlTick tick;
   if(SymbolInfoTick(symbol, tick))
   {
      out.bid           = tick.bid;
      out.ask           = tick.ask;
      out.mid           = (tick.bid + tick.ask) / 2.0;
      out.time          = tick.time;
      out.spread_points = (out.point > 0.0) ? (out.ask - out.bid) / out.point : -1.0;
   }

   // CLOSEONLY still counts as a valid trade_mode at the symbol-spec level;
   // BrokerGate (ORD-3, Phase 2) is responsible for rejecting *new* exposure
   // under CLOSEONLY specifically — this probe only rules out DISABLED.
   out.session_trade_allowed = (out.trade_mode != SYMBOL_TRADE_MODE_DISABLED);

   if(out.trade_mode == SYMBOL_TRADE_MODE_DISABLED)
   {
      PrintFormat("FATAL: symbol %s trade_mode=DISABLED at broker.", symbol);
      return false;
   }
   if(out.filling_mode_flags == 0)
   {
      PrintFormat("FATAL: symbol %s reports no supported filling mode flags.", symbol);
      return false;
   }
   if(out.volume_min <= 0.0 || out.volume_step <= 0.0)
   {
      PrintFormat("FATAL: symbol %s has invalid volume_min/volume_step from broker.", symbol);
      return false;
   }

   return true;
}

// REQ: INP-5, TEST-2
// Best-effort at OnInit: statically verifiable only if ATR history already
// exists (fresh charts / cold Strategy Tester starts often do not have it
// yet), matching SA §14.2's "INIT_FAILED if statically verifiable, else
// runtime warning" wording for this specific check.
bool CheckGridStepAgainstBrokerConstraints(string &violation, bool &staticallyVerifiable)
{
   violation = "";
   staticallyVerifiable = false;

   int atrHandle = iATR(_Symbol, PERIOD_CURRENT, InpAtrPeriod);
   if(atrHandle == INVALID_HANDLE)
      return true;

   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   int copied = CopyBuffer(atrHandle, 0, 0, 1, atrBuf);
   IndicatorRelease(atrHandle);

   if(copied != 1)
      return true;

   staticallyVerifiable = true;

   double point            = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   long   stopsLevel       = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long   freezeLevel      = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double requiredMinDist  = (double)(stopsLevel + freezeLevel) * point;
   double gridStep         = InpGridStepATRMultiplier * atrBuf[0];

   if(gridStep <= requiredMinDist)
   {
      violation = StringFormat(
         "GridStepATRMultiplier(%.2f) x current ATR(%.5f)=%.5f does not clear stops+freeze distance(%.5f)",
         InpGridStepATRMultiplier, atrBuf[0], gridStep, requiredMinDist);
      return false;
   }
   return true;
}

// REQ: INP-1, TEST-2
// Runtime warning only (SA §14.2 table row) — depends on live equity, which
// is not knowable at compile time or before the account is connected.
void WarnIfBasketLossExceedsHardStopBudget()
{
   double equity          = AccountInfoDouble(ACCOUNT_EQUITY);
   double hardStopBudget  = equity * InpHardEquityStopPct / 100.0;
   if(InpMaxBasketLossMoney > hardStopBudget)
      PrintFormat("INPUT_VALIDATION_WARNING: MaxBasketLossMoney(%.2f) exceeds implied HardEquityStopPct "
                  "budget(%.2f at current equity %.2f) — basket loss gate may never trigger before hard stop.",
                  InpMaxBasketLossMoney, hardStopBudget, equity);
}

// REQ: INP-1, INP-5, TEST-2
// SA §14.2: under InpStrictPropRiskMode, any violation of the five
// unconditional checks below fails INIT. Outside strict mode, the spec
// says "log and continue only if InpAuditRequired == false" — read
// conservatively here: audit-required-but-non-strict also fails closed
// rather than silently running with an unvalidated risk ladder.
// [ASSUMPTION: this reading of the non-strict/audit interaction is not
// spelled out with an explicit truth table in the SA/DDS.]
bool ValidateInputCrossChecks(string &failReason)
{
   string violations[];
   int    n = 0;

   double projectedMaxLot = InpBaseLot * MathPow(InpRecoveryLotMultiplier, (double)InpMaxRecoveryDepth);
   if(projectedMaxLot > InpMaxExposureLots)
   {
      ArrayResize(violations, n + 1);
      violations[n++] = StringFormat(
         "Exponential lot overflow: base_lot(%.2f) x multiplier(%.2f)^depth(%d)=%.4f > MaxExposureLots(%.2f)",
         InpBaseLot, InpRecoveryLotMultiplier, InpMaxRecoveryDepth, projectedMaxLot, InpMaxExposureLots);
   }

   if(InpMinFreeMarginPct >= 100.0 - InpMaxMarginUsagePct)
   {
      ArrayResize(violations, n + 1);
      violations[n++] = StringFormat(
         "Margin gate inconsistency: MinFreeMarginPct(%.2f) >= 100-MaxMarginUsagePct(%.2f)",
         InpMinFreeMarginPct, 100.0 - InpMaxMarginUsagePct);
   }

   if(InpMaxDailyLossPct > InpMaxTotalDrawdownPct)
   {
      ArrayResize(violations, n + 1);
      violations[n++] = StringFormat(
         "Daily loss(%.2f) exceeds total drawdown cap(%.2f)", InpMaxDailyLossPct, InpMaxTotalDrawdownPct);
   }

   if(InpHardEquityStopPct > InpMaxTotalDrawdownPct)
   {
      ArrayResize(violations, n + 1);
      violations[n++] = StringFormat(
         "HardEquityStopPct(%.2f) exceeds MaxTotalDrawdownPct(%.2f)", InpHardEquityStopPct, InpMaxTotalDrawdownPct);
   }

   double minViableRecoveryLot = InpBaseLot * InpRecoveryLotMultiplier;
   if(InpMaxRecoveryLots < minViableRecoveryLot)
   {
      ArrayResize(violations, n + 1);
      violations[n++] = StringFormat(
         "MaxRecoveryLots(%.2f) < base_lot x multiplier(%.4f)", InpMaxRecoveryLots, minViableRecoveryLot);
   }

   failReason = "";
   if(n > 0)
   {
      for(int i = 0; i < n; i++)
      {
         PrintFormat("INPUT_VALIDATION_VIOLATION: %s", violations[i]);
         failReason = (StringLen(failReason) > 0) ? failReason + " | " + violations[i] : violations[i];
      }

      if(InpStrictPropRiskMode || InpAuditRequired)
         return false;

      Print("Input violations logged but continuing: StrictPropRiskMode=false and AuditRequired=false.");
   }

   string gridViolation;
   bool   gridVerifiable;
   bool   gridPassed = CheckGridStepAgainstBrokerConstraints(gridViolation, gridVerifiable);
   if(!gridVerifiable)
   {
      Print("INPUT_VALIDATION_WARNING: ATR history not yet available; grid-step vs "
            "broker-constraint check deferred to the Phase 3 signal engine.");
   }
   else if(!gridPassed)
   {
      PrintFormat("INPUT_VALIDATION_VIOLATION: %s (statically verifiable at OnInit -> failing closed per TEST-2).",
                  gridViolation);
      failReason = (StringLen(failReason) > 0) ? failReason + " | " + gridViolation : gridViolation;
      return false;
   }

   WarnIfBasketLossExceedsHardStopBudget();

   return true;
}

// REQ: STA-3 (read-only precursor: does NOT write g_tradeState[]; per STA-3
// that store is written only inside OnTradeTransaction()/reconciliation,
// which is added in Phase 2 as ReconcileAllEAPositions(), ORD-15)
void SyncBrokerStateSkeleton()
{
   int    matched   = 0;
   double grossLots = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))   // ORD-8: reselect before reading any live field
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      matched++;
      grossLots += PositionGetDouble(POSITION_VOLUME);
   }

   PrintFormat("SYNC_BROKER skeleton: %d existing EA position(s) for magic=%I64d symbol=%s, gross lots=%.2f. "
               "Full lifecycle reconciliation (ORD-15) activates in Phase 2 — no new trading permitted until then.",
               matched, InpMagicNumber, _Symbol, grossLots);
}

//+------------------------------------------------------------------+
//| EVENT HANDLERS — minimal, compile-only wiring for Phase 1.        |
//| Signal/risk/order sections are added in Phases 2-6 and will       |
//| extend these handlers, not replace this bootstrap logic.          |
//+------------------------------------------------------------------+

// REQ: ARCH-1, STA-2, FSM-1, TEST-2
int OnInit()
{
   PrintFormat("OnInit starting. symbol=%s magic=%I64d", _Symbol, InpMagicNumber);

   if(!ValidateAccountIsHedging())
      return INIT_FAILED;

   SMarketSnapshot capabilityProbe;
   if(!DiscoverSymbolCapabilities(_Symbol, capabilityProbe))
      return INIT_FAILED;

   string failReason = "";
   if(!ValidateInputCrossChecks(failReason))
   {
      PrintFormat("OnInit FAILED: input cross-validation. %s", failReason);
      return INIT_FAILED;
   }

   g_eaState = EA_LOAD_STATE;
   // DDS §4: state-file persistence is a convenience cache, never the
   // source of truth. Nothing is loaded from disk here — every boot
   // reconciles against the live broker instead (full version: Phase 2).
   g_eaState = EA_SYNC_BROKER;
   SyncBrokerStateSkeleton();

   if(!EventSetTimer(1))
   {
      Print("OnInit FAILED: EventSetTimer(1) rejected by terminal.");
      return INIT_FAILED;
   }

   g_eaState = EA_IDLE;
   PrintFormat("OnInit complete. state=EA_IDLE symbol_digits=%d point=%.5f stops_level=%d freeze_level=%d",
               capabilityProbe.digits, capabilityProbe.point,
               (int)capabilityProbe.stops_level_points, (int)capabilityProbe.freeze_level_points);
   return INIT_SUCCEEDED;
}

// REQ: ARCH-1
void OnDeinit(const int reason)
{
   EventKillTimer();
   PrintFormat("OnDeinit reason=%d. Open positions (if any) are left untouched — a Hedging-account "
               "basket must survive terminal restart and is picked up by the next OnInit -> "
               "SYNC_BROKER pass, never closed here.", reason);
}

void OnTick()
{
   // Phase 1 scope: inputs + state only. Kill-switch (LOG-4), the full
   // per-cycle market snapshot (SIG-1), and all signal/risk/order wiring
   // are added in Phases 2-6. Intentionally inert until then.
   if(g_eaState != EA_IDLE)
      return;
}

void OnTimer()
{
   // Intentionally inert in Phase 1: ReconcileAllEAPositions (ORD-15) and
   // ProcessPendingIntent (ORD-12) are added in Phase 2 once the orders
   // section exists. Timer is armed now so OnInit's EventSetTimer(1) has a
   // receiver ahead of that wiring.
}
