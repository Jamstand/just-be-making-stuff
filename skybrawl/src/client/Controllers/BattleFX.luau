--[[
    Battlegrounds-style match effects:

      impact       flash, shock ring, debris and dust on a hit (scaled by force)
      impactFrame  a black/white manga frame: the world blows out to white
                   with the fighters as black silhouettes, then flips
      slam         a knockdown: crater, rocks and a dust ring on the ground
      block        a shield flash in front of a blocker
      guardBreak   the shield shattering
      awaken       an aura and glowing outline for the awakening's length
      speedLines   streaks radiating from the middle of the screen

    The Effects setting picks how much of it shows: Full, Reduced (flashes
    and rings, no debris, smoke, impact frames or speed lines) or Off.
    Nothing here affects gameplay.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Legends = require(Shared.Legends)

local Settings = require(script.Parent.Settings)

local BattleFX = {}

local LEVELS = { Full = 2, Reduced = 1, Off = 0 }
local MAX_BITS = 90
local GRAVITY = -70
local FIRE = "rbxasset://textures/particles/fire_main.dds"
local SPARKLE = "rbxasset://textures/particles/sparkles_main.dds"

local folder = nil
local origin = Vector3.zero
local bits = {} -- debris and smoke, moved by hand each frame
local auras = {} -- [model] = { emitter, light, outline, color, ends }
local gui = nil
local colorCorrection = nil
local frameToken = 0
local rng = Random.new()
local stepConn = nil

local function level()
	return LEVELS[Settings.get("Effects") or "Full"] or 2
end

local function worldPos(x, y, z)
	return origin + Vector3.new(x, y, z or 0)
end

local function part(size, cframe, color, shape, material)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = material or Enum.Material.Neon
	p.Color = color
	p.Size = size
	p.CFrame = cframe
	if shape then
		p.Shape = shape
	end
	p.Parent = folder
	return p
end

local function tween(instance, duration, goal, style, direction)
	local t = TweenService:Create(
		instance,
		TweenInfo.new(duration, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out),
		goal
	)
	t:Play()
	return t
end

local function fade(p, duration, endSize, delayDestroy)
	local goal = { Transparency = 1 }
	if endSize then
		goal.Size = endSize
	end
	tween(p, duration, goal)
	task.delay(duration + (delayDestroy or 0.05), function()
		p:Destroy()
	end)
end

-- A flat ring facing the camera (a cylinder whose axis points at the screen).
local function ring(center, radius, color, duration, grow, thickness)
	local cf = CFrame.new(center) * CFrame.Angles(0, math.rad(90), 0)
	local p = part(Vector3.new(thickness or 0.15, radius * 2, radius * 2), cf, color, Enum.PartType.Cylinder)
	p.Transparency = 0.15
	fade(p, duration, Vector3.new(0.05, radius * 2 * grow, radius * 2 * grow))
	return p
end

-- A flat ring lying on the ground.
local function groundRing(center, radius, color, duration, grow)
	local cf = CFrame.new(center) * CFrame.Angles(0, 0, math.rad(90))
	local p = part(Vector3.new(0.12, radius * 2, radius * 2), cf, color, Enum.PartType.Cylinder)
	p.Transparency = 0.3
	fade(p, duration, Vector3.new(0.05, radius * 2 * grow, radius * 2 * grow))
end

-- Hand-moved bits ---------------------------------------------------------------

local function addBit(p, velocity, life, opts)
	if #bits >= MAX_BITS then
		local old = table.remove(bits, 1)
		old.part:Destroy()
	end
	opts = opts or {}
	table.insert(bits, {
		part = p,
		pos = p.Position,
		vel = velocity,
		spin = opts.spin or Vector3.zero,
		rot = p.CFrame - p.Position,
		gravity = opts.gravity or GRAVITY,
		drag = opts.drag or 0,
		life = life,
		age = 0,
		grow = opts.grow,
		size = p.Size,
		fadeFrom = opts.fadeFrom or 0.6,
		alpha = p.Transparency,
		floorY = opts.floorY,
	})
end

local function stepBits(dt)
	local i = 1
	while i <= #bits do
		local b = bits[i]
		b.age += dt
		if b.age >= b.life or not b.part.Parent then
			b.part:Destroy()
			table.remove(bits, i)
			continue
		end
		b.vel += Vector3.new(0, b.gravity * dt, 0)
		if b.drag > 0 then
			b.vel *= math.exp(-b.drag * dt)
		end
		b.pos += b.vel * dt
		if b.floorY and b.pos.Y < b.floorY then
			-- rocks skid to a stop on the ground
			b.pos = Vector3.new(b.pos.X, b.floorY, b.pos.Z)
			b.vel = Vector3.new(b.vel.X * 0.5, math.abs(b.vel.Y) * 0.25, b.vel.Z * 0.5)
			b.spin *= 0.5
		end
		b.rot = b.rot * CFrame.Angles(b.spin.X * dt, b.spin.Y * dt, b.spin.Z * dt)
		local k = b.age / b.life
		b.part.CFrame = CFrame.new(b.pos) * b.rot
		if b.grow then
			b.part.Size = b.size * (1 + b.grow * k)
		end
		if k > b.fadeFrom then
			b.part.Transparency = b.alpha + (1 - b.alpha) * (k - b.fadeFrom) / (1 - b.fadeFrom)
		end
		i += 1
	end
end

local function rocks(center, count, speed, color, floorY)
	for _ = 1, count do
		local s = rng:NextNumber(0.25, 0.6)
		local p = part(
			Vector3.new(s, s * rng:NextNumber(0.6, 1), s),
			CFrame.new(center) * CFrame.Angles(rng:NextNumber(0, 6), rng:NextNumber(0, 6), 0),
			color,
			nil,
			Enum.Material.Slate
		)
		local a = rng:NextNumber(math.rad(25), math.rad(155))
		local v = Vector3.new(math.cos(a) * speed, math.sin(a) * speed, rng:NextNumber(-0.4, 0.4) * speed)
		local spin = Vector3.new(rng:NextNumber(-12, 12), rng:NextNumber(-12, 12), rng:NextNumber(-12, 12))
		addBit(p, v, rng:NextNumber(0.9, 1.5), { spin = spin, floorY = floorY, fadeFrom = 0.7 })
	end
end

local function smoke(center, count, spread, color)
	for _ = 1, count do
		local s = rng:NextNumber(1.2, 2.2)
		local offset = Vector3.new(rng:NextNumber(-spread, spread), rng:NextNumber(0, 0.6), rng:NextNumber(-0.5, 0.5))
		local p =
			part(Vector3.one * s, CFrame.new(center + offset), color, Enum.PartType.Ball, Enum.Material.SmoothPlastic)
		p.Transparency = 0.35
		local dir = offset.Unit
		if offset.Magnitude < 1e-3 then
			dir = Vector3.yAxis
		end
		addBit(p, Vector3.new(dir.X * 9, rng:NextNumber(2, 5), dir.Z * 3), rng:NextNumber(0.6, 1.0), {
			gravity = 3,
			drag = 3.5,
			grow = 1.4,
			fadeFrom = 0.1,
		})
	end
end

-- Screen overlays ------------------------------------------------------------------

local function screenGui()
	if gui and gui.Parent then
		return gui
	end
	local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return nil
	end
	gui = Instance.new("ScreenGui")
	gui.Name = "SkybrawlBattleFX"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 5
	gui.Parent = playerGui
	return gui
end

local function getColorCorrection()
	if not colorCorrection or not colorCorrection.Parent then
		colorCorrection = Instance.new("ColorCorrectionEffect")
		colorCorrection.Name = "SkybrawlImpactFrame"
		colorCorrection.Enabled = false
		colorCorrection.Parent = Lighting
	end
	return colorCorrection
end

-- Effects --------------------------------------------------------------------------

--[[
    A hit at (x, y). force is the knockback force; opts:
      color     the flash color
      ground    the floor height under the hit, for rocks to land on
      big       an ultimate (or other cinematic) hit
]]
function BattleFX.impact(x, y, force, opts)
	local lvl = level()
	if not folder or lvl == 0 then
		return
	end
	opts = opts or {}
	force = force or 0
	local center = worldPos(x, y, 1.6)
	local strength = math.clamp(force / 100, 0.15, 1.6) + (opts.big and 0.8 or 0)
	local color = opts.color or Color3.fromRGB(255, 240, 200)
	ring(center, 0.8 + strength * 1.2, color, 0.18 + strength * 0.08, 3)
	if strength > 0.55 then
		ring(center, 0.6 + strength, Color3.new(1, 1, 1), 0.28, 4.5, 0.08)
	end
	if lvl < 2 then
		return
	end
	if strength > 0.45 then
		local n = math.floor(4 + strength * 6)
		rocks(center, n, 14 + strength * 16, Color3.fromRGB(120, 112, 104), opts.ground and worldPos(0, opts.ground).Y)
		smoke(center, math.floor(2 + strength * 3), 1.2, Color3.fromRGB(225, 220, 212))
	end
	-- streaks flying out the far side of the hit
	for _ = 1, math.floor(3 + strength * 5) do
		local a = rng:NextNumber(0, math.pi * 2)
		local dir = Vector3.new(math.cos(a), math.sin(a), 0)
		local len = rng:NextNumber(1.5, 3) * (0.6 + strength)
		local p = part(Vector3.new(0.12, 0.12, len), CFrame.lookAt(center, center + dir), color)
		tween(p, 0.16, { CFrame = CFrame.lookAt(center + dir * len * 1.6, center + dir * len * 3), Transparency = 1 })
		task.delay(0.2, function()
			p:Destroy()
		end)
	end
end

--[[
    A black/white manga impact frame for `duration` seconds. models are the
    fighters to show as silhouettes (attacker and victim).
]]
function BattleFX.impactFrame(models, duration)
	if level() < 2 then
		return
	end
	duration = duration or 0.14
	frameToken += 1
	local token = frameToken
	local cc = getColorCorrection()
	cc.Enabled = true
	cc.Saturation = -1
	cc.Contrast = 1
	cc.Brightness = 0.75
	cc.TintColor = Color3.new(1, 1, 1)
	local lights = {}
	for _, model in models or {} do
		if model and model.Parent then
			local outline = model:FindFirstChild("SkyOutline")
			if outline then
				outline.Enabled = false
			end
			local h = Instance.new("Highlight")
			h.Name = "SkyImpactFrame"
			h.FillColor = Color3.new(0, 0, 0)
			h.FillTransparency = 0
			h.OutlineColor = Color3.new(1, 1, 1)
			h.OutlineTransparency = 0
			h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			h.Adornee = model:FindFirstChild("VisualRig") or model
			h.Parent = model
			table.insert(lights, { h = h, outline = outline })
		end
	end
	-- second half: flip to white silhouettes on a black world
	task.delay(duration * 0.5, function()
		if token ~= frameToken then
			return
		end
		cc.Brightness = -0.6
		cc.Contrast = 1.5
		for _, l in lights do
			l.h.FillColor = Color3.new(1, 1, 1)
			l.h.OutlineColor = Color3.new(0, 0, 0)
		end
	end)
	task.delay(duration, function()
		for _, l in lights do
			l.h:Destroy()
			if l.outline and l.outline.Parent then
				l.outline.Enabled = true
			end
		end
		if token == frameToken then
			cc.Enabled = false
		end
	end)
end

-- A fighter slammed into the ground at (x, y): crater, rocks, a dust ring.
function BattleFX.slam(x, y, strength)
	local lvl = level()
	if not folder or lvl == 0 then
		return
	end
	strength = strength or 1
	local ground = worldPos(x, y, 0)
	groundRing(ground + Vector3.new(0, 0.1, 0), 1.2, Color3.fromRGB(240, 235, 225), 0.3, 3.5 * strength)
	if lvl < 2 then
		return
	end
	-- the crater: a dark scorched disc ringed with tilted slabs
	local radius = 1.6 + strength
	local disc = part(
		Vector3.new(0.08, radius * 2, radius * 2),
		CFrame.new(ground + Vector3.new(0, 0.04, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color3.fromRGB(58, 52, 48),
		Enum.PartType.Cylinder,
		Enum.Material.Slate
	)
	disc.Transparency = 0.15
	local slabs = { disc }
	for k = 1, 8 do
		local a = k / 8 * math.pi * 2 + rng:NextNumber(-0.2, 0.2)
		local pos = ground + Vector3.new(math.cos(a) * radius, 0.2, math.sin(a) * radius * 0.7)
		local s = rng:NextNumber(0.5, 0.9) * (0.7 + strength * 0.3)
		local slab = part(
			Vector3.new(s * 1.4, s * 0.35, s),
			CFrame.lookAt(pos, ground) * CFrame.Angles(math.rad(rng:NextNumber(20, 40)), 0, 0),
			Color3.fromRGB(110, 102, 96),
			nil,
			Enum.Material.Slate
		)
		table.insert(slabs, slab)
	end
	task.delay(2.2, function()
		for _, p in slabs do
			fade(p, 0.8)
		end
	end)
	rocks(ground + Vector3.new(0, 0.5, 0), math.floor(5 + strength * 4), 16, Color3.fromRGB(120, 112, 104), ground.Y)
	smoke(ground + Vector3.new(0, 0.6, 0), math.floor(4 + strength * 2), 1.5, Color3.fromRGB(225, 220, 212))
end

-- Dust kicked up by a landing, dash or tech roll.
function BattleFX.dust(x, y, count)
	if not folder or level() < 2 then
		return
	end
	smoke(worldPos(x, y + 0.3, 0), count or 3, 1, Color3.fromRGB(225, 220, 212))
end

-- A hit caught on someone's guard. facing is the blocker's facing.
function BattleFX.block(x, y, facing)
	if not folder or level() == 0 then
		return
	end
	local center = worldPos(x + (facing or 1) * 1.1, y, 1.6)
	local cf = CFrame.new(center) * CFrame.Angles(0, math.rad(90), 0)
	local shield = part(Vector3.new(0.1, 4, 4), cf, Color3.fromRGB(120, 220, 255), Enum.PartType.Cylinder)
	shield.Transparency = 0.35
	fade(shield, 0.2, Vector3.new(0.05, 5.2, 5.2))
	ring(center, 1.6, Color3.new(1, 1, 1), 0.14, 1.6, 0.06)
end

-- The guard shattering.
function BattleFX.guardBreak(x, y)
	if not folder or level() == 0 then
		return
	end
	local center = worldPos(x, y, 1.6)
	ring(center, 2.4, Color3.fromRGB(255, 90, 70), 0.3, 3)
	ring(center, 1.2, Color3.new(1, 1, 1), 0.2, 4, 0.08)
	if level() < 2 then
		return
	end
	for _ = 1, 12 do
		local s = rng:NextNumber(0.5, 1.1)
		local p = part(
			Vector3.new(s, s * 0.6, 0.08),
			CFrame.new(center) * CFrame.Angles(0, 0, rng:NextNumber(0, 6.28)),
			Color3.fromRGB(140, 225, 255)
		)
		p.Transparency = 0.2
		local a = rng:NextNumber(0, math.pi * 2)
		local v = Vector3.new(math.cos(a), math.sin(a) + 0.4, rng:NextNumber(-0.3, 0.3)) * rng:NextNumber(14, 24)
		local spin = Vector3.new(rng:NextNumber(-9, 9), rng:NextNumber(-9, 9), rng:NextNumber(-9, 9))
		addBit(p, v, 0.7, { spin = spin, gravity = -45, fadeFrom = 0.3 })
	end
end

local function auraColor(model)
	local legend = Legends.get(model:GetAttribute("Legend") or "Avatar")
	return legend and legend.Color or Color3.fromRGB(255, 220, 120)
end

local function endAura(model)
	local a = auras[model]
	if not a then
		return
	end
	auras[model] = nil
	a.emitter.Enabled = false
	a.sparks.Enabled = false
	task.delay(1, function()
		a.attachment:Destroy()
	end)
	a.light:Destroy()
	if a.outline and a.outline.Parent then
		a.outline.OutlineColor = a.outlineColor
	end
end

-- Awakened: a flame aura and a glowing outline for `duration` seconds.
function BattleFX.awaken(model, duration)
	if not model or not folder then
		return
	end
	endAura(model)
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	local color = auraColor(model)
	local bright = color:Lerp(Color3.new(1, 1, 1), 0.45)
	local lvl = level()
	local attachment = Instance.new("Attachment")
	attachment.Name = "SkyAura"
	attachment.Position = Vector3.new(0, -0.5, 0)
	attachment.Parent = root

	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = FIRE
	emitter.Color = ColorSequence.new(bright, color)
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 2.2),
		NumberSequenceKeypoint.new(1, 0.2),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.35, 0.6)
	emitter.Rate = lvl >= 2 and 70 or (lvl == 1 and 25 or 0)
	emitter.Speed = NumberRange.new(4, 8)
	emitter.SpreadAngle = Vector2.new(12, 12)
	emitter.Acceleration = Vector3.new(0, 14, 0)
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Shape = Enum.ParticleEmitterShape.Box
	emitter.Parent = attachment

	local sparks = Instance.new("ParticleEmitter")
	sparks.Texture = SPARKLE
	sparks.Color = ColorSequence.new(Color3.new(1, 1, 1), bright)
	sparks.LightEmission = 1
	sparks.Size = NumberSequence.new(0.35, 0)
	sparks.Lifetime = NumberRange.new(0.4, 0.8)
	sparks.Rate = lvl >= 2 and 18 or 0
	sparks.Speed = NumberRange.new(6, 12)
	sparks.SpreadAngle = Vector2.new(40, 40)
	sparks.Acceleration = Vector3.new(0, 8, 0)
	sparks.Parent = attachment

	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 12
	light.Brightness = lvl > 0 and 2 or 0
	light.Parent = root

	local outline = model:FindFirstChild("SkyOutline")
	auras[model] = {
		attachment = attachment,
		emitter = emitter,
		sparks = sparks,
		light = light,
		outline = outline,
		outlineColor = outline and outline.OutlineColor,
		ends = os.clock() + duration,
	}
	if outline then
		outline.OutlineColor = bright
	end
	if lvl > 0 then
		emitter:Emit(lvl >= 2 and 40 or 12)
		ring(root.Position + Vector3.new(0, 0, 1.6), 2, bright, 0.4, 4)
	end
end

function BattleFX.endAwaken(model)
	if model then
		endAura(model)
	end
end

-- Speed lines streaking in from the screen edges.
function BattleFX.speedLines(duration)
	if level() < 2 then
		return
	end
	local screen = screenGui()
	if not screen then
		return
	end
	local holder = Instance.new("Frame")
	holder.Name = "SpeedLines"
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromScale(1, 1)
	holder.Parent = screen
	local lines = {}
	for k = 1, 28 do
		local a = k / 28 * 360 + rng:NextNumber(-5, 5)
		local line = Instance.new("Frame")
		line.AnchorPoint = Vector2.new(0, 0.5)
		line.BorderSizePixel = 0
		line.BackgroundColor3 = Color3.new(1, 1, 1)
		line.Position = UDim2.fromScale(0.5, 0.5)
		line.Size = UDim2.new(0.8, 0, 0, rng:NextInteger(2, 5))
		line.Rotation = a
		line.Parent = holder
		local gradient = Instance.new("UIGradient")
		gradient.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.45, 1),
			NumberSequenceKeypoint.new(0.75, 0.3),
			NumberSequenceKeypoint.new(1, 0.6),
		})
		gradient.Parent = line
		table.insert(lines, line)
	end
	local ends = os.clock() + duration
	local conn
	conn = RunService.RenderStepped:Connect(function()
		local left = ends - os.clock()
		if left <= 0 or not holder.Parent then
			conn:Disconnect()
			holder:Destroy()
			return
		end
		for _, line in lines do
			line.BackgroundTransparency = rng:NextNumber() < 0.35 and 1 or math.clamp(1 - left / duration, 0.1, 1)
		end
	end)
end

-- Lifecycle --------------------------------------------------------------------------

function BattleFX.startMatch(arenaOrigin)
	BattleFX.stopMatch()
	origin = arenaOrigin
	folder = Instance.new("Folder")
	folder.Name = "SkybrawlBattleFX"
	folder.Parent = workspace
	stepConn = RunService.RenderStepped:Connect(function(dt)
		stepBits(dt)
		local now = os.clock()
		for model, a in auras do
			if now >= a.ends or not model.Parent then
				endAura(model)
			end
		end
	end)
end

function BattleFX.stopMatch()
	if stepConn then
		stepConn:Disconnect()
		stepConn = nil
	end
	for model in auras do
		endAura(model)
	end
	bits = {}
	frameToken += 1
	if colorCorrection then
		colorCorrection.Enabled = false
	end
	if gui then
		gui:Destroy()
		gui = nil
	end
	if folder then
		folder:Destroy()
		folder = nil
	end
end

return BattleFX
