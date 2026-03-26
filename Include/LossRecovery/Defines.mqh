//+------------------------------------------------------------------+
//|                                                      Defines.mqh |
//|                         Loss Recovery Strategy - Definitions      |
//|                         Enums, constants, magic numbers, structs  |
//+------------------------------------------------------------------+
#ifndef __DEFINES_MQH__
#define __DEFINES_MQH__

//--- Magic numbers for order identification
#define MAGIC_RECOVERY   880001
#define MAGIC_HEDGE      880002
#define MAGIC_AVERAGING  880003

//--- Global variable keys for cross-EA communication
#define GV_SESSION_ID    "RM_SessionID"
#define GV_STATE         "RM_State"
#define GV_PAUSE_TRADE   "RM_PauseTrade"
#define GV_FILE_LOCK     "RM_FileLock"

//--- Persistence
#define RECOVERY_FOLDER  "LossRecovery"
#define SESSION_PREFIX   "session_"
#define LOG_FILENAME     "recovery_log.csv"
#define TEMP_SUFFIX      ".tmp"

//--- Session state machine
enum ENUM_SESSION_STATE
{
   STATE_IDLE       = 0,   // No active recovery
   STATE_TRIGGERED  = 1,   // Loss threshold breached, session created
   STATE_HEDGING    = 2,   // Placing hedge order
   STATE_AVERAGING  = 3,   // Grid orders being placed/monitored
   STATE_RECOVERING = 4,   // Recovery target met, partial closes in progress
   STATE_CLOSING    = 5,   // Final cleanup closes
   STATE_CLEANUP    = 6,   // Archiving session, clearing flags
   STATE_EMERGENCY  = 7,   // Emergency close all
   STATE_ARCHIVED   = 8    // Session complete
};

//--- Lot sizing mode for averaging grid
enum ENUM_SIZING_MODE
{
   SIZING_FIXED      = 0,  // All steps use base_lot
   SIZING_GEOMETRIC  = 1,  // step_i = base_lot * multiplier^(i-1)
   SIZING_RISK_BASED = 2   // Calculate lot from risk % per step
};

//--- Close strategy for partial recovery
enum ENUM_CLOSE_STRATEGY
{
   CLOSE_ALL         = 0,  // Close all averaging + full losing
   CLOSE_INTELLIGENT = 1,  // Close first+last averaging when count > threshold
   CLOSE_CASCADE     = 2   // Close sequentially in order
};

//--- Threshold mode
enum ENUM_THRESHOLD_MODE
{
   THRESHOLD_USD     = 0,  // Absolute USD value
   THRESHOLD_PERCENT = 1   // Percentage of equity
};

//--- Event log types
enum ENUM_LOG_EVENT
{
   LOG_TRIGGER       = 0,
   LOG_HEDGE         = 1,
   LOG_AVG_OPEN      = 2,
   LOG_AVG_FILL      = 3,
   LOG_PARTIAL_CLOSE = 4,
   LOG_FULL_CLOSE    = 5,
   LOG_EMERGENCY     = 6,
   LOG_STATE_CHANGE  = 7,
   LOG_ERROR         = 8,
   LOG_INFO          = 9
};

//--- Position info struct (losing or hedge)
struct SPositionInfo
{
   ulong  ticket;
   string symbol;
   int    direction;    // +1 = buy, -1 = sell
   double volume;
   double open_price;
   double pnl;

   void Reset()
   {
      ticket     = 0;
      symbol     = "";
      direction  = 0;
      volume     = 0.0;
      open_price = 0.0;
      pnl        = 0.0;
   }
};

//--- Averaging order info struct
struct SAveragingOrder
{
   ulong  ticket;
   double volume;
   double open_price;
   int    step;         // Grid level 1..N
   double pnl;
   bool   is_closed;

   void Reset()
   {
      ticket     = 0;
      volume     = 0.0;
      open_price = 0.0;
      step       = 0;
      pnl        = 0.0;
      is_closed  = false;
   }
};

//--- Grid level definition (planned, not yet executed)
struct SGridLevel
{
   int    step;
   double volume;
   double price_offset;  // Distance from hedge price in price units
   double target_price;  // Actual price level
   bool   is_filled;
};

//--- Session parameters snapshot
struct SSessionParams
{
   double base_lot;
   int    sizing_mode;       // ENUM_SIZING_MODE as int for serialization
   double geometric_multiplier;
   int    max_steps;
   double max_total_volume;
   double grid_spacing_pips;
   bool   use_atr_spacing;
   double atr_multiplier;
   int    atr_period;
   double partial_unit_lot;
   int    close_strategy;    // ENUM_CLOSE_STRATEGY as int
   int    n_close_threshold;
   int    max_retries;
};

//--- Session metrics
struct SSessionMetrics
{
   double equity_at_trigger;
   int    steps_opened;
   double total_avg_volume;
   datetime time_created;
   datetime time_updated;
   int    partial_close_count;
   double total_recovered;
};

//--- Convert state enum to string
string StateToString(ENUM_SESSION_STATE state)
{
   switch(state)
   {
      case STATE_IDLE:       return "IDLE";
      case STATE_TRIGGERED:  return "TRIGGERED";
      case STATE_HEDGING:    return "HEDGING";
      case STATE_AVERAGING:  return "AVERAGING";
      case STATE_RECOVERING: return "RECOVERING";
      case STATE_CLOSING:    return "CLOSING";
      case STATE_CLEANUP:    return "CLEANUP";
      case STATE_EMERGENCY:  return "EMERGENCY";
      case STATE_ARCHIVED:   return "ARCHIVED";
   }
   return "UNKNOWN";
}

//--- Convert string back to state enum
ENUM_SESSION_STATE StringToState(string s)
{
   if(s == "IDLE")       return STATE_IDLE;
   if(s == "TRIGGERED")  return STATE_TRIGGERED;
   if(s == "HEDGING")    return STATE_HEDGING;
   if(s == "AVERAGING")  return STATE_AVERAGING;
   if(s == "RECOVERING") return STATE_RECOVERING;
   if(s == "CLOSING")    return STATE_CLOSING;
   if(s == "CLEANUP")    return STATE_CLEANUP;
   if(s == "EMERGENCY")  return STATE_EMERGENCY;
   if(s == "ARCHIVED")   return STATE_ARCHIVED;
   return STATE_IDLE;
}

//--- Convert log event to string
string LogEventToString(ENUM_LOG_EVENT evt)
{
   switch(evt)
   {
      case LOG_TRIGGER:       return "TRIGGER";
      case LOG_HEDGE:         return "HEDGE";
      case LOG_AVG_OPEN:      return "AVG_OPEN";
      case LOG_AVG_FILL:      return "AVG_FILL";
      case LOG_PARTIAL_CLOSE: return "PARTIAL_CLOSE";
      case LOG_FULL_CLOSE:    return "FULL_CLOSE";
      case LOG_EMERGENCY:     return "EMERGENCY";
      case LOG_STATE_CHANGE:  return "STATE_CHANGE";
      case LOG_ERROR:         return "ERROR";
      case LOG_INFO:          return "INFO";
   }
   return "UNKNOWN";
}

#endif // __DEFINES_MQH__
