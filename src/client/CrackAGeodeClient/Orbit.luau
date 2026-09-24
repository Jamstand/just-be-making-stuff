-- Orbit trophies: every player's best index finds orbit their avatar as neon shards.
-- Pure client-side rendering from index bitmasks — zero network cost per frame.
-- Runs on Heartbeat with a distance cull: rings beyond 120 studs are parked once
-- (not rewritten per frame), 40-120 studs animate at 15 Hz, closer ones every
-- frame; a missing character parks its ring once. Ring size (4/6/12 shards) and
-- the total animated-part budget (24/48) follow Quality.Tier and rebuild live.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Orbit = {}
local Config, Quality
local player = Players.LocalPlayer
local masks = {}   -- [userId] = mask
local rings = {}   -- [userId] = { parts = {..}, entries = {..}, parked = bool, lastT = number }

local PARK_CF = CFrame.new(0, -500, 0)
local FAR = 120          -- beyond: parked
local MID = 40           -- beyond: 15 Hz
local MID_RATE = 1 / 15

local function tier()
	return (Quality and Quality.Tier) or 2
end
local RING_CAP = { [0] = 4, [1] = 6, [2] = 12 }
local function ringCap()
	return RING_CAP[tier()] or 12
end
local function totalCap()
	return tier() >= 2 and 48 or 24
end

local function entriesFromMask(mask, cap)
	-- one shard per (rarity, mutation) found, best first, capped per tier
	local entries = {}
	for r = 7, 1, -1 do
		for m = 4, 1, -1 do
			local bitIndex = (r - 1) * 4 + (m - 1)
			if bit32.band(mask, bit32.lshift(1, bitIndex)) ~= 0 then
				table.insert(entries, { rarity = r, mutation = m })
				if #entries >= cap then return entries end
			end
		end
	end
	return entries
end

local function destroyRing(userId)
	local ring = rings[userId]
	if ring then
		for _, part in ipairs(ring.parts) do part:Destroy() end
	end
	rings[userId] = nil
end

local function rebuild(userId)
	destroyRing(userId)
	local mask = masks[userId]
	if not mask or mask == 0 then return end
	local entries = entriesFromMask(mask, ringCap())
	local parts = {}
	for _, e in ipairs(entries) do
		local rar = Config.Rarities[e.rarity]
		local mut = Config.Mutations[e.mutation]
		local p = Instance.new("Part")
		local s = 0.34 + e.rarity * 0.05 + (e.mutation - 1) * 0.05
		p.Size = Vector3.new(s * 0.6, s, s * 0.6)
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Material = Enum.Material.Glass -- gem trophies glint instead of glowing flatly
		p.Reflectance = 0.1
		p.Color = (e.mutation > 1 and mut.color) or rar.color
		p.CFrame = PARK_CF
		p.Parent = workspace.CurrentCamera
		table.insert(parts, p)
	end
	rings[userId] = { parts = parts, entries = entries, parked = true, lastT = 0 }
end

local function park(ring)
	if ring.parked then return end
	ring.parked = true
	for _, part in ipairs(ring.parts) do part.CFrame = PARK_CF end
end

local function animate(ring, hrp, t)
	ring.parked = false
	ring.lastT = t
	local n = #ring.parts
	local base = hrp.Position
	for i, part in ipairs(ring.parts) do
		local a = t * 0.9 + (i / n) * math.pi * 2
		-- diamond-orient + slow tumble so the gems read as crystals,
		-- not flat floating quads (QA)
		part.CFrame = CFrame.new(base + Vector3.new(
			math.cos(a) * 2.7,
			0.4 + math.sin(t * 2 + i) * 0.35,
			math.sin(a) * 2.7
		)) * CFrame.Angles(t * 1.4 + i * 2, a, math.rad(45))
	end
end

function Orbit.Sync(data)
	if type(data) ~= "table" or type(data.userId) ~= "number" or type(data.mask) ~= "number" then return end
	if masks[data.userId] == data.mask then return end
	masks[data.userId] = data.mask
	rebuild(data.userId)
end

local live = {} -- reused per frame: rings that want animating this frame
local function byDist(a, b) return a._dist < b._dist end

function Orbit.Init(config, quality)
	Config = config
	Quality = quality

	Players.PlayerRemoving:Connect(function(pl)
		destroyRing(pl.UserId)
		masks[pl.UserId] = nil
	end)

	if Quality and Quality.Changed then
		Quality.Changed:Connect(function(field)
			if field == "Tier" then
				for uid in pairs(masks) do rebuild(uid) end
			end
		end)
	end

	RunService.Heartbeat:Connect(function()
		local t = os.clock()
		local myChar = player.Character
		local myHrp = myChar and myChar:FindFirstChild("HumanoidRootPart")
		local cam = workspace.CurrentCamera
		local origin = (myHrp and myHrp.Position) or (cam and cam.CFrame.Position) or Vector3.zero

		table.clear(live)
		local liveParts = 0
		for _, pl in ipairs(Players:GetPlayers()) do
			local ring = rings[pl.UserId]
			if ring then
				local char = pl.Character
				local hrp = char and char:FindFirstChild("HumanoidRootPart")
				if not hrp then
					park(ring)
				else
					local dist = (hrp.Position - origin).Magnitude
					if dist > FAR then
						park(ring)
					elseif dist > MID and (t - ring.lastT) < MID_RATE then
						-- mid range: hold at 15 Hz (keeps whatever pose it has)
					else
						ring._hrp = hrp
						ring._dist = dist
						live[#live + 1] = ring
						liveParts += #ring.parts
					end
				end
			end
		end

		local budget = totalCap()
		if liveParts > budget then table.sort(live, byDist) end -- nearest rings win the budget
		for _, ring in ipairs(live) do
			local n = #ring.parts
			if n <= budget then
				budget -= n
				animate(ring, ring._hrp, t)
			else
				park(ring)
			end
		end
	end)
end

return Orbit
