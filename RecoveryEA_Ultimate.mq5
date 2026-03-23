//+------------------------------------------------------------------+
//|                                       RecoveryEA_Ultimate.mq5    |
//|                        จรวจนำวิถี Recovery EA V8                    |
//|                     Zone Recovery Hedging + Fibonacci Scaling     |
//|                          BTCUSD / MT5 / $500 Account             |
//+------------------------------------------------------------------+
#property copyright "Recovery EA Ultimate"
#property link      ""
#property version   "8.00"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| SECTION 1: INPUT PARAMETERS                                      |
//+------------------------------------------------------------------+
input group "=== General ==="
input long   InpMagicNumber        = 88888;    // Magic Number
input bool   InpAutoLot            = true;     // Auto Lot Sizing
input double InpBaseLot            = 0.01;     // Base Lot (if AutoLot=false)
input double InpAutoLotEquityStep  = 500.0;    // Equity per 0.01 lot step

input group "=== Zone Recovery ==="
input int    InpMaxLayers          = 8;        // Max Recovery Layers
input int    InpZoneRecoveryPts    = 8000;     // Zone Recovery Distance (points)

input group "=== Filters ==="
input int    InpMaxSpread          = 500;      // Max Spread (points)
input double InpEquityCutoffPct    = 10.0;     // Equity Cutoff % (kill switch)

input group "=== H4 Trend ==="
input int    InpH4_EMA_Fast        = 50;       // H4 EMA Fast Period
input int    InpH4_EMA_Slow        = 200;      // H4 EMA Slow Period

input group "=== M5 Entry ==="
input int    InpM5_EMA1            = 8;        // M5 EMA Fast
input int    InpM5_EMA2            = 13;       // M5 EMA Mid
input int    InpM5_EMA3            = 21;       // M5 EMA Slow
input int    InpRSI_Period         = 14;       // RSI Period (M5)
input int    InpRSI_Oversold       = 25;       // RSI Oversold Level
input int    InpRSI_Overbought     = 75;       // RSI Overbought Level

input group "=== Profit Management ==="
input double InpProfitPerVol       = 50.0;     // Target USD per 0.01 lot volume
input double InpTrailingActivation = 0.8;      // Trailing activation ratio (0-1)
input double InpTrailingStep       = 10.0;     // Trailing step (USD)

input group "=== Display ==="
input bool   InpShowDashboard      = true;     // Show Dashboard

//+------------------------------------------------------------------+
//| SECTION 2: ENUMS & GLOBAL STATE                                  |
//+------------------------------------------------------------------+
enum ENUM_TREND
{
   TREND_BULL  =  1,
   TREND_BEAR  = -1,
   TREND_FLAT  =  0
};

enum ENUM_SIGNAL
{
   SIGNAL_BUY  =  1,
   SIGNAL_SELL = -1,
   SIGNAL_NONE =  0
};

// Indicator handles
int gH4EmaFastHandle, gH4EmaSlowHandle;
int gM5Ema1Handle, gM5Ema2Handle, gM5Ema3Handle;
int gM5RsiHandle;

// Cached indicator values
double gH4EmaFast, gH4EmaSlow;
double gM5Ema1[2], gM5Ema2[2], gM5Ema3[2];
double gM5Rsi[6]; // 6 bars: [0]=current .. [5]=oldest for lookback window

// Fill mode
ENUM_ORDER_TYPE_FILLING gFillType;

// Symbol info
double gPoint;
int    gDigits;
double gVolStep, gVolMin, gVolMax;

// Cycle state
int    gCycleDirection;       // 1=Buy, -1=Sell, 0=none
int    gLayerCount;
double gCycleProfitBuffer;    // Accumulated shaving profit
double gTrailingHighWater;    // Trailing basket high-water mark
bool   gTrailingActive;
double gInitialEquity;        // Equity at cycle start

// New bar detection
datetime gLastBarTime;

// Diagnostic logging counter
int gDiagCounter;

// Trade object
CTrade gTrade;

// Fibonacci lot multipliers (relative to base lot)
const double FibMultiplier[8] = {1.0, 1.0, 2.0, 3.0, 5.0, 8.0, 13.0, 21.0};

// GlobalVariable key prefix
string gGVPrefix;

//+------------------------------------------------------------------+
//| SECTION 3: OnInit                                                |
//+------------------------------------------------------------------+
int OnInit()
{
   // Build GV prefix
   gGVPrefix = "REA_" + IntegerToString(InpMagicNumber) + "_";

   // Symbol info
   gPoint  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   gDigits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   gVolStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   gVolMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   gVolMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   // Detect fill mode
   DetectFillMode();

   // Setup trade object
   gTrade.SetExpertMagicNumber(InpMagicNumber);
   gTrade.SetTypeFilling(gFillType);
   gTrade.SetDeviationInPoints(50);

   // Create indicator handles — H4
   gH4EmaFastHandle = iMA(_Symbol, PERIOD_H4, InpH4_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   gH4EmaSlowHandle = iMA(_Symbol, PERIOD_H4, InpH4_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);

   // Create indicator handles — M5
   gM5Ema1Handle = iMA(_Symbol, PERIOD_M5, InpM5_EMA1, 0, MODE_EMA, PRICE_CLOSE);
   gM5Ema2Handle = iMA(_Symbol, PERIOD_M5, InpM5_EMA2, 0, MODE_EMA, PRICE_CLOSE);
   gM5Ema3Handle = iMA(_Symbol, PERIOD_M5, InpM5_EMA3, 0, MODE_EMA, PRICE_CLOSE);
   gM5RsiHandle  = iRSI(_Symbol, PERIOD_M5, InpRSI_Period, PRICE_CLOSE);

   // Validate handles
   if(gH4EmaFastHandle == INVALID_HANDLE || gH4EmaSlowHandle == INVALID_HANDLE ||
      gM5Ema1Handle == INVALID_HANDLE || gM5Ema2Handle == INVALID_HANDLE ||
      gM5Ema3Handle == INVALID_HANDLE || gM5RsiHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create indicator handles");
      return INIT_FAILED;
   }

   // Initialize state
   gCycleDirection    = 0;
   gLayerCount        = 0;
   gCycleProfitBuffer = 0.0;
   gTrailingHighWater = 0.0;
   gTrailingActive    = false;
   gLastBarTime       = 0;
   gDiagCounter       = 0;

   // Store initial equity
   gInitialEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   // Recover persisted state
   RecoverState();

   Print("RecoveryEA Ultimate V8 initialized on ", _Symbol);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| SECTION 14: OnDeinit                                             |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Release indicator handles
   if(gH4EmaFastHandle != INVALID_HANDLE) IndicatorRelease(gH4EmaFastHandle);
   if(gH4EmaSlowHandle != INVALID_HANDLE) IndicatorRelease(gH4EmaSlowHandle);
   if(gM5Ema1Handle != INVALID_HANDLE)    IndicatorRelease(gM5Ema1Handle);
   if(gM5Ema2Handle != INVALID_HANDLE)    IndicatorRelease(gM5Ema2Handle);
   if(gM5Ema3Handle != INVALID_HANDLE)    IndicatorRelease(gM5Ema3Handle);
   if(gM5RsiHandle != INVALID_HANDLE)     IndicatorRelease(gM5RsiHandle);

   Comment("");
   Print("RecoveryEA Ultimate V8 deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| SECTION 4: OnTick                                                |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1. Cache indicator values
   if(!CacheIndicators())
      return;

   // 2. Equity cutoff — kill switch
   if(CheckEquityCutoff())
      return;

   // 3. Active cycle management
   if(HasOpenCycle())
   {
      ManageRecovery();
      SmartShaving();
      CheckDynamicTP();
   }
   else
   {
      // 4. New entry logic — only on new M5 bar
      if(IsNewBar())
      {
         gDiagCounter++;

         ENUM_TREND trend = GetH4Trend();

         // Diagnostic log every 12 bars (~1 hour on M5)
         if(gDiagCounter % 12 == 1)
         {
            bool emaUp = (gM5Ema1[0] > gM5Ema2[0]) && (gM5Ema2[0] > gM5Ema3[0]);
            bool emaDn = (gM5Ema1[0] < gM5Ema2[0]) && (gM5Ema2[0] < gM5Ema3[0]);
            long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
            Print("DIAG: H4=", (trend==TREND_BULL?"BULL":(trend==TREND_BEAR?"BEAR":"FLAT")),
                  " EMA_UP=", emaUp, " EMA_DN=", emaDn,
                  " RSI=", DoubleToString(gM5Rsi[0],1),
                  " RSI[1]=", DoubleToString(gM5Rsi[1],1),
                  " RSI[2]=", DoubleToString(gM5Rsi[2],1),
                  " Spread=", spread);
         }

         if(trend == TREND_FLAT)
         {
            if(InpShowDashboard) UpdateDashboard(trend);
            return;
         }

         if(!CheckSpreadFilter())
         {
            if(gDiagCounter % 12 == 1)
               Print("DIAG: Entry blocked by spread filter. Spread=",
                     SymbolInfoInteger(_Symbol, SYMBOL_SPREAD), " Max=", InpMaxSpread);
            if(InpShowDashboard) UpdateDashboard(trend);
            return;
         }

         ENUM_SIGNAL signal = GetM5Signal(trend);
         if(signal != SIGNAL_NONE)
            OpenInitialEntry(signal);
      }
   }

   // 5. Dashboard
   if(InpShowDashboard)
      UpdateDashboard(GetH4Trend());
}

//+------------------------------------------------------------------+
//| SECTION 2b: Fill Mode Detection                                  |
//+------------------------------------------------------------------+
void DetectFillMode()
{
   long fillMode = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);

   if((fillMode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      gFillType = ORDER_FILLING_IOC;
   else if((fillMode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      gFillType = ORDER_FILLING_FOK;
   else
      gFillType = ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//| SECTION 3b: Cache Indicators                                     |
//+------------------------------------------------------------------+
bool CacheIndicators()
{
   double buf[1];

   // H4 EMAs — only need bar[0]
   if(CopyBuffer(gH4EmaFastHandle, 0, 0, 1, buf) < 1) return false;
   gH4EmaFast = buf[0];

   if(CopyBuffer(gH4EmaSlowHandle, 0, 0, 1, buf) < 1) return false;
   gH4EmaSlow = buf[0];

   // M5 EMAs — need bar[0] and bar[1]
   double buf2[2];

   if(CopyBuffer(gM5Ema1Handle, 0, 0, 2, buf2) < 2) return false;
   gM5Ema1[0] = buf2[1]; gM5Ema1[1] = buf2[0]; // [0]=current, [1]=previous

   if(CopyBuffer(gM5Ema2Handle, 0, 0, 2, buf2) < 2) return false;
   gM5Ema2[0] = buf2[1]; gM5Ema2[1] = buf2[0];

   if(CopyBuffer(gM5Ema3Handle, 0, 0, 2, buf2) < 2) return false;
   gM5Ema3[0] = buf2[1]; gM5Ema3[1] = buf2[0];

   // M5 RSI — need bar[0] through bar[5] for lookback window
   double bufRsi[6];
   if(CopyBuffer(gM5RsiHandle, 0, 0, 6, bufRsi) < 6) return false;
   // CopyBuffer returns oldest-first; reverse to [0]=current, [5]=oldest
   for(int r = 0; r < 6; r++)
      gM5Rsi[r] = bufRsi[5 - r];

   return true;
}

//+------------------------------------------------------------------+
//| SECTION 5: H4 Trend Lock                                         |
//+------------------------------------------------------------------+
ENUM_TREND GetH4Trend()
{
   if(gH4EmaSlow == 0.0)
      return TREND_FLAT;

   double ratio = (gH4EmaFast - gH4EmaSlow) / gH4EmaSlow;

   if(ratio > 0.001)       // EMA50 > EMA200 by 0.1%
      return TREND_BULL;
   else if(ratio < -0.001) // EMA50 < EMA200 by 0.1%
      return TREND_BEAR;
   else
      return TREND_FLAT;
}

//+------------------------------------------------------------------+
//| SECTION 6: M5 Entry Engine                                       |
//+------------------------------------------------------------------+
ENUM_SIGNAL GetM5Signal(ENUM_TREND trend)
{
   // Buy: EMA alignment + RSI recovered from oversold within lookback + H4 bull
   if(trend == TREND_BULL)
   {
      bool emaAligned = (gM5Ema1[0] > gM5Ema2[0]) && (gM5Ema2[0] > gM5Ema3[0]);

      // RSI was oversold at any point in bars[1..5] AND current bar is above threshold
      bool wasOversold = false;
      for(int i = 1; i <= 5; i++)
      {
         if(gM5Rsi[i] < InpRSI_Oversold) { wasOversold = true; break; }
      }
      bool rsiRecovered = wasOversold && (gM5Rsi[0] >= InpRSI_Oversold);

      if(emaAligned && rsiRecovered)
         return SIGNAL_BUY;
   }

   // Sell: EMA alignment + RSI recovered from overbought within lookback + H4 bear
   if(trend == TREND_BEAR)
   {
      bool emaAligned = (gM5Ema1[0] < gM5Ema2[0]) && (gM5Ema2[0] < gM5Ema3[0]);

      bool wasOverbought = false;
      for(int i = 1; i <= 5; i++)
      {
         if(gM5Rsi[i] > InpRSI_Overbought) { wasOverbought = true; break; }
      }
      bool rsiRecovered = wasOverbought && (gM5Rsi[0] <= InpRSI_Overbought);

      if(emaAligned && rsiRecovered)
         return SIGNAL_SELL;
   }

   return SIGNAL_NONE;
}

//+------------------------------------------------------------------+
//| New Bar Detection (M5)                                           |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime currentBarTime = iTime(_Symbol, PERIOD_M5, 0);
   if(currentBarTime == 0) return false;

   if(currentBarTime != gLastBarTime)
   {
      gLastBarTime = currentBarTime;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Spread Filter                                                    |
//+------------------------------------------------------------------+
bool CheckSpreadFilter()
{
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (spread <= InpMaxSpread);
}

//+------------------------------------------------------------------+
//| SECTION 7: Lot Calculation                                       |
//+------------------------------------------------------------------+
double CalculateBaseLot()
{
   if(!InpAutoLot)
      return FinalizeLot(InpBaseLot);

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lot = MathFloor(equity / InpAutoLotEquityStep) * 0.01;
   if(lot < 0.01) lot = 0.01;

   return FinalizeLot(lot);
}

//+------------------------------------------------------------------+
double GetFibonacciLot(int layer)
{
   double baseLot = CalculateBaseLot();
   int idx = MathMin(layer, 7);
   double lot = baseLot * FibMultiplier[idx];
   return FinalizeLot(lot);
}

//+------------------------------------------------------------------+
double FinalizeLot(double lot)
{
   if(gVolStep > 0)
      lot = MathFloor(lot / gVolStep) * gVolStep;

   lot = MathMax(lot, gVolMin);
   lot = MathMin(lot, gVolMax);

   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Margin Safety Check                                              |
//+------------------------------------------------------------------+
bool CheckMarginSafe(ENUM_ORDER_TYPE orderType, double lot)
{
   double marginRequired = 0;
   if(!OrderCalcMargin(orderType, _Symbol, lot, SymbolInfoDouble(_Symbol, SYMBOL_ASK), marginRequired))
      return false;

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   // Reject if remaining free margin < 20% of equity
   if((freeMargin - marginRequired) < equity * 0.20)
      return false;

   return true;
}

//+------------------------------------------------------------------+
//| SECTION 7b: Open Initial Entry                                   |
//+------------------------------------------------------------------+
void OpenInitialEntry(ENUM_SIGNAL signal)
{
   double lot = CalculateBaseLot();
   ENUM_ORDER_TYPE orderType = (signal == SIGNAL_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   if(!CheckMarginSafe(orderType, lot))
   {
      Print("WARN: Insufficient margin for initial entry. Lot=", lot);
      return;
   }

   double price = (orderType == ORDER_TYPE_BUY)
                  ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                  : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   string comment = "REA_L0";

   if(gTrade.PositionOpen(_Symbol, orderType, lot, price, 0, 0, comment))
   {
      gCycleDirection = (signal == SIGNAL_BUY) ? 1 : -1;
      gLayerCount = 1;
      gCycleProfitBuffer = 0.0;
      gTrailingHighWater = 0.0;
      gTrailingActive = false;
      gInitialEquity = AccountInfoDouble(ACCOUNT_EQUITY);

      SaveState();
      Print("Opened initial entry: ", EnumToString(orderType), " Lot=", lot);
   }
   else
   {
      Print("ERROR: Failed to open initial entry. Error=", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Has Open Cycle — check if we have positions with our magic       |
//+------------------------------------------------------------------+
bool HasOpenCycle()
{
   if(gCycleDirection == 0) return false;

   // Verify at least one position exists
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
         return true;
   }

   // No positions found but state says cycle active — reset
   if(gCycleDirection != 0)
   {
      Print("INFO: Cycle state orphaned. Resetting.");
      ResetCycleState();
   }
   return false;
}

//+------------------------------------------------------------------+
//| SECTION 8: Zone Recovery Hedging                                 |
//+------------------------------------------------------------------+
void ManageRecovery()
{
   if(gLayerCount >= InpMaxLayers)
      return;

   // Find the last entry in our cycle
   double lastEntryPrice = 0;
   ENUM_POSITION_TYPE lastType = POSITION_TYPE_BUY;
   datetime lastTime = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      if(openTime > lastTime)
      {
         lastTime = openTime;
         lastEntryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         lastType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      }
   }

   if(lastEntryPrice == 0) return;

   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double zoneDistance = InpZoneRecoveryPts * gPoint;

   bool triggerHedge = false;

   if(lastType == POSITION_TYPE_BUY)
   {
      // Price dropped below last buy by zone distance
      if(currentBid <= lastEntryPrice - zoneDistance)
         triggerHedge = true;
   }
   else
   {
      // Price rose above last sell by zone distance
      if(currentAsk >= lastEntryPrice + zoneDistance)
         triggerHedge = true;
   }

   if(!triggerHedge) return;

   // Open hedge in opposite direction
   ENUM_ORDER_TYPE hedgeType = (lastType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   double lot = GetFibonacciLot(gLayerCount);

   if(!CheckMarginSafe(hedgeType, lot))
   {
      Print("WARN: Insufficient margin for recovery layer ", gLayerCount, ". Lot=", lot);
      return;
   }

   double price = (hedgeType == ORDER_TYPE_BUY) ? currentAsk : currentBid;
   string comment = "REA_L" + IntegerToString(gLayerCount);

   if(gTrade.PositionOpen(_Symbol, hedgeType, lot, price, 0, 0, comment))
   {
      gLayerCount++;
      SaveState();
      Print("Opened recovery layer ", gLayerCount, ": ", EnumToString(hedgeType), " Lot=", lot);
   }
   else
   {
      Print("ERROR: Failed to open recovery layer. Error=", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| SECTION 9: Smart Shaving                                         |
//+------------------------------------------------------------------+
void SmartShaving()
{
   // Need at least 3 positions to shave (keep at least 1 open)
   int totalPositions = CountCyclePositions();
   if(totalPositions < 3) return;

   // Find the most profitable and the deepest losing position
   ulong bestTicket = 0, worstTicket = 0;
   double bestProfit = -DBL_MAX, worstProfit = DBL_MAX;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

      if(profit > bestProfit)
      {
         bestProfit = profit;
         bestTicket = ticket;
      }
      if(profit < worstProfit)
      {
         worstProfit = profit;
         worstTicket = ticket;
      }
   }

   if(bestTicket == 0 || worstTicket == 0 || bestTicket == worstTicket)
      return;

   // Only shave if the best leg is profitable enough ($2 per layer minimum)
   double shaveThreshold = 2.0 * gLayerCount;
   if(bestProfit < shaveThreshold)
      return;

   // Only shave if net result of closing both is positive
   double netResult = bestProfit + worstProfit;
   if(netResult <= 0)
      return;

   // Check freeze level
   long freezeLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   if(freezeLevel > 0)
   {
      // Verify positions are not frozen
      if(!CanClosePosition(bestTicket, freezeLevel) || !CanClosePosition(worstTicket, freezeLevel))
         return;
   }

   // Close both positions
   bool closedBest = gTrade.PositionClose(bestTicket);
   if(closedBest)
   {
      bool closedWorst = gTrade.PositionClose(worstTicket);
      if(closedWorst)
      {
         gCycleProfitBuffer += netResult;
         SaveState();
         Print("Shaved pair: Best=$", bestProfit, " Worst=$", worstProfit, " Net=$", netResult,
               " Buffer=$", gCycleProfitBuffer);
      }
      else
      {
         Print("WARN: Closed best leg but failed to close worst. Error=", GetLastError());
         gCycleProfitBuffer += bestProfit;
         SaveState();
      }
   }
}

//+------------------------------------------------------------------+
//| Check if position can be closed (freeze level)                   |
//+------------------------------------------------------------------+
bool CanClosePosition(ulong ticket, long freezeLevel)
{
   if(!PositionSelectByTicket(ticket)) return false;

   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   double currentPrice = (posType == POSITION_TYPE_BUY)
                         ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                         : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double distancePoints = MathAbs(currentPrice - openPrice) / gPoint;
   return (distancePoints >= freezeLevel);
}

//+------------------------------------------------------------------+
//| SECTION 10: Dynamic TP & Trailing                                |
//+------------------------------------------------------------------+
void CheckDynamicTP()
{
   // Calculate total volume and floating P&L
   double totalVolume = 0;
   double floatingPL = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      totalVolume += PositionGetDouble(POSITION_VOLUME);
      floatingPL  += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }

   if(totalVolume <= 0) return;

   // Dynamic target based on total volume
   double target = (totalVolume / 0.01) * InpProfitPerVol;
   double netProfit = floatingPL + gCycleProfitBuffer;

   // Trailing activation threshold
   double activationLevel = target * InpTrailingActivation;

   if(netProfit >= activationLevel)
   {
      if(!gTrailingActive)
      {
         // Activate trailing
         gTrailingActive = true;
         gTrailingHighWater = netProfit;
         SaveState();
         Print("Trailing activated. Target=$", target, " NetProfit=$", netProfit);
      }
      else
      {
         // Update high-water mark
         if(netProfit > gTrailingHighWater)
         {
            gTrailingHighWater = netProfit;
            SaveState();
         }

         // Check trailing step pullback
         if(netProfit < (gTrailingHighWater - InpTrailingStep))
         {
            Print("Trailing stop hit. HW=$", gTrailingHighWater, " Current=$", netProfit);
            CloseAllCyclePositions();
            return;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Close All Cycle Positions                                        |
//+------------------------------------------------------------------+
void CloseAllCyclePositions()
{
   int maxAttempts = 3;

   for(int attempt = 0; attempt < maxAttempts; attempt++)
   {
      bool allClosed = true;

      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

         if(!gTrade.PositionClose(ticket))
         {
            Print("WARN: Failed to close ticket ", ticket, " Error=", GetLastError());
            allClosed = false;
         }
      }

      if(allClosed) break;
      Sleep(100);
   }

   // Verify
   int remaining = CountCyclePositions();
   if(remaining == 0)
   {
      double totalPL = gCycleProfitBuffer; // Realized from shaving (floating already closed)
      Print("Cycle closed successfully. Buffer profit=$", totalPL);
      ResetCycleState();
   }
   else
   {
      Print("WARN: ", remaining, " positions remain after close attempt");
   }
}

//+------------------------------------------------------------------+
//| Count positions in our cycle                                     |
//+------------------------------------------------------------------+
int CountCyclePositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| SECTION 11: Safety Systems                                       |
//+------------------------------------------------------------------+
bool CheckEquityCutoff()
{
   if(gCycleDirection == 0) return false;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double cutoffLevel = gInitialEquity * (1.0 - InpEquityCutoffPct / 100.0);

   if(equity < cutoffLevel)
   {
      Print("!!! EQUITY CUTOFF TRIGGERED !!! Equity=$", equity, " Cutoff=$", cutoffLevel);
      CloseAllCyclePositions();
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| SECTION 12: State Persistence                                    |
//+------------------------------------------------------------------+
void SaveState()
{
   GlobalVariableSet(gGVPrefix + "CycleDir",     (double)gCycleDirection);
   GlobalVariableSet(gGVPrefix + "LayerCount",   (double)gLayerCount);
   GlobalVariableSet(gGVPrefix + "ProfitBuffer", gCycleProfitBuffer);
   GlobalVariableSet(gGVPrefix + "TrailHigh",    gTrailingHighWater);
   GlobalVariableSet(gGVPrefix + "TrailActive",  gTrailingActive ? 1.0 : 0.0);
   GlobalVariableSet(gGVPrefix + "InitEquity",   gInitialEquity);
}

//+------------------------------------------------------------------+
void RecoverState()
{
   if(GlobalVariableCheck(gGVPrefix + "CycleDir"))
   {
      gCycleDirection    = (int)GlobalVariableGet(gGVPrefix + "CycleDir");
      gLayerCount        = (int)GlobalVariableGet(gGVPrefix + "LayerCount");
      gCycleProfitBuffer = GlobalVariableGet(gGVPrefix + "ProfitBuffer");
      gTrailingHighWater = GlobalVariableGet(gGVPrefix + "TrailHigh");
      gTrailingActive    = (GlobalVariableGet(gGVPrefix + "TrailActive") > 0.5);
      gInitialEquity     = GlobalVariableGet(gGVPrefix + "InitEquity");

      if(gCycleDirection != 0)
         Print("State recovered: Dir=", gCycleDirection, " Layers=", gLayerCount,
               " Buffer=$", gCycleProfitBuffer, " InitEq=$", gInitialEquity);
   }
}

//+------------------------------------------------------------------+
void ClearState()
{
   GlobalVariableDel(gGVPrefix + "CycleDir");
   GlobalVariableDel(gGVPrefix + "LayerCount");
   GlobalVariableDel(gGVPrefix + "ProfitBuffer");
   GlobalVariableDel(gGVPrefix + "TrailHigh");
   GlobalVariableDel(gGVPrefix + "TrailActive");
   GlobalVariableDel(gGVPrefix + "InitEquity");
}

//+------------------------------------------------------------------+
void ResetCycleState()
{
   gCycleDirection    = 0;
   gLayerCount        = 0;
   gCycleProfitBuffer = 0.0;
   gTrailingHighWater = 0.0;
   gTrailingActive    = false;

   ClearState();
   Print("Cycle state reset.");
}

//+------------------------------------------------------------------+
//| SECTION 13: Dashboard                                            |
//+------------------------------------------------------------------+
void UpdateDashboard(ENUM_TREND trend)
{
   string trendStr, trendArrow;
   if(trend == TREND_BULL)      { trendStr = "BULL"; trendArrow = " ▲"; }
   else if(trend == TREND_BEAR) { trendStr = "BEAR"; trendArrow = " ▼"; }
   else                         { trendStr = "FLAT"; trendArrow = " ─"; }

   string rsiStatus;
   if(gM5Rsi[0] < InpRSI_Oversold)       rsiStatus = "OVERSOLD";
   else if(gM5Rsi[0] > InpRSI_Overbought) rsiStatus = "OVERBOUGHT";
   else                                    rsiStatus = "NEUTRAL";

   string cycleStr = "NONE";
   if(gCycleDirection == 1)  cycleStr = "BUY";
   if(gCycleDirection == -1) cycleStr = "SELL";

   // Calculate net profit
   double floatingPL = 0;
   double totalVolume = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      floatingPL  += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      totalVolume += PositionGetDouble(POSITION_VOLUME);
   }
   double netProfit = floatingPL + gCycleProfitBuffer;

   string trailStr = gTrailingActive ? "ON" : "OFF";

   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   string dashboard = "";
   dashboard += "═══════════════════════════════════════\n";
   dashboard += "   จรวจนำวิถี Recovery EA V8\n";
   dashboard += "═══════════════════════════════════════\n";
   dashboard += "H4 Trend    : " + trendStr + trendArrow + "\n";
   dashboard += "M5 RSI(" + IntegerToString(InpRSI_Period) + ")  : " +
                DoubleToString(gM5Rsi[0], 1) + " [" + rsiStatus + "]\n";
   dashboard += "───────────────────────────────────────\n";
   dashboard += "Cycle       : " + cycleStr + " | Layers: " +
                IntegerToString(gLayerCount) + "/" + IntegerToString(InpMaxLayers) + "\n";
   dashboard += "Volume      : " + DoubleToString(totalVolume, 2) + " lots\n";
   dashboard += "Net Profit  : $" + DoubleToString(netProfit, 2) +
                " (Trail: " + trailStr + ")\n";
   dashboard += "Buffer      : $" + DoubleToString(gCycleProfitBuffer, 2) + "\n";
   dashboard += "───────────────────────────────────────\n";
   dashboard += "Equity      : $" + DoubleToString(equity, 2) + "\n";
   dashboard += "Free Margin : $" + DoubleToString(freeMargin, 2) + "\n";
   dashboard += "Spread      : " + IntegerToString(spread) + " pts\n";
   dashboard += "═══════════════════════════════════════\n";

   Comment(dashboard);
}

//+------------------------------------------------------------------+
