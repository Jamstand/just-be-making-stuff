--[[
    Arena layouts. Coordinates are local to the arena origin: X is
    left/right, Y is up, and the main stage top usually sits at Y = 0.

    Platforms are { X1, Y1, X2, Y2 } rectangles.
      Soft = true   one-way: jump up through it, hold down to drop through.
      Style         "Island" (stone + grass), "Ruin" (brick), "Wood" (planks)

    Blast is the KO boundary; Camera is the area the camera is allowed
    to show.

    Kit names an imported 3D map kit (ReplicatedStorage.MapModels.<Kit>, made
    by art/blender/maps/*.py) that replaces the code-built visuals when it's
    there. Its painted background layers come from Config.Art.SkyImages[mapId];
    Sky.Top and Sky.Bottom color the plain gradient behind them.
]]

local Maps = {}

Maps.List = {
	SkyholdKeep = {
		Id = "SkyholdKeep",
		Name = "Skyhold Keep",
		Description = "A classic floating keep with two side platforms.",
		Platforms = {
			{ -36, -14, 36, 0, Style = "Island" },
			{ -27, 13, -13, 14, Soft = true, Style = "Wood" },
			{ 13, 13, 27, 14, Soft = true, Style = "Wood" },
			{ -7, 24, 7, 25, Soft = true, Style = "Wood" },
		},
		Spawns = { { -22, 0, 1 }, { 22, 0, -1 }, { -8, 0, 1 }, { 8, 0, -1 } },
		Respawns = { { 0, 34 }, { -14, 34 }, { 14, 34 } },
		WeaponSpawns = { { -28, 45 }, { -12, 45 }, { 0, 45 }, { 12, 45 }, { 28, 45 } },
		Blast = { -100, -75, 100, 80 },
		Camera = { -80, -45, 80, 62 },
		Sky = { Top = Color3.fromRGB(92, 158, 230), Bottom = Color3.fromRGB(255, 214, 170) },
		Seed = 11,
	},

	TwinIsles = {
		Id = "TwinIsles",
		Name = "Twin Isles",
		Description = "Two islands, a bridge, and a gap you really don't want to fall in.",
		Platforms = {
			{ -46, -12, -9, 0, Style = "Island" },
			{ 9, -12, 46, 0, Style = "Island" },
			{ -6, 9, 6, 10, Soft = true, Style = "Wood" },
			{ -34, 17, -20, 18, Soft = true, Style = "Wood" },
			{ 20, 17, 34, 18, Soft = true, Style = "Wood" },
		},
		Spawns = { { -30, 0, 1 }, { 30, 0, -1 }, { -16, 0, 1 }, { 16, 0, -1 } },
		Respawns = { { 0, 34 }, { -20, 34 }, { 20, 34 } },
		WeaponSpawns = { { -36, 45 }, { -20, 45 }, { 0, 45 }, { 20, 45 }, { 36, 45 } },
		Blast = { -110, -75, 110, 80 },
		Camera = { -90, -45, 90, 62 },
		Sky = { Top = Color3.fromRGB(70, 120, 210), Bottom = Color3.fromRGB(170, 220, 255) },
		Seed = 23,
	},

	AncientRuins = {
		Id = "AncientRuins",
		Name = "Ancient Ruins",
		Description = "Crumbling walls on both edges are perfect for wall jumps.",
		Platforms = {
			{ -40, -14, 40, 0, Style = "Island" },
			{ -40, 0, -32, 6, Style = "Ruin" },
			{ 32, 0, 40, 6, Style = "Ruin" },
			{ -26, 13, -12, 14, Soft = true, Style = "Wood" },
			{ 12, 13, 26, 14, Soft = true, Style = "Wood" },
			{ -7, 24, 7, 25, Soft = true, Style = "Wood" },
		},
		Spawns = { { -20, 0, 1 }, { 20, 0, -1 }, { -6, 0, 1 }, { 6, 0, -1 } },
		Respawns = { { 0, 36 }, { -16, 36 }, { 16, 36 } },
		WeaponSpawns = { { -24, 45 }, { -8, 45 }, { 8, 45 }, { 24, 45 } },
		Blast = { -105, -75, 105, 82 },
		Camera = { -85, -45, 85, 64 },
		Sky = { Top = Color3.fromRGB(120, 110, 200), Bottom = Color3.fromRGB(255, 180, 150) },
		Seed = 37,
	},

	DuelRock = {
		Id = "DuelRock",
		Name = "Duel Rock",
		Description = "A small rock for tight 1v1s.",
		Platforms = {
			{ -26, -12, 26, 0, Style = "Island" },
			{ -10, 12, 10, 13, Soft = true, Style = "Wood" },
		},
		Spawns = { { -14, 0, 1 }, { 14, 0, -1 }, { -5, 0, 1 }, { 5, 0, -1 } },
		Respawns = { { 0, 28 }, { -10, 28 }, { 10, 28 } },
		WeaponSpawns = { { -18, 40 }, { 0, 40 }, { 18, 40 } },
		Blast = { -85, -70, 85, 74 },
		Camera = { -68, -42, 68, 58 },
		Sky = { Top = Color3.fromRGB(60, 100, 180), Bottom = Color3.fromRGB(255, 200, 140) },
		Seed = 41,
	},
}

-- Maps with Blender-made kits. Their collision is these rectangles; the kits
-- are built to match them exactly (see art/blender/sky/mapkit.py).
-- stylua: ignore start
Maps.List.SkyShip = {
	Id = "SkyShip",
	Name = "Sky-Ship Deck",
	Description = "A flying galleon: a long deck, a raised quarterdeck and the rigging above.",
	Kit = "SkyShip",
	Platforms = {
		{ -40, -10, 40, 0, Style = "Wood" },
		{ 24, 0, 40, 6, Style = "Wood" },
		{ -6, 26, 6, 27, Soft = true, Style = "Wood" },
		{ -26, 14, -12, 15, Soft = true, Style = "Wood" },
		{ 10, 16, 22, 17, Soft = true, Style = "Wood" },
	},
	Spawns = { { -24, 0, 1 }, { 14, 0, -1 }, { -10, 0, 1 }, { 32, 6, -1 } },
	Respawns = { { 0, 36 }, { -18, 34 }, { 16, 34 } },
	WeaponSpawns = { { -30, 45 }, { -16, 45 }, { 0, 45 }, { 16, 45 }, { 32, 45 } },
	Blast = { -105, -75, 105, 82 },
	Camera = { -85, -45, 85, 64 },
	Sky = { Top = Color3.fromRGB(92, 158, 230), Bottom = Color3.fromRGB(255, 214, 170) },
	Seed = 51,
}

Maps.List.VolcanicForge = {
	Id = "VolcanicForge",
	Name = "Volcanic Forge",
	Description = "Two basalt ledges over the lava, an anvil in the gap and chains overhead.",
	Kit = "VolcanicForge",
	Platforms = {
		{ -42, -12, -12, 0, Style = "Ruin" },
		{ 12, -12, 42, 0, Style = "Ruin" },
		{ -8, 6, 8, 7, Soft = true, Style = "Wood" },
		{ -32, 15, -20, 16, Soft = true, Style = "Wood" },
		{ 20, 15, 32, 16, Soft = true, Style = "Wood" },
		{ -10, 26, 10, 27, Soft = true, Style = "Wood" },
	},
	Spawns = { { -30, 0, 1 }, { 30, 0, -1 }, { -18, 0, 1 }, { 18, 0, -1 } },
	Respawns = { { 0, 38 }, { -18, 36 }, { 18, 36 } },
	WeaponSpawns = { { -32, 45 }, { -18, 45 }, { 0, 45 }, { 18, 45 }, { 32, 45 } },
	Blast = { -108, -75, 108, 82 },
	Camera = { -88, -45, 88, 64 },
	Sky = { Top = Color3.fromRGB(58, 27, 46), Bottom = Color3.fromRGB(224, 102, 58) },
	GlowColor = Color3.fromRGB(255, 120, 40),
	Seed = 61,
}

Maps.List.FrozenPeaks = {
	Id = "FrozenPeaks",
	Name = "Frozen Peaks",
	Description = "A snowy summit with a rocky step, two ice shelves and a frozen arch.",
	Kit = "FrozenPeaks",
	Platforms = {
		{ -34, -14, 34, 0, Style = "Island" },
		{ -34, 0, -24, 5, Style = "Ruin" },
		{ -22, 12, -8, 13, Soft = true, Style = "Wood" },
		{ 8, 12, 22, 13, Soft = true, Style = "Wood" },
		{ -6, 22, 6, 23, Soft = true, Style = "Wood" },
	},
	Spawns = { { -29, 5, 1 }, { 20, 0, -1 }, { -12, 0, 1 }, { 8, 0, -1 } },
	Respawns = { { 0, 34 }, { -15, 34 }, { 15, 34 } },
	WeaponSpawns = { { -28, 45 }, { -15, 45 }, { 0, 45 }, { 15, 45 }, { 28, 45 } },
	Blast = { -100, -75, 100, 80 },
	Camera = { -80, -45, 80, 62 },
	Sky = { Top = Color3.fromRGB(59, 79, 154), Bottom = Color3.fromRGB(201, 216, 245) },
	GlowColor = Color3.fromRGB(150, 230, 255),
	Seed = 71,
}

Maps.List.JungleTemple = {
	Id = "JungleTemple",
	Name = "Jungle Temple",
	Description = "An overgrown temple: a stepped dais in the middle and vine bridges either side.",
	Kit = "JungleTemple",
	Platforms = {
		{ -38, -12, 38, 0, Style = "Ruin" },
		{ -12, 0, 12, 4, Style = "Ruin" },
		{ -32, 13, -18, 14, Soft = true, Style = "Wood" },
		{ 18, 13, 32, 14, Soft = true, Style = "Wood" },
		{ -8, 20, 8, 21, Soft = true, Style = "Wood" },
	},
	Spawns = { { -26, 0, 1 }, { 26, 0, -1 }, { -6, 4, 1 }, { 6, 4, -1 } },
	Respawns = { { 0, 32 }, { -20, 34 }, { 20, 34 } },
	WeaponSpawns = { { -30, 45 }, { -16, 45 }, { 0, 45 }, { 16, 45 }, { 30, 45 } },
	Blast = { -102, -75, 102, 80 },
	Camera = { -82, -45, 82, 62 },
	Sky = { Top = Color3.fromRGB(47, 143, 122), Bottom = Color3.fromRGB(242, 230, 168) },
	GlowColor = Color3.fromRGB(110, 255, 170),
	Seed = 81,
}
-- stylua: ignore end

Maps.Order = {
	"SkyShip",
	"VolcanicForge",
	"FrozenPeaks",
	"JungleTemple",
	"SkyholdKeep",
	"TwinIsles",
	"AncientRuins",
	"DuelRock",
}

function Maps.get(mapId)
	return Maps.List[mapId]
end

-- Collision world used by FighterSim. Built once per map and cached.
local worldCache = {}

function Maps.getWorld(mapId)
	local cached = worldCache[mapId]
	if cached then
		return cached
	end
	local map = Maps.List[mapId]
	assert(map, "unknown map " .. tostring(mapId))
	local platforms = {}
	for _, p in map.Platforms do
		table.insert(platforms, {
			minX = math.min(p[1], p[3]),
			minY = math.min(p[2], p[4]),
			maxX = math.max(p[1], p[3]),
			maxY = math.max(p[2], p[4]),
			soft = p.Soft == true,
		})
	end
	local world = {
		platforms = platforms,
		blast = { minX = map.Blast[1], minY = map.Blast[2], maxX = map.Blast[3], maxY = map.Blast[4] },
		camera = { minX = map.Camera[1], minY = map.Camera[2], maxX = map.Camera[3], maxY = map.Camera[4] },
	}
	worldCache[mapId] = world
	return world
end

-- Highest platform top at or below `y` that spans `x`. Returns nil over the void.
function Maps.groundBelow(world, x, y)
	local best
	for _, p in world.platforms do
		if x >= p.minX and x <= p.maxX and p.maxY <= y + 0.01 then
			if best == nil or p.maxY > best then
				best = p.maxY
			end
		end
	end
	return best
end

function Maps.isOutOfBounds(world, x, y)
	local b = world.blast
	return x < b.minX or x > b.maxX or y < b.minY or y > b.maxY
end

return Maps
