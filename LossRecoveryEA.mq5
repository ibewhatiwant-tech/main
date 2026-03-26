//+------------------------------------------------------------------+
//|                                               LossRecoveryEA.mq5 |
//|                         Loss Recovery Strategy Expert Advisor     |
//|                                                                   |
//| Strategy:                                                         |
//|   1. Monitor positions for losses exceeding threshold              |
//|   2. Lock (hedge) the losing position                              |
//|   3. Open averaging grid orders to generate recovery profit        |
//|   4. Partial close losing + hedge as averaging profits accumulate  |
//|   5. Emergency close if equity drops below critical level          |
//|   6. Persist session state for restart recovery                    |
//+------------------------------------------------------------------+
#property copyright "Loss Recovery Strategy"
#property version   "1.00"
#property strict

//--- Include modules
#include "Include/LossRecovery/Defines.mqh"
#include "Include/LossRecovery/Utils.mqh"
#include "Include/LossRecovery/Logger.mqh"
#include "Include/LossRecovery/RecoverySession.mqh"
#include "Include/LossRecovery/Persistence.mqh"
#include "Include/LossRecovery/PositionManager.mqh"
#include "Include/LossRecovery/Monitor.mqh"
#include "Include/LossRecovery/HedgeEngine.mqh"
#include "Include/LossRecovery/AveragingEngine.mqh"
#include "Include/LossRecovery/ExitManager.mqh"

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
//--- Loss Detection
input string              Inp_Section1       = "=== Loss Detection ===";   // ──────────────
input ENUM_THRESHOLD_MODE InpThresholdMode   = THRESHOLD_USD;               // Threshold mode
input double              InpLossThreshold   = -200.0;                      // Loss threshold (USD or %)
input double              InpEmergencyThresh = -500.0;                      // Emergency threshold (USD or %)
input ulong               InpMagicFilter     = 0;                           // Magic filter (0=all positions)

//--- Lot Sizing
input string              Inp_Section2       = "=== Lot Sizing ===";       // ──────────────
input double              InpBaseLot         = 0.10;                        // Base lot size
input ENUM_SIZING_MODE    InpSizingMode      = SIZING_GEOMETRIC;            // Sizing mode
input double              InpGeoMultiplier   = 2.0;                         // Geometric multiplier
input int                 InpMaxSteps        = 6;                           // Max grid levels
input double              InpMaxTotalVolume  = 2.0;                         // Max total grid volume

//--- Grid Spacing
input string              Inp_Section3       = "=== Grid Spacing ===";     // ──────────────
input double              InpGridSpacingPips = 50.0;                        // Grid spacing (pips)
input bool                InpUseATRSpacing   = false;                       // Use ATR-based spacing
input double              InpATRMultiplier   = 1.5;                         // ATR multiplier
input int                 InpATRPeriod       = 14;                          // ATR period

//--- Exit Strategy
input string              Inp_Section4       = "=== Exit Strategy ===";    // ──────────────
input double              InpPartialUnitLot  = 0.05;                        // Partial close unit lot
input ENUM_CLOSE_STRATEGY InpCloseStrategy   = CLOSE_INTELLIGENT;           // Close strategy
input int                 InpNCloseThreshold = 3;                           // Intelligent close threshold

//--- Execution
input string              Inp_Section5       = "=== Execution ===";        // ──────────────
input int                 InpMaxRetries      = 3;                           // Max order retries
input int                 InpBaseBackoffMs   = 1000;                        // Base backoff (ms)
input ulong               InpSlippage        = 20;                          // Slippage (points)

//--- Other
input string              Inp_Section6       = "=== Other ===";            // ──────────────
input bool                InpPauseOtherEAs   = false;                       // Pause other EAs on trigger

//+------------------------------------------------------------------+
//| Global objects                                                     |
//+------------------------------------------------------------------+
CLogger           g_logger;
CPersistence       g_persistence;
CPositionManager   g_pos_mgr;
CMonitor           g_monitor;
CHedgeEngine       g_hedge_engine;
CAveragingEngine   g_avg_engine;
CExitManager       g_exit_mgr;
CRecoverySession   g_session;

int                g_consecutive_failures;
bool               g_initialized;

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   g_initialized = false;
   g_consecutive_failures = 0;

   //--- Check hedging mode
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("[LossRecoveryEA] ERROR: This EA requires a Hedging account. "
            "Current account mode does not support hedging.");
      return INIT_FAILED;
   }

   //--- Initialize logger
   if(!g_logger.Init())
   {
      Print("[LossRecoveryEA] Failed to initialize logger");
      return INIT_FAILED;
   }

   g_logger.Log(LOG_INFO, "====== LossRecoveryEA Initializing ======");
   g_logger.Log(LOG_INFO, StringFormat("Account: %d, Balance: %.2f, Equity: %.2f",
                AccountInfoInteger(ACCOUNT_LOGIN),
                AccountInfoDouble(ACCOUNT_BALANCE),
                AccountInfoDouble(ACCOUNT_EQUITY)));

   //--- Initialize persistence
   g_persistence.SetLogger(&g_logger);

   //--- Initialize position manager
   g_pos_mgr.Init(&g_logger, InpMaxRetries, InpBaseBackoffMs);
   g_pos_mgr.SetSlippage(InpSlippage);

   //--- Initialize monitor
   g_monitor.Init(&g_logger, InpThresholdMode,
                  InpLossThreshold, InpEmergencyThresh,
                  InpMagicFilter);

   //--- Initialize hedge engine
   g_hedge_engine.Init(&g_logger, &g_pos_mgr);

   //--- Initialize averaging engine
   g_avg_engine.Init(&g_logger, &g_pos_mgr);
   g_avg_engine.SetParameters(InpSizingMode, InpBaseLot, InpGeoMultiplier,
                              InpMaxSteps, InpMaxTotalVolume,
                              InpGridSpacingPips, InpUseATRSpacing,
                              InpATRMultiplier, InpATRPeriod);

   //--- Initialize exit manager
   g_exit_mgr.Init(&g_logger, &g_pos_mgr, &g_hedge_engine,
                   InpCloseStrategy, InpPartialUnitLot, InpNCloseThreshold);

   //--- Try to restore existing session
   if(g_persistence.FindActiveSession(g_session))
   {
      g_logger.Log(LOG_INFO, StringFormat(
         "Restored active session: %s, state=%s, symbol=%s",
         g_session.session_id,
         StateToString(g_session.state),
         g_session.losing_position.symbol));

      // Reconcile with live positions
      if(g_persistence.ReconcileSession(g_session))
      {
         g_logger.Log(LOG_INFO, "Session reconciled with live positions");
         g_persistence.SaveSession(g_session);
      }

      g_logger.SetSessionID(g_session.session_id);
   }
   else
   {
      g_logger.Log(LOG_INFO, "No active session found - starting in IDLE mode");
      g_session.Reset();
   }

   //--- Log parameters
   g_logger.Log(LOG_INFO, StringFormat(
      "Parameters: threshold=%.2f %s, emergency=%.2f, base_lot=%.2f, "
      "sizing=%d, multiplier=%.1f, max_steps=%d, max_vol=%.2f, "
      "spacing=%.1f pips %s, partial_lot=%.2f, strategy=%d",
      InpLossThreshold,
      (InpThresholdMode == THRESHOLD_USD ? "USD" : "%"),
      InpEmergencyThresh,
      InpBaseLot, InpSizingMode, InpGeoMultiplier,
      InpMaxSteps, InpMaxTotalVolume,
      InpGridSpacingPips,
      (InpUseATRSpacing ? "(ATR)" : "(fixed)"),
      InpPartialUnitLot, InpCloseStrategy));

   g_logger.Log(LOG_INFO, "====== Initialization Complete ======");
   g_initialized = true;

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   g_logger.Log(LOG_INFO, StringFormat("====== Deinitializing (reason=%d) ======", reason));

   // Save active session before shutdown
   if(g_session.IsActive())
   {
      g_persistence.SaveSession(g_session);
      g_logger.Log(LOG_INFO, StringFormat("Session %s saved (state=%s)",
                   g_session.session_id, StateToString(g_session.state)));
   }

   // Clear pause flag if we set it
   if(InpPauseOtherEAs)
      g_persistence.SetPauseFlag(false);

   g_logger.Log(LOG_INFO, "====== Deinitialization Complete ======");
}

//+------------------------------------------------------------------+
//| Expert tick function                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!g_initialized) return;

   //=== PHASE 0: Emergency check (highest priority) ===
   if(g_session.IsActive() && g_monitor.CheckEmergency())
   {
      HandleEmergency();
      return;
   }

   //=== PHASE 1: Process current session state ===
   if(g_session.IsActive())
   {
      ProcessSession();
      return;
   }

   //=== PHASE 2: Monitor for new triggers (IDLE state) ===
   ScanForTrigger();
}

//+------------------------------------------------------------------+
//| Process the active recovery session based on state                 |
//+------------------------------------------------------------------+
void ProcessSession()
{
   switch(g_session.state)
   {
      case STATE_TRIGGERED:
         OnStateTriggered();
         break;

      case STATE_HEDGING:
         OnStateHedging();
         break;

      case STATE_AVERAGING:
         OnStateAveraging();
         break;

      case STATE_RECOVERING:
         OnStateRecovering();
         break;

      case STATE_CLOSING:
         OnStateClosing();
         break;

      case STATE_CLEANUP:
         OnStateCleanup();
         break;

      case STATE_EMERGENCY:
         OnStateEmergency();
         break;

      case STATE_ARCHIVED:
         // Session complete - reset for next trigger
         g_session.Reset();
         break;

      default:
         break;
   }
}

//+------------------------------------------------------------------+
//| IDLE -> Scan for losing positions exceeding threshold              |
//+------------------------------------------------------------------+
void ScanForTrigger()
{
   SPositionInfo worst_pos;
   if(!g_monitor.CheckTrigger(worst_pos))
      return;

   // Create new recovery session
   g_session.Reset();
   g_session.session_id = GenerateSessionID();
   g_session.losing_position = worst_pos;

   // Snapshot parameters
   g_session.params.base_lot             = InpBaseLot;
   g_session.params.sizing_mode          = (int)InpSizingMode;
   g_session.params.geometric_multiplier = InpGeoMultiplier;
   g_session.params.max_steps            = InpMaxSteps;
   g_session.params.max_total_volume     = InpMaxTotalVolume;
   g_session.params.grid_spacing_pips    = InpGridSpacingPips;
   g_session.params.use_atr_spacing      = InpUseATRSpacing;
   g_session.params.atr_multiplier       = InpATRMultiplier;
   g_session.params.atr_period           = InpATRPeriod;
   g_session.params.partial_unit_lot     = InpPartialUnitLot;
   g_session.params.close_strategy       = (int)InpCloseStrategy;
   g_session.params.n_close_threshold    = InpNCloseThreshold;
   g_session.params.max_retries          = InpMaxRetries;

   // Metrics
   g_session.metrics.equity_at_trigger = AccountInfoDouble(ACCOUNT_EQUITY);
   g_session.metrics.time_created      = TimeCurrent();
   g_session.metrics.time_updated      = TimeCurrent();

   g_session.SetState(STATE_TRIGGERED);
   g_logger.SetSessionID(g_session.session_id);

   g_logger.Log(LOG_TRIGGER, StringFormat(
      "Recovery triggered: session=%s, ticket=#%d, %s %s %.2f lots @ %.5f, pnl=%.2f",
      g_session.session_id,
      worst_pos.ticket, worst_pos.symbol,
      (worst_pos.direction > 0 ? "BUY" : "SELL"),
      worst_pos.volume, worst_pos.open_price, worst_pos.pnl));

   // Pause other EAs if configured
   if(InpPauseOtherEAs)
      g_persistence.SetPauseFlag(true);

   // Persist immediately
   g_persistence.SaveSession(g_session);
}

//+------------------------------------------------------------------+
//| STATE_TRIGGERED: Place the hedge order                             |
//+------------------------------------------------------------------+
void OnStateTriggered()
{
   g_logger.Log(LOG_STATE_CHANGE, "State: TRIGGERED -> Placing hedge...");

   if(g_hedge_engine.PlaceHedge(g_session))
   {
      g_session.SetState(STATE_HEDGING);
      g_logger.Log(LOG_STATE_CHANGE, "Hedge placed -> STATE_HEDGING");

      // Immediately verify and move to AVERAGING
      if(g_hedge_engine.IsHedgeValid(g_session))
      {
         g_session.SetState(STATE_AVERAGING);
         g_logger.Log(LOG_STATE_CHANGE, "Hedge verified -> STATE_AVERAGING");

         // Build the averaging grid
         g_avg_engine.BuildGrid(g_session);
      }

      g_persistence.SaveSession(g_session);
      g_consecutive_failures = 0;
   }
   else
   {
      g_consecutive_failures++;
      if(g_consecutive_failures > InpMaxRetries)
      {
         g_logger.Log(LOG_ERROR, StringFormat(
            "Hedge placement failed %d times -> EMERGENCY",
            g_consecutive_failures));
         g_session.SetState(STATE_EMERGENCY);
         g_persistence.SaveSession(g_session);
      }
   }
}

//+------------------------------------------------------------------+
//| STATE_HEDGING: Verify hedge is in place, then move to averaging   |
//+------------------------------------------------------------------+
void OnStateHedging()
{
   if(g_hedge_engine.IsHedgeValid(g_session))
   {
      g_session.SetState(STATE_AVERAGING);
      g_logger.Log(LOG_STATE_CHANGE, "Hedge confirmed -> STATE_AVERAGING");

      // Build the averaging grid
      g_avg_engine.BuildGrid(g_session);
      g_persistence.SaveSession(g_session);
      g_consecutive_failures = 0;
   }
   else
   {
      // Hedge may have been closed externally
      g_consecutive_failures++;
      if(g_consecutive_failures > InpMaxRetries)
      {
         g_logger.Log(LOG_ERROR, "Hedge lost and retries exhausted -> EMERGENCY");
         g_session.SetState(STATE_EMERGENCY);
         g_persistence.SaveSession(g_session);
      }
      else
      {
         // Try to re-place hedge
         g_logger.Log(LOG_INFO, "Hedge not found, re-placing...");
         g_hedge_engine.PlaceHedge(g_session);
      }
   }
}

//+------------------------------------------------------------------+
//| STATE_AVERAGING: Place grid orders and check for recovery target   |
//+------------------------------------------------------------------+
void OnStateAveraging()
{
   // Update live PnL
   g_session.UpdateLivePnL();

   // Try to place next grid level if price reached
   bool new_order = g_avg_engine.CheckAndPlaceNextStep(g_session);
   if(new_order)
      g_persistence.SaveSession(g_session);

   // Check if recovery target is met
   if(g_exit_mgr.CheckRecoveryTarget(g_session))
   {
      g_session.SetState(STATE_RECOVERING);
      g_logger.Log(LOG_STATE_CHANGE, StringFormat(
         "Recovery target met (avg_pnl=%.2f) -> STATE_RECOVERING",
         g_session.GetTotalAveragingPnL()));
      g_persistence.SaveSession(g_session);
   }
}

//+------------------------------------------------------------------+
//| STATE_RECOVERING: Execute partial closes                           |
//+------------------------------------------------------------------+
void OnStateRecovering()
{
   g_session.UpdateLivePnL();

   bool close_done = g_exit_mgr.ExecutePartialClose(g_session);

   if(close_done)
   {
      g_persistence.SaveSession(g_session);

      // Check if recovery is complete
      if(g_exit_mgr.IsRecoveryComplete(g_session))
      {
         g_session.SetState(STATE_CLOSING);
         g_logger.Log(LOG_STATE_CHANGE,
            "Recovery complete -> STATE_CLOSING");
         g_persistence.SaveSession(g_session);
      }
      else
      {
         // Need more averaging profit - go back to AVERAGING
         g_session.SetState(STATE_AVERAGING);
         g_logger.Log(LOG_STATE_CHANGE,
            "Partial close done, need more -> STATE_AVERAGING");
         g_persistence.SaveSession(g_session);
      }
   }
   else
   {
      // Cannot close yet - check if we should go back to averaging
      if(!g_exit_mgr.CheckRecoveryTarget(g_session))
      {
         g_session.SetState(STATE_AVERAGING);
         g_logger.Log(LOG_STATE_CHANGE,
            "Recovery target no longer met -> STATE_AVERAGING");
         g_persistence.SaveSession(g_session);
      }
   }
}

//+------------------------------------------------------------------+
//| STATE_CLOSING: Close remaining positions                           |
//+------------------------------------------------------------------+
void OnStateClosing()
{
   bool all_closed = g_exit_mgr.ExecuteFullClose(g_session);

   if(all_closed)
   {
      g_session.SetState(STATE_CLEANUP);
      g_logger.Log(LOG_STATE_CHANGE, "All positions closed -> STATE_CLEANUP");
      g_persistence.SaveSession(g_session);
   }
   else
   {
      g_consecutive_failures++;
      if(g_consecutive_failures > InpMaxRetries * 2)
      {
         g_logger.Log(LOG_ERROR, "Closing failed repeatedly -> EMERGENCY");
         g_session.SetState(STATE_EMERGENCY);
         g_persistence.SaveSession(g_session);
      }
   }
}

//+------------------------------------------------------------------+
//| STATE_CLEANUP: Archive session and reset                           |
//+------------------------------------------------------------------+
void OnStateCleanup()
{
   g_logger.Log(LOG_INFO, StringFormat(
      "Session %s cleanup: total_recovered=%.2f, partial_closes=%d, "
      "equity_at_trigger=%.2f, current_equity=%.2f",
      g_session.session_id,
      g_session.metrics.total_recovered,
      g_session.metrics.partial_close_count,
      g_session.metrics.equity_at_trigger,
      AccountInfoDouble(ACCOUNT_EQUITY)));

   // Unpause other EAs
   if(InpPauseOtherEAs)
      g_persistence.SetPauseFlag(false);

   // Archive session
   g_session.SetState(STATE_ARCHIVED);
   g_persistence.SaveSession(g_session);
   g_persistence.ArchiveSession(g_session.session_id);

   // Clear global variables
   g_persistence.ClearGlobalVars();

   g_logger.Log(LOG_STATE_CHANGE, "Session archived -> STATE_IDLE");
   g_consecutive_failures = 0;

   // Reset for next trigger
   g_session.Reset();
}

//+------------------------------------------------------------------+
//| STATE_EMERGENCY: Close everything with maximum effort              |
//+------------------------------------------------------------------+
void OnStateEmergency()
{
   g_logger.Log(LOG_EMERGENCY, "Processing EMERGENCY state...");

   bool all_closed = g_exit_mgr.ExecuteEmergencyClose(g_session);

   if(all_closed)
   {
      g_session.SetState(STATE_CLEANUP);
      g_logger.Log(LOG_STATE_CHANGE, "Emergency close done -> STATE_CLEANUP");
   }
   else
   {
      g_logger.Log(LOG_ERROR,
         "Emergency close incomplete - will retry next tick");
   }

   g_persistence.SaveSession(g_session);
}

//+------------------------------------------------------------------+
//| Handle emergency trigger from any state                            |
//+------------------------------------------------------------------+
void HandleEmergency()
{
   ENUM_SESSION_STATE prev_state = g_session.state;
   g_session.SetState(STATE_EMERGENCY);

   g_logger.Log(LOG_EMERGENCY, StringFormat(
      "EMERGENCY triggered from state %s! Equity=%.2f",
      StateToString(prev_state),
      AccountInfoDouble(ACCOUNT_EQUITY)));

   g_persistence.SaveSession(g_session);

   // Immediately try emergency close
   OnStateEmergency();
}

//+------------------------------------------------------------------+
//| Trade transaction handler - track position changes                 |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   // Log significant trade events
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      // A deal was added - could be one of our orders being filled
      if(g_session.IsActive())
      {
         // Mark session as needing persistence update
         g_session.metrics.time_updated = TimeCurrent();
      }
   }
}

//+------------------------------------------------------------------+
//| Timer function (optional - for periodic persistence)               |
//+------------------------------------------------------------------+
void OnTimer()
{
   // Periodic session save (every 60 seconds)
   if(g_session.IsActive())
   {
      g_session.UpdateLivePnL();
      g_persistence.SaveSession(g_session);
   }
}
//+------------------------------------------------------------------+
