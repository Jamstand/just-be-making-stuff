-- GeodeService: the 5-second core loop. 14 nodes in a ring, ClickDetector taps,
-- server-side rolls + FX, respawn, Auto-Crack pass loop, Golden Geode products.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Geodes = {}
local S, Config, Remotes, Data, Econ
local nodes = {}
local lastCrack = {}
local lastHint = {} -- [player] = os.clock() of the last Golden-Geode bystander hint (1 per 10 s)

local ROCK_COLOR = Color3.fromRGB(58, 54, 78)
local ROCK_VARIANT = "GeodeRockPBR" -- PBR MaterialVariant (base Slate); authored in MaterialService

-- Show/hide every part + light of a node's geode model (used on crack / respawn).
-- Each part stores its resting transparency in a "BaseT" attribute so it restores.
local function setNodeShown(node, shown)
	for _, part in ipairs(node.parts) do
		part.Transparency = shown and (part:GetAttribute("BaseT") or 0) or 1
	end
	for _, l in ipairs(node.lights) do l.Enabled = shown end
	node.rock.CanCollide = shown
end

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
	if S and S.SFXGroup then s.SoundGroup = S.SFXGroup end -- each client's SFX slider scales this group
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
		shell.Material = Enum.Material.Slate
		shell.MaterialVariant = ROCK_VARIANT
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
		shard.Material = (i % 3 == 0) and Enum.Material.Neon or Enum.Material.Glass
		shard.Reflectance = (i % 3 == 0) and 0 or 0.08
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
	-- node ClickDetectors are live from Geodes.Init, before later modules (CollectPets,
	-- Dailies, ...) have Init'd: ignore taps until bootstrap finishes so a hook can never
	-- index its unset module state and strand the node
	if not (S and S.Ready) then return end
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

	local dropTable = zone and zone.geodes and zone.geodes[1] and zone.geodes[1].dropTable
	local rarityIdx = opts.forceRarity or Econ.RollRarity(player, dropTable)
	local mutIdx = opts.forceMutation or Econ.RollMutation(player)
	local gained, newEntry = Econ.RegisterFind(player, rarityIdx, mutIdx, node.valueMult, node.regionKey)
	-- sibling-system hooks are pcall'd: node.alive is already false and the respawn is only
	-- scheduled below, so a hook error must never abort the crack (it would strand the node)
	local okHooks, hookErr = pcall(function()
		if S.ServerGoals and S.ServerGoals.Event then -- co-op server goals (luck-only reward)
			S.ServerGoals.Event(player, "crack", 1)
			if rarityIdx >= 5 then S.ServerGoals.Event(player, "rare", 1) end
		end
		if S.CollectPets then S.CollectPets.MaybeDrop(player, node.regionKey) end -- Phase 3: pet drop chance
		if S.Dailies then
			S.Dailies.Event(player, "crack", 1)
			S.Dailies.Event(player, "earn", gained)
			if rarityIdx >= Config.LuckyTierIndex then S.Dailies.Event(player, "rare", 1) end
		end
	end)
	if not okHooks then warn("[Geodes] crack hook failed: " .. tostring(hookErr)) end

	setNodeShown(node, false)
	Geodes.CrackFX(node.pos, node.size, rarityIdx, mutIdx)

	Remotes.CrackFX:FireAllClients({
		nodeId = id, rarity = rarityIdx, mutation = mutIdx, gained = gained,
		userId = player.UserId, name = player.DisplayName,
		pos = node.pos, newEntry = newEntry,
	})

	local rar = Config.Rarities[rarityIdx]
	if rarityIdx >= 5 then
		local mutTag = mutIdx > 1 and (Config.Mutations[mutIdx].key .. " ") or ""
		-- token-bucketed (5 per 10 s, overflow coalesced) so a busy server never floods
		S.Social.Broadcast("rare", { text = "⭐ " .. player.DisplayName .. " found a " .. mutTag .. rar.name .. "!", userId = player.UserId, colorRGB = rar.color })
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
	setNodeShown(node, true)
end

-- Decorative helpers for the geode model.
local function geoPart(model, props)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	for k, v in pairs(props) do p[k] = v end
	p:SetAttribute("BaseT", p.Transparency)
	p.Parent = model
	return p
end

-- A crystal druse: a cluster of crystal points growing out of centerCF's +Y.
-- Mostly Glass (real specular glint) with every 4th point a Neon accent, so the
-- crust glints as the camera moves instead of glowing flatly.
local function crystalCluster(model, centerCF, count, spread, len, colors)
	for i = 1, count do
		local h = len * (0.55 + math.random() * 0.9)
		local glassy = (i % 4 ~= 0)
		local col = colors[math.random(#colors)]
		geoPart(model, {
			Name = "Crystal",
			Size = Vector3.new(h * (0.24 + math.random() * 0.14), h, h * (0.24 + math.random() * 0.14)),
			Material = glassy and Enum.Material.Glass or Enum.Material.Neon,
			Color = glassy and col:Lerp(Color3.new(1, 1, 1), 0.2) or col,
			Transparency = glassy and 0.12 or 0.05,
			Reflectance = glassy and 0.08 or 0,
			CFrame = centerCF
				* CFrame.new((math.random() - 0.5) * spread, 0, (math.random() - 0.5) * spread)
				* CFrame.Angles(math.rad(math.random(-32, 32)), math.rad(math.random(0, 360)), math.rad(math.random(-32, 32)))
				* CFrame.new(0, h * 0.5 - 0.15, 0),
		})
	end
end

-- One geode node: a rocky shell with an inner glow seen through glowing crack bands,
-- and a crystal druse breaking through the top. Every 4th node is a SPLIT variant
-- whose top has cracked open to reveal the crystal-lined hollow (the hero showpiece).
local function buildNode(id, ringIndex, ringCount, region)
	local theme = region.theme
	local size = 5.5 + (ringIndex % 3)
	local a = (ringIndex / ringCount) * math.pi * 2
	local radius = region.radius or Config.Balance.NodeRingRadius
	local pos = region.center + Vector3.new(math.cos(a) * radius, size / 2, math.sin(a) * radius)
	local crystals = theme.crystals
	local seamColor = crystals[(ringIndex % #crystals) + 1]
	local coreColor = crystals[((ringIndex + 1) % #crystals) + 1]
	local isSplit = (id % 4 == 0)

	local model = Instance.new("Model")
	model.Name = "Node" .. id
	model:SetAttribute("NodeId", id)

	-- rocky outer shell (the clickable, colliding part): a main boulder plus fused
	-- lumps in darker rock shades, so the silhouette reads boulder, not billiard ball
	local gm = game:GetService("ReplicatedStorage"):FindFirstChild("GeodeMeshes")
	local shellTmpl = gm and gm:FindFirstChild("GeodeShell")
	local rock
	if shellTmpl then
		-- authored PBR mesh shell: believable rocky silhouette, textures baked in
		rock = shellTmpl:Clone()
		rock.Size = Vector3.new(size, size * (isSplit and 0.88 or 0.96), size * 1.02)
		rock.CanCollide = true
		rock.CanQuery = true
	else
		rock = Instance.new("Part")
		rock.Shape = Enum.PartType.Ball
		rock.Size = Vector3.new(size, size * (isSplit and 0.88 or 0.96), size * 1.02)
		rock.Material = Enum.Material.Slate
		rock.MaterialVariant = ROCK_VARIANT
		rock.Color = theme.rock
	end
	rock.Name = "Rock"
	rock.CFrame = CFrame.new(pos) * CFrame.Angles(math.random() * 6, math.random() * 6, math.random() * 6)
	rock.Anchored = true
	rock:SetAttribute("BaseT", 0)
	rock.Parent = model
	for i = 1, (shellTmpl and 0 or 3) do
		local ls = size * (0.34 + math.random() * 0.22)
		local la = math.random() * math.pi * 2
		local lift = -size * 0.12 + math.random() * size * 0.3
		geoPart(model, {
			Name = "Lump", Shape = Enum.PartType.Ball,
			Size = Vector3.new(ls, ls * (0.8 + math.random() * 0.3), ls),
			CFrame = CFrame.new(pos + Vector3.new(math.cos(la) * size * 0.44, lift, math.sin(la) * size * 0.44))
				* CFrame.Angles(math.random() * 3, math.random() * 3, math.random() * 3),
			Material = Enum.Material.Slate, MaterialVariant = ROCK_VARIANT,
			Color = theme.rock:Lerp(Color3.new(0, 0, 0), 0.08 + 0.08 * i), Transparency = 0,
		})
	end

	-- inner glow core, seen faintly through the shell's crack bands
	local core = geoPart(model, {
		Name = "Core", Shape = Enum.PartType.Ball,
		Size = Vector3.new(size * 0.74, size * 0.74, size * 0.74),
		CFrame = CFrame.new(pos), Material = Enum.Material.Neon,
		Color = coreColor, Transparency = isSplit and 0.5 or 0.7,
	})
	if isSplit then
		local light = Instance.new("PointLight")
		light.Color = coreColor
		light.Brightness = 2.2
		light.Range = size * 2
		light.Shadows = false
		light.Parent = core
		TweenService:Create(light, TweenInfo.new(1.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Brightness = 1.5 }):Play()
	end

	-- THE crack-me affordance (QA): one bright glowing crack ring girdling the
	-- shell at a random tilt — reads as "this splits open here" on any shell
	-- (mesh or procedural), and keeps every node readable in dark pockets.
	geoPart(model, {
		Name = "CrackRing", Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.22, size * 1.04, size * 1.04),
		CFrame = CFrame.new(pos) * CFrame.Angles(math.random() * 0.9 - 0.45, math.random() * math.pi, math.rad(90) + (math.random() * 0.6 - 0.3)),
		Material = Enum.Material.Neon, Color = seamColor, Transparency = 0.35,
	})
	-- glowing cracks: thin seams sunk into the shell surface (no wrap-around hoops),
	-- each crusted with a tiny crystal or two pushing out of the fissure
	for _ = 1, (isSplit and 3 or 4) do
		local dir = Vector3.new(math.random() - 0.5, math.random() * 0.7 - 0.15, math.random() - 0.5)
		if dir.Magnitude < 0.05 then dir = Vector3.new(0, 1, 0) end
		dir = dir.Unit
		local at = pos + dir * (size * 0.5)
		local seamCF = CFrame.lookAt(at, at + dir) * CFrame.Angles(0, 0, math.random() * math.pi)
		geoPart(model, {
			Name = "Seam",
			Size = Vector3.new(0.24, size * (0.42 + math.random() * 0.2), 0.55),
			CFrame = seamCF,
			Material = Enum.Material.Neon, Color = seamColor, Transparency = 0.05,
		})
		for _ = 1, math.random(1, 2) do
			local ch = 0.5 + math.random() * 0.7
			geoPart(model, {
				Name = "CrackCrystal",
				Size = Vector3.new(ch * 0.32, ch, ch * 0.32),
				CFrame = seamCF
					* CFrame.new(0, (math.random() - 0.5) * size * 0.3, -(0.1 + ch * 0.3))
					* CFrame.Angles(math.rad(-90 + math.random(-24, 24)), math.rad(math.random(0, 360)), 0),
				Material = Enum.Material.Neon, Color = (math.random() < 0.5) and seamColor or coreColor, Transparency = 0.05,
			})
		end
	end

	-- crystal druse breaking through the top
	local mouthCF = CFrame.new(pos + Vector3.new(0, size * 0.34, 0))
	if isSplit then
		-- dark inner hollow + a fuller druse + a popped-off rock lid tilted to the side
		geoPart(model, {
			Name = "Cavity", Shape = Enum.PartType.Ball,
			Size = Vector3.new(size * 0.64, size * 0.5, size * 0.64),
			CFrame = CFrame.new(pos + Vector3.new(0, size * 0.26, 0)),
			Material = Enum.Material.Slate, Color = Color3.fromRGB(13, 11, 20), Transparency = 0,
		})
		crystalCluster(model, mouthCF, 14, size * 0.5, size * 0.44, crystals)
		geoPart(model, {
			Name = "Lid", Shape = Enum.PartType.Ball,
			Size = Vector3.new(size * 0.6, size * 0.32, size * 0.72),
			CFrame = CFrame.new(pos + Vector3.new(size * 0.52, size * 0.34, size * 0.12)) * CFrame.Angles(math.rad(36), math.rad(22), math.rad(30)),
			Material = Enum.Material.Slate, MaterialVariant = ROCK_VARIANT, Color = theme.rock, Transparency = 0,
		})
		for _ = 1, 2 do
			local rs = size * (0.14 + math.random() * 0.1)
			geoPart(model, {
				Name = "Rubble",
				Size = Vector3.new(rs, rs * 0.8, rs),
				CFrame = CFrame.new(pos + Vector3.new((math.random() - 0.5) * size * 1.5, -size * 0.42 + rs * 0.4, (math.random() - 0.5) * size * 1.5))
					* CFrame.Angles(math.random() * 3, math.random() * 3, math.random() * 3),
				Material = Enum.Material.Slate, MaterialVariant = ROCK_VARIANT, Color = theme.rock:Lerp(Color3.new(0, 0, 0), 0.15),
			})
		end
	else
		crystalCluster(model, mouthCF, 7, size * 0.34, size * 0.34, crystals)
	end

	local click = Instance.new("ClickDetector")
	click.MaxActivationDistance = Config.Balance.ClickRange
	click.Parent = rock
	click.MouseClick:Connect(function(player)
		Geodes.TryCrack(player, id)
	end)

	-- gather all parts + lights so crack / respawn can toggle the whole geode
	local parts, lights = {}, {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then parts[#parts + 1] = d
		elseif d:IsA("PointLight") then lights[#lights + 1] = d end
	end

	model.Parent = workspace.CrackAGeode.Nodes
	nodes[id] = { model = model, rock = rock, seam = rock, parts = parts, lights = lights,
		alive = true, size = size, pos = pos,
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
		if opened then return end
		if clicker ~= player then
			-- bystander tap: a rate-limited nudge to cheer the owner on (1 per 10 s per
			-- clicker; userId = the owner so the toast can offer a one-tap Cheer)
			if typeof(clicker) == "Instance" and clicker.Parent == Players and player.Parent == Players then
				local nowc = os.clock()
				if not lastHint[clicker] or nowc - lastHint[clicker] >= 10 then
					lastHint[clicker] = nowc
					S.Social.Tell(clicker, "info", {
						text = "That's " .. player.DisplayName .. "'s Golden Geode — cheer them on! 👏",
						userId = player.UserId,
					})
				end
			end
			return
		end
		opened = true
		local rarityIdx = (math.random() < 0.15) and 6 or 5
		local mutIdx = (math.random() < 0.05) and 4 or Econ.RollMutation(player)
		local gained, newEntry = Econ.RegisterFind(player, rarityIdx, mutIdx)
		if S.ServerGoals and S.ServerGoals.Event then S.ServerGoals.Event(player, "rare", 1) end -- always Ruby+
		Geodes.CrackFX(pos, size, rarityIdx, mutIdx)
		Remotes.CrackFX:FireAllClients({
			rarity = rarityIdx, mutation = mutIdx, gained = gained,
			userId = player.UserId, name = player.DisplayName, pos = pos, newEntry = newEntry,
		})
		local rar = Config.Rarities[rarityIdx]
		S.Social.Broadcast("rare", { text = "🌟 " .. player.DisplayName .. " cracked their Golden Geode: " .. rar.name .. "!", userId = player.UserId, colorRGB = rar.color })
		S.Boards.Feed(player.DisplayName, rar.name .. " (Golden)", mutIdx > 1 and Config.Mutations[mutIdx].key or nil)
		Econ.Push(player)
		model:Destroy()
	end
	local click = Instance.new("ClickDetector")
	click.MaxActivationDistance = 40
	click.Parent = rock
	click.MouseClick:Connect(openGolden)

	model.Parent = workspace.CrackAGeode.Nodes
	-- Expiry: a paid Golden Geode must never vanish unopened. After 300s it
	-- auto-opens for its owner (or quietly cleans up if they already left).
	task.delay(300, function()
		if opened or not model.Parent then return end
		if player.Parent then
			openGolden(player)
		else
			model:Destroy()
		end
	end)
	S.Social.Broadcast("golden", {
		text = isFree and ("🌟 " .. player.DisplayName .. " earned a GOLDEN GEODE from their streak!")
			or ("🌟 " .. player.DisplayName .. " bought a GOLDEN GEODE!"),
		userId = player.UserId,
		colorRGB = { 255, 210, 90 },
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
		lastHint[player] = nil
	end)

	-- Mobile CRACK button: crack the nearest in-range live node. Routed through
	-- TryCrack, which re-validates range + cooldown server-side, so this remote
	-- grants no advantage a normal tap wouldn't. Lightly rate-limited.
	local lastReq = {}
	Remotes.CrackRequest.OnServerEvent:Connect(function(player)
		if not S.Ready then return end -- bootstrap still running (same gate as TryCrack)
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