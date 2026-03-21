#ifndef __COPY_RISK_MQH__
#define __COPY_RISK_MQH__

#include "CopyTypes.mqh"

class CRiskManager
  {
private:
   datetime DayStart(const datetime t) const
     {
      MqlDateTime dt;
      TimeToStruct(t,dt);
      dt.hour=0;
      dt.min=0;
      dt.sec=0;
      return(StructToTime(dt));
     }

public:
   double            m_maxDrawdownPercent;
   double            m_dailyLossPercent;
   double            m_maxLotPerTrade;
   int               m_maxOpenPositions;
   double            m_highestEquity;
   double            m_todayStartEquity;
   datetime          m_todayStartTime;

   bool Init(double maxDDPct,double dailyLossPct,double maxLotPerTrade,int maxOpenPositions)
     {
      m_maxDrawdownPercent=maxDDPct;
      m_dailyLossPercent=dailyLossPct;
      m_maxLotPerTrade=maxLotPerTrade;
      m_maxOpenPositions=maxOpenPositions;

      double eq=AccountInfoDouble(ACCOUNT_EQUITY);
      m_highestEquity=eq;
      m_todayStartEquity=eq;
      m_todayStartTime=DayStart(TimeCurrent());
      return(true);
     }

   void UpdateEquityState()
     {
      double eq=AccountInfoDouble(ACCOUNT_EQUITY);
      if(eq>m_highestEquity)
         m_highestEquity=eq;

      datetime currentDayStart=DayStart(TimeCurrent());
      // Reset the daily baseline once at each new server day.
      if(currentDayStart!=m_todayStartTime)
        {
         m_todayStartTime=currentDayStart;
         m_todayStartEquity=eq;
        }
     }

   bool AllowTrade(const CTradeSignal &sig,double lot)
     {
      UpdateEquityState();

      double eq=AccountInfoDouble(ACCOUNT_EQUITY);
      if(m_highestEquity>0.0 && m_maxDrawdownPercent>0.0)
        {
         double ddPct=((m_highestEquity-eq)/m_highestEquity)*100.0;
         if(ddPct>=m_maxDrawdownPercent)
           {
            PrintFormat("[RISK] Blocked signal %s: drawdown %.2f%% >= %.2f%%",sig.signalId,ddPct,m_maxDrawdownPercent);
            return(false);
           }
        }

      if(m_todayStartEquity>0.0 && m_dailyLossPercent>0.0)
        {
         double dailyPct=((eq-m_todayStartEquity)/m_todayStartEquity)*100.0;
         if(dailyPct<=-m_dailyLossPercent)
           {
            PrintFormat("[RISK] Blocked signal %s: daily P/L %.2f%% <= -%.2f%%",sig.signalId,dailyPct,m_dailyLossPercent);
            return(false);
           }
        }

      if(m_maxLotPerTrade>0.0 && lot>m_maxLotPerTrade)
        {
         PrintFormat("[RISK] Blocked signal %s: lot %.2f > max %.2f",sig.signalId,lot,m_maxLotPerTrade);
         return(false);
        }

      int openPositions=PositionsTotal();
      if(m_maxOpenPositions>0 && openPositions>=m_maxOpenPositions)
        {
         PrintFormat("[RISK] Blocked signal %s: open positions %d >= max %d",sig.signalId,openPositions,m_maxOpenPositions);
         return(false);
        }

      return(true);
     }
  };

#endif // __COPY_RISK_MQH__
