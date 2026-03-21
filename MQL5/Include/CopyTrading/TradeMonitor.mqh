//+------------------------------------------------------------------+
//| CopyTrading/TradeMonitor.mqh                                     |
//| Monitors master account positions and detects trade events       |
//+------------------------------------------------------------------+
#pragma once
#include "Defines.mqh"
#include "Logger.mqh"
#include "Signal.mqh"

//+------------------------------------------------------------------+
//| Snapshot of a single open position at a given point in time      |
//+------------------------------------------------------------------+
struct SPositionSnapshot
  {
   ulong             ticket;
   string            symbol;
   int               type;        // POSITION_TYPE_BUY or POSITION_TYPE_SELL
   double            volume;
   double            openPrice;
   double            stopLoss;
   double            takeProfit;
   int               magic;
   string            comment;
   datetime          openTime;
  };

//+------------------------------------------------------------------+
//| CTradeMonitor                                                    |
//| Detects new positions, modifications, and closures on the master |
//| account.  Call OnTrade() on every EA OnTrade() event, then drain |
//| the signal queue via GetNextSignal() / HasPendingSignals().       |
//+------------------------------------------------------------------+
class CTradeMonitor
  {
private:
   //--- Snapshots
   SPositionSnapshot m_prevSnapshot[];   // State as of the last OnTrade() call
   SPositionSnapshot m_currSnapshot[];   // State captured during current scan
   int               m_prevCount;        // Valid entries in m_prevSnapshot
   int               m_currCount;        // Valid entries in m_currSnapshot

   //--- Signal queue
   CSignal           m_pendingSignals[]; // Detected signals awaiting dispatch
   int               m_pendingCount;     // Number of valid signals in queue

   //--- Configuration
   string            m_masterId;
   string            m_allowedSymbols[]; // Parsed allowed-symbol list (empty = all)
   int               m_symbolCount;      // Valid entries in m_allowedSymbols
   bool              m_filterByMagic;
   int               m_filterMagic;
   ENUM_DIRECTION_FILTER m_dirFilter;

   //--- Dependencies
   CLogger          *m_logger;

   //--- Runtime state
   double            m_masterEquity;     // Updated every OnTrade() scan

   //--- Private helpers
   void              ScanCurrentPositions();
   void              DetectNewPositions();
   void              DetectModifications();
   void              DetectClosures();
   void              UpdateSnapshot();
   bool              FindInSnapshot(ulong ticket,
                                    const SPositionSnapshot &arr[],
                                    int count,
                                    SPositionSnapshot &found) const;
   void              AddSignal(const CSignal &signal);
   bool              PopulateSnapshotEntry(int posIndex,
                                           SPositionSnapshot &snap) const;

public:
                     CTradeMonitor();

   //--- Lifecycle
   bool              Init(CLogger *logger,
                          string   masterId,
                          bool     filterByMagic = false,
                          int      magic         = 0,
                          ENUM_DIRECTION_FILTER dirFilter = DIR_BOTH);

   //--- Called by the EA's OnTrade() handler
   void              OnTrade();

   //--- Signal queue interface
   bool              GetNextSignal(CSignal &signal);
   bool              HasPendingSignals() const { return m_pendingCount > 0; }

   //--- Symbol filter
   void              SetSymbolFilter(string symbols);
   bool              IsSymbolAllowed(string symbol) const;

   //--- Direction filter
   bool              IsDirectionAllowed(ENUM_ORDER_TYPE orderType) const;

   //--- Getters
   double            GetMasterEquity()   const { return m_masterEquity; }
   int               GetPendingCount()   const { return m_pendingCount; }
  };

//+------------------------------------------------------------------+
//| Constructor — zero / safe defaults                               |
//+------------------------------------------------------------------+
CTradeMonitor::CTradeMonitor()
  {
   m_prevCount    = 0;
   m_currCount    = 0;
   m_pendingCount = 0;
   m_symbolCount  = 0;
   m_masterId     = "";
   m_filterByMagic = false;
   m_filterMagic  = 0;
   m_dirFilter    = DIR_BOTH;
   m_logger       = NULL;
   m_masterEquity = 0.0;

   ArrayResize(m_prevSnapshot,   0);
   ArrayResize(m_currSnapshot,   0);
   ArrayResize(m_pendingSignals, 0);
   ArrayResize(m_allowedSymbols, 0);
  }

//+------------------------------------------------------------------+
//| Initialise the monitor                                           |
//+------------------------------------------------------------------+
bool CTradeMonitor::Init(CLogger *logger,
                         string   masterId,
                         bool     filterByMagic = false,
                         int      magic         = 0,
                         ENUM_DIRECTION_FILTER dirFilter = DIR_BOTH)
  {
   if(logger == NULL)
     {
      Print("CTradeMonitor::Init — logger pointer is NULL");
      return false;
     }

   if(masterId == "")
     {
      Print("CTradeMonitor::Init — masterId is empty");
      return false;
     }

   m_logger        = logger;
   m_masterId      = masterId;
   m_filterByMagic = filterByMagic;
   m_filterMagic   = magic;
   m_dirFilter     = dirFilter;

   // Pre-allocate arrays to a reasonable initial capacity
   ArrayResize(m_prevSnapshot,   32);
   ArrayResize(m_currSnapshot,   32);
   ArrayResize(m_pendingSignals, CT_MAX_QUEUE_SIZE);

   m_prevCount    = 0;
   m_currCount    = 0;
   m_pendingCount = 0;

   // Take initial snapshot so the first OnTrade() call has a baseline
   ScanCurrentPositions();
   UpdateSnapshot();

   m_masterEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   m_logger.Info("TradeMonitor initialised",
                 "masterId="   + m_masterId +
                 " magicFilter=" + (m_filterByMagic
                                    ? IntegerToString(m_filterMagic)
                                    : "off") +
                 " dirFilter=" + EnumToString(m_dirFilter));
   return true;
  }

//+------------------------------------------------------------------+
//| OnTrade — detect all changes since the last call                 |
//+------------------------------------------------------------------+
void CTradeMonitor::OnTrade()
  {
   if(m_logger == NULL)
      return;

   ScanCurrentPositions();
   DetectNewPositions();
   DetectModifications();
   DetectClosures();
   UpdateSnapshot();

   m_masterEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   m_logger.Debug("OnTrade scan complete",
                  "positions=" + IntegerToString(m_currCount) +
                  " pendingSignals=" + IntegerToString(m_pendingCount));
  }

//+------------------------------------------------------------------+
//| ScanCurrentPositions — populate m_currSnapshot from live state   |
//+------------------------------------------------------------------+
void CTradeMonitor::ScanCurrentPositions()
  {
   m_currCount = 0;
   int total   = PositionsTotal();

   // Ensure the array is large enough (grow on demand)
   if(ArraySize(m_currSnapshot) < total)
      ArrayResize(m_currSnapshot, total + 16);

   for(int i = 0; i < total; i++)
     {
      SPositionSnapshot snap;
      if(!PopulateSnapshotEntry(i, snap))
         continue;

      // Magic-number filter
      if(m_filterByMagic && snap.magic != m_filterMagic)
         continue;

      // Symbol filter
      if(!IsSymbolAllowed(snap.symbol))
         continue;

      m_currSnapshot[m_currCount] = snap;
      m_currCount++;
     }

   m_logger.Trace("ScanCurrentPositions",
                  "total=" + IntegerToString(total) +
                  " accepted=" + IntegerToString(m_currCount));
  }

//+------------------------------------------------------------------+
//| PopulateSnapshotEntry — read position fields into snap struct    |
//+------------------------------------------------------------------+
bool CTradeMonitor::PopulateSnapshotEntry(int posIndex,
                                          SPositionSnapshot &snap) const
  {
   ulong ticket = PositionGetTicket(posIndex);
   if(ticket == 0)
      return false;

   snap.ticket     = ticket;
   snap.symbol     = PositionGetString(POSITION_SYMBOL);
   snap.type       = (int)PositionGetInteger(POSITION_TYPE);
   snap.volume     = PositionGetDouble(POSITION_VOLUME);
   snap.openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
   snap.stopLoss   = PositionGetDouble(POSITION_SL);
   snap.takeProfit = PositionGetDouble(POSITION_TP);
   snap.magic      = (int)PositionGetInteger(POSITION_MAGIC);
   snap.comment    = PositionGetString(POSITION_COMMENT);
   snap.openTime   = (datetime)PositionGetInteger(POSITION_TIME);
   return true;
  }

//+------------------------------------------------------------------+
//| DetectNewPositions — tickets in curr but absent from prev        |
//+------------------------------------------------------------------+
void CTradeMonitor::DetectNewPositions()
  {
   for(int i = 0; i < m_currCount; i++)
     {
      SPositionSnapshot curr = m_currSnapshot[i];

      SPositionSnapshot dummy;
      if(FindInSnapshot(curr.ticket, m_prevSnapshot, m_prevCount, dummy))
         continue; // Already known

      // Determine order type from position type
      ENUM_ORDER_TYPE orderType = (curr.type == POSITION_TYPE_BUY)
                                  ? ORDER_TYPE_BUY
                                  : ORDER_TYPE_SELL;

      // Direction filter
      if(!IsDirectionAllowed(orderType))
        {
         m_logger.Debug("DetectNewPositions: skipped — direction filter",
                        "ticket=" + IntegerToString((long)curr.ticket) +
                        " type="  + EnumToString(orderType));
         continue;
        }

      // Build market-order signal
      CSignal sig;
      sig.signalId     = sig.GenerateUUID((long)AccountInfoInteger(ACCOUNT_LOGIN));
      sig.masterId     = m_masterId;
      sig.timestamp    = TimeCurrent();
      sig.type         = SIGNAL_MARKET_ORDER;
      sig.orderType    = orderType;
      sig.symbol       = curr.symbol;
      sig.volume       = curr.volume;
      sig.price        = curr.openPrice;
      sig.stopLoss     = curr.stopLoss;
      sig.takeProfit   = curr.takeProfit;
      sig.masterTicket = curr.ticket;
      sig.magicNumber  = curr.magic;
      sig.comment      = curr.comment;
      sig.masterEquity = m_masterEquity;
      sig.slippage     = CT_MAX_SLIPPAGE;

      AddSignal(sig);

      m_logger.Info("New position detected",
                    "ticket=" + IntegerToString((long)curr.ticket) +
                    " symbol=" + curr.symbol +
                    " type="   + EnumToString(orderType) +
                    " vol="    + DoubleToString(curr.volume, 4));
     }
  }

//+------------------------------------------------------------------+
//| DetectModifications — same ticket, SL or TP changed             |
//+------------------------------------------------------------------+
void CTradeMonitor::DetectModifications()
  {
   for(int i = 0; i < m_currCount; i++)
     {
      SPositionSnapshot curr = m_currSnapshot[i];

      SPositionSnapshot prev;
      if(!FindInSnapshot(curr.ticket, m_prevSnapshot, m_prevCount, prev))
         continue; // New position — handled by DetectNewPositions

      bool slChanged = (MathAbs(curr.stopLoss   - prev.stopLoss)   > 1e-10);
      bool tpChanged = (MathAbs(curr.takeProfit - prev.takeProfit) > 1e-10);

      if(!slChanged && !tpChanged)
         continue;

      CSignal sig;
      sig.signalId      = sig.GenerateUUID((long)AccountInfoInteger(ACCOUNT_LOGIN));
      sig.masterId      = m_masterId;
      sig.timestamp     = TimeCurrent();
      sig.type          = SIGNAL_MODIFY;
      sig.orderType     = (curr.type == POSITION_TYPE_BUY)
                          ? ORDER_TYPE_BUY
                          : ORDER_TYPE_SELL;
      sig.symbol        = curr.symbol;
      sig.volume        = curr.volume;
      sig.price         = curr.openPrice;
      sig.masterTicket  = curr.ticket;
      sig.magicNumber   = curr.magic;
      sig.comment       = curr.comment;
      sig.masterEquity  = m_masterEquity;
      sig.newStopLoss   = curr.stopLoss;
      sig.newTakeProfit = curr.takeProfit;
      // Carry current SL/TP in the main fields too for convenience
      sig.stopLoss      = curr.stopLoss;
      sig.takeProfit    = curr.takeProfit;

      AddSignal(sig);

      m_logger.Info("Position modified",
                    "ticket=" + IntegerToString((long)curr.ticket) +
                    " symbol=" + curr.symbol +
                    " newSL="  + DoubleToString(curr.stopLoss, 5) +
                    " newTP="  + DoubleToString(curr.takeProfit, 5));
     }
  }

//+------------------------------------------------------------------+
//| DetectClosures — tickets present in prev but absent from curr    |
//+------------------------------------------------------------------+
void CTradeMonitor::DetectClosures()
  {
   for(int i = 0; i < m_prevCount; i++)
     {
      SPositionSnapshot prev = m_prevSnapshot[i];

      SPositionSnapshot dummy;
      if(FindInSnapshot(prev.ticket, m_currSnapshot, m_currCount, dummy))
         continue; // Still open

      CSignal sig;
      sig.signalId     = sig.GenerateUUID((long)AccountInfoInteger(ACCOUNT_LOGIN));
      sig.masterId     = m_masterId;
      sig.timestamp    = TimeCurrent();
      sig.type         = SIGNAL_CLOSE;
      sig.orderType    = (prev.type == POSITION_TYPE_BUY)
                         ? ORDER_TYPE_BUY
                         : ORDER_TYPE_SELL;
      sig.symbol       = prev.symbol;
      sig.volume       = prev.volume;
      sig.price        = prev.openPrice;
      sig.stopLoss     = prev.stopLoss;
      sig.takeProfit   = prev.takeProfit;
      sig.masterTicket = prev.ticket;
      sig.magicNumber  = prev.magic;
      sig.comment      = prev.comment;
      sig.masterEquity = m_masterEquity;

      AddSignal(sig);

      m_logger.Info("Position closed",
                    "ticket=" + IntegerToString((long)prev.ticket) +
                    " symbol=" + prev.symbol +
                    " vol="    + DoubleToString(prev.volume, 4));
     }
  }

//+------------------------------------------------------------------+
//| UpdateSnapshot — promote curr to prev for the next cycle         |
//+------------------------------------------------------------------+
void CTradeMonitor::UpdateSnapshot()
  {
   // Ensure prev array is large enough
   if(ArraySize(m_prevSnapshot) < m_currCount)
      ArrayResize(m_prevSnapshot, m_currCount + 16);

   for(int i = 0; i < m_currCount; i++)
      m_prevSnapshot[i] = m_currSnapshot[i];

   m_prevCount = m_currCount;
  }

//+------------------------------------------------------------------+
//| FindInSnapshot — linear search by ticket; returns true if found  |
//+------------------------------------------------------------------+
bool CTradeMonitor::FindInSnapshot(ulong ticket,
                                   const SPositionSnapshot &arr[],
                                   int count,
                                   SPositionSnapshot &found) const
  {
   for(int i = 0; i < count; i++)
     {
      if(arr[i].ticket == ticket)
        {
         found = arr[i];
         return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| AddSignal — append to the pending queue, growing it if needed    |
//+------------------------------------------------------------------+
void CTradeMonitor::AddSignal(const CSignal &signal)
  {
   // Guard against queue overflow
   if(m_pendingCount >= CT_MAX_QUEUE_SIZE)
     {
      if(m_logger != NULL)
         m_logger.Warn("AddSignal: pending queue full — dropping oldest signal",
                       "queueSize=" + IntegerToString(m_pendingCount));

      // Shift the queue left by one to make room (oldest discarded)
      for(int i = 0; i < m_pendingCount - 1; i++)
         m_pendingSignals[i] = m_pendingSignals[i + 1];
      m_pendingCount--;
     }

   // Grow the backing array if the allocated size is exhausted
   if(m_pendingCount >= ArraySize(m_pendingSignals))
      ArrayResize(m_pendingSignals, m_pendingCount + 16);

   m_pendingSignals[m_pendingCount] = signal;
   m_pendingCount++;
  }

//+------------------------------------------------------------------+
//| GetNextSignal — pop the oldest signal from the front of the queue|
//+------------------------------------------------------------------+
bool CTradeMonitor::GetNextSignal(CSignal &signal)
  {
   if(m_pendingCount == 0)
      return false;

   signal = m_pendingSignals[0];

   // Shift remaining signals left
   for(int i = 0; i < m_pendingCount - 1; i++)
      m_pendingSignals[i] = m_pendingSignals[i + 1];

   m_pendingCount--;
   return true;
  }

//+------------------------------------------------------------------+
//| SetSymbolFilter — parse a comma-separated symbol list            |
//| Examples: "EURUSD,GBPUSD,USDJPY"  or "" (empty = allow all)     |
//+------------------------------------------------------------------+
void CTradeMonitor::SetSymbolFilter(string symbols)
  {
   m_symbolCount = 0;
   ArrayResize(m_allowedSymbols, 0);

   if(symbols == "")
     {
      if(m_logger != NULL)
         m_logger.Debug("SetSymbolFilter: symbol filter cleared (all symbols allowed)");
      return;
     }

   // Tokenise on commas
   string token  = "";
   int    len    = StringLen(symbols);
   int    count  = 0;

   ArrayResize(m_allowedSymbols, 32); // Initial allocation; grows as needed

   for(int i = 0; i <= len; i++)
     {
      string ch = (i < len) ? StringSubstr(symbols, i, 1) : ",";
      if(ch == ",")
        {
         // Trim whitespace from token
         StringTrimLeft(token);
         StringTrimRight(token);

         if(StringLen(token) > 0)
           {
            if(count >= ArraySize(m_allowedSymbols))
               ArrayResize(m_allowedSymbols, count + 16);

            StringToUpper(token);
            m_allowedSymbols[count] = token;
            count++;
           }
         token = "";
        }
      else
        {
         token += ch;
        }
     }

   m_symbolCount = count;
   ArrayResize(m_allowedSymbols, m_symbolCount);

   if(m_logger != NULL)
     {
      string list = "";
      for(int i = 0; i < m_symbolCount; i++)
         list += (i > 0 ? "," : "") + m_allowedSymbols[i];
      m_logger.Info("SetSymbolFilter: filter set",
                    "symbols=" + list +
                    " count="  + IntegerToString(m_symbolCount));
     }
  }

//+------------------------------------------------------------------+
//| IsSymbolAllowed — check against the symbol filter                |
//| Returns true if the list is empty (no filter) or symbol matches  |
//+------------------------------------------------------------------+
bool CTradeMonitor::IsSymbolAllowed(string symbol) const
  {
   if(m_symbolCount == 0)
      return true; // No filter — all symbols permitted

   // Normalise to upper-case for case-insensitive comparison
   string upper = symbol;
   StringToUpper(upper);

   for(int i = 0; i < m_symbolCount; i++)
     {
      if(m_allowedSymbols[i] == upper)
         return true;
     }

   return false;
  }

//+------------------------------------------------------------------+
//| IsDirectionAllowed — test an order type against m_dirFilter      |
//+------------------------------------------------------------------+
bool CTradeMonitor::IsDirectionAllowed(ENUM_ORDER_TYPE orderType) const
  {
   bool isBuy = (orderType == ORDER_TYPE_BUY         ||
                 orderType == ORDER_TYPE_BUY_LIMIT    ||
                 orderType == ORDER_TYPE_BUY_STOP     ||
                 orderType == ORDER_TYPE_BUY_STOP_LIMIT);

   switch(m_dirFilter)
     {
      case DIR_BOTH:
         return true;

      case DIR_BUY_ONLY:
         return isBuy;

      case DIR_SELL_ONLY:
         return !isBuy;

      case DIR_REVERSE:
         // Reversal is applied at replication time; both directions are forwarded
         return true;

      default:
         return true;
     }
  }
