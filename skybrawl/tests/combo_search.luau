--[[
    Lists the true combos the current frame data allows: for each weapon, every
    light opener x link (jump, chase dodge at several angles) x follow-up,
    tried at a few victim damage levels and spacings.

        lune run tests/combo_search            all weapons
        lune run tests/combo_search Sword 40   one weapon, one damage level
]]

local h = require("./harness")
local Duel = require("./duel")
local Weapons = h.require("Weapons")
local process = require("@lune/process")

local weaponFilter = process.args[1]
local damageFilter = tonumber(process.args[2] or "")

local OPENERS = {
	{ "NLight", { "Light" } },
	{ "SLight", { "Light", toward = 1 } },
	{ "DLight", { "Light", y = -1 } },
}
local LINKS = {
	{ "jump", { "Jump", toward = 0.6, when = Duel.afterActive } },
	{ "chase fwd", { "Dodge", toward = 1, when = Duel.afterActive } },
	{ "chase diag", { "Dodge", toward = 0.7, y = 0.7, when = Duel.afterActive } },
	{ "chase up", { "Dodge", toward = 0.3, y = 0.95, when = Duel.afterActive } },
}
local FOLLOWS = {
	{ "N", { "Light" } },
	{ "S", { "Light", toward = 1 } },
	{ "D", { "Light", y = -1 } },
	{ "Nsig", { "Heavy" } },
	{ "Ssig", { "Heavy", toward = 1 } },
}

local DAMAGES = damageFilter and { damageFilter } or { 0, 40, 80, 140 }

for _, weapon in { "Unarmed", "Sword", "Hammer", "Spear", "Gauntlets", "Scythe", "Bow" } do
	if weaponFilter == nil or weaponFilter == weapon then
		print(weapon)
		for _, damage in DAMAGES do
			local found = {}
			for _, opener in OPENERS do
				for _, link in LINKS do
					for _, follow in FOLLOWS do
						for _, gap in { 2.2, 3, 4 } do
							local hits = Duel.run({
								weapon = weapon,
								route = { opener[2], link[2], follow[2] },
								gap = gap,
								damage = damage,
							})
							if Duel.isTrue(hits, 2) then
								local name = string.format("%s > %s > %s", opener[1], link[1], Duel.describe({ hits[2] }))
								found[name] = true
							end
						end
					end
				end
			end
			local list = {}
			for name in found do
				table.insert(list, name)
			end
			table.sort(list)
			print(string.format("  %3d%%: %d  %s", damage, #list, table.concat(list, ", ")))
		end
	end
end
