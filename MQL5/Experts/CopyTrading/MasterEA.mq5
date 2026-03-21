//+------------------------------------------------------------------+
//| CopyTrading/MasterEA.mq5                                        |
//| Master Expert Advisor — Signal Provider                          |
//| Detects trades on master account and broadcasts signals          |
//| to follower accounts via file-based transmission.               |
//+------------------------------------------------------------------+
#property copyright   "Copy Trading System v1.0"
#property link        "https://github.com/ibewhatiwant-tech/main"
#property version     "1.00"
#property description "Master EA: Broadcasts trade signals to followers"
#property strict

//--- Include all required components
#include <CopyTrading/Defines.mqh>
#include <CopyTrading/Logger.mqh>
#include <CopyTrading/Signal.mqh>
#include <CopyTrading/TradeMonitor.mqh>
#include <CopyTrading/SignalBroadcaster.mqh>
#include <CopyTrading/PerformanceTracker.mqh>
#include <CopyTrading/Dashboard.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+

//--- Signal Identity
input string          InpSignalName         = "My Trading Signals";      // Signal name (displayed to followers)
input string          InpSignalDescription  = "Automated forex strategy"; // Signal description

//--- Signal Broadcasting
input bool            InpBroadcastEnabled   = true;                       // Enable signal broadcasting
input string          InpSignalDirectory    = "";                          // Signal directory (blank=default)

//--- Trade Filtering
input bool            InpFilterSymbols      = false;                       // Enable symbol filter
input string          InpAllowedSymbols     = "EURUSD,GBPUSD,USDJPY";    // Allowed symbols (comma-separated)
input bool            InpFilterByMagic      = false;                       // Filter trades by magic number
input int             InpMagicFilter        = 0;                           // Magic number to filter (0=disabled)
input ENUM_DIRECTION_FILTER InpDirFilter    = DIR_BOTH;                   // Direction filter

//--- Display
input bool            InpShowDashboard      = true;                        // Show on-chart dashboard
input int             InpDashboardCorner    = 1;                           // Dashboard corner (0=TL,1=TR,2=BL,3=BR)
input int             InpDashboardFontSize  = 9;                           // Dashboard font size

//--- Logging
input ENUM_LOG_LEVEL  InpLogLevel           = LOG_INFO;                    // Log verbosity level

//--- Notifications
input bool            InpEnablePushAlerts   = true;                        // Enable MT5 push notifications
input bool            InpAlertOnFailure     = true;                        // Alert on broadcast failure

//+------------------------------------------------------------------+
//| Global EA Objects                                                  |
//+------------------------------------------------------------------+
CLogger            g_logger;
CTradeMonitor      g_monitor;
CSignalBroadcaster g_broadcaster;
CPerformanceTracker g_perfTracker;
CDashboard         g_dashboard;

string             g_masterId     = "";
bool               g_initialized  = false;
datetime           g_lastTimerRun = 0;
int                g_timerCounter = 0;
bool               g_broadcastEnabled = true;

//+------------------------------------------------------------------+
//| Expert Advisor Initialization                                     |
//+------------------------------------------------------------------+
int OnInit()
  {
   Print("==================================================");
   Print("CopyTrading MasterEA v", CT_VERSION, " initializing...");
   Print("Account: ", AccountInfoString(ACCOUNT_NAME),
         " #", AccountInfoInteger(ACCOUNT_LOGIN));
   Print("==================================================");

   //--- Generate master ID from account number
   g_masterId = IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));

   //--- Initialize logger
   if(!g_logger.Init("MasterEA_" + g_masterId, InpLogLevel))
     {
      Print("ERROR: Failed to initialize logger");
      return INIT_FAILED;
     }
   g_logger.Info("Logger initialized");

   //--- Validate inputs
   if(InpSignalName == "")
     {
      g_logger.Error("Signal name cannot be empty");
      return INIT_FAILED;
     }

   //--- Initialize signal broadcaster
   if(!g_broadcaster.Init(&g_logger, g_masterId))
     {
      g_logger.Fatal("Failed to initialize SignalBroadcaster");
      return INIT_FAILED;
     }
   g_logger.Info("Signal broadcaster initialized");

   //--- Initialize trade monitor
   if(!g_monitor.Init(&g_logger, g_masterId, InpFilterByMagic, InpMagicFilter, InpDirFilter))
     {
      g_logger.Fatal("Failed to initialize TradeMonitor");
      return INIT_FAILED;
     }

   //--- Set symbol filter on monitor
   if(InpFilterSymbols && InpAllowedSymbols != "")
      g_monitor.SetSymbolFilter(InpAllowedSymbols);

   g_logger.Info("Trade monitor initialized");

   //--- Initialize performance tracker
   if(!g_perfTracker.Init(&g_logger, g_masterId, true))
     {
      g_logger.Warn("Failed to initialize PerformanceTracker (non-fatal)");
     }

   //--- Initialize dashboard
   if(InpShowDashboard)
     {
      if(!g_dashboard.Init(true, InpDashboardCorner, InpDashboardFontSize))
        {
         g_logger.Warn("Failed to initialize dashboard (non-fatal)");
        }
      else
        {
         g_logger.Info("Dashboard initialized");
        }
     }

   //--- Enable broadcasting
   g_broadcastEnabled = InpBroadcastEnabled;

   //--- Start periodic timer (1 second)
   if(!EventSetTimer(1))
     {
      g_logger.Warn("Failed to set timer — periodic tasks may not run");
     }

   g_initialized = true;
   g_logger.Info("MasterEA fully initialized. Signal ID: " + g_masterId);
   g_logger.Info("Signal Name: " + InpSignalName);

   if(InpEnablePushAlerts)
      SendNotification("CopyTrading: MasterEA started on account #" + g_masterId);

   //--- Force initial dashboard update
   if(InpShowDashboard)
      UpdateDashboard();

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert Advisor Deinitialization                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   g_logger.Info("MasterEA deinitializing. Reason: " + IntegerToString(reason));

   //--- Cleanup
   EventKillTimer();

   if(InpShowDashboard)
      g_dashboard.Destroy();

   g_perfTracker.SaveToFile();

   g_initialized = false;
   g_logger.Info("MasterEA shutdown complete");
   g_logger.Deinit();
  }

//+------------------------------------------------------------------+
//| OnTrade — Primary signal detection handler                        |
//+------------------------------------------------------------------+
void OnTrade()
  {
   if(!g_initialized || !g_broadcastEnabled)
      return;

   //--- Let trade monitor detect changes
   g_monitor.OnTrade();

   //--- Process all detected signals
   CSignal signal;
   while(g_monitor.GetNextSignal(signal))
     {
      g_logger.Debug("Detected trade event: " + signal.symbol +
                     " type=" + IntegerToString(signal.type) +
                     " ticket=" + IntegerToString((long)signal.masterTicket));

      //--- Add master equity to signal for equity-based allocation on followers
      signal.masterEquity = AccountInfoDouble(ACCOUNT_EQUITY);

      //--- Broadcast signal
      if(g_broadcastEnabled)
        {
         if(g_broadcaster.BroadcastSignal(signal))
           {
            g_logger.Info("Signal broadcast: " + signal.symbol + " " +
                          EnumToString(signal.orderType) + " vol=" +
                          DoubleToString(signal.volume, 2));
           }
         else
           {
            g_logger.Error("Failed to broadcast signal: " + signal.signalId);
            if(InpAlertOnFailure)
               Alert("CopyTrading: Failed to broadcast trade signal on " + signal.symbol);
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| OnTimer — Periodic tasks                                          |
//+------------------------------------------------------------------+
void OnTimer()
  {
   if(!g_initialized)
      return;

   g_timerCounter++;

   //--- Heartbeat and cleanup (via broadcaster timer)
   g_broadcaster.OnTimer();

   //--- Performance tracker update (every 5 seconds)
   if(g_timerCounter % 5 == 0)
      g_perfTracker.OnTick();

   //--- Dashboard update (every 3 seconds)
   if(InpShowDashboard && g_timerCounter % 3 == 0)
      UpdateDashboard();
  }

//+------------------------------------------------------------------+
//| OnTick — Keep EA active                                           |
//+------------------------------------------------------------------+
void OnTick()
  {
   // Minimal — main work done in OnTrade() and OnTimer()
   // Performance tracking tick
   if(g_initialized)
      g_perfTracker.OnTick();
  }

//+------------------------------------------------------------------+
//| Update dashboard display                                          |
//+------------------------------------------------------------------+
void UpdateDashboard()
  {
   if(!InpShowDashboard)
      return;

   int openPositions = 0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(PositionGetTicket(i) > 0)
         openPositions++;
     }

   g_dashboard.UpdateMaster(
      InpSignalName,
      g_broadcastEnabled,
      0,    // Follower count not tracked in file-based mode
      openPositions,
      &g_perfTracker
   );
  }

//+------------------------------------------------------------------+
//| Handle manual commands via chart comment                          |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   // Reserved for future UI interaction
  }
