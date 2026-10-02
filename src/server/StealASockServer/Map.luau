-- Map: builds the whole "Giant's Bedroom at night" from Parts at startup so the entire game lives
-- in git. You are sock-sized on a kid's bedroom floor: a colossal bed and nightstand tower over
-- you, the lamp is the main light, toy blocks and crayons litter the corners, the Great Dryer
-- hums at one end and the Lint Trap (a giant laundry basket) waits at the other.
-- Every piece is tagged with CollectionService so real models can replace it later.
-- Layout numbers live in Map.Layout; Base/Clothesline read them instead of hard-coding.
local CollectionService = game:GetService("CollectionService")

local MeshTemplate = require(script.Parent:WaitForChild("MeshTemplate"))

local Map = {}
local GLOW_PARTS: { [string]: Color3 } -- filled once the palette below exists
-- see-through parts from tools/blender/props (the dryer door's glass bowl)
local GLASS_PARTS: { [string]: { color: Color3, transparency: number } } = {
	DryerGlass = { color = Color3.fromRGB(190, 225, 255), transparency = 0.55 },
}
-- the dryer's galaxy layers and the ceiling fan's blades: each client spins them
-- (StealASockClient.SockFX), so no shadows/collisions
local SPIN_PARTS: { [string]: boolean } = { DryerVortex = true, DryerStars = true, FanBlades = true }
local S

local LAYOUT = {
	-- the whole bedroom, sized like a real kid's room around the bed (bed 290 long = ~2 m, so ~145
	-- studs per metre: 7.6 x 6.2 m, 2.75 m ceiling); the furniture and clutter stand round the rug
	FloorX = 1100,
	FloorZ = 900,
	RugX = 440, -- the play area: drawers, clothesline, dryer, lint trap (inside the forcefield)
	RugZ = 260,
	FieldHeight = 60, -- the forcefield round the rug keeps players off the furniture
	Tile = 20,
	WallHeight = 400, -- walls up to the ceiling (with the ceiling fan in the middle)
	LineY = 15, -- clothesline rail height
	LineStartX = -160, -- inside the dryer drum: socks slide out of it
	LineEndX = 150,
	HangDrop = 4.6, -- sock pivot (Leg centre) sits this far under the rail; socks are 2x scale
	RiseLength = 50, -- the rope leaves the centre of the dryer's void and eases down to LineY over this
	DryerX = -172,
	LintX = 174,
	BaseXs = { -126, -42, 42, 126 },
	BaseZ = 83, -- bases at +BaseZ (south) and -BaseZ (north), facing the line (front edge 62 from it)
	BaseW = 46, -- drawer footprint (x)
	BaseD = 42, -- drawer footprint (z): deep enough for three rows of slots
	WallH = 9, -- drawer wall height (taller than a jump)
	SlotCols = 4,
	SlotSpacingX = 11,
	-- slot rows (base-local z, +Z = the front): rows 1-2 hold the BaseSlots, row 3 at the back is the
	-- padlocked row the +4 Drawer Slots pass unlocks (StoreConfig.ExtraSlots)
	SlotRowZ = { -3, 7, -13 },
	SlotSize = 5,
	FrontApron = 10, -- claim zone extends this far out the front of the drawer
	SpawnZ = 30,
}
Map.Layout = LAYOUT
Map.Root = nil :: Folder?
Map.Folders = {} :: { [string]: Folder }
Map.Dryer = {} :: { [string]: BasePart }
-- studs the rope rises at the dryer end so it starts in the centre of the void (set by buildClothesline)
local lineRise = 0

-- extra height of the rope `t` studs along the line: lineRise at the dryer, easing to 0 at RiseLength
local function riseAt(t: number): number
	local u = math.clamp(t / LAYOUT.RiseLength, 0, 1)
	return lineRise * (1 + math.cos(math.pi * u)) / 2
end
Map.Bases = {} :: { Model }

-- Palette sampled from docs/concept/bedroom_keyframe.png. Flat colours on SmoothPlastic: the
-- concept has no surface texture, so Wood/Fabric materials (which add realistic grain) are out.
local C = {
	Plank1 = Color3.fromRGB(176, 118, 68),
	Plank2 = Color3.fromRGB(190, 130, 78),
	RugA = Color3.fromRGB(245, 231, 206),
	RugB = Color3.fromRGB(227, 154, 136),
	RugEdge = Color3.fromRGB(150, 84, 70),
	Wall = Color3.fromRGB(82, 68, 130),
	WallStripe = Color3.fromRGB(72, 58, 116),
	Baseboard = Color3.fromRGB(120, 92, 60),
	Wood = Color3.fromRGB(183, 122, 69),
	WoodDark = Color3.fromRGB(138, 90, 48),
	Felt = Color3.fromRGB(84, 112, 186), -- blue drawer lining, as in the concept
	Knob = Color3.fromRGB(240, 200, 90),
	Mattress = Color3.fromRGB(248, 246, 240),
	Blanket = Color3.fromRGB(92, 127, 200),
	BlanketStripe = Color3.fromRGB(214, 79, 79),
	Pillow = Color3.fromRGB(255, 255, 255),
	Lamp = Color3.fromRGB(255, 229, 138),
	Moon = Color3.fromRGB(190, 210, 255),
	MoonGlow = Color3.fromRGB(247, 237, 207),
	Metal = Color3.fromRGB(233, 238, 245),
	MetalDark = Color3.fromRGB(70, 90, 130),
	Swirl = Color3.fromRGB(123, 63, 224),
	Ceiling = Color3.fromRGB(58, 50, 104), -- the ceiling at night, a shade darker than the walls
	FanLight = Color3.fromRGB(255, 236, 200),
	Lint = Color3.fromRGB(190, 187, 204), -- matches the Blender basket's lavender-white lint
	Basket = Color3.fromRGB(200, 160, 100),
	DryerBlue = Color3.fromRGB(109, 165, 227),
	LockGold = Color3.fromRGB(255, 196, 64), -- the back row's padlocks (the UI kit's gold candy)
	LockShine = Color3.fromRGB(255, 228, 140),
	LockSteel = Color3.fromRGB(196, 200, 214),
	LockInk = Color3.fromRGB(46, 28, 40),
}

local function part(name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, parent: Instance, tag: string?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	if tag then
		CollectionService:AddTag(p, tag)
	end
	return p
end

local function ball(name: string, diameter: number, cf: CFrame, color: Color3, material: Enum.Material?, parent: Instance, tag: string?): Part
	local p = part(name, Vector3.new(diameter, diameter, diameter), cf, color, material, parent, tag)
	p.Shape = Enum.PartType.Ball
	return p
end

-- vertical cylinder (Part cylinders lie along X, so we rotate)
local function column(name: string, radius: number, height: number, cf: CFrame, color: Color3, material: Enum.Material?, parent: Instance, tag: string?): Part
	local p = part(name, Vector3.new(height, radius * 2, radius * 2), cf * CFrame.Angles(0, 0, math.pi / 2), color, material, parent, tag)
	p.Shape = Enum.PartType.Cylinder
	return p
end

local function label(adornee: BasePart, text: string, size: number, offsetY: number, color: Color3?): TextLabel
	local gui = Instance.new("BillboardGui")
	gui.Name = "Label"
	gui.Adornee = adornee
	gui.Size = UDim2.fromOffset(260, 60)
	gui.StudsOffset = Vector3.new(0, offsetY, 0)
	gui.MaxDistance = 160
	gui.LightInfluence = 0
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.Font = Enum.Font.FredokaOne
	t.TextScaled = true
	t.TextColor3 = color or Color3.new(1, 1, 1)
	t.TextStrokeTransparency = 0.2
	t.Text = text
	t.Parent = gui
	local sizer = Instance.new("UITextSizeConstraint")
	sizer.MaxTextSize = size
	sizer.Parent = t
	gui.Parent = adornee
	return t
end
Map.Label = label

-- ---------- real meshes (optional) ----------
-- Put a Model/MeshPart into ReplicatedStorage.MapMeshes named Bed, Nightstand, Lamp, Dryer, Duck,
-- Teddy, Basket, Blocks, Crayons, Drawer (one is enough - it is cloned per base), Window, Picture or
-- Bookshelf (the last two exist only as meshes) and the builder
-- below uses it instead of the Part version: it is scaled to fit the slot's size and its bottom is
-- set on the floor point. See docs/ART_PIPELINE.md.
local meshFolder: Folder? = nil

local function ensureMeshFolder(): Folder
	local rs = game:GetService("ReplicatedStorage")
	local f = rs:FindFirstChild("MapMeshes")
	if not f then
		f = Instance.new("Folder")
		f.Name = "MapMeshes"
		f.Parent = rs
	end
	return f :: Folder
end

-- `floorCF` = where the bottom-centre of the piece goes (y = floor level); `fit` = max size.
-- `alignBack` = put the piece's back (its -Z side) on floorCF instead of its centre: for wall decor
-- and furniture that stands against a wall (floorCF on the wall, its +Z pointing into the room).
-- Returns the placed Model, or nil when there is no template of that name.
local function placeTemplate(name: string, floorCF: CFrame, fit: Vector3, parent: Instance, tag: string?, alignBack: boolean?): Model?
	local template = meshFolder and meshFolder:FindFirstChild(name)
	if not template then
		return nil
	end
	-- turns Blender templates so their front faces +Z, hides markers, outlines cast no shadow
	local model = MeshTemplate.Prepare(template, false)
	if not model then
		return nil
	end
	local lo, hi = MeshTemplate.SolidBounds(model)
	if not (lo and hi) then
		model:Destroy()
		return nil
	end
	local size = hi - lo
	if size.X <= 0 or size.Y <= 0 or size.Z <= 0 then
		model:Destroy()
		return nil
	end
	local scale = math.min(fit.X / size.X, fit.Y / size.Y, fit.Z / size.Z)
	model:ScaleTo(model:GetScale() * scale)
	-- Style pass on whatever came from the Creator Store / a generator: flat toy materials only,
	-- no glowing slabs (a Neon lampshade becomes a blob under bloom), no leftover lights/sounds/scripts.
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			local mat = d.Material
			if mat == Enum.Material.Neon then
				local biggest = math.max(d.Size.X, d.Size.Y, d.Size.Z)
				if biggest > 6 then
					d.Material = Enum.Material.SmoothPlastic
				end
			elseif mat ~= Enum.Material.Glass and mat ~= Enum.Material.ForceField then
				d.Material = Enum.Material.SmoothPlastic
			end
			d.Reflectance = 0
		elseif d:IsA("Light") or d:IsA("Sound") or d:IsA("Script") or d:IsA("LocalScript") or d:IsA("ModuleScript") or d:IsA("ClickDetector") or d:IsA("ProximityPrompt") then
			d:Destroy()
		end
	end
	-- glow and glass parts from tools/blender/props: the lamp globe, the dryer's galaxy portal and
	-- door glass, the window's moon, the ceiling's star stickers
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and GLOW_PARTS[d.Name] then
			d.Material = Enum.Material.Neon
			d.Color = GLOW_PARTS[d.Name]
			d.CastShadow = false
		elseif d:IsA("BasePart") and GLASS_PARTS[d.Name] then
			local glass = GLASS_PARTS[d.Name]
			d.Material = Enum.Material.Glass
			d.Color = glass.color
			d.Transparency = glass.transparency
			d.CastShadow = false
			d.CanCollide = false
		elseif d:IsA("BasePart") and SPIN_PARTS[d.Name] then
			d.CastShadow = false
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		end
	end
	-- the point that lands on floorCF: the bottom of the visible parts, centred on the _Base marker
	-- when there is one (the modeller's floor centre - e.g. the dryer's body, not its open door),
	-- else on the bounds; with alignBack, the back (-Z side) instead of the centre
	lo, hi = MeshTemplate.SolidBounds(model)
	local mn, mx = lo :: Vector3, hi :: Vector3
	local base = MeshTemplate.MarkerPosition(model, "_Base")
	local anchor = Vector3.new(
		if base then base.X else (mn.X + mx.X) / 2,
		mn.Y,
		if alignBack then mn.Z elseif base then base.Z else (mn.Z + mx.Z) / 2
	)
	local bottomOffset = anchor - model:GetPivot().Position
	model:PivotTo(floorCF * CFrame.new(-bottomOffset.X, -bottomOffset.Y, -bottomOffset.Z))
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
		end
	end
	model.Name = name
	if tag then
		CollectionService:AddTag(model, tag)
	end
	model.Parent = parent
	return model
end
Map.PlaceTemplate = placeTemplate

-- decorative mesh pieces never block players, catch touches or eat prompt/mouse queries
local function decor(model: Instance)
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		end
	end
end

GLOW_PARTS = {
	LampGlow = C.Lamp,
	DryerPortal = Color3.fromRGB(150, 90, 255),
	MoonGlow = C.MoonGlow,
	FanLight = C.FanLight,
	CeilingStars = Color3.fromRGB(200, 255, 170), -- the RoomShell's glow-in-the-dark star stickers
}

local function pointLight(parent: BasePart, color: Color3, range: number, brightness: number, shadows: boolean?): PointLight
	local l = Instance.new("PointLight")
	l.Color = color
	l.Range = range
	l.Brightness = brightness
	l.Shadows = shadows == true
	l.Parent = parent
	return l
end

-- The Great Dryer's galaxy breathing out into the room: twinkling sparkles, fast bright motes and
-- soft purple wisps, all leaving `mouth`'s Front face. `unit` = studs per model unit (~10), so the
-- particles keep their size if the dryer's fit changes. SockFX also bursts VoidSparkles whenever a
-- sock pops out onto the line.
local function voidParticles(mouth: BasePart, unit: number)
	local k = unit / 10
	local function emitter(name: string): ParticleEmitter
		local e = Instance.new("ParticleEmitter")
		e.Name = name
		e.EmissionDirection = Enum.NormalId.Front
		e.LightInfluence = 0
		e.ZOffset = 0.5
		e.Rotation = NumberRange.new(0, 360)
		e.Parent = mouth
		return e
	end
	local sparkles = emitter("VoidSparkles")
	sparkles.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	sparkles.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
		ColorSequenceKeypoint.new(0.4, Color3.fromRGB(225, 175, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 90, 255)),
	})
	sparkles.LightEmission = 1
	sparkles.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5 * k), NumberSequenceKeypoint.new(0.25, 1.4 * k), NumberSequenceKeypoint.new(1, 0) })
	sparkles.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(0.75, 0.25), NumberSequenceKeypoint.new(1, 1) })
	sparkles.Rate = 22
	sparkles.Lifetime = NumberRange.new(1.8, 3.2)
	sparkles.Speed = NumberRange.new(6 * k, 12 * k)
	sparkles.SpreadAngle = Vector2.new(35, 35)
	sparkles.Drag = 0.9
	sparkles.Acceleration = Vector3.new(0, 1.5 * k, 0)
	sparkles.RotSpeed = NumberRange.new(-200, 200)

	local motes = emitter("VoidMotes")
	motes.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	motes.Color = ColorSequence.new(Color3.fromRGB(255, 240, 255), Color3.fromRGB(255, 140, 230))
	motes.LightEmission = 1
	motes.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4 * k), NumberSequenceKeypoint.new(1, 0) })
	motes.Rate = 30
	motes.Lifetime = NumberRange.new(1, 1.8)
	motes.Speed = NumberRange.new(10 * k, 16 * k)
	motes.SpreadAngle = Vector2.new(20, 20)

	local wisps = emitter("VoidWisps")
	wisps.Texture = "rbxasset://textures/particles/smoke_main.dds"
	wisps.Color = ColorSequence.new(Color3.fromRGB(185, 125, 255), Color3.fromRGB(100, 50, 210))
	wisps.LightEmission = 0.6
	wisps.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 3 * k), NumberSequenceKeypoint.new(1, 7 * k) })
	wisps.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(0.6, 0.65), NumberSequenceKeypoint.new(1, 1) })
	wisps.Rate = 4
	wisps.Lifetime = NumberRange.new(2.5, 4)
	wisps.Speed = NumberRange.new(3 * k, 6 * k)
	wisps.SpreadAngle = Vector2.new(15, 15)
	wisps.Drag = 0.4
	wisps.Acceleration = Vector3.new(0, 0.8 * k, 0)
	wisps.RotSpeed = NumberRange.new(-30, 30)
end

-- ---------- floor, rug, walls ----------

-- The textured room (mesh only, tools/blender/props/roomshell.py): plank floor, starry wallpaper,
-- cream baseboard and crown molding, plaster ceiling, the knitted play rug and glow-in-the-dark
-- ceiling stars. It is built at 1 stud per unit, so its fit box is the room itself (scale 1). Only
-- its walls cast shadows, like the wall Parts it covers; the ceiling and the stars never do.
local SHELL_SHADOWS: { [string]: boolean } = { RoomWalls = true }

local function buildShell(folder: Folder): Model?
	local L = LAYOUT
	local shell = placeTemplate("RoomShell", CFrame.new(0, 0, 0), Vector3.new(L.FloorX, L.WallHeight, L.FloorZ), folder, "MapFloor")
	if not shell then
		return nil
	end
	decor(shell)
	for _, d in ipairs(shell:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CastShadow = SHELL_SHADOWS[d.Name] == true
		end
	end
	local stars = shell:FindFirstChild("CeilingStars", true)
	if stars and stars:IsA("BasePart") then
		stars.Transparency = 0.15 -- Neon from GLOW_PARTS, a little softer
	end
	return shell
end

local function buildFloor(folder: Folder)
	local L = LAYOUT
	-- with the RoomShell in place the Parts below are only there for collision (planks, walls,
	-- ceiling) and turn invisible; without it they are the room's look
	local shell = buildShell(folder)
	local function hide(p: BasePart)
		if shell then
			p.Transparency = 1
			p.CastShadow = false
		end
	end
	local planks = Instance.new("Folder")
	planks.Name = "Planks"
	planks.Parent = folder
	local plankW = 40
	local nx = L.FloorX / plankW
	for ix = 0, nx - 1 do
		local x = -L.FloorX / 2 + plankW / 2 + ix * plankW
		hide(part("Plank", Vector3.new(plankW - 0.4, 1, L.FloorZ), CFrame.new(x, -0.5, 0), if ix % 2 == 0 then C.Plank1 else C.Plank2, Enum.Material.SmoothPlastic, planks, "MapFloor"))
	end
	-- checkered rug over the play area (spec: checkered floor) with a dark border
	local rug = Instance.new("Folder")
	rug.Name = "Rug"
	rug.Parent = folder
	local edge = part("RugEdge", Vector3.new(L.RugX + 8, 0.3, L.RugZ + 8), CFrame.new(0, 0.05, 0), C.RugEdge, Enum.Material.SmoothPlastic, rug, "MapFloor")
	edge.CanCollide = false
	hide(edge)
	local cx, cz = L.RugX / L.Tile, L.RugZ / L.Tile
	for ix = 0, cx - 1 do
		for iz = 0, cz - 1 do
			local x = -L.RugX / 2 + L.Tile / 2 + ix * L.Tile
			local z = -L.RugZ / 2 + L.Tile / 2 + iz * L.Tile
			local t = part("Tile", Vector3.new(L.Tile, 0.4, L.Tile), CFrame.new(x, 0.2, z), if (ix + iz) % 2 == 0 then C.RugA else C.RugB, Enum.Material.SmoothPlastic, rug, "MapFloor")
			t.CanCollide = false
			hide(t)
		end
	end
	-- walls with wallpaper stripes, a baseboard, a ceiling and crown molding
	local walls = Instance.new("Folder")
	walls.Name = "Walls"
	walls.Parent = folder
	local h = L.WallHeight
	local function wall(name: string, size: Vector3, cf: CFrame, along: string)
		hide(part(name, size, cf, C.Wall, Enum.Material.SmoothPlastic, walls, "MapWall"))
		local length = if along == "x" then size.X else size.Z
		for i = 0, length / 80 - 1 do
			local offset = -length / 2 + 40 + i * 80
			local scf = if along == "x" then cf * CFrame.new(offset, 0, 0) else cf * CFrame.new(0, 0, offset)
			local ssize = if along == "x" then Vector3.new(28, h, size.Z + 0.2) else Vector3.new(size.X + 0.2, h, 28)
			local stripe = part("Stripe", ssize, scf, C.WallStripe, Enum.Material.SmoothPlastic, walls, "MapWall")
			stripe.CanCollide = false
			hide(stripe)
		end
		local bh = 14 -- a real ~10 cm baseboard at this scale
		local bsize = if along == "x" then Vector3.new(size.X, bh, size.Z + 3) else Vector3.new(size.X + 3, bh, size.Z)
		hide(part("Baseboard", bsize, cf * CFrame.new(0, -h / 2 + bh / 2, 0), C.Baseboard, Enum.Material.SmoothPlastic, walls, "MapWall"))
		local msize = if along == "x" then Vector3.new(size.X, 10, size.Z + 6) else Vector3.new(size.X + 6, 10, size.Z)
		local molding = part("CrownMolding", msize, cf * CFrame.new(0, h / 2 - 5, 0), C.Baseboard, Enum.Material.SmoothPlastic, walls, "MapWall")
		molding.CastShadow = false
		hide(molding)
	end
	wall("WallNorth", Vector3.new(L.FloorX + 4, h, 3), CFrame.new(0, h / 2, -L.FloorZ / 2 - 1.5), "x")
	wall("WallSouth", Vector3.new(L.FloorX + 4, h, 3), CFrame.new(0, h / 2, L.FloorZ / 2 + 1.5), "x")
	wall("WallWest", Vector3.new(3, h, L.FloorZ), CFrame.new(-L.FloorX / 2 - 1.5, h / 2, 0), "z")
	wall("WallEast", Vector3.new(3, h, L.FloorZ), CFrame.new(L.FloorX / 2 + 1.5, h / 2, 0), "z")
	-- the ceiling: no shadow, so the moonlight from the window still lights the room
	local ceiling = part("Ceiling", Vector3.new(L.FloorX + 6, 2, L.FloorZ + 6), CFrame.new(0, h + 1, 0), C.Ceiling, Enum.Material.SmoothPlastic, walls, "MapWall")
	ceiling.CastShadow = false
	hide(ceiling)
end

-- The ceiling fan hangs in the middle of the ceiling; its FanBlades spin on every client (SockFX)
-- and its FanLight glows. Mesh only.
local function buildCeilingFan(folder: Folder)
	local fan = placeTemplate("CeilingFan", CFrame.new(0, 0, 0), Vector3.new(220, 110, 220), folder, "Furniture")
	if not fan then
		return
	end
	local _, hi = MeshTemplate.SolidBounds(fan)
	if hi then
		fan:PivotTo(fan:GetPivot() + Vector3.new(0, LAYOUT.WallHeight - hi.Y, 0)) -- canopy against the ceiling
	end
	decor(fan)
	local glow = fan:FindFirstChild("FanLight", true)
	if glow and glow:IsA("BasePart") then
		pointLight(glow, C.FanLight, 60, 0.8)
	end
end

-- ---------- furniture ----------

local function buildBed(folder: Folder)
	local L = LAYOUT
	local z0 = -L.FloorZ / 2 -- north wall
	-- long side against the north wall, outside the forcefield (its front stops at the rug edge)
	local depth, width = 130, 270
	local zc = z0 + depth / 2 + 6
	if placeTemplate("Bed", CFrame.new(0, 0, z0 + 72), Vector3.new(290, 110, 140), folder, "Furniture") then
		return
	end
	local frameH = 26
	part("BedFrame", Vector3.new(width, frameH, depth), CFrame.new(0, frameH / 2, zc), C.WoodDark, Enum.Material.SmoothPlastic, folder, "Furniture")
	for _, x in ipairs({ -width / 2 + 6, width / 2 - 6 }) do
		for _, z in ipairs({ zc - depth / 2 + 6, zc + depth / 2 - 6 }) do
			local postH = if z < zc then 82 else 58
			column("BedPost", 6, postH, CFrame.new(x, postH / 2, z), C.Wood, Enum.Material.SmoothPlastic, folder, "Furniture")
			ball("BedFinial", 16, CFrame.new(x, postH + 6, z), C.Wood, Enum.Material.SmoothPlastic, folder, "Furniture")
		end
	end
	local mattressH = 18
	part("Mattress", Vector3.new(width - 8, mattressH, depth - 6), CFrame.new(0, frameH + mattressH / 2, zc), C.Mattress, Enum.Material.SmoothPlastic, folder, "Furniture")
	local blanketTop = frameH + mattressH
	local blanket = part("Blanket", Vector3.new(width - 16, 5, depth - 30), CFrame.new(0, blanketTop + 2.5, zc + 12), C.Blanket, Enum.Material.SmoothPlastic, folder, "Furniture")
	for i = 0, 5 do
		part("BlanketStripe", Vector3.new(12, 5.2, depth - 30), blanket.CFrame * CFrame.new(-width / 2 + 30 + i * 44, 0, 0), C.BlanketStripe, Enum.Material.SmoothPlastic, folder, "Furniture")
	end
	-- blanket hanging off the front edge (the part players see)
	part("BlanketDrape", Vector3.new(width - 16, 22, 4), CFrame.new(0, blanketTop - 6, zc + depth / 2 - 1), C.Blanket, Enum.Material.SmoothPlastic, folder, "Furniture")
	for _, x in ipairs({ -60, 60 }) do
		local pillow = part("Pillow", Vector3.new(70, 12, 30), CFrame.new(x, blanketTop + 6, zc - depth / 2 + 24), C.Pillow, Enum.Material.SmoothPlastic, folder, "Furniture")
		pillow.CFrame = pillow.CFrame * CFrame.Angles(0, 0, if x < 0 then 0.06 else -0.06)
	end
	part("Headboard", Vector3.new(width - 20, 60, 6), CFrame.new(0, 30, z0 + 4), C.Wood, Enum.Material.SmoothPlastic, folder, "Furniture")
	for i = 0, 4 do
		column("HeadboardSlat", 3, 40, CFrame.new(-width / 2 + 40 + i * (width - 80) / 4, 60, z0 + 4), C.WoodDark, Enum.Material.SmoothPlastic, folder, "Furniture")
	end
end

-- Round moon window above the bed, like the concept: a porthole with a crescent moon.
local function buildWindow(folder: Folder)
	local z0 = -LAYOUT.FloorZ / 2 -- north wall
	local wx, wy = 0, 230 -- centred over the bed, a real ~1 m round window
	-- curtains framing it (mesh only): rod above, drapes down to just over the bed
	placeTemplate("Curtains", CFrame.new(wx, 115, z0), Vector3.new(320, 240, 24), folder, "Furniture", true)
	local mesh = placeTemplate("Window", CFrame.new(wx, wy - 70, z0), Vector3.new(140, 140, 24), folder, "Furniture", true)
	if mesh then
		local moon = mesh:FindFirstChild("MoonGlow", true)
		local anchor = if moon and moon:IsA("BasePart") then moon else mesh:FindFirstChildWhichIsA("BasePart", true)
		if anchor then
			pointLight(anchor, C.Moon, 240, 1.0)
		end
		return
	end
	local ring = part("WindowRing", Vector3.new(2, 64, 64), CFrame.new(wx, wy, z0 + 2.2) * CFrame.Angles(0, math.pi / 2, 0), C.WoodDark, Enum.Material.SmoothPlastic, folder, "Furniture")
	ring.Shape = Enum.PartType.Cylinder
	local win = part("Window", Vector3.new(1.4, 56, 56), CFrame.new(wx, wy, z0 + 2.6) * CFrame.Angles(0, math.pi / 2, 0), Color3.fromRGB(46, 58, 120), Enum.Material.Neon, folder, "Furniture")
	win.Shape = Enum.PartType.Cylinder
	win.Transparency = 0.1
	pointLight(win, C.Moon, 240, 1.0)
	local moon = ball("Moon", 30, CFrame.new(wx + 2, wy + 2, z0 + 3.4), Color3.fromRGB(240, 242, 255), Enum.Material.Neon, folder, "Furniture")
	moon.Transparency = 0.05
	moon.CanCollide = false
	local bite = ball("MoonBite", 26, CFrame.new(wx + 12, wy + 8, z0 + 3.2), Color3.fromRGB(46, 58, 120), Enum.Material.Neon, folder, "Furniture")
	bite.CanCollide = false
end

local function buildNightstand(folder: Folder)
	local L = LAYOUT
	-- beside the bed's head end (the bed spans x -145..145), back against the north wall
	local x, z = -192, -L.FloorZ / 2 + 38
	local h = 92
	-- concept proportions: the nightstand's top is about level with the mattress, and the lamp
	-- globe is about 0.6 of the nightstand's width
	local stand = placeTemplate("Nightstand", CFrame.new(x, 0, z), Vector3.new(72, 80, 72), folder, "Furniture")
	if stand then
		local _, standHi = MeshTemplate.SolidBounds(stand)
		local standTop = if standHi then standHi.Y else 80
		local lampTop = standTop + 50
		-- lamp toward the back-left, the alarm clock front-right turned a little toward the room
		local lamp = placeTemplate("Lamp", CFrame.new(x - 12, standTop, z - 6), Vector3.new(46, 56, 46), folder, "Furniture")
		local clock = placeTemplate("AlarmClock", CFrame.new(x + 21, standTop, z + 15) * CFrame.Angles(0, 0.35, 0), Vector3.new(22, 25, 14), folder, "Furniture")
		if clock then
			decor(clock)
		end
		x -= 12 -- the bulb and its light sit in the lamp
		z -= 6
		local lampLo, lampHi
		if lamp then
			lampLo, lampHi = MeshTemplate.SolidBounds(lamp)
		end
		local bulbY = if lampLo and lampHi then standTop + (lampHi.Y - lampLo.Y) * 0.6 else lampTop
		local bulb = ball("LampBulb", 6, CFrame.new(x, bulbY, z), Color3.fromRGB(255, 240, 200), Enum.Material.Neon, folder, "Furniture")
		bulb.Transparency = if lamp then 1 else 0
		bulb.CanCollide = false
		local spot = Instance.new("SpotLight")
		spot.Color = C.Lamp
		spot.Range = 420
		spot.Angle = 150
		spot.Brightness = 1.0
		spot.Face = Enum.NormalId.Bottom
		spot.Shadows = true
		spot.Parent = bulb
		pointLight(bulb, C.Lamp, 260, 0.6)
		local fill = part("RoomFill", Vector3.new(1, 1, 1), CFrame.new(0, 70, 0), C.Lamp, Enum.Material.SmoothPlastic, folder, "Furniture")
		fill.Transparency = 1
		fill.CanCollide = false
		fill.CanQuery = false
		pointLight(fill, Color3.fromRGB(255, 236, 214), 320, 0.55)
		return
	end
	part("Nightstand", Vector3.new(76, h, 70), CFrame.new(x, h / 2, z), C.Wood, Enum.Material.SmoothPlastic, folder, "Furniture")
	part("NightstandTop", Vector3.new(82, 5, 76), CFrame.new(x, h + 2.5, z), C.WoodDark, Enum.Material.SmoothPlastic, folder, "Furniture")
	part("NightstandDrawer", Vector3.new(60, 24, 2), CFrame.new(x, 58, z + 36), C.WoodDark, Enum.Material.SmoothPlastic, folder, "Furniture")
	part("NightstandKnob", Vector3.new(8, 8, 3), CFrame.new(x, 58, z + 38), C.Knob, Enum.Material.Metal, folder, "Furniture")
	-- lamp: base, stem, shade, and the main light of the room
	column("LampBase", 12, 4, CFrame.new(x, h + 7, z), C.MetalDark, Enum.Material.Metal, folder, "Furniture")
	column("LampStem", 2, 40, CFrame.new(x, h + 29, z), C.Metal, Enum.Material.Metal, folder, "Furniture")
	local shade = column("LampShade", 24, 28, CFrame.new(x, h + 60, z), C.Lamp, Enum.Material.SmoothPlastic, folder, "Furniture")
	shade.Transparency = 0.1
	local bulb = ball("LampBulb", 12, CFrame.new(x, h + 60, z), Color3.fromRGB(255, 240, 200), Enum.Material.Neon, folder, "Furniture")
	local spot = Instance.new("SpotLight")
	spot.Color = C.Lamp
	spot.Range = 420
	spot.Angle = 150
	spot.Brightness = 1.4
	spot.Face = Enum.NormalId.Bottom
	spot.Shadows = true
	spot.Parent = bulb
	pointLight(bulb, C.Lamp, 260, 0.8)
	-- soft warm fill over the play area so the socks and drawers always read
	local fill = part("RoomFill", Vector3.new(1, 1, 1), CFrame.new(0, 70, 0), C.Lamp, Enum.Material.SmoothPlastic, folder, "Furniture")
	fill.Transparency = 1
	fill.CanCollide = false
	fill.CanQuery = false
	pointLight(fill, Color3.fromRGB(255, 236, 214), 320, 0.55)
end

-- Wall decor and clutter round the room (mesh only - the Part map does without): everything here
-- stands outside the forcefield, between the rug and the walls. `face` turns the piece's front
-- (+Z) toward the room; wall pieces put their back on the wall (alignBack).
local CLUTTER = {
	-- north wall (the bed, nightstand, window and curtains are built above)
	{ name = "ToyChest", at = Vector3.new(320, 0, -395), face = 0, fit = Vector3.new(116, 78, 72) },
	{ name = "PottedPlant", at = Vector3.new(495, 0, -400), face = -0.4, fit = Vector3.new(90, 170, 90) },
	{ name = "PosterRocket", at = Vector3.new(-345, 140, -450), face = 0, fit = Vector3.new(90, 130, 4), wall = true },
	-- west wall: wardrobe, desk + chair with a picture above, a pennant
	{ name = "Wardrobe", at = Vector3.new(-550, 0, -250), face = math.pi / 2, fit = Vector3.new(180, 300, 95), wall = true },
	{ name = "Pennant", at = Vector3.new(-550, 250, -40), face = math.pi / 2, fit = Vector3.new(120, 50, 6), wall = true },
	{ name = "Desk", at = Vector3.new(-550, 0, 170), face = math.pi / 2, fit = Vector3.new(200, 115, 100), wall = true },
	{ name = "DeskChair", at = Vector3.new(-418, 0, 195), face = -math.pi / 2, fit = Vector3.new(80, 140, 80) },
	{ name = "Picture", at = Vector3.new(-550, 175, 170), face = math.pi / 2, fit = Vector3.new(110, 82, 10), wall = true },
	{ name = "TrashCan", at = Vector3.new(-490, 0, 305), face = 0.6, fit = Vector3.new(50, 64, 50) },
	{ name = "BookStack", at = Vector3.new(-360, 0, -120), face = 0.9, fit = Vector3.new(40, 42, 32) },
	-- east wall: low bookshelf with a poster above, bean bag, hamper
	{ name = "Bookshelf", at = Vector3.new(550, 0, -150), face = -math.pi / 2, fit = Vector3.new(150, 125, 56), wall = true },
	{ name = "PosterDino", at = Vector3.new(550, 170, -150), face = -math.pi / 2, fit = Vector3.new(130, 90, 4), wall = true },
	{ name = "BeanBag", at = Vector3.new(430, 0, 40), face = -math.pi / 2 - 0.4, fit = Vector3.new(120, 80, 110) },
	{ name = "BeachBall", at = Vector3.new(330, 0, 150), face = 0.4, fit = Vector3.new(58, 55, 58) },
	{ name = "Hamper", at = Vector3.new(480, 0, 300), face = -math.pi / 2 - 0.6, fit = Vector3.new(90, 110, 90) },
	-- south wall: door, dresser; slippers by the door, the toy car on the floor
	{ name = "Door", at = Vector3.new(-300, 0, 450), face = math.pi, fit = Vector3.new(140, 300, 16), wall = true },
	{ name = "Dresser", at = Vector3.new(180, 0, 450), face = math.pi, fit = Vector3.new(175, 150, 82), wall = true },
	{ name = "Slippers", at = Vector3.new(-190, 0, 330), face = math.pi + 0.3, fit = Vector3.new(60, 20, 50) },
	{ name = "ToyCar", at = Vector3.new(0, 0, 280), face = 2.6, fit = Vector3.new(44, 32, 70) }, -- nose = front, so its length is Z
}

local function buildDecor(folder: Folder)
	for _, c in ipairs(CLUTTER) do
		placeTemplate(c.name, CFrame.new(c.at) * CFrame.Angles(0, c.face, 0), c.fit, folder, "Furniture", c.wall)
	end
end

-- The forcefield round the play area: four invisible walls along the rug's edge. Players can't
-- climb out onto the bed, the nightstand or the clutter; nothing gameplay-related is outside it.
-- Each client shows a soft shimmer on the wall only where the player walks up to it (SockFX).
local function buildBoundary(folder: Folder)
	local L = LAYOUT
	local hx, hz, h = L.RugX / 2 + 6, L.RugZ / 2 + 6, L.FieldHeight
	local field = Instance.new("Folder")
	field.Name = "Forcefield"
	field.Parent = folder
	local sides = {
		{ Vector3.new(hx * 2 + 1, h, 1), Vector3.new(0, h / 2, -hz) },
		{ Vector3.new(hx * 2 + 1, h, 1), Vector3.new(0, h / 2, hz) },
		{ Vector3.new(1, h, hz * 2 + 1), Vector3.new(-hx, h / 2, 0) },
		{ Vector3.new(1, h, hz * 2 + 1), Vector3.new(hx, h / 2, 0) },
	}
	for _, sd in ipairs(sides) do
		local wall = part("Field", sd[1], CFrame.new(sd[2]), Color3.fromRGB(170, 130, 255), Enum.Material.ForceField, field, "Boundary")
		wall.Transparency = 1
		wall.CastShadow = false
		wall.CanQuery = false -- the camera and prompts look straight through it
		wall.CanTouch = false
	end
end

local function buildToys(folder: Folder)
	local L = LAYOUT
	local half = L.FloorX / 2 -- the Part fallbacks below use it
	-- letter blocks
	local blocks = {
		{ x = -half + 60, z = 130, s = 24, letter = "S", color = Color3.fromRGB(230, 80, 90), rot = 0.2 },
		{ x = -half + 84, z = 118, s = 20, letter = "O", color = Color3.fromRGB(90, 160, 240), rot = -0.4 },
		{ x = -half + 66, z = 130, s = 18, letter = "C", color = Color3.fromRGB(250, 200, 70), rot = 0.1, stack = 24 },
		{ x = half - 70, z = -120, s = 26, letter = "K", color = Color3.fromRGB(110, 200, 120), rot = 0.5 },
		{ x = half - 60, z = 140, s = 22, letter = "!", color = Color3.fromRGB(200, 110, 230), rot = -0.2 },
	}
	-- the toys are scattered round the rug, outside the forcefield
	local blocksModel = placeTemplate("Blocks", CFrame.new(-330, 0, 250) * CFrame.Angles(0, math.pi / 2, 0), Vector3.new(90, 40, 60), folder, "Toy")
	for _, b in ipairs(if blocksModel then {} else blocks) do
		local y = b.s / 2 + (b.stack or 0)
		local blk = part("ToyBlock", Vector3.new(b.s, b.s, b.s), CFrame.new(b.x, y, b.z) * CFrame.Angles(0, b.rot, 0), b.color, Enum.Material.SmoothPlastic, folder, "Toy")
		for _, face in ipairs({ Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right }) do
			local gui = Instance.new("SurfaceGui")
			gui.Face = face
			gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
			gui.PixelsPerStud = 20
			gui.LightInfluence = 0.5
			local t = Instance.new("TextLabel")
			t.Size = UDim2.fromScale(1, 1)
			t.BackgroundTransparency = 1
			t.Font = Enum.Font.FredokaOne
			t.TextScaled = true
			t.TextColor3 = Color3.fromRGB(255, 250, 235)
			t.Text = b.letter
			t.Parent = gui
			gui.Parent = blk
		end
	end
	-- crayons
	local crayons = {
		{ x = half - 90, z = 120, rot = 0.3, color = Color3.fromRGB(240, 60, 60) },
		{ x = half - 110, z = 128, rot = 0.15, color = Color3.fromRGB(60, 120, 240) },
		{ x = -half + 120, z = -140, rot = -0.7, color = Color3.fromRGB(60, 200, 90) },
	}
	local crayonsModel = placeTemplate("Crayons", CFrame.new(330, 0, 280) * CFrame.Angles(0, -0.5, 0), Vector3.new(80, 20, 60), folder, "Toy")
	for _, cr in ipairs(if crayonsModel then {} else crayons) do
		local cf = CFrame.new(cr.x, 3, cr.z) * CFrame.Angles(0, cr.rot, 0)
		local body = part("Crayon", Vector3.new(56, 6, 6), cf, cr.color, Enum.Material.SmoothPlastic, folder, "Toy")
		body.Shape = Enum.PartType.Cylinder
		local wrap = part("CrayonWrap", Vector3.new(36, 6.4, 6.4), cf * CFrame.new(-4, 0, 0), Color3.fromRGB(240, 230, 200), Enum.Material.SmoothPlastic, folder, "Toy")
		wrap.Shape = Enum.PartType.Cylinder
		local tip = part("CrayonTip", Vector3.new(8, 4, 4), cf * CFrame.new(32, 0, 0), cr.color, Enum.Material.SmoothPlastic, folder, "Toy")
		tip.Shape = Enum.PartType.Cylinder
	end
	-- rubber duck (east side, looking at the play area)
	local dx, dz = 320, -60
	if not placeTemplate("Duck", CFrame.new(dx, 0, dz) * CFrame.Angles(0, -math.pi / 2, 0), Vector3.new(44, 46, 44), folder, "Toy") then
	ball("DuckBody", 30, CFrame.new(dx, 13, dz), Color3.fromRGB(255, 220, 60), Enum.Material.SmoothPlastic, folder, "Toy")
	ball("DuckHead", 18, CFrame.new(dx - 4, 34, dz - 8), Color3.fromRGB(255, 220, 60), Enum.Material.SmoothPlastic, folder, "Toy")
	part("DuckBeak", Vector3.new(8, 4, 10), CFrame.new(dx - 6, 32, dz - 20), Color3.fromRGB(255, 130, 40), Enum.Material.SmoothPlastic, folder, "Toy")
	ball("DuckEye", 3, CFrame.new(dx - 10, 38, dz - 14), Color3.new(0, 0, 0), Enum.Material.SmoothPlastic, folder, "Toy")
	ball("DuckEye", 3, CFrame.new(dx + 1, 38, dz - 15), Color3.new(0, 0, 0), Enum.Material.SmoothPlastic, folder, "Toy")
	end
	-- teddy bear sitting on the west side, facing the play area
	local tx, tz = -330, 40
	local fur = Color3.fromRGB(160, 110, 70)
	if not placeTemplate("Teddy", CFrame.new(tx, 0, tz) * CFrame.Angles(0, math.pi / 2, 0), Vector3.new(72, 90, 72), folder, "Toy") then
	ball("BearBody", 34, CFrame.new(tx, 15, tz), fur, Enum.Material.SmoothPlastic, folder, "Toy")
	ball("BearHead", 24, CFrame.new(tx + 4, 40, tz + 4), fur, Enum.Material.SmoothPlastic, folder, "Toy")
	ball("BearEar", 9, CFrame.new(tx - 4, 50, tz + 2), fur, Enum.Material.SmoothPlastic, folder, "Toy")
	ball("BearEar", 9, CFrame.new(tx + 12, 50, tz + 2), fur, Enum.Material.SmoothPlastic, folder, "Toy")
	ball("BearSnout", 11, CFrame.new(tx + 8, 37, tz + 14), Color3.fromRGB(220, 190, 150), Enum.Material.SmoothPlastic, folder, "Toy")
	ball("BearNose", 4, CFrame.new(tx + 9, 39, tz + 19), Color3.new(0, 0, 0), Enum.Material.SmoothPlastic, folder, "Toy")
	ball("BearEye", 3, CFrame.new(tx + 1, 44, tz + 14), Color3.new(0, 0, 0), Enum.Material.SmoothPlastic, folder, "Toy")
	ball("BearEye", 3, CFrame.new(tx + 13, 44, tz + 13), Color3.new(0, 0, 0), Enum.Material.SmoothPlastic, folder, "Toy")
	ball("BearArm", 14, CFrame.new(tx - 16, 14, tz + 8), fur, Enum.Material.SmoothPlastic, folder, "Toy")
	ball("BearArm", 14, CFrame.new(tx + 20, 14, tz + 8), fur, Enum.Material.SmoothPlastic, folder, "Toy")
	end
	-- a bedroom door on the south wall (Parts only when there is no Door mesh - see CLUTTER)
	local meshes = meshFolder
	if not (meshes and meshes:FindFirstChild("Door")) then
		local sz, dx0 = L.FloorZ / 2, -300
		part("Door", Vector3.new(116, 290, 2), CFrame.new(dx0, 145, sz - 1), C.Baseboard, Enum.Material.SmoothPlastic, folder, "Furniture")
		part("DoorPanel", Vector3.new(84, 100, 1), CFrame.new(dx0, 200, sz - 2.2), Color3.fromRGB(220, 220, 228), Enum.Material.SmoothPlastic, folder, "Furniture")
		part("DoorPanel", Vector3.new(84, 100, 1), CFrame.new(dx0, 75, sz - 2.2), Color3.fromRGB(220, 220, 228), Enum.Material.SmoothPlastic, folder, "Furniture")
		ball("DoorKnob", 12, CFrame.new(dx0 + 44, 135, sz - 4), C.Knob, Enum.Material.Metal, folder, "Furniture")
	end
end

local function buildDustBunnies(folder: Folder)
	local spots = { { -90, -30 }, { 60, -40 }, { 180, 60 }, { -180, 40 }, { 0, -120 }, { 100, 120 }, { -60, 130 }, { 210, -60 }, { -220, -150 }, { 150, -150 } }
	for i, s in ipairs(spots) do
		local size = 4 + (i % 3) * 1.5
		local b = ball("DustBunny", size, CFrame.new(s[1], size / 2, s[2]), C.Lint, Enum.Material.SmoothPlastic, folder, "DustBunny")
		b.CanCollide = false
		for j = 1, 3 do
			local a = j * 2.1 + i
			local puff = ball("DustPuff", size * 0.45, CFrame.new(s[1] + math.cos(a) * size * 0.45, size * 0.55, s[2] + math.sin(a) * size * 0.45), C.Lint, Enum.Material.SmoothPlastic, folder, "DustBunny")
			puff.CanCollide = false
		end
	end
end

-- ---------- the Great Dryer, the clothesline, the Lint Trap ----------

local function buildDryer(folder: Folder)
	local L = LAYOUT
	local x = L.DryerX
	-- fit = the machine about 34 studs wide and 42 tall, plus its open door on one side
	local dryerModel = placeTemplate("Dryer", CFrame.new(x, 0, 0) * CFrame.Angles(0, math.pi / 2, 0), Vector3.new(56, 42, 38), folder, "Dryer")
	if dryerModel then
		-- keep the spinning portal + light + steam so the Clothesline loop and the mood still work
		local _, dsize = dryerModel:GetBoundingBox()
		local cy = dsize.Y * 0.45
		-- the Blender dryer marks its porthole centre with Dryer_Pin; older models guess it
		local porthole = MeshTemplate.MarkerPosition(dryerModel, "_Pin") or Vector3.new(x + dsize.X * 0.25, cy, 0)
		local swirlPos = porthole - Vector3.new(3, 0, 0) -- just inside the drum
		local swirl = ball("DryerSwirl", 9, CFrame.new(swirlPos), C.Swirl, Enum.Material.Neon, folder, "Dryer")
		swirl.Transparency = 0.25
		swirl.CanCollide = false
		local core = ball("DryerCore", 4, CFrame.new(swirlPos), Color3.fromRGB(255, 220, 255), Enum.Material.Neon, folder, "Dryer")
		core.CanCollide = false
		pointLight(swirl, C.Swirl, 34, 0.7)
		local drum = part("DryerDrum", Vector3.new(0.2, 0.2, 0.2), CFrame.new(x, porthole.Y, porthole.Z), C.Swirl, Enum.Material.Neon, folder, "Dryer")
		drum.Transparency = 1
		drum.CanCollide = false
		if dryerModel:FindFirstChild("DryerPortal", true) then
			-- the model has its own glowing portal: keep the spin parts (and the light) but hide them
			swirl.Transparency = 1
			core.Transparency = 1
		end
		-- particles flowing out of the galaxy, toward the clothesline (the model's front)
		local basePos = MeshTemplate.MarkerPosition(dryerModel, "_Base")
		local unitPos = MeshTemplate.MarkerPosition(dryerModel, "_Unit")
		local front, unit = Vector3.new(1, 0, 0), 10
		if basePos and unitPos then
			local flat = Vector3.new(unitPos.X - basePos.X, 0, unitPos.Z - basePos.Z)
			if flat.Magnitude > 1e-3 then
				front, unit = flat.Unit, flat.Magnitude
			end
		end
		local mouth = part("DryerVoidEmitter", Vector3.new(1.4 * unit, 1.4 * unit, 0.5), CFrame.lookAt(porthole + front * 0.15 * unit, porthole + front * unit), C.Swirl, Enum.Material.SmoothPlastic, folder, "Dryer")
		mouth.Transparency = 1
		mouth.CanCollide = false
		mouth.CanQuery = false
		mouth.CanTouch = false
		mouth.CastShadow = false
		voidParticles(mouth, unit)
		local anchor = dryerModel.PrimaryPart or dryerModel:FindFirstChildWhichIsA("BasePart", true)
		if anchor then
			label(anchor, "THE GREAT DRYER", 34, dsize.Y / 2 + 6, Color3.fromRGB(255, 240, 120))
		end
		Map.Dryer.Body = anchor or drum
		Map.Dryer.Drum = drum
		Map.Dryer.Swirl = swirl
		Map.Dryer.Core = core
		return
	end
	local body = part("DryerBody", Vector3.new(24, 26, 26), CFrame.new(x, 13, 0), C.Metal, Enum.Material.SmoothPlastic, folder, "Dryer")
	part("DryerTop", Vector3.new(24.4, 3, 26.4), CFrame.new(x, 25.5, 0), C.DryerBlue, Enum.Material.SmoothPlastic, folder, "Dryer")
	part("DryerFace", Vector3.new(1, 24, 24), CFrame.new(x + 12.3, 13, 0), C.DryerBlue, Enum.Material.SmoothPlastic, folder, "Dryer")
	part("DryerFoot", Vector3.new(22, 2, 24), CFrame.new(x, 1, 0), C.MetalDark, Enum.Material.SmoothPlastic, folder, "Dryer")
	-- porthole: dark ring, glass, and the cosmic swirl inside
	local ring = part("DryerRim", Vector3.new(1.6, 18, 18), CFrame.new(x + 12.6, 13, 0), Color3.fromRGB(233, 238, 245), Enum.Material.SmoothPlastic, folder, "Dryer")
	ring.Shape = Enum.PartType.Cylinder
	local drum = part("DryerDrum", Vector3.new(0.8, 15, 15), CFrame.new(x + 13.1, 13, 0), Color3.fromRGB(150, 110, 240), Enum.Material.Glass, folder, "Dryer")
	drum.Shape = Enum.PartType.Cylinder
	drum.Transparency = 0.45
	drum.CanCollide = false
	local swirl = ball("DryerSwirl", 11, CFrame.new(x + 6, 13, 0), C.Swirl, Enum.Material.Neon, folder, "Dryer")
	swirl.Transparency = 0.15
	swirl.CanCollide = false
	local core = ball("DryerCore", 5, CFrame.new(x + 6, 13, 0), Color3.fromRGB(255, 220, 255), Enum.Material.Neon, folder, "Dryer")
	core.CanCollide = false
	pointLight(swirl, C.Swirl, 34, 0.7)
	-- control panel with knobs
	part("DryerPanel", Vector3.new(24, 6, 8), CFrame.new(x, 29, -9), C.MetalDark, Enum.Material.Metal, folder, "Dryer")
	for i, kc in ipairs({ Color3.fromRGB(255, 80, 80), Color3.fromRGB(80, 220, 120), Color3.fromRGB(255, 220, 80) }) do
		local knob = part("DryerKnob", Vector3.new(2.6, 2.6, 1.2), CFrame.new(x - 7 + i * 4.5, 30, -4.5), kc, Enum.Material.Neon, folder, "Dryer")
		knob.Shape = Enum.PartType.Cylinder
		knob.CFrame = knob.CFrame * CFrame.Angles(0, math.pi / 2, 0)
	end
	-- exhaust hose curling to the wall
	local hoseY = 20
	for i = 0, 6 do
		local hx = x - 12 - i * 8
		local hy = hoseY + math.sin(i * 0.9) * 4
		local seg = part("DryerHose", Vector3.new(9, 5, 5), CFrame.new(hx, hy, -6) * CFrame.Angles(0, 0, math.cos(i * 0.9) * 0.3), Color3.fromRGB(200, 205, 215), Enum.Material.Metal, folder, "Dryer")
		seg.Shape = Enum.PartType.Cylinder
	end
	-- warm steam puffing out of the top
	local steam = Instance.new("ParticleEmitter")
	steam.Name = "Steam"
	steam.Rate = 6
	steam.Lifetime = NumberRange.new(2, 3.5)
	steam.Speed = NumberRange.new(3, 5)
	steam.SpreadAngle = Vector2.new(20, 20)
	steam.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2), NumberSequenceKeypoint.new(1, 7) })
	steam.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1) })
	steam.Color = ColorSequence.new(Color3.fromRGB(230, 220, 255))
	steam.EmissionDirection = Enum.NormalId.Top
	steam.Parent = body
	label(body, "THE GREAT DRYER", 34, 20, Color3.fromRGB(255, 240, 120))
	Map.Dryer.Body = body
	Map.Dryer.Drum = drum
	Map.Dryer.Swirl = swirl
	Map.Dryer.Core = core
end

local function buildClothesline(folder: Folder)
	local L = LAYOUT
	-- a sagging rope from the centre of the dryer's void (the dryer holds that end - a post there
	-- would poke through the bigger mesh dryer) to a broom-handle post; it starts at the drum's height
	-- and eases down to LineY, so socks come out of the middle of the swirl
	local drum = Map.Dryer.Drum
	lineRise = if drum then drum.Position.Y - (L.LineY + 0.3) else 0
	local length = L.LineEndX - L.LineStartX
	local n = math.ceil(length / 10)
	local sag = 1.4
	for i = 0, n - 1 do
		local t0, t1 = i / n, (i + 1) / n
		local x0, x1 = L.LineStartX + t0 * length, L.LineStartX + t1 * length
		local y0 = L.LineY + 0.3 - sag * math.sin(t0 * math.pi) + riseAt(t0 * length)
		local y1 = L.LineY + 0.3 - sag * math.sin(t1 * math.pi) + riseAt(t1 * length)
		local p0, p1 = Vector3.new(x0, y0, 0), Vector3.new(x1, y1, 0)
		local seg = part("Rope", Vector3.new((p1 - p0).Magnitude + 0.3, 0.4, 0.4), CFrame.lookAt((p0 + p1) / 2, p1) * CFrame.Angles(0, math.pi / 2, 0), Color3.fromRGB(235, 225, 205), Enum.Material.SmoothPlastic, folder, "Clothesline")
		seg.Shape = Enum.PartType.Cylinder
		seg.CanCollide = false
	end
	column("PostEast", 1.1, L.LineY + 4, CFrame.new(L.LineEndX, (L.LineY + 4) / 2, 0), C.Wood, Enum.Material.SmoothPlastic, folder, "Clothesline")
	ball("PostCapE", 3, CFrame.new(L.LineEndX, L.LineY + 4.5, 0), C.WoodDark, Enum.Material.SmoothPlastic, folder, "Clothesline")
	-- Lint Trap: a giant laundry basket overflowing with lint
	local bx = L.LintX
	local basketModel = placeTemplate("Basket", CFrame.new(bx, 0, 0), Vector3.new(34, 30, 34), folder, "LintTrap")
	if basketModel then
		local anchor = basketModel.PrimaryPart or basketModel:FindFirstChildWhichIsA("BasePart", true)
		if anchor then
			label(anchor, "LINT TRAP", 28, select(2, basketModel:GetBoundingBox()).Y / 2 + 5, Color3.fromRGB(200, 200, 210))
		end
		return
	end
	local basket = column("LintTrap", 13, 18, CFrame.new(bx, 9, 0), C.Basket, Enum.Material.SmoothPlastic, folder, "LintTrap")
	basket.CanCollide = true
	for i = 0, 13 do
		local a = i / 14 * math.pi * 2
		local slat = part("BasketSlat", Vector3.new(2.2, 19, 1), CFrame.new(bx + math.cos(a) * 13.2, 9.5, math.sin(a) * 13.2) * CFrame.Angles(0, -a, 0), C.WoodDark, Enum.Material.SmoothPlastic, folder, "LintTrap")
		slat.CanCollide = false
	end
	column("BasketRim", 14, 1.6, CFrame.new(bx, 18.8, 0), C.WoodDark, Enum.Material.SmoothPlastic, folder, "LintTrap")
	local lint = ball("LintPile", 22, CFrame.new(bx, 17, 0), C.Lint, Enum.Material.SmoothPlastic, folder, "LintTrap")
	lint.CanCollide = false
	for i = 1, 5 do
		local a = i * 1.3
		local puff = ball("LintPuff", 6 + i % 2 * 2, CFrame.new(bx + math.cos(a) * 10, 22 + i % 3, math.sin(a) * 10), C.Lint, Enum.Material.SmoothPlastic, folder, "LintTrap")
		puff.CanCollide = false
	end
	label(basket, "LINT TRAP", 28, 20, Color3.fromRGB(200, 200, 210))
end

-- A chunky toy padlock (~3 studs tall) sitting on a back-row slot's cushion, keyhole facing out of
-- the drawer. Plain Parts that never block or catch anything; Base shows/hides it through the
-- parts' Transparency once it knows whether the owner has the +4 Drawer Slots pass.
local function padlock(slot: BasePart, seatY: number, tilt: number): Model
	local lock = Instance.new("Model")
	lock.Name = "Padlock"
	-- bottom centre on the seat, +Z out of the drawer, leaning a little like a dropped toy
	local at = slot.CFrame * CFrame.new(0, seatY - slot.Position.Y, 0) * CFrame.Angles(0, 0, tilt)
	local w, h, d = 2.6, 1.8, 1.2
	local body = part("PadlockBody", Vector3.new(w, h, d), at * CFrame.new(0, h / 2, 0), C.LockGold, nil, lock)
	part("PadlockCap", Vector3.new(w + 0.1, 0.35, d + 0.1), at * CFrame.new(0, h - 0.15, 0), C.LockShine, nil, lock)
	-- keyhole: a round hole over a slot, both through the body so it shows front and back
	local hole = part("PadlockKeyhole", Vector3.new(d + 0.06, 0.5, 0.5), at * CFrame.new(0, h / 2 + 0.12, 0) * CFrame.Angles(0, math.pi / 2, 0), C.LockInk, nil, lock)
	hole.Shape = Enum.PartType.Cylinder
	part("PadlockKeyslot", Vector3.new(0.22, 0.55, d + 0.06), at * CFrame.new(0, h / 2 - 0.22, 0), C.LockInk, nil, lock)
	-- the shackle: two posts out of the cap and a half ring of short rods between them, with a
	-- ball on every bend so the ring reads as one smooth bar
	local r, t = 0.75, 0.4
	local yc = h + 0.35
	for _, sx in ipairs({ -1, 1 }) do
		column("PadlockShackle", t / 2, yc - h + 0.3, at * CFrame.new(sx * r, (yc + h - 0.3) / 2, 0), C.LockSteel, nil, lock)
	end
	local n = 4
	for k = 0, n - 1 do
		local a0, a1 = k / n * math.pi, (k + 1) / n * math.pi
		local p0 = Vector3.new(r * math.cos(a0), yc + r * math.sin(a0), 0)
		local p1 = Vector3.new(r * math.cos(a1), yc + r * math.sin(a1), 0)
		local rod = part("PadlockShackle", Vector3.new((p1 - p0).Magnitude, t, t), at * CFrame.new((p0 + p1) / 2) * CFrame.Angles(0, 0, math.atan2(p1.Y - p0.Y, p1.X - p0.X)), C.LockSteel, nil, lock)
		rod.Shape = Enum.PartType.Cylinder
		if k > 0 then
			ball("PadlockShackle", t, at * CFrame.new(p0), C.LockSteel, nil, lock)
		end
	end
	decor(lock)
	lock.PrimaryPart = body
	lock.Parent = slot
	return lock
end

-- The back row's sign: a floating "🔒 +4 SLOTS" pill and the prompt that opens the Store. The
-- client shows the prompt to the drawer's owner only; Base flips its Locked attribute and
-- LockGui.Enabled.
local function lockSign(cf: CFrame, model: Model)
	local extra = S.Config.Store.ExtraSlots
	local sign = part("LockSign", Vector3.new(1, 1, 1), cf, C.LockGold, nil, model)
	sign.Transparency = 1
	sign.CanCollide = false
	sign.CanQuery = false
	sign.CanTouch = false
	sign.CastShadow = false
	local gui = Instance.new("BillboardGui")
	gui.Name = "LockGui"
	gui.Adornee = sign
	gui.Size = UDim2.fromScale(8, 2.2) -- studs: a sign over the padlocks, shrinking with distance
	gui.StudsOffset = Vector3.new(0, 2, 0) -- above the prompt's own pop-up
	gui.AlwaysOnTop = false
	gui.MaxDistance = 60
	gui.LightInfluence = 0
	-- the UI kit's candy pill: cream-to-gold gradient, plum outline, a soft gloss on top
	local pill = Instance.new("Frame")
	pill.Name = "Pill"
	pill.Size = UDim2.fromScale(1, 1)
	pill.BackgroundColor3 = Color3.new(1, 1, 1)
	pill.BorderSizePixel = 0
	pill.ZIndex = 1
	pill.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = pill
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(74, 42, 94)
	stroke.Thickness = 3
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = pill
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new(Color3.fromRGB(255, 244, 214), Color3.fromRGB(255, 190, 70))
	gradient.Parent = pill
	local gloss = Instance.new("Frame")
	gloss.Name = "Gloss"
	gloss.AnchorPoint = Vector2.new(0.5, 0)
	gloss.Position = UDim2.fromScale(0.5, 0.08)
	gloss.Size = UDim2.fromScale(0.86, 0.36)
	gloss.BackgroundColor3 = Color3.new(1, 1, 1)
	gloss.BackgroundTransparency = 0.6
	gloss.BorderSizePixel = 0
	gloss.ZIndex = 2
	gloss.Parent = pill
	local glossCorner = Instance.new("UICorner")
	glossCorner.CornerRadius = UDim.new(0.5, 0)
	glossCorner.Parent = gloss
	local text = Instance.new("TextLabel")
	text.Name = "LockText"
	text.AnchorPoint = Vector2.new(0.5, 0.5)
	text.Position = UDim2.fromScale(0.5, 0.52)
	text.Size = UDim2.fromScale(0.84, 0.7)
	text.BackgroundTransparency = 1
	text.ZIndex = 3
	text.Font = Enum.Font.FredokaOne
	text.TextScaled = true
	text.TextColor3 = Color3.fromRGB(70, 40, 8)
	text.Text = "🔒 +" .. extra .. " SLOTS"
	text.Parent = pill
	gui.Parent = sign
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "UnlockSlotsPrompt"
	prompt.ActionText = "Unlock"
	prompt.ObjectText = "+" .. extra .. " Drawer Slots"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 18 -- reaches the whole back row from inside the drawer
	prompt.RequiresLineOfSight = false
	prompt:SetAttribute("Locked", true)
	prompt.Parent = sign
end

-- One base = one open dresser drawer with a felt lining and a little warm light: three rows of
-- slot cushions, the back one padlocked until the owner has the +4 Drawer Slots pass.
-- Local space: origin at the drawer floor centre (y = 0 is the map floor), +Z points out of the
-- drawer toward the clothesline.
local function buildBase(index: number, x: number, z: number, folder: Folder): Model
	local L = LAYOUT
	local facing = if z > 0 then math.pi else 0
	local cf = CFrame.new(x, 0, z) * CFrame.Angles(0, facing, 0)
	local model = Instance.new("Model")
	model.Name = "Base_" .. index
	model:SetAttribute("Index", index)
	CollectionService:AddTag(model, "Base")

	local floor = part("Floor", Vector3.new(L.BaseW, 1, L.BaseD), cf * CFrame.new(0, 0.5, 0), C.Wood, Enum.Material.SmoothPlastic, model)
	model.PrimaryPart = floor
	-- optional real drawer shell: the Part walls stay for collision but turn invisible
	local shell = placeTemplate("Drawer", cf * CFrame.new(0, 0, 0), Vector3.new(L.BaseW + 6, L.WallH + 6, L.BaseD + 6), model)
	local wallT = if shell then 1 else 0
	if shell then
		decor(shell) -- the invisible Part walls below keep doing the blocking
	end
	local felt = part("Felt", Vector3.new(L.BaseW - 2, 0.3, L.BaseD - 2), cf * CFrame.new(0, 1.15, 0), C.Felt, Enum.Material.SmoothPlastic, model)
	felt.CanCollide = false
	if shell and shell:FindFirstChild("DrawerLiner", true) then
		felt.Transparency = 1 -- the mesh brings its own polka-dot liner floor (top at 1.3, like the felt)
	end
	part("BackWall", Vector3.new(L.BaseW, L.WallH, 1), cf * CFrame.new(0, 1 + L.WallH / 2, -L.BaseD / 2 + 0.5), C.Wood, Enum.Material.SmoothPlastic, model).Transparency = wallT
	part("LeftWall", Vector3.new(1, L.WallH, L.BaseD), cf * CFrame.new(-L.BaseW / 2 + 0.5, 1 + L.WallH / 2, 0), C.Wood, Enum.Material.SmoothPlastic, model).Transparency = wallT
	part("RightWall", Vector3.new(1, L.WallH, L.BaseD), cf * CFrame.new(L.BaseW / 2 - 0.5, 1 + L.WallH / 2, 0), C.Wood, Enum.Material.SmoothPlastic, model).Transparency = wallT
	-- the drawer front: chunky, rounded-looking, with a big brass knob
	part("FrontLip", Vector3.new(L.BaseW + 2, 2.5, 2), cf * CFrame.new(0, 2.25, L.BaseD / 2), C.WoodDark, Enum.Material.SmoothPlastic, model).Transparency = wallT
	part("FrontTrim", Vector3.new(L.BaseW + 2, 0.8, 2.4), cf * CFrame.new(0, 3.5, L.BaseD / 2), C.Knob, Enum.Material.Metal, model).Transparency = wallT
	local knob = ball("Handle", 3, cf * CFrame.new(0, 2.4, L.BaseD / 2 + 1.6), C.Knob, Enum.Material.Metal, model)
	knob.CanCollide = false
	knob.Transparency = wallT
	-- warm light inside the drawer
	local lamp = part("DrawerLamp", Vector3.new(6, 0.4, 1), cf * CFrame.new(0, L.WallH, -L.BaseD / 2 + 1.2), C.Lamp, Enum.Material.Neon, model)
	lamp.CanCollide = false
	pointLight(lamp, C.Lamp, 34, 0.55)

	-- Shutter: rises out of the floor when the drawer is slammed (Base moves it).
	local shutter = part("Shutter", Vector3.new(L.BaseW, L.WallH, 1), cf * CFrame.new(0, 1 + L.WallH / 2, L.BaseD / 2 - 0.5), C.WoodDark, Enum.Material.SmoothPlastic, model)
	shutter:SetAttribute("ClosedY", shutter.Position.Y)
	shutter.CFrame = shutter.CFrame - Vector3.new(0, L.WallH + 2, 0)
	shutter.Transparency = 1
	shutter.CanCollide = false
	-- a full drawer front (with handle) welded to the shutter, so slamming really shuts the drawer;
	-- the plain shutter part then stays invisible (Base.SetShutter reads "Skinned")
	local front = placeTemplate("DrawerFront", shutter.CFrame * CFrame.new(0, -L.WallH / 2, 0), Vector3.new(L.BaseW + 2, L.WallH, 4.2), model)
	if front then
		front.Name = "ShutterSkin"
		decor(front)
		for _, d in ipairs(front:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Anchored = false
				d.Massless = true
				local w = Instance.new("WeldConstraint")
				w.Part0 = shutter
				w.Part1 = d
				w.Parent = d
			end
		end
		shutter:SetAttribute("Skinned", true)
	end

	-- Slots: little felt cushions. The first BaseSlots fill rows 1-2; the back row (ExtraSlots more,
	-- attribute BackRow) wears padlocks until the owner has the +4 Drawer Slots pass.
	local slots = Instance.new("Folder")
	slots.Name = "Slots"
	slots.Parent = model
	local baseSlots = S.Config.Economy.BaseSlots
	local total = baseSlots + S.Config.Store.ExtraSlots
	local function rowZ(row: number): number
		return L.SlotRowZ[row] or (L.SlotRowZ[#L.SlotRowZ] - (row - #L.SlotRowZ) * 10)
	end
	for i = 1, total do
		local row = math.ceil(i / L.SlotCols)
		local col = (i - 1) % L.SlotCols + 1
		local sx = (col - (L.SlotCols + 1) / 2) * L.SlotSpacingX
		local sz = rowZ(row)
		local slot = part("Slot_" .. i, Vector3.new(L.SlotSize, 0.6, L.SlotSize), cf * CFrame.new(sx, 1.5, sz), Color3.fromRGB(240, 200, 150), Enum.Material.SmoothPlastic, slots, "SockSlot")
		slot:SetAttribute("Index", i)
		local seatY = slot.Position.Y + slot.Size.Y / 2
		-- a puffy tufted cushion instead of the flat pad; socks sit on its top (Base.SlotCFrame)
		local cushion = placeTemplate("SlotCushion", cf * CFrame.new(sx, 1.3, sz), Vector3.new(7, 2.2, 7), slot)
		if cushion then
			decor(cushion)
			slot.Transparency = 1
			local lo, hi = MeshTemplate.SolidBounds(cushion)
			if lo and hi then
				local seat = lo.Y + 0.76 * (hi.Y - lo.Y) -- the tufted middle, a little under the dome
				slot:SetAttribute("SeatLift", seat - (slot.Position.Y + slot.Size.Y / 2 - 0.1))
				seatY = seat
			end
		end
		if i > baseSlots then
			slot:SetAttribute("BackRow", true)
			padlock(slot, seatY, if i % 2 == 0 then -0.1 else 0.1)
		end
	end
	lockSign(cf * CFrame.new(0, 6.5, rowZ(math.ceil((baseSlots + 1) / L.SlotCols))), model)

	-- Collect pad (inside, near the front) with the amount printed on it
	local pad = part("CollectPad", Vector3.new(10, 0.3, 5), cf * CFrame.new(0, 1.35, 16), Color3.fromRGB(80, 230, 120), Enum.Material.Neon, model, "CollectPad")
	local padGui = Instance.new("SurfaceGui")
	padGui.Name = "PadGui"
	padGui.Face = Enum.NormalId.Top
	padGui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	padGui.PixelsPerStud = 40
	padGui.LightInfluence = 0
	padGui.Adornee = pad
	local padText = Instance.new("TextLabel")
	padText.Name = "PadText"
	padText.Size = UDim2.fromScale(1, 1)
	padText.BackgroundTransparency = 1
	padText.Font = Enum.Font.FredokaOne
	padText.TextScaled = true
	padText.TextColor3 = Color3.fromRGB(20, 60, 30)
	padText.Text = "COLLECT $0"
	padText.Rotation = if z > 0 then 0 else 180
	padText.Parent = padGui
	padGui.Parent = pad
	-- gold coin tray round the pad (the pad keeps its glow, text and touch)
	local tray = placeTemplate("CollectTray", cf * CFrame.new(0, 1.3, 16), Vector3.new(13.6, 2.4, 6.9), model)
	if tray then
		decor(tray)
	end

	-- Slam Drawer button (tucked in the back-left corner, clear of slot 9's cushion; only reachable in person)
	local buttonBase = part("ButtonBase", Vector3.new(3, 2, 3), cf * CFrame.new(-20, 2, -18), C.MetalDark, Enum.Material.Metal, model)
	local button = part("SlamButton", Vector3.new(0.6, 2.4, 2.4), cf * CFrame.new(-20, 3.3, -18) * CFrame.Angles(0, 0, math.pi / 2), Color3.fromRGB(240, 60, 60), Enum.Material.Neon, model, "SlamButton")
	button.Shape = Enum.PartType.Cylinder
	-- big red arcade button on a hazard-striped box (the part keeps the Slam prompt)
	local skin = placeTemplate("SlamButton", cf * CFrame.new(-20, 1.3, -18), Vector3.new(3.6, 3.0, 3.6), model)
	local slamLabelY = 2
	if skin then
		skin.Name = "SlamButtonSkin" -- Base looks the button part up as model.SlamButton
		decor(skin)
		buttonBase.Transparency = 1
		button.Transparency = 1
		slamLabelY = 2.8
	end
	label(button, "SLAM", 20, slamLabelY, Color3.fromRGB(255, 120, 120))

	-- Name sign above the back wall
	local signPart = part("Sign", Vector3.new(16, 3.4, 0.6), cf * CFrame.new(0, L.WallH + 6, -L.BaseD / 2 + 0.5), Color3.fromRGB(255, 255, 255), Enum.Material.SmoothPlastic, model)
	local signText = label(signPart, "Drawer " .. index .. " - FREE", 34, 0, Color3.fromRGB(40, 40, 60))
	signText.Parent.Name = "SignGui"
	if shell then
		signPart.Transparency = 1 -- the floating name label stays; the plain white plank goes
	end

	model.Parent = folder
	return model
end

local function buildSpawn(folder: Folder)
	local mat = part("WelcomeMat", Vector3.new(16, 0.5, 12), CFrame.new(0, 0.45, LAYOUT.SpawnZ), Color3.fromRGB(180, 60, 60), Enum.Material.SmoothPlastic, folder, "MapFloor")
	mat.CanCollide = false
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "Spawn"
	spawn.Size = Vector3.new(10, 1, 8)
	spawn.CFrame = CFrame.new(0, 0.5, LAYOUT.SpawnZ)
	spawn.Anchored = true
	spawn.Transparency = 1
	spawn.CanCollide = false
	spawn.Duration = 0
	spawn.Parent = folder
end

function Map.Init(s)
	S = s
	local folder = ensureMeshFolder()
	meshFolder = folder
	local meshCount = #folder:GetChildren()
	if meshCount > 0 then
		print("[Map] " .. meshCount .. " mesh template(s) found in ReplicatedStorage.MapMeshes")
	end
	local root = Instance.new("Folder")
	root.Name = "StealASock"
	Map.Root = root
	for _, name in ipairs({ "Map", "Bases", "Line", "Drawer", "Carried" }) do
		local f = Instance.new("Folder")
		f.Name = name
		f.Parent = root
		Map.Folders[name] = f
	end
	-- the client reads these to move line socks itself (see StealASockClient.SockFX)
	local line = Map.Folders.Line
	line:SetAttribute("StartX", LAYOUT.LineStartX)
	line:SetAttribute("EndX", LAYOUT.LineEndX)
	line:SetAttribute("Y", LAYOUT.LineY - LAYOUT.HangDrop)
	line:SetAttribute("PinOffset", 4.3) -- Leg centre -> clothespin, at sock scale

	local mapFolder = Map.Folders.Map
	buildFloor(mapFolder)
	buildBed(mapFolder)
	buildWindow(mapFolder)
	buildDecor(mapFolder)
	buildCeilingFan(mapFolder)
	buildBoundary(mapFolder)
	buildNightstand(mapFolder)
	buildToys(mapFolder)
	buildDustBunnies(mapFolder)
	buildDryer(mapFolder)
	buildClothesline(mapFolder)
	line:SetAttribute("Rise", lineRise) -- known once the dryer is built
	line:SetAttribute("RiseLength", LAYOUT.RiseLength)
	buildSpawn(mapFolder)
	local baseIndex = 0
	for _, sideZ in ipairs({ -LAYOUT.BaseZ, LAYOUT.BaseZ }) do
		for _, x in ipairs(LAYOUT.BaseXs) do
			baseIndex += 1
			table.insert(Map.Bases, buildBase(baseIndex, x, sideZ, Map.Folders.Bases))
		end
	end
	root.Parent = workspace
end

-- World position of a sock hanging `t` studs along the clothesline.
function Map.LinePoint(t: number): CFrame
	local L = LAYOUT
	return CFrame.new(L.LineStartX + t, L.LineY - L.HangDrop + riseAt(t), 0)
end

function Map.LineLength(): number
	return LAYOUT.LineEndX - LAYOUT.LineStartX
end

return Map
