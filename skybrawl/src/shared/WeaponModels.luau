--[[
    Weapon visuals. If the weapon's mesh has been imported into
    ReplicatedStorage.WeaponMeshes (art/export/weapons/<Id>.fbx, see
    art/IMPORTING.md), that is used: the legend's own skin ("KestrelSword")
    first, then the base mesh ("Sword"). Otherwise the weapon is built from
    plain Parts, so the game works with nothing imported.

    Weapon frame: the grip is at the origin, the weapon points along +Y,
    and its broad side lies along Z (so blades face the 2D camera when held).
    The fist closes on the grip: gauntlets wrap it, knuckles toward -Z (the
    end of the arm) and the cuff up the forearm (+Z).

    A legend whose rig has its own fists (Legends' BuiltInFists: Brann's
    mech arms) holds bare gauntlet models: just the grips, a glow on the
    rig's knuckles and swing trails across them, so no gauntlet mesh pokes
    through the rig's fists.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Weapons = require(script.Parent.Weapons)
local WeaponMeshes = require(script.Parent.WeaponMeshes)
local Markers = require(script.Parent.Markers)
local Cosmetics = require(script.Parent.Cosmetics)
local Legends = require(script.Parent.Legends)
local Util = require(script.Parent.Util)

local WeaponModels = {}

local WOOD = Enum.Material.Wood

local function materialOf(name)
	local ok, material = pcall(function()
		return Enum.Material[name]
	end)
	return ok and material or Enum.Material.Metal
end

local function newPart(name, size, cframe, color, material)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

local SHAPES = {}

SHAPES.Sword = function(add, primary, secondary, mat)
	add("Handle", Vector3.new(0.28, 1.2, 0.28), CFrame.new(0, 0.1, 0), secondary, WOOD)
	add("Pommel", Vector3.new(0.4, 0.3, 0.4), CFrame.new(0, -0.55, 0), primary, mat)
	add("Guard", Vector3.new(0.35, 0.25, 1.5), CFrame.new(0, 0.75, 0), primary, mat)
	add("Blade", Vector3.new(0.16, 3.8, 0.6), CFrame.new(0, 2.8, 0), primary, mat, true)
	add("Tip", Vector3.new(0.16, 0.4, 0.3), CFrame.new(0, 4.85, 0), primary, mat, true)
	return Vector3.new(0, 1, 0), Vector3.new(0, 4.8, 0)
end

SHAPES.Hammer = function(add, primary, secondary, mat)
	add("Handle", Vector3.new(0.32, 4.4, 0.32), CFrame.new(0, 1.4, 0), secondary, WOOD)
	add("Head", Vector3.new(1.4, 1.6, 3.0), CFrame.new(0, 3.7, 0), primary, mat, true)
	add("FaceA", Vector3.new(1.5, 1.2, 0.3), CFrame.new(0, 3.7, 1.45), secondary, mat)
	add("FaceB", Vector3.new(1.5, 1.2, 0.3), CFrame.new(0, 3.7, -1.45), secondary, mat)
	return Vector3.new(0, 2.5, 0), Vector3.new(0, 4.4, 0)
end

SHAPES.Spear = function(add, primary, secondary, mat)
	add("Shaft", Vector3.new(0.24, 7.2, 0.24), CFrame.new(0, 2.4, 0), secondary, WOOD)
	add("Collar", Vector3.new(0.36, 0.3, 0.36), CFrame.new(0, 5.9, 0), primary, mat)
	add("Tip", Vector3.new(0.16, 1.6, 0.7), CFrame.new(0, 6.8, 0), primary, mat, true)
	add("Butt", Vector3.new(0.3, 0.3, 0.3), CFrame.new(0, -1.2, 0), primary, mat)
	return Vector3.new(0, 4, 0), Vector3.new(0, 7.5, 0)
end

SHAPES.Gauntlets = function(add, primary, secondary, mat)
	add("Fist", Vector3.new(1.42, 1.42, 0.72), CFrame.new(0, 0, -0.03), primary, mat, true)
	add("Cuff", Vector3.new(1.4, 1.4, 0.32), CFrame.new(0, 0, 0.48), secondary, mat)
	for i, y in { -0.35, 0, 0.35 } do
		add("Spike" .. i, Vector3.new(0.25, 0.25, 0.4), CFrame.new(0, y, -0.52), primary, mat, true)
	end
	return Vector3.new(0, -0.45, -0.42), Vector3.new(0, 0.45, -0.42)
end

SHAPES.Scythe = function(add, primary, secondary, mat)
	add("Shaft", Vector3.new(0.24, 6.4, 0.24), CFrame.new(0, 2.2, 0), secondary, WOOD)
	add("Collar", Vector3.new(0.34, 0.4, 0.34), CFrame.new(0, 5.3, 0), primary, mat)
	add("Blade", Vector3.new(0.14, 0.7, 3.4), CFrame.new(0, 5.1, -1.6), primary, mat, true)
	add(
		"BladeTip",
		Vector3.new(0.14, 0.5, 1.2),
		CFrame.new(0, 4.7, -3.4) * CFrame.Angles(math.rad(-35), 0, 0),
		primary,
		mat,
		true
	)
	return Vector3.new(0, 5, -0.5), Vector3.new(0, 5, -3.4)
end

SHAPES.Bow = function(add, primary, secondary, mat)
	add("Grip", Vector3.new(0.3, 0.3, 0.9), CFrame.new(0, 0, 0), secondary, WOOD)
	add(
		"UpperLimb",
		Vector3.new(0.22, 0.25, 2.2),
		CFrame.new(0, -0.35, 1.25) * CFrame.Angles(math.rad(20), 0, 0),
		primary,
		mat,
		true
	)
	add(
		"LowerLimb",
		Vector3.new(0.22, 0.25, 2.2),
		CFrame.new(0, -0.35, -1.25) * CFrame.Angles(math.rad(-20), 0, 0),
		primary,
		mat,
		true
	)
	add(
		"String",
		Vector3.new(0.05, 0.05, 4.5),
		CFrame.new(0, -0.72, 0),
		Color3.fromRGB(240, 240, 230),
		Enum.Material.SmoothPlastic
	)
	return Vector3.new(0, 0, -1), Vector3.new(0, 0, 1)
end

-- Glow colour for skins' Neon parts, by legend (skin ids start with it).
local GLOW = {
	Kestrel = Color3.fromRGB(110, 230, 235),
	Brann = Color3.fromRGB(255, 140, 40),
	Yuki = Color3.fromRGB(150, 230, 255),
	Moss = Color3.fromRGB(110, 255, 120),
	Vex = Color3.fromRGB(190, 110, 255),
	Sol = Color3.fromRGB(255, 210, 90),
}

-- How far a legend's built-in fists reach past the wrist (Brann's mech
-- fists, art/blender/fighters/brann.py: 0.61 R6 studs, at his in-game
-- scale). Bare models put their trail and knuckle glow there.
local BUILT_IN_KNUCKLES = -0.65

local meshTemplates = {} -- [id] = template | false

local function vec(t)
	return Vector3.new(t[1], t[2], t[3])
end

-- Reads an imported weapon model into the weapon frame using its markers.
local function meshTemplate(id)
	local cached = meshTemplates[id]
	if cached ~= nil then
		return cached or nil
	end
	local folder = ReplicatedStorage:FindFirstChild("WeaponMeshes")
	local model = folder and folder:FindFirstChild(id)
	local info = WeaponMeshes.Weapons[id]
	local template = nil
	if model and info then
		local parts = Markers.read(model, WeaponMeshes.MarkerDistance, -1)
		for _, p in parts do
			p.glow = p.name == "Glow"
		end
		if #parts > 0 then
			template = { parts = parts, info = info }
		else
			warn("[WeaponModels] WeaponMeshes." .. id .. " has no meshes")
		end
	end
	meshTemplates[id] = template or false
	return template
end

function WeaponModels.hasMesh(id)
	return meshTemplate(id) ~= nil
end

local function legendOf(skinId)
	for legend in GLOW do
		if string.sub(skinId, 1, #legend) == legend then
			return legend
		end
	end
	return nil
end

--[[
    Returns a Model whose PrimaryPart ("Grip") sits at the origin. The other
    parts are welded to it, so moving the grip moves the whole weapon.
    `skinId` picks a legend's mesh ("KestrelSword") when it's imported.
    `bare` builds only the grip, a knuckle glow and the swing trail, for a
    rig's built-in fists (see bareFor).
]]
function WeaponModels.build(weaponId, colorId, skinId, bare)
	local scheme = Cosmetics.resolve("WeaponColor", colorId)
	local shape = SHAPES[weaponId]
	assert(shape, "no model for weapon " .. tostring(weaponId))

	local model = Instance.new("Model")
	model.Name = weaponId

	local grip =
		newPart("Grip", Vector3.new(0.2, 0.2, 0.2), CFrame.new(), Color3.new(1, 1, 1), Enum.Material.SmoothPlastic)
	grip.Transparency = 1
	grip.Parent = model
	model.PrimaryPart = grip

	local primary = scheme.Primary
	local secondary = scheme.Secondary
	local mat = materialOf(scheme.Material)

	local function add(name, size, cframe, color, material, glows)
		if bare then
			return nil
		end
		local part = newPart(name, size, cframe, color, material)
		if glows and scheme.Glow and material ~= Enum.Material.Neon then
			part.Reflectance = 0.15
		end
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = grip
		weld.Part1 = part
		weld.Parent = part
		part.Parent = model
		return part
	end

	local trailBase, trailTip
	local template = (skinId and meshTemplate(skinId)) or meshTemplate(weaponId)
	if template then
		local glowColor = GLOW[legendOf(skinId or "") or ""] or primary
		local parts = if bare then {} else template.parts
		for _, p in parts do
			local part = Markers.cloneMesh(p.source)
			part.Size = p.size
			part.CFrame = p.cframe
			part.Anchored = false
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.Massless = true
			part.CastShadow = false
			if p.glow then
				Markers.makeGlow(part)
				part.Material = Enum.Material.Neon
				part.Color = glowColor
			else
				part.Material = Enum.Material.SmoothPlastic
			end
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = grip
			weld.Part1 = part
			weld.Parent = part
			part.Parent = model
		end
		trailBase, trailTip = vec(template.info.Trail[1]), vec(template.info.Trail[2])
	else
		trailBase, trailTip = shape(add, primary, secondary, mat)
	end

	if bare then
		-- the rig's fists light up while it holds gauntlets, and swing
		-- trails run across its own knuckles
		trailBase = Vector3.new(trailBase.X, trailBase.Y, BUILT_IN_KNUCKLES)
		trailTip = Vector3.new(trailTip.X, trailTip.Y, BUILT_IN_KNUCKLES)
		local knuckles = Instance.new("Attachment")
		knuckles.Name = "Knuckles"
		knuckles.Position = Vector3.new(0, 0, BUILT_IN_KNUCKLES)
		knuckles.Parent = grip
		local light = Instance.new("PointLight")
		light.Color = GLOW[legendOf(skinId or "") or ""] or primary
		light.Range = 5
		light.Brightness = 1.5
		light.Parent = knuckles
	elseif scheme.Glow then
		local light = Instance.new("PointLight")
		light.Color = primary
		light.Range = 8
		light.Brightness = 1.2
		light.Parent = grip
	end

	-- Swing trail, toggled locally on each client while attacking.
	local a0 = Instance.new("Attachment")
	a0.Name = "TrailBase"
	a0.Position = trailBase
	a0.Parent = grip
	local a1 = Instance.new("Attachment")
	a1.Name = "TrailTip"
	a1.Position = trailTip
	a1.Parent = grip
	local trail = Instance.new("Trail")
	trail.Name = "SwingTrail"
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Lifetime = 0.16
	trail.MinLength = 0.05
	trail.FaceCamera = true
	trail.LightEmission = 0.6
	trail.Color = ColorSequence.new(primary:Lerp(Color3.new(1, 1, 1), 0.5))
	trail.Transparency = NumberSequence.new(0.25, 1)
	trail.Enabled = false
	trail.Parent = grip

	return model
end

-- Where the grip sits in a hand without a "Grip" attachment. Weapons are
-- fitted to a classic blocky fist gripped at its centre, 0.23 studs above
-- the end of the arm (as the legend rigs grip, art/blender/sky/avatar.py).
local FIST_CENTER = 0.23

local function handOffset(hand)
	if hand.Name == "RightHand" or hand.Name == "LeftHand" then
		-- an R15 hand is the end of the fist; its centre is close enough
		return Vector3.zero
	end
	-- R6 arms are 2 studs long; the fist is at the bottom.
	return Vector3.new(0, -hand.Size.Y / 2 + FIST_CENTER, 0)
end

-- Grip orientation relative to the hand: weapon +Y points forward along the
-- hand's look direction, broad side up.
local GRIP_ROTATION = CFrame.Angles(math.rad(-90), 0, 0)

-- Where a weapon's grip sits relative to a hand part.
function WeaponModels.gripC0(hand)
	local grip = hand:FindFirstChild("Grip")
	if grip and grip:IsA("Attachment") then
		return grip.CFrame
	end
	return CFrame.new(handOffset(hand)) * GRIP_ROTATION
end

function WeaponModels.detach(character)
	local existing = character:FindFirstChild("EquippedWeapon")
	if existing then
		existing:Destroy()
	end
end

-- Whether `model` (a fighter, or a legend's rig itself) holding `weaponId`
-- gets bare models: gauntlets on a legend's own rig when that rig has
-- built-in fists. Fighters in their own avatar's look have no rig.
function WeaponModels.bareFor(model, weaponId)
	local rig = if model.Name == "VisualRig" then model else model:FindFirstChild("VisualRig")
	local legend = rig and Legends.List[rig:GetAttribute("Legend") or ""]
	return weaponId == "Gauntlets" and legend ~= nil and legend.BuiltInFists == true
end

-- Welds a weapon to the character's hand(s). Returns the folder. Each
-- weapon model is named after the hand it belongs in ("Right"/"Left"); the
-- client may move it to the other hand while the fighter faces left (see
-- FighterAnimator), using the "GripWeld".
function WeaponModels.attach(character, weaponId, colorId, skinId)
	WeaponModels.detach(character)
	if not Weapons.isWeapon(weaponId) then
		return nil
	end
	local weapon = Weapons.get(weaponId)
	local sides = weapon.Hand == "Both" and { "Right", "Left" } or { weapon.Hand }
	local bare = WeaponModels.bareFor(character, weaponId)

	local folder = Instance.new("Folder")
	folder.Name = "EquippedWeapon"
	for _, side in sides do
		local hand = Util.getHand(character, side)
		if hand then
			local model = WeaponModels.build(weaponId, colorId, skinId, bare)
			model.Name = side
			local c0 = WeaponModels.gripC0(hand)
			model:PivotTo(hand.CFrame * c0)
			local weld = Instance.new("Weld")
			weld.Name = "GripWeld"
			weld.Part0 = hand
			weld.Part1 = model.PrimaryPart
			weld.C0 = c0
			weld.Parent = model.PrimaryPart
			model.Parent = folder
		end
	end
	folder.Parent = character
	return folder
end

-- Turns the weapon on its side so the broad face points at the 2D camera.
WeaponModels.DisplayRotation = CFrame.Angles(0, 0, math.rad(-45)) * CFrame.Angles(0, math.rad(90), 0)

-- An anchored, glowing copy used for weapons lying on the stage.
function WeaponModels.buildPickup(weaponId)
	local model = WeaponModels.build(weaponId, nil, nil)
	model.PrimaryPart.Anchored = true
	local weapon = Weapons.get(weaponId)

	local light = Instance.new("PointLight")
	light.Color = weapon.Color
	light.Range = 10
	light.Brightness = 2
	light.Parent = model.PrimaryPart

	local sparkle = Instance.new("ParticleEmitter")
	sparkle.Color = ColorSequence.new(weapon.Color)
	sparkle.LightEmission = 1
	sparkle.Size = NumberSequence.new(0.35, 0)
	sparkle.Lifetime = NumberRange.new(0.4, 0.8)
	sparkle.Rate = 12
	sparkle.Speed = NumberRange.new(1, 3)
	sparkle.SpreadAngle = Vector2.new(180, 180)
	sparkle.Parent = model.PrimaryPart

	return model
end

return WeaponModels
