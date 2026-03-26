//+------------------------------------------------------------------+
//|                                                  ExitManager.mqh |
//|                         Loss Recovery Strategy - Exit Logic       |
//|                         Partial close, intelligent close, emergency|
//+------------------------------------------------------------------+
#ifndef __EXITMANAGER_MQH__
#define __EXITMANAGER_MQH__

#include "Defines.mqh"
#include "Utils.mqh"
#include "Logger.mqh"
#include "PositionManager.mqh"
#include "RecoverySession.mqh"
#include "HedgeEngine.mqh"

//+------------------------------------------------------------------+
//| CExitManager - Recovery close logic                               |
//+------------------------------------------------------------------+
class CExitManager
{
private:
   CLogger          *m_logger;
   CPositionManager *m_pos_mgr;
   CHedgeEngine     *m_hedge_engine;

   ENUM_CLOSE_STRATEGY m_close_strategy;
   double              m_partial_unit_lot;
   int                 m_n_close_threshold;

public:
   CExitManager();
   ~CExitManager();

   void   Init(CLogger *logger, CPositionManager *pos_mgr, CHedgeEngine *hedge_engine,
               ENUM_CLOSE_STRATEGY strategy, double partial_unit_lot, int n_close_threshold);

   //--- Recovery checks
   bool   CheckRecoveryTarget(CRecoverySession &session);
   double CalculateRecoverableAmount(CRecoverySession &session);

   //--- Partial close execution
   bool   ExecutePartialClose(CRecoverySession &session);

   //--- Intelligent close (first + latest when count > threshold)
   bool   ExecuteIntelligentClose(CRecoverySession &session);

   //--- Cascade close (sequential)
   bool   ExecuteCascadeClose(CRecoverySession &session);

   //--- Full close (all positions)
   bool   ExecuteFullClose(CRecoverySession &session);

   //--- Emergency close (close everything with max effort)
   bool   ExecuteEmergencyClose(CRecoverySession &session);

   //--- Check if recovery is complete
   bool   IsRecoveryComplete(CRecoverySession &session);

private:
   bool   CloseAveragingOrder(CRecoverySession &session, int index);
   bool   PartialCloseLosing(CRecoverySession &session, double lots);
   bool   PartialCloseHedge(CRecoverySession &session, double lots);
   double CalculateLossPerLot(CRecoverySession &session);
   double CalculateCloseLots(double avg_profit, double loss_per_lot, string symbol);
};

//+------------------------------------------------------------------+
CExitManager::CExitManager()
{
   m_logger           = NULL;
   m_pos_mgr          = NULL;
   m_hedge_engine     = NULL;
   m_close_strategy   = CLOSE_INTELLIGENT;
   m_partial_unit_lot = 0.05;
   m_n_close_threshold = 3;
}

//+------------------------------------------------------------------+
CExitManager::~CExitManager()
{
}

//+------------------------------------------------------------------+
void CExitManager::Init(CLogger *logger, CPositionManager *pos_mgr,
                        CHedgeEngine *hedge_engine,
                        ENUM_CLOSE_STRATEGY strategy, double partial_unit_lot,
                        int n_close_threshold)
{
   m_logger            = logger;
   m_pos_mgr           = pos_mgr;
   m_hedge_engine      = hedge_engine;
   m_close_strategy    = strategy;
   m_partial_unit_lot  = partial_unit_lot;
   m_n_close_threshold = n_close_threshold;
}

//+------------------------------------------------------------------+
//| Calculate loss per lot of the losing position                     |
//+------------------------------------------------------------------+
double CExitManager::CalculateLossPerLot(CRecoverySession &session)
{
   if(session.losing_position.volume <= 0) return 0;
   return MathAbs(session.losing_position.pnl) / session.losing_position.volume;
}

//+------------------------------------------------------------------+
//| Calculate how many lots can be closed given avg profit             |
//+------------------------------------------------------------------+
double CExitManager::CalculateCloseLots(double avg_profit, double loss_per_lot,
                                        string symbol)
{
   if(loss_per_lot <= 0) return 0;

   double lots = avg_profit / loss_per_lot;

   // Cap at partial_unit_lot
   lots = MathMin(lots, m_partial_unit_lot);

   return NormalizeLot(symbol, lots);
}

//+------------------------------------------------------------------+
//| Check if averaging profit is enough to cover partial close cost   |
//+------------------------------------------------------------------+
bool CExitManager::CheckRecoveryTarget(CRecoverySession &session)
{
   session.UpdateLivePnL();

   double avg_pnl = session.GetTotalAveragingPnL();
   if(avg_pnl <= 0) return false;

   double loss_per_lot = CalculateLossPerLot(session);
   if(loss_per_lot <= 0) return false;

   // Calculate minimum profit needed to close partial_unit_lot
   double min_profit = loss_per_lot * m_partial_unit_lot * 1.05; // 5% buffer

   return (avg_pnl >= min_profit);
}

//+------------------------------------------------------------------+
//| Calculate total recoverable amount from current averaging profits |
//+------------------------------------------------------------------+
double CExitManager::CalculateRecoverableAmount(CRecoverySession &session)
{
   session.UpdateLivePnL();
   double avg_pnl = session.GetTotalAveragingPnL();
   double loss_per_lot = CalculateLossPerLot(session);

   if(loss_per_lot <= 0 || avg_pnl <= 0) return 0;

   double closeable = avg_pnl / loss_per_lot;
   return closeable;
}

//+------------------------------------------------------------------+
//| Execute partial close based on configured strategy                |
//+------------------------------------------------------------------+
bool CExitManager::ExecutePartialClose(CRecoverySession &session)
{
   switch(m_close_strategy)
   {
      case CLOSE_INTELLIGENT:
         if(session.GetActiveAveragingCount() > m_n_close_threshold)
            return ExecuteIntelligentClose(session);
         else
            return ExecuteCascadeClose(session);

      case CLOSE_CASCADE:
         return ExecuteCascadeClose(session);

      case CLOSE_ALL:
         return ExecuteFullClose(session);
   }

   return false;
}

//+------------------------------------------------------------------+
//| Intelligent close: close first + latest averaging orders           |
//| Then partial close losing + hedge by calculated amount            |
//+------------------------------------------------------------------+
bool CExitManager::ExecuteIntelligentClose(CRecoverySession &session)
{
   session.UpdateLivePnL();

   int active_count = session.GetActiveAveragingCount();
   if(active_count <= m_n_close_threshold)
   {
      if(m_logger != NULL)
         m_logger.Log(LOG_INFO, StringFormat(
            "Active averaging count %d <= threshold %d, using cascade instead",
            active_count, m_n_close_threshold));
      return ExecuteCascadeClose(session);
   }

   // Find first (oldest) and last (newest) active averaging orders
   int first_idx = session.FindOldestActiveOrder();
   int last_idx  = session.FindNewestActiveOrder();

   if(first_idx < 0 || last_idx < 0 || first_idx == last_idx)
      return false;

   // Calculate combined profit from these two orders
   double first_profit = session.averaging_orders[first_idx].pnl;
   double last_profit  = session.averaging_orders[last_idx].pnl;
   double combined_profit = first_profit + last_profit;

   if(combined_profit <= 0)
   {
      if(m_logger != NULL)
         m_logger.Log(LOG_INFO, StringFormat(
            "Combined profit of first(%.2f) + last(%.2f) = %.2f <= 0, skipping",
            first_profit, last_profit, combined_profit));
      return false;
   }

   // Calculate how many lots of the losing position we can close
   double loss_per_lot = CalculateLossPerLot(session);
   string symbol = session.losing_position.symbol;
   double close_lots = CalculateCloseLots(combined_profit, loss_per_lot, symbol);

   if(close_lots <= 0)
   {
      if(m_logger != NULL)
         m_logger.Log(LOG_INFO, "Calculated close lots <= 0, insufficient profit");
      return false;
   }

   if(m_logger != NULL)
      m_logger.Log(LOG_INFO, StringFormat(
         "Intelligent close: closing avg orders #%d(step %d) + #%d(step %d), "
         "profit=%.2f, partial close=%.2f lots",
         session.averaging_orders[first_idx].ticket,
         session.averaging_orders[first_idx].step,
         session.averaging_orders[last_idx].ticket,
         session.averaging_orders[last_idx].step,
         combined_profit, close_lots));

   // Step 1: Close the two averaging orders
   bool ok1 = CloseAveragingOrder(session, first_idx);
   bool ok2 = CloseAveragingOrder(session, last_idx);

   if(!ok1 && !ok2)
   {
      if(m_logger != NULL)
         m_logger.Log(LOG_ERROR, "Failed to close both averaging orders");
      return false;
   }

   // Step 2: Partial close the losing position
   bool ok3 = PartialCloseLosing(session, close_lots);

   // Step 3: Partial close the hedge to maintain lock ratio
   bool ok4 = PartialCloseHedge(session, close_lots);

   // Update metrics
   double recovered = combined_profit - (close_lots * loss_per_lot);
   session.metrics.partial_close_count++;
   session.metrics.total_recovered += MathMax(recovered, 0);
   session.metrics.time_updated = TimeCurrent();

   if(m_logger != NULL)
      m_logger.Log(LOG_PARTIAL_CLOSE, StringFormat(
         "Intelligent close complete: recovered=%.2f, total_recovered=%.2f, "
         "losing_vol=%.2f, hedge_vol=%.2f, active_avg=%d",
         recovered, session.metrics.total_recovered,
         session.losing_position.volume, session.hedge_position.volume,
         session.GetActiveAveragingCount()));

   return true;
}

//+------------------------------------------------------------------+
//| Cascade close: close averaging orders sequentially (oldest first) |
//+------------------------------------------------------------------+
bool CExitManager::ExecuteCascadeClose(CRecoverySession &session)
{
   session.UpdateLivePnL();

   int first_idx = session.FindOldestActiveOrder();
   if(first_idx < 0) return false;

   double profit = session.averaging_orders[first_idx].pnl;
   if(profit <= 0) return false;

   double loss_per_lot = CalculateLossPerLot(session);
   string symbol = session.losing_position.symbol;
   double close_lots = CalculateCloseLots(profit, loss_per_lot, symbol);

   if(close_lots <= 0) return false;

   if(m_logger != NULL)
      m_logger.Log(LOG_INFO, StringFormat(
         "Cascade close: closing avg order #%d(step %d), profit=%.2f, "
         "partial close=%.2f lots",
         session.averaging_orders[first_idx].ticket,
         session.averaging_orders[first_idx].step,
         profit, close_lots));

   // Close the averaging order
   bool ok1 = CloseAveragingOrder(session, first_idx);
   if(!ok1) return false;

   // Partial close losing + hedge
   PartialCloseLosing(session, close_lots);
   PartialCloseHedge(session, close_lots);

   // Update metrics
   session.metrics.partial_close_count++;
   session.metrics.total_recovered += MathMax(profit - close_lots * loss_per_lot, 0);
   session.metrics.time_updated = TimeCurrent();

   return true;
}

//+------------------------------------------------------------------+
//| Full close: close all averaging orders, hedge, and losing         |
//+------------------------------------------------------------------+
bool CExitManager::ExecuteFullClose(CRecoverySession &session)
{
   if(m_logger != NULL)
      m_logger.Log(LOG_FULL_CLOSE, "Executing full close of all session positions");

   bool all_ok = true;

   // Close all averaging orders (newest first to reduce exposure gradually)
   for(int i = ArraySize(session.averaging_orders) - 1; i >= 0; i--)
   {
      if(!session.averaging_orders[i].is_closed &&
         session.averaging_orders[i].ticket > 0)
      {
         if(!CloseAveragingOrder(session, i))
            all_ok = false;
      }
   }

   // Close hedge
   if(session.hedge_position.ticket > 0 &&
      m_pos_mgr.IsPositionOpen(session.hedge_position.ticket))
   {
      if(!m_pos_mgr.ClosePosition(session.hedge_position.ticket))
      {
         if(m_logger != NULL)
            m_logger.Log(LOG_ERROR, "Failed to close hedge position #" +
                         IntegerToString(session.hedge_position.ticket));
         all_ok = false;
      }
      else
      {
         session.hedge_position.volume = 0;
      }
   }

   // Close losing position
   if(session.losing_position.ticket > 0 &&
      m_pos_mgr.IsPositionOpen(session.losing_position.ticket))
   {
      if(!m_pos_mgr.ClosePosition(session.losing_position.ticket))
      {
         if(m_logger != NULL)
            m_logger.Log(LOG_ERROR, "Failed to close losing position #" +
                         IntegerToString(session.losing_position.ticket));
         all_ok = false;
      }
      else
      {
         session.losing_position.volume = 0;
      }
   }

   return all_ok;
}

//+------------------------------------------------------------------+
//| Emergency close: maximum effort to close everything               |
//+------------------------------------------------------------------+
bool CExitManager::ExecuteEmergencyClose(CRecoverySession &session)
{
   if(m_logger != NULL)
      m_logger.Log(LOG_EMERGENCY, "!!! EMERGENCY CLOSE - Closing all positions !!!");

   bool all_ok = true;

   // Close averaging orders (newest first)
   for(int i = ArraySize(session.averaging_orders) - 1; i >= 0; i--)
   {
      if(!session.averaging_orders[i].is_closed &&
         session.averaging_orders[i].ticket > 0)
      {
         if(m_pos_mgr.IsPositionOpen(session.averaging_orders[i].ticket))
         {
            if(!m_pos_mgr.ClosePosition(session.averaging_orders[i].ticket))
               all_ok = false;
            else
               session.averaging_orders[i].is_closed = true;
         }
         else
         {
            session.averaging_orders[i].is_closed = true;
         }
      }
   }

   // Close hedge
   if(session.hedge_position.ticket > 0)
   {
      if(m_pos_mgr.IsPositionOpen(session.hedge_position.ticket))
      {
         if(!m_pos_mgr.ClosePosition(session.hedge_position.ticket))
            all_ok = false;
         else
            session.hedge_position.volume = 0;
      }
      else
      {
         session.hedge_position.volume = 0;
      }
   }

   // Close losing position
   if(session.losing_position.ticket > 0)
   {
      if(m_pos_mgr.IsPositionOpen(session.losing_position.ticket))
      {
         if(!m_pos_mgr.ClosePosition(session.losing_position.ticket))
            all_ok = false;
         else
            session.losing_position.volume = 0;
      }
      else
      {
         session.losing_position.volume = 0;
      }
   }

   if(m_logger != NULL)
   {
      if(all_ok)
         m_logger.Log(LOG_EMERGENCY, "Emergency close completed successfully");
      else
         m_logger.Log(LOG_ERROR, "Emergency close had failures - some positions may remain open");
   }

   return all_ok;
}

//+------------------------------------------------------------------+
//| Check if recovery is complete (all or enough closed)              |
//+------------------------------------------------------------------+
bool CExitManager::IsRecoveryComplete(CRecoverySession &session)
{
   // Recovery is complete when:
   // 1. Losing position volume is zero (fully closed)
   // 2. Or there are no more active averaging orders to use
   // 3. Or remaining loss is near zero

   if(session.losing_position.volume <= 0)
      return true;

   if(!m_pos_mgr.IsPositionOpen(session.losing_position.ticket))
      return true;

   // Check remaining volume
   double remaining = m_pos_mgr.GetPositionVolume(session.losing_position.ticket);
   double min_lot = SymbolInfoDouble(session.losing_position.symbol, SYMBOL_VOLUME_MIN);

   if(remaining <= min_lot && session.GetActiveAveragingCount() == 0)
      return true;

   return false;
}

//+------------------------------------------------------------------+
//| Close a specific averaging order by index                         |
//+------------------------------------------------------------------+
bool CExitManager::CloseAveragingOrder(CRecoverySession &session, int index)
{
   if(index < 0 || index >= ArraySize(session.averaging_orders))
      return false;

   if(session.averaging_orders[index].is_closed)
      return true;

   ulong ticket = session.averaging_orders[index].ticket;
   if(ticket == 0) return false;

   if(!m_pos_mgr.IsPositionOpen(ticket))
   {
      session.averaging_orders[index].is_closed = true;
      return true;
   }

   if(m_pos_mgr.ClosePosition(ticket))
   {
      session.averaging_orders[index].is_closed = true;

      if(m_logger != NULL)
         m_logger.LogTrade(LOG_FULL_CLOSE, ticket,
                          session.averaging_orders[index].volume,
                          0, StringFormat("Averaging order step %d closed, pnl=%.2f",
                                         session.averaging_orders[index].step,
                                         session.averaging_orders[index].pnl));
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Partial close the losing position                                 |
//+------------------------------------------------------------------+
bool CExitManager::PartialCloseLosing(CRecoverySession &session, double lots)
{
   if(session.losing_position.ticket == 0) return false;

   lots = NormalizeLot(session.losing_position.symbol, lots);
   if(lots <= 0) return false;

   bool result = m_pos_mgr.PartialClose(session.losing_position.ticket, lots);

   if(result)
   {
      // Update volume from live position
      double new_vol = m_pos_mgr.GetPositionVolume(session.losing_position.ticket);
      session.losing_position.volume = new_vol;

      if(m_logger != NULL)
         m_logger.LogTrade(LOG_PARTIAL_CLOSE,
            session.losing_position.ticket, lots, 0,
            StringFormat("Losing position partial close: %.2f lots, remaining=%.2f",
                         lots, new_vol));
   }

   return result;
}

//+------------------------------------------------------------------+
//| Partial close the hedge position to maintain lock ratio           |
//+------------------------------------------------------------------+
bool CExitManager::PartialCloseHedge(CRecoverySession &session, double lots)
{
   if(session.hedge_position.ticket == 0) return false;

   lots = NormalizeLot(session.hedge_position.symbol, lots);
   if(lots <= 0) return false;

   bool result = m_pos_mgr.PartialClose(session.hedge_position.ticket, lots);

   if(result)
   {
      double new_vol = m_pos_mgr.GetPositionVolume(session.hedge_position.ticket);
      session.hedge_position.volume = new_vol;

      if(m_logger != NULL)
         m_logger.LogTrade(LOG_PARTIAL_CLOSE,
            session.hedge_position.ticket, lots, 0,
            StringFormat("Hedge partial close: %.2f lots, remaining=%.2f",
                         lots, new_vol));
   }

   return result;
}

#endif // __EXITMANAGER_MQH__
