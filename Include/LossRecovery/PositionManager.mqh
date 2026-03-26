//+------------------------------------------------------------------+
//|                                              PositionManager.mqh |
//|                         Loss Recovery Strategy - Order Execution  |
//+------------------------------------------------------------------+
#ifndef __POSITIONMANAGER_MQH__
#define __POSITIONMANAGER_MQH__

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include "Defines.mqh"
#include "Utils.mqh"
#include "Logger.mqh"

//+------------------------------------------------------------------+
//| CPositionManager - Order execution with retry/backoff             |
//+------------------------------------------------------------------+
class CPositionManager
{
private:
   CTrade         m_trade;
   CPositionInfo  m_pos_info;
   CLogger       *m_logger;
   int            m_max_retries;
   int            m_base_backoff_ms;  // Base backoff in milliseconds

public:
   CPositionManager();
   ~CPositionManager();

   void   Init(CLogger *logger, int max_retries = 3, int base_backoff_ms = 1000);
   void   SetMagic(ulong magic) { m_trade.SetExpertMagicNumber(magic); }
   void   SetSlippage(ulong slippage) { m_trade.SetDeviationInPoints(slippage); }

   //--- Open positions
   bool   OpenBuy(string symbol, double volume, string comment, ulong magic,
                  double sl = 0, double tp = 0);
   bool   OpenSell(string symbol, double volume, string comment, ulong magic,
                   double sl = 0, double tp = 0);
   bool   OpenPosition(string symbol, ENUM_ORDER_TYPE type, double volume,
                       string comment, ulong magic, double sl = 0, double tp = 0);

   //--- Close positions
   bool   ClosePosition(ulong ticket);
   bool   PartialClose(ulong ticket, double volume);

   //--- Query
   bool   IsPositionOpen(ulong ticket);
   double GetPositionVolume(ulong ticket);
   double GetPositionProfit(ulong ticket);
   ulong  GetResultTicket() { return m_trade.ResultOrder(); }

private:
   bool   ExecuteWithRetry(string operation);
   void   LogRetcode(string operation, uint retcode);
   void   Backoff(int attempt);
};

//+------------------------------------------------------------------+
CPositionManager::CPositionManager()
{
   m_logger = NULL;
   m_max_retries = 3;
   m_base_backoff_ms = 1000;
}

//+------------------------------------------------------------------+
CPositionManager::~CPositionManager()
{
}

//+------------------------------------------------------------------+
void CPositionManager::Init(CLogger *logger, int max_retries, int base_backoff_ms)
{
   m_logger = logger;
   m_max_retries = max_retries;
   m_base_backoff_ms = base_backoff_ms;

   m_trade.SetTypeFilling(ORDER_FILLING_FOK);
   m_trade.SetDeviationInPoints(20);
   m_trade.SetAsyncMode(false);
}

//+------------------------------------------------------------------+
bool CPositionManager::OpenBuy(string symbol, double volume, string comment,
                               ulong magic, double sl, double tp)
{
   return OpenPosition(symbol, ORDER_TYPE_BUY, volume, comment, magic, sl, tp);
}

//+------------------------------------------------------------------+
bool CPositionManager::OpenSell(string symbol, double volume, string comment,
                                ulong magic, double sl, double tp)
{
   return OpenPosition(symbol, ORDER_TYPE_SELL, volume, comment, magic, sl, tp);
}

//+------------------------------------------------------------------+
bool CPositionManager::OpenPosition(string symbol, ENUM_ORDER_TYPE type,
                                    double volume, string comment, ulong magic,
                                    double sl, double tp)
{
   volume = NormalizeLot(symbol, volume);

   m_trade.SetExpertMagicNumber(magic);

   for(int attempt = 0; attempt <= m_max_retries; attempt++)
   {
      if(attempt > 0)
      {
         if(m_logger != NULL)
            m_logger.Log(LOG_INFO, StringFormat("Retry %d/%d for %s %s %.2f lots",
                         attempt, m_max_retries,
                         (type == ORDER_TYPE_BUY ? "BUY" : "SELL"),
                         symbol, volume));
         Backoff(attempt);
      }

      bool result = false;
      if(type == ORDER_TYPE_BUY)
      {
         double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
         result = m_trade.Buy(volume, symbol, ask, sl, tp, comment);
      }
      else if(type == ORDER_TYPE_SELL)
      {
         double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
         result = m_trade.Sell(volume, symbol, bid, sl, tp, comment);
      }

      uint retcode = m_trade.ResultRetcode();
      LogRetcode("OpenPosition", retcode);

      if(result && (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED))
      {
         if(m_logger != NULL)
         {
            ulong ticket = m_trade.ResultDeal();
            if(ticket == 0) ticket = m_trade.ResultOrder();
            m_logger.LogTrade(LOG_INFO, ticket, volume,
                             m_trade.ResultPrice(),
                             StringFormat("%s %s opened",
                                         (type == ORDER_TYPE_BUY ? "BUY" : "SELL"),
                                         symbol));
         }
         return true;
      }

      // Check if retcode is retryable
      if(!IsRetryableError(retcode))
      {
         if(m_logger != NULL)
            m_logger.Log(LOG_ERROR, StringFormat("Non-retryable error %d for %s",
                         retcode, symbol));
         return false;
      }
   }

   if(m_logger != NULL)
      m_logger.Log(LOG_ERROR, StringFormat("All %d retries exhausted for open %s %s",
                   m_max_retries,
                   (type == ORDER_TYPE_BUY ? "BUY" : "SELL"),
                   symbol));
   return false;
}

//+------------------------------------------------------------------+
bool CPositionManager::ClosePosition(ulong ticket)
{
   for(int attempt = 0; attempt <= m_max_retries; attempt++)
   {
      if(attempt > 0)
      {
         if(m_logger != NULL)
            m_logger.Log(LOG_INFO, StringFormat("Retry %d/%d for close #%d",
                         attempt, m_max_retries, ticket));
         Backoff(attempt);
      }

      // Verify position still exists
      if(!PositionSelectByTicket(ticket))
      {
         if(m_logger != NULL)
            m_logger.Log(LOG_INFO, StringFormat("Position #%d already closed", ticket));
         return true;
      }

      bool result = m_trade.PositionClose(ticket);
      uint retcode = m_trade.ResultRetcode();
      LogRetcode("ClosePosition", retcode);

      if(result && (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED))
      {
         if(m_logger != NULL)
            m_logger.LogTrade(LOG_FULL_CLOSE, ticket,
                             PositionGetDouble(POSITION_VOLUME),
                             m_trade.ResultPrice(),
                             "Position closed");
         return true;
      }

      if(!IsRetryableError(retcode))
         return false;
   }

   if(m_logger != NULL)
      m_logger.Log(LOG_ERROR, StringFormat("All retries exhausted for close #%d", ticket));
   return false;
}

//+------------------------------------------------------------------+
bool CPositionManager::PartialClose(ulong ticket, double volume)
{
   // Verify position still exists
   if(!PositionSelectByTicket(ticket))
   {
      if(m_logger != NULL)
         m_logger.Log(LOG_INFO, StringFormat("Position #%d not found for partial close", ticket));
      return false;
   }

   string symbol = PositionGetString(POSITION_SYMBOL);
   double current_volume = PositionGetDouble(POSITION_VOLUME);
   volume = NormalizeLot(symbol, volume);

   // If requested volume >= current volume, do full close
   if(volume >= current_volume)
      return ClosePosition(ticket);

   for(int attempt = 0; attempt <= m_max_retries; attempt++)
   {
      if(attempt > 0)
      {
         if(m_logger != NULL)
            m_logger.Log(LOG_INFO, StringFormat("Retry %d/%d for partial close #%d %.2f lots",
                         attempt, m_max_retries, ticket, volume));
         Backoff(attempt);
      }

      // Re-verify position
      if(!PositionSelectByTicket(ticket))
         return false;

      bool result = m_trade.PositionClosePartial(ticket, volume);
      uint retcode = m_trade.ResultRetcode();
      LogRetcode("PartialClose", retcode);

      if(result && (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED))
      {
         if(m_logger != NULL)
            m_logger.LogTrade(LOG_PARTIAL_CLOSE, ticket, volume,
                             m_trade.ResultPrice(),
                             StringFormat("Partial close %.2f of %.2f lots",
                                         volume, current_volume));
         return true;
      }

      if(!IsRetryableError(retcode))
         return false;
   }

   if(m_logger != NULL)
      m_logger.Log(LOG_ERROR, StringFormat("All retries exhausted for partial close #%d", ticket));
   return false;
}

//+------------------------------------------------------------------+
bool CPositionManager::IsPositionOpen(ulong ticket)
{
   return PositionSelectByTicket(ticket);
}

//+------------------------------------------------------------------+
double CPositionManager::GetPositionVolume(ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
      return 0.0;
   return PositionGetDouble(POSITION_VOLUME);
}

//+------------------------------------------------------------------+
double CPositionManager::GetPositionProfit(ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
      return 0.0;
   return PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
}

//+------------------------------------------------------------------+
void CPositionManager::LogRetcode(string operation, uint retcode)
{
   if(m_logger == NULL) return;

   if(retcode != TRADE_RETCODE_DONE && retcode != TRADE_RETCODE_PLACED)
   {
      m_logger.Log(LOG_ERROR, StringFormat("%s retcode=%d: %s",
                   operation, retcode, m_trade.ResultComment()));
   }
}

//+------------------------------------------------------------------+
void CPositionManager::Backoff(int attempt)
{
   // Exponential backoff: base * 2^(attempt-1)
   int wait_ms = m_base_backoff_ms * (int)MathPow(2, attempt - 1);
   Sleep(wait_ms);
}

//+------------------------------------------------------------------+
//| Check if trade error is retryable                                 |
//+------------------------------------------------------------------+
bool IsRetryableError(uint retcode)
{
   switch(retcode)
   {
      case TRADE_RETCODE_REQUOTE:
      case TRADE_RETCODE_REJECT:
      case TRADE_RETCODE_ERROR:
      case TRADE_RETCODE_TIMEOUT:
      case TRADE_RETCODE_PRICE_OFF:
      case TRADE_RETCODE_CONNECTION:
      case TRADE_RETCODE_TOO_MANY_REQUESTS:
         return true;

      // Non-retryable errors
      case TRADE_RETCODE_INVALID:
      case TRADE_RETCODE_INVALID_VOLUME:
      case TRADE_RETCODE_INVALID_PRICE:
      case TRADE_RETCODE_INVALID_STOPS:
      case TRADE_RETCODE_TRADE_DISABLED:
      case TRADE_RETCODE_MARKET_CLOSED:
      case TRADE_RETCODE_NO_MONEY:
      case TRADE_RETCODE_POSITION_CLOSED:
      case TRADE_RETCODE_LIMIT_ORDERS:
      case TRADE_RETCODE_LIMIT_VOLUME:
      case TRADE_RETCODE_HEDGE_PROHIBITED:
         return false;
   }
   return false;
}

#endif // __POSITIONMANAGER_MQH__
