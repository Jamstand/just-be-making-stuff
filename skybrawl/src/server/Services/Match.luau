--[[
    One running match in one arena.

    Authority split:
      - Each player's client simulates its own fighter (FighterSim) and
        reports what it does: attacks, dodges, throws, and melee hits it saw.
      - The server checks those reports (timing, range, invulnerability,
        teams), owns damage/knockback/KOs/stocks/weapons/projectiles, and
        tells the victim's client how far to fly.
      - Bots are simulated entirely on the server with the same FighterSim.
      - Every fighter plays a legend (Legends.luau): its signatures and
        Dexterity timing come from Legends.getAttack, and Strength/Defense
        scale damage here. Legends with imported art get their visual rig
        (LegendRig) on top of the Roblox character.

    Lifecycle: Loading -> Countdown -> Playing -> Ended
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Maps = require(Shared.Maps)
local Weapons = require(Shared.Weapons)
local WeaponModels = require(Shared.WeaponModels)
local FighterSim = require(Shared.FighterSim)
local Combat = require(Shared.Combat)
local Cosmetics = require(Shared.Cosmetics)
local Ranks = require(Shared.Ranks)
local Legends = require(Shared.Legends)
local LegendRig = require(Shared.LegendRig)
local Util = require(Shared.Util)
local Net = require(Shared.Net)

local BotBrain = require(script.Parent.BotBrain)

local Match = {}
Match.__index = Match

local GRAVEYARD_Y = 600
local SKIN_TONES = {
	Color3.fromRGB(255, 220, 190), Color3.fromRGB(234, 184, 146), Color3.fromRGB(198, 134, 98),
	Color3.fromRGB(141, 85, 54), Color3.fromRGB(96, 62, 40), Color3.fromRGB(255, 205, 150),
}
local SHIRT_COLORS = {
	Color3.fromRGB(70, 130, 220), Color3.fromRGB(220, 80, 80), Color3.fromRGB(90, 190, 110),
	Color3.fromRGB(230, 170, 60), Color3.fromRGB(160, 100, 220), Color3.fromRGB(60, 190, 190),
}

function Match.new(id, config, services)
	local self = setmetatable({}, Match)
	self.id = id
	self.config = config
	self.services = services
	self.map = Maps.get(config.mapId)
	self.world = Maps.getWorld(config.mapId)
	self.slot, self.origin = services.ArenaService.acquire()
	assert(self.slot, "no free arena slot")
	self.folder = services.ArenaService.buildMap(config.mapId, self.origin, self.slot)

	self.fighters = {} -- [fighterId] = fighter
	self.order = {} -- fighter ids in join order
	self.playerFighters = {} -- [Player] = fighter
	self.pickups = {} -- [id] = pickup
	self.projectiles = {} -- [id] = projectile
	self.phase = "Loading"
	self.nextObjectId = 0
	self.respawnIndex = 0
	self.rng = Random.new()
	self.connections = {}
	self.nextPickupAt = math.huge

	self.allowedWeapons = {}
	self.allowedSet = {}
	for _, weaponId in Weapons.Order do
		if config.weapons == nil or config.weapons[weaponId] then
			table.insert(self.allowedWeapons, weaponId)
			self.allowedSet[weaponId] = true
		end
	end
	return self
end

-- Fighters ----------------------------------------------------------------

local function teamColor(team)
	return Config.TeamColors[team] or Color3.new(1, 1, 1)
end

function Match:newFighter(id, team)
	local f = {
		id = id,
		team = team,
		name = id,
		userId = 0,
		isBot = false,
		stocks = self.config.winRule == "Stocks" and self.config.stocks or 0,
		score = 0,
		damage = 0,
		weapon = "Unarmed",
		alive = true,
		eliminated = false,
		eliminatedAt = 0,
		left = false,
		invulnUntil = 0, -- respawn invulnerability
		dodgeInvulnUntil = 0, -- from dodges; an attack (gravity cancel) ends it
		lastHitBy = nil,
		lastHitTime = 0,
		hitstunUntil = 0,
		lastHitDealt = 0,
		comboBy = nil,
		comboCount = 0,
		comboTrue = false,
		legend = "Avatar",
		lastWeapon = nil,
		kos = 0,
		falls = 0,
		damageDealt = 0,
		damageTaken = 0,
		attacks = {},
		attackOrder = {},
		facing = 1,
		feetOffset = 3,
		lastX = 0,
		lastY = 0,
		ready = false,
		awaitingSpawn = false,
		awaitingUntil = 0,
		actionBudget = Config.Combat.MaxActionsPerSecond,
		budgetClock = os.clock(),
		level = 1,
	}
	self.fighters[id] = f
	table.insert(self.order, id)
	return f
end

function Match:AddPlayer(player, team)
	local f = self:newFighter("p" .. player.UserId, team)
	f.player = player
	f.name = player.DisplayName
	f.userId = player.UserId
	local profile = self.services.DataService.get(player)
	if profile then
		f.weaponColor = profile.Equipped.WeaponColor
		f.koEffect = profile.Equipped.KOEffect
		f.trail = profile.Equipped.Trail
		f.level = Ranks.levelFromXP(profile.XP)
		local title = Cosmetics.resolve("Title", profile.Equipped.Title)
		f.title = title and title.Name
		f.legend = Legends.isValid(profile.Legend) and profile.Legend or Legends.Default
	end
	if self.config.ranked then
		f.rating = self.services.ProgressionService.ratingOf(player, self.config.mode)
	end
	self.playerFighters[player] = f
	return f
end

function Match:AddBot(difficulty, team, name)
	self.nextObjectId += 1
	local f = self:newFighter("b" .. self.nextObjectId, team)
	f.isBot = true
	f.difficulty = Config.Bots.Difficulties[difficulty] and difficulty or "Normal"
	f.name = name or Util.pick(Config.Bots.Names, self.rng)
	f.weaponColor = Cosmetics.Defaults.WeaponColor
	f.koEffect = Cosmetics.Defaults.KOEffect
	f.title = f.difficulty .. " Bot"
	local roster = {}
	for _, id in Legends.Order do
		if id ~= "Avatar" then
			table.insert(roster, id)
		end
	end
	f.legend = Util.pick(roster, self.rng)
	return f
end

function Match:SameTeam(a, b)
	return a.team == b.team
end

function Match:GetPosition(f)
	if f.isBot then
		if f.state then
			return f.state.x, f.state.y
		end
		return f.lastX, f.lastY
	end
	local root = f.root
	if root and root.Parent then
		local p = root.Position - self.origin
		f.lastX, f.lastY = p.X, p.Y - f.feetOffset
	end
	return f.lastX, f.lastY
end

function Match:IsInvulnerable(f)
	local now = os.clock()
	if now < f.invulnUntil or now < f.dodgeInvulnUntil then
		return true
	end
	return f.isBot and f.state ~= nil and FighterSim.isInvulnerable(f.state)
end

function Match:IsAttacking(f)
	if f.isBot then
		return f.state ~= nil and f.state.action == "Attack"
	end
	local seq = f.attackOrder[#f.attackOrder]
	local rec = seq and f.attacks[seq]
	if not rec then
		return false
	end
	return os.clock() - rec.start < rec.move.Startup + rec.move.Active + (rec.move.Charge or 0)
end

function Match:fighterInfo(f)
	return {
		id = f.id,
		name = f.name,
		userId = f.userId,
		isBot = f.isBot,
		team = f.team,
		color = teamColor(f.team),
		model = f.model,
		level = f.level,
		title = f.title,
		stocks = f.stocks,
		score = f.score,
		damage = f.damage,
		weapon = f.weapon,
		rating = f.rating,
		legend = f.legend,
	}
end

-- Networking --------------------------------------------------------------

function Match:Broadcast(kind, data, except)
	local remote = Net.get("MatchEvent")
	for player, f in self.playerFighters do
		if not f.left and player ~= except and player.Parent then
			remote:FireClient(player, kind, data)
		end
	end
end

function Match:Send(player, kind, data)
	if player.Parent then
		Net.get("MatchEvent"):FireClient(player, kind, data)
	end
end

-- Setup -------------------------------------------------------------------

local function disableHumanoidStates(humanoid)
	for _, state in {
		Enum.HumanoidStateType.FallingDown,
		Enum.HumanoidStateType.Ragdoll,
		Enum.HumanoidStateType.GettingUp,
		Enum.HumanoidStateType.Climbing,
		Enum.HumanoidStateType.Swimming,
		Enum.HumanoidStateType.Seated,
		Enum.HumanoidStateType.Jumping,
		Enum.HumanoidStateType.Freefall,
		Enum.HumanoidStateType.Running,
		Enum.HumanoidStateType.Landed,
		Enum.HumanoidStateType.Flying,
		Enum.HumanoidStateType.StrafingNoPhysics,
	} do
		humanoid:SetStateEnabled(state, false)
	end
	humanoid:ChangeState(Enum.HumanoidStateType.Physics)
end

function Match:spawnBotModel(f)
	local desc = Instance.new("HumanoidDescription")
	local skin = Util.pick(SKIN_TONES, self.rng)
	local shirt = Util.pick(SHIRT_COLORS, self.rng)
	local pants = shirt:Lerp(Color3.fromRGB(30, 30, 40), 0.6)
	desc.HeadColor = skin
	desc.LeftArmColor = skin
	desc.RightArmColor = skin
	desc.TorsoColor = shirt
	desc.LeftLegColor = pants
	desc.RightLegColor = pants

	local ok, model = pcall(function()
		return Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R15)
	end)
	if not ok or not model then
		warn("[Match] couldn't create bot model:", model)
		return false
	end
	model.Name = f.name
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	for _, d in model:GetDescendants() do
		if d:IsA("LocalScript") or d:IsA("Script") then
			d:Destroy()
		end
	end
	humanoid.MaxHealth = 100
	humanoid.Health = 100
	f.model = model
	f.root = root
	f.humanoid = humanoid
	f.feetOffset = Util.feetOffset(model)
	-- Anchored until GO so the bot doesn't fall while players load in.
	root.Anchored = true
	model.Parent = self.folder
	disableHumanoidStates(humanoid)
	self.services.CharacterService.setupCharacter(model)
	self.services.CharacterService.setNameplate(model, {
		name = f.name,
		title = f.title,
		color = teamColor(f.team),
	})
	model:SetAttribute("FighterId", f.id)
	model:SetAttribute("Legend", f.legend)
	LegendRig.attach(model, f.legend)
	return true
end

function Match:preparePlayer(f)
	local player = f.player
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not humanoid or humanoid.Health <= 0 or not character:FindFirstChild("HumanoidRootPart") then
		pcall(function()
			player:LoadCharacter()
		end)
		local deadline = os.clock() + 8
		repeat
			task.wait(0.1)
			character = player.Character
		until (character and character:FindFirstChild("HumanoidRootPart") and character:FindFirstChildOfClass("Humanoid")) or os.clock() > deadline or not player.Parent
		humanoid = character and character:FindFirstChildOfClass("Humanoid")
	end
	if not character or not humanoid or not character:FindFirstChild("HumanoidRootPart") then
		return false
	end
	f.model = character
	f.root = character.HumanoidRootPart
	f.humanoid = humanoid
	f.feetOffset = Util.feetOffset(character)
	humanoid.Health = humanoid.MaxHealth
	character:SetAttribute("FighterId", f.id)
	character:SetAttribute("MatchId", self.id)
	character:SetAttribute("Legend", f.legend)
	LegendRig.attach(character, f.legend)
	self.services.CharacterService.setTeamColor(character, teamColor(f.team))
	self.services.CharacterService.applyTrail(character, f.trail)
	WeaponModels.detach(character)

	table.insert(self.connections, humanoid.Died:Connect(function()
		self:Forfeit(f)
	end))
	return true
end

function Match:placeAtSpawns()
	local spawns = self.map.Spawns
	local teamSlots = {}
	local index = 0
	for _, id in self.order do
		local f = self.fighters[id]
		local spawn
		if self.config.mode == "2v2" then
			-- Team 1 takes spawns 1 and 3, team 2 takes 2 and 4.
			teamSlots[f.team] = (teamSlots[f.team] or 0) + 1
			local slot = (f.team - 1) % 2 + 1 + (teamSlots[f.team] - 1) * 2
			spawn = spawns[(slot - 1) % #spawns + 1]
		else
			index += 1
			spawn = spawns[(index - 1) % #spawns + 1]
		end
		f.lastX, f.lastY, f.facing = spawn[1], spawn[2], spawn[3]
		if f.isBot then
			f.state = FighterSim.newState(spawn[1], spawn[2], spawn[3])
			f.state.frozen = true
			f.brain = BotBrain.new(f, self, f.difficulty)
		end
		if f.root then
			f.model:PivotTo(Util.fighterCFrame(self.origin, spawn[1], spawn[2], f.feetOffset, spawn[3]))
		end
		f.awaitingSpawn = not f.isBot
		f.awaitingUntil = math.huge
	end
end

function Match:Start()
	-- Bots first (CreateHumanoidModelFromDescription yields).
	for _, id in self.order do
		local f = self.fighters[id]
		if f.isBot and not self:spawnBotModel(f) then
			f.eliminated = true
			f.alive = false
		end
	end
	for player, f in self.playerFighters do
		if not self:preparePlayer(f) then
			self:RemovePlayer(player)
		end
	end
	if self.phase == "Ended" then
		return
	end

	self:placeAtSpawns()

	local fighters = {}
	for _, id in self.order do
		table.insert(fighters, self:fighterInfo(self.fighters[id]))
	end
	for player, f in self.playerFighters do
		if not f.left then
			self:Send(player, "Start", {
				matchId = self.id,
				mapId = self.config.mapId,
				origin = self.origin,
				arena = self.folder,
				mode = self.config.mode,
				source = self.config.source,
				ranked = self.config.ranked == true,
				winRule = self.config.winRule,
				stocks = self.config.stocks,
				timeLimit = self.config.timeLimit,
				damageMultiplier = self.config.damageMultiplier,
				friendlyFire = self.config.friendlyFire == true,
				fighters = fighters,
				you = f.id,
				spawn = { x = f.lastX, y = f.lastY, facing = f.facing },
			})
		end
	end

	-- Wait for clients to load the arena.
	local deadline = os.clock() + Config.Match.LoadTimeout
	while os.clock() < deadline and self.phase ~= "Ended" do
		local allReady = true
		for _, f in self.playerFighters do
			if not f.left and not f.ready then
				allReady = false
			end
		end
		if allReady then
			break
		end
		task.wait(0.1)
	end
	if self.phase == "Ended" then
		return
	end

	self.phase = "Countdown"
	for n = Config.Match.CountdownSeconds, 1, -1 do
		self:Broadcast("Countdown", { n = n })
		task.wait(1)
		if self.phase == "Ended" then
			return
		end
	end

	self.phase = "Playing"
	self.startClock = os.clock()
	local limit = self.config.timeLimit
	if limit and limit > 0 then
		self.endClock = self.startClock + limit
	end
	self.nextPickupAt = self.startClock + Config.WeaponDrops.FirstSpawnDelay
	for _, f in self.fighters do
		if f.isBot and f.state then
			f.state.frozen = false
			if f.root then
				f.root.Anchored = false
				pcall(function()
					f.root:SetNetworkOwner(nil)
				end)
			end
		end
		f.awaitingUntil = os.clock() + 3
	end
	self:Broadcast("Go", {
		endsAt = self.endClock and (workspace:GetServerTimeNow() + limit) or nil,
	})

	table.insert(self.connections, RunService.Heartbeat:Connect(function(dt)
		local ok, err = pcall(self.Step, self, dt)
		if not ok then
			warn("[Match] step error:", err)
		end
	end))
	self:CheckEnd()
end

-- Per-frame update ----------------------------------------------------------

function Match:nearPickup(x, y, range)
	local best, bestDist
	for _, pickup in self.pickups do
		local dx = math.abs(pickup.x - x)
		if dx <= range and pickup.y >= y - 3 and pickup.y <= y + Config.Physics.FighterHeight + 1 then
			if not best or dx < bestDist then
				best, bestDist = pickup, dx
			end
		end
	end
	return best
end

function Match:stepBot(f, dt)
	local s = f.state
	if not f.alive or not s or not f.root or not f.root.Parent then
		return
	end
	local input = f.brain:Update(dt)
	local ctx = {
		world = self.world,
		weapon = f.weapon,
		legend = f.legend,
		armed = Weapons.isWeapon(f.weapon),
		nearPickup = self:nearPickup(s.x, s.y, Config.WeaponDrops.PickupRange) ~= nil,
	}
	local events = FighterSim.step(s, input, dt, ctx)
	for _, ev in events do
		self:handleBotEvent(f, ev)
	end

	-- Melee hits
	local x1, y1, x2, y2 = FighterSim.activeHitbox(s)
	local rec = f.attacks[s.seq]
	if x1 and rec then
		for _, target in self.fighters do
			if target ~= f and target.alive and not target.awaitingSpawn and not rec.hits[target.id] then
				if self.config.friendlyFire or not self:SameTeam(f, target) then
					local tx, ty = self:GetPosition(target)
					local hx1, hy1, hx2, hy2 = FighterSim.hurtbox(tx, ty)
					if FighterSim.overlaps(x1, y1, x2, y2, hx1, hy1, hx2, hy2) then
						rec.hits[target.id] = true
						local hit, hitstop = self:ApplyHit(f, target, rec.move, rec.charge, s.facing)
						if hit then
							rec.confirmed = true
							FighterSim.onHitConfirm(s, hitstop)
						end
					end
				end
			end
		end
	end

	f.facing = s.facing
	f.root.CFrame = Util.fighterCFrame(self.origin, s.x, s.y, f.feetOffset, s.facing)
	f.root.AssemblyLinearVelocity = Vector3.new(s.vx, s.vy, 0)
end

function Match:recordAttack(f, seq, slot, move, facing)
	local existing = table.find(f.attackOrder, seq)
	if existing then
		table.remove(f.attackOrder, existing)
	end
	f.attacks[seq] = {
		slot = slot,
		move = move,
		weapon = f.weapon,
		start = os.clock(),
		charge = 0,
		hits = {},
		facing = facing,
		fired = false,
	}
	table.insert(f.attackOrder, seq)
	while #f.attackOrder > 10 do
		f.attacks[table.remove(f.attackOrder, 1)] = nil
	end
end

function Match:handleBotEvent(f, ev)
	if ev.type == "Attack" then
		local move = Legends.getAttack(f.legend, f.weapon, ev.slot)
		self:recordAttack(f, ev.seq, ev.slot, move, ev.facing)
		self:Broadcast("Action", { fighterId = f.id, kind = "Attack", slot = ev.slot, weapon = f.weapon, facing = ev.facing, seq = ev.seq })
	elseif ev.type == "Release" then
		local rec = f.attacks[ev.seq]
		if rec then
			rec.charge = ev.charge
		end
		self:Broadcast("Action", { fighterId = f.id, kind = "Release", seq = ev.seq, charge = ev.charge })
	elseif ev.type == "Fire" then
		local rec = f.attacks[ev.seq]
		if rec and not rec.fired then
			rec.fired = true
			rec.charge = ev.charge
			self:fireProjectiles(f, rec)
		end
	elseif ev.type == "Dodge" then
		self:Broadcast("Action", { fighterId = f.id, kind = "Dodge", dodgeKind = ev.kind })
	elseif ev.type == "Jump" and ev.kind ~= "Ground" then
		self:Broadcast("Action", { fighterId = f.id, kind = "Jump", jumpKind = ev.kind })
	elseif ev.type == "Throw" then
		self:ThrowWeapon(f, ev.dirY, ev.facing)
	elseif ev.type == "Pickup" then
		self:TryPickup(f)
	end
end

function Match:Step(dt)
	if self.phase ~= "Playing" then
		return
	end
	local now = os.clock()

	for _, f in self.fighters do
		if f.isBot then
			self:stepBot(f, dt)
		end
		if self.phase ~= "Playing" then
			return
		end
	end

	for _, f in self.fighters do
		if f.alive and not f.eliminated then
			local x, y = self:GetPosition(f)
			local out = Maps.isOutOfBounds(self.world, x, y)
			if f.awaitingSpawn then
				if not out or now > f.awaitingUntil then
					f.awaitingSpawn = false
				end
			elseif out then
				self:KO(f, x, y)
				if self.phase ~= "Playing" then
					return
				end
			end
		end
	end

	self:stepPickups(dt, now)
	self:stepProjectiles(dt)

	if self.endClock and now >= self.endClock then
		self:Finish("Time")
	end
end

-- Hits --------------------------------------------------------------------

function Match:ApplyHit(attacker, target, move, charge, facing, sourceX, ranged)
	if self:IsInvulnerable(target) or not target.alive then
		return false
	end
	local now = os.clock()
	local mult = (self.config.damageMultiplier or 1) * Legends.damageTakenMult(target.legend)
	if attacker then
		mult *= Legends.damageDealtMult(attacker.legend)
	end
	local dmg = Combat.damage(move, charge, mult)
	target.damage = math.min(Config.Combat.MaxDamage, target.damage + dmg)
	target.damageTaken += dmg
	if attacker then
		attacker.damageDealt += dmg
	end

	local tx, ty = self:GetPosition(target)
	local ax = sourceX
	if not ax and attacker then
		ax = self:GetPosition(attacker)
	end
	local kbx, kby, force = Combat.knockback(move, target.damage, charge, facing, tx - (ax or tx))
	local hitstun = Combat.hitstun(force)
	local hitstop = Combat.hitstop(force)

	-- Combo counter: consecutive hits by the same attacker. A hit while the
	-- victim is still in hitstun is a true link; one shortly after is a string.
	local attackerId = attacker and attacker.id or nil
	if attackerId and target.comboBy == attackerId and now <= target.hitstunUntil + Config.Combat.ComboGrace then
		target.comboCount += 1
		target.comboTrue = target.comboTrue and now <= target.hitstunUntil
	else
		target.comboBy = attackerId
		target.comboCount = 1
		target.comboTrue = true
	end

	target.lastHitBy = attackerId
	target.lastHitTime = now
	target.hitstunUntil = now + hitstop + hitstun
	if attacker then
		attacker.lastHitDealt = now
	end
	if target.isBot and target.state then
		FighterSim.applyHit(target.state, kbx, kby, hitstun, hitstop)
	end

	self:Broadcast("Hit", {
		attackerId = attacker and attacker.id,
		victimId = target.id,
		damage = dmg,
		total = target.damage,
		kbx = kbx,
		kby = kby,
		hitstun = hitstun,
		force = force,
		heavy = move.Kind == "Heavy",
		ranged = ranged == true,
		hitstop = hitstop,
		combo = target.comboCount,
		trueCombo = target.comboTrue,
		signature = move.Signature,
		x = tx,
		y = ty + Config.Physics.FighterHeight * 0.55,
	})
	return true, hitstop
end

function Match:onHitReport(f, data)
	local rec = f.attacks[data.seq]
	if not rec or not rec.move.Hitbox then
		return
	end
	local target = type(data.target) == "string" and self.fighters[data.target]
	if not target or target == f or not target.alive or target.eliminated or target.awaitingSpawn then
		return
	end
	if rec.hits[target.id] then
		return
	end
	local move = rec.move
	local now = os.clock()
	local age = now - rec.start
	if age < move.Startup * 0.5 or age > Weapons.maxAttackWindow(move) + Config.Combat.HitTimeSlack then
		return
	end
	if self:SameTeam(f, target) and not self.config.friendlyFire then
		return
	end
	local ax, ay = self:GetPosition(f)
	local tx, ty = self:GetPosition(target)
	local reachX, reachY = Weapons.reach(move)
	local slack = Config.Combat.HitRangeSlack
	if math.abs(tx - ax) > reachX + Config.Physics.FighterWidth + slack then
		return
	end
	if math.abs(ty - ay) > reachY + Config.Physics.FighterHeight + slack then
		return
	end
	rec.hits[target.id] = true
	if self:ApplyHit(f, target, move, rec.charge, rec.facing) then
		rec.confirmed = true
	end
end

-- KOs, respawns, forfeits ---------------------------------------------------

function Match:KO(f, x, y)
	local now = os.clock()
	f.alive = false
	f.falls += 1
	local credit = f.lastHitBy and now - f.lastHitTime <= Config.Combat.KOCreditWindow and self.fighters[f.lastHitBy] or nil
	if credit and (credit == f or self:SameTeam(credit, f)) then
		credit = nil
	end
	if credit then
		credit.kos += 1
	end

	if self.config.winRule == "Timed" then
		f.score -= 1
		if credit then
			credit.score += 1
		end
	else
		f.stocks -= 1
		if f.stocks <= 0 then
			f.eliminated = true
			f.eliminatedAt = now
		end
	end
	self:SetWeapon(f, "Unarmed")
	if f.isBot and f.state then
		f.state.frozen = true
		f.root.Anchored = true
		f.root.CFrame = Util.fighterCFrame(self.origin, 0, GRAVEYARD_Y, f.feetOffset, 1)
	end

	local b = self.world.blast
	self:Broadcast("KO", {
		victimId = f.id,
		attackerId = credit and credit.id or nil,
		x = math.clamp(x, b.minX, b.maxX),
		y = math.clamp(y, b.minY, b.maxY),
		stocks = f.stocks,
		score = f.score,
		eliminated = f.eliminated,
		attackerScore = credit and credit.score or nil,
		attackerKOs = credit and credit.kos or nil,
		koEffect = credit and credit.koEffect or Cosmetics.Defaults.KOEffect,
	})

	if not f.eliminated then
		task.delay(Config.Combat.RespawnTime, function()
			self:Respawn(f)
		end)
	end
	self:CheckEnd()
end

function Match:Respawn(f)
	if self.phase ~= "Playing" or f.left or f.eliminated or f.alive then
		return
	end
	local spots = self.map.Respawns
	self.respawnIndex = self.respawnIndex % #spots + 1
	local spot = spots[self.respawnIndex]
	local facing = spot[1] <= 0 and 1 or -1
	local now = os.clock()
	f.alive = true
	f.damage = 0
	f.lastHitBy = nil
	f.invulnUntil = now + Config.Combat.RespawnInvuln
	f.lastX, f.lastY = spot[1], spot[2]
	if f.isBot then
		FighterSim.respawn(f.state, spot[1], spot[2], facing, Config.Combat.RespawnInvuln)
		if f.root then
			f.root.Anchored = false
			pcall(function()
				f.root:SetNetworkOwner(nil)
			end)
		end
	else
		f.awaitingSpawn = true
		f.awaitingUntil = now + 3
	end
	self:Broadcast("Respawn", {
		fighterId = f.id,
		x = spot[1],
		y = spot[2],
		facing = facing,
		invuln = Config.Combat.RespawnInvuln,
	})
end

-- Player quit, left the game, or their character died.
function Match:Forfeit(f)
	if f.left then
		return
	end
	f.left = true
	f.alive = false
	f.eliminated = true
	f.eliminatedAt = os.clock()
	if self.config.winRule == "Stocks" then
		f.stocks = 0
	end
	local wasPreFight = self.phase == "Loading" or self.phase == "Countdown"
	if (self.phase == "Playing" or wasPreFight) and self.config.ranked and f.player and not f.ratingApplied then
		f.ratingApplied = true
		local total, count = 0, 0
		for _, other in self.fighters do
			if other.team ~= f.team and other.rating then
				total += other.rating
				count += 1
			end
		end
		if count > 0 then
			self.services.ProgressionService.applyLeaver(f.player, self.config.mode, total / count)
		end
	end
	if f.player and f.player.Parent then
		self:Send(f.player, "Leave", {})
	end
	if f.player and self.onPlayerLeft then
		self.onPlayerLeft(f.player)
	end
	self:Broadcast("Left", { fighterId = f.id })
	if wasPreFight and self.config.ranked then
		-- Nobody gets a free ranked win from a dodge before the fight starts.
		self:Finish("Abandoned")
	elseif self.phase == "Playing" then
		self:CheckEnd()
	elseif self.phase ~= "Ended" then
		local anyone = false
		for _, other in self.playerFighters do
			if not other.left then
				anyone = true
			end
		end
		if not anyone then
			self:Finish("Abandoned")
		end
	end
end

function Match:RemovePlayer(player)
	local f = self.playerFighters[player]
	if f then
		self:Forfeit(f)
	end
end

-- Weapons -----------------------------------------------------------------

function Match:SetWeapon(f, weaponId)
	f.weapon = weaponId
	if f.model and f.model.Parent then
		if Weapons.isWeapon(weaponId) then
			f.lastWeapon = weaponId
			WeaponModels.attach(f.model, weaponId, f.weaponColor, Legends.weaponSkin(f.legend, weaponId))
		else
			WeaponModels.detach(f.model)
		end
		f.model:SetAttribute("Weapon", weaponId)
	end
	self:Broadcast("Weapon", { fighterId = f.id, weapon = weaponId })
end

function Match:spawnPickup()
	if #self.allowedWeapons == 0 or #self.map.WeaponSpawns == 0 then
		return
	end
	local weaponId = Util.pick(self.allowedWeapons, self.rng)
	local spot = Util.pick(self.map.WeaponSpawns, self.rng)
	self.nextObjectId += 1
	local id = self.nextObjectId
	local model = WeaponModels.buildPickup(weaponId)
	model.Name = "Pickup" .. id
	model:SetAttribute("PickupId", id)
	model:SetAttribute("WeaponId", weaponId)
	local pickup = {
		id = id,
		weaponId = weaponId,
		model = model,
		x = spot[1],
		y = spot[2],
		groundY = Maps.groundBelow(self.world, spot[1], spot[2]),
		falling = true,
		spawnedAt = os.clock(),
	}
	model:PivotTo(CFrame.new(self.origin + Vector3.new(pickup.x, pickup.y + 1, 0)) * WeaponModels.DisplayRotation)
	model.Parent = self.folder:FindFirstChild("Pickups")
	self.pickups[id] = pickup
end

function Match:removePickup(id)
	local pickup = self.pickups[id]
	if pickup then
		self.pickups[id] = nil
		pickup.model:Destroy()
	end
end

function Match:stepPickups(dt, now)
	if now >= self.nextPickupAt then
		local count = 0
		for _ in self.pickups do
			count += 1
		end
		if count < Config.WeaponDrops.MaxOnStage then
			self:spawnPickup()
		end
		self.nextPickupAt = now + self.rng:NextNumber(Config.WeaponDrops.SpawnIntervalMin, Config.WeaponDrops.SpawnIntervalMax)
	end
	for id, pickup in self.pickups do
		if now - pickup.spawnedAt > Config.WeaponDrops.Lifetime then
			self:removePickup(id)
		elseif pickup.falling then
			pickup.y -= Config.WeaponDrops.FallSpeed * dt
			if pickup.groundY and pickup.y <= pickup.groundY then
				pickup.y = pickup.groundY
				pickup.falling = false
			end
			if pickup.y < self.world.blast.minY then
				self:removePickup(id)
			else
				pickup.model:PivotTo(CFrame.new(self.origin + Vector3.new(pickup.x, pickup.y + 1, 0)) * WeaponModels.DisplayRotation)
			end
		end
	end
end

function Match:TryPickup(f)
	if Weapons.isWeapon(f.weapon) or not f.alive then
		return
	end
	local x, y = self:GetPosition(f)
	local pickup = self:nearPickup(x, y, Config.WeaponDrops.PickupRangeServer)
	if pickup then
		self:removePickup(pickup.id)
		self:SetWeapon(f, Legends.weaponFromPickup(f.legend, pickup.weaponId, f.lastWeapon, self.allowedSet))
	end
end

-- Projectiles -------------------------------------------------------------

function Match:spawnProjectile(owner, spec)
	self.nextObjectId += 1
	local id = self.nextObjectId
	spec.id = id
	spec.owner = owner
	spec.age = 0
	spec.hits = {}
	self.projectiles[id] = spec
	self:Broadcast("Projectile", {
		id = id,
		ownerId = owner.id,
		kind = spec.kind,
		weaponId = spec.weaponId,
		skin = spec.weaponId and Legends.weaponSkin(owner.legend, spec.weaponId) or nil,
		colorId = owner.weaponColor,
		x = spec.x,
		y = spec.y,
		vx = spec.vx,
		vy = spec.vy,
		gravity = spec.gravity,
		lifetime = spec.lifetime,
	})
end

function Match:fireProjectiles(f, rec)
	local p = rec.move.Projectile
	local x, y = self:GetPosition(f)
	local facing = rec.facing or 1
	for i = 1, p.Count do
		local angle = math.rad(p.Angle + (i - (p.Count + 1) / 2) * p.Spread)
		self:spawnProjectile(f, {
			kind = "Arrow",
			x = x + facing * 1.2,
			y = y + 3,
			vx = math.cos(angle) * p.Speed * facing,
			vy = math.sin(angle) * p.Speed,
			gravity = p.Gravity,
			lifetime = p.Lifetime,
			w = p.W,
			h = p.H,
			move = rec.move,
			charge = rec.charge,
			pierce = p.Pierce,
		})
	end
end

function Match:ThrowWeapon(f, dirY, facing)
	if not Weapons.isWeapon(f.weapon) or not f.alive then
		return
	end
	facing = facing == -1 and -1 or 1
	local weaponId = f.weapon
	self:SetWeapon(f, "Unarmed")
	local angle = math.rad(dirY == 1 and 45 or dirY == -1 and -35 or 8)
	local x, y = self:GetPosition(f)
	local W = Config.WeaponDrops
	self:spawnProjectile(f, {
		kind = "Weapon",
		weaponId = weaponId,
		x = x + facing * 1.5,
		y = y + 3.2,
		vx = math.cos(angle) * W.ThrowSpeed * facing,
		vy = math.sin(angle) * W.ThrowSpeed,
		gravity = W.ThrowGravity,
		lifetime = W.ThrowLifetime,
		w = 2.6,
		h = 2.6,
		move = Combat.ThrowMove,
		charge = 0,
		pierce = false,
	})
end

local function insideSolid(world, x, y)
	for _, p in world.platforms do
		if not p.soft and x > p.minX and x < p.maxX and y > p.minY and y < p.maxY then
			return true
		end
	end
	return false
end

function Match:endProjectile(id, proj)
	self.projectiles[id] = nil
	self:Broadcast("ProjectileEnd", { id = id, x = proj.x, y = proj.y })
end

function Match:stepProjectiles(dt)
	for id, proj in self.projectiles do
		proj.age += dt
		proj.vy -= proj.gravity * dt
		proj.x += proj.vx * dt
		proj.y += proj.vy * dt
		if proj.age >= proj.lifetime or Maps.isOutOfBounds(self.world, proj.x, proj.y) or insideSolid(self.world, proj.x, proj.y) then
			self:endProjectile(id, proj)
		else
			local x1, y1 = proj.x - proj.w / 2, proj.y - proj.h / 2
			local x2, y2 = proj.x + proj.w / 2, proj.y + proj.h / 2
			local owner = proj.owner
			for _, target in self.fighters do
				if target ~= owner and target.alive and not target.awaitingSpawn and not proj.hits[target.id] then
					if self.config.friendlyFire or not self:SameTeam(owner, target) then
						local tx, ty = self:GetPosition(target)
						local hx1, hy1, hx2, hy2 = FighterSim.hurtbox(tx, ty)
						if FighterSim.overlaps(x1, y1, x2, y2, hx1, hy1, hx2, hy2) then
							proj.hits[target.id] = true
							local facing = proj.vx >= 0 and 1 or -1
							local hit = self:ApplyHit(owner, target, proj.move, proj.charge, facing, proj.x - facing, true)
							if hit and not proj.pierce then
								self:endProjectile(id, proj)
								break
							end
						end
					end
				end
			end
		end
	end
end

-- Player actions ------------------------------------------------------------

local DODGE_INVULN = {
	Spot = Config.Physics.SpotDodgeTime,
	AirSpot = Config.Physics.SpotDodgeTime,
	Air = Config.Physics.AirDodgeInvuln,
	Dash = 0,
	Chase = 0,
}

-- Client-reported cooldowns are only trusted this much, to allow for lag.
local COOLDOWN_LENIENCY = 0.6
-- A fighter in hitstun can't act; allow this much lag at the end of it.
local HITSTUN_SLACK = 0.1

local DODGE_COOLDOWN = {
	Spot = Config.Physics.SpotDodgeCooldown,
	AirSpot = Config.Physics.AirDodgeCooldown,
	Air = Config.Physics.AirDodgeCooldown,
	Dash = Config.Physics.DashCooldown,
	Chase = Config.Combat.ChaseDodgeTime,
}
-- A chase dodge is only allowed this soon after the fighter's last hit
-- (the chase window plus room for lag).
local CHASE_SLACK = 0.35

-- Finite number check for anything a client sends (NaN and inf rejected).
local function finite(value)
	return type(value) == "number" and value == value and math.abs(value) < 1e9
end

local VALID_SLOTS = {}
for _, slot in Weapons.Slots do
	VALID_SLOTS[slot] = true
end

local function validSeq(value)
	return finite(value) and value % 1 == 0
end

-- Whether a new attack may start now. Attacks can't overlap in FighterSim,
-- so a new one can only begin once the previous one is (mostly) over,
-- unless it was cut short by landing (air attacks) or by getting hit.
function Match:canStartAttack(f, now)
	local seq = f.attackOrder[#f.attackOrder]
	local prev = seq and f.attacks[seq]
	if not prev then
		return true
	end
	if prev.move.Air or f.lastHitTime > prev.start then
		return now - prev.start >= 0.05
	end
	-- A light that hit can be cancelled (jump or chase dodge) once its
	-- active frames are over, and then the next attack can start.
	if prev.confirmed and prev.move.Kind == "Light" then
		return now - prev.start >= (prev.move.Startup + prev.move.Active) * COOLDOWN_LENIENCY
	end
	local duration = prev.move.Startup + prev.move.Active + prev.move.Recovery
	return now - prev.start >= duration * COOLDOWN_LENIENCY
end

function Match:OnAction(player, kind, data)
	local f = self.playerFighters[player]
	if not f or f.left then
		return
	end

	-- Token bucket against remote spam.
	local now = os.clock()
	local rate = Config.Combat.MaxActionsPerSecond
	f.actionBudget = math.min(rate, f.actionBudget + (now - f.budgetClock) * rate)
	f.budgetClock = now
	if f.actionBudget < 1 then
		return
	end
	f.actionBudget -= 1

	if kind == "Ready" then
		f.ready = true
		return
	elseif kind == "Forfeit" then
		self:Forfeit(f)
		task.spawn(function()
			pcall(function()
				player:LoadCharacter()
			end)
		end)
		return
	end
	if self.phase ~= "Playing" or not f.alive or type(data) ~= "table" then
		return
	end
	-- FighterSim can't attack, dodge or throw during hitstun, and the server
	-- knows how long the hitstun it dealt lasts.
	local inHitstun = now < f.hitstunUntil - HITSTUN_SLACK
	if inHitstun and (kind == "Attack" or kind == "Dodge" or kind == "Throw") then
		return
	end

	if kind == "Attack" then
		if not VALID_SLOTS[data.slot] or not validSeq(data.seq) then
			return
		end
		local move = Legends.getAttack(f.legend, f.weapon, data.slot)
		if not move or not self:canStartAttack(f, now) then
			return
		end
		-- FighterSim can only attack out of an invulnerable dodge by gravity
		-- cancelling an air spot dodge, which ends the invulnerability.
		f.dodgeInvulnUntil = 0
		local facing = data.facing == -1 and -1 or 1
		f.facing = facing
		self:recordAttack(f, data.seq, data.slot, move, facing)
		self:Broadcast("Action", { fighterId = f.id, kind = "Attack", slot = data.slot, weapon = f.weapon, facing = facing, seq = data.seq }, player)
	elseif kind == "Release" then
		local rec = validSeq(data.seq) and f.attacks[data.seq]
		if rec and finite(data.charge) then
			local maxCharge = rec.move.Charge or 0
			local elapsed = now - rec.start + 0.15
			rec.charge = math.clamp(data.charge, 0, maxCharge > 0 and math.min(1, elapsed / maxCharge) or 0)
			self:Broadcast("Action", { fighterId = f.id, kind = "Release", seq = data.seq, charge = rec.charge }, player)
		end
	elseif kind == "Fire" then
		local rec = validSeq(data.seq) and f.attacks[data.seq]
		if rec and rec.move.Projectile and not rec.fired then
			local age = now - rec.start
			if age >= rec.move.Startup * 0.5 and age < Weapons.maxAttackWindow(rec.move) + Config.Combat.HitTimeSlack then
				rec.fired = true
				self:fireProjectiles(f, rec)
			end
		end
	elseif kind == "Hit" then
		if validSeq(data.seq) then
			self:onHitReport(f, data)
		end
	elseif kind == "Dodge" then
		local invuln = DODGE_INVULN[data.kind]
		if invuln == nil then
			return
		end
		if data.kind == "Chase" and now - f.lastHitDealt > Config.Combat.ChaseWindow + CHASE_SLACK then
			return
		end
		local cdMult = data.kind == "Chase" and 1 or Legends.dodgeCooldownMult(f.legend)
		local cooldown = DODGE_COOLDOWN[data.kind] * cdMult * COOLDOWN_LENIENCY
		local last = f.lastDodge and f.lastDodge[data.kind]
		if last and now - last < cooldown then
			return
		end
		f.lastDodge = f.lastDodge or {}
		f.lastDodge[data.kind] = now
		if invuln > 0 then
			f.dodgeInvulnUntil = math.max(f.dodgeInvulnUntil, now + invuln + Config.Combat.DodgeInvulnSlack)
		end
		self:Broadcast("Action", { fighterId = f.id, kind = "Dodge", dodgeKind = data.kind }, player)
	elseif kind == "Jump" then
		if data.kind == "Air" or data.kind == "Wall" then
			self:Broadcast("Action", { fighterId = f.id, kind = "Jump", jumpKind = data.kind }, player)
		end
	elseif kind == "Throw" then
		local dirY = data.dirY == 1 and 1 or (data.dirY == -1 and -1 or 0)
		self:ThrowWeapon(f, dirY, data.facing)
	elseif kind == "Pickup" then
		self:TryPickup(f)
	end
end

-- Ending ------------------------------------------------------------------

function Match:CheckEnd()
	if self.phase ~= "Playing" then
		return
	end
	local humans = false
	local humanTeams = {}
	local teams = {}
	local teamCount = 0
	for _, f in self.fighters do
		if f.player and not f.left then
			humans = true
			humanTeams[f.team] = true
		end
		if not f.eliminated and not teams[f.team] then
			teams[f.team] = true
			teamCount += 1
		end
	end
	-- Once no team with a player on it can still win, there's nothing left
	-- to watch (e.g. bots finishing an FFA among themselves).
	local humanTeamAlive = false
	for team in humanTeams do
		if teams[team] then
			humanTeamAlive = true
		end
	end
	if not humans then
		self:Finish("Abandoned")
	elseif teamCount <= 1 or not humanTeamAlive then
		self:Finish("Decided")
	end
end

-- Returns teams sorted best first, and whether the top two are tied.
function Match:rankTeams()
	local byTeam = {}
	local list = {}
	for _, f in self.fighters do
		local t = byTeam[f.team]
		if not t then
			t = { team = f.team, stocks = 0, damage = 0, score = 0, alive = false, lastOut = 0, members = {} }
			byTeam[f.team] = t
			table.insert(list, t)
		end
		t.stocks += math.max(0, f.stocks)
		t.damage += f.damage
		t.score += f.score
		if not f.eliminated then
			t.alive = true
		end
		t.lastOut = math.max(t.lastOut, f.eliminated and f.eliminatedAt or math.huge)
		table.insert(t.members, f)
	end

	local timed = self.config.winRule == "Timed"
	local function better(a, b)
		if timed then
			if a.alive ~= b.alive then
				return a.alive
			end
			if a.score ~= b.score then
				return a.score > b.score
			end
			return a.damage < b.damage
		end
		if a.alive ~= b.alive then
			return a.alive
		end
		if a.stocks ~= b.stocks then
			return a.stocks > b.stocks
		end
		if a.lastOut ~= b.lastOut then
			return a.lastOut > b.lastOut
		end
		return a.damage < b.damage
	end
	table.sort(list, better)

	local tied = false
	if #list >= 2 then
		tied = not better(list[1], list[2]) and not better(list[2], list[1])
	end
	return list, tied
end

function Match:Finish(reason)
	if self.phase == "Ended" then
		return
	end
	local wasPlaying = self.phase == "Playing"
	self.phase = "Ended"
	for _, connection in self.connections do
		connection:Disconnect()
	end
	self.connections = {}
	for _, f in self.fighters do
		if f.isBot and f.state then
			f.state.frozen = true
			if f.root and f.root.Parent then
				f.root.Anchored = true
			end
		end
	end

	local teams, tied = self:rankTeams()
	local winnerTeam = (not tied and teams[1]) and teams[1].team or nil
	local results = {}
	for rank, t in teams do
		for _, f in t.members do
			table.insert(results, {
				id = f.id,
				name = f.name,
				team = f.team,
				isBot = f.isBot,
				placement = tied and rank <= 2 and 1 or rank,
				kos = f.kos,
				falls = f.falls,
				damageDealt = f.damageDealt,
				stocks = f.stocks,
				score = f.score,
				won = f.team == winnerTeam,
				left = f.left,
			})
		end
	end

	local rewards = {}
	if reason ~= "Abandoned" and wasPlaying then
		local hasBots = false
		for _, f in self.fighters do
			if f.isBot then
				hasBots = true
			end
		end
		local entries = {}
		for player, f in self.playerFighters do
			if not f.left and player.Parent then
				local opponentRating
				if self.config.ranked then
					local total, count = 0, 0
					for _, other in self.fighters do
						if other.team ~= f.team and other.rating then
							total += other.rating
							count += 1
						end
					end
					opponentRating = count > 0 and total / count or nil
				end
				table.insert(entries, {
					player = player,
					team = f.team,
					won = f.team == winnerTeam,
					draw = tied,
					kos = f.kos,
					falls = f.falls,
					damageDealt = f.damageDealt,
					opponentRating = opponentRating,
				})
			end
		end
		rewards = self.services.ProgressionService.applyMatch({
			source = self.config.source,
			ranked = self.config.ranked,
			mode = self.config.mode,
			duration = os.clock() - (self.startClock or os.clock()),
			hasBots = hasBots,
		}, entries)
	end

	for player, f in self.playerFighters do
		if not f.left then
			self:Send(player, "End", {
				reason = reason,
				winnerTeam = winnerTeam,
				draw = tied,
				results = results,
				rewards = rewards[player],
				you = f.id,
				returnIn = reason == "Abandoned" and 3 or Config.Match.ResultsSeconds,
			})
		end
	end

	task.delay(reason == "Abandoned" and 3 or Config.Match.ResultsSeconds, function()
		self:Cleanup()
	end)
end

function Match:Cleanup()
	for player, f in self.playerFighters do
		if not f.left and player.Parent then
			self:Send(player, "Leave", {})
			local character = player.Character
			if character then
				character:SetAttribute("FighterId", nil)
				character:SetAttribute("MatchId", nil)
				character:SetAttribute("TeamColor", nil)
			end
			task.spawn(function()
				pcall(function()
					player:LoadCharacter()
				end)
			end)
		end
	end
	if self.folder then
		self.folder:Destroy()
		self.folder = nil
	end
	self.services.ArenaService.release(self.slot)
	if self.onFinished then
		self.onFinished(self)
	end
end

return Match
