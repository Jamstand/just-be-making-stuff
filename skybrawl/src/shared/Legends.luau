--[[
    The roster. Each legend has two weapons, four stats and three signature
    heavies per weapon (their ground heavies with that weapon). "Avatar" is
    your own Roblox avatar: any weapon, average stats, the shared heavies.

    Stats (2..9, each legend's add up to 22):
      Strength    +5% damage dealt per point above 5
      Dexterity   3% faster startup and recovery per point above 5
      Defense     -4% damage taken per point above 5
      Speed       +4% run/air/dash speed and -3% dodge cooldowns per point above 5

    Legends.getAttack(legend, weapon, slot) is the one lookup everything uses
    (FighterSim, the server, visuals): it applies the signature and the
    Dexterity timing, so client and server always agree on frame data.

    Signature fields replace the shared heavy's; anything not given falls
    back to it (timings, damage, knockback, hitbox), except Motion, Radial
    and Projectile, which a signature only has if it says so.
]]

local Weapons = require(script.Parent.Weapons)

local Legends = {}

local function hb(x, y, w, h)
	return { X = x, Y = y, W = w, H = h }
end

local function motion(at, duration, vx, vy)
	return { At = at, Duration = duration, VX = vx, VY = vy }
end

local function arrows(t)
	t.Gravity = t.Gravity or 0
	t.Lifetime = t.Lifetime or 0.8
	t.W = t.W or 1.6
	t.H = t.H or 0.6
	t.Count = t.Count or 1
	t.Spread = t.Spread or 0
	t.Pierce = t.Pierce == true
	t.Visual = t.Visual or "Arrow"
	return t
end

-- stylua: ignore start
Legends.List = {
	Kestrel = {
		Id = "Kestrel", Name = "Kestrel", Title = "Sky-Corsair",
		Description = "A fast, slippery duelist who lives on the edge of the stage.",
		Weapons = { "Sword", "Bow" },
		Stats = { Strength = 5, Dexterity = 6, Defense = 4, Speed = 7 },
		Color = Color3.fromRGB(31, 128, 136),
		Signatures = {
			Sword = {
				NHeavy = { Name = "Updraft", Startup = 0.26, Active = 0.2, Recovery = 0.4, Damage = 15, BaseKnockback = 28, KnockbackScaling = 48, Angle = 85, Charge = 0.5, Motion = motion(0.24, 0.2, 4, 38), Hitbox = hb(1, 5, 4.5, 6) },
				SHeavy = { Name = "Gale Rush", Startup = 0.28, Active = 0.16, Recovery = 0.42, Damage = 16, BaseKnockback = 30, KnockbackScaling = 52, Angle = 25, Charge = 0.5, Motion = motion(0.26, 0.18, 52, 0), Hitbox = hb(2.5, 3, 5, 3) },
				DHeavy = { Name = "Compass Sweep", Startup = 0.28, Active = 0.2, Recovery = 0.4, Damage = 14, BaseKnockback = 26, KnockbackScaling = 46, Angle = 45, Charge = 0.5, Radial = true, Hitbox = hb(0, 1.2, 10, 2.6) },
			},
			Bow = {
				NHeavy = { Name = "Skyfall Volley", Startup = 0.32, Active = 0.05, Recovery = 0.4, Damage = 8, BaseKnockback = 24, KnockbackScaling = 40, Angle = 80, Charge = 0.5, Projectile = arrows({ Speed = 90, Angle = 75, Lifetime = 0.7, Count = 3, Spread = 20 }) },
				SHeavy = { Name = "Piercing Gale", Startup = 0.34, Active = 0.05, Recovery = 0.42, Damage = 15, BaseKnockback = 28, KnockbackScaling = 50, Angle = 20, Charge = 0.6, Projectile = arrows({ Speed = 160, Angle = 0, Lifetime = 0.9, W = 2.6, H = 0.9, Pierce = true }) },
				DHeavy = { Name = "Anchor Kick", Startup = 0.26, Active = 0.16, Recovery = 0.4, Damage = 14, BaseKnockback = 26, KnockbackScaling = 48, Angle = 70, Charge = 0.5, Motion = motion(0.22, 0.16, -18, 30), Hitbox = hb(2, 1.5, 4.5, 3) },
			},
		},
	},
	Brann = {
		Id = "Brann", Name = "Brann", Title = "Forge Smith",
		Description = "Slow, sturdy and devastating when a swing lands.",
		Weapons = { "Hammer", "Gauntlets" },
		Stats = { Strength = 8, Dexterity = 4, Defense = 7, Speed = 3 },
		Color = Color3.fromRGB(196, 92, 40),
		Signatures = {
			Hammer = {
				NHeavy = { Name = "Anvil Rise", Startup = 0.42, Active = 0.18, Recovery = 0.46, Damage = 21, BaseKnockback = 33, KnockbackScaling = 62, Angle = 78, Charge = 0.7, Hitbox = hb(1.5, 5, 6.5, 7) },
				SHeavy = { Name = "Forge Charge", Startup = 0.38, Active = 0.24, Recovery = 0.48, Damage = 20, BaseKnockback = 32, KnockbackScaling = 60, Angle = 30, Charge = 0.7, Motion = motion(0.34, 0.24, 40, 0), Hitbox = hb(3, 3, 4.5, 4) },
				DHeavy = { Name = "Quake", Startup = 0.42, Active = 0.18, Recovery = 0.5, Damage = 19, BaseKnockback = 32, KnockbackScaling = 58, Angle = 55, Charge = 0.7, Radial = true, Hitbox = hb(0, 1, 13, 2.8) },
			},
			Gauntlets = {
				NHeavy = { Name = "Bellows Blast", Startup = 0.3, Active = 0.16, Recovery = 0.36, Damage = 16, BaseKnockback = 28, KnockbackScaling = 52, Angle = 85, Charge = 0.5, Hitbox = hb(1.4, 4.8, 3.8, 5) },
				SHeavy = { Name = "Hot Iron", Startup = 0.3, Active = 0.24, Recovery = 0.38, Damage = 16, BaseKnockback = 28, KnockbackScaling = 52, Angle = 35, Charge = 0.5, Motion = motion(0.28, 0.24, 30, 0), Hitbox = hb(1.5, 3, 5, 3.4) },
				DHeavy = { Name = "Ember Stomp", Startup = 0.3, Active = 0.16, Recovery = 0.4, Damage = 15, BaseKnockback = 28, KnockbackScaling = 48, Angle = 65, Charge = 0.5, Radial = true, Hitbox = hb(0, 0.8, 8.5, 2.2) },
			},
		},
	},
	Yuki = {
		Id = "Yuki", Name = "Yuki", Title = "Frost Ranger",
		Description = "Keeps foes at spear's length and picks them off from range.",
		Weapons = { "Spear", "Bow" },
		Stats = { Strength = 5, Dexterity = 7, Defense = 4, Speed = 6 },
		Color = Color3.fromRGB(150, 200, 240),
		Signatures = {
			Spear = {
				NHeavy = { Name = "Icicle Pillar", Startup = 0.32, Active = 0.16, Recovery = 0.4, Damage = 16, BaseKnockback = 28, KnockbackScaling = 52, Angle = 88, Charge = 0.6, Motion = motion(0.3, 0.14, 0, 30), Hitbox = hb(1.5, 6.5, 3, 7) },
				SHeavy = { Name = "Glacier Lance", Startup = 0.36, Active = 0.14, Recovery = 0.42, Damage = 17, BaseKnockback = 30, KnockbackScaling = 54, Angle = 22, Charge = 0.6, Motion = motion(0.32, 0.16, 36, 0), Hitbox = hb(6, 2.8, 10, 2) },
				DHeavy = { Name = "Frost Ring", Startup = 0.34, Active = 0.2, Recovery = 0.42, Damage = 15, BaseKnockback = 28, KnockbackScaling = 48, Angle = 48, Charge = 0.6, Radial = true, Hitbox = hb(0, 1.2, 12, 2.4) },
			},
			Bow = {
				NHeavy = { Name = "Snowfall", Startup = 0.3, Active = 0.05, Recovery = 0.4, Damage = 14, BaseKnockback = 26, KnockbackScaling = 48, Angle = 70, Charge = 0.5, Projectile = arrows({ Speed = 100, Angle = 70, Gravity = 60, Lifetime = 1.0, W = 2, H = 2 }) },
				SHeavy = { Name = "Frozen Line", Startup = 0.32, Active = 0.05, Recovery = 0.42, Damage = 9, BaseKnockback = 22, KnockbackScaling = 40, Angle = 25, Charge = 0.5, Projectile = arrows({ Speed = 130, Angle = 0, Lifetime = 0.8, Count = 2, Spread = 6 }) },
				DHeavy = { Name = "Ice Step", Startup = 0.28, Active = 0.05, Recovery = 0.4, Damage = 13, BaseKnockback = 26, KnockbackScaling = 46, Angle = 40, Charge = 0.5, Motion = motion(0.22, 0.16, -20, 34), Projectile = arrows({ Speed = 110, Angle = -30, Lifetime = 0.6 }) },
			},
		},
	},
	Moss = {
		Id = "Moss", Name = "Moss", Title = "Jungle Druid",
		Description = "Long reach and steady footing; good at everything.",
		Weapons = { "Scythe", "Spear" },
		Stats = { Strength = 6, Dexterity = 5, Defense = 6, Speed = 5 },
		Color = Color3.fromRGB(96, 170, 70),
		Signatures = {
			Scythe = {
				NHeavy = { Name = "Thornwhirl", Startup = 0.34, Active = 0.2, Recovery = 0.42, Damage = 16, BaseKnockback = 28, KnockbackScaling = 50, Angle = 82, Charge = 0.6, Radial = true, Motion = motion(0.3, 0.18, 0, 24), Hitbox = hb(0, 4.5, 8, 7) },
				SHeavy = { Name = "Vine Snare", Startup = 0.36, Active = 0.16, Recovery = 0.42, Damage = 17, BaseKnockback = 30, KnockbackScaling = 52, Angle = 35, Charge = 0.6, Hitbox = hb(5, 3, 8, 3.2) },
				DHeavy = { Name = "Root Sweep", Startup = 0.34, Active = 0.18, Recovery = 0.44, Damage = 15, BaseKnockback = 28, KnockbackScaling = 48, Angle = 60, Charge = 0.6, Radial = true, Hitbox = hb(0, 1, 12, 2.4) },
			},
			Spear = {
				NHeavy = { Name = "Sprout", Startup = 0.32, Active = 0.16, Recovery = 0.4, Damage = 16, BaseKnockback = 28, KnockbackScaling = 50, Angle = 75, Charge = 0.6, Motion = motion(0.28, 0.14, 8, 26), Hitbox = hb(3, 5.5, 4.5, 5) },
				SHeavy = { Name = "Bamboo Vault", Startup = 0.36, Active = 0.2, Recovery = 0.44, Damage = 17, BaseKnockback = 30, KnockbackScaling = 54, Angle = 30, Charge = 0.6, Motion = motion(0.3, 0.22, 34, 22), Hitbox = hb(2.5, 3.5, 4.5, 4) },
				DHeavy = { Name = "Seed Spiral", Startup = 0.34, Active = 0.2, Recovery = 0.42, Damage = 15, BaseKnockback = 28, KnockbackScaling = 46, Angle = 45, Charge = 0.6, Radial = true, Hitbox = hb(0, 1, 11, 2.2) },
			},
		},
	},
	Vex = {
		Id = "Vex", Name = "Vex", Title = "Shadow Rogue",
		Description = "Hits hard and fast, but can't take much in return.",
		Weapons = { "Scythe", "Gauntlets" },
		Stats = { Strength = 6, Dexterity = 7, Defense = 3, Speed = 6 },
		Color = Color3.fromRGB(120, 70, 170),
		Signatures = {
			Scythe = {
				NHeavy = { Name = "Eclipse", Startup = 0.3, Active = 0.2, Recovery = 0.4, Damage = 17, BaseKnockback = 30, KnockbackScaling = 54, Angle = 80, Charge = 0.5, Radial = true, Hitbox = hb(0, 5, 9, 5) },
				SHeavy = { Name = "Shadow Step", Startup = 0.3, Active = 0.14, Recovery = 0.42, Damage = 17, BaseKnockback = 30, KnockbackScaling = 56, Angle = 28, Charge = 0.5, Motion = motion(0.28, 0.12, 70, 0), Hitbox = hb(2, 3, 6, 3) },
				DHeavy = { Name = "Nightfall", Startup = 0.3, Active = 0.18, Recovery = 0.42, Damage = 15, BaseKnockback = 28, KnockbackScaling = 50, Angle = 50, Charge = 0.5, Radial = true, Hitbox = hb(0, 1, 11, 2.4) },
			},
			Gauntlets = {
				NHeavy = { Name = "Rising Claw", Startup = 0.26, Active = 0.18, Recovery = 0.34, Damage = 15, BaseKnockback = 28, KnockbackScaling = 54, Angle = 86, Charge = 0.4, Motion = motion(0.24, 0.16, 0, 32), Hitbox = hb(1, 5, 3.6, 5.4) },
				SHeavy = { Name = "Phantom Rush", Startup = 0.28, Active = 0.16, Recovery = 0.34, Damage = 16, BaseKnockback = 28, KnockbackScaling = 54, Angle = 26, Charge = 0.4, Motion = motion(0.26, 0.16, 62, 0), Hitbox = hb(2.6, 3, 4, 2.6) },
				DHeavy = { Name = "Umbral Burst", Startup = 0.26, Active = 0.16, Recovery = 0.36, Damage = 14, BaseKnockback = 26, KnockbackScaling = 48, Angle = 70, Charge = 0.4, Radial = true, Hitbox = hb(0, 1, 7.5, 2.6) },
			},
		},
	},
	Sol = {
		Id = "Sol", Name = "Sol", Title = "Sun Knight",
		Description = "An armored knight with crushing, reliable swings.",
		Weapons = { "Sword", "Hammer" },
		Stats = { Strength = 7, Dexterity = 4, Defense = 7, Speed = 4 },
		Color = Color3.fromRGB(230, 180, 60),
		Signatures = {
			Sword = {
				NHeavy = { Name = "Sunrise", Startup = 0.32, Active = 0.16, Recovery = 0.4, Damage = 17, BaseKnockback = 30, KnockbackScaling = 52, Angle = 82, Charge = 0.6, Hitbox = hb(1.5, 5.5, 5, 6) },
				SHeavy = { Name = "Zenith Lunge", Startup = 0.34, Active = 0.14, Recovery = 0.42, Damage = 18, BaseKnockback = 31, KnockbackScaling = 56, Angle = 30, Charge = 0.6, Motion = motion(0.3, 0.16, 44, 0), Hitbox = hb(4.5, 2.8, 6.5, 2.8) },
				DHeavy = { Name = "Corona", Startup = 0.32, Active = 0.2, Recovery = 0.42, Damage = 16, BaseKnockback = 29, KnockbackScaling = 50, Angle = 45, Charge = 0.6, Radial = true, Hitbox = hb(0, 2, 10, 3.6) },
			},
			Hammer = {
				NHeavy = { Name = "Solar Flare", Startup = 0.42, Active = 0.18, Recovery = 0.46, Damage = 21, BaseKnockback = 33, KnockbackScaling = 62, Angle = 80, Charge = 0.7, Hitbox = hb(2, 5, 6.5, 6.5) },
				SHeavy = { Name = "Judgement", Startup = 0.44, Active = 0.16, Recovery = 0.48, Damage = 22, BaseKnockback = 34, KnockbackScaling = 64, Angle = 40, Charge = 0.7, Motion = motion(0.38, 0.12, 22, 0), Hitbox = hb(4.6, 2.8, 6.4, 4) },
				DHeavy = { Name = "Daybreak", Startup = 0.42, Active = 0.18, Recovery = 0.5, Damage = 19, BaseKnockback = 32, KnockbackScaling = 58, Angle = 50, Charge = 0.7, Radial = true, Hitbox = hb(0, 1, 12.5, 2.8) },
			},
		},
	},
	Avatar = {
		Id = "Avatar", Name = "My Avatar", Title = "Yourself",
		Description = "Fight as your own Roblox avatar. Picks up any weapon.",
		Weapons = nil,
		Stats = { Strength = 5, Dexterity = 6, Defense = 5, Speed = 6 },
		Color = Color3.fromRGB(200, 200, 210),
		Signatures = {},
	},
}
-- stylua: ignore end

Legends.Order = { "Kestrel", "Brann", "Yuki", "Moss", "Vex", "Sol", "Avatar" }
Legends.Default = "Kestrel"
Legends.StatNames = { "Strength", "Dexterity", "Defense", "Speed" }
Legends.SignatureSlots = { "NHeavy", "SHeavy", "DHeavy" }

function Legends.get(legendId)
	return Legends.List[legendId or ""] or Legends.List.Avatar
end

function Legends.isValid(legendId)
	return type(legendId) == "string" and Legends.List[legendId] ~= nil
end

function Legends.usesAvatar(legendId)
	return Legends.get(legendId).Id == "Avatar"
end

-- Stat effects --------------------------------------------------------------

local function stat(legendId, name)
	return Legends.get(legendId).Stats[name] - 5
end

function Legends.damageDealtMult(legendId)
	return 1 + 0.05 * stat(legendId, "Strength")
end

function Legends.damageTakenMult(legendId)
	return 1 - 0.04 * stat(legendId, "Defense")
end

function Legends.timingMult(legendId)
	return 1 - 0.03 * stat(legendId, "Dexterity")
end

function Legends.speedMult(legendId)
	return 1 + 0.04 * stat(legendId, "Speed")
end

function Legends.dodgeCooldownMult(legendId)
	return 1 - 0.03 * stat(legendId, "Speed")
end

-- Weapons -------------------------------------------------------------------

function Legends.hasWeapon(legendId, weaponId)
	local weapons = Legends.get(legendId).Weapons
	if not weapons then
		return Weapons.isWeapon(weaponId)
	end
	return table.find(weapons, weaponId) ~= nil
end

--[[
    What a legend gets from a weapon pickup: legends alternate between their
    two weapons (the first pickup gives the matching one if the pickup is one
    of theirs); "Avatar" takes whatever the pickup is. `allowed` (a set) is
    the match's weapon list: a legend's weapon that isn't on it is skipped,
    and if neither is, they get the pickup itself.
]]
function Legends.weaponFromPickup(legendId, pickupWeapon, lastWeapon, allowed)
	local all = Legends.get(legendId).Weapons
	if not all then
		return pickupWeapon
	end
	local weapons = {}
	for _, w in all do
		if not allowed or allowed[w] then
			table.insert(weapons, w)
		end
	end
	if #weapons == 0 then
		return pickupWeapon
	elseif #weapons == 1 then
		return weapons[1]
	end
	if lastWeapon == weapons[1] then
		return weapons[2]
	elseif lastWeapon == weapons[2] then
		return weapons[1]
	end
	if table.find(weapons, pickupWeapon) then
		return pickupWeapon
	end
	return weapons[1]
end

-- Mesh skin for a held weapon ("KestrelSword"), used by visuals.
function Legends.weaponSkin(legendId, weaponId)
	local legend = Legends.get(legendId)
	if legend.Weapons and table.find(legend.Weapons, weaponId) then
		return legend.Id .. weaponId
	end
	return weaponId
end

-- Attacks -------------------------------------------------------------------

local INHERIT = {
	"Startup", "Active", "Recovery", "Damage", "BaseKnockback", "KnockbackScaling", "Angle", "Charge",
}

local function signature(base, sig, legendId, weaponId, slot)
	local move = table.clone(base)
	move.Motion = nil
	move.Radial = nil
	move.Projectile = nil
	move.Hitbox = nil
	for key, value in sig do
		move[key] = value
	end
	for _, key in INHERIT do
		if move[key] == nil then
			move[key] = base[key]
		end
	end
	if not move.Hitbox and not move.Projectile then
		move.Hitbox = base.Hitbox
	end
	move.Signature = sig.Name
	move.AnimKey = legendId .. "." .. weaponId .. "." .. slot
	return move
end

local cache = {}

function Legends.getAttack(legendId, weaponId, slot)
	local legend = Legends.get(legendId)
	weaponId = Weapons.get(weaponId).Id
	local key = legend.Id .. "/" .. weaponId .. "/" .. tostring(slot)
	local cached = cache[key]
	if cached then
		return cached
	end
	local base = Weapons.getAttack(weaponId, slot)
	if not base then
		return nil
	end
	local sigs = legend.Signatures[weaponId]
	local sig = sigs and sigs[slot]
	local move = sig and signature(base, sig, legend.Id, weaponId, slot) or table.clone(base)
	move.AnimKey = move.AnimKey or (weaponId .. "." .. slot)
	local mult = Legends.timingMult(legend.Id)
	move.Startup *= mult
	move.Recovery *= mult
	if move.Motion then
		move.Motion = table.clone(move.Motion)
		move.Motion.At *= mult
	end
	table.freeze(move)
	cache[key] = move
	return move
end

function Legends.signatureName(legendId, weaponId, slot)
	local sigs = Legends.get(legendId).Signatures[weaponId]
	local sig = sigs and sigs[slot]
	return sig and sig.Name or nil
end

return Legends
