//+------------------------------------------------------------------+
//| CopyTrading/PerformanceTracker.mqh                               |
//| Performance metrics and statistics tracking                      |
//+------------------------------------------------------------------+
#pragma once
#include "Defines.mqh"
#include "Logger.mqh"

//+------------------------------------------------------------------+
//| CPerformanceTracker                                              |
//| Tracks lifetime and daily trading statistics for master or       |
//| follower EAs. Persists state to a flat key=value text file so    |
//| metrics survive EA restarts.                                     |
//+------------------------------------------------------------------+
class CPerformanceTracker
  {
private:
   //--- Lifetime statistics
   int               m_totalTrades;
   int               m_winTrades;
   int               m_loseTrades;
   int               m_breakEvenTrades;
   double            m_grossProfit;
   double            m_grossLoss;
   double            m_maxDrawdown;        // Peak-to-trough in account currency
   double            m_maxDrawdownPct;     // Peak-to-trough as a percentage
   double            m_highestEquity;
   double            m_lowestEquity;
   double            m_startEquity;
   double            m_startBalance;
   datetime          m_startDate;

   //--- Today's statistics
   int               m_todayTrades;
   int               m_todayWins;
   int               m_todayLosses;
   double            m_todayProfit;
   datetime          m_todayDate;         // Midnight timestamp of the current day

   //--- Copy-trading specific (meaningful for follower trackers)
   int               m_tradesCopied;
   int               m_tradesSkipped;
   int               m_tradesFailed;
   double            m_totalSlippage;     // Cumulative slippage in pips
   int               m_slippageCount;    // Number of slippage samples

   //--- Recent trade history — circular buffer of last 100 PnL values
   double            m_tradeResults[100];
   int               m_tradeResultsHead; // Next write position
   int               m_tradeResultsCount;// Number of entries stored (max 100)

   //--- Infrastructure
   string            m_statsFile;        // Full path for persistence
   CLogger          *m_logger;
   bool              m_isMaster;

   //--- Private helpers
   void              AddTradeResult(double pnl);
   void              UpdateTodayStats(double pnl, datetime closeTime);
   void              CheckDayRollover();
   void              UpdateDrawdown(double equity);
   string            DoubleToStr2(double value) const;

public:
                     CPerformanceTracker();

   //--- Lifecycle
   bool              Init(CLogger *logger, string accountId, bool isMaster);

   //--- Trade event hooks
   void              OnTradeOpen();
   void              OnTradeClose(double pnl, datetime closeTime);
   void              OnTick();

   //--- Copy-trading event recording
   void              RecordTradeCopied(double slippagePips);
   void              RecordTradeSkipped();
   void              RecordTradeFailed();

   //--- Computed statistics
   double            GetWinRate() const;
   double            GetProfitFactor() const;
   double            GetNetProfit() const;
   double            GetCurrentEquity() const;
   double            GetCurrentPnLPct() const;
   double            GetAverageSlippage() const;
   double            GetMaxDrawdownPct() const;
   int               GetTodayTrades() const;
   double            GetTodayProfit() const;

   //--- Raw getters
   int               GetTotalTrades() const    { return m_totalTrades;    }
   int               GetWinTrades() const      { return m_winTrades;      }
   int               GetLoseTrades() const     { return m_loseTrades;     }
   double            GetGrossProfit() const    { return m_grossProfit;    }
   double            GetGrossLoss() const      { return m_grossLoss;      }
   double            GetMaxDrawdown() const    { return m_maxDrawdown;    }
   int               GetTradesCopied() const   { return m_tradesCopied;   }
   int               GetTradesSkipped() const  { return m_tradesSkipped;  }
   int               GetTradesFailed() const   { return m_tradesFailed;   }
   double            GetStartEquity() const    { return m_startEquity;    }
   double            GetHighestEquity() const  { return m_highestEquity;  }

   //--- Persistence
   void              SaveToFile();
   void              LoadFromFile();

   //--- Display
   string            GetSummary() const;
  };

//+------------------------------------------------------------------+
//| Constructor — zero-initialise all members                        |
//+------------------------------------------------------------------+
CPerformanceTracker::CPerformanceTracker()
  {
   m_totalTrades       = 0;
   m_winTrades         = 0;
   m_loseTrades        = 0;
   m_breakEvenTrades   = 0;
   m_grossProfit       = 0.0;
   m_grossLoss         = 0.0;
   m_maxDrawdown       = 0.0;
   m_maxDrawdownPct    = 0.0;
   m_highestEquity     = 0.0;
   m_lowestEquity      = 0.0;
   m_startEquity       = 0.0;
   m_startBalance      = 0.0;
   m_startDate         = 0;

   m_todayTrades       = 0;
   m_todayWins         = 0;
   m_todayLosses       = 0;
   m_todayProfit       = 0.0;
   m_todayDate         = 0;

   m_tradesCopied      = 0;
   m_tradesSkipped     = 0;
   m_tradesFailed      = 0;
   m_totalSlippage     = 0.0;
   m_slippageCount     = 0;

   ArrayInitialize(m_tradeResults, 0.0);
   m_tradeResultsHead  = 0;
   m_tradeResultsCount = 0;

   m_statsFile         = "";
   m_logger            = NULL;
   m_isMaster          = true;
  }

//+------------------------------------------------------------------+
//| Initialise the tracker for a given account                       |
//+------------------------------------------------------------------+
bool CPerformanceTracker::Init(CLogger *logger, string accountId, bool isMaster)
  {
   m_logger   = logger;
   m_isMaster = isMaster;

   m_statsFile = CT_STATE_DIR + CT_STATS_PREFIX + accountId + ".txt";

   m_startEquity   = AccountInfoDouble(ACCOUNT_EQUITY);
   m_startBalance  = AccountInfoDouble(ACCOUNT_BALANCE);
   m_startDate     = TimeCurrent();
   m_highestEquity = m_startEquity;
   m_lowestEquity  = m_startEquity;

   // Floor to the start of the current trading day (D1 bar open time)
   m_todayDate = iTime(NULL, PERIOD_D1, 0);

   // Load persisted stats — may override the defaults set above
   LoadFromFile();

   if(m_logger != NULL)
      m_logger.Info("PerformanceTracker initialised",
                    "account=" + accountId +
                    " isMaster=" + (isMaster ? "true" : "false") +
                    " startEquity=" + DoubleToString(m_startEquity, 2));

   return true;
  }

//+------------------------------------------------------------------+
//| OnTradeOpen — no metrics updated until the trade is closed       |
//+------------------------------------------------------------------+
void CPerformanceTracker::OnTradeOpen()
  {
   // Intentionally empty — stats are recorded on close
  }

//+------------------------------------------------------------------+
//| OnTradeClose — update all counters and persist periodically      |
//+------------------------------------------------------------------+
void CPerformanceTracker::OnTradeClose(double pnl, datetime closeTime)
  {
   m_totalTrades++;

   if(pnl > 0.0)
     {
      m_winTrades++;
      m_grossProfit += pnl;
     }
   else if(pnl < 0.0)
     {
      m_loseTrades++;
      m_grossLoss += MathAbs(pnl);
     }
   else
     {
      m_breakEvenTrades++;
     }

   AddTradeResult(pnl);
   UpdateTodayStats(pnl, closeTime);

   // Update equity-based metrics
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   m_highestEquity = MathMax(m_highestEquity, equity);
   m_lowestEquity  = MathMin(m_lowestEquity,  equity);
   UpdateDrawdown(equity);

   // Persist every 10 trades to limit file I/O
   if(m_totalTrades % 10 == 0)
      SaveToFile();
  }

//+------------------------------------------------------------------+
//| OnTick — update live equity metrics and check day rollover       |
//+------------------------------------------------------------------+
void CPerformanceTracker::OnTick()
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   m_highestEquity = MathMax(m_highestEquity, equity);
   m_lowestEquity  = MathMin(m_lowestEquity,  equity);

   UpdateDrawdown(equity);
   CheckDayRollover();
  }

//+------------------------------------------------------------------+
//| RecordTradeCopied — track successful copy with slippage          |
//+------------------------------------------------------------------+
void CPerformanceTracker::RecordTradeCopied(double slippagePips)
  {
   m_tradesCopied++;
   m_totalSlippage += slippagePips;
   m_slippageCount++;
  }

//+------------------------------------------------------------------+
//| RecordTradeSkipped — trade was valid but intentionally skipped   |
//+------------------------------------------------------------------+
void CPerformanceTracker::RecordTradeSkipped()
  {
   m_tradesSkipped++;
  }

//+------------------------------------------------------------------+
//| RecordTradeFailed — copy attempt ended in an execution error     |
//+------------------------------------------------------------------+
void CPerformanceTracker::RecordTradeFailed()
  {
   m_tradesFailed++;
  }

//+------------------------------------------------------------------+
//| GetWinRate — percentage of winning trades                        |
//+------------------------------------------------------------------+
double CPerformanceTracker::GetWinRate() const
  {
   if(m_totalTrades == 0)
      return 0.0;
   return (double)m_winTrades / (double)m_totalTrades * 100.0;
  }

//+------------------------------------------------------------------+
//| GetProfitFactor — gross profit divided by gross loss             |
//+------------------------------------------------------------------+
double CPerformanceTracker::GetProfitFactor() const
  {
   if(m_grossLoss == 0.0)
      return (m_grossProfit > 0.0 ? 999.0 : 0.0);
   return m_grossProfit / m_grossLoss;
  }

//+------------------------------------------------------------------+
//| GetNetProfit — total realised P&L                                |
//+------------------------------------------------------------------+
double CPerformanceTracker::GetNetProfit() const
  {
   return m_grossProfit - m_grossLoss;
  }

//+------------------------------------------------------------------+
//| GetCurrentEquity — live account equity                           |
//+------------------------------------------------------------------+
double CPerformanceTracker::GetCurrentEquity() const
  {
   return AccountInfoDouble(ACCOUNT_EQUITY);
  }

//+------------------------------------------------------------------+
//| GetCurrentPnLPct — equity change from session start as %        |
//+------------------------------------------------------------------+
double CPerformanceTracker::GetCurrentPnLPct() const
  {
   if(m_startEquity == 0.0)
      return 0.0;
   return (AccountInfoDouble(ACCOUNT_EQUITY) - m_startEquity) / m_startEquity * 100.0;
  }

//+------------------------------------------------------------------+
//| GetAverageSlippage — mean slippage across copied trades          |
//+------------------------------------------------------------------+
double CPerformanceTracker::GetAverageSlippage() const
  {
   if(m_slippageCount == 0)
      return 0.0;
   return m_totalSlippage / (double)m_slippageCount;
  }

//+------------------------------------------------------------------+
//| GetMaxDrawdownPct — worst peak-to-trough drawdown percentage     |
//+------------------------------------------------------------------+
double CPerformanceTracker::GetMaxDrawdownPct() const
  {
   return m_maxDrawdownPct;
  }

//+------------------------------------------------------------------+
//| GetTodayTrades — number of trades closed today                   |
//+------------------------------------------------------------------+
int CPerformanceTracker::GetTodayTrades() const
  {
   return m_todayTrades;
  }

//+------------------------------------------------------------------+
//| GetTodayProfit — net P&L for the current calendar day           |
//+------------------------------------------------------------------+
double CPerformanceTracker::GetTodayProfit() const
  {
   return m_todayProfit;
  }

//+------------------------------------------------------------------+
//| SaveToFile — persist all counters as key=value text lines        |
//+------------------------------------------------------------------+
void CPerformanceTracker::SaveToFile()
  {
   int h = FileOpen(m_statsFile,
                    FILE_WRITE | FILE_TXT | FILE_COMMON);
   if(h == INVALID_HANDLE)
     {
      if(m_logger != NULL)
         m_logger.Error("PerformanceTracker::SaveToFile failed to open file",
                        "path=" + m_statsFile + " err=" + IntegerToString(GetLastError()));
      return;
     }

   FileWriteString(h, "totalTrades="     + IntegerToString(m_totalTrades)     + "\n");
   FileWriteString(h, "winTrades="       + IntegerToString(m_winTrades)       + "\n");
   FileWriteString(h, "loseTrades="      + IntegerToString(m_loseTrades)      + "\n");
   FileWriteString(h, "breakEvenTrades=" + IntegerToString(m_breakEvenTrades) + "\n");
   FileWriteString(h, "grossProfit="     + DoubleToString(m_grossProfit, 5)   + "\n");
   FileWriteString(h, "grossLoss="       + DoubleToString(m_grossLoss, 5)     + "\n");
   FileWriteString(h, "maxDrawdown="     + DoubleToString(m_maxDrawdown, 5)   + "\n");
   FileWriteString(h, "maxDrawdownPct="  + DoubleToString(m_maxDrawdownPct,5) + "\n");
   FileWriteString(h, "highestEquity="   + DoubleToString(m_highestEquity, 5) + "\n");
   FileWriteString(h, "lowestEquity="    + DoubleToString(m_lowestEquity, 5)  + "\n");
   FileWriteString(h, "startEquity="     + DoubleToString(m_startEquity, 5)   + "\n");
   FileWriteString(h, "startBalance="    + DoubleToString(m_startBalance, 5)  + "\n");
   FileWriteString(h, "startDate="       + IntegerToString((long)m_startDate) + "\n");

   FileWriteString(h, "todayTrades="     + IntegerToString(m_todayTrades)     + "\n");
   FileWriteString(h, "todayWins="       + IntegerToString(m_todayWins)       + "\n");
   FileWriteString(h, "todayLosses="     + IntegerToString(m_todayLosses)     + "\n");
   FileWriteString(h, "todayProfit="     + DoubleToString(m_todayProfit, 5)   + "\n");
   FileWriteString(h, "todayDate="       + IntegerToString((long)m_todayDate) + "\n");

   FileWriteString(h, "tradesCopied="    + IntegerToString(m_tradesCopied)    + "\n");
   FileWriteString(h, "tradesSkipped="   + IntegerToString(m_tradesSkipped)   + "\n");
   FileWriteString(h, "tradesFailed="    + IntegerToString(m_tradesFailed)    + "\n");
   FileWriteString(h, "totalSlippage="   + DoubleToString(m_totalSlippage, 5) + "\n");
   FileWriteString(h, "slippageCount="   + IntegerToString(m_slippageCount)   + "\n");

   FileWriteString(h, "tradeResultsHead="  + IntegerToString(m_tradeResultsHead)  + "\n");
   FileWriteString(h, "tradeResultsCount=" + IntegerToString(m_tradeResultsCount) + "\n");

   // Persist each circular-buffer entry
   for(int i = 0; i < 100; i++)
      FileWriteString(h, "tr_" + IntegerToString(i) + "=" +
                      DoubleToString(m_tradeResults[i], 5) + "\n");

   FileClose(h);
  }

//+------------------------------------------------------------------+
//| LoadFromFile — restore persisted state on EA restart             |
//+------------------------------------------------------------------+
void CPerformanceTracker::LoadFromFile()
  {
   int h = FileOpen(m_statsFile,
                    FILE_READ | FILE_TXT | FILE_COMMON | FILE_SHARE_READ);
   if(h == INVALID_HANDLE)
      return; // No saved state yet — normal on first run

   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      StringTrimRight(line);
      StringTrimLeft(line);
      if(StringLen(line) == 0)
         continue;

      int sep = StringFind(line, "=");
      if(sep < 1)
         continue;

      string key   = StringSubstr(line, 0, sep);
      string value = StringSubstr(line, sep + 1);

      if(key == "totalTrades")          m_totalTrades       = (int)StringToInteger(value);
      else if(key == "winTrades")       m_winTrades         = (int)StringToInteger(value);
      else if(key == "loseTrades")      m_loseTrades        = (int)StringToInteger(value);
      else if(key == "breakEvenTrades") m_breakEvenTrades   = (int)StringToInteger(value);
      else if(key == "grossProfit")     m_grossProfit       = StringToDouble(value);
      else if(key == "grossLoss")       m_grossLoss         = StringToDouble(value);
      else if(key == "maxDrawdown")     m_maxDrawdown       = StringToDouble(value);
      else if(key == "maxDrawdownPct")  m_maxDrawdownPct    = StringToDouble(value);
      else if(key == "highestEquity")   m_highestEquity     = StringToDouble(value);
      else if(key == "lowestEquity")    m_lowestEquity      = StringToDouble(value);
      else if(key == "startEquity")     m_startEquity       = StringToDouble(value);
      else if(key == "startBalance")    m_startBalance      = StringToDouble(value);
      else if(key == "startDate")       m_startDate         = (datetime)StringToInteger(value);
      else if(key == "todayTrades")     m_todayTrades       = (int)StringToInteger(value);
      else if(key == "todayWins")       m_todayWins         = (int)StringToInteger(value);
      else if(key == "todayLosses")     m_todayLosses       = (int)StringToInteger(value);
      else if(key == "todayProfit")     m_todayProfit       = StringToDouble(value);
      else if(key == "todayDate")       m_todayDate         = (datetime)StringToInteger(value);
      else if(key == "tradesCopied")    m_tradesCopied      = (int)StringToInteger(value);
      else if(key == "tradesSkipped")   m_tradesSkipped     = (int)StringToInteger(value);
      else if(key == "tradesFailed")    m_tradesFailed      = (int)StringToInteger(value);
      else if(key == "totalSlippage")   m_totalSlippage     = StringToDouble(value);
      else if(key == "slippageCount")   m_slippageCount     = (int)StringToInteger(value);
      else if(key == "tradeResultsHead")  m_tradeResultsHead  = (int)StringToInteger(value);
      else if(key == "tradeResultsCount") m_tradeResultsCount = (int)StringToInteger(value);
      else
        {
         // Circular buffer entries: keys like "tr_0" .. "tr_99"
         if(StringLen(key) > 3 && StringSubstr(key, 0, 3) == "tr_")
           {
            int idx = (int)StringToInteger(StringSubstr(key, 3));
            if(idx >= 0 && idx < 100)
               m_tradeResults[idx] = StringToDouble(value);
           }
        }
     }

   FileClose(h);
  }

//+------------------------------------------------------------------+
//| GetSummary — one-line summary string for dashboard display       |
//+------------------------------------------------------------------+
string CPerformanceTracker::GetSummary() const
  {
   string winRateStr = DoubleToString(GetWinRate(), 1);
   string pfStr      = DoubleToString(GetProfitFactor(), 2);
   string ddStr      = DoubleToString(m_maxDrawdownPct, 1);
   string netStr     = DoubleToString(GetNetProfit(), 2);

   return "Trades: " + IntegerToString(m_totalTrades) +
          " | Win: "  + winRateStr + "%" +
          " | PF: "   + pfStr +
          " | DD: "   + ddStr + "%" +
          " | Net: "  + netStr;
  }

//+------------------------------------------------------------------+
//| AddTradeResult — insert PnL into the circular buffer             |
//+------------------------------------------------------------------+
void CPerformanceTracker::AddTradeResult(double pnl)
  {
   m_tradeResults[m_tradeResultsHead] = pnl;
   m_tradeResultsHead = (m_tradeResultsHead + 1) % 100;
   if(m_tradeResultsCount < 100)
      m_tradeResultsCount++;
  }

//+------------------------------------------------------------------+
//| UpdateTodayStats — accumulate today's counters                   |
//+------------------------------------------------------------------+
void CPerformanceTracker::UpdateTodayStats(double pnl, datetime closeTime)
  {
   // Determine the D1 bar open-time that contains closeTime
   datetime closeDay = iTime(NULL, PERIOD_D1, 0);

   // If the trade closed before the current D1 bar it belongs to a prior day;
   // we do not backfill — only update if the trade is from today.
   if(closeDay == m_todayDate)
     {
      m_todayTrades++;
      m_todayProfit += pnl;
      if(pnl > 0.0)
         m_todayWins++;
      else if(pnl < 0.0)
         m_todayLosses++;
     }
  }

//+------------------------------------------------------------------+
//| CheckDayRollover — reset today's stats when a new day begins     |
//+------------------------------------------------------------------+
void CPerformanceTracker::CheckDayRollover()
  {
   datetime currentDay = iTime(NULL, PERIOD_D1, 0);
   if(currentDay != m_todayDate)
     {
      if(m_logger != NULL)
         m_logger.Info("PerformanceTracker day rollover",
                       "prevDay=" + TimeToString(m_todayDate, TIME_DATE) +
                       " newDay="  + TimeToString(currentDay,  TIME_DATE) +
                       " todayTrades=" + IntegerToString(m_todayTrades) +
                       " todayProfit=" + DoubleToString(m_todayProfit, 2));

      m_todayDate   = currentDay;
      m_todayTrades = 0;
      m_todayWins   = 0;
      m_todayLosses = 0;
      m_todayProfit = 0.0;

      SaveToFile();
     }
  }

//+------------------------------------------------------------------+
//| UpdateDrawdown — recalculate worst drawdown from current equity  |
//+------------------------------------------------------------------+
void CPerformanceTracker::UpdateDrawdown(double equity)
  {
   if(m_highestEquity <= 0.0)
      return;

   double dd    = m_highestEquity - equity;
   double ddPct = dd / m_highestEquity * 100.0;

   if(dd > m_maxDrawdown)
      m_maxDrawdown = dd;

   if(ddPct > m_maxDrawdownPct)
      m_maxDrawdownPct = ddPct;
  }

//+------------------------------------------------------------------+
//| DoubleToStr2 — format a double to 2 decimal places               |
//+------------------------------------------------------------------+
string CPerformanceTracker::DoubleToStr2(double value) const
  {
   return DoubleToString(value, 2);
  }
