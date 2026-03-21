//+------------------------------------------------------------------+
//| CopyTrading/RiskManager.mqh                                      |
//| Risk management and trade validation                             |
//+------------------------------------------------------------------+
#ifndef COPYTRADING_RISKMANAGER_MQH
#define COPYTRADING_RISKMANAGER_MQH
#include "Defines.mqh"
#include "Logger.mqh"
#include "Signal.mqh"

//+------------------------------------------------------------------+
//| CRiskManager                                                     |
//| Validates trades against risk limits and monitors account health |
//+------------------------------------------------------------------+
class CRiskManager
  {
private:
   //--- Configuration
   double            m_maxDrawdownPct;      // Max allowed drawdown % (default 20%)
   double            m_dailyLossLimit;      // Daily loss limit in currency (0=disabled)
   double            m_dailyLossPct;        // Daily loss limit as % of start equity (0=disabled)
   int               m_maxOpenPositions;    // Max open positions (default 20)
   double            m_minMarginLevelPct;   // Min margin level % (default 200%)
   bool              m_requireStopLoss;     // Require SL on all trades
   int               m_emergencySLPips;     // Emergency SL distance in pips when SL missing
   bool              m_closeOnDrawdown;     // Close all positions when drawdown limit hit

   //--- Runtime state
   double            m_highestEquity;       // Peak equity for drawdown calculation
   double            m_dayStartEquity;      // Equity at start of the trading day
   datetime          m_dayStartTime;        // Timestamp of the day start
   bool              m_copyingHalted;       // True when copying has been suspended
   string            m_haltReason;          // Reason copying was halted
   double            m_warningDrawdownPct;  // Warning threshold (75% of max by default)

   //--- Drawdown warning state — emit the warning only once per threshold crossing
   bool              m_drawdownWarnIssued;
   //--- Daily loss warning state — emit only once per day crossing 50% of limit
   bool              m_dailyLossWarnIssued;

   CLogger          *m_logger;

   //--- Private helpers
   void              CloseAllPositions();

public:
                     CRiskManager();

   //--- Initialisation
   bool              Init(CLogger *logger,
                          double   maxDrawdownPct,
                          double   dailyLossLimit,
                          int      maxPositions,
                          double   minMarginPct,
                          bool     requireSL,
                          int      emergencySLPips,
                          bool     closeOnDrawdown);

   //--- Core validation — called before every order send
   bool              ValidateTrade(const CSignal &signal, double lotSize);

   //--- Called on every EA OnTick() to maintain continuous monitoring
   void              OnTick();

   //--- Individual checks (public so EA can call for diagnostics)
   bool              CheckDrawdown();
   bool              CheckDailyLoss();
   bool              CheckPositionCount();
   bool              CheckMargin(string symbol,
                                 ENUM_ORDER_TYPE orderType,
                                 double          lots,
                                 double          price);
   bool              EnforceSLPolicy(CSignal &signal);

   //--- Day boundary reset
   void              ResetDailyLimits(datetime serverTime);

   //--- Halt management
   void              HaltCopying(string reason);
   void              ManualReset();

   //--- Getters / setters
   bool              IsCopyingAllowed()  { return !m_copyingHalted; }
   string            GetHaltReason()     { return m_haltReason; }
   double            GetCurrentDrawdown();
   double            GetDailyPnL();
   void              SetDailyLossPct(double pct) { m_dailyLossPct = pct; }
  };

//+------------------------------------------------------------------+
//| Constructor — safe zero / default initialisation                 |
//+------------------------------------------------------------------+
CRiskManager::CRiskManager()
  {
   m_maxDrawdownPct     = 20.0;
   m_dailyLossLimit     = 0.0;
   m_dailyLossPct       = 0.0;
   m_maxOpenPositions   = 20;
   m_minMarginLevelPct  = 200.0;
   m_requireStopLoss    = false;
   m_emergencySLPips    = 50;
   m_closeOnDrawdown    = false;

   m_highestEquity      = 0.0;
   m_dayStartEquity     = 0.0;
   m_dayStartTime       = 0;
   m_copyingHalted      = false;
   m_haltReason         = "";
   m_warningDrawdownPct = m_maxDrawdownPct * (CT_DRAWDOWN_WARN_PCT / 100.0);

   m_drawdownWarnIssued  = false;
   m_dailyLossWarnIssued = false;

   m_logger = NULL;
  }

//+------------------------------------------------------------------+
//| Initialise the risk manager with caller-supplied parameters      |
//+------------------------------------------------------------------+
bool CRiskManager::Init(CLogger *logger,
                        double   maxDrawdownPct,
                        double   dailyLossLimit,
                        int      maxPositions,
                        double   minMarginPct,
                        bool     requireSL,
                        int      emergencySLPips,
                        bool     closeOnDrawdown)
  {
   if(logger == NULL)
     {
      Print("CRiskManager::Init — logger pointer is NULL");
      return false;
     }

   m_logger             = logger;
   m_maxDrawdownPct     = (maxDrawdownPct  > 0.0) ? maxDrawdownPct  : 20.0;
   m_dailyLossLimit     = dailyLossLimit;
   m_maxOpenPositions   = (maxPositions    > 0)   ? maxPositions    : 20;
   m_minMarginLevelPct  = (minMarginPct    > 0.0) ? minMarginPct    : 200.0;
   m_requireStopLoss    = requireSL;
   m_emergencySLPips    = (emergencySLPips > 0)   ? emergencySLPips : 50;
   m_closeOnDrawdown    = closeOnDrawdown;

   // Derived warning threshold
   m_warningDrawdownPct = m_maxDrawdownPct * (CT_DRAWDOWN_WARN_PCT / 100.0);

   // Seed equity baselines from current account state
   double equity        = AccountInfoDouble(ACCOUNT_EQUITY);
   m_highestEquity      = equity;
   m_dayStartEquity     = equity;
   m_dayStartTime       = TimeCurrent();

   m_copyingHalted      = false;
   m_haltReason         = "";
   m_drawdownWarnIssued  = false;
   m_dailyLossWarnIssued = false;

   m_logger.Info("RiskManager initialised",
                 "maxDD=" + DoubleToString(m_maxDrawdownPct, 2) +
                 "% dailyLimit=" + DoubleToString(m_dailyLossLimit, 2) +
                 " maxPos=" + IntegerToString(m_maxOpenPositions) +
                 " minMargin=" + DoubleToString(m_minMarginLevelPct, 1) + "%");
   return true;
  }

//+------------------------------------------------------------------+
//| ValidateTrade — gate every outbound order through all checks     |
//+------------------------------------------------------------------+
bool CRiskManager::ValidateTrade(const CSignal &signal, double lotSize)
  {
   // Close and modify signals always pass — we must never block them
   if(signal.type == SIGNAL_CLOSE || signal.type == SIGNAL_CLOSE_PARTIAL)
     {
      m_logger.Debug("ValidateTrade: CLOSE/CLOSE_PARTIAL signal allowed without risk checks",
                     "masterTicket=" + IntegerToString((long)signal.masterTicket));
      return true;
     }

   if(signal.type == SIGNAL_MODIFY)
     {
      m_logger.Debug("ValidateTrade: MODIFY signal allowed without risk checks",
                     "masterTicket=" + IntegerToString((long)signal.masterTicket));
      return true;
     }

   // --- 1. Global halt check ---
   if(!IsCopyingAllowed())
     {
      m_logger.Warn("ValidateTrade: copying is halted — trade blocked",
                    "reason=" + m_haltReason +
                    " symbol=" + signal.symbol);
      return false;
     }

   // --- 2. Drawdown check ---
   if(!CheckDrawdown())
     {
      m_logger.Warn("ValidateTrade: drawdown check failed — trade blocked",
                    "symbol=" + signal.symbol);
      return false;
     }

   // --- 3. Daily loss check ---
   if(!CheckDailyLoss())
     {
      m_logger.Warn("ValidateTrade: daily loss check failed — trade blocked",
                    "symbol=" + signal.symbol);
      return false;
     }

   // --- 4. Position count check ---
   if(!CheckPositionCount())
     {
      m_logger.Warn("ValidateTrade: position count check failed — trade blocked",
                    "symbol=" + signal.symbol);
      return false;
     }

   // --- 5. Margin check ---
   double entryPrice = (signal.price > 0.0)
                       ? signal.price
                       : SymbolInfoDouble(signal.symbol, SYMBOL_ASK);
   if(!CheckMargin(signal.symbol, signal.orderType, lotSize, entryPrice))
     {
      m_logger.Warn("ValidateTrade: margin check failed — trade blocked",
                    "symbol=" + signal.symbol +
                    " lots=" + DoubleToString(lotSize, 2));
      return false;
     }

   // --- 6. Stop-loss policy check (may mutate signal.stopLoss) ---
   // Cast away const so EnforceSLPolicy can apply an emergency SL
   CSignal &mutableSignal = const_cast<CSignal &>(signal);
   if(!EnforceSLPolicy(mutableSignal))
     {
      m_logger.Warn("ValidateTrade: SL policy check failed — trade blocked",
                    "symbol=" + signal.symbol);
      return false;
     }

   m_logger.Debug("ValidateTrade: all checks passed",
                  "symbol=" + signal.symbol +
                  " type=" + EnumToString(signal.orderType) +
                  " lots=" + DoubleToString(lotSize, 2));
   return true;
  }

//+------------------------------------------------------------------+
//| OnTick — called every EA tick to track equity and day boundary   |
//+------------------------------------------------------------------+
void CRiskManager::OnTick()
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   // Update running high-water mark
   m_highestEquity = MathMax(m_highestEquity, equity);

   // Check for day rollover (compare calendar date of server time)
   datetime now        = TimeCurrent();
   datetime nowDay     = (datetime)(now - (now % 86400));
   datetime startDay   = (datetime)(m_dayStartTime - (m_dayStartTime % 86400));
   if(nowDay > startDay)
      ResetDailyLimits(now);

   // Continuous drawdown monitoring (may trigger halt)
   CheckDrawdown();

   // Continuous daily loss monitoring (may trigger halt)
   CheckDailyLoss();
  }

//+------------------------------------------------------------------+
//| CheckDrawdown — returns false when limit is breached             |
//+------------------------------------------------------------------+
bool CRiskManager::CheckDrawdown()
  {
   if(m_highestEquity <= 0.0)
      return true;  // No baseline yet — allow through

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd     = (m_highestEquity - equity) / m_highestEquity * 100.0;

   // Hard limit breached
   if(dd >= m_maxDrawdownPct)
     {
      HaltCopying("Max drawdown exceeded: " + DoubleToString(dd, 2) + "%");
      if(m_closeOnDrawdown)
         CloseAllPositions();
      return false;
     }

   // Warning threshold — emit once per crossing
   if(dd >= m_warningDrawdownPct && !m_drawdownWarnIssued)
     {
      m_drawdownWarnIssued = true;
      m_logger.Warn("Drawdown warning: " + DoubleToString(dd, 2) +
                    "% — limit is " + DoubleToString(m_maxDrawdownPct, 2) + "%");
     }
   else if(dd < m_warningDrawdownPct)
     {
      // Reset flag so warning fires again if equity recovers and drops again
      m_drawdownWarnIssued = false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| CheckDailyLoss — returns false when today's loss limit hit       |
//+------------------------------------------------------------------+
bool CRiskManager::CheckDailyLoss()
  {
   if(m_dayStartEquity <= 0.0)
      return true;

   double pnl = AccountInfoDouble(ACCOUNT_EQUITY) - m_dayStartEquity;

   // Currency limit check
   if(m_dailyLossLimit > 0.0 && pnl <= -m_dailyLossLimit)
     {
      HaltCopying("Daily currency loss limit exceeded: PnL=" +
                  DoubleToString(pnl, 2) +
                  " limit=-" + DoubleToString(m_dailyLossLimit, 2));
      return false;
     }

   // Percentage limit check
   if(m_dailyLossPct > 0.0)
     {
      double pnlPct = (pnl / m_dayStartEquity) * 100.0;
      if(pnlPct <= -m_dailyLossPct)
        {
         HaltCopying("Daily loss % limit exceeded: " +
                     DoubleToString(pnlPct, 2) +
                     "% limit=-" + DoubleToString(m_dailyLossPct, 2) + "%");
         return false;
        }

      // Warning at 50% of the percentage limit
      double warnPct = m_dailyLossPct * (CT_DAILY_LOSS_WARN_PCT / 100.0);
      if(pnlPct <= -warnPct && !m_dailyLossWarnIssued)
        {
         m_dailyLossWarnIssued = true;
         m_logger.Warn("Daily loss warning: " + DoubleToString(pnlPct, 2) +
                       "% — limit is -" + DoubleToString(m_dailyLossPct, 2) + "%");
        }
      else if(pnlPct > -warnPct)
        {
         m_dailyLossWarnIssued = false;
        }
     }

   // Currency warning at 50% of currency limit
   if(m_dailyLossLimit > 0.0 && !m_dailyLossWarnIssued)
     {
      double warnAmt = m_dailyLossLimit * (CT_DAILY_LOSS_WARN_PCT / 100.0);
      if(pnl <= -warnAmt)
        {
         m_dailyLossWarnIssued = true;
         m_logger.Warn("Daily loss warning: PnL=" + DoubleToString(pnl, 2) +
                       " — limit=-" + DoubleToString(m_dailyLossLimit, 2));
        }
     }

   return !m_copyingHalted;
  }

//+------------------------------------------------------------------+
//| CheckPositionCount — ensures we do not exceed max open positions |
//+------------------------------------------------------------------+
bool CRiskManager::CheckPositionCount()
  {
   int count = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) == CT_MAGIC_NUMBER)
         count++;
     }

   if(count >= m_maxOpenPositions)
     {
      m_logger.Warn("Max positions reached: " + IntegerToString(count) +
                    "/" + IntegerToString(m_maxOpenPositions));
      return false;
     }

   m_logger.Debug("Position count check passed: " + IntegerToString(count) +
                  "/" + IntegerToString(m_maxOpenPositions));
   return true;
  }

//+------------------------------------------------------------------+
//| CheckMargin — validates that the account can carry the new trade |
//+------------------------------------------------------------------+
bool CRiskManager::CheckMargin(string          symbol,
                                ENUM_ORDER_TYPE orderType,
                                double          lots,
                                double          price)
  {
   double margin = 0.0;
   if(!OrderCalcMargin(orderType, symbol, lots, price, margin))
     {
      m_logger.Error("CheckMargin: OrderCalcMargin failed",
                     "symbol=" + symbol +
                     " type=" + EnumToString(orderType) +
                     " lots=" + DoubleToString(lots, 2) +
                     " error=" + IntegerToString(GetLastError()));
      return false;
     }

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(margin > freeMargin)
     {
      m_logger.Warn("Insufficient margin: need " + DoubleToString(margin, 2) +
                    " have " + DoubleToString(freeMargin, 2),
                    "symbol=" + symbol +
                    " lots=" + DoubleToString(lots, 2));
      return false;
     }

   // Project what margin level would be after the trade opens
   double usedMargin  = AccountInfoDouble(ACCOUNT_MARGIN);
   double totalMargin = usedMargin + margin;
   if(totalMargin > 0.0)
     {
      double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
      double newLevel = equity / totalMargin * 100.0;
      if(newLevel < m_minMarginLevelPct)
        {
         m_logger.Warn("Trade would drop margin level to " +
                       DoubleToString(newLevel, 1) +
                       "% — minimum is " +
                       DoubleToString(m_minMarginLevelPct, 1) + "%",
                       "symbol=" + symbol +
                       " lots=" + DoubleToString(lots, 2));
         return false;
        }
     }

   m_logger.Debug("Margin check passed: required=" + DoubleToString(margin, 2) +
                  " free=" + DoubleToString(freeMargin, 2),
                  "symbol=" + symbol);
   return true;
  }

//+------------------------------------------------------------------+
//| EnforceSLPolicy — applies or validates stop-loss on the signal   |
//+------------------------------------------------------------------+
bool CRiskManager::EnforceSLPolicy(CSignal &signal)
  {
   if(!m_requireStopLoss)
      return true;

   // SL is already set — validate that it is at a sane distance
   if(signal.stopLoss != 0.0)
     {
      // Ensure there is a minimum 1-pip distance between entry and SL
      double point = SymbolInfoDouble(signal.symbol, SYMBOL_POINT);
      if(point <= 0.0)
         point = 0.00001;  // Fallback for non-standard instruments

      double slDist = MathAbs(signal.price - signal.stopLoss);
      double minDist = point * 10.0;  // At least 1 pip
      if(slDist < minDist)
        {
         m_logger.Warn("EnforceSLPolicy: SL distance too small (" +
                       DoubleToString(slDist / point, 1) + " points)",
                       "symbol=" + signal.symbol);
         // Continue — apply emergency SL below to override invalid SL
        }
      else
        {
         m_logger.Debug("EnforceSLPolicy: existing SL accepted",
                        "symbol=" + signal.symbol +
                        " sl=" + DoubleToString(signal.stopLoss, 5));
         return true;
        }
     }

   // No SL (or invalid SL) — apply emergency SL
   double point  = SymbolInfoDouble(signal.symbol, SYMBOL_POINT);
   if(point <= 0.0)
      point = 0.00001;

   // 1 pip = 10 points for 5-digit brokers, direct points for 3-digit
   double slDist = (double)m_emergencySLPips * point * 10.0;

   bool isBuy = (signal.orderType == ORDER_TYPE_BUY         ||
                 signal.orderType == ORDER_TYPE_BUY_LIMIT    ||
                 signal.orderType == ORDER_TYPE_BUY_STOP     ||
                 signal.orderType == ORDER_TYPE_BUY_STOP_LIMIT);

   double entryPrice = (signal.price > 0.0)
                       ? signal.price
                       : SymbolInfoDouble(signal.symbol, isBuy ? SYMBOL_ASK : SYMBOL_BID);

   if(isBuy)
      signal.stopLoss = entryPrice - slDist;
   else
      signal.stopLoss = entryPrice + slDist;

   m_logger.Info("Applied emergency SL: " + IntegerToString(m_emergencySLPips) +
                 " pips",
                 "symbol=" + signal.symbol +
                 " sl=" + DoubleToString(signal.stopLoss, 5));
   return true;
  }

//+------------------------------------------------------------------+
//| ResetDailyLimits — called at midnight (server time day rollover) |
//+------------------------------------------------------------------+
void CRiskManager::ResetDailyLimits(datetime serverTime)
  {
   double currentEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
   m_dayStartEquity      = currentEquity;
   m_dayStartTime        = serverTime;
   m_dailyLossWarnIssued = false;

   // If the halt was solely due to the daily loss limit, lift it automatically
   // so copying resumes at the start of the new day
   if(m_copyingHalted &&
      (StringFind(m_haltReason, "Daily") >= 0 ||
       StringFind(m_haltReason, "daily") >= 0))
     {
      m_copyingHalted = false;
      m_haltReason    = "";
      m_logger.Info("Daily loss halt automatically lifted at day reset");
     }

   m_logger.Info("Daily limits reset",
                 "dayStartEquity=" + DoubleToString(m_dayStartEquity, 2));
  }

//+------------------------------------------------------------------+
//| HaltCopying — suspend all new trade copying                      |
//+------------------------------------------------------------------+
void CRiskManager::HaltCopying(string reason)
  {
   // Do not log or re-notify if already halted for the same reason
   if(m_copyingHalted)
      return;

   m_copyingHalted = true;
   m_haltReason    = reason;

   m_logger.Warn("Copying HALTED: " + reason);

   // MT5 mobile push notification (silently ignores errors if not configured)
   SendNotification("CopyTrading: Copying halted - " + reason);

   // Visible pop-up alert on the chart
   Alert("CopyTrading: " + reason);
  }

//+------------------------------------------------------------------+
//| ManualReset — operator-initiated resume after reviewing a halt   |
//+------------------------------------------------------------------+
void CRiskManager::ManualReset()
  {
   m_copyingHalted      = false;
   m_haltReason         = "";
   m_drawdownWarnIssued  = false;
   m_dailyLossWarnIssued = false;

   // Reset equity high-water mark to current equity so the drawdown
   // calculation starts fresh from the new baseline
   m_highestEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   m_logger.Info("Copying manually resumed",
                 "baselineEquity=" + DoubleToString(m_highestEquity, 2));
  }

//+------------------------------------------------------------------+
//| GetCurrentDrawdown — percentage drop from peak equity            |
//+------------------------------------------------------------------+
double CRiskManager::GetCurrentDrawdown()
  {
   if(m_highestEquity <= 0.0)
      return 0.0;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   return (m_highestEquity - equity) / m_highestEquity * 100.0;
  }

//+------------------------------------------------------------------+
//| GetDailyPnL — profit/loss since start of current trading day     |
//+------------------------------------------------------------------+
double CRiskManager::GetDailyPnL()
  {
   return AccountInfoDouble(ACCOUNT_EQUITY) - m_dayStartEquity;
  }

//+------------------------------------------------------------------+
//| CloseAllPositions — market-close every position carrying our     |
//| magic number (called on drawdown breach when m_closeOnDrawdown)  |
//+------------------------------------------------------------------+
void CRiskManager::CloseAllPositions()
  {
   m_logger.Warn("CloseAllPositions: closing all positions due to drawdown limit");

   // Collect tickets first — modifying the position list while iterating is unsafe
   int   total   = PositionsTotal();
   ulong tickets[];
   int   count   = 0;
   ArrayResize(tickets, total);

   for(int i = 0; i < total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) == CT_MAGIC_NUMBER)
        {
         tickets[count] = ticket;
         count++;
        }
     }

   // Now close each collected position
   for(int i = 0; i < count; i++)
     {
      ulong ticket = tickets[i];
      if(!PositionSelectByTicket(ticket))
        {
         m_logger.Warn("CloseAllPositions: could not select ticket " +
                       IntegerToString((long)ticket));
         continue;
        }

      string sym    = PositionGetString(POSITION_SYMBOL);
      double vol    = PositionGetDouble(POSITION_VOLUME);
      int    ptype  = (int)PositionGetInteger(POSITION_TYPE);

      MqlTradeRequest req  = {};
      MqlTradeResult  res  = {};

      req.action       = TRADE_ACTION_DEAL;
      req.position     = ticket;
      req.symbol       = sym;
      req.volume       = vol;
      req.deviation    = CT_MAX_SLIPPAGE;
      req.magic        = CT_MAGIC_NUMBER;
      req.comment      = "CT_DD_CLOSE";
      req.type_filling = ORDER_FILLING_FOK;

      // Counter-direction order closes the position
      if(ptype == POSITION_TYPE_BUY)
        {
         req.type  = ORDER_TYPE_SELL;
         req.price = SymbolInfoDouble(sym, SYMBOL_BID);
        }
      else
        {
         req.type  = ORDER_TYPE_BUY;
         req.price = SymbolInfoDouble(sym, SYMBOL_ASK);
        }

      if(!OrderSend(req, res))
        {
         m_logger.Error("CloseAllPositions: OrderSend failed for ticket " +
                        IntegerToString((long)ticket) +
                        " retcode=" + IntegerToString(res.retcode),
                        "symbol=" + sym);
        }
      else
        {
         m_logger.Info("CloseAllPositions: closed ticket " +
                       IntegerToString((long)ticket),
                       "symbol=" + sym +
                       " vol=" + DoubleToString(vol, 2));
        }
     }
  }
#endif // COPYTRADING_RISKMANAGER_MQH
