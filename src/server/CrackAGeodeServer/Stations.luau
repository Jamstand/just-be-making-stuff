-- StationsService: makes every hub station readable at a glance.
--   * brightens the leaderboard text (adds outlines so names/values pop at range)
--   * gives each station a color identity: a floating icon+label marker and a
--     matching glowing floor pad
--   * raises a soft light shaft + "CRACK GEODES" marker over the crater so a new
--     player instantly sees where to go.
-- Runs after Decor; purely cosmetic, all non-colliding.

local TweenService = game:GetService("TweenService")

local Stations = {}
local S, Config
local folder

local function part(props, parent)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CastShadow = false
	for k, v in pairs(props) do p[k] = v end
	p.Parent = parent
	return p
end

-- floating icon + name that reads from a distance (bobs gently, ignores world light)
local function marker(pos, icon, name, color, scale, maxDist, parent)
	local anchor = part({ Transparency = 1, Size = Vector3.new(1, 1, 1), CFrame = CFrame.new(pos) }, parent)
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromScale(scale, scale * 0.5)
	bb.LightInfluence = 0
	bb.MaxDistance = maxDist
	bb.Parent = anchor
	local ic = Instance.new("TextLabel")
	ic.Size = UDim2.fromScale(1, 0.64); ic.BackgroundTransparency = 1
	ic.Text = icon; ic.TextScaled = true; ic.Font = Enum.Font.GothamBlack
	ic.TextColor3 = Color3.fromRGB(255, 255, 255)
	ic.TextStrokeColor3 = color; ic.TextStrokeTransparency = 0.1
	ic.Parent = bb
	local nm = Instance.new("TextLabel")
	nm.Position = UDim2.fromScale(0, 0.64); nm.Size = UDim2.fromScale(1, 0.36); nm.BackgroundTransparency = 1
	nm.Text = name; nm.TextScaled = true; nm.Font = Enum.Font.GothamBlack
	nm.TextColor3 = color; nm.TextStrokeColor3 = Color3.fromRGB(0, 0, 0); nm.TextStrokeTransparency = 0.3
	nm.Parent = bb
	TweenService:Create(bb, TweenInfo.new(1.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ StudsOffset = Vector3.new(0, 0.9, 0) }):Play()
	return anchor
end

-- a glowing colored disc on the floor = the station's color identity from afar
local function pad(x, z, color, withLight, parent)
	local d = part({ Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.4, 9, 9),
		CFrame = CFrame.new(x, 0.15, z) * CFrame.Angles(0, 0, math.rad(90)),
		Material = Enum.Material.Neon, Color = color, Transparency = 0.5 }, parent)
	if withLight then
		local pl = Instance.new("PointLight")
		pl.Color = color; pl.Range = 20; pl.Brightness = 1.0; pl.Shadows = false; pl.Parent = d
	end
end

local function brightenBoards(cg)
	local boards = cg:FindFirstChild("Boards")
	if not boards then return end
	for _, nm in ipairs({ "TopGems", "TopRebirths", "RarityFeed" }) do
		local b = boards:FindFirstChild(nm)
		local gui = b and b:FindFirstChildOfClass("SurfaceGui")
		if gui then
			gui.Brightness = 3.2
			gui.PixelsPerStud = 48
			local title = gui:FindFirstChild("Title")
			local list = gui:FindFirstChild("List")
			if title then
				title.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
				title.TextStrokeTransparency = 0
			end
			if list then
				list.TextColor3 = Color3.fromRGB(246, 247, 255)
				list.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
				list.TextStrokeTransparency = 0
				list.Font = Enum.Font.GothamBold
			end
		end
	end
end

-- soft vertical light shaft + real downward spotlight + "go here" marker over the crater
local function geodeBeacon(parent)
	local col = Color3.fromRGB(150, 212, 255)
	local bright = Color3.fromRGB(215, 238, 255)
	local outer = part({ Shape = Enum.PartType.Cylinder, Size = Vector3.new(56, 22, 22),
		CFrame = CFrame.new(0, 28, 0) * CFrame.Angles(0, 0, math.rad(90)),
		Material = Enum.Material.Neon, Color = col, Transparency = 0.92 }, parent)
	part({ Shape = Enum.PartType.Cylinder, Size = Vector3.new(56, 7, 7),
		CFrame = CFrame.new(0, 28, 0) * CFrame.Angles(0, 0, math.rad(90)),
		Material = Enum.Material.Neon, Color = bright, Transparency = 0.82 }, parent)
	TweenService:Create(outer, TweenInfo.new(2.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Transparency = 0.97 }):Play()
	local orb = part({ Shape = Enum.PartType.Ball, Size = Vector3.new(5, 5, 5), CFrame = CFrame.new(0, 55, 0),
		Material = Enum.Material.Neon, Color = bright, Transparency = 0.25 }, parent)
	local sl = Instance.new("SpotLight")
	sl.Face = Enum.NormalId.Bottom; sl.Angle = 55; sl.Range = 70; sl.Brightness = 2.2; sl.Color = col; sl.Shadows = false
	sl.Parent = orb
	local pl = Instance.new("PointLight"); pl.Color = col; pl.Range = 26; pl.Brightness = 1.4; pl.Shadows = false; pl.Parent = orb
	marker(Vector3.new(0, 15, 0), "⛏️", "CRACK GEODES", col, 13, 1200, parent)
end

function Stations.Init(services)
	S = services
	Config = S.Config
	local cg = workspace.CrackAGeode
	if cg:FindFirstChild("Stations") then return end -- baked into the place; skip runtime regeneration
	folder = Instance.new("Folder"); folder.Name = "Stations"; folder.Parent = cg

	brightenBoards(cg)

	-- leaderboards (gold identity, one marker over the board cluster)
	local boards = cg:FindFirstChild("Boards")
	if boards then
		local sum, n = Vector3.new(0, 0, 0), 0
		for _, nm in ipairs({ "TopGems", "TopRebirths", "RarityFeed" }) do
			local b = boards:FindFirstChild(nm)
			if b then sum = sum + b.Position; n = n + 1 end
		end
		if n > 0 then
			local c = sum / n
			marker(Vector3.new(c.X, c.Y + 8, c.Z), "🏆", "LEADERBOARDS", Color3.fromRGB(255, 205, 90), 8, 500, folder)
			pad(c.X, c.Z, Color3.fromRGB(255, 200, 110), true, folder)
		end
	end

	-- pedestal stations (distinct color identities)
	for _, def in ipairs({
		{ nm = "UpgradePedestal", icon = "⛏️", name = "UPGRADES", color = Color3.fromRGB(255, 165, 70), h = 8 },
		{ nm = "AscensionAltar", icon = "🌌", name = "ASCEND", color = Color3.fromRGB(190, 130, 255), h = 9 },
	}) do
		local p0 = cg.Map:FindFirstChild(def.nm)
		if p0 then
			local p = p0.Position
			marker(Vector3.new(p.X, p.Y + def.h, p.Z), def.icon, def.name, def.color, 7, 450, folder)
			pad(p.X, p.Z, def.color, true, folder)
		end
	end

	-- gardens: green identity pad under each (they already carry name signs)
	local gardens = cg:FindFirstChild("Gardens")
	if gardens then
		for _, st in ipairs(gardens:GetChildren()) do
			local base = st:FindFirstChild("Base")
			if base then pad(base.Position.X, base.Position.Z, Color3.fromRGB(120, 230, 140), false, folder) end
		end
	end

	-- the focal point: light shaft over the geode-cracking area
	geodeBeacon(folder)
end

return Stations
