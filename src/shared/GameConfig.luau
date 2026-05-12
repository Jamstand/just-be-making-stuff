local GameConfig = {
	MapHalfSize = 110,
	CoinFloatHeight = 4,
	CoinSpinSpeed = 2,
	CoinRespawnSeconds = 5,
	TotalCoins = 40,

	-- Coin tiers: weight = relative spawn probability
	CoinTiers = {
		Bronze = { Value = 1, Color = Color3.fromRGB(205, 127, 50), Weight = 60, Size = 1.6 },
		Silver = { Value = 5, Color = Color3.fromRGB(192, 192, 192), Weight = 28, Size = 1.9 },
		Gold = { Value = 20, Color = Color3.fromRGB(255, 215, 0), Weight = 10, Size = 2.2 },
		Diamond = { Value = 100, GemReward = 1, Color = Color3.fromRGB(120, 230, 255), Weight = 2, Size = 2.4 },
	},

	-- Per-upgrade base stats. Effects are applied in UpgradeService.
	Upgrades = {
		Speed = { MaxTier = 5, Base = 16, PerTier = 4 },         -- 16, 20, 24, 28, 32, 36
		Jump = { MaxTier = 5, Base = 50, PerTier = 10 },         -- 50, 60, ...
		Multiplier = { MaxTier = 5, Base = 1.0, PerTier = 0.5 }, -- 1.0, 1.5, 2.0, ...
		Magnet = { MaxTier = 3, Base = 0, PerTier = 10 },        -- 0, 10, 20, 30 stud pickup radius
	},

	-- GamePass perks. Set GamePassId to your real asset id after publishing.
	GamePasses = {
		DoubleCoins = { GamePassId = 0, Multiplier = 2 },
		VIP = { GamePassId = 0, Multiplier = 1.5, Trail = true },
		AutoCollect = { GamePassId = 0, Radius = 15 },
	},

	-- DeveloperProducts grant gems. Set ProductId to your real asset id.
	GemProducts = {
		Small = { ProductId = 0, Gems = 80, RobuxPrice = 99 },
		Medium = { ProductId = 0, Gems = 500, RobuxPrice = 499 },
		Large = { ProductId = 0, Gems = 1200, RobuxPrice = 999 },
	},

	DailyReward = {
		CoinAmount = 250,
		GemAmount = 5,
		IntervalSeconds = 22 * 60 * 60, -- claim once per ~22h
	},

	DataStoreName = "PlayerData_v1",
	AutosaveSeconds = 60,
}

return GameConfig
