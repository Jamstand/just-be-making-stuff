--[[
    Checks the generated art data the game relies on. Run from the skybrawl
    folder with:  lune run tests/art

      - AnimationData has a clip for every weapon x attack slot, every legend
        signature, and every movement state FighterAnimator asks for, and
        every key is well formed
      - FighterRigs has the shared skeleton and every legend's parts
      - WeaponMeshes covers the base weapons and every legend's skins
      - every map with a Kit has its Blender script and export
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local h = require("./harness")

local Weapons = h.require("Weapons")
local Legends = h.require("Legends")
local Maps = h.require("Maps")
local FighterRigs = h.require("FighterRigs")
local WeaponMeshes = h.require("WeaponMeshes")

local root = process.cwd

-- AnimationData is a folder of modules; load its parts directly.
local folder = root .. "/src/shared/AnimationData/"
local clips = {}
local joints = nil
for _, file in fs.readDir(folder) do
	if string.sub(file, -5) == ".luau" and file ~= "init.luau" then
		local chunk = luau.load(fs.readFile(folder .. file), { debugName = file })
		for name, clip in chunk() do
			h.expect(clips[name] == nil, "duplicate clip " .. name)
			clips[name] = clip
		end
	end
end
do
	local init = fs.readFile(folder .. "init.luau")
	local list = string.match(init, "Joints = {(.-)}")
	joints = {}
	for name in string.gmatch(list or "", '"(%w+)"') do
		table.insert(joints, name)
	end
end

print("Animations")

h.test("the clip joint list matches the rig", function()
	h.expect(#joints == 15, "expected 15 joints, got " .. #joints)
	local rigJoints = {}
	for _, j in FighterRigs.Joints do
		rigJoints[j.Name] = true
	end
	for _, name in joints do
		h.expect(rigJoints[name], "AnimationData joint " .. name .. " is not in FighterRigs")
	end
end)

h.test("every weapon has a clip for every attack slot", function()
	for id in Weapons.List do
		for _, slot in Weapons.Slots do
			h.expect(clips[id .. "." .. slot], "missing clip " .. id .. "." .. slot)
		end
	end
end)

h.test("every signature has its own clip", function()
	for _, id in Legends.Order do
		for _, weapon in Legends.List[id].Weapons or {} do
			for _, slot in Legends.SignatureSlots do
				local key = Legends.getAttack(id, weapon, slot).AnimKey
				h.expect(clips[key], "missing clip " .. key)
			end
		end
	end
end)

h.test("movement clips exist for every state the animator plays", function()
	for _, state in { "Idle", "Run", "Jump", "Fall" } do
		h.expect(clips["Loco." .. state], "missing Loco." .. state)
		for _, weapon in Weapons.Order do
			h.expect(clips[weapon .. "." .. state], "missing " .. weapon .. "." .. state)
		end
	end
	for _, name in { "AirJump", "Land", "Dash", "Dodge", "AirSpot", "AirDodge", "Chase", "Hurt", "Tumble", "WallSlide", "Throw" } do
		h.expect(clips["Loco." .. name], "missing Loco." .. name)
	end
end)

h.test("every key is well formed and attacks span all three phases", function()
	local styles = {
		Linear = true, Constant = true, Quad = true, Cubic = true, Quart = true, Quint = true,
		Sine = true, Exponential = true, Circular = true,
	}
	for name, clip in clips do
		h.expect(#clip.Keys >= 2, name .. " has fewer than 2 keys")
		local last = -1
		for _, key in clip.Keys do
			h.expect(#key.R == 45, name .. " key has " .. #key.R .. " rotation values")
			h.expect(key.T >= last, name .. " keys out of order")
			last = key.T
			local style = string.match(key.E, "^(%a+)")
			h.expect(styles[style], name .. " has unknown ease " .. key.E)
			for _, v in key.R do
				h.expect(v == v and math.abs(v) <= 360, name .. " has a bad angle")
			end
		end
		if clip.Phased then
			h.expect(clip.Keys[1].T == 0 and last == 3, name .. " should run from phase 0 to 3")
		end
	end
end)

print("Rigs and meshes")

h.test("every legend has an exported rig with all 15 parts", function()
	for _, id in Legends.Order do
		if id ~= "Avatar" then
			local fighter = FighterRigs.Fighters[id]
			h.expect(fighter, "no FighterRigs entry for " .. id)
			for _, j in FighterRigs.Joints do
				h.expect(fighter.Parts[j.Part1], id .. " is missing " .. j.Part1)
			end
			h.expect(fighter.Height > 5 and fighter.Height < 7, id .. " height " .. fighter.Height)
			h.expect(fs.isFile(root .. "/art/export/fighters/" .. id .. ".fbx"), id .. ".fbx not exported")
		end
	end
end)

h.test("weapon meshes cover the base weapons and every legend skin", function()
	for _, id in Weapons.Order do
		h.expect(WeaponMeshes.Weapons[id], "no mesh for " .. id)
	end
	for _, id in Legends.Order do
		for _, weapon in Legends.List[id].Weapons or {} do
			local skin = Legends.weaponSkin(id, weapon)
			local mesh = WeaponMeshes.Weapons[skin]
			h.expect(mesh and mesh.Base == weapon, "no " .. weapon .. " skin for " .. id)
			h.expect(fs.isFile(root .. "/art/export/weapons/" .. skin .. ".fbx"), skin .. ".fbx not exported")
		end
	end
end)

h.test("every map kit has its Blender script, export and sky", function()
	local scripts = { SkyShip = "sky_ship", VolcanicForge = "volcanic_forge", FrozenPeaks = "frozen_peaks", JungleTemple = "jungle_temple" }
	for id, map in Maps.List do
		if map.Kit then
			h.expect(scripts[map.Kit], "unknown kit " .. map.Kit)
			h.expect(fs.isFile(root .. "/art/blender/maps/" .. scripts[map.Kit] .. ".py"), id .. " has no map script")
			h.expect(fs.isFile(root .. "/art/export/maps/" .. map.Kit .. ".fbx"), id .. " kit not exported")
			h.expect(fs.isFile(root .. "/art/export/skies/" .. id .. ".png"), id .. " sky not rendered")
		end
	end
end)

h.finish()
