--[[
    Damage, knockback and hitstun formulas shared by server and client.
]]

local Config = require(script.Parent.Config)

local C = Config.Combat

local Combat = {}

-- Damage % an attack adds, after charge and the match's damage multiplier.
function Combat.damage(move, chargeFrac, multiplier)
	local raw = move.Damage * (1 + (chargeFrac or 0) * C.ChargeDamageBonus) * (multiplier or 1)
	return math.max(1, math.floor(raw + 0.5))
end

--[[
    Launch velocity for a hit.
      victimDamage   the victim's damage % after this hit
      facing         attacker facing (1/-1)
      dx             victim.x - attacker.x (used by Radial moves)
    Returns kbx, kby, force.
]]
function Combat.knockback(move, victimDamage, chargeFrac, facing, dx)
	local force = (move.BaseKnockback + move.KnockbackScaling * (victimDamage / 100)) * C.KnockbackScale
	force *= 1 + (chargeFrac or 0) * C.ChargeKnockbackBonus
	local dir = facing
	if move.Radial then
		dir = (dx or 0) >= 0 and 1 or -1
	end
	local angle = math.rad(move.Angle)
	return math.cos(angle) * force * dir, math.sin(angle) * force, force
end

function Combat.hitstun(force)
	return math.min(C.MaxHitstun, C.BaseHitstun + force * C.HitstunPerForce)
end

-- Thrown weapons behave like a tiny attack.
Combat.ThrowMove = {
	Damage = Config.WeaponDrops.ThrowDamage,
	BaseKnockback = Config.WeaponDrops.ThrowBaseKnockback,
	KnockbackScaling = Config.WeaponDrops.ThrowKnockbackScaling,
	Angle = Config.WeaponDrops.ThrowAngle,
	Kind = "Light",
}

-- White -> yellow -> orange -> red -> dark red as damage climbs.
local DAMAGE_COLORS = {
	{ 0, Color3.fromRGB(255, 255, 255) },
	{ 40, Color3.fromRGB(255, 240, 120) },
	{ 90, Color3.fromRGB(255, 160, 50) },
	{ 140, Color3.fromRGB(240, 60, 40) },
	{ 200, Color3.fromRGB(150, 20, 30) },
}

function Combat.damageColor(damage)
	for i = 2, #DAMAGE_COLORS do
		local hi = DAMAGE_COLORS[i]
		if damage <= hi[1] then
			local lo = DAMAGE_COLORS[i - 1]
			local alpha = (damage - lo[1]) / (hi[1] - lo[1])
			return lo[2]:Lerp(hi[2], alpha)
		end
	end
	return DAMAGE_COLORS[#DAMAGE_COLORS][2]
end

return Combat
