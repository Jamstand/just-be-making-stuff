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
	look: { string }, -- signature features the Factory builds (see Factory.luau FEATURES)
	motion: string?, -- idle motion in a drawer: bob (default) | bounce | wiggle | wobble | hop | skate | shiver | float | spin
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
	{ id = "Tubolino",    name = "Tubolino Bianchino",  rarity = "Common", income = 1,  color = rgb(245, 245, 245), accent = rgb(90, 90, 200),   sound = "", look = { "sadstripe", "sadbrows" } },
	{ id = "AnkleBiter",  name = "Ankle Biter",         rarity = "Common", income = 2,  color = rgb(240, 200, 200), accent = rgb(255, 255, 255), sound = "", look = { "small", "fangs" }, motion = "bounce" },
	{ id = "CrustyCrew",  name = "Crusty Crew",         rarity = "Common", income = 3,  color = rgb(210, 190, 140), accent = rgb(150, 120, 70),  sound = "", look = { "crusty", "stiff" } },
	{ id = "GymGary",     name = "Gym Class Gary",      rarity = "Common", income = 5,  color = rgb(180, 220, 180), accent = rgb(230, 60, 60),   sound = "", look = { "sweatband", "damp" } },
	{ id = "PolkaDottie", name = "Polka Dottie",        rarity = "Common", income = 2,  color = rgb(71, 198, 192),  accent = rgb(255, 95, 162),  sound = "", look = { "polkadots", "hairbow" }, motion = "bounce" },
	{ id = "Pisolino",    name = "Pisolino Pigiamino",  rarity = "Common", income = 4,  color = rgb(157, 176, 240), accent = rgb(52, 64, 127),   sound = "", look = { "pajamas", "nightcap" } },
	{ id = "Bambino",     name = "Bambino Calzino",     rarity = "Common", income = 1,  color = rgb(255, 239, 176), accent = rgb(143, 208, 255), sound = "", look = { "small", "pacifier", "babycurl" }, motion = "wobble" },
	-- Rare
	{ id = "Argylo",      name = "Argylo Bargylo",      rarity = "Rare", income = 10, color = rgb(120, 80, 60),   accent = rgb(220, 190, 120), sound = "", look = { "argyle", "monocle" } },
	{ id = "ToeToe",      name = "Toe-Toe Wiggletto",   rarity = "Rare", income = 18, color = rgb(255, 160, 200), accent = rgb(255, 230, 240), sound = "", look = { "toes" }, motion = "wiggle" },
	{ id = "Sockrates",   name = "Sockrates",           rarity = "Rare", income = 28, color = rgb(235, 225, 200), accent = rgb(200, 200, 210), sound = "", look = { "beard", "toga", "thinking" } },
	{ id = "KneeHigh",    name = "Knee-High Kevin",     rarity = "Rare", income = 40, color = rgb(100, 140, 255), accent = rgb(255, 255, 255), sound = "", look = { "tall" }, motion = "wobble" },
	{ id = "Jingleo",     name = "Jingleo Bellini",     rarity = "Rare", income = 14, color = rgb(217, 58, 58),   accent = rgb(46, 139, 78),   sound = "", look = { "furcuff", "jinglebell" }, motion = "bounce" },
	{ id = "Ninjolino",   name = "Ninjolino Stealthini", rarity = "Rare", income = 22, color = rgb(42, 45, 69),   accent = rgb(224, 64, 58),   sound = "", look = { "ninjamask", "headband" } },
	{ id = "Sockbeard",   name = "Captain Sockbeard",   rarity = "Rare", income = 34, color = rgb(44, 76, 126),   accent = rgb(243, 231, 201), sound = "", look = { "sailorstripes", "tricorn", "eyepatch" }, motion = "wobble" },
	-- Epic
	{ id = "Slipperino",  name = "Slipperino Grippolini", rarity = "Epic", income = 75,  color = rgb(90, 200, 255),  accent = rgb(255, 255, 255), sound = "", look = { "gripdots" }, motion = "skate" },
	{ id = "Compressio",  name = "Compressio Stressio",   rarity = "Epic", income = 120, color = rgb(60, 60, 70),    accent = rgb(255, 80, 80),   sound = "", look = { "stress" }, motion = "shiver" },
	{ id = "Sockhopper",  name = "Sockhopper",            rarity = "Epic", income = 180, color = rgb(120, 230, 120), accent = rgb(255, 200, 60),  sound = "", look = { "pogo" }, motion = "hop" },
	{ id = "DJDryer",     name = "DJ Dryer Sheet",        rarity = "Epic", income = 250, color = rgb(230, 230, 250), accent = rgb(255, 0, 200),   sound = "", look = { "headphones", "sheet" }, motion = "spin" },
	{ id = "Spaghettino", name = "Chef Spaghettino",      rarity = "Epic", income = 100, color = rgb(251, 245, 232), accent = rgb(217, 68, 63),  sound = "", look = { "toque", "mustachio", "tricolor" } },
	{ id = "Sockula",     name = "Count Sockula",         rarity = "Epic", income = 210, color = rgb(211, 204, 227), accent = rgb(179, 32, 58),  sound = "", look = { "vampcape", "fangs" }, motion = "float" },
	-- Legendary
	{ id = "Socktopus",   name = "Socktopus",             rarity = "Legendary", income = 600,  color = rgb(200, 60, 200),  accent = rgb(255, 180, 255), sound = "", single = true, alwaysPaired = true, look = { "tentacles" } },
	{ id = "Sockington",  name = "Sir Sockington III",    rarity = "Legendary", income = 1200, color = rgb(200, 200, 210), accent = rgb(255, 215, 0),   sound = "", look = { "armor" } },
	{ id = "Stinkolino",  name = "Stinkolino Pestilini",  rarity = "Legendary", income = 2000, color = rgb(120, 160, 60),  accent = rgb(60, 80, 20),    sound = "", look = { "flies", "stinklines" } },
	{ id = "Merlino",     name = "Merlino Magnifico",     rarity = "Legendary", income = 900,  color = rgb(75, 79, 200),   accent = rgb(242, 193, 78),  sound = "", look = { "wizardhat", "stars" }, motion = "float" },
	{ id = "Sockstrong",  name = "Neil Sockstrong",       rarity = "Legendary", income = 1600, color = rgb(232, 236, 242), accent = rgb(255, 138, 61),  sound = "", look = { "spacehelmet", "jetpack" }, motion = "float" },
	-- Mythic
	{ id = "SockNess",    name = "The Sock Ness Monster", rarity = "Mythic", income = 6000,  color = rgb(40, 120, 90),   accent = rgb(120, 200, 160), sound = "", look = { "longneck" } },
	{ id = "Shockini",    name = "Static Shockini",       rarity = "Mythic", income = 20000, color = rgb(255, 255, 120), accent = rgb(120, 220, 255), sound = "", look = { "lightning" }, motion = "shiver" },
	{ id = "Dragonzola",  name = "Dragonzola",            rarity = "Mythic", income = 12000, color = rgb(242, 120, 46),  accent = rgb(255, 209, 92),  sound = "", look = { "dragonwings", "horns", "dragontail" }, motion = "hop" },
	-- Sock God
	{ id = "Lintlord",    name = "Lintlord",              rarity = "SockGod", income = 75000,  color = rgb(150, 150, 160), accent = rgb(255, 215, 0), sound = "", look = { "lintcrown", "lintbody" } },
	{ id = "Zillionaire", name = "Sockzillionaire",       rarity = "SockGod", income = 250000, color = rgb(255, 215, 0),   accent = rgb(20, 20, 20),  sound = "", look = { "tophat", "goldthread", "cashspray" } },
	{ id = "Toetankhamun", name = "King Toetankhamun",    rarity = "SockGod", income = 150000, color = rgb(234, 223, 198), accent = rgb(242, 193, 78), sound = "", look = { "nemes", "bandages", "pharaohbeard" } },
	-- Secret
	{ id = "LostSock",    name = "The Lost Sock",         rarity = "Secret", income = 1000000, color = rgb(30, 30, 40),   accent = rgb(200, 200, 255), sound = "", single = true, noMatch = true, maxPerServer = 1, announceSpawn = true, look = { "lost" }, motion = "float" },
	{ id = "PuppetSupreme", name = "Sock Puppet Supreme", rarity = "Secret", income = 1500000, color = rgb(255, 90, 60), accent = rgb(255, 255, 255), sound = "", look = { "puppet" }, motion = "bounce",
		banter = {
			"You're the left one? No YOU'RE the left one!",
			"We should start a podcast.",
			"I've been in the dryer. I've seen things.",
			"Who keeps eating all the lint?",
			"Best. Drawer. Ever.",
			"Psst... I think that player wants to steal us.",
		} },
	{ id = "Sockfather",  name = "The Sockfather",        rarity = "Secret", income = 2000000, color = rgb(60, 59, 71),   accent = rgb(211, 32, 63),   sound = "", announceSpawn = true, look = { "pinstripes", "fedora", "rose" } },
}

for _, t in ipairs(SockConfig.List) do
	SockConfig.ById[t.id] = t
end

return SockConfig
