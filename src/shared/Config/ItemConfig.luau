--!strict
-- ItemConfig: the item bar. Everyone has the Towel Snap in slot 1; the other items are unlocked
-- in the Item Shop's Items tab with cash, or straight away with Robux (each item's `product` is a
-- StoreConfig developer product, a one-time unlock). A player carries the towel plus up to
-- `LoadoutSize` unlocked items. The server checks every use (cooldowns, ownership, range) and
-- decides every hit; the client only asks.
--
-- Every unlocked item can be upgraded 3 times with cash (`Levels`): each level changes some of the
-- item's numbers (cumulative), and the last one turns it golden (its `<model>_Gold` look). Read an
-- item's number at a level with ItemConfig.Stat(key, level, name); the tuning tables below hold the
-- level-0 values.
--
-- CASH PRICES ARE PROPOSALS (Josh's call), like the Robux prices in StoreConfig. Never rename a
-- `key`: saves (profile.items / profile.loadout / profile.itemLevels) and receipts refer to it.
export type Item = {
	key: string,
	display: string,
	desc: string, -- one line for the Item Shop card
	icon: string, -- emoji used until the item's 3D model (ReplicatedStorage.ItemMeshes) is there
	color: Color3, -- card / slot colour
	price: number, -- cash; 0 = everyone has it (the towel)
	product: string?, -- StoreConfig.Products key of its Robux unlock
	cooldown: number, -- seconds from one use to the next
	model: string?, -- ItemMeshes name of what the player holds (the towel picks one per look)
}

-- One upgrade level of an item: its cash price, one line for the Item Shop, and the numbers it
-- changes (tuning-table names, or `cooldown`); later levels keep earlier levels' changes.
export type Level = {
	price: number,
	desc: string,
	set: { [string]: number },
}

local ItemConfig = {
	LoadoutSize = 3, -- unlocked items in the bar next to the towel
	Order = { "Towel", "SlipperDash", "BananaPeel", "Glider", "DuckAlarm", "BubbleBlaster", "SoftenerCloud", "StaticBalloon", "LaundryBasket" },
	Items = {} :: { [string]: Item },

	-- ---------- Towel Snap (reach, knockback and stun stay in EconomyConfig / ShopConfig / StoreConfig) ----------
	-- The towel's look by Towel Snap level (index = level + 1); the Golden Towel pass shows "Royal".
	TowelLooks = { "Plain", "Striped", "Beach", "Spa", "Sports", "Champion" },
	TowelRoyal = "Royal",
	TowelCone = 0.5, -- a hit must be within this cos() of where you face (0.5 = 60 degrees either side)
	-- holding the towel: every `count`-th crack in a row (each within `window` s of the last) is a
	-- finisher - a wider sweep (`cone`, a cos()) with `knockMult` x the knockback
	TowelCombo = { count = 3, window = 1.6, cone = 0.15, knockMult = 1.6 },
	-- aim help on touch screens and gamepads: a snap turns to the nearest target within this cos() of
	-- where you face (0 = 90 degrees either side) and the towel's reach
	TowelAssistCone = 0.0,
	ShoveMult = 0.5, -- players who aren't carrying a sock: this share of a thief's knockback, no stun
	ShoveGrace = 1, -- seconds a pushed player can't be pushed again (by anything)

	-- ---------- the items' own numbers (level 0; `Levels` change them) ----------
	-- Slipper Dash: dashing into a player bumps them (bumpMult x a towel shove; a thief drops the
	-- sock); `airDashes` more dashes while still in the air
	Dash = { distance = 22, seconds = 0.25, carryMult = 0.7, bumpRadius = 3.5, bumpMult = 1, airDashes = 1 },
	-- Banana Peel: up to `peels` out at once; a slipper slides `bowlDistance` studs forward and anyone
	-- within `bowlRadius` of the slide stumbles too (`chain` levels deep; a thief anywhere drops the sock)
	Banana = { lifetime = 30, slipSeconds = 1.2, radius = 2.2, peels = 1, bowlDistance = 14, bowlRadius = 3.5, stumbleSeconds = 0.6, chain = 3 },
	-- Dryer-Sheet Glider: from any jump; a second press mid-glide slams down: a shockwave within
	-- `slamRadius` (slamMult x a towel shove); `slamStun` > 0 also stuns thieves and drops their sock
	Glider = { fallSpeed = 6, forwardSpeed = 22, maxSeconds = 8, slamSpeed = 70, slamRadius = 9, slamMult = 1, slamStun = 0 },
	-- Rubber Duck Alarm: one per player, in your own drawer; it waddles after an intruder
	-- (`chaseSpeed`) and honks every `honkGap` s when within `honkRange`: they slow to `honkSlow` for
	-- `honkSeconds`, and you see a thief through walls for `revealSeconds`; `honkStun` > 0 also stuns
	-- a thief and sends the sock home (at most once per intruder per `stunGap` s); `ducks` out at once
	Duck = { quackGap = 5, highlightSeconds = 6, ducks = 1, chaseSpeed = 9, honkRange = 6, honkGap = 1.5, honkSlow = 0.6, honkSeconds = 1.2, revealSeconds = 5, honkStun = 0, stunGap = 15 },
	-- Bubble Blaster: bubbles bounce off walls `bounces` times; a pop splashes a push (splashMult x a
	-- towel shove) within `splashRadius`; `shots` bubbles in a fan; `homing` (0..1) steers toward thieves
	Bubble = { speed = 40, range = 40, radius = 2.5, floatSeconds = 2, floatHeight = 6, bounceMult = 0.3, bounces = 1, splashRadius = 6, splashMult = 0.4, shots = 1, homing = 0 },
	-- Softener Cloud: drifts the way you aimed at `driftSpeed` and grows to `growRadius`; a thief
	-- inside for `napAfter` s nods off for `napSeconds` and the sock goes home
	Softener = { distance = 6, radius = 8, lifetime = 6, slowMult = 0.6, thiefSlowMult = 0.45, driftSpeed = 3, growRadius = 11, napAfter = 2, napSeconds = 1.5 },
	-- Static Balloon: hold to rub it for up to `chargeSeconds`: the zap's radius grows from `radius`
	-- to `chargeRadius` and its push from 1x to `chargeMult` x a towel shove; `chainJumps` more
	-- players just outside get an arc too; `zapStun` > 0 stuns thieves
	Balloon = { radius = 12, hairSeconds = 3, chargeSeconds = 2, chargeRadius = 18, chargeMult = 1.8, chainJumps = 0, zapStun = 0 },
	-- Laundry Basket: hidden until you pop out; popping out yourself is a pounce: everyone else
	-- within `pounceRadius` jumps back (pounceMult x a towel shove); `pounceDrop` = 1: thieves drop the sock
	Basket = { maxSeconds = 15, speedMult = 0.55, pounceRadius = 8, pounceMult = 1, pounceDrop = 0 },

	MaxLevel = 3, -- the last level turns the item golden
	-- item key -> its tuning table above
	Tuning = { SlipperDash = "Dash", BananaPeel = "Banana", Glider = "Glider", DuckAlarm = "Duck", BubbleBlaster = "Bubble", SoftenerCloud = "Softener", StaticBalloon = "Balloon", LaundryBasket = "Basket" } :: { [string]: string },
	Levels = {} :: { [string]: { Level } },
}

ItemConfig.Items = {
	Towel         = { key = "Towel",         display = "Towel Snap",        icon = "💥", color = Color3.fromRGB(90, 170, 255),  price = 0,       cooldown = 1,
		desc = "Snap a thief to send them flying and their stolen sock home. Shoves anyone else." },
	SlipperDash   = { key = "SlipperDash",   display = "Slipper Dash",      icon = "🥿", color = Color3.fromRGB(190, 160, 255), price = 5000,    cooldown = 6,  product = "Item_SlipperDash",   model = "DashSlippers",
		desc = "A quick forward dash in fuzzy slippers: escape with a sock or catch a thief." },
	BananaPeel    = { key = "BananaPeel",    display = "Banana Peel",       icon = "🍌", color = Color3.fromRGB(255, 214, 80),  price = 15000,   cooldown = 12, product = "Item_BananaPeel",    model = "BananaPeel",
		desc = "Drop a peel. The next player to run over it slips and drops any sock they carry." },
	Glider        = { key = "Glider",        display = "Dryer-Sheet Glider", icon = "🪂", color = Color3.fromRGB(150, 220, 255), price = 40000,   cooldown = 4,  product = "Item_Glider",        model = "DryerSheet",
		desc = "Jump off the furniture and glide across the bedroom on a dryer sheet." },
	DuckAlarm     = { key = "DuckAlarm",     display = "Rubber Duck Alarm", icon = "🦆", color = Color3.fromRGB(255, 200, 60),  price = 75000,   cooldown = 10, product = "Item_DuckAlarm",     model = "AlarmDuck",
		desc = "Place it in your drawer: it quacks and lights up anyone who walks in." },
	BubbleBlaster = { key = "BubbleBlaster", display = "Bubble Blaster",    icon = "🫧", color = Color3.fromRGB(120, 210, 255), price = 150000,  cooldown = 8,  product = "Item_BubbleBlaster", model = "BubbleBlaster",
		desc = "A thief hit by the bubble floats away inside it and drops the sock." },
	SoftenerCloud = { key = "SoftenerCloud", display = "Softener Cloud",    icon = "☁️", color = Color3.fromRGB(255, 170, 220), price = 400000,  cooldown = 18, product = "Item_SoftenerCloud", model = "SoftenerBottle",
		desc = "Spray a fluffy cloud: everyone inside moves slow and sleepy, thieves slowest." },
	StaticBalloon = { key = "StaticBalloon", display = "Static Balloon",    icon = "🎈", color = Color3.fromRGB(255, 110, 120), price = 1000000, cooldown = 20, product = "Item_StaticBalloon", model = "StaticBalloon",
		desc = "ZAP! Everyone near you hops back with their hair on end; thieves drop the sock." },
	LaundryBasket = { key = "LaundryBasket", display = "Laundry Basket",    icon = "🧺", color = Color3.fromRGB(230, 190, 120), price = 2500000, cooldown = 25, product = "Item_LaundryBasket", model = "LaundryBasket",
		desc = "Hide under a basket and shuffle along. Use it again to pop out." },
}

-- Upgrade levels (prices: 1.5x, 3x and 6x the unlock price). Level 3 also turns the item golden.
ItemConfig.Levels = {
	SlipperDash = {
		{ price = 7500,     desc = "Recharges faster (6 s -> 4.5 s)",                   set = { cooldown = 4.5 } },
		{ price = 15000,    desc = "Longer dash (22 -> 30 studs)",                      set = { distance = 30 } },
		{ price = 30000,    desc = "GOLDEN: bumps 50% harder, a sparkling trail",       set = { bumpMult = 1.5 } },
	},
	BananaPeel = {
		{ price = 22500,    desc = "Peels last longer (30 s -> 60 s)",                  set = { lifetime = 60 } },
		{ price = 45000,    desc = "Two peels out at once",                             set = { peels = 2 } },
		{ price = 90000,    desc = "GOLDEN: longer slips, longer bowling slides",       set = { slipSeconds = 2, bowlDistance = 20 } },
	},
	Glider = {
		{ price = 60000,    desc = "Glide longer and faster",                           set = { maxSeconds = 12, forwardSpeed = 27 } },
		{ price = 120000,   desc = "Bigger slam (9 -> 13 studs)",                       set = { slamRadius = 13, slamMult = 1.3 } },
		{ price = 240000,   desc = "GOLDEN: the slam stuns thieves and drops their sock", set = { slamStun = 0.8 } },
	},
	DuckAlarm = {
		{ price = 112500,   desc = "Stronger, longer honks",                            set = { honkSlow = 0.45, honkSeconds = 1.8 } },
		{ price = 225000,   desc = "Two ducks guard your drawer",                       set = { ducks = 2 } },
		{ price = 450000,   desc = "GOLDEN: a honk stuns a thief and sends the sock home", set = { honkStun = 0.8 } },
	},
	BubbleBlaster = {
		{ price = 225000,   desc = "Recharges faster (8 s -> 6 s)",                     set = { cooldown = 6 } },
		{ price = 450000,   desc = "Three bubbles in a fan",                            set = { shots = 3 } },
		{ price = 900000,   desc = "GOLDEN: bubbles chase thieves and float them longer", set = { homing = 0.6, floatSeconds = 3 } },
	},
	SoftenerCloud = {
		{ price = 600000,   desc = "The cloud lasts longer (6 s -> 9 s)",               set = { lifetime = 9 } },
		{ price = 1200000,  desc = "A bigger cloud",                                    set = { radius = 10, growRadius = 14 } },
		{ price = 2400000,  desc = "GOLDEN: thieves nod off after just 1 s",            set = { napAfter = 1 } },
	},
	StaticBalloon = {
		{ price = 1500000,  desc = "Recharges faster (20 s -> 15 s)",                   set = { cooldown = 15 } },
		{ price = 3000000,  desc = "A bigger charged zap (18 -> 23 studs)",             set = { chargeRadius = 23 } },
		{ price = 6000000,  desc = "GOLDEN: the zap arcs to 2 more players and stuns thieves", set = { chainJumps = 2, zapStun = 0.5 } },
	},
	LaundryBasket = {
		{ price = 3750000,  desc = "Shuffle faster under the basket",                   set = { speedMult = 0.75 } },
		{ price = 7500000,  desc = "Hide longer (15 s -> 25 s)",                        set = { maxSeconds = 25 } },
		{ price = 15000000, desc = "GOLDEN: a bigger pounce that makes thieves drop the sock", set = { pounceRadius = 11, pounceDrop = 1 } },
	},
}

-- An item's number at an upgrade level: the tuning table's level-0 value (or the item's
-- `cooldown`) with every change up to that level applied. 0 when the item or number doesn't exist.
function ItemConfig.Stat(key: string, level: number, name: string): number
	local value: number? = nil
	if name == "cooldown" then
		local item = ItemConfig.Items[key]
		value = if item then item.cooldown else nil
	else
		local tableName = ItemConfig.Tuning[key]
		local tuning = if tableName then (ItemConfig :: any)[tableName] else nil
		value = if type(tuning) == "table" and type(tuning[name]) == "number" then tuning[name] else nil
	end
	local levels = ItemConfig.Levels[key]
	if levels then
		for i = 1, math.min(level, #levels) do
			local v = levels[i].set[name]
			if v ~= nil then
				value = v
			end
		end
	end
	return value or 0
end

-- Is the item golden at this level? (its tool and world objects use `<model>_Gold`)
function ItemConfig.IsGold(level: number): boolean
	return level >= ItemConfig.MaxLevel
end

return ItemConfig
