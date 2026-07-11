//+------------------------------------------------------------------+
//|                                   MT5_Forex_Trading_System_EA.mq5 |
//|  Risk-first scalping + grid/hedge recovery EA for XAUUSD and     |
//|  index-style CFDs. Implements MT5_Forex_Trading_System_Architecture.md |
//+------------------------------------------------------------------+
#property copyright "MT5 Forex Trading System"
#property version   "1.00"
#property strict

//====================================================================
// SECTION 1: INPUTS  (spec §4.1, extended by §17-§26)
//====================================================================

// --- Risk ---
input double InpMaxDailyLossPct        = 3.0;     // Max daily loss (% of balance)
input double InpMaxTotalDrawdownPct    = 12.0;    // Max total drawdown (% of balance)
input double InpHardEquityStopPct      = 15.0;    // Hard equity stop (% of balance)
input double InpMaxBasketLossMoney     = 400.0;   // Max basket floating loss (account ccy)
input double InpMaxFloatingLossPct     = 8.0;     // Max floating loss (% of equity)
input double InpMaxExposureLots        = 3.0;     // Max lots (this symbol+magic)
input double InpMaxMarginUsagePct      = 40.0;    // Max margin usage (%)
input double InpMinFreeMarginPct       = 50.0;    // Min free margin (%) required

// --- Execution ---
input int    InpMaxSpreadPoints        = 350;     // Max spread (points)
input int    InpMaxSlippagePoints      = 30;      // Max slippage / deviation (points)
input int    InpMaxOrderRetries        = 3;        // Max OrderSend retries
input int    InpRetryBackoffMs         = 250;      // Retry backoff (ms)
input long   InpMagicNumber            = 774411;   // Magic number
input double InpBaseLot                = 0.10;     // Base lot size

// --- Session (broker-server-time based, §18) ---
input int    InpEntryStartHour         = 7;        // Entry session start (broker hour)
input int    InpEntryEndHour           = 20;       // Entry session end (broker hour)
input int    InpReduceOnlyStartHour    = 21;       // Reduce-only start (broker hour)
input bool   InpForcedFlatBeforeWeekend= true;      // Force flat before weekend
input int    InpFridayFlatHour         = 20;        // Friday flat hour (broker time)
input int    InpWeekendFlattenEscalationMin = 5;    // Escalation window (minutes, §26)

// --- Signal ---
input int    InpATRPeriod              = 14;
input int    InpEMAFastPeriod          = 12;
input int    InpEMASlowPeriod          = 50;
input int    InpEMA200H1Period         = 200;
input int    InpRSIPeriod              = 14;
input double InpRSIOverbought          = 70.0;
input double InpRSIOversold            = 30.0;
input int    InpADXPeriod              = 14;
input double InpADXTrendThreshold      = 25.0;
input double InpADXRangeThreshold      = 18.0;
input int    InpDonchianPeriod         = 20;
input double InpMinSignalScore         = 60.0;
input int    InpMaxSignalAgeSeconds    = 20;
input double InpChaosATRMultiplier     = 2.5;      // ATR spike ratio -> chaos regime

// --- Recovery ---
input bool   InpEnableGrid             = true;
input bool   InpEnableHedge            = true;
input int    InpMaxRecoveryDepth       = 4;
input double InpGridStepATRMultiplier  = 1.5;
input double InpRecoveryLotMultiplier  = 1.5;
input double InpMaxRecoveryLots        = 2.0;
input double InpMinUnwindProfitMoney   = 5.0;
input double InpSlippageBufferMoney    = 2.0;
input double InpCommissionBufferMoney  = 1.0;
input double InpSwapBufferMoney        = 1.0;
input int    InpMinSecondsBetweenActions = 20;     // OneRecoveryPerBar-style throttle

// --- Multi-instance governance (§17) ---
input bool   InpParticipateSharedLedger = true;
input double InpMaxAccountExposureLots  = 8.0;
input double InpMaxAccountFloatingLossMoney = 1000.0;
input int    InpSharedLedgerStaleSeconds = 90;

// --- Currency normalization (§19) ---
input bool   InpAssumeUSDOnlyAccount   = false;    // If true: validated USD-only at OnInit

// --- Compliance / audit (§23) ---
input bool   InpStrictPropRiskMode     = true;
input bool   InpAuditRequired          = true;

// --- Kill switch / alerting (§21,§22) ---
input bool   InpUseWebhook             = false;
input string InpWebhookURL             = "";
input int    InpExecFailureAlertCount  = 3;
input int    InpExecFailureWindowSec   = 300;

// --- Misc ---
input int    InpTimerSeconds           = 1;
input string InpEAPrefix               = "MT5FTS";

//====================================================================
// SECTION 2: CONSTANTS / ENUMS
//====================================================================
enum ENUM_SESSION_MODE
  {
   SESSION_ENTRY_ALLOWED,
   SESSION_RECOVERY_ONLY,
   SESSION_REDUCE_ONLY,
   SESSION_FLAT_ONLY,
   SESSION_CLOSED
  };

enum ENUM_REGIME_STATE
  {
   REGIME_UNKNOWN,
   REGIME_RANGE,
   REGIME_TREND_UP,
   REGIME_TREND_DOWN,
   REGIME_BREAKOUT_UP,
   REGIME_BREAKOUT_DOWN,
   REGIME_CHAOS,
   REGIME_NEWS_LOCK
  };

enum ENUM_SIGNAL_TYPE
  {
   SIGNAL_HOLD,
   SIGNAL_BUY,
   SIGNAL_SELL,
   SIGNAL_EXIT_BUY,
   SIGNAL_EXIT_SELL
  };

enum ENUM_RISK_STATE
  {
   RISK_NORMAL,
   RISK_CAUTION,
   RISK_RECOVERY_ONLY,
   RISK_NO_EXPANSION,
   RISK_FORCE_REDUCE,
   RISK_HARD_STOP,
   RISK_DISABLED
  };

enum ENUM_RECOVERY_MODE
  {
   RECOVERY_NONE,
   RECOVERY_GRID,
   RECOVERY_HEDGE,
   RECOVERY_REDUCE_ONLY,
   RECOVERY_UNWIND,
   RECOVERY_HARD_STOP
  };

enum ENUM_INTENT_TYPE
  {
   INTENT_NONE,
   INTENT_ENTRY,
   INTENT_GRID,
   INTENT_HEDGE,
   INTENT_PARTIAL_CLOSE,
   INTENT_FLATTEN,
   INTENT_MODIFY
  };

enum ENUM_BROKER_GATE_RESULT
  {
   BROKER_PASS,
   BROKER_BLOCK_SPREAD,
   BROKER_BLOCK_SESSION_CLOSED,
   BROKER_BLOCK_STOP_LEVEL,
   BROKER_BLOCK_FREEZE_LEVEL,
   BROKER_BLOCK_VOLUME,
   BROKER_BLOCK_MARGIN,
   BROKER_BLOCK_TRADE_DISABLED,
   BROKER_BLOCK_STALE_PRICE,
   BROKER_BLOCK_DUPLICATE
  };

enum ENUM_FSM_STATE
  {
   ST_INIT,
   ST_LOAD_STATE,
   ST_SYNC_BROKER,
   ST_IDLE,
   ST_ENTRY_SCAN,
   ST_SIGNAL_READY,
   ST_RISK_CHECK,
   ST_BROKER_GATE,
   ST_ORDERCHECK,
   ST_ORDERSEND,
   ST_ORDER_PENDING,
   ST_POSITION_SYNC,
   ST_IN_POSITION,
   ST_EXIT_SCAN,
   ST_RECOVERY_CHECK,
   ST_RECOVERY_ACTIVE,
   ST_UNWIND_CHECK,
   ST_UNWIND,
   ST_NO_EXPANSION,
   ST_FORCE_REDUCE,
   ST_FLATTEN,
   ST_HALT,
   ST_EXECUTION_FAILED
  };

string StateName(ENUM_FSM_STATE s)
  {
   switch(s)
     {
      case ST_INIT: return "INIT";
      case ST_LOAD_STATE: return "LOAD_STATE";
      case ST_SYNC_BROKER: return "SYNC_BROKER";
      case ST_IDLE: return "IDLE";
      case ST_ENTRY_SCAN: return "ENTRY_SCAN";
      case ST_SIGNAL_READY: return "SIGNAL_READY";
      case ST_RISK_CHECK: return "RISK_CHECK";
      case ST_BROKER_GATE: return "BROKER_GATE";
      case ST_ORDERCHECK: return "ORDERCHECK";
      case ST_ORDERSEND: return "ORDERSEND";
      case ST_ORDER_PENDING: return "ORDER_PENDING";
      case ST_POSITION_SYNC: return "POSITION_SYNC";
      case ST_IN_POSITION: return "IN_POSITION";
      case ST_EXIT_SCAN: return "EXIT_SCAN";
      case ST_RECOVERY_CHECK: return "RECOVERY_CHECK";
      case ST_RECOVERY_ACTIVE: return "RECOVERY_ACTIVE";
      case ST_UNWIND_CHECK: return "UNWIND_CHECK";
      case ST_UNWIND: return "UNWIND";
      case ST_NO_EXPANSION: return "NO_EXPANSION";
      case ST_FORCE_REDUCE: return "FORCE_REDUCE";
      case ST_FLATTEN: return "FLATTEN";
      case ST_HALT: return "HALT";
      case ST_EXECUTION_FAILED: return "EXECUTION_FAILED";
     }
   return "UNKNOWN";
  }

//====================================================================
// SECTION 3: STRUCTS
//====================================================================
struct MarketSnapshot
  {
   string            symbol;
   datetime          time;
   double            bid;
   double            ask;
   double            mid;
   double            spread_points;
   int               digits;
   double            point;
   double            tick_size;
   double            tick_value;
   double            contract_size;
   double            volume_min;
   double            volume_max;
   double            volume_step;
   double            stops_level_points;
   double            freeze_level_points;
   ENUM_SYMBOL_TRADE_MODE trade_mode;
   int               filling_mode_flags;
   bool              session_trade_allowed;
   bool              valid;
  };

struct RegimeSnapshot
  {
   ENUM_REGIME_STATE regime;
   double            confidence;
   int               volatility_bucket;   // 0 low,1 normal,2 high
   int               trend_direction;     // -1 down, 0 flat, 1 up
   double            trend_strength;      // ADX value
   bool              allow_mean_reversion;
   bool              allow_breakout;
   bool              allow_grid;
   bool              allow_hedge;
   double            atr;
   double            ema_fast;
   double            ema_slow;
   double            ema200_h1;
   double            rsi;
   double            adx;
   double            donchian_high;
   double            donchian_low;
   double            vwap;
  };

struct SignalDecision
  {
   ENUM_SIGNAL_TYPE  direction;
   double            score;
   string            reason;
   double            entry_price_reference;
   double            invalidation_price;
   double            target_price;
   datetime          signal_time;
   int               signal_age_seconds;
   ENUM_REGIME_STATE regime_at_signal;
   bool              allow_entry;
  };

struct RiskDecision
  {
   ENUM_RISK_STATE   risk_state;
   bool              allow_entry;
   bool              allow_recovery;
   bool              allow_hedge;
   bool              allow_partial_close;
   bool              allow_flatten;
   double            max_new_lot;
   double            max_total_lot;
   string            block_reason;
   ENUM_FSM_STATE    force_action;
  };

struct TradeIntent
  {
   ENUM_INTENT_TYPE  intent_type;
   ENUM_ORDER_TYPE   direction;
   double            volume;
   double            price;
   double            sl;
   double            tp;
   int               deviation;
   ENUM_ORDER_TYPE_FILLING filling_mode;
   long              magic;
   string            comment;
   string            reason;
   ulong             target_ticket;      // for close/modify
   bool              valid;
  };

struct ExposureLedger
  {
   double            buy_lots;
   double            sell_lots;
   double            net_lots;
   double            gross_lots;
   double            avg_buy_price;
   double            avg_sell_price;
   int               position_count;
  };

struct BasketLedger
  {
   long              basket_id;
   double            floating_pl;
   double            realized_pl_today;
   int               depth;
   bool              has_positions;
   double            gross_lots;
  };

struct RecoveryLedger
  {
   ENUM_RECOVERY_MODE mode;
   int               depth;
   double            hedge_lots;
   datetime          last_recovery_time;
   double            last_recovery_price;
  };

struct CurrencyContext
  {
   string            account_currency;
   string            symbol_profit_currency;
   double            conversion_rate;
   bool              conversion_valid;
   datetime          last_refresh;
  };

struct BrokerTimeContext
  {
   int               gmt_offset_hours;
   bool              dst_active_guess;
   datetime          last_offset_check_time;
  };

struct RuntimeStateRecord
  {
   int               fsm_state;
   int               recovery_mode;
   int               recovery_depth;
   long              basket_id;
   double            daily_realized_pl;
   int               daily_pl_day;          // day-of-year marker
   datetime          last_recovery_time;
   double            last_recovery_price;
   bool              halted;
   bool              kill_switch_latched;
   int               last_gmt_offset;
  };

//====================================================================
// SECTION 4: GLOBAL STATE
//====================================================================
ENUM_FSM_STATE     g_state              = ST_INIT;
ENUM_FSM_STATE     g_prev_state         = ST_INIT;
bool               g_halt               = false;
bool               g_kill_switch_latched= false;

MarketSnapshot     g_snap, g_prev_snap;
RegimeSnapshot     g_regime;
SignalDecision     g_signal;
RiskDecision       g_risk;
ExposureLedger     g_exposure;
BasketLedger       g_basket;
RecoveryLedger     g_recovery;
CurrencyContext    g_ccy;
BrokerTimeContext  g_btime;
TradeIntent        g_intent;

int                h_atr, h_ema_fast, h_ema_slow, h_ema200_h1, h_rsi, h_adx;

double             g_daily_realized_pl  = 0.0;
int                g_daily_pl_day       = -1;
long               g_basket_id_counter  = 0;

bool               g_pending_intent_active = false;
bool               g_pending_close_lock    = false;
bool               g_trade_lock            = false;
bool               g_snapshot_dirty_after_drift = false;

datetime           g_last_action_time   = 0;
datetime           g_flatten_entered_time = 0;
bool               g_weekend_escalated  = false;
bool               g_weekend_gap_logged = false;

datetime           g_exec_failure_times[]; // rolling window for alerting

string             g_prefix;
string             g_state_file_name;
string             g_shared_ledger_file;

// alert throttle: key -> last time
string             g_alert_keys[];
datetime           g_alert_times[];

//====================================================================
// SECTION 5: UTILITY FUNCTIONS
//====================================================================
double NormalizeVolume(double vol)
  {
   double vmin  = g_snap.volume_min>0 ? g_snap.volume_min : SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax  = g_snap.volume_max>0 ? g_snap.volume_max : SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vstep = g_snap.volume_step>0 ? g_snap.volume_step : SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(vstep<=0) vstep = 0.01;
   double steps = MathRound(vol/vstep);
   double result = steps*vstep;
   if(result<vmin) result = vmin;
   if(result>vmax) result = vmax;
   int decimals = 2;
   if(vstep<0.01) decimals = 3;
   return NormalizeDouble(result, decimals);
  }

double NormalizePriceValue(double price)
  {
   double ts = g_snap.tick_size>0 ? g_snap.tick_size : SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts<=0) ts = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double steps = MathRound(price/ts);
   double result = steps*ts;
   int digs = g_snap.digits>0 ? g_snap.digits : (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return NormalizeDouble(result, digs);
  }

int DayOfYearNow()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   return dt.day_of_year;
  }

void ResetDailyPLIfNewDay()
  {
   int doy = DayOfYearNow();
   if(g_daily_pl_day != doy)
     {
      g_daily_pl_day = doy;
      g_daily_realized_pl = 0.0;
     }
  }

bool IsFridayFlatWindow()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt); // TimeCurrent() is already broker server time
   if(dt.day_of_week==5 && dt.hour>=InpFridayFlatHour) return true;
   if(dt.day_of_week==6) return true; // Saturday - market closed for FX/CFD typically
   return false;
  }

//====================================================================
// SECTION 18 (early decl): CSV LOGGING ENGINE
//====================================================================
int OpenLogFile(string filename, bool &isNew)
  {
   isNew = !FileIsExist(filename, FILE_COMMON);
   int h = FileOpen(filename, FILE_READ|FILE_WRITE|FILE_CSV|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE, ';');
   if(h!=INVALID_HANDLE)
      FileSeek(h, 0, SEEK_END);
   return h;
  }

void LogSignal(const SignalDecision &s, const RegimeSnapshot &r)
  {
   bool isNew; int h = OpenLogFile("signal_log.csv", isNew);
   if(h==INVALID_HANDLE) return;
   if(isNew) FileWrite(h,"timestamp","symbol","direction","score","reason","entry_ref","invalidation","target","signal_age_s","regime","allow_entry");
   FileWrite(h, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), _Symbol, EnumToString(s.direction),
             DoubleToString(s.score,1), s.reason, DoubleToString(s.entry_price_reference,g_snap.digits),
             DoubleToString(s.invalidation_price,g_snap.digits), DoubleToString(s.target_price,g_snap.digits),
             IntegerToString(s.signal_age_seconds), EnumToString(r.regime), s.allow_entry?"1":"0");
   FileClose(h);
  }

void LogRegime(const RegimeSnapshot &r)
  {
   bool isNew; int h = OpenLogFile("regime_log.csv", isNew);
   if(h==INVALID_HANDLE) return;
   if(isNew) FileWrite(h,"timestamp","symbol","regime","confidence","vol_bucket","trend_dir","trend_strength","atr","ema_fast","ema_slow","ema200_h1","rsi","adx","donchian_hi","donchian_lo","vwap");
   FileWrite(h, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), _Symbol, EnumToString(r.regime),
             DoubleToString(r.confidence,1), IntegerToString(r.volatility_bucket), IntegerToString(r.trend_direction),
             DoubleToString(r.trend_strength,1), DoubleToString(r.atr,g_snap.digits), DoubleToString(r.ema_fast,g_snap.digits),
             DoubleToString(r.ema_slow,g_snap.digits), DoubleToString(r.ema200_h1,g_snap.digits), DoubleToString(r.rsi,1),
             DoubleToString(r.adx,1), DoubleToString(r.donchian_high,g_snap.digits), DoubleToString(r.donchian_low,g_snap.digits),
             DoubleToString(r.vwap,g_snap.digits));
   FileClose(h);
  }

void LogRisk(const RiskDecision &rd)
  {
   bool isNew; int h = OpenLogFile("risk_log.csv", isNew);
   if(h==INVALID_HANDLE) return;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double margin = AccountInfoDouble(ACCOUNT_MARGIN);
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double marginLevel = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   double accountFloatingPL = AccountInfoDouble(ACCOUNT_PROFIT);
   double ddPct = balance>0 ? (balance-equity)/balance*100.0 : 0.0;
   if(isNew) FileWrite(h,"timestamp","symbol","equity","balance","margin","free_margin","margin_level","daily_realized_pl","floating_pl","basket_pl","drawdown_pct","exposure_lots","risk_state","allow_entry","allow_recovery","allow_reduce","block_reason","force_action");
   FileWrite(h, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), _Symbol, DoubleToString(equity,2), DoubleToString(balance,2),
             DoubleToString(margin,2), DoubleToString(freeMargin,2), DoubleToString(marginLevel,2), DoubleToString(g_daily_realized_pl,2),
             DoubleToString(accountFloatingPL,2), DoubleToString(g_basket.floating_pl,2), DoubleToString(ddPct,2),
             DoubleToString(g_exposure.gross_lots,2), EnumToString(rd.risk_state), rd.allow_entry?"1":"0", rd.allow_recovery?"1":"0",
             rd.allow_partial_close?"1":"0", rd.block_reason, StateName(rd.force_action));
   FileClose(h);
  }

void LogBroker(ENUM_BROKER_GATE_RESULT res, const TradeIntent &ti)
  {
   bool isNew; int h = OpenLogFile("broker_log.csv", isNew);
   if(h==INVALID_HANDLE) return;
   if(isNew) FileWrite(h,"timestamp","symbol","intent_type","result","spread_points","volume","price");
   FileWrite(h, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), _Symbol, EnumToString(ti.intent_type),
             EnumToString(res), DoubleToString(g_snap.spread_points,1), DoubleToString(ti.volume,2), DoubleToString(ti.price,g_snap.digits));
   FileClose(h);
  }

void LogOrderCheck(const MqlTradeRequest &req, const MqlTradeCheckResult &chk, bool ok, ENUM_RISK_STATE rs, ENUM_BROKER_GATE_RESULT bg)
  {
   bool isNew; int h = OpenLogFile("ordercheck_log.csv", isNew);
   if(h==INVALID_HANDLE) return;
   if(isNew) FileWrite(h,"timestamp","symbol","intent_type","direction","volume","price","sl","tp","margin_required","free_margin","ordercheck_bool","check_retcode","check_comment","normalized_volume","normalized_price","risk_state","broker_gate_result");
   FileWrite(h, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), req.symbol, EnumToString(g_intent.intent_type), EnumToString(req.type),
             DoubleToString(req.volume,2), DoubleToString(req.price,g_snap.digits), DoubleToString(req.sl,g_snap.digits), DoubleToString(req.tp,g_snap.digits),
             DoubleToString(chk.margin,2), DoubleToString(chk.margin_free,2), ok?"1":"0", IntegerToString((int)chk.retcode), chk.comment,
             DoubleToString(req.volume,2), DoubleToString(req.price,g_snap.digits), EnumToString(rs), EnumToString(bg));
   FileClose(h);
  }

void LogExecution(const MqlTradeRequest &req, const MqlTradeResult &res, bool sendOk, int lastErr, int latencyMs, int retryCount, string finalAction)
  {
   bool isNew; int h = OpenLogFile("execution_log.csv", isNew);
   if(h==INVALID_HANDLE) return;
   if(isNew) FileWrite(h,"timestamp","symbol","magic","state","intent_type","direction","request_volume","filled_volume","request_price","fill_price","bid","ask","spread_points","sl","tp","ordersend_bool","get_last_error","retcode","deal","order","comment","latency_ms","retry_count","final_action");
   FileWrite(h, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), req.symbol, IntegerToString((int)req.magic), StateName(g_state),
             EnumToString(g_intent.intent_type), EnumToString(req.type), DoubleToString(req.volume,2), DoubleToString(res.volume,2),
             DoubleToString(req.price,g_snap.digits), DoubleToString(res.price,g_snap.digits), DoubleToString(g_snap.bid,g_snap.digits),
             DoubleToString(g_snap.ask,g_snap.digits), DoubleToString(g_snap.spread_points,1), DoubleToString(req.sl,g_snap.digits),
             DoubleToString(req.tp,g_snap.digits), sendOk?"1":"0", IntegerToString(lastErr), IntegerToString((int)res.retcode),
             IntegerToString((int)res.deal), IntegerToString((int)res.order), res.comment, IntegerToString(latencyMs),
             IntegerToString(retryCount), finalAction);
   FileClose(h);
  }

void LogTransaction(string what, ulong ticket, double volume, double price, double profit)
  {
   bool isNew; int h = OpenLogFile("transaction_log.csv", isNew);
   if(h==INVALID_HANDLE) return;
   if(isNew) FileWrite(h,"timestamp","symbol","what","ticket","volume","price","profit");
   FileWrite(h, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), _Symbol, what, IntegerToString((long)ticket),
             DoubleToString(volume,2), DoubleToString(price,g_snap.digits), DoubleToString(profit,2));
   FileClose(h);
  }

void LogBasket(const BasketLedger &b, const ExposureLedger &e)
  {
   bool isNew; int h = OpenLogFile("basket_log.csv", isNew);
   if(h==INVALID_HANDLE) return;
   if(isNew) FileWrite(h,"timestamp","symbol","basket_id","floating_pl","realized_pl_today","depth","has_positions","gross_lots","buy_lots","sell_lots","net_lots","position_count");
   FileWrite(h, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), _Symbol, IntegerToString(b.basket_id), DoubleToString(b.floating_pl,2),
             DoubleToString(b.realized_pl_today,2), IntegerToString(b.depth), b.has_positions?"1":"0", DoubleToString(b.gross_lots,2),
             DoubleToString(e.buy_lots,2), DoubleToString(e.sell_lots,2), DoubleToString(e.net_lots,2), IntegerToString(e.position_count));
   FileClose(h);
  }

void LogRecovery(string action, const RecoveryLedger &r, double lot)
  {
   bool isNew; int h = OpenLogFile("recovery_log.csv", isNew);
   if(h==INVALID_HANDLE) return;
   if(isNew) FileWrite(h,"timestamp","symbol","action","mode","depth","hedge_lots","lot","last_recovery_price");
   FileWrite(h, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), _Symbol, action, EnumToString(r.mode), IntegerToString(r.depth),
             DoubleToString(r.hedge_lots,2), DoubleToString(lot,2), DoubleToString(r.last_recovery_price,g_snap.digits));
   FileClose(h);
  }

void LogUnwind(bool proven, double winningProfit, double losingFloat, double buffers, double netAfter)
  {
   bool isNew; int h = OpenLogFile("unwind_log.csv", isNew);
   if(h==INVALID_HANDLE) return;
   if(isNew) FileWrite(h,"timestamp","symbol","proven","winning_profit","losing_float_loss","buffers","net_after");
   FileWrite(h, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), _Symbol, proven?"1":"0", DoubleToString(winningProfit,2),
             DoubleToString(losingFloat,2), DoubleToString(buffers,2), DoubleToString(netAfter,2));
   FileClose(h);
  }

void LogState(ENUM_FSM_STATE fromS, ENUM_FSM_STATE toS, string reason)
  {
   bool isNew; int h = OpenLogFile("state_log.csv", isNew);
   if(h==INVALID_HANDLE) return;
   if(isNew) FileWrite(h,"timestamp","symbol","from_state","to_state","reason");
   FileWrite(h, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), _Symbol, StateName(fromS), StateName(toS), reason);
   FileClose(h);
  }

void LogError(string context, int errCode, string detail)
  {
   bool isNew; int h = OpenLogFile("error_log.csv", isNew);
   if(h==INVALID_HANDLE) return;
   if(isNew) FileWrite(h,"timestamp","symbol","context","error_code","detail");
   FileWrite(h, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), _Symbol, context, IntegerToString(errCode), detail);
   FileClose(h);
   Print("[ERROR] ", context, " code=", errCode, " ", detail);
  }

void LogRuntimeStateCsv()
  {
   bool isNew; int h = OpenLogFile("runtime_state.csv", isNew);
   if(h==INVALID_HANDLE) return;
   if(isNew) FileWrite(h,"timestamp","symbol","fsm_state","recovery_mode","recovery_depth","basket_id","halted","kill_switch");
   FileWrite(h, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), _Symbol, StateName(g_state), EnumToString(g_recovery.mode),
             IntegerToString(g_recovery.depth), IntegerToString(g_basket_id_counter), g_halt?"1":"0", g_kill_switch_latched?"1":"0");
   FileClose(h);
  }

//====================================================================
// SECTION 22: ALERTING LAYER (§22)
//====================================================================
bool AlertRecentlyFired(string key, int throttleSec)
  {
   for(int i=0;i<ArraySize(g_alert_keys);i++)
     {
      if(g_alert_keys[i]==key)
        {
         if(TimeCurrent()-g_alert_times[i] < throttleSec) return true;
         g_alert_times[i] = TimeCurrent();
         return false;
        }
     }
   int n = ArraySize(g_alert_keys);
   ArrayResize(g_alert_keys, n+1);
   ArrayResize(g_alert_times, n+1);
   g_alert_keys[n] = key;
   g_alert_times[n] = TimeCurrent();
   return false;
  }

void SendAlert(string eventKey, string details)
  {
   if(AlertRecentlyFired(eventKey, 60)) return;
   string msg = StringFormat("[%s] %s | %s | %s", InpEAPrefix, eventKey, _Symbol, details);
   Alert(msg);
   SendNotification(msg);
   if(InpUseWebhook && StringLen(InpWebhookURL)>0)
     {
      string headers = "Content-Type: application/json\r\n";
      string body = StringFormat("{\"event\":\"%s\",\"symbol\":\"%s\",\"details\":\"%s\"}", eventKey, _Symbol, details);
      uchar post[]; uchar result[]; string resultHeaders;
      StringToCharArray(body, post, 0, StringLen(body));
      ResetLastError();
      int rc = WebRequest("POST", InpWebhookURL, headers, 3000, post, result, resultHeaders);
      if(rc==-1)
        {
         int e = GetLastError();
         if(e==4014) LogError("Webhook", e, "WEBHOOK_PERMISSION_DENIED");
         else LogError("Webhook", e, "webhook send failed, fallback used");
        }
     }
  }

void RegisterExecFailure()
  {
   int n = ArraySize(g_exec_failure_times);
   ArrayResize(g_exec_failure_times, n+1);
   g_exec_failure_times[n] = TimeCurrent();

   datetime cutoff = TimeCurrent()-InpExecFailureWindowSec;
   datetime tmp[];
   int keep=0;
   for(int i=0;i<ArraySize(g_exec_failure_times);i++)
      if(g_exec_failure_times[i]>=cutoff)
        {
         ArrayResize(tmp, keep+1);
         tmp[keep]=g_exec_failure_times[i];
         keep++;
        }
   ArrayResize(g_exec_failure_times, keep);
   for(int i=0;i<keep;i++) g_exec_failure_times[i]=tmp[i];

   if(ArraySize(g_exec_failure_times) >= InpExecFailureAlertCount)
      SendAlert("EXECUTION_DEGRADATION", StringFormat("%d failures in %ds window", ArraySize(g_exec_failure_times), InpExecFailureWindowSec));
  }

//====================================================================
// SECTION 20: KILL SWITCH (§21)
//====================================================================
bool CheckKillSwitch()
  {
   string gv = InpEAPrefix+"_KILL_SWITCH";
   if(GlobalVariableCheck(gv) && GlobalVariableGet(gv)==1.0) return true;
   string flagFile = InpEAPrefix+"_KILL.flag";
   if(FileIsExist(flagFile, FILE_COMMON)) return true;
   return false;
  }

//====================================================================
// SECTION 6: MARKET SNAPSHOT BUILDER
//====================================================================
bool BuildMarketSnapshot(MarketSnapshot &snap)
  {
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
     {
      snap.valid = false;
      LogError("BuildMarketSnapshot", GetLastError(), "SymbolInfoTick failed");
      return false;
     }
   snap.symbol        = _Symbol;
   snap.time          = tick.time;
   snap.bid           = tick.bid;
   snap.ask           = tick.ask;
   snap.mid           = (tick.bid+tick.ask)/2.0;
   snap.digits        = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   snap.point         = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   snap.tick_size      = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   snap.tick_value     = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   snap.contract_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   snap.volume_min     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   snap.volume_max     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   snap.volume_step    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   snap.stops_level_points  = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   snap.freeze_level_points = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   snap.trade_mode     = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   snap.filling_mode_flags = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   snap.session_trade_allowed = (snap.trade_mode==SYMBOL_TRADE_MODE_FULL || snap.trade_mode==SYMBOL_TRADE_MODE_LONGONLY || snap.trade_mode==SYMBOL_TRADE_MODE_SHORTONLY);
   if(snap.point<=0) snap.spread_points = 0;
   else snap.spread_points = (snap.ask-snap.bid)/snap.point;
   snap.valid = true;
   return true;
  }

// §24: Broker Symbol Specification Drift detection
void CheckSymbolSpecDrift()
  {
   if(!g_prev_snap.valid) return;
   if(g_prev_snap.digits!=g_snap.digits || g_prev_snap.tick_size!=g_snap.tick_size || g_prev_snap.volume_step!=g_snap.volume_step)
     {
      LogError("SymbolSpecDrift", 0, "SYMBOL_SPEC_DRIFT_DETECTED");
      g_pending_intent_active = false;
      g_intent.valid = false;
      g_snapshot_dirty_after_drift = true;
     }
  }

//====================================================================
// SECTION 7: INDICATOR ENGINE
//====================================================================
bool InitIndicators()
  {
   h_atr       = iATR(_Symbol, PERIOD_M5, InpATRPeriod);
   h_ema_fast  = iMA(_Symbol, PERIOD_M5, InpEMAFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   h_ema_slow  = iMA(_Symbol, PERIOD_M5, InpEMASlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
   h_ema200_h1 = iMA(_Symbol, PERIOD_H1, InpEMA200H1Period, 0, MODE_EMA, PRICE_CLOSE);
   h_rsi       = iRSI(_Symbol, PERIOD_M5, InpRSIPeriod, PRICE_CLOSE);
   h_adx       = iADX(_Symbol, PERIOD_M5, InpADXPeriod);
   if(h_atr==INVALID_HANDLE || h_ema_fast==INVALID_HANDLE || h_ema_slow==INVALID_HANDLE ||
      h_ema200_h1==INVALID_HANDLE || h_rsi==INVALID_HANDLE || h_adx==INVALID_HANDLE)
     {
      LogError("InitIndicators", GetLastError(), "one or more indicator handles invalid");
      return false;
     }
   return true;
  }

void ReleaseIndicators()
  {
   if(h_atr!=INVALID_HANDLE) IndicatorRelease(h_atr);
   if(h_ema_fast!=INVALID_HANDLE) IndicatorRelease(h_ema_fast);
   if(h_ema_slow!=INVALID_HANDLE) IndicatorRelease(h_ema_slow);
   if(h_ema200_h1!=INVALID_HANDLE) IndicatorRelease(h_ema200_h1);
   if(h_rsi!=INVALID_HANDLE) IndicatorRelease(h_rsi);
   if(h_adx!=INVALID_HANDLE) IndicatorRelease(h_adx);
  }

bool CopyOne(int handle, int buffer, double &out)
  {
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, buffer, 0, 1, buf) != 1) return false;
   out = buf[0];
   return true;
  }

bool ComputeDonchian(int period, double &hi, double &lo)
  {
   double highs[], lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);
   if(CopyHigh(_Symbol, PERIOD_M5, 1, period, highs) != period) return false;
   if(CopyLow(_Symbol, PERIOD_M5, 1, period, lows) != period) return false;
   hi = highs[ArrayMaximum(highs)];
   lo = lows[ArrayMinimum(lows)];
   return true;
  }

bool ComputeSessionVWAP(double &vwap)
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   dt.hour=0; dt.min=0; dt.sec=0;
   datetime dayStart = StructToTime(dt);
   int bars = iBarShift(_Symbol, PERIOD_M5, dayStart, false);
   if(bars<=0) bars = 1;
   bars = MathMin(bars+1, 288);
   double closes[], vols[];
   ArraySetAsSeries(closes, true);
   ArraySetAsSeries(vols, true);
   if(CopyClose(_Symbol, PERIOD_M5, 0, bars, closes) != bars) return false;
   long tv[]; ArraySetAsSeries(tv, true);
   if(CopyTickVolume(_Symbol, PERIOD_M5, 0, bars, tv) != bars) return false;
   double sumPV=0, sumV=0;
   for(int i=0;i<bars;i++) { sumPV += closes[i]*(double)tv[i]; sumV += (double)tv[i]; }
   if(sumV<=0) { vwap = closes[0]; return true; }
   vwap = sumPV/sumV;
   return true;
  }

bool UpdateRegimeSnapshot(RegimeSnapshot &r)
  {
   double atrArr[]; ArraySetAsSeries(atrArr, true);
   if(CopyBuffer(h_atr, 0, 0, 20, atrArr) < 20) { LogError("Regime", GetLastError(), "CopyBuffer ATR failed"); return false; }
   double atrNow = atrArr[0];
   double atrAvg=0; for(int i=0;i<20;i++) atrAvg+=atrArr[i]; atrAvg/=20.0;

   double emaFast, emaSlow, ema200h1, rsi;
   if(!CopyOne(h_ema_fast,0,emaFast))  { LogError("Regime", GetLastError(), "ema fast copy failed"); return false; }
   if(!CopyOne(h_ema_slow,0,emaSlow))  { LogError("Regime", GetLastError(), "ema slow copy failed"); return false; }
   if(!CopyOne(h_ema200_h1,0,ema200h1)){ LogError("Regime", GetLastError(), "ema200 h1 copy failed"); return false; }
   if(!CopyOne(h_rsi,0,rsi))            { LogError("Regime", GetLastError(), "rsi copy failed"); return false; }

   double adxMain[]; ArraySetAsSeries(adxMain, true);
   if(CopyBuffer(h_adx, 0, 0, 1, adxMain) != 1) { LogError("Regime", GetLastError(), "adx copy failed"); return false; }
   double adx = adxMain[0];

   double dHi, dLo;
   if(!ComputeDonchian(InpDonchianPeriod, dHi, dLo)) { LogError("Regime", GetLastError(), "donchian failed"); return false; }
   double vwap;
   if(!ComputeSessionVWAP(vwap)) vwap = g_snap.mid;

   r.atr = atrNow; r.ema_fast=emaFast; r.ema_slow=emaSlow; r.ema200_h1=ema200h1; r.rsi=rsi; r.adx=adx;
   r.donchian_high=dHi; r.donchian_low=dLo; r.vwap=vwap;
   r.trend_strength = adx;
   r.volatility_bucket = (atrAvg>0 && atrNow > atrAvg*1.3) ? 2 : ((atrAvg>0 && atrNow < atrAvg*0.7) ? 0 : 1);

   bool kill = CheckKillSwitch();
   string newsFlag = InpEAPrefix+"_NEWS.flag";
   bool newsLock = FileIsExist(newsFlag, FILE_COMMON);

   if(newsLock)
     {
      r.regime = REGIME_NEWS_LOCK; r.confidence=90;
     }
   else if(atrAvg>0 && atrNow > atrAvg*InpChaosATRMultiplier)
     {
      r.regime = REGIME_CHAOS; r.confidence=80;
     }
   else if(g_snap.mid > dHi && adx>=InpADXTrendThreshold)
     {
      r.regime = REGIME_BREAKOUT_UP; r.confidence=75; r.trend_direction=1;
     }
   else if(g_snap.mid < dLo && adx>=InpADXTrendThreshold)
     {
      r.regime = REGIME_BREAKOUT_DOWN; r.confidence=75; r.trend_direction=-1;
     }
   else if(adx>=InpADXTrendThreshold && emaFast>emaSlow && emaSlow>ema200h1)
     {
      r.regime = REGIME_TREND_UP; r.confidence=70; r.trend_direction=1;
     }
   else if(adx>=InpADXTrendThreshold && emaFast<emaSlow && emaSlow<ema200h1)
     {
      r.regime = REGIME_TREND_DOWN; r.confidence=70; r.trend_direction=-1;
     }
   else if(adx<=InpADXRangeThreshold)
     {
      r.regime = REGIME_RANGE; r.confidence=65; r.trend_direction=0;
     }
   else
     {
      r.regime = REGIME_UNKNOWN; r.confidence=30; r.trend_direction=0;
     }

   r.allow_mean_reversion = (r.regime==REGIME_RANGE);
   r.allow_breakout       = (r.regime==REGIME_BREAKOUT_UP || r.regime==REGIME_BREAKOUT_DOWN);
   r.allow_grid           = (r.regime==REGIME_RANGE) && InpEnableGrid;
   r.allow_hedge          = (r.regime==REGIME_TREND_UP || r.regime==REGIME_TREND_DOWN) && InpEnableHedge;
   return true;
  }

// §23 grid-step-vs-broker-constraint check against live ATR, throttled to once per bar.
datetime g_last_grid_step_check_bar = 0;
void CheckGridStepVsBrokerConstraint()
  {
   datetime barTime = iTime(_Symbol, PERIOD_M5, 0);
   if(barTime==g_last_grid_step_check_bar) return;
   g_last_grid_step_check_bar = barTime;

   double gridStepPoints = InpGridStepATRMultiplier*g_regime.atr/g_snap.point;
   double constraintPoints = g_snap.stops_level_points+g_snap.freeze_level_points;
   if(gridStepPoints <= constraintPoints)
      LogError("GridStepVsBrokerConstraint", 0, "grid step ("+DoubleToString(gridStepPoints,1)+"pts) too tight against stops+freeze level ("+DoubleToString(constraintPoints,1)+"pts)");
  }

//====================================================================
// SECTION 18b: SESSION TIME INTEGRITY (§18)
//====================================================================
void RecomputeBrokerTimeOffset()
  {
   int prevOffset = g_btime.gmt_offset_hours;
   datetime gmt = TimeGMT();
   datetime srv = TimeCurrent();
   int offset = (int)MathRound((double)(gmt-srv)/3600.0);
   g_btime.gmt_offset_hours = offset;
   g_btime.last_offset_check_time = TimeCurrent();
   if(g_prev_snap.valid && prevOffset != offset && prevOffset != 0)
     {
      LogError("SessionTimeIntegrity", 0, "SESSION_OFFSET_SHIFT_DETECTED prev="+IntegerToString(prevOffset)+" new="+IntegerToString(offset));
     }
  }

//====================================================================
// SECTION 8: SESSION ENGINE
//====================================================================
ENUM_SESSION_MODE ComputeSessionMode()
  {
   bool terminalOk = TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) && TerminalInfoInteger(TERMINAL_CONNECTED);
   bool accountOk  = AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)!=0;

   if(InpForcedFlatBeforeWeekend && IsFridayFlatWindow())
      return SESSION_FLAT_ONLY;

   if(!terminalOk || !accountOk)
      return SESSION_CLOSED;

   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt); // TimeCurrent() is already broker server time
   int hour = dt.hour;

   if(hour>=InpReduceOnlyStartHour)
      return SESSION_REDUCE_ONLY;

   if(hour>=InpEntryStartHour && hour<InpEntryEndHour)
      return SESSION_ENTRY_ALLOWED;

   return SESSION_RECOVERY_ONLY;
  }

//====================================================================
// SECTION 19: CURRENCY NORMALIZATION (§19)
//====================================================================
bool RefreshCurrencyContext()
  {
   g_ccy.account_currency = AccountInfoString(ACCOUNT_CURRENCY);
   g_ccy.symbol_profit_currency = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);

   if(g_ccy.account_currency==g_ccy.symbol_profit_currency)
     {
      g_ccy.conversion_rate = 1.0;
      g_ccy.conversion_valid = true;
      g_ccy.last_refresh = TimeCurrent();
      return true;
     }

   if(InpAssumeUSDOnlyAccount)
     {
      // Validated once at OnInit; if currencies diverge here at runtime, treat as failure.
      g_ccy.conversion_valid = false;
      LogError("CurrencyNormalization", 0, "CURRENCY_CONVERSION_UNAVAILABLE - USD-only assumption violated at runtime");
      return false;
     }

   string pair1 = g_ccy.symbol_profit_currency+g_ccy.account_currency;
   string pair2 = g_ccy.account_currency+g_ccy.symbol_profit_currency;
   string useSymbol = "";
   bool invert = false;
   if(SymbolSelect(pair1, true) && SymbolInfoDouble(pair1, SYMBOL_BID)>0) { useSymbol=pair1; invert=false; }
   else if(SymbolSelect(pair2, true) && SymbolInfoDouble(pair2, SYMBOL_BID)>0) { useSymbol=pair2; invert=true; }

   if(useSymbol=="")
     {
      g_ccy.conversion_valid = false;
      LogError("CurrencyNormalization", 0, "CURRENCY_CONVERSION_UNAVAILABLE - no conversion pair found");
      return false;
     }

   MqlTick t;
   if(!SymbolInfoTick(useSymbol, t) || (TimeCurrent()-t.time) > 300)
     {
      g_ccy.conversion_valid = false;
      LogError("CurrencyNormalization", 0, "CURRENCY_CONVERSION_UNAVAILABLE - stale tick on "+useSymbol);
      return false;
     }

   double mid = (t.bid+t.ask)/2.0;
   g_ccy.conversion_rate = invert ? (mid>0 ? 1.0/mid : 0.0) : mid;
   g_ccy.conversion_valid = (g_ccy.conversion_rate>0);
   g_ccy.last_refresh = TimeCurrent();
   if(!g_ccy.conversion_valid)
      LogError("CurrencyNormalization", 0, "CURRENCY_CONVERSION_UNAVAILABLE - invalid rate");
   return g_ccy.conversion_valid;
  }

//====================================================================
// SECTION 14: POSITION / BASKET MANAGER
//====================================================================
void SyncExposureLedger()
  {
   ExposureLedger e; ZeroMemory(e);
   double sumBuyPrice=0, sumSellPrice=0; int buyCnt=0, sellCnt=0;
   double floatingPL=0;
   int depthGrid=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;

      double vol = PositionGetDouble(POSITION_VOLUME);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      floatingPL += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      e.position_count++;
      e.gross_lots += vol;

      if(ptype==POSITION_TYPE_BUY) { e.buy_lots+=vol; sumBuyPrice+=openPrice*vol; buyCnt++; }
      else                          { e.sell_lots+=vol; sumSellPrice+=openPrice*vol; sellCnt++; }

      string cmt = PositionGetString(POSITION_COMMENT);
      if(StringFind(cmt, "GRID")>=0 || StringFind(cmt, "HEDGE")>=0) depthGrid++;
     }
   e.net_lots = e.buy_lots - e.sell_lots;
   e.avg_buy_price  = e.buy_lots>0 ? sumBuyPrice/e.buy_lots : 0.0;
   e.avg_sell_price = e.sell_lots>0 ? sumSellPrice/e.sell_lots : 0.0;
   g_exposure = e;

   g_basket.floating_pl = floatingPL;
   g_basket.has_positions = (e.position_count>0);
   g_basket.gross_lots = e.gross_lots;
   g_basket.depth = depthGrid;
   g_basket.basket_id = g_basket_id_counter;
   if(!g_basket.has_positions && g_recovery.depth>0)
     {
      // basket fully closed: recovery cycle complete, reset
      g_recovery.mode = RECOVERY_NONE;
      g_recovery.depth = 0;
      g_recovery.hedge_lots = 0;
     }
  }

void SyncDailyRealizedPL()
  {
   ResetDailyPLIfNewDay();
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   dt.hour=0; dt.min=0; dt.sec=0;
   datetime dayStart = StructToTime(dt);
   if(!HistorySelect(dayStart, TimeCurrent())) return;
   double sum=0;
   int total = HistoryDealsTotal();
   for(int i=0;i<total;i++)
     {
      ulong dticket = HistoryDealGetTicket(i);
      if(dticket==0) continue;
      if(HistoryDealGetString(dticket, DEAL_SYMBOL)!=_Symbol) continue;
      if((long)HistoryDealGetInteger(dticket, DEAL_MAGIC)!=InpMagicNumber) continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(dticket, DEAL_ENTRY)!=DEAL_ENTRY_OUT) continue;
      sum += HistoryDealGetDouble(dticket, DEAL_PROFIT) + HistoryDealGetDouble(dticket, DEAL_SWAP) + HistoryDealGetDouble(dticket, DEAL_COMMISSION);
     }
   g_daily_realized_pl = sum;
   g_basket.realized_pl_today = sum;
  }

//====================================================================
// SECTION 17: MULTI-INSTANCE SHARED RISK LEDGER (§17)
//====================================================================
struct SharedLedgerRow
  {
   long   magic;
   double lots;
   double floating_pl;
   double margin_pct;
   datetime tstamp;
  };

bool ReadSharedLedgerRows(SharedLedgerRow &rows[])
  {
   ArrayResize(rows,0);
   if(!FileIsExist(g_shared_ledger_file, FILE_COMMON)) return false;
   int h = FileOpen(g_shared_ledger_file, FILE_READ|FILE_CSV|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE, ';');
   if(h==INVALID_HANDLE) return false;
   while(!FileIsEnding(h))
     {
      string sMagic = FileReadString(h);
      if(sMagic=="") break;
      string sLots = FileReadString(h);
      string sPL   = FileReadString(h);
      string sMargin = FileReadString(h);
      string sTime = FileReadString(h);
      SharedLedgerRow row;
      row.magic = StringToInteger(sMagic);
      row.lots  = StringToDouble(sLots);
      row.floating_pl = StringToDouble(sPL);
      row.margin_pct  = StringToDouble(sMargin);
      row.tstamp = (datetime)StringToInteger(sTime);
      int n = ArraySize(rows);
      ArrayResize(rows, n+1);
      rows[n] = row;
     }
   FileClose(h);
   return true;
  }

void WriteSharedLedgerRow()
  {
   if(!InpParticipateSharedLedger) return;
   SharedLedgerRow rows[];
   ReadSharedLedgerRows(rows);
   double marginPct = 0;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq>0) marginPct = AccountInfoDouble(ACCOUNT_MARGIN)/eq*100.0;

   bool found=false;
   for(int i=0;i<ArraySize(rows);i++)
     {
      if(rows[i].magic==InpMagicNumber)
        {
         rows[i].lots = g_exposure.gross_lots;
         rows[i].floating_pl = g_basket.floating_pl;
         rows[i].margin_pct = marginPct;
         rows[i].tstamp = TimeCurrent();
         found=true;
         break;
        }
     }
   if(!found)
     {
      int n=ArraySize(rows);
      ArrayResize(rows,n+1);
      rows[n].magic=InpMagicNumber; rows[n].lots=g_exposure.gross_lots; rows[n].floating_pl=g_basket.floating_pl;
      rows[n].margin_pct=marginPct; rows[n].tstamp=TimeCurrent();
     }

   int h = FileOpen(g_shared_ledger_file, FILE_WRITE|FILE_CSV|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE, ';');
   if(h==INVALID_HANDLE) { LogError("SharedLedger", GetLastError(), "write open failed"); return; }
   for(int i=0;i<ArraySize(rows);i++)
      FileWrite(h, IntegerToString(rows[i].magic), DoubleToString(rows[i].lots,2), DoubleToString(rows[i].floating_pl,2),
                DoubleToString(rows[i].margin_pct,2), IntegerToString((long)rows[i].tstamp));
   FileClose(h);
  }

bool ReadSharedLedgerAggregate(double &totalLots, double &totalFloatingPL, bool &staleDetected)
  {
   totalLots=0; totalFloatingPL=0; staleDetected=false;
   SharedLedgerRow rows[];
   if(!ReadSharedLedgerRows(rows) || ArraySize(rows)==0) return false;
   for(int i=0;i<ArraySize(rows);i++)
     {
      totalLots += rows[i].lots;
      totalFloatingPL += rows[i].floating_pl;
      if(TimeCurrent()-rows[i].tstamp > InpSharedLedgerStaleSeconds) staleDetected=true;
     }
   return true;
  }

//====================================================================
// SECTION 9: (regime engine defined in Section 7 above)
//====================================================================

//====================================================================
// SECTION 10: SIGNAL ENGINE
//====================================================================
bool ComputeSignal(SignalDecision &s)
  {
   ZeroMemory(s);
   s.signal_time = TimeCurrent();
   s.regime_at_signal = g_regime.regime;
   s.direction = SIGNAL_HOLD;
   s.score = 0;
   s.allow_entry = false;
   s.entry_price_reference = g_snap.mid;

   if(g_regime.regime==REGIME_CHAOS || g_regime.regime==REGIME_NEWS_LOCK || g_regime.regime==REGIME_UNKNOWN)
     {
      s.reason = "regime blocks entry: "+EnumToString(g_regime.regime);
      return true;
     }

   double score=0; ENUM_SIGNAL_TYPE dir = SIGNAL_HOLD; string reason="";

   if(g_regime.regime==REGIME_RANGE)
     {
      if(g_regime.rsi<=InpRSIOversold && g_snap.mid < g_regime.vwap)
        {
         dir = SIGNAL_BUY; score = 55 + (InpRSIOversold-g_regime.rsi);
         reason = "range mean-reversion BUY: RSI oversold below VWAP";
        }
      else if(g_regime.rsi>=InpRSIOverbought && g_snap.mid > g_regime.vwap)
        {
         dir = SIGNAL_SELL; score = 55 + (g_regime.rsi-InpRSIOverbought);
         reason = "range mean-reversion SELL: RSI overbought above VWAP";
        }
     }
   else if(g_regime.regime==REGIME_TREND_UP)
     {
      if(g_regime.ema_fast>g_regime.ema_slow && g_regime.rsi<InpRSIOverbought)
        {
         dir = SIGNAL_BUY; score = 50 + MathMin(g_regime.adx-InpADXTrendThreshold,20);
         reason = "trend-follow BUY: EMA fast>slow, ADX confirmed";
        }
     }
   else if(g_regime.regime==REGIME_TREND_DOWN)
     {
      if(g_regime.ema_fast<g_regime.ema_slow && g_regime.rsi>InpRSIOversold)
        {
         dir = SIGNAL_SELL; score = 50 + MathMin(g_regime.adx-InpADXTrendThreshold,20);
         reason = "trend-follow SELL: EMA fast<slow, ADX confirmed";
        }
     }
   else if(g_regime.regime==REGIME_BREAKOUT_UP)
     {
      dir = SIGNAL_BUY; score = g_regime.confidence;
      reason = "breakout BUY: close above Donchian high";
     }
   else if(g_regime.regime==REGIME_BREAKOUT_DOWN)
     {
      dir = SIGNAL_SELL; score = g_regime.confidence;
      reason = "breakout SELL: close below Donchian low";
     }

   // Exit signals for an already-open basket take priority over any fresh entry read,
   // since managing existing exposure is higher priority than scanning for new exposure.
   bool haveBuy  = g_exposure.buy_lots>0;
   bool haveSell = g_exposure.sell_lots>0;
   if(haveBuy && (g_regime.regime==REGIME_TREND_DOWN || g_regime.regime==REGIME_BREAKOUT_DOWN))
     {
      dir = SIGNAL_EXIT_BUY; score = 80;
      reason = "exit BUY basket: regime reversed to "+EnumToString(g_regime.regime);
     }
   else if(haveBuy && g_regime.regime==REGIME_RANGE && g_regime.rsi>=InpRSIOverbought)
     {
      dir = SIGNAL_EXIT_BUY; score = 65;
      reason = "exit BUY basket: RSI overbought reversion in range";
     }
   else if(haveSell && (g_regime.regime==REGIME_TREND_UP || g_regime.regime==REGIME_BREAKOUT_UP))
     {
      dir = SIGNAL_EXIT_SELL; score = 80;
      reason = "exit SELL basket: regime reversed to "+EnumToString(g_regime.regime);
     }
   else if(haveSell && g_regime.regime==REGIME_RANGE && g_regime.rsi<=InpRSIOversold)
     {
      dir = SIGNAL_EXIT_SELL; score = 65;
      reason = "exit SELL basket: RSI oversold reversion in range";
     }

   s.direction = dir;
   s.score = score;
   s.reason = reason;
   s.signal_age_seconds = 0;
   s.invalidation_price = (dir==SIGNAL_BUY) ? g_snap.mid - g_regime.atr*2.0 : (dir==SIGNAL_SELL ? g_snap.mid + g_regime.atr*2.0 : 0.0);
   s.target_price        = (dir==SIGNAL_BUY) ? g_snap.mid + g_regime.atr*1.5 : (dir==SIGNAL_SELL ? g_snap.mid - g_regime.atr*1.5 : 0.0);
   s.allow_entry = (dir==SIGNAL_BUY || dir==SIGNAL_SELL) && (score>=InpMinSignalScore);
   return true;
  }

//====================================================================
// SECTION 11: RISK ENGINE
//====================================================================
RiskDecision ComputeRiskState()
  {
   RiskDecision rd; ZeroMemory(rd);
   rd.risk_state = RISK_NORMAL;
   rd.allow_entry = true;
   rd.allow_recovery = true;
   rd.allow_hedge = true;
   rd.allow_partial_close = true;
   rd.allow_flatten = true;
   rd.max_new_lot = InpBaseLot;
   rd.max_total_lot = InpMaxExposureLots;
   rd.block_reason = "";
   rd.force_action = ST_IDLE;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double marginUsedPct = equity>0 ? AccountInfoDouble(ACCOUNT_MARGIN)/equity*100.0 : 0.0;
   double freeMarginPct = equity>0 ? AccountInfoDouble(ACCOUNT_MARGIN_FREE)/equity*100.0 : 100.0;
   double ddPct = balance>0 ? (balance-equity)/balance*100.0 : 0.0;

   // Hard equity stop (highest priority)
   if(ddPct >= InpHardEquityStopPct)
     {
      rd.risk_state = RISK_HARD_STOP;
      rd.allow_entry=false; rd.allow_recovery=false; rd.allow_hedge=false; rd.allow_partial_close=true; rd.allow_flatten=true;
      rd.max_new_lot=0; rd.max_total_lot=0;
      rd.block_reason = "HARD_EQUITY_STOP drawdown="+DoubleToString(ddPct,2);
      rd.force_action = ST_FLATTEN;
      return rd;
     }

   // Currency conversion gate (§19)
   if(!g_ccy.conversion_valid && !InpAssumeUSDOnlyAccount)
     {
      rd.risk_state = RISK_NO_EXPANSION;
      rd.allow_entry=false; rd.allow_recovery=false; rd.allow_hedge=false;
      rd.block_reason = "CURRENCY_CONVERSION_UNAVAILABLE";
     }

   // Total drawdown gate
   if(ddPct >= InpMaxTotalDrawdownPct)
     {
      rd.risk_state = RISK_FORCE_REDUCE;
      rd.allow_entry=false; rd.allow_recovery=false; rd.allow_hedge=false; rd.allow_partial_close=true;
      rd.block_reason = "TOTAL_DD_BREACH dd="+DoubleToString(ddPct,2);
      rd.force_action = ST_FORCE_REDUCE;
     }

   // Daily loss gate
   double dailyLossLimit = balance*InpMaxDailyLossPct/100.0;
   if(-g_daily_realized_pl >= dailyLossLimit && rd.risk_state!=RISK_FORCE_REDUCE)
     {
      rd.risk_state = RISK_NO_EXPANSION;
      rd.allow_entry=false; rd.allow_recovery=false; rd.allow_hedge=false;
      rd.block_reason = "DAILY_LOSS_BREACH pl="+DoubleToString(g_daily_realized_pl,2);
     }

   // Basket loss gate. POSITION_PROFIT/SWAP are already reported by the
   // terminal in account currency, so no further conversion is applied here;
   // the CURRENCY_CONVERSION_UNAVAILABLE gate above still blocks expansion
   // when account and symbol profit currencies diverge and the pair can't be resolved.
   double basketLossLimit = InpMaxBasketLossMoney;
   double basketFloatingAccountCcy = g_basket.floating_pl;
   if(-basketFloatingAccountCcy >= basketLossLimit && rd.risk_state==RISK_NORMAL)
     {
      rd.risk_state = RISK_RECOVERY_ONLY;
      rd.allow_entry=false;
      rd.block_reason = "BASKET_LOSS_BREACH pl="+DoubleToString(basketFloatingAccountCcy,2);
     }

   // Floating loss % of equity gate
   if(equity>0 && (-basketFloatingAccountCcy)/equity*100.0 >= InpMaxFloatingLossPct && rd.risk_state!=RISK_FORCE_REDUCE)
     {
      rd.risk_state = RISK_FORCE_REDUCE;
      rd.allow_entry=false; rd.allow_recovery=false; rd.allow_hedge=false;
      rd.block_reason = "FLOATING_LOSS_PCT_BREACH";
      rd.force_action = ST_FORCE_REDUCE;
     }

   // Margin gates
   if(marginUsedPct >= InpMaxMarginUsagePct)
     {
      if(rd.risk_state==RISK_NORMAL) rd.risk_state = RISK_NO_EXPANSION;
      rd.allow_entry=false; rd.allow_recovery=false;
      rd.block_reason = "MARGIN_USAGE_BREACH pct="+DoubleToString(marginUsedPct,2);
     }
   if(freeMarginPct < InpMinFreeMarginPct)
     {
      if(rd.risk_state==RISK_NORMAL) rd.risk_state = RISK_NO_EXPANSION;
      rd.allow_entry=false; rd.allow_recovery=false;
      rd.block_reason = "FREE_MARGIN_LOW pct="+DoubleToString(freeMarginPct,2);
     }

   // Exposure cap (local)
   if(g_exposure.gross_lots >= InpMaxExposureLots)
     {
      rd.allow_entry=false; rd.allow_recovery=false;
      if(rd.risk_state==RISK_NORMAL) rd.risk_state = RISK_NO_EXPANSION;
      rd.block_reason = "LOCAL_EXPOSURE_CAP";
     }

   // Max recovery depth
   if(g_recovery.depth >= InpMaxRecoveryDepth)
     {
      rd.allow_recovery=false; rd.allow_hedge=false;
      if(rd.risk_state==RISK_NORMAL) rd.risk_state = RISK_NO_EXPANSION;
      rd.block_reason = "MAX_RECOVERY_DEPTH";
     }

   // News/chaos lock
   if(g_regime.regime==REGIME_CHAOS || g_regime.regime==REGIME_NEWS_LOCK)
     {
      rd.allow_entry=false; rd.allow_recovery=false; rd.allow_hedge=false;
      if(rd.risk_state==RISK_NORMAL) rd.risk_state = RISK_CAUTION;
      rd.block_reason = "NEWS_OR_CHAOS_LOCK";
     }

   // §17 Shared account-level exposure governance
   if(InpParticipateSharedLedger)
     {
      double totalLots=0, totalFloatPL=0; bool stale=false;
      bool ok = ReadSharedLedgerAggregate(totalLots, totalFloatPL, stale);
      if(!ok)
        {
         // ledger unavailable -> degraded mode, halve local caps
         rd.max_total_lot = InpMaxExposureLots/2.0;
         if(g_exposure.gross_lots >= rd.max_total_lot)
           {
            rd.allow_entry=false; rd.allow_recovery=false;
            if(rd.risk_state==RISK_NORMAL) rd.risk_state = RISK_NO_EXPANSION;
           }
         rd.block_reason = "SHARED_LEDGER_UNAVAILABLE_DEGRADED_MODE";
         LogError("SharedLedger", 0, "SHARED_LEDGER_UNAVAILABLE_DEGRADED_MODE");
        }
      else
        {
         if(stale)
           {
            rd.allow_entry=false; rd.allow_recovery=false;
            if(rd.risk_state==RISK_NORMAL) rd.risk_state = RISK_NO_EXPANSION;
            rd.block_reason = "SHARED_LEDGER_STALE";
           }
         if(totalLots >= InpMaxAccountExposureLots)
           {
            rd.allow_entry=false; rd.allow_recovery=false;
            if(rd.risk_state==RISK_NORMAL) rd.risk_state = RISK_NO_EXPANSION;
            rd.block_reason = "ACCOUNT_EXPOSURE_CAP";
           }
         if(-totalFloatPL >= InpMaxAccountFloatingLossMoney)
           {
            rd.allow_entry=false; rd.allow_recovery=false;
            if(rd.risk_state==RISK_NORMAL) rd.risk_state = RISK_RECOVERY_ONLY;
            rd.block_reason = "ACCOUNT_FLOATING_LOSS_CAP";
           }
        }
     }

   if(rd.risk_state==RISK_NORMAL || rd.risk_state==RISK_RECOVERY_ONLY)
      rd.max_new_lot = InpBaseLot;
   else
      rd.max_new_lot = 0;

   return rd;
  }

//====================================================================
// SECTION 12: BROKERGATE
//====================================================================
ENUM_ORDER_TYPE_FILLING SelectFillingMode()
  {
   int flags = g_snap.filling_mode_flags;
   if((flags & SYMBOL_FILLING_FOK)!=0) return ORDER_FILLING_FOK;
   if((flags & SYMBOL_FILLING_IOC)!=0) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
  }

ENUM_BROKER_GATE_RESULT RunBrokerGate(const TradeIntent &intent)
  {
   if(!g_snap.valid) return BROKER_BLOCK_STALE_PRICE;
   if(TimeCurrent()-g_snap.time > 10) return BROKER_BLOCK_STALE_PRICE;

   if(g_snap.trade_mode==SYMBOL_TRADE_MODE_DISABLED) return BROKER_BLOCK_TRADE_DISABLED;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return BROKER_BLOCK_TRADE_DISABLED;
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)) return BROKER_BLOCK_TRADE_DISABLED;

   bool isReduceType = (intent.intent_type==INTENT_PARTIAL_CLOSE || intent.intent_type==INTENT_FLATTEN);

   if(!isReduceType)
     {
      if(!g_snap.session_trade_allowed) return BROKER_BLOCK_SESSION_CLOSED;
      if(g_snap.spread_points > InpMaxSpreadPoints) return BROKER_BLOCK_SPREAD;
     }

   // Reduce/close orders must never be blocked by min/step drift against an existing
   // position's volume - only new-exposure orders are validated against current volume limits.
   if(!isReduceType)
     {
      if(intent.volume < g_snap.volume_min - 1e-8 || intent.volume > g_snap.volume_max + 1e-8) return BROKER_BLOCK_VOLUME;
      double stepsCheck = MathRound(intent.volume/g_snap.volume_step);
      if(MathAbs(stepsCheck*g_snap.volume_step - intent.volume) > 1e-6) return BROKER_BLOCK_VOLUME;
     }

   if(!isReduceType && (intent.sl>0 || intent.tp>0))
     {
      double minDist = g_snap.stops_level_points*g_snap.point;
      double refPrice = (intent.direction==ORDER_TYPE_BUY) ? g_snap.ask : g_snap.bid;
      if(intent.sl>0 && MathAbs(refPrice-intent.sl) < minDist) return BROKER_BLOCK_STOP_LEVEL;
      if(intent.tp>0 && MathAbs(intent.tp-refPrice) < minDist) return BROKER_BLOCK_STOP_LEVEL;
     }

   if(intent.intent_type==INTENT_MODIFY)
     {
      double freezeDist = g_snap.freeze_level_points*g_snap.point;
      double refPrice = g_snap.mid;
      if(intent.sl>0 && MathAbs(refPrice-intent.sl) < freezeDist) return BROKER_BLOCK_FREEZE_LEVEL;
      if(intent.tp>0 && MathAbs(intent.tp-refPrice) < freezeDist) return BROKER_BLOCK_FREEZE_LEVEL;
     }

   double marginReq=0;
   ENUM_ORDER_TYPE ot = intent.direction;
   double priceForMargin = (ot==ORDER_TYPE_BUY) ? g_snap.ask : g_snap.bid;
   if(!isReduceType)
     {
      if(!OrderCalcMargin(ot, _Symbol, intent.volume, priceForMargin, marginReq)) return BROKER_BLOCK_MARGIN;
      double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(marginReq > freeMargin) return BROKER_BLOCK_MARGIN;
   }

   if(!isReduceType && g_pending_intent_active) return BROKER_BLOCK_DUPLICATE;
   if(intent.intent_type==INTENT_PARTIAL_CLOSE || intent.intent_type==INTENT_MODIFY)
     {
      if(g_pending_close_lock) return BROKER_BLOCK_DUPLICATE;
     }

   return BROKER_PASS;
  }

//====================================================================
// SECTION 13: ORDERCHECK / ORDERSEND ENGINE
//====================================================================
void BuildRequestFromIntent(const TradeIntent &intent, MqlTradeRequest &req)
  {
   ZeroMemory(req);
   req.symbol   = _Symbol;
   req.magic    = intent.magic;
   req.deviation= intent.deviation;
   req.comment  = intent.comment;
   req.type_filling = SelectFillingMode();

   if(intent.intent_type==INTENT_ENTRY || intent.intent_type==INTENT_GRID || intent.intent_type==INTENT_HEDGE)
     {
      req.action = TRADE_ACTION_DEAL;
      req.type   = intent.direction;
      req.volume = intent.volume;
      req.price  = (intent.direction==ORDER_TYPE_BUY) ? g_snap.ask : g_snap.bid;
      req.sl     = intent.sl;
      req.tp     = intent.tp;
      req.type_time = ORDER_TIME_GTC;
     }
   else if(intent.intent_type==INTENT_PARTIAL_CLOSE || intent.intent_type==INTENT_FLATTEN)
     {
      req.action   = TRADE_ACTION_DEAL;
      req.position = intent.target_ticket;
      req.volume   = intent.volume;
      req.type     = intent.direction; // opposite of position type, set by caller
      req.price    = (intent.direction==ORDER_TYPE_BUY) ? g_snap.ask : g_snap.bid;
      req.type_time = ORDER_TIME_GTC;
     }
   else if(intent.intent_type==INTENT_MODIFY)
     {
      req.action   = TRADE_ACTION_SLTP;
      req.position = intent.target_ticket;
      req.sl       = intent.sl;
      req.tp       = intent.tp;
     }
  }

// Single bounded attempt to re-attach SL/TP to a position that was sent naked
// after TRADE_RETCODE_INVALID_STOPS. If freeze level still blocks it, the
// failure is logged so the unprotected position is visible for reconciliation.
void AttemptSltpFollowup(ulong positionTicket, double sl, double tp)
  {
   if(!PositionSelectByTicket(positionTicket)) return;

   TradeIntent mti; ZeroMemory(mti);
   mti.intent_type = INTENT_MODIFY;
   mti.target_ticket = positionTicket;
   mti.sl = NormalizePriceValue(sl);
   mti.tp = NormalizePriceValue(tp);
   mti.magic = InpMagicNumber;

   ENUM_BROKER_GATE_RESULT bg = RunBrokerGate(mti);
   LogBroker(bg, mti);
   if(bg != BROKER_PASS)
     {
      LogError("SltpFollowup", 0, "blocked by broker gate: "+EnumToString(bg)+" ticket="+IntegerToString((long)positionTicket));
      return;
     }

   MqlTradeRequest req; BuildRequestFromIntent(mti, req);
   MqlTradeCheckResult chk; ZeroMemory(chk);
   bool checkOk = OrderCheck(req, chk);
   LogOrderCheck(req, chk, checkOk, RISK_NORMAL, bg);
   if(!checkOk)
     {
      LogError("SltpFollowup", GetLastError(), "ORDERCHECK_FAIL retcode="+IntegerToString((int)chk.retcode));
      return;
     }

   MqlTradeResult res; ZeroMemory(res);
   ResetLastError();
   bool ok = OrderSend(req, res);
   LogExecution(req, res, ok, GetLastError(), 0, 0, ok?"SLTP_REATTACHED":"SLTP_REATTACH_FAILED");
   if(!ok) LogError("SltpFollowup", GetLastError(), "position left without SL/TP, ticket="+IntegerToString((long)positionTicket));
  }

// Returns true if order eventually succeeded (fully or partially), false otherwise.
bool ExecuteIntent(const TradeIntent &intentIn, ENUM_RISK_STATE rs)
  {
   TradeIntent intent = intentIn;

   // INV-2: no grid/hedge expansion while risk_state in {FORCE_REDUCE, HARD_STOP}
   if((intent.intent_type==INTENT_GRID || intent.intent_type==INTENT_HEDGE) &&
      (rs==RISK_FORCE_REDUCE || rs==RISK_HARD_STOP))
     {
      LogError("Invariant", 0, "INV-2 violated attempt blocked");
      return false;
     }
   // INV-5: recovery depth check
   if((intent.intent_type==INTENT_GRID || intent.intent_type==INTENT_HEDGE) && g_recovery.depth >= InpMaxRecoveryDepth)
     {
      LogError("Invariant", 0, "INV-5 violated attempt blocked");
      return false;
     }
   // INV-4: trade lock blocks non-reduce intents
   bool isReduce = (intent.intent_type==INTENT_PARTIAL_CLOSE || intent.intent_type==INTENT_FLATTEN);
   if(g_trade_lock && !isReduce)
     {
      LogError("Invariant", 0, "INV-4 g_trade_lock blocks non-reduce intent");
      return false;
     }
   // INV-3: duplicate intent guard
   if(!isReduce && g_pending_intent_active) return false;
   if(isReduce && g_pending_close_lock) return false;

   intent.volume = NormalizeVolume(intent.volume);

   ENUM_BROKER_GATE_RESULT bg = RunBrokerGate(intent);
   LogBroker(bg, intent);
   if(bg != BROKER_PASS)
     {
      SetState(ST_IDLE, "broker gate blocked: "+EnumToString(bg));
      return false;
     }

   g_pending_intent_active = !isReduce;
   g_pending_close_lock = isReduce;
   g_trade_lock = true;

   MqlTradeRequest req;
   BuildRequestFromIntent(intent, req);

   SetState(ST_ORDERCHECK, "preflight validation for "+EnumToString(intent.intent_type));
   MqlTradeCheckResult chk; ZeroMemory(chk);
   bool checkOk = OrderCheck(req, chk);
   LogOrderCheck(req, chk, checkOk, rs, bg);
   if(!checkOk)
     {
      LogError("OrderCheck", GetLastError(), "ORDERCHECK_FAIL retcode="+IntegerToString((int)chk.retcode)+" "+chk.comment);
      g_pending_intent_active = false; g_pending_close_lock=false; g_trade_lock=false;
      SetState(ST_IDLE, "ordercheck failed, state remains safe");
      return false;
     }

   SetState(ST_ORDERSEND, "sending "+EnumToString(intent.intent_type));
   int retries=0;
   bool sendOk=false;
   bool sentNaked=false;
   double origSl = req.sl, origTp = req.tp;
   MqlTradeResult res; ZeroMemory(res);
   uint startTick = GetTickCount();
   while(retries <= InpMaxOrderRetries)
     {
      MqlTick t; SymbolInfoTick(_Symbol, t);
      req.price = (req.type==ORDER_TYPE_BUY || req.type==ORDER_TYPE_BUY_STOP) ? t.ask : t.bid;

      ResetLastError();
      sendOk = OrderSend(req, res);
      int lastErr = GetLastError();
      int latency = (int)(GetTickCount()-startTick);

      if(sendOk && (res.retcode==TRADE_RETCODE_DONE || res.retcode==TRADE_RETCODE_DONE_PARTIAL || res.retcode==TRADE_RETCODE_PLACED))
        {
         LogExecution(req, res, sendOk, lastErr, latency, retries, "SUCCESS");
         if(res.retcode==TRADE_RETCODE_DONE_PARTIAL && res.volume < req.volume)
           {
            LogError("PartialFill", 0, "requested="+DoubleToString(req.volume,2)+" filled="+DoubleToString(res.volume,2));
           }
         break;
        }

      // classify retcode
      bool retryable = (res.retcode==TRADE_RETCODE_REQUOTE || res.retcode==TRADE_RETCODE_PRICE_CHANGED ||
                         res.retcode==TRADE_RETCODE_PRICE_OFF || res.retcode==TRADE_RETCODE_TIMEOUT ||
                         res.retcode==TRADE_RETCODE_CONNECTION);
      LogExecution(req, res, sendOk, lastErr, latency, retries, retryable?"RETRY":"FAIL");
      if(res.retcode==TRADE_RETCODE_TIMEOUT || res.retcode==TRADE_RETCODE_CONNECTION)
         SetState(ST_ORDER_PENDING, "uncertain execution state, will resync from broker");

      if(res.retcode==TRADE_RETCODE_INVALID_VOLUME)
        {
         req.volume = NormalizeVolume(req.volume);
        }
      else if(res.retcode==TRADE_RETCODE_INVALID_STOPS)
        {
         req.sl = 0; req.tp = 0; sentNaked = true; // send naked, modify immediately after fill
        }
      else if(res.retcode==TRADE_RETCODE_NO_MONEY)
        {
         RegisterExecFailure();
         break; // caller should reduce size / force reduce
        }
      else if(res.retcode==TRADE_RETCODE_MARKET_CLOSED || res.retcode==TRADE_RETCODE_TRADE_DISABLED)
        {
         RegisterExecFailure();
         break;
        }
      else if(!retryable)
        {
         RegisterExecFailure();
         break;
        }

      retries++;
      if(retries<=InpMaxOrderRetries) Sleep(InpRetryBackoffMs);
     }

   g_pending_intent_active = false;
   g_pending_close_lock = false;
   g_trade_lock = false;

   if(!sendOk || (res.retcode!=TRADE_RETCODE_DONE && res.retcode!=TRADE_RETCODE_DONE_PARTIAL && res.retcode!=TRADE_RETCODE_PLACED))
     {
      RegisterExecFailure();
      SetState(ST_EXECUTION_FAILED, "OrderSend failed retcode="+IntegerToString((int)res.retcode));
      return false;
     }

   if(intent.intent_type==INTENT_GRID || intent.intent_type==INTENT_HEDGE)
     {
      g_recovery.depth++;
      g_recovery.last_recovery_time = TimeCurrent();
      g_recovery.last_recovery_price = req.price;
      if(intent.intent_type==INTENT_HEDGE) g_recovery.hedge_lots += res.volume;
      LogRecovery(intent.intent_type==INTENT_GRID?"GRID_OPENED":"HEDGE_OPENED", g_recovery, req.volume);
     }

   LogTransaction(EnumToString(intent.intent_type), res.order, res.volume, res.price, 0);

   // Stops were stripped to get past an INVALID_STOPS rejection; re-attach them now
   // that the position exists, instead of leaving it permanently unprotected.
   if(sentNaked && (origSl>0 || origTp>0) && res.order>0)
      AttemptSltpFollowup(res.order, origSl, origTp);

   return true;
  }

//====================================================================
// SECTION 15: GRID / HEDGE / RECOVERY FSM
//====================================================================
bool RecoveryThrottleOk()
  {
   if(g_recovery.last_recovery_time==0) return true;
   if(TimeCurrent()-g_recovery.last_recovery_time < InpMinSecondsBetweenActions) return false;
   double distPts = MathAbs(g_snap.mid - g_recovery.last_recovery_price)/g_snap.point;
   double minDist = InpGridStepATRMultiplier*g_regime.atr/g_snap.point;
   if(distPts < minDist) return false;
   return true;
  }

bool RecoveryActionThrottleOk()
  {
   if(g_last_action_time==0) return true;
   return (TimeCurrent()-g_last_action_time >= InpMinSecondsBetweenActions);
  }

void RunRecoveryFSM()
  {
   if(!g_basket.has_positions) { g_recovery.mode = RECOVERY_NONE; return; }
   if(!g_risk.allow_recovery)
     {
      g_recovery.mode = (g_risk.risk_state==RISK_HARD_STOP || g_risk.risk_state==RISK_FORCE_REDUCE) ? RECOVERY_HARD_STOP : RECOVERY_REDUCE_ONLY;
      if(RecoveryActionThrottleOk())
        {
         SetState(g_recovery.mode==RECOVERY_HARD_STOP ? ST_FORCE_REDUCE : ST_NO_EXPANSION, g_risk.block_reason);
         LogRecovery(g_recovery.mode==RECOVERY_HARD_STOP?"HARD_STOP_REDUCE":"RISK_BLOCKED_REDUCE_ONLY", g_recovery, 0);
         if(g_recovery.mode==RECOVERY_HARD_STOP) ExecuteUnwindOrFlatten("recovery_hard_stop");
         else ExecutePartialReduce("recovery_reduce_only: "+g_risk.block_reason);
         g_last_action_time = TimeCurrent();
        }
      return;
     }
   if(g_regime.regime==REGIME_CHAOS || g_regime.regime==REGIME_NEWS_LOCK)
     {
      g_recovery.mode = RECOVERY_REDUCE_ONLY;
      if(RecoveryActionThrottleOk() && g_basket.floating_pl<0)
        {
         SetState(ST_NO_EXPANSION, "chaos/news regime - reduce only");
         LogRecovery("CHAOS_REDUCE_ONLY", g_recovery, 0);
         ExecutePartialReduce("chaos_news_reduce_only");
         g_last_action_time = TimeCurrent();
        }
      return;
     }

   bool basketLosing = g_basket.floating_pl < 0;
   if(!basketLosing) { g_recovery.mode = RECOVERY_NONE; return; }

   if(g_regime.allow_grid && g_recovery.depth < InpMaxRecoveryDepth)
      g_recovery.mode = RECOVERY_GRID;
   else if(g_regime.allow_hedge && g_recovery.depth < InpMaxRecoveryDepth)
      g_recovery.mode = RECOVERY_HEDGE;
   else
      g_recovery.mode = RECOVERY_REDUCE_ONLY;

   if(g_recovery.mode==RECOVERY_REDUCE_ONLY)
     {
      if(RecoveryActionThrottleOk())
        {
         SetState(ST_NO_EXPANSION, "recovery cap reached - reduce only");
         LogRecovery("CAP_REACHED_REDUCE_ONLY", g_recovery, 0);
         ExecutePartialReduce("recovery_cap_reduce_only");
         g_last_action_time = TimeCurrent();
        }
      return;
     }

   if(g_recovery.mode==RECOVERY_GRID || g_recovery.mode==RECOVERY_HEDGE)
     {
      if(!RecoveryThrottleOk()) return;

      double baseVol = InpBaseLot * MathPow(InpRecoveryLotMultiplier, g_recovery.depth);
      baseVol = MathMin(baseVol, InpMaxRecoveryLots);
      double roomLeft = InpMaxExposureLots - g_exposure.gross_lots;
      if(roomLeft < g_snap.volume_min - 1e-8) { g_recovery.mode = RECOVERY_REDUCE_ONLY; return; }
      baseVol = MathMin(baseVol, roomLeft);
      baseVol = NormalizeVolume(baseVol);
      // NormalizeVolume() rounds to the nearest step and can round baseVol
      // back above roomLeft when roomLeft sits between steps; never breach the cap.
      if(baseVol < g_snap.volume_min - 1e-8 || baseVol > roomLeft + 1e-8) { g_recovery.mode = RECOVERY_REDUCE_ONLY; return; }

      TradeIntent ti; ZeroMemory(ti);
      ti.magic = InpMagicNumber;
      ti.deviation = InpMaxSlippagePoints;
      ti.volume = baseVol;

      if(g_recovery.mode==RECOVERY_GRID)
        {
         // same direction as the dominant basket side (net exposure sign)
         ENUM_ORDER_TYPE dir = (g_exposure.net_lots>=0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
         ti.direction = dir;
         ti.intent_type = INTENT_GRID;
         ti.comment = "EA|GRID|"+IntegerToString(g_recovery.depth+1)+"|"+IntegerToString(g_basket_id_counter);
         ti.reason = "grid recovery expansion in range regime";
        }
      else
        {
         // hedge: open opposite direction to reduce net exposure
         ENUM_ORDER_TYPE dir = (g_exposure.net_lots>=0) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
         ti.direction = dir;
         ti.intent_type = INTENT_HEDGE;
         ti.comment = "EA|HEDGE|"+IntegerToString(g_basket_id_counter);
         ti.reason = "hedge recovery against adverse trend";
        }
      ti.valid = true;
      g_intent = ti;
      SetState(ST_RECOVERY_ACTIVE, ti.reason);
      ExecuteIntent(ti, g_risk.risk_state);
     }
  }

//====================================================================
// SECTION 16: UNWIND ENGINE
//====================================================================
bool CheckUnwindProof(double &winningProfit, double &losingFloat, double &buffers)
  {
   winningProfit=0; losingFloat=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
      double pl = PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(pl>=0) winningProfit += pl; else losingFloat += (-pl);
     }
   double slippageBuf = InpSlippageBufferMoney;
   double commBuf = InpCommissionBufferMoney;
   double swapBuf = InpSwapBufferMoney;
   buffers = slippageBuf+commBuf+swapBuf+InpMinUnwindProfitMoney;
   bool proven = (winningProfit >= losingFloat + buffers);
   double netAfter = winningProfit - losingFloat - (slippageBuf+commBuf+swapBuf);
   LogUnwind(proven, winningProfit, losingFloat, buffers, netAfter);
   return proven;
  }

void ExecuteUnwindOrFlatten(string reason)
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;

      TradeIntent ti; ZeroMemory(ti);
      ti.intent_type = INTENT_FLATTEN;
      ti.magic = InpMagicNumber;
      ti.deviation = InpMaxSlippagePoints;
      ti.target_ticket = ticket;
      ti.volume = PositionGetDouble(POSITION_VOLUME);
      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      ti.direction = (ptype==POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      ti.comment = "EA|CLOSE|"+reason;
      ti.reason = reason;
      ti.valid = true;
      g_intent = ti;
      ExecuteIntent(ti, g_risk.risk_state);
     }
  }

void ExecutePartialReduce(string reason)
  {
   // Close oldest position first, one per cycle, to progressively de-risk.
   ulong oldestTicket=0; datetime oldestTime=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
      datetime ot = (datetime)PositionGetInteger(POSITION_TIME);
      if(oldestTicket==0 || ot<oldestTime) { oldestTicket=ticket; oldestTime=ot; }
     }
   if(oldestTicket==0) return;
   if(!PositionSelectByTicket(oldestTicket)) return;

   TradeIntent ti; ZeroMemory(ti);
   ti.intent_type = INTENT_PARTIAL_CLOSE;
   ti.magic = InpMagicNumber;
   ti.deviation = InpMaxSlippagePoints;
   ti.target_ticket = oldestTicket;
   ti.volume = PositionGetDouble(POSITION_VOLUME);
   ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   ti.direction = (ptype==POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   ti.comment = "EA|REDUCE|"+reason;
   ti.reason = reason;
   ti.valid = true;
   g_intent = ti;
   ExecuteIntent(ti, g_risk.risk_state);
  }

//====================================================================
// SECTION 26: WEEKEND GAP ESCALATION (§26)
//====================================================================
void CheckWeekendGapEscalation()
  {
   ENUM_SESSION_MODE sm = ComputeSessionMode();
   if(sm==SESSION_FLAT_ONLY && g_basket.has_positions)
     {
      if(g_flatten_entered_time==0) g_flatten_entered_time = TimeCurrent();
      int elapsedMin = (int)((TimeCurrent()-g_flatten_entered_time)/60);
      if(elapsedMin >= InpWeekendFlattenEscalationMin && !g_weekend_escalated)
        {
         g_weekend_escalated = true;
         SendAlert("WEEKEND_FLATTEN_FAILURE", "positions still open "+IntegerToString(elapsedMin)+"min after flatten trigger");
         ExecuteUnwindOrFlatten("weekend_escalated_flatten");
        }
      MqlDateTime dt; TimeToStruct(TimeCurrent(), dt); // TimeCurrent() is already broker server time
      if(dt.day_of_week==5 && dt.hour>=23 && !g_weekend_gap_logged)
        {
         g_weekend_gap_logged = true;
         LogError("WeekendGap", 0, "WEEKEND_GAP_RISK_CARRIED positions="+IntegerToString(g_exposure.position_count)+" gross_lots="+DoubleToString(g_exposure.gross_lots,2));
        }
     }
   else
     {
      g_flatten_entered_time = 0;
      g_weekend_escalated = false;
      g_weekend_gap_logged = false;
     }
  }

//====================================================================
// SECTION 17b: PERSISTENCE (state file, restart-safe)
//====================================================================
void SaveState()
  {
   RuntimeStateRecord rec;
   rec.fsm_state = (int)g_state;
   rec.recovery_mode = (int)g_recovery.mode;
   rec.recovery_depth = g_recovery.depth;
   rec.basket_id = g_basket_id_counter;
   rec.daily_realized_pl = g_daily_realized_pl;
   rec.daily_pl_day = g_daily_pl_day;
   rec.last_recovery_time = g_recovery.last_recovery_time;
   rec.last_recovery_price = g_recovery.last_recovery_price;
   rec.halted = g_halt;
   rec.kill_switch_latched = g_kill_switch_latched;
   rec.last_gmt_offset = g_btime.gmt_offset_hours;

   int h = FileOpen(g_state_file_name, FILE_WRITE|FILE_BIN|FILE_COMMON);
   if(h==INVALID_HANDLE) { LogError("SaveState", GetLastError(), "cannot open state file for write"); return; }
   FileWriteStruct(h, rec);
   FileClose(h);
  }

bool LoadState()
  {
   if(!FileIsExist(g_state_file_name, FILE_COMMON)) return false;
   int h = FileOpen(g_state_file_name, FILE_READ|FILE_BIN|FILE_COMMON);
   if(h==INVALID_HANDLE) return false;
   RuntimeStateRecord rec;
   if(FileReadStruct(h, rec) <= 0) { FileClose(h); return false; }
   FileClose(h);

   g_recovery.mode = (ENUM_RECOVERY_MODE)rec.recovery_mode;
   g_recovery.depth = rec.recovery_depth;
   g_basket_id_counter = rec.basket_id;
   g_daily_realized_pl = rec.daily_realized_pl;
   g_daily_pl_day = rec.daily_pl_day;
   g_recovery.last_recovery_time = rec.last_recovery_time;
   g_recovery.last_recovery_price = rec.last_recovery_price;
   g_halt = rec.halted;
   g_kill_switch_latched = rec.kill_switch_latched;
   g_btime.gmt_offset_hours = rec.last_gmt_offset;
   return true;
  }

// Rebuild recovery depth from broker positions when state file missing/corrupted.
void RebuildStateFromBroker()
  {
   int depth=0; int hedgeCount=0; double hedgeLots=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
      string cmt = PositionGetString(POSITION_COMMENT);
      if(StringFind(cmt,"GRID")>=0 || StringFind(cmt,"HEDGE")>=0) depth++;
      if(StringFind(cmt,"HEDGE")>=0) { hedgeCount++; hedgeLots += PositionGetDouble(POSITION_VOLUME); }
     }
   g_recovery.depth = depth;
   g_recovery.hedge_lots = hedgeLots;
   if(depth>0) g_recovery.mode = (hedgeCount>0) ? RECOVERY_HEDGE : RECOVERY_GRID;
   if(g_basket_id_counter==0) g_basket_id_counter = (long)TimeCurrent();
  }

//====================================================================
// SECTION 19b: DASHBOARD
//====================================================================
void DashboardLabel(string name, string text, int y, color clr)
  {
   string objName = InpEAPrefix+"_DB_"+name;
   if(ObjectFind(0, objName)<0)
     {
      ObjectCreate(0, objName, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, objName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, 10);
      ObjectSetInteger(0, objName, OBJPROP_FONTSIZE, 9);
      ObjectSetString(0, objName, OBJPROP_FONT, "Consolas");
     }
   ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, objName, OBJPROP_TEXT, text);
   ObjectSetInteger(0, objName, OBJPROP_COLOR, clr);
  }

void UpdateDashboard()
  {
   int y=15;
   DashboardLabel("title", InpEAPrefix+" | "+_Symbol, y, clrWhite); y+=16;
   DashboardLabel("state", "FSM: "+StateName(g_state), y, clrAqua); y+=16;
   DashboardLabel("regime", "Regime: "+EnumToString(g_regime.regime), y, clrYellow); y+=16;
   DashboardLabel("risk", "Risk: "+EnumToString(g_risk.risk_state)+" "+g_risk.block_reason, y, (g_risk.risk_state==RISK_NORMAL?clrLime:clrOrangeRed)); y+=16;
   DashboardLabel("basket", StringFormat("Basket PL: %.2f  Lots: %.2f  Depth: %d", g_basket.floating_pl, g_exposure.gross_lots, g_recovery.depth), y, clrWhite); y+=16;
   DashboardLabel("recovery", "Recovery: "+EnumToString(g_recovery.mode), y, clrSilver); y+=16;
   DashboardLabel("session", "Session: "+EnumToString(ComputeSessionMode()), y, clrSilver); y+=16;
   DashboardLabel("kill", g_kill_switch_latched?"KILL SWITCH ACTIVE":"kill: off", y, g_kill_switch_latched?clrRed:clrGray); y+=16;
   DashboardLabel("daily", StringFormat("Daily PL: %.2f  DD: %.2f%%", g_daily_realized_pl, AccountInfoDouble(ACCOUNT_BALANCE)>0?(AccountInfoDouble(ACCOUNT_BALANCE)-AccountInfoDouble(ACCOUNT_EQUITY))/AccountInfoDouble(ACCOUNT_BALANCE)*100.0:0), y, clrWhite);
  }

void RemoveDashboard()
  {
   ObjectsDeleteAll(0, InpEAPrefix+"_DB_");
  }

//====================================================================
// SECTION 22b (§25): FSM STATE TRANSITION CHOKE POINT (INV-6)
//====================================================================
void SetState(ENUM_FSM_STATE newState, string reason)
  {
   if(newState==g_state)
     {
      // still log a heartbeat row is not required for identical repeats; only log on actual change
      return;
     }
   g_prev_state = g_state;
   LogState(g_prev_state, newState, reason);
   g_state = newState;
  }

//====================================================================
// SECTION 23: INPUT CROSS-VALIDATION MATRIX (§23)
//====================================================================
bool ValidateInputsCrossCheck()
  {
   bool allOk = true;
   string failures = "";

   double maxLotAtDepth = InpBaseLot * MathPow(InpRecoveryLotMultiplier, InpMaxRecoveryDepth);
   if(maxLotAtDepth > InpMaxExposureLots) { allOk=false; failures += "ExponentialLotOverflow;"; }

   double minFreeMarginNeeded = 100.0 - InpMaxMarginUsagePct;
   if(!(InpMinFreeMarginPct < minFreeMarginNeeded)) { allOk=false; failures += "MarginGateConsistency;"; }

   if(!(InpMaxDailyLossPct <= InpMaxTotalDrawdownPct)) { allOk=false; failures += "DailyLossVsTotalDDOrdering;"; }

   if(!(InpHardEquityStopPct <= InpMaxTotalDrawdownPct)) { allOk=false; failures += "HardStopVsTotalDDOrdering;"; }

   double neededRecoveryLot = InpBaseLot*InpRecoveryLotMultiplier;
   if(!(InpMaxRecoveryLots >= neededRecoveryLot)) { allOk=false; failures += "RecoveryLotVsMaxRecoveryLot;"; }

   // Grid step vs broker constraint: cannot be statically verified without a live
   // ATR reading yet, so this uses a conservative floor at OnInit; CheckGridStepVsBrokerConstraint()
   // re-runs the real check against live ATR once per bar from OnTick.
   if(g_snap.valid)
     {
      double minExpectedATR = g_snap.point*10.0; // conservative floor, refined at runtime
      double gridStepPoints = InpGridStepATRMultiplier*minExpectedATR/g_snap.point;
      double constraintPoints = g_snap.stops_level_points+g_snap.freeze_level_points;
      if(gridStepPoints <= constraintPoints)
        {
         LogError("InputCrossValidation", 0, "GridStepVsBrokerConstraint runtime warning");
        }
     }

   if(!allOk)
     {
      LogError("InputCrossValidation", 0, "INIT_FAILED checks: "+failures);
      if(InpStrictPropRiskMode) return false;
      if(InpAuditRequired) return false; // "log and continue only if InpAuditRequired == false"
     }
   return true;
  }

//====================================================================
// SECTION 20b: OnInit
//====================================================================
int OnInit()
  {
   g_prefix = InpEAPrefix;
   g_state_file_name = g_prefix+"_state_"+_Symbol+"_"+IntegerToString(InpMagicNumber)+".dat";
   g_shared_ledger_file = g_prefix+"_SharedLedger_"+IntegerToString((int)AccountInfoInteger(ACCOUNT_LOGIN))+".csv";

   SetState(ST_INIT, "OnInit start");

   if(!InitIndicators())
     {
      LogError("OnInit", GetLastError(), "indicator init failed");
      return INIT_FAILED;
     }

   if(!BuildMarketSnapshot(g_snap))
     {
      LogError("OnInit", GetLastError(), "initial market snapshot failed");
      return INIT_FAILED;
     }

   RecomputeBrokerTimeOffset();

   // §19 currency: strict USD-only explicit validation at OnInit
   g_ccy.account_currency = AccountInfoString(ACCOUNT_CURRENCY);
   g_ccy.symbol_profit_currency = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
   if(InpAssumeUSDOnlyAccount)
     {
      if(g_ccy.account_currency!="USD" || g_ccy.symbol_profit_currency!="USD")
        {
         LogError("OnInit", 0, "InpAssumeUSDOnlyAccount is true but account/symbol currency is not USD");
         return INIT_FAILED;
        }
      g_ccy.conversion_rate = 1.0; g_ccy.conversion_valid = true;
     }
   else
     {
      RefreshCurrencyContext();
     }

   if(!ValidateInputsCrossCheck())
     {
      return INIT_FAILED;
     }

   SetState(ST_LOAD_STATE, "loading persisted state");
   if(!LoadState())
     {
      LogError("OnInit", 0, "state file missing/corrupted, rebuilding from broker");
      RebuildStateFromBroker();
     }

   SetState(ST_SYNC_BROKER, "syncing broker state");
   SyncExposureLedger();
   SyncDailyRealizedPL();
   if(g_basket_id_counter==0) g_basket_id_counter = (long)TimeCurrent();

   g_kill_switch_latched = CheckKillSwitch();

   EventSetTimer(InpTimerSeconds);

   SetState(ST_IDLE, "init complete");
   Print(InpEAPrefix, " initialized on ", _Symbol, " magic=", InpMagicNumber);
   return INIT_SUCCEEDED;
  }

//====================================================================
// SECTION 21b: OnDeinit
//====================================================================
void OnDeinit(const int reason)
  {
   SaveState();
   LogRuntimeStateCsv();
   ReleaseIndicators();
   RemoveDashboard();
   EventKillTimer();
   LogError("OnDeinit", reason, "EA deinitialized");
  }

//====================================================================
// SECTION 24b: OnTimer  (§18 offset recompute, §26 escalation, ledger)
//====================================================================
void OnTimer()
  {
   RecomputeBrokerTimeOffset();
   g_kill_switch_latched = CheckKillSwitch();
   if(InpParticipateSharedLedger) WriteSharedLedgerRow();
   CheckWeekendGapEscalation();
   SaveState();
  }

//====================================================================
// SECTION 23b: OnTradeTransaction
//====================================================================
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type==TRADE_TRANSACTION_DEAL_ADD)
     {
      if(HistoryDealSelect(trans.deal))
        {
         string sym = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
         long magic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
         if(sym==_Symbol && magic==InpMagicNumber)
           {
            double vol = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
            double price = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
            double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
            LogTransaction("DEAL_ADD", trans.deal, vol, price, profit);
           }
        }
      SetState(ST_POSITION_SYNC, "trade transaction deal add");
      SyncExposureLedger();
      SyncDailyRealizedPL();
     }
   else if(trans.type==TRADE_TRANSACTION_POSITION)
     {
      SyncExposureLedger();
     }
  }

//====================================================================
// SECTION 22c: MAIN CONTROL LOOP (spec §12)
//====================================================================
void OnTick()
  {
   // §21 kill switch: checked before market snapshot build
   if(CheckKillSwitch())
     {
      g_kill_switch_latched = true;
      SetState(ST_FLATTEN, "manual kill switch");
      ExecuteUnwindOrFlatten("manual_kill_switch");
      g_halt = true;
      LogError("ManualKillSwitch", 0, "OPERATOR_FORCED_HALT");
      SaveState();
      return;
     }

   if(g_halt)
     {
      SetState(ST_HALT, "halted");
      return;
     }

   // 1. Build MarketSnapshot
   g_prev_snap = g_snap;
   if(!BuildMarketSnapshot(g_snap))
     {
      SetState(ST_IDLE, "no fresh tick");
      return;
     }
   CheckSymbolSpecDrift();
   if(g_snapshot_dirty_after_drift)
     {
      // §24: force one extra clean BuildMarketSnapshot() cycle before any BrokerGate call
      g_snapshot_dirty_after_drift = false;
      SetState(ST_SYNC_BROKER, "symbol spec drift - forcing rebuilt snapshot before next gate");
      return;
     }

   // 2. Sync account, positions, exposure
   SetState(ST_SYNC_BROKER, "tick sync");
   SyncExposureLedger();
   SyncDailyRealizedPL();
   LogBasket(g_basket, g_exposure);

   // 3. Update indicators and regime
   if(!UpdateRegimeSnapshot(g_regime))
     {
      SetState(ST_IDLE, "regime update failed, blocking entries this tick");
      return;
     }
   LogRegime(g_regime);
   CheckGridStepVsBrokerConstraint();

   // §19 currency refresh (periodic, cheap to call - internally rate-limited by tick check via last_refresh)
   if(!InpAssumeUSDOnlyAccount && (TimeCurrent()-g_ccy.last_refresh > 60 || !g_ccy.conversion_valid))
      RefreshCurrencyContext();

   // 4. Update session mode
   ENUM_SESSION_MODE sessionMode = ComputeSessionMode();

   // 5. Recalculate risk state
   SetState(ST_RISK_CHECK, "risk recompute");
   g_risk = ComputeRiskState();
   LogRisk(g_risk);

   if(g_risk.risk_state==RISK_HARD_STOP)
     {
      SetState(ST_FLATTEN, g_risk.block_reason);
      ExecuteUnwindOrFlatten("hard_stop");
      g_halt = true;
      SendAlert("RISK_HARD_STOP", g_risk.block_reason);
      SaveState();
      return;
     }

   if(sessionMode==SESSION_FLAT_ONLY && g_basket.has_positions)
     {
      SetState(ST_FLATTEN, "forced flat session window");
      ExecuteUnwindOrFlatten("session_flat_only");
      CheckWeekendGapEscalation();
      return;
     }

   // 6. Manage existing basket or scan new entry
   if(g_basket.has_positions)
     {
      SetState(ST_IN_POSITION, "basket active");

      // §16 unwind proof check first — do not close hedge/recovery blindly
      SetState(ST_UNWIND_CHECK, "testing unwind offset proof");
      double winP, loseP, buf;
      bool proven = CheckUnwindProof(winP, loseP, buf);
      if(proven && g_risk.allow_partial_close && g_basket.floating_pl > -InpMaxBasketLossMoney)
        {
         g_recovery.mode = RECOVERY_UNWIND;
         SetState(ST_UNWIND, "unwind proof satisfied");
         ExecuteUnwindOrFlatten("unwind_proof_satisfied");
        }
      else if(g_risk.risk_state==RISK_FORCE_REDUCE)
        {
         SetState(ST_FORCE_REDUCE, g_risk.block_reason);
         ExecutePartialReduce(g_risk.block_reason);
        }
      else
        {
         // Exit scan for primary basket (regime/signal-based exit)
         if(!ComputeSignal(g_signal)) LogError("SignalEngine", GetLastError(), "signal compute failed");
         LogSignal(g_signal, g_regime);

         bool haveBuy = g_exposure.buy_lots>0;
         bool haveSell = g_exposure.sell_lots>0;
         if((haveBuy && g_signal.direction==SIGNAL_EXIT_BUY) || (haveSell && g_signal.direction==SIGNAL_EXIT_SELL))
           {
            SetState(ST_EXIT_SCAN, "exit signal");
            ExecuteUnwindOrFlatten("signal_exit");
           }
         else if(g_recovery.depth < InpMaxRecoveryDepth && sessionMode!=SESSION_REDUCE_ONLY && sessionMode!=SESSION_CLOSED)
           {
            SetState(ST_RECOVERY_CHECK, "evaluating recovery");
            if(g_risk.allow_recovery)
               RunRecoveryFSM();
            else
               SetState(ST_NO_EXPANSION, g_risk.block_reason);
           }
         else
           {
            SetState(ST_NO_EXPANSION, "recovery cap or session restriction");
           }
        }
     }
   else
     {
      // No basket: scan for a new primary entry
      if(sessionMode!=SESSION_ENTRY_ALLOWED)
        {
         SetState(ST_IDLE, "entry not permitted this session: "+EnumToString(sessionMode));
        }
      else if(!g_risk.allow_entry)
        {
         SetState(ST_IDLE, g_risk.block_reason);
        }
      else
        {
         SetState(ST_ENTRY_SCAN, "scanning for entry");
         if(!ComputeSignal(g_signal)) LogError("SignalEngine", GetLastError(), "signal compute failed");
         LogSignal(g_signal, g_regime);
         g_signal.signal_age_seconds = (int)(TimeCurrent()-g_signal.signal_time);

         if(g_signal.allow_entry && g_signal.signal_age_seconds<=InpMaxSignalAgeSeconds &&
            g_snap.spread_points<=InpMaxSpreadPoints)
           {
            SetState(ST_SIGNAL_READY, g_signal.reason);
            SetState(ST_BROKER_GATE, "building entry intent");

            TradeIntent ti; ZeroMemory(ti);
            ti.intent_type = INTENT_ENTRY;
            ti.magic = InpMagicNumber;
            ti.deviation = InpMaxSlippagePoints;
            ti.direction = (g_signal.direction==SIGNAL_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
            ti.volume = MathMin(g_risk.max_new_lot, InpBaseLot);
            ti.sl = g_signal.invalidation_price;
            ti.tp = g_signal.target_price;
            ti.comment = "EA|ENTRY|"+IntegerToString(g_basket_id_counter);
            ti.reason = g_signal.reason;
            ti.valid = true;
            g_intent = ti;

            g_basket_id_counter++;
            SetState(ST_ORDERSEND, "sending entry order");
            if(ExecuteIntent(ti, g_risk.risk_state))
               SetState(ST_POSITION_SYNC, "entry executed");
            else
               SetState(ST_IDLE, "entry execution failed or blocked");
           }
         else
           {
            SetState(ST_IDLE, "no qualifying signal");
           }
        }
     }

   UpdateDashboard();
   LogRuntimeStateCsv();
  }
