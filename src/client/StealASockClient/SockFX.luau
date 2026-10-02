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
--  * The ceiling fan's blades turn; the invisible forcefield round the play area lights up a
--    patch of glowing hexagon cells only where the player walks up to it.
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
-- Map's field walls are invisible. Walking up to one lights a honeycomb of glowing hexagon cells on
-- the wall around the spot you're nearest: the patch fades in and grows as you get closer, its cells
-- twinkle, and touching the wall sends a ripple out through them. Far away there's nothing to see.
-- The honeycomb is fixed to the wall (only which cells are lit follows you), and it's all local:
-- each player sees only their own.
local HEX_R = 2.5 -- cell corner radius (studs)
local HEX_GAP = 0.86 -- cells drawn this much smaller than the lattice, so each one reads on its own
local HEX_RINGS = 3 -- rings of cells round the centre one -> 37 cells, 6 bars each
local HEX_BAR = 0.22 -- bar thickness
local FIELD_SHOW = 22 -- studs: cells start to appear this close to the wall
local FIELD_TOUCH = 3.5 -- studs: this close counts as touching (ripples)
local FIELD_COLOR = Color3.fromRGB(196, 158, 255)
local SQRT3 = math.sqrt(3)

type FieldWall = { part: BasePart, u: Vector3, n: Vector3, halfLen: number, halfThick: number, bottom: number, height: number }
type HexCell = { dq: number, dr: number, bars: { BasePart }, phase: number, alpha: number, cu: number, cv: number }

-- lattice (q, r) -> wall coords (u along the wall, v up), flat-topped hexagons
local function hexCentre(q: number, r: number): (number, number)
	return HEX_R * 1.5 * q, HEX_R * SQRT3 * (r + q / 2)
end

-- wall coords -> nearest lattice cell (cube rounding)
local function hexRound(u: number, v: number): (number, number)
	local fq = (2 / 3 * u) / HEX_R
	local fr = (-1 / 3 * u + SQRT3 / 3 * v) / HEX_R
	local fs = -fq - fr
	local q, r, s = math.round(fq), math.round(fr), math.round(fs)
	local dq, dr, ds = math.abs(q - fq), math.abs(r - fr), math.abs(s - fs)
	if dq > dr and dq > ds then
		q = -r - s
	elseif dr > ds then
		r = -q - s
	end
	return q, r
end

local function startField(mapFolder: Instance)
	local field = mapFolder:WaitForChild("Forcefield", 20)
	if not field then
		return
	end
	local walls = {} :: { FieldWall }
	for _, w in ipairs(field:GetChildren()) do
		if w:IsA("BasePart") then
			local thinX = w.Size.X < w.Size.Z
			table.insert(walls, {
				part = w,
				u = if thinX then w.CFrame.ZVector else w.CFrame.XVector,
				n = if thinX then w.CFrame.XVector else w.CFrame.ZVector,
				halfLen = (if thinX then w.Size.Z else w.Size.X) / 2,
				halfThick = (if thinX then w.Size.X else w.Size.Z) / 2,
				bottom = w.Position.Y - w.Size.Y / 2,
				height = w.Size.Y,
			})
		end
	end
	if #walls == 0 then
		return
	end

	-- the cell pool: built once, moved only when the lit patch shifts to another cell
	local folder = Instance.new("Folder")
	folder.Name = "FieldHexes"
	folder.Parent = workspace
	local cells = {} :: { HexCell }
	local allBars = {} :: { BasePart }
	for dq = -HEX_RINGS, HEX_RINGS do
		for dr = math.max(-HEX_RINGS, -dq - HEX_RINGS), math.min(HEX_RINGS, -dq + HEX_RINGS) do
			local bars = {}
			for _ = 1, 6 do
				local bar = Instance.new("Part")
				bar.Name = "Hex"
				bar.Size = Vector3.new(HEX_R * HEX_GAP + HEX_BAR * 0.5, 0.06, HEX_BAR)
				bar.Material = Enum.Material.Neon
				bar.Color = FIELD_COLOR
				bar.Transparency = 1
				bar.Anchored = true
				bar.CanCollide = false
				bar.CanQuery = false
				bar.CanTouch = false
				bar.CastShadow = false
				bar.Parent = folder
				table.insert(bars, bar)
				table.insert(allBars, bar)
			end
			table.insert(cells, { dq = dq, dr = dr, bars = bars, phase = math.random() * math.pi * 2, alpha = 0, cu = 0, cv = 0 })
		end
	end

	local placedWall, placedQ, placedR = nil :: FieldWall?, 0, 0
	local function place(wall: FieldWall, side: number, q0: number, r0: number)
		placedWall, placedQ, placedR = wall, q0, r0
		local centre = wall.part.Position
		local origin = Vector3.new(centre.X, wall.bottom, centre.Z) + wall.n * side * (wall.halfThick + 0.05)
		local cfs = table.create(#allBars)
		for _, cell in ipairs(cells) do
			cell.cu, cell.cv = hexCentre(q0 + cell.dq, r0 + cell.dr)
			local at = origin + wall.u * cell.cu + Vector3.yAxis * cell.cv
			for k = 0, 5 do
				local a = math.rad(30 + 60 * k) -- edge midpoints of a flat-topped hexagon
				local out = wall.u * math.cos(a) + Vector3.yAxis * math.sin(a)
				local along = wall.u * -math.sin(a) + Vector3.yAxis * math.cos(a)
				table.insert(cfs, CFrame.fromMatrix(at + out * (HEX_R * HEX_GAP * SQRT3 / 2), along, wall.n))
			end
		end
		workspace:BulkMoveTo(allBars, cfs, Enum.BulkMoveMode.FireCFrameChanged)
	end

	local shown = false
	local wasTouching = false
	local rippleAt, rippleU, rippleV, rippleWall = -math.huge, 0, 0, nil :: FieldWall?
	local function hideAll()
		for _, cell in ipairs(cells) do
			cell.alpha = 0
			for _, bar in ipairs(cell.bars) do
				bar.Transparency = 1
			end
		end
		shown = false
	end

	RunService.RenderStepped:Connect(function()
		local character = Players.LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not (root and root:IsA("BasePart")) then
			if shown then
				hideAll()
			end
			return
		end
		local p = root.Position
		-- nearest wall, and where on it the player is (u along it, v up from its foot)
		local best, bestD, bestU, bestSide = nil :: FieldWall?, math.huge, 0, 1
		for _, w in ipairs(walls) do
			local rel = p - w.part.Position
			local u = rel:Dot(w.u)
			local across = rel:Dot(w.n)
			local over = math.max(math.abs(u) - w.halfLen, 0)
			local d = math.sqrt(math.max(math.abs(across) - w.halfThick, 0) ^ 2 + over ^ 2)
			if d < bestD then
				best, bestD, bestU, bestSide = w, d, math.clamp(u, -w.halfLen, w.halfLen), if across >= 0 then 1 else -1
			end
		end
		if not best or bestD > FIELD_SHOW then
			if shown then
				hideAll()
			end
			wasTouching = false
			return
		end
		local wall = best :: FieldWall
		local pv = math.clamp(p.Y - wall.bottom + 2.5, 0, wall.height) -- centred about head height
		local q0, r0 = hexRound(bestU, pv)
		if wall ~= placedWall or q0 ~= placedQ or r0 ~= placedR then
			place(wall, bestSide, q0, r0)
		end
		local t = os.clock()
		local touching = bestD < FIELD_TOUCH
		if touching and (not wasTouching or t - rippleAt > 1.6) then
			rippleAt, rippleU, rippleV, rippleWall = t, bestU, pv, wall
		end
		wasTouching = touching

		local near = 1 - bestD / FIELD_SHOW -- 0 far .. 1 touching
		local reach = HEX_R * (1.2 + (HEX_RINGS * SQRT3 - 1.2) * near) -- grows to the pool's edge as you come closer
		local rippleAge = t - rippleAt
		local rippling = rippleWall == wall and rippleAge < 1.1
		for _, cell in ipairs(cells) do
			local alpha = 0
			local inside = math.abs(cell.cu) <= wall.halfLen and cell.cv >= -HEX_R * 0.5 and cell.cv <= wall.height
			if inside then
				local du, dv = cell.cu - bestU, cell.cv - pv
				local r = math.sqrt(du * du + dv * dv)
				local fall = math.clamp(1 - r / reach, 0, 1)
				fall = fall * fall * (3 - 2 * fall)
				local twinkle = 0.65 + 0.35 * math.sin(t * 3.2 + cell.phase)
				alpha = near * fall * twinkle * 0.8
				if rippling then
					local ru, rv = cell.cu - rippleU, cell.cv - rippleV
					local front = rippleAge * 26
					local bump = math.max(0, 1 - math.abs(math.sqrt(ru * ru + rv * rv) - front) / (HEX_R * 1.6))
					alpha = math.max(alpha, bump * (1 - rippleAge / 1.1) * 0.95)
				end
			end
			if math.abs(alpha - cell.alpha) > 0.01 or (alpha == 0 and cell.alpha ~= 0) then
				cell.alpha = alpha
				for _, bar in ipairs(cell.bars) do
					bar.Transparency = 1 - alpha
				end
			end
		end
		shown = true
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
