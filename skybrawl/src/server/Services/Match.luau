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
        (LegendRig) on top of the Roblox character, unless the player fights
        in their own avatar's look (the FightAsAvatar setting).
      - Battlegrounds combat (Config.Battle) is decided here too: whether a
        hit is blocked (players report when they block), the guard meter and
        guard breaks, which hits ragdoll, the ultimate meter, awakening
        (everyone freezes for the cut-in) and the one ultimate move per
        awakening. Players report knockdowns and techs; their invulnerability
        is only granted shortly after a hit that tumbled them.

    Characters exist only for a match: Start preloads every player's
    character in parallel (once each, one shared deadline), keeps them on
    the spawn pad until the VS splash is over, and the match destroys them
    again when the player forfeits, when the match is cleaned up, or when a
    load finishes after the fighter was dropped.

    Combat timing runs on the match clock (Match:now()), which a training
    room can slow down (SetTimeScale); real time is kept only for loading
    deadlines, the action rate limit and reward durations. A training match
    has a hook object (config.training) that Match calls at fixed points.

    Every MatchEvent carries matchId. Players who never got "Start" (still
    on the VS splash) get SelectEvent "Cancel" instead of "End"/"Leave".

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
local MatchRules = require(Shared.MatchRules)
local Net = require(Shared.Net)

local BotBrain = require(script.Parent.BotBrain)

local Match = {}
Match.__index = Match

local B = Config.Battle

local GRAVEYARD_Y = 600
local SKIN_TONES = {
	Color3.fromRGB(255, 220, 190),
	Color3.fromRGB(234, 184, 146),
	Color3.fromRGB(198, 134, 98),
	Color3.fromRGB(141, 85, 54),
	Color3.fromRGB(96, 62, 40),
	Color3.fromRGB(255, 205, 150),
}
local SHIRT_COLORS = {
	Color3.fromRGB(70, 130, 220),
	Color3.fromRGB(220, 80, 80),
	Color3.fromRGB(90, 190, 110),
	Color3.fromRGB(230, 170, 60),
	Color3.fromRGB(160, 100, 220),
	Color3.fromRGB(60, 190, 190),
}

-- Finite number check for anything a client sends (NaN and inf rejected).
local function finite(value)
	return type(value) == "number" and value == value and math.abs(value) < 1e9
end

-- A character the match can use as is: alive, with a root part.
local function liveCharacter(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if character and humanoid and humanoid.Health > 0 and character:FindFirstChild("HumanoidRootPart") then
		return character
	end
	return nil
end

-- Takes a player's match character away (no LoadCharacter: players have no character outside matches).
local function releaseCharacter(player)
	local ok, err = pcall(function()
		local character = player.Character
		if character then
			character:SetAttribute("FighterId", nil)
			character:SetAttribute("MatchId", nil)
			character:SetAttribute("TeamColor", nil)
		end
		player.Character = nil
		if character then
			character:Destroy()
		end
	end)
	if not ok then
		warn("[Match] couldn't release the character of", player.Name, err)
	end
end

-- Runs fn(...) and warns instead of throwing, so one failing step (often another service's code) never stops the
-- steps after it from ending the match, freeing the arena and the players.
local function try(label, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		warn("[Match] " .. label .. " failed:", err)
	end
	return ok
end

-- How long a player's character may take to load (from the start of Match:Start, shared by every player).
local LOAD_SECONDS = 8

--[[
    reserved = { slot, origin, startAt? } from the caller (select phase,
    training): the slot stays the caller's if construction fails. Without
    it the match acquires a "Match" slot itself and releases it on failure.
    startAt is the os.clock() time before which "Start" isn't sent.
]]
function Match.new(id, config, services, reserved)
	local self = setmetatable({}, Match)
	self.id = id
	self.config = config
	self.services = services
	self.map = Maps.get(config.mapId)
	self.world = Maps.getWorld(config.mapId)
	if reserved then
		self.slot, self.origin = reserved.slot, reserved.origin
		self.ownsSlot = false
	else
		self.slot, self.origin = services.ArenaService.acquire("Match")
		assert(self.slot, "no free arena slot")
		self.ownsSlot = true
	end
	local built, folder = pcall(services.ArenaService.buildMap, config.mapId, self.origin, self.slot)
	if not built then
		if self.ownsSlot then
			services.ArenaService.release(self.slot)
		end
		error(folder, 0)
	end
	self.folder = folder

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
	-- the match clock (Match:now): real time scaled by timeScale, continuous across scale changes
	self.timeScale = 1
	self.clockBase = os.clock()
	self.timeBase = self.clockBase
	self.startAt = reserved and reserved.startAt
	self.startSent = {} -- [Player] = true once "Start" went out to them
	self.training = config.training

	self.allowedWeapons = {}
	self.allowedSet = {}
	for _, weaponId in Weapons.Order do
		if config.weapons == nil or config.weapons[weaponId] then
			table.insert(self.allowedWeapons, weaponId)
			self.allowedSet[weaponId] = true
		end
	end
	if self.training then
		self:callTraining("Attach", self)
	end
	return self
end

-- Calls a training hook (TrainingRoom:<name>(...)); a failing hook never breaks the match.
function Match:callTraining(name, ...)
	local room = self.training
	local hook = room and room[name]
	if type(hook) ~= "function" then
		return
	end
	local ok, err = pcall(hook, room, ...)
	if not ok then
		warn("[Match] training hook " .. name .. " failed:", err)
	end
end

-- Match clock -----------------------------------------------------------------

-- Seconds on the match clock: os.clock() pace at scale 1, slower in slow motion.
function Match:now()
	return self.timeBase + (os.clock() - self.clockBase) * self.timeScale
end

function Match:SetTimeScale(scale)
	self.timeBase = self:now()
	self.clockBase = os.clock()
	self.timeScale = scale
	self:Broadcast("TimeScale", { scale = scale })
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
		ownLook = false, -- a player fighting in their own avatar's look
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
		-- battlegrounds combat
		guard = B.GuardMax,
		lastGuardHit = 0,
		blocking = false,
		blockFacing = 1,
		ult = 0,
		awakenUntil = 0,
		ultUsed = false,
		lastTumbleHit = -100,
		-- stats for missions (MatchEntry)
		damageByWeapon = {}, -- [weaponId] = damage dealt ("Unarmed" included)
		trueCombos = 0,
		maxCombo = 0,
		loading = false, -- a character preload is running (Start)
	}
	self.fighters[id] = f
	table.insert(self.order, id)
	return f
end

-- pick = { legend, ownLook } from the select session; anything missing comes from the profile.
function Match:AddPlayer(player, team, pick)
	pick = pick or {}
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
		-- "Fight as my avatar": the legend's moves and stats, your own look
		f.ownLook = profile.Settings.FightAsAvatar == true
	end
	if Legends.isValid(pick.legend) then
		f.legend = pick.legend
	end
	if type(pick.ownLook) == "boolean" then
		f.ownLook = pick.ownLook
	end
	if self.config.ranked then
		f.rating = self.services.ProgressionService.ratingOf(player, self.config.mode)
	end
	self.playerFighters[player] = f
	return f
end

-- legend: the select session's pick (any legend but Avatar; else random). opts.dummy marks the training dummy.
function Match:AddBot(difficulty, team, name, legend, opts)
	self.nextObjectId += 1
	local f = self:newFighter("b" .. self.nextObjectId, team)
	f.isBot = true
	f.difficulty = Config.Bots.Difficulties[difficulty] and difficulty or "Normal"
	f.name = name or Util.pick(Config.Bots.Names, self.rng)
	f.weaponColor = Cosmetics.Defaults.WeaponColor
	f.koEffect = Cosmetics.Defaults.KOEffect
	f.title = f.difficulty .. " Bot"
	if Legends.isValid(legend) and legend ~= "Avatar" then
		f.legend = legend
	else
		local roster = {}
		for _, id in Legends.Order do
			if id ~= "Avatar" then
				table.insert(roster, id)
			end
		end
		f.legend = Util.pick(roster, self.rng)
	end
	if opts and opts.dummy then
		f.isDummy = true
		f.title = "Training Dummy"
	end
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
	local now = self:now()
	if now < f.invulnUntil or now < f.dodgeInvulnUntil then
		return true
	end
	return f.isBot and f.state ~= nil and FighterSim.isInvulnerable(f.state)
end

function Match:IsBlocking(f)
	if f.isBot then
		return f.state ~= nil and FighterSim.isBlocking(f.state)
	end
	return f.blocking
end

function Match:BlockFacing(f)
	if f.isBot then
		return f.state and f.state.facing or 1
	end
	return f.blockFacing
end

function Match:IsAwakened(f)
	return self:now() < f.awakenUntil
end

-- What the ultimate button does for this fighter right now.
function Match:UltimateState(f)
	if self:IsAwakened(f) then
		return not f.ultUsed and "Attack" or nil
	end
	return f.ult >= B.UltMax and "Awaken" or nil
end

function Match:addUlt(f, amount)
	if not f or self:IsAwakened(f) then
		return
	end
	f.ult = math.clamp(f.ult + amount, 0, B.UltMax)
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
	return self:now() - rec.start < rec.move.Startup + rec.move.Active + (rec.move.Charge or 0)
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
		ownLook = f.ownLook == true,
		ult = f.ult,
		guard = f.guard,
	}
end

-- Networking --------------------------------------------------------------

-- Every event carries the match id (clients drop events of any other match).
function Match:Broadcast(kind, data, except)
	data = data or {}
	data.matchId = self.id
	local remote = Net.get("MatchEvent")
	for player, f in self.playerFighters do
		if not f.left and player ~= except and player.Parent then
			remote:FireClient(player, kind, data)
		end
	end
end

function Match:Send(player, kind, data)
	data = data or {}
	data.matchId = self.id
	if player.Parent then
		Net.get("MatchEvent"):FireClient(player, kind, data)
	end
end

-- For players who never got "Start": they are still on the VS splash (training: on the Practice screen).
function Match:sendCancel(player, reason, requeued)
	if not player.Parent then
		return
	end
	if self.training then
		Net.get("Toast"):FireClient(player, "Couldn't start the training room.", "error")
	elseif self.config.selectId then
		Net.get("SelectEvent"):FireClient(player, "Cancel", {
			id = self.config.selectId,
			reason = reason,
			requeued = requeued == true,
		})
	else
		Net.get("Toast"):FireClient(player, reason, "error")
	end
end

-- Setup -------------------------------------------------------------------

local function disableHumanoidStates(humanoid)
	for _, state in
		{
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
		}
	do
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

--[[
    A character loaded for this match that nothing will use (the match
    ended, or the fighter was dropped while it loaded) is destroyed, unless
    the player is gone or already in another match. A player still in this
    (ended) match is left to Cleanup.
]]
function Match:releaseUnused(player)
	if player.Parent and self.services.MatchService.getMatchOf(player) == nil then
		releaseCharacter(player)
	end
end

-- Starts loading the player's character in the background; f.loading stays true until LoadCharacter returns.
function Match:preloadCharacter(f)
	local player = f.player
	f.loading = true
	task.spawn(function()
		local ok, err = pcall(function()
			player:LoadCharacter()
		end)
		f.loading = false
		if not ok then
			warn("[Match] couldn't load the character of", player.Name, err)
		end
		if self.phase == "Ended" or f.left then
			self:releaseUnused(player)
		end
	end)
end

--[[
    Readies one player's character. Waits (until `deadline`, os.clock()) for
    the preload Start began, and loads the character itself only when there
    was no preload or it finished without one: a player is never loaded
    twice. Returns false when there is no usable character, or the match
    ended or dropped the fighter meanwhile (then it connects nothing and
    destroys the character it loaded, see releaseUnused).
]]
function Match:preparePlayer(f, deadline)
	local player = f.player
	deadline = deadline or (os.clock() + LOAD_SECONDS)
	local function wanted()
		return player.Parent ~= nil and self.phase ~= "Ended" and not f.left
	end
	local function waitFor(condition)
		while not condition() and os.clock() < deadline and wanted() do
			task.wait(0.1)
		end
	end
	if not liveCharacter(player) then
		waitFor(function()
			return not f.loading
		end)
		if not liveCharacter(player) and not f.loading and wanted() then
			pcall(function()
				player:LoadCharacter()
			end)
		end
		-- LoadCharacter returns once the character exists; its parts may still be arriving.
		waitFor(function()
			return liveCharacter(player) ~= nil
		end)
	end
	if self.phase == "Ended" or f.left then
		self:releaseUnused(player)
		return false
	end
	local character = liveCharacter(player)
	if not character then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	f.model = character
	f.root = character.HumanoidRootPart
	f.humanoid = humanoid
	f.feetOffset = Util.feetOffset(character)
	humanoid.Health = humanoid.MaxHealth
	character:SetAttribute("FighterId", f.id)
	character:SetAttribute("MatchId", self.id)
	character:SetAttribute("Legend", f.legend)
	if f.ownLook then
		LegendRig.detach(character)
	else
		LegendRig.attach(character, f.legend)
	end
	self.services.CharacterService.setTeamColor(character, teamColor(f.team))
	self.services.CharacterService.applyTrail(character, f.trail)
	WeaponModels.detach(character)

	table.insert(
		self.connections,
		humanoid.Died:Connect(function()
			self:Forfeit(f)
		end)
	)
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
		-- (a dropped player's character is gone or about to be)
		if f.root and not f.left then
			f.model:PivotTo(Util.fighterCFrame(self.origin, spawn[1], spawn[2], f.feetOffset, spawn[3]))
		end
		f.awaitingSpawn = not f.isBot
		f.awaitingUntil = math.huge
	end
	-- bot brains exist now (a training room swaps the dummy's brain here)
	self:callTraining("OnPlaced")
end

function Match:Start()
	if self.phase == "Ended" then
		return
	end
	-- Bots first (CreateHumanoidModelFromDescription yields).
	for _, id in self.order do
		local f = self.fighters[id]
		if f.isBot and not self:spawnBotModel(f) then
			f.eliminated = true
			f.alive = false
		end
	end
	if self.phase == "Ended" then
		return
	end
	-- Load every player's character at once (during the VS splash), then ready them one by one. The loads run in
	-- parallel, so they share one deadline: slow loads never add up.
	for player, f in self.playerFighters do
		if not f.left and player.Parent and not liveCharacter(player) then
			self:preloadCharacter(f)
		end
	end
	local loadDeadline = os.clock() + LOAD_SECONDS
	for player, f in self.playerFighters do
		if not f.left then
			local ready = self:preparePlayer(f, loadDeadline)
			if self.phase == "Ended" then
				return
			end
			if not ready and not f.left then
				-- Still on the server: our failure, not a dodge (no leaver loss).
				self:Forfeit(f, player.Parent and { noPenalty = true } or nil)
				if self.phase == "Ended" then
					return
				end
			end
		end
	end

	-- The VS splash runs until startAt. Characters wait on the spawn pad meanwhile: arena parts don't collide
	-- with them and nothing moves them before the client's "Start", so placed early they would fall.
	while self.startAt and os.clock() < self.startAt and self.phase ~= "Ended" do
		task.wait(0.05)
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
		if not f.left and player.Parent then
			self.startSent[player] = true
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
				training = self.training ~= nil,
				queueType = self.config.queueType,
				timeScale = self.timeScale,
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
	self.startClock = self:now()
	self.playStartedAt = os.clock() -- real time, for the reward duration
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
		f.awaitingUntil = self:now() + 3
	end
	self:Broadcast("Go", {
		endsAt = self.endClock and (workspace:GetServerTimeNow() + limit) or nil,
	})

	table.insert(
		self.connections,
		RunService.Heartbeat:Connect(function(dt)
			local ok, err = pcall(self.Step, self, dt)
			if not ok then
				warn("[Match] step error:", err)
			end
		end)
	)
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
		ultimate = self:UltimateState(f),
		awakened = self:IsAwakened(f),
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
						local hit, hitstop, blocked =
							self:ApplyHit(f, target, rec.move, rec.charge, s.facing, nil, nil, rec.weapon)
						if blocked then
							FighterSim.freeze(s, hitstop)
						elseif hit then
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
		start = self:now(),
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
		if ev.slot == "Ultimate" then
			f.ultUsed = true
		end
		self:recordAttack(f, ev.seq, ev.slot, move, ev.facing)
		self:Broadcast(
			"Action",
			{ fighterId = f.id, kind = "Attack", slot = ev.slot, weapon = f.weapon, facing = ev.facing, seq = ev.seq }
		)
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
	elseif ev.type == "Awaken" then
		if self:UltimateState(f) == "Awaken" then
			self:Awaken(f)
		end
	elseif ev.type == "Block" then
		self:Broadcast("Action", { fighterId = f.id, kind = "Block", on = ev.on })
	elseif ev.type == "Knockdown" or ev.type == "Tech" or ev.type == "GetUp" then
		self:Broadcast("Action", { fighterId = f.id, kind = "Down", downKind = ev.type, dir = ev.dir })
	end
end

function Match:Step(dt)
	if self.phase ~= "Playing" then
		return
	end
	local now = self:now()
	local sdt = dt * self.timeScale -- match-clock seconds this frame

	for _, f in self.fighters do
		if f.isBot then
			self:stepBot(f, sdt)
		end
		if self.phase ~= "Playing" then
			return
		end
	end

	for _, f in self.fighters do
		-- the guard refills while not blocking
		if f.guard < B.GuardMax and not self:IsBlocking(f) and now - f.lastGuardHit > B.GuardRegenDelay then
			f.guard = math.min(B.GuardMax, f.guard + B.GuardRegen * sdt)
		end
		if f.awakenUntil > 0 and now >= f.awakenUntil then
			self:EndAwakening(f)
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

	self:stepPickups(sdt, now)
	self:stepProjectiles(sdt)

	if self.endClock and now >= self.endClock then
		self:Finish("Time")
	end
	if self.phase == "Playing" then
		self:callTraining("Step", sdt)
	end
end

-- Hits --------------------------------------------------------------------

-- A hit that a blocking fighter caught on their guard: no damage, but it
-- drains the guard meter; an empty one breaks and stuns them. Returns like
-- ApplyHit (the third value is true for a plain block, false for a break).
function Match:BlockHit(attacker, target, move, charge, mult, ax, tx, ty)
	local now = self:now()
	local dmg = Combat.damage(move, charge, mult)
	local drain = B.GuardDrainBase + dmg * B.GuardDrainPerDamage * (move.Kind == "Heavy" and B.GuardDrainHeavy or 1)
	target.guard = math.max(0, target.guard - drain)
	target.lastGuardHit = now
	self:addUlt(target, dmg * B.UltPerBlocked)
	local hitstop = Combat.hitstop(dmg * 3)
	local event = {
		attackerId = attacker and attacker.id,
		victimId = target.id,
		guard = target.guard,
		hitstop = hitstop,
		ult = target.ult,
		x = tx,
		y = ty + Config.Physics.FighterHeight * 0.55,
	}
	if target.guard <= 0 then
		target.blocking = false
		target.hitstunUntil = now + B.GuardBreakStun
		if target.isBot and target.state then
			FighterSim.applyGuardBreak(target.state, B.GuardBreakStun)
		end
		event.stun = B.GuardBreakStun
		self:Broadcast("GuardBreak", event)
		return true, hitstop, false
	end
	local pushX = (tx >= ax and 1 or -1) * B.BlockPushback
	target.hitstunUntil = math.max(target.hitstunUntil, now + B.BlockStun)
	if target.isBot and target.state then
		FighterSim.applyBlock(target.state, pushX, B.BlockStun, hitstop)
	end
	event.pushX = pushX
	event.stun = B.BlockStun
	self:Broadcast("Blocked", event)
	return true, hitstop, true
end

-- weaponId: the weapon the hit came from (melee: the attack's weapon; thrown weapons and arrows: theirs).
function Match:ApplyHit(attacker, target, move, charge, facing, sourceX, ranged, weaponId)
	if self:IsInvulnerable(target) or not target.alive then
		return false
	end
	local now = self:now()
	local mult = (self.config.damageMultiplier or 1) * Legends.damageTakenMult(target.legend)
	if attacker then
		mult *= Legends.damageDealtMult(attacker.legend)
		if self:IsAwakened(attacker) then
			mult *= B.AwakenDamageMult
		end
	end

	-- Blocked from the front?
	if self:IsBlocking(target) and not move.Unblockable then
		local bx, by = self:GetPosition(target)
		local ax = sourceX or (attacker and self:GetPosition(attacker)) or bx
		if (ax - bx) * self:BlockFacing(target) >= -0.5 then
			return self:BlockHit(attacker, target, move, charge, mult, ax, bx, by)
		end
	end
	target.blocking = false

	local dmg = Combat.damage(move, charge, mult)
	target.damage = math.min(Config.Combat.MaxDamage, target.damage + dmg)
	target.damageTaken += dmg
	if attacker then
		attacker.damageDealt += dmg
		local key = weaponId or "Unarmed"
		attacker.damageByWeapon[key] = (attacker.damageByWeapon[key] or 0) + dmg
	end

	local tx, ty = self:GetPosition(target)
	local ax = sourceX
	if not ax and attacker then
		ax = self:GetPosition(attacker)
	end
	local kbx, kby, force = Combat.knockback(move, target.damage, charge, facing, tx - (ax or tx))
	local hitstun = Combat.hitstun(force)
	local hitstop = Combat.hitstop(force)
	local ragdoll = force >= B.RagdollForce
	if ragdoll then
		target.lastTumbleHit = now
	end
	self:addUlt(attacker, dmg * B.UltPerDamageDealt)
	self:addUlt(target, dmg * B.UltPerDamageTaken)

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
	if attacker then
		attacker.maxCombo = math.max(attacker.maxCombo, target.comboCount)
		-- a "true combo" (missions) is counted once, when it reaches TrueComboHits with every hit linked
		if target.comboCount == Config.Missions.TrueComboHits and target.comboTrue then
			attacker.trueCombos += 1
		end
	end

	target.lastHitBy = attackerId
	target.lastHitTime = now
	target.hitstunUntil = now + hitstop + hitstun
	if attacker then
		attacker.lastHitDealt = now
	end
	if target.isBot and target.state then
		FighterSim.applyHit(target.state, kbx, kby, hitstun, hitstop, ragdoll)
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
		ultimate = move.Ultimate == true,
		ragdoll = ragdoll,
		attackerUlt = attacker and attacker.ult,
		victimUlt = target.ult,
		x = tx,
		y = ty + Config.Physics.FighterHeight * 0.55,
	})
	return true, hitstop, false
end

-- Awakening: the meter's spent, everyone freezes for the cut-in, then the
-- fighter fights stronger and faster for a while, with one ultimate move.
function Match:Awaken(f)
	local now = self:now()
	f.ult = 0
	f.ultUsed = false
	f.awakenUntil = now + B.AwakenFreeze + B.AwakenTime
	f.invulnUntil = math.max(f.invulnUntil, now + B.AwakenFreeze)
	f.blocking = false
	for _, other in self.fighters do
		if other.isBot and other.state then
			if other == f then
				FighterSim.awaken(other.state, B.AwakenFreeze)
			else
				FighterSim.freeze(other.state, B.AwakenFreeze)
			end
		end
	end
	self:Broadcast("Awaken", { fighterId = f.id, freeze = B.AwakenFreeze, duration = B.AwakenTime })
end

function Match:EndAwakening(f)
	if f.awakenUntil > 0 then
		f.awakenUntil = 0
		self:Broadcast("AwakenEnd", { fighterId = f.id })
	end
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
	local now = self:now()
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
	if self:ApplyHit(f, target, move, rec.charge, rec.facing, nil, nil, rec.weapon) then
		rec.confirmed = true
	end
end

-- KOs, respawns, forfeits ---------------------------------------------------

function Match:KO(f, x, y)
	local now = self:now()
	f.alive = false
	f.falls += 1
	local credit = f.lastHitBy and now - f.lastHitTime <= Config.Combat.KOCreditWindow and self.fighters[f.lastHitBy]
		or nil
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
	self:callTraining("OnKO", f, credit)
	self:SetWeapon(f, "Unarmed")
	self:EndAwakening(f)
	f.blocking = false
	f.guard = B.GuardMax
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
		-- in real seconds, at the scale of the moment of the KO
		task.delay(Config.Combat.RespawnTime / self.timeScale, function()
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
	local now = self:now()
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
	-- may set f.damage (training: keep damage after a KO); the event below carries it
	self:callTraining("OnRespawn", f)
	self:Broadcast("Respawn", {
		fighterId = f.id,
		x = spot[1],
		y = spot[2],
		facing = facing,
		invuln = Config.Combat.RespawnInvuln,
		damage = f.damage,
	})
end

--[[
    Player quit, left the game, their character died, or (opts.noPenalty)
    the server couldn't load their fighter. Does nothing once the match has
    ended (Cleanup takes care of everyone still in it).
      - The character is released (unless the player is leaving the server,
        or already moved on to another match).
      - The player gets "Leave" if they got "Start", else SelectEvent
        "Cancel" (they are still on the VS splash).
      - Ranked before the fight: the leaver takes a loss (not with
        noPenalty) and the match is abandoned; everyone else is re-queued.
]]
function Match:Forfeit(f, opts)
	if self.phase == "Ended" or f.left then
		return
	end
	opts = opts or {}
	f.left = true
	f.noPenalty = opts.noPenalty == true
	f.alive = false
	f.eliminated = true
	f.eliminatedAt = self:now()
	if self.config.winRule == "Stocks" then
		f.stocks = 0
	end
	local wasPreFight = self.phase == "Loading" or self.phase == "Countdown"
	local player = f.player
	local penalty = not f.noPenalty and (self.phase == "Playing" or wasPreFight) and self.config.ranked
	if penalty and player and not f.ratingApplied then
		f.ratingApplied = true
		local total, count = 0, 0
		for _, other in self.fighters do
			if other.team ~= f.team and other.rating then
				total += other.rating
				count += 1
			end
		end
		if count > 0 then
			local ProgressionService = self.services.ProgressionService
			try("applyLeaver", ProgressionService.applyLeaver, player, self.config.mode, total / count, f.legend)
		end
	end
	if player then
		if player.Parent and not f.leavingServer then
			local current = self.services.MatchService.getMatchOf(player)
			if current == self or current == nil then
				releaseCharacter(player)
			end
			if self.startSent[player] then
				self:Send(player, "Leave", {})
			else
				self:sendCancel(player, f.noPenalty and "Couldn't load your fighter." or "You left the match.", false)
			end
		end
		if self.onPlayerLeft then
			self.onPlayerLeft(player)
		end
	end
	self:Broadcast("Left", { fighterId = f.id })
	if wasPreFight and self.config.ranked then
		-- Nobody gets a free ranked win from a dodge before the fight starts: everyone else goes back in the queue.
		local reason = f.noPenalty and "A fighter couldn't load." or (f.name .. " left before the fight.")
		self:Finish("Abandoned", 0, { requeue = true, reason = reason })
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

-- The player is leaving the server (MatchService's PlayerRemoving handler).
function Match:RemovePlayer(player)
	local f = self.playerFighters[player]
	if f then
		f.leavingServer = true
		self:Forfeit(f)
	end
end

-- Changes from outside the fight (the training room) -------------------------

-- Switches a fighter's legend (bots: never Avatar). ownLook nil keeps the current look choice.
function Match:SetLegend(f, legendId, ownLook)
	if not Legends.isValid(legendId) or (f.isBot and legendId == "Avatar") then
		return
	end
	f.legend = legendId
	if ownLook ~= nil then
		f.ownLook = ownLook == true and not f.isBot
	end
	local model = f.model
	if model and model.Parent then
		model:SetAttribute("Legend", legendId)
		if f.ownLook then
			LegendRig.detach(model)
		else
			LegendRig.attach(model, legendId)
		end
	end
	if Weapons.isWeapon(f.weapon) then
		-- a weapon the new legend can't use is dropped; one it can is re-mounted on the new rig
		self:SetWeapon(f, Legends.hasWeapon(legendId, f.weapon) and f.weapon or "Unarmed")
	end
	self:Broadcast("Legend", { fighterId = f.id, legend = legendId, ownLook = f.ownLook == true })
end

-- Sets a fighter's damage outside a hit. Values that aren't finite numbers are ignored.
function Match:SetDamage(f, value)
	if not finite(value) then
		return
	end
	f.damage = math.clamp(value, 0, Config.Combat.MaxDamage)
	self:Broadcast("Damage", { fighterId = f.id, total = f.damage })
end

-- Puts a fighter at (x, y), alive, keeping its damage (training: reset positions).
function Match:PlaceFighter(f, x, y, facing, invuln)
	if not finite(x) or not finite(y) then
		return
	end
	facing = facing == -1 and -1 or 1
	invuln = finite(invuln) and math.max(0, invuln) or 0
	local now = self:now()
	f.alive = true
	f.lastX, f.lastY, f.facing = x, y, facing
	f.invulnUntil = now + invuln
	if f.isBot then
		if f.state then
			FighterSim.respawn(f.state, x, y, facing, invuln)
		end
		if f.root then
			f.root.CFrame = Util.fighterCFrame(self.origin, x, y, f.feetOffset, facing)
			if self.phase == "Playing" then
				f.root.Anchored = false
				pcall(function()
					f.root:SetNetworkOwner(nil)
				end)
			end
		end
	else
		f.awaitingSpawn = true
		f.awaitingUntil = now + 3
	end
	self:Broadcast("Respawn", {
		fighterId = f.id,
		x = x,
		y = y,
		facing = facing,
		invuln = invuln,
		damage = f.damage,
	})
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

--[[
    Drops a weapon pickup and returns its id (nil when nothing can drop).
    Without weaponId: a random allowed weapon at a random weapon spawn (or
    at x, y when given). With weaponId: that weapon even if the match's
    weapon list leaves it out (the training spawner), at x, y.
]]
function Match:SpawnPickup(weaponId, x, y)
	if weaponId == nil then
		if #self.allowedWeapons == 0 then
			return nil
		end
		weaponId = Util.pick(self.allowedWeapons, self.rng)
	elseif not Weapons.isWeapon(weaponId) then
		return nil
	end
	if not finite(x) or not finite(y) then
		if #self.map.WeaponSpawns == 0 then
			return nil
		end
		local spot = Util.pick(self.map.WeaponSpawns, self.rng)
		x, y = spot[1], spot[2]
	end
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
		x = x,
		y = y,
		groundY = Maps.groundBelow(self.world, x, y),
		falling = true,
		spawnedAt = self:now(),
	}
	model:PivotTo(CFrame.new(self.origin + Vector3.new(pickup.x, pickup.y + 1, 0)) * WeaponModels.DisplayRotation)
	model.Parent = self.folder:FindFirstChild("Pickups")
	self.pickups[id] = pickup
	return id
end

function Match:removePickup(id)
	local pickup = self.pickups[id]
	if pickup then
		self.pickups[id] = nil
		pickup.model:Destroy()
	end
end

function Match:stepPickups(dt, now)
	if now >= self.nextPickupAt and self.config.autoWeapons ~= false then
		local count = 0
		for _ in self.pickups do
			count += 1
		end
		if count < Config.WeaponDrops.MaxOnStage then
			self:SpawnPickup()
		end
		self.nextPickupAt = now
			+ self.rng:NextNumber(Config.WeaponDrops.SpawnIntervalMin, Config.WeaponDrops.SpawnIntervalMax)
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
				pickup.model:PivotTo(
					CFrame.new(self.origin + Vector3.new(pickup.x, pickup.y + 1, 0)) * WeaponModels.DisplayRotation
				)
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
			sourceWeapon = rec.weapon, -- arrows count for the bow (mission stats)
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
		if
			proj.age >= proj.lifetime
			or Maps.isOutOfBounds(self.world, proj.x, proj.y)
			or insideSolid(self.world, proj.x, proj.y)
		then
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
							local weaponId = proj.weaponId or proj.sourceWeapon
							local hit = self:ApplyHit(
								owner,
								target,
								proj.move,
								proj.charge,
								facing,
								proj.x - facing,
								true,
								weaponId
							)
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

local VALID_SLOTS = { Ultimate = true }
for _, slot in Weapons.Slots do
	VALID_SLOTS[slot] = true
end

-- Invulnerability a downed fighter gets, and how long after a tumbling hit
-- a knockdown or tech can still be claimed.
local DOWN_INVULN = {
	Knockdown = B.KnockdownTime + B.GetUpTime,
	GetUp = B.GetUpTime,
	Tech = B.TechRollTime,
}
local DOWN_WINDOW = Config.Combat.MaxHitstun + 4

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
	-- Punch chain hits cut each other's recovery short, hit or not.
	if prev.move.Chain and prev.move.Chain < 4 then
		return now - prev.start >= (prev.move.Startup + prev.move.Active) * COOLDOWN_LENIENCY
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

	-- Token bucket against remote spam (real time, whatever the match clock does).
	local realNow = os.clock()
	local rate = Config.Combat.MaxActionsPerSecond
	f.actionBudget = math.min(rate, f.actionBudget + (realNow - f.budgetClock) * rate)
	f.budgetClock = realNow
	if f.actionBudget < 1 then
		return
	end
	f.actionBudget -= 1
	local now = self:now()

	if kind == "Ready" then
		f.ready = true
		return
	elseif kind == "Forfeit" then
		-- the character is released; players get a new one only in their next match
		self:Forfeit(f)
		return
	end
	if self.phase ~= "Playing" or not f.alive or type(data) ~= "table" then
		return
	end
	-- FighterSim can't attack, dodge or throw during hitstun, and the server
	-- knows how long the hitstun it dealt lasts.
	local inHitstun = now < f.hitstunUntil - HITSTUN_SLACK
	if inHitstun and (kind == "Attack" or kind == "Dodge" or kind == "Throw" or kind == "Awaken") then
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
		if data.slot == "Ultimate" then
			if self:UltimateState(f) ~= "Attack" then
				return
			end
			f.ultUsed = true
		end
		f.blocking = false
		-- FighterSim can only attack out of an invulnerable dodge by gravity
		-- cancelling an air spot dodge, which ends the invulnerability.
		f.dodgeInvulnUntil = 0
		local facing = data.facing == -1 and -1 or 1
		f.facing = facing
		self:recordAttack(f, data.seq, data.slot, move, facing)
		self:Broadcast(
			"Action",
			{ fighterId = f.id, kind = "Attack", slot = data.slot, weapon = f.weapon, facing = facing, seq = data.seq },
			player
		)
	elseif kind == "Release" then
		local rec = validSeq(data.seq) and f.attacks[data.seq]
		if rec and finite(data.charge) then
			local maxCharge = rec.move.Charge or 0
			local elapsed = now - rec.start + 0.15
			rec.charge = math.clamp(data.charge, 0, maxCharge > 0 and math.min(1, elapsed / maxCharge) or 0)
			self:Broadcast(
				"Action",
				{ fighterId = f.id, kind = "Release", seq = data.seq, charge = rec.charge },
				player
			)
		end
	elseif kind == "Fire" then
		local rec = validSeq(data.seq) and f.attacks[data.seq]
		if rec and rec.move.Projectile and not rec.fired then
			local age = now - rec.start
			if
				age >= rec.move.Startup * 0.5
				and age < Weapons.maxAttackWindow(rec.move) + Config.Combat.HitTimeSlack
			then
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
	elseif kind == "Block" then
		local on = data.on == true and not inHitstun
		if on == f.blocking then
			return
		end
		f.blocking = on
		f.blockFacing = data.facing == -1 and -1 or 1
		self:Broadcast("Action", { fighterId = f.id, kind = "Block", on = on }, player)
	elseif kind == "Down" then
		local invuln = DOWN_INVULN[data.kind]
		if not invuln or now - f.lastTumbleHit > DOWN_WINDOW then
			return
		end
		f.blocking = false
		f.dodgeInvulnUntil = math.max(f.dodgeInvulnUntil, now + invuln + Config.Combat.DodgeInvulnSlack)
		local dir = data.dir == -1 and -1 or (data.dir == 1 and 1 or 0)
		self:Broadcast("Action", { fighterId = f.id, kind = "Down", downKind = data.kind, dir = dir }, player)
	elseif kind == "Awaken" then
		if self:UltimateState(f) == "Awaken" then
			self:Awaken(f)
		end
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

--[[
    Ends the match. linger = seconds the arena stays before Cleanup
    (Config.Match.EndLingerSeconds when nil; 0 = clean up now).
    opts.requeue: put the queue units back in their queue at Cleanup (ranked
    pre-fight dodges); opts.reason: the Cancel text for players who never
    got "Start". Cleanup is always scheduled, even when the results or the
    rewards fail.
]]
function Match:Finish(reason, linger, opts)
	if self.phase == "Ended" then
		return
	end
	opts = opts or {}
	linger = linger or Config.Match.EndLingerSeconds
	self.finishOpts = opts
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

	try("results", self.sendResults, self, reason, linger, opts, wasPlaying)

	if linger <= 0 then
		try("Cleanup", self.Cleanup, self)
	else
		task.delay(linger, function()
			try("Cleanup", self.Cleanup, self)
		end)
	end
end

-- Rewards (ProgressionService.applyMatch) for a match that reached Playing; {} when it can't pay them.
function Match:applyRewards(entries, hasBots, botDifficulties, duration)
	local ok, rewards = pcall(self.services.ProgressionService.applyMatch, {
		source = self.config.source,
		ranked = self.config.ranked,
		mode = self.config.mode,
		duration = duration,
		hasBots = hasBots,
		queueType = self.config.queueType,
		mapId = self.config.mapId,
		training = self.config.training ~= nil,
		minBotDifficulty = MatchRules.easiestBot(botDifficulties),
		damageMultiplier = self.config.damageMultiplier,
	}, entries)
	if not ok then
		warn("[Match] rewards failed:", rewards)
		return {}
	end
	return type(rewards) == "table" and rewards or {}
end

-- Finish's report: results rows, rewards, then "End" to started players and SelectEvent "Cancel" to the others.
function Match:sendResults(reason, linger, opts, wasPlaying)
	local teams, tied = self:rankTeams()
	local winnerTeam = (not tied and teams[1]) and teams[1].team or nil
	local results = {}
	local placementOf = {}
	for rank, t in teams do
		for _, f in t.members do
			local placement = tied and rank <= 2 and 1 or rank
			placementOf[f] = placement
			table.insert(results, {
				id = f.id,
				name = f.name,
				userId = f.userId,
				team = f.team,
				isBot = f.isBot,
				legend = f.legend,
				ownLook = f.ownLook == true,
				placement = placement,
				kos = f.kos,
				falls = f.falls,
				damageDealt = f.damageDealt,
				damageTaken = f.damageTaken,
				stocks = f.stocks,
				score = f.score,
				won = f.team == winnerTeam,
				left = f.left,
				mvp = false,
			})
		end
	end
	local mvpId = MatchRules.mvp(results)
	for _, row in results do
		row.mvp = row.id == mvpId
	end
	local duration = self.playStartedAt and (os.clock() - self.playStartedAt) or 0

	local rewards = {}
	if reason ~= "Abandoned" and wasPlaying then
		local hasBots = false
		local botDifficulties = {}
		for _, f in self.fighters do
			if f.isBot then
				hasBots = true
				table.insert(botDifficulties, f.difficulty)
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
					damageTaken = f.damageTaken,
					opponentRating = opponentRating,
					legend = f.legend,
					ownLook = f.ownLook == true,
					placement = placementOf[f],
					weaponDamage = table.clone(f.damageByWeapon),
					trueCombos = f.trueCombos,
					maxCombo = f.maxCombo,
				})
			end
		end
		rewards = self:applyRewards(entries, hasBots, botDifficulties, duration)
	end

	local postMatch = {
		queueType = self.training == nil and self.config.queueType or nil,
		botOptions = self.config.botOptions,
		roomId = self.config.roomId,
	}
	for player, f in self.playerFighters do
		if not f.left and player.Parent then
			if self.startSent[player] then
				self:Send(player, "End", {
					reason = reason,
					winnerTeam = winnerTeam,
					draw = tied,
					results = results,
					rewards = rewards[player],
					you = f.id,
					returnIn = linger,
					mode = self.config.mode,
					source = self.config.source,
					ranked = self.config.ranked == true,
					mapId = self.config.mapId,
					duration = duration,
					mvpId = mvpId,
					requeued = opts.requeue == true,
					postMatch = postMatch,
				})
			else
				-- still on the VS splash: they never saw this match
				self:sendCancel(player, opts.reason or "The match couldn't start.", opts.requeue == true)
			end
		end
	end
end

-- Cleanup for one player still in the fight: "Leave" if they got "Start", and their character goes.
function Match:releasePlayer(player)
	if player.Parent and self.services.MatchService.getMatchOf(player) == self then
		if self.startSent[player] then
			self:Send(player, "Leave", {})
		end
		releaseCharacter(player)
	end
end

--[[
    Releases everyone still in this match (players who already moved on to
    another match are left alone): "Leave" to those who got "Start", and
    their characters are destroyed. Then the arena goes, the slot is freed,
    MatchService forgets the match, and a ranked pre-fight dodge puts the
    other units back in the queue. Each step runs even when one before it
    fails.
]]
function Match:Cleanup()
	if self.cleanedUp then
		return
	end
	self.cleanedUp = true
	local leavers = {}
	for player, f in self.playerFighters do
		if f.left then
			if not f.noPenalty then
				table.insert(leavers, player)
			end
		else
			try("release", self.releasePlayer, self, player)
		end
	end
	local folder = self.folder
	self.folder = nil
	if folder then
		try("arena removal", folder.Destroy, folder)
	end
	try("slot release", self.services.ArenaService.release, self.slot)
	if self.onFinished then
		try("onFinished", self.onFinished, self)
	end
	local opts = self.finishOpts or {}
	if opts.requeue and self.config.units and self.config.queueType then
		try("requeue", self.services.QueueService.requeue, self.config.units, self.config.queueType, leavers)
	end
end

return Match
