--[[
    Builds the arenas and hands out arena slots. There is no lobby: players
    sit in the menus between matches and only have a character in a match.

    Arenas are built from Maps data when a match starts and destroyed when
    it ends. Each arena slot sits far apart on the X axis so matches running
    side by side can never see each other. Slots come from two pools:
      Match     slots 1..Config.Match.MaxArenas (queues, custom rooms, bots;
                the select phase reserves one before the match exists)
      Training  the next Config.Training.MaxRooms slots, so training rooms
                never block matchmaking

    A map with a Kit uses the imported Blender kit from
    ReplicatedStorage.MapModels.<Kit> when it's there (see art/IMPORTING.md);
    otherwise its platforms are built from Parts like the classic maps. The
    server builds a gradient sky; clients draw the map's painted image
    (Config.Art.SkyImages, in layers) in front of it (client SkyBackdrop).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Maps = require(Shared.Maps)
local Markers = require(Shared.Markers)

local KIT_MARKER_DISTANCE = 10

local ArenaService = {}

local slotsInUse = {}

local COLORS = {
	Grass = Color3.fromRGB(110, 190, 90),
	GrassDark = Color3.fromRGB(80, 160, 75),
	Rock = Color3.fromRGB(120, 112, 130),
	RockDark = Color3.fromRGB(88, 80, 100),
	Ruin = Color3.fromRGB(205, 185, 150),
	RuinDark = Color3.fromRGB(160, 140, 112),
	Wood = Color3.fromRGB(150, 100, 60),
	WoodDark = Color3.fromRGB(105, 70, 45),
	Leaves = Color3.fromRGB(90, 175, 95),
	LeavesAlt = Color3.fromRGB(240, 170, 200),
	Trunk = Color3.fromRGB(110, 75, 50),
	Cloud = Color3.fromRGB(255, 255, 255),
}

-- Part helpers ------------------------------------------------------------

local function part(parent, name, size, cframe, color, material, shape)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CollisionGroup = "Arena"
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if shape then
		p.Shape = shape
	end
	p.Parent = parent
	return p
end

local function tree(parent, base, rng, scale, blossom)
	scale = scale or 1
	local trunkH = (5 + rng:NextNumber() * 3) * scale
	part(
		parent,
		"Trunk",
		Vector3.new(1.2 * scale, trunkH, 1.2 * scale),
		CFrame.new(base + Vector3.new(0, trunkH / 2, 0)),
		COLORS.Trunk,
		Enum.Material.Wood
	)
	local leafColor = blossom and COLORS.LeavesAlt or COLORS.Leaves
	for i = 1, 3 do
		local r = (3 + rng:NextNumber() * 1.6) * scale
		local offset = Vector3.new(
			rng:NextNumber(-1.6, 1.6) * scale,
			trunkH + (i - 1) * 1.4 * scale,
			rng:NextNumber(-1.2, 1.2) * scale
		)
		part(
			parent,
			"Leaves",
			Vector3.new(r * 2, r * 1.7, r * 2),
			CFrame.new(base + offset),
			leafColor:Lerp(COLORS.GrassDark, rng:NextNumber() * 0.3),
			Enum.Material.Grass,
			Enum.PartType.Ball
		)
	end
end

-- Floating rock chunk with a grassy top, used for scenery.
local function floatingIsland(parent, center, size, rng)
	part(
		parent,
		"IsleTop",
		Vector3.new(size, size * 0.18, size * 0.8),
		CFrame.new(center),
		COLORS.Grass,
		Enum.Material.Grass
	)
	local depth = size * 0.55
	part(
		parent,
		"IsleRock",
		Vector3.new(size * 0.85, depth, size * 0.7),
		CFrame.new(center - Vector3.new(0, depth / 2 + size * 0.05, 0)),
		COLORS.Rock,
		Enum.Material.Slate
	)
	part(
		parent,
		"IsleTip",
		Vector3.new(size * 0.45, size * 0.45, size * 0.45),
		CFrame.new(center - Vector3.new(0, depth + size * 0.12, 0)) * CFrame.Angles(0, 0, math.rad(45)),
		COLORS.RockDark,
		Enum.Material.Slate
	)
	if size > 10 and rng:NextNumber() < 0.6 then
		tree(
			parent,
			center + Vector3.new(rng:NextNumber(-size * 0.25, size * 0.25), size * 0.09, 0),
			rng,
			size / 18,
			rng:NextNumber() < 0.3
		)
	end
end

local function cloud(parent, center, rng, scale)
	for _ = 1, rng:NextInteger(3, 5) do
		local r = (4 + rng:NextNumber() * 5) * scale
		local p = part(
			parent,
			"Cloud",
			Vector3.new(r * 2.2, r * 1.4, r * 1.6),
			CFrame.new(
				center
					+ Vector3.new(
						rng:NextNumber(-8, 8) * scale,
						rng:NextNumber(-1.5, 1.5) * scale,
						rng:NextNumber(-2, 2)
					)
			),
			COLORS.Cloud,
			Enum.Material.SmoothPlastic,
			Enum.PartType.Ball
		)
		p.Transparency = 0.12
		p.CastShadow = false
	end
end

-- Sky gradient plane behind an arena (faces +Z, toward the camera). A map's
-- painted sky layers are drawn in front of it by each client (SkyBackdrop),
-- sized to their own camera.
local function skyBackdrop(parent, center, top, bottom)
	local backdrop = part(parent, "Sky", Vector3.new(2048, 2048, 1), CFrame.new(center), Color3.new(1, 1, 1))
	backdrop.CastShadow = false
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Back
	gui.LightInfluence = 0
	gui.MaxDistance = 100000
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 1
	gui.Parent = backdrop
	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BorderSizePixel = 0
	frame.BackgroundColor3 = Color3.new(1, 1, 1)
	frame.Parent = gui
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, top),
		ColorSequenceKeypoint.new(0.62, top:Lerp(bottom, 0.55)),
		ColorSequenceKeypoint.new(1, bottom),
	})
	gradient.Parent = frame
end

-- Imported map kits -----------------------------------------------------------

local kitTemplates = {} -- [kit] = parts | false

local function kitTemplate(kit)
	local cached = kitTemplates[kit]
	if cached ~= nil then
		return cached or nil
	end
	local folder = ReplicatedStorage:FindFirstChild("MapModels")
	local model = folder and folder:FindFirstChild(kit)
	local parts = nil
	if model then
		parts = Markers.read(model, KIT_MARKER_DISTANCE, 1)
		if #parts == 0 then
			warn("[ArenaService] MapModels." .. kit .. " has no meshes")
			parts = nil
		end
	end
	kitTemplates[kit] = parts or false
	return parts
end

function ArenaService.hasKit(mapId)
	local map = Maps.get(mapId)
	return map ~= nil and map.Kit ~= nil and kitTemplate(map.Kit) ~= nil
end

-- Places a kit at the arena origin. Pieces named "Glow..." become Neon.
local function buildKit(parent, origin, parts, glowColor)
	local base = CFrame.new(origin)
	for _, p in parts do
		local piece = Markers.cloneMesh(p.source)
		piece.Size = p.size
		piece.CFrame = base * p.cframe
		piece.Anchored = true
		piece.CanCollide = false
		piece.CanQuery = false
		piece.CanTouch = false
		piece.CollisionGroup = "Arena"
		if string.sub(p.name, 1, 4) == "Glow" then
			Markers.makeGlow(piece)
			piece.Material = Enum.Material.Neon
			piece.Color = glowColor or Color3.fromRGB(255, 220, 140)
			piece.CastShadow = false
		else
			piece.Material = Enum.Material.SmoothPlastic
		end
		piece.Parent = parent
	end
end

-- Arena maps --------------------------------------------------------------

local function buildPlatform(stage, origin, plat, rng)
	local x1, y1, x2, y2 =
		math.min(plat[1], plat[3]), math.min(plat[2], plat[4]), math.max(plat[1], plat[3]), math.max(plat[2], plat[4])
	local w, h = x2 - x1, y2 - y1
	local cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
	local function at(x, y, z)
		return CFrame.new(origin + Vector3.new(x, y, z or 0))
	end

	if plat.Soft then
		part(stage, "Plank", Vector3.new(w, h, 8), at(cx, cy), COLORS.Wood, Enum.Material.WoodPlanks)
		part(
			stage,
			"PlankTrim",
			Vector3.new(w + 0.6, 0.35, 8.6),
			at(cx, y1 + 0.17),
			COLORS.WoodDark,
			Enum.Material.Wood
		)
		for _, side in { -1, 1 } do
			local x = cx + side * (w / 2 - 1)
			part(
				stage,
				"Rope",
				Vector3.new(0.15, 40, 0.15),
				at(x, y2 + 20, -3.6),
				Color3.fromRGB(190, 160, 110),
				Enum.Material.Fabric
			)
		end
	elseif plat.Style == "Ruin" then
		part(stage, "RuinWall", Vector3.new(w, h, 12), at(cx, cy), COLORS.Ruin, Enum.Material.Brick)
		part(
			stage,
			"RuinCap",
			Vector3.new(w + 0.8, 0.8, 12.8),
			at(cx, y2 - 0.4),
			COLORS.RuinDark,
			Enum.Material.Limestone
		)
		part(stage, "RuinPillar", Vector3.new(w * 0.4, 10, 2), at(cx, y2 + 5, -6), COLORS.Ruin, Enum.Material.Brick)
	else
		local depth = 16
		part(stage, "Rock", Vector3.new(w, h, depth), at(cx, cy), COLORS.Rock, Enum.Material.Slate)
		part(
			stage,
			"Grass",
			Vector3.new(w + 0.8, 1.2, depth + 0.8),
			at(cx, y2 - 0.6),
			COLORS.Grass,
			Enum.Material.Grass
		)
		part(
			stage,
			"GrassLip",
			Vector3.new(w + 1.4, 0.5, depth + 1.4),
			at(cx, y2 - 1.3),
			COLORS.GrassDark,
			Enum.Material.Grass
		)
		-- Jagged rock hanging under the island.
		local chunks = math.max(3, math.floor(w / 9))
		for i = 1, chunks do
			local t = (i - 0.5) / chunks
			local chunkX = x1 + t * w + rng:NextNumber(-2, 2)
			local size = math.min(w / chunks * 1.4, 12) * (0.7 + rng:NextNumber() * 0.5)
			local drop = h + size * (0.2 + (1 - math.abs(t - 0.5) * 2) * 0.8)
			part(
				stage,
				"Underside",
				Vector3.new(size, size, depth * 0.7),
				at(chunkX, y2 - drop, rng:NextNumber(-2, 2)) * CFrame.Angles(0, 0, math.rad(45)),
				COLORS.RockDark,
				Enum.Material.Slate
			)
		end
		-- Scenery on top, pushed behind the fighting plane.
		if w > 28 then
			tree(stage, origin + Vector3.new(x1 + 5, y2, -6), rng, 1, rng:NextNumber() < 0.3)
			tree(stage, origin + Vector3.new(x2 - 5, y2, -5.5), rng, 0.85, rng:NextNumber() < 0.3)
		end
		for _ = 1, math.floor(w / 10) do
			local rx = rng:NextNumber(x1 + 2, x2 - 2)
			part(
				stage,
				"Stone",
				Vector3.new(1.5, 1, 1.4) * (0.6 + rng:NextNumber()),
				at(rx, y2 + 0.2, rng:NextNumber(-7, -4)) * CFrame.Angles(0, rng:NextNumber(0, 3), 0),
				COLORS.Rock,
				Enum.Material.Slate
			)
		end
	end
end

function ArenaService.buildMap(mapId, origin, slot)
	local map = Maps.get(mapId)
	assert(map, "unknown map " .. tostring(mapId))
	local rng = Random.new(map.Seed)

	local folder = Instance.new("Folder")
	folder.Name = "Arena" .. tostring(slot)
	local stage = Instance.new("Folder")
	stage.Name = "Stage"
	stage.Parent = folder
	local scenery = Instance.new("Folder")
	scenery.Name = "Scenery"
	scenery.Parent = folder
	local pickups = Instance.new("Folder")
	pickups.Name = "Pickups"
	pickups.Parent = folder
	local projectiles = Instance.new("Folder")
	projectiles.Name = "Projectiles"
	projectiles.Parent = folder

	local kit = map.Kit and kitTemplate(map.Kit)
	if kit then
		buildKit(stage, origin, kit, map.GlowColor)
	else
		for _, plat in map.Platforms do
			buildPlatform(stage, origin, plat, rng)
		end
	end

	local camera = map.Camera
	local camCenter = Vector3.new((camera[1] + camera[3]) / 2, (camera[2] + camera[4]) / 2, 0)
	skyBackdrop(
		scenery,
		origin + camCenter + Vector3.new(0, 0, -Config.Art.SkyGradientDepth),
		map.Sky.Top,
		map.Sky.Bottom
	)

	folder:SetAttribute("MapId", mapId)
	folder:SetAttribute("Origin", origin)
	folder:SetAttribute("Kit", kit ~= nil)
	if kit then
		-- The kit brings its own scenery.
		folder.Parent = workspace:FindFirstChild("Arenas")
		return folder
	end

	for _ = 1, 12 do
		local center = origin
			+ Vector3.new(rng:NextNumber(-170, 170), rng:NextNumber(-70, 80), rng:NextNumber(-150, -60))
		floatingIsland(scenery, center, rng:NextNumber(6, 22), rng)
	end
	for _ = 1, 14 do
		local center = origin
			+ Vector3.new(rng:NextNumber(-200, 200), rng:NextNumber(-60, 110), rng:NextNumber(-200, -40))
		cloud(scenery, center, rng, rng:NextNumber(0.8, 1.8))
	end

	folder:SetAttribute("MapId", mapId)
	folder:SetAttribute("Origin", origin)
	folder.Parent = workspace:FindFirstChild("Arenas")
	return folder
end

-- Slots -------------------------------------------------------------------

-- First and last slot of a pool ("Match" when nil).
local function poolRange(pool)
	if pool == "Training" then
		return Config.Match.MaxArenas + 1, Config.Match.MaxArenas + Config.Training.MaxRooms
	end
	return 1, Config.Match.MaxArenas
end

-- Reserves a free slot of the pool. Returns slot, origin (nil when the pool is full).
function ArenaService.acquire(pool)
	local first, last = poolRange(pool)
	for slot = first, last do
		if not slotsInUse[slot] then
			slotsInUse[slot] = true
			local origin = Vector3.new(slot * Config.Match.ArenaSpacing, Config.Match.ArenaHeight, 0)
			return slot, origin
		end
	end
	return nil
end

function ArenaService.release(slot)
	slotsInUse[slot] = nil
end

function ArenaService.freeSlots(pool)
	local first, last = poolRange(pool)
	local free = 0
	for slot = first, last do
		if not slotsInUse[slot] then
			free += 1
		end
	end
	return free
end

function ArenaService.init()
	if not workspace:FindFirstChild("Arenas") then
		local arenas = Instance.new("Folder")
		arenas.Name = "Arenas"
		arenas.Parent = workspace
	end
end

function ArenaService.start() end

return ArenaService
