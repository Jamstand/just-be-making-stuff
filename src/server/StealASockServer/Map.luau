-- Map: builds the whole laundromat blockout from Parts at startup so the entire game lives in
-- git. Every piece is tagged with CollectionService so real models can replace it later.
-- Layout numbers live in Map.Layout; Base/Clothesline read them instead of hard-coding.
local CollectionService = game:GetService("CollectionService")

local Map = {}
local S

local LAYOUT = {
	FloorX = 420,
	FloorZ = 260,
	Tile = 20,
	WallHeight = 40,
	LineY = 10, -- clothesline rail height
	LineStartX = -150,
	LineEndX = 150,
	HangDrop = 2.9, -- sock pivot sits this far under the rail
	DryerX = -178,
	LintX = 172,
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

local COLOR_LIGHT = Color3.fromRGB(240, 240, 248)
local COLOR_TEAL = Color3.fromRGB(70, 180, 190)
local COLOR_WOOD = Color3.fromRGB(196, 146, 92)
local COLOR_DRAWER = Color3.fromRGB(230, 196, 140)

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

local function label(adornee: BasePart, text: string, size: number, offsetY: number, color: Color3?): TextLabel
	local gui = Instance.new("BillboardGui")
	gui.Name = "Label"
	gui.Adornee = adornee
	gui.Size = UDim2.fromOffset(260, 60)
	gui.StudsOffset = Vector3.new(0, offsetY, 0)
	gui.MaxDistance = 140
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

local function buildFloor(folder: Folder)
	local L = LAYOUT
	local nx = L.FloorX / L.Tile
	local nz = L.FloorZ / L.Tile
	local floorFolder = Instance.new("Folder")
	floorFolder.Name = "Floor"
	floorFolder.Parent = folder
	for ix = 0, nx - 1 do
		for iz = 0, nz - 1 do
			local x = -L.FloorX / 2 + L.Tile / 2 + ix * L.Tile
			local z = -L.FloorZ / 2 + L.Tile / 2 + iz * L.Tile
			local color = if (ix + iz) % 2 == 0 then COLOR_LIGHT else COLOR_TEAL
			part("Tile", Vector3.new(L.Tile, 1, L.Tile), CFrame.new(x, -0.5, z), color, nil, floorFolder, "MapFloor")
		end
	end
	-- outer walls (see-through so the camera never gets stuck)
	local h = L.WallHeight
	local wallColor = Color3.fromRGB(255, 225, 235)
	local function wall(name, size, cf)
		local w = part(name, size, cf, wallColor, Enum.Material.SmoothPlastic, folder, "MapWall")
		w.Transparency = 0.6
	end
	wall("WallNorth", Vector3.new(L.FloorX, h, 2), CFrame.new(0, h / 2, -L.FloorZ / 2 - 1))
	wall("WallSouth", Vector3.new(L.FloorX, h, 2), CFrame.new(0, h / 2, L.FloorZ / 2 + 1))
	wall("WallWest", Vector3.new(2, h, L.FloorZ + 4), CFrame.new(-L.FloorX / 2 - 1, h / 2, 0))
	wall("WallEast", Vector3.new(2, h, L.FloorZ + 4), CFrame.new(L.FloorX / 2 + 1, h / 2, 0))
end

local function buildDryer(folder: Folder)
	local L = LAYOUT
	local body = part("DryerBody", Vector3.new(16, 18, 18), CFrame.new(L.DryerX, 9, 0), Color3.fromRGB(225, 228, 235), Enum.Material.Metal, folder, "Dryer")
	local rim = part("DryerRim", Vector3.new(1, 14, 14), CFrame.new(L.DryerX + 8.4, 9, 0), Color3.fromRGB(40, 40, 50), Enum.Material.Metal, folder, "Dryer")
	rim.Shape = Enum.PartType.Cylinder
	local drum = part("DryerDrum", Vector3.new(0.8, 12, 12), CFrame.new(L.DryerX + 8.9, 9, 0), Color3.fromRGB(120, 80, 200), Enum.Material.Glass, folder, "Dryer")
	drum.Shape = Enum.PartType.Cylinder
	drum.Transparency = 0.35
	local swirl = part("DryerSwirl", Vector3.new(9, 9, 9), CFrame.new(L.DryerX + 6, 9, 0), Color3.fromRGB(170, 90, 255), Enum.Material.Neon, folder, "Dryer")
	swirl.Shape = Enum.PartType.Ball
	swirl.Transparency = 0.2
	local knob = part("DryerKnob", Vector3.new(2, 2, 1), CFrame.new(L.DryerX + 8.5, 16, -5), Color3.fromRGB(255, 80, 80), Enum.Material.SmoothPlastic, folder, "Dryer")
	label(body, "THE GREAT DRYER", 34, 15, Color3.fromRGB(255, 240, 120))
	Map.Dryer.Body = body
	Map.Dryer.Drum = drum
	Map.Dryer.Swirl = swirl
	Map.Dryer.Knob = knob
end

local function buildClothesline(folder: Folder)
	local L = LAYOUT
	local length = L.LineEndX - L.LineStartX
	part("Rail", Vector3.new(length, 0.35, 0.35), CFrame.new((L.LineStartX + L.LineEndX) / 2, L.LineY, 0), Color3.fromRGB(240, 240, 240), Enum.Material.SmoothPlastic, folder, "Clothesline")
	part("PostWest", Vector3.new(1, L.LineY, 1), CFrame.new(L.LineStartX, L.LineY / 2, 0), COLOR_WOOD, Enum.Material.Wood, folder, "Clothesline")
	part("PostEast", Vector3.new(1, L.LineY, 1), CFrame.new(L.LineEndX, L.LineY / 2, 0), COLOR_WOOD, Enum.Material.Wood, folder, "Clothesline")
	-- Lint Trap: unbought socks fall in here and despawn
	local trap = part("LintTrap", Vector3.new(12, 6, 12), CFrame.new(L.LintX, 3, 0), Color3.fromRGB(120, 120, 130), Enum.Material.Fabric, folder, "LintTrap")
	trap.CanCollide = true
	local lint = part("LintPile", Vector3.new(10, 2, 10), CFrame.new(L.LintX, 6.5, 0), Color3.fromRGB(170, 170, 175), Enum.Material.Fabric, folder, "LintTrap")
	lint.CanCollide = false
	label(trap, "LINT TRAP", 28, 7, Color3.fromRGB(200, 200, 210))
end

local function buildDustBunnies(folder: Folder)
	local spots = { { -90, -30 }, { 60, -40 }, { 150, 40 }, { -160, 50 }, { 0, -100 }, { 100, 100 }, { -60, 110 }, { 180, -90 } }
	for i, s in ipairs(spots) do
		local size = 4 + (i % 3) * 1.5
		local b = part("DustBunny", Vector3.new(size, size, size), CFrame.new(s[1], size / 2, s[2]), Color3.fromRGB(150, 150, 150), Enum.Material.Fabric, folder, "DustBunny")
		b.Shape = Enum.PartType.Ball
		b.CanCollide = false
	end
end

-- One base = one open dresser drawer. Local space: origin at the drawer floor centre (y = 0 is
-- the map floor), +Z points out of the drawer toward the clothesline.
local function buildBase(index: number, x: number, z: number, folder: Folder): Model
	local L = LAYOUT
	local facing = if z > 0 then math.pi else 0
	local cf = CFrame.new(x, 0, z) * CFrame.Angles(0, facing, 0)
	local model = Instance.new("Model")
	model.Name = "Base_" .. index
	model:SetAttribute("Index", index)
	CollectionService:AddTag(model, "Base")

	local floor = part("Floor", Vector3.new(L.BaseW, 1, L.BaseD), cf * CFrame.new(0, 0.5, 0), COLOR_DRAWER, Enum.Material.Wood, model)
	model.PrimaryPart = floor
	local wallColor = Color3.fromRGB(190, 140, 90)
	part("BackWall", Vector3.new(L.BaseW, L.WallH, 1), cf * CFrame.new(0, 1 + L.WallH / 2, -L.BaseD / 2 + 0.5), wallColor, Enum.Material.Wood, model)
	part("LeftWall", Vector3.new(1, L.WallH, L.BaseD), cf * CFrame.new(-L.BaseW / 2 + 0.5, 1 + L.WallH / 2, 0), wallColor, Enum.Material.Wood, model)
	part("RightWall", Vector3.new(1, L.WallH, L.BaseD), cf * CFrame.new(L.BaseW / 2 - 0.5, 1 + L.WallH / 2, 0), wallColor, Enum.Material.Wood, model)
	part("FrontLip", Vector3.new(L.BaseW, 1.5, 1), cf * CFrame.new(0, 1.75, L.BaseD / 2 - 0.5), wallColor, Enum.Material.Wood, model)
	-- Handle (decor) on the front lip
	part("Handle", Vector3.new(10, 1, 1), cf * CFrame.new(0, 1.75, L.BaseD / 2 + 0.6), Color3.fromRGB(220, 200, 80), Enum.Material.Metal, model)

	-- Shutter: rises out of the floor when the drawer is slammed (Base moves it).
	local shutter = part("Shutter", Vector3.new(L.BaseW, L.WallH, 1), cf * CFrame.new(0, 1 + L.WallH / 2, L.BaseD / 2 - 0.5), Color3.fromRGB(120, 80, 50), Enum.Material.Wood, model)
	shutter:SetAttribute("ClosedY", shutter.Position.Y)
	shutter.CFrame = shutter.CFrame - Vector3.new(0, L.WallH + 2, 0)
	shutter.Transparency = 1
	shutter.CanCollide = false

	-- Slots
	local slots = Instance.new("Folder")
	slots.Name = "Slots"
	slots.Parent = model
	local total = S.Config.Economy.BaseSlots
	for i = 1, total do
		local row = math.ceil(i / L.SlotCols)
		local col = (i - 1) % L.SlotCols + 1
		local sx = (col - (L.SlotCols + 1) / 2) * L.SlotSpacingX
		local sz = L.SlotRowZ[row] or (L.SlotRowZ[#L.SlotRowZ] - (row - #L.SlotRowZ) * 10)
		local slot = part("Slot_" .. i, Vector3.new(L.SlotSize, 0.6, L.SlotSize), cf * CFrame.new(sx, 1.3, sz), Color3.fromRGB(250, 235, 200), Enum.Material.SmoothPlastic, slots, "SockSlot")
		slot:SetAttribute("Index", i)
	end

	-- Collect pad (inside, near the front)
	local pad = part("CollectPad", Vector3.new(10, 0.3, 5), cf * CFrame.new(0, 1.15, 11), Color3.fromRGB(80, 230, 120), Enum.Material.Neon, model, "CollectPad")
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
	part("ButtonBase", Vector3.new(3, 2, 3), cf * CFrame.new(-19, 2, -12), Color3.fromRGB(60, 60, 70), Enum.Material.Metal, model)
	local button = part("SlamButton", Vector3.new(0.6, 2.4, 2.4), cf * CFrame.new(-19, 3.3, -12) * CFrame.Angles(0, 0, math.pi / 2), Color3.fromRGB(240, 60, 60), Enum.Material.Neon, model, "SlamButton")
	button.Shape = Enum.PartType.Cylinder
	label(button, "SLAM", 20, 2, Color3.fromRGB(255, 120, 120))

	-- Sign above the back wall
	local signPart = part("Sign", Vector3.new(14, 3, 0.5), cf * CFrame.new(0, L.WallH + 6, -L.BaseD / 2 + 0.5), Color3.fromRGB(255, 255, 255), Enum.Material.SmoothPlastic, model)
	local signText = label(signPart, "Drawer " .. index .. " - FREE", 34, 0, Color3.fromRGB(40, 40, 60))
	signText.Parent.Name = "SignGui"

	model.Parent = folder
	return model
end

local function buildSpawn(folder: Folder)
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "Spawn"
	spawn.Size = Vector3.new(10, 1, 10)
	spawn.CFrame = CFrame.new(0, 0.5, LAYOUT.SpawnZ)
	spawn.Anchored = true
	spawn.Color = Color3.fromRGB(255, 220, 120)
	spawn.Duration = 0
	spawn.Parent = folder
end

function Map.Init(s)
	S = s
	local root = Instance.new("Folder")
	root.Name = "StealASock"
	Map.Root = root
	for _, name in ipairs({ "Map", "Bases", "Line", "Drawer", "Carried" }) do
		local f = Instance.new("Folder")
		f.Name = name
		f.Parent = root
		Map.Folders[name] = f
	end
	local mapFolder = Map.Folders.Map
	buildFloor(mapFolder)
	buildDryer(mapFolder)
	buildClothesline(mapFolder)
	buildDustBunnies(mapFolder)
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
