//+------------------------------------------------------------------+
//|                                              RecoverySession.mqh |
//|                         Loss Recovery Strategy - Session State    |
//+------------------------------------------------------------------+
#ifndef __RECOVERYSESSION_MQH__
#define __RECOVERYSESSION_MQH__

#include "Defines.mqh"
#include "Utils.mqh"

//+------------------------------------------------------------------+
//| CRecoverySession - Tracks all data for one recovery cycle         |
//+------------------------------------------------------------------+
class CRecoverySession
{
public:
   string              session_id;
   ENUM_SESSION_STATE  state;
   SPositionInfo       losing_position;
   SPositionInfo       hedge_position;
   SAveragingOrder     averaging_orders[];
   SGridLevel          grid_levels[];
   SSessionParams      params;
   SSessionMetrics     metrics;

   CRecoverySession();
   ~CRecoverySession();

   //--- State management
   void   SetState(ENUM_SESSION_STATE new_state);
   bool   IsActive();
   void   Reset();

   //--- Averaging order management
   void   AddAveragingOrder(const SAveragingOrder &order);
   void   MarkOrderClosed(ulong ticket);
   int    GetActiveAveragingCount();
   double GetTotalAveragingPnL();
   double GetTotalAveragingVolume();
   int    FindOldestActiveOrder();   // Returns index
   int    FindNewestActiveOrder();   // Returns index

   //--- Grid management
   void   SetGridLevels(const SGridLevel &levels[]);
   int    GetNextUnfilledLevel();

   //--- Serialization (to/from JSON)
   string ToJSON();
   bool   FromJSON(const string &json);

   //--- Update PnL from live positions
   void   UpdateLivePnL();

private:
   string PositionToJSON(const SPositionInfo &pos);
   string AveragingOrderToJSON(const SAveragingOrder &order);
   string ParamsToJSON();
   string MetricsToJSON();
   void   PositionFromJSON(const string &json, SPositionInfo &pos);
   void   AveragingOrderFromJSON(const string &json, SAveragingOrder &order);
   void   ParamsFromJSON(const string &json);
   void   MetricsFromJSON(const string &json);
};

//+------------------------------------------------------------------+
CRecoverySession::CRecoverySession()
{
   Reset();
}

//+------------------------------------------------------------------+
CRecoverySession::~CRecoverySession()
{
}

//+------------------------------------------------------------------+
void CRecoverySession::Reset()
{
   session_id = "";
   state = STATE_IDLE;
   losing_position.Reset();
   hedge_position.Reset();
   ArrayResize(averaging_orders, 0);
   ArrayResize(grid_levels, 0);

   ZeroMemory(params);
   ZeroMemory(metrics);
}

//+------------------------------------------------------------------+
void CRecoverySession::SetState(ENUM_SESSION_STATE new_state)
{
   state = new_state;
   metrics.time_updated = TimeCurrent();
}

//+------------------------------------------------------------------+
bool CRecoverySession::IsActive()
{
   return (state != STATE_IDLE && state != STATE_ARCHIVED);
}

//+------------------------------------------------------------------+
void CRecoverySession::AddAveragingOrder(const SAveragingOrder &order)
{
   int size = ArraySize(averaging_orders);
   ArrayResize(averaging_orders, size + 1);
   averaging_orders[size] = order;
   metrics.steps_opened = size + 1;
   metrics.total_avg_volume += order.volume;
   metrics.time_updated = TimeCurrent();
}

//+------------------------------------------------------------------+
void CRecoverySession::MarkOrderClosed(ulong ticket)
{
   for(int i = 0; i < ArraySize(averaging_orders); i++)
   {
      if(averaging_orders[i].ticket == ticket)
      {
         averaging_orders[i].is_closed = true;
         metrics.time_updated = TimeCurrent();
         return;
      }
   }
}

//+------------------------------------------------------------------+
int CRecoverySession::GetActiveAveragingCount()
{
   int count = 0;
   for(int i = 0; i < ArraySize(averaging_orders); i++)
   {
      if(!averaging_orders[i].is_closed)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
double CRecoverySession::GetTotalAveragingPnL()
{
   double total = 0.0;
   for(int i = 0; i < ArraySize(averaging_orders); i++)
   {
      if(!averaging_orders[i].is_closed)
         total += averaging_orders[i].pnl;
   }
   return total;
}

//+------------------------------------------------------------------+
double CRecoverySession::GetTotalAveragingVolume()
{
   double total = 0.0;
   for(int i = 0; i < ArraySize(averaging_orders); i++)
   {
      if(!averaging_orders[i].is_closed)
         total += averaging_orders[i].volume;
   }
   return total;
}

//+------------------------------------------------------------------+
int CRecoverySession::FindOldestActiveOrder()
{
   for(int i = 0; i < ArraySize(averaging_orders); i++)
   {
      if(!averaging_orders[i].is_closed)
         return i;
   }
   return -1;
}

//+------------------------------------------------------------------+
int CRecoverySession::FindNewestActiveOrder()
{
   for(int i = ArraySize(averaging_orders) - 1; i >= 0; i--)
   {
      if(!averaging_orders[i].is_closed)
         return i;
   }
   return -1;
}

//+------------------------------------------------------------------+
void CRecoverySession::SetGridLevels(const SGridLevel &levels[])
{
   int size = ArraySize(levels);
   ArrayResize(grid_levels, size);
   for(int i = 0; i < size; i++)
      grid_levels[i] = levels[i];
}

//+------------------------------------------------------------------+
int CRecoverySession::GetNextUnfilledLevel()
{
   for(int i = 0; i < ArraySize(grid_levels); i++)
   {
      if(!grid_levels[i].is_filled)
         return i;
   }
   return -1;
}

//+------------------------------------------------------------------+
void CRecoverySession::UpdateLivePnL()
{
   // Update losing position PnL
   if(losing_position.ticket > 0 && PositionSelectByTicket(losing_position.ticket))
   {
      losing_position.pnl = PositionGetDouble(POSITION_PROFIT) +
                            PositionGetDouble(POSITION_SWAP);
      losing_position.volume = PositionGetDouble(POSITION_VOLUME);
   }

   // Update hedge position PnL
   if(hedge_position.ticket > 0 && PositionSelectByTicket(hedge_position.ticket))
   {
      hedge_position.pnl = PositionGetDouble(POSITION_PROFIT) +
                           PositionGetDouble(POSITION_SWAP);
      hedge_position.volume = PositionGetDouble(POSITION_VOLUME);
   }

   // Update averaging orders PnL
   for(int i = 0; i < ArraySize(averaging_orders); i++)
   {
      if(!averaging_orders[i].is_closed &&
         averaging_orders[i].ticket > 0 &&
         PositionSelectByTicket(averaging_orders[i].ticket))
      {
         averaging_orders[i].pnl = PositionGetDouble(POSITION_PROFIT) +
                                   PositionGetDouble(POSITION_SWAP);
         averaging_orders[i].volume = PositionGetDouble(POSITION_VOLUME);
      }
   }
}

//+------------------------------------------------------------------+
//| Serialization - ToJSON                                            |
//+------------------------------------------------------------------+
string CRecoverySession::ToJSON()
{
   string json = "{\n";
   json += "  " + JsonString("session_id", session_id) + ",\n";
   json += "  " + JsonString("state", StateToString(state)) + ",\n";
   json += "  \"losing_position\":" + PositionToJSON(losing_position) + ",\n";
   json += "  \"hedge_position\":" + PositionToJSON(hedge_position) + ",\n";

   // Averaging orders array
   json += "  \"averaging_orders\":[";
   for(int i = 0; i < ArraySize(averaging_orders); i++)
   {
      if(i > 0) json += ",";
      json += "\n    " + AveragingOrderToJSON(averaging_orders[i]);
   }
   json += "\n  ],\n";

   json += "  \"params\":" + ParamsToJSON() + ",\n";
   json += "  \"metrics\":" + MetricsToJSON() + "\n";
   json += "}";

   return json;
}

//+------------------------------------------------------------------+
string CRecoverySession::PositionToJSON(const SPositionInfo &pos)
{
   string json = "{";
   json += JsonInt("ticket", (long)pos.ticket) + ",";
   json += JsonString("symbol", pos.symbol) + ",";
   json += JsonInt("direction", pos.direction) + ",";
   json += JsonNumber("volume", pos.volume, 2) + ",";
   json += JsonNumber("open_price", pos.open_price, 5) + ",";
   json += JsonNumber("pnl", pos.pnl, 2);
   json += "}";
   return json;
}

//+------------------------------------------------------------------+
string CRecoverySession::AveragingOrderToJSON(const SAveragingOrder &order)
{
   string json = "{";
   json += JsonInt("ticket", (long)order.ticket) + ",";
   json += JsonNumber("volume", order.volume, 2) + ",";
   json += JsonNumber("open_price", order.open_price, 5) + ",";
   json += JsonInt("step", order.step) + ",";
   json += JsonNumber("pnl", order.pnl, 2) + ",";
   json += JsonBool("is_closed", order.is_closed);
   json += "}";
   return json;
}

//+------------------------------------------------------------------+
string CRecoverySession::ParamsToJSON()
{
   string json = "{";
   json += JsonNumber("base_lot", params.base_lot, 2) + ",";
   json += JsonInt("sizing_mode", params.sizing_mode) + ",";
   json += JsonNumber("geometric_multiplier", params.geometric_multiplier, 2) + ",";
   json += JsonInt("max_steps", params.max_steps) + ",";
   json += JsonNumber("max_total_volume", params.max_total_volume, 2) + ",";
   json += JsonNumber("grid_spacing_pips", params.grid_spacing_pips, 1) + ",";
   json += JsonBool("use_atr_spacing", params.use_atr_spacing) + ",";
   json += JsonNumber("atr_multiplier", params.atr_multiplier, 2) + ",";
   json += JsonInt("atr_period", params.atr_period) + ",";
   json += JsonNumber("partial_unit_lot", params.partial_unit_lot, 2) + ",";
   json += JsonInt("close_strategy", params.close_strategy) + ",";
   json += JsonInt("n_close_threshold", params.n_close_threshold) + ",";
   json += JsonInt("max_retries", params.max_retries);
   json += "}";
   return json;
}

//+------------------------------------------------------------------+
string CRecoverySession::MetricsToJSON()
{
   string json = "{";
   json += JsonNumber("equity_at_trigger", metrics.equity_at_trigger, 2) + ",";
   json += JsonInt("steps_opened", metrics.steps_opened) + ",";
   json += JsonNumber("total_avg_volume", metrics.total_avg_volume, 2) + ",";
   json += JsonString("time_created", FormatDateTime(metrics.time_created)) + ",";
   json += JsonString("time_updated", FormatDateTime(metrics.time_updated)) + ",";
   json += JsonInt("partial_close_count", metrics.partial_close_count) + ",";
   json += JsonNumber("total_recovered", metrics.total_recovered, 2);
   json += "}";
   return json;
}

//+------------------------------------------------------------------+
//| Deserialization - FromJSON                                        |
//+------------------------------------------------------------------+
bool CRecoverySession::FromJSON(const string &json)
{
   Reset();

   session_id = JsonGetString(json, "session_id");
   if(session_id == "") return false;

   state = StringToState(JsonGetString(json, "state"));

   // Parse losing position
   string losing_json = JsonGetObject(json, "losing_position");
   if(losing_json != "") PositionFromJSON(losing_json, losing_position);

   // Parse hedge position
   string hedge_json = JsonGetObject(json, "hedge_position");
   if(hedge_json != "") PositionFromJSON(hedge_json, hedge_position);

   // Parse averaging orders
   string avg_array = JsonGetArray(json, "averaging_orders");
   if(avg_array != "")
   {
      string elements[];
      int count = JsonSplitArray(avg_array, elements);
      ArrayResize(averaging_orders, count);
      for(int i = 0; i < count; i++)
         AveragingOrderFromJSON(elements[i], averaging_orders[i]);
   }

   // Parse params
   string params_json = JsonGetObject(json, "params");
   if(params_json != "") ParamsFromJSON(params_json);

   // Parse metrics
   string metrics_json = JsonGetObject(json, "metrics");
   if(metrics_json != "") MetricsFromJSON(metrics_json);

   return true;
}

//+------------------------------------------------------------------+
void CRecoverySession::PositionFromJSON(const string &json, SPositionInfo &pos)
{
   pos.ticket     = (ulong)JsonGetInt(json, "ticket");
   pos.symbol     = JsonGetString(json, "symbol");
   pos.direction  = (int)JsonGetInt(json, "direction");
   pos.volume     = JsonGetDouble(json, "volume");
   pos.open_price = JsonGetDouble(json, "open_price");
   pos.pnl        = JsonGetDouble(json, "pnl");
}

//+------------------------------------------------------------------+
void CRecoverySession::AveragingOrderFromJSON(const string &json, SAveragingOrder &order)
{
   order.ticket     = (ulong)JsonGetInt(json, "ticket");
   order.volume     = JsonGetDouble(json, "volume");
   order.open_price = JsonGetDouble(json, "open_price");
   order.step       = (int)JsonGetInt(json, "step");
   order.pnl        = JsonGetDouble(json, "pnl");
   order.is_closed  = JsonGetBool(json, "is_closed");
}

//+------------------------------------------------------------------+
void CRecoverySession::ParamsFromJSON(const string &json)
{
   params.base_lot              = JsonGetDouble(json, "base_lot");
   params.sizing_mode           = (int)JsonGetInt(json, "sizing_mode");
   params.geometric_multiplier  = JsonGetDouble(json, "geometric_multiplier");
   params.max_steps             = (int)JsonGetInt(json, "max_steps");
   params.max_total_volume      = JsonGetDouble(json, "max_total_volume");
   params.grid_spacing_pips     = JsonGetDouble(json, "grid_spacing_pips");
   params.use_atr_spacing       = JsonGetBool(json, "use_atr_spacing");
   params.atr_multiplier        = JsonGetDouble(json, "atr_multiplier");
   params.atr_period            = (int)JsonGetInt(json, "atr_period");
   params.partial_unit_lot      = JsonGetDouble(json, "partial_unit_lot");
   params.close_strategy        = (int)JsonGetInt(json, "close_strategy");
   params.n_close_threshold     = (int)JsonGetInt(json, "n_close_threshold");
   params.max_retries           = (int)JsonGetInt(json, "max_retries");
}

//+------------------------------------------------------------------+
void CRecoverySession::MetricsFromJSON(const string &json)
{
   metrics.equity_at_trigger   = JsonGetDouble(json, "equity_at_trigger");
   metrics.steps_opened        = (int)JsonGetInt(json, "steps_opened");
   metrics.total_avg_volume    = JsonGetDouble(json, "total_avg_volume");
   metrics.time_created        = StringToTime(JsonGetString(json, "time_created"));
   metrics.time_updated        = StringToTime(JsonGetString(json, "time_updated"));
   metrics.partial_close_count = (int)JsonGetInt(json, "partial_close_count");
   metrics.total_recovered     = JsonGetDouble(json, "total_recovered");
}

#endif // __RECOVERYSESSION_MQH__
