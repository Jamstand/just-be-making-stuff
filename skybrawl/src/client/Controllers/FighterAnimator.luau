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

    In-between frames: attack clips are authored in move phases, so a fast
    move would play their big swings in under a frame and the arm would
    teleport. Each attack is re-timed for its real frame data (retime) so no
    joint turns faster than MAX_TURN: the wind-up is shortened and the swing
    spreads over the last startup frames and into the active frames, the way
    a Brawlhalla slash reads. Keys stay inside the phase they were authored
    in, so the strike still lands while the hitbox is out.

    Fades: when a layer switches clips the new clip starts playing at once,
    and the difference between the old pose and the new clip's first frame
    is laid on top and shrunk to nothing over the fade. That difference is a
    fixed rotation per joint, so there is nothing to flip mid-fade (blending
    a frozen old pose toward a moving new one snaps when the new clip swings
    through the opposite rotation). Fades last longer when the pose has
    further to go, so they never turn a joint faster than MAX_TURN either.

    Clip lookup: attacks try "<Legend>.<Weapon>.<Slot>", "<Weapon>.<Slot>",
    "Unarmed.<Slot>"; locomotion tries "<Weapon>.<State>", "Loco.<State>".

    Skinned legends: the joints still drive invisible proxy parts (which hold
    the weapons), and each joint's transform is copied onto the skin's bone
    of the same name, turned into the bone's own axes. Sway bones (capes,
    hair, tails) hang from a joint and follow it on damped springs, within a
    swing limit, and capes never swing through the body.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AnimationData = require(Shared.AnimationData)
local Config = require(Shared.Config)
local FighterRigs = require(Shared.FighterRigs)
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
local MAX_FADE = 0.2
-- Fastest a joint may turn: 55 degrees a frame at 60 fps.
local MAX_TURN = math.rad(55 * 60)
local RIG_HEIGHT = 6
-- Sway bones: gravity pulls their tips a little below the rest pose.
local SWAY_GRAVITY = Vector3.new(0, -30, 0)
-- Cloth hanging from the hips or waist (aprons, tabards, capes) stays this
-- far from the line through each hip and knee, so raised knees push it
-- aside instead of poking through.
local THIGH_RADIUS = 0.38

-- The SkyRig skeleton, for following joints in world space (sway bones).
local JOINT_PIVOT = {} -- [joint index] = rig-space pivot (unscaled)
local JOINT_PARENT = {} -- [joint index] = parent joint index
local JOINT_ORDER = {} -- parents first
do
	local jointOfPart = {}
	for _, j in FighterRigs.Joints do
		jointOfPart[j.Part1] = j.Name
	end
	for _, j in FighterRigs.Joints do
		local i = JOINT_INDEX[j.Name]
		if i then
			JOINT_PIVOT[i] = Vector3.new(j.Pivot[1], j.Pivot[2], j.Pivot[3])
			local parent = jointOfPart[j.Part0]
			JOINT_PARENT[i] = parent and JOINT_INDEX[parent] or nil
			table.insert(JOINT_ORDER, i)
		end
	end
end

local LEGS = {
	{ JOINT_INDEX.LeftHip, JOINT_INDEX.LeftKnee },
	{ JOINT_INDEX.RightHip, JOINT_INDEX.RightKnee },
}

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

-- How much faster than average an ease moves at its fastest.
local PEAK =
	{ Linear = 1, Sine = math.pi / 2, Quad = 2, Cubic = 3, Quart = 4, Quint = 5, Exponential = 7, Circular = 4 }

local function easePeak(key)
	if key.constant then
		return 1
	end
	return key.style and PEAK[key.style.Name] or 1
end

-- How far a rotation turns, the short way round (radians).
local function turnOf(cf)
	local _, angle = cf:ToAxisAngle()
	angle = math.abs(angle) % (2 * math.pi)
	return angle > math.pi and 2 * math.pi - angle or angle
end

-- The biggest joint turn (radians) between two poses.
local function maxTurn(a, b)
	local worst = 0
	for i = 1, NJ do
		local angle = turnOf(a[i]:Inverse() * b[i])
		if angle > worst then
			worst = angle
		end
	end
	return worst
end

local retimed = {}

-- A clip's spans: { { clip time, seconds }, ... } back to back from 0. An
-- attack has three (startup, active, recovery, one phase each); a timed
-- clip has one.
local function phaseSpans(timing)
	return { { 1, timing.startup }, { 1, timing.active }, { 1, timing.recovery } }
end

-- Clip time -> seconds for a set of spans.
local function toSeconds(spans, p)
	local t = 0
	for _, span in spans do
		local len, secs = span[1], span[2]
		if p <= len then
			return t + p / len * secs
		end
		p -= len
		t += secs
	end
	return t
end

--[[
    A clip re-timed to play in `spans` so no joint turns faster than
    MAX_TURN. The result's key times are in seconds. Each key may slide
    within the span it was authored in (an attack's startup, active or
    recovery), and keys move apart where a segment is too fast for its time,
    taking the time from slower segments next to it. If a span is simply too
    short for what's in it (a full spin inside 3 active frames), its keys may
    spill into the next span rather than snap. A Constant key (hold, then
    jump to the next pose) gets a short ramp before the jump instead.
]]
local function retime(clip, spans)
	local parts = { clip.name }
	for _, span in spans do
		table.insert(parts, string.format("%.4f/%.4f", span[1], span[2]))
	end
	local cacheKey = table.concat(parts, "|")
	local cached = retimed[cacheKey]
	if cached then
		return cached
	end
	-- where each span starts, in clip time and in seconds
	local clipStart, secStart = { 0 }, { 0 }
	for i, span in spans do
		clipStart[i + 1] = clipStart[i] + span[1]
		secStart[i + 1] = secStart[i] + span[2]
	end
	local function spanOf(p)
		for i = #spans, 1, -1 do
			if p >= clipStart[i] - 1e-9 then
				return i
			end
		end
		return 1
	end

	-- keys with times in seconds, and the stretch of time (the span it was
	-- authored in) each may move within
	local keys, times, lo, hi = {}, {}, {}, {}
	local function add(key, t, p)
		local i = spanOf(p)
		table.insert(keys, key)
		table.insert(times, t)
		table.insert(lo, secStart[i])
		table.insert(hi, secStart[i + 1])
	end
	for i, key in clip.keys do
		local nextKey = clip.keys[i + 1]
		if key.constant and nextKey then
			-- hold, then ramp into the next pose instead of jumping
			local ramp = maxTurn(key.cf, nextKey.cf) / MAX_TURN
			local t0, t1 = toSeconds(spans, key.t), toSeconds(spans, nextKey.t)
			local held = table.clone(key)
			held.constant = nil
			add(held, t0, key.t)
			add(table.clone(held), math.max(t0, t1 - ramp), key.t)
		else
			add(key, toSeconds(spans, key.t), key.t)
		end
	end
	local n = #keys
	-- the time each segment needs at MAX_TURN
	local need = {}
	for i = 1, n - 1 do
		need[i] = maxTurn(keys[i].cf, keys[i + 1].cf) * easePeak(keys[i]) / MAX_TURN
	end
	-- the first and last keys don't move
	lo[1], hi[1] = times[1], times[1]
	lo[n], hi[n] = times[n], times[n]

	-- how far key i can move left/right, pushing its neighbours if needed
	local function capLeft(i)
		if i <= 1 then
			return 0
		end
		local room = times[i] - lo[i]
		local gap = times[i] - times[i - 1] - need[i - 1]
		return math.max(0, math.min(room, math.max(0, gap) + capLeft(i - 1)))
	end
	local function capRight(i)
		if i >= n then
			return 0
		end
		local room = hi[i] - times[i]
		local gap = times[i + 1] - times[i] - need[i]
		return math.max(0, math.min(room, math.max(0, gap) + capRight(i + 1)))
	end
	local function pushLeft(i, by)
		times[i] -= by
		if i > 1 then
			local short = need[i - 1] - (times[i] - times[i - 1])
			if short > 0 then
				pushLeft(i - 1, math.min(short, by))
			end
		end
	end
	local function pushRight(i, by)
		times[i] += by
		if i < n then
			local short = need[i] - (times[i + 1] - times[i])
			if short > 0 then
				pushRight(i + 1, math.min(short, by))
			end
		end
	end
	local function spread()
		local worst = 0
		for _ = 1, 4 do
			worst = 0
			for i = 1, n - 1 do
				local short = need[i] - (times[i + 1] - times[i])
				if short > 1e-6 then
					local left, right = capLeft(i), capRight(i + 1)
					local takeLeft = math.min(left, math.max(short / 2, short - right))
					local takeRight = math.min(right, short - takeLeft)
					if takeLeft > 0 then
						pushLeft(i, takeLeft)
					end
					if takeRight > 0 then
						pushRight(i + 1, takeRight)
					end
					worst = math.max(worst, short - takeLeft - takeRight)
				end
			end
		end
		return worst
	end
	if spread() > 1e-4 then
		-- some span can't hold its motion: let keys cross span edges
		for i = 2, n - 1 do
			lo[i], hi[i] = times[1], times[n]
		end
		spread()
	end

	local out = table.create(n)
	for i, key in keys do
		local k = table.clone(key)
		k.t = times[i]
		if i > 1 and k.t < out[i - 1].t then
			k.t = out[i - 1].t
		end
		out[i] = k
	end
	local result = { name = clip.name, seconds = true, loop = false, length = secStart[#spans + 1], keys = out }
	retimed[cacheKey] = result
	return result
end

function FighterAnimator.hasClip(name)
	return compile(name) ~= nil
end

-- For tests: a clip as it plays for a move's timing (keys in seconds).
function FighterAnimator.timedClip(name, timing)
	local clip = compile(name)
	return clip and clip.phased and retime(clip, phaseSpans(timing)) or clip
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
-- clip starts from (`fresh`): offset * fresh = old. Returns how long a fade
-- of that difference should take: at least `base`, longer when a joint has
-- far to go (the eased fade peaks at 1.5x its average speed).
local function captureOffset(old, fresh, out, base)
	local worst = 0
	for i = 1, NJ do
		local offset = old.cf[i] * fresh.cf[i]:Inverse()
		out.cf[i] = offset
		worst = math.max(worst, turnOf(offset))
	end
	out.off = old.off - fresh.off
	-- the clip keeps moving under the fade, so the fade itself gets half
	-- the speed budget
	return math.clamp(worst * 1.5 * 2 / MAX_TURN, base or 0, MAX_FADE)
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

-- A bone's rest frame relative to the rig root, from its CFrame chain (bones
-- are relative to their parent bone, the top one to its part).
local function restFrame(bone, rootPart)
	local cf = CFrame.identity
	local node = bone
	while node and node:IsA("Bone") do
		cf = node.CFrame * cf
		node = node.Parent
	end
	if node and node:IsA("BasePart") then
		return rootPart.CFrame:ToObjectSpace(node.CFrame * cf)
	end
	return cf
end

local function vecOf(t)
	return Vector3.new(t[1], t[2], t[3])
end

-- Finds a skinned legend's bones: one per joint, plus its sway chains.
local function bindSkin(rig)
	rig.bones = nil
	rig.sways = nil
	local visual = rig.visual
	local skin = visual and visual:FindFirstChild("Skin")
	local root = visual and visual.PrimaryPart
	if not (skin and root) then
		return
	end
	local byName = {}
	for _, d in skin:GetDescendants() do
		if d:IsA("Bone") then
			byName[d.Name] = d
		end
	end
	rig.bones = {}
	for i, name in JOINTS do
		local bone = byName[name]
		if bone then
			local rot = restFrame(bone, root).Rotation
			rig.bones[i] = { bone = bone, rot = rot, inv = rot:Inverse() }
		end
	end
	rig.sways = {}
	rig.written = table.create(NJ, CFrame.identity)
	rig.frames = table.create(NJ, CFrame.identity)
	local info = FighterRigs.Fighters[visual:GetAttribute("Legend") or rig.legend or ""]
	for _, spec in (info and info.Sways) or {} do
		local parent = JOINT_INDEX[spec.Parent]
		local chain = {
			parent = parent,
			segments = {},
			stiffness = spec.Stiffness,
			damping = spec.Damping,
			limit = math.rad(spec.Limit),
			behind = spec.Behind,
			legs = spec.Parent == "Root" or spec.Parent == "Waist",
		}
		for k = 1, #spec.Points - 1 do
			local bone = byName[spec.Name .. k]
			if not bone then
				break
			end
			local a, b = vecOf(spec.Points[k]), vecOf(spec.Points[k + 1])
			local rot = restFrame(bone, root).Rotation
			table.insert(chain.segments, {
				bone = bone,
				rot = rot,
				inv = rot:Inverse(),
				head = a,
				dir = (b - a).Unit,
				length = (b - a).Magnitude,
			})
		end
		if parent and #chain.segments > 0 then
			table.insert(rig.sways, chain)
		end
	end
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
	bindSkin(rig)
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
		locoFadeLen = LOCO_FADE,
		locoOffset = newPose(),
		action = nil,
		actionFade = 0,
		actionFadeLen = ACTION_FADE_IN,
		actionOffset = newPose(),
		outFade = 0,
		outFadeLen = ACTION_FADE_OUT,
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
	for _, b in rig.bones or {} do
		b.bone.Transform = CFrame.identity
	end
	for _, chain in rig.sways or {} do
		for _, seg in chain.segments do
			seg.bone.Transform = CFrame.identity
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
		rig.locoFadeLen = captureOffset(rig.locoPose, rig.tmp, rig.locoOffset, LOCO_FADE)
		rig.locoFade = rig.locoFadeLen
	else
		rig.locoFade = 0
	end
	rig.loco = { state = state, weapon = weapon, clip = clip, t = 0, speed = speed or 1 }
end

-- Actions ------------------------------------------------------------------------

-- Blends the current pose back into the locomotion layer.
local function fadeOut(rig)
	rig.outFadeLen = captureOffset(rig.pose, rig.locoPose, rig.outOffset, ACTION_FADE_OUT)
	rig.outFade = rig.outFadeLen
end

-- Where an attack is in its clip: the move phase, in seconds when the clip
-- was re-timed.
local function attackClipTime(action)
	local phase = phaseAt(action.t, action.timing, action.p0)
	return action.clip.seconds and toSeconds(action.spans, phase) or phase
end

-- Fades from the pose showing now into the current action at its current
-- time (a new action, or one that jumped ahead).
local function fadeIn(rig)
	local action = rig.action
	if action.kind == "Attack" then
		sample(action.clip, attackClipTime(action), rig.facing < 0, rig.tmp)
	else
		sample(action.clip, 0, rig.facing < 0, rig.tmp)
	end
	rig.actionFadeLen = captureOffset(rig.pose, rig.tmp, rig.actionOffset, ACTION_FADE_IN)
	rig.actionFade = rig.actionFadeLen
	rig.outFade = 0
end

local function startAction(rig, action)
	rig.action = action
	fadeIn(rig)
end

-- Jumps an attack ahead to `t` seconds (a ground pound landing), blending
-- into the new pose rather than snapping to it.
local function skipTo(rig, action, t)
	if t > action.t then
		action.t = t
		fadeIn(rig)
	end
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
	if rig.held then
		state = rig.held
	elseif grounded or rig.airborneFor < 0.06 then
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
			skipTo(rig, action, s + a)
		elseif landed and action.air then
			FighterAnimator.endAttack(rig.model)
		end
	end
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
	local timing = {
		startup = move.Startup,
		active = move.EndsOnLand and math.max(move.Active, 0.35) or move.Active,
		recovery = move.Recovery,
	}
	local spans = phaseSpans(timing)
	if clip.phased then
		clip = retime(clip, spans)
	end
	startAction(rig, {
		kind = "Attack",
		clip = clip,
		t = 0,
		seq = seq,
		timing = timing,
		spans = spans,
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
		skipTo(rig, action, s + a)
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
	local rate = opts.stretch and duration and clip.length / math.max(duration, 1e-3) or 1
	if not opts.loopFor and not clip.phased and clip.length > 0 then
		-- one-shot clips play in real seconds, re-timed like attacks
		clip = retime(clip, { { clip.length, clip.length / rate } })
		rate = 1
	end
	startAction(rig, {
		kind = "Clip",
		clip = clip,
		t = 0,
		duration = duration or clip.length,
		rate = rate,
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

-- Hit: recoil, or tumble when the hit ragdolls them, for as long as the
-- hitstun lasts.
function FighterAnimator.hurt(model, hitstun, force, ragdoll)
	local tumble = ragdoll
	if tumble == nil then
		tumble = (force or 0) > Config.Battle.RagdollForce
	end
	if tumble then
		-- limp until they land (up to TumbleHold past the hitstun)
		local limp = hitstun + (ragdoll and Config.Battle.TumbleHold or 0)
		FighterAnimator.playClip(model, "Loco.Tumble", limp, { loopFor = limp })
	else
		FighterAnimator.playClip(model, "Loco.Hurt", math.max(hitstun, 0.2), { hold = true })
	end
end

-- Holds someone else's fighter in a locomotion state ("Block") until
-- cleared with nil. Your own fighter's state comes from FighterSim.
function FighterAnimator.setHeld(model, state)
	local rig = rigs[model]
	if rig then
		rig.held = state
		if state then
			FighterAnimator.setLocomotion(model, state)
		end
	end
end

-- Knocked down after a tumble, getting up, or teching the landing.
function FighterAnimator.down(model, kind, dir)
	local B = Config.Battle
	if kind == "Knockdown" then
		FighterAnimator.playClip(model, "Loco.Knockdown", B.KnockdownTime, { hold = true })
	elseif kind == "GetUp" then
		FighterAnimator.playClip(model, "Loco.GetUp", B.GetUpTime, { stretch = true })
	elseif kind == "Tech" then
		local roll = dir ~= nil and dir ~= 0
		FighterAnimator.playClip(model, roll and "Loco.TechRoll" or "Loco.Tech", B.TechRollTime, { stretch = true })
	end
end

-- Guard broken: dazed for `duration`.
function FighterAnimator.stunned(model, duration)
	FighterAnimator.playClip(model, "Loco.Stunned", duration, { loopFor = duration })
end

-- The awakening pose, held through the freeze.
function FighterAnimator.awaken(model, duration)
	FighterAnimator.playClip(model, "Loco.Awaken", duration, { stretch = true })
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
	local bones = rig.bones
	for i, j in rig.motors do
		local motor = j.motor
		local cf = pose.cf[i]
		if i == 1 then
			cf = CFrame.new(pose.off * scale) * cf
		end
		if bones then
			rig.written[i] = cf
			local b = bones[i]
			if b then
				b.bone.Transform = b.inv * cf * b.rot
			end
		end
		if not j.plain then
			cf = j.inv * cf * j.rot
		end
		motor.Transform = cf
	end
end

-- Rotation taking unit vector a onto unit vector b.
local function between(a, b)
	local axis = a:Cross(b)
	local m = axis.Magnitude
	if m < 1e-6 then
		return CFrame.identity
	end
	return CFrame.fromAxisAngle(axis / m, math.atan2(m, math.clamp(a:Dot(b), -1, 1)))
end

-- Sway bones: each segment's tip trails its rest position on a damped
-- spring (in world space, so it lags behind fast moves), within a swing
-- limit, and capes stay on their side of the body.
local function closestOnSegment(p, a, b)
	local ab = b - a
	local t = math.clamp((p - a):Dot(ab) / math.max(ab:Dot(ab), 1e-9), 0, 1)
	return a + ab * t
end

-- Re-aims a hanging segment (from head along dir) so its middle and tip
-- stay out of the thighs: a raised knee lifts the cloth forward and up over
-- it (backward for cloth behind), never sideways into the other leg.
local function clearLegs(rootCF, frames, chain, head, dir, len, s)
	local r = THIGH_RADIUS * s
	local out = (if chain.behind == 1 then -rootCF.LookVector else rootCF.LookVector) + rootCF.UpVector * 0.5
	local legs = {}
	for k, leg in LEGS do
		local a = (rootCF * frames[leg[1]]).Position
		local b = (rootCF * frames[leg[2]]).Position
		local axis = (b - a).Unit
		local push = out - axis * out:Dot(axis)
		legs[k] = { a = a, b = b, push = if push.Magnitude > 1e-3 then push.Unit else nil }
	end
	for _ = 1, 12 do
		local nudge = nil
		for _, leg in legs do
			for _, f in { 0.5, 1 } do
				local q = head + dir * len * f
				local away = q - closestOnSegment(q, leg.a, leg.b)
				if away.Magnitude < r then
					nudge = leg.push or away.Unit
				end
			end
		end
		if not nudge then
			break
		end
		dir = (dir + nudge * 0.25).Unit -- swing a little further out and look again
	end
	return dir
end

local function stepSways(rig, dt)
	local sways = rig.sways
	if not sways or #sways == 0 then
		return
	end
	local root = rig.visual and rig.visual.PrimaryPart
	if not root then
		return
	end
	local s = rig.scale
	local frames = rig.frames
	for _, i in JOINT_ORDER do
		local parent = JOINT_PARENT[i]
		local t = rig.written[i]
		if parent then
			frames[i] = frames[parent] * CFrame.new((JOINT_PIVOT[i] - JOINT_PIVOT[parent]) * s) * t
		else
			frames[i] = CFrame.new(JOINT_PIVOT[i] * s) * t
		end
	end
	local rootCF = root.CFrame
	for _, chain in sways do
		local frame = rootCF * frames[chain.parent]
		local head = frame:PointToWorldSpace((chain.segments[1].head - JOINT_PIVOT[chain.parent]) * s)
		local pull = 1 - (1 - chain.stiffness) ^ (dt * 60)
		local keep = (1 - chain.damping) ^ (dt * 60)
		for _, seg in chain.segments do
			local len = seg.length * s
			local rest = frame:VectorToWorldSpace(seg.dir)
			local target = head + rest * len
			local p, prev = seg.tip, seg.prev
			if not p or (p - target).Magnitude > len * 3 + 2 then
				p, prev = target, target -- first frame, or a teleport
			end
			local moved = p
			if dt > 0 then
				moved = p + (p - prev) * keep + SWAY_GRAVITY * dt * dt + (target - p) * pull
			end
			local dir = moved - head
			dir = if dir.Magnitude > 1e-6 then dir.Unit else rest
			local angle = math.acos(math.clamp(dir:Dot(rest), -1, 1))
			if angle > chain.limit then
				local axis = rest:Cross(dir)
				if axis.Magnitude > 1e-6 then
					dir = CFrame.fromAxisAngle(axis.Unit, chain.limit):VectorToWorldSpace(rest)
				else
					dir = rest
				end
			end
			if chain.behind then
				local loc = frame:VectorToObjectSpace(dir)
				if loc.Z * chain.behind < -0.05 then
					dir = frame:VectorToWorldSpace(Vector3.new(loc.X, loc.Y, -0.05 * chain.behind).Unit)
				end
			end
			if chain.legs then
				dir = clearLegs(rootCF, frames, chain, head, dir, len, s)
			end
			local tip = head + dir * len
			if dt > 0 or not seg.tip then
				seg.prev, seg.tip = p, tip
			end
			local turn = between(seg.dir, frame:VectorToObjectSpace(dir))
			seg.bone.Transform = seg.inv * turn * seg.rot
			frame = CFrame.new(head) * frame.Rotation * turn
			head = tip
		end
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
			applyOffset(rig.locoOffset, rig.locoFade / rig.locoFadeLen, rig.locoPose, rig.locoPose)
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
			sample(action.clip, attackClipTime(action), mirror, rig.tmp)
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
			applyOffset(rig.actionOffset, rig.actionFade / rig.actionFadeLen, rig.tmp, out)
		else
			copyPose(rig.tmp, out)
		end
		if finished then
			rig.action = nil
			fadeOut(rig)
		end
	elseif rig.outFade > 0 then
		rig.outFade = math.max(0, rig.outFade - step)
		applyOffset(rig.outOffset, rig.outFade / rig.outFadeLen, rig.locoPose, out)
	else
		copyPose(rig.locoPose, out)
	end

	write(rig)
	stepSways(rig, step)
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
