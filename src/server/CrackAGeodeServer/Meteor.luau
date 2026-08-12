-- MeteorService: every ~10 minutes a Meteor Geode slams into the crater.
-- Shared HP scales with players online; cracking it triggers the SUPERNOVA.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local Lighting = game:GetService("Lighting")

local Meteor = {}
local S
local active = nil
local lastTap = {}

local function fireState(payload)
	S.Remotes.MeteorState:FireAllClients(payload)
end

local function playSound(id, parent, volume)
	local snd = Instance.new("Sound")
	snd.SoundId = id
	snd.Volume = volume or 1
	snd.RollOffMaxDistance = 400
	snd.Parent = parent
	snd:Play()
	Debris:AddItem(snd, 6)
end

local function supernova()
	if not active then return end
	local state = active
	active = nil
	local pos = state.part.Position

	fireState({ phase = "boom" })
	playSound(S.Config.Sounds.Boom, workspace.CrackAGeode.FX:FindFirstChildOfClass("Part") or state.part, 1)

	-- white-out flash
	local cc = Lighting:FindFirstChild("GeodeColor")
	if cc then
		TweenService:Create(cc, TweenInfo.new(0.12), { Brightness = 0.75 }):Play()
		task.delay(0.25, function()
			TweenService:Create(cc, TweenInfo.new(1.4), { Brightness = 0 }):Play()
		end)
	end

	-- expanding shockwave ring
	local ring = Instance.new("Part")
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(0.8, 6, 6)
	ring.CFrame = CFrame.new(0, 2, 0) * CFrame.Angles(0, 0, math.rad(90))
	ring.Anchored = true
	ring.CanCollide = false
	ring.Material = Enum.Material.Neon
	ring.Color = Color3.fromRGB(255, 235, 160)
	ring.Transparency = 0.1
	ring.Parent = workspace.CrackAGeode.FX
	TweenService:Create(ring, TweenInfo.new(1.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.8, 230, 230),
		Transparency = 1,
	}):Play()
	Debris:AddItem(ring, 1.5)

	-- loot-rain debris
	for i = 1, 40 do
		local chunk = Instance.new("Part")
		local s = 0.6 + math.random() * 1.2
		chunk.Size = Vector3.new(s, s, s)
		chunk.CFrame = CFrame.new(pos + Vector3.new(math.random(-4, 4), 3, math.random(-4, 4)))
		chunk.Material = Enum.Material.Neon
		chunk.Color = S.Config.Rarities[math.random(2, 5)].color
		chunk.CanCollide = true
		chunk.Parent = workspace.CrackAGeode.FX
		local a = math.random() * 6.283
		chunk.AssemblyLinearVelocity = Vector3.new(math.cos(a) * (20 + math.random(0, 25)), 45 + math.random(0, 30), math.sin(a) * (20 + math.random(0, 25)))
		Debris:AddItem(chunk, 4)
	end

	-- contribution-scaled payouts
	local playerCount = #Players:GetPlayers()
	local best, bestDmg = nil, 0
	for player, dmg in pairs(state.contrib) do
		if player.Parent then
			local share = dmg / state.maxHp
			local scale = math.clamp(0.5 + share * playerCount, 0.5, 2)
			local gained = S.Econ.AwardGems(player, S.Config.Balance.MeteorPayoutBase * scale)
			if S.Dailies then
				S.Dailies.Event(player, "earn", gained)
				S.Dailies.Event(player, "meteor", 1)
			end
			S.Remotes.Announce:FireClient(player, {
				kind = "meteor",
				text = "💥 SUPERNOVA! +" .. S.Config.Fmt(gained) .. " Gems!",
				color = Color3.fromRGB(255, 235, 160),
			})
			S.Econ.Push(player)
			if dmg > bestDmg then best, bestDmg = player, dmg end
		end
	end
	if best then
		S.Remotes.Announce:FireAllClients({
			kind = "meteor",
			text = "💥 " .. best.DisplayName .. " led the Meteor crack!",
			color = Color3.fromRGB(255, 235, 160),
		})
	end

	state.part:Destroy()
end

function Meteor.Spawn()
	local size = 13
	local meteor = Instance.new("Part")
	meteor.Name = "MeteorGeode"
	meteor.Shape = Enum.PartType.Ball
	meteor.Size = Vector3.new(size, size, size)
	meteor.CFrame = CFrame.new(75, 95, 55)
	meteor.Anchored = true
	meteor.Material = Enum.Material.CrackedLava
	meteor.Color = Color3.fromRGB(255, 130, 60)
	meteor.Parent = workspace.CrackAGeode.FX

	local att = Instance.new("Attachment")
	att.Parent = meteor
	local trail = Instance.new("ParticleEmitter")
	trail.Color = ColorSequence.new(Color3.fromRGB(255, 160, 70), Color3.fromRGB(255, 60, 30))
	trail.Rate = 60
	trail.Lifetime = NumberRange.new(0.5, 1.1)
	trail.Speed = NumberRange.new(3, 8)
	trail.SpreadAngle = Vector2.new(180, 180)
	trail.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.6), NumberSequenceKeypoint.new(1, 0.2) })
	trail.LightEmission = 1
	trail.Parent = att
	local pl = Instance.new("PointLight")
	pl.Color = Color3.fromRGB(255, 150, 70)
	pl.Range = 40
	pl.Brightness = 4
	pl.Parent = meteor

	local tween = TweenService:Create(meteor, TweenInfo.new(2.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		CFrame = CFrame.new(0, size / 2 - 2, 0),
	})
	tween:Play()
	tween.Completed:Wait()

	playSound(S.Config.Sounds.Boom, meteor, 0.9)
	fireState({ phase = "impact" })
	trail.Rate = 12

	local hp = S.Config.Balance.MeteorHPPerPlayer * math.max(1, #Players:GetPlayers())
	active = { part = meteor, hp = hp, maxHp = hp, contrib = {} }
	fireState({ phase = "active", hp = hp, maxHp = hp })

	local click = Instance.new("ClickDetector")
	click.MaxActivationDistance = 50
	click.Parent = meteor
	click.MouseClick:Connect(function(player)
		-- fireclickdetector bypasses MaxActivationDistance client-side, so the
		-- server re-validates range and rate-limits taps itself
		local now = os.clock()
		if lastTap[player] and now - lastTap[player] < 0.1 then return end
		lastTap[player] = now
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if not hrp or (hrp.Position - meteor.Position).Magnitude > 65 then return end
		Meteor.Damage(player, 1)
	end)
end

-- shared damage path (ClickDetector + test harness)
function Meteor.Damage(player, taps)
	for _ = 1, taps or 1 do
		if not active then return end
		local p = S.Data.Cache[player]
		if not p then return end
		local dmg = 1 + p.power
		active.hp -= dmg
		active.contrib[player] = (active.contrib[player] or 0) + dmg
		fireState({ phase = "active", hp = math.max(0, active.hp), maxHp = active.maxHp })
		if active.hp <= 0 then
			supernova()
			return
		end
	end
end

function Meteor.IsActive()
	return active ~= nil
end

local function fizzle()
	if not active then return end
	local state = active
	active = nil
	fireState({ phase = "dead" })
	TweenService:Create(state.part, TweenInfo.new(2), {
		CFrame = state.part.CFrame * CFrame.new(0, -16, 0),
		Transparency = 1,
	}):Play()
	Debris:AddItem(state.part, 2.2)
end

function Meteor.Init(services)
	S = services
	Players.PlayerRemoving:Connect(function(player)
		lastTap[player] = nil
	end)
	task.spawn(function()
		task.wait(20) -- let the server settle before the first cycle
		while true do
			local interval = workspace:GetAttribute("MeteorInterval") or S.Config.Balance.MeteorInterval
			task.wait(math.max(35, interval) - 30)
			S.Remotes.Announce:FireAllClients({
				kind = "warn",
				text = "☄️ METEOR GEODE incoming in 30 seconds — get to the crater!",
				color = Color3.fromRGB(255, 160, 80),
			})
			fireState({ phase = "warning", t = 30 })
			task.wait(30)
			Meteor.Spawn()
			local t0 = os.clock()
			while active and os.clock() - t0 < 60 do
				task.wait(0.25)
			end
			if active then fizzle() end
		end
	end)
end

return Meteor
