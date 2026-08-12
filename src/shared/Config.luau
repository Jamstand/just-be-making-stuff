--!strict
-- Crack a Geode! — single tuning surface for the whole game.
-- After publishing: create the passes/products on the Creator Dashboard and paste their IDs below.
-- While any id is 0 (or the place is unpublished), that item runs in Studio-test mode:
-- purchases are simulated through the SAME grant functions ProcessReceipt uses.

local Config = {}

Config.Version = 1

-- ===== Monetization catalog =====
-- Game pass lineup. `id` stays 0 until you create each pass on the Creator
-- Dashboard, then paste its numeric Pass ID here (see the walkthrough). The
-- internal `key` is what the code uses — do not change it; only edit id/price/text.
Config.GamePasses = {
	{ key = "DoubleGems", id = 0, price = 149, icon = "💰", name = "2× Coins",   desc = "Permanently DOUBLE all Coin income — every crack, garden harvest & meteor." },
	{ key = "AutoCrack",  id = 0, price = 49,  icon = "🤖", name = "Auto-Crack", desc = "Auto-cracks nearby geodes for you — hands-free, great for idle & mobile." },
	{ key = "DoubleLuck", id = 0, price = 199, icon = "🍀", name = "Lucky",      desc = "Permanently boosts your odds of Rare crystals (Emerald & up)." },
	{ key = "VIP",        id = 0, price = 399, icon = "👑", name = "VIP",        desc = "Daily Coin bonus + [VIP] chat tag + exclusive Royal pet + gold aura & +2 Garden plots." },
}

-- Developer products (consumable, re-buyable via ProcessReceipt). `id` stays 0
-- until you create each on the Creator Dashboard, then paste the Product ID here.
Config.DevProducts = {
	{ key = "LuckyBoost",    id = 0, price = 19, icon = "⚡", name = "Lucky Boost (5 min)", desc = "+100% Luck for 5 minutes. Stacks to 15." },
	{ key = "GiftBoost",     id = 0, price = 25, icon = "🎁", name = "Gift a Boost",        desc = "Gift a Lucky Boost AND give the whole server +10% Luck!" },
	{ key = "InstantRegrow", id = 0, price = 29, icon = "🌱", name = "Instant Regrow",      desc = "Instantly matures ALL your Garden plots." },
	{ key = "GoldenGeode",   id = 0, price = 79, icon = "🌟", name = "Golden Geode",        desc = "Spawn a giant golden geode — guaranteed Ruby+ inside!" },
	-- coin packs (3 price points; `coins` = amount granted)
	{ key = "CoinsSmall",  id = 0, price = 25,  icon = "💰", name = "Coin Pouch", desc = "+12,500 Coins instantly.",        coins = 12500 },
	{ key = "CoinsMedium", id = 0, price = 99,  icon = "💰", name = "Coin Sack",  desc = "+80,000 Coins — better value!",   coins = 80000 },
	{ key = "CoinsLarge",  id = 0, price = 399, icon = "💰", name = "Coin Vault", desc = "+600,000 Coins — best value!",     coins = 600000 },
	-- one-time discounted starter pack (offered only during a player's FIRST session).
	-- starter=true hides it from the normal shop list; it renders as a special offer card.
	{ key = "StarterPack", id = 0, price = 49, icon = "⭐", name = "Starter Pack",
		desc = "40,000 Coins + the exclusive Starter Sprite pet (+15% forever). One-time only!",
		coins = 40000, starter = true },
}

function Config.PassByKey(key)
	for _, p in ipairs(Config.GamePasses) do
		if p.key == key then return p end
	end
	return nil
end

function Config.ProductByKey(key)
	for _, p in ipairs(Config.DevProducts) do
		if p.key == key then return p end
	end
	return nil
end

-- ===== Rarities & mutations =====
Config.Rarities = {
	{ key = "Quartz",    name = "Quartz",    weight = 60,   value = 5,     color = Color3.fromRGB(235, 235, 245) },
	{ key = "Amethyst",  name = "Amethyst",  weight = 25,   value = 12,    color = Color3.fromRGB(180, 120, 255) },
	{ key = "Topaz",     name = "Topaz",     weight = 10,   value = 40,    color = Color3.fromRGB(255, 195, 70) },
	{ key = "Emerald",   name = "Emerald",   weight = 3.5,  value = 150,   color = Color3.fromRGB(70, 245, 140) },
	{ key = "Ruby",      name = "Ruby",      weight = 1.2,  value = 600,   color = Color3.fromRGB(255, 80, 100) },
	{ key = "Starstone", name = "Starstone", weight = 0.25, value = 3000,  color = Color3.fromRGB(100, 190, 255) },
	{ key = "VoidOpal",  name = "Void Opal", weight = 0.05, value = 15000, color = Color3.fromRGB(255, 115, 230) },
}
Config.LuckyTierIndex = 4 -- Emerald and up get multiplied by the player's luck factor

Config.Mutations = {
	{ key = "None",      weight = 92.5, mult = 1,  color = nil },
	{ key = "Glowing",   weight = 5,    mult = 3,  color = Color3.fromRGB(255, 255, 190) },
	{ key = "Giant",     weight = 2,    mult = 5,  color = Color3.fromRGB(130, 255, 255) },
	{ key = "Celestial", weight = 0.5,  mult = 20, color = Color3.fromRGB(255, 235, 130) },
}

-- ===== Ascension perks (1 shard each) =====
Config.Perks = {
	{ key = "AutoRadius",  icon = "📡", name = "Wide Auto-Crack", desc = "+4 studs Auto-Crack radius" },
	{ key = "ExtraPlot",   icon = "🌱", name = "Extra Plot",      desc = "+1 Geode Garden plot" },
	{ key = "OfflineCap",  icon = "⏰", name = "Deep Roots",      desc = "Garden offline cap 24h → 48h" },
	{ key = "PityDown",    icon = "🎯", name = "Fate's Favor",    desc = "Mythic pity thresholds -20%" },
	{ key = "CelestialUp", icon = "✨", name = "Star Blessed",    desc = "Celestial mutation odds +0.25%" },
}

-- ===== Balance =====
Config.Balance = {
	CrackCooldownBase = 2.0,
	CrackCooldownDecay = 0.94,
	CrackCooldownMin = 0.4,
	PowerCostBase = 25, PowerCostGrowth = 1.35,
	LuckCostBase = 100, LuckCostGrowth = 1.4,   -- cheaper so Luck is a viable second path
	LuckWeightPerLevel = 0.08,                   -- more rare-odds per level
	-- Rebirth pacing (retuned 2026-08-12): compounding reward keeps pace with cost,
	-- so every rebirth stays ~6-15 min instead of doubling forever. See economy sim.
	RebirthCostBase = 20000, RebirthCostGrowth = 1.72,
	RebirthMultBase = 1.5,   -- income x1.5 per rebirth (compounding), replaces the old +0.5 linear
	RebirthMultPer = 0.5,    -- (legacy, unused)
	AscendMult = 2.5,        -- income x2.5 per ascension (permanent)
	AscensionAtRebirth = 15,
	PityFirstTopaz = 15,
	PityRuby = 400,
	PityStar = 2000,
	GardenRate = 0.15,
	MeteorInterval = 600,
	MeteorHPPerPlayer = 60,
	MeteorPayoutBase = 400,
	GoldenHourInterval = 1800,
	GoldenHourDuration = 120,
	ServerLuckPerGift = 0.1,
	ServerLuckMax = 0.5,
	ServerLuckDuration = 120,
	BoostSeconds = 300,
	BoostCapSeconds = 900,
	AutosaveInterval = 30,
	NodeCount = 14,
	NodeRingRadius = 45,
	NodeRespawn = 2,
	ClickRange = 16,
}

-- ===== Formulas =====
function Config.PowerCost(level)
	return math.floor(Config.Balance.PowerCostBase * Config.Balance.PowerCostGrowth ^ level)
end

function Config.LuckCost(level)
	return math.floor(Config.Balance.LuckCostBase * Config.Balance.LuckCostGrowth ^ level)
end

function Config.RebirthCost(rebirths)
	return math.floor(Config.Balance.RebirthCostBase * Config.Balance.RebirthCostGrowth ^ rebirths)
end

function Config.Cooldown(power)
	return math.max(Config.Balance.CrackCooldownMin, Config.Balance.CrackCooldownBase * Config.Balance.CrackCooldownDecay ^ power)
end

function Config.Fmt(n)
	if n < 1000 then return tostring(math.floor(n)) end
	local suffix = { "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc" }
	local i = math.clamp(math.floor(math.log(n, 1000)), 1, #suffix)
	return string.format("%.1f%s", n / (1000 ^ i), suffix[i])
end

-- ===== Music playlist (licensed Creator Store tracks — swap IDs freely) =====
Config.Music = {
	"rbxassetid://92441677745155",  -- Coastline Drift
	"rbxassetid://100043543602050", -- Snooze
	"rbxassetid://131102720495723", -- Awareness
	"rbxassetid://125082910760435", -- Diamond Shaped Signs
}

-- ===== Sounds (free Creator Store SFX) =====
Config.Sounds = {
	Crack = "rbxassetid://9120826936",
	Gem = "rbxassetid://4612374393",
	Rare = "rbxassetid://135385970610304",
	Boom = "rbxassetid://138533090376585",
	Buy = "rbxassetid://93529351909119",
}

return Config
