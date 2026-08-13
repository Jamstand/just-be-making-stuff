-- RegionsService: builds the unlockable biome arenas (Frost Hollow, Magma Depths,
-- Astral Void) offset far from the hub, plus the hub Warp Nexus. Travel is
-- server-authoritative: Touched portal pads teleport the player and gate on their
-- rebirth count. Geode rings inside each arena are built by GeodeService from the
-- same Config.Regions, so this module only owns arena geometry + travel.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Regions = {}
local S, Config
local folder
local lastWarp = {}   -- [player] = os.clock(), debounces portal touches
local HUB_RETURN = CFrame.new(Vector3.new(0, 5, -55), Vector3.new(0, 5, 0))

local function part(props, parent)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	for k, v in pairs(props) do p[k] = v end
	p.Parent = parent
	return p
end

local function pointLight(parent, color, range, brightness)
	local pl = Instance.new("PointLight")
	pl.Color = color
	pl.Range = range
	pl.Brightness = brightness
	pl.Parent = parent
	return pl
end

-- a 3-shard crystal cluster with a glowing core
local function crystalCluster(center, colors, scale, parent)
	for i = 1, 3 do
		local col = colors[((i - 1) % #colors) + 1]
		local h = (4 + math.random() * 5) * scale
		local w = (0.7 + math.random() * 0.6) * scale
		local ang = math.random() * math.pi * 2
		local off = Vector3.new(math.cos(ang) * 1.6 * scale, 0, math.sin(ang) * 1.6 * scale)
		part({
			Size = Vector3.new(w, h, w),
			CFrame = CFrame.new(center + off + Vector3.new(0, h / 2 - 0.5, 0))
				* CFrame.Angles(math.rad(math.random(-16, 16)), math.rad(math.random(0, 360)), math.rad(math.random(-16, 16))),
			Material = Enum.Material.Neon, Color = col,
		}, parent)
	end
	local core = part({
		Shape = Enum.PartType.Ball, Size = Vector3.new(2, 2, 2) * scale,
		CFrame = CFrame.new(center + Vector3.new(0, 1.4 * scale, 0)),
		Material = Enum.Material.Neon, Color = colors[1], Transparency = 0.15,
	}, parent)
	pointLight(core, colors[1], 16 * scale, 1.6)
end

local function themedParticles(kind, center, accent, parent)
	if kind == "none" then return end
	local anchor = part({ Transparency = 1, Size = Vector3.new(70, 1, 70),
		CFrame = CFrame.new(center + Vector3.new(0, 28, 0)) }, parent)
	local pe = Instance.new("ParticleEmitter")
	pe.Parent = anchor
	if kind == "snow" then
		pe.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255))
		pe.Size = NumberSequence.new(0.45)
		pe.Transparency = NumberSequence.new(0.2)
		pe.Lifetime = NumberRange.new(6, 10)
		pe.Rate = 55
		pe.Speed = NumberRange.new(1, 4)
		pe.Acceleration = Vector3.new(2, -7, 0)
		pe.SpreadAngle = Vector2.new(30, 30)
		pe.Rotation = NumberRange.new(0, 360)
	elseif kind == "ember" then
		anchor.CFrame = CFrame.new(center + Vector3.new(0, 2, 0))
		anchor.Size = Vector3.new(80, 1, 80)
		pe.Color = ColorSequence.new(Color3.fromRGB(255, 170, 70), Color3.fromRGB(255, 60, 30))
		pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 0) })
		pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
		pe.Lifetime = NumberRange.new(2.5, 4.5)
		pe.Rate = 60
		pe.Speed = NumberRange.new(5, 11)
		pe.Acceleration = Vector3.new(0, 9, 0)
		pe.LightEmission = 1
		pe.SpreadAngle = Vector2.new(40, 40)
	elseif kind == "star" then
		pe.Color = ColorSequence.new(accent)
		pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.3, 0.5), NumberSequenceKeypoint.new(1, 0) })
		pe.Transparency = NumberSequence.new(0.1)
		pe.Lifetime = NumberRange.new(4, 9)
		pe.Rate = 40
		pe.Speed = NumberRange.new(0.4, 1.6)
		pe.Acceleration = Vector3.new(0, -0.4, 0)
		pe.LightEmission = 1
		pe.SpreadAngle = Vector2.new(180, 180)
	elseif kind == "bubble" then
		anchor.CFrame = CFrame.new(center + Vector3.new(0, 3, 0))
		anchor.Size = Vector3.new(80, 1, 80)
		pe.Color = ColorSequence.new(Color3.fromRGB(180, 245, 255))
		pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 0.7) })
		pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 0.9) })
		pe.Lifetime = NumberRange.new(4, 7)
		pe.Rate = 45
		pe.Speed = NumberRange.new(3, 7)
		pe.Acceleration = Vector3.new(0, 5, 0)
		pe.LightEmission = 0.6
		pe.SpreadAngle = Vector2.new(20, 20)
	end
end

-- floating text sign (title + optional subtitle)
local function sign(parent, pos, title, subtitle, color, scale, alwaysOnTop, maxDist)
	local anchor = part({ Transparency = 1, Size = Vector3.new(1, 1, 1), CFrame = CFrame.new(pos) }, parent)
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromScale(scale, scale * 0.28)
	bb.AlwaysOnTop = alwaysOnTop or false
	bb.MaxDistance = maxDist or 400
	bb.Parent = anchor
	local tl = Instance.new("TextLabel")
	tl.Size = UDim2.fromScale(1, subtitle and 0.66 or 1)
	tl.BackgroundTransparency = 1
	tl.Text = title
	tl.TextColor3 = color
	tl.TextStrokeTransparency = 0.2
	tl.TextScaled = true
	tl.Font = Enum.Font.GothamBlack
	tl.Parent = bb
	if subtitle then
		local s = Instance.new("TextLabel")
		s.Position = UDim2.fromScale(0, 0.66)
		s.Size = UDim2.fromScale(1, 0.34)
		s.BackgroundTransparency = 1
		s.Text = subtitle
		s.TextColor3 = Color3.fromRGB(255, 255, 255)
		s.TextStrokeTransparency = 0.3
		s.TextScaled = true
		s.Font = Enum.Font.GothamBold
		s.Parent = bb
	end
	return anchor
end

-- glowing floor disc + light column + label; returns the touch pad
local function buildPortal(parent, pos, color, title, subtitle)
	local pad = part({
		Shape = Enum.PartType.Cylinder, Size = Vector3.new(1.2, 13, 13),
		CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.rad(90)),
		Material = Enum.Material.Neon, Color = color, Transparency = 0.35,
	}, parent)
	pointLight(pad, color, 24, 2.4)
	TweenService:Create(pad, TweenInfo.new(1.3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Transparency = 0.7 }):Play()
	local column = part({
		Size = Vector3.new(7, 46, 7), CFrame = CFrame.new(pos + Vector3.new(0, 23, 0)),
		Material = Enum.Material.Neon, Color = color, Transparency = 0.86,
	}, parent)
	local att = Instance.new("Attachment"); att.Parent = column
	local pe = Instance.new("ParticleEmitter")
	pe.Color = ColorSequence.new(color); pe.LightEmission = 1
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 0) })
	pe.Transparency = NumberSequence.new(0.3)
	pe.Lifetime = NumberRange.new(1, 2); pe.Rate = 20; pe.Speed = NumberRange.new(6, 12)
	pe.Acceleration = Vector3.new(0, 6, 0); pe.SpreadAngle = Vector2.new(14, 14)
	pe.Parent = att
	sign(parent, pos + Vector3.new(0, 7.5, 0), title, subtitle, color, 15, true, 150)
	return pad
end

local function makeWarp(pad, handler)
	pad.Touched:Connect(function(hit)
		local player = Players:GetPlayerFromCharacter(hit and hit.Parent)
		if not player then return end
		if lastWarp[player] and os.clock() - lastWarp[player] < 2 then return end
		handler(player)
	end)
end

function Regions.Warp(player, key)
	local region = Config.RegionByKey(key)
	if not region then return end
	local p = S.Data.Cache[player]
	if not region.isHub and not Config.Zones.IsUnlocked(region, Config.Zones.StatsFor(p)) then
		lastWarp[player] = os.clock()
		local prog = Config.Zones.Progress(region, Config.Zones.StatsFor(p))
		S.Remotes.Announce:FireClient(player, {
			kind = "warn",
			text = "🔒 " .. region.icon .. " " .. region.name .. " — " .. prog.text .. " (" .. prog.label .. ")",
			color = Color3.fromRGB(255, 180, 120),
		})
		return
	end
	local char = player.Character
	if not (char and char:FindFirstChild("HumanoidRootPart")) then return end
	lastWarp[player] = os.clock()
	char:PivotTo(region.isHub and HUB_RETURN or region._arrival)
	S.Remotes.Announce:FireClient(player, {
		kind = "region",
		text = region.icon .. " Welcome to " .. region.name .. "!",
		color = region.theme.accent,
	})
end

local function buildArena(region)
	local root = Instance.new("Folder"); root.Name = region.key; root.Parent = folder
	local theme, c = region.theme, region.center
	local R = region.radius + 14

	-- floor disc
	part({
		Shape = Enum.PartType.Cylinder, Size = Vector3.new(2, R * 2, R * 2),
		CFrame = CFrame.new(c + Vector3.new(0, -1, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Material = theme.floorMaterial, Color = theme.floor, CanCollide = true,
	}, root)

	-- perimeter: themed lip wall (walkable barrier) + invisible tall fence (anti-void)
	local segs = 26
	for i = 1, segs do
		local a = (i / segs) * math.pi * 2
		local seg = (R * 2 * math.pi / segs) + 1.5
		part({
			Size = Vector3.new(seg, 10, 3),
			CFrame = CFrame.new(c + Vector3.new(math.cos(a) * R, 4, math.sin(a) * R)) * CFrame.Angles(0, -a + math.pi / 2, 0),
			Material = theme.wallMaterial, Color = theme.rock, CanCollide = true,
		}, root)
		part({
			Size = Vector3.new(seg, 40, 1),
			CFrame = CFrame.new(c + Vector3.new(math.cos(a) * (R + 1), 24, math.sin(a) * (R + 1))) * CFrame.Angles(0, -a + math.pi / 2, 0),
			Transparency = 1, CanCollide = true,
		}, root)
	end

	-- perimeter crystal clusters + central hero cluster
	for i = 1, 10 do
		local a = (i / 10) * math.pi * 2 + 0.3
		crystalCluster(c + Vector3.new(math.cos(a) * (region.radius + 6), 0, math.sin(a) * (region.radius + 6)), theme.crystals, 1.4, root)
	end
	crystalCluster(c, theme.crystals, 3, root)

	-- ambient fill lights
	for i = 1, 4 do
		local a = (i / 4) * math.pi * 2
		local lp = part({ Transparency = 1, Size = Vector3.new(1, 1, 1),
			CFrame = CFrame.new(c + Vector3.new(math.cos(a) * region.radius * 0.55, 12, math.sin(a) * region.radius * 0.55)) }, root)
		pointLight(lp, theme.ambient, 42, 1.3)
	end

	themedParticles(theme.particle, c, theme.accent, root)
	sign(root, c + Vector3.new(0, 30, 0), region.icon .. " " .. region.name, nil, theme.accent, 34, false, 500)

	-- arrival spot + return portal (offset laterally so you don't instantly re-warp)
	local arrivalPos = c + Vector3.new(0, 0.4, -(region.radius + 8))
	region._arrival = CFrame.new(arrivalPos + Vector3.new(0, 4, 0), c)
	local retPad = buildPortal(root, c + Vector3.new(16, 0.6, -(region.radius + 8)), theme.accent, "↩ Return to Cavern", "Home")
	makeWarp(retPad, function(pl) Regions.Warp(pl, "Cavern") end)
end

local function buildHubNexus()
	local root = Instance.new("Folder"); root.Name = "WarpNexus"; root.Parent = folder
	local base = Vector3.new(54, 0, -72)
	part({
		Shape = Enum.PartType.Cylinder, Size = Vector3.new(1.5, 44, 44),
		CFrame = CFrame.new(base + Vector3.new(0, -0.3, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Material = Enum.Material.Slate, Color = Color3.fromRGB(42, 38, 60), CanCollide = true,
	}, root)
	pointLight(part({ Transparency = 1, Size = Vector3.new(1, 1, 1), CFrame = CFrame.new(base + Vector3.new(0, 8, 0)) }, root),
		Color3.fromRGB(180, 140, 255), 40, 1.4)
	sign(root, base + Vector3.new(0, 17, 0), "🌀 WARP NEXUS", "Travel to unlocked biomes", Color3.fromRGB(195, 155, 255), 20, false, 300)

	local nonHub = {}
	for _, r in ipairs(Config.Regions) do
		if not r.isHub then nonHub[#nonHub + 1] = r end
	end
	for i, r in ipairs(nonHub) do
		local zoff = (i - (#nonHub + 1) / 2) * 14
		local pad = buildPortal(root, base + Vector3.new(0, 0.6, zoff), r.theme.accent, r.icon .. " " .. r.name, Config.Zones.UnlockText(r))
		pad:SetAttribute("ZoneKey", r.key) -- client NexusFX reads this to build the teasing card
		local key = r.key
		makeWarp(pad, function(pl) Regions.Warp(pl, key) end)
	end
end

function Regions.Init(services)
	S = services
	Config = S.Config
	folder = Instance.new("Folder")
	folder.Name = "Regions"
	folder.Parent = workspace.CrackAGeode

	for _, region in ipairs(Config.Regions) do
		if not region.isHub then buildArena(region) end
	end
	buildHubNexus()

	Players.PlayerRemoving:Connect(function(pl) lastWarp[pl] = nil end)

	-- safety net: anything that falls into the void returns to the hub
	task.spawn(function()
		while true do
			task.wait(1)
			for _, pl in ipairs(Players:GetPlayers()) do
				local hrp = pl.Character and pl.Character:FindFirstChild("HumanoidRootPart")
				if hrp and hrp.Position.Y < -60 then
					Regions.Warp(pl, "Cavern")
				end
			end
		end
	end)
end

return Regions
