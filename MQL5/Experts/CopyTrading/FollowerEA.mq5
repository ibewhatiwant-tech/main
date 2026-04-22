//+------------------------------------------------------------------+
//| CopyTrading/FollowerEA.mq5                                       |
//| Follower Expert Advisor — Signal Subscriber                      |
//| Receives trade signals from master and replicates them           |
//| with configurable risk management and allocation rules.          |
//+------------------------------------------------------------------+
#property copyright   "Copy Trading System v1.0"
#property link        "https://github.com/ibewhatiwant-tech/main"
#property version     "1.00"
#property description "Follower EA: Copies trades from master account"
#property strict

//--- Include all required components
#include <CopyTrading/Defines.mqh>
#include <CopyTrading/Logger.mqh>
#include <CopyTrading/Signal.mqh>
#include <CopyTrading/MT5Wrapper.mqh>
#include <CopyTrading/AllocationEngine.mqh>
#include <CopyTrading/RiskManager.mqh>
#include <CopyTrading/SignalReceiver.mqh>
#include <CopyTrading/TradeReplicator.mqh>
#include <CopyTrading/PerformanceTracker.mqh>
#include <CopyTrading/Dashboard.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+

//--- Master Connection
input string          InpMasterSignalID     = "";          // Master Signal ID (account number)
input string          InpMasterName         = "Master";    // Display name for master

//--- Allocation Method
input ENUM_ALLOCATION_METHOD InpAllocMethod = ALLOC_LOT_MULTIPLIER; // Allocation method
input double          InpFixedLotSize       = 0.01;        // Fixed lot size (ALLOC_FIXED_LOT)
input double          InpLotMultiplier      = 0.10;        // Lot multiplier (ALLOC_LOT_MULTIPLIER)
input double          InpRiskPercent        = 1.0;         // Risk % per trade (ALLOC_RISK_PERCENT)
input double          InpEquityPercent      = 10.0;        // Equity % allocation (ALLOC_EQUITY_PERCENT)
input double          InpMaxLotSize         = 10.0;        // Maximum lot size per trade

//--- Risk Management
input double          InpMaxDrawdownPct     = 20.0;        // Maximum drawdown % (halt copying)
input double          InpDailyLossLimit     = 0.0;         // Daily loss limit in currency (0=disabled)
input double          InpDailyLossPct       = 0.0;         // Daily loss limit % (0=disabled)
input int             InpMaxOpenPositions   = 20;          // Maximum open positions
input double          InpMinMarginLevel     = 200.0;       // Minimum margin level %
input bool            InpCloseOnDrawdown    = false;       // Close positions when drawdown limit hit
input bool            InpRequireStopLoss    = true;        // Require stop loss on all trades
input int             InpEmergencySLPips    = 100;         // Emergency stop loss (pips, if no SL)

//--- Trade Filtering
input bool            InpFilterSymbols      = false;       // Enable symbol filter
input string          InpAllowedSymbols     = "";          // Allowed symbols (comma-separated, blank=all)
input ENUM_DIRECTION_FILTER InpDirFilter    = DIR_BOTH;   // Direction filter
input string          InpSymbolMap          = "";          // Symbol name map: "MasterSym=FollowerSym,..." (e.g. XAUUSDm=XAUUSD)

//--- Time Filtering
input bool            InpEnableTimeFilter   = false;       // Enable trading hours filter
input string          InpTradingStart       = "09:00";     // Trading start time (HH:MM, server time)
input string          InpTradingEnd         = "17:00";     // Trading end time (HH:MM, server time)
input bool            InpCloseOutsideHours  = false;       // Close positions outside trading hours

//--- Synchronization
input bool            InpAutoReconcile      = true;        // Enable automatic position reconciliation
input bool            InpCopyingEnabled     = true;        // Enable copying (master switch)

//--- Display
input bool            InpShowDashboard      = true;        // Show on-chart dashboard
input int             InpDashboardCorner    = 1;           // Dashboard corner (0=TL,1=TR,2=BL,3=BR)
input int             InpDashboardFontSize  = 9;           // Dashboard font size

//--- Logging and Alerts
input ENUM_LOG_LEVEL  InpLogLevel           = LOG_INFO;    // Log verbosity level
input bool            InpAlertOnCopied      = false;       // Alert on each successful copy
input bool            InpAlertOnFailed      = true;        // Alert on replication failure
input bool            InpAlertOnRiskLimits  = true;        // Alert on risk limit events

//+------------------------------------------------------------------+
//| Global EA Objects                                                  |
//+------------------------------------------------------------------+
CLogger             g_logger;
CMT5Wrapper         g_mt5;
CAllocationEngine   g_allocEngine;
CRiskManager        g_riskMgr;
CSignalReceiver     g_receiver;
CTradeReplicator    g_replicator;
CPerformanceTracker g_perfTracker;
CDashboard          g_dashboard;

string              g_followerId    = "";
bool                g_initialized   = false;
bool                g_copyingEnabled = true;
int                 g_timerCounter  = 0;

//--- Time filter state
int                 g_tradingStartMinutes = 0;  // Start time in minutes from midnight
int                 g_tradingEndMinutes   = 0;  // End time in minutes from midnight

//+------------------------------------------------------------------+
//| Expert Advisor Initialization                                     |
//+------------------------------------------------------------------+
int OnInit()
  {
   Print("==================================================");
   Print("CopyTrading FollowerEA v", CT_VERSION, " initializing...");
   Print("Account: ", AccountInfoString(ACCOUNT_NAME),
         " #", AccountInfoInteger(ACCOUNT_LOGIN));
   Print("==================================================");

   //--- Ensure shared directories exist (broker common folder)
   FolderCreate("CopyTrading",  FILE_COMMON);
   FolderCreate(CT_SIGNAL_DIR,  FILE_COMMON);
   FolderCreate(CT_STATE_DIR,   FILE_COMMON);
   FolderCreate(CT_LOG_DIR,     FILE_COMMON);

   //--- Validate required inputs
   if(InpMasterSignalID == "")
     {
      Print("ERROR: Master Signal ID is required. Please enter the master account number.");
      return INIT_FAILED;
     }

   //--- Build follower ID from account number
   g_followerId = IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));

   //--- Initialize logger
   if(!g_logger.Init("FollowerEA_" + g_followerId, InpLogLevel))
     {
      Print("ERROR: Failed to initialize logger");
      return INIT_FAILED;
     }
   g_logger.Info("Logger initialized for follower: " + g_followerId);
   g_logger.Info("Copying from master: " + InpMasterSignalID);

   //--- Initialize MT5 wrapper
   if(!g_mt5.Init(&g_logger, CT_MAGIC_NUMBER, CT_MAX_SLIPPAGE))
     {
      g_logger.Fatal("Failed to initialize MT5 wrapper");
      return INIT_FAILED;
     }

   //--- Initialize allocation engine
   double param2 = InpFixedLotSize; // fallback fixed lot for risk-based
   if(!g_allocEngine.Init(&g_logger, &g_mt5, InpAllocMethod,
                          GetAllocParam1(), param2, InpMaxLotSize))
     {
      g_logger.Fatal("Failed to initialize AllocationEngine");
      return INIT_FAILED;
     }
   g_logger.Info("Allocation method: " + EnumToString(InpAllocMethod));

   //--- Initialize risk manager
   if(!g_riskMgr.Init(&g_logger,
                       InpMaxDrawdownPct,
                       InpDailyLossLimit,
                       InpMaxOpenPositions,
                       InpMinMarginLevel,
                       InpRequireStopLoss,
                       InpEmergencySLPips,
                       InpCloseOnDrawdown))
     {
      g_logger.Fatal("Failed to initialize RiskManager");
      return INIT_FAILED;
     }
   if(InpDailyLossPct > 0)
      g_riskMgr.SetDailyLossPct(InpDailyLossPct);
   g_logger.Info("Risk manager initialized: MaxDD=" + DoubleToString(InpMaxDrawdownPct,1) + "%" +
                 " DailyLimit=" + DoubleToString(InpDailyLossLimit,2));

   //--- Initialize signal receiver
   if(!g_receiver.Init(&g_logger, InpMasterSignalID, g_followerId))
     {
      g_logger.Fatal("Failed to initialize SignalReceiver");
      return INIT_FAILED;
     }
   g_logger.Info("Signal receiver initialized, watching master: " + InpMasterSignalID);

   //--- Initialize performance tracker
   if(!g_perfTracker.Init(&g_logger, g_followerId, false))
     {
      g_logger.Warn("Failed to initialize PerformanceTracker (non-fatal)");
     }

   //--- Initialize trade replicator
   if(!g_replicator.Init(&g_logger, &g_mt5, &g_allocEngine, &g_riskMgr,
                          &g_perfTracker,
                          g_followerId, CT_MAGIC_NUMBER, CT_MAX_SLIPPAGE))
     {
      g_logger.Fatal("Failed to initialize TradeReplicator");
      return INIT_FAILED;
     }

   //--- Apply filters to replicator
   if(InpFilterSymbols && InpAllowedSymbols != "")
      g_replicator.SetSymbolFilter(InpAllowedSymbols);
   g_replicator.SetDirectionFilter(InpDirFilter);
   if(InpSymbolMap != "")
      g_replicator.SetSymbolMap(InpSymbolMap);

   //--- Parse time filter
   if(InpEnableTimeFilter)
     {
      g_tradingStartMinutes = ParseTimeToMinutes(InpTradingStart);
      g_tradingEndMinutes   = ParseTimeToMinutes(InpTradingEnd);
      g_logger.Info("Time filter active: " + InpTradingStart + " - " + InpTradingEnd);
     }

   //--- Initialize dashboard
   if(InpShowDashboard)
     {
      if(!g_dashboard.Init(false, InpDashboardCorner, InpDashboardFontSize))
        {
         g_logger.Warn("Failed to initialize dashboard (non-fatal)");
        }
      else
        {
         g_logger.Info("Dashboard initialized");
        }
     }

   //--- Set copying state
   g_copyingEnabled = InpCopyingEnabled;

   //--- Start 1-second timer
   if(!EventSetTimer(1))
     {
      g_logger.Warn("Failed to set timer");
     }

   g_initialized = true;
   g_logger.Info("FollowerEA fully initialized.");
   g_logger.Info("Equity: " + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) +
                 " Balance: " + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));

   if(InpShowDashboard)
      UpdateDashboard();

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert Advisor Deinitialization                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   g_logger.Info("FollowerEA deinitializing. Reason: " + IntegerToString(reason));

   EventKillTimer();

   if(InpShowDashboard)
      g_dashboard.Destroy();

   g_replicator.SavePositionMap();
   g_perfTracker.SaveToFile();

   g_initialized = false;
   g_logger.Info("FollowerEA shutdown complete");
   g_logger.Deinit();
  }

//+------------------------------------------------------------------+
//| OnTimer — Main signal polling and processing loop                 |
//+------------------------------------------------------------------+
void OnTimer()
  {
   if(!g_initialized)
      return;

   g_timerCounter++;

   //--- Poll for new signals from master (every tick = every 1 second)
   g_receiver.Poll();

   //--- Process queued signals
   if(g_copyingEnabled && g_riskMgr.IsCopyingAllowed())
     {
      ProcessPendingSignals();
     }
   else if(!g_riskMgr.IsCopyingAllowed() && g_timerCounter % 60 == 0)
     {
      g_logger.Debug("Copying halted: " + g_riskMgr.GetHaltReason());
     }

   //--- Risk monitoring (every tick)
   g_riskMgr.OnTick();

   //--- Performance tracking update (every 5 seconds)
   if(g_timerCounter % 5 == 0)
      g_perfTracker.OnTick();

   //--- Position reconciliation (every CT_RECONCILE_SECS)
   if(InpAutoReconcile && g_replicator.NeedReconcile())
      g_replicator.ReconcilePositions();

   //--- Dashboard update (every 3 seconds)
   if(InpShowDashboard && g_timerCounter % 3 == 0)
      UpdateDashboard();

   //--- Alert on connection loss (every 30 seconds when disconnected)
   if(g_timerCounter % 30 == 0)
     {
      if(!g_receiver.IsConnected())
        {
         g_logger.Warn("Master connection: " + g_receiver.GetStatusString());
         if(InpAlertOnFailed)
            Alert("CopyTrading: Lost connection to master " + InpMasterSignalID);
        }
     }
  }

//+------------------------------------------------------------------+
//| OnTick — Real-time risk monitoring                                |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!g_initialized)
      return;

   //--- Continuous risk monitoring on every price update
   g_riskMgr.OnTick();
   g_perfTracker.OnTick();
  }

//+------------------------------------------------------------------+
//| Process all pending signals from queue                            |
//+------------------------------------------------------------------+
void ProcessPendingSignals()
  {
   CSignal signal;
   int processed = 0;

   while(g_receiver.HasPendingSignals() && processed < 10)
     {
      if(!g_receiver.DequeueSignal(signal))
         break;

      processed++;

      //--- Skip stale market orders
      if(signal.IsStale())
        {
         g_logger.Info("Skipping stale signal: " + signal.signalId +
                       " (" + signal.symbol + " " + IntegerToString(signal.type) + ")");
         g_perfTracker.RecordTradeSkipped();
         continue;
        }

      //--- Apply time filter
      if(InpEnableTimeFilter && !IsWithinTradingHours())
        {
         if(signal.type == SIGNAL_MARKET_ORDER || signal.type == SIGNAL_PENDING_ORDER)
           {
            g_logger.Debug("Signal skipped: outside trading hours (" + signal.symbol + ")");
            g_perfTracker.RecordTradeSkipped();
            continue;
           }
        }

      //--- Process the signal
      g_logger.Debug("Processing signal: " + signal.signalId +
                     " sym=" + signal.symbol +
                     " type=" + IntegerToString(signal.type));

      g_replicator.ProcessSignal(signal);

      //--- Alert on successful copy
      if(InpAlertOnCopied && signal.type == SIGNAL_MARKET_ORDER)
        {
         Alert("CopyTrading: Copied " + signal.symbol + " " +
               EnumToString(signal.orderType) + " from master");
        }
     }
  }

//+------------------------------------------------------------------+
//| Update the dashboard display                                      |
//+------------------------------------------------------------------+
void UpdateDashboard()
  {
   if(!InpShowDashboard)
      return;

   int openPositions = 0;
   int magic = CT_MAGIC_NUMBER;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetInteger(POSITION_MAGIC) == magic)
         openPositions++;
     }

   double drawdownPct = g_riskMgr.GetCurrentDrawdown();
   double marginLevel = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   bool connected     = g_receiver.IsConnected();

   g_dashboard.UpdateFollower(
      InpMasterName,
      connected,
      g_copyingEnabled,
      !g_riskMgr.IsCopyingAllowed(),
      g_riskMgr.GetHaltReason(),
      openPositions,
      drawdownPct,
      InpMaxDrawdownPct,
      marginLevel,
      &g_perfTracker
   );
  }

//+------------------------------------------------------------------+
//| Check if current time is within trading hours                    |
//+------------------------------------------------------------------+
bool IsWithinTradingHours()
  {
   if(!InpEnableTimeFilter)
      return true;

   datetime serverTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(serverTime, dt);

   int currentMinutes = dt.hour * 60 + dt.min;
   return (currentMinutes >= g_tradingStartMinutes && currentMinutes < g_tradingEndMinutes);
  }

//+------------------------------------------------------------------+
//| Parse "HH:MM" time string to minutes from midnight               |
//+------------------------------------------------------------------+
int ParseTimeToMinutes(string timeStr)
  {
   int colonPos = StringFind(timeStr, ":");
   if(colonPos < 0)
      return 0;

   int hours   = (int)StringToInteger(StringSubstr(timeStr, 0, colonPos));
   int minutes = (int)StringToInteger(StringSubstr(timeStr, colonPos + 1));
   return hours * 60 + minutes;
  }

//+------------------------------------------------------------------+
//| Get allocation parameter 1 based on selected method              |
//+------------------------------------------------------------------+
double GetAllocParam1()
  {
   switch(InpAllocMethod)
     {
      case ALLOC_FIXED_LOT:      return InpFixedLotSize;
      case ALLOC_LOT_MULTIPLIER: return InpLotMultiplier;
      case ALLOC_RISK_PERCENT:   return InpRiskPercent;
      case ALLOC_EQUITY_PERCENT: return InpEquityPercent;
      default:                   return InpLotMultiplier;
     }
  }
