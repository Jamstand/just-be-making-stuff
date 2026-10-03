--!strict
-- ItemConfig: the item bar. Everyone has the Towel Snap in slot 1; the other items are unlocked
-- in the Item Shop's Items tab with cash, or straight away with Robux (each item's `product` is a
-- StoreConfig developer product, a one-time unlock). A player carries the towel plus up to
-- `LoadoutSize` unlocked items. The server checks every use (cooldowns, ownership, range) and
-- decides every hit; the client only asks.
--
-- CASH PRICES ARE PROPOSALS (Josh's call), like the Robux prices in StoreConfig. Never rename a
-- `key`: saves (profile.items / profile.loadout) and receipts refer to it.
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

local ItemConfig = {
	LoadoutSize = 3, -- unlocked items in the bar next to the towel
	Order = { "Towel", "SlipperDash", "BananaPeel", "Glider", "DuckAlarm", "BubbleBlaster", "SoftenerCloud", "StaticBalloon", "LaundryBasket" },
	Items = {} :: { [string]: Item },

	-- ---------- Towel Snap (reach, knockback and stun stay in EconomyConfig / ShopConfig / StoreConfig) ----------
	-- The towel's look by Towel Snap level (index = level + 1); the Golden Towel pass shows "Royal".
	TowelLooks = { "Plain", "Striped", "Beach", "Spa", "Sports", "Champion" },
	TowelRoyal = "Royal",
	TowelCone = 0.5, -- a hit must be within this cos() of where you face (0.5 = 60 degrees either side)
	ShoveMult = 0.5, -- players who aren't carrying a sock: this share of a thief's knockback, no stun
	ShoveGrace = 1, -- seconds a pushed player can't be pushed again (by anything)

	-- ---------- the items' own numbers ----------
	Dash = { distance = 22, seconds = 0.25, carryMult = 0.7 }, -- Slipper Dash (carryMult: shorter while carrying a sock)
	Banana = { lifetime = 30, slipSeconds = 1.2, radius = 2.2 }, -- Banana Peel: one per player, gone after a slip
	Glider = { fallSpeed = 6, forwardSpeed = 22, maxSeconds = 8 }, -- Dryer-Sheet Glider: only while falling
	Duck = { quackGap = 5, highlightSeconds = 6 }, -- Rubber Duck Alarm: one per player, in your own drawer
	Bubble = { speed = 40, range = 40, radius = 2.5, floatSeconds = 2, floatHeight = 6, bounceMult = 0.3 }, -- Bubble Blaster
	Softener = { distance = 6, radius = 8, lifetime = 6, slowMult = 0.6, thiefSlowMult = 0.45 }, -- Softener Cloud
	Balloon = { radius = 12, hairSeconds = 3 }, -- Static Balloon: knockback = a towel shove
	Basket = { maxSeconds = 15, speedMult = 0.55 }, -- Laundry Basket: hidden until you pop out
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

return ItemConfig
