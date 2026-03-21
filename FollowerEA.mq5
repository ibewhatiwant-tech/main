#property strict
#property version   "1.00"

#include "CopyTypes.mqh"
#include "CopyBus.mqh"
#include "CopyAllocation.mqh"
#include "CopyRisk.mqh"

input string InpBusPrefix = "COPY";
input int    InpPollIntervalMs = 200;
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_CURRENT;

input int    InpAllocationMode = ALLOC_FIXED_LOT;
input double InpFixedLot = 0.10;
input double InpMultiplier = 1.0;
input double InpRiskPercent = 1.0;
input double InpMaxLot = 5.0;

input double InpMaxDDPercent = 20.0;
input double InpDailyLossPercent = 5.0;
input double InpMaxLotPerTrade = 2.0;
input int    InpMaxOpenPositions = 50;

CSignalBusFollower g_bus;
CAllocationEngine  g_alloc;
CRiskManager       g_risk;
ulong              g_lastSeqProcessed=0;

struct FollowerMetrics
  {
   ulong             totalSignalsRead;
   ulong             lastSeq;
   double            avgLatencyMs;
   int               maxSignalsPerCycle;
   datetime          lastLogTime;
  };

FollowerMetrics g_metrics;

string ActionToText(const int action)
  {
   switch(action)
     {
      case ACTION_BUY:        return("BUY");
      case ACTION_SELL:       return("SELL");
      case ACTION_BUY_LIMIT:  return("BUY_LIMIT");
      case ACTION_SELL_LIMIT: return("SELL_LIMIT");
      case ACTION_BUY_STOP:   return("BUY_STOP");
      case ACTION_SELL_STOP:  return("SELL_STOP");
      default:                return("UNKNOWN");
     }
  }

int OnInit()
  {
   if(!g_bus.Init(InpBusPrefix))
      return(INIT_FAILED);

   g_lastSeqProcessed=0;

   if(!g_alloc.Init((AllocationMode)InpAllocationMode,InpFixedLot,InpMultiplier,InpRiskPercent,InpMaxLot))
      return(INIT_FAILED);

   if(!g_risk.Init(InpMaxDDPercent,InpDailyLossPercent,InpMaxLotPerTrade,InpMaxOpenPositions))
      return(INIT_FAILED);

   int intervalMs=InpPollIntervalMs;
   if(intervalMs<50)
      intervalMs=50;
   EventSetMillisecondTimer(intervalMs);

   g_metrics.totalSignalsRead=0;
   g_metrics.lastSeq=0;
   g_metrics.avgLatencyMs=0.0;
   g_metrics.maxSignalsPerCycle=0;
   g_metrics.lastLogTime=0;

   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
  }

void OnTimer()
  {
   g_risk.UpdateEquityState();

   string signals[];
   ulong fromSeq=g_lastSeqProcessed;
   ulong toSeq=0;

   int count=g_bus.FetchNew(signals,fromSeq,toSeq,20);
   if(count<=0)
      return;

   int signalsThisCycle=0;

   for(int i=0;i<count;i++)
     {
      CTradeSignal sig;
      if(!StringToTradeSignal(signals[i],sig))
        {
         PrintFormat("[FOLLOWER] Failed to parse signal payload: idx=%d",i);
         continue;
        }

      signalsThisCycle++;
      g_metrics.totalSignalsRead++;

      if(sig.timestamp>0)
        {
         double latencyMs=(double)(TimeCurrent()-sig.timestamp)*1000.0;
         // EMA for low-cost latency smoothing.
         if(g_metrics.avgLatencyMs<=0.0)
            g_metrics.avgLatencyMs=latencyMs;
         else
            g_metrics.avgLatencyMs=(0.2*latencyMs)+(0.8*g_metrics.avgLatencyMs);
        }

      double lot=g_alloc.CalculateLot(sig);
      if(lot<=0.0)
        {
         PrintFormat("[FOLLOWER] Skip signal %s: calculated lot <= 0",sig.signalId);
         continue;
        }

      if(!g_risk.AllowTrade(sig,lot))
         continue;

      PrintFormat("[FOLLOWER] Would replicate type=%d action=%s symbol=%s lot=%.2f price=%.5f masterTicket=%I64u",
                  sig.tradeType,ActionToText(sig.action),sig.symbol,lot,sig.price,sig.orderTicket);

      // v1 assumption: order placement/mapping intentionally deferred.
     }

   g_lastSeqProcessed=fromSeq;
   g_metrics.lastSeq=g_lastSeqProcessed;

   if(signalsThisCycle>g_metrics.maxSignalsPerCycle)
      g_metrics.maxSignalsPerCycle=signalsThisCycle;

   datetime now=TimeCurrent();
   if(g_metrics.lastLogTime==0 || (now-g_metrics.lastLogTime)>=10)
     {
      PrintFormat("[FOLLOWER_METRICS] total=%I64u avgLatencyMs=%.2f maxPerCycle=%d lastSeq=%I64u",
                  g_metrics.totalSignalsRead,g_metrics.avgLatencyMs,g_metrics.maxSignalsPerCycle,g_metrics.lastSeq);
      g_metrics.lastLogTime=now;
     }
  }
