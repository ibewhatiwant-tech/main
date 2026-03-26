//+------------------------------------------------------------------+
//|                                                        Utils.mqh |
//|                         Loss Recovery Strategy - Utility Helpers  |
//+------------------------------------------------------------------+
#ifndef __UTILS_MQH__
#define __UTILS_MQH__

#include "Defines.mqh"

//+------------------------------------------------------------------+
//| Normalize lot size to broker's requirements                       |
//+------------------------------------------------------------------+
double NormalizeLot(string symbol, double lot)
{
   double min_lot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lot_step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(lot_step <= 0) lot_step = 0.01;

   // Round to nearest lot step
   lot = MathFloor(lot / lot_step + 0.5) * lot_step;

   // Clamp to min/max
   if(lot < min_lot) lot = min_lot;
   if(lot > max_lot) lot = max_lot;

   // Round to avoid floating point issues
   int digits = (int)MathCeil(-MathLog10(lot_step));
   lot = NormalizeDouble(lot, digits);

   return lot;
}

//+------------------------------------------------------------------+
//| Convert pips to price distance for a given symbol                 |
//+------------------------------------------------------------------+
double PipsToPrice(string symbol, double pips)
{
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   // For 5-digit/3-digit brokers, 1 pip = 10 points
   // For 4-digit/2-digit brokers, 1 pip = 1 point
   double pip_size = (digits == 3 || digits == 5) ? point * 10.0 : point;

   return NormalizeDouble(pips * pip_size, digits);
}

//+------------------------------------------------------------------+
//| Get pip size for a symbol                                         |
//+------------------------------------------------------------------+
double GetPipSize(string symbol)
{
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   return (digits == 3 || digits == 5) ? point * 10.0 : point;
}

//+------------------------------------------------------------------+
//| Convert price distance to pips                                    |
//+------------------------------------------------------------------+
double PriceToPips(string symbol, double price_distance)
{
   double pip_size = GetPipSize(symbol);
   if(pip_size <= 0) return 0;
   return price_distance / pip_size;
}

//+------------------------------------------------------------------+
//| Get ATR value for dynamic spacing                                 |
//+------------------------------------------------------------------+
double GetATR(string symbol, int period, ENUM_TIMEFRAMES timeframe = PERIOD_CURRENT)
{
   int handle = iATR(symbol, timeframe, period);
   if(handle == INVALID_HANDLE)
   {
      Print("[Utils] Failed to create ATR indicator for ", symbol);
      return 0.0;
   }

   double atr_buffer[];
   ArraySetAsSeries(atr_buffer, true);

   if(CopyBuffer(handle, 0, 0, 1, atr_buffer) <= 0)
   {
      Print("[Utils] Failed to copy ATR buffer for ", symbol);
      IndicatorRelease(handle);
      return 0.0;
   }

   double atr_value = atr_buffer[0];
   IndicatorRelease(handle);
   return atr_value;
}

//+------------------------------------------------------------------+
//| Get pip value in account currency for 1 lot                       |
//+------------------------------------------------------------------+
double GetPipValue(string symbol)
{
   double tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double pip_size   = GetPipSize(symbol);

   if(tick_size <= 0) return 0.0;

   return tick_value * pip_size / tick_size;
}

//+------------------------------------------------------------------+
//| Get opposite order type                                           |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE OppositeOrderType(int direction)
{
   return (direction > 0) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
}

//+------------------------------------------------------------------+
//| Direction to position type                                        |
//+------------------------------------------------------------------+
ENUM_POSITION_TYPE DirectionToPositionType(int direction)
{
   return (direction > 0) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
}

//+------------------------------------------------------------------+
//| Position type to direction                                        |
//+------------------------------------------------------------------+
int PositionTypeToDirection(ENUM_POSITION_TYPE pos_type)
{
   return (pos_type == POSITION_TYPE_BUY) ? 1 : -1;
}

//+------------------------------------------------------------------+
//| Generate session ID from current time                             |
//+------------------------------------------------------------------+
string GenerateSessionID()
{
   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);
   return StringFormat("%04d%02d%02d_%02d%02d%02d",
                       dt.year, dt.mon, dt.day,
                       dt.hour, dt.min, dt.sec);
}

//+------------------------------------------------------------------+
//| Format datetime for logging                                       |
//+------------------------------------------------------------------+
string FormatDateTime(datetime dt)
{
   MqlDateTime mdt;
   TimeToStruct(dt, mdt);
   return StringFormat("%04d-%02d-%02d %02d:%02d:%02d",
                       mdt.year, mdt.mon, mdt.day,
                       mdt.hour, mdt.min, mdt.sec);
}

//+------------------------------------------------------------------+
//| Escape string for JSON output                                     |
//+------------------------------------------------------------------+
string JsonEscape(string s)
{
   StringReplace(s, "\\", "\\\\");
   StringReplace(s, "\"", "\\\"");
   StringReplace(s, "\n", "\\n");
   StringReplace(s, "\r", "\\r");
   StringReplace(s, "\t", "\\t");
   return s;
}

//+------------------------------------------------------------------+
//| Simple JSON string value builder                                  |
//+------------------------------------------------------------------+
string JsonString(string key, string value)
{
   return "\"" + JsonEscape(key) + "\":\"" + JsonEscape(value) + "\"";
}

//+------------------------------------------------------------------+
//| Simple JSON number value builder                                  |
//+------------------------------------------------------------------+
string JsonNumber(string key, double value, int digits = 8)
{
   return "\"" + JsonEscape(key) + "\":" + DoubleToString(value, digits);
}

//+------------------------------------------------------------------+
//| Simple JSON integer value builder                                 |
//+------------------------------------------------------------------+
string JsonInt(string key, long value)
{
   return "\"" + JsonEscape(key) + "\":" + IntegerToString(value);
}

//+------------------------------------------------------------------+
//| Simple JSON boolean value builder                                 |
//+------------------------------------------------------------------+
string JsonBool(string key, bool value)
{
   return "\"" + JsonEscape(key) + "\":" + (value ? "true" : "false");
}

//+------------------------------------------------------------------+
//| Extract string value from JSON by key (simple parser)             |
//+------------------------------------------------------------------+
string JsonGetString(const string &json, const string key)
{
   string search = "\"" + key + "\":\"";
   int pos = StringFind(json, search);
   if(pos < 0) return "";

   int start = pos + StringLen(search);
   int end = start;
   bool escaped = false;

   while(end < StringLen(json))
   {
      ushort ch = StringGetCharacter(json, end);
      if(escaped)
      {
         escaped = false;
         end++;
         continue;
      }
      if(ch == '\\')
      {
         escaped = true;
         end++;
         continue;
      }
      if(ch == '"')
         break;
      end++;
   }

   return StringSubstr(json, start, end - start);
}

//+------------------------------------------------------------------+
//| Extract numeric value from JSON by key (simple parser)            |
//+------------------------------------------------------------------+
double JsonGetDouble(const string &json, const string key)
{
   string search = "\"" + key + "\":";
   int pos = StringFind(json, search);
   if(pos < 0) return 0.0;

   int start = pos + StringLen(search);
   // Skip whitespace
   while(start < StringLen(json) && StringGetCharacter(json, start) == ' ')
      start++;

   int end = start;
   while(end < StringLen(json))
   {
      ushort ch = StringGetCharacter(json, end);
      if((ch >= '0' && ch <= '9') || ch == '.' || ch == '-' || ch == '+' || ch == 'e' || ch == 'E')
         end++;
      else
         break;
   }

   string num_str = StringSubstr(json, start, end - start);
   return StringToDouble(num_str);
}

//+------------------------------------------------------------------+
//| Extract integer value from JSON by key                            |
//+------------------------------------------------------------------+
long JsonGetInt(const string &json, const string key)
{
   return (long)JsonGetDouble(json, key);
}

//+------------------------------------------------------------------+
//| Extract boolean value from JSON by key                            |
//+------------------------------------------------------------------+
bool JsonGetBool(const string &json, const string key)
{
   string search = "\"" + key + "\":";
   int pos = StringFind(json, search);
   if(pos < 0) return false;

   int start = pos + StringLen(search);
   while(start < StringLen(json) && StringGetCharacter(json, start) == ' ')
      start++;

   return (StringSubstr(json, start, 4) == "true");
}

//+------------------------------------------------------------------+
//| Extract JSON object by key (returns content between { })          |
//+------------------------------------------------------------------+
string JsonGetObject(const string &json, const string key)
{
   string search = "\"" + key + "\":";
   int pos = StringFind(json, search);
   if(pos < 0) return "";

   int start = pos + StringLen(search);
   // Skip whitespace
   while(start < StringLen(json) && StringGetCharacter(json, start) == ' ')
      start++;

   if(start >= StringLen(json) || StringGetCharacter(json, start) != '{')
      return "";

   int depth = 0;
   int end = start;
   while(end < StringLen(json))
   {
      ushort ch = StringGetCharacter(json, end);
      if(ch == '{') depth++;
      if(ch == '}') depth--;
      if(depth == 0)
      {
         end++;
         break;
      }
      end++;
   }

   return StringSubstr(json, start, end - start);
}

//+------------------------------------------------------------------+
//| Extract JSON array by key (returns content between [ ])           |
//+------------------------------------------------------------------+
string JsonGetArray(const string &json, const string key)
{
   string search = "\"" + key + "\":";
   int pos = StringFind(json, search);
   if(pos < 0) return "";

   int start = pos + StringLen(search);
   while(start < StringLen(json) && StringGetCharacter(json, start) == ' ')
      start++;

   if(start >= StringLen(json) || StringGetCharacter(json, start) != '[')
      return "";

   int depth = 0;
   int end = start;
   while(end < StringLen(json))
   {
      ushort ch = StringGetCharacter(json, end);
      if(ch == '[') depth++;
      if(ch == ']') depth--;
      if(depth == 0)
      {
         end++;
         break;
      }
      end++;
   }

   return StringSubstr(json, start, end - start);
}

//+------------------------------------------------------------------+
//| Split JSON array into individual elements                         |
//+------------------------------------------------------------------+
int JsonSplitArray(const string &json_array, string &elements[])
{
   ArrayResize(elements, 0);

   if(StringLen(json_array) < 2) return 0;

   // Remove outer brackets
   string inner = StringSubstr(json_array, 1, StringLen(json_array) - 2);
   if(StringLen(inner) == 0) return 0;

   int depth = 0;
   int start = 0;
   int count = 0;

   for(int i = 0; i < StringLen(inner); i++)
   {
      ushort ch = StringGetCharacter(inner, i);
      if(ch == '{' || ch == '[') depth++;
      if(ch == '}' || ch == ']') depth--;
      if(ch == ',' && depth == 0)
      {
         count++;
         ArrayResize(elements, count);
         elements[count - 1] = StringSubstr(inner, start, i - start);
         start = i + 1;
      }
   }

   // Last element
   count++;
   ArrayResize(elements, count);
   elements[count - 1] = StringSubstr(inner, start);

   return count;
}

#endif // __UTILS_MQH__
