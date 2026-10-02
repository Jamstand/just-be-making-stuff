--!strict
-- StoreConfig: the Robux Store (game passes + developer products).
--
-- PRICES ARE PROPOSALS. Josh sets the real ones: create each pass/product in the Creator
-- Dashboard, then paste its id below and set `price` to what Roblox charges (the UI shows this
-- number). Never change a `key` once the item is live - saves and receipts refer to it.
-- While an id is 0, purchases are SIMULATED in Studio only (Monetize.luau test mode); a live
-- server never grants an id-0 item.
export type Pass = {
	key: string,
	id: number,
	price: number, -- Robux (proposed until Josh confirms)
	display: string,
	desc: string,
	icon: string,
	color: Color3,
}

export type Product = {
	key: string,
	id: number,
	price: number, -- Robux (proposed until Josh confirms)
	display: string,
	desc: string,
	icon: string,
	color: Color3,
	cashMin: number?, -- cash packs: at least this much...
	cashSeconds: number?, -- ...or this many seconds of the buyer's current income, whichever is more
	minutes: number?, -- Server Luck: duration (buying again adds time)
	luck: number?, -- Server Luck: each rarity rank's weight is multiplied by luck^(rank - 1)
	minRank: number?, -- Rare Sock Drop: lowest rarity rank it can roll (3 = Epic)
}

local StoreConfig = {
	PassOrder = { "DoubleCash", "VIP", "ExtraSlots", "GoldenTowel" },
	ProductOrder = { "CashSmall", "CashMedium", "CashLarge", "ServerLuck", "RareDrop", "Relock" },
	Featured = "DoubleCash", -- the pass the Store marks "BEST"
	Passes = {} :: { [string]: Pass },
	Products = {} :: { [string]: Product },
	DoubleCashMult = 2, -- 2x Cash pass: income multiplier
	VipIncomeBonus = 0.1, -- VIP pass: +10% income
	ExtraSlots = 4, -- Extra Drawer Slots pass: slots added (the drawer's back row)
	GoldenTowelMult = 1.5, -- Golden Towel pass: reach and knockback multiplier
}

StoreConfig.Passes = {
	DoubleCash  = { key = "DoubleCash",  id = 0, price = 199, display = "2x Cash",          icon = "💰", color = Color3.fromRGB(88, 200, 110),
		desc = "Every sock earns double, forever." },
	VIP         = { key = "VIP",         id = 0, price = 249, display = "VIP",              icon = "👑", color = Color3.fromRGB(255, 200, 60),
		desc = "Gold VIP name tag, +10% cash and a VIP badge." },
	ExtraSlots  = { key = "ExtraSlots",  id = 0, price = 299, display = "+4 Drawer Slots",  icon = "🗄️", color = Color3.fromRGB(150, 90, 230),
		desc = "Unlocks the back row of your drawer: 4 more socks." },
	GoldenTowel = { key = "GoldenTowel", id = 0, price = 149, display = "Golden Towel",     icon = "✨", color = Color3.fromRGB(255, 215, 80),
		desc = "A shiny gold towel with +50% snap reach and knockback." },
}

StoreConfig.Products = {
	CashSmall  = { key = "CashSmall",  id = 0, price = 29,  display = "Pouch of Cash",  icon = "🪙", color = Color3.fromRGB(240, 192, 96),
		desc = "5 minutes of your income (at least $2.5K).", cashMin = 2500, cashSeconds = 300 },
	CashMedium = { key = "CashMedium", id = 0, price = 99,  display = "Sack of Cash",   icon = "💵", color = Color3.fromRGB(110, 210, 120),
		desc = "30 minutes of your income (at least $25K).", cashMin = 25000, cashSeconds = 1800 },
	CashLarge  = { key = "CashLarge",  id = 0, price = 299, display = "Vault of Cash",  icon = "🏦", color = Color3.fromRGB(90, 170, 255),
		desc = "2 hours of your income (at least $250K).", cashMin = 250000, cashSeconds = 7200 },
	ServerLuck = { key = "ServerLuck", id = 0, price = 49,  display = "Server Luck",    icon = "🍀", color = Color3.fromRGB(88, 200, 110),
		desc = "Rarer socks come out of the Dryer for EVERYONE for 15 minutes.", minutes = 15, luck = 1.5 },
	RareDrop   = { key = "RareDrop",   id = 0, price = 99,  display = "Rare Sock Drop", icon = "🎁", color = Color3.fromRGB(190, 90, 255),
		desc = "An Epic-or-better sock flies straight into your drawer.", minRank = 3 },
	Relock     = { key = "Relock",     id = 0, price = 15,  display = "Instant Re-lock", icon = "⚡", color = Color3.fromRGB(255, 120, 90),
		desc = "Slam your drawer right now - no cooldown." },
}

return StoreConfig
