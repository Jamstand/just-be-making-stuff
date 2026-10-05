--[[
    Scripted 1v1 duels on the real FighterSim and hit formulas, for combo
    tests and the combo search tool (tests/combo_search).
]]

local h = require("./harness")

local Config = h.require("Config")
local Maps = h.require("Maps")
local FighterSim = h.require("FighterSim")
local Combat = h.require("Combat")
local Legends = h.require("Legends")

local DT = 1 / 60

local Duel = {}

function Duel.newInput()
	return {
		moveX = 0,
		moveY = 0,
		jumpHeld = false,
		heavyHeld = false,
		buffer = { Jump = 0, Light = 0, Heavy = 0, Dodge = 0, Throw = 0 },
	}
end

function Duel.ctx(weapon, legend, mapId)
	return {
		world = Maps.getWorld(mapId or "SkyholdKeep"),
		weapon = weapon or "Unarmed",
		legend = legend or "Avatar",
		armed = weapon ~= nil and weapon ~= "Unarmed",
		nearPickup = false,
	}
end

function Duel.tick(s, input, c, events)
	for k, v in input.buffer do
		input.buffer[k] = math.max(0, v - DT)
	end
	return FighterSim.step(s, input, DT, c, events or {})
end

function Duel.press(input, action)
	input.buffer[action] = Config.InputBufferTime
end

function Duel.grounded(x, facing)
	local s = FighterSim.newState(x, 0, facing or 1)
	local input = Duel.newInput()
	for _ = 1, 2 do
		Duel.tick(s, input, Duel.ctx())
	end
	return s
end

function Duel.canAct(a)
	return a.action == nil and a.hitstop <= 0
end

function Duel.afterActive(a)
	local move = a.move
	return a.action == "Attack" and move ~= nil and a.actionTime >= move.Startup + move.Active
end

--[[
    route = list of steps the attacker performs in order:
      { "Light"|"Heavy"|"Jump"|"Dodge", x = moveX, y = moveY,
        toward = moveX pointed at the victim, when = fn(attacker, victim) }
    A step fires once `when` is true (default: as soon as the attacker can
    act or cancel). Returns the hits; hit.linked = the victim was still in
    hitstun (a true combo link).
]]
function Duel.run(opts)
	local legend = opts.legend or "Avatar"
	local c = Duel.ctx(opts.weapon, legend)
	local vc = Duel.ctx(nil, "Avatar")
	local a = Duel.grounded(0, 1)
	local v = Duel.grounded(opts.gap or 2.6, -1)
	local ai, vi = Duel.newInput(), Duel.newInput()
	local damage = opts.damage or 0
	local hits = {}
	local logged = {}
	local step = 1
	local route = opts.route
	for _ = 1, 60 * 3 do
		local spec = route[step]
		if spec then
			local ready
			if spec.when then
				ready = spec.when(a, v)
			else
				ready = Duel.canAct(a) or Duel.afterActive(a)
			end
			if ready then
				ai.moveX, ai.moveY = spec.x or 0, spec.y or 0
				if spec.toward then
					ai.moveX = spec.toward * (v.x >= a.x and 1 or -1)
				end
				Duel.press(ai, spec[1])
				ai.jumpHeld = spec[1] == "Jump"
				step += 1
			end
		end
		Duel.tick(a, ai, c)
		Duel.tick(v, vi, vc)
		if opts.trace then
			print(
				string.format(
					"a x%6.2f y%6.2f vx%6.1f vy%6.1f %-7s %-8s t%.2f | v x%6.2f y%6.2f vx%6.1f vy%6.1f %-7s hs%.2f",
					a.x,
					a.y,
					a.vx,
					a.vy,
					tostring(a.action),
					tostring(a.slot or a.dodgeKind),
					a.actionTime,
					v.x,
					v.y,
					v.vx,
					v.vy,
					tostring(v.action),
					v.hitstun
				)
			)
		end
		local x1, y1, x2, y2 = FighterSim.activeHitbox(a)
		if x1 and not logged[a.seq] then
			local hx1, hy1, hx2, hy2 = FighterSim.hurtbox(v.x, v.y)
			if FighterSim.overlaps(x1, y1, x2, y2, hx1, hy1, hx2, hy2) then
				logged[a.seq] = true
				local move = a.move
				local inHitstun = v.action == "Hitstun"
				damage += Combat.damage(move, 0, Legends.damageDealtMult(legend))
				local kbx, kby, force = Combat.knockback(move, damage, 0, a.facing, v.x - a.x)
				local stop = Combat.hitstop(force)
				FighterSim.applyHit(v, kbx, kby, Combat.hitstun(force), stop)
				FighterSim.onHitConfirm(a, stop)
				table.insert(hits, { slot = a.slot, linked = inHitstun, damage = damage })
			end
		end
		if step > #route and a.action == nil and v.action ~= "Hitstun" then
			break
		end
	end
	return hits
end

function Duel.describe(hits)
	local parts = {}
	for i, hit in hits do
		table.insert(parts, (i > 1 and (hit.linked and " > " or " ~ ") or "") .. hit.slot)
	end
	return table.concat(parts)
end

-- True if the first n hits all landed, each while the victim was in hitstun.
function Duel.isTrue(hits, n)
	if #hits < n then
		return false
	end
	for i = 2, n do
		if not hits[i].linked then
			return false
		end
	end
	return true
end

return Duel
