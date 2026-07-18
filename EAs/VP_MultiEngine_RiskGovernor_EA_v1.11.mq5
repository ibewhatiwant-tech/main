//+------------------------------------------------------------------+
//| VP_MultiEngine_RiskGovernor_EA.mq5                              |
//| Rolling Volume Profile: VA Rejection, VA Breakout, POC Reversion|
//| Version 1.11                                                     |
//+------------------------------------------------------------------+
#property strict
#property version   "1.11"
#property description "XAUUSD rolling volume-profile multi-engine EA with centralized risk governor"

#include <Trade/Trade.mqh>

input group "General"
input ulong  InpBaseMagicNumber             = 2026001;
input bool   InpRequireHedgingAccount       = true;
input int    InpSlippagePoints              = 50;
input int    InpSubmissionTimeoutSeconds    = 30;
input bool   InpEnableAuditLog              = true;
input string InpAuditFileName               = "VP_MULTI_ENGINE_AUDIT.csv";

input group "Engine Controls"
input bool   InpEnablePOCReversion          = true;
input bool   InpEnableVABreakout            = true;
input bool   InpEnableVARejection           = true;
input bool   InpAllowMultipleEntriesSameBar = false;
input bool   InpAllowOppositeExposure       = false;
input int    InpCooldownBars                = 1;

input group "Rolling Volume Profile"
input int    InpProfileBars                 = 48;
input int    InpPriceBins                   = 120;
input double InpValueAreaPct                = 70.0;
input bool   InpUseRealVolume               = false;

input group "Filters"
input int    InpATRPeriod                   = 14;
input double InpATRMinimumPoints            = 0.0;
input int    InpEMAPeriod                   = 200;
input bool   InpUseEMAFilter                = true;
input int    InpVolumeMAPeriod              = 20;
input int    InpMaxSpreadPoints             = 350;
input int    InpMaxTickAgeSeconds           = 15;

input group "Signal and Exit Rules"
input double InpBreakoutVolumeMultiplier    = 1.50;
input double InpBreakoutATRDistance         = 0.20;
input double InpWickBodyRatio               = 1.00;
input int    InpSwingLookback               = 5;
input int    InpStopBufferPoints            = 50;
input bool   InpUseATRStops                 = true;
input double InpATRStopMultiplier           = 1.50;
input bool   InpPOCUseRRTarget              = false;
input double InpPOCRewardRisk               = 2.00;
input double InpMinimumRewardRisk           = 1.20;

input group "Central Risk Governor"
input double InpRiskPercentPerTrade         = 1.00;
input double InpMaxOpenRiskPercent          = 5.00;
input double InpMaxDailyLossPercent         = 5.00;
input double InpKillSwitchDrawdownPercent   = 20.00;
input int    InpMaxTradesPerDay             = 20;
input int    InpMaxSimultaneousPositions    = 3;
input bool   InpCloseEAOrdersOnKillSwitch   = true;

enum ENUM_ENGINE
{
   ENGINE_POC_REVERSION = 0,
   ENGINE_VA_BREAKOUT   = 1,
   ENGINE_VA_REJECTION  = 2
};

enum ENUM_PORTFOLIO_STATE
{
   PORTFOLIO_BOOT = 0,
   PORTFOLIO_READY,
   PORTFOLIO_HALT_DAILY_LOSS,
   PORTFOLIO_HALT_DRAWDOWN,
   PORTFOLIO_HALT_MANUAL
};

enum ENUM_LANE_STATE
{
   LANE_IDLE = 0,
   LANE_RESERVED,
   LANE_SUBMITTED,
   LANE_OPEN,
   LANE_COOLDOWN
};

struct SMarket
{
   bool valid;
   MqlRates rates[];
   double bid;
   double ask;
   double spreadPoints;
   double atr;
   double ema;
   datetime barTime;
};

struct STradeProposal
{
   bool valid;
   ENUM_ENGINE engine;
   ENUM_ORDER_TYPE direction;
   double entry;
   double sl;
   double tp;
   double volume;
   double riskMoney;
   double rewardRisk;
   int priority;
   string reason;
};

struct SLane
{
   ENUM_ENGINE engine;
   ENUM_ORDER_TYPE direction;
   ENUM_LANE_STATE state;
   datetime cooldownUntil;
   datetime submittedAt;
   double reservedRiskMoney;
   double lastRiskMoney;
   double requestedEntry;
   double requestedVolume;
   ulong orderTicket;
   ulong positionIdentifier;
   string lastReason;
};

struct SRiskLedger
{
   double balance;
   double equity;
   double freeMargin;
   double actualOpenRiskMoney;
   double reservedRiskMoney;
   double maxOpenRiskMoney;
   double dailyPnL;
   double dailyLossLimitMoney;
   int openPositions;
   int entryDealsToday;
};

class CRollingVolumeProfile
{
private:
   double m_histogram[];
   int    m_allocatedBins;

public:
   bool     valid;
   datetime sourceEndTime;
   double   poc;
   double   vah;
   double   val;

   CRollingVolumeProfile()
   {
      m_allocatedBins = 0;
      Reset();
   }

   void Reset()
   {
      valid = false;
      sourceEndTime = 0;
      poc = 0.0;
      vah = 0.0;
      val = 0.0;
   }

   bool BuildFromSnapshot(const MqlRates &rates[], const int startShift,
                          const int profileBars, const int priceBins,
                          const double valueAreaPct, const bool useRealVolume)
   {
      Reset();
      if(profileBars < 2 || priceBins < 2 || valueAreaPct <= 0.0 || valueAreaPct > 100.0)
         return false;
      if(ArraySize(rates) < startShift + profileBars)
         return false;

      if(m_allocatedBins != priceBins)
      {
         ArrayResize(m_histogram, priceBins);
         m_allocatedBins = priceBins;
      }
      ArrayInitialize(m_histogram, 0.0);

      double rangeHigh = -DBL_MAX;
      double rangeLow = DBL_MAX;
      for(int shift = startShift; shift < startShift + profileBars; shift++)
      {
         rangeHigh = MathMax(rangeHigh, rates[shift].high);
         rangeLow = MathMin(rangeLow, rates[shift].low);
      }
      double range = rangeHigh - rangeLow;
      if(range <= 0.0)
         return false;

      double binSize = range / (double)priceBins;
      double inverseBin = 1.0 / binSize;
      for(int shift = startShift; shift < startShift + profileBars; shift++)
      {
         long volume = rates[shift].tick_volume;
         if(useRealVolume && rates[shift].real_volume > 0)
            volume = rates[shift].real_volume;
         if(volume <= 0)
            continue;

         int firstBin = (int)MathFloor((rates[shift].low - rangeLow) * inverseBin);
         int lastBin = (int)MathFloor((rates[shift].high - rangeLow) * inverseBin);
         firstBin = MathMax(0, MathMin(firstBin, priceBins - 1));
         lastBin = MathMax(0, MathMin(lastBin, priceBins - 1));
         int touched = lastBin - firstBin + 1;
         if(touched <= 0)
            continue;

         double volumePerBin = (double)volume / (double)touched;
         for(int bin = firstBin; bin <= lastBin; bin++)
            m_histogram[bin] += volumePerBin;
      }

      int pocIndex = 0;
      double totalVolume = 0.0;
      double maximumVolume = -1.0;
      for(int bin = 0; bin < priceBins; bin++)
      {
         totalVolume += m_histogram[bin];
         if(m_histogram[bin] > maximumVolume)
         {
            maximumVolume = m_histogram[bin];
            pocIndex = bin;
         }
      }
      if(totalVolume <= 0.0)
         return false;

      int left = pocIndex;
      int right = pocIndex;
      double accumulated = m_histogram[pocIndex];
      double target = totalVolume * valueAreaPct / 100.0;
      while(accumulated < target && (left > 0 || right < priceBins - 1))
      {
         double leftVolume = (left > 0) ? m_histogram[left - 1] : -1.0;
         double rightVolume = (right < priceBins - 1) ? m_histogram[right + 1] : -1.0;
         if(leftVolume > rightVolume)
         {
            left--;
            accumulated += m_histogram[left];
         }
         else
         {
            right++;
            accumulated += m_histogram[right];
         }
      }

      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      poc = NormalizeDouble(rangeLow + ((double)pocIndex + 0.5) * binSize, digits);
      val = NormalizeDouble(rangeLow + (double)left * binSize, digits);
      vah = NormalizeDouble(rangeLow + (double)(right + 1) * binSize, digits);
      sourceEndTime = rates[startShift].time;
      valid = true;
      return true;
   }
};

int g_atrHandle = INVALID_HANDLE;
int g_emaHandle = INVALID_HANDLE;
datetime g_lastBarTime = 0;
datetime g_lastBrokerDay = 0;
double g_peakEquity = 0.0;
double g_reservedRiskMoney = 0.0;
ENUM_PORTFOLIO_STATE g_portfolioState = PORTFOLIO_BOOT;
CRollingVolumeProfile g_profile;
SLane g_lanes[6];

int SymbolDigits()
{
   return (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
}

double NormalizePrice(const double price)
{
   return NormalizeDouble(price, SymbolDigits());
}

ulong EngineMagic(const ENUM_ENGINE engine)
{
   return InpBaseMagicNumber + (ulong)engine + 1;
}

string EngineName(const ENUM_ENGINE engine)
{
   if(engine == ENGINE_POC_REVERSION) return "POC_REV";
   if(engine == ENGINE_VA_BREAKOUT) return "VA_BRK";
   return "VA_REJ";
}

string DirectionName(const ENUM_ORDER_TYPE direction)
{
   return direction == ORDER_TYPE_BUY ? "BUY" : "SELL";
}

int LaneIndex(const ENUM_ENGINE engine, const ENUM_ORDER_TYPE direction)
{
   return (int)engine * 2 + (direction == ORDER_TYPE_BUY ? 0 : 1);
}

int LaneIndexByOrderTicket(const ulong ticket)
{
   if(ticket == 0) return -1;
   for(int i = 0; i < 6; i++)
      if(g_lanes[i].orderTicket == ticket) return i;
   return -1;
}

int LaneIndexByPosition(const ulong positionId)
{
   if(positionId == 0) return -1;
   for(int i = 0; i < 6; i++)
      if(g_lanes[i].positionIdentifier == positionId) return i;
   return -1;
}

bool IsOurMagic(const long magic)
{
   return magic == (long)EngineMagic(ENGINE_POC_REVERSION) ||
          magic == (long)EngineMagic(ENGINE_VA_BREAKOUT) ||
          magic == (long)EngineMagic(ENGINE_VA_REJECTION);
}

bool IsSuccessfulRetcode(const uint retcode)
{
   return retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_DONE_PARTIAL ||
          retcode == TRADE_RETCODE_PLACED;
}

datetime BrokerDayStart()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   return StructToTime(dt);
}

string StateKey(const string suffix)
{
   return "VP_MER_" + (string)AccountInfoInteger(ACCOUNT_LOGIN) + "_" + _Symbol + "_" +
          (string)InpBaseMagicNumber + "_" + suffix;
}

void Audit(const string eventName, const string engine, const string direction,
           const string reason, const double entry = 0.0, const double sl = 0.0,
           const double tp = 0.0, const double volume = 0.0,
           const double risk = 0.0, const uint retcode = 0,
           const ulong orderTicket = 0, const ulong dealTicket = 0,
           const ulong positionId = 0, const double fillPrice = 0.0,
           const double fillVolume = 0.0, const string brokerComment = "",
           const double commission = 0.0, const double swap = 0.0,
           const double netPnL = 0.0, const double rMultiple = 0.0)
{
   if(!InpEnableAuditLog)
      return;
   int handle = FileOpen(InpAuditFileName, FILE_COMMON | FILE_CSV | FILE_READ | FILE_WRITE);
   if(handle == INVALID_HANDLE)
      return;
   FileSeek(handle, 0, SEEK_END);
   FileWrite(handle, TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS), eventName,
             engine, direction, reason, entry, sl, tp, volume, risk,
             g_profile.poc, g_profile.vah, g_profile.val, retcode,
             orderTicket, dealTicket, positionId, fillPrice, fillVolume, brokerComment,
             commission, swap, netPnL, rMultiple);
   FileClose(handle);
}

void SavePersistentState()
{
   GlobalVariableSet(StateKey("PEAK_EQUITY"), g_peakEquity);
   GlobalVariableSet(StateKey("STATE"), (double)g_portfolioState);
   GlobalVariableSet(StateKey("DAILY_DAY"), (double)g_lastBrokerDay);
}

void LoadPersistentState()
{
   double value = 0.0;
   if(GlobalVariableGet(StateKey("PEAK_EQUITY"), value)) g_peakEquity = value;
   if(GlobalVariableGet(StateKey("STATE"), value)) g_portfolioState = (ENUM_PORTFOLIO_STATE)(int)value;
   if(GlobalVariableGet(StateKey("DAILY_DAY"), value)) g_lastBrokerDay = (datetime)value;
}

void SetPortfolioState(const ENUM_PORTFOLIO_STATE state, const string reason)
{
   g_portfolioState = state;
   SavePersistentState();
   Audit("PORTFOLIO_STATE", "", "", reason);
}

void HandleDailyRollover()
{
   datetime today = BrokerDayStart();
   if(g_lastBrokerDay == 0)
   {
      g_lastBrokerDay = today;
      SavePersistentState();
      return;
   }
   if(today == g_lastBrokerDay)
      return;
   g_lastBrokerDay = today;
   if(g_portfolioState == PORTFOLIO_HALT_DAILY_LOSS)
      SetPortfolioState(PORTFOLIO_READY, "New broker day - daily loss halt reset");
   else
      SavePersistentState();
}

bool IsNewBar()
{
   datetime current = iTime(_Symbol, _Period, 0);
   if(current == 0) return false;
   if(current == g_lastBarTime) return false;
   g_lastBarTime = current;
   return true;
}

bool LoadMarket(SMarket &market)
{
   market.valid = false;
   int requiredBars = MathMax(InpEMAPeriod + 5,
                      MathMax(InpProfileBars + 2,
                      MathMax(InpSwingLookback + 5, InpVolumeMAPeriod + 5)));
   ArrayResize(market.rates, requiredBars);
   ArraySetAsSeries(market.rates, true);
   if(CopyRates(_Symbol, _Period, 0, requiredBars, market.rates) != requiredBars)
      return false;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return false;
   if(TimeCurrent() - tick.time > InpMaxTickAgeSeconds) return false;
   double atrBuffer[], emaBuffer[];
   ArraySetAsSeries(atrBuffer, true);
   ArraySetAsSeries(emaBuffer, true);
   if(CopyBuffer(g_atrHandle, 0, 1, 1, atrBuffer) != 1) return false;
   if(CopyBuffer(g_emaHandle, 0, 1, 1, emaBuffer) != 1) return false;

   market.bid = tick.bid;
   market.ask = tick.ask;
   market.spreadPoints = (market.ask - market.bid) / _Point;
   market.atr = atrBuffer[0];
   market.ema = emaBuffer[0];
   market.barTime = market.rates[0].time;
   market.valid = market.bid > 0.0 && market.ask > 0.0 && market.atr > 0.0;
   return market.valid;
}

double BarVolume(const SMarket &market, const int shift)
{
   if(InpUseRealVolume && market.rates[shift].real_volume > 0)
      return (double)market.rates[shift].real_volume;
   return (double)market.rates[shift].tick_volume;
}

double AverageVolume(const SMarket &market)
{
   double total = 0.0;
   for(int shift = 2; shift < 2 + InpVolumeMAPeriod; shift++) total += BarVolume(market, shift);
   return total / (double)InpVolumeMAPeriod;
}

bool SpreadOK(const SMarket &market) { return market.spreadPoints <= (double)InpMaxSpreadPoints; }
bool ATROK(const SMarket &market) { return market.atr / _Point >= InpATRMinimumPoints; }

int CountOurOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && IsOurMagic(PositionGetInteger(POSITION_MAGIC))) count++;
   }
   return count;
}

bool FindPositionForLane(const ENUM_ENGINE engine, const ENUM_ORDER_TYPE direction, ulong &positionId)
{
   long desired = direction == ORDER_TYPE_BUY ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)EngineMagic(engine)) continue;
      if(PositionGetInteger(POSITION_TYPE) == desired) { positionId = ticket; return true; }
   }
   positionId = 0;
   return false;
}

bool HasPositionForLane(const ENUM_ENGINE engine, const ENUM_ORDER_TYPE direction)
{
   ulong positionId;
   return FindPositionForLane(engine, direction, positionId);
}

bool HasOppositeEAPosition(const ENUM_ORDER_TYPE direction)
{
   long desired = direction == ORDER_TYPE_BUY ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || !IsOurMagic(PositionGetInteger(POSITION_MAGIC))) continue;
      if(PositionGetInteger(POSITION_TYPE) == desired) return true;
   }
   return false;
}

double CalculateOpenRiskMoney()
{
   double risk = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || !IsOurMagic(PositionGetInteger(POSITION_MAGIC))) continue;
      double sl = PositionGetDouble(POSITION_SL), open = PositionGetDouble(POSITION_PRICE_OPEN), volume = PositionGetDouble(POSITION_VOLUME);
      if(sl <= 0.0 || open <= 0.0 || volume <= 0.0) return DBL_MAX;
      ENUM_ORDER_TYPE type = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double projected = 0.0;
      if(!OrderCalcProfit(type, _Symbol, volume, open, sl, projected)) return DBL_MAX;
      risk += MathAbs(projected);
   }
   return risk;
}

double CalculateDailyPnL()
{
   if(!HistorySelect(BrokerDayStart(), TimeCurrent())) return 0.0;
   double pnl = 0.0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol || !IsOurMagic(HistoryDealGetInteger(deal, DEAL_MAGIC))) continue;
      pnl += HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_COMMISSION) + HistoryDealGetDouble(deal, DEAL_SWAP);
   }
   return pnl;
}

int CountEntryDealsToday()
{
   if(!HistorySelect(BrokerDayStart(), TimeCurrent())) return 0;
   int count = 0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol || !IsOurMagic(HistoryDealGetInteger(deal, DEAL_MAGIC))) continue;
      if(HistoryDealGetInteger(deal, DEAL_ENTRY) == DEAL_ENTRY_IN) count++;
   }
   return count;
}

void RefreshRiskLedger(SRiskLedger &ledger)
{
   ledger.balance = AccountInfoDouble(ACCOUNT_BALANCE);
   ledger.equity = AccountInfoDouble(ACCOUNT_EQUITY);
   ledger.freeMargin = AccountInfoDouble(ACCOUNT_FREEMARGIN);
   ledger.actualOpenRiskMoney = CalculateOpenRiskMoney();
   ledger.reservedRiskMoney = g_reservedRiskMoney;
   ledger.maxOpenRiskMoney = ledger.balance * InpMaxOpenRiskPercent / 100.0;
   ledger.dailyPnL = CalculateDailyPnL();
   ledger.dailyLossLimitMoney = ledger.balance * InpMaxDailyLossPercent / 100.0;
   ledger.openPositions = CountOurOpenPositions();
   ledger.entryDealsToday = CountEntryDealsToday();
}

void CloseAllEAPositions()
{
   CTrade closer;
   closer.SetDeviationInPoints(InpSlippagePoints);
   closer.SetTypeFillingBySymbol(_Symbol);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || !IsOurMagic(PositionGetInteger(POSITION_MAGIC))) continue;
      if(!closer.PositionClose(ticket)) Audit("KILL_CLOSE_FAIL", "", "", closer.ResultRetcodeDescription(), 0,0,0,0,0, closer.ResultRetcode());
   }
}

bool ApplyPortfolioStops(SRiskLedger &ledger)
{
   g_peakEquity = MathMax(g_peakEquity, ledger.equity);
   SavePersistentState();
   if(g_peakEquity > 0.0)
   {
      double dd = (g_peakEquity - ledger.equity) / g_peakEquity * 100.0;
      if(dd >= InpKillSwitchDrawdownPercent)
      {
         SetPortfolioState(PORTFOLIO_HALT_DRAWDOWN, "Drawdown kill switch");
         if(InpCloseEAOrdersOnKillSwitch) CloseAllEAPositions();
         return false;
      }
   }
   if(ledger.dailyPnL <= -ledger.dailyLossLimitMoney)
   {
      if(g_portfolioState == PORTFOLIO_READY)
         SetPortfolioState(PORTFOLIO_HALT_DAILY_LOSS, "Daily loss limit");
      return false;
   }
   return g_portfolioState == PORTFOLIO_READY;
}

bool LossAtStop(const ENUM_ORDER_TYPE direction, const double volume, const double entry, const double sl, double &loss)
{
   double projected = 0.0;
   if(!OrderCalcProfit(direction, _Symbol, volume, entry, sl, projected)) return false;
   loss = MathAbs(projected);
   return loss > 0.0;
}

double NormalizeVolumeDown(const double requested)
{
   double minimum = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maximum = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) return 0.0;
   double volume = MathFloor(MathMin(requested, maximum) / step) * step;
   volume = NormalizeDouble(volume, 8);
   return volume >= minimum ? volume : 0.0;
}

bool SizeProposal(STradeProposal &proposal, const SRiskLedger &ledger)
{
   double oneLotLoss = 0.0;
   if(!LossAtStop(proposal.direction, 1.0, proposal.entry, proposal.sl, oneLotLoss)) return false;
   double allowed = ledger.balance * InpRiskPercentPerTrade / 100.0;
   proposal.volume = NormalizeVolumeDown(allowed / oneLotLoss);
   if(proposal.volume <= 0.0) return false;
   if(!LossAtStop(proposal.direction, proposal.volume, proposal.entry, proposal.sl, proposal.riskMoney)) return false;
   return proposal.riskMoney <= allowed + 0.01;
}

bool StopsAreValid(const STradeProposal &proposal, const SMarket &market)
{
   int stops = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freeze = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double distance = (double)MathMax(stops, freeze) * _Point;
   if(proposal.direction == ORDER_TYPE_BUY)
      return proposal.sl < market.bid && proposal.tp > market.ask && market.bid - proposal.sl >= distance && proposal.tp - market.ask >= distance;
   return proposal.sl > market.ask && proposal.tp < market.bid && proposal.sl - market.ask >= distance && market.bid - proposal.tp >= distance;
}

bool BrokerPermitsTrading(string &reason)
{
   if((ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL)
   {
      reason = "Symbol trade mode does not permit full trading";
      return false;
   }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) { reason = "Terminal trading is disabled"; return false; }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) { reason = "Algo trading is disabled for this EA"; return false; }
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT)) { reason = "Account does not permit EA trading"; return false; }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)) { reason = "Account trading is disabled"; return false; }
   return true;
}

bool ResolveFillingPolicy(ENUM_ORDER_TYPE_FILLING &filling)
{
   long modeFlags = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((modeFlags & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) { filling = ORDER_FILLING_FOK; return true; }
   if((modeFlags & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) { filling = ORDER_FILLING_IOC; return true; }
   ENUM_SYMBOL_TRADE_EXECUTION exeMode = (ENUM_SYMBOL_TRADE_EXECUTION)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_EXEMODE);
   if(exeMode != SYMBOL_TRADE_EXECUTION_MARKET) { filling = ORDER_FILLING_RETURN; return true; }
   return false;
}

bool RiskGovernorApprove(STradeProposal &proposal, const SMarket &market, SRiskLedger &ledger, string &reason)
{
   reason = "";
   if(g_portfolioState != PORTFOLIO_READY) { reason = "Portfolio halted"; return false; }
   if(!BrokerPermitsTrading(reason)) return false;
   if(!SpreadOK(market)) { reason = "Spread limit"; return false; }
   if(!ATROK(market)) { reason = "ATR minimum"; return false; }
   if(proposal.rewardRisk < InpMinimumRewardRisk) { reason = "Reward risk below minimum"; return false; }
   if(HasPositionForLane(proposal.engine, proposal.direction)) { reason = "Duplicate engine direction"; return false; }
   if(!InpAllowOppositeExposure && HasOppositeEAPosition(proposal.direction)) { reason = "Opposite exposure blocked"; return false; }
   if(ledger.openPositions >= InpMaxSimultaneousPositions) { reason = "Maximum positions"; return false; }
   if(ledger.entryDealsToday >= InpMaxTradesPerDay) { reason = "Maximum daily entries"; return false; }
   if(!SizeProposal(proposal, ledger)) { reason = "Risk sizing invalid"; return false; }
   if(!StopsAreValid(proposal, market)) { reason = "Stops or freeze level"; return false; }
   if(ledger.actualOpenRiskMoney == DBL_MAX) { reason = "Existing position has no valid stop"; return false; }
   if(ledger.actualOpenRiskMoney + ledger.reservedRiskMoney + proposal.riskMoney > ledger.maxOpenRiskMoney) { reason = "Aggregate open risk"; return false; }
   double margin = 0.0;
   if(!OrderCalcMargin(proposal.direction, _Symbol, proposal.volume, proposal.entry, margin)) { reason = "Margin calculation failed"; return false; }
   if(margin > ledger.freeMargin) { reason = "Insufficient free margin"; return false; }
   return true;
}

double LowestLow(const SMarket &market)
{
   double low = DBL_MAX;
   for(int shift = 1; shift <= InpSwingLookback; shift++) low = MathMin(low, market.rates[shift].low);
   return low;
}

double HighestHigh(const SMarket &market)
{
   double high = -DBL_MAX;
   for(int shift = 1; shift <= InpSwingLookback; shift++) high = MathMax(high, market.rates[shift].high);
   return high;
}

STradeProposal EmptyProposal()
{
   STradeProposal p;
   p.valid = false; p.engine = ENGINE_POC_REVERSION; p.direction = ORDER_TYPE_BUY;
   p.entry = 0; p.sl = 0; p.tp = 0; p.volume = 0; p.riskMoney = 0; p.rewardRisk = 0; p.priority = 0; p.reason = "";
   return p;
}

bool BuildLevels(const ENUM_ORDER_TYPE direction, const SMarket &market, const double target,
                 double &entry, double &sl, double &tp, double &rr)
{
   entry = direction == ORDER_TYPE_BUY ? market.ask : market.bid;
   if(direction == ORDER_TYPE_BUY)
   {
      double swing = LowestLow(market) - InpStopBufferPoints * _Point;
      double atr = entry - market.atr * InpATRStopMultiplier;
      sl = InpUseATRStops ? MathMin(swing, atr) : swing;
      tp = target;
      if(sl >= entry || tp <= entry) return false;
      rr = (tp - entry) / (entry - sl);
   }
   else
   {
      double swing = HighestHigh(market) + InpStopBufferPoints * _Point;
      double atr = entry + market.atr * InpATRStopMultiplier;
      sl = InpUseATRStops ? MathMax(swing, atr) : swing;
      tp = target;
      if(sl <= entry || tp >= entry) return false;
      rr = (entry - tp) / (sl - entry);
   }
   entry = NormalizePrice(entry); sl = NormalizePrice(sl); tp = NormalizePrice(tp);
   return rr > 0.0;
}

STradeProposal CreateProposal(const ENUM_ENGINE engine, const ENUM_ORDER_TYPE direction,
                              const int priority, const string reason, const SMarket &market,
                              const double target)
{
   STradeProposal p = EmptyProposal();
   if(!BuildLevels(direction, market, target, p.entry, p.sl, p.tp, p.rewardRisk)) return p;
   p.valid = true; p.engine = engine; p.direction = direction; p.priority = priority; p.reason = reason;
   return p;
}

STradeProposal BuildVARejection(const SMarket &market, const CRollingVolumeProfile &profile)
{
   STradeProposal p = EmptyProposal();
   MqlRates bar = market.rates[1];
   double body = MathAbs(bar.close - bar.open);
   double upperWick = bar.high - MathMax(bar.open, bar.close);
   double lowerWick = MathMin(bar.open, bar.close) - bar.low;
   double avgVol = AverageVolume(market), volume = BarVolume(market, 1);
   bool sellTrend = !InpUseEMAFilter || bar.close < market.ema;
   bool buyTrend = !InpUseEMAFilter || bar.close > market.ema;
   if(bar.high > profile.vah && bar.close < profile.vah && upperWick > body * InpWickBodyRatio && volume > avgVol && sellTrend)
      return CreateProposal(ENGINE_VA_REJECTION, ORDER_TYPE_SELL, 3, "VAH rejection", market, profile.poc);
   if(bar.low < profile.val && bar.close > profile.val && lowerWick > body * InpWickBodyRatio && volume > avgVol && buyTrend)
      return CreateProposal(ENGINE_VA_REJECTION, ORDER_TYPE_BUY, 3, "VAL rejection", market, profile.poc);
   return p;
}

STradeProposal BuildVABreakout(const SMarket &market, const CRollingVolumeProfile &profile)
{
   STradeProposal p = EmptyProposal();
   MqlRates bar = market.rates[1];
   double avgVol = AverageVolume(market), volume = BarVolume(market, 1), projection = profile.vah - profile.val;
   if(projection <= 0.0) return p;
   bool buyTrend = !InpUseEMAFilter || bar.close > market.ema;
   bool sellTrend = !InpUseEMAFilter || bar.close < market.ema;
   if(bar.close > profile.vah && bar.close - profile.vah >= market.atr * InpBreakoutATRDistance && volume >= avgVol * InpBreakoutVolumeMultiplier && buyTrend)
      return CreateProposal(ENGINE_VA_BREAKOUT, ORDER_TYPE_BUY, 2, "VAH breakout", market, market.ask + projection);
   if(bar.close < profile.val && profile.val - bar.close >= market.atr * InpBreakoutATRDistance && volume >= avgVol * InpBreakoutVolumeMultiplier && sellTrend)
      return CreateProposal(ENGINE_VA_BREAKOUT, ORDER_TYPE_SELL, 2, "VAL breakout", market, market.bid - projection);
   return p;
}

STradeProposal BuildPOCReversion(const SMarket &market, const CRollingVolumeProfile &profile)
{
   STradeProposal p = EmptyProposal();
   MqlRates previous = market.rates[2], signal = market.rates[1];
   double avgVol = AverageVolume(market), volume = BarVolume(market, 1);
   bool buyTrend = !InpUseEMAFilter || signal.close > market.ema;
   bool sellTrend = !InpUseEMAFilter || signal.close < market.ema;
   if(previous.close < profile.poc && signal.close > profile.poc && volume > avgVol && buyTrend)
   {
      double target = profile.vah;
      if(InpPOCUseRRTarget)
      {
         double entry = market.ask;
         double sl = InpUseATRStops ? MathMin(LowestLow(market) - InpStopBufferPoints * _Point, entry - market.atr * InpATRStopMultiplier) : LowestLow(market) - InpStopBufferPoints * _Point;
         target = entry + (entry - sl) * InpPOCRewardRisk;
      }
      return CreateProposal(ENGINE_POC_REVERSION, ORDER_TYPE_BUY, 1, "POC bullish reversion", market, target);
   }
   if(previous.close > profile.poc && signal.close < profile.poc && volume > avgVol && sellTrend)
   {
      double target = profile.val;
      if(InpPOCUseRRTarget)
      {
         double entry = market.bid;
         double sl = InpUseATRStops ? MathMax(HighestHigh(market) + InpStopBufferPoints * _Point, entry + market.atr * InpATRStopMultiplier) : HighestHigh(market) + InpStopBufferPoints * _Point;
         target = entry - (sl - entry) * InpPOCRewardRisk;
      }
      return CreateProposal(ENGINE_POC_REVERSION, ORDER_TYPE_SELL, 1, "POC bearish reversion", market, target);
   }
   return p;
}

void InitializeLanes()
{
   for(int engine = 0; engine < 3; engine++)
   {
      for(int side = 0; side < 2; side++)
      {
         int index = engine * 2 + side;
         g_lanes[index].engine = (ENUM_ENGINE)engine;
         g_lanes[index].direction = side == 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
         g_lanes[index].state = LANE_IDLE;
         g_lanes[index].cooldownUntil = 0;
         g_lanes[index].submittedAt = 0;
         g_lanes[index].reservedRiskMoney = 0.0;
         g_lanes[index].lastRiskMoney = 0.0;
         g_lanes[index].requestedEntry = 0.0;
         g_lanes[index].requestedVolume = 0.0;
         g_lanes[index].orderTicket = 0;
         g_lanes[index].positionIdentifier = 0;
         g_lanes[index].lastReason = "";
      }
   }
}

void ReleaseLaneReservation(SLane &lane)
{
   if(lane.reservedRiskMoney > 0.0)
      g_reservedRiskMoney = MathMax(0.0, g_reservedRiskMoney - lane.reservedRiskMoney);
   lane.reservedRiskMoney = 0.0;
}

void ResetLane(SLane &lane)
{
   ReleaseLaneReservation(lane);
   lane.state = LANE_IDLE;
   lane.orderTicket = 0;
   lane.positionIdentifier = 0;
   lane.lastRiskMoney = 0.0;
   lane.requestedEntry = 0.0;
   lane.requestedVolume = 0.0;
   lane.submittedAt = 0;
}

void ReconcileLanes()
{
   datetime now = TimeCurrent();
   for(int i = 0; i < 6; i++)
   {
      SLane &lane = g_lanes[i];
      ulong positionId = 0;
      bool hasPosition = FindPositionForLane(lane.engine, lane.direction, positionId);
      if(hasPosition)
      {
         if(lane.state != LANE_OPEN)
         {
            lane.state = LANE_OPEN;
            ReleaseLaneReservation(lane);
            lane.orderTicket = 0;
         }
         lane.positionIdentifier = positionId;
         continue;
      }
      if(lane.state == LANE_OPEN)
      {
         // Position gone with no matching exit deal seen yet (e.g. missed event after a restart).
         lane.state = LANE_COOLDOWN;
         lane.cooldownUntil = now + InpCooldownBars * PeriodSeconds(_Period);
         lane.positionIdentifier = 0;
         lane.lastRiskMoney = 0.0;
      }
      else if(lane.state == LANE_SUBMITTED)
      {
         if(now - lane.submittedAt > InpSubmissionTimeoutSeconds)
         {
            Audit("SUBMISSION_TIMEOUT", EngineName(lane.engine), DirectionName(lane.direction),
                  "No confirmed fill or rejection within timeout");
            ResetLane(lane);
         }
      }
      if(lane.state == LANE_COOLDOWN && now >= lane.cooldownUntil) lane.state = LANE_IDLE;
   }
}

bool SubmitProposal(STradeProposal &proposal, SLane &lane, SRiskLedger &ledger)
{
   MqlTradeRequest request;
   MqlTradeCheckResult check;
   MqlTradeResult result;
   ZeroMemory(request); ZeroMemory(check); ZeroMemory(result);
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.magic = EngineMagic(proposal.engine);
   request.volume = proposal.volume;
   request.type = proposal.direction;
   request.price = proposal.entry;
   request.sl = proposal.sl;
   request.tp = proposal.tp;
   request.deviation = InpSlippagePoints;
   request.comment = "VP|" + EngineName(proposal.engine) + "|" + DirectionName(proposal.direction);

   if(!ResolveFillingPolicy(request.type_filling))
   {
      Audit("FILLING_POLICY_BLOCK", EngineName(proposal.engine), DirectionName(proposal.direction),
            "No compatible filling policy for symbol execution mode");
      return false;
   }

   lane.requestedEntry = proposal.entry;
   lane.requestedVolume = proposal.volume;
   lane.lastRiskMoney = proposal.riskMoney;
   lane.reservedRiskMoney = proposal.riskMoney;
   lane.state = LANE_RESERVED;
   g_reservedRiskMoney += proposal.riskMoney;
   ledger.reservedRiskMoney += proposal.riskMoney;

   if(!OrderCheck(request, check) || check.retcode != TRADE_RETCODE_DONE)
   {
      Audit("ORDER_CHECK_BLOCK", EngineName(proposal.engine), DirectionName(proposal.direction), check.comment,
            proposal.entry, proposal.sl, proposal.tp, proposal.volume, proposal.riskMoney, check.retcode);
      ResetLane(lane);
      return false;
   }
   if(!OrderSend(request, result) || !IsSuccessfulRetcode(result.retcode))
   {
      Audit("ORDER_SEND_FAIL", EngineName(proposal.engine), DirectionName(proposal.direction), result.comment,
            proposal.entry, proposal.sl, proposal.tp, proposal.volume, proposal.riskMoney, result.retcode);
      ResetLane(lane);
      return false;
   }
   lane.orderTicket = result.order;
   lane.submittedAt = TimeCurrent();
   lane.state = LANE_SUBMITTED;
   Audit("ORDER_SENT", EngineName(proposal.engine), DirectionName(proposal.direction), proposal.reason,
         proposal.entry, proposal.sl, proposal.tp, proposal.volume, proposal.riskMoney, result.retcode,
         result.order, result.deal, 0, result.price, result.volume, result.comment);
   return true;
}

void SortProposals(STradeProposal &proposals[])
{
   for(int i = 0; i < ArraySize(proposals) - 1; i++)
      for(int j = i + 1; j < ArraySize(proposals); j++)
         if(proposals[j].priority > proposals[i].priority ||
            (proposals[j].priority == proposals[i].priority && proposals[j].rewardRisk > proposals[i].rewardRisk))
         {
            STradeProposal temp = proposals[i]; proposals[i] = proposals[j]; proposals[j] = temp;
         }
}

void ResolveAndExecute(STradeProposal &proposals[], const SMarket &market, SRiskLedger &ledger)
{
   SortProposals(proposals);
   bool entryTaken = false;
   for(int i = 0; i < ArraySize(proposals); i++)
   {
      STradeProposal &proposal = proposals[i];
      if(!proposal.valid) continue;
      if(!InpAllowMultipleEntriesSameBar && entryTaken)
      {
         Audit("PROPOSAL_BLOCKED", EngineName(proposal.engine), DirectionName(proposal.direction), "Entry already accepted this bar");
         continue;
      }
      SLane &lane = g_lanes[LaneIndex(proposal.engine, proposal.direction)];
      if(lane.state != LANE_IDLE)
      {
         Audit("PROPOSAL_BLOCKED", EngineName(proposal.engine), DirectionName(proposal.direction), "Lane is not idle");
         continue;
      }
      string reason;
      if(!RiskGovernorApprove(proposal, market, ledger, reason))
      {
         lane.lastReason = reason;
         Audit("RISK_BLOCK", EngineName(proposal.engine), DirectionName(proposal.direction), reason,
               proposal.entry, proposal.sl, proposal.tp);
         continue;
      }
      if(SubmitProposal(proposal, lane, ledger))
      {
         entryTaken = true;
         ledger.openPositions++;
      }
   }
}

int OnInit()
{
   if(InpProfileBars < 10 || InpPriceBins < 10 || InpValueAreaPct <= 0.0 || InpValueAreaPct > 100.0 ||
      InpRiskPercentPerTrade <= 0.0 || InpMaxOpenRiskPercent <= 0.0 || InpATRPeriod < 2 ||
      InpEMAPeriod < 2 || InpVolumeMAPeriod < 2 || InpSwingLookback < 1)
      return INIT_PARAMETERS_INCORRECT;

   if(InpRequireHedgingAccount && AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("This EA requires an MT5 Hedging account.");
      return INIT_FAILED;
   }
   g_atrHandle = iATR(_Symbol, _Period, InpATRPeriod);
   g_emaHandle = iMA(_Symbol, _Period, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_atrHandle == INVALID_HANDLE || g_emaHandle == INVALID_HANDLE)
   {
      if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
      if(g_emaHandle != INVALID_HANDLE) IndicatorRelease(g_emaHandle);
      return INIT_FAILED;
   }
   InitializeLanes();
   LoadPersistentState();
   if(g_peakEquity <= 0.0) g_peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_portfolioState == PORTFOLIO_BOOT) g_portfolioState = PORTFOLIO_READY;
   if(g_lastBrokerDay == 0) g_lastBrokerDay = BrokerDayStart();
   g_lastBarTime = iTime(_Symbol, _Period, 0);
   ReconcileLanes();
   SavePersistentState();
   Audit("INIT", "", "", "Version 1.11 initialized");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   SavePersistentState();
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   if(g_emaHandle != INVALID_HANDLE) IndicatorRelease(g_emaHandle);
   Audit("DEINIT", "", "", (string)reason);
}

void OnTick()
{
   HandleDailyRollover();
   SRiskLedger ledger;
   RefreshRiskLedger(ledger);
   if(!ApplyPortfolioStops(ledger)) return;
   ReconcileLanes();
   if(!IsNewBar()) return;

   SMarket market;
   if(!LoadMarket(market)) { Audit("DATA_BLOCK", "", "", "Market snapshot unavailable"); return; }

   // Frozen pre-signal profile: bars 2..(ProfileBars+1), while bar 1 confirms the setup.
   if(!g_profile.BuildFromSnapshot(market.rates, 2, InpProfileBars, InpPriceBins, InpValueAreaPct, InpUseRealVolume))
   {
      Audit("DATA_BLOCK", "", "", "Profile build failed");
      return;
   }

   STradeProposal proposals[];
   ArrayResize(proposals, 0);
   if(InpEnableVARejection)
   {
      int n = ArraySize(proposals); ArrayResize(proposals, n + 1);
      proposals[n] = BuildVARejection(market, g_profile);
   }
   if(InpEnableVABreakout)
   {
      int n = ArraySize(proposals); ArrayResize(proposals, n + 1);
      proposals[n] = BuildVABreakout(market, g_profile);
   }
   if(InpEnablePOCReversion)
   {
      int n = ArraySize(proposals); ArrayResize(proposals, n + 1);
      proposals[n] = BuildPOCReversion(market, g_profile);
   }
   RefreshRiskLedger(ledger);
   ResolveAndExecute(proposals, market, ledger);
}

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      if(!HistoryDealSelect(trans.deal)) return;
      if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol) return;
      long magic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
      if(!IsOurMagic(magic)) return;

      long entryType = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
      double dealPrice = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
      double dealVolume = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
      ulong positionId = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
      uint dealReason = (uint)HistoryDealGetInteger(trans.deal, DEAL_REASON);
      string dealComment = HistoryDealGetString(trans.deal, DEAL_COMMENT);

      if(entryType == DEAL_ENTRY_IN)
      {
         int idx = LaneIndexByOrderTicket(trans.order);
         if(idx < 0)
         {
            ENUM_ENGINE eng = (magic == (long)EngineMagic(ENGINE_POC_REVERSION)) ? ENGINE_POC_REVERSION :
                              (magic == (long)EngineMagic(ENGINE_VA_BREAKOUT)) ? ENGINE_VA_BREAKOUT : ENGINE_VA_REJECTION;
            ENUM_ORDER_TYPE dir = HistoryDealGetInteger(trans.deal, DEAL_TYPE) == DEAL_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
            idx = LaneIndex(eng, dir);
         }
         SLane &lane = g_lanes[idx];
         ReleaseLaneReservation(lane);
         lane.state = LANE_OPEN;
         lane.positionIdentifier = positionId;
         lane.orderTicket = 0;
         Audit("FILL_CONFIRMED", EngineName(lane.engine), DirectionName(lane.direction), "Position opened",
               lane.requestedEntry, 0.0, 0.0, lane.requestedVolume, lane.lastRiskMoney, dealReason,
               trans.order, trans.deal, positionId, dealPrice, dealVolume, dealComment);
      }
      else if(entryType == DEAL_ENTRY_OUT || entryType == DEAL_ENTRY_OUT_BY)
      {
         int idx = LaneIndexByPosition(positionId);
         if(idx >= 0)
         {
            SLane &lane = g_lanes[idx];
            double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
            double commission = HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
            double swap = HistoryDealGetDouble(trans.deal, DEAL_SWAP);
            double netPnL = profit + commission + swap;
            double rMultiple = lane.lastRiskMoney > 0.0 ? netPnL / lane.lastRiskMoney : 0.0;
            Audit("EXIT_CONFIRMED", EngineName(lane.engine), DirectionName(lane.direction), "Position exit deal",
                  0.0, 0.0, 0.0, dealVolume, lane.lastRiskMoney, dealReason,
                  trans.order, trans.deal, positionId, dealPrice, dealVolume, dealComment,
                  commission, swap, netPnL, rMultiple);
            if(!HasPositionForLane(lane.engine, lane.direction))
            {
               lane.state = LANE_COOLDOWN;
               lane.cooldownUntil = TimeCurrent() + InpCooldownBars * PeriodSeconds(_Period);
               lane.positionIdentifier = 0;
               lane.lastRiskMoney = 0.0;
            }
         }
      }
   }
   else if(trans.type == TRADE_TRANSACTION_REQUEST)
   {
      if(result.retcode != 0 && !IsSuccessfulRetcode(result.retcode))
      {
         int idx = LaneIndexByOrderTicket(result.order);
         if(idx >= 0)
         {
            SLane &lane = g_lanes[idx];
            Audit("TRANSACTION_REJECT", EngineName(lane.engine), DirectionName(lane.direction), result.comment,
                  0,0,0,0,0, result.retcode);
            ResetLane(lane);
         }
         else
         {
            Audit("TRANSACTION_REJECT", "", "", result.comment, 0,0,0,0,0, result.retcode);
         }
      }
   }
}
//+------------------------------------------------------------------+
