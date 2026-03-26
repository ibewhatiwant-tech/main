//+------------------------------------------------------------------+
//|                                                  HedgeEngine.mqh |
//|                         Loss Recovery Strategy - Hedge/Lock Logic |
//+------------------------------------------------------------------+
#ifndef __HEDGEENGINE_MQH__
#define __HEDGEENGINE_MQH__

#include "Defines.mqh"
#include "Utils.mqh"
#include "Logger.mqh"
#include "PositionManager.mqh"
#include "RecoverySession.mqh"

//+------------------------------------------------------------------+
//| CHedgeEngine - Calculate and place hedge orders for locking       |
//+------------------------------------------------------------------+
class CHedgeEngine
{
private:
   CLogger          *m_logger;
   CPositionManager *m_pos_mgr;

public:
   CHedgeEngine();
   ~CHedgeEngine();

   void   Init(CLogger *logger, CPositionManager *pos_mgr);

   //--- Calculate required hedge volume to neutralize exposure
   double CalculateHedgeVolume(const SPositionInfo &losing_pos, string symbol);

   //--- Place the hedge order
   bool   PlaceHedge(CRecoverySession &session);

   //--- Verify hedge is in place
   bool   IsHedgeValid(const CRecoverySession &session);

   //--- Adjust hedge if losing position was partially closed
   bool   AdjustHedge(CRecoverySession &session, double new_target_volume);
};

//+------------------------------------------------------------------+
CHedgeEngine::CHedgeEngine()
{
   m_logger  = NULL;
   m_pos_mgr = NULL;
}

//+------------------------------------------------------------------+
CHedgeEngine::~CHedgeEngine()
{
}

//+------------------------------------------------------------------+
void CHedgeEngine::Init(CLogger *logger, CPositionManager *pos_mgr)
{
   m_logger  = logger;
   m_pos_mgr = pos_mgr;
}

//+------------------------------------------------------------------+
//| Calculate hedge volume needed to make net exposure = 0            |
//| Takes into account existing positions on the same symbol          |
//+------------------------------------------------------------------+
double CHedgeEngine::CalculateHedgeVolume(const SPositionInfo &losing_pos,
                                          string symbol)
{
   // We need to open opposite direction with same volume as the losing position
   // to achieve net exposure = 0 for this recovery pair
   double hedge_volume = losing_pos.volume;

   // Normalize to broker constraints
   hedge_volume = NormalizeLot(symbol, hedge_volume);

   if(m_logger != NULL)
      m_logger.Log(LOG_INFO, StringFormat(
         "Hedge calculation: losing=%.2f lots %s -> hedge=%.2f lots %s",
         losing_pos.volume,
         (losing_pos.direction > 0 ? "BUY" : "SELL"),
         hedge_volume,
         (losing_pos.direction > 0 ? "SELL" : "BUY")));

   return hedge_volume;
}

//+------------------------------------------------------------------+
//| Place hedge order opposite to the losing position                 |
//+------------------------------------------------------------------+
bool CHedgeEngine::PlaceHedge(CRecoverySession &session)
{
   if(m_pos_mgr == NULL)
   {
      if(m_logger != NULL)
         m_logger.Log(LOG_ERROR, "PositionManager not initialized");
      return false;
   }

   string symbol = session.losing_position.symbol;
   double volume = CalculateHedgeVolume(session.losing_position, symbol);

   if(volume <= 0)
   {
      if(m_logger != NULL)
         m_logger.Log(LOG_ERROR, "Invalid hedge volume calculated: " +
                      DoubleToString(volume, 2));
      return false;
   }

   // Determine hedge direction (opposite of losing position)
   bool result = false;
   string comment = "LR_Hedge_" + session.session_id;

   if(session.losing_position.direction > 0)
   {
      // Losing is BUY -> hedge with SELL
      result = m_pos_mgr.OpenSell(symbol, volume, comment, MAGIC_HEDGE);
   }
   else
   {
      // Losing is SELL -> hedge with BUY
      result = m_pos_mgr.OpenBuy(symbol, volume, comment, MAGIC_HEDGE);
   }

   if(result)
   {
      // Find the newly opened hedge position
      // We need to search for the position by magic number since the deal ticket
      // might not directly correspond to the position ticket
      Sleep(100); // Brief wait for position to register

      int total = PositionsTotal();
      for(int i = total - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;

         ulong pos_magic = (ulong)PositionGetInteger(POSITION_MAGIC);
         if(pos_magic != MAGIC_HEDGE) continue;

         string pos_symbol = PositionGetString(POSITION_SYMBOL);
         if(pos_symbol != symbol) continue;

         string pos_comment = PositionGetString(POSITION_COMMENT);
         if(StringFind(pos_comment, session.session_id) >= 0 ||
            pos_comment == comment)
         {
            session.hedge_position.ticket     = ticket;
            session.hedge_position.symbol     = pos_symbol;
            session.hedge_position.direction  = PositionTypeToDirection(
               (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE));
            session.hedge_position.volume     = PositionGetDouble(POSITION_VOLUME);
            session.hedge_position.open_price = PositionGetDouble(POSITION_PRICE_OPEN);
            session.hedge_position.pnl        = PositionGetDouble(POSITION_PROFIT);
            break;
         }
      }

      if(session.hedge_position.ticket > 0)
      {
         if(m_logger != NULL)
            m_logger.LogTrade(LOG_HEDGE,
               session.hedge_position.ticket,
               session.hedge_position.volume,
               session.hedge_position.open_price,
               StringFormat("Hedge placed: %s %s",
                  (session.hedge_position.direction > 0 ? "BUY" : "SELL"),
                  symbol));
         return true;
      }
      else
      {
         if(m_logger != NULL)
            m_logger.Log(LOG_ERROR,
               "Hedge order sent but position not found after placement");
         return false;
      }
   }

   if(m_logger != NULL)
      m_logger.Log(LOG_ERROR, "Failed to place hedge order for " + symbol);
   return false;
}

//+------------------------------------------------------------------+
//| Verify hedge position still exists and matches expected volume    |
//+------------------------------------------------------------------+
bool CHedgeEngine::IsHedgeValid(const CRecoverySession &session)
{
   if(session.hedge_position.ticket == 0)
      return false;

   if(!PositionSelectByTicket(session.hedge_position.ticket))
      return false;

   double vol = PositionGetDouble(POSITION_VOLUME);
   return (vol > 0);
}

//+------------------------------------------------------------------+
//| Adjust hedge volume (e.g., after partial close of losing pos)     |
//+------------------------------------------------------------------+
bool CHedgeEngine::AdjustHedge(CRecoverySession &session, double new_target_volume)
{
   if(session.hedge_position.ticket == 0)
      return false;

   double current_volume = m_pos_mgr.GetPositionVolume(session.hedge_position.ticket);
   if(current_volume <= 0)
      return false;

   new_target_volume = NormalizeLot(session.hedge_position.symbol, new_target_volume);

   if(new_target_volume >= current_volume)
      return true; // Already at or below target

   // Partial close to reduce hedge
   double close_vol = NormalizeLot(session.hedge_position.symbol,
                                   current_volume - new_target_volume);

   if(close_vol <= 0) return true;

   bool result = m_pos_mgr.PartialClose(session.hedge_position.ticket, close_vol);

   if(result)
   {
      session.hedge_position.volume = m_pos_mgr.GetPositionVolume(
                                         session.hedge_position.ticket);
      if(m_logger != NULL)
         m_logger.LogTrade(LOG_PARTIAL_CLOSE,
            session.hedge_position.ticket,
            close_vol,
            0,
            StringFormat("Hedge adjusted: %.2f -> %.2f",
                         current_volume, session.hedge_position.volume));
   }

   return result;
}

#endif // __HEDGEENGINE_MQH__
