--[[
    Checks the generated art data the game relies on. Run from the skybrawl
    folder with:  lune run tests/art

      - AnimationData has a clip for every weapon x attack slot, every legend
        signature, and every movement state FighterAnimator asks for, and
        every key is well formed
      - FighterRigs has the shared skeleton and every legend's parts
      - WeaponMeshes covers the base weapons and every legend's skins
      - every map with a Kit has its Blender script and export
      - the painted sky layers fill the camera's view in every camera look,
        sit behind the maps' 3D scenery, and the nearer ones slide more
      - the background renderer (art/blender/sky/vista.py) uses the same
        layers and parallax speeds as Config.Art.SkyLayers, and every map
        with a Kit has its painted background script and layer images
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local CFrame = roblox.CFrame
local Vector2 = roblox.Vector2
local Vector3 = roblox.Vector3

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

h.test("painted backgrounds match the game's sky layers", function()
	local Config = h.require("Config")
	-- vista.py renders each layer as wide as the game draws it, which
	-- depends on the layer's parallax speed.
	local source = fs.readFile(root .. "/art/blender/sky/vista.py")
	local block = string.match(source, "PARALLAX = (%b{})")
	h.expect(block, "vista.py has no PARALLAX table")
	local names = {}
	for _, spec in Config.Art.SkyLayers do
		local value = string.match(block, '"' .. spec.Name .. '":%s*([%d%.]+)')
		h.expect(value, "vista.py's PARALLAX has no " .. spec.Name)
		h.near(tonumber(value), spec.Parallax, 1e-9, spec.Name .. " parallax in vista.py")
		table.insert(names, spec.Name)
	end
	local layers = string.match(source, "LAYERS = (%b())")
	h.expect(layers == '("' .. table.concat(names, '", "') .. '")', "vista.py's LAYERS differ from Config.Art.SkyLayers")

	local scripts = { SkyShip = "sky_ship", VolcanicForge = "volcanic_forge", FrozenPeaks = "frozen_peaks", JungleTemple = "jungle_temple" }
	for id, map in Maps.List do
		if map.Kit then
			h.expect(fs.isFile(root .. "/art/blender/vistas/" .. scripts[map.Kit] .. ".py"), id .. " has no background script")
			for _, spec in Config.Art.SkyLayers do
				local file = root .. "/art/export/skies/painted/" .. id .. "_" .. spec.Name .. ".png"
				h.expect(fs.isFile(file), id .. "'s " .. spec.Name .. " layer not rendered")
			end
		end
	end
end)

-- The painted background (client SkyBackdrop), run against a fake camera.
h.test("sky layers fill the view, stay behind the scenery and parallax in order", function()
	local Config = h.require("Config")
	local layersSpec = Config.Art.SkyLayers
	-- The maps' 3D scenery reaches about 230 studs behind the lane.
	local SCENERY_DEPTH = 235
	for i, spec in layersSpec do
		h.expect(spec.Depth > SCENERY_DEPTH, spec.Name .. " is in front of the map scenery")
		h.expect(spec.Depth < Config.Art.SkyGradientDepth, spec.Name .. " is behind the gradient")
		if i > 1 then
			h.expect(spec.Depth < layersSpec[i - 1].Depth, "layers must go back to front")
			h.expect(spec.Parallax > layersSpec[i - 1].Parallax, "nearer layers must scroll faster")
		end
	end

	local camera = { FieldOfView = 40, ViewportSize = Vector2.new(1920, 1080), CFrame = CFrame.new() }
	local step = nil
	local parts = {}
	local shared = setmetatable({}, {
		__index = function(_, child)
			return { __module = child }
		end,
	})
	local globals = {
		game = {
			GetService = function(_, name)
				if name == "RunService" then
					return {
						RenderStepped = {
							Connect = function(_, fn)
								step = fn
								return {
									Disconnect = function()
										step = nil
									end,
								}
							end,
						},
					}
				end
				return {
					WaitForChild = function()
						return shared
					end,
				}
			end,
		},
		workspace = { CurrentCamera = camera },
		Instance = {
			new = function(class)
				local instance = { ClassName = class }
				function instance.Destroy(self)
					self.Destroyed = true
				end
				if class == "Part" then
					table.insert(parts, instance)
				end
				return instance
			end,
		},
		Enum = setmetatable({}, {
			__index = function(_, enum)
				return setmetatable({}, {
					__index = function(_, item)
						return enum .. "." .. item
					end,
				})
			end,
		}),
	}
	local SkyBackdrop = h.requireClient("SkyBackdrop", globals)

	local mapId = "SkyShip"
	local saved = Config.Art.SkyImages[mapId]
	Config.Art.SkyImages[mapId] = { Sky = "1", Landmarks = "2", Haze = "3" }
	local origin = Vector3.new(2500, 120, 0)
	SkyBackdrop.start(mapId, origin)
	Config.Art.SkyImages[mapId] = saved
	h.expect(#parts == #layersSpec and step ~= nil, "one plane per layer")

	local map = Maps.get(mapId)
	local bounds = map.Camera
	local center = Vector2.new((bounds[1] + bounds[3]) / 2, (bounds[2] + bounds[4]) / 2)
	local corners = { Vector2.new(-1, -1), Vector2.new(1, -1), Vector2.new(-1, 1), Vector2.new(1, 1) }

	for _, look in Config.Camera.Looks do
		for _, aspect in { 16 / 9, 4 / 3, 21 / 9 } do
			for _, h2 in { Config.Camera.MinViewHeight, 60, bounds[4] - bounds[2] } do
				for _, pan in { Vector2.zero, Vector2.new(1, 0), Vector2.new(-1, 0.5), Vector2.new(2.5, -1) } do
					-- Place the camera the way CameraController does.
					local fov = look.FOV
					local pitch = math.rad(look.Pitch or 0)
					local distance = (h2 / 2) / math.tan(math.rad(fov) / 2)
					local look2 = center + pan * Vector2.new(h2 / 2 * aspect, h2 / 2)
					local target = origin + Vector3.new(look2.X, look2.Y, 0)
					local position = target + Vector3.new(0, math.sin(pitch) * distance, math.cos(pitch) * distance)
					camera.FieldOfView = fov
					camera.ViewportSize = Vector2.new(1000 * aspect, 1000)
					camera.CFrame = CFrame.new(position) * CFrame.Angles(-pitch, 0, 0)
					step()

					local slides = {}
					for i, part in parts do
						local spec = layersSpec[i]
						local planeZ = origin.Z - spec.Depth
						local where = string.format("%s, %s look, aspect %.2f, view %d, pan (%.1f, %.1f)", spec.Name, look.Id, aspect, h2, pan.X, pan.Y)
						h.near(part.CFrame.Position.Z, planeZ, 1e-3, where .. ": depth")
						h.expect(part.Size.X <= 2048 and part.Size.Y <= 2048, where .. ": plane too big")
						local p = part.CFrame.Position
						local minX, maxX = math.huge, -math.huge
						for _, c in corners do
							local ty = math.tan(math.rad(fov) / 2)
							local dir = camera.CFrame:VectorToWorldSpace(Vector3.new(c.X * ty * aspect, c.Y * ty, -1))
							local hit = position + dir * ((planeZ - position.Z) / dir.Z)
							minX = math.min(minX, hit.X)
							maxX = math.max(maxX, hit.X)
							h.expect(math.abs(hit.X - p.X) <= part.Size.X / 2 + 1e-3, where .. ": view edge past the plane's side")
							h.expect(math.abs(hit.Y - p.Y) <= part.Size.Y / 2 + 1e-3, where .. ": view edge past the plane's top or bottom")
						end
						-- How far the plane has slid against the view, in half-views.
						slides[i] = ((minX + maxX) / 2 - p.X) / ((maxX - minX) / 2)
					end
					if pan.X > 0 then
						for i = 2, #slides do
							h.expect(slides[i] > slides[i - 1] and slides[1] > 0, string.format("%s look, pan %.1f: layer %d slides %.3f vs %.3f", look.Id, pan.X, i, slides[i], slides[i - 1]))
						end
					end
				end
			end
		end
	end
	SkyBackdrop.stop()
	h.expect(step == nil and parts[1].Destroyed, "stop removes the planes")
end)

h.finish()
