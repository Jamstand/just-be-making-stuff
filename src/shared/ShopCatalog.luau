-- Tier N costs: cost[N] is the cost to GO from tier N-1 to tier N.
-- Costs are paid in either "Coins" or "Gems" as noted by CurrencyType.

local ShopCatalog = {
	Upgrades = {
		Speed = {
			DisplayName = "Speed Boost",
			Description = "+4 walk speed per tier",
			CurrencyType = "Coins",
			Costs = { 100, 500, 2500, 10000, 35000 },
		},
		Jump = {
			DisplayName = "Jump Boost",
			Description = "+10 jump power per tier",
			CurrencyType = "Coins",
			Costs = { 150, 800, 3500, 12000, 40000 },
		},
		Multiplier = {
			DisplayName = "Coin Multiplier",
			Description = "+50% coin value per tier",
			CurrencyType = "Gems",
			Costs = { 25, 80, 200, 500, 1200 },
		},
		Magnet = {
			DisplayName = "Coin Magnet",
			Description = "Pulls nearby coins toward you",
			CurrencyType = "Gems",
			Costs = { 50, 150, 400 },
		},
	},
}

return ShopCatalog
