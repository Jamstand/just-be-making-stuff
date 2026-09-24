-- PetView: every player's equipped rebirth pet as a glowing crystal golem that
-- hovers beside the avatar and bobs (plan CM-3, evolved in place).
--   * LOCAL pet: driven by the snapshot (PetView.Set(snap.pets.active) — immediate
--     feedback, works against a server that sets no attributes) and animated on
--     RenderStepped with the PointLight, sparkle particles and a name billboard
--     (MaxDistance 60).
--   * OTHER players' pets: built from the server-set attributes PetName / PetEmoji /
--     PetColor (ONE AttributeChanged connection per player, 0.1 s coalesced rebuild,
--     destroyed when PetName == "") and animated on ONE Heartbeat connection with a
--     15 Hz accumulator: each tick the nearest N characters within 100 studs
--     (N = 4/8/12 by Quality.Tier) get their golem origin lerped with the same bob;
--     everything else is parked (Model.Parent = nil). No PointLight for others,
--     particle rate 0 beyond 40 studs, name billboard MaxDistance 40.
--   * The golem builder (authored template under ReplicatedStorage.PetModels.<name>,
--     else the procedural crystal golem) is keyed by {name, emoji, color}; models live
--     in the client-created workspace.GeodePets folder (outside CrackAGeode and the
--     camera, so Signposts and the light cull ignore them); every billboard carries
--     Signpost=false. Cleanup on PlayerRemoving.
--
--   PetView.Init(Quality)
--   PetView.Set(active)   local pet from snapshot.pets.active ({ name, emoji, color = {r,g,b} }) or nil

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SG = require(ReplicatedStorage:WaitForChild("StyleGuide")) -- pet tag font from the tokens

local PetView = {}
local Quality
local player = Players.LocalPlayer

local RANGE = 100            -- studs: beyond this other pets are parked
local PARTICLE_RANGE = 40    -- studs: beyond this other pets emit nothing
local TICK = 1 / 15          -- others animate at 15 Hz
local NEAR_BY_TIER = { [0] = 4, [1] = 8, [2] = 12 }
local LOCAL_LERP, OTHER_LERP = 0.14, 0.4
local DEFAULT_COLOR = Color3.fromRGB(180, 120, 255)

local folder = nil    -- workspace.GeodePets (client-created)
local current = nil   -- local pet entry: { model, parts, torso, pe, bb, key, origin, shown, rate }
local others = {}     -- [Player] = { player, attrConn, pending, phase, pet = entry|nil }

-- ===== helpers =====
local function tier()
	local t = Quality and Quality.Tier
	return type(t) == "number" and t or 2
end

local function nearCap()
	return NEAR_BY_TIER[tier()] or 12
end

local function particleRate()
	return tier() <= 1 and 3 or 6
end

local function getFolder()
	if folder and folder.Parent then return folder end
	local f = workspace:FindFirstChild("GeodePets")
	if not (f and f:IsA("Folder")) then
		f = Instance.new("Folder")
		f.Name = "GeodePets"
		f.Parent = workspace
	end
	folder = f
	return f
end

local function myPosition()
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hrp then return hrp.Position end
	local cam = workspace.CurrentCamera
	return cam and cam.CFrame.Position or nil
end

-- hover to the player's right-and-behind, gently bobbing + swaying
local function targetFor(hrp, t)
	return hrp.CFrame * CFrame.new(2.6, 1.5 + math.sin(t * 2.2) * 0.5, 1.9)
		* CFrame.Angles(math.rad(math.sin(t * 1.4) * 4), math.rad(math.sin(t * 0.8) * 16), 0)
end

local function place(e, origin)
	for _, pd in ipairs(e.parts) do
		pd[1].CFrame = origin * pd[2]
	end
end

local function specFromActive(active)
	if type(active) ~= "table" or type(active.name) ~= "string" or active.name == "" then return nil end
	local c = active.color
	local color
	if typeof(c) == "Color3" then
		color = c
	elseif type(c) == "table" then
		color = Color3.fromRGB(tonumber(c[1]) or 0, tonumber(c[2]) or 0, tonumber(c[3]) or 0)
	else
		color = DEFAULT_COLOR
	end
	return { name = active.name, emoji = type(active.emoji) == "string" and active.emoji or "", color = color }
end

local function specFromAttributes(pl)
	local name = pl:GetAttribute("PetName")
	if type(name) ~= "string" or name == "" then return nil end
	local emoji = pl:GetAttribute("PetEmoji")
	local color = pl:GetAttribute("PetColor")
	return {
		name = name,
		emoji = type(emoji) == "string" and emoji or "",
		color = typeof(color) == "Color3" and color or DEFAULT_COLOR,
	}
end

local function keyOf(spec)
	return spec.name .. "|" .. spec.emoji .. "|" .. spec.color:ToHex()
end

-- ===== golem builder =====
-- Parts are anchored and stored with a local offset from the pet's origin; the
-- animation loops re-place every part relative to a smoothed origin CFrame.
local function buildGolem(spec, isLocal)
	local color = spec.color
	local light = color:Lerp(Color3.new(1, 1, 1), 0.3)
	local bright = color:Lerp(Color3.new(1, 1, 1), 0.55)
	local dark = color:Lerp(Color3.fromRGB(35, 32, 55), 0.45) -- shade toward deep slate, not black

	local model = Instance.new("Model")
	model.Name = "GeodePet"
	local parts = {}
	local function crystal(size, offset, col, mat)
		local p = Instance.new("Part")
		p.Size = size
		p.Material = mat or Enum.Material.Glass -- real specular glint; Neon only for true emissives
		if p.Material == Enum.Material.Glass then
			p.Reflectance = 0.08
			p.Transparency = 0.08
		end
		p.Color = col
		p.Anchored = true
		p.CanCollide = false; p.CanQuery = false; p.CanTouch = false; p.CastShadow = false
		p.Parent = model
		parts[#parts + 1] = { p, offset }
		return p
	end

	-- Authored mesh template (ReplicatedStorage.PetModels.<pet name>) wins; the
	-- procedural crystal golem below is the fallback for pets without one yet.
	local tmplFolder = ReplicatedStorage:FindFirstChild("PetModels")
	local tmpl = tmplFolder and tmplFolder:FindFirstChild(spec.name)
	local torso
	if tmpl and (tmpl:IsA("Model") or tmpl:IsA("BasePart")) then
		local m = tmpl:Clone()
		local pivot = m:GetPivot()
		local moved = {}
		if m:IsA("BasePart") then moved[1] = m end
		for _, d in ipairs(m:GetDescendants()) do
			if d:IsA("BasePart") then moved[#moved + 1] = d end
		end
		for _, d in ipairs(moved) do
			d.Anchored = true
			d.CanCollide = false; d.CanQuery = false; d.CanTouch = false; d.CastShadow = false
			parts[#parts + 1] = { d, pivot:ToObjectSpace(d.CFrame) }
			d.Parent = model
			if not torso or d.Size.Magnitude > torso.Size.Magnitude then torso = d end
		end
		if m.Parent ~= model then m:Destroy() end
	end

	if not torso then
		-- torso (faceted crystal block), then head + facial + limbs + back spikes
		torso = crystal(Vector3.new(1.25, 1.5, 0.95), CFrame.Angles(0, math.rad(12), math.rad(6)), color)
		crystal(Vector3.new(0.55, 0.72, 0.55), CFrame.new(0, 0.05, 0.42) * CFrame.Angles(0, 0, math.rad(45)), bright, Enum.Material.Neon) -- chest heart (true emissive)
		crystal(Vector3.new(0.85, 0.8, 0.8), CFrame.new(0, 1.15, 0) * CFrame.Angles(0, math.rad(-10), 0), light) -- head
		crystal(Vector3.new(0.15, 0.18, 0.1), CFrame.new(-0.2, 1.22, 0.4), bright, Enum.Material.Neon) -- L eye
		crystal(Vector3.new(0.15, 0.18, 0.1), CFrame.new(0.2, 1.22, 0.4), bright, Enum.Material.Neon)  -- R eye
		crystal(Vector3.new(0.32, 0.95, 0.32), CFrame.new(-0.82, 0.15, 0) * CFrame.Angles(0, 0, math.rad(28)), color) -- L arm
		crystal(Vector3.new(0.32, 0.95, 0.32), CFrame.new(0.82, 0.15, 0) * CFrame.Angles(0, 0, math.rad(-28)), color) -- R arm
		crystal(Vector3.new(0.36, 0.6, 0.36), CFrame.new(-0.34, -0.98, 0), dark) -- L leg
		crystal(Vector3.new(0.36, 0.6, 0.36), CFrame.new(0.34, -0.98, 0), dark)  -- R leg
		for i = 1, 3 do -- back / shoulder crystal spikes
			local hgt = 0.9 + i * 0.18
			local xx = ({ -0.5, 0.55, 0 })[i]
			crystal(Vector3.new(0.26, hgt, 0.26), CFrame.new(xx, 0.55, -0.42)
				* CFrame.Angles(math.rad(-24), math.rad((i - 2) * 20), math.rad((i - 2) * 10)), bright)
		end
	end

	-- glow (local only) + sparkle + name on the torso
	if isLocal then
		local pl = Instance.new("PointLight")
		pl.Color = color; pl.Range = 5; pl.Brightness = 0.8; pl.Shadows = false; pl.Parent = torso
	end
	local att = Instance.new("Attachment"); att.Parent = torso
	local pe = Instance.new("ParticleEmitter")
	pe.Color = ColorSequence.new(bright); pe.Rate = isLocal and 6 or 0; pe.LightEmission = 1
	pe.Lifetime = NumberRange.new(0.6, 1.1); pe.Speed = NumberRange.new(0.4, 1.2)
	pe.SpreadAngle = Vector2.new(180, 180)
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 0) })
	pe.Parent = att
	local bb = Instance.new("BillboardGui")
	-- name-tag sized, hugging the pet (QA: label floated detached over empty space)
	bb.Size = UDim2.fromScale(2.8, 0.8)
	bb.StudsOffset = Vector3.new(0, torso.Size.Y / 2 + 0.9, 0)
	bb.AlwaysOnTop = isLocal
	bb.MaxDistance = isLocal and 60 or 40
	bb:SetAttribute("Signpost", false) -- never enters the Signposts clamp loop
	bb.Parent = torso
	local tl = Instance.new("TextLabel")
	tl.Size = UDim2.fromScale(1, 1); tl.BackgroundTransparency = 1
	tl.Text = (spec.emoji ~= "" and (spec.emoji .. " ") or "") .. spec.name
	tl.TextColor3 = light; tl.TextStrokeTransparency = 0.2; tl.TextScaled = true
	tl.Font = SG.Font.Heading; tl.Parent = bb

	return { model = model, parts = parts, torso = torso, pe = pe, bb = bb, key = keyOf(spec),
		origin = nil, shown = false, rate = isLocal and 6 or 0 }
end

local function destroyEntry(e)
	if e and e.model then e.model:Destroy() end
end

-- ===== local pet (snapshot-driven) =====
function PetView.Set(active)
	local spec = specFromActive(active)
	if not spec then
		if current then destroyEntry(current) end
		current = nil
		return
	end
	local key = keyOf(spec)
	if current and current.key == key then return end -- unchanged
	if current then destroyEntry(current) end
	current = buildGolem(spec, true)
	current.model.Parent = getFolder()
	current.shown = true
end

-- ===== other players (attribute-driven) =====
local function park(pet)
	if not pet.shown then return end
	pet.shown = false
	pet.model.Parent = nil
	if pet.rate ~= 0 then
		pet.rate = 0
		pet.pe.Rate = 0
	end
end

local function show(o, t)
	local pet = o.pet
	local target = targetFor(o._hrp, t + o.phase)
	if not pet.shown then
		-- (re)appear in place: no lerp from a stale origin
		pet.origin = target
		place(pet, target)
		pet.shown = true
		pet.model.Parent = getFolder()
	else
		pet.origin = pet.origin:Lerp(target, OTHER_LERP)
		place(pet, pet.origin)
	end
	local rate = o._dist <= PARTICLE_RANGE and particleRate() or 0
	if pet.rate ~= rate then
		pet.rate = rate
		pet.pe.Rate = rate
	end
end

local function rebuildOther(o)
	local spec = specFromAttributes(o.player)
	local key = spec and keyOf(spec) or nil
	if o.pet and o.pet.key == key then return end
	if o.pet then
		destroyEntry(o.pet)
		o.pet = nil
	end
	if spec then
		o.pet = buildGolem(spec, false) -- parked (Parent nil) until the tick picks it
	end
end

-- PetName / PetEmoji / PetColor change together in one Push: coalesce into one build
local function markDirty(o)
	if o.pending then return end
	o.pending = true
	task.delay(0.1, function()
		o.pending = false
		if others[o.player] ~= o then return end
		rebuildOther(o)
	end)
end

local function addPlayer(pl)
	if pl == player or others[pl] then return end
	local o = { player = pl, pet = nil, pending = false, phase = (pl.UserId % 7) * 0.9 }
	others[pl] = o
	o.attrConn = pl.AttributeChanged:Connect(function(name) -- ONE per player
		if name == "PetName" or name == "PetEmoji" or name == "PetColor" then markDirty(o) end
	end)
	rebuildOther(o)
end

local function removePlayer(pl)
	local o = others[pl]
	if not o then return end
	others[pl] = nil
	if o.attrConn then o.attrConn:Disconnect() end
	if o.pet then destroyEntry(o.pet) end
	o.pet = nil
end

-- ===== init =====
local live = {} -- reused per tick: candidates within RANGE
local function byDist(a, b) return a._dist < b._dist end

function PetView.Init(quality)
	Quality = quality
	PetView.Quality = quality
	getFolder()

	for _, pl in ipairs(Players:GetPlayers()) do addPlayer(pl) end
	Players.PlayerAdded:Connect(addPlayer)
	Players.PlayerRemoving:Connect(removePlayer)

	-- local pet: every frame (the one RenderStepped consumer in this module)
	RunService.RenderStepped:Connect(function()
		local e = current
		if not e then return end
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if not hrp then return end
		local target = targetFor(hrp, os.clock())
		e.origin = e.origin and e.origin:Lerp(target, LOCAL_LERP) or target
		place(e, e.origin)
	end)

	-- others: one Heartbeat connection, 15 Hz, nearest N within RANGE
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < TICK then return end
		acc = 0
		local t = os.clock()
		local origin = myPosition()
		table.clear(live)
		for _, o in pairs(others) do
			local pet = o.pet
			if pet then
				local char = o.player.Character
				local hrp = char and char:FindFirstChild("HumanoidRootPart")
				local dist = (hrp and origin) and (hrp.Position - origin).Magnitude or math.huge
				if hrp and dist <= RANGE then
					o._hrp, o._dist = hrp, dist
					live[#live + 1] = o
				else
					park(pet)
				end
			end
		end
		local n = nearCap()
		if #live > n then table.sort(live, byDist) end -- nearest N win
		for i, o in ipairs(live) do
			if i <= n then show(o, t) else park(o.pet) end
		end
	end)

	if Quality and Quality.Changed then
		Quality.Changed:Connect(function(field)
			if field ~= "Tier" then return end
			-- caps are read live each tick; force the particle rate to re-evaluate
			for _, o in pairs(others) do
				if o.pet and o.pet.shown then o.pet.rate = -1 end
			end
		end)
	end
end

return PetView
