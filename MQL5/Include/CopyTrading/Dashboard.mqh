//+------------------------------------------------------------------+
//| CopyTrading/Dashboard.mqh                                        |
//| On-chart graphical dashboard display                             |
//+------------------------------------------------------------------+
#ifndef COPYTRADING_DASHBOARD_MQH
#define COPYTRADING_DASHBOARD_MQH
#include "Defines.mqh"
#include "PerformanceTracker.mqh"

//+------------------------------------------------------------------+
//| CDashboard                                                       |
//| Creates and manages a set of OBJ_LABEL chart objects that        |
//| display live Copy Trading status for both Master and Follower    |
//| EAs. All labels share a common name prefix so they can be        |
//| cleanly removed on deinit without touching other objects.        |
//+------------------------------------------------------------------+
class CDashboard
  {
private:
   //--- Layout configuration
   int               m_corner;          // Chart corner (ENUM_BASE_CORNER: 0-3)
   int               m_fontSize;
   int               m_x;              // Base X offset in pixels
   int               m_y;              // Base Y offset in pixels
   int               m_lineHeight;     // Vertical pixels between rows

   //--- Colour palette
   color             m_colorNormal;
   color             m_colorPositive;
   color             m_colorNegative;
   color             m_colorWarning;
   color             m_colorHeader;

   //--- State
   bool              m_visible;
   bool              m_isMaster;
   string            m_labels[50];     // Object name registry
   int               m_labelCount;
   string            m_chartSymbol;
   long              m_chartId;

   //--- Private helpers
   string            LabelName(int lineIndex) const;
   void              CreateLabels();
   void              CreateMasterLabels();
   void              CreateFollowerLabels();

public:
                     CDashboard();
                    ~CDashboard();

   //--- Lifecycle
   bool              Init(bool isMaster, int corner = 1, int fontSize = 9);
   void              Destroy();

   //--- Label primitive
   void              CreateLabel(string name, string text, int x, int y, color clr);
   void              SetLabelText(string name, string text, color clr = -1);

   //--- Update facades
   void              UpdateMaster(string signalName,
                                  bool broadcasting,
                                  int followerCount,
                                  int openPositions,
                                  CPerformanceTracker *perf);

   void              UpdateFollower(string masterName,
                                   bool connected,
                                   bool copyingActive,
                                   bool halted,
                                   string haltReason,
                                   int openPositions,
                                   double drawdownPct,
                                   double drawdownLimit,
                                   double marginLevel,
                                   CPerformanceTracker *perf);

   //--- Visibility / colour
   void              SetVisible(bool visible);
   void              SetColors(color positive, color negative, color warning);

   //--- Formatting helpers
   string            FormatPnL(double pnl) const;
   color             GetPnLColor(double pnl) const;
   string            BoolToStatus(bool b, string trueStr, string falseStr) const;
  };

//+------------------------------------------------------------------+
//| Constructor — initialise to safe defaults                        |
//+------------------------------------------------------------------+
CDashboard::CDashboard()
  {
   m_corner        = 1;
   m_fontSize      = 9;
   m_x             = 10;
   m_y             = 20;
   m_lineHeight    = 16;
   m_colorNormal   = clrWhite;
   m_colorPositive = clrLime;
   m_colorNegative = clrTomato;
   m_colorWarning  = clrYellow;
   m_colorHeader   = clrCyan;
   m_visible       = false;
   m_isMaster      = true;
   m_labelCount    = 0;
   m_chartSymbol   = "";
   m_chartId       = 0;
  }

//+------------------------------------------------------------------+
//| Destructor — remove all owned objects on deletion               |
//+------------------------------------------------------------------+
CDashboard::~CDashboard()
  {
   Destroy();
  }

//+------------------------------------------------------------------+
//| Build the object name for a given line index                     |
//+------------------------------------------------------------------+
string CDashboard::LabelName(int lineIndex) const
  {
   return CT_DASHBOARD_OBJ_PREFIX + (m_isMaster ? "M" : "F") +
          "_" + IntegerToString(lineIndex);
  }

//+------------------------------------------------------------------+
//| Initialise the dashboard and create all label objects            |
//+------------------------------------------------------------------+
bool CDashboard::Init(bool isMaster, int corner = 1, int fontSize = 9)
  {
   m_isMaster   = isMaster;
   m_corner     = corner;
   m_fontSize   = fontSize;

   m_chartId     = ChartID();
   m_chartSymbol = ChartSymbol();

   m_x          = 10;
   m_y          = 20;
   m_lineHeight = 16;

   m_colorNormal   = clrWhite;
   m_colorPositive = clrLime;
   m_colorNegative = clrTomato;
   m_colorWarning  = clrYellow;
   m_colorHeader   = clrCyan;

   m_labelCount = 0;
   m_visible    = true;

   CreateLabels();

   ChartRedraw();
   return true;
  }

//+------------------------------------------------------------------+
//| Create a single OBJ_LABEL at the specified position              |
//+------------------------------------------------------------------+
void CDashboard::CreateLabel(string name, string text, int x, int y, color clr)
  {
   // Remove any pre-existing object with this name to avoid conflicts
   ObjectDelete(m_chartId, name);

   ObjectCreate(m_chartId, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(m_chartId, name, OBJPROP_CORNER,    m_corner);
   ObjectSetInteger(m_chartId, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(m_chartId, name, OBJPROP_YDISTANCE, y);
   ObjectSetString (m_chartId, name, OBJPROP_TEXT,      text);
   ObjectSetInteger(m_chartId, name, OBJPROP_COLOR,     clr);
   ObjectSetInteger(m_chartId, name, OBJPROP_FONTSIZE,  m_fontSize);
   ObjectSetString (m_chartId, name, OBJPROP_FONT,      "Courier New");
   ObjectSetInteger(m_chartId, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(m_chartId, name, OBJPROP_HIDDEN,    true);

   // Register name in the label registry (guard against overflow)
   if(m_labelCount < 50)
     {
      m_labels[m_labelCount] = name;
      m_labelCount++;
     }
  }

//+------------------------------------------------------------------+
//| Update the text (and optionally the colour) of an existing label |
//+------------------------------------------------------------------+
void CDashboard::SetLabelText(string name, string text, color clr = -1)
  {
   ObjectSetString(m_chartId, name, OBJPROP_TEXT, text);
   if(clr != (color)(-1))
      ObjectSetInteger(m_chartId, name, OBJPROP_COLOR, clr);
  }

//+------------------------------------------------------------------+
//| Dispatch to the correct layout builder                           |
//+------------------------------------------------------------------+
void CDashboard::CreateLabels()
  {
   if(m_isMaster)
      CreateMasterLabels();
   else
      CreateFollowerLabels();
  }

//+------------------------------------------------------------------+
//| Build the master dashboard skeleton (10 rows)                    |
//|                                                                  |
//| Row  0 : ===== COPY TRADING - MASTER =====  (header)            |
//| Row  1 : Signal: <name>                                          |
//| Row  2 : Status: <status>                                        |
//| Row  3 : ---------------------------------------- (separator)   |
//| Row  4 : Followers : <n>                                         |
//| Row  5 : Today Trades: <n>                                       |
//| Row  6 : Today P&L  : <value>                                    |
//| Row  7 : Win Rate   : <pct>%                                     |
//| Row  8 : Open Pos   : <n>                                        |
//| Row  9 : Success    : <pct>%  (copied / (copied+failed))         |
//+------------------------------------------------------------------+
void CDashboard::CreateMasterLabels()
  {
   int line = 0;

   CreateLabel(LabelName(line), "===== COPY TRADING - MASTER =====",
               m_x, m_y + line * m_lineHeight, m_colorHeader);
   line++;

   CreateLabel(LabelName(line), "Signal  : ---",
               m_x, m_y + line * m_lineHeight, m_colorNormal);
   line++;

   CreateLabel(LabelName(line), "Status  : ---",
               m_x, m_y + line * m_lineHeight, m_colorNormal);
   line++;

   CreateLabel(LabelName(line), "----------------------------------",
               m_x, m_y + line * m_lineHeight, clrDimGray);
   line++;

   CreateLabel(LabelName(line), "Followers : 0",
               m_x, m_y + line * m_lineHeight, m_colorNormal);
   line++;

   CreateLabel(LabelName(line), "Today Trd : 0",
               m_x, m_y + line * m_lineHeight, m_colorNormal);
   line++;

   CreateLabel(LabelName(line), "Today P&L : 0.00",
               m_x, m_y + line * m_lineHeight, m_colorNormal);
   line++;

   CreateLabel(LabelName(line), "Win Rate  : 0.0%",
               m_x, m_y + line * m_lineHeight, m_colorNormal);
   line++;

   CreateLabel(LabelName(line), "Open Pos  : 0",
               m_x, m_y + line * m_lineHeight, m_colorNormal);
   line++;

   CreateLabel(LabelName(line), "Success   : ---",
               m_x, m_y + line * m_lineHeight, m_colorNormal);
  }

//+------------------------------------------------------------------+
//| Build the follower dashboard skeleton (12 rows)                  |
//|                                                                  |
//| Row  0 : ===== COPY TRADING - FOLLOWER =====  (header)          |
//| Row  1 : Master   : <name>                                       |
//| Row  2 : Conn     : <status>                                     |
//| Row  3 : ---------------------------------------- (separator)   |
//| Row  4 : Today P&L : <value>                                     |
//| Row  5 : Total P&L : <value>                                     |
//| Row  6 : Balance   : <value>          ← account balance         |
//| Row  7 : Drawdown  : <pct>% / <limit>%                          |
//| Row  8 : Max DD    : <pct>%           ← historical peak-to-trough|
//| Row  9 : Margin    : <pct>%                                      |
//| Row 10 : Copied/Sip: <n> / <n.n>     ← copies / avg slippage   |
//| Row 11 : Halt      : <reason>                                    |
//+------------------------------------------------------------------+
void CDashboard::CreateFollowerLabels()
  {
   int line = 0;

   CreateLabel(LabelName(line), "===== COPY TRADING - FOLLOWER =====",
               m_x, m_y + line * m_lineHeight, m_colorHeader);
   line++;

   CreateLabel(LabelName(line), "Master  : ---",
               m_x, m_y + line * m_lineHeight, m_colorNormal);
   line++;

   CreateLabel(LabelName(line), "Conn    : ---",
               m_x, m_y + line * m_lineHeight, m_colorNormal);
   line++;

   CreateLabel(LabelName(line), "----------------------------------",
               m_x, m_y + line * m_lineHeight, clrDimGray);
   line++;

   CreateLabel(LabelName(line), "Today P&L : 0.00",
               m_x, m_y + line * m_lineHeight, m_colorNormal);
   line++;

   CreateLabel(LabelName(line), "Total P&L : 0.00",
               m_x, m_y + line * m_lineHeight, m_colorNormal);
   line++;

   CreateLabel(LabelName(line), "Balance   : ---",
               m_x, m_y + line * m_lineHeight, m_colorNormal);
   line++;

   CreateLabel(LabelName(line), "Drawdown  : 0.0% / 0.0%",
               m_x, m_y + line * m_lineHeight, m_colorNormal);
   line++;

   CreateLabel(LabelName(line), "Max DD    : 0.0%",
               m_x, m_y + line * m_lineHeight, m_colorNormal);
   line++;

   CreateLabel(LabelName(line), "Margin    : ---",
               m_x, m_y + line * m_lineHeight, m_colorNormal);
   line++;

   CreateLabel(LabelName(line), "Copied/Sip: 0 / 0.0",
               m_x, m_y + line * m_lineHeight, m_colorNormal);
   line++;

   CreateLabel(LabelName(line), "Halt      : ---",
               m_x, m_y + line * m_lineHeight, m_colorNormal);
  }

//+------------------------------------------------------------------+
//| UpdateMaster — refresh all master dashboard rows with live data  |
//+------------------------------------------------------------------+
void CDashboard::UpdateMaster(string signalName,
                              bool broadcasting,
                              int followerCount,
                              int openPositions,
                              CPerformanceTracker *perf)
  {
   // Row 0: header — static, no update needed

   // Row 1: signal name
   SetLabelText(LabelName(1), "Signal  : " + signalName, m_colorNormal);

   // Row 2: broadcast status
   if(broadcasting)
      SetLabelText(LabelName(2), "Status  : * BROADCASTING", m_colorPositive);
   else
      SetLabelText(LabelName(2), "Status  : o STOPPED", m_colorNegative);

   // Row 3: separator — static

   // Row 4: follower count
   SetLabelText(LabelName(4), "Followers : " + IntegerToString(followerCount),
                m_colorNormal);

   // Row 5: today trades
   int todayTrades = (perf != NULL) ? perf.GetTodayTrades() : 0;
   SetLabelText(LabelName(5), "Today Trd : " + IntegerToString(todayTrades),
                m_colorNormal);

   // Row 6: today P&L
   double todayPnL = (perf != NULL) ? perf.GetTodayProfit() : 0.0;
   SetLabelText(LabelName(6), "Today P&L : " + FormatPnL(todayPnL),
                GetPnLColor(todayPnL));

   // Row 7: win rate
   double winRate = (perf != NULL) ? perf.GetWinRate() : 0.0;
   color  wrColor = (winRate >= 50.0) ? m_colorPositive : m_colorNegative;
   SetLabelText(LabelName(7), "Win Rate  : " + DoubleToString(winRate, 1) + "%",
                wrColor);

   // Row 8: open positions
   SetLabelText(LabelName(8), "Open Pos  : " + IntegerToString(openPositions),
                m_colorNormal);

   // Row 9: total trades (all-time closed)
   int totalTrades = (perf != NULL) ? perf.GetTotalTrades() : 0;
   SetLabelText(LabelName(9), "Total Trd : " + IntegerToString(totalTrades), m_colorNormal);

   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| UpdateFollower — refresh all follower dashboard rows             |
//+------------------------------------------------------------------+
void CDashboard::UpdateFollower(string masterName,
                                bool connected,
                                bool copyingActive,
                                bool halted,
                                string haltReason,
                                int openPositions,
                                double drawdownPct,
                                double drawdownLimit,
                                double marginLevel,
                                CPerformanceTracker *perf)
  {
   // Row 0: header — static

   // Row 1: master name
   SetLabelText(LabelName(1), "Master  : " + masterName, m_colorNormal);

   // Row 2: connection status
   string connStr;
   color  connClr;
   if(connected && copyingActive)
     {
      connStr = "Conn    : * Connected";
      connClr = m_colorPositive;
     }
   else if(connected && !copyingActive)
     {
      connStr = "Conn    : ~ Degraded";
      connClr = m_colorWarning;
     }
   else
     {
      connStr = "Conn    : o Disconnected";
      connClr = m_colorNegative;
     }
   SetLabelText(LabelName(2), connStr, connClr);

   // Row 3: separator — static

   // Row 4: today P&L
   double todayPnL = (perf != NULL) ? perf.GetTodayProfit() : 0.0;
   SetLabelText(LabelName(4), "Today P&L : " + FormatPnL(todayPnL),
                GetPnLColor(todayPnL));

   // Row 5: total (lifetime) net P&L
   double totalPnL = (perf != NULL) ? perf.GetNetProfit() : 0.0;
   SetLabelText(LabelName(5), "Total P&L : " + FormatPnL(totalPnL),
                GetPnLColor(totalPnL));

   // Row 6: account balance
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   SetLabelText(LabelName(6),
                "Balance   : " + DoubleToString(balance, 2),
                m_colorNormal);

   // Row 7: drawdown vs limit
   color ddClr = m_colorNormal;
   if(drawdownLimit > 0.0)
     {
      double ddRatio = drawdownPct / drawdownLimit * 100.0;
      if(ddRatio >= 100.0)
         ddClr = m_colorNegative;
      else if(ddRatio >= (double)CT_DRAWDOWN_WARN_PCT)
         ddClr = m_colorWarning;
      else
         ddClr = m_colorPositive;
     }
   SetLabelText(LabelName(7),
                "Drawdown  : " + DoubleToString(drawdownPct, 1) + "% / " +
                DoubleToString(drawdownLimit, 1) + "%",
                ddClr);

   // Row 8: max historical drawdown (peak-to-trough %)
   double maxDD    = (perf != NULL) ? perf.GetMaxDrawdownPct() : 0.0;
   color  maxDDClr = (maxDD > drawdownLimit * 0.8 && drawdownLimit > 0.0) ? m_colorWarning : m_colorNormal;
   SetLabelText(LabelName(8),
                "Max DD    : " + DoubleToString(maxDD, 1) + "%",
                maxDDClr);

   // Row 9: margin level
   color  marginClr;
   string marginStr;
   if(marginLevel <= 0.0)
     {
      marginStr = "Margin    : N/A";
      marginClr = m_colorNormal;
     }
   else
     {
      marginStr = "Margin    : " + DoubleToString(marginLevel, 1) + "%";
      marginClr = (marginLevel < (double)CT_MARGIN_WARN_PCT) ? m_colorWarning : m_colorNormal;
      if(marginLevel < 150.0)
         marginClr = m_colorNegative;
     }
   SetLabelText(LabelName(9), marginStr, marginClr);

   // Row 10: copied count / average slippage pips
   int    copied  = (perf != NULL) ? perf.GetTradesCopied()     : 0;
   double avgSlip = (perf != NULL) ? perf.GetAverageSlippage()  : 0.0;
   SetLabelText(LabelName(10),
                "Copied/Sip: " + IntegerToString(copied) + " / " +
                DoubleToString(avgSlip, 1),
                m_colorNormal);

   // Row 11: halt status — show reason in red when halted
   if(halted)
      SetLabelText(LabelName(11), "Halt      : " + haltReason, m_colorNegative);
   else
      SetLabelText(LabelName(11), "Halt      : ---", m_colorNormal);

   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Destroy — remove all owned chart objects and reset state         |
//+------------------------------------------------------------------+
void CDashboard::Destroy()
  {
   for(int i = 0; i < m_labelCount; i++)
     {
      if(m_labels[i] != "")
         ObjectDelete(m_chartId, m_labels[i]);
     }
   m_labelCount = 0;
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| SetVisible — show or hide all dashboard labels at once           |
//+------------------------------------------------------------------+
void CDashboard::SetVisible(bool visible)
  {
   m_visible = visible;
   long timeframes = visible ? OBJ_ALL_PERIODS : OBJ_NO_PERIODS;

   for(int i = 0; i < m_labelCount; i++)
     {
      if(m_labels[i] != "")
         ObjectSetInteger(m_chartId, m_labels[i], OBJPROP_TIMEFRAMES, timeframes);
     }
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| SetColors — override the positive / negative / warning palette   |
//+------------------------------------------------------------------+
void CDashboard::SetColors(color positive, color negative, color warning)
  {
   m_colorPositive = positive;
   m_colorNegative = negative;
   m_colorWarning  = warning;
  }

//+------------------------------------------------------------------+
//| FormatPnL — format a P&L value with an explicit sign prefix      |
//| e.g.  1234.56 → "+1,234.56"  |  -78.9 → "-78.90"               |
//+------------------------------------------------------------------+
string CDashboard::FormatPnL(double pnl) const
  {
   string raw = DoubleToString(MathAbs(pnl), 2);
   if(pnl >= 0.0)
      return "+" + raw;
   return "-" + raw;
  }

//+------------------------------------------------------------------+
//| GetPnLColor — positive P&L is green, negative is red, zero white |
//+------------------------------------------------------------------+
color CDashboard::GetPnLColor(double pnl) const
  {
   if(pnl > 0.0)  return m_colorPositive;
   if(pnl < 0.0)  return m_colorNegative;
   return m_colorNormal;
  }

//+------------------------------------------------------------------+
//| BoolToStatus — conditional string selection                      |
//+------------------------------------------------------------------+
string CDashboard::BoolToStatus(bool b, string trueStr, string falseStr) const
  {
   return b ? trueStr : falseStr;
  }
#endif // COPYTRADING_DASHBOARD_MQH
