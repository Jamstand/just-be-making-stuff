--[[
    Headless bot-vs-bot fights using the real BotBrain, FighterSim and
    knockback code. Run from the skybrawl folder:  lune run tests/bots
]]

local h = require("./harness")

local Config = h.require("Config")
local Maps = h.require("Maps")
local FighterSim = h.require("FighterSim")
local Combat = h.require("Combat")
local Weapons = h.require("Weapons")
local BotBrain = h.requireServer("BotBrain")

local DT = 1 / 60
local B = Config.Battle

local function simulate(mapId, difficultyA, difficultyB, seconds, weaponA, weaponB)
	local world = Maps.getWorld(mapId)
	local map = Maps.get(mapId)
	local match = { world = world, fighters = {}, pickups = {} }
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
	function match:UltimateState(f)
		if f.awakenLeft > 0 then
			return not f.ultUsed and "Attack" or nil
		end
		return f.ult >= B.UltMax and "Awaken" or nil
	end

	local fighters = {}
	for i, spec in { { difficultyA, weaponA }, { difficultyB, weaponB } } do
		local spawn = map.Spawns[i]
		local f = {
			id = "b" .. i,
			team = i,
			alive = true,
			eliminated = false,
			weapon = spec[2] or "Unarmed",
			damage = 0,
			state = FighterSim.newState(spawn[1], spawn[2], spawn[3]),
			kos = 0,
			falls = 0,
			selfDestructs = 0,
			hits = 0,
			lastHitAt = -100,
			guard = B.GuardMax,
			ult = 0,
			awakenLeft = 0,
			ultUsed = false,
			blocks = 0,
			guardBreaks = 0,
			techs = 0,
			knockdowns = 0,
			awakenings = 0,
			ultimates = 0,
		}
		f.brain = BotBrain.new(f, match, spec[1])
		fighters[i] = f
		match.fighters[f.id] = f
	end

	local t = 0
	local respawnAt = {}
	while t < seconds do
		t += DT
		for i, f in fighters do
			if not f.alive then
				if t >= respawnAt[i] then
					local spot = map.Respawns[1]
					FighterSim.respawn(f.state, spot[1], spot[2], 1, Config.Combat.RespawnInvuln)
					f.alive = true
					f.damage = 0
				end
				continue
			end
			local s = f.state
			f.awakenLeft = math.max(0, f.awakenLeft - DT)
			if not FighterSim.isBlocking(s) then
				f.guard = math.min(B.GuardMax, f.guard + B.GuardRegen * DT)
			end
			local input = f.brain:Update(DT)
			local events = FighterSim.step(s, input, DT, {
				world = world,
				weapon = f.weapon,
				armed = Weapons.isWeapon(f.weapon),
				nearPickup = false,
				ultimate = match:UltimateState(f),
				awakened = f.awakenLeft > 0,
			})
			for _, ev in events do
				if ev.type == "Attack" then
					f.hitThisSeq = {}
					if ev.slot == "Ultimate" then
						f.ultUsed = true
						f.ultimates += 1
					end
				elseif ev.type == "Awaken" and match:UltimateState(f) == "Awaken" then
					f.ult = 0
					f.ultUsed = false
					f.awakenLeft = B.AwakenFreeze + B.AwakenTime
					f.awakenings += 1
					FighterSim.awaken(s, B.AwakenFreeze)
					FighterSim.freeze(fighters[3 - i].state, B.AwakenFreeze)
				elseif ev.type == "Tech" then
					f.techs += 1
				elseif ev.type == "Knockdown" then
					f.knockdowns += 1
				end
			end
			local x1, y1, x2, y2 = FighterSim.activeHitbox(s)
			if x1 then
				local other = fighters[3 - i]
				if other.alive and not FighterSim.isInvulnerable(other.state) and not f.hitThisSeq[other.id] then
					local hx1, hy1, hx2, hy2 = FighterSim.hurtbox(other.state.x, other.state.y)
					if FighterSim.overlaps(x1, y1, x2, y2, hx1, hy1, hx2, hy2) then
						f.hitThisSeq[other.id] = true
						local move = s.move
						local dmg = Combat.damage(move, FighterSim.chargeFraction(s), 1)
						local os_ = other.state
						if
							FighterSim.isBlocking(os_)
							and not move.Unblockable
							and (s.x - os_.x) * os_.facing >= -0.5
						then
							local heavy = move.Kind == "Heavy" and B.GuardDrainHeavy or 1
							other.guard -= B.GuardDrainBase + dmg * B.GuardDrainPerDamage * heavy
							other.blocks += 1
							if other.guard <= 0 then
								other.guard = 0
								other.guardBreaks += 1
								FighterSim.applyGuardBreak(os_, B.GuardBreakStun)
							else
								FighterSim.applyBlock(os_, (os_.x >= s.x and 1 or -1) * B.BlockPushback, B.BlockStun, 0)
							end
						else
							other.damage += dmg
							local kbx, kby, force = Combat.knockback(move, other.damage, 0, s.facing, os_.x - s.x)
							FighterSim.applyHit(os_, kbx, kby, Combat.hitstun(force), 0, force >= B.RagdollForce)
							other.lastHitAt = t
							f.hits += 1
							if f.awakenLeft <= 0 then
								f.ult = math.min(B.UltMax, f.ult + dmg * B.UltPerDamageDealt)
							end
							if other.awakenLeft <= 0 then
								other.ult = math.min(B.UltMax, other.ult + dmg * B.UltPerDamageTaken)
							end
						end
					end
				end
			end
			if Maps.isOutOfBounds(world, s.x, s.y) then
				f.alive = false
				f.falls += 1
				f.awakenLeft = 0
				f.guard = B.GuardMax
				if t - f.lastHitAt > Config.Combat.KOCreditWindow then
					f.selfDestructs += 1
				else
					fighters[3 - i].kos += 1
				end
				respawnAt[i] = t + Config.Combat.RespawnTime
			end
		end
	end
	return fighters
end

local function report(label, fighters)
	local a, b = fighters[1], fighters[2]
	print(
		string.format(
			"  %-34s A: %3d hits %2d KOs %2d SDs   B: %3d hits %2d KOs %2d SDs",
			label,
			a.hits,
			a.kos,
			a.selfDestructs,
			b.hits,
			b.kos,
			b.selfDestructs
		)
	)
end

print("Bot fights (3 simulated minutes each)")

local totals = {
	hits = 0,
	kos = 0,
	selfDestructs = 0,
	falls = 0,
	blocks = 0,
	guardBreaks = 0,
	techs = 0,
	knockdowns = 0,
	awakenings = 0,
	ultimates = 0,
}
local hardVsEasyKOs, easyVsHardKOs = 0, 0
for _, mapId in Maps.Order do
	for _, pairing in { { "Normal", "Normal" }, { "Hard", "Easy" } } do
		local fighters = simulate(mapId, pairing[1], pairing[2], 180, "Sword", "Sword")
		report(mapId .. " " .. pairing[1] .. " vs " .. pairing[2], fighters)
		for _, f in fighters do
			totals.hits += f.hits
			totals.kos += f.kos
			totals.selfDestructs += f.selfDestructs
			totals.falls += f.falls
			for _, key in { "blocks", "guardBreaks", "techs", "knockdowns", "awakenings", "ultimates" } do
				totals[key] += f[key]
			end
		end
		if pairing[1] == "Hard" then
			hardVsEasyKOs += fighters[1].kos
			easyVsHardKOs += fighters[2].kos
		end
	end
end
print(string.format("  totals: %d hits, %d KOs, %d self-destructs", totals.hits, totals.kos, totals.selfDestructs))
print(
	string.format(
		"  battle: %d blocks, %d guard breaks, %d knockdowns, %d techs, %d awakenings, %d ultimates",
		totals.blocks,
		totals.guardBreaks,
		totals.knockdowns,
		totals.techs,
		totals.awakenings,
		totals.ultimates
	)
)

h.test("bots land hits and score KOs", function()
	h.expect(totals.hits > 100, "too few hits: " .. totals.hits)
	h.expect(totals.kos >= 8, "too few KOs: " .. totals.kos)
end)

h.test("bots rarely fall off on their own", function()
	h.expect(
		totals.selfDestructs <= math.max(2, totals.falls * 0.25),
		string.format("%d of %d falls were self-destructs", totals.selfDestructs, totals.falls)
	)
end)

h.test("bots block, tech, awaken and use ultimates", function()
	h.expect(totals.blocks > 20, "too few blocks: " .. totals.blocks)
	h.expect(totals.techs > 0 and totals.knockdowns > 0, "no techs or no knockdowns")
	h.expect(totals.awakenings > 0, "no awakenings")
	h.expect(totals.ultimates > 0, "no ultimates")
end)

h.test("hard bots beat easy bots", function()
	h.expect(hardVsEasyKOs > easyVsHardKOs, string.format("hard %d vs easy %d", hardVsEasyKOs, easyVsHardKOs))
end)

h.finish()
