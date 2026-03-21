//+------------------------------------------------------------------+
//| CopyTrading/Defines.mqh                                          |
//| Shared constants, enums, and data structures for the             |
//| Copy Trading System for MetaTrader 5                             |
//+------------------------------------------------------------------+
#pragma once

//--- Signal type enumeration
enum ENUM_SIGNAL_TYPE
  {
   SIGNAL_MARKET_ORDER  = 0,  // New market order opened
   SIGNAL_PENDING_ORDER = 1,  // New pending order placed
   SIGNAL_MODIFY        = 2,  // Position/order modification (SL/TP)
   SIGNAL_CLOSE         = 3,  // Full position closure
   SIGNAL_CLOSE_PARTIAL = 4   // Partial position closure
  };

//--- Allocation method enumeration
enum ENUM_ALLOCATION_METHOD
  {
   ALLOC_FIXED_LOT      = 0,  // Fixed lot size regardless of master
   ALLOC_LOT_MULTIPLIER = 1,  // Master lot size * multiplier
   ALLOC_RISK_PERCENT   = 2,  // Risk percentage of equity per trade
   ALLOC_EQUITY_PERCENT = 3   // Equity percentage proportional to master
  };

//--- Direction filter enumeration
enum ENUM_DIRECTION_FILTER
  {
   DIR_BOTH     = 0,  // Copy both buy and sell trades
   DIR_BUY_ONLY = 1,  // Copy only buy trades
   DIR_SELL_ONLY= 2,  // Copy only sell trades
   DIR_REVERSE  = 3   // Reverse direction (buy→sell, sell→buy)
  };

//--- Log level enumeration
enum ENUM_LOG_LEVEL
  {
   LOG_TRACE = 0,
   LOG_DEBUG = 1,
   LOG_INFO  = 2,
   LOG_WARN  = 3,
   LOG_ERROR = 4,
   LOG_FATAL = 5
  };

//--- Broadcast/reception method
enum ENUM_BROADCAST_METHOD
  {
   BROADCAST_FILE       = 0,  // File-based (shared directory)
   BROADCAST_GLOBAL_VAR = 1   // MT5 global variables (same terminal)
  };

//--- Connection status
enum ENUM_CONNECTION_STATUS
  {
   CONN_CONNECTED    = 0,  // Active, latency < 1000ms
   CONN_DEGRADED     = 1,  // Connected but high latency
   CONN_RECONNECTING = 2,  // Attempting to restore
   CONN_DISCONNECTED = 3,  // No communication > 30s
   CONN_ERROR        = 4   // Fatal error
  };

//+------------------------------------------------------------------+
//| Position correspondence map entry                                 |
//+------------------------------------------------------------------+
struct SPositionMap
  {
   ulong             masterTicket;    // Master's position ticket
   ulong             followerTicket;  // Follower's position ticket
   string            symbol;          // Trading symbol
   double            masterOpenPrice; // Master's open price
   double            followerOpenPrice;// Follower's open price
   double            masterVolume;    // Master's original volume
   double            followerVolume;  // Follower's original volume
   datetime          openTime;        // When position was opened
   int               magicNumber;     // EA magic number
  };

//+------------------------------------------------------------------+
//| Daily performance snapshot                                        |
//+------------------------------------------------------------------+
struct SDailyStats
  {
   datetime          date;
   double            startEquity;
   double            endEquity;
   int               totalTrades;
   int               winTrades;
   int               loseTrades;
   double            grossProfit;
   double            grossLoss;
   double            maxDrawdown;
  };

//+------------------------------------------------------------------+
//| System-wide constants                                             |
//+------------------------------------------------------------------+
#define CT_VERSION              "1.0.0"
#define CT_MAGIC_NUMBER         20251230
#define CT_SIGNAL_DIR           "CopyTrading\\Signals\\"
#define CT_LOG_DIR              "CopyTrading\\Logs\\"
#define CT_STATE_DIR            "CopyTrading\\State\\"
#define CT_MAX_QUEUE_SIZE       100
#define CT_SIGNAL_MAX_AGE       300        // 5 minutes (seconds)
#define CT_HEARTBEAT_SECS       5          // Heartbeat interval
#define CT_HEARTBEAT_TIMEOUT    30         // Offline threshold (seconds)
#define CT_RECONNECT_SECS       10         // Reconnection retry interval
#define CT_MAX_RECONNECT_TRIES  3          // Maximum reconnection attempts
#define CT_RECONCILE_SECS       60         // Position reconciliation interval
#define CT_MAX_SLIPPAGE         30         // Default max slippage (points)
#define CT_MAX_RETRY_COUNT      3          // Max order execution retries
#define CT_LOG_MAX_SIZE_MB      10         // Log rotation size threshold
#define CT_MAX_POSITION_MAP     500        // Max tracked positions
#define CT_FILE_CLEANUP_SECS    600        // Signal file cleanup age (10 min)
#define CT_DASHBOARD_OBJ_PREFIX "CT_"     // Chart object name prefix
#define CT_NULL_TICKET          0          // Invalid ticket sentinel

//--- Warning thresholds
#define CT_DRAWDOWN_WARN_PCT    75.0       // Warn at 75% of max drawdown
#define CT_DAILY_LOSS_WARN_PCT  50.0       // Warn at 50% of daily loss
#define CT_MARGIN_WARN_PCT      300.0      // Warn when margin below 300%

//--- Lot size limits
#define CT_LOT_MIN_DEFAULT      0.01
#define CT_LOT_MAX_DEFAULT      100.0

//--- String constants
#define CT_HEARTBEAT_PREFIX     "heartbeat_"
#define CT_SIGNAL_PREFIX        "signal_"
#define CT_STATE_PREFIX         "state_"
#define CT_POSMAP_PREFIX        "posmap_"
#define CT_STATS_PREFIX         "stats_"
