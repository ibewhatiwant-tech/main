
//+------------------------------------------------------------------+
// EA_CODE_SKELETON.mq5
// Institutional Prop-Safe EA Framework Skeleton
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

CTrade trade;

input double BaseLot = 0.01;
input double MaxSpread = 50;

bool SpreadGate()
{
   double spread=(SymbolInfoDouble(_Symbol,SYMBOL_ASK)-SymbolInfoDouble(_Symbol,SYMBOL_BID))/_Point;
   if(spread>MaxSpread)
   {
      Print("Spread gate triggered");
      return false;
   }
   return true;
}

void StrategyLogic()
{
   // placeholder for signals
}

void OnTick()
{
   if(!SpreadGate())
      return;

   StrategyLogic();
}
