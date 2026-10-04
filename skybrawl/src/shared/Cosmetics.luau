--[[
    Cosmetics sold for coins in the shop. Nothing here affects gameplay.

    Categories:
      WeaponColor   recolors every weapon you hold
      Trail         streak behind you during matches
      KOEffect      plays where your opponent gets KO'd
      Title         shown under your name
]]

local Cosmetics = {}

Cosmetics.Categories = { "WeaponColor", "Trail", "KOEffect", "Title" }

Cosmetics.CategoryNames = {
	WeaponColor = "Weapon Colors",
	Trail = "Trails",
	KOEffect = "KO Effects",
	Title = "Titles",
}

Cosmetics.Defaults = {
	WeaponColor = "wc_steel",
	Trail = "tr_none",
	KOEffect = "ko_burst",
	Title = "ti_rookie",
}

local items = {
	-- Weapon colors
	{ Id = "wc_steel", Category = "WeaponColor", Name = "Steel", Price = 0, Primary = Color3.fromRGB(205, 210, 220), Secondary = Color3.fromRGB(110, 72, 45), Material = "Metal" },
	{ Id = "wc_crimson", Category = "WeaponColor", Name = "Crimson", Price = 250, Primary = Color3.fromRGB(205, 45, 55), Secondary = Color3.fromRGB(45, 30, 30), Material = "Metal" },
	{ Id = "wc_emerald", Category = "WeaponColor", Name = "Emerald", Price = 250, Primary = Color3.fromRGB(50, 190, 110), Secondary = Color3.fromRGB(60, 45, 30), Material = "Metal" },
	{ Id = "wc_gilded", Category = "WeaponColor", Name = "Gilded", Price = 350, Primary = Color3.fromRGB(255, 200, 70), Secondary = Color3.fromRGB(90, 40, 30), Material = "Metal" },
	{ Id = "wc_frost", Category = "WeaponColor", Name = "Frost", Price = 450, Primary = Color3.fromRGB(160, 225, 255), Secondary = Color3.fromRGB(230, 245, 255), Material = "Glass", Glow = true },
	{ Id = "wc_shadow", Category = "WeaponColor", Name = "Shadow", Price = 550, Primary = Color3.fromRGB(45, 30, 70), Secondary = Color3.fromRGB(170, 100, 255), Material = "SmoothPlastic", Glow = true },
	{ Id = "wc_sunfire", Category = "WeaponColor", Name = "Sunfire", Price = 900, Primary = Color3.fromRGB(255, 150, 40), Secondary = Color3.fromRGB(255, 230, 120), Material = "Neon", Glow = true },

	-- Trails
	{ Id = "tr_none", Category = "Trail", Name = "None", Price = 0 },
	{ Id = "tr_sky", Category = "Trail", Name = "Sky Streak", Price = 300, Colors = { Color3.fromRGB(150, 215, 255), Color3.fromRGB(255, 255, 255) } },
	{ Id = "tr_ember", Category = "Trail", Name = "Ember", Price = 450, Colors = { Color3.fromRGB(255, 190, 70), Color3.fromRGB(255, 60, 40) } },
	{ Id = "tr_void", Category = "Trail", Name = "Void", Price = 600, Colors = { Color3.fromRGB(150, 80, 255), Color3.fromRGB(30, 10, 60) } },
	{ Id = "tr_rainbow", Category = "Trail", Name = "Rainbow", Price = 1200, Colors = {
		Color3.fromRGB(255, 80, 80), Color3.fromRGB(255, 200, 60), Color3.fromRGB(90, 230, 110),
		Color3.fromRGB(80, 170, 255), Color3.fromRGB(190, 100, 255),
	} },

	-- KO effects
	{ Id = "ko_burst", Category = "KOEffect", Name = "Burst", Price = 0, Style = "Burst", Color = Color3.fromRGB(255, 255, 255) },
	{ Id = "ko_petals", Category = "KOEffect", Name = "Petals", Price = 500, Style = "Petals", Color = Color3.fromRGB(255, 160, 210) },
	{ Id = "ko_fireworks", Category = "KOEffect", Name = "Fireworks", Price = 600, Style = "Fireworks", Color = Color3.fromRGB(255, 120, 200) },
	{ Id = "ko_shockwave", Category = "KOEffect", Name = "Shockwave", Price = 700, Style = "Shockwave", Color = Color3.fromRGB(255, 220, 90) },
	{ Id = "ko_thunder", Category = "KOEffect", Name = "Thunderclap", Price = 850, Style = "Lightning", Color = Color3.fromRGB(150, 205, 255) },

	-- Titles
	{ Id = "ti_rookie", Category = "Title", Name = "Rookie", Price = 0 },
	{ Id = "ti_brawler", Category = "Title", Name = "Brawler", Price = 200 },
	{ Id = "ti_skypirate", Category = "Title", Name = "Sky Pirate", Price = 400 },
	{ Id = "ti_edgeguard", Category = "Title", Name = "Edge Guard", Price = 500 },
	{ Id = "ti_champion", Category = "Title", Name = "Champion", Price = 1000 },
	{ Id = "ti_legend", Category = "Title", Name = "Legend", Price = 2500 },
}

Cosmetics.Items = items
Cosmetics.ById = {}
for index, item in items do
	item.Order = index
	Cosmetics.ById[item.Id] = item
end

function Cosmetics.get(id)
	return Cosmetics.ById[id]
end

function Cosmetics.inCategory(category)
	local list = {}
	for _, item in items do
		if item.Category == category then
			table.insert(list, item)
		end
	end
	return list
end

-- Equipped item for a category, falling back to the free default.
function Cosmetics.resolve(category, id)
	local item = id and Cosmetics.ById[id]
	if item and item.Category == category then
		return item
	end
	return Cosmetics.ById[Cosmetics.Defaults[category]]
end

return Cosmetics
