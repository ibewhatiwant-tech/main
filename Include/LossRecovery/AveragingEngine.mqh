//+------------------------------------------------------------------+
//|                                              AveragingEngine.mqh |
//|                         Loss Recovery Strategy - Grid Averaging   |
//+------------------------------------------------------------------+
#ifndef __AVERAGINGENGINE_MQH__
#define __AVERAGINGENGINE_MQH__

#include "Defines.mqh"
#include "Utils.mqh"
#include "Logger.mqh"
#include "PositionManager.mqh"
#include "RecoverySession.mqh"

//+------------------------------------------------------------------+
//| CAveragingEngine - Grid planning and order placement              |
//+------------------------------------------------------------------+
class CAveragingEngine
{
private:
   CLogger          *m_logger;
   CPositionManager *m_pos_mgr;

   // Parameters
   ENUM_SIZING_MODE  m_sizing_mode;
   double            m_base_lot;
   double            m_geometric_multiplier;
   int               m_max_steps;
   double            m_max_total_volume;
   double            m_grid_spacing_pips;
   bool              m_use_atr_spacing;
   double            m_atr_multiplier;
   int               m_atr_period;

public:
   CAveragingEngine();
   ~CAveragingEngine();

   void   Init(CLogger *logger, CPositionManager *pos_mgr);
   void   SetParameters(ENUM_SIZING_MODE sizing_mode, double base_lot,
                        double geometric_multiplier, int max_steps,
                        double max_total_volume, double grid_spacing_pips,
                        bool use_atr_spacing, double atr_multiplier, int atr_period);

   //--- Grid planning
   bool   BuildGrid(CRecoverySession &session);
   bool   CanPlaceNextLevel(CRecoverySession &session);
   bool   CheckAndPlaceNextStep(CRecoverySession &session);

   //--- Calculations
   double CalculateLotForStep(string symbol, int step);
   double CalculateGridSpacing(string symbol);
   double CalculateBreakevenPrice(CRecoverySession &session);

private:
   double GetGridDirection(const CRecoverySession &session);
};

//+------------------------------------------------------------------+
CAveragingEngine::CAveragingEngine()
{
   m_logger  = NULL;
   m_pos_mgr = NULL;
   m_sizing_mode = SIZING_GEOMETRIC;
   m_base_lot = 0.1;
   m_geometric_multiplier = 2.0;
   m_max_steps = 6;
   m_max_total_volume = 2.0;
   m_grid_spacing_pips = 50.0;
   m_use_atr_spacing = false;
   m_atr_multiplier = 1.5;
   m_atr_period = 14;
}

//+------------------------------------------------------------------+
CAveragingEngine::~CAveragingEngine()
{
}

//+------------------------------------------------------------------+
void CAveragingEngine::Init(CLogger *logger, CPositionManager *pos_mgr)
{
   m_logger  = logger;
   m_pos_mgr = pos_mgr;
}

//+------------------------------------------------------------------+
void CAveragingEngine::SetParameters(ENUM_SIZING_MODE sizing_mode, double base_lot,
                                     double geometric_multiplier, int max_steps,
                                     double max_total_volume, double grid_spacing_pips,
                                     bool use_atr_spacing, double atr_multiplier,
                                     int atr_period)
{
   m_sizing_mode           = sizing_mode;
   m_base_lot              = base_lot;
   m_geometric_multiplier  = geometric_multiplier;
   m_max_steps             = max_steps;
   m_max_total_volume      = max_total_volume;
   m_grid_spacing_pips     = grid_spacing_pips;
   m_use_atr_spacing       = use_atr_spacing;
   m_atr_multiplier        = atr_multiplier;
   m_atr_period            = atr_period;
}

//+------------------------------------------------------------------+
//| Calculate lot size for a given grid step                          |
//+------------------------------------------------------------------+
double CAveragingEngine::CalculateLotForStep(string symbol, int step)
{
   double lot = 0;

   switch(m_sizing_mode)
   {
      case SIZING_FIXED:
         lot = m_base_lot;
         break;

      case SIZING_GEOMETRIC:
         lot = m_base_lot * MathPow(m_geometric_multiplier, step);
         break;

      case SIZING_RISK_BASED:
      {
         // Risk 2% of free margin per step
         double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
         double risk_amount = free_margin * 0.02;
         double pip_value = GetPipValue(symbol);
         double spacing = CalculateGridSpacing(symbol);
         double spacing_pips = PriceToPips(symbol, spacing);

         if(pip_value > 0 && spacing_pips > 0)
            lot = risk_amount / (spacing_pips * pip_value);
         else
            lot = m_base_lot;
         break;
      }
   }

   return NormalizeLot(symbol, lot);
}

//+------------------------------------------------------------------+
//| Calculate grid spacing in price units                             |
//+------------------------------------------------------------------+
double CAveragingEngine::CalculateGridSpacing(string symbol)
{
   if(m_use_atr_spacing)
   {
      double atr = GetATR(symbol, m_atr_period);
      if(atr > 0)
         return atr * m_atr_multiplier;
   }

   return PipsToPrice(symbol, m_grid_spacing_pips);
}

//+------------------------------------------------------------------+
//| Get grid direction multiplier (+1 or -1)                          |
//| Averaging orders go in the OPPOSITE direction of the losing pos   |
//| (same direction as hedge) to accumulate profit                    |
//+------------------------------------------------------------------+
double CAveragingEngine::GetGridDirection(const CRecoverySession &session)
{
   // If losing position is BUY (price fell), averaging orders are SELL
   // Grid levels go DOWN from hedge price
   // If losing position is SELL (price rose), averaging orders are BUY
   // Grid levels go UP from hedge price
   return (session.losing_position.direction > 0) ? -1.0 : 1.0;
}

//+------------------------------------------------------------------+
//| Build the grid plan (price levels and volumes) for the session    |
//+------------------------------------------------------------------+
bool CAveragingEngine::BuildGrid(CRecoverySession &session)
{
   string symbol = session.losing_position.symbol;
   double spacing = CalculateGridSpacing(symbol);

   if(spacing <= 0)
   {
      if(m_logger != NULL)
         m_logger.Log(LOG_ERROR, "Invalid grid spacing calculated: " +
                      DoubleToString(spacing, 5));
      return false;
   }

   double direction = GetGridDirection(session);
   double base_price = session.hedge_position.open_price;

   // Build grid levels
   SGridLevel levels[];
   ArrayResize(levels, m_max_steps);
   double cumulative_volume = 0;

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   for(int i = 0; i < m_max_steps; i++)
   {
      double lot = CalculateLotForStep(symbol, i);

      // Check max total volume constraint
      if(cumulative_volume + lot > m_max_total_volume)
      {
         lot = NormalizeLot(symbol, m_max_total_volume - cumulative_volume);
         if(lot <= 0)
         {
            ArrayResize(levels, i);
            break;
         }
      }

      levels[i].step         = i + 1;
      levels[i].volume       = lot;
      levels[i].price_offset = spacing * (i + 1);
      levels[i].target_price = NormalizeDouble(base_price + direction * spacing * (i + 1), digits);
      levels[i].is_filled    = false;
      cumulative_volume     += lot;
   }

   session.SetGridLevels(levels);

   if(m_logger != NULL)
   {
      int count = ArraySize(levels);
      m_logger.Log(LOG_INFO, StringFormat(
         "Grid built: %d levels, total planned volume=%.2f, spacing=%.5f (%s)",
         count, cumulative_volume, spacing,
         m_use_atr_spacing ? "ATR-based" : "fixed pips"));

      for(int i = 0; i < count; i++)
      {
         m_logger.Log(LOG_INFO, StringFormat(
            "  Level %d: price=%.5f, volume=%.2f",
            levels[i].step, levels[i].target_price, levels[i].volume));
      }
   }

   return (ArraySize(levels) > 0);
}

//+------------------------------------------------------------------+
//| Check if the next grid level can be placed                        |
//+------------------------------------------------------------------+
bool CAveragingEngine::CanPlaceNextLevel(CRecoverySession &session)
{
   int next_idx = session.GetNextUnfilledLevel();
   if(next_idx < 0)
      return false; // All levels filled or no grid

   // Check max steps
   if(session.GetActiveAveragingCount() >= m_max_steps)
      return false;

   // Check max total volume
   double current_vol = session.GetTotalAveragingVolume();
   if(current_vol >= m_max_total_volume)
      return false;

   return true;
}

//+------------------------------------------------------------------+
//| Check price and place next averaging order if conditions met      |
//+------------------------------------------------------------------+
bool CAveragingEngine::CheckAndPlaceNextStep(CRecoverySession &session)
{
   if(!CanPlaceNextLevel(session))
      return false;

   int next_idx = session.GetNextUnfilledLevel();
   if(next_idx < 0) return false;

   string symbol = session.losing_position.symbol;
   double target_price = session.grid_levels[next_idx].target_price;
   double direction = GetGridDirection(session);

   // Get current price
   double current_price;
   if(direction < 0)
      current_price = SymbolInfoDouble(symbol, SYMBOL_BID); // SELL orders use bid
   else
      current_price = SymbolInfoDouble(symbol, SYMBOL_ASK); // BUY orders use ask

   // Check if price has reached the grid level
   bool price_reached = false;
   if(direction < 0)
      price_reached = (current_price <= target_price); // Price falling for SELL grid
   else
      price_reached = (current_price >= target_price); // Price rising for BUY grid

   if(!price_reached)
      return false;

   // Place the averaging order
   double volume = session.grid_levels[next_idx].volume;
   volume = NormalizeLot(symbol, volume);

   // Check max total volume again with this specific volume
   double current_total = session.GetTotalAveragingVolume();
   if(current_total + volume > m_max_total_volume)
   {
      volume = NormalizeLot(symbol, m_max_total_volume - current_total);
      if(volume <= 0) return false;
   }

   string comment = StringFormat("LR_Avg_%s_L%d", session.session_id,
                                 session.grid_levels[next_idx].step);

   bool result = false;
   if(direction < 0)
      result = m_pos_mgr.OpenSell(symbol, volume, comment, MAGIC_AVERAGING);
   else
      result = m_pos_mgr.OpenBuy(symbol, volume, comment, MAGIC_AVERAGING);

   if(result)
   {
      // Mark grid level as filled
      session.grid_levels[next_idx].is_filled = true;

      // Find the new position and add to session
      Sleep(100);

      int total = PositionsTotal();
      for(int i = total - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;

         ulong pos_magic = (ulong)PositionGetInteger(POSITION_MAGIC);
         if(pos_magic != MAGIC_AVERAGING) continue;

         string pos_comment = PositionGetString(POSITION_COMMENT);
         if(StringFind(pos_comment, comment) >= 0 || pos_comment == comment)
         {
            SAveragingOrder avg_order;
            avg_order.ticket     = ticket;
            avg_order.volume     = PositionGetDouble(POSITION_VOLUME);
            avg_order.open_price = PositionGetDouble(POSITION_PRICE_OPEN);
            avg_order.step       = session.grid_levels[next_idx].step;
            avg_order.pnl        = 0;
            avg_order.is_closed  = false;

            session.AddAveragingOrder(avg_order);

            if(m_logger != NULL)
               m_logger.LogTrade(LOG_AVG_OPEN, ticket, avg_order.volume,
                                avg_order.open_price,
                                StringFormat("Averaging level %d placed",
                                            avg_order.step));
            break;
         }
      }

      return true;
   }

   if(m_logger != NULL)
      m_logger.Log(LOG_ERROR, StringFormat("Failed to place averaging level %d for %s",
                   session.grid_levels[next_idx].step, symbol));
   return false;
}

//+------------------------------------------------------------------+
//| Calculate breakeven price for all averaging orders + losing pos   |
//+------------------------------------------------------------------+
double CAveragingEngine::CalculateBreakevenPrice(CRecoverySession &session)
{
   double total_cost = 0;
   double total_volume = 0;

   // Losing position
   if(session.losing_position.volume > 0)
   {
      total_cost += session.losing_position.open_price * session.losing_position.volume;
      total_volume += session.losing_position.volume;
   }

   // Averaging orders (only active ones, in opposite direction)
   for(int i = 0; i < ArraySize(session.averaging_orders); i++)
   {
      if(!session.averaging_orders[i].is_closed)
      {
         // Averaging is opposite direction, so its contribution is negative
         total_cost -= session.averaging_orders[i].open_price *
                       session.averaging_orders[i].volume;
         total_volume -= session.averaging_orders[i].volume;
      }
   }

   if(MathAbs(total_volume) < 0.001) return 0;

   return total_cost / total_volume;
}

#endif // __AVERAGINGENGINE_MQH__
