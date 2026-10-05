--[[
    Legend visual rigs: a legend's imported meshes, jointed with Motor6Ds on
    the SkyRig skeleton (FighterRigs), mounted on top of a Roblox character
    whose own avatar is hidden. FighterAnimator moves the joints.

    Art comes from ReplicatedStorage.FighterModels.<Legend>: the model Studio's
    3D importer makes from art/export/fighters/<Legend>.fbx (see
    art/IMPORTING.md). Its three marker meshes tell us how the importer scaled
    and turned it, so any import settings work. If a legend's model isn't
    there, the fighter simply keeps their Roblox avatar.

    The rig ("VisualRig") contains RigRoot (an invisible part welded to the
    HumanoidRootPart, at the feet) and the 15 parts named like R15 parts, with
    Motor6Ds named like R15 joints (Root, Waist, Neck, RightShoulder, ...).
    Each hand has a "Grip" attachment where a held weapon goes.

    Skinned legends (the import has Bones) keep those 15 parts as invisible
    proxies, which carry the joints and the weapons, and add the imported
    skinned mesh as "Skin", welded to RigRoot. Its bones carry the joint
    names, and FighterAnimator copies each joint's motion onto its bone (plus
    the sway bones for capes, hair and tails).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(script.Parent.Config)
local FighterRigs = require(script.Parent.FighterRigs)
local Legends = require(script.Parent.Legends)
local Markers = require(script.Parent.Markers)
local Util = require(script.Parent.Util)

local LegendRig = {}

-- The SkyRig skeleton is authored at this height; rigs are scaled from it.
LegendRig.RigHeight = 6
-- Weapon frame (grip at origin, weapon along +Y, broad side along Z) to
-- the hand: weapon +Y points forward, broad side up.
LegendRig.GripRotation = CFrame.Angles(math.rad(-90), 0, 0)

local templates = {} -- [legendId] = template | false

local function vec(t)
	return Vector3.new(t[1], t[2], t[3])
end

local function partNames()
	local names = {}
	for _, joint in FighterRigs.Joints do
		table.insert(names, joint.Part1)
	end
	return names
end
local PART_NAMES = partNames()

local function modelsFolder()
	return ReplicatedStorage:FindFirstChild("FighterModels")
end

--[[
    Reads an imported model into rig space: for each part, its CFrame relative
    to the rig origin (feet center, facing -Z) and its size at 1 unit = 1
    stud of the original art. Returns nil if the model is missing or broken.
]]
function LegendRig.readModel(model, fighterName)
	local read = Markers.read(model, FighterRigs.MarkerDistance, -1)
	local byName = {}
	for _, p in read do
		byName[p.name] = p
	end
	local parts = {}
	for _, name in PART_NAMES do
		local p = byName[name]
		if not p then
			return nil, "missing part " .. name
		end
		parts[name] = p
	end

	-- Sanity check against the exported layout (catches a wrong import).
	local expected = fighterName and FighterRigs.Fighters[fighterName]
	if expected then
		local head = vec(expected.Parts.Head.Center)
		local off = (parts.Head.cframe.Position - head).Magnitude
		if off > 1 then
			warn(
				string.format(
					"[LegendRig] %s's imported head is %.1f studs from where the export put it",
					fighterName,
					off
				)
			)
		end
	end
	return { parts = parts }
end

function LegendRig.template(legendId)
	local cached = templates[legendId]
	if cached ~= nil then
		return cached or nil
	end
	local folder = modelsFolder()
	local model = folder and folder:FindFirstChild(legendId)
	local template, err = nil, nil
	if model and model:FindFirstChildWhichIsA("Bone", true) then
		template = { skinned = true, model = model }
	elseif model then
		template, err = LegendRig.readModel(model, legendId)
		if not template then
			warn("[LegendRig] can't use FighterModels." .. legendId .. ": " .. tostring(err))
		end
	end
	templates[legendId] = template or false
	return template
end

function LegendRig.hasArt(legendId)
	return not Legends.usesAvatar(legendId) and LegendRig.template(legendId) ~= nil
end

local function setupPart(part)
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = true
	if part:IsA("MeshPart") or part:IsA("Part") then
		part.Material = Enum.Material.SmoothPlastic
	end
	pcall(function()
		part.CollisionGroup = "Characters"
	end)
end

-- Invisible proxy parts for a skinned legend: boxes around what each joint
-- moves (from FighterRigs), so joints, weapons and effects have parts.
local function proxyParts(legendId)
	local info = FighterRigs.Fighters[legendId]
	local parts = {}
	for _, joint in FighterRigs.Joints do
		local box = info and info.Parts and info.Parts[joint.Part1]
		local center = box and vec(box.Center) or vec(joint.Pivot)
		local size = box and vec(box.Size) or Vector3.one * 0.3
		parts[joint.Part1] = {
			cframe = CFrame.new(center),
			size = Vector3.new(math.max(size.X, 0.1), math.max(size.Y, 0.1), math.max(size.Z, 0.1)),
		}
	end
	return parts
end

-- The imported skinned model, scaled and moved so its art origin sits on
-- the rig origin, its animation controllers removed (FighterAnimator drives
-- the bones) and its parts welded to RigRoot.
local function addSkin(rig, root, template, s)
	local skin = Instance.new("Model")
	skin.Name = "Skin"
	for _, child in template.model:GetChildren() do
		if not (child:IsA("Humanoid") or child:IsA("AnimationController") or child:IsA("LuaSourceContainer")) then
			child:Clone().Parent = skin
		end
	end
	for _, d in skin:GetDescendants() do
		if d:IsA("Animator") or d:IsA("AnimationController") then
			d:Destroy()
		end
	end
	local _, k = Markers.basis(skin, FighterRigs.MarkerDistance, -1)
	if math.abs(k - s) > 1e-4 then
		skin:ScaleTo(skin:GetScale() * s / k)
	end
	local basis = Markers.basis(skin, FighterRigs.MarkerDistance, -1)
	skin:PivotTo(root.CFrame * basis:ToObjectSpace(skin:GetPivot()))
	for _, d in skin:GetDescendants() do
		if d:IsA("BasePart") then
			if Markers.isMarker(d) then
				d:Destroy()
			else
				setupPart(d)
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = root
				weld.Part1 = d
				weld.Parent = d
			end
		end
	end
	skin.Parent = rig
	return skin
end

--[[
    Builds a VisualRig at the origin, `height` studs tall (feet at y = 0,
    facing -Z). Returns the model, or nil if the legend has no art.
]]
function LegendRig.build(legendId, height)
	local template = LegendRig.template(legendId)
	if not template then
		return nil
	end
	local s = (height or Config.Art.FighterHeight) / LegendRig.RigHeight

	local rig = Instance.new("Model")
	rig.Name = "VisualRig"
	rig:SetAttribute("Legend", legendId)
	rig:SetAttribute("RigScale", s)

	local root = Instance.new("Part")
	root.Name = "RigRoot"
	root.Size = Vector3.one * 0.2
	root.Transparency = 1
	setupPart(root)
	root.CFrame = CFrame.new()
	root.Parent = rig
	rig.PrimaryPart = root

	local rigCF = { RigRoot = CFrame.new() }
	local parts = { RigRoot = root }
	for name, info in template.skinned and proxyParts(legendId) or template.parts do
		local part
		if template.skinned then
			part = Instance.new("Part")
			part.Transparency = 1
		else
			part = Markers.cloneMesh(info.source)
		end
		part.Name = name
		part.Size = info.size * s
		local cf = CFrame.new(info.cframe.Position * s) * info.cframe.Rotation
		rigCF[name] = cf
		part.CFrame = cf
		setupPart(part)
		part.Parent = rig
		parts[name] = part
	end
	if template.skinned then
		rig:SetAttribute("Skinned", true)
		addSkin(rig, root, template, s)
	end

	for _, joint in FighterRigs.Joints do
		local pivot = CFrame.new(vec(joint.Pivot) * s)
		local motor = Instance.new("Motor6D")
		motor.Name = joint.Name
		motor.Part0 = parts[joint.Part0]
		motor.Part1 = parts[joint.Part1]
		motor.C0 = rigCF[joint.Part0]:Inverse() * pivot
		motor.C1 = rigCF[joint.Part1]:Inverse() * pivot
		motor.Parent = parts[joint.Part1]
	end

	for side, grip in FighterRigs.Grip do
		local hand = parts[grip.Part]
		local attachment = Instance.new("Attachment")
		attachment.Name = "Grip"
		attachment.CFrame = rigCF[grip.Part]:Inverse() * CFrame.new(vec(grip.Position) * s) * LegendRig.GripRotation
		attachment:SetAttribute("Side", side)
		attachment.Parent = hand
	end
	return rig
end

-- The avatar's own visuals: body parts (direct children of the character),
-- their decals (the face), and accessories. Weapons, the rig and anything
-- else the game adds are left alone.
local function isAvatarVisual(character, d)
	if d.Name == "HumanoidRootPart" then
		return false
	end
	if d:IsA("BasePart") then
		return d.Parent == character or d:FindFirstAncestorOfClass("Accessory") ~= nil
	end
	if d:IsA("Decal") then
		return d.Parent ~= nil and d.Parent.Parent == character
	end
	return false
end

local function hide(d)
	if d:GetAttribute("SkyTransparency") == nil then
		d:SetAttribute("SkyTransparency", d.Transparency)
	end
	d.Transparency = 1
end

local function hideAvatar(character)
	for _, d in character:GetDescendants() do
		if isAvatarVisual(character, d) then
			hide(d)
		end
	end
end

local function showAvatar(character)
	for _, d in character:GetDescendants() do
		local original = d:GetAttribute("SkyTransparency")
		if original ~= nil and (d:IsA("BasePart") or d:IsA("Decal")) then
			d.Transparency = original
			d:SetAttribute("SkyTransparency", nil)
		end
	end
end

-- Mounts the legend's rig on a character (server side; replicates to all).
-- Returns the rig, or nil when the fighter keeps their avatar.
function LegendRig.attach(character, legendId)
	LegendRig.detach(character)
	if Legends.usesAvatar(legendId) then
		return nil
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return nil
	end
	local rig = LegendRig.build(legendId, Config.Art.FighterHeight)
	if not rig then
		return nil
	end
	local feet = Util.feetOffset(character)
	local offset = CFrame.new(0, -feet, 0)
	rig:PivotTo(hrp.CFrame * offset)
	local weld = Instance.new("Weld")
	weld.Name = "RigMount"
	weld.Part0 = hrp
	weld.Part1 = rig.PrimaryPart
	weld.C0 = offset
	weld.Parent = rig.PrimaryPart
	rig.Parent = character
	hideAvatar(character)
	-- Accessories that finish loading later get hidden too.
	local conn
	conn = character.DescendantAdded:Connect(function(d)
		if not rig.Parent then
			conn:Disconnect()
			return
		end
		if isAvatarVisual(character, d) then
			hide(d)
		end
	end)
	character:SetAttribute("VisualRig", legendId)
	return rig
end

function LegendRig.detach(character)
	local existing = character:FindFirstChild("VisualRig")
	if existing then
		existing:Destroy()
		showAvatar(character)
	end
	character:SetAttribute("VisualRig", nil)
end

function LegendRig.get(character)
	return character and character:FindFirstChild("VisualRig")
end

return LegendRig
