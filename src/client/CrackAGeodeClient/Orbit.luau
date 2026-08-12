-- Orbit trophies: every player's best index finds orbit their avatar as neon shards.
-- Pure client-side rendering from index bitmasks — zero network cost per frame.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local UserInputService = game:GetService("UserInputService")

local Orbit = {}
local Config
local masks = {}   -- [userId] = mask
local rings = {}   -- [userId] = { parts = {..}, entries = {..} }
-- fewer orbiting trophy parts on mobile (each is a RenderStepped-driven part)
local MAX_ORBIT = (UserInputService.TouchEnabled and not UserInputService.MouseEnabled) and 6 or 12

local function entriesFromMask(mask)
	-- one shard per (rarity, mutation) found, best first, cap 12
	local entries = {}
	for r = 7, 1, -1 do
		for m = 4, 1, -1 do
			local bitIndex = (r - 1) * 4 + (m - 1)
			if bit32.band(mask, bit32.lshift(1, bitIndex)) ~= 0 then
				table.insert(entries, { rarity = r, mutation = m })
				if #entries >= MAX_ORBIT then return entries end
			end
		end
	end
	return entries
end

local function rebuild(userId)
	local ring = rings[userId]
	if ring then
		for _, part in ipairs(ring.parts) do part:Destroy() end
	end
	local mask = masks[userId]
	if not mask or mask == 0 then
		rings[userId] = nil
		return
	end
	local entries = entriesFromMask(mask)
	local parts = {}
	for i, e in ipairs(entries) do
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
		p.Material = Enum.Material.Neon
		p.Color = (e.mutation > 1 and mut.color) or rar.color
		p.Parent = workspace.CurrentCamera
		table.insert(parts, p)
	end
	rings[userId] = { parts = parts, entries = entries }
end

function Orbit.Sync(data)
	if masks[data.userId] == data.mask then return end
	masks[data.userId] = data.mask
	rebuild(data.userId)
end

function Orbit.Init(config)
	Config = config

	Players.PlayerRemoving:Connect(function(player)
		local ring = rings[player.UserId]
		if ring then
			for _, part in ipairs(ring.parts) do part:Destroy() end
		end
		rings[player.UserId] = nil
		masks[player.UserId] = nil
	end)

	RunService.RenderStepped:Connect(function()
		local t = os.clock()
		for _, player in ipairs(Players:GetPlayers()) do
			local ring = rings[player.UserId]
			if ring then
				local char = player.Character
				local hrp = char and char:FindFirstChild("HumanoidRootPart")
				if hrp then
					local n = #ring.parts
					for i, part in ipairs(ring.parts) do
						local a = t * 0.9 + (i / n) * math.pi * 2
						part.CFrame = CFrame.new(hrp.Position + Vector3.new(
							math.cos(a) * 2.7,
							0.4 + math.sin(t * 2 + i) * 0.35,
							math.sin(a) * 2.7
						)) * CFrame.Angles(0, a, math.rad(20))
					end
				else
					for _, part in ipairs(ring.parts) do
						part.CFrame = CFrame.new(0, -500, 0)
					end
				end
			end
		end
	end)
end

return Orbit
