--!strict
-- ===================================================================
--  ZONES — the single, data-driven source of truth for every biome.
--
--  Each zone is PURE DATA: name, theme colors, a TYPED unlock condition,
--  geode types with drop tables, an exclusive pet, and a multiplier.
--  The engine (see server ZoneEngine) spawns & themes a zone entirely from
--  this data, so ADDING A ZONE = one entry here + decoration. Zone 1
--  (Crystal Cavern) is the existing baked hub (prebuilt = true).
--
--  Unlock condition types (data-driven — add gate styles without engine changes):
--    { type = "always" }                 -- starting zone
--    { type = "cracks",   value = N }     -- total geodes cracked  (grinder gate)
--    { type = "rebirths", value = N }     -- rebirth count         (progression gate)
--    { type = "shards",   value = N }     -- hidden shards found    (explorer gate)
--    { type = "indexPct", value = 0..1 }  -- collection completion  (collector gate)
-- ===================================================================

local Zones = {}
local C = Color3.fromRGB

Zones.list = {
	{
		key = "Cavern", name = "Crystal Cavern", icon = "🔮", isHub = true, prebuilt = true,
		center = Vector3.new(0, 0, 0), nodeCount = 14, radius = 45,
		unlock = { type = "always" },
		multiplier = 1, valueMult = 1,
		exclusivePet = { name = "Cave Sprite", emoji = "🪨", color = C(180, 150, 255), bonus = 0.10 },
		-- Zone-exclusive VIP pet: guaranteed for VIP-pass owners on their first crack here,
		-- and a rare (earnable) drop for everyone else. Its bonus ADDS on top of collectibles.
		vipPet = { name = "Crystal Monarch", emoji = "👑", color = C(230, 200, 120), bonus = 0.25 },
		geodes = {
			{ key = "cavern", name = "Cavern Geode",
			  dropTable = { Quartz = 60, Amethyst = 25, Topaz = 10, Emerald = 3.5, Ruby = 1.2, Starstone = 0.25, VoidOpal = 0.05 } },
		},
		theme = {
			rock = C(58, 54, 78), floor = C(44, 40, 62),
			floorMaterial = Enum.Material.Slate, wallMaterial = Enum.Material.Slate,
			accent = C(168, 110, 255), ambient = C(140, 120, 210),
			crystals = { C(158, 96, 255), C(64, 214, 224), C(190, 150, 255) },
			particle = "none",
		},
		light = {
			atmosphere = C(96, 92, 128), haze = 1.1, density = 0.24, glare = 0, decay = C(56, 52, 80),
			tint = C(255, 248, 240), brightness = 0.02, contrast = 0.1, saturation = 0.06,
			fog = C(34, 30, 48), bloom = 0.35, clock = 14.4,
		},
	},
	{
		key = "Frost", name = "Frost Hollow", icon = "❄️",
		center = Vector3.new(1000, 0, 0), nodeCount = 14, radius = 48,
		unlock = { type = "cracks", value = 250 }, -- grinder gate
		multiplier = 3, valueMult = 3, unlockPrice = 79, unlockProductId = 3707942040, -- Robux skip-unlock (still earnable free via the gate)
		exclusivePet = { name = "Frost Fawn", emoji = "❄️", color = C(150, 225, 255), bonus = 0.40 },
		vipPet = { name = "Glacier Guardian", emoji = "👑", color = C(150, 225, 255), bonus = 0.60 },
		geodes = {
			{ key = "frost", name = "Frost Geode",
			  dropTable = { Quartz = 45, Amethyst = 28, Topaz = 15, Emerald = 7, Ruby = 3, Starstone = 1.5, VoidOpal = 0.5 } },
		},
		theme = {
			rock = C(112, 128, 152), floor = C(148, 168, 188),
			floorMaterial = Enum.Material.Glacier, wallMaterial = Enum.Material.Ice,
			accent = C(120, 214, 255), ambient = C(160, 200, 255),
			crystals = { C(110, 206, 255), C(190, 232, 255), C(64, 214, 224) },
			particle = "snow",
		},
		light = {
			atmosphere = C(196, 220, 244), haze = 1.4, density = 0.24, glare = 0.05, decay = C(150, 180, 215),
			tint = C(240, 246, 255), brightness = 0.05, contrast = 0.1, saturation = 0.04,
			fog = C(150, 176, 206), bloom = 0.4, clock = 14,
		},
	},
	{
		key = "Sunken", name = "Sunken Grotto", icon = "🐚",
		center = Vector3.new(0, 0, -1000), nodeCount = 14, radius = 48,
		unlock = { type = "shards", value = 5 }, -- explorer gate (find 5 hidden shards in Zone 1)
		multiplier = 5, valueMult = 5, unlockPrice = 99, unlockProductId = 3707942088,
		exclusivePet = { name = "Grotto Jelly", emoji = "🪺", color = C(90, 230, 210), bonus = 0.55 },
		vipPet = { name = "Abyssal Warden", emoji = "👑", color = C(90, 230, 210), bonus = 0.85 },
		geodes = {
			{ key = "sunken", name = "Sunken Geode",
			  dropTable = { Quartz = 38, Amethyst = 27, Topaz = 17, Emerald = 9, Ruby = 5, Starstone = 2.5, VoidOpal = 1 } },
		},
		theme = {
			rock = C(46, 66, 78), floor = C(40, 60, 70),
			floorMaterial = Enum.Material.Sand, wallMaterial = Enum.Material.Slate,
			accent = C(64, 214, 224), ambient = C(70, 180, 190),
			crystals = { C(64, 214, 224), C(120, 240, 214), C(255, 206, 120) },
			particle = "bubble",
		},
		light = {
			atmosphere = C(90, 170, 182), haze = 1.2, density = 0.2, glare = 0.02, decay = C(58, 124, 140),
			tint = C(224, 244, 242), brightness = 0.06, contrast = 0.1, saturation = 0.08,
			fog = C(24, 54, 64), bloom = 0.4, clock = 0,
		},
	},
	{
		key = "Magma", name = "Magma Depths", icon = "🌋",
		center = Vector3.new(0, 0, 1000), nodeCount = 14, radius = 48,
		unlock = { type = "rebirths", value = 3 }, -- progression gate
		multiplier = 9, valueMult = 9, unlockPrice = 149, unlockProductId = 3707942132,
		exclusivePet = { name = "Ember Drake", emoji = "🔥", color = C(255, 120, 60), bonus = 0.70 },
		vipPet = { name = "Inferno Titan", emoji = "👑", color = C(255, 120, 60), bonus = 1.10 },
		geodes = {
			{ key = "magma", name = "Magma Geode",
			  dropTable = { Quartz = 30, Amethyst = 25, Topaz = 20, Emerald = 12, Ruby = 7, Starstone = 4, VoidOpal = 2 } },
		},
		theme = {
			rock = C(58, 44, 44), floor = C(46, 34, 34),
			floorMaterial = Enum.Material.Basalt, wallMaterial = Enum.Material.Basalt,
			accent = C(255, 138, 64), ambient = C(255, 150, 90),
			crystals = { C(255, 148, 64), C(255, 206, 120), C(255, 96, 64) },
			particle = "ember",
		},
		light = {
			atmosphere = C(210, 120, 70), haze = 1.2, density = 0.26, glare = 0.05, decay = C(150, 70, 44),
			tint = C(255, 226, 204), brightness = 0.03, contrast = 0.12, saturation = 0.1,
			fog = C(56, 28, 22), bloom = 0.45, clock = 0,
		},
	},
	{
		key = "Astral", name = "Astral Void", icon = "🌌",
		center = Vector3.new(-1000, 0, 0), nodeCount = 16, radius = 50,
		unlock = { type = "indexPct", value = 0.8 }, -- collector endgame gate
		multiplier = 25, valueMult = 25, unlockPrice = 249, unlockProductId = 3707942181,
		exclusivePet = { name = "Void Wisp", emoji = "🌌", color = C(200, 130, 255), bonus = 1.20 },
		vipPet = { name = "Cosmic Sovereign", emoji = "👑", color = C(200, 130, 255), bonus = 1.80 },
		geodes = {
			{ key = "astral", name = "Astral Geode",
			  dropTable = { Quartz = 18, Amethyst = 20, Topaz = 22, Emerald = 18, Ruby = 12, Starstone = 7, VoidOpal = 3 } },
		},
		theme = {
			-- Glass floor/walls were a mobile transparency-overdraw hazard: now Slate
			rock = C(40, 34, 58), floor = C(28, 24, 42),
			floorMaterial = Enum.Material.Slate, wallMaterial = Enum.Material.Slate,
			accent = C(178, 120, 255), ambient = C(150, 110, 230),
			crystals = { C(158, 96, 255), C(64, 214, 224), C(210, 160, 255) },
			particle = "star",
		},
		light = {
			atmosphere = C(110, 90, 170), haze = 1.0, density = 0.22, glare = 0.05, decay = C(70, 56, 120),
			tint = C(238, 230, 255), brightness = 0.03, contrast = 0.12, saturation = 0.1,
			fog = C(20, 16, 34), bloom = 0.45, clock = 0,
		},
	},
}

-- ---- accessors ----
function Zones.Get(key)
	for _, z in ipairs(Zones.list) do
		if z.key == key then return z end
	end
	return nil
end

function Zones.Index(key)
	for i, z in ipairs(Zones.list) do
		if z.key == key then return i end
	end
	return nil
end

-- ---- unlock evaluation (PURE: operates on a stats snapshot, never a Player) ----

-- Build the stats snapshot the evaluators read, from a data profile.
function Zones.StatsFor(profile)
	if not profile then return { cracks = 0, rebirths = 0, indexPct = 0, shards = {}, purchased = {} } end
	local bits, mask = 0, profile.indexMask or 0
	for i = 0, 27 do
		if bit32.band(mask, bit32.lshift(1, i)) ~= 0 then bits += 1 end
	end
	return {
		cracks = profile.cracks or 0,
		rebirths = profile.rebirths or 0,
		indexPct = bits / 28,
		shards = profile.zoneShards or {}, -- { [zoneKey] = count } (Phase 2 explorer gate)
		purchased = profile.zonesPurchased or {}, -- { [zoneKey] = true } (Phase 4 paid skip-unlock)
	}
end

local function currentFor(zone, stats)
	local u = zone.unlock
	if not u or u.type == "always" then return 1, 1 end
	if u.type == "cracks" then return stats.cracks or 0, u.value end
	if u.type == "rebirths" then return stats.rebirths or 0, u.value end
	if u.type == "shards" then return (stats.shards and stats.shards[zone.key]) or 0, u.value end
	if u.type == "indexPct" then return stats.indexPct or 0, u.value end
	return 0, 1
end

function Zones.IsUnlocked(zone, stats)
	if not zone then return false end
	if not zone.unlock or zone.unlock.type == "always" then return true end
	if stats and stats.purchased and stats.purchased[zone.key] then return true end -- paid skip-unlock
	local cur, goal = currentFor(zone, stats)
	return cur >= goal
end

-- The dev-product key that skip-unlocks a zone (nil for the always-open hub / no price).
function Zones.UnlockProductKey(zone)
	if not zone or not zone.unlockPrice then return nil end
	return "Unlock_" .. zone.key
end

function Zones.UnlockText(zone)
	local u = zone and zone.unlock
	if not u or u.type == "always" then return "Starting zone" end
	if u.type == "cracks" then return "Crack " .. u.value .. " geodes" end
	if u.type == "rebirths" then return "Reach Rebirth " .. u.value end
	if u.type == "shards" then return "Find " .. u.value .. " hidden shards" end
	if u.type == "indexPct" then return "Complete " .. math.floor(u.value * 100) .. "% of the Index" end
	return "Locked"
end

-- progress toward the unlock, for the teasing UI: pct 0..1 + a "cur / goal" label
function Zones.Progress(zone, stats)
	local cur, goal = currentFor(zone, stats)
	local pct = goal > 0 and math.clamp(cur / goal, 0, 1) or 1
	local label
	if zone.unlock and zone.unlock.type == "indexPct" then
		label = math.floor((stats.indexPct or 0) * 100) .. "% / " .. math.floor(zone.unlock.value * 100) .. "%"
	else
		label = tostring(math.floor(cur)) .. " / " .. tostring(goal)
	end
	return { pct = pct, current = cur, goal = goal, label = label, text = Zones.UnlockText(zone) }
end

return Zones
