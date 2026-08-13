-- ShardService: the explorer gate for Sunken Grotto. Five hidden glowing shards
-- are tucked around Zone 1 (behind mounds / on shelves / far edges). Each player
-- collects each shard once (touch or click); at 5 found, Sunken Grotto unlocks
-- (the zone gate reads p.zoneShards.Sunken via Zones.StatsFor). Shards are subtle:
-- short-range glow, no map beacon — you have to explore to find them.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Shards = {}
local S
local NEEDED = 5
local TARGET = "Sunken"
local COLOR = Color3.fromRGB(90, 230, 210)

-- hand-placed hidden spots (XZ); Y is raycast onto the terrain so they sit on the
-- ground behind cover rather than floating or buried.
local SPOTS = {
	Vector3.new(-124, 0, 24),   -- far west wall base, behind mounds
	Vector3.new(120, 0, -18),   -- far east wall base
	Vector3.new(-24, 0, 122),   -- far north perimeter
	Vector3.new(58, 0, 108),    -- NE, tucked past the garden ring
	Vector3.new(-96, 0, -80),   -- SW corner, behind stalagmites
}

local function surfaceY(x, z)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { workspace.Terrain }
	local r = workspace:Raycast(Vector3.new(x, 80, z), Vector3.new(0, -160, 0), params)
	return r and r.Position.Y or 0
end

function Shards.Collect(player, id)
	local p = S.Data.Cache[player]
	if not p then return end
	p.foundShards = p.foundShards or {}
	p.zoneShards = p.zoneShards or {}
	local skey = "s" .. id -- string key survives DataStore JSON round-trip
	if p.foundShards[skey] then return end -- already collected by this player
	p.foundShards[skey] = true
	local n = (p.zoneShards[TARGET] or 0) + 1
	p.zoneShards[TARGET] = n
	if S.Data.SaveSoon then S.Data.SaveSoon(player) end
	S.Econ.Push(player) -- refresh snapshot -> counter UI + Nexus progress
	S.Remotes.Announce:FireClient(player, {
		kind = "shard",
		text = "🔹 Hidden Shard found!  (" .. n .. "/" .. NEEDED .. ")",
		color = COLOR,
	})
	if n >= NEEDED then
		S.Remotes.Announce:FireAllClients({
			kind = "unlock",
			text = "🐚 " .. player.DisplayName .. " found all 5 shards — Sunken Grotto unlocked!",
			color = COLOR,
		})
	end
end

local function makeShard(id, xz, parent)
	local pos = Vector3.new(xz.X, surfaceY(xz.X, xz.Z) + 1.6, xz.Z)
	local model = Instance.new("Model")
	model.Name = "HiddenShard" .. id

	local shard = Instance.new("Part")
	shard.Name = "Shard"
	shard.Size = Vector3.new(1.0, 2.6, 1.0)
	shard.CFrame = CFrame.new(pos) * CFrame.Angles(0, math.rad(id * 40), math.rad(12))
	shard.Anchored = true
	shard.CanCollide = false
	shard.CanQuery = true
	shard.Material = Enum.Material.Neon
	shard.Color = COLOR
	shard.Transparency = 0.12
	shard:SetAttribute("ShardId", id)
	shard.Parent = model

	local pl = Instance.new("PointLight")
	pl.Color = COLOR; pl.Range = 9; pl.Brightness = 1.3; pl.Shadows = false; pl.Parent = shard
	local att = Instance.new("Attachment"); att.Parent = shard
	local pe = Instance.new("ParticleEmitter")
	pe.Color = ColorSequence.new(COLOR); pe.Rate = 6; pe.LightEmission = 1
	pe.Lifetime = NumberRange.new(0.6, 1.2); pe.Speed = NumberRange.new(0.4, 1.4)
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(1, 0) })
	pe.SpreadAngle = Vector2.new(180, 180); pe.Parent = att

	TweenService:Create(shard, TweenInfo.new(1.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ CFrame = shard.CFrame + Vector3.new(0, 1.0, 0) }):Play()

	local click = Instance.new("ClickDetector")
	click.MaxActivationDistance = 16
	click.Parent = shard
	click.MouseClick:Connect(function(plr) Shards.Collect(plr, id) end)

	model.Parent = parent
end

function Shards.Init(services)
	S = services
	local folder = Instance.new("Folder")
	folder.Name = "HiddenShards"
	folder.Parent = workspace.CrackAGeode
	for id, xz in ipairs(SPOTS) do
		makeShard(id, xz, folder)
	end

	-- Deterministic proximity collection (Touched is flaky for anchored,
	-- non-colliding parts): walk within range of an uncollected shard to grab it.
	task.spawn(function()
		while true do
			task.wait(0.4)
			for _, player in ipairs(Players:GetPlayers()) do
				local p = S.Data.Cache[player]
				local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
				if p and hrp then
					for _, m in ipairs(folder:GetChildren()) do
						local s = m:FindFirstChild("Shard")
						local id = s and s:GetAttribute("ShardId")
						if s and id and not (p.foundShards and p.foundShards["s" .. id]) then
							if (hrp.Position - s.Position).Magnitude <= 10 then
								Shards.Collect(player, id)
							end
						end
					end
				end
			end
		end
	end)
end

return Shards
