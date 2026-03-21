//+------------------------------------------------------------------+
//| CopyTrading/MT5Wrapper.mqh                                       |
//| MT5 API wrapper with retry logic and error handling              |
//+------------------------------------------------------------------+
#pragma once
#include "Defines.mqh"
#include "Logger.mqh"

//+------------------------------------------------------------------+
//| CMT5Wrapper — safe wrappers around MQL5 trading functions        |
//| Provides unified retry logic, error classification, and          |
//| symbol property helpers used by the rest of the copy system.     |
//+------------------------------------------------------------------+
class CMT5Wrapper
  {
private:
   CLogger          *m_logger;
   int               m_defaultSlippage;
   int               m_magicNumber;
   datetime          m_lastRequestTime;
   int               m_consecutiveFailures;

   //--- internal helpers
   void              ThrottleIfNeeded();
   void              RecordSuccess();
   void              RecordFailure(const string &context, uint retcode);

public:
                     CMT5Wrapper();
                    ~CMT5Wrapper();

   //--- lifecycle
   bool              Init(CLogger *logger, int magicNumber, int slippage = CT_MAX_SLIPPAGE);

   //--- order execution
   bool              SendMarketOrder(string symbol,
                                     ENUM_ORDER_TYPE orderType,
                                     double volume,
                                     double sl,
                                     double tp,
                                     string comment,
                                     ulong  &ticket);

   bool              ModifyPosition(ulong ticket, double sl, double tp);

   bool              ClosePosition(ulong ticket, double volume = 0.0);

   bool              PlacePendingOrder(string          symbol,
                                       ENUM_ORDER_TYPE orderType,
                                       double          volume,
                                       double          price,
                                       double          sl,
                                       double          tp,
                                       datetime        expiration,
                                       string          comment,
                                       ulong           &ticket);

   bool              CancelPendingOrder(ulong ticket);

   //--- error classification
   bool              IsRetriableError(uint retcode);
   string            RetcodeToString(uint retcode);

   //--- symbol property helpers
   double            NormalizeLotSize(string symbol, double lots);
   double            GetSymbolMinLot(string symbol);
   double            GetSymbolMaxLot(string symbol);
   double            GetSymbolLotStep(string symbol);
   bool              CheckSymbolExists(string symbol);
   double            GetAsk(string symbol);
   double            GetBid(string symbol);
   double            GetPipValue(string symbol);

   //--- accessors
   int               GetConsecutiveFailures() const { return m_consecutiveFailures; }
   datetime          GetLastRequestTime()     const { return m_lastRequestTime;     }
  };

//+------------------------------------------------------------------+
//| Constructor                                                       |
//+------------------------------------------------------------------+
CMT5Wrapper::CMT5Wrapper()
  {
   m_logger              = NULL;
   m_defaultSlippage     = CT_MAX_SLIPPAGE;
   m_magicNumber         = CT_MAGIC_NUMBER;
   m_lastRequestTime     = 0;
   m_consecutiveFailures = 0;
  }

//+------------------------------------------------------------------+
//| Destructor                                                        |
//+------------------------------------------------------------------+
CMT5Wrapper::~CMT5Wrapper()
  {
   // m_logger is owned externally — do not delete here
  }

//+------------------------------------------------------------------+
//| Initialise the wrapper                                            |
//| Must be called before any trading method.                         |
//+------------------------------------------------------------------+
bool CMT5Wrapper::Init(CLogger *logger, int magicNumber, int slippage = CT_MAX_SLIPPAGE)
  {
   if(logger == NULL)
     {
      Print("CMT5Wrapper::Init — logger pointer is NULL");
      return false;
     }

   m_logger          = logger;
   m_magicNumber     = magicNumber;
   m_defaultSlippage = (slippage > 0) ? slippage : CT_MAX_SLIPPAGE;
   m_lastRequestTime = 0;
   m_consecutiveFailures = 0;

   m_logger.Info("CMT5Wrapper initialised",
                 "magic=" + IntegerToString(m_magicNumber) +
                 " slippage=" + IntegerToString(m_defaultSlippage));
   return true;
  }

//+------------------------------------------------------------------+
//| Ensure at least 1 second between consecutive requests to avoid   |
//| exchange throttling / TRADE_RETCODE_TOO_MANY_REQUESTS            |
//+------------------------------------------------------------------+
void CMT5Wrapper::ThrottleIfNeeded()
  {
   datetime now = TimeCurrent();
   if(m_lastRequestTime > 0 && (now - m_lastRequestTime) < 1)
      Sleep(1000);
   m_lastRequestTime = TimeCurrent();
  }

//+------------------------------------------------------------------+
//| Reset failure counter on a successful operation                  |
//+------------------------------------------------------------------+
void CMT5Wrapper::RecordSuccess()
  {
   m_consecutiveFailures = 0;
  }

//+------------------------------------------------------------------+
//| Increment failure counter and write an error log entry           |
//+------------------------------------------------------------------+
void CMT5Wrapper::RecordFailure(const string &context, uint retcode)
  {
   m_consecutiveFailures++;
   if(m_logger != NULL)
      m_logger.Error(context + " failed: " + RetcodeToString(retcode),
                     "retcode=" + IntegerToString((int)retcode) +
                     " consecutive=" + IntegerToString(m_consecutiveFailures));
  }

//+------------------------------------------------------------------+
//| Send a market order with retry logic                             |
//| Returns true and populates ticket on TRADE_RETCODE_DONE.         |
//+------------------------------------------------------------------+
bool CMT5Wrapper::SendMarketOrder(string          symbol,
                                   ENUM_ORDER_TYPE orderType,
                                   double          volume,
                                   double          sl,
                                   double          tp,
                                   string          comment,
                                   ulong           &ticket)
  {
   ticket = CT_NULL_TICKET;

   if(m_logger == NULL)
      return false;

   // Normalise lot size before touching the market
   double normVol = NormalizeLotSize(symbol, volume);
   if(normVol <= 0.0)
     {
      m_logger.Error("SendMarketOrder — lot size normalised to zero",
                     "symbol=" + symbol + " volume=" + DoubleToString(volume, 2));
      return false;
     }

   MqlTradeRequest request = {};
   MqlTradeResult  result  = {};

   request.action       = TRADE_ACTION_DEAL;
   request.symbol       = symbol;
   request.volume       = normVol;
   request.type         = orderType;
   request.sl           = sl;
   request.tp           = tp;
   request.deviation    = m_defaultSlippage;
   request.magic        = m_magicNumber;
   request.comment      = comment;
   request.type_filling = ORDER_FILLING_IOC;   // fallback to FOK when rejected

   for(int attempt = 1; attempt <= CT_MAX_RETRY_COUNT + 1; attempt++)
     {
      // Refresh price on each attempt (price may have moved)
      if(orderType == ORDER_TYPE_BUY)
         request.price = SymbolInfoDouble(symbol, SYMBOL_ASK);
      else
         request.price = SymbolInfoDouble(symbol, SYMBOL_BID);

      ThrottleIfNeeded();

      bool sent = OrderSend(request, result);

      if(sent && result.retcode == TRADE_RETCODE_DONE)
        {
         ticket = result.order;
         RecordSuccess();
         m_logger.Info("SendMarketOrder — order executed",
                       "symbol=" + symbol +
                       " type=" + EnumToString(orderType) +
                       " vol=" + DoubleToString(normVol, 2) +
                       " ticket=" + IntegerToString((long)ticket) +
                       " price=" + DoubleToString(result.price, 5));
         return true;
        }

      // ORDER_FILLING_IOC rejected by some brokers — retry with FOK
      if(result.retcode == TRADE_RETCODE_INVALID_FILL && attempt == 1)
        {
         request.type_filling = ORDER_FILLING_FOK;
         m_logger.Debug("SendMarketOrder — retrying with ORDER_FILLING_FOK",
                        "symbol=" + symbol);
         continue;
        }

      if(!IsRetriableError(result.retcode) || attempt > CT_MAX_RETRY_COUNT)
        {
         RecordFailure("SendMarketOrder", result.retcode);
         return false;
        }

      // Retriable — back off and try again
      int sleepMs = 500 * attempt;
      m_logger.Warn("SendMarketOrder — retriable error, retrying",
                    "attempt=" + IntegerToString(attempt) +
                    " retcode=" + IntegerToString((int)result.retcode) +
                    " msg=" + RetcodeToString(result.retcode) +
                    " sleep=" + IntegerToString(sleepMs) + "ms");
      Sleep(sleepMs);
     }

   RecordFailure("SendMarketOrder", result.retcode);
   return false;
  }

//+------------------------------------------------------------------+
//| Modify the SL and TP of an open position                         |
//+------------------------------------------------------------------+
bool CMT5Wrapper::ModifyPosition(ulong ticket, double sl, double tp)
  {
   if(m_logger == NULL)
      return false;

   if(!PositionSelectByTicket(ticket))
     {
      m_logger.Error("ModifyPosition — position not found",
                     "ticket=" + IntegerToString((long)ticket));
      return false;
     }

   string symbol = PositionGetString(POSITION_SYMBOL);
   double price  = PositionGetDouble(POSITION_PRICE_OPEN);

   MqlTradeRequest request = {};
   MqlTradeResult  result  = {};

   request.action   = TRADE_ACTION_SLTP;
   request.symbol   = symbol;
   request.position = ticket;
   request.sl       = sl;
   request.tp       = tp;
   request.magic    = m_magicNumber;
   // price field is not used for SLTP but set it for completeness
   request.price    = price;

   for(int attempt = 1; attempt <= CT_MAX_RETRY_COUNT + 1; attempt++)
     {
      ThrottleIfNeeded();

      bool sent = OrderSend(request, result);

      if(sent && result.retcode == TRADE_RETCODE_DONE)
        {
         RecordSuccess();
         m_logger.Info("ModifyPosition — SL/TP updated",
                       "ticket=" + IntegerToString((long)ticket) +
                       " sl=" + DoubleToString(sl, 5) +
                       " tp=" + DoubleToString(tp, 5));
         return true;
        }

      if(!IsRetriableError(result.retcode) || attempt > CT_MAX_RETRY_COUNT)
        {
         RecordFailure("ModifyPosition", result.retcode);
         return false;
        }

      int sleepMs = 500 * attempt;
      m_logger.Warn("ModifyPosition — retriable error, retrying",
                    "attempt=" + IntegerToString(attempt) +
                    " retcode=" + IntegerToString((int)result.retcode) +
                    " sleep=" + IntegerToString(sleepMs) + "ms");
      Sleep(sleepMs);
     }

   RecordFailure("ModifyPosition", result.retcode);
   return false;
  }

//+------------------------------------------------------------------+
//| Close an open position fully or partially                        |
//| volume==0 means close the entire position.                       |
//+------------------------------------------------------------------+
bool CMT5Wrapper::ClosePosition(ulong ticket, double volume = 0.0)
  {
   if(m_logger == NULL)
      return false;

   if(!PositionSelectByTicket(ticket))
     {
      m_logger.Error("ClosePosition — position not found",
                     "ticket=" + IntegerToString((long)ticket));
      return false;
     }

   string          symbol    = PositionGetString(POSITION_SYMBOL);
   double          posVol    = PositionGetDouble(POSITION_VOLUME);
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   // Determine close volume
   double closeVol = (volume <= 0.0 || volume >= posVol) ? posVol : volume;
   closeVol = NormalizeLotSize(symbol, closeVol);
   if(closeVol <= 0.0)
     {
      m_logger.Error("ClosePosition — close volume normalised to zero",
                     "ticket=" + IntegerToString((long)ticket));
      return false;
     }

   // Opposite order type to close
   ENUM_ORDER_TYPE closeType = (posType == POSITION_TYPE_BUY)
                               ? ORDER_TYPE_SELL
                               : ORDER_TYPE_BUY;

   MqlTradeRequest request = {};
   MqlTradeResult  result  = {};

   request.action       = TRADE_ACTION_DEAL;
   request.symbol       = symbol;
   request.volume       = closeVol;
   request.type         = closeType;
   request.position     = ticket;
   request.deviation    = m_defaultSlippage;
   request.magic        = m_magicNumber;
   request.type_filling = ORDER_FILLING_IOC;

   for(int attempt = 1; attempt <= CT_MAX_RETRY_COUNT + 1; attempt++)
     {
      // Refresh close price on each attempt
      request.price = (closeType == ORDER_TYPE_BUY)
                      ? SymbolInfoDouble(symbol, SYMBOL_ASK)
                      : SymbolInfoDouble(symbol, SYMBOL_BID);

      ThrottleIfNeeded();

      bool sent = OrderSend(request, result);

      if(sent && result.retcode == TRADE_RETCODE_DONE)
        {
         RecordSuccess();
         m_logger.Info("ClosePosition — position closed",
                       "ticket=" + IntegerToString((long)ticket) +
                       " vol=" + DoubleToString(closeVol, 2) +
                       " price=" + DoubleToString(result.price, 5));
         return true;
        }

      // Try FOK if IOC was rejected
      if(result.retcode == TRADE_RETCODE_INVALID_FILL && attempt == 1)
        {
         request.type_filling = ORDER_FILLING_FOK;
         m_logger.Debug("ClosePosition — retrying with ORDER_FILLING_FOK",
                        "ticket=" + IntegerToString((long)ticket));
         continue;
        }

      if(!IsRetriableError(result.retcode) || attempt > CT_MAX_RETRY_COUNT)
        {
         RecordFailure("ClosePosition", result.retcode);
         return false;
        }

      int sleepMs = 500 * attempt;
      m_logger.Warn("ClosePosition — retriable error, retrying",
                    "attempt=" + IntegerToString(attempt) +
                    " retcode=" + IntegerToString((int)result.retcode) +
                    " sleep=" + IntegerToString(sleepMs) + "ms");
      Sleep(sleepMs);
     }

   RecordFailure("ClosePosition", result.retcode);
   return false;
  }

//+------------------------------------------------------------------+
//| Place a pending order (no retry — price is stale quickly)        |
//+------------------------------------------------------------------+
bool CMT5Wrapper::PlacePendingOrder(string          symbol,
                                     ENUM_ORDER_TYPE orderType,
                                     double          volume,
                                     double          price,
                                     double          sl,
                                     double          tp,
                                     datetime        expiration,
                                     string          comment,
                                     ulong           &ticket)
  {
   ticket = CT_NULL_TICKET;

   if(m_logger == NULL)
      return false;

   double normVol = NormalizeLotSize(symbol, volume);
   if(normVol <= 0.0)
     {
      m_logger.Error("PlacePendingOrder — lot size normalised to zero",
                     "symbol=" + symbol + " volume=" + DoubleToString(volume, 2));
      return false;
     }

   MqlTradeRequest request = {};
   MqlTradeResult  result  = {};

   request.action     = TRADE_ACTION_PENDING;
   request.symbol     = symbol;
   request.volume     = normVol;
   request.type       = orderType;
   request.price      = price;
   request.sl         = sl;
   request.tp         = tp;
   request.expiration = expiration;
   request.magic      = m_magicNumber;
   request.comment    = comment;

   // Set expiration type
   if(expiration > 0)
      request.type_time = ORDER_TIME_SPECIFIED;
   else
      request.type_time = ORDER_TIME_GTC;

   ThrottleIfNeeded();

   bool sent = OrderSend(request, result);

   if(sent && (result.retcode == TRADE_RETCODE_DONE ||
               result.retcode == TRADE_RETCODE_PLACED))
     {
      ticket = result.order;
      RecordSuccess();
      m_logger.Info("PlacePendingOrder — order placed",
                    "symbol=" + symbol +
                    " type=" + EnumToString(orderType) +
                    " vol=" + DoubleToString(normVol, 2) +
                    " price=" + DoubleToString(price, 5) +
                    " ticket=" + IntegerToString((long)ticket));
      return true;
     }

   RecordFailure("PlacePendingOrder", result.retcode);
   return false;
  }

//+------------------------------------------------------------------+
//| Cancel a pending order                                           |
//+------------------------------------------------------------------+
bool CMT5Wrapper::CancelPendingOrder(ulong ticket)
  {
   if(m_logger == NULL)
      return false;

   MqlTradeRequest request = {};
   MqlTradeResult  result  = {};

   request.action = TRADE_ACTION_REMOVE;
   request.order  = ticket;
   request.magic  = m_magicNumber;

   ThrottleIfNeeded();

   bool sent = OrderSend(request, result);

   if(sent && result.retcode == TRADE_RETCODE_DONE)
     {
      RecordSuccess();
      m_logger.Info("CancelPendingOrder — order cancelled",
                    "ticket=" + IntegerToString((long)ticket));
      return true;
     }

   RecordFailure("CancelPendingOrder", result.retcode);
   return false;
  }

//+------------------------------------------------------------------+
//| Return true for transient errors worth retrying                  |
//+------------------------------------------------------------------+
bool CMT5Wrapper::IsRetriableError(uint retcode)
  {
   switch(retcode)
     {
      case TRADE_RETCODE_REQUOTE:       // 10004 — requote, new price available
      case TRADE_RETCODE_CONNECTION:    // 10005 — no connection to trade server
      case TRADE_RETCODE_PRICE_CHANGED: // 10006 — price changed
      case TRADE_RETCODE_TIMEOUT:       // 10010 — request processing timeout
      case TRADE_RETCODE_OFF_QUOTES:    // 10021 — no quotes / market closed
      case TRADE_RETCODE_ERROR:         // 10022 — common error (internal)
         return true;

      default:
         return false;
     }
  }

//+------------------------------------------------------------------+
//| Human-readable description for the most common return codes      |
//+------------------------------------------------------------------+
string CMT5Wrapper::RetcodeToString(uint retcode)
  {
   switch(retcode)
     {
      case TRADE_RETCODE_DONE:              return "Request completed successfully (DONE)";
      case TRADE_RETCODE_DONE_PARTIAL:      return "Request completed partially (DONE_PARTIAL)";
      case TRADE_RETCODE_REQUOTE:           return "Requote — new price offered (REQUOTE)";
      case TRADE_RETCODE_REJECT:            return "Request rejected by server (REJECT)";
      case TRADE_RETCODE_CANCEL:            return "Request cancelled by client (CANCEL)";
      case TRADE_RETCODE_PLACED:            return "Order placed successfully (PLACED)";
      case TRADE_RETCODE_CONNECTION:        return "No connection to trade server (CONNECTION)";
      case TRADE_RETCODE_PRICE_CHANGED:     return "Price changed (PRICE_CHANGED)";
      case TRADE_RETCODE_PRICE_OFF:         return "No quotes for the request (PRICE_OFF)";
      case TRADE_RETCODE_INVALID_EXPIRE:    return "Invalid order expiration (INVALID_EXPIRE)";
      case TRADE_RETCODE_ORDER_CHANGED:     return "Order state changed (ORDER_CHANGED)";
      case TRADE_RETCODE_TOO_MANY_REQUESTS: return "Too many requests (TOO_MANY_REQUESTS)";
      case TRADE_RETCODE_NO_CHANGES:        return "No changes in the request (NO_CHANGES)";
      case TRADE_RETCODE_SERVER_DISABLES_AT:return "Autotrading disabled by server (SERVER_DISABLES_AT)";
      case TRADE_RETCODE_CLIENT_DISABLES_AT:return "Autotrading disabled by client (CLIENT_DISABLES_AT)";
      case TRADE_RETCODE_LOCKED:            return "Request locked for processing (LOCKED)";
      case TRADE_RETCODE_FROZEN:            return "Order/position frozen (FROZEN)";
      case TRADE_RETCODE_INVALID_FILL:      return "Invalid filling type (INVALID_FILL)";
      case TRADE_RETCODE_CONNECTION_FAILED: return "Connection failed (CONNECTION_FAILED)";
      case TRADE_RETCODE_ONLY_REAL:         return "Real account required (ONLY_REAL)";
      case TRADE_RETCODE_LIMIT_ORDERS:      return "Pending orders limit reached (LIMIT_ORDERS)";
      case TRADE_RETCODE_LIMIT_VOLUME:      return "Volume limit reached (LIMIT_VOLUME)";
      case TRADE_RETCODE_INVALID_ORDER:     return "Invalid or prohibited order type (INVALID_ORDER)";
      case TRADE_RETCODE_POSITION_CLOSED:   return "Position already closed (POSITION_CLOSED)";
      case TRADE_RETCODE_TIMEOUT:           return "Request timed out (TIMEOUT)";
      case TRADE_RETCODE_OFF_QUOTES:        return "No quotes / market closed (OFF_QUOTES)";
      case TRADE_RETCODE_ERROR:             return "Common internal error (ERROR)";
      case TRADE_RETCODE_NO_MONEY:          return "Insufficient funds (NO_MONEY)";
      case TRADE_RETCODE_INVALID_STOPS:     return "Invalid stop levels (INVALID_STOPS)";
      case TRADE_RETCODE_TRADE_DISABLED:    return "Trading disabled for this symbol (TRADE_DISABLED)";
      case TRADE_RETCODE_MARKET_CLOSED:     return "Market is closed (MARKET_CLOSED)";
      case TRADE_RETCODE_INVALID_PRICE:     return "Invalid price (INVALID_PRICE)";
      case TRADE_RETCODE_INVALID_VOLUME:    return "Invalid volume (INVALID_VOLUME)";
      default:
         return "Unknown retcode: " + IntegerToString((int)retcode);
     }
  }

//+------------------------------------------------------------------+
//| Normalise a lot size to broker constraints                       |
//+------------------------------------------------------------------+
double CMT5Wrapper::NormalizeLotSize(string symbol, double lots)
  {
   double step   = GetSymbolLotStep(symbol);
   double minLot = GetSymbolMinLot(symbol);
   double maxLot = GetSymbolMaxLot(symbol);

   // Guard against degenerate broker data
   if(step   <= 0.0) step   = 0.01;
   if(minLot <= 0.0) minLot = CT_LOT_MIN_DEFAULT;
   if(maxLot <= 0.0) maxLot = CT_LOT_MAX_DEFAULT;

   // Round to nearest step
   lots = MathRound(lots / step) * step;

   // Clamp within [min, max]
   lots = MathMax(minLot, MathMin(maxLot, lots));

   // Re-round after clamping to eliminate floating-point drift
   lots = NormalizeDouble(lots, (int)MathRound(-MathLog10(step)));

   return lots;
  }

//+------------------------------------------------------------------+
//| Return the minimum lot size for the symbol                       |
//+------------------------------------------------------------------+
double CMT5Wrapper::GetSymbolMinLot(string symbol)
  {
   return SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
  }

//+------------------------------------------------------------------+
//| Return the maximum lot size for the symbol                       |
//+------------------------------------------------------------------+
double CMT5Wrapper::GetSymbolMaxLot(string symbol)
  {
   return SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
  }

//+------------------------------------------------------------------+
//| Return the lot step for the symbol                               |
//+------------------------------------------------------------------+
double CMT5Wrapper::GetSymbolLotStep(string symbol)
  {
   return SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
  }

//+------------------------------------------------------------------+
//| Verify that a symbol is available and subscribe to market data   |
//+------------------------------------------------------------------+
bool CMT5Wrapper::CheckSymbolExists(string symbol)
  {
   // SymbolSelect forces the symbol into the Market Watch so that
   // SymbolInfo calls will return live data even if not visible.
   if(!SymbolSelect(symbol, true))
     {
      if(m_logger != NULL)
         m_logger.Warn("CheckSymbolExists — SymbolSelect failed",
                       "symbol=" + symbol +
                       " error=" + IntegerToString(GetLastError()));
      return false;
     }

   long selected = 0;
   if(!SymbolInfoInteger(symbol, SYMBOL_SELECT, selected) || selected == 0)
     {
      if(m_logger != NULL)
         m_logger.Warn("CheckSymbolExists — symbol not selectable",
                       "symbol=" + symbol);
      return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Return the current ask price for a symbol                        |
//+------------------------------------------------------------------+
double CMT5Wrapper::GetAsk(string symbol)
  {
   return SymbolInfoDouble(symbol, SYMBOL_ASK);
  }

//+------------------------------------------------------------------+
//| Return the current bid price for a symbol                        |
//+------------------------------------------------------------------+
double CMT5Wrapper::GetBid(string symbol)
  {
   return SymbolInfoDouble(symbol, SYMBOL_BID);
  }

//+------------------------------------------------------------------+
//| Calculate the monetary value of 1 pip for 1.0 standard lot       |
//| Formula:  pipValue = (tickValue / tickSize) * point * 10         |
//|                                                                   |
//| tickValue  — profit/loss per 1 tick move for 1 lot               |
//| tickSize   — minimum price movement                               |
//| point      — smallest price increment (1 pip = 10 points for     |
//|              5-digit brokers)                                     |
//|                                                                   |
//| Multiplying by 10 converts the point-level value to pip level.   |
//+------------------------------------------------------------------+
double CMT5Wrapper::GetPipValue(string symbol)
  {
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double point     = SymbolInfoDouble(symbol, SYMBOL_POINT);

   if(tickSize <= 0.0 || tickValue <= 0.0 || point <= 0.0)
     {
      if(m_logger != NULL)
         m_logger.Warn("GetPipValue — degenerate symbol properties",
                       "symbol=" + symbol +
                       " tickValue=" + DoubleToString(tickValue, 6) +
                       " tickSize="  + DoubleToString(tickSize, 6)  +
                       " point="     + DoubleToString(point, 6));
      return 0.0;
     }

   return (tickValue / tickSize) * point * 10.0;
  }
