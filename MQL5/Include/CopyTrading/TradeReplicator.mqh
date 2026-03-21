//+------------------------------------------------------------------+
//| CopyTrading/TradeReplicator.mqh                                  |
//| Executes trade replications on the follower account              |
//+------------------------------------------------------------------+
#ifndef COPYTRADING_TRADEREPLICATOR_MQH
#define COPYTRADING_TRADEREPLICATOR_MQH
#include "Defines.mqh"
#include "Logger.mqh"
#include "Signal.mqh"
#include "MT5Wrapper.mqh"
#include "AllocationEngine.mqh"
#include "RiskManager.mqh"
#include "PerformanceTracker.mqh"

//+------------------------------------------------------------------+
//| CTradeReplicator                                                 |
//| Core of the Follower EA — receives CSignal objects and           |
//| executes matching trades on the local account.  Maintains a      |
//| persistent Master<->Follower position map so modifications,      |
//| partial closes and full closes are routed to the correct local   |
//| ticket regardless of restarts.                                   |
//+------------------------------------------------------------------+
class CTradeReplicator
  {
private:
   //--- Position correspondence map
   SPositionMap      m_positionMap[];          // Master<->Follower ticket pairs
   int               m_positionMapCount;       // Number of live entries

   //--- External dependencies (owned by the caller — never deleted here)
   CMT5Wrapper          *m_mt5;
   CAllocationEngine    *m_allocEngine;
   CRiskManager         *m_riskMgr;
   CLogger              *m_logger;
   CPerformanceTracker  *m_perf;

   //--- Configuration
   string            m_followerId;
   int               m_magicNumber;
   int               m_slippage;
   ENUM_DIRECTION_FILTER m_dirFilter;

   //--- Symbol filter
   string            m_allowedSymbols[];
   int               m_allowedSymbolCount;
   bool              m_filterSymbols;

   //--- Reconciliation
   datetime          m_lastReconcileTime;

   //--- Persistent state file path
   string            m_posMapFile;

   //--- Private helpers
   bool              IsBuyType(ENUM_ORDER_TYPE t);

public:
                     CTradeReplicator();
                    ~CTradeReplicator();

   //--- Lifecycle
   bool              Init(CLogger             *logger,
                          CMT5Wrapper          *mt5,
                          CAllocationEngine    *alloc,
                          CRiskManager         *risk,
                          CPerformanceTracker  *perf,
                          string                followerId,
                          int                   magicNumber = CT_MAGIC_NUMBER,
                          int                   slippage    = CT_MAX_SLIPPAGE);

   //--- Primary entry point
   void              ProcessSignal(CSignal &signal);

   //--- Signal-type handlers
   bool              ReplicateMarketOrder(CSignal &signal);
   bool              ReplicatePendingOrder(CSignal &signal);
   bool              ReplicateModification(const CSignal &signal);
   bool              ReplicateClosure(const CSignal &signal);
   bool              ReplicatePartialClosure(const CSignal &signal);

   //--- Position map management
   void              AddPositionMap(ulong  masterTicket,
                                    ulong  followerTicket,
                                    string symbol,
                                    double masterOpenPrice,
                                    double followerOpenPrice,
                                    double masterVolume,
                                    double followerVolume);
   ulong             FindFollowerTicket(ulong masterTicket);
   bool              RemoveFromPositionMap(ulong masterTicket);

   //--- Persistence
   void              SavePositionMap();
   void              LoadPositionMap();

   //--- Reconciliation
   void              ReconcilePositions();
   bool              NeedReconcile();

   //--- Direction / symbol filters
   void              SetSymbolFilter(string symbols);
   bool              IsSymbolAllowed(string symbol);
   void              SetDirectionFilter(ENUM_DIRECTION_FILTER filter);
   ENUM_ORDER_TYPE   ApplyDirectionFilter(ENUM_ORDER_TYPE orderType);
   bool              ShouldProcessDirection(ENUM_ORDER_TYPE orderType);

   //--- Accessors
   int               GetPositionMapCount() const { return m_positionMapCount; }
  };

//+------------------------------------------------------------------+
//| Constructor — zero / safe-default initialise all members         |
//+------------------------------------------------------------------+
CTradeReplicator::CTradeReplicator()
  {
   m_positionMapCount   = 0;
   m_mt5                = NULL;
   m_allocEngine        = NULL;
   m_riskMgr            = NULL;
   m_logger             = NULL;
   m_perf               = NULL;
   m_followerId         = "";
   m_magicNumber        = CT_MAGIC_NUMBER;
   m_slippage           = CT_MAX_SLIPPAGE;
   m_dirFilter          = DIR_BOTH;
   m_allowedSymbolCount = 0;
   m_filterSymbols      = false;
   m_lastReconcileTime  = 0;
   m_posMapFile         = "";
  }

//+------------------------------------------------------------------+
//| Destructor — dependencies owned externally, not freed here       |
//+------------------------------------------------------------------+
CTradeReplicator::~CTradeReplicator()
  {
   // Flush any pending map changes to disk before destruction
   if(m_positionMapCount > 0)
      SavePositionMap();
  }

//+------------------------------------------------------------------+
//| Init — wire up dependencies and restore persisted map            |
//+------------------------------------------------------------------+
bool CTradeReplicator::Init(CLogger              *logger,
                             CMT5Wrapper           *mt5,
                             CAllocationEngine     *alloc,
                             CRiskManager          *risk,
                             CPerformanceTracker   *perf,
                             string                 followerId,
                             int                    magicNumber = CT_MAGIC_NUMBER,
                             int                    slippage    = CT_MAX_SLIPPAGE)
  {
   if(logger == NULL)
     {
      Print("CTradeReplicator::Init — logger pointer is NULL");
      return false;
     }
   if(mt5 == NULL)
     {
      logger.Error("CTradeReplicator::Init — mt5 pointer is NULL");
      return false;
     }
   if(alloc == NULL)
     {
      logger.Error("CTradeReplicator::Init — allocation engine pointer is NULL");
      return false;
     }
   if(risk == NULL)
     {
      logger.Error("CTradeReplicator::Init — risk manager pointer is NULL");
      return false;
     }
   if(followerId == "")
     {
      logger.Error("CTradeReplicator::Init — followerId is empty");
      return false;
     }

   m_logger       = logger;
   m_mt5          = mt5;
   m_allocEngine  = alloc;
   m_riskMgr      = risk;
   m_perf         = perf;    // may be NULL — all calls guarded with != NULL check
   m_followerId   = followerId;
   m_magicNumber  = (magicNumber > 0) ? magicNumber : CT_MAGIC_NUMBER;
   m_slippage     = (slippage    > 0) ? slippage    : CT_MAX_SLIPPAGE;
   m_dirFilter    = DIR_BOTH;
   m_filterSymbols = false;
   m_allowedSymbolCount = 0;
   m_lastReconcileTime  = 0;

   m_posMapFile = CT_STATE_DIR + CT_POSMAP_PREFIX + followerId + ".csv";

   ArrayResize(m_positionMap, CT_MAX_POSITION_MAP);
   m_positionMapCount = 0;

   LoadPositionMap();

   m_logger.Info("CTradeReplicator initialised",
                 "followerId="  + followerId +
                 " magic="      + IntegerToString(m_magicNumber) +
                 " slippage="   + IntegerToString(m_slippage) +
                 " mapFile="    + m_posMapFile +
                 " mapEntries=" + IntegerToString(m_positionMapCount));
   return true;
  }

//+------------------------------------------------------------------+
//| ProcessSignal — dispatch incoming signal to the correct handler  |
//+------------------------------------------------------------------+
void CTradeReplicator::ProcessSignal(CSignal &signal)
  {
   m_logger.Info("Processing signal: " + signal.signalId +
                 " type=" + IntegerToString((int)signal.type),
                 "symbol=" + signal.symbol +
                 " masterTicket=" + IntegerToString((long)signal.masterTicket));

   // Direction and symbol filters apply only to order-opening signals
   if(signal.type == SIGNAL_MARKET_ORDER || signal.type == SIGNAL_PENDING_ORDER)
     {
      // Direction filter
      if(!ShouldProcessDirection(signal.orderType))
        {
         m_logger.Info("ProcessSignal — signal skipped by direction filter",
                       "signalId="  + signal.signalId +
                       " orderType=" + EnumToString(signal.orderType) +
                       " filter="   + EnumToString(m_dirFilter));
         return;
        }

      // Symbol filter
      if(!IsSymbolAllowed(signal.symbol))
        {
         m_logger.Info("ProcessSignal — signal skipped by symbol filter",
                       "signalId=" + signal.signalId +
                       " symbol="  + signal.symbol);
         return;
        }
     }

   switch(signal.type)
     {
      case SIGNAL_MARKET_ORDER:
         ReplicateMarketOrder(signal);
         break;

      case SIGNAL_PENDING_ORDER:
         ReplicatePendingOrder(signal);
         break;

      case SIGNAL_MODIFY:
         ReplicateModification(signal);
         break;

      case SIGNAL_CLOSE:
         ReplicateClosure(signal);
         break;

      case SIGNAL_CLOSE_PARTIAL:
         ReplicatePartialClosure(signal);
         break;

      default:
         m_logger.Warn("ProcessSignal — unknown signal type",
                       "type=" + IntegerToString((int)signal.type) +
                       " signalId=" + signal.signalId);
         break;
     }
  }

//+------------------------------------------------------------------+
//| ReplicateMarketOrder — open a matching market order              |
//+------------------------------------------------------------------+
bool CTradeReplicator::ReplicateMarketOrder(CSignal &signal)
  {
   // Symbol availability check
   if(!m_mt5.CheckSymbolExists(signal.symbol))
     {
      m_logger.Error("ReplicateMarketOrder — symbol not found on follower",
                     "symbol=" + signal.symbol +
                     " signalId=" + signal.signalId);
      return false;
     }

   // Calculate follower lot size
   double lots = m_allocEngine.CalculateLotSize(signal);
   if(lots <= 0.0)
     {
      m_logger.Error("ReplicateMarketOrder — lot calculation returned 0",
                     "symbol="   + signal.symbol +
                     " signalId=" + signal.signalId);
      return false;
     }

   // Apply direction filter (possibly reverse BUY<->SELL)
   ENUM_ORDER_TYPE orderType = ApplyDirectionFilter(signal.orderType);

   // Risk validation (may mutate signal's SL via EnforceSLPolicy internally)
   if(!m_riskMgr.ValidateTrade(signal, lots))
     {
      m_logger.Info("ReplicateMarketOrder — trade skipped by risk manager",
                    "symbol="   + signal.symbol +
                    " lots="    + DoubleToString(lots, 2) +
                    " signalId=" + signal.signalId);
      return false;
     }

   // Refresh execution price from live market
   double price = (orderType == ORDER_TYPE_BUY)
                  ? m_mt5.GetAsk(signal.symbol)
                  : m_mt5.GetBid(signal.symbol);

   // Use master's absolute SL/TP levels (valid for all forex symbols)
   double followerSL = (signal.stopLoss   != 0.0) ? signal.stopLoss   : 0.0;
   double followerTP = (signal.takeProfit != 0.0) ? signal.takeProfit : 0.0;

   // Build a short comment containing the first 8 characters of the signal ID
   string commentId = (StringLen(signal.signalId) >= 8)
                      ? StringSubstr(signal.signalId, 0, 8)
                      : signal.signalId;
   string comment   = "CT:" + commentId;

   // Execute the market order
   ulong ticket = CT_NULL_TICKET;
   bool  ok     = m_mt5.SendMarketOrder(signal.symbol,
                                         orderType,
                                         lots,
                                         followerSL,
                                         followerTP,
                                         comment,
                                         ticket);

   if(ok)
     {
      AddPositionMap(signal.masterTicket,
                     ticket,
                     signal.symbol,
                     signal.price,
                     price,
                     signal.volume,
                     lots);

      m_logger.Info("ReplicateMarketOrder — order executed",
                    "masterTicket="    + IntegerToString((long)signal.masterTicket) +
                    " followerTicket=" + IntegerToString((long)ticket) +
                    " symbol="         + signal.symbol +
                    " lots="           + DoubleToString(lots, 2) +
                    " price="          + DoubleToString(price, 5) +
                    " sl="             + DoubleToString(followerSL, 5) +
                    " tp="             + DoubleToString(followerTP, 5));
      if(m_perf != NULL) m_perf.RecordTradeCopied(0.0);
     }
   else
     {
      m_logger.Error("ReplicateMarketOrder — order execution failed",
                     "masterTicket=" + IntegerToString((long)signal.masterTicket) +
                     " symbol="       + signal.symbol +
                     " lots="         + DoubleToString(lots, 2));
      if(m_perf != NULL) m_perf.RecordTradeFailed();
     }

   return ok;
  }

//+------------------------------------------------------------------+
//| ReplicatePendingOrder — place a matching pending order           |
//+------------------------------------------------------------------+
bool CTradeReplicator::ReplicatePendingOrder(CSignal &signal)
  {
   // Symbol availability check
   if(!m_mt5.CheckSymbolExists(signal.symbol))
     {
      m_logger.Error("ReplicatePendingOrder — symbol not found on follower",
                     "symbol=" + signal.symbol +
                     " signalId=" + signal.signalId);
      return false;
     }

   // Calculate follower lot size
   double lots = m_allocEngine.CalculateLotSize(signal);
   if(lots <= 0.0)
     {
      m_logger.Error("ReplicatePendingOrder — lot calculation returned 0",
                     "symbol="   + signal.symbol +
                     " signalId=" + signal.signalId);
      return false;
     }

   // Apply direction filter (pending orders can also be reversed)
   ENUM_ORDER_TYPE orderType = ApplyDirectionFilter(signal.orderType);

   // Risk validation
   if(!m_riskMgr.ValidateTrade(signal, lots))
     {
      m_logger.Info("ReplicatePendingOrder — trade skipped by risk manager",
                    "symbol="   + signal.symbol +
                    " lots="    + DoubleToString(lots, 2) +
                    " signalId=" + signal.signalId);
      return false;
     }

   // Build comment
   string commentId = (StringLen(signal.signalId) >= 8)
                      ? StringSubstr(signal.signalId, 0, 8)
                      : signal.signalId;
   string comment   = "CT:" + commentId;

   // Place the pending order at the master's price level
   ulong ticket = CT_NULL_TICKET;
   bool  ok     = m_mt5.PlacePendingOrder(signal.symbol,
                                           orderType,
                                           lots,
                                           signal.price,
                                           signal.stopLoss,
                                           signal.takeProfit,
                                           signal.expiration,
                                           comment,
                                           ticket);

   if(ok)
     {
      AddPositionMap(signal.masterTicket,
                     ticket,
                     signal.symbol,
                     signal.price,
                     signal.price,     // Entry price not yet filled — store intended price
                     signal.volume,
                     lots);

      m_logger.Info("ReplicatePendingOrder — order placed",
                    "masterTicket="    + IntegerToString((long)signal.masterTicket) +
                    " followerTicket=" + IntegerToString((long)ticket) +
                    " symbol="         + signal.symbol +
                    " type="           + EnumToString(orderType) +
                    " lots="           + DoubleToString(lots, 2) +
                    " price="          + DoubleToString(signal.price, 5));
      if(m_perf != NULL) m_perf.RecordTradeCopied(0.0);
     }
   else
     {
      m_logger.Error("ReplicatePendingOrder — order placement failed",
                     "masterTicket=" + IntegerToString((long)signal.masterTicket) +
                     " symbol="       + signal.symbol +
                     " lots="         + DoubleToString(lots, 2) +
                     " price="        + DoubleToString(signal.price, 5));
      if(m_perf != NULL) m_perf.RecordTradeFailed();
     }

   return ok;
  }

//+------------------------------------------------------------------+
//| ReplicateModification — update SL/TP on the follower position    |
//+------------------------------------------------------------------+
bool CTradeReplicator::ReplicateModification(const CSignal &signal)
  {
   ulong followerTicket = FindFollowerTicket(signal.masterTicket);
   if(followerTicket == CT_NULL_TICKET)
     {
      m_logger.Warn("ReplicateModification — no matching follower position for master ticket " +
                    IntegerToString((long)signal.masterTicket),
                    "signalId=" + signal.signalId +
                    " symbol="  + signal.symbol);
      return false;
     }

   // Use master's absolute SL/TP levels directly
   double newSL = signal.newStopLoss;
   double newTP = signal.newTakeProfit;

   bool ok = m_mt5.ModifyPosition(followerTicket, newSL, newTP);

   if(ok)
     {
      m_logger.Info("ReplicateModification — position modified",
                    "masterTicket="    + IntegerToString((long)signal.masterTicket) +
                    " followerTicket=" + IntegerToString((long)followerTicket) +
                    " newSL="          + DoubleToString(newSL, 5) +
                    " newTP="          + DoubleToString(newTP, 5));
     }
   else
     {
      m_logger.Error("ReplicateModification — modification failed",
                     "masterTicket="    + IntegerToString((long)signal.masterTicket) +
                     " followerTicket=" + IntegerToString((long)followerTicket) +
                     " newSL="          + DoubleToString(newSL, 5) +
                     " newTP="          + DoubleToString(newTP, 5));
     }

   return ok;
  }

//+------------------------------------------------------------------+
//| ReplicateClosure — fully close the matching follower position    |
//+------------------------------------------------------------------+
bool CTradeReplicator::ReplicateClosure(const CSignal &signal)
  {
   ulong followerTicket = FindFollowerTicket(signal.masterTicket);
   if(followerTicket == CT_NULL_TICKET)
     {
      m_logger.Warn("ReplicateClosure — no matching position to close",
                    "masterTicket=" + IntegerToString((long)signal.masterTicket) +
                    " signalId="    + signal.signalId +
                    " symbol="      + signal.symbol);
      return false;
     }

   bool ok = m_mt5.ClosePosition(followerTicket);

   if(ok)
     {
      RemoveFromPositionMap(signal.masterTicket);
      m_logger.Info("ReplicateClosure — position closed and removed from map",
                    "masterTicket="    + IntegerToString((long)signal.masterTicket) +
                    " followerTicket=" + IntegerToString((long)followerTicket) +
                    " symbol="         + signal.symbol);
     }
   else
     {
      m_logger.Error("ReplicateClosure — close failed",
                     "masterTicket="    + IntegerToString((long)signal.masterTicket) +
                     " followerTicket=" + IntegerToString((long)followerTicket) +
                     " symbol="         + signal.symbol);
     }

   return ok;
  }

//+------------------------------------------------------------------+
//| ReplicatePartialClosure — close a proportional follower volume   |
//+------------------------------------------------------------------+
bool CTradeReplicator::ReplicatePartialClosure(const CSignal &signal)
  {
   ulong followerTicket = FindFollowerTicket(signal.masterTicket);
   if(followerTicket == CT_NULL_TICKET)
     {
      m_logger.Warn("ReplicatePartialClosure — no matching position to partial-close",
                    "masterTicket=" + IntegerToString((long)signal.masterTicket) +
                    " signalId="    + signal.signalId +
                    " symbol="      + signal.symbol);
      return false;
     }

   // Locate the map entry to read original volumes
   int entryIdx = -1;
   for(int i = 0; i < m_positionMapCount; i++)
     {
      if(m_positionMap[i].masterTicket == signal.masterTicket)
        {
         entryIdx = i;
         break;
        }
     }

   if(entryIdx < 0)
     {
      m_logger.Error("ReplicatePartialClosure — map entry disappeared after FindFollowerTicket",
                     "masterTicket=" + IntegerToString((long)signal.masterTicket));
      return false;
     }

   double masterVol   = m_positionMap[entryIdx].masterVolume;
   double followerVol = m_positionMap[entryIdx].followerVolume;

   // Guard against degenerate master volume
   if(masterVol <= 0.0)
     {
      m_logger.Error("ReplicatePartialClosure — masterVolume in map is zero",
                     "masterTicket=" + IntegerToString((long)signal.masterTicket));
      return false;
     }

   // Guard against degenerate close volume
   if(signal.closeVolume <= 0.0)
     {
      m_logger.Error("ReplicatePartialClosure — signal.closeVolume is zero",
                     "masterTicket=" + IntegerToString((long)signal.masterTicket));
      return false;
     }

   // Calculate proportional follower close volume
   double ratio           = signal.closeVolume / masterVol;
   double followerCloseVol = followerVol * ratio;
   followerCloseVol        = m_mt5.NormalizeLotSize(signal.symbol, followerCloseVol);

   if(followerCloseVol <= 0.0)
     {
      m_logger.Error("ReplicatePartialClosure — followerCloseVol normalised to 0",
                     "masterTicket=" + IntegerToString((long)signal.masterTicket) +
                     " ratio="       + DoubleToString(ratio, 4) +
                     " follVol="     + DoubleToString(followerVol, 2));
      return false;
     }

   m_logger.Info("ReplicatePartialClosure — executing partial close",
                 "masterTicket="    + IntegerToString((long)signal.masterTicket) +
                 " followerTicket=" + IntegerToString((long)followerTicket) +
                 " masterClose="    + DoubleToString(signal.closeVolume, 2) +
                 " followerClose="  + DoubleToString(followerCloseVol, 2) +
                 " ratio="          + DoubleToString(ratio, 4));

   bool ok = m_mt5.ClosePosition(followerTicket, followerCloseVol);

   if(ok)
     {
      // Update remaining volumes in the position map
      double remainingMaster   = masterVol   - signal.closeVolume;
      double remainingFollower = followerVol - followerCloseVol;

      // If effectively fully closed (rounding artefacts), remove entirely
      double minLot = m_mt5.GetSymbolMinLot(signal.symbol);
      if(minLot <= 0.0)
         minLot = CT_LOT_MIN_DEFAULT;

      if(remainingFollower < minLot || remainingMaster <= 0.0)
        {
         RemoveFromPositionMap(signal.masterTicket);
         m_logger.Info("ReplicatePartialClosure — position fully closed, removed from map",
                       "masterTicket=" + IntegerToString((long)signal.masterTicket));
        }
      else
        {
         m_positionMap[entryIdx].masterVolume   = remainingMaster;
         m_positionMap[entryIdx].followerVolume = remainingFollower;
         SavePositionMap();
         m_logger.Info("ReplicatePartialClosure — map volumes updated",
                       "masterTicket="    + IntegerToString((long)signal.masterTicket) +
                       " masterRemain="   + DoubleToString(remainingMaster, 2) +
                       " followerRemain=" + DoubleToString(remainingFollower, 2));
        }
     }
   else
     {
      m_logger.Error("ReplicatePartialClosure — partial close failed",
                     "masterTicket="    + IntegerToString((long)signal.masterTicket) +
                     " followerTicket=" + IntegerToString((long)followerTicket) +
                     " followerClose="  + DoubleToString(followerCloseVol, 2));
     }

   return ok;
  }

//+------------------------------------------------------------------+
//| AddPositionMap — record a new Master<->Follower pair             |
//+------------------------------------------------------------------+
void CTradeReplicator::AddPositionMap(ulong  masterTicket,
                                       ulong  followerTicket,
                                       string symbol,
                                       double masterOpenPrice,
                                       double followerOpenPrice,
                                       double masterVolume,
                                       double followerVolume)
  {
   if(m_positionMapCount >= CT_MAX_POSITION_MAP)
     {
      m_logger.Error("AddPositionMap — position map is full (CT_MAX_POSITION_MAP=" +
                     IntegerToString(CT_MAX_POSITION_MAP) + ")",
                     "masterTicket=" + IntegerToString((long)masterTicket));
      return;
     }

   m_positionMap[m_positionMapCount].masterTicket      = masterTicket;
   m_positionMap[m_positionMapCount].followerTicket    = followerTicket;
   m_positionMap[m_positionMapCount].symbol            = symbol;
   m_positionMap[m_positionMapCount].masterOpenPrice   = masterOpenPrice;
   m_positionMap[m_positionMapCount].followerOpenPrice = followerOpenPrice;
   m_positionMap[m_positionMapCount].masterVolume      = masterVolume;
   m_positionMap[m_positionMapCount].followerVolume    = followerVolume;
   m_positionMap[m_positionMapCount].openTime          = TimeCurrent();
   m_positionMap[m_positionMapCount].magicNumber       = m_magicNumber;

   m_positionMapCount++;
   SavePositionMap();
  }

//+------------------------------------------------------------------+
//| FindFollowerTicket — linear search by master ticket              |
//+------------------------------------------------------------------+
ulong CTradeReplicator::FindFollowerTicket(ulong masterTicket)
  {
   for(int i = 0; i < m_positionMapCount; i++)
     {
      if(m_positionMap[i].masterTicket == masterTicket)
         return m_positionMap[i].followerTicket;
     }
   return CT_NULL_TICKET;
  }

//+------------------------------------------------------------------+
//| RemoveFromPositionMap — find by master ticket, compact the array |
//+------------------------------------------------------------------+
bool CTradeReplicator::RemoveFromPositionMap(ulong masterTicket)
  {
   for(int i = 0; i < m_positionMapCount; i++)
     {
      if(m_positionMap[i].masterTicket == masterTicket)
        {
         // Shift all subsequent entries down by one slot
         for(int j = i; j < m_positionMapCount - 1; j++)
            m_positionMap[j] = m_positionMap[j + 1];

         m_positionMapCount--;

         // Zero out the now-unused last slot to avoid stale data
         ZeroMemory(m_positionMap[m_positionMapCount]);

         SavePositionMap();
         return true;
        }
     }

   m_logger.Warn("RemoveFromPositionMap — masterTicket not found",
                 "masterTicket=" + IntegerToString((long)masterTicket));
   return false;
  }

//+------------------------------------------------------------------+
//| SavePositionMap — write current map to CSV in the common folder  |
//+------------------------------------------------------------------+
void CTradeReplicator::SavePositionMap()
  {
   int handle = FileOpen(m_posMapFile,
                         FILE_WRITE | FILE_TXT | FILE_COMMON);

   if(handle == INVALID_HANDLE)
     {
      m_logger.Error("SavePositionMap — could not open file for write",
                     "path="  + m_posMapFile +
                     " error=" + IntegerToString(GetLastError()));
      return;
     }

   // Write CSV header
   FileWriteString(handle,
                   "masterTicket,followerTicket,symbol,"
                   "masterOpenPrice,followerOpenPrice,"
                   "masterVolume,followerVolume,"
                   "openTime,magicNumber\n");

   // Write one CSV row per map entry
   for(int i = 0; i < m_positionMapCount; i++)
     {
      string line =
         IntegerToString((long)m_positionMap[i].masterTicket)      + "," +
         IntegerToString((long)m_positionMap[i].followerTicket)     + "," +
         m_positionMap[i].symbol                                    + "," +
         DoubleToString(m_positionMap[i].masterOpenPrice,   8)      + "," +
         DoubleToString(m_positionMap[i].followerOpenPrice, 8)      + "," +
         DoubleToString(m_positionMap[i].masterVolume,      8)      + "," +
         DoubleToString(m_positionMap[i].followerVolume,    8)      + "," +
         IntegerToString((long)m_positionMap[i].openTime)           + "," +
         IntegerToString(m_positionMap[i].magicNumber)              + "\n";

      FileWriteString(handle, line);
     }

   FileClose(handle);
  }

//+------------------------------------------------------------------+
//| LoadPositionMap — restore persisted map from CSV on startup      |
//+------------------------------------------------------------------+
void CTradeReplicator::LoadPositionMap()
  {
   m_positionMapCount = 0;

   int handle = FileOpen(m_posMapFile,
                         FILE_READ | FILE_TXT | FILE_COMMON | FILE_SHARE_READ);

   if(handle == INVALID_HANDLE)
     {
      // File not yet created — normal on first run
      m_logger.Debug("LoadPositionMap — no existing map file found",
                     "path=" + m_posMapFile);
      return;
     }

   // Skip the header line
   if(!FileIsEnding(handle))
      FileReadString(handle);    // Discard header

   int lineNum = 1;

   while(!FileIsEnding(handle))
     {
      string line = FileReadString(handle);
      lineNum++;

      // Skip blank lines
      if(StringLen(line) == 0)
         continue;

      // Split by comma
      string parts[];
      int    numParts = StringSplit(line, ',', parts);

      if(numParts != 9)
        {
         m_logger.Warn("LoadPositionMap — unexpected column count on line " +
                       IntegerToString(lineNum),
                       "expected=9 got=" + IntegerToString(numParts) +
                       " line=" + line);
         continue;
        }

      // Guard against overflow
      if(m_positionMapCount >= CT_MAX_POSITION_MAP)
        {
         m_logger.Error("LoadPositionMap — map full before file exhausted",
                        "CT_MAX_POSITION_MAP=" + IntegerToString(CT_MAX_POSITION_MAP));
         break;
        }

      // Parse fields — wrap in explicit casts to avoid silent truncation
      m_positionMap[m_positionMapCount].masterTicket      = (ulong)StringToInteger(parts[0]);
      m_positionMap[m_positionMapCount].followerTicket    = (ulong)StringToInteger(parts[1]);
      m_positionMap[m_positionMapCount].symbol            = parts[2];
      m_positionMap[m_positionMapCount].masterOpenPrice   = StringToDouble(parts[3]);
      m_positionMap[m_positionMapCount].followerOpenPrice = StringToDouble(parts[4]);
      m_positionMap[m_positionMapCount].masterVolume      = StringToDouble(parts[5]);
      m_positionMap[m_positionMapCount].followerVolume    = StringToDouble(parts[6]);
      m_positionMap[m_positionMapCount].openTime          = (datetime)StringToInteger(parts[7]);
      m_positionMap[m_positionMapCount].magicNumber       = (int)StringToInteger(parts[8]);

      // Basic sanity: skip entries with zeroed tickets
      if(m_positionMap[m_positionMapCount].masterTicket   == CT_NULL_TICKET ||
         m_positionMap[m_positionMapCount].followerTicket == CT_NULL_TICKET)
        {
         m_logger.Warn("LoadPositionMap — skipping entry with null ticket",
                       "line=" + IntegerToString(lineNum));
         continue;
        }

      m_positionMapCount++;
     }

   FileClose(handle);

   m_logger.Info("LoadPositionMap — loaded position map",
                 "path="    + m_posMapFile +
                 " entries=" + IntegerToString(m_positionMapCount));
  }

//+------------------------------------------------------------------+
//| ReconcilePositions — synchronise map against live positions      |
//| Called periodically (see NeedReconcile) to remove stale entries  |
//| for positions that closed outside the EA (e.g. SL/TP hit,        |
//| manual close, margin call).                                       |
//+------------------------------------------------------------------+
void CTradeReplicator::ReconcilePositions()
  {
   m_logger.Debug("ReconcilePositions — starting reconciliation",
                  "mapCount=" + IntegerToString(m_positionMapCount));

   bool mapChanged = false;

   // Iterate backwards so RemoveFromPositionMap compaction is safe
   for(int i = m_positionMapCount - 1; i >= 0; i--)
     {
      ulong followerTicket = m_positionMap[i].followerTicket;

      // Check whether the follower position is still open
      bool positionOpen = PositionSelectByTicket(followerTicket);

      if(!positionOpen)
        {
         m_logger.Info("ReconcilePositions — follower position no longer open, removing from map",
                       "masterTicket="    + IntegerToString((long)m_positionMap[i].masterTicket) +
                       " followerTicket=" + IntegerToString((long)followerTicket) +
                       " symbol="         + m_positionMap[i].symbol);

         // Compact array manually (index i is already known)
         for(int j = i; j < m_positionMapCount - 1; j++)
            m_positionMap[j] = m_positionMap[j + 1];

         m_positionMapCount--;
         ZeroMemory(m_positionMap[m_positionMapCount]);
         mapChanged = true;
        }
      else
        {
         // Verify magic number matches so we do not claim foreign positions
         int liveMagic = (int)PositionGetInteger(POSITION_MAGIC);
         if(liveMagic != m_magicNumber)
           {
            m_logger.Warn("ReconcilePositions — follower ticket has wrong magic number",
                          "followerTicket=" + IntegerToString((long)followerTicket) +
                          " expectedMagic=" + IntegerToString(m_magicNumber) +
                          " foundMagic="    + IntegerToString(liveMagic));
           }
        }
     }

   if(mapChanged)
      SavePositionMap();

   m_logger.Debug("ReconcilePositions — reconciliation complete",
                  "mapCount=" + IntegerToString(m_positionMapCount));

   m_lastReconcileTime = TimeCurrent();
  }

//+------------------------------------------------------------------+
//| NeedReconcile — true when the reconciliation interval has lapsed |
//+------------------------------------------------------------------+
bool CTradeReplicator::NeedReconcile()
  {
   return (TimeCurrent() - m_lastReconcileTime) >= CT_RECONCILE_SECS;
  }

//+------------------------------------------------------------------+
//| SetSymbolFilter — parse comma-separated symbol list              |
//| Pass an empty string to disable filtering (allow all symbols).   |
//+------------------------------------------------------------------+
void CTradeReplicator::SetSymbolFilter(string symbols)
  {
   m_allowedSymbolCount = 0;

   if(symbols == "")
     {
      m_filterSymbols = false;
      m_logger.Info("SetSymbolFilter — symbol filter disabled (all symbols allowed)");
      return;
     }

   // Split by comma and trim whitespace from each token
   string parts[];
   int count = StringSplit(symbols, ',', parts);

   ArrayResize(m_allowedSymbols, count);

   for(int i = 0; i < count; i++)
     {
      string sym = parts[i];
      StringTrimLeft(sym);
      StringTrimRight(sym);

      if(StringLen(sym) > 0)
        {
         m_allowedSymbols[m_allowedSymbolCount] = sym;
         m_allowedSymbolCount++;
        }
     }

   m_filterSymbols = (m_allowedSymbolCount > 0);

   m_logger.Info("SetSymbolFilter — symbol filter configured",
                 "count="   + IntegerToString(m_allowedSymbolCount) +
                 " filter="  + symbols);
  }

//+------------------------------------------------------------------+
//| IsSymbolAllowed — check if symbol passes the active filter       |
//+------------------------------------------------------------------+
bool CTradeReplicator::IsSymbolAllowed(string symbol)
  {
   if(!m_filterSymbols)
      return true;

   for(int i = 0; i < m_allowedSymbolCount; i++)
     {
      if(m_allowedSymbols[i] == symbol)
         return true;
     }

   return false;
  }

//+------------------------------------------------------------------+
//| SetDirectionFilter — configure the direction filter              |
//+------------------------------------------------------------------+
void CTradeReplicator::SetDirectionFilter(ENUM_DIRECTION_FILTER filter)
  {
   m_dirFilter = filter;
   m_logger.Info("SetDirectionFilter — filter set to " + EnumToString(filter));
  }

//+------------------------------------------------------------------+
//| ApplyDirectionFilter — reverse order type when DIR_REVERSE set   |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE CTradeReplicator::ApplyDirectionFilter(ENUM_ORDER_TYPE orderType)
  {
   if(m_dirFilter != DIR_REVERSE)
      return orderType;

   switch(orderType)
     {
      case ORDER_TYPE_BUY:             return ORDER_TYPE_SELL;
      case ORDER_TYPE_SELL:            return ORDER_TYPE_BUY;
      case ORDER_TYPE_BUY_LIMIT:       return ORDER_TYPE_SELL_LIMIT;
      case ORDER_TYPE_SELL_LIMIT:      return ORDER_TYPE_BUY_LIMIT;
      case ORDER_TYPE_BUY_STOP:        return ORDER_TYPE_SELL_STOP;
      case ORDER_TYPE_SELL_STOP:       return ORDER_TYPE_BUY_STOP;
      case ORDER_TYPE_BUY_STOP_LIMIT:  return ORDER_TYPE_SELL_STOP_LIMIT;
      case ORDER_TYPE_SELL_STOP_LIMIT: return ORDER_TYPE_BUY_STOP_LIMIT;
      default:                         return orderType;
     }
  }

//+------------------------------------------------------------------+
//| ShouldProcessDirection — gate signal by direction filter         |
//+------------------------------------------------------------------+
bool CTradeReplicator::ShouldProcessDirection(ENUM_ORDER_TYPE orderType)
  {
   switch(m_dirFilter)
     {
      case DIR_BOTH:
         return true;

      case DIR_BUY_ONLY:
         return IsBuyType(orderType);

      case DIR_SELL_ONLY:
         return !IsBuyType(orderType);

      case DIR_REVERSE:
         // Process all directions but the direction will be flipped in
         // ApplyDirectionFilter before order execution
         return true;

      default:
         return true;
     }
  }

//+------------------------------------------------------------------+
//| IsBuyType — true for any buy-side order type                     |
//+------------------------------------------------------------------+
bool CTradeReplicator::IsBuyType(ENUM_ORDER_TYPE t)
  {
   return (t == ORDER_TYPE_BUY            ||
           t == ORDER_TYPE_BUY_LIMIT      ||
           t == ORDER_TYPE_BUY_STOP       ||
           t == ORDER_TYPE_BUY_STOP_LIMIT);
  }
#endif // COPYTRADING_TRADEREPLICATOR_MQH
