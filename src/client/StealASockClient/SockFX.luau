-- SockFX: everything that makes socks feel alive, done on the client so it costs the server nothing.
--  * Line socks: position = f(server time) from the LineStart/LineDuration attributes, with a sway,
--    and a drop into the Lint Trap at the end. Smooth on every client, zero replication traffic.
--  * Drawer socks: idle motion around RestCFrame by the type's Motion attribute (bob, bounce,
--    wiggle, wobble, hop, skate, shiver, float, spin), started ~0.8 s after placement so the
--    server's buy hop finishes first.
--  * Rainbow mutation hue cycling.
--  * One-shot bursts requested by the server (FX remote): buy, pair, perfect, steal, claim, snap.
--  * The Great Dryer's galaxy: its two layers spin, its glow breathes, and it puffs sparkles
--    whenever a sock pops out onto the line.
--  * The ceiling fan's blades turn; the invisible forcefield round the play area shimmers only
--    where the player walks up to it.
-- One Heartbeat loop for the socks; carried socks are left to physics.
local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local SockFX = {}

local lineStartX, lineEndX, lineY, pinOffset = 0, 0, 0, 2.4
local lineRise, riseLength = 0, 50 -- the rope starts this much higher, in the dryer's void (Map.riseAt)
local active = {} :: { [Model]: boolean }
local rainbowParts = {} :: { [Model]: { BasePart } }

-- Toon outlines: Roblox renders at most 31 Highlights at once, so only the socks nearest the
-- camera (plus the dryer) get the thick dark outline from the concept art.
local MAX_OUTLINES = 22
local OUTLINE_COLOR = Color3.fromRGB(34, 22, 48)
local highlights = {} :: { [Model]: Highlight }

local function outline(model: Model): Highlight
	local h = highlights[model]
	if not h then
		h = Instance.new("Highlight")
		h.Name = "ToonOutline"
		h.OutlineColor = OUTLINE_COLOR
		h.OutlineTransparency = 0
		h.FillTransparency = 1
		h.DepthMode = Enum.HighlightDepthMode.Occluded
		h.Enabled = false
		h.Adornee = model
		h.Parent = model
		highlights[model] = h
	end
	return h
end

local function refreshOutlines()
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local camPos = cam.CFrame.Position
	local list = {}
	for model in pairs(active) do
		local leg = model.PrimaryPart
		if leg then
			table.insert(list, { model = model, d = (leg.Position - camPos).Magnitude })
		end
	end
	table.sort(list, function(a, b)
		return a.d < b.d
	end)
	local shown = 0
	for _, entry in ipairs(list) do
		-- Blender meshes have the outline baked in; only Part-built socks need a Highlight
		if entry.model:GetAttribute("FromMesh") then
			local h = highlights[entry.model]
			if h then
				h.Enabled = false
			end
		else
			shown += 1
			outline(entry.model).Enabled = shown <= MAX_OUTLINES and entry.d < 140
		end
	end
end

local function pivotOffset(dy: number, roll: number, pitch: number?): CFrame
	return CFrame.new(0, dy, 0) * CFrame.Angles(pitch or 0, 0, roll)
end

-- Idle offsets, keyed by SockConfig.motion. `t` is time, `p` a per-sock phase.
local MOTIONS: { [string]: (t: number, p: number) -> CFrame } = {
	bob = function(t, p)
		return pivotOffset(math.sin(t * 1.6 + p) * 0.12, math.sin(t * 0.9 + p) * 0.04)
	end,
	bounce = function(t, p)
		local s = math.abs(math.sin(t * 3.2 + p))
		return pivotOffset(s * 0.6, 0) * CFrame.Angles(0, 0, math.sin(t * 6.4 + p) * 0.08)
	end,
	wiggle = function(t, p)
		return pivotOffset(math.sin(t * 2 + p) * 0.08, math.sin(t * 9 + p) * 0.14)
	end,
	wobble = function(t, p)
		return pivotOffset(0, math.sin(t * 2.4 + p) * 0.22, math.sin(t * 1.7 + p) * 0.1)
	end,
	hop = function(t, p)
		local cycle = (t * 1.4 + p) % 1
		local h = math.max(0, math.sin(cycle * math.pi)) * 1.8
		return pivotOffset(h, math.sin(cycle * math.pi * 2) * 0.05)
	end,
	skate = function(t, p)
		return CFrame.new(math.sin(t * 1.2 + p) * 0.9, 0, 0) * CFrame.Angles(0, 0, math.sin(t * 1.2 + p) * -0.12)
	end,
	shiver = function(t, p)
		return CFrame.new(math.sin(t * 40 + p) * 0.05, 0, 0) * CFrame.Angles(0, 0, math.sin(t * 37 + p) * 0.03)
	end,
	float = function(t, p)
		return pivotOffset(1.2 + math.sin(t * 1.1 + p) * 0.5, 0) * CFrame.Angles(0, t * 0.6 + p, 0)
	end,
	spin = function(t, p)
		return pivotOffset(math.sin(t * 2 + p) * 0.1, 0) * CFrame.Angles(0, math.sin(t * 1.5 + p) * 0.5, 0)
	end,
}

local function lineCFrame(model: Model, now: number, phase: number): CFrame?
	local t0 = model:GetAttribute("LineStart")
	local dur = model:GetAttribute("LineDuration")
	if typeof(t0) ~= "number" or typeof(dur) ~= "number" or dur <= 0 then
		return nil
	end
	local progress = math.clamp((now - t0) / dur, 0, 1.1)
	local along = math.min(progress, 1) * (lineEndX - lineStartX)
	local x = lineStartX + along
	-- out of the centre of the dryer's void, easing down to the line (same curve as Map.riseAt)
	local rise = lineRise * (1 + math.cos(math.pi * math.clamp(along / riseLength, 0, 1))) / 2
	local sway = math.sin(now * 2.2 + phase) * 0.1
	local drop = if progress > 0.965 then ((progress - 0.965) / 0.035) ^ 2 * 9 else 0
	-- rotate around the clothespin (top of the sock) so it swings, not slides
	return CFrame.new(x, lineY + rise - drop, 0) * CFrame.new(0, pinOffset, 0) * CFrame.Angles(0, 0, sway) * CFrame.new(0, -pinOffset, 0)
end

-- ---------- the Great Dryer's galaxy ----------
-- The Blender dryer exports its galaxy as two textured layers (tools/blender/props/dryer.py). They
-- turn here, on each client, about the porthole axis: through the Dryer_Pin marker, along the
-- machine's front (Dryer_Base -> Dryer_Unit). Counter-clockwise seen from the front, so the spiral
-- arms seem to drain into the void; the stars turn faster for depth. Rad/s:
local VORTEX_LAYERS: { [string]: number } = { DryerVortex = 0.55, DryerStars = 0.85 }
local PORTAL_DIM, PORTAL_BRIGHT = Color3.fromRGB(150, 90, 255), Color3.fromRGB(205, 150, 255)
local voidSparkles: ParticleEmitter? = nil

local function findSuffix(root: Instance, suffix: string): BasePart?
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") and string.sub(d.Name, -#suffix) == suffix then
			return d
		end
	end
	return nil
end

local function startDryer(mapFolder: Instance)
	local emitterPart = mapFolder:WaitForChild("DryerVoidEmitter", 20)
	local sparkles = emitterPart and emitterPart:FindFirstChild("VoidSparkles")
	if sparkles and sparkles:IsA("ParticleEmitter") then
		voidSparkles = sparkles
	end
	local dryer = mapFolder:WaitForChild("Dryer", 20)
	if not dryer then
		return -- the Part-built dryer has no galaxy layers
	end
	-- parts can stream in after the model: give them a few seconds
	local pin, base, unit
	local layers = {} :: { { part: BasePart, rest: CFrame, speed: number } }
	local portal: BasePart? = nil
	for _ = 1, 20 do
		pin, base, unit = findSuffix(dryer, "_Pin"), findSuffix(dryer, "_Base"), findSuffix(dryer, "_Unit")
		layers = {}
		for name, speed in pairs(VORTEX_LAYERS) do
			local p = dryer:FindFirstChild(name, true)
			if p and p:IsA("BasePart") then
				table.insert(layers, { part = p, rest = p.CFrame, speed = speed })
			end
		end
		local glow = dryer:FindFirstChild("DryerPortal", true)
		portal = if glow and glow:IsA("BasePart") then glow else nil
		if pin and base and unit and #layers == 2 then
			break
		end
		task.wait(0.5)
	end
	if not (pin and base and unit) then
		return
	end
	local flat = Vector3.new(unit.Position.X - base.Position.X, 0, unit.Position.Z - base.Position.Z)
	if flat.Magnitude < 1e-3 then
		return
	end
	local axis = flat.Unit
	local centre = pin.Position
	RunService.RenderStepped:Connect(function()
		local t = os.clock()
		for _, layer in ipairs(layers) do
			layer.part.CFrame = CFrame.new(centre) * CFrame.fromAxisAngle(axis, t * layer.speed) * CFrame.new(-centre) * layer.rest
		end
		if portal then
			portal.Color = PORTAL_DIM:Lerp(PORTAL_BRIGHT, (math.sin(t * 2.2) + 1) * 0.25)
		end
	end)
end

-- ---------- the ceiling fan ----------
-- Map hangs the Blender fan (tools/blender/props/ceilingfan.py) from the ceiling; its FanBlades turn
-- here about the vertical axis through the CeilingFan_Pin marker (the hub).
local FAN_SPEED = 1.3 -- rad/s, a lazy night-time spin

local function startFan(mapFolder: Instance)
	local fan = mapFolder:WaitForChild("CeilingFan", 20)
	if not fan then
		return -- no fan mesh imported
	end
	local blades, pin
	for _ = 1, 20 do -- parts can stream in after the model
		local b = fan:FindFirstChild("FanBlades", true)
		blades = if b and b:IsA("BasePart") then b else nil
		pin = findSuffix(fan, "_Pin")
		if blades and pin then
			break
		end
		task.wait(0.5)
	end
	if not (blades and pin) then
		return
	end
	local bladePart = blades :: BasePart
	local rest = bladePart.CFrame
	local hub = (pin :: BasePart).Position
	RunService.RenderStepped:Connect(function()
		local turn = CFrame.Angles(0, os.clock() * FAN_SPEED, 0)
		bladePart.CFrame = CFrame.new(hub) * turn * CFrame.new(-hub) * rest
	end)
end

-- ---------- the forcefield round the play area ----------
-- Map's field walls are invisible. Walking up to one fades in a soft ForceField-material disc on the
-- wall right where you are, so the edge only shows itself when you reach it.
local FIELD_SHOW = 28 -- studs: start showing the shimmer this close

local function startField(mapFolder: Instance)
	local field = mapFolder:WaitForChild("Forcefield", 20)
	if not field then
		return
	end
	local walls = {} :: { BasePart }
	for _, w in ipairs(field:GetChildren()) do
		if w:IsA("BasePart") then
			table.insert(walls, w)
		end
	end
	local ripple = Instance.new("Part")
	ripple.Name = "FieldShimmer"
	ripple.Shape = Enum.PartType.Cylinder -- a disc: the cylinder's axis is the wall's normal
	ripple.Material = Enum.Material.ForceField
	ripple.Color = Color3.fromRGB(175, 140, 255)
	ripple.Anchored = true
	ripple.CanCollide = false
	ripple.CanQuery = false
	ripple.CanTouch = false
	ripple.CastShadow = false
	ripple.Transparency = 1
	ripple.Size = Vector3.new(0.3, 20, 20)
	ripple.Parent = workspace
	RunService.RenderStepped:Connect(function()
		local character = Players.LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not (root and root:IsA("BasePart")) then
			ripple.Transparency = 1
			return
		end
		local p = root.Position
		local bestD, bestPoint, bestNormal = math.huge, nil, nil
		for _, w in ipairs(walls) do
			local lp = w.CFrame:PointToObjectSpace(p)
			local h = w.Size / 2
			local cp = Vector3.new(math.clamp(lp.X, -h.X, h.X), math.clamp(lp.Y, -h.Y, h.Y), math.clamp(lp.Z, -h.Z, h.Z))
			local d = (lp - cp).Magnitude
			if d < bestD then
				-- the wall's thin axis, pointing at the player's side
				local n = if w.Size.X < w.Size.Z then Vector3.new(math.sign(lp.X), 0, 0) else Vector3.new(0, 0, math.sign(lp.Z))
				bestD, bestPoint, bestNormal = d, w.CFrame:PointToWorldSpace(cp), w.CFrame:VectorToWorldSpace(n)
			end
		end
		if not (bestPoint and bestNormal) or bestD > FIELD_SHOW then
			ripple.Transparency = 1
			return
		end
		local near = 1 - bestD / FIELD_SHOW -- 0 far .. 1 touching
		local size = 16 + 18 * near
		local at = Vector3.new(bestPoint.X, math.max(p.Y, size / 2), bestPoint.Z) + bestNormal * 0.2
		ripple.Size = Vector3.new(0.3, size, size)
		ripple.CFrame = CFrame.fromMatrix(at, bestNormal, Vector3.yAxis)
		ripple.Transparency = 1 - 0.6 * near * (0.85 + 0.15 * math.sin(os.clock() * 5))
	end)
end

-- a sock that just popped out of the dryer: puff some sparkles out of the galaxy
local function dryerBurst(model: Model)
	local lineStart = model:GetAttribute("LineStart")
	if voidSparkles and typeof(lineStart) == "number" and workspace:GetServerTimeNow() - lineStart < 1.5 then
		voidSparkles:Emit(24)
	end
end

local function track(model: Instance)
	if not model:IsA("Model") then
		return
	end
	-- the server sets LineStart just after parenting a new line sock: catch it either way
	if model:GetAttribute("LineStart") ~= nil then
		dryerBurst(model)
	else
		model:GetAttributeChangedSignal("LineStart"):Once(function()
			dryerBurst(model)
		end)
	end
	active[model] = true
	if model:GetAttribute("Rainbow") then
		local parts = {}
		for _, name in ipairs({ "Leg", "Foot", "Cuff" }) do
			local p = model:FindFirstChild(name)
			if p and p:IsA("BasePart") then
				table.insert(parts, p)
			end
		end
		rainbowParts[model] = parts
	end
	model.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			active[model] = nil
			rainbowParts[model] = nil
			highlights[model] = nil
		end
	end)
end

function SockFX.Init()
	local root = workspace:WaitForChild("StealASock", 30)
	local line = root and root:WaitForChild("Line", 10)
	if line then
		lineStartX = line:GetAttribute("StartX") or -160
		lineEndX = line:GetAttribute("EndX") or 150
		lineY = line:GetAttribute("Y") or 10
		pinOffset = line:GetAttribute("PinOffset") or 4.3
		lineRise = line:GetAttribute("Rise") or 0
		riseLength = math.max(line:GetAttribute("RiseLength") or 50, 1)
	end
	for _, model in ipairs(CollectionService:GetTagged("Sock")) do
		track(model)
	end
	CollectionService:GetInstanceAddedSignal("Sock"):Connect(track)

	task.spawn(function()
		local mapFolder = root and root:WaitForChild("Map", 10)
		if mapFolder then
			task.spawn(startFan, mapFolder)
			task.spawn(startField, mapFolder)
			startDryer(mapFolder)
		end
	end)

	-- the Great Dryer always gets an outline; socks are re-ranked by distance twice a second
	task.spawn(function()
		local mapFolder = root and root:WaitForChild("Map", 10)
		local dryerBody = mapFolder and (mapFolder:FindFirstChild("DryerBody") or mapFolder:FindFirstChild("Dryer"))
		if dryerBody and not dryerBody:FindFirstChild("Dryer_Outline", true) then
			local h = Instance.new("Highlight")
			h.Name = "ToonOutline"
			h.OutlineColor = OUTLINE_COLOR
			h.FillTransparency = 1
			h.DepthMode = Enum.HighlightDepthMode.Occluded
			h.Parent = dryerBody
		end
		while true do
			refreshOutlines()
			task.wait(0.5)
		end
	end)

	RunService.Heartbeat:Connect(function()
		local now = workspace:GetServerTimeNow()
		local clock = os.clock()
		for model in pairs(active) do
			local leg = model.PrimaryPart
			if leg then
				local uid = model:GetAttribute("Uid") or 0
				local phase = (uid % 17) * 0.7
				local state = model:GetAttribute("State")
				if state == "line" then
					local cf = lineCFrame(model, now, phase)
					if cf then
						leg.CFrame = cf
					end
				elseif state == "drawer" then
					local rest = model:GetAttribute("RestCFrame")
					local placedAt = model:GetAttribute("PlacedAt")
					if typeof(rest) == "CFrame" and typeof(placedAt) == "number" and now - placedAt > 0.8 then
						local motion = MOTIONS[model:GetAttribute("Motion")] or MOTIONS.bob
						leg.CFrame = rest * motion(clock, phase)
					end
				end
				local rainbow = rainbowParts[model]
				if rainbow then
					local color = Color3.fromHSV((clock * 0.25 + phase) % 1, 0.75, 1)
					for _, p in ipairs(rainbow) do
						p.Color = color
					end
				end
			end
		end
	end)
end

-- ---------- one-shot bursts ----------

local BURSTS = {
	buy = { count = 18, color = Color3.fromRGB(255, 255, 255), size = 0.5, speed = 8, life = 0.7 },
	pair = { count = 40, color = Color3.fromRGB(120, 255, 160), size = 0.45, speed = 12, life = 1.2, confetti = true },
	perfect = { count = 70, color = Color3.fromRGB(255, 200, 60), size = 0.5, speed = 15, life = 1.5, confetti = true },
	steal = { count = 24, color = Color3.fromRGB(255, 70, 70), size = 0.6, speed = 10, life = 0.6 },
	claim = { count = 30, color = Color3.fromRGB(120, 255, 160), size = 0.5, speed = 9, life = 0.9 },
	snap = { count = 16, color = Color3.fromRGB(255, 255, 255), size = 0.8, speed = 14, life = 0.4 },
}

function SockFX.Burst(kind: string, position: Vector3, color: Color3?)
	local spec = BURSTS[kind] or BURSTS.buy
	local holder = Instance.new("Part")
	holder.Name = "FX_" .. kind
	holder.Size = Vector3.new(0.2, 0.2, 0.2)
	holder.Transparency = 1
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.CFrame = CFrame.new(position)
	local e = Instance.new("ParticleEmitter")
	e.Rate = 0
	e.Lifetime = NumberRange.new(spec.life * 0.6, spec.life)
	e.Speed = NumberRange.new(spec.speed * 0.5, spec.speed)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, spec.size), NumberSequenceKeypoint.new(1, 0) })
	e.LightEmission = 0.8
	e.Acceleration = Vector3.new(0, if spec.confetti then -14 else -4, 0)
	e.Drag = 2
	if spec.confetti then
		e.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, color or spec.color),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 120, 220)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(120, 200, 255)),
		})
		e.Rotation = NumberRange.new(0, 360)
		e.RotSpeed = NumberRange.new(-300, 300)
	else
		e.Color = ColorSequence.new(color or spec.color)
	end
	e.Parent = holder
	holder.Parent = workspace.CurrentCamera
	e:Emit(spec.count)
	if kind == "pair" or kind == "perfect" or kind == "claim" then
		local l = Instance.new("PointLight")
		l.Color = color or spec.color
		l.Range = 14
		l.Brightness = 2
		l.Parent = holder
		task.delay(0.4, function()
			l:Destroy()
		end)
	end
	Debris:AddItem(holder, spec.life + 0.5)
end

return SockFX
