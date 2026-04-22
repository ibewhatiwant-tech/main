//+------------------------------------------------------------------+
//| CopyTrading/AllocationEngine.mqh                                 |
//| Calculates follower lot sizes using 4 allocation methods         |
//+------------------------------------------------------------------+
#ifndef COPYTRADING_ALLOCATIONENGINE_MQH
#define COPYTRADING_ALLOCATIONENGINE_MQH
#include "Defines.mqh"
#include "Logger.mqh"
#include "Signal.mqh"
#include "MT5Wrapper.mqh"

//+------------------------------------------------------------------+
//| CAllocationEngine — computes follower position sizes             |
//|                                                                  |
//| Supported methods (ENUM_ALLOCATION_METHOD from Defines.mqh):     |
//|   ALLOC_FIXED_LOT      — constant lot regardless of master       |
//|   ALLOC_LOT_MULTIPLIER — master lot * fixed multiplier           |
//|   ALLOC_RISK_PERCENT   — risk X% of equity per trade             |
//|   ALLOC_EQUITY_PERCENT — equity-proportional to master           |
//+------------------------------------------------------------------+
class CAllocationEngine
  {
private:
   //--- configuration
   ENUM_ALLOCATION_METHOD  m_method;
   double                  m_fixedLot;
   double                  m_multiplier;
   double                  m_riskPercent;
   double                  m_equityPercent;
   double                  m_maxLotSize;
   ENUM_ALLOCATION_METHOD  m_fallbackMethod;   // used when risk-based has no SL
   double                  m_fallbackFixed;    // fallback fixed lot for no-SL case
   int                     m_emergencySLPips;  // synthetic SL distance when SL==0

   //--- dependencies
   CLogger                *m_logger;
   CMT5Wrapper            *m_mt5;

   //--- internal helpers
   double                  CapAndNormalize(string symbol, double lots,
                                           const string &context);
   double                  FallbackLot(string symbol);

public:
                           CAllocationEngine();
                          ~CAllocationEngine();

   //--- lifecycle
   bool                    Init(CLogger *logger,
                                CMT5Wrapper *mt5,
                                ENUM_ALLOCATION_METHOD method,
                                double param1,
                                double param2,
                                double maxLot);

   //--- primary interface
   double                  CalculateLotSize(const CSignal &signal);

   //--- per-method calculations (public for unit testing)
   double                  CalculateFixedLot(string symbol);
   double                  CalculateMultiplier(string symbol, double masterLots);
   double                  CalculateRiskBased(const CSignal &signal);
   double                  CalculateEquityBased(const CSignal &signal);

   //--- setters
   void                    SetMethod(ENUM_ALLOCATION_METHOD method)  { m_method         = method;   }
   void                    SetFixedLot(double lot)                   { m_fixedLot        = lot;      }
   void                    SetMultiplier(double mult)                { m_multiplier      = mult;     }
   void                    SetRiskPercent(double pct)                { m_riskPercent     = pct;      }
   void                    SetEquityPercent(double pct)              { m_equityPercent   = pct;      }
   void                    SetMaxLotSize(double maxLot)              { m_maxLotSize      = maxLot;   }
   void                    SetFallbackFixed(double lot)              { m_fallbackFixed   = lot;      }
   void                    SetEmergencySLPips(int pips)              { m_emergencySLPips = pips;     }

   //--- getters
   ENUM_ALLOCATION_METHOD  GetMethod()        const { return m_method;        }
   double                  GetFixedLot()      const { return m_fixedLot;      }
   double                  GetMultiplier()    const { return m_multiplier;    }
   double                  GetRiskPercent()   const { return m_riskPercent;   }
   double                  GetEquityPercent() const { return m_equityPercent; }
   double                  GetMaxLotSize()    const { return m_maxLotSize;    }
   double                  GetFallbackFixed() const { return m_fallbackFixed; }
  };

//+------------------------------------------------------------------+
//| Constructor — set safe defaults                                  |
//+------------------------------------------------------------------+
CAllocationEngine::CAllocationEngine()
  {
   m_method          = ALLOC_FIXED_LOT;
   m_fixedLot        = CT_LOT_MIN_DEFAULT;
   m_multiplier      = 1.0;
   m_riskPercent     = 1.0;
   m_equityPercent   = 100.0;
   m_maxLotSize      = CT_LOT_MAX_DEFAULT;
   m_fallbackMethod  = ALLOC_FIXED_LOT;
   m_fallbackFixed   = CT_LOT_MIN_DEFAULT;
   m_emergencySLPips = 50;
   m_logger          = NULL;
   m_mt5             = NULL;
  }

//+------------------------------------------------------------------+
//| Destructor — dependencies owned externally, not deleted here     |
//+------------------------------------------------------------------+
CAllocationEngine::~CAllocationEngine()
  {
   // m_logger and m_mt5 are owned by the caller — do not delete
  }

//+------------------------------------------------------------------+
//| Initialise the engine                                            |
//|                                                                  |
//| param1 meaning per method:                                       |
//|   ALLOC_FIXED_LOT      — fixed lot size                          |
//|   ALLOC_LOT_MULTIPLIER — lot multiplier                          |
//|   ALLOC_RISK_PERCENT   — risk percent of equity (e.g. 1.0 = 1%) |
//|   ALLOC_EQUITY_PERCENT — equity percent (e.g. 100.0 = 100%)     |
//|                                                                  |
//| param2 — fallback fixed lot for risk-based when SL is absent     |
//+------------------------------------------------------------------+
bool CAllocationEngine::Init(CLogger *logger,
                              CMT5Wrapper *mt5,
                              ENUM_ALLOCATION_METHOD method,
                              double param1,
                              double param2,
                              double maxLot)
  {
   if(logger == NULL)
     {
      Print("CAllocationEngine::Init — logger pointer is NULL");
      return false;
     }

   if(mt5 == NULL)
     {
      logger.Error("CAllocationEngine::Init — MT5Wrapper pointer is NULL");
      return false;
     }

   m_logger = logger;
   m_mt5    = mt5;
   m_method = method;

   // Assign param1 to the correct field based on selected method
   switch(method)
     {
      case ALLOC_FIXED_LOT:
         m_fixedLot = (param1 > 0.0) ? param1 : CT_LOT_MIN_DEFAULT;
         break;

      case ALLOC_LOT_MULTIPLIER:
         m_multiplier = (param1 > 0.0) ? param1 : 1.0;
         break;

      case ALLOC_RISK_PERCENT:
         m_riskPercent = (param1 > 0.0) ? param1 : 1.0;
         break;

      case ALLOC_EQUITY_PERCENT:
         m_equityPercent = (param1 > 0.0) ? param1 : 100.0;
         break;

      default:
         m_logger.Warn("CAllocationEngine::Init — unknown allocation method, defaulting to ALLOC_FIXED_LOT",
                       "method=" + IntegerToString((int)method));
         m_method   = ALLOC_FIXED_LOT;
         m_fixedLot = (param1 > 0.0) ? param1 : CT_LOT_MIN_DEFAULT;
         break;
     }

   // param2 is the fallback fixed lot (used by risk-based when no SL is given)
   m_fallbackFixed  = (param2 > 0.0) ? param2 : CT_LOT_MIN_DEFAULT;
   m_fallbackMethod = ALLOC_FIXED_LOT;

   // Apply max lot cap
   m_maxLotSize = (maxLot > 0.0) ? maxLot : CT_LOT_MAX_DEFAULT;

   m_logger.Info("CAllocationEngine initialised",
                 "method="     + EnumToString(m_method) +
                 " param1="    + DoubleToString(param1, 4) +
                 " fallback="  + DoubleToString(m_fallbackFixed, 4) +
                 " maxLot="    + DoubleToString(m_maxLotSize, 4));

   return true;
  }

//+------------------------------------------------------------------+
//| Clamp lots to [minLot, m_maxLotSize] and normalize to symbol     |
//| constraints. Logs the outcome. Returns 0.0 on hard failure.      |
//+------------------------------------------------------------------+
double CAllocationEngine::CapAndNormalize(string symbol, double lots,
                                          const string &context)
  {
   if(lots <= 0.0)
     {
      if(m_logger != NULL)
         m_logger.Warn("CapAndNormalize — calculated lot <= 0, using fallback",
                       context + " symbol=" + symbol +
                       " raw=" + DoubleToString(lots, 4));
      lots = m_fallbackFixed;
     }

   // Apply the user-configured maximum before broker normalization
   if(lots > m_maxLotSize)
     {
      if(m_logger != NULL)
         m_logger.Debug("CapAndNormalize — clamped to maxLotSize",
                        context + " raw=" + DoubleToString(lots, 4) +
                        " max=" + DoubleToString(m_maxLotSize, 4));
      lots = m_maxLotSize;
     }

   // Normalize to broker step / min / max
   double normalized = m_mt5.NormalizeLotSize(symbol, lots);

   if(m_logger != NULL)
      m_logger.Debug("CapAndNormalize — result",
                     context + " symbol=" + symbol +
                     " raw=" + DoubleToString(lots, 4) +
                     " normalized=" + DoubleToString(normalized, 4));

   return normalized;
  }

//+------------------------------------------------------------------+
//| Return the fallback lot, normalized to the symbol                |
//+------------------------------------------------------------------+
double CAllocationEngine::FallbackLot(string symbol)
  {
   return m_mt5.NormalizeLotSize(symbol, m_fallbackFixed);
  }

//+------------------------------------------------------------------+
//| Dispatch to the appropriate calculation method and return the    |
//| final normalized, capped lot size.                               |
//+------------------------------------------------------------------+
double CAllocationEngine::CalculateLotSize(const CSignal &signal)
  {
   if(m_logger == NULL || m_mt5 == NULL)
     {
      Print("CAllocationEngine::CalculateLotSize — engine not initialised");
      return 0.0;
     }

   double lots = 0.0;

   switch(m_method)
     {
      case ALLOC_FIXED_LOT:
         lots = CalculateFixedLot(signal.symbol);
         break;

      case ALLOC_LOT_MULTIPLIER:
         lots = CalculateMultiplier(signal.symbol, signal.volume);
         break;

      case ALLOC_RISK_PERCENT:
         lots = CalculateRiskBased(signal);
         break;

      case ALLOC_EQUITY_PERCENT:
         lots = CalculateEquityBased(signal);
         break;

      default:
         m_logger.Error("CalculateLotSize — unrecognised allocation method",
                        "method=" + IntegerToString((int)m_method));
         lots = FallbackLot(signal.symbol);
         break;
     }

   // Final safety check — should not happen if sub-methods are correct
   if(lots <= 0.0)
     {
      m_logger.Warn("CalculateLotSize — result was zero, applying fallback",
                    "method=" + EnumToString(m_method) +
                    " symbol=" + signal.symbol);
      lots = FallbackLot(signal.symbol);
     }

   m_logger.Info("CalculateLotSize — final lot size",
                 "method="   + EnumToString(m_method) +
                 " symbol="  + signal.symbol +
                 " masterVol=" + DoubleToString(signal.volume, 4) +
                 " followerLot=" + DoubleToString(lots, 4));

   return lots;
  }

//+------------------------------------------------------------------+
//| ALLOC_FIXED_LOT                                                  |
//| Returns m_fixedLot normalized to the given symbol's constraints. |
//+------------------------------------------------------------------+
double CAllocationEngine::CalculateFixedLot(string symbol)
  {
   double lots = m_fixedLot;

   m_logger.Debug("CalculateFixedLot",
                  "symbol=" + symbol +
                  " fixedLot=" + DoubleToString(lots, 4));

   return CapAndNormalize(symbol, lots, "CalculateFixedLot");
  }

//+------------------------------------------------------------------+
//| ALLOC_LOT_MULTIPLIER                                             |
//| Scales the master's lot size by m_multiplier.                    |
//+------------------------------------------------------------------+
double CAllocationEngine::CalculateMultiplier(string symbol, double masterLots)
  {
   if(masterLots <= 0.0)
     {
      m_logger.Warn("CalculateMultiplier — masterLots <= 0, using fallback",
                    "symbol=" + symbol +
                    " masterLots=" + DoubleToString(masterLots, 4));
      return FallbackLot(symbol);
     }

   double lots = masterLots * m_multiplier;

   m_logger.Debug("CalculateMultiplier",
                  "symbol="     + symbol +
                  " master="    + DoubleToString(masterLots, 4) +
                  " mult="      + DoubleToString(m_multiplier, 4) +
                  " raw="       + DoubleToString(lots, 4));

   return CapAndNormalize(symbol, lots, "CalculateMultiplier");
  }

//+------------------------------------------------------------------+
//| ALLOC_RISK_PERCENT                                               |
//|                                                                  |
//| lots = riskAmount / (slPips * pipValuePerLot)                    |
//|                                                                  |
//| Where:                                                           |
//|   riskAmount  = equity * riskPercent / 100                       |
//|   slPips      = |signal.price - signal.stopLoss| / (point * pipDivisor) |
//|   pipDivisor  = 10 for 3/5-digit symbols; 1 otherwise             |
//|   pipValue    = CMT5Wrapper::GetPipValue (per 1.0 standard lot)  |
//|                                                                  |
//| Falls back to m_fallbackFixed when:                              |
//|   - signal.stopLoss == 0 (no SL defined)                         |
//|   - slPips < 1.0 (degenerate — too small to be meaningful)       |
//|   - pipValue == 0 (symbol data not available)                    |
//+------------------------------------------------------------------+
double CAllocationEngine::CalculateRiskBased(const CSignal &signal)
  {
   // --- equity and risk amount ---
   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = equity * m_riskPercent / 100.0;

   if(equity <= 0.0)
     {
      m_logger.Warn("CalculateRiskBased — equity <= 0, using fallback",
                    "symbol=" + signal.symbol +
                    " equity=" + DoubleToString(equity, 2));
      return FallbackLot(signal.symbol);
     }

   // --- validate stop loss ---
   if(signal.stopLoss == 0.0)
     {
      m_logger.Debug("CalculateRiskBased — no SL in signal, applying fallback lot",
                     "symbol=" + signal.symbol +
                     " fallback=" + DoubleToString(m_fallbackFixed, 4));
      return FallbackLot(signal.symbol);
     }

   // --- compute SL distance in pips ---
   double point = SymbolInfoDouble(signal.symbol, SYMBOL_POINT);
   if(point <= 0.0)
     {
      m_logger.Warn("CalculateRiskBased — SYMBOL_POINT is zero, using fallback",
                    "symbol=" + signal.symbol);
      return FallbackLot(signal.symbol);
     }

   long digits = SymbolInfoInteger(signal.symbol, SYMBOL_DIGITS);
   double pipDivisor = (digits == 3 || digits == 5) ? 10.0 : 1.0;
   double slPips = MathAbs(signal.price - signal.stopLoss) / (point * pipDivisor);

   if(slPips < 1.0)
     {
      m_logger.Warn("CalculateRiskBased — slPips < 1 (degenerate SL), using fallback",
                    "symbol="  + signal.symbol +
                    " price="  + DoubleToString(signal.price, 5) +
                    " sl="     + DoubleToString(signal.stopLoss, 5) +
                    " slPips=" + DoubleToString(slPips, 2));
      return FallbackLot(signal.symbol);
     }

   // --- pip value (per 1.0 standard lot in account currency) ---
   double pipValue = m_mt5.GetPipValue(signal.symbol);
   if(pipValue <= 0.0)
     {
      m_logger.Warn("CalculateRiskBased — pipValue <= 0, using fallback",
                    "symbol=" + signal.symbol +
                    " pipValue=" + DoubleToString(pipValue, 6));
      return FallbackLot(signal.symbol);
     }

   // --- core formula ---
   //   lots = riskAmount / (slPips * pipValuePerLot)
   double lots = riskAmount / (slPips * pipValue);

   m_logger.Debug("CalculateRiskBased",
                  "symbol="     + signal.symbol +
                  " equity="    + DoubleToString(equity, 2) +
                  " risk%="     + DoubleToString(m_riskPercent, 2) +
                  " riskAmt="   + DoubleToString(riskAmount, 2) +
                  " slPips="    + DoubleToString(slPips, 2) +
                  " pipVal="    + DoubleToString(pipValue, 6) +
                  " rawLots="   + DoubleToString(lots, 4));

   return CapAndNormalize(signal.symbol, lots, "CalculateRiskBased");
  }

//+------------------------------------------------------------------+
//| ALLOC_EQUITY_PERCENT                                             |
//|                                                                  |
//| Scales the master's lot proportionally to the follower/master    |
//| equity ratio, then applies an additional percentage factor.      |
//|                                                                  |
//| ratio = (followerEquity / masterEquity) * (equityPercent / 100)  |
//| lots  = signal.volume * ratio                                    |
//|                                                                  |
//| Falls back to ALLOC_LOT_MULTIPLIER (with m_multiplier) when      |
//| masterEquity <= 0.                                               |
//+------------------------------------------------------------------+
double CAllocationEngine::CalculateEquityBased(const CSignal &signal)
  {
   double followerEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double masterEquity   = signal.masterEquity;

   if(masterEquity <= 0.0)
     {
      // No master equity in signal — fall back to simple multiplier
      m_logger.Warn("CalculateEquityBased — masterEquity <= 0, falling back to multiplier",
                    "symbol=" + signal.symbol +
                    " masterEquity=" + DoubleToString(masterEquity, 2));
      return CalculateMultiplier(signal.symbol, signal.volume);
     }

   if(followerEquity <= 0.0)
     {
      m_logger.Warn("CalculateEquityBased — followerEquity <= 0, using fallback",
                    "symbol=" + signal.symbol +
                    " followerEquity=" + DoubleToString(followerEquity, 2));
      return FallbackLot(signal.symbol);
     }

   if(signal.volume <= 0.0)
     {
      m_logger.Warn("CalculateEquityBased — signal.volume <= 0, using fallback",
                    "symbol=" + signal.symbol +
                    " volume=" + DoubleToString(signal.volume, 4));
      return FallbackLot(signal.symbol);
     }

   double ratio = (followerEquity / masterEquity) * (m_equityPercent / 100.0);
   double lots  = signal.volume * ratio;

   m_logger.Debug("CalculateEquityBased",
                  "symbol="   + signal.symbol +
                  " follEq="  + DoubleToString(followerEquity, 2) +
                  " masterEq=" + DoubleToString(masterEquity, 2) +
                  " eq%="     + DoubleToString(m_equityPercent, 2) +
                  " ratio="   + DoubleToString(ratio, 4) +
                  " masterVol=" + DoubleToString(signal.volume, 4) +
                  " rawLots=" + DoubleToString(lots, 4));

   return CapAndNormalize(signal.symbol, lots, "CalculateEquityBased");
  }
#endif // COPYTRADING_ALLOCATIONENGINE_MQH
