--!strict
-- ShopConfig: the Item Shop - permanent upgrades bought with in-game cash. Each upgrade has five
-- levels; `levels[n]` is what level n costs and what it gives. Level 0 = not bought (base game).
-- The server applies every effect (Upgrades.luau) and re-checks every purchase; the client only
-- shows them (ShopUI.luau). Balance lives here.
export type Level = {
	price: number,
	value: number, -- what the level gives, in the upgrade's own unit (see `unit`)
	label: string, -- shown on the card, e.g. "14 stud reach"
}

export type Upgrade = {
	key: string,
	display: string,
	icon: string, -- emoji until painted icons arrive
	color: Color3, -- card accent
	desc: string,
	unit: string,
	levels: { Level },
}

local ShopConfig = {
	Order = { "Towel", "Speed", "Lock", "Collect" },
	Upgrades = {} :: { [string]: Upgrade },
	TowelKnockbackPerLevel = 0.12, -- Towel: knockback x(1 + this x level)
	SpeedCarryRelief = 0.1, -- Speed: each level removes this share of the carry slowdown
	LockCooldownCut = 2, -- Lock: each level takes this many seconds off the re-lock cooldown
	AutoCollectLevel = 3, -- Collect: from this level, cash collects itself while you stand in your drawer
}

ShopConfig.Upgrades = {
	-- value = Towel Snap reach in studs (the base game is EconomyConfig.TowelRange = 10)
	Towel = { key = "Towel", display = "Towel Snap", icon = "💥", color = Color3.fromRGB(90, 170, 255), unit = "studs",
		desc = "Longer reach and a harder snap - send thieves flying.",
		levels = {
			{ price = 500,    value = 12, label = "12 stud reach" },
			{ price = 3000,   value = 14, label = "14 stud reach" },
			{ price = 20000,  value = 16, label = "16 stud reach" },
			{ price = 120000, value = 18, label = "18 stud reach" },
			{ price = 750000, value = 20, label = "20 stud reach" },
		} },
	-- value = extra WalkSpeed (the base game is EconomyConfig.BaseWalkSpeed = 16)
	Speed = { key = "Speed", display = "Speed Socks", icon = "👟", color = Color3.fromRGB(110, 210, 120), unit = "speed",
		desc = "Run faster, and carry stolen socks with less slowdown.",
		levels = {
			{ price = 750,     value = 1.5, label = "+1.5 speed" },
			{ price = 5000,    value = 3,   label = "+3 speed" },
			{ price = 30000,   value = 4.5, label = "+4.5 speed" },
			{ price = 200000,  value = 6,   label = "+6 speed" },
			{ price = 1200000, value = 8,   label = "+8 speed" },
		} },
	-- value = extra seconds your drawer stays slammed (the base game is EconomyConfig.LockSeconds = 60)
	Lock = { key = "Lock", display = "Sturdy Lock", icon = "🔒", color = Color3.fromRGB(255, 170, 60), unit = "seconds",
		desc = "Your drawer stays slammed longer and re-locks sooner.",
		levels = {
			{ price = 1000,    value = 10, label = "+10s lock" },
			{ price = 7500,    value = 20, label = "+20s lock" },
			{ price = 50000,   value = 30, label = "+30s lock" },
			{ price = 300000,  value = 45, label = "+45s lock" },
			{ price = 2000000, value = 60, label = "+60s lock" },
		} },
	-- value = bonus percent on every Collect; level AutoCollectLevel+ also collects by itself
	Collect = { key = "Collect", display = "Coin Magnet", icon = "🧲", color = Color3.fromRGB(240, 192, 96), unit = "percent",
		desc = "Bonus cash on every Collect. Level 3+ collects by itself while you're in your drawer.",
		levels = {
			{ price = 2000,    value = 10, label = "+10% collect" },
			{ price = 15000,   value = 20, label = "+20% collect" },
			{ price = 100000,  value = 30, label = "+30% + auto" },
			{ price = 600000,  value = 40, label = "+40% + auto" },
			{ price = 4000000, value = 50, label = "+50% + auto" },
		} },
}

return ShopConfig
