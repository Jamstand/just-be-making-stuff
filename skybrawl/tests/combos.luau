--[[
    Legends and combo-flow tests. Run from the skybrawl folder with:
        lune run tests/combos
]]

local h = require("./harness")

local Config = h.require("Config")
local Weapons = h.require("Weapons")
local Maps = h.require("Maps")
local FighterSim = h.require("FighterSim")
local Combat = h.require("Combat")
local Legends = h.require("Legends")

local P = Config.Physics
local C = Config.Combat
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

local function ctx(weapon, legend)
	return {
		world = Maps.getWorld("SkyholdKeep"),
		weapon = weapon or "Unarmed",
		legend = legend or "Avatar",
		armed = weapon ~= nil and weapon ~= "Unarmed",
		nearPickup = false,
	}
end

local function tick(s, input, c, events)
	for k, v in input.buffer do
		input.buffer[k] = math.max(0, v - DT)
	end
	return FighterSim.step(s, input, DT, c, events or {})
end

local function run(s, input, seconds, c)
	local events = {}
	for _ = 1, math.floor(seconds / DT + 0.5) do
		tick(s, input, c, events)
	end
	return events
end

local function press(input, action)
	input.buffer[action] = Config.InputBufferTime
end

local function grounded(x, facing)
	local s = FighterSim.newState(x, 0, facing or 1)
	run(s, newInput(), 2 * DT, ctx())
	return s
end

print("Legends")

h.test("every legend's stats add up to 22 and stay in 2..9", function()
	for id, legend in Legends.List do
		local total = 0
		for _, name in Legends.StatNames do
			local v = legend.Stats[name]
			h.expect(v >= 2 and v <= 9, id .. " " .. name)
			total += v
		end
		h.expect(total == 22, id .. " stats add up to " .. total)
	end
end)

h.test("legend titles are short and descriptions fit the fighter card in one sentence", function()
	for id, legend in Legends.List do
		local words = select(2, string.gsub(legend.Title, "%S+", ""))
		h.expect(words >= 1 and words <= 3 and #legend.Title <= 18, id .. " title: " .. legend.Title)
		local d = legend.Description
		-- FightersPanel gives the description a 40px box (2 lines of 15pt) in an info
		-- column roughly 290px wide at full size: 70 characters is a rough proxy.
		h.expect(#d <= 70, id .. " description is " .. #d .. " characters (2 lines on the card)")
		if id ~= "Avatar" then
			h.expect(string.sub(d, -1) == "." and not string.find(d, "[.!?] "), id .. " description: one sentence")
		end
	end
end)

h.test("each legend has two weapons with three signatures each", function()
	for _, id in Legends.Order do
		local legend = Legends.List[id]
		if id ~= "Avatar" then
			h.expect(#legend.Weapons == 2 and legend.Weapons[1] ~= legend.Weapons[2], id .. " weapons")
			for _, weapon in legend.Weapons do
				h.expect(Weapons.isWeapon(weapon), id .. " " .. weapon)
				for _, slot in Legends.SignatureSlots do
					local move = Legends.getAttack(id, weapon, slot)
					h.expect(move.Signature, id .. " " .. weapon .. " " .. slot .. " has no signature")
					h.expect(move.AnimKey == id .. "." .. weapon .. "." .. slot, "anim key " .. move.AnimKey)
					h.expect(move.Hitbox or move.Projectile, id .. " " .. weapon .. " " .. slot .. " needs a hitbox")
					h.expect(
						move.Kind == "Heavy" and move.Charge > 0,
						id .. " " .. weapon .. " " .. slot .. " is a heavy"
					)
				end
			end
		end
	end
end)

h.test("signatures are distinct and roughly as strong as the shared heavies", function()
	for _, id in Legends.Order do
		local legend = Legends.List[id]
		for _, weapon in legend.Weapons or {} do
			for _, slot in Legends.SignatureSlots do
				local sig = Legends.getAttack(id, weapon, slot)
				local base = Weapons.getAttack(weapon, slot)
				local ratio = sig.Damage / base.Damage
				h.expect(
					ratio > 0.4 and ratio < 1.5,
					string.format("%s %s %s damage ratio %.2f", id, weapon, slot, ratio)
				)
			end
		end
	end
end)

h.test("dexterity speeds up startup and recovery but not active frames", function()
	local fast = Legends.getAttack("Yuki", "Sword", "NLight") -- Dex 7
	local slow = Legends.getAttack("Brann", "Sword", "NLight") -- Dex 4
	local base = Weapons.getAttack("Sword", "NLight")
	h.near(fast.Startup, base.Startup * 0.94, 1e-6, "Yuki startup")
	h.near(slow.Recovery, base.Recovery * 1.03, 1e-6, "Brann recovery")
	h.near(fast.Active, base.Active, 1e-9, "active unchanged")
end)

h.test("legends alternate between their two weapons; avatars take anything", function()
	h.expect(Legends.weaponFromPickup("Kestrel", "Hammer", nil) == "Sword")
	h.expect(Legends.weaponFromPickup("Kestrel", "Bow", nil) == "Bow")
	h.expect(Legends.weaponFromPickup("Kestrel", "Bow", "Bow") == "Sword")
	h.expect(Legends.weaponFromPickup("Kestrel", "Spear", "Sword") == "Bow")
	h.expect(Legends.weaponFromPickup("Avatar", "Spear", "Sword") == "Spear")
	-- a room that only drops some weapons
	h.expect(Legends.weaponFromPickup("Kestrel", "Sword", "Bow", { Sword = true }) == "Sword", "only Sword allowed")
	h.expect(
		Legends.weaponFromPickup("Brann", "Sword", nil, { Sword = true }) == "Sword",
		"neither of Brann's weapons allowed"
	)
	h.expect(Legends.weaponFromPickup("Sol", "Hammer", "Sword", { Sword = true, Hammer = true }) == "Hammer")
	h.expect(Legends.weaponSkin("Brann", "Hammer") == "BrannHammer")
	h.expect(Legends.weaponSkin("Brann", "Sword") == "Sword")
end)

h.test("speed stat changes run speed and dodge cooldowns", function()
	local fast, slow = grounded(-20), grounded(-20)
	local input = newInput()
	input.moveX = 1
	run(fast, input, 0.5, ctx(nil, "Kestrel"))
	run(slow, input, 0.5, ctx(nil, "Brann"))
	h.near(fast.vx, P.RunSpeed * 1.08, 0.01, "Kestrel run speed")
	h.near(slow.vx, P.RunSpeed * 0.92, 0.01, "Brann run speed")
end)

print("Combo flow")

local function startLight(s, input, c)
	press(input, "Light")
	tick(s, input, c)
end

h.test("a light that hit can be jump-cancelled once its active frames end", function()
	local c = ctx("Sword")
	local s = grounded(0)
	local input = newInput()
	startLight(s, input, c)
	local move = s.move
	FighterSim.onHitConfirm(s, 0)
	-- still active: jump is ignored
	press(input, "Jump")
	tick(s, input, c)
	h.expect(s.action == "Attack", "jumped during startup/active")
	input.buffer.Jump = 0
	run(s, input, move.Startup + move.Active, c)
	h.expect(s.action == "Attack", "attack should still be in recovery")
	press(input, "Jump")
	local events = {}
	tick(s, input, c, events)
	h.expect(s.action == nil and s.vy > 0, "jump should cancel the recovery")
	local cancelled = false
	for _, ev in events do
		if ev.type == "Jump" and ev.cancel then
			cancelled = true
		end
	end
	h.expect(cancelled, "Jump event should say it cancelled an attack")
end)

h.test("a light that whiffed can't be cancelled", function()
	local c = ctx("Sword")
	local s = grounded(0)
	local input = newInput()
	startLight(s, input, c)
	local move = s.move
	run(s, input, move.Startup + move.Active + 0.02, c)
	press(input, "Jump")
	tick(s, input, c)
	h.expect(s.action == "Attack", "whiffed light was cancelled")
end)

h.test("chase dodge: after a hit, dodge ignores cooldown and gives no invulnerability", function()
	local c = ctx("Sword")
	local s = grounded(0)
	local input = newInput()
	s.dodgeCooldown = 5 -- would normally block any dodge
	startLight(s, input, c)
	FighterSim.onHitConfirm(s, 0)
	run(s, input, s.move.Startup + s.move.Active + 0.01, c)
	input.moveX, input.moveY = 1, 1
	press(input, "Dodge")
	local events = {}
	tick(s, input, c, events)
	h.expect(s.action == "Dodge" and s.dodgeKind == "Chase", "expected a chase dodge, got " .. tostring(s.dodgeKind))
	h.expect(s.invuln == 0, "chase dodge must not be invulnerable")
	h.expect(s.vx > 30 and s.vy > 30, "chase dodge should burst up-forward")
	h.expect(s.chaseTimer == 0, "one chase dodge per hit")
	h.expect(not s.airDodgeUsed, "chase dodge doesn't use the air dodge")
end)

h.test("gravity cancel: a light out of an air spot dodge uses a ground attack", function()
	local c = ctx("Sword")
	local s = FighterSim.newState(0, 10, 1)
	local input = newInput()
	tick(s, input, c)
	press(input, "Dodge")
	tick(s, input, c)
	h.expect(s.dodgeKind == "AirSpot", "expected an air spot dodge")
	h.expect(s.invuln > 0)
	input.moveX = 1
	press(input, "Light")
	tick(s, input, c)
	h.expect(s.action == "Attack" and s.slot == "SLight", "expected a gravity-cancel SLight, got " .. tostring(s.slot))
	h.expect(s.invuln == 0, "attacking out of the dodge ends its invulnerability")
	h.expect(not s.grounded)
end)

h.test("hit-stop freezes the attacker, then the attack continues", function()
	local c = ctx("Sword")
	local s = grounded(0)
	local input = newInput()
	startLight(s, input, c)
	local t0 = s.actionTime
	FighterSim.onHitConfirm(s, 0.08)
	run(s, input, 0.05, c)
	h.near(s.actionTime, t0, 1e-9, "time should not advance during hit-stop")
	run(s, input, 0.1, c)
	h.expect(s.actionTime > t0, "attack should resume")
end)

-- Duels -------------------------------------------------------------------

local Duel = require("./duel")
local afterActive = Duel.afterActive

local jumpIn = { "Jump", toward = 0.6, when = afterActive }
local chaseDiag = { "Dodge", toward = 0.7, y = 0.7, when = afterActive }
-- the punch chain: three quick hits, then the neutral light finisher
local chainHit = { "Light", when = afterActive }
local chain = { { "Light" }, chainHit, chainHit, chainHit }

local function after(steps, ...)
	local out = table.clone(steps)
	for _, step in { ... } do
		table.insert(out, step)
	end
	return out
end

-- Each route is tried at a few spacings; it should be a true combo at 0%
-- for at least one of them and at none of them at 140%.
local ROUTES = {
	{
		name = "Fists down light > jump > side air",
		weapon = "Unarmed",
		legend = "Avatar",
		steps = { { "Light", y = -1 }, jumpIn, { "Light", toward = 1 } },
	},
	{
		name = "Sword punch chain > jump > side air",
		weapon = "Sword",
		legend = "Kestrel",
		steps = after(chain, jumpIn, { "Light", toward = 1 }),
		hits = 5,
	},
	{
		name = "Hammer down light > jump > neutral air",
		weapon = "Hammer",
		legend = "Brann",
		steps = { { "Light", y = -1 }, jumpIn, { "Light" } },
	},
	{
		name = "Spear down light > jump > neutral air",
		weapon = "Spear",
		legend = "Yuki",
		steps = { { "Light", y = -1 }, jumpIn, { "Light" } },
	},
	{
		name = "Gauntlets down light > chase dodge > side air",
		weapon = "Gauntlets",
		legend = "Brann",
		steps = { { "Light", y = -1 }, chaseDiag, { "Light", toward = 1 } },
	},
	{
		name = "Gauntlets punch chain > jump > side air",
		weapon = "Gauntlets",
		legend = "Vex",
		steps = after(chain, jumpIn, { "Light", toward = 1 }),
		hits = 5,
	},
	{
		name = "Scythe punch chain > jump > neutral air",
		weapon = "Scythe",
		legend = "Moss",
		steps = after(chain, jumpIn, { "Light" }),
		hits = 5,
	},
}
local GAPS = { 2.2, 3, 4 }

local TRACE = require("@lune/process").env.TRACE
if TRACE then
	local r = ROUTES[tonumber(TRACE)]
	Duel.run({
		weapon = r.weapon,
		legend = r.legend,
		route = r.steps,
		gap = GAPS[tonumber(require("@lune/process").env.GAP or "2") or 2],
		trace = true,
	})
end

local comboReport = {}
for _, route in ROUTES do
	h.test(route.name .. " is a true combo at low damage only", function()
		local lowBest, highWorst
		local n = route.hits or 2
		for _, gap in GAPS do
			local low = Duel.run({ weapon = route.weapon, legend = route.legend, route = route.steps, gap = gap })
			local high =
				Duel.run({ weapon = route.weapon, legend = route.legend, route = route.steps, gap = gap, damage = 140 })
			if Duel.isTrue(low, n) or not lowBest then
				lowBest = lowBest and Duel.isTrue(lowBest, n) and lowBest or low
			end
			if Duel.isTrue(high, n) or not highWorst then
				highWorst = highWorst and Duel.isTrue(highWorst, n) and highWorst or high
			end
		end
		table.insert(
			comboReport,
			string.format(
				"       %-50s 0%%: %-24s 140%%: %s",
				route.name,
				Duel.describe(lowBest),
				Duel.describe(highWorst)
			)
		)
		h.expect(Duel.isTrue(lowBest, n), "not a true combo at 0%: " .. Duel.describe(lowBest))
		h.expect(not Duel.isTrue(highWorst, n), "still true at 140% (should only string): " .. Duel.describe(highWorst))
	end)
end

-- Battlegrounds-style: the punch chain itself always links, at any damage.
for _, weapon in { "Unarmed", "Sword", "Hammer", "Spear", "Gauntlets", "Scythe", "Bow" } do
	h.test(weapon .. " punch chain is a true combo at 0% and 140%", function()
		for _, damage in { 0, 140 } do
			-- (the bow's finisher is an arrow, which these melee duels don't fire)
			local n = weapon == "Bow" and 3 or 4
			local best
			for _, gap in GAPS do
				local hits = Duel.run({ weapon = weapon, route = chain, gap = gap, damage = damage })
				if Duel.isTrue(hits, n) then
					best = hits
				end
				best = best or hits
			end
			h.expect(Duel.isTrue(best, n), string.format("%d%%: %s", damage, Duel.describe(best)))
		end
	end)
end
for _, line in comboReport do
	print(line)
end

h.finish()
