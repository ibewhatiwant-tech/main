#ifndef __COPY_ALLOCATION_MQH__
#define __COPY_ALLOCATION_MQH__

#include "CopyTypes.mqh"

enum AllocationMode
  {
   ALLOC_FIXED_LOT=0,
   ALLOC_MULTIPLIER=1,
   ALLOC_RISK_PERCENT=2
  };

class CAllocationEngine
  {
private:
   AllocationMode    m_mode;
   double            m_fixedLot;
   double            m_multiplier;
   double            m_riskPercent;
   double            m_maxLot;
   string            m_symbol;
   double            m_brokerMinLot;
   double            m_brokerMaxLot;
   double            m_brokerLotStep;

   int StepDigits(const double step) const
     {
      int d=0;
      double s=step;
      while(d<8 && s<1.0)
        {
         s*=10.0;
         d++;
        }
      return(d);
     }

   double ClampAndNormalize(const double lot) const
     {
      double v=lot;
      if(v<0.0)
         v=0.0;

      double localMax=m_maxLot;
      if(localMax<=0.0)
         localMax=m_brokerMaxLot;

      if(localMax>0.0 && v>localMax)
         v=localMax;
      if(m_brokerMaxLot>0.0 && v>m_brokerMaxLot)
         v=m_brokerMaxLot;

      if(m_brokerLotStep<=0.0)
         return(v);

      v=MathFloor(v/m_brokerLotStep)*m_brokerLotStep;
      if(v>0.0 && v<m_brokerMinLot)
         v=m_brokerMinLot;

      int digits=StepDigits(m_brokerLotStep);
      return(NormalizeDouble(v,digits));
     }

public:
   bool Init(AllocationMode mode,double fixedLot,double multiplier,double riskPercent,double maxLot)
     {
      m_mode=mode;
      m_fixedLot=fixedLot;
      m_multiplier=multiplier;
      m_riskPercent=riskPercent;
      m_maxLot=maxLot;
      m_symbol=_Symbol;

      // Assumption for v1: cache broker volume limits from chart symbol at init.
      if(!SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_MIN,m_brokerMinLot))
         m_brokerMinLot=0.01;
      if(!SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_MAX,m_brokerMaxLot))
         m_brokerMaxLot=100.0;
      if(!SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_STEP,m_brokerLotStep))
         m_brokerLotStep=0.01;

      return(true);
     }

   double CalculateLot(const CTradeSignal &sig)
     {
      double lot=0.0;

      if(m_mode==ALLOC_FIXED_LOT)
        {
         lot=m_fixedLot;
        }
      else
         if(m_mode==ALLOC_MULTIPLIER)
           {
            lot=sig.volume*m_multiplier;
           }
         else // ALLOC_RISK_PERCENT
           {
            if(sig.stopLoss!=0.0 && sig.price>0.0)
              {
               string sym=sig.symbol;
               if(StringLen(sym)<=0)
                  sym=_Symbol;

               double point=0.0;
               double tickValue=0.0;
               double tickSize=0.0;
               SymbolInfoDouble(sym,SYMBOL_POINT,point);
               SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_VALUE,tickValue);
               SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_SIZE,tickSize);

               if(point>0.0 && tickValue>0.0 && tickSize>0.0)
                 {
                  double slPoints=MathAbs(sig.price-sig.stopLoss)/point;
                  double valuePerPoint=tickValue*(point/tickSize);
                  double equity=AccountInfoDouble(ACCOUNT_EQUITY);
                  double riskAmount=equity*(m_riskPercent/100.0);
                  double riskPerLot=slPoints*valuePerPoint;

                  if(riskPerLot>0.0)
                     lot=riskAmount/riskPerLot;
                 }
              }

            // Assumption for v1: if SL is unavailable, fallback to fixed lot.
            if(lot<=0.0)
               lot=m_fixedLot;
           }

      return(ClampAndNormalize(lot));
     }
  };

#endif // __COPY_ALLOCATION_MQH__
