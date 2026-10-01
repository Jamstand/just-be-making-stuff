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
local S

local LAYOUT = {
	FloorX = 520,
	FloorZ = 340,
	RugX = 440,
	RugZ = 260,
	Tile = 20,
	WallHeight = 110,
	LineY = 15, -- clothesline rail height
	LineStartX = -160, -- inside the dryer drum: socks slide out of it
	LineEndX = 150,
	HangDrop = 4.6, -- sock pivot (Leg centre) sits this far under the rail; socks are 2x scale
	DryerX = -172,
	LintX = 174,
	BaseXs = { -126, -42, 42, 126 },
	BaseZ = 78, -- bases at +BaseZ (south) and -BaseZ (north), facing the line
	BaseW = 46, -- drawer footprint (x)
	BaseD = 32, -- drawer footprint (z)
	WallH = 9, -- drawer wall height (taller than a jump)
	SlotCols = 4,
	SlotSpacingX = 11,
	SlotRowZ = { -8, 2 }, -- Phase 3 adds rows toward the back for rebirth levels
	SlotSize = 5,
	FrontApron = 10, -- claim zone extends this far out the front of the drawer
	SpawnZ = 30,
}
Map.Layout = LAYOUT
Map.Root = nil :: Folder?
Map.Folders = {} :: { [string]: Folder }
Map.Dryer = {} :: { [string]: BasePart }
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
	Lint = Color3.fromRGB(165, 165, 172),
	Basket = Color3.fromRGB(200, 160, 100),
	DryerBlue = Color3.fromRGB(109, 165, 227),
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
	-- door glass, the window's moon
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

GLOW_PARTS = {
	LampGlow = C.Lamp,
	DryerPortal = Color3.fromRGB(150, 90, 255),
	MoonGlow = C.MoonGlow,
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

-- ---------- floor, rug, walls ----------

local function buildFloor(folder: Folder)
	local L = LAYOUT
	local planks = Instance.new("Folder")
	planks.Name = "Planks"
	planks.Parent = folder
	local plankW = 40
	local nx = L.FloorX / plankW
	for ix = 0, nx - 1 do
		local x = -L.FloorX / 2 + plankW / 2 + ix * plankW
		part("Plank", Vector3.new(plankW - 0.4, 1, L.FloorZ), CFrame.new(x, -0.5, 0), if ix % 2 == 0 then C.Plank1 else C.Plank2, Enum.Material.SmoothPlastic, planks, "MapFloor")
	end
	-- checkered rug over the play area (spec: checkered floor) with a dark border
	local rug = Instance.new("Folder")
	rug.Name = "Rug"
	rug.Parent = folder
	local edge = part("RugEdge", Vector3.new(L.RugX + 8, 0.3, L.RugZ + 8), CFrame.new(0, 0.05, 0), C.RugEdge, Enum.Material.SmoothPlastic, rug, "MapFloor")
	edge.CanCollide = false
	local cx, cz = L.RugX / L.Tile, L.RugZ / L.Tile
	for ix = 0, cx - 1 do
		for iz = 0, cz - 1 do
			local x = -L.RugX / 2 + L.Tile / 2 + ix * L.Tile
			local z = -L.RugZ / 2 + L.Tile / 2 + iz * L.Tile
			local t = part("Tile", Vector3.new(L.Tile, 0.4, L.Tile), CFrame.new(x, 0.2, z), if (ix + iz) % 2 == 0 then C.RugA else C.RugB, Enum.Material.SmoothPlastic, rug, "MapFloor")
			t.CanCollide = false
		end
	end
	-- walls with wallpaper stripes and a baseboard (no ceiling: the night sky is the ceiling)
	local walls = Instance.new("Folder")
	walls.Name = "Walls"
	walls.Parent = folder
	local h = L.WallHeight
	local function wall(name: string, size: Vector3, cf: CFrame, along: string)
		part(name, size, cf, C.Wall, Enum.Material.SmoothPlastic, walls, "MapWall")
		local length = if along == "x" then size.X else size.Z
		for i = 0, length / 40 - 1 do
			local offset = -length / 2 + 20 + i * 40
			local scf = if along == "x" then cf * CFrame.new(offset, 0, 0) else cf * CFrame.new(0, 0, offset)
			local ssize = if along == "x" then Vector3.new(14, h, size.Z + 0.2) else Vector3.new(size.X + 0.2, h, 14)
			local stripe = part("Stripe", ssize, scf, C.WallStripe, Enum.Material.SmoothPlastic, walls, "MapWall")
			stripe.CanCollide = false
		end
		local bsize = if along == "x" then Vector3.new(size.X, 5, size.Z + 1.2) else Vector3.new(size.X + 1.2, 5, size.Z)
		part("Baseboard", bsize, cf * CFrame.new(0, -h / 2 + 2.5, 0), C.Baseboard, Enum.Material.SmoothPlastic, walls, "MapWall")
	end
	wall("WallNorth", Vector3.new(L.FloorX + 4, h, 3), CFrame.new(0, h / 2, -L.FloorZ / 2 - 1.5), "x")
	wall("WallSouth", Vector3.new(L.FloorX + 4, h, 3), CFrame.new(0, h / 2, L.FloorZ / 2 + 1.5), "x")
	wall("WallWest", Vector3.new(3, h, L.FloorZ), CFrame.new(-L.FloorX / 2 - 1.5, h / 2, 0), "z")
	wall("WallEast", Vector3.new(3, h, L.FloorZ), CFrame.new(L.FloorX / 2 + 1.5, h / 2, 0), "z")
end

-- ---------- furniture ----------

local function buildBed(folder: Folder)
	local L = LAYOUT
	local z0 = -L.FloorZ / 2 -- north wall
	local depth, width = 76, 270
	local zc = z0 + depth / 2 + 2
	if placeTemplate("Bed", CFrame.new(0, 0, zc), Vector3.new(width + 20, 100, depth + 10), folder, "Furniture") then
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
	local wx, wy = 40, 92
	local mesh = placeTemplate("Window", CFrame.new(wx, wy - 32, z0), Vector3.new(64, 64, 10), folder, "Furniture", true)
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
	local x, z = -L.FloorX / 2 + 52, -118
	local h = 92
	-- concept proportions: the nightstand's top is about level with the mattress, and the lamp
	-- globe is about 0.6 of the nightstand's width
	local stand = placeTemplate("Nightstand", CFrame.new(x, 0, z), Vector3.new(52, 54, 52), folder, "Furniture")
	if stand then
		local _, standHi = MeshTemplate.SolidBounds(stand)
		local standTop = if standHi then standHi.Y else 54
		local lampTop = standTop + 50
		local lamp = placeTemplate("Lamp", CFrame.new(x, standTop, z), Vector3.new(33, 40, 33), folder, "Furniture")
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

-- Wall decor from the concept (mesh only - the Part map does without): a framed landscape on the
-- west wall and a bookshelf against the east wall.
local function buildDecor(folder: Folder)
	local L = LAYOUT
	placeTemplate("Picture", CFrame.new(-L.FloorX / 2, 46, -40) * CFrame.Angles(0, math.pi / 2, 0), Vector3.new(54, 42, 6), folder, "Furniture", true)
	placeTemplate("Bookshelf", CFrame.new(L.FloorX / 2, 0, -100) * CFrame.Angles(0, -math.pi / 2, 0), Vector3.new(72, 62, 30), folder, "Furniture", true)
end

local function buildToys(folder: Folder)
	local L = LAYOUT
	local half = L.FloorX / 2
	-- letter blocks
	local blocks = {
		{ x = -half + 60, z = 130, s = 24, letter = "S", color = Color3.fromRGB(230, 80, 90), rot = 0.2 },
		{ x = -half + 84, z = 118, s = 20, letter = "O", color = Color3.fromRGB(90, 160, 240), rot = -0.4 },
		{ x = -half + 66, z = 130, s = 18, letter = "C", color = Color3.fromRGB(250, 200, 70), rot = 0.1, stack = 24 },
		{ x = half - 70, z = -120, s = 26, letter = "K", color = Color3.fromRGB(110, 200, 120), rot = 0.5 },
		{ x = half - 60, z = 140, s = 22, letter = "!", color = Color3.fromRGB(200, 110, 230), rot = -0.2 },
	}
	local blocksModel = placeTemplate("Blocks", CFrame.new(-half + 70, 0, 125), Vector3.new(90, 40, 60), folder, "Toy")
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
	local crayonsModel = placeTemplate("Crayons", CFrame.new(half - 100, 0, 124), Vector3.new(80, 20, 60), folder, "Toy")
	for _, cr in ipairs(if crayonsModel then {} else crayons) do
		local cf = CFrame.new(cr.x, 3, cr.z) * CFrame.Angles(0, cr.rot, 0)
		local body = part("Crayon", Vector3.new(56, 6, 6), cf, cr.color, Enum.Material.SmoothPlastic, folder, "Toy")
		body.Shape = Enum.PartType.Cylinder
		local wrap = part("CrayonWrap", Vector3.new(36, 6.4, 6.4), cf * CFrame.new(-4, 0, 0), Color3.fromRGB(240, 230, 200), Enum.Material.SmoothPlastic, folder, "Toy")
		wrap.Shape = Enum.PartType.Cylinder
		local tip = part("CrayonTip", Vector3.new(8, 4, 4), cf * CFrame.new(32, 0, 0), cr.color, Enum.Material.SmoothPlastic, folder, "Toy")
		tip.Shape = Enum.PartType.Cylinder
	end
	-- rubber duck (east side)
	local dx, dz = half - 40, 40
	if not placeTemplate("Duck", CFrame.new(dx, 0, dz) * CFrame.Angles(0, math.pi, 0), Vector3.new(44, 46, 44), folder, "Toy") then
	ball("DuckBody", 30, CFrame.new(dx, 13, dz), Color3.fromRGB(255, 220, 60), Enum.Material.SmoothPlastic, folder, "Toy")
	ball("DuckHead", 18, CFrame.new(dx - 4, 34, dz - 8), Color3.fromRGB(255, 220, 60), Enum.Material.SmoothPlastic, folder, "Toy")
	part("DuckBeak", Vector3.new(8, 4, 10), CFrame.new(dx - 6, 32, dz - 20), Color3.fromRGB(255, 130, 40), Enum.Material.SmoothPlastic, folder, "Toy")
	ball("DuckEye", 3, CFrame.new(dx - 10, 38, dz - 14), Color3.new(0, 0, 0), Enum.Material.SmoothPlastic, folder, "Toy")
	ball("DuckEye", 3, CFrame.new(dx + 1, 38, dz - 15), Color3.new(0, 0, 0), Enum.Material.SmoothPlastic, folder, "Toy")
	end
	-- teddy bear slumped in the west corner
	local tx, tz = -half + 46, 60
	local fur = Color3.fromRGB(160, 110, 70)
	if not placeTemplate("Teddy", CFrame.new(tx, 0, tz) * CFrame.Angles(0, math.pi / 2, 0), Vector3.new(48, 60, 48), folder, "Toy") then
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
	-- a bedroom door on the south wall
	local sz = L.FloorZ / 2
	part("Door", Vector3.new(60, 96, 2), CFrame.new(-190, 48, sz - 1), C.Baseboard, Enum.Material.SmoothPlastic, folder, "Furniture")
	part("DoorPanel", Vector3.new(44, 34, 1), CFrame.new(-190, 66, sz - 2.2), Color3.fromRGB(220, 220, 228), Enum.Material.SmoothPlastic, folder, "Furniture")
	part("DoorPanel", Vector3.new(44, 34, 1), CFrame.new(-190, 24, sz - 2.2), Color3.fromRGB(220, 220, 228), Enum.Material.SmoothPlastic, folder, "Furniture")
	ball("DoorKnob", 6, CFrame.new(-166, 46, sz - 3), C.Knob, Enum.Material.Metal, folder, "Furniture")
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
	-- a sagging rope in 12 segments between two broom-handle posts
	local n = 12
	local length = L.LineEndX - L.LineStartX
	local sag = 1.4
	for i = 0, n - 1 do
		local t0, t1 = i / n, (i + 1) / n
		local x0, x1 = L.LineStartX + t0 * length, L.LineStartX + t1 * length
		local y0 = L.LineY + 0.3 - sag * math.sin(t0 * math.pi)
		local y1 = L.LineY + 0.3 - sag * math.sin(t1 * math.pi)
		local p0, p1 = Vector3.new(x0, y0, 0), Vector3.new(x1, y1, 0)
		local seg = part("Rope", Vector3.new((p1 - p0).Magnitude + 0.3, 0.4, 0.4), CFrame.lookAt((p0 + p1) / 2, p1) * CFrame.Angles(0, math.pi / 2, 0), Color3.fromRGB(235, 225, 205), Enum.Material.SmoothPlastic, folder, "Clothesline")
		seg.Shape = Enum.PartType.Cylinder
		seg.CanCollide = false
	end
	column("PostWest", 1.1, L.LineY + 4, CFrame.new(L.LineStartX + 6, (L.LineY + 4) / 2, 3), C.Wood, Enum.Material.SmoothPlastic, folder, "Clothesline")
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

-- One base = one open dresser drawer with a felt lining and a little warm light.
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
		-- decoration only: the invisible Part walls below keep doing the blocking
		for _, d in ipairs(shell:GetDescendants()) do
			if d:IsA("BasePart") then
				d.CanCollide = false
				d.CanQuery = false
				d.CanTouch = false
			end
		end
	end
	local felt = part("Felt", Vector3.new(L.BaseW - 2, 0.3, L.BaseD - 2), cf * CFrame.new(0, 1.15, 0), C.Felt, Enum.Material.SmoothPlastic, model)
	felt.CanCollide = false
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

	-- Slots: little felt cushions
	local slots = Instance.new("Folder")
	slots.Name = "Slots"
	slots.Parent = model
	local total = S.Config.Economy.BaseSlots
	for i = 1, total do
		local row = math.ceil(i / L.SlotCols)
		local col = (i - 1) % L.SlotCols + 1
		local sx = (col - (L.SlotCols + 1) / 2) * L.SlotSpacingX
		local sz = L.SlotRowZ[row] or (L.SlotRowZ[#L.SlotRowZ] - (row - #L.SlotRowZ) * 10)
		local slot = part("Slot_" .. i, Vector3.new(L.SlotSize, 0.6, L.SlotSize), cf * CFrame.new(sx, 1.5, sz), Color3.fromRGB(240, 200, 150), Enum.Material.SmoothPlastic, slots, "SockSlot")
		slot:SetAttribute("Index", i)
	end

	-- Collect pad (inside, near the front) with the amount printed on it
	local pad = part("CollectPad", Vector3.new(10, 0.3, 5), cf * CFrame.new(0, 1.35, 11), Color3.fromRGB(80, 230, 120), Enum.Material.Neon, model, "CollectPad")
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

	-- Slam Drawer button (back-left corner; only reachable in person)
	part("ButtonBase", Vector3.new(3, 2, 3), cf * CFrame.new(-19, 2, -12), C.MetalDark, Enum.Material.Metal, model)
	local button = part("SlamButton", Vector3.new(0.6, 2.4, 2.4), cf * CFrame.new(-19, 3.3, -12) * CFrame.Angles(0, 0, math.pi / 2), Color3.fromRGB(240, 60, 60), Enum.Material.Neon, model, "SlamButton")
	button.Shape = Enum.PartType.Cylinder
	label(button, "SLAM", 20, 2, Color3.fromRGB(255, 120, 120))

	-- Name sign above the back wall
	local signPart = part("Sign", Vector3.new(16, 3.4, 0.6), cf * CFrame.new(0, L.WallH + 6, -L.BaseD / 2 + 0.5), Color3.fromRGB(255, 255, 255), Enum.Material.SmoothPlastic, model)
	local signText = label(signPart, "Drawer " .. index .. " - FREE", 34, 0, Color3.fromRGB(40, 40, 60))
	signText.Parent.Name = "SignGui"

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
	buildNightstand(mapFolder)
	buildToys(mapFolder)
	buildDustBunnies(mapFolder)
	buildDryer(mapFolder)
	buildClothesline(mapFolder)
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
	return CFrame.new(L.LineStartX + t, L.LineY - L.HangDrop, 0)
end

function Map.LineLength(): number
	return LAYOUT.LineEndX - LAYOUT.LineStartX
end

return Map
