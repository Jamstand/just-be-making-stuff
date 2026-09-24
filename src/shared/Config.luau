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
	{ key = "DoubleGems", id = 1947680333, price = 149, icon = "💰", name = "2× Gems",    desc = "Permanently DOUBLE all Gem income — every crack, garden harvest & meteor." },
	{ key = "AutoCrack",  id = 1949360316, price = 49,  icon = "🤖", name = "Auto-Crack", desc = "Auto-cracks nearby geodes for you — hands-free, great for idle & mobile." },
	{ key = "DoubleLuck", id = 1950950318, price = 199, icon = "🍀", name = "Lucky",      desc = "Permanently boosts your odds of Rare crystals (Emerald & up)." },
	{ key = "VIP",        id = 1948736326, price = 399, icon = "👑", name = "VIP",        desc = "Daily Gem bonus + [VIP] chat tag + exclusive Royal pet + gold aura & +2 Garden plots." },
}

-- Developer products (consumable, re-buyable via ProcessReceipt). `id` stays 0
-- until you create each on the Creator Dashboard, then paste the Product ID here.
Config.DevProducts = {
	{ key = "LuckyBoost",    id = 3707941537, price = 19, icon = "⚡", name = "Lucky Boost (5 min)", desc = "+100% Luck for 5 minutes. Stacks to 15." },
	{ key = "GiftBoost",     id = 3707941703, price = 25, icon = "🎁", name = "Gift a Boost",        desc = "Gift a Lucky Boost AND give the whole server +10% Luck!" },
	{ key = "InstantRegrow", id = 3707941759, price = 29, icon = "🌱", name = "Instant Regrow",      desc = "Instantly matures ALL your Garden plots." },
	{ key = "GoldenGeode",   id = 3707941808, price = 79, icon = "🌟", name = "Golden Geode",        desc = "Spawn a giant golden geode — guaranteed Ruby+ inside!" },
	-- gem packs (3 price points; `coins` = amount granted — internal field name, do not rename)
	{ key = "CoinsSmall",  id = 3707941838, price = 25,  icon = "💰", name = "Gem Pouch", desc = "+12,500 Gems instantly.",        coins = 12500 },
	{ key = "CoinsMedium", id = 3707941875, price = 99,  icon = "💰", name = "Gem Sack",  desc = "+80,000 Gems — better value!",   coins = 80000 },
	{ key = "CoinsLarge",  id = 3707941917, price = 399, icon = "💰", name = "Gem Vault", desc = "+600,000 Gems — best value!",     coins = 600000 },
	-- one-time discounted starter pack (offered only during a player's FIRST session).
	-- starter=true hides it from the normal shop list; it renders as a special offer card.
	{ key = "StarterPack", id = 3707941969, price = 49, icon = "⭐", name = "Starter Pack",
		desc = "40,000 Gems + the exclusive Starter Sprite pet (+15% forever). One-time only!",
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

-- ===== Zones (biomes) =====
-- Zone data now lives in the data-driven ReplicatedStorage.Zones module — the
-- single source of truth (typed unlocks, drop tables, exclusive pets, multipliers).
-- These aliases keep existing consumers reading from Zones. Adding a zone = one
-- entry in Zones (plus decoration) — nothing to edit here.
local Zones = require(game:GetService("ReplicatedStorage"):WaitForChild("Zones"))
Config.Zones = Zones
Config.Regions = Zones.list       -- back-compat alias (spatial/theme/light data)
Config.RegionByKey = Zones.Get    -- back-compat alias

-- Phase 4: auto-derive one skip-unlock dev product per gated zone, straight from
-- its data. The zone stays fully EARNABLE via its unlock condition — this product
-- only lets a player pay Robux to open it now. Add a zone with an unlockPrice and
-- its product appears automatically; nothing else to edit. Create each on the
-- Creator Dashboard and paste its Product ID over the 0 to go live.
for _, z in ipairs(Zones.list) do
	if z.unlockPrice and z.unlockPrice > 0 then
		table.insert(Config.DevProducts, {
			key = "Unlock_" .. z.key, id = z.unlockProductId or 0, price = z.unlockPrice, icon = z.icon,
			name = "Unlock " .. z.name,
			desc = "Open " .. z.name .. " instantly (×" .. z.multiplier .. " Gems). Or earn it free: " .. string.lower(Zones.UnlockText(z)) .. ".",
			zone = z.key,        -- consumed by Monetize.GrantProduct
			zoneUnlock = true,   -- lets the shop UI skip these; they surface on the zone gate instead
		})
	end
end

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

-- ===== Currency (player-facing) =====
-- The currency is "Gems 💎" everywhere a player can read it. Internal keys
-- (DoubleGems, CoinsSmall/Medium/Large, the `coins` field) never change.
Config.Currency = { name = "Gems", icon = "💎" }

-- "12.3K 💎" — the one way to print an amount with its icon.
function Config.Cur(n)
	return Config.Fmt(tonumber(n) or 0) .. " " .. Config.Currency.icon
end

-- ===== Social (presence, feed, cheers, server goals, settings) =====
-- Single source for every social limit and route; server AND client read these
-- (no duplicated literals). Cheer wire value = index into Reactions.
Config.Social = {
	Reactions = { "👏", "🔥", "💎", "🎉", "👋", "💜" },   -- Cheer idx 1..6 (wire value = index)
	CheerGap = 2, CheerBurst = 6, CheerBurstWindow = 30,  -- per sender
	CheerTargetCap = 3, CheerTargetWindow = 10,           -- per target (display cap)
	FeedRing = 30, JoinCoalesce = 3, LeaveMinSession = 20,
	ProfileGap = 1, ProfileCache = 5,
	LeaderboardRefresh = 75, LeaderboardWriteGap = 60, LeaderboardTop = 50,
	SettingsGap = 2,
	SettingsDefault = { music = 22, sfx = 100, reduceFx = false, socialPings = true, hideFeed = false },
	GifterTitleAt = 3,                                    -- giftsGiven >= 3 -> Title "Gifter"
	Goals = {
		{ key = "cracks",   icon = "⛏️", event = "crack",   goal = 500, goalMin = 150, label = "Crack %d geodes together" },
		{ key = "rares",    icon = "⭐", event = "rare",    goal = 10,  goalMin = 3,   label = "Find %d Rare+ crystals together" },
		{ key = "rebirths", icon = "🔄", event = "rebirth", goal = 3,   goalMin = 1,   label = "%d Rebirths together" },
	},
	GoalWindow = 900, GoalRest = 60,                      -- seconds
	-- Announce routing for BROADCASTS (personal messages are flag-routed: personal=true -> toast)
	KindRoute = {
		warn = "headline", meteor = "headline", golden = "headline", goal = "headline",
		rare = "feed", rebirth = "feed", ascend = "feed", pet = "feed", pass = "feed", zone = "feed",
		zoneFirst = "feed", join = "feed", leave = "feed", cheer = "feed", gift = "feed", mvp = "feed",
		unlock = "feed", quest = "feed",
		-- personal-only kinds listed for colour lookup; they arrive with personal=true
		vip = "toast", onboard = "toast", daily = "toast", ach = "toast", giftReceived = "toast",
		region = "toast", locked = "toast", meteorPayout = "toast", garden = "toast", shard = "toast",
		welcome = "toast", info = "toast", error = "toast", ok = "toast",
	},
}

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