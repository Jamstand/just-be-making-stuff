-- SockFX: everything that makes socks feel alive, done on the client so it costs the server nothing.
--  * Line socks: position = f(server time) from the LineStart/LineDuration attributes, with a sway,
--    and a drop into the Lint Trap at the end. Smooth on every client, zero replication traffic.
--  * Drawer socks: idle motion around RestCFrame by the type's Motion attribute (bob, bounce,
--    wiggle, wobble, hop, skate, shiver, float, spin), started ~0.8 s after placement so the
--    server's buy hop finishes first.
--  * Rainbow mutation hue cycling.
--  * One-shot bursts requested by the server (FX remote): buy, pair, perfect, steal, claim, snap.
-- One Heartbeat loop for all of it; carried socks are left to physics.
local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")

local SockFX = {}

local lineStartX, lineEndX, lineY = 0, 0, 0
local active = {} :: { [Model]: boolean }
local rainbowParts = {} :: { [Model]: { BasePart } }

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
	local x = lineStartX + math.min(progress, 1) * (lineEndX - lineStartX)
	local sway = math.sin(now * 2.2 + phase) * 0.1
	local drop = if progress > 0.965 then ((progress - 0.965) / 0.035) ^ 2 * 9 else 0
	-- rotate around the clothespin (top of the sock) so it swings, not slides
	return CFrame.new(x, lineY - drop, 0) * CFrame.new(0, 2.4, 0) * CFrame.Angles(0, 0, sway) * CFrame.new(0, -2.4, 0)
end

local function track(model: Instance)
	if not model:IsA("Model") then
		return
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
		end
	end)
end

function SockFX.Init()
	local root = workspace:WaitForChild("StealASock", 30)
	local line = root and root:WaitForChild("Line", 10)
	if line then
		lineStartX = line:GetAttribute("StartX") or -160
		lineEndX = line:GetAttribute("EndX") or 150
		lineY = line:GetAttribute("Y") or 7
	end
	for _, model in ipairs(CollectionService:GetTagged("Sock")) do
		track(model)
	end
	CollectionService:GetInstanceAddedSignal("Sock"):Connect(track)

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
