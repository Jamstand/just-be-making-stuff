--[[
    Weapon + attack data.

    Every weapon (and Unarmed) has the same 11 attack slots:

      Ground lights:  NLight  SLight  DLight
      Air lights:     NAir    SAir    DAir
      Ground heavies: NHeavy  SHeavy  DHeavy      (hold to charge)
      Air heavies:    Recovery (neutral/up/side)  GroundPound (down)

    Attack fields (times in seconds, distances in studs):

      Startup / Active / Recovery   phase lengths
      Damage                        damage % added on hit
      BaseKnockback / KnockbackScaling / Angle
                                    launch = BKB + KBS * (victim damage / 100),
                                    Angle in degrees relative to facing
                                    (0 forward, 90 up, negative = downward,
                                    >90 pulls back toward the attacker)
      Radial                        launch away from the attacker horizontally
                                    instead of along their facing
      Hitbox = {X, Y, W, H}         center offset from the fighter's feet
                                    (X is mirrored by facing) and size
      Motion = {At, Duration, VX, VY}
                                    sets the attacker's velocity for a while
      Charge                        max seconds a held heavy can charge
      EndsOnLand                    active until the attacker lands
      Projectile = {...}            fires projectile(s) at Startup instead of
                                    using a melee hitbox
      Anim                          procedural pose (see client Visuals)
      AirDrift                      0..1 how much air control you keep
]]

local Weapons = {}

-- stylua: ignore start
Weapons.Slots = {
	"NLight", "SLight", "DLight",
	"NAir", "SAir", "DAir",
	"NHeavy", "SHeavy", "DHeavy",
	"Recovery", "GroundPound",
}
-- stylua: ignore end

Weapons.SlotNames = {
	NLight = "Neutral Light",
	SLight = "Side Light",
	DLight = "Down Light",
	NAir = "Neutral Air",
	SAir = "Side Air",
	DAir = "Down Air",
	NHeavy = "Neutral Heavy",
	SHeavy = "Side Heavy",
	DHeavy = "Down Heavy",
	Recovery = "Recovery",
	GroundPound = "Ground Pound",
}

local HEAVY_SLOTS = { NHeavy = true, SHeavy = true, DHeavy = true, Recovery = true, GroundPound = true }
local AIR_SLOTS = { NAir = true, SAir = true, DAir = true, Recovery = true, GroundPound = true }

local function hb(x, y, w, h)
	return { X = x, Y = y, W = w, H = h }
end

local function motion(at, duration, vx, vy)
	return { At = at, Duration = duration, VX = vx, VY = vy }
end

-- Fills defaults so every attack has the full set of fields.
local function attack(slot, t)
	t.Slot = slot
	t.Kind = HEAVY_SLOTS[slot] and "Heavy" or "Light"
	t.Air = AIR_SLOTS[slot] == true
	t.Startup = t.Startup or 0.12
	t.Active = t.Active or 0.1
	t.Recovery = t.Recovery or 0.2
	t.Damage = t.Damage or 8
	t.BaseKnockback = t.BaseKnockback or (t.Kind == "Heavy" and 28 or 18)
	t.KnockbackScaling = t.KnockbackScaling or (t.Kind == "Heavy" and 50 or 14)
	t.Angle = t.Angle or 35
	t.AirDrift = t.AirDrift or (t.Air and 0.6 or 0)
	t.Anim = t.Anim or "Slash"
	if slot == "GroundPound" then
		t.EndsOnLand = true
	end
	return t
end

local function moveset(list)
	local out = {}
	for slot, t in list do
		out[slot] = attack(slot, t)
	end
	for _, slot in Weapons.Slots do
		assert(out[slot], "moveset missing slot " .. slot)
	end
	return out
end

-- Shared air heavies keep recoveries consistent between weapons.
local function recovery(t)
	t.Startup = t.Startup or 0.08
	t.Active = t.Active or 0.28
	t.Recovery = t.Recovery or 0.32
	t.Damage = t.Damage or 10
	t.BaseKnockback = t.BaseKnockback or 24
	t.KnockbackScaling = t.KnockbackScaling or 30
	t.Angle = t.Angle or 85
	t.Motion = t.Motion or motion(0.06, 0.26, 9, 62)
	t.Anim = t.Anim or "Flip"
	t.AirDrift = t.AirDrift or 0.35
	return t
end

local function groundPound(t)
	t.Startup = t.Startup or 0.14
	t.Active = t.Active or 1.0
	t.Recovery = t.Recovery or 0.26
	t.Damage = t.Damage or 14
	t.BaseKnockback = t.BaseKnockback or 28
	t.KnockbackScaling = t.KnockbackScaling or 46
	t.Angle = t.Angle or 55
	t.Radial = true
	t.Motion = t.Motion or motion(0.12, 1.0, 0, -95)
	t.Anim = "Stomp"
	t.AirDrift = t.AirDrift or 0.25
	return t
end

-- stylua: ignore start
Weapons.List = {
	Unarmed = {
		Id = "Unarmed",
		Name = "Fists",
		Description = "Weak but quick. Grab a weapon as soon as you can.",
		Color = Color3.fromRGB(200, 200, 200),
		Hand = "Right",
		Moves = moveset({
			NLight = { Startup = 0.1, Active = 0.08, Recovery = 0.16, Damage = 5, BaseKnockback = 15, KnockbackScaling = 10, Angle = 25, Hitbox = hb(2.4, 3.3, 2.8, 2), Anim = "Punch" },
			SLight = { Startup = 0.12, Active = 0.12, Recovery = 0.2, Damage = 6, Angle = 25, Motion = motion(0.08, 0.14, 28, 0), Hitbox = hb(2.6, 3, 3.2, 2.2), Anim = "Punch" },
			DLight = { Startup = 0.12, Active = 0.1, Recovery = 0.2, Damage = 6, Angle = 60, Hitbox = hb(2.4, 0.8, 3.4, 1.6), Anim = "Kick" },
			NAir = { Startup = 0.1, Active = 0.14, Recovery = 0.16, Damage = 6, Angle = 70, Hitbox = hb(1.4, 4.6, 4.2, 3), Anim = "Uppercut" },
			SAir = { Startup = 0.12, Active = 0.12, Recovery = 0.2, Damage = 7, Angle = 30, Hitbox = hb(2.6, 2.8, 3.4, 2.4), Anim = "Kick" },
			DAir = { Startup = 0.14, Active = 0.14, Recovery = 0.22, Damage = 7, Angle = -40, Hitbox = hb(1, -0.4, 3.2, 2.4), Anim = "Stomp" },
			NHeavy = { Startup = 0.3, Active = 0.12, Recovery = 0.35, Damage = 12, BaseKnockback = 24, KnockbackScaling = 42, Angle = 80, Charge = 0.5, Hitbox = hb(1.8, 4.4, 3.2, 4.2), Anim = "Uppercut" },
			SHeavy = { Startup = 0.32, Active = 0.12, Recovery = 0.38, Damage = 13, BaseKnockback = 26, KnockbackScaling = 46, Angle = 30, Charge = 0.5, Motion = motion(0.26, 0.16, 34, 0), Hitbox = hb(2.8, 3, 3.6, 2.4), Anim = "Punch" },
			DHeavy = { Startup = 0.28, Active = 0.16, Recovery = 0.4, Damage = 11, BaseKnockback = 24, KnockbackScaling = 40, Angle = 40, Radial = true, Charge = 0.5, Hitbox = hb(0, 0.8, 7.5, 1.8), Anim = "Sweep" },
			Recovery = recovery({ Damage = 8, Hitbox = hb(1, 4, 3.4, 4.4) }),
			GroundPound = groundPound({ Damage = 11, Hitbox = hb(0, 0.4, 4, 3) }),
		}),
	},

	Sword = {
		Id = "Sword",
		Name = "Sword",
		Description = "Balanced and fast. A great all-rounder.",
		Color = Color3.fromRGB(150, 200, 255),
		Hand = "Right",
		Moves = moveset({
			NLight = { Startup = 0.1, Active = 0.1, Recovery = 0.18, Damage = 8, Angle = 50, Hitbox = hb(3, 3.6, 4.2, 3), Anim = "Arc" },
			SLight = { Startup = 0.11, Active = 0.1, Recovery = 0.2, Damage = 9, BaseKnockback = 20, KnockbackScaling = 16, Angle = 25, Motion = motion(0.08, 0.12, 30, 0), Hitbox = hb(3.6, 2.8, 5, 2.4), Anim = "Thrust" },
			DLight = { Startup = 0.12, Active = 0.12, Recovery = 0.22, Damage = 9, Angle = 70, Motion = motion(0.06, 0.16, 34, 0), Hitbox = hb(3, 0.9, 4.4, 1.8), Anim = "Low" },
			NAir = { Startup = 0.1, Active = 0.16, Recovery = 0.18, Damage = 8, Angle = 75, Hitbox = hb(1, 5, 6, 3.4), Anim = "Arc" },
			SAir = { Startup = 0.11, Active = 0.12, Recovery = 0.2, Damage = 9, BaseKnockback = 20, KnockbackScaling = 16, Angle = 30, Hitbox = hb(3.6, 2.8, 5.2, 2.8), Anim = "Slash" },
			DAir = { Startup = 0.14, Active = 0.16, Recovery = 0.22, Damage = 9, Angle = -40, Motion = motion(0.12, 0.16, 26, -40), Hitbox = hb(2, 0, 3.6, 2.6), Anim = "Dive" },
			NHeavy = { Startup = 0.3, Active = 0.14, Recovery = 0.36, Damage = 16, BaseKnockback = 28, KnockbackScaling = 50, Angle = 80, Charge = 0.6, Hitbox = hb(1.5, 5, 5, 5), Anim = "Uppercut" },
			SHeavy = { Startup = 0.32, Active = 0.12, Recovery = 0.38, Damage = 17, BaseKnockback = 30, KnockbackScaling = 54, Angle = 32, Charge = 0.6, Motion = motion(0.26, 0.16, 40, 0), Hitbox = hb(4, 2.8, 5.6, 2.6), Anim = "Thrust" },
			DHeavy = { Startup = 0.3, Active = 0.16, Recovery = 0.4, Damage = 15, BaseKnockback = 28, KnockbackScaling = 48, Angle = 40, Radial = true, Charge = 0.6, Hitbox = hb(0, 1.2, 10, 2.4), Anim = "Sweep" },
			Recovery = recovery({ Hitbox = hb(1.5, 4, 4, 5) }),
			GroundPound = groundPound({ Hitbox = hb(0, 0.5, 4.5, 3) }),
		}),
	},

	Hammer = {
		Id = "Hammer",
		Name = "Hammer",
		Description = "Slow, huge hitboxes, and the hardest hits in the game.",
		Color = Color3.fromRGB(255, 170, 90),
		Hand = "Right",
		Moves = moveset({
			NLight = { Startup = 0.14, Active = 0.12, Recovery = 0.24, Damage = 10, BaseKnockback = 22, KnockbackScaling = 16, Angle = 60, Hitbox = hb(3, 3.6, 5, 3.4), Anim = "Overhead" },
			SLight = { Startup = 0.15, Active = 0.12, Recovery = 0.26, Damage = 11, BaseKnockback = 24, KnockbackScaling = 18, Angle = 28, Motion = motion(0.1, 0.12, 22, 0), Hitbox = hb(3.8, 2.6, 5.4, 3), Anim = "Slash" },
			DLight = { Startup = 0.14, Active = 0.14, Recovery = 0.26, Damage = 10, BaseKnockback = 22, KnockbackScaling = 16, Angle = 75, Hitbox = hb(3.4, 0.8, 5, 1.8), Anim = "Low" },
			NAir = { Startup = 0.13, Active = 0.18, Recovery = 0.22, Damage = 10, Angle = 80, Radial = true, Hitbox = hb(0, 3, 7.5, 6), Anim = "Spin" },
			SAir = { Startup = 0.15, Active = 0.14, Recovery = 0.24, Damage = 11, BaseKnockback = 24, KnockbackScaling = 18, Angle = 25, Hitbox = hb(3.8, 2.8, 5.4, 3.2), Anim = "Slash" },
			DAir = { Startup = 0.17, Active = 0.16, Recovery = 0.26, Damage = 12, BaseKnockback = 22, KnockbackScaling = 16, Angle = -55, Hitbox = hb(1.6, -0.2, 4.4, 3), Anim = "Overhead" },
			NHeavy = { Startup = 0.4, Active = 0.16, Recovery = 0.44, Damage = 20, BaseKnockback = 32, KnockbackScaling = 60, Angle = 75, Charge = 0.7, Hitbox = hb(2.4, 4.5, 6, 6), Anim = "Uppercut" },
			SHeavy = { Startup = 0.42, Active = 0.14, Recovery = 0.46, Damage = 21, BaseKnockback = 34, KnockbackScaling = 64, Angle = 35, Charge = 0.7, Hitbox = hb(4.2, 2.6, 6.4, 3.4), Anim = "Overhead" },
			DHeavy = { Startup = 0.4, Active = 0.18, Recovery = 0.48, Damage = 19, BaseKnockback = 32, KnockbackScaling = 58, Angle = 45, Radial = true, Charge = 0.7, Hitbox = hb(0, 1, 12, 2.6), Anim = "Slam" },
			Recovery = recovery({ Startup = 0.1, Active = 0.3, Recovery = 0.36, Damage = 12, BaseKnockback = 26, KnockbackScaling = 32, Angle = 88, Motion = motion(0.08, 0.26, 6, 58), Hitbox = hb(0.5, 4.5, 5.5, 5.5), Anim = "Spin" }),
			GroundPound = groundPound({ Startup = 0.16, Recovery = 0.3, Damage = 17, BaseKnockback = 32, KnockbackScaling = 50, Angle = 60, Motion = motion(0.14, 1.0, 0, -100), Hitbox = hb(0, 0.5, 6, 3.5) }),
		}),
	},

	Spear = {
		Id = "Spear",
		Name = "Spear",
		Description = "Long reach. Poke from a distance and keep them out.",
		Color = Color3.fromRGB(120, 230, 160),
		Hand = "Right",
		Moves = moveset({
			NLight = { Startup = 0.11, Active = 0.1, Recovery = 0.2, Damage = 8, Angle = 65, Hitbox = hb(2.5, 5, 3.5, 4), Anim = "Uppercut" },
			SLight = { Startup = 0.12, Active = 0.1, Recovery = 0.22, Damage = 9, BaseKnockback = 20, KnockbackScaling = 15, Angle = 22, Hitbox = hb(5.2, 2.8, 7, 1.8), Anim = "Thrust" },
			DLight = { Startup = 0.13, Active = 0.12, Recovery = 0.22, Damage = 8, BaseKnockback = 20, Angle = 70, Hitbox = hb(5, 0.7, 7, 1.4), Anim = "Low" },
			NAir = { Startup = 0.11, Active = 0.16, Recovery = 0.2, Damage = 8, Angle = 80, Radial = true, Hitbox = hb(0, 3.4, 8, 5), Anim = "Spin" },
			SAir = { Startup = 0.12, Active = 0.12, Recovery = 0.22, Damage = 9, Angle = 25, Hitbox = hb(5.4, 2.8, 7.4, 2), Anim = "Thrust" },
			DAir = { Startup = 0.14, Active = 0.16, Recovery = 0.24, Damage = 9, Angle = -70, Hitbox = hb(0.6, -1.5, 2.4, 4.4), Anim = "Dive" },
			NHeavy = { Startup = 0.34, Active = 0.14, Recovery = 0.4, Damage = 16, BaseKnockback = 28, KnockbackScaling = 50, Angle = 82, Charge = 0.6, Hitbox = hb(2, 6, 4, 6), Anim = "Uppercut" },
			SHeavy = { Startup = 0.36, Active = 0.12, Recovery = 0.42, Damage = 17, BaseKnockback = 30, KnockbackScaling = 54, Angle = 25, Charge = 0.6, Hitbox = hb(6.5, 2.8, 9, 2), Anim = "Thrust" },
			DHeavy = { Startup = 0.34, Active = 0.16, Recovery = 0.42, Damage = 15, BaseKnockback = 28, KnockbackScaling = 46, Angle = 50, Charge = 0.6, Motion = motion(0.28, 0.16, 30, 0), Hitbox = hb(4, 1, 8, 2), Anim = "Low" },
			Recovery = recovery({ Motion = motion(0.06, 0.24, 14, 60), Hitbox = hb(2, 4, 4, 5), Anim = "Thrust" }),
			GroundPound = groundPound({ Hitbox = hb(0, -0.5, 4, 4) }),
		}),
	},

	Gauntlets = {
		Id = "Gauntlets",
		Name = "Gauntlets",
		Description = "Very fast, short range. Built for combos.",
		Color = Color3.fromRGB(255, 120, 120),
		Hand = "Both",
		Moves = moveset({
			NLight = { Startup = 0.08, Active = 0.08, Recovery = 0.14, Damage = 7, BaseKnockback = 16, KnockbackScaling = 12, Angle = 45, Hitbox = hb(2.4, 3.4, 3.2, 2.4), Anim = "Punch" },
			SLight = { Startup = 0.09, Active = 0.1, Recovery = 0.16, Damage = 8, Angle = 20, Motion = motion(0.06, 0.12, 32, 0), Hitbox = hb(2.8, 3, 3.6, 2.4), Anim = "Punch" },
			DLight = { Startup = 0.1, Active = 0.1, Recovery = 0.18, Damage = 7, Angle = 75, Hitbox = hb(2.4, 0.8, 3.6, 1.6), Anim = "Low" },
			NAir = { Startup = 0.08, Active = 0.12, Recovery = 0.16, Damage = 7, Angle = 80, Hitbox = hb(1, 5, 3.6, 3.2), Anim = "Uppercut" },
			SAir = { Startup = 0.09, Active = 0.1, Recovery = 0.16, Damage = 8, Angle = 30, Hitbox = hb(2.8, 3, 3.6, 2.4), Anim = "Punch" },
			DAir = { Startup = 0.12, Active = 0.14, Recovery = 0.2, Damage = 8, Angle = -50, Motion = motion(0.1, 0.14, 0, -50), Hitbox = hb(0.8, -0.4, 3, 2.6), Anim = "Stomp" },
			NHeavy = { Startup = 0.28, Active = 0.12, Recovery = 0.34, Damage = 15, BaseKnockback = 26, KnockbackScaling = 50, Angle = 82, Charge = 0.5, Hitbox = hb(1.6, 4.6, 3.4, 4.6), Anim = "Uppercut" },
			SHeavy = { Startup = 0.3, Active = 0.14, Recovery = 0.34, Damage = 16, BaseKnockback = 28, KnockbackScaling = 52, Angle = 28, Charge = 0.5, Motion = motion(0.24, 0.18, 48, 0), Hitbox = hb(3, 3, 4, 2.6), Anim = "Punch" },
			DHeavy = { Startup = 0.28, Active = 0.14, Recovery = 0.36, Damage = 14, BaseKnockback = 26, KnockbackScaling = 46, Angle = 70, Radial = true, Charge = 0.5, Hitbox = hb(0, 0.8, 7.5, 2), Anim = "Slam" },
			Recovery = recovery({ Startup = 0.06, Active = 0.3, Recovery = 0.3, Damage = 9, Angle = 88, Motion = motion(0.04, 0.26, 4, 64), Hitbox = hb(1, 4.5, 3.4, 4.4), Anim = "Uppercut" }),
			GroundPound = groundPound({ Startup = 0.12, Recovery = 0.24, Damage = 13, Motion = motion(0.1, 1.0, 0, -100), Hitbox = hb(0, 0.4, 4, 3) }),
		}),
	},

	Scythe = {
		Id = "Scythe",
		Name = "Scythe",
		Description = "Wide arcs, and its side light pulls enemies in.",
		Color = Color3.fromRGB(190, 130, 255),
		Hand = "Right",
		Moves = moveset({
			NLight = { Startup = 0.12, Active = 0.14, Recovery = 0.2, Damage = 8, Angle = 70, Hitbox = hb(2, 4, 6, 4), Anim = "Arc" },
			SLight = { Startup = 0.13, Active = 0.12, Recovery = 0.22, Damage = 9, BaseKnockback = 18, KnockbackScaling = 10, Angle = 150, Hitbox = hb(4.6, 2.8, 5.4, 3), Anim = "Reap" },
			DLight = { Startup = 0.13, Active = 0.12, Recovery = 0.22, Damage = 8, Angle = 70, Hitbox = hb(4, 0.8, 6.5, 1.8), Anim = "Low" },
			NAir = { Startup = 0.11, Active = 0.18, Recovery = 0.2, Damage = 8, Angle = 80, Radial = true, Hitbox = hb(0, 3, 8, 6.5), Anim = "Spin" },
			SAir = { Startup = 0.13, Active = 0.12, Recovery = 0.22, Damage = 9, Angle = 32, Hitbox = hb(4.4, 3, 6, 3.2), Anim = "Slash" },
			DAir = { Startup = 0.15, Active = 0.16, Recovery = 0.24, Damage = 9, Angle = -45, Hitbox = hb(2.6, -0.6, 5, 3), Anim = "Reap" },
			NHeavy = { Startup = 0.34, Active = 0.16, Recovery = 0.4, Damage = 16, BaseKnockback = 28, KnockbackScaling = 50, Angle = 78, Radial = true, Charge = 0.6, Hitbox = hb(0, 5, 9, 4.5), Anim = "Arc" },
			SHeavy = { Startup = 0.36, Active = 0.14, Recovery = 0.42, Damage = 17, BaseKnockback = 30, KnockbackScaling = 54, Angle = 30, Charge = 0.6, Motion = motion(0.3, 0.14, 26, 0), Hitbox = hb(4.6, 2.8, 7, 3.2), Anim = "Reap" },
			DHeavy = { Startup = 0.34, Active = 0.18, Recovery = 0.44, Damage = 15, BaseKnockback = 28, KnockbackScaling = 48, Angle = 50, Radial = true, Charge = 0.6, Hitbox = hb(0, 1, 11, 2.4), Anim = "Sweep" },
			Recovery = recovery({ Angle = 85, Radial = true, Motion = motion(0.06, 0.26, 6, 60), Hitbox = hb(0, 3.5, 7, 6), Anim = "Spin" }),
			GroundPound = groundPound({ Damage = 15, Recovery = 0.28, Hitbox = hb(0, 0.5, 6, 3) }),
		}),
	},

	Bow = {
		Id = "Bow",
		Name = "Bow",
		Description = "Shoots arrows on light attacks. Keep your distance.",
		Color = Color3.fromRGB(240, 220, 120),
		Hand = "Left",
		Moves = moveset({
			NLight = { Startup = 0.14, Active = 0.05, Recovery = 0.22, Damage = 6, BaseKnockback = 14, KnockbackScaling = 10, Angle = 60, Anim = "Shoot", Projectile = { Speed = 95, Angle = 60, Lifetime = 0.7 } },
			SLight = { Startup = 0.15, Active = 0.05, Recovery = 0.22, Damage = 7, BaseKnockback = 16, KnockbackScaling = 12, Angle = 20, Anim = "Shoot", Projectile = { Speed = 110, Angle = 0, Lifetime = 0.8 } },
			DLight = { Startup = 0.12, Active = 0.1, Recovery = 0.22, Damage = 7, Angle = 65, Hitbox = hb(2.6, 0.8, 3.6, 1.6), Anim = "Kick" },
			NAir = { Startup = 0.12, Active = 0.05, Recovery = 0.2, Damage = 4, BaseKnockback = 12, KnockbackScaling = 8, Angle = 30, Anim = "Shoot", Projectile = { Speed = 95, Angle = 15, Lifetime = 0.6, Count = 3, Spread = 15 } },
			SAir = { Startup = 0.13, Active = 0.05, Recovery = 0.22, Damage = 7, BaseKnockback = 16, KnockbackScaling = 12, Angle = 25, Anim = "Shoot", Projectile = { Speed = 110, Angle = 0, Lifetime = 0.8 } },
			DAir = { Startup = 0.13, Active = 0.05, Recovery = 0.22, Damage = 7, Angle = -30, Anim = "Shoot", Projectile = { Speed = 100, Angle = -50, Lifetime = 0.7 } },
			NHeavy = { Startup = 0.3, Active = 0.14, Recovery = 0.36, Damage = 15, BaseKnockback = 28, KnockbackScaling = 50, Angle = 80, Charge = 0.5, Hitbox = hb(1.6, 4.6, 4, 4.6), Anim = "Uppercut" },
			SHeavy = { Startup = 0.4, Active = 0.05, Recovery = 0.42, Damage = 15, BaseKnockback = 26, KnockbackScaling = 48, Angle = 25, Charge = 0.6, Anim = "Shoot", Projectile = { Speed = 140, Angle = 0, Lifetime = 1.0, W = 2.4, H = 0.8, Pierce = true } },
			DHeavy = { Startup = 0.3, Active = 0.16, Recovery = 0.4, Damage = 14, BaseKnockback = 26, KnockbackScaling = 46, Angle = 50, Radial = true, Charge = 0.5, Hitbox = hb(0, 1, 8, 2), Anim = "Sweep" },
			Recovery = recovery({ Damage = 9, Hitbox = hb(1, 4, 3.5, 5) }),
			GroundPound = groundPound({ Damage = 13, Hitbox = hb(0, 0.5, 4.4, 3) }),
		}),
	},
}
-- stylua: ignore end

Weapons.Order = { "Sword", "Hammer", "Spear", "Gauntlets", "Scythe", "Bow" }

-- Projectile defaults
for _, weapon in Weapons.List do
	for _, move in weapon.Moves do
		local p = move.Projectile
		if p then
			p.Gravity = p.Gravity or 0
			p.Lifetime = p.Lifetime or 0.8
			p.W = p.W or 1.6
			p.H = p.H or 0.6
			p.Count = p.Count or 1
			p.Spread = p.Spread or 0
			p.Pierce = p.Pierce == true
			p.Visual = p.Visual or "Arrow"
		end
	end
end

function Weapons.get(weaponId)
	return Weapons.List[weaponId or "Unarmed"] or Weapons.List.Unarmed
end

function Weapons.getAttack(weaponId, slot)
	local weapon = Weapons.get(weaponId)
	return weapon.Moves[slot]
end

function Weapons.isWeapon(weaponId)
	return weaponId ~= nil and weaponId ~= "Unarmed" and Weapons.List[weaponId] ~= nil
end

-- The longest a hit report for this attack can arrive after it started.
function Weapons.maxAttackWindow(move)
	return move.Startup + (move.Charge or 0) + move.Active
end

-- Rough reach of a melee hitbox, used for server-side range checks.
function Weapons.reach(move)
	local box = move.Hitbox
	if not box then
		return 0, 0
	end
	return math.abs(box.X) + box.W / 2, math.max(math.abs(box.Y), math.abs(box.Y + box.H / 2)) + box.H / 2
end

return Weapons
