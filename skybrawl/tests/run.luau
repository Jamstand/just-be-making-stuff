--[[
    Simulation tests for the shared gameplay code. Run from the skybrawl
    folder with:  lune run tests/run
]]

local h = require("./harness")

local Config = h.require("Config")
local Weapons = h.require("Weapons")
local Maps = h.require("Maps")
local FighterSim = h.require("FighterSim")
local Combat = h.require("Combat")
local Ranks = h.require("Ranks")
local Legends = h.require("Legends")

local P = Config.Physics
local DT = 1 / 60

local function newInput()
	return {
		moveX = 0,
		moveY = 0,
		jumpHeld = false,
		heavyHeld = false,
		buffer = { Jump = 0, Light = 0, Heavy = 0, Dodge = 0, Throw = 0 },
	}
end

local function ctx(mapId, weapon, legend)
	return {
		world = Maps.getWorld(mapId or "SkyholdKeep"),
		weapon = weapon or "Unarmed",
		legend = legend or "Avatar",
		armed = weapon ~= nil,
		nearPickup = false,
	}
end

local function run(s, input, seconds, c, onStep)
	local events = {}
	local steps = math.floor(seconds / DT + 0.5)
	for i = 1, steps do
		for k, v in input.buffer do
			input.buffer[k] = math.max(0, v - DT)
		end
		FighterSim.step(s, input, DT, c, events)
		if onStep then
			onStep(s, i)
		end
	end
	return events
end

local function press(input, action)
	input.buffer[action] = Config.InputBufferTime
end

print("Weapons")

h.test("every weapon has all 14 attacks with sane numbers", function()
	for id, weapon in Weapons.List do
		for _, slot in Weapons.Slots do
			local move = weapon.Moves[slot]
			h.expect(move, id .. " missing " .. slot)
			h.expect(move.Startup > 0 and move.Active > 0 and move.Recovery > 0, id .. "." .. slot .. " timing")
			h.expect(move.Damage > 0 and move.Damage < 40, id .. "." .. slot .. " damage")
			h.expect(move.Hitbox or move.Projectile, id .. "." .. slot .. " needs a hitbox or projectile")
			if move.Hitbox then
				h.expect(move.Hitbox.W > 0 and move.Hitbox.H > 0, id .. "." .. slot .. " hitbox size")
			end
		end
	end
end)

h.test("heavies hit harder than lights for every weapon", function()
	for id, weapon in Weapons.List do
		h.expect(weapon.Moves.SHeavy.KnockbackScaling > weapon.Moves.SLight.KnockbackScaling, id)
	end
end)

print("Movement")

h.test("standing still stays on the stage", function()
	local s = FighterSim.newState(0, 0, 1)
	run(s, newInput(), 1, ctx())
	h.expect(s.grounded, "should be grounded")
	h.near(s.y, 0, 0.001, "y")
	h.near(s.x, 0, 0.001, "x")
end)

h.test("running reaches run speed", function()
	local s = FighterSim.newState(-20, 0, 1)
	local input = newInput()
	input.moveX = 1
	run(s, input, 0.5, ctx())
	h.near(s.vx, P.RunSpeed * Legends.speedMult("Avatar"), 0.01, "vx")
	h.expect(s.facing == 1)
end)

local function grounded(x, y, facing)
	local s = FighterSim.newState(x, y, facing or 1)
	run(s, newInput(), 2 * DT, ctx())
	return s
end

h.test("jump height is about v^2 / 2g and three jumps reach the top platform", function()
	local s = grounded(0, 0)
	local input = newInput()
	input.jumpHeld = true
	press(input, "Jump")
	local peak = 0
	run(s, input, 1.2, ctx(), function(state)
		peak = math.max(peak, state.y)
	end)
	h.near(peak, P.JumpVelocity ^ 2 / (2 * P.Gravity), 0.6, "single jump peak")

	-- ground + 2 air jumps
	s = grounded(0, 0)
	input = newInput()
	input.jumpHeld = true
	peak = 0
	press(input, "Jump")
	run(s, input, 0.35, ctx(), function(state)
		peak = math.max(peak, state.y)
	end)
	press(input, "Jump")
	run(s, input, 0.35, ctx(), function(state)
		peak = math.max(peak, state.y)
	end)
	press(input, "Jump")
	run(s, input, 0.5, ctx(), function(state)
		peak = math.max(peak, state.y)
	end)
	h.expect(peak > 25, "triple jump should clear the top platform (y=25), got " .. peak)
end)

h.test("short hop is lower than a full jump", function()
	local s = grounded(0, 0)
	local input = newInput()
	press(input, "Jump")
	input.jumpHeld = false
	local peak = 0
	run(s, input, 1, ctx(), function(state)
		peak = math.max(peak, state.y)
	end)
	h.expect(peak < P.JumpVelocity ^ 2 / (2 * P.Gravity) * 0.6, "short hop peak " .. peak)
end)

h.test("can jump up through a soft platform and land on it", function()
	-- Under the left soft platform on Skyhold Keep (x -27..-13, top y 14)
	local s = FighterSim.newState(-20, 0, 1)
	local input = newInput()
	input.jumpHeld = true
	press(input, "Jump")
	run(s, input, 0.3, ctx())
	press(input, "Jump")
	run(s, input, 1.5, ctx())
	h.expect(s.grounded and s.onSoft, "should be standing on the soft platform")
	h.near(s.y, 14, 0.01, "y")
end)

h.test("tapping down drops through a soft platform", function()
	local s = FighterSim.newState(-20, 14, 1)
	local input = newInput()
	run(s, input, 0.2, ctx())
	h.expect(s.onSoft)
	input.moveY = -1
	run(s, input, 0.1, ctx())
	input.moveY = 0
	run(s, input, 1.5, ctx())
	h.near(s.y, 0, 0.01, "should land on the main stage")
end)

h.test("walking off the edge falls, and the wall stops you from walking back in", function()
	local s = grounded(33, 0)
	local input = newInput()
	input.moveX = 1
	run(s, input, 0.5, ctx())
	h.expect(not s.grounded and s.y < 0, "should be falling")

	s = FighterSim.newState(41, -4, -1)
	input.moveX = -1
	run(s, input, 0.3, ctx())
	h.expect(s.x >= 36 + P.FighterWidth / 2 - 0.001, "should not pass into the stage wall, x=" .. s.x)
	h.expect(s.wallTouch == -1, "should be touching the wall")
end)

h.test("wall cling slows the fall and wall jump pushes away", function()
	local s = FighterSim.newState(36 + P.FighterWidth / 2, -4, -1)
	local input = newInput()
	input.moveX = -1
	run(s, input, 0.5, ctx())
	h.expect(s.wallSide == -1, "should be clinging")
	h.expect(s.vy >= -P.WallSlideSpeed - 0.5, "slow slide, vy=" .. s.vy)
	press(input, "Jump")
	run(s, input, 1 / 60, ctx())
	h.expect(s.vx > 0 and s.vy > 0, "wall jump should push right and up")
end)

h.test("off-stage recovery with jumps + recovery attack gets back on stage", function()
	local s = FighterSim.newState(55, -6, -1)
	s.airJumps = P.MaxAirJumps
	local input = newInput()
	input.moveX = -1
	input.jumpHeld = true
	local c = ctx("SkyholdKeep", "Sword")
	for _ = 1, P.MaxAirJumps do
		press(input, "Jump")
		run(s, input, 0.35, c)
	end
	input.moveY = 1
	press(input, "Heavy")
	run(s, input, 0.1, c)
	input.moveY = 0
	run(s, input, 2, c)
	h.expect(s.grounded and s.x < 36, string.format("should be back on stage, at (%.1f, %.1f)", s.x, s.y))
end)

h.test("fast fall falls faster", function()
	local normal = FighterSim.newState(31, 60, 1)
	run(normal, newInput(), 0.4, ctx())
	local fast = FighterSim.newState(31, 60, 1)
	local input = newInput()
	input.moveY = -1
	run(fast, input, 0.4, ctx())
	h.expect(fast.y < normal.y - 3, "fast fall should be lower")
end)

h.test("spot dodge gives invulnerability, dash moves you", function()
	local s = FighterSim.newState(0, 0, 1)
	local input = newInput()
	run(s, input, 0.05, ctx())
	press(input, "Dodge")
	run(s, input, 1 / 60, ctx())
	h.expect(FighterSim.isInvulnerable(s), "spot dodge should be invulnerable")
	run(s, input, 1.2, ctx())
	input.moveX = 1
	press(input, "Dodge")
	local events = run(s, input, 0.1, ctx())
	local dashed = false
	for _, ev in events do
		if ev.type == "Dodge" and ev.kind == "Dash" then
			dashed = true
		end
	end
	h.expect(dashed and s.vx > P.RunSpeed, "should dash")
end)

h.test("attack hitbox is only active during the active window", function()
	local s = FighterSim.newState(0, 0, 1)
	local input = newInput()
	run(s, input, 0.05, ctx())
	input.moveY = -1
	press(input, "Light")
	local move = Weapons.getAttack("Sword", "DLight")
	local activeFrames = 0
	local firstActive = nil
	run(s, input, 0.6, ctx("SkyholdKeep", "Sword"), function(state, i)
		if FighterSim.activeHitbox(state) then
			activeFrames += 1
			firstActive = firstActive or i
		end
	end)
	h.expect(activeFrames > 0, "should have active frames")
	h.near(firstActive * DT, move.Startup, 2 * DT, "startup")
	h.near(activeFrames * DT, move.Active, 2 * DT, "active length")
	h.expect(s.action == nil, "attack should have finished")
end)

h.test("side light faces the pressed direction and lunges", function()
	local s = FighterSim.newState(0, 0, 1)
	local input = newInput()
	run(s, input, 0.05, ctx())
	input.moveX = -1
	press(input, "Light")
	run(s, input, 0.2, ctx("SkyholdKeep", "Sword"))
	h.expect(s.facing == -1, "should face left")
	h.expect(s.x < -2, "should lunge left, x=" .. s.x)
end)

h.test("held heavy charges and reports a charge fraction", function()
	local s = FighterSim.newState(0, 0, 1)
	local input = newInput()
	run(s, input, 0.05, ctx())
	press(input, "Heavy")
	input.heavyHeld = true
	run(s, input, 0.4, ctx("SkyholdKeep", "Hammer"))
	input.heavyHeld = false
	local events = run(s, input, 0.1, ctx("SkyholdKeep", "Hammer"))
	local release
	for _, ev in events do
		if ev.type == "Release" then
			release = ev
		end
	end
	h.expect(release and release.charge > 0.4, "should report a decent charge")
end)

h.test("ground pound ends on landing", function()
	local s = FighterSim.newState(0, 20, 1)
	local input = newInput()
	run(s, input, 0.05, ctx())
	input.moveY = -1
	press(input, "Heavy")
	local landed = false
	run(s, input, 1, ctx("SkyholdKeep", "Sword"), function(state)
		if state.grounded then
			landed = true
		end
	end)
	h.expect(landed, "should land")
	h.expect(s.action == nil, "should be done after recovery")
end)

h.test("bow light attacks fire projectiles", function()
	local s = FighterSim.newState(0, 0, 1)
	local input = newInput()
	run(s, input, 0.05, ctx())
	input.moveX = 1
	press(input, "Light")
	local events = run(s, input, 0.4, ctx("SkyholdKeep", "Bow"))
	local fired = false
	for _, ev in events do
		if ev.type == "Fire" then
			fired = true
		end
	end
	h.expect(fired, "should fire")
end)

print("Battlegrounds combat")

local B = Config.Battle

local function slotsOf(events)
	local out = {}
	for _, ev in events do
		if ev.type == "Attack" then
			table.insert(out, ev.slot)
		end
	end
	return table.concat(out, " ")
end

-- Presses light every time the current attack's active frames end.
h.test("neutral light runs the punch chain: three quick hits, then the launcher", function()
	for _, weapon in { "Unarmed", "Sword", "Hammer", "Spear" } do
		local s = FighterSim.newState(0, 0, 1)
		local input = newInput()
		local c = ctx("SkyholdKeep", weapon)
		run(s, input, 0.05, c)
		local events = {}
		for _ = 1, 60 do
			local m = s.move
			if s.action == nil or (s.action == "Attack" and m and s.actionTime >= m.Startup + m.Active) then
				press(input, "Light")
			end
			for _, ev in run(s, input, DT, c) do
				table.insert(events, ev)
			end
		end
		h.expect(
			string.find(slotsOf(events), "Chain1 Chain2 Chain3 NLight", 1, true) == 1,
			weapon .. ": " .. slotsOf(events)
		)
		local launcher = Weapons.getAttack(weapon, "NLight")
		h.expect(launcher.Chain == 4 and launcher.Angle >= 50, weapon .. " finisher should launch")
	end
end)

h.test("the chain starts over after a pause, and direction picks the other lights", function()
	local s = FighterSim.newState(0, 0, 1)
	local input = newInput()
	local c = ctx("SkyholdKeep", "Sword")
	run(s, input, 0.05, c)
	press(input, "Light")
	local events = run(s, input, 0.3, c)
	run(s, input, B.ChainWindow + 0.2, c)
	press(input, "Light")
	for _, ev in run(s, input, 0.3, c) do
		table.insert(events, ev)
	end
	input.moveY = -1
	press(input, "Light")
	for _, ev in run(s, input, 0.5, c) do
		table.insert(events, ev)
	end
	h.expect(slotsOf(events) == "Chain1 Chain1 DLight", slotsOf(events))
end)

h.test("holding block blocks on the ground, stops attacks, and a dodge breaks out", function()
	local s = FighterSim.newState(0, 0, 1)
	local input = newInput()
	local c = ctx()
	run(s, input, 0.05, c)
	input.blockHeld = true
	local events = run(s, input, 0.1, c)
	h.expect(s.action == "Block", "should block, got " .. tostring(s.action))
	h.expect(events[1] and events[1].type == "Block" and events[1].on, "should report blocking")
	press(input, "Light")
	run(s, input, 0.2, c)
	h.expect(s.action == "Block", "attacks wait while blocking")
	FighterSim.applyBlock(s, -B.BlockPushback, B.BlockStun, 0.05)
	run(s, input, 0.1, c)
	h.expect(s.action == "Block" and s.x < -0.3, "a blocked hit pushes back but keeps the block")
	press(input, "Dodge")
	run(s, input, 0.05, c)
	h.expect(s.action == "Block", "no dodging out during block stun")
	run(s, input, B.BlockStun, c)
	press(input, "Dodge")
	run(s, input, 0.05, c)
	h.expect(s.action == "Dodge", "a dodge breaks out of block, got " .. tostring(s.action))
	input.blockHeld = false
	run(s, input, 0.6, c)
	h.expect(s.action == nil, "free again")
end)

h.test("a guard break stuns, then lets go", function()
	local s = FighterSim.newState(0, 0, 1)
	local input = newInput()
	local c = ctx()
	run(s, input, 0.05, c)
	input.blockHeld = true
	run(s, input, 0.1, c)
	FighterSim.applyGuardBreak(s, B.GuardBreakStun)
	input.blockHeld = false
	press(input, "Light")
	run(s, input, B.GuardBreakStun - 0.1, c)
	h.expect(s.action == "Stunned", "stunned, got " .. tostring(s.action))
	run(s, input, 0.2, c)
	h.expect(s.action == nil, "the stun wears off")
end)

h.test("a tumbling launch knocks you down on landing; dodge just before landing techs", function()
	for _, tech in { false, true } do
		local s = FighterSim.newState(0, 0, 1)
		local input = newInput()
		local c = ctx()
		run(s, input, 0.05, c)
		FighterSim.applyHit(s, 6, 40, 0.9, 0, true)
		local events = {}
		for _ = 1, 120 do
			if tech and s.vy < 0 and s.y < 3 and not s.grounded then
				press(input, "Dodge")
			end
			for _, ev in run(s, input, DT, c) do
				table.insert(events, ev)
			end
			if s.action == "Knockdown" or s.action == "TechRoll" then
				break
			end
		end
		if tech then
			h.expect(s.action == "TechRoll", "should tech, got " .. tostring(s.action))
			h.expect(FighterSim.isInvulnerable(s), "invulnerable while teching")
		else
			h.expect(s.action == "Knockdown", "should be knocked down, got " .. tostring(s.action))
			h.expect(FighterSim.isInvulnerable(s), "invulnerable while down")
			run(s, input, B.KnockdownTime + B.GetUpTime + 0.1, c)
			h.expect(s.action == nil, "gets back up, got " .. tostring(s.action))
		end
	end
end)

h.test("a weak hit doesn't knock down; a ragdoll stays limp over the stage until it lands or jumps out", function()
	local s = FighterSim.newState(0, 0, 1)
	local input = newInput()
	local c = ctx()
	run(s, input, 0.05, c)
	FighterSim.applyHit(s, 4, 30, 0.3, 0, false)
	run(s, input, 1.5, c)
	h.expect(s.action == nil and s.grounded, "lands on its feet")

	-- over the stage: limp past the hitstun, then down on landing
	FighterSim.applyHit(s, 4, 60, 0.2, 0, true)
	run(s, input, 0.3, c)
	h.expect(s.action == "Hitstun" and s.tumble and not s.grounded, "still limp after the hitstun")
	h.expect(FighterSim.animState(s) == "Tumble", "shows the tumble")
	for _ = 1, 120 do
		run(s, input, DT, c)
		if s.action ~= "Hitstun" then
			break
		end
	end
	h.expect(s.action == "Knockdown", "knocked down on landing, got " .. tostring(s.action))
	run(s, input, B.KnockdownTime + B.GetUpTime + 0.1, c)

	-- jumping breaks out of it
	FighterSim.applyHit(s, 4, 60, 0.2, 0, true)
	run(s, input, 0.3, c)
	input.buffer.Jump = Config.InputBufferTime
	run(s, input, 2 * DT, c)
	h.expect(s.action ~= "Hitstun" and not s.tumble, "jumped out of the ragdoll")
	run(s, input, 1.5, c)
	h.expect(s.action == nil and s.grounded, "lands on its feet after jumping out")

	-- off the stage: control comes back to recover
	local off = FighterSim.newState(5000, 40, 1)
	FighterSim.applyHit(off, 4, 30, 0.2, 0, true)
	run(off, input, 0.3, c)
	h.expect(off.action == nil and not off.tumble, "recovers off the stage, got " .. tostring(off.action))
end)

h.test("the ultimate button awakens, then uses the legend's ultimate once awake", function()
	local s = FighterSim.newState(0, 0, 1)
	local input = newInput()
	local c = ctx("SkyholdKeep", "Sword", "Sol")
	run(s, input, 0.05, c)
	press(input, "Ultimate")
	h.expect(slotsOf(run(s, input, 0.1, c)) == "", "nothing without a full meter")
	c.ultimate = "Awaken"
	press(input, "Ultimate")
	local asked = false
	for _, ev in run(s, input, 0.1, c) do
		asked = asked or ev.type == "Awaken"
	end
	h.expect(asked, "a full meter asks to awaken")
	FighterSim.awaken(s, B.AwakenFreeze)
	h.expect(s.action == "Awakening" and FighterSim.isInvulnerable(s), "awakening pose")
	run(s, input, B.AwakenFreeze + 0.05, c)
	c.ultimate = "Attack"
	c.awakened = true
	press(input, "Ultimate")
	local events = run(s, input, 0.05, c)
	h.expect(slotsOf(events) == "Ultimate", "ultimate move: " .. slotsOf(events))
	local move = Legends.getAttack("Sol", "Sword", "Ultimate")
	h.expect(move.Unblockable and move.Ultimate and move.Signature == "Zenith Smash", "Sol's ultimate")
	for _, id in Legends.Order do
		local u = Legends.getAttack(id, "Unarmed", "Ultimate")
		h.expect(u and u.Hitbox and u.Damage >= 20, id .. " needs an ultimate")
	end
end)

h.test("awakened fighters run faster", function()
	local speeds = {}
	for _, awake in { false, true } do
		local s = FighterSim.newState(0, 0, 1)
		local input = newInput()
		local c = ctx()
		c.awakened = awake
		input.moveX = 1
		run(s, input, 0.6, c)
		table.insert(speeds, s.vx)
	end
	h.near(speeds[2] / speeds[1], B.AwakenSpeedMult, 0.01, "awakened speed")
end)

print("Knockback / KOs")

-- A defender that tries to survive: drifts back toward the stage, uses its
-- jumps when falling below the stage, then its recovery attack.
local function survivor(s, input)
	input.moveY = 0
	if s.grounded then
		input.moveX = 0
		return
	end
	input.moveX = s.x > 0 and -1 or 1
	input.jumpHeld = true
	if s.action == nil and s.vy < 0 and s.y < 4 then
		if s.airJumps > 0 then
			press(input, "Jump")
		elseif not s.recoveryUsed then
			input.moveY = 1
			press(input, "Heavy")
		end
	end
end

-- Lowest damage % at which `move` KOs a defender at stage center, or nil
-- if it never does below 300%.
local function koPercent(weaponId, slot, mapId)
	local move = Weapons.getAttack(weaponId, slot)
	local world = Maps.getWorld(mapId or "SkyholdKeep")
	local c = { world = world, weapon = "Unarmed", armed = false, nearPickup = false }
	for damage = 0, 300, 5 do
		local s = FighterSim.newState(0, 0, -1)
		local kbx, kby, force = Combat.knockback(move, damage, 0, 1, 1)
		FighterSim.applyHit(s, kbx, kby, Combat.hitstun(force))
		local input = newInput()
		local ko = false
		for _ = 1, 60 * 5 do
			for k, v in input.buffer do
				input.buffer[k] = math.max(0, v - DT)
			end
			if s.action ~= "Hitstun" then
				survivor(s, input)
			end
			FighterSim.step(s, input, DT, c)
			if Maps.isOutOfBounds(world, s.x, s.y) then
				ko = true
				break
			end
			if s.grounded and s.action == nil and math.abs(s.x) < 34 then
				break
			end
		end
		if ko then
			return damage
		end
	end
	return nil
end

h.test("lights never KO from center below 300%", function()
	for id in Weapons.List do
		local p = koPercent(id, "SLight")
		h.expect(p == nil, id .. " side light KOs at " .. tostring(p))
	end
end)

local report = {}
h.test("side heavies KO from center somewhere between 90% and 260%", function()
	for id in Weapons.List do
		local p = koPercent(id, "SHeavy")
		report[id] = p
		h.expect(p ~= nil and p >= 90 and p <= 260, id .. " side heavy KOs at " .. tostring(p))
	end
end)
for id, p in report do
	print(string.format("       %-9s side heavy KOs at %s%%", id, tostring(p)))
end

h.test("hammer KOs earlier than unarmed", function()
	local hammer, fists = koPercent("Hammer", "SHeavy"), koPercent("Unarmed", "SHeavy")
	h.expect(
		hammer and fists and hammer < fists,
		string.format("hammer %s vs fists %s", tostring(hammer), tostring(fists))
	)
end)

print("Ranks")

h.test("Elo is symmetric-ish and favors upsets", function()
	local winUp = Ranks.newRating(1000, 1400, 1, 20) - 1000
	local winDown = Ranks.newRating(1400, 1000, 1, 20) - 1400
	h.expect(winUp > winDown, "beating a stronger player should be worth more")
	local loss = Ranks.newRating(1000, 1000, 0, 20) - 1000
	h.expect(loss == -12, "even loss at K=24 is -12, got " .. loss)
	h.expect(Ranks.newRating(1000, 1000, 1, 0) - 1000 == 20, "placement K=40")
end)

h.test("tiers and levels", function()
	h.expect(Ranks.tier(1000).Name == "Bronze")
	h.expect(Ranks.tier(2100).Name == "Diamond")
	h.expect(Ranks.tier(100).Name == "Tin")
	local level, into, need = Ranks.levelFromXP(0)
	h.expect(level == 1 and into == 0 and need == Config.Levels.BaseXP)
	level = Ranks.levelFromXP(Config.Levels.BaseXP + 5)
	h.expect(level == 2)
end)

print("Maps")

h.test("every map has 4 spawns standing on solid ground inside the camera", function()
	for id, map in Maps.List do
		local world = Maps.getWorld(id)
		h.expect(#map.Spawns >= 4, id .. " spawns")
		for _, spawn in map.Spawns do
			local ground = Maps.groundBelow(world, spawn[1], spawn[2])
			h.expect(ground and math.abs(ground - spawn[2]) < 0.01, id .. " spawn not on ground")
		end
		for _, spot in map.Respawns do
			h.expect(not Maps.isOutOfBounds(world, spot[1], spot[2]), id .. " respawn out of bounds")
		end
		local cam, blast = world.camera, world.blast
		h.expect(
			cam.minX > blast.minX and cam.maxX < blast.maxX and cam.minY > blast.minY and cam.maxY < blast.maxY,
			id .. " camera inside blast zone"
		)
	end
end)

h.test("weapon spawns drop onto a platform", function()
	for id, map in Maps.List do
		local world = Maps.getWorld(id)
		for _, spot in map.WeaponSpawns do
			h.expect(
				Maps.groundBelow(world, spot[1], spot[2]) ~= nil,
				id .. " weapon spawn over the void at x=" .. spot[1]
			)
		end
	end
end)

print("Settings")

h.test("saved settings keep FightAsAvatar only as a boolean", function()
	local DataService = h.requireServer("DataService")
	h.expect(Config.DefaultSettings.FightAsAvatar == false, "FightAsAvatar should default to off")
	h.expect(DataService.sanitizeSettings({ FightAsAvatar = true }).FightAsAvatar == true, "kept true")
	h.expect(DataService.sanitizeSettings({ FightAsAvatar = false }).FightAsAvatar == false, "kept false")
	for _, junk in { "yes", 1, {} } do
		h.expect(DataService.sanitizeSettings({ FightAsAvatar = junk }).FightAsAvatar == nil, "kept a " .. type(junk))
	end
	h.expect(DataService.sanitizeSettings({}).FightAsAvatar == nil, "invented a value")
end)

h.test("a rate-limited settings save still updates FightAsAvatar", function()
	local DataService = h.requireServer("DataService")
	local settings = { FightAsAvatar = false, Zoom = 1 }
	DataService.applyMatchSettings(settings, { FightAsAvatar = true, Zoom = 3 })
	h.expect(settings.FightAsAvatar == true, "the dropped save's FightAsAvatar was lost")
	h.expect(settings.Zoom == 1, "a dropped save changed a setting a match doesn't read")
	DataService.applyMatchSettings(settings, { FightAsAvatar = "no" })
	h.expect(settings.FightAsAvatar == true, "took a non-boolean FightAsAvatar")
	DataService.applyMatchSettings(settings, "junk")
	h.expect(settings.FightAsAvatar == true, "a junk payload changed the settings")
end)

h.finish()
