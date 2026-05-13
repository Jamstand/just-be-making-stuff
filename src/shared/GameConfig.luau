--!strict
--[[
    Central tuning + identity config. Server and client both require this.

    Step 7 of the setup checklist:
      Paste the numeric IDs from your Roblox Creator Dashboard into the
      ProductId / GamePassId fields below. Until then, the corresponding
      buttons in the Gems / Passes tabs will render as "Not set".
]]

local GameConfig = {}

-- World ------------------------------------------------------------------

GameConfig.MapHalfSize = 90
GameConfig.CoinFloatHeight = 4
GameConfig.CoinSpinSpeed = 2
GameConfig.CoinRespawnSeconds = 5
GameConfig.CoinCount = 40
GameConfig.ShopBeaconPosition = Vector3.new(12, 4, 0)
GameConfig.ShopOpenRadius = 10

-- Coin tiers -------------------------------------------------------------
-- Weights are relative; higher = more common.

GameConfig.CoinTiers = {
	{
		Name = "Bronze",
		Color = Color3.fromRGB(205, 127, 50),
		Coins = 1,
		Gems = 0,
		Weight = 60,
		Rare = false,
	},
	{
		Name = "Silver",
		Color = Color3.fromRGB(200, 200, 210),
		Coins = 5,
		Gems = 0,
		Weight = 25,
		Rare = false,
	},
	{
		Name = "Gold",
		Color = Color3.fromRGB(255, 215, 0),
		Coins = 15,
		Gems = 0,
		Weight = 12,
		Rare = false,
	},
	{
		Name = "Diamond",
		Color = Color3.fromRGB(120, 230, 255),
		Coins = 50,
		Gems = 1,
		Weight = 3,
		Rare = true,
	},
}

-- Daily reward -----------------------------------------------------------

GameConfig.DailyRewardCoins = 250
GameConfig.DailyRewardGems = 5
GameConfig.DailyCooldownSeconds = 22 * 60 * 60 -- 22h so you can claim a bit earlier each day

-- Upgrades ---------------------------------------------------------------
--
-- Tiers are 1-indexed; a player at Tier = 0 has no upgrade applied.
-- Cost = currency to advance from (Tier) to (Tier+1).
-- Value = effective value once you reach (Tier+1).

GameConfig.Upgrades = {
	Speed = {
		Display = "Walk Speed",
		Currency = "Coins",
		BaseValue = 16,
		Tiers = {
			{ Cost = 100, Value = 20 },
			{ Cost = 300, Value = 24 },
			{ Cost = 800, Value = 28 },
			{ Cost = 2000, Value = 32 },
		},
	},
	Jump = {
		Display = "Jump Power",
		Currency = "Coins",
		BaseValue = 50,
		Tiers = {
			{ Cost = 150, Value = 60 },
			{ Cost = 400, Value = 72 },
			{ Cost = 1000, Value = 86 },
			{ Cost = 2500, Value = 100 },
		},
	},
	Multiplier = {
		Display = "Coin Multiplier",
		Currency = "Gems",
		BaseValue = 1,
		Tiers = {
			{ Cost = 20, Value = 1.25 },
			{ Cost = 60, Value = 1.5 },
			{ Cost = 150, Value = 2.0 },
		},
	},
	Magnet = {
		Display = "Magnet Range",
		Currency = "Gems",
		BaseValue = 0,
		Tiers = {
			{ Cost = 50, Value = 8 },
			{ Cost = 120, Value = 12 },
			{ Cost = 250, Value = 18 },
		},
	},
}

-- Upgrade display order (Luau dictionaries don't preserve insertion order).
GameConfig.UpgradeOrder = { "Speed", "Jump", "Multiplier", "Magnet" }

-- Gem packs (Robux Developer Products) -----------------------------------

GameConfig.GemProducts = {
	Small = {
		ProductId = 0, -- TODO: paste DeveloperProduct ID from Creator Dashboard
		Gems = 80,
		Display = "Small Gem Pack",
		Robux = 99,
	},
	Medium = {
		ProductId = 0,
		Gems = 500,
		Display = "Medium Gem Pack",
		Robux = 499,
	},
	Large = {
		ProductId = 0,
		Gems = 1200,
		Display = "Large Gem Pack",
		Robux = 999,
	},
}

GameConfig.GemProductOrder = { "Small", "Medium", "Large" }

-- Game Passes ------------------------------------------------------------

GameConfig.GamePasses = {
	DoubleCoins = {
		GamePassId = 0, -- TODO: paste GamePass ID from Creator Dashboard
		Display = "2x Coins",
		Description = "Doubles every coin pickup.",
		Multiplier = 2,
	},
	VIP = {
		GamePassId = 0,
		Display = "VIP",
		Description = "1.5x coins, gold trail, and a VIP tag.",
		Multiplier = 1.5,
	},
	AutoCollect = {
		GamePassId = 0,
		Display = "Auto Collect Magnet",
		Description = "Permanent magnet range of 16 studs.",
		MagnetRange = 16,
	},
}

GameConfig.GamePassOrder = { "DoubleCoins", "VIP", "AutoCollect" }

-- DataStore --------------------------------------------------------------

GameConfig.DataStoreName = "CoinRushPlayerData_v1"
GameConfig.AutosaveSeconds = 60

return GameConfig
