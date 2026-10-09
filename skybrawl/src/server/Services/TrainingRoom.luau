--[[
    One training room (menus design 4.11): the hook object a training Match
    carries (config.training), and the TrainingRequest controls for it.

    Match calls (each in a pcall):
      Attach(match)     end of Match.new
      OnPlaced()        the fighters are placed: the dummy's bot brain goes
                        inside a DummyBrain (the behaviour picker), and stays
                        its fight brain and its way back to the stage
      Step(dt)          every Playing frame: the first "Settings" right after
                        the countdown, then a "Dummy" snapshot to the player
                        every 1 / Config.Training.SnapshotRate real seconds
      OnKO(f, credit)   counts the dummy's KOs and remembers its damage
      OnRespawn(f)      "Keep damage after KO": the dummy comes back with that
                        damage (Match broadcasts Respawn with it right after)

    room:Control(action, payload) runs one TrainingRequest action for the
    room's player (Start belongs to TrainingService). Leave works in any
    phase; everything else waits until the countdown is over. Every change
    sends the "Settings" event (TrainingEvent, menus design 3.2).
    The weapon spawner keeps its own oldest-first list of the pickups it
    dropped, so at most Config.Training.MaxManualPickups of them exist (the
    oldest goes only once the new one has dropped). RESET POSITIONS also
    brings back a fighter still waiting to respawn, with the damage its
    respawn would have given it (0, or the dummy's kept damage).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Legends = require(Shared.Legends)
local Weapons = require(Shared.Weapons)
local FighterSim = require(Shared.FighterSim)
local DummyBrain = require(Shared.DummyBrain)

local BotBrain = require(script.Parent.BotBrain)

local TrainingRoom = {}
TrainingRoom.__index = TrainingRoom

local BAD = "Bad request."
local WAIT = "Wait for the countdown."
local SPAWN_HEIGHT = 8 -- the spawner drops weapons this far above you

-- Frames left of a timer, for the dummy's state label.
local function framesLeft(seconds)
	return math.max(0, math.ceil(seconds * 60 - 1e-6))
end

-- What the dummy is doing, for the DUMMY readout: "IDLE", "HITSTUN 12F", "BLOCKSTUN 9F", "TUMBLE"...
function TrainingRoom.stateLabel(f, s)
	if not f.alive or not s then
		return "RESPAWNING"
	end
	local action = s.action
	if action == "Hitstun" then
		if s.hitstun > 0 then
			return "HITSTUN " .. framesLeft(s.hitstun) .. "F"
		end
		return if s.tumble then "TUMBLE" else "HITSTUN"
	elseif action == "Block" then
		if s.blockstun > 0 then
			return "BLOCKSTUN " .. framesLeft(s.blockstun) .. "F"
		end
		return "BLOCK"
	elseif action == "Stunned" then
		return "STUNNED " .. framesLeft(s.actionDuration - s.actionTime) .. "F"
	elseif action == "Knockdown" then
		return "DOWN"
	elseif action == "GetUp" then
		return "GETTING UP"
	elseif action == "TechRoll" then
		return "TECH"
	elseif action == "Attack" then
		return if s.charging then "CHARGING" else "ATTACK"
	elseif action == "Dodge" then
		return "DODGE"
	elseif action == "Dash" then
		return "DASH"
	elseif action == "Throw" then
		return "THROW"
	elseif action == "Awakening" then
		return "AWAKENING"
	end
	if s.grounded then
		return if math.abs(s.vx) > 2 then "RUN" else "IDLE"
	end
	return "AIRBORNE"
end

--[[
    opts = { mode?, difficulty?, clock? }: the dummy's starting behaviour
    and bot level (Config.Training defaults) and the real-time clock for
    the snapshot rate (os.clock; tests pass their own).
]]
function TrainingRoom.new(player, opts)
	opts = opts or {}
	local self = setmetatable({}, TrainingRoom)
	self.player = player
	self.mode = if table.find(Config.Training.DummyModes, opts.mode) then opts.mode else Config.Training.DefaultMode
	self.difficulty = if table.find(Config.Bots.DifficultyOrder, opts.difficulty)
		then opts.difficulty
		else Config.Training.DefaultDifficulty
	self.keepDamage = false
	self.kos = 0
	self.savedDamage = 0
	self.manualPickups = {} -- pickup ids the spawner dropped, oldest first
	self.clock = opts.clock or os.clock
	self.nextSnapshot = -math.huge
	self.settingsSent = false
	self.match = nil
	self.me = nil -- the player's fighter
	self.dummy = nil
	return self
end

-- Hooks --------------------------------------------------------------------------

function TrainingRoom:Attach(match)
	self.match = match
end

function TrainingRoom:OnPlaced()
	local match = self.match
	self.me = match.playerFighters[self.player]
	for _, id in match.order do
		local f = match.fighters[id]
		if f.isDummy then
			self.dummy = f
		end
	end
	local dummy = self.dummy
	if dummy then
		dummy.brain = DummyBrain.new(dummy, match, {
			mode = self.mode,
			fight = BotBrain.new(dummy, match, self.difficulty),
		})
	end
end

function TrainingRoom:Step(_dt)
	if not self.settingsSent then
		self:sendSettings()
	end
	local now = self.clock()
	if now >= self.nextSnapshot then
		local interval = 1 / Config.Training.SnapshotRate
		-- keeps the average rate even though frames don't land on the interval (never bursts to catch up)
		self.nextSnapshot = math.max(self.nextSnapshot + interval, now)
		local snapshot = self:snapshot()
		if snapshot then
			self.match:Send(self.player, "Training", snapshot)
		end
	end
end

function TrainingRoom:OnKO(f, _credit)
	if f == self.dummy then
		self.kos += 1
		self.savedDamage = f.damage
	end
end

function TrainingRoom:OnRespawn(f)
	if f == self.dummy and self.keepDamage then
		f.damage = self.savedDamage
	end
end

-- Events ---------------------------------------------------------------------------------

-- The "Dummy" TrainingEvent (plus `slot` while it attacks, for the hitbox tag), or nil before it exists.
function TrainingRoom:snapshot()
	local dummy = self.dummy
	local s = dummy and dummy.state
	if not s then
		return nil
	end
	local x1, y1, x2, y2 = FighterSim.activeHitbox(s)
	local hx1, hy1, hx2, hy2 = FighterSim.hurtbox(s.x, s.y)
	return {
		kind = "Dummy",
		fighterId = dummy.id,
		x = s.x,
		y = s.y,
		facing = s.facing,
		action = s.action,
		actionFrame = if s.action ~= nil then framesLeft(s.actionTime) else 0,
		slot = if s.action == "Attack" then s.slot else nil,
		hitbox = if x1 then { x1, y1, x2, y2 } else nil,
		hurtbox = { hx1, hy1, hx2, hy2 },
		damage = dummy.damage,
		mode = self.mode,
		difficulty = self.difficulty,
		kos = self.kos,
		stateLabel = TrainingRoom.stateLabel(dummy, s),
		legend = dummy.legend,
		weapon = dummy.weapon,
	}
end

-- The "Settings" TrainingEvent.
function TrainingRoom:settings()
	local me, dummy, match = self.me, self.dummy, self.match
	return {
		kind = "Settings",
		legend = if me then me.legend else "Avatar",
		weapon = if me then me.weapon else "Unarmed",
		dummyLegend = if dummy then dummy.legend else Config.Training.DummyLegend,
		dummyMode = self.mode,
		difficulty = self.difficulty,
		keepDamage = self.keepDamage,
		speed = if match then match.timeScale else 1,
	}
end

function TrainingRoom:sendSettings()
	self.settingsSent = true
	if self.match then
		self.match:Send(self.player, "Training", self:settings())
	end
end

-- Controls -------------------------------------------------------------------------------

-- Each returns ok, message?.
local CONTROLS = {}

function CONTROLS.SetLegend(room, p)
	if not Legends.isValid(p.legend) then
		return false, BAD
	end
	local match, me = room.match, room.me
	if me.weapon ~= "Unarmed" then
		match:SetWeapon(me, "Unarmed")
	end
	if me.legend ~= p.legend then
		match:SetLegend(me, p.legend)
	end
	return true
end

function CONTROLS.SetWeapon(room, p)
	local weapon = p.weapon
	local me = room.me
	if weapon ~= "Unarmed" and not (Weapons.isWeapon(weapon) and Legends.hasWeapon(me.legend, weapon)) then
		return false, BAD
	end
	if me.weapon ~= weapon then
		room.match:SetWeapon(me, weapon)
	end
	return true
end

function CONTROLS.SetDummyLegend(room, p)
	if not Legends.isValid(p.legend) or p.legend == "Avatar" then
		return false, BAD
	end
	if room.dummy.legend ~= p.legend then
		room.match:SetLegend(room.dummy, p.legend)
	end
	return true
end

function CONTROLS.SetDummyMode(room, p)
	if
		not table.find(Config.Training.DummyModes, p.mode) or not table.find(Config.Bots.DifficultyOrder, p.difficulty)
	then
		return false, BAD
	end
	local dummy = room.dummy
	local brain = dummy.brain
	room.mode = p.mode
	if brain and brain.setMode then
		brain:setMode(p.mode)
	end
	if p.difficulty ~= room.difficulty then
		room.difficulty = p.difficulty
		dummy.difficulty = p.difficulty
		if brain and brain.setFight then
			brain:setFight(BotBrain.new(dummy, room.match, p.difficulty))
		end
	end
	return true
end

function CONTROLS.SetDamage(room, p)
	local value = p.value
	-- (NaN fails value == value; the size check also rejects both infinities)
	if type(value) ~= "number" or value ~= value or math.abs(value) >= 1e6 then
		return false, BAD
	end
	room.match:SetDamage(room.dummy, math.floor(math.clamp(value, 0, Config.Combat.MaxDamage)))
	return true
end

function CONTROLS.KeepDamage(room, p)
	if type(p.on) ~= "boolean" then
		return false, BAD
	end
	room.keepDamage = p.on
	return true
end

function CONTROLS.SetSpeed(room, p)
	if type(p.scale) ~= "number" or not table.find(Config.Training.Speeds, p.scale) then
		return false, BAD
	end
	if room.match.timeScale ~= p.scale then
		room.match:SetTimeScale(p.scale)
	end
	return true
end

function CONTROLS.SpawnWeapon(room, p)
	if type(p.weapon) ~= "string" or not table.find(Weapons.Order, p.weapon) then
		return false, BAD
	end
	local match = room.match
	local list = room.manualPickups
	-- forget drops that were picked up or expired
	for i = #list, 1, -1 do
		if match.pickups[list[i]] == nil then
			table.remove(list, i)
		end
	end
	local x, y = match:GetPosition(room.me)
	local id = match:SpawnPickup(p.weapon, x, y + SPAWN_HEIGHT)
	if id == nil then
		-- (nothing is removed for a drop that didn't happen)
		return false, "The weapon couldn't drop here."
	end
	table.insert(list, id)
	-- over the cap: the oldest drops go
	while #list > Config.Training.MaxManualPickups do
		match:removePickup(table.remove(list, 1))
	end
	return true
end

function CONTROLS.ResetPositions(room, _p)
	local match = room.match
	local spawns = match.map.Spawns
	local first, second = spawns[1], spawns[2] or spawns[1]
	for id, projectile in match.projectiles do
		match:endProjectile(id, projectile)
	end
	for _, f in { room.me, room.dummy } do
		if not f.alive then
			-- KO'd and waiting for its respawn (which PlaceFighter's alive = true then skips): it comes back with
			-- the damage Respawn would give it, as PlaceFighter keeps f.damage
			f.damage = if f == room.dummy and room.keepDamage then room.savedDamage else 0
			f.lastHitBy = nil
		end
		-- both sims start fresh: the server's own stun, combo and block bookkeeping for them too
		f.hitstunUntil = 0
		f.comboBy = nil
		f.comboCount = 0
		f.blocking = false
	end
	match:PlaceFighter(room.me, first[1], first[2], first[3], 0)
	match:PlaceFighter(room.dummy, second[1], second[2], second[3], 0)
	return true
end

-- The actions room:Control knows besides Leave.
TrainingRoom.ACTIONS = {}
for name in CONTROLS do
	TrainingRoom.ACTIONS[name] = true
end

-- Runs one TrainingRequest action (not Start). Returns ok, message.
function TrainingRoom:Control(action, payload)
	local match = self.match
	if action == "Leave" then
		if match and match.phase ~= "Ended" then
			match:Finish("Abandoned", 0)
		end
		return true
	end
	local control = CONTROLS[action]
	if not control then
		return false, BAD
	end
	if not match or match.phase ~= "Playing" or not self.me or not self.dummy then
		return false, WAIT
	end
	local ok, message = control(self, if type(payload) == "table" then payload else {})
	if ok then
		self:sendSettings()
	end
	return ok, message
end

return TrainingRoom
