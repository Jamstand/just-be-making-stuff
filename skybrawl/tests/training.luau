--[[
    The training room (menus design 4.11, 5.11): the dummy's behaviours
    (DummyBrain with the real FighterSim and BotBrain), frame data and the
    combo readout (FrameData), the room's hooks and controls (TrainingRoom on
    a fake match that calls the hooks in Match's order) and TrainingRequest
    (TrainingService on fake services).
    Run from the skybrawl folder:  lune run tests/training
]]

local roblox = require("@lune/roblox")

local h = require("./harness")

local Config = h.require("Config")
local Maps = h.require("Maps")
local FighterSim = h.require("FighterSim")
local Combat = h.require("Combat")
local Legends = h.require("Legends")
local Weapons = h.require("Weapons")
local DummyBrain = h.require("DummyBrain")
local FrameData = h.require("FrameData")
local BotBrain = h.requireServer("BotBrain")
local TrainingRoom = h.requireServer("TrainingRoom")

local DT = 1 / 60
local MAP = Config.Training.MapId
local B = Config.Battle

-- Fakes ---------------------------------------------------------------------------

-- A match as BotBrain and DummyBrain read it (tests/bots.luau style).
local function brainMatch()
	local match = { world = Maps.getWorld(MAP), fighters = {}, pickups = {} }
	function match:SameTeam(a, b)
		return a.team == b.team
	end
	function match:GetPosition(f)
		return f.state.x, f.state.y
	end
	function match:IsAttacking(f)
		return f.state.action == "Attack"
	end
	function match:IsBlocking(f)
		return FighterSim.isBlocking(f.state)
	end
	function match:UltimateState(_f)
		return nil
	end
	return match
end

local function addFighter(match, id, team, x, y, facing)
	local f = {
		id = id,
		team = team,
		alive = true,
		eliminated = false,
		weapon = "Unarmed",
		legend = "Avatar",
		damage = 0,
		guard = B.GuardMax,
		state = FighterSim.newState(x, y, facing),
	}
	f.state.grounded = y == 0
	match.fighters[id] = f
	return f
end

local function ctxFor(match, f)
	return {
		world = match.world,
		weapon = f.weapon,
		legend = f.legend,
		armed = Weapons.isWeapon(f.weapon),
		nearPickup = false,
		ultimate = nil,
		awakened = false,
	}
end

local function quiet(input)
	if input.moveX ~= 0 or input.moveY ~= 0 or input.blockHeld or input.heavyHeld then
		return false
	end
	for _, remaining in input.buffer do
		if remaining > 0 then
			return false
		end
	end
	return true
end

local function idleInput()
	return {
		moveX = 0,
		moveY = 0,
		jumpHeld = false,
		heavyHeld = false,
		blockHeld = false,
		buffer = { Jump = 0, Light = 0, Heavy = 0, Dodge = 0, Throw = 0, Ultimate = 0 },
	}
end

-- One frame of your sim as MatchClient feeds the meter: the step's Attack / AttackEnd events, then observe.
-- Returns the meter's view and the step's events; the buffered presses count down like Input's.
local function meterStep(meter, s, input, ctx)
	local events = FighterSim.step(s, input, DT, ctx)
	for _, ev in events do
		if ev.type == "Attack" then
			meter:start(s.move, ev.seq)
		elseif ev.type == "AttackEnd" then
			meter:finish(ev.seq, s)
		end
	end
	for action, remaining in input.buffer do
		input.buffer[action] = math.max(0, remaining - DT)
	end
	return meter:observe(s), events
end

-- A training match as TrainingRoom sees it. KO / Respawn call the room's hooks in Match's order (4.4 item 6):
-- OnKO after the stock/score change; OnRespawn after damage = 0 and before the Respawn broadcast.
local function trainingSetup(opts)
	opts = opts or {}
	local clock = { now = 0 }
	local player = h.fakePlayer(opts.userId or 101, "Trainee")
	local room = TrainingRoom.new(player, {
		clock = function()
			return clock.now
		end,
	})
	local match = {
		id = 7,
		phase = opts.phase or "Playing",
		fighters = {},
		order = {},
		playerFighters = {},
		pickups = {},
		projectiles = {},
		timeScale = 1,
		map = Maps.get(MAP),
		world = Maps.getWorld(MAP),
		training = room,
		sent = {},
		broadcasts = {},
		calls = {},
		nextId = 0,
	}
	local function record(name, ...)
		table.insert(match.calls, { name = name, args = table.pack(...) })
	end
	function match:Send(_player, kind, data)
		table.insert(self.sent, { kind = kind, data = data })
	end
	function match:Broadcast(kind, data)
		table.insert(self.broadcasts, { kind = kind, data = data })
	end
	function match:SameTeam(a, b)
		return a.team == b.team
	end
	function match:GetPosition(f)
		if f.state then
			return f.state.x, f.state.y
		end
		return f.lastX, f.lastY
	end
	function match:IsAttacking(f)
		return f.state ~= nil and f.state.action == "Attack"
	end
	function match:IsBlocking(f)
		return f.state ~= nil and FighterSim.isBlocking(f.state)
	end
	function match:UltimateState(_f)
		return nil
	end
	function match:SetLegend(f, legend, ownLook)
		record("SetLegend", f, legend, ownLook)
		f.legend = legend
	end
	function match:SetWeapon(f, weapon)
		record("SetWeapon", f, weapon)
		f.weapon = weapon
	end
	function match:SetDamage(f, value)
		record("SetDamage", f, value)
		f.damage = value
	end
	function match:SetTimeScale(scale)
		record("SetTimeScale", scale)
		self.timeScale = scale
	end
	function match:SpawnPickup(weapon, x, y)
		self.nextId += 1
		self.pickups[self.nextId] = { id = self.nextId, weaponId = weapon, x = x, y = y }
		record("SpawnPickup", weapon, x, y)
		return self.nextId
	end
	function match:removePickup(id)
		record("removePickup", id)
		self.pickups[id] = nil
	end
	function match:endProjectile(id, _projectile)
		record("endProjectile", id)
		self.projectiles[id] = nil
	end
	function match:PlaceFighter(f, x, y, facing, invuln)
		record("PlaceFighter", f, x, y, facing, invuln)
		f.alive = true -- (and keeps f.damage)
		self:Broadcast(
			"Respawn",
			{ fighterId = f.id, x = x, y = y, facing = facing, invuln = invuln, damage = f.damage }
		)
	end
	function match:Finish(reason, linger)
		record("Finish", reason, linger)
		self.phase = "Ended"
	end
	function match:KO(f)
		f.alive = false
		f.score -= 1
		self.training:OnKO(f, nil)
		f.weapon = "Unarmed"
	end
	function match:Respawn(f)
		f.alive = true
		f.damage = 0
		self.training:OnRespawn(f)
		self:Broadcast("Respawn", { fighterId = f.id, damage = f.damage })
	end

	local me = {
		id = "p" .. player.UserId,
		player = player,
		team = 1,
		legend = "Kestrel",
		weapon = "Unarmed",
		alive = true,
		damage = 0,
		score = 0,
		lastX = -14,
		lastY = 0,
	}
	local dummy = {
		id = "b1",
		isBot = true,
		isDummy = true,
		team = 2,
		legend = "Brann",
		weapon = "Unarmed",
		difficulty = "Normal",
		alive = true,
		eliminated = false,
		damage = 0,
		score = 0,
		guard = B.GuardMax,
		state = FighterSim.newState(14, 0, -1),
	}
	dummy.state.grounded = true
	match.fighters[me.id] = me
	match.fighters[dummy.id] = dummy
	match.order = { me.id, dummy.id }
	match.playerFighters[player] = me
	room:Attach(match)
	room:OnPlaced()
	return { room = room, match = match, me = me, dummy = dummy, player = player, clock = clock }
end

local function callsNamed(match, name)
	local list = {}
	for _, call in match.calls do
		if call.name == name then
			table.insert(list, call)
		end
	end
	return list
end

print("DummyBrain")

h.test("Stand dummy sends no input", function()
	local match = brainMatch()
	local player = addFighter(match, "p1", 1, -3, 0, 1)
	local dummy = addFighter(match, "b1", 2, 3, 0, -1)
	local fight = BotBrain.new(dummy, match, "Hard")
	local brain = DummyBrain.new(dummy, match, { mode = "Stand", fight = fight })
	player.state.action = "Attack" -- even with an attack coming
	for _ = 1, 120 do
		local input = brain:Update(DT)
		h.expect(input ~= fight.input, "a standing dummy on the stage used the bot brain")
		h.expect(quiet(input), "a standing dummy pressed something")
	end
end)

h.test("Jump dummy jumps on its timer when grounded", function()
	local match = brainMatch()
	addFighter(match, "p1", 1, -10, 0, 1)
	local dummy = addFighter(match, "b1", 2, 3, 0, -1)
	local brain = DummyBrain.new(dummy, match, { mode = "Jump", fight = BotBrain.new(dummy, match, "Normal") })
	local presses = {}
	local t = 0
	local function run(seconds)
		for _ = 1, math.floor(seconds * 60 + 0.5) do
			t += DT
			local input = brain:Update(DT)
			if input.buffer.Jump >= Config.InputBufferTime - 1e-9 then
				table.insert(presses, t)
			end
			-- (the sim would use the press at once; this fake keeps the buffer, so clear it like the sim does)
			input.buffer.Jump = 0
		end
	end
	run(2)
	h.expect(#presses == 2, "expected 2 jumps in 2 s on the ground, got " .. #presses)
	h.near(presses[1], Config.Training.JumpInterval, DT * 1.5, "first jump")
	h.near(presses[2] - presses[1], Config.Training.JumpInterval, DT * 1.5, "jump interval")
	-- in the air the timer runs out, but it waits for the ground
	dummy.state.grounded = false
	local before = #presses
	run(2)
	h.expect(#presses == before, "jumped while airborne")
	dummy.state.grounded = true
	run(DT)
	h.expect(#presses == before + 1, "didn't jump on landing once the timer had run out")
end)

h.test("Dodge dummy spot-dodges an incoming attack in range", function()
	local match = brainMatch()
	local player = addFighter(match, "p1", 1, -3, 0, 1)
	local dummy = addFighter(match, "b1", 2, 3, 0, -1)
	local brain = DummyBrain.new(dummy, match, { mode = "Dodge", fight = BotBrain.new(dummy, match, "Normal") })
	local input = brain:Update(DT)
	h.expect(input.buffer.Dodge == 0, "dodged with nothing coming")
	player.state.action = "Attack"
	input = brain:Update(DT)
	h.expect(input.buffer.Dodge > 0, "didn't dodge an attack in range")
	h.expect(input.moveX == 0 and input.moveY == 0, "a spot dodge has no direction")
	-- the real sim turns that into a spot dodge (invulnerable)
	FighterSim.step(dummy.state, input, DT, ctxFor(match, dummy))
	h.expect(dummy.state.action == "Dodge" and dummy.state.dodgeKind == "Spot", "the sim didn't spot dodge")
	h.expect(FighterSim.isInvulnerable(dummy.state), "a spot dodge is invulnerable")
	-- out of range: no dodge
	local far = DummyBrain.new(dummy, match, { mode = "Dodge" })
	player.state.x = dummy.state.x - Config.Training.DodgeRange - 2
	input = far:Update(DT)
	h.expect(input.buffer.Dodge == 0, "dodged an attack out of range")
end)

h.test("Block dummy turns to face the player, then holds block", function()
	local match = brainMatch()
	addFighter(match, "p1", 1, -5, 0, 1)
	local dummy = addFighter(match, "b1", 2, 3, 0, 1) -- facing away from the player
	local brain = DummyBrain.new(dummy, match, { mode = "Block", fight = BotBrain.new(dummy, match, "Normal") })
	local ctx = ctxFor(match, dummy)
	local input = brain:Update(DT)
	h.expect(input.moveX == -1 and not input.blockHeld, "should turn toward the player first")
	FighterSim.step(dummy.state, input, DT, ctx)
	h.expect(dummy.state.facing == -1, "didn't turn")
	input = brain:Update(DT)
	h.expect(input.blockHeld and input.moveX == 0, "should hold block once facing the player")
	FighterSim.step(dummy.state, input, DT, ctx)
	h.expect(FighterSim.isBlocking(dummy.state), "the sim isn't blocking")
	for _ = 1, 30 do
		input = brain:Update(DT)
		FighterSim.step(dummy.state, input, DT, ctx)
	end
	h.expect(FighterSim.isBlocking(dummy.state) and dummy.state.facing == -1, "stopped blocking")
	h.expect(math.abs(dummy.state.x - 3) < 0.5, "walked while blocking")
end)

h.test("Fight dummy defers to the bot brain", function()
	local match = brainMatch()
	addFighter(match, "p1", 1, -5, 0, 1)
	local dummy = addFighter(match, "b1", 2, 3, 0, -1)
	local sentinel = { moveX = 1, moveY = 0, buffer = {} }
	local updates = 0
	local fight = {
		Update = function(_self, _dt)
			updates += 1
			return sentinel
		end,
		isOffstage = function(_self, _s)
			return false
		end,
	}
	local brain = DummyBrain.new(dummy, match, { mode = "Fight", fight = fight })
	h.expect(brain:Update(DT) == sentinel and updates == 1, "Fight didn't use the bot brain")
	brain:setMode("Stand")
	h.expect(brain:Update(DT) ~= sentinel and updates == 1, "Stand used the bot brain on the stage")
	-- a new bot level swaps the fight brain
	local other = { moveX = -1, moveY = 0, buffer = {} }
	brain:setFight({
		Update = function()
			return other
		end,
		isOffstage = function()
			return false
		end,
	})
	brain:setMode("Fight")
	h.expect(brain:Update(DT) == other, "setFight didn't take")
end)

h.test("an offstage dummy recovers through the bot brain", function()
	local match = brainMatch()
	addFighter(match, "p1", 1, -5, 0, 1)
	local dummy = addFighter(match, "b1", 2, 40, -6, -1) -- past the right edge of Duel Rock, below its top
	local fight = BotBrain.new(dummy, match, "Hard")
	-- (DummyBrain wakes the bot brain through this field: a rename must fail here)
	h.expect(type(fight.thinkTimer) == "number", "BotBrain has no thinkTimer for DummyBrain to reset")
	fight.thinkTimer = 5 -- a stale decision must not delay the recovery
	for _, mode in DummyBrain.MODES do
		local brain = DummyBrain.new(dummy, match, { mode = mode, fight = fight })
		local input = brain:Update(DT)
		h.expect(input == fight.input, mode .. " dummy off the stage didn't use the bot brain")
		h.expect(input.moveX == -1, mode .. " dummy didn't head back to the stage")
	end
	-- the real thing: a standing dummy knocked off the side gets back on
	local brain = DummyBrain.new(dummy, match, { mode = "Stand", fight = fight })
	dummy.state = FighterSim.newState(34, 4, -1)
	dummy.state.vx = 12
	local ctx = ctxFor(match, dummy)
	local landed = false
	for _ = 1, 360 do
		FighterSim.step(dummy.state, brain:Update(DT), DT, ctx)
		if dummy.state.grounded then
			landed = true
			break
		end
		h.expect(not Maps.isOutOfBounds(match.world, dummy.state.x, dummy.state.y), "fell out")
	end
	h.expect(landed, "never made it back to the stage")
end)

h.test("a blocking dummy takes no damage from lights", function()
	local match = brainMatch()
	local attacker = addFighter(match, "p1", 1, -1.8, 0, 1)
	local dummy = addFighter(match, "b1", 2, 1.8, 0, 1) -- facing away: it has to turn first
	local brain = DummyBrain.new(dummy, match, { mode = "Block", fight = BotBrain.new(dummy, match, "Normal") })
	local press = {
		moveX = 0,
		moveY = 0,
		jumpHeld = false,
		heavyHeld = false,
		blockHeld = false,
		buffer = { Jump = 0, Light = 0, Heavy = 0, Dodge = 0, Throw = 0, Ultimate = 0 },
	}
	local blocks, lights, hitSeq = 0, 0, {}
	local nextPress = 0
	local t = 0
	for _ = 1, 4 * 60 do
		t += DT
		-- the attacker: walk into range, then a light every 0.35 s (neutral chain and side lights)
		local a, d = attacker.state, dummy.state
		local dx = d.x - a.x
		press.moveX = 0
		for action, remaining in press.buffer do
			press.buffer[action] = math.max(0, remaining - DT)
		end
		if math.abs(dx) > 2.6 then
			press.moveX = if dx > 0 then 1 else -1
		elseif t >= nextPress and a.action == nil then
			press.buffer.Light = Config.InputBufferTime
			if lights % 2 == 1 then
				press.moveX = if dx > 0 then 1 else -1
			end
			lights += 1
			nextPress = t + 0.35
		end
		for _, ev in FighterSim.step(a, press, DT, ctxFor(match, attacker)) do
			if ev.type == "Attack" then
				hitSeq[ev.seq] = false
			end
		end
		FighterSim.step(d, brain:Update(DT), DT, ctxFor(match, dummy))
		-- the fake match's hit check (Match.ApplyHit's block rule: blocking, and the hit comes from the front)
		local x1, y1, x2, y2 = FighterSim.activeHitbox(a)
		if x1 and hitSeq[a.seq] == false then
			local hx1, hy1, hx2, hy2 = FighterSim.hurtbox(d.x, d.y)
			if FighterSim.overlaps(x1, y1, x2, y2, hx1, hy1, hx2, hy2) then
				hitSeq[a.seq] = true
				local move = a.move
				h.expect(move.Kind == "Light", "the attacker used a heavy")
				if FighterSim.isBlocking(d) and not move.Unblockable and (a.x - d.x) * d.facing >= -0.5 then
					blocks += 1
					FighterSim.applyBlock(d, (if d.x >= a.x then 1 else -1) * B.BlockPushback, B.BlockStun, 0)
				else
					dummy.damage += Combat.damage(move, 0, 1)
					local kbx, kby, force = Combat.knockback(move, dummy.damage, 0, a.facing, d.x - a.x)
					FighterSim.applyHit(d, kbx, kby, Combat.hitstun(force), 0, false)
				end
			end
		end
	end
	h.expect(blocks >= 4, "too few lights reached the dummy: " .. blocks)
	h.expect(dummy.damage == 0, "the blocking dummy took " .. dummy.damage .. " damage")
end)

print("FrameData")

h.test("FrameData.summary matches Legends.getAttack (Avatar Sword side light is 7/6/12)", function()
	local move = Legends.getAttack("Avatar", "Sword", "SLight")
	local s = FrameData.summary(move)
	h.expect(
		s.startup == 7 and s.active == 6 and s.recovery == 12,
		string.format("Avatar Sword side light is %d/%d/%d", s.startup, s.active, s.recovery)
	)
	h.expect(s.total == 24, "total frames " .. s.total)
	h.expect(s.name == "Side Light" and s.kind == "Light" and not s.air, "name/kind/air")
	h.expect(
		s.damage == move.Damage
			and s.kbBase == move.BaseKnockback
			and s.kbScaling == move.KnockbackScaling
			and s.angle == move.Angle,
		"damage and knockback come from the move"
	)
	-- every attack: the numbers are the legend-scaled seconds in 60 fps frames
	local count = 0
	for _, legendId in Legends.Order do
		for _, weaponId in { "Unarmed", table.unpack(Weapons.Order) } do
			for _, slot in { "Ultimate", table.unpack(Weapons.Slots) } do
				local m = Legends.getAttack(legendId, weaponId, slot)
				if m then
					local f = FrameData.summary(m)
					count += 1
					local label = legendId .. " " .. weaponId .. " " .. slot
					h.expect(math.abs(f.startup - m.Startup * 60) < 1 or f.startup == 1, label .. " startup")
					h.expect(math.abs(f.startup + f.active - (m.Startup + m.Active) * 60) < 1, label .. " active")
					h.expect(math.abs(f.total + 1 - (m.Startup + m.Active + m.Recovery) * 60) < 1, label .. " total")
					h.expect(f.total == f.startup - 1 + f.active + f.recovery, label .. " total = sum")
					h.expect(f.active >= 1 and f.recovery >= 0, label .. " phases")
					h.expect(f.charge == FrameData.frames(m.Charge or 0), label .. " charge")
					h.expect(f.name == (m.Signature or Weapons.SlotNames[slot]), label .. " name")
				end
			end
		end
	end
	h.expect(count > 500, "too few attacks checked: " .. count)
	-- Dexterity is in: Brann (4) is slower than the weapon's own numbers, Yuki (7) faster
	local base = Weapons.getAttack("Spear", "SLight")
	h.expect(
		FrameData.summary(Legends.getAttack("Yuki", "Spear", "SLight")).total
			< FrameData.frames(base.Startup + base.Active + base.Recovery),
		"Yuki's Dexterity isn't applied"
	)
	h.expect(FrameData.frames(0.1) == 6 and FrameData.frames(0.11) == 7, "frames() rounds to the nearest frame")
end)

h.test("FrameData.phaseAt marks startup, active and recovery frames", function()
	local move = Legends.getAttack("Avatar", "Sword", "SLight")
	local expected = {
		[1] = "Startup",
		[6] = "Startup",
		[7] = "Active",
		[12] = "Active",
		[13] = "Recovery",
		[24] = "Recovery",
		[25] = "Done",
	}
	for frame, phase in expected do
		local got, index = FrameData.phaseAt(move, frame / 60, false)
		h.expect(got == phase and index == frame, string.format("frame %d: %s %d", frame, got, index))
	end
	local phase, index = FrameData.phaseAt(move, 0.05, true)
	h.expect(phase == "Charge" and index == 0, "charging is frame 0")
	-- against the real sim: "Active" exactly while FighterSim has a hitbox out
	local match = brainMatch()
	local f = addFighter(match, "p1", 1, 0, 0, 1)
	local input = {
		moveX = 1,
		moveY = 0,
		jumpHeld = false,
		heavyHeld = false,
		blockHeld = false,
		buffer = { Jump = 0, Light = Config.InputBufferTime, Heavy = 0, Dodge = 0, Throw = 0, Ultimate = 0 },
	}
	f.weapon = "Sword"
	local ctx = ctxFor(match, f)
	local cells = FrameData.cells(FrameData.summary(move))
	local frames = 0
	for _ = 1, 60 do
		FighterSim.step(f.state, input, DT, ctx)
		input.moveX = 0
		if f.state.action ~= "Attack" then
			break
		end
		frames += 1
		local p, i = FrameData.phaseAt(f.state.move, f.state.actionTime, f.state.charging)
		h.expect(i == frames, "frame index " .. i .. " on the sim's frame " .. frames)
		h.expect((p == "Active") == (FighterSim.activeHitbox(f.state) ~= nil), "phase " .. p .. " on frame " .. i)
		h.expect(cells[i] == p, "strip cell " .. i)
	end
	h.expect(frames == #cells, string.format("the sim attacked for %d frames, the strip has %d", frames, #cells))
end)

h.test("FrameData meter holds during a charge and shortens on a cancel", function()
	local meter = FrameData.newMeter()
	local heavy = Legends.getAttack("Avatar", "Unarmed", "NHeavy")
	h.expect((heavy.Charge or 0) > 0, "the test needs a chargeable heavy")
	meter:start(heavy, 1)
	local sim = { seq = 1, action = "Attack", actionTime = 0, charging = true }
	for _ = 1, 20 do
		local view = meter:observe(sim)
		h.expect(view.current == 0 and view.charging, "the meter ran during the charge")
	end
	sim.charging = false
	sim.actionTime = 3 / 60
	local view = meter:observe(sim)
	h.expect(view.current == 3 and not view.charging, "the meter didn't pick up after the charge")
	-- runs to its end: the whole strip, not cancelled
	local summary = FrameData.summary(heavy)
	sim.actionTime = summary.total / 60
	meter:observe(sim)
	sim.actionTime = (summary.total + 1) / 60
	view = meter:finish(1, sim)
	h.expect(view.done and not view.cancelled and #view.cells == summary.total, "a full attack came out cut")

	-- a side light that hit, jump-cancelled for real: FighterSim's grounded jump clears the action before its
	-- endAttack, so no AttackEnd comes; the frames it played stay and it is marked cancelled (not interrupted)
	local match = brainMatch()
	local f = addFighter(match, "p1", 1, 0, 0, 1)
	f.weapon = "Sword"
	local ctx = ctxFor(match, f)
	local input = idleInput()
	input.moveX = 1
	input.buffer.Light = Config.InputBufferTime
	local light = Legends.getAttack("Avatar", "Sword", "SLight")
	local played, jumped, confirmed = 0, nil, false
	for _ = 1, 60 do
		local events
		view, events = meterStep(meter, f.state, input, ctx)
		input.moveX = 0
		for _, ev in events do
			if ev.type == "Jump" then
				jumped = ev
			end
		end
		if jumped then
			break
		end
		played = view.current
		local s = f.state
		if not confirmed and FighterSim.activeHitbox(s) then
			confirmed = true
			FighterSim.onHitConfirm(s, 0)
		end
		if s.action == "Attack" and s.actionTime >= s.move.Startup + s.move.Active then
			input.buffer.Jump = Config.InputBufferTime
		end
	end
	h.expect(jumped and jumped.kind == "Ground" and jumped.cancel, "the sim didn't jump-cancel the light")
	h.expect(view.done and view.cancelled and not view.interrupted, "a jump cancel wasn't marked cancelled")
	local full = FrameData.cells(FrameData.summary(light))
	h.expect(#view.cells == played and played < #full, string.format("cancel kept %d cells", #view.cells))
	for i, cell in view.cells do
		h.expect(cell == full[i], "the strip kept the frames it played")
	end
	h.expect(view.cells[#view.cells] == "Recovery", "cancelled once its active frames were over")
	-- the next punch of a chain replaces the attack in the same step (the sim is on the new seq already)
	meter:start(light, 3)
	sim = { seq = 3, action = "Attack", actionTime = 5 / 60, charging = false }
	meter:observe(sim)
	view = meter:finish(3, { seq = 4, action = "Attack", actionTime = 1 / 60 })
	h.expect(view.cancelled and #view.cells == 5, "chain cut")
	-- a hit cuts it off without AttackEnd: interrupted
	meter:start(light, 5)
	meter:observe({ seq = 5, action = "Attack", actionTime = 4 / 60 })
	view = meter:observe({ seq = 5, action = "Hitstun", actionTime = 4 / 60 })
	h.expect(view.done and view.interrupted and not view.cancelled and #view.cells == 4, "interrupted by a hit")
	meter:start(light, 7)
	meter:observe({ seq = 7, action = "Attack", actionTime = 2 / 60 })
	view = meter:observe({ seq = 7, action = "Stunned", actionTime = 0 })
	h.expect(view.interrupted and not view.cancelled, "a guard break interrupts too")
	-- an old seq's AttackEnd doesn't touch the current meter
	meter:start(light, 6)
	view = meter:finish(5, sim)
	h.expect(not view.done, "an old AttackEnd froze the new attack")
end)

h.test("a ground pound that lands plays out its recovery and isn't a cancel", function()
	-- EndsOnLand: landing skips the rest of the active frames, then the recovery runs to the attack's end
	local match = brainMatch()
	local f = addFighter(match, "p1", 1, 0, 8, 1)
	local ctx = ctxFor(match, f)
	local meter = FrameData.newMeter()
	local input = idleInput()
	input.moveY = -1
	input.buffer.Heavy = Config.InputBufferTime
	local view, landedAt, ended = nil, nil, false
	for frame = 1, 240 do
		local events
		view, events = meterStep(meter, f.state, input, ctx)
		input.moveY = 0
		for _, ev in events do
			if ev.type == "Land" and not landedAt then
				landedAt = frame
			elseif ev.type == "AttackEnd" then
				ended = true
			end
		end
		if ended then
			break
		end
	end
	local summary = view.summary
	h.expect(summary and summary.name == "Ground Pound", "the sim didn't ground pound")
	h.expect(landedAt and landedAt < summary.startup + summary.active, "landed during the active frames")
	h.expect(ended and view.done and not view.cancelled and not view.interrupted, "a landed ground pound was cut")
	h.expect(#view.cells == summary.total and view.current == summary.total, "the whole strip, to its last frame")
end)

h.test("combo readout sums damage and resets on a new combo", function()
	local combo = FrameData.newCombo()
	combo:onHit({ combo = 1, trueCombo = true, damage = 8, total = 8 })
	combo:onHit({ combo = 2, trueCombo = true, damage = 9, total = 17 })
	combo:onHit({ combo = 3, trueCombo = true, damage = 9, total = 26 })
	local view = combo:get()
	h.expect(view.hits == 3 and view.damage == 26 and view.lastHit == 9, "3 hits, 26 damage, last +9")
	combo:onHit({ combo = 1, trueCombo = true, damage = 5, total = 31 })
	view = combo:get()
	h.expect(view.hits == 1 and view.damage == 5 and view.lastHit == 5, "a new combo starts over")
	-- a combo whose first hits never arrived starts over too
	combo:onHit({ combo = 4, trueCombo = false, damage = 3, total = 40 })
	combo:onHit({ combo = 2, trueCombo = true, damage = 6, total = 46 })
	view = combo:get()
	h.expect(view.hits == 2 and view.damage == 6, "a lower count is a new combo")
end)

h.test("combo readout says TRUE COMBO only while every hit linked", function()
	local combo = FrameData.newCombo()
	combo:onHit({ combo = 1, trueCombo = true, damage = 8 })
	h.expect(not combo:get().isTrue, "one hit isn't a combo")
	combo:onHit({ combo = 2, trueCombo = true, damage = 8 })
	h.expect(combo:get().isTrue, "two linked hits are a true combo")
	combo:onHit({ combo = 3, trueCombo = false, damage = 8 })
	h.expect(not combo:get().isTrue, "a hit that didn't link makes it a string")
	combo:onHit({ combo = 4, trueCombo = false, damage = 8 })
	h.expect(not combo:get().isTrue and combo:get().hits == 4, "still a string")
	combo:onHit({ combo = 1, trueCombo = true, damage = 8 })
	combo:onHit({ combo = 2, trueCombo = true, damage = 8 })
	h.expect(combo:get().isTrue, "a new combo can be true again")
end)

print("TrainingRoom")

h.test("keep damage survives a KO in the event order", function()
	local t = trainingSetup()
	local room, match, dummy = t.room, t.match, t.dummy
	dummy.damage = 85
	match:KO(dummy)
	match:Respawn(dummy)
	local last = match.broadcasts[#match.broadcasts]
	h.expect(last.kind == "Respawn" and last.data.damage == 0, "without keep damage the dummy comes back at 0")
	h.expect(room.kos == 1, "KO not counted")

	local ok = room:Control("KeepDamage", { on = true })
	h.expect(ok, "KeepDamage refused")
	h.expect(t.match.sent[#t.match.sent].data.keepDamage == true, "Settings didn't say keepDamage")
	dummy.damage = 85
	match:KO(dummy)
	h.expect(dummy.damage == 85, "OnKO touched the damage")
	match:Respawn(dummy)
	last = match.broadcasts[#match.broadcasts]
	h.expect(last.kind == "Respawn" and last.data.damage == 85, "the Respawn event didn't carry the kept damage")
	h.expect(dummy.damage == 85 and room.kos == 2, "kept damage / KOs")
	-- the player's own KO keeps nothing
	t.me.damage = 50
	t.me.score = 0
	match:KO(t.me)
	match:Respawn(t.me)
	h.expect(t.me.damage == 0 and room.kos == 2, "the player's KO went through the dummy rules")
end)

h.test("SetDamage rejects NaN and infinity", function()
	local t = trainingSetup()
	local room = t.room
	for _, bad in { 0 / 0, math.huge, -math.huge, "50", 1e6, -1e6, true } do
		local ok, message = room:Control("SetDamage", { value = bad })
		h.expect(not ok and message == "Bad request.", "accepted " .. tostring(bad))
	end
	h.expect(#callsNamed(t.match, "SetDamage") == 0, "a bad value reached Match:SetDamage")
	for _, case in { { 55.7, 55 }, { 5000, Config.Combat.MaxDamage }, { -5, 0 }, { 120, 120 } } do
		local ok = room:Control("SetDamage", { value = case[1] })
		local calls = callsNamed(t.match, "SetDamage")
		h.expect(
			ok and calls[#calls].args[2] == case[2],
			"SetDamage " .. case[1] .. " -> " .. tostring(calls[#calls].args[2])
		)
		h.expect(calls[#calls].args[1] == t.dummy, "SetDamage went to the wrong fighter")
	end
end)

h.test("manual weapon drops are capped and the oldest goes first", function()
	local t = trainingSetup()
	local room, match = t.room, t.match
	local max = Config.Training.MaxManualPickups
	for i = 1, max + 2 do
		local ok = room:Control("SpawnWeapon", { weapon = Weapons.Order[(i - 1) % #Weapons.Order + 1] })
		h.expect(ok, "SpawnWeapon refused")
	end
	local removed = callsNamed(match, "removePickup")
	h.expect(#removed == 2 and removed[1].args[1] == 1 and removed[2].args[1] == 2, "the two oldest drops go first")
	local live = 0
	for _ in match.pickups do
		live += 1
	end
	h.expect(live == max, "live drops: " .. live)
	local spawn = callsNamed(match, "SpawnPickup")[1]
	h.expect(spawn.args[2] == t.me.lastX and spawn.args[3] == t.me.lastY + 8, "drops at your x, 8 studs up")
	-- a drop someone picked up doesn't count any more
	match.pickups[3] = nil
	room:Control("SpawnWeapon", { weapon = "Bow" })
	h.expect(#callsNamed(match, "removePickup") == 2, "removed a drop although one was already gone")
	local ok, message = room:Control("SpawnWeapon", { weapon = "Unarmed" })
	h.expect(not ok and message == "Bad request.", "spawned Unarmed")
	-- a drop that can't happen removes nothing (the list is full: the old order removed the oldest first)
	local spawnPickup = match.SpawnPickup
	match.SpawnPickup = function()
		return nil
	end
	ok, message = room:Control("SpawnWeapon", { weapon = "Sword" })
	h.expect(not ok and message == "The weapon couldn't drop here.", "a failed drop: " .. tostring(message))
	h.expect(#callsNamed(match, "removePickup") == 2 and #room.manualPickups == max, "a failed drop lost an old one")
	match.SpawnPickup = spawnPickup
end)

h.test("controls are refused until the countdown ends", function()
	local valid = {
		SetLegend = { legend = "Kestrel" },
		SetWeapon = { weapon = "Sword" }, -- (Kestrel's)
		SetDummyLegend = { legend = "Sol" },
		SetDummyMode = { mode = "Block", difficulty = "Hard" },
		SetDamage = { value = 50 },
		KeepDamage = { on = true },
		SetSpeed = { scale = 0.5 },
		SpawnWeapon = { weapon = "Hammer" },
		ResetPositions = {},
	}
	for action in TrainingRoom.ACTIONS do
		h.expect(valid[action], "no test payload for " .. action)
	end
	for _, phase in { "Loading", "Countdown" } do
		local t = trainingSetup({ phase = phase })
		for action, payload in valid do
			local ok, message = t.room:Control(action, payload)
			h.expect(not ok and message == "Wait for the countdown.", action .. " allowed in " .. phase)
		end
		h.expect(#t.match.calls == 0, "a refused control changed the match")
	end
	local t = trainingSetup()
	for action, payload in valid do
		local ok, message = t.room:Control(action, payload)
		h.expect(ok, action .. " refused while playing: " .. tostring(message))
	end
	-- Leave works in any phase
	local early = trainingSetup({ phase = "Countdown" })
	h.expect(early.room:Control("Leave") == true, "Leave refused")
	local finish = callsNamed(early.match, "Finish")[1]
	h.expect(finish and finish.args[1] == "Abandoned" and finish.args[2] == 0, "Leave = Finish(Abandoned, 0)")
end)

h.test("controls change the match and send the settings", function()
	local t = trainingSetup()
	local room, match, me, dummy = t.room, t.match, t.me, t.dummy
	-- your legend: the weapon resets to Unarmed
	me.weapon = "Sword"
	h.expect(room:Control("SetLegend", { legend = "Vex" }), "SetLegend")
	h.expect(me.legend == "Vex" and me.weapon == "Unarmed", "legend / weapon reset")
	local settings = match.sent[#match.sent].data
	h.expect(settings.kind == "Settings" and settings.legend == "Vex" and settings.weapon == "Unarmed", "Settings")
	-- weapons: Unarmed or the legend's own (Avatar: any)
	h.expect(room:Control("SetWeapon", { weapon = "Scythe" }) and me.weapon == "Scythe", "Vex's scythe")
	h.expect(not room:Control("SetWeapon", { weapon = "Bow" }), "Vex can't hold a bow")
	h.expect(not room:Control("SetWeapon", { weapon = "Laser" }), "unknown weapon")
	room:Control("SetLegend", { legend = "Avatar" })
	h.expect(room:Control("SetWeapon", { weapon = "Bow" }) and me.weapon == "Bow", "Avatar holds anything")
	h.expect(not room:Control("SetLegend", { legend = "Nobody" }), "unknown legend")
	-- the dummy
	h.expect(not room:Control("SetDummyLegend", { legend = "Avatar" }), "the dummy can't be Avatar")
	h.expect(room:Control("SetDummyLegend", { legend = "Moss" }) and dummy.legend == "Moss", "dummy legend")
	local fightBefore = dummy.brain.fight
	h.expect(room:Control("SetDummyMode", { mode = "Dodge", difficulty = "Normal" }), "SetDummyMode")
	h.expect(dummy.brain.mode == "Dodge" and dummy.brain.fight == fightBefore, "mode only")
	h.expect(room:Control("SetDummyMode", { mode = "Fight", difficulty = "Hard" }), "SetDummyMode Hard")
	h.expect(dummy.brain.mode == "Fight" and dummy.brain.fight ~= fightBefore, "a new bot level swaps the fight brain")
	h.expect(dummy.brain.fight.difficulty == "Hard" and dummy.difficulty == "Hard", "bot level")
	h.expect(not room:Control("SetDummyMode", { mode = "Dance", difficulty = "Hard" }), "unknown mode")
	h.expect(not room:Control("SetDummyMode", { mode = "Stand", difficulty = "Insane" }), "unknown level")
	settings = match.sent[#match.sent].data
	h.expect(
		settings.dummyMode == "Fight" and settings.difficulty == "Hard" and settings.dummyLegend == "Moss",
		"Settings"
	)
	-- speed
	h.expect(not room:Control("SetSpeed", { scale = 0.3 }), "only Config.Training.Speeds")
	h.expect(room:Control("SetSpeed", { scale = 0.25 }) and match.timeScale == 0.25, "slow motion")
	h.expect(match.sent[#match.sent].data.speed == 0.25, "Settings speed")
	-- reset positions: spawns 1 and 2, no invulnerability, projectiles cleared, damage kept
	match.projectiles[41] = { x = 0, y = 0 }
	dummy.damage = 70
	dummy.hitstunUntil = 99
	h.expect(room:Control("ResetPositions"), "ResetPositions")
	local placed = callsNamed(match, "PlaceFighter")
	local spawns = Maps.get(MAP).Spawns
	h.expect(#placed == 2, "two fighters placed")
	h.expect(placed[1].args[1] == me and placed[1].args[2] == spawns[1][1] and placed[1].args[5] == 0, "you at spawn 1")
	h.expect(
		placed[2].args[1] == dummy and placed[2].args[2] == spawns[2][1] and placed[2].args[4] == spawns[2][3],
		"dummy"
	)
	h.expect(next(match.projectiles) == nil and #callsNamed(match, "endProjectile") == 1, "projectiles cleared")
	h.expect(dummy.damage == 70 and dummy.hitstunUntil == 0, "damage kept, stun cleared")
	local respawn = match.broadcasts[#match.broadcasts]
	h.expect(respawn.kind == "Respawn" and respawn.data.damage == 70, "Respawn carries the damage")
	-- unknown actions
	h.expect(select(2, room:Control("Explode", {})) == "Bad request.", "unknown action")
end)

h.test("reset positions brings a KO'd fighter back as its respawn would", function()
	local t = trainingSetup()
	local room, match, me, dummy = t.room, t.match, t.me, t.dummy
	local function lastRespawn(f)
		for i = #match.broadcasts, 1, -1 do
			local b = match.broadcasts[i]
			if b.kind == "Respawn" and b.data.fighterId == f.id then
				return b.data
			end
		end
		return nil
	end
	-- KO'd at 180% and reset during the respawn delay: back at 0, not 180
	dummy.damage = 180
	match:KO(dummy)
	h.expect(room:Control("ResetPositions"), "ResetPositions")
	h.expect(dummy.alive and dummy.damage == 0 and lastRespawn(dummy).damage == 0, "came back with its old damage")
	-- with keep damage after KO: the kept damage
	h.expect(room:Control("KeepDamage", { on = true }), "KeepDamage")
	dummy.damage = 120
	match:KO(dummy)
	room:Control("ResetPositions")
	h.expect(dummy.damage == 120 and lastRespawn(dummy).damage == 120, "keep damage after KO through a reset")
	-- your own KO: back at 0; a fighter still standing keeps its damage
	me.damage = 60
	match:KO(me)
	dummy.damage = 40
	room:Control("ResetPositions")
	h.expect(me.alive and me.damage == 0 and lastRespawn(me).damage == 0, "your KO'd damage came back")
	h.expect(dummy.damage == 40 and lastRespawn(dummy).damage == 40, "a standing fighter lost its damage")
end)

h.test("snapshots go out at the snapshot rate with the dummy's state", function()
	local t = trainingSetup()
	local room, match, dummy = t.room, t.match, t.dummy
	for _ = 1, 60 do
		t.clock.now += DT
		room:Step(DT)
	end
	local settings, dummies = 0, {}
	for _, sent in match.sent do
		if sent.kind == "Training" and sent.data.kind == "Settings" then
			settings += 1
		elseif sent.kind == "Training" and sent.data.kind == "Dummy" then
			table.insert(dummies, sent.data)
		end
	end
	h.expect(settings == 1, "the first Step sends the settings once: " .. settings)
	local rate = Config.Training.SnapshotRate
	h.expect(math.abs(#dummies - rate) <= 1, string.format("%d snapshots in a second (rate %d)", #dummies, rate))
	local snap = dummies[#dummies]
	h.expect(snap.fighterId == dummy.id and snap.stateLabel == "IDLE" and snap.mode == "Stand", "snapshot fields")
	h.expect(#snap.hurtbox == 4 and snap.hitbox == nil and snap.legend == "Brann", "boxes / legend")
	-- slow motion doesn't slow the snapshots (real seconds)
	match.timeScale = 0.25
	local before = #match.sent
	for _ = 1, 60 do
		t.clock.now += DT
		room:Step(DT * 0.25)
	end
	h.expect(math.abs(#match.sent - before - rate) <= 1, "snapshots follow real time")
	-- an attacking dummy sends its hitbox
	dummy.state.action = "Attack"
	dummy.state.move = Legends.getAttack("Brann", "Unarmed", "SLight")
	dummy.state.slot = "SLight"
	dummy.state.actionTime = dummy.state.move.Startup + 0.01
	local snapshot = room:snapshot()
	h.expect(snapshot.hitbox and #snapshot.hitbox == 4 and snapshot.slot == "SLight", "hitbox")
	h.expect(snapshot.stateLabel == "ATTACK" and snapshot.actionFrame > 0, "attack state")
end)

h.test("the dummy's state label reads the sim", function()
	local f = { alive = true }
	local s = FighterSim.newState(0, 0, 1)
	s.grounded = true
	h.expect(TrainingRoom.stateLabel(f, s) == "IDLE", "idle")
	s.action, s.hitstun = "Hitstun", 0.2
	h.expect(TrainingRoom.stateLabel(f, s) == "HITSTUN 12F", TrainingRoom.stateLabel(f, s))
	s.hitstun, s.tumble = 0, true
	h.expect(TrainingRoom.stateLabel(f, s) == "TUMBLE", "tumble")
	s.action, s.blockstun = "Block", 0.15
	h.expect(TrainingRoom.stateLabel(f, s) == "BLOCKSTUN 9F", TrainingRoom.stateLabel(f, s))
	s.action = "Knockdown"
	h.expect(TrainingRoom.stateLabel(f, s) == "DOWN", "down")
	s.action = "Dodge"
	h.expect(TrainingRoom.stateLabel(f, s) == "DODGE", "dodge")
	s.action, s.grounded = nil, false
	h.expect(TrainingRoom.stateLabel(f, s) == "AIRBORNE", "airborne")
	f.alive = false
	h.expect(TrainingRoom.stateLabel(f, s) == "RESPAWNING", "respawning")
end)

print("TrainingService")

-- TrainingService on fake services; returns the service, the fakes and the remote's invoke function.
local function serviceSetup()
	h.resetRemotes()
	local fakes = {
		profiles = {},
		busy = {},
		queued = {},
		rooms = {},
		matches = {},
		acquired = {},
		released = {},
		started = {},
		freeSlots = 2,
		failStart = false,
		warnings = {},
	}
	local services = {
		DataService = {
			get = function(player)
				return fakes.profiles[player]
			end,
		},
		MatchService = {
			busyReason = function(player)
				return fakes.busy[player]
			end,
			getMatchOf = function(player)
				return fakes.matches[player]
			end,
			startMatch = function(config, reserved)
				table.insert(fakes.started, { config = config, reserved = reserved })
				if fakes.failStart then
					return nil, "The match couldn't start."
				end
				local match = { phase = "Countdown", training = config.training, timeScale = 1 }
				for _, p in config.participants do
					if p.player then
						fakes.matches[p.player] = match
					end
				end
				return match
			end,
		},
		QueueService = {
			isQueued = function(player)
				return fakes.queued[player] == true
			end,
		},
		RoomService = {
			getRoomOf = function(player)
				return fakes.rooms[player]
			end,
		},
		ArenaService = {
			acquire = function(pool)
				table.insert(fakes.acquired, pool)
				if fakes.freeSlots <= 0 then
					return nil
				end
				fakes.freeSlots -= 1
				return 8 + #fakes.acquired, roblox.Vector3.new(0, 500, 0)
			end,
			release = function(slot)
				table.insert(fakes.released, slot)
				fakes.freeSlots += 1
			end,
		},
	}
	local TrainingService = h.requireServer("TrainingService", {
		warn = function(...)
			table.insert(fakes.warnings, table.concat({ ... }, " "))
		end,
	})
	TrainingService.init(services)
	TrainingService.start()
	local remote = h.remote("TrainingRequest")
	local function invoke(player, ...)
		return remote.OnServerInvoke(player, ...)
	end
	return TrainingService, fakes, invoke
end

local function profile(legend)
	return { Legend = legend or "Yuki", Settings = { FightAsAvatar = true } }
end

h.test("Start builds a training match on a training slot", function()
	local _, fakes, invoke = serviceSetup()
	local player = h.fakePlayer(201, "Learner")
	fakes.profiles[player] = profile("Yuki")
	local ok, message = invoke(player, "Start", { dummyLegend = "Vex" })
	h.expect(ok, "Start refused: " .. tostring(message))
	h.expect(fakes.acquired[1] == "Training", "slot from the Training pool")
	local started = fakes.started[1]
	local config = started.config
	h.expect(started.reserved.slot == 9 and started.reserved.origin ~= nil, "the reserved slot goes to startMatch")
	h.expect(config.mode == "1v1" and config.source == "Training" and config.ranked == false, "mode / source")
	h.expect(config.mapId == Config.Training.MapId and config.winRule == "Timed" and config.timeLimit == 0, "rules")
	h.expect(config.autoWeapons == false and config.damageMultiplier == 1 and config.weapons == nil, "weapons")
	local room = config.training
	h.expect(type(room.Control) == "function" and type(room.OnPlaced) == "function", "the room hook")
	h.expect(room.player == player and room.mode == Config.Training.DefaultMode, "the room's player and mode")
	local p1, p2 = config.participants[1], config.participants[2]
	h.expect(p1.player == player and p1.team == 1 and p1.legend == "Yuki" and p1.ownLook == true, "the player")
	h.expect(p2.bot and p2.dummy and p2.team == 2 and p2.legend == "Vex", "the dummy")
	h.expect(p2.name == Config.Training.DummyName and p2.difficulty == Config.Training.DefaultDifficulty, "dummy name")
	-- payload legend wins; an Avatar dummy falls back to the default
	local other = h.fakePlayer(202, "Other")
	fakes.profiles[other] = profile("Sol")
	invoke(other, "Start", { legend = "Moss", dummyLegend = "Avatar" })
	config = fakes.started[2].config
	h.expect(config.participants[1].legend == "Moss", "payload legend")
	h.expect(config.participants[2].legend == Config.Training.DummyLegend, "Avatar dummy refused")
end)

h.test("Start refuses players who aren't free, and gives the slot back on failure", function()
	local _, fakes, invoke = serviceSetup()
	local player = h.fakePlayer(203, "Busy")
	local ok, message = invoke(player, "Start", {})
	h.expect(not ok and message == "Your profile is still loading.", "no profile")
	fakes.profiles[player] = profile()
	fakes.busy[player] = "You're in a match."
	ok, message = invoke(player, "Start", {})
	h.expect(not ok and message == "You're in a match.", "busy")
	fakes.busy[player] = nil
	fakes.queued[player] = true
	ok, message = invoke(player, "Start", {})
	h.expect(not ok and message == "Cancel your search first.", "queued")
	fakes.queued[player] = nil
	fakes.rooms[player] = { id = 1 }
	ok, message = invoke(player, "Start", {})
	h.expect(not ok and message == "Leave your custom room first.", "in a room")
	fakes.rooms[player] = nil
	h.expect(#fakes.acquired == 0, "a refused Start took a slot")
	fakes.freeSlots = 0
	ok, message = invoke(player, "Start", {})
	h.expect(not ok and message == "The training rooms are full. Try again in a moment.", "full")
	fakes.freeSlots = 1
	fakes.failStart = true
	ok, message = invoke(player, "Start", {})
	h.expect(not ok and message == "The match couldn't start.", "startMatch failed: " .. tostring(message))
	h.expect(#fakes.released == 1 and fakes.released[1] == fakes.started[1].reserved.slot, "slot released")
end)

h.test("TrainingRequest controls reach your own room only, and spam is refused", function()
	-- bound before init (not Main.server's order): "Not ready."
	h.resetRemotes()
	h.requireServer("TrainingService").start()
	local early, earlyMessage = h.remote("TrainingRequest").OnServerInvoke(h.fakePlayer(299, "Early"), "Start", {})
	h.expect(early == false and earlyMessage == "Not ready.", "a request before init")
	local _, fakes, invoke = serviceSetup()
	local player = h.fakePlayer(204, "Trainee")
	local stranger = h.fakePlayer(205, "Stranger")
	fakes.profiles[player] = profile()
	invoke(player, "Start", {})
	local ok, message = invoke(stranger, "SetDamage", { value = 10 })
	h.expect(not ok and message == "Wait for the countdown.", "a stranger reached a room")
	ok, message = invoke(stranger, "Leave")
	h.expect(not ok and message == "You're not in the training room.", "Leave outside a room")
	fakes.matches[stranger] = fakes.matches[player]
	ok, message = invoke(stranger, "SetDamage", { value = 10 })
	h.expect(not ok and message == "Wait for the countdown.", "someone else's room")
	ok, message = invoke(stranger, "Leave")
	h.expect(not ok and message == "You're not in the training room.", "left someone else's room")
	h.expect(fakes.matches[player].phase == "Countdown", "a stranger ended the room")
	ok, message = invoke(player, "SetDamage", { value = 10 })
	h.expect(not ok and message == "Wait for the countdown.", "countdown: " .. tostring(message))
	ok, message = invoke(player, "Teleport", {})
	h.expect(not ok and message == "Bad request.", "unknown action")
	ok, message = invoke(player, 42)
	h.expect(not ok and message == "Bad request.", "not a string")
	-- a broken handler answers instead of throwing
	local room = fakes.matches[player].training
	room.Control = function()
		error("boom")
	end
	ok, message = invoke(player, "KeepDamage", { on = true })
	h.expect(not ok and message == "Something went wrong.", "errors are wrapped")
	h.expect(#fakes.warnings == 1 and string.find(fakes.warnings[1], "boom", 1, true), "the error is logged")
	-- the token bucket: a burst of 10, then "Slow down."
	local spammer = h.fakePlayer(206, "Spammer")
	local refused = 0
	for _ = 1, 14 do
		local _, m = invoke(spammer, "ResetPositions")
		if m == "Slow down." then
			refused += 1
		end
	end
	h.expect(refused >= 3 and refused <= 4, "rate limit refused " .. refused .. " of 14")
	-- ...but Leave always gets through, so a player who mashed a hotkey can still get out
	for _ = 1, 5 do
		local _, m = invoke(spammer, "Leave")
		h.expect(m == "You're not in the training room.", "Leave was rate limited: " .. tostring(m))
	end
end)

print("Training panel helpers")

h.test("weapon choices and free hotkeys", function()
	local kestrel = FrameData.weaponOptions("Kestrel")
	h.expect(#kestrel == 3 and kestrel[1] == "Unarmed" and kestrel[2] == "Sword" and kestrel[3] == "Bow", "Kestrel")
	h.expect(#FrameData.weaponOptions("Avatar") == 1 + #Weapons.Order, "Avatar holds every weapon")
	h.expect(FrameData.subtitle("Sword", Legends.getAttack("Avatar", "Sword", "SLight")) == "SWORD · GROUND", "sub")
	h.expect(FrameData.subtitle("Unarmed", Legends.getAttack("Avatar", "Unarmed", "NAir")) == "FISTS · AIR", "air")
	local defaults = FrameData.hotkeys(function(device, action)
		return Config.DefaultKeybinds[device][action] or {}
	end)
	h.expect(
		defaults.Keyboard.Reset == "R" and defaults.Keyboard.Spawn == "V" and defaults.Keyboard.Panel == "Tab",
		"kb"
	)
	h.expect(defaults.Gamepad.Reset == "ButtonR3" and defaults.Gamepad.Spawn == "ButtonL3", "gamepad")
	local rebound = FrameData.hotkeys(function(device, action)
		if device == "Keyboard" and action == "Throw" then
			return { "V" }
		end
		return Config.DefaultKeybinds[device][action] or {}
	end)
	h.expect(rebound.Keyboard.Spawn == nil and rebound.Keyboard.Reset == "R", "a key bound to a fight action is off")
end)

h.test("the panel's Up / Down order never skips a row", function()
	-- the training panel's controls as TrainingHUD lays them out (fractions of the row's width)
	local function whole(id)
		return { { id = id, x = 0, w = 1 } }
	end
	local speeds, spawns = {}, {}
	for i = 1, 3 do
		table.insert(speeds, { id = "Speed" .. i, x = 0.3 + (i - 1) * 0.236, w = 0.223 })
	end
	for i = 1, 6 do
		table.insert(spawns, { id = "Spawn" .. i, x = (i - 1) / 6, w = 1 / 6 - 0.015 })
	end
	local rows = {
		whole("Legend"),
		whole("Weapon"),
		whole("DummyLegend"),
		{
			{ id = "Stand", x = 0, w = 0.32 },
			{ id = "Jump", x = 0.34, w = 0.32 },
			{ id = "Dodge", x = 0.68, w = 0.32 },
		},
		{ { id = "Block", x = 0, w = 0.32 }, { id = "Fight", x = 0.34, w = 0.64 } },
		whole("BotLevel"),
		{ { id = "Damage", x = 0, w = 0.66 } }, -- (its Left / Right step the value: RESET is the next stop down)
		{ { id = "ResetDamage", x = 0.68, w = 0.32 } },
		whole("Keep"),
		whole("Hitboxes"),
		whole("FrameData"),
		whole("Combo"),
		speeds,
		spawns,
		{ { id = "ResetPositions", x = 0, w = 0.49 }, { id = "Leave", x = 0.51, w = 0.49 } },
	}
	local links = FrameData.panelLinks(rows)
	local function go(id, dir)
		return links[id][dir]
	end
	-- Down from the top visits every row in order, then stays on the last
	local walk, id = { "Legend" }, "Legend"
	while go(id, "Down") ~= id do
		id = go(id, "Down")
		table.insert(walk, id)
	end
	local expected = "Legend Weapon DummyLegend Jump Fight BotLevel Damage ResetDamage Keep Hitboxes FrameData Combo "
		.. "Speed1 Spawn3 ResetPositions"
	h.expect(table.concat(walk, " ") == expected, "Down walk: " .. table.concat(walk, " "))
	-- the reviewer's skips
	for _, case in
		{
			{ "Block", "Down", "BotLevel" },
			{ "Stand", "Down", "Block" },
			{ "Block", "Up", "Stand" },
			{ "Fight", "Up", "Jump" },
			{ "Fight", "Down", "BotLevel" },
			{ "Dodge", "Down", "Fight" },
			{ "Jump", "Down", "Fight" },
			{ "BotLevel", "Up", "Fight" },
			{ "Damage", "Down", "ResetDamage" },
			{ "ResetDamage", "Down", "Keep" },
			{ "Keep", "Up", "ResetDamage" },
			{ "ResetDamage", "Up", "Damage" },
			{ "Stand", "Up", "DummyLegend" },
			{ "Dodge", "Up", "DummyLegend" },
			{ "Speed1", "Up", "Combo" },
			{ "Spawn1", "Up", "Speed1" },
			{ "Spawn6", "Down", "Leave" },
			{ "Spawn2", "Down", "ResetPositions" },
			{ "Leave", "Up", "Spawn5" },
			{ "Jump", "Left", "Stand" },
			{ "Dodge", "Right", "Dodge" },
			{ "Hitboxes", "Right", "Hitboxes" },
			{ "Legend", "Up", "Legend" },
		}
	do
		h.expect(go(case[1], case[2]) == case[3], case[1] .. " " .. case[2] .. " -> " .. tostring(go(case[1], case[2])))
	end
	-- every control can be reached from the default focus
	local seen, queue, count = { Legend = true }, { "Legend" }, 0
	while #queue > 0 do
		local current = table.remove(queue, 1)
		count += 1
		for _, dir in { "Up", "Down", "Left", "Right" } do
			local nextId = go(current, dir)
			if not seen[nextId] then
				seen[nextId] = true
				table.insert(queue, nextId)
			end
		end
	end
	local total = 0
	for _ in links do
		total += 1
	end
	h.expect(count == total, string.format("%d of %d controls reachable", count, total))
	h.expect(FrameData.MODE_LABELS.Fight == "FIGHT BACK", "mode labels")
end)

h.finish()
