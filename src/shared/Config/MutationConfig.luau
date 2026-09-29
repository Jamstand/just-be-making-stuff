--!strict
-- MutationConfig: rolled once when a sock spawns. Total chance is about 10%; the rest is "None".
-- Phase 1 applies the income multiplier and a simple color/material look.
-- Phase 2 adds the full particle looks and event-boosted odds.
export type Mutation = {
	mult: number,
	chance: number,
	display: string,
	color: Color3?, -- overrides the sock's type color
	material: Enum.Material?,
}

local MutationConfig = {
	-- Roll order (rarest first so event boosts can scale a single entry).
	Order = { "LintGalaxy", "Rainbow", "GoldenThread", "Holey", "Glow", "Static", "Fuzzy" },
	Table = {} :: { [string]: Mutation },
}

MutationConfig.Table = {
	None         = { mult = 1,    chance = 0,      display = "" },
	Fuzzy        = { mult = 1.25, chance = 0.05,   display = "Fuzzy",         material = Enum.Material.Fabric },
	Static       = { mult = 1.5,  chance = 0.025,  display = "Static",        color = Color3.fromRGB(120, 200, 255), material = Enum.Material.Neon },
	Glow         = { mult = 2,    chance = 0.012,  display = "Glow",          material = Enum.Material.Neon },
	Holey        = { mult = 3,    chance = 0.008,  display = "Holey",         color = Color3.fromRGB(255, 250, 200) },
	GoldenThread = { mult = 4,    chance = 0.0035, display = "Golden Thread", color = Color3.fromRGB(255, 215, 0),   material = Enum.Material.Metal },
	Rainbow      = { mult = 6,    chance = 0.0013, display = "Rainbow",       color = Color3.fromRGB(255, 120, 220) },
	LintGalaxy   = { mult = 10,   chance = 0.0002, display = "Lint Galaxy",   color = Color3.fromRGB(70, 20, 130),   material = Enum.Material.Neon },
}

return MutationConfig
