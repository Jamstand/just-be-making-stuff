-- GeodeService: the 5-second core loop. 14 nodes in a ring, ClickDetector taps,
-- server-side rolls + FX, respawn, Auto-Crack pass loop, Golden Geode products.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Geodes = {}
local S, Config, Remotes, Data, Econ
local nodes = {}
local lastCrack = {}

local ROCK_COLOR = Color3.fromRGB(72, 68, 92)

local function fxPart(pos)
	local p = Instance.new("Part")
	p.Size = Vector3.new(0.4, 0.4, 0.4)
	p.Transparency = 1
	p.Anchored = true
	p.CanCollide = false
	p.CFrame = CFrame.new(pos)
	p.Parent = workspace.CrackAGeode.FX
	return p
end

local function playSound(id, parent, volume, speed)
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume or 0.7
	s.PlaybackSpeed = speed or 1
	s.RollOffMaxDistance = 150
	s.Parent = parent
	s:Play()
	Debris:AddItem(s, 5)
end

function Geodes.CrackFX(pos, size, rarityIdx, mutIdx)
	local rar = Config.Rarities[rarityIdx]
	local mut = Config.Mutations[mutIdx]
	local fx = workspace.CrackAGeode.FX
	local anchor = fxPart(pos)
	Debris:AddItem(anchor, 2)

	-- sound
	playSound(Config.Sounds.Crack, anchor, 0.8, 0.9 + math.random() * 0.2)
	if rarityIdx >= Config.LuckyTierIndex then
		playSound(Config.Sounds.Rare, anchor, 0.9, 1 + (rarityIdx - 4) * 0.06)
	end

	-- light flash
	local pl = Instance.new("PointLight")
	pl.Color = rar.color
	pl.Brightness = 10
	pl.Range = 24 + rarityIdx * 3
	pl.Parent = anchor
	TweenService:Create(pl, TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Brightness = 0 }):Play()

	-- particle burst
	local att = Instance.new("Attachment")
	att.Parent = anchor
	local pe = Instance.new("ParticleEmitter")
	pe.Color = ColorSequence.new(rar.color)
	pe.LightEmission = 1
	pe.Speed = NumberRange.new(8, 20)
	pe.Lifetime = NumberRange.new(0.4, 0.9)
	pe.SpreadAngle = Vector2.new(180, 180)
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 0.05) })
	pe.Enabled = false
	pe.Parent = att
	pe:Emit(math.min(24 + rarityIdx * 8, 70))
	if mutIdx == 4 then
		local pe2 = pe:Clone()
		pe2.Color = ColorSequence.new(Color3.fromRGB(255, 235, 130))
		pe2.Parent = att
		pe2:Emit(40)
	end

	-- two half shells fly apart with glowing inner lenses
	local dir = Vector3.new(math.cos(math.random() * 6.283), 0, math.sin(math.random() * 6.283))
	for sgn = -1, 1, 2 do
		local shell = Instance.new("Part")
		shell.Size = Vector3.new(size, size, size * 0.45)
		shell.CFrame = CFrame.lookAt(pos, pos + dir * sgn)
		shell.Anchored = true
		shell.CanCollide = false
		shell.Material = Enum.Material.Rock
		shell.Color = ROCK_COLOR
		shell.Parent = fx
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Parent = shell

		local inner = Instance.new("Part")
		inner.Size = Vector3.new(size * 0.84, size * 0.84, size * 0.18)
		inner.CFrame = shell.CFrame * CFrame.new(0, 0, -size * 0.14)
		inner.Anchored = true
		inner.CanCollide = false
		inner.Material = Enum.Material.Neon
		inner.Color = rar.color
		inner.Parent = fx
		local imesh = Instance.new("SpecialMesh")
		imesh.MeshType = Enum.MeshType.Sphere
		imesh.Parent = inner

		local target = CFrame.new(pos + dir * sgn * size * 0.95 + Vector3.new(0, 1.2, 0))
			* CFrame.lookAt(Vector3.zero, dir * sgn).Rotation
			* CFrame.Angles(math.rad(-58), 0, math.rad(math.random(-20, 20)))
		local ti = TweenInfo.new(0.38, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		TweenService:Create(shell, ti, { CFrame = target }):Play()
		TweenService:Create(inner, ti, { CFrame = target * CFrame.new(0, 0, -size * 0.14) }):Play()
		Debris:AddItem(shell, 1.5)
		Debris:AddItem(inner, 1.5)
	end

	-- crystal shards
	local shardScale = (mutIdx == 3) and 1.7 or 1
	local shardColor = mut.color or rar.color
	for i = 1, 6 + rarityIdx do
		local shard = Instance.new("Part")
		local h = (0.5 + math.random() * 0.9) * shardScale
		shard.Size = Vector3.new(h * 0.35, h, h * 0.35)
		shard.CFrame = CFrame.new(pos)
		shard.Anchored = true
		shard.CanCollide = false
		shard.Material = Enum.Material.Neon
		shard.Color = (i % 2 == 0) and rar.color or shardColor
		shard.Parent = fx
		local a = math.random() * 6.283
		local r = 2 + math.random() * 4
		local targetCF = CFrame.new(pos + Vector3.new(math.cos(a) * r, 1 + math.random() * 3.5, math.sin(a) * r))
			* CFrame.Angles(math.random() * 3, math.random() * 3, math.random() * 3)
		TweenService:Create(shard, TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { CFrame = targetCF }):Play()
		task.delay(0.55, function()
			if shard.Parent then
				TweenService:Create(shard, TweenInfo.new(0.5), { Transparency = 1 }):Play()
			end
		end)
		Debris:AddItem(shard, 1.2)
	end

	-- rising glow core
	local core = Instance.new("Part")
	core.Size = Vector3.new(size * 0.5, size * 0.5, size * 0.5)
	core.CFrame = CFrame.new(pos)
	core.Anchored = true
	core.CanCollide = false
	core.Material = Enum.Material.Neon
	core.Color = shardColor
	core.Shape = Enum.PartType.Ball
	core.Parent = fx
	TweenService:Create(core, TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		CFrame = CFrame.new(pos + Vector3.new(0, 5, 0)),
		Size = Vector3.new(0.2, 0.2, 0.2),
		Transparency = 1,
	}):Play()
	Debris:AddItem(core, 1)
end

function Geodes.TryCrack(player, id, opts)
	opts = opts or {}
	local node = nodes[id]
	if not (node and node.alive) then return end
	local p = Data.WaitFor(player, 5)
	if not p then return end
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then return end
	local zone = Config.Zones.Get(node.regionKey)
	if zone and not Config.Zones.IsUnlocked(zone, Config.Zones.StatsFor(p)) then return end -- zone not unlocked
	if (hrp.Position - node.pos).Magnitude > Config.Balance.ClickRange + 8 then return end
	local now = os.clock()
	local cd = Config.Cooldown(p.power)
	if lastCrack[player] and now - lastCrack[player] < cd - 0.05 then return end
	lastCrack[player] = now
	node.alive = false

	local rarityIdx = opts.forceRarity or Econ.RollRarity(player)
	local mutIdx = opts.forceMutation or Econ.RollMutation(player)
	local gained, newEntry = Econ.RegisterFind(player, rarityIdx, mutIdx, node.valueMult, node.regionKey)
	if S.CollectPets then S.CollectPets.MaybeDrop(player, node.regionKey) end -- Phase 3: pet drop chance
	if S.Dailies then
		S.Dailies.Event(player, "crack", 1)
		S.Dailies.Event(player, "earn", gained)
		if rarityIdx >= Config.LuckyTierIndex then S.Dailies.Event(player, "rare", 1) end
	end

	node.rock.Transparency = 1
	node.rock.CanCollide = false
	node.seam.Transparency = 1
	Geodes.CrackFX(node.pos, node.size, rarityIdx, mutIdx)

	Remotes.CrackFX:FireAllClients({
		nodeId = id, rarity = rarityIdx, mutation = mutIdx, gained = gained,
		userId = player.UserId, name = player.DisplayName,
		pos = node.pos, newEntry = newEntry,
	})

	local rar = Config.Rarities[rarityIdx]
	if rarityIdx >= 5 then
		local mutTag = mutIdx > 1 and (Config.Mutations[mutIdx].key .. " ") or ""
		Remotes.Announce:FireAllClients({ kind = "rare", text = "⭐ " .. player.DisplayName .. " found a " .. mutTag .. rar.name .. "!", color = rar.color })
		S.Boards.Feed(player.DisplayName, rar.name, mutIdx > 1 and Config.Mutations[mutIdx].key or nil)
	end

	Econ.Push(player)
	task.delay(Config.Balance.NodeRespawn, function()
		Geodes.Respawn(id)
	end)
end

function Geodes.Respawn(id)
	local node = nodes[id]
	if not node or node.alive then return end
	node.alive = true
	node.rock.CanCollide = true
	node.rock.Size = Vector3.new(1, 1, 1)
	node.rock.Transparency = 0
	node.seam.Transparency = 0.35
	TweenService:Create(node.rock, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Size = Vector3.new(node.size, node.size, node.size),
	}):Play()
end

-- One geode node in a region's ring. `ringIndex`/`ringCount` place it around the
-- region center; the region theme colors the rock + crystal seam; the node carries
-- its region's payout multiplier and rebirth unlock so TryCrack can gate + scale.
local function buildNode(id, ringIndex, ringCount, region)
	local theme = region.theme
	local size = 5.5 + (ringIndex % 3)
	local a = (ringIndex / ringCount) * math.pi * 2
	local radius = region.radius or Config.Balance.NodeRingRadius
	local pos = region.center + Vector3.new(math.cos(a) * radius, size / 2, math.sin(a) * radius)
	local seamColor = theme.crystals[(ringIndex % #theme.crystals) + 1]

	local model = Instance.new("Model")
	model.Name = "Node" .. id
	model:SetAttribute("NodeId", id)

	local rock = Instance.new("Part")
	rock.Name = "Rock"
	rock.Shape = Enum.PartType.Ball
	rock.Size = Vector3.new(size, size, size)
	rock.CFrame = CFrame.new(pos)
	rock.Anchored = true
	rock.Material = Enum.Material.Rock
	rock.Color = theme.rock
	rock.Parent = model

	local seam = Instance.new("Part")
	seam.Name = "Seam"
	seam.Shape = Enum.PartType.Cylinder
	seam.Size = Vector3.new(0.4, size + 0.35, size + 0.35)
	seam.CFrame = CFrame.new(pos) * CFrame.Angles(math.rad(math.random(-30, 30)), math.rad(math.random(0, 180)), math.rad(90))
	seam.Anchored = true
	seam.CanCollide = false
	seam.Material = Enum.Material.Neon
	seam.Color = seamColor
	seam.Transparency = 0.35
	seam.Parent = model

	local click = Instance.new("ClickDetector")
	click.MaxActivationDistance = Config.Balance.ClickRange
	click.Parent = rock
	click.MouseClick:Connect(function(player)
		Geodes.TryCrack(player, id)
	end)

	TweenService:Create(seam, TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Transparency = 0.75 }):Play()

	model.Parent = workspace.CrackAGeode.Nodes
	nodes[id] = { model = model, rock = rock, seam = seam, alive = true, size = size, pos = pos,
		valueMult = region.valueMult or 1, unlock = region.unlock or 0, regionKey = region.key }
end

-- Golden Geode: personal jackpot node by the crater (dev product / streak day 7)
function Geodes.SpawnGolden(player, isFree)
	local a = math.random() * 6.283
	local size = 9
	local pos = Vector3.new(math.cos(a) * 26, size / 2, math.sin(a) * 26)
	local model = Instance.new("Model")
	model.Name = "GoldenGeode_" .. player.UserId

	local rock = Instance.new("Part")
	rock.Shape = Enum.PartType.Ball
	rock.Size = Vector3.new(size, size, size)
	rock.CFrame = CFrame.new(pos)
	rock.Anchored = true
	rock.Material = Enum.Material.Foil
	rock.Color = Color3.fromRGB(255, 200, 60)
	rock.Parent = model
	local pl = Instance.new("PointLight")
	pl.Color = Color3.fromRGB(255, 210, 90); pl.Range = 30; pl.Brightness = 3; pl.Parent = rock

	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromScale(12, 2.6); bb.StudsOffset = Vector3.new(0, size / 2 + 2, 0)
	bb.AlwaysOnTop = true; bb.MaxDistance = 200; bb.Parent = rock
	local tl = Instance.new("TextLabel")
	tl.Size = UDim2.fromScale(1, 1); tl.BackgroundTransparency = 1
	tl.Text = "🌟 " .. player.DisplayName .. "'s GOLDEN GEODE"
	tl.TextColor3 = Color3.fromRGB(255, 220, 90); tl.TextStrokeTransparency = 0.1
	tl.TextScaled = true; tl.Font = Enum.Font.GothamBlack; tl.Parent = bb

	local opened = false
	local function openGolden(clicker)
		if clicker ~= player or opened then return end
		opened = true
		local rarityIdx = (math.random() < 0.15) and 6 or 5
		local mutIdx = (math.random() < 0.05) and 4 or Econ.RollMutation(player)
		local gained, newEntry = Econ.RegisterFind(player, rarityIdx, mutIdx)
		Geodes.CrackFX(pos, size, rarityIdx, mutIdx)
		Remotes.CrackFX:FireAllClients({
			rarity = rarityIdx, mutation = mutIdx, gained = gained,
			userId = player.UserId, name = player.DisplayName, pos = pos, newEntry = newEntry,
		})
		local rar = Config.Rarities[rarityIdx]
		Remotes.Announce:FireAllClients({ kind = "rare", text = "🌟 " .. player.DisplayName .. " cracked their Golden Geode: " .. rar.name .. "!", color = rar.color })
		S.Boards.Feed(player.DisplayName, rar.name .. " (Golden)", mutIdx > 1 and Config.Mutations[mutIdx].key or nil)
		Econ.Push(player)
		model:Destroy()
	end
	local click = Instance.new("ClickDetector")
	click.MaxActivationDistance = 40
	click.Parent = rock
	click.MouseClick:Connect(openGolden)

	model.Parent = workspace.CrackAGeode.Nodes
	Debris:AddItem(model, 300)
	Remotes.Announce:FireAllClients({
		kind = "golden",
		text = isFree and ("🌟 " .. player.DisplayName .. " earned a GOLDEN GEODE from their streak!")
			or ("🌟 " .. player.DisplayName .. " bought a GOLDEN GEODE!"),
		color = Color3.fromRGB(255, 210, 90),
	})
	return { model = model, Open = openGolden }
end

function Geodes.Init(services)
	S = services
	Config, Remotes, Data, Econ = S.Config, S.Remotes, S.Data, S.Econ

	-- Build a themed geode ring for every region (hub + unlockable biomes).
	local nextId = 0
	for _, region in ipairs(Config.Regions) do
		local count = region.nodeCount or Config.Balance.NodeCount
		for k = 1, count do
			nextId += 1
			buildNode(nextId, k, count, region)
		end
	end

	Players.PlayerRemoving:Connect(function(player)
		lastCrack[player] = nil
	end)

	-- Mobile CRACK button: crack the nearest in-range live node. Routed through
	-- TryCrack, which re-validates range + cooldown server-side, so this remote
	-- grants no advantage a normal tap wouldn't. Lightly rate-limited.
	local lastReq = {}
	Remotes.CrackRequest.OnServerEvent:Connect(function(player)
		local nowc = os.clock()
		if lastReq[player] and nowc - lastReq[player] < 0.05 then return end
		lastReq[player] = nowc
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if not hrp then return end
		local bestId, bestDist
		for id, node in pairs(nodes) do
			if node.alive and type(id) == "number" then
				local d = (node.pos - hrp.Position).Magnitude
				if d <= Config.Balance.ClickRange and (not bestDist or d < bestDist) then
					bestId, bestDist = id, d
				end
			end
		end
		if bestId then Geodes.TryCrack(player, bestId) end
	end)
	Players.PlayerRemoving:Connect(function(player) lastReq[player] = nil end)

	-- Auto-Crack pass: hands-free cracking of any live node in radius
	task.spawn(function()
		while true do
			task.wait(0.2)
			for _, player in ipairs(Players:GetPlayers()) do
				local p = Data.Cache[player]
				if p and S.Monetize.Owns(player, "AutoCrack") then
					local char = player.Character
					local hrp = char and char:FindFirstChild("HumanoidRootPart")
					if hrp then
						local nowc = os.clock()
						if not lastCrack[player] or nowc - lastCrack[player] >= Config.Cooldown(p.power) then
							local radius = 8 + (p.perks.AutoRadius and 4 or 0)
							for id, node in pairs(nodes) do
								if node.alive and type(id) == "number" and (node.pos - hrp.Position).Magnitude <= radius + node.size / 2 then
									Geodes.TryCrack(player, id)
									break
								end
							end
						end
					end
				end
			end
		end
	end)
end

return Geodes
