--!strict
-- SockConfig: the roster. Every type exists as a LEFT and a RIGHT unit unless `single` is set.
-- `income` is the base income per second for ONE half (price = income x rarity payback).
-- `sound` is the signature SoundId slot ("" = silent until you paste an asset id in Phase 4).
export type SockType = {
	id: string,
	name: string,
	rarity: string,
	income: number,
	color: Color3,
	accent: Color3,
	sound: string,
	single: boolean?, -- one unit, no L/R (Socktopus, The Lost Sock)
	alwaysPaired: boolean?, -- counts as paired on its own (Socktopus)
	noMatch: boolean?, -- can never pair (The Lost Sock)
	maxPerServer: number?, -- cap on copies alive in one server
	announceSpawn: boolean?, -- whole server is told when it spawns
	banter: { string }?, -- Sock Puppet Supreme chat lines (Phase 2)
}

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

local SockConfig = {
	List = {} :: { SockType },
	ById = {} :: { [string]: SockType },
}

SockConfig.List = {
	-- Common
	{ id = "Tubolino",    name = "Tubolino Bianchino",  rarity = "Common", income = 1,  color = rgb(245, 245, 245), accent = rgb(90, 90, 200),   sound = "" },
	{ id = "AnkleBiter",  name = "Ankle Biter",         rarity = "Common", income = 2,  color = rgb(240, 200, 200), accent = rgb(255, 255, 255), sound = "" },
	{ id = "CrustyCrew",  name = "Crusty Crew",         rarity = "Common", income = 3,  color = rgb(210, 190, 140), accent = rgb(150, 120, 70),  sound = "" },
	{ id = "GymGary",     name = "Gym Class Gary",      rarity = "Common", income = 5,  color = rgb(180, 220, 180), accent = rgb(230, 60, 60),   sound = "" },
	-- Rare
	{ id = "Argylo",      name = "Argylo Bargylo",      rarity = "Rare", income = 10, color = rgb(120, 80, 60),   accent = rgb(220, 190, 120), sound = "" },
	{ id = "ToeToe",      name = "Toe-Toe Wiggletto",   rarity = "Rare", income = 18, color = rgb(255, 160, 200), accent = rgb(255, 230, 240), sound = "" },
	{ id = "Sockrates",   name = "Sockrates",           rarity = "Rare", income = 28, color = rgb(235, 225, 200), accent = rgb(200, 200, 210), sound = "" },
	{ id = "KneeHigh",    name = "Knee-High Kevin",     rarity = "Rare", income = 40, color = rgb(100, 140, 255), accent = rgb(255, 255, 255), sound = "" },
	-- Epic
	{ id = "Slipperino",  name = "Slipperino Grippolini", rarity = "Epic", income = 75,  color = rgb(90, 200, 255),  accent = rgb(255, 255, 255), sound = "" },
	{ id = "Compressio",  name = "Compressio Stressio",   rarity = "Epic", income = 120, color = rgb(60, 60, 70),    accent = rgb(255, 80, 80),   sound = "" },
	{ id = "Sockhopper",  name = "Sockhopper",            rarity = "Epic", income = 180, color = rgb(120, 230, 120), accent = rgb(255, 200, 60),  sound = "" },
	{ id = "DJDryer",     name = "DJ Dryer Sheet",        rarity = "Epic", income = 250, color = rgb(230, 230, 250), accent = rgb(255, 0, 200),   sound = "" },
	-- Legendary
	{ id = "Socktopus",   name = "Socktopus",             rarity = "Legendary", income = 600,  color = rgb(200, 60, 200),  accent = rgb(255, 180, 255), sound = "", single = true, alwaysPaired = true },
	{ id = "Sockington",  name = "Sir Sockington III",    rarity = "Legendary", income = 1200, color = rgb(200, 200, 210), accent = rgb(255, 215, 0),   sound = "" },
	{ id = "Stinkolino",  name = "Stinkolino Pestilini",  rarity = "Legendary", income = 2000, color = rgb(120, 160, 60),  accent = rgb(60, 80, 20),    sound = "" },
	-- Mythic
	{ id = "SockNess",    name = "The Sock Ness Monster", rarity = "Mythic", income = 6000,  color = rgb(40, 120, 90),   accent = rgb(120, 200, 160), sound = "" },
	{ id = "Shockini",    name = "Static Shockini",       rarity = "Mythic", income = 20000, color = rgb(255, 255, 120), accent = rgb(120, 220, 255), sound = "" },
	-- Sock God
	{ id = "Lintlord",    name = "Lintlord",              rarity = "SockGod", income = 75000,  color = rgb(150, 150, 160), accent = rgb(255, 215, 0), sound = "" },
	{ id = "Zillionaire", name = "Sockzillionaire",       rarity = "SockGod", income = 250000, color = rgb(255, 215, 0),   accent = rgb(20, 20, 20),  sound = "" },
	-- Secret
	{ id = "LostSock",    name = "The Lost Sock",         rarity = "Secret", income = 1000000, color = rgb(30, 30, 40),   accent = rgb(200, 200, 255), sound = "", single = true, noMatch = true, maxPerServer = 1, announceSpawn = true },
	{ id = "PuppetSupreme", name = "Sock Puppet Supreme", rarity = "Secret", income = 1500000, color = rgb(255, 90, 60), accent = rgb(255, 255, 255), sound = "",
		banter = {
			"You're the left one? No YOU'RE the left one!",
			"We should start a podcast.",
			"I've been in the dryer. I've seen things.",
			"Who keeps eating all the lint?",
			"Best. Drawer. Ever.",
			"Psst... I think that player wants to steal us.",
		} },
}

for _, t in ipairs(SockConfig.List) do
	SockConfig.ById[t.id] = t
end

return SockConfig
