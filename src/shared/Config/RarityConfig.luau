--!strict
-- RarityConfig: spawn weights, income bands, payback (price = income x payback) and thief speed.
export type Tier = {
	rank: number,
	weight: number,
	income: { number }, -- {min, max} income per second for socks of this tier
	payback: number, -- seconds; price = income * payback
	carrySpeed: number, -- WalkSpeed multiplier while carrying a stolen sock of this tier
	color: Color3,
	display: string,
}

local RarityConfig = {
	Order = { "Common", "Rare", "Epic", "Legendary", "Mythic", "SockGod", "Secret" },
	Tiers = {} :: { [string]: Tier },
	AnnounceFromRank = 4, -- Legendary and up get server-wide announcements
}

RarityConfig.Tiers = {
	Common    = { rank = 1, weight = 55,   income = { 1, 5 },             payback = 20,  carrySpeed = 0.90, color = Color3.fromRGB(205, 205, 212), display = "Common" },
	Rare      = { rank = 2, weight = 26,   income = { 10, 40 },           payback = 40,  carrySpeed = 0.85, color = Color3.fromRGB(80, 170, 255),  display = "Rare" },
	Epic      = { rank = 3, weight = 12,   income = { 75, 250 },          payback = 60,  carrySpeed = 0.80, color = Color3.fromRGB(190, 90, 255),  display = "Epic" },
	Legendary = { rank = 4, weight = 5.3,  income = { 600, 2000 },        payback = 90,  carrySpeed = 0.75, color = Color3.fromRGB(255, 170, 40),  display = "Legendary" },
	Mythic    = { rank = 5, weight = 1.4,  income = { 6000, 20000 },      payback = 150, carrySpeed = 0.70, color = Color3.fromRGB(255, 70, 90),   display = "Mythic" },
	SockGod   = { rank = 6, weight = 0.29, income = { 75000, 250000 },    payback = 300, carrySpeed = 0.65, color = Color3.fromRGB(255, 230, 80),  display = "Sock God" },
	Secret    = { rank = 7, weight = 0.01, income = { 1000000, 2000000 }, payback = 600, carrySpeed = 0.60, color = Color3.fromRGB(40, 40, 60),    display = "SECRET" },
}

return RarityConfig
