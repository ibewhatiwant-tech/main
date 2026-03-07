# GRID RISK MODEL

Models exposure growth for grid systems.

Core formulas:

Lot_n = BaseLot \* (Multiplier \^ (n-1))

FloatingLoss = Σ(price_distance × lot × contract_size)

Purpose: Predict maximum survivable trend distance before liquidation.
