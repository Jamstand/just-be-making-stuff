--[[
    Plays the Blender-made clips (Shared.AnimationData) on every fighter, on
    every client. Nothing is uploaded: each frame it samples the clips and
    writes Motor6D.Transform on the fighter's joints, so it works the same on
    a legend's VisualRig, an R15 avatar, or (roughly) an R6 avatar.

    Two layers per fighter:
      locomotion   Idle / Run / Jump / Fall / WallSlide, looped, crossfaded.
                   Your own fighter's state comes from FighterSim; everyone
                   else's is read from how their character moves.
      action       attacks (timed to the move's startup/active/recovery so the
                   swing lines up with the hitbox), dodges, hurt, throws.

    Clips are authored facing right with the weapon in the right (near) hand.
    When a fighter faces left the clip is mirrored and their weapon moves to
    the other hand, like Brawlhalla flipping its sprites, so the weapon is
    always on the camera's side.

    Fades: when a layer switches clips the new clip starts playing at once,
    and the difference between the old pose and the new clip's first frame
    is laid on top and shrunk to nothing over the fade. That difference is a
    fixed rotation per joint, so there is nothing to flip mid-fade (blending
    a frozen old pose toward a moving new one snaps when the new clip swings
    through the opposite rotation).

    Clip lookup: attacks try "<Legend>.<Weapon>.<Slot>", "<Weapon>.<Slot>",
    "Unarmed.<Slot>"; locomotion tries "<Weapon>.<State>", "Loco.<State>".
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AnimationData = require(Shared.AnimationData)
local Config = require(Shared.Config)
local Legends = require(Shared.Legends)
local Maps = require(Shared.Maps)
local Weapons = require(Shared.Weapons)
local WeaponModels = require(Shared.WeaponModels)
local Util = require(Shared.Util)

local FighterAnimator = {}

local JOINTS = AnimationData.Joints
local NJ = #JOINTS
local JOINT_INDEX = {}
for i, name in JOINTS do
	JOINT_INDEX[name] = i
end
local MIRROR = {}
for i, name in JOINTS do
	local other = name
	if string.sub(name, 1, 4) == "Left" then
		other = "Right" .. string.sub(name, 5)
	elseif string.sub(name, 1, 5) == "Right" then
		other = "Left" .. string.sub(name, 6)
	end
	MIRROR[i] = JOINT_INDEX[other]
end

local R6_JOINTS = {
	Root = { "HumanoidRootPart", "RootJoint" },
	Neck = { "Torso", "Neck" },
	RightShoulder = { "Torso", "Right Shoulder" },
	LeftShoulder = { "Torso", "Left Shoulder" },
	RightHip = { "Torso", "Right Hip" },
	LeftHip = { "Torso", "Left Hip" },
}
local R15_PART = {
	Root = "LowerTorso",
	Waist = "UpperTorso",
	Neck = "Head",
	RightShoulder = "RightUpperArm",
	RightElbow = "RightLowerArm",
	RightWrist = "RightHand",
	LeftShoulder = "LeftUpperArm",
	LeftElbow = "LeftLowerArm",
	LeftWrist = "LeftHand",
	RightHip = "RightUpperLeg",
	RightKnee = "RightLowerLeg",
	RightAnkle = "RightFoot",
	LeftHip = "LeftUpperLeg",
	LeftKnee = "LeftLowerLeg",
	LeftAnkle = "LeftFoot",
}

local LOCO_FADE = 0.12
local ACTION_FADE_IN = 0.05
local ACTION_FADE_OUT = 0.12
local RIG_HEIGHT = 6

local rigs = {} -- [model] = rig
local world = nil
local origin = Vector3.zero

-- Clips -------------------------------------------------------------------

local compiled = {}

local function compile(name)
	local cached = compiled[name]
	if cached ~= nil then
		return cached or nil
	end
	local raw = AnimationData.Clips[name]
	if not raw then
		compiled[name] = false
		return nil
	end
	local keys = {}
	for _, k in raw.Keys do
		local styleName, dirName = string.match(k.E, "^(%a+)%.?(%a*)$")
		local key = { t = k.T, cf = table.create(NJ), cfm = table.create(NJ) }
		if styleName == "Constant" then
			key.constant = true
		elseif styleName ~= "Linear" then
			key.style = Enum.EasingStyle[styleName]
			key.dir = Enum.EasingDirection[dirName ~= "" and dirName or "InOut"]
		end
		local r = k.R
		for i = 1, NJ do
			local o = (i - 1) * 3
			key.cf[i] = CFrame.Angles(math.rad(r[o + 1]), math.rad(r[o + 2]), math.rad(r[o + 3]))
		end
		for i = 1, NJ do
			local o = (MIRROR[i] - 1) * 3
			key.cfm[i] = CFrame.Angles(math.rad(r[o + 1]), -math.rad(r[o + 2]), -math.rad(r[o + 3]))
		end
		local off = k.O and Vector3.new(k.O[1], k.O[2], k.O[3]) or Vector3.zero
		key.off = off
		key.offm = Vector3.new(-off.X, off.Y, off.Z)
		table.insert(keys, key)
	end
	local clip = { name = name, phased = raw.Phased, loop = raw.Loop, length = raw.Length, keys = keys }
	compiled[name] = clip
	return clip
end

function FighterAnimator.hasClip(name)
	return compile(name) ~= nil
end

local function newPose()
	local cf = table.create(NJ)
	for i = 1, NJ do
		cf[i] = CFrame.identity
	end
	return { cf = cf, off = Vector3.zero }
end

local function copyPose(src, dst)
	for i = 1, NJ do
		dst.cf[i] = src.cf[i]
	end
	dst.off = src.off
end

local function sample(clip, t, mirror, out)
	local keys = clip.keys
	local n = #keys
	if clip.loop and clip.length > 0 then
		t = t % clip.length
	end
	local k0, k1 = keys[1], keys[1]
	if t >= keys[n].t then
		k0, k1 = keys[n], keys[n]
	elseif t > keys[1].t then
		for i = 1, n - 1 do
			if t < keys[i + 1].t then
				k0, k1 = keys[i], keys[i + 1]
				break
			end
		end
	end
	local a = 0
	if k0 ~= k1 then
		a = (t - k0.t) / math.max(k1.t - k0.t, 1e-6)
		if k0.constant then
			a = 0
		elseif k0.style then
			a = TweenService:GetValue(math.clamp(a, 0, 1), k0.style, k0.dir)
		end
	end
	local c0, c1 = mirror and k0.cfm or k0.cf, mirror and k1.cfm or k1.cf
	for i = 1, NJ do
		out.cf[i] = a == 0 and c0[i] or c0[i]:Lerp(c1[i], a)
	end
	local o0, o1 = mirror and k0.offm or k0.off, mirror and k1.offm or k1.off
	out.off = o0:Lerp(o1, a)
end

-- The difference between the pose showing now (`old`) and the pose a new
-- clip starts from (`fresh`): offset * fresh = old.
local function captureOffset(old, fresh, out)
	for i = 1, NJ do
		out.cf[i] = old.cf[i] * fresh.cf[i]:Inverse()
	end
	out.off = old.off - fresh.off
end

-- Lays `k` (1 = all, 0 = none) of an offset over the live pose. Eased so the
-- fade starts and ends without a kick.
local function applyOffset(offset, k, live, out)
	k = math.clamp(k, 0, 1)
	k = k * k * (3 - 2 * k)
	for i = 1, NJ do
		out.cf[i] = CFrame.identity:Lerp(offset.cf[i], k) * live.cf[i]
	end
	out.off = live.off + offset.off * k
end

-- Move phase (0-1 startup, 1-2 active, 2-3 recovery) at `t` seconds.
-- `p0` is how far the windup already got while charging: the startup
-- then plays from there, still taking the full startup time.
local function phaseAt(t, timing, p0)
	local s, a, r = timing.startup, timing.active, timing.recovery
	if t < s then
		p0 = p0 or 0
		return p0 + (1 - p0) * t / math.max(s, 1e-3)
	elseif t < s + a then
		return 1 + (t - s) / math.max(a, 1e-3)
	end
	return math.min(3, 2 + (t - s - a) / math.max(r, 1e-3))
end

-- Rigs ----------------------------------------------------------------------

local function findJoints(model)
	local joints = {}
	local rig = model.Name == "VisualRig" and model or model:FindFirstChild("VisualRig")
	local scale = 1
	if rig then
		scale = rig:GetAttribute("RigScale") or (Config.Art.FighterHeight / RIG_HEIGHT)
		for _, d in rig:GetDescendants() do
			if d:IsA("Motor6D") and JOINT_INDEX[d.Name] then
				joints[JOINT_INDEX[d.Name]] = d
			end
		end
		return joints, scale, rig
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.RigType == Enum.HumanoidRigType.R6 then
		for name, path in R6_JOINTS do
			local part = model:FindFirstChild(path[1])
			local motor = part and part:FindFirstChild(path[2])
			if motor and motor:IsA("Motor6D") then
				joints[JOINT_INDEX[name]] = motor
			end
		end
		scale = 5 / RIG_HEIGHT
	else
		for name, partName in R15_PART do
			local part = model:FindFirstChild(partName)
			local motor = part and part:FindFirstChild(name)
			if motor and motor:IsA("Motor6D") then
				joints[JOINT_INDEX[name]] = motor
			end
		end
		local feet = Util.feetOffset(model)
		scale = math.max(0.5, (feet + 2.2) / RIG_HEIGHT)
	end
	return joints, scale, nil
end

local function bindJoints(rig)
	local joints, scale, visual = findJoints(rig.model)
	rig.motors = {}
	for i, motor in joints do
		-- LegendRig builds C0 so each joint's frame is rig-aligned even when
		-- the imported parts are rotated, so clips apply directly. Avatar
		-- joints are expressed in the C0 frame and need converting.
		local rot = motor.C0.Rotation
		local plain = visual ~= nil or rot:FuzzyEq(CFrame.identity, 1e-4)
		rig.motors[i] = { motor = motor, rot = rot, inv = rot:Inverse(), plain = plain }
	end
	rig.scale = scale
	rig.visual = visual
	rig.boundTo = visual or rig.model
	local h = rig.model:FindFirstChild("SkyOutline")
	if h then
		h.Adornee = visual or rig.model
	end
end

local function outline(model)
	if not Config.Art.Outlines or model:FindFirstChild("SkyOutline") then
		return
	end
	local h = Instance.new("Highlight")
	h.Adornee = model:FindFirstChild("VisualRig") or model
	h.Name = "SkyOutline"
	h.FillTransparency = 1
	h.OutlineColor = Config.Art.OutlineColor
	h.OutlineTransparency = 0
	h.DepthMode = Enum.HighlightDepthMode.Occluded
	h.Parent = model
end

--[[
    Starts animating a fighter. opts:
      isMe      true for your own fighter (locomotion is set by MatchClient)
      preview   a menu preview (no physics; locomotion set by the caller)
      legend    legend id (else the model's "Legend" attribute)
]]
function FighterAnimator.track(model, opts)
	opts = opts or {}
	if rigs[model] then
		rigs[model].isMe = opts.isMe or rigs[model].isMe
		return rigs[model]
	end
	local rig = {
		model = model,
		isMe = opts.isMe == true,
		preview = opts.preview == true,
		legend = opts.legend,
		weapon = opts.weapon or "Unarmed",
		facing = 1,
		pose = newPose(),
		locoPose = newPose(),
		tmp = newPose(),
		snapshot = newPose(),
		loco = nil,
		locoFade = 0,
		locoOffset = newPose(),
		action = nil,
		actionFade = 0,
		actionOffset = newPose(),
		outFade = 0,
		outOffset = newPose(),
		stopUntil = 0,
		lastPos = nil,
		vel = Vector3.zero,
		airborneFor = 0,
		weaponHand = setmetatable({}, { __mode = "k" }),
		trailOn = false,
	}
	bindJoints(rig)
	rigs[model] = rig
	if not rig.preview then
		outline(model)
	end
	FighterAnimator.setLocomotion(model, "Idle")
	return rig
end

local function resetJoints(rig)
	for _, j in rig.motors do
		if j.motor.Parent then
			j.motor.Transform = CFrame.identity
		end
	end
end

function FighterAnimator.untrack(model)
	local rig = rigs[model]
	if not rig then
		return
	end
	rigs[model] = nil
	resetJoints(rig)
	local h = model:FindFirstChild("SkyOutline")
	if h then
		h:Destroy()
	end
end

function FighterAnimator.untrackAll()
	for model in rigs do
		FighterAnimator.untrack(model)
	end
end

local function legendOf(rig)
	return rig.legend or rig.model:GetAttribute("Legend") or "Avatar"
end

local function weaponOf(rig)
	local w = rig.model:GetAttribute("Weapon")
	if type(w) == "string" then
		return w
	end
	return rig.weapon or "Unarmed"
end

function FighterAnimator.setWeapon(model, weaponId)
	local rig = rigs[model]
	if rig then
		rig.weapon = weaponId
	end
end

-- Locomotion ------------------------------------------------------------------

local function locoClip(weapon, state)
	local prefix = (weapon == nil or weapon == "Unarmed") and "Loco" or weapon
	return compile(prefix .. "." .. state) or compile("Loco." .. state)
end

function FighterAnimator.setLocomotion(model, state, speed)
	local rig = rigs[model]
	if not rig then
		return
	end
	local weapon = weaponOf(rig)
	if rig.loco and rig.loco.state == state and rig.loco.weapon == weapon then
		rig.loco.speed = speed or 1
		return
	end
	local clip = locoClip(weapon, state)
	if not clip then
		return
	end
	if rig.loco then
		sample(clip, 0, rig.facing < 0, rig.tmp)
		captureOffset(rig.locoPose, rig.tmp, rig.locoOffset)
		rig.locoFade = LOCO_FADE
	else
		rig.locoFade = 0
	end
	rig.loco = { state = state, weapon = weapon, clip = clip, t = 0, speed = speed or 1 }
end

-- Infers someone else's locomotion from how their character moves.
local function inferLocomotion(rig, dt)
	local root = rig.model:FindFirstChild("HumanoidRootPart")
	if not root or dt <= 0 then
		return
	end
	local pos = root.Position
	if rig.lastPos then
		local v = (pos - rig.lastPos) / dt
		rig.vel = rig.vel:Lerp(v, math.min(1, dt * 18))
	end
	rig.lastPos = pos
	local feetY = pos.Y - Util.feetOffset(rig.model) - origin.Y
	local x = pos.X - origin.X
	local grounded = false
	if world then
		local ground = Maps.groundBelow(world, x, feetY + 0.3)
		grounded = ground ~= nil and feetY - ground < 0.35 and math.abs(rig.vel.Y) < 6
	end
	local landed = grounded and rig.airborneFor > 0.1
	rig.airborneFor = grounded and 0 or rig.airborneFor + dt
	local vx, vy = rig.vel.X, rig.vel.Y
	local state
	if grounded or rig.airborneFor < 0.06 then
		state = math.abs(vx) > 3 and "Run" or "Idle"
	elseif vy > 4 then
		state = "Jump"
	else
		state = "Fall"
	end
	FighterAnimator.setLocomotion(rig.model, state, state == "Run" and math.clamp(math.abs(vx) / 26, 0.6, 1.4) or 1)
	-- Landing ends a ground pound's active part early and cuts other air
	-- attacks short, like FighterSim does.
	local action = rig.action
	if grounded and action and action.kind == "Attack" then
		if action.endsOnLand and action.t > action.timing.startup + 0.05 then
			local s, a = action.timing.startup, action.timing.active
			if action.t < s + a then
				action.t = s + a
			end
		elseif landed and action.air then
			FighterAnimator.endAttack(rig.model)
		end
	end
end

-- Actions ------------------------------------------------------------------------

-- Blends the current pose back into the locomotion layer.
local function fadeOut(rig)
	captureOffset(rig.pose, rig.locoPose, rig.outOffset)
	rig.outFade = ACTION_FADE_OUT
end

local function startAction(rig, action)
	sample(action.clip, 0, rig.facing < 0, rig.tmp)
	captureOffset(rig.pose, rig.tmp, rig.actionOffset)
	rig.actionFade = ACTION_FADE_IN
	rig.outFade = 0
	rig.action = action
end

--[[
    An attack started. timing comes from the move (Legends.getAttack), so the
    clip's strike lines up with the hitbox whatever the legend's Dexterity.
]]
function FighterAnimator.playAttack(model, weaponId, slot, seq, charging)
	local rig = rigs[model]
	if not rig then
		return
	end
	local legend = legendOf(rig)
	local move = Legends.getAttack(legend, weaponId, slot)
	if not move then
		return
	end
	local clip = compile(move.AnimKey)
		or compile(Weapons.get(weaponId).Id .. "." .. slot)
		or compile("Unarmed." .. slot)
	if not clip then
		return
	end
	startAction(rig, {
		kind = "Attack",
		clip = clip,
		t = 0,
		seq = seq,
		timing = {
			startup = move.Startup,
			active = move.EndsOnLand and math.max(move.Active, 0.35) or move.Active,
			recovery = move.Recovery,
		},
		charging = charging == true,
		chargeLeft = (move.Charge or 0) + 0.3,
		chargeT = 0,
		p0 = 0,
		endsOnLand = move.EndsOnLand == true,
		air = move.Air == true,
	})
end

function FighterAnimator.releaseCharge(model, seq)
	local rig = rigs[model]
	local action = rig and rig.action
	if action and action.charging and (seq == nil or action.seq == seq) then
		action.charging = false
		action.t = 0
	end
end

-- An attack ended early (landing cut an air attack short): blend out.
function FighterAnimator.endAttack(model, seq)
	local rig = rigs[model]
	local action = rig and rig.action
	if action and action.kind == "Attack" and (seq == nil or action.seq == seq) then
		rig.action = nil
		fadeOut(rig)
	end
end

-- Ground pound (or any EndsOnLand move) landed: skip to its recovery.
function FighterAnimator.landed(model)
	local rig = rigs[model]
	local action = rig and rig.action
	if action and action.endsOnLand then
		local s, a = action.timing.startup, action.timing.active
		action.t = math.max(action.t, s + a)
	end
end

-- A non-attack clip ("Loco.Dodge", ...). `duration` stretches or holds it.
function FighterAnimator.playClip(model, name, duration, opts)
	local rig = rigs[model]
	if not rig then
		return
	end
	local clip = compile(name)
	if not clip then
		return
	end
	opts = opts or {}
	if opts.ifIdle and rig.action then
		return
	end
	startAction(rig, {
		kind = "Clip",
		clip = clip,
		t = 0,
		duration = duration or clip.length,
		rate = opts.stretch and duration and clip.length / math.max(duration, 1e-3) or 1,
		hold = opts.hold == true,
		loopFor = opts.loopFor,
	})
end

function FighterAnimator.dodge(model, kind)
	local clips = {
		Spot = "Loco.Dodge",
		AirSpot = "Loco.AirSpot",
		Air = "Loco.AirDodge",
		Chase = "Loco.Chase",
		Dash = "Loco.Dash",
	}
	local durations = {
		Spot = Config.Physics.SpotDodgeTime,
		AirSpot = Config.Physics.SpotDodgeTime,
		Air = Config.Physics.AirDodgeTime + 0.08,
		Chase = Config.Combat.ChaseDodgeTime + 0.06,
		Dash = Config.Physics.DashTime,
	}
	local name = clips[kind]
	if name then
		FighterAnimator.playClip(model, name, durations[kind], { stretch = kind ~= "Dash" })
	end
end

-- Hit: recoil (or tumble on big hits) for as long as the hitstun lasts.
function FighterAnimator.hurt(model, hitstun, force)
	local tumble = (force or 0) > 70
	if tumble then
		FighterAnimator.playClip(model, "Loco.Tumble", hitstun, { loopFor = hitstun })
	else
		FighterAnimator.playClip(model, "Loco.Hurt", math.max(hitstun, 0.2), { hold = true })
	end
end

function FighterAnimator.airJump(model)
	FighterAnimator.playClip(model, "Loco.AirJump", nil)
end

function FighterAnimator.land(model)
	FighterAnimator.playClip(model, "Loco.Land", nil, { ifIdle = true })
end

function FighterAnimator.throw(model)
	FighterAnimator.playClip(model, "Loco.Throw", nil)
end

function FighterAnimator.stopAction(model)
	local rig = rigs[model]
	if rig and rig.action then
		rig.action = nil
		fadeOut(rig)
	end
end

-- Freezes a fighter's animation briefly (hit-stop).
function FighterAnimator.hitstop(model, duration)
	local rig = rigs[model]
	if rig and duration and duration > 0 then
		rig.stopUntil = math.max(rig.stopUntil, os.clock() + duration)
	end
end

-- Weapon hand ----------------------------------------------------------------

local function otherSide(side)
	return side == "Right" and "Left" or "Right"
end

-- Facing left mirrors the animation, so one-handed weapons swap hands.
local function updateWeaponHands(rig, mirror)
	local folder = rig.model:FindFirstChild("EquippedWeapon")
	if not folder then
		return
	end
	local both = folder:FindFirstChild("Right") and folder:FindFirstChild("Left")
	for _, weapon in folder:GetChildren() do
		local grip = weapon:IsA("Model") and weapon.PrimaryPart
		local weld = grip and grip:FindFirstChild("GripWeld")
		if weld and (weapon.Name == "Right" or weapon.Name == "Left") then
			local want = (mirror and not both) and otherSide(weapon.Name) or weapon.Name
			if rig.weaponHand[weapon] ~= want then
				local hand = Util.getHand(rig.model, want)
				if hand then
					weld.Part0 = hand
					weld.C0 = WeaponModels.gripC0(hand)
					rig.weaponHand[weapon] = want
				end
			end
		end
	end
end

local function setTrails(model, on)
	local folder = model:FindFirstChild("EquippedWeapon")
	if not folder then
		return
	end
	for _, d in folder:GetDescendants() do
		if d:IsA("Trail") then
			d.Enabled = on
		end
	end
end

-- Per frame --------------------------------------------------------------------

local function write(rig)
	local scale = rig.scale
	local pose = rig.pose
	for i, j in rig.motors do
		local motor = j.motor
		local cf = pose.cf[i]
		if i == 1 then
			cf = CFrame.new(pose.off * scale) * cf
		end
		if not j.plain then
			cf = j.inv * cf * j.rot
		end
		motor.Transform = cf
	end
end

local function updateRig(rig, dt)
	local model = rig.model
	if not model.Parent then
		rigs[model] = nil
		return
	end
	if rig.boundTo and not rig.boundTo.Parent or (not rig.visual and model:FindFirstChild("VisualRig")) then
		resetJoints(rig)
		bindJoints(rig)
	end

	local root = model:FindFirstChild("HumanoidRootPart")
	if root and not rig.preview then
		rig.facing = root.CFrame.LookVector.X >= 0 and 1 or -1
	end
	local mirror = rig.facing < 0

	local stopped = os.clock() < rig.stopUntil
	local step = stopped and 0 or dt

	if not rig.isMe and not rig.preview then
		inferLocomotion(rig, dt)
	elseif rig.loco and rig.loco.weapon ~= weaponOf(rig) then
		FighterAnimator.setLocomotion(model, rig.loco.state, rig.loco.speed)
	end

	-- Locomotion layer
	local loco = rig.loco
	if loco then
		loco.t += step * loco.speed
		sample(loco.clip, loco.t, mirror, rig.locoPose)
		if rig.locoFade > 0 then
			rig.locoFade = math.max(0, rig.locoFade - step)
			applyOffset(rig.locoOffset, rig.locoFade / LOCO_FADE, rig.locoPose, rig.locoPose)
		end
	end

	-- Action layer
	local action = rig.action
	local out = rig.pose
	if action then
		local finished = false
		if action.kind == "Attack" then
			local timing = action.timing
			if action.charging then
				-- FighterSim's startup doesn't start until the charge is released,
				-- so wind up on a separate clock and keep the attack clock at 0.
				action.chargeLeft -= step
				action.chargeT += step
				action.p0 = math.min(0.92, action.chargeT / math.max(timing.startup, 1e-3))
				if action.chargeLeft <= 0 then
					action.charging = false
				end
			else
				action.t += step
			end
			local phase = phaseAt(action.t, timing, action.p0)
			sample(action.clip, phase, mirror, rig.tmp)
			if action.charging and action.p0 >= 0.9 then
				-- tremble while holding a charge
				rig.tmp.cf[1] = rig.tmp.cf[1] * CFrame.Angles(0, math.rad(math.sin(os.clock() * 55) * 2.5), 0)
			end
			finished = action.t >= timing.startup + timing.active + timing.recovery
		else
			action.t += step
			local t
			if action.loopFor then
				t = action.t % action.clip.length
				finished = action.t >= action.loopFor
			elseif action.hold then
				t = math.min(action.t, action.clip.length)
				finished = action.t >= action.duration
			else
				t = action.t * action.rate
				finished = t >= action.clip.length
			end
			sample(action.clip, t, mirror, rig.tmp)
		end
		if rig.actionFade > 0 then
			rig.actionFade = math.max(0, rig.actionFade - step)
			applyOffset(rig.actionOffset, rig.actionFade / ACTION_FADE_IN, rig.tmp, out)
		else
			copyPose(rig.tmp, out)
		end
		if finished then
			rig.action = nil
			fadeOut(rig)
		end
	elseif rig.outFade > 0 then
		rig.outFade = math.max(0, rig.outFade - step)
		applyOffset(rig.outOffset, rig.outFade / ACTION_FADE_OUT, rig.locoPose, out)
	else
		copyPose(rig.locoPose, out)
	end

	write(rig)
	updateWeaponHands(rig, mirror)

	-- Swing trails while an attack's blade is moving.
	local a = rig.action
	local swinging = false
	if a and a.kind == "Attack" and not a.charging then
		local timing = a.timing
		swinging = a.t > timing.startup * 0.5 and a.t < timing.startup + timing.active + 0.06
	end
	if swinging ~= rig.trailOn then
		rig.trailOn = swinging
		setTrails(model, swinging)
	end
end

-- Match lifecycle ----------------------------------------------------------------

function FighterAnimator.startMatch(mapId, arenaOrigin)
	world = Maps.getWorld(mapId)
	origin = arenaOrigin
end

function FighterAnimator.stopMatch()
	FighterAnimator.untrackAll()
	world = nil
end

function FighterAnimator.init()
	RunService.PreRender:Connect(function(dt)
		for _, rig in rigs do
			local ok, err = pcall(updateRig, rig, dt)
			if not ok then
				warn("[FighterAnimator]", err)
				rigs[rig.model] = nil
			end
		end
	end)
end

return FighterAnimator
