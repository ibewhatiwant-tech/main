//+------------------------------------------------------------------+
//| CopyTrading/Signal.mqh                                           |
//| Trade signal data structure with JSON serialization              |
//+------------------------------------------------------------------+
#ifndef COPYTRADING_SIGNAL_MQH
#define COPYTRADING_SIGNAL_MQH
#include "Defines.mqh"

class CSignal
  {
public:
   // Identification
   string            signalId;          // Unique UUID
   string            masterId;          // Master account identifier
   datetime          timestamp;         // Signal generation time (UTC)

   // Signal type
   ENUM_SIGNAL_TYPE  type;              // Signal type
   ENUM_ORDER_TYPE   orderType;         // BUY, SELL, BUY_LIMIT, etc.

   // Trade details
   string            symbol;            // Trading symbol
   double            volume;            // Master's lot size
   double            price;             // Entry price (0 for market orders)
   double            stopLoss;          // Stop loss level (0 = none)
   double            takeProfit;        // Take profit level (0 = none)

   // Identification
   ulong             masterTicket;      // Master's position/order ticket
   int               magicNumber;       // EA magic number
   string            comment;           // Trade comment
   datetime          expiration;        // Order expiration (pending orders)
   int               slippage;          // Allowed slippage in points

   // Modification details (SIGNAL_MODIFY type)
   double            newStopLoss;       // New SL value
   double            newTakeProfit;     // New TP value

   // Partial closure details (SIGNAL_CLOSE_PARTIAL type)
   double            closeVolume;       // Volume to close

   // Equity reference for ALLOC_EQUITY_PERCENT calculation
   double            masterEquity;      // Master's current equity

                     CSignal();
   void              Reset();
   string            ToJSON() const;
   bool              FromJSON(const string &json);
   bool              Validate() const;
   bool              IsStale() const;
   string            GenerateUUID(long accountId);

private:
   string            JSONEscape(const string &s) const;
   string            JSONString(const string &key, const string &val) const;
   string            JSONDouble(const string &key, double val, int digits=5) const;
   string            JSONInt(const string &key, long val) const;
   string            JSONBool(const string &key, bool val) const;
   string            GetJSONValue(const string &json, const string &key) const;
   double            GetJSONDouble(const string &json, const string &key) const;
   long              GetJSONLong(const string &json, const string &key) const;
   bool              GetJSONBool(const string &json, const string &key) const;
  };

//+------------------------------------------------------------------+
//| Constructor — zero-initialise all fields                         |
//+------------------------------------------------------------------+
CSignal::CSignal()
  {
   Reset();
  }

//+------------------------------------------------------------------+
//| Reset all fields to safe defaults                                |
//+------------------------------------------------------------------+
void CSignal::Reset()
  {
   signalId      = "";
   masterId      = "";
   timestamp     = 0;
   type          = SIGNAL_MARKET_ORDER;
   orderType     = ORDER_TYPE_BUY;
   symbol        = "";
   volume        = 0.0;
   price         = 0.0;
   stopLoss      = 0.0;
   takeProfit    = 0.0;
   masterTicket  = 0;
   magicNumber   = 0;
   comment       = "";
   expiration    = 0;
   slippage      = CT_MAX_SLIPPAGE;
   newStopLoss   = 0.0;
   newTakeProfit = 0.0;
   closeVolume   = 0.0;
   masterEquity  = 0.0;
  }

//+------------------------------------------------------------------+
//| Escape a string for safe JSON embedding                          |
//+------------------------------------------------------------------+
string CSignal::JSONEscape(const string &s) const
  {
   string result = s;
   // Backslash must be replaced first to avoid double-escaping
   StringReplace(result, "\\", "\\\\");
   StringReplace(result, "\"", "\\\"");
   StringReplace(result, "\n", "\\n");
   StringReplace(result, "\r", "\\r");
   StringReplace(result, "\t", "\\t");
   return result;
  }

//+------------------------------------------------------------------+
//| Build  "key":"value"  JSON fragment                              |
//+------------------------------------------------------------------+
string CSignal::JSONString(const string &key, const string &val) const
  {
   return "\"" + key + "\":\"" + JSONEscape(val) + "\"";
  }

//+------------------------------------------------------------------+
//| Build  "key":number  JSON fragment                               |
//+------------------------------------------------------------------+
string CSignal::JSONDouble(const string &key, double val, int digits=5) const
  {
   return "\"" + key + "\":" + DoubleToString(val, digits);
  }

//+------------------------------------------------------------------+
//| Build  "key":integer  JSON fragment                              |
//+------------------------------------------------------------------+
string CSignal::JSONInt(const string &key, long val) const
  {
   return "\"" + key + "\":" + IntegerToString(val);
  }

//+------------------------------------------------------------------+
//| Build  "key":true/false  JSON fragment                           |
//+------------------------------------------------------------------+
string CSignal::JSONBool(const string &key, bool val) const
  {
   return "\"" + key + "\":" + (val ? "true" : "false");
  }

//+------------------------------------------------------------------+
//| Serialise signal to a compact JSON string                        |
//+------------------------------------------------------------------+
string CSignal::ToJSON() const
  {
   string j = "{";
   j += JSONString("signalId",      signalId)     + ",";
   j += JSONString("masterId",      masterId)      + ",";
   j += JSONInt   ("timestamp",     (long)timestamp) + ",";
   j += JSONInt   ("type",          (long)type)    + ",";
   j += JSONInt   ("orderType",     (long)orderType) + ",";
   j += JSONString("symbol",        symbol)        + ",";
   j += JSONDouble("volume",        volume)        + ",";
   j += JSONDouble("price",         price)         + ",";
   j += JSONDouble("stopLoss",      stopLoss)      + ",";
   j += JSONDouble("takeProfit",    takeProfit)    + ",";
   j += JSONInt   ("masterTicket",  (long)masterTicket) + ",";
   j += JSONInt   ("magicNumber",   (long)magicNumber)  + ",";
   j += JSONString("comment",       comment)       + ",";
   j += JSONInt   ("expiration",    (long)expiration) + ",";
   j += JSONInt   ("slippage",      (long)slippage) + ",";
   j += JSONDouble("newStopLoss",   newStopLoss)   + ",";
   j += JSONDouble("newTakeProfit", newTakeProfit) + ",";
   j += JSONDouble("closeVolume",   closeVolume)   + ",";
   j += JSONDouble("masterEquity",  masterEquity);
   j += "}";
   return j;
  }

//+------------------------------------------------------------------+
//| Extract the raw value string for a given JSON key                |
//| Handles both quoted strings and bare values (numbers, booleans)  |
//+------------------------------------------------------------------+
string CSignal::GetJSONValue(const string &json, const string &key) const
  {
   // Search for  "key":
   string searchKey = "\"" + key + "\":";
   int keyPos = StringFind(json, searchKey);
   if(keyPos < 0)
      return "";

   int valueStart = keyPos + StringLen(searchKey);

   // Skip any whitespace
   while(valueStart < StringLen(json) &&
         (StringSubstr(json, valueStart, 1) == " "  ||
          StringSubstr(json, valueStart, 1) == "\t" ||
          StringSubstr(json, valueStart, 1) == "\r" ||
          StringSubstr(json, valueStart, 1) == "\n"))
      valueStart++;

   if(valueStart >= StringLen(json))
      return "";

   string firstChar = StringSubstr(json, valueStart, 1);

   if(firstChar == "\"")
     {
      // Quoted string — scan forward respecting escape sequences
      int pos = valueStart + 1;
      string result = "";
      int jsonLen = StringLen(json);
      while(pos < jsonLen)
        {
         string ch = StringSubstr(json, pos, 1);
         if(ch == "\\")
           {
            pos++;
            if(pos < jsonLen)
              {
               string esc = StringSubstr(json, pos, 1);
               if(esc == "\"")      result += "\"";
               else if(esc == "\\") result += "\\";
               else if(esc == "n")  result += "\n";
               else if(esc == "r")  result += "\r";
               else if(esc == "t")  result += "\t";
               else                 result += esc;
               pos++;
              }
            continue;
           }
         if(ch == "\"")
            break;
         result += ch;
         pos++;
        }
      return result;
     }
   else
     {
      // Bare value — ends at ',', '}', ']', or whitespace
      int endPos = valueStart;
      int jsonLen = StringLen(json);
      while(endPos < jsonLen)
        {
         string ch = StringSubstr(json, endPos, 1);
         if(ch == "," || ch == "}" || ch == "]" ||
            ch == " " || ch == "\t" || ch == "\r" || ch == "\n")
            break;
         endPos++;
        }
      return StringSubstr(json, valueStart, endPos - valueStart);
     }
  }

//+------------------------------------------------------------------+
//| Parse a double value from JSON                                   |
//+------------------------------------------------------------------+
double CSignal::GetJSONDouble(const string &json, const string &key) const
  {
   string val = GetJSONValue(json, key);
   if(val == "")
      return 0.0;
   return StringToDouble(val);
  }

//+------------------------------------------------------------------+
//| Parse a long integer value from JSON                             |
//+------------------------------------------------------------------+
long CSignal::GetJSONLong(const string &json, const string &key) const
  {
   string val = GetJSONValue(json, key);
   if(val == "")
      return 0;
   return StringToInteger(val);
  }

//+------------------------------------------------------------------+
//| Parse a boolean value from JSON                                  |
//+------------------------------------------------------------------+
bool CSignal::GetJSONBool(const string &json, const string &key) const
  {
   string val = GetJSONValue(json, key);
   return (val == "true" || val == "1");
  }

//+------------------------------------------------------------------+
//| Deserialise a signal from a JSON string                          |
//+------------------------------------------------------------------+
bool CSignal::FromJSON(const string &json)
  {
   if(StringLen(json) < 2)
      return false;

   Reset();

   signalId      = GetJSONValue(json, "signalId");
   masterId      = GetJSONValue(json, "masterId");
   timestamp     = (datetime)GetJSONLong(json, "timestamp");
   type          = (ENUM_SIGNAL_TYPE)GetJSONLong(json, "type");
   orderType     = (ENUM_ORDER_TYPE)GetJSONLong(json, "orderType");
   symbol        = GetJSONValue(json, "symbol");
   volume        = GetJSONDouble(json, "volume");
   price         = GetJSONDouble(json, "price");
   stopLoss      = GetJSONDouble(json, "stopLoss");
   takeProfit    = GetJSONDouble(json, "takeProfit");
   masterTicket  = (ulong)GetJSONLong(json, "masterTicket");
   magicNumber   = (int)GetJSONLong(json, "magicNumber");
   comment       = GetJSONValue(json, "comment");
   expiration    = (datetime)GetJSONLong(json, "expiration");
   slippage      = (int)GetJSONLong(json, "slippage");
   newStopLoss   = GetJSONDouble(json, "newStopLoss");
   newTakeProfit = GetJSONDouble(json, "newTakeProfit");
   closeVolume   = GetJSONDouble(json, "closeVolume");
   masterEquity  = GetJSONDouble(json, "masterEquity");

   return true;
  }

//+------------------------------------------------------------------+
//| Validate required signal fields                                  |
//+------------------------------------------------------------------+
bool CSignal::Validate() const
  {
   if(symbol == "")
     {
      Print("CSignal::Validate — symbol is empty");
      return false;
     }
   if(volume <= 0.0)
     {
      Print("CSignal::Validate — volume must be > 0, got: ", volume);
      return false;
     }
   if(masterId == "")
     {
      Print("CSignal::Validate — masterId is empty");
      return false;
     }
   if(signalId == "")
     {
      Print("CSignal::Validate — signalId is empty");
      return false;
     }
   if(timestamp <= 0)
     {
      Print("CSignal::Validate — timestamp is not set");
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Returns true when a market-order signal has expired              |
//+------------------------------------------------------------------+
bool CSignal::IsStale() const
  {
   if(type != SIGNAL_MARKET_ORDER)
      return false;
   return ((TimeCurrent() - timestamp) > CT_SIGNAL_MAX_AGE);
  }

//+------------------------------------------------------------------+
//| Generate a UUID v4-style identifier                              |
//| Format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx                     |
//+------------------------------------------------------------------+
string CSignal::GenerateUUID(long accountId)
  {
   // Seed with account id XOR current microsecond time
   MathSrand((int)(accountId ^ (long)TimeCurrent() ^ (long)GetMicrosecondCount()));

   // Helper lambda-equivalent: produce a random hex nibble
   // We build 32 hex chars then insert dashes and version bits
   uchar bytes[16];
   for(int i = 0; i < 16; i++)
      bytes[i] = (uchar)(MathRand() & 0xFF);

   // Set version 4 bits: top nibble of byte 6 = 0100
   bytes[6] = (bytes[6] & 0x0F) | 0x40;

   // Set variant bits: top two bits of byte 8 = 10xxxxxx
   bytes[8] = (bytes[8] & 0x3F) | 0x80;

   // Format as  xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   string hex = "";
   string hexChars = "0123456789abcdef";
   for(int i = 0; i < 16; i++)
     {
      int hi = (bytes[i] >> 4) & 0x0F;
      int lo =  bytes[i]       & 0x0F;
      hex += StringSubstr(hexChars, hi, 1);
      hex += StringSubstr(hexChars, lo, 1);
      if(i == 3 || i == 5 || i == 7 || i == 9)
         hex += "-";
     }
   return hex;
  }
#endif // COPYTRADING_SIGNAL_MQH
