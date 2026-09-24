-- MeteorService: every ~10 minutes a Meteor Geode slams into the crater.
-- Shared HP scales with players online; cracking it triggers the SUPERNOVA.
--
--   MeteorState (S->all):
--     { phase = "warning", t = 30 }
--     { phase = "impact" }
--     { phase = "active", hp, maxHp, helpers:int, shares = { [tostring(userId)] = pct:int } }
--        — Damage only mutates + sets `dirty`; the 0.25 s cycle loop flushes it (≤ 4 Hz)
--     { phase = "boom", results = {{ userId, name, pct, gained }} (≤ 5, desc), mvpUserId }
--     { phase = "dead", nextAt:int }
--   Phase changes fire immediately. Meteor.NextAt() = os.time() of the next spawn
--   (0 while a meteor is live) for the snapshot's nextMeteorAt.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local Lighting = game:GetService("Lighting")

local Meteor = {}
local S
local active = nil
local lastTap = {}
local nextAt = 0        -- os.time() of the next meteor spawn (0 = unknown)
local recentStates = {} -- last 10 MeteorState payloads { phase, at = os.clock() } (TestHook `meteorState`)

local function fireState(payload)
	recentStates[#recentStates + 1] = { phase = payload.phase, at = os.clock() }
	while #recentStates > 10 do table.remove(recentStates, 1) end
	S.Remotes.MeteorState:FireAllClients(payload)
end

local function cycleLength()
	local interval = workspace:GetAttribute("MeteorInterval") or S.Config.Balance.MeteorInterval
	return math.max(35, tonumber(interval) or 600)
end

-- The next cycle's spawn time as predicted right now (the loop top re-derives it a
-- beat later from the same numbers).
local function predictNext()
	return os.time() + cycleLength()
end

function Meteor.NextAt()
	if active then return 0 end
	return nextAt
end

-- helpers = online contributors; shares = each one's % of the damage dealt so far
-- (floored, so the shares always sum to ≤ 100). Third value = total damage dealt.
local function sharesOf(state)
	local total, helpers = 0, 0
	for _, dmg in pairs(state.contrib) do total += dmg end
	local shares = {}
	if total > 0 then
		for pl, dmg in pairs(state.contrib) do
			if pl.Parent == Players then
				helpers += 1
				shares[tostring(pl.UserId)] = math.floor(dmg / total * 100)
			end
		end
	end
	return helpers, shares, total
end

-- Dirty-flagged `active` flush, called from the 0.25 s cycle loop: ≤ 4 events/s no
-- matter how many players tap how fast.
local function flushActive()
	if not (active and active.dirty) then return end
	active.dirty = false
	local helpers, shares = sharesOf(active)
	fireState({ phase = "active", hp = math.max(0, active.hp), maxHp = active.maxHp, helpers = helpers, shares = shares })
end

-- Timestamps of the last 10 MeteorState broadcasts (rate verification in Studio).
function Meteor.RecentStates()
	local out = table.create(#recentStates)
	for i, e in ipairs(recentStates) do out[i] = { phase = e.phase, at = e.at } end
	return out
end

local function playSound(id, parent, volume)
	local snd = Instance.new("Sound")
	snd.SoundId = id
	snd.Volume = volume or 1
	snd.RollOffMaxDistance = 400
	if S and S.SFXGroup then snd.SoundGroup = S.SFXGroup end -- each client's SFX slider scales this group
	snd.Parent = parent
	snd:Play()
	Debris:AddItem(snd, 6)
end

local function supernova()
	if not active then return end
	local state = active
	active = nil
	nextAt = predictNext()
	local pos = state.part.Position

	-- contribution-scaled payouts FIRST (all synchronous) so the boom carries the
	-- results card: top 5 by share, plus the MVP
	local playerCount = #Players:GetPlayers()
	local _, shares = sharesOf(state)
	local results = {}
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
			S.Social.Tell(player, "meteorPayout", {
				text = "💥 SUPERNOVA! +" .. S.Config.Cur(gained) .. "!",
				colorRGB = { 255, 235, 160 },
			})
			S.Econ.Push(player)
			results[#results + 1] = {
				userId = player.UserId, name = player.DisplayName,
				pct = shares[tostring(player.UserId)] or 0, gained = gained,
			}
			if dmg > bestDmg then best, bestDmg = player, dmg end
		end
	end
	table.sort(results, function(a, b)
		if a.pct ~= b.pct then return a.pct > b.pct end
		return a.userId < b.userId
	end)
	while #results > 5 do table.remove(results) end

	fireState({ phase = "boom", results = results, mvpUserId = best and best.UserId or nil })
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
		chunk.Material = Enum.Material.Glass -- loot gems glint under Future lighting
		chunk.Reflectance = 0.1
		chunk.Color = S.Config.Rarities[math.random(2, 5)].color
		chunk.CanCollide = true
		chunk.Parent = workspace.CrackAGeode.FX
		local a = math.random() * 6.283
		chunk.AssemblyLinearVelocity = Vector3.new(math.cos(a) * (20 + math.random(0, 25)), 45 + math.random(0, 30), math.sin(a) * (20 + math.random(0, 25)))
		Debris:AddItem(chunk, 4)
	end

	if best then
		S.Social.Broadcast("mvp", {
			text = "💥 " .. best.DisplayName .. " led the Meteor crack!",
			userId = best.UserId,
			colorRGB = { 255, 235, 160 },
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
	active = { part = meteor, hp = hp, maxHp = hp, contrib = {}, dirty = false }
	fireState({ phase = "active", hp = hp, maxHp = hp, helpers = 0, shares = {} })

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

-- shared damage path (ClickDetector + test harness): mutates hp/contrib and marks the
-- state dirty; the cycle loop broadcasts (so N tapping players never mean N×10 Hz fan-out)
function Meteor.Damage(player, taps)
	for _ = 1, taps or 1 do
		if not active then return end
		local p = S.Data.Cache[player]
		if not p then return end
		local dmg = 1 + p.power
		active.hp -= dmg
		active.contrib[player] = (active.contrib[player] or 0) + dmg
		active.dirty = true
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
	nextAt = predictNext()
	fireState({ phase = "dead", nextAt = nextAt })
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
	nextAt = os.time() + 20 + cycleLength() -- the first cycle starts after the settle wait
	task.spawn(function()
		task.wait(20) -- let the server settle before the first cycle
		while true do
			local total = cycleLength()
			nextAt = os.time() + total -- spawn time of this cycle (the HUD "Meteor in M:SS" clock)
			task.wait(total - 30)
			S.Social.Broadcast("warn", {
				text = "☄️ METEOR GEODE incoming in 30 seconds — get to the crater!",
				colorRGB = { 255, 160, 80 },
			})
			fireState({ phase = "warning", t = 30 })
			task.wait(30)
			Meteor.Spawn()
			local t0 = os.clock()
			while active and os.clock() - t0 < 60 do
				task.wait(0.25)
				flushActive() -- dirty-flagged: ≤ 4 `active` payloads/s
			end
			if active then fizzle() end
		end
	end)
end

return Meteor