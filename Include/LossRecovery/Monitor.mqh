//+------------------------------------------------------------------+
//|                                                      Monitor.mqh |
//|                         Loss Recovery Strategy - Position Monitor |
//+------------------------------------------------------------------+
#ifndef __MONITOR_MQH__
#define __MONITOR_MQH__

#include <Trade/PositionInfo.mqh>
#include "Defines.mqh"
#include "Utils.mqh"
#include "Logger.mqh"

//+------------------------------------------------------------------+
//| CMonitor - Scans positions for loss thresholds and exposure       |
//+------------------------------------------------------------------+
class CMonitor
{
private:
   CLogger              *m_logger;
   ENUM_THRESHOLD_MODE   m_threshold_mode;
   double                m_loss_threshold;
   double                m_emergency_threshold;
   ulong                 m_magic_filter;     // Only monitor positions with this magic (0 = all)

public:
   CMonitor();
   ~CMonitor();

   void   Init(CLogger *logger,
               ENUM_THRESHOLD_MODE mode,
               double loss_threshold,
               double emergency_threshold,
               ulong magic_filter = 0);

   //--- Threshold checks
   bool   CheckTrigger(SPositionInfo &worst_position);
   bool   CheckEmergency();

   //--- Position scanning
   double GetAccountFloatingPnL();
   double GetNetExposure(string symbol);
   double GetSymbolFloatingPnL(string symbol, ulong magic = 0);
   int    GetPositionCount(ulong magic = 0);

   //--- Find specific positions
   bool   FindWorstPosition(SPositionInfo &pos);
   void   ScanPositionsByMagic(ulong magic, SPositionInfo &positions[], int &count);

private:
   double GetThresholdValue();
   double GetEmergencyValue();
};

//+------------------------------------------------------------------+
CMonitor::CMonitor()
{
   m_logger = NULL;
   m_threshold_mode = THRESHOLD_USD;
   m_loss_threshold = -200.0;
   m_emergency_threshold = -500.0;
   m_magic_filter = 0;
}

//+------------------------------------------------------------------+
CMonitor::~CMonitor()
{
}

//+------------------------------------------------------------------+
void CMonitor::Init(CLogger *logger,
                    ENUM_THRESHOLD_MODE mode,
                    double loss_threshold,
                    double emergency_threshold,
                    ulong magic_filter)
{
   m_logger = logger;
   m_threshold_mode = mode;
   m_loss_threshold = loss_threshold;
   m_emergency_threshold = emergency_threshold;
   m_magic_filter = magic_filter;
}

//+------------------------------------------------------------------+
//| Check if any position exceeds loss threshold                      |
//+------------------------------------------------------------------+
bool CMonitor::CheckTrigger(SPositionInfo &worst_position)
{
   double threshold = GetThresholdValue();

   worst_position.Reset();
   double worst_pnl = 0;
   bool found = false;

   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      // Filter by magic if set
      if(m_magic_filter > 0)
      {
         ulong pos_magic = (ulong)PositionGetInteger(POSITION_MAGIC);
         if(pos_magic != m_magic_filter) continue;
      }

      // Skip positions already managed by recovery (hedge/averaging)
      ulong pos_magic = (ulong)PositionGetInteger(POSITION_MAGIC);
      if(pos_magic == MAGIC_HEDGE || pos_magic == MAGIC_AVERAGING)
         continue;

      double pnl = PositionGetDouble(POSITION_PROFIT) +
                   PositionGetDouble(POSITION_SWAP);

      if(pnl < worst_pnl)
      {
         worst_pnl = pnl;
         worst_position.ticket     = ticket;
         worst_position.symbol     = PositionGetString(POSITION_SYMBOL);
         worst_position.direction  = PositionTypeToDirection(
                                       (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE));
         worst_position.volume     = PositionGetDouble(POSITION_VOLUME);
         worst_position.open_price = PositionGetDouble(POSITION_PRICE_OPEN);
         worst_position.pnl        = pnl;
         found = true;
      }
   }

   if(found && worst_pnl <= threshold)
   {
      if(m_logger != NULL)
         m_logger.Log(LOG_TRIGGER, StringFormat(
            "Loss threshold breached: %.2f <= %.2f | ticket=#%d %s %.2f lots",
            worst_pnl, threshold,
            worst_position.ticket, worst_position.symbol,
            worst_position.volume));
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Check if equity drop exceeds emergency threshold                  |
//+------------------------------------------------------------------+
bool CMonitor::CheckEmergency()
{
   double emergency = GetEmergencyValue();
   double floating_pnl = GetAccountFloatingPnL();

   if(floating_pnl <= emergency)
   {
      if(m_logger != NULL)
         m_logger.Log(LOG_EMERGENCY, StringFormat(
            "EMERGENCY threshold breached: floating P/L=%.2f <= %.2f",
            floating_pnl, emergency));
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Get total floating P/L across all positions                       |
//+------------------------------------------------------------------+
double CMonitor::GetAccountFloatingPnL()
{
   double total = 0;
   int count = PositionsTotal();
   for(int i = 0; i < count; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      total += PositionGetDouble(POSITION_PROFIT) +
               PositionGetDouble(POSITION_SWAP);
   }
   return total;
}

//+------------------------------------------------------------------+
//| Get net exposure for a symbol (buy_vol - sell_vol)                |
//+------------------------------------------------------------------+
double CMonitor::GetNetExposure(string symbol)
{
   double net = 0;
   int count = PositionsTotal();
   for(int i = 0; i < count; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;

      double vol = PositionGetDouble(POSITION_VOLUME);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(type == POSITION_TYPE_BUY)
         net += vol;
      else
         net -= vol;
   }
   return net;
}

//+------------------------------------------------------------------+
//| Get floating P/L for a specific symbol and magic                  |
//+------------------------------------------------------------------+
double CMonitor::GetSymbolFloatingPnL(string symbol, ulong magic)
{
   double total = 0;
   int count = PositionsTotal();
   for(int i = 0; i < count; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;

      if(magic > 0)
      {
         ulong pos_magic = (ulong)PositionGetInteger(POSITION_MAGIC);
         if(pos_magic != magic) continue;
      }

      total += PositionGetDouble(POSITION_PROFIT) +
               PositionGetDouble(POSITION_SWAP);
   }
   return total;
}

//+------------------------------------------------------------------+
int CMonitor::GetPositionCount(ulong magic)
{
   int total = 0;
   int count = PositionsTotal();
   for(int i = 0; i < count; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      if(magic > 0)
      {
         ulong pos_magic = (ulong)PositionGetInteger(POSITION_MAGIC);
         if(pos_magic != magic) continue;
      }
      total++;
   }
   return total;
}

//+------------------------------------------------------------------+
//| Find the worst losing position (most negative P/L)                |
//+------------------------------------------------------------------+
bool CMonitor::FindWorstPosition(SPositionInfo &pos)
{
   pos.Reset();
   double worst_pnl = 0;
   bool found = false;

   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      ulong pos_magic = (ulong)PositionGetInteger(POSITION_MAGIC);
      if(pos_magic == MAGIC_HEDGE || pos_magic == MAGIC_AVERAGING)
         continue;

      if(m_magic_filter > 0 && pos_magic != m_magic_filter)
         continue;

      double pnl = PositionGetDouble(POSITION_PROFIT) +
                   PositionGetDouble(POSITION_SWAP);

      if(pnl < worst_pnl)
      {
         worst_pnl = pnl;
         pos.ticket     = ticket;
         pos.symbol     = PositionGetString(POSITION_SYMBOL);
         pos.direction  = PositionTypeToDirection(
                            (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE));
         pos.volume     = PositionGetDouble(POSITION_VOLUME);
         pos.open_price = PositionGetDouble(POSITION_PRICE_OPEN);
         pos.pnl        = pnl;
         found = true;
      }
   }

   return found;
}

//+------------------------------------------------------------------+
void CMonitor::ScanPositionsByMagic(ulong magic, SPositionInfo &positions[], int &count)
{
   count = 0;
   ArrayResize(positions, 0);

   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      ulong pos_magic = (ulong)PositionGetInteger(POSITION_MAGIC);
      if(pos_magic != magic) continue;

      count++;
      ArrayResize(positions, count);
      positions[count - 1].ticket     = ticket;
      positions[count - 1].symbol     = PositionGetString(POSITION_SYMBOL);
      positions[count - 1].direction  = PositionTypeToDirection(
                                          (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE));
      positions[count - 1].volume     = PositionGetDouble(POSITION_VOLUME);
      positions[count - 1].open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      positions[count - 1].pnl        = PositionGetDouble(POSITION_PROFIT) +
                                        PositionGetDouble(POSITION_SWAP);
   }
}

//+------------------------------------------------------------------+
//| Get threshold value in absolute USD terms                         |
//+------------------------------------------------------------------+
double CMonitor::GetThresholdValue()
{
   if(m_threshold_mode == THRESHOLD_PERCENT)
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      return -(MathAbs(m_loss_threshold) / 100.0) * equity;
   }
   return m_loss_threshold; // Already negative USD
}

//+------------------------------------------------------------------+
double CMonitor::GetEmergencyValue()
{
   if(m_threshold_mode == THRESHOLD_PERCENT)
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      return -(MathAbs(m_emergency_threshold) / 100.0) * equity;
   }
   return m_emergency_threshold;
}

#endif // __MONITOR_MQH__
