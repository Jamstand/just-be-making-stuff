-- DecorService: dresses the hub cavern with environment detail so it reads full
-- and the eye is led to the crater. Adds radial glowing floor veins converging on
-- the crater (the focal point), a framing ring of crystal obelisks + a central
-- beacon, a lit path from spawn to the crater, scattered + wall crystal clusters,
-- stalagmites, and drifting dust motes. All decor is non-colliding so it never
-- blocks movement or cracking. Placement avoids spawn, gardens, pedestals, the
-- warp nexus, the spawn->crater path, and the cracking annulus.

local TweenService = game:GetService("TweenService")

local Decor = {}
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

local function light(parent, color, range, bright)
	local pl = Instance.new("PointLight")
	pl.Color = color; pl.Range = range; pl.Brightness = bright; pl.Shadows = false
	pl.Parent = parent
	return pl
end

-- a neon crystal cluster of `scale` (varied shard count); optional floor light
local function cluster(center, colors, scale, withLight, parent)
	local shards = math.clamp(math.floor(2 + scale * 1.4), 2, 8)
	for _ = 1, shards do
		local col = colors[math.random(#colors)]
		local h = (3 + math.random() * 4) * scale
		local w = (0.45 + math.random() * 0.5) * math.sqrt(scale)
		local ang = math.random() * math.pi * 2
		local rad = math.random() * 1.7 * scale
		part({
			Size = Vector3.new(w, h, w),
			CFrame = CFrame.new(center + Vector3.new(math.cos(ang) * rad, h / 2 - 0.4, math.sin(ang) * rad))
				* CFrame.Angles(math.rad(math.random(-22, 22)), math.rad(math.random(0, 360)), math.rad(math.random(-22, 22))),
			Material = Enum.Material.Neon, Color = col,
		}, parent)
	end
	if withLight then
		local core = part({ Shape = Enum.PartType.Ball, Size = Vector3.new(1.1, 1.1, 1.1) * scale,
			CFrame = CFrame.new(center + Vector3.new(0, 1.1 * scale, 0)), Material = Enum.Material.Neon,
			Color = colors[1], Transparency = 0.5 }, parent)
		light(core, colors[1], 5.5 * scale, 0.8)
	end
end

-- a rocky floor spike (two 45°-rotated blocks tapering up) with a glowing tip
local function stalagmite(base, height, rock, tip, parent)
	local h1, h2 = height * 0.58, height * 0.5
	part({ Size = Vector3.new(3.0, h1, 3.0), CFrame = CFrame.new(base + Vector3.new(0, h1 / 2, 0)) * CFrame.Angles(0, math.rad(45), 0),
		Material = Enum.Material.Slate, Color = rock }, parent)
	part({ Size = Vector3.new(1.6, h2, 1.6), CFrame = CFrame.new(base + Vector3.new(0, h1 + h2 / 2 - 0.5, 0)) * CFrame.Angles(0, math.rad(45), 0),
		Material = Enum.Material.Slate, Color = rock }, parent)
	part({ Shape = Enum.PartType.Ball, Size = Vector3.new(1.1, 1.7, 1.1), CFrame = CFrame.new(base + Vector3.new(0, h1 + h2 - 0.4, 0)),
		Material = Enum.Material.Neon, Color = tip, Transparency = 0.1 }, parent)
end

-- a flat glowing strip on the floor from a to b
local function veinSeg(a, b, color, width, transparency, parent)
	local mid = (a + b) / 2
	local len = (b - a).Magnitude
	if len < 0.1 then return end
	part({
		Size = Vector3.new(width, 0.12, len),
		CFrame = CFrame.lookAt(Vector3.new(mid.X, 0.07, mid.Z), Vector3.new(b.X, 0.07, b.Z)),
		Material = Enum.Material.Neon, Color = color, Transparency = transparency,
	}, parent)
end

-- an organic radial energy vein from the crater outward (jittered, fading)
local function radialVein(angle, innerR, outerR, color, parent)
	local pts = {}
	for i = 0, 3 do
		local r = innerR + (outerR - innerR) * (i / 3)
		local ja = angle + (math.random() - 0.5) * 0.18
		pts[i + 1] = Vector3.new(math.cos(ja) * r, 0, math.sin(ja) * r)
	end
	for i = 1, 3 do
		veinSeg(pts[i], pts[i + 1], color, 1.4 - (i - 1) * 0.35, 0.2 + (i - 1) * 0.22, parent)
	end
end

function Decor.Init(services)
	S = services
	Config = S.Config
	local cg = workspace.CrackAGeode
	if cg:FindFirstChild("Decor") then return end -- baked into the place; skip runtime regeneration
	folder = Instance.new("Folder"); folder.Name = "Decor"; folder.Parent = cg

	local theme = Config.RegionByKey("Cavern").theme
	local cr = theme.crystals
	local palette = { cr[1], cr[2], cr[3], Color3.fromRGB(210, 120, 255) }
	local veinColor = Color3.fromRGB(130, 200, 255)
	local rock = theme.rock

	-- keep-out points
	local keepouts = {}
	local function addKeep(v) if v then keepouts[#keepouts + 1] = Vector3.new(v.X, 0, v.Z) end end
	local spawn = workspace:FindFirstChildOfClass("SpawnLocation")
	if spawn then addKeep(spawn.Position) end
	addKeep(Vector3.new(54, 0, -72)) -- warp nexus
	local gardens = cg:FindFirstChild("Gardens")
	if gardens then for _, st in ipairs(gardens:GetChildren()) do local b = st:FindFirstChild("Base"); if b then addKeep(b.Position) end end end
	for _, nm in ipairs({ "UpgradePedestal", "AscensionAltar", "PedestalColumn", "PedestalBase" }) do
		local pp = cg.Map:FindFirstChild(nm); if pp then addKeep(pp.Position) end
	end

	local function blocked(pos, clearance)
		local r = math.sqrt(pos.X * pos.X + pos.Z * pos.Z)
		if r > 14 and r < 53 then return true end                       -- keep the cracking annulus clear
		if math.abs(pos.X) < 10 and pos.Z < -46 and pos.Z > -78 then return true end -- spawn->crater path
		for _, k in ipairs(keepouts) do
			if (k - Vector3.new(pos.X, 0, pos.Z)).Magnitude < (clearance or 13) then return true end
		end
		return false
	end

	-- 1) radial energy veins converging on the crater
	for i = 1, 16 do
		radialVein((i / 16) * math.pi * 2, 15, 50, veinColor, folder)
	end

	-- 2) framing ring of crystal obelisks just outside the node ring
	for i = 1, 14 do
		local a = (i / 14) * math.pi * 2
		local pos = Vector3.new(math.cos(a) * 55, 0, math.sin(a) * 55)
		if not blocked(pos, 10) then cluster(pos, palette, 2.0, true, folder) end
	end

	-- 3) central beacon = the obvious focal point
	part({ Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.6, 26, 26),
		CFrame = CFrame.new(0, 0.2, 0) * CFrame.Angles(0, 0, math.rad(90)),
		Material = Enum.Material.Neon, Color = veinColor, Transparency = 0.55 }, folder)
	cluster(Vector3.new(0, 0, 0), palette, 2.6, false, folder)
	part({ Size = Vector3.new(2.4, 20, 2.4), CFrame = CFrame.new(0, 10, 0) * CFrame.Angles(0, math.rad(45), 0),
		Material = Enum.Material.Neon, Color = Color3.fromRGB(190, 150, 255) }, folder)
	local core = part({ Shape = Enum.PartType.Ball, Size = Vector3.new(3.4, 3.4, 3.4), CFrame = CFrame.new(0, 20, 0),
		Material = Enum.Material.Neon, Color = Color3.fromRGB(210, 190, 255), Transparency = 0.4 }, folder)
	local pulse = light(core, Color3.fromRGB(200, 180, 255), 44, 1.4)
	TweenService:Create(pulse, TweenInfo.new(2.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Brightness = 2.3 }):Play()

	-- 4) lit path from spawn to the crater (leading line + growing lanterns)
	veinSeg(Vector3.new(0, 0, -70), Vector3.new(0, 0, -50), veinColor, 2.2, 0.25, folder)
	for _, st in ipairs({ { z = -68, s = 0.8 }, { z = -61, s = 1.0 }, { z = -54, s = 1.3 } }) do
		for _, sx in ipairs({ -7, 7 }) do
			cluster(Vector3.new(sx, 0, st.z), palette, st.s, false, folder)
		end
	end

	-- 5) mid-field clusters + stalagmites (between play area and the garden ring)
	for _ = 1, 26 do
		local a = math.random() * math.pi * 2
		local r = 62 + math.random() * 22
		local pos = Vector3.new(math.cos(a) * r, 0, math.sin(a) * r)
		if not blocked(pos, 12) then
			if math.random() < 0.5 then
				cluster(pos, palette, 0.7 + math.random() * 1.1, math.random() < 0.3, folder)
			else
				stalagmite(pos, 6 + math.random() * 7, rock, palette[math.random(#palette)], folder)
			end
		end
	end

	-- 6) big wall clusters + tall stalagmites around the perimeter
	for i = 1, 20 do
		local a = (i / 20) * math.pi * 2 + 0.15
		local r = 112 + math.random() * 14
		local pos = Vector3.new(math.cos(a) * r, 0, math.sin(a) * r)
		if not blocked(pos, 12) then
			if math.random() < 0.55 then
				cluster(pos, palette, 1.8 + math.random() * 1.8, math.random() < 0.4, folder)
			else
				stalagmite(pos, 10 + math.random() * 10, rock, palette[math.random(#palette)], folder)
			end
		end
	end

	-- 7) floating dust / sparkle motes in the air (two drifting layers)
	for _, y in ipairs({ 10, 24 }) do
		local anchor = part({ Transparency = 1, Size = Vector3.new(240, 1, 240), CFrame = CFrame.new(0, y, 0) }, folder)
		local pe = Instance.new("ParticleEmitter")
		pe.Color = ColorSequence.new(Color3.fromRGB(210, 200, 255))
		pe.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		pe.LightEmission = 1
		pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.2, 0.45), NumberSequenceKeypoint.new(0.8, 0.55), NumberSequenceKeypoint.new(1, 1) })
		pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 0.5) })
		pe.Lifetime = NumberRange.new(6, 12)
		pe.Rate = 35
		pe.Speed = NumberRange.new(0.5, 2)
		pe.Acceleration = Vector3.new(0.5, -0.3, 0.2)
		pe.SpreadAngle = Vector2.new(180, 180)
		pe.Rotation = NumberRange.new(0, 360)
		pe.Parent = anchor
	end
end

return Decor
