-- ItemRig: procedural character animation for the item bar, on every client for every player
-- (ItemFX asks for it). Nothing here is an animation asset and nothing replicates:
--   * body moves (swing and its combo finisher, place, shoot, spray, zap, dash, slip, tumble, float,
--     dive / land (the glide slam), pounce, bowl (sliding on a peel), startle (a honk), cheer (an
--     upgrade), nap, and the persistent glide, sleepy, static, charge (rubbing the balloon)) are
--     written into the character's Motor6D.Transform on RunService.Stepped, which runs
--     AFTER the Animator each frame: our rotation is laid on top of whatever the default Animate
--     script plays (walk, idle, toolnone), so the two never fight; when a move ends we stop writing
--     and the Animator's own pose is back the next frame (or we put back the last one it wrote).
--     Every move has an anticipation (a small wind-up the other way) and a follow-through (an
--     overshoot that settles), so it reads from far away.
--   * the rigs run on their own clock, which big moments slow down or freeze for a hit-stop
--     (SetTimeScale; ItemMoments drives it) - only on this client, only the look.
--   * the Towel Snap is an overhead crack: the towel goes up and back over the shoulder and is
--     lashed down in front. Holding the button keeps it going: after each crack the arm lifts the
--     towel back over the shoulder and the next crack comes as soon as the cooldown allows
--     (SetWhipHold; other players' holds arrive with their swings). Held but not swinging, the arm
--     rests lower and the towel hangs.
--   * the towel's whip: its Seg1..Seg6 Bones (Blender towel) or Seg1..Seg6 Motor6Ds (Part towel)
--     are bent in a wave that curls back, unrolls and cracks at the tip, then droops and sways.
--   * the Laundry Basket's wobble (its BasketJoint Motor6D) while someone shuffles under it.
-- Poses are rotations in the character's own axes (x right, y up, z back) about each joint, so R15
-- and R6 share every move (R6 has no elbows / waist: the waist folds into the root).
-- API: ItemRig.Play(character, kind, data?), ItemRig.Stop(character, kind), ItemRig.Has(character, kind),
--      ItemRig.SetWhipHold(character, on, seconds?), ItemRig.SetTimeScale(scale),
--      ItemRig.SetReduced(on), ItemRig.Count() -> active rigs (tests)
--      (swing data: { finisher = true } = the combo finisher: a high wind-up, a wide lash across
--      with a body twist; charge data: { on, charge = 0..1 })
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local ItemRig = {}

local sin, exp, clamp, min = math.sin, math.exp, math.clamp, math.min
local PI = math.pi
local TAU = math.pi * 2

local RANGE = 160 -- studs from the camera: farther characters skip the moves (they'd be dots)
local TOWEL_RANGE = 70 -- studs: a held towel droops and sways only this close
local WIND = 0.12 -- swing: wind-up seconds
local CRACK = 0.22 -- swing: the crack (ItemFX.CRACK_T): the arm lands its lash, the towel's tip straightens
local DROOP = 0.2 -- radians per towel segment at rest (the towel hangs from the hand)
local FLOOR_GAP = 0.5 -- studs: the towel's tip stays at least this far above the floor under you
local LIFT = 0.32 -- swing: when the follow-through ends and, while held, the arm lifts the towel again
local LIFT_TIME = 0.4 -- held: seconds to lift the towel back over the shoulder (a back cast)
local HELD_ARM = -0.5 -- radians the arm rests lower than Roblox's "holding a tool" pose
-- the combo finisher: a longer, higher wind-up and a later crack (ItemFX.CRACK_FINISHER = 0.32)
local WIND_F = 0.2
local CRACK_F = 0.32
local LIFT_F = 0.44

local clock = os.clock() -- the rigs' own time: real time, slowed or frozen by big moments
local timeScale = 1

-- ---------- small maths ----------

local function ease(u: number): number
	u = clamp(u, 0, 1)
	return u * u * (3 - 2 * u)
end

-- keyframes { {t, v}, ... } (t ascending) eased between keys
local function keys(t: number, list: { { number } }): number
	local first = list[1]
	if t <= first[1] then
		return first[2]
	end
	for i = 2, #list do
		local k = list[i]
		if t <= k[1] then
			local p = list[i - 1]
			return p[2] + (k[2] - p[2]) * ease((t - p[1]) / (k[1] - p[1]))
		end
	end
	return list[#list][2]
end

local function bump(u: number): number
	return if u <= 0 or u >= 1 then 0 else sin(PI * u)
end

-- ---------- types ----------

type Joint = {
	motor: Motor6D,
	r0: CFrame, -- C0's rotation: pose space -> the joint's own space
	r0inv: CFrame,
	written: CFrame?, -- what we wrote last frame
	base: CFrame?, -- what the Animator had written under it
}

type Pose = { [string]: Vector3 } -- joint -> (x, y, z) radians in the character's axes

type Layer = { kind: string, t0: number, dur: number, data: { [string]: any } }

-- `along`: how far along the towel (the handle's +Z, studs from the grip) the segment's joint is
type TowelSeg = { index: number, bone: Bone?, motor: Motor6D?, r: CFrame, rinv: CFrame, axis: Vector3, weight: number, limit: number, along: number }

type Rig = {
	character: Model,
	r6: boolean,
	joints: { [string]: Joint },
	layers: { Layer },
	root: BasePart?,
	humanoid: Humanoid?,
	towelTool: Instance?,
	towelHandle: BasePart?,
	towelLength: number, -- studs from the grip to the towel's far edge
	towelLook: any,
	towelBuilt: number,
	towelSegs: { TowelSeg },
	towelSwing: number, -- the rigs' clock at the last swing (0 = none)
	towelChained: boolean, -- that swing started with the towel already up (a held loop)
	towelFinisher: boolean, -- that swing is the combo finisher (a bigger whip)
	whipHoldUntil: number, -- os.clock() until which the towel button counts as held (0 = not)
	holdW: number, -- 0..1, eased toward "held": lifts the towel again after a crack
	idleW: number, -- 0..1, eased toward "holding the towel, not swinging": the lowered arm
	basket: Motor6D?,
	tumbleAxis: Vector3?,
	turn: Vector3?, -- this frame's tumble: axis * angle in the root's space
}

local rigs: { [Model]: Rig } = {}
local reduced = false

-- R15 joint name -> (part, motor); R6 equivalents
local R15 = {
	Root = { "LowerTorso", "Root" },
	Waist = { "UpperTorso", "Waist" },
	Neck = { "Head", "Neck" },
	RShoulder = { "RightUpperArm", "RightShoulder" },
	RElbow = { "RightLowerArm", "RightElbow" },
	LShoulder = { "LeftUpperArm", "LeftShoulder" },
	LElbow = { "LeftLowerArm", "LeftElbow" },
	RHip = { "RightUpperLeg", "RightHip" },
	LHip = { "LeftUpperLeg", "LeftHip" },
	RKnee = { "RightLowerLeg", "RightKnee" },
	LKnee = { "LeftLowerLeg", "LeftKnee" },
}
local R6 = {
	Root = { "HumanoidRootPart", "RootJoint" },
	Neck = { "Torso", "Neck" },
	RShoulder = { "Torso", "Right Shoulder" },
	LShoulder = { "Torso", "Left Shoulder" },
	RHip = { "Torso", "Right Hip" },
	LHip = { "Torso", "Left Hip" },
}

local function findJoints(character: Model): ({ [string]: Joint }, boolean)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local r6 = humanoid ~= nil and humanoid.RigType == Enum.HumanoidRigType.R6
	local map = if r6 then R6 else R15
	local joints = {}
	for name, spec in pairs(map) do
		local part = character:FindFirstChild(spec[1])
		local motor = part and part:FindFirstChild(spec[2])
		if motor and motor:IsA("Motor6D") then
			local r0 = motor.C0.Rotation
			joints[name] = { motor = motor, r0 = r0, r0inv = r0:Inverse(), written = nil, base = nil }
		end
	end
	return joints, r6
end

local function getRig(character: Model): Rig
	local rig = rigs[character]
	if not rig then
		local joints, r6 = findJoints(character)
		local root = character:FindFirstChild("HumanoidRootPart")
		rig = {
			character = character,
			r6 = r6,
			joints = joints,
			layers = {},
			root = if root and root:IsA("BasePart") then root else nil,
			humanoid = character:FindFirstChildOfClass("Humanoid"),
			towelTool = nil,
			towelHandle = nil,
			towelLength = 4,
			towelLook = nil,
			towelBuilt = 0,
			towelSegs = {},
			towelSwing = 0,
			towelChained = false,
			towelFinisher = false,
			whipHoldUntil = 0,
			holdW = 0,
			idleW = 0,
			basket = nil,
			tumbleAxis = nil,
			turn = nil,
		}
		rigs[character] = rig
	end
	return rig
end

-- ---------- moves ----------
-- Each adds rotations (x, y, z per joint) for time t (seconds since it started, 0..dur).

local function add(pose: Pose, joint: string, x: number, y: number, z: number)
	local v = pose[joint]
	pose[joint] = if v then v + Vector3.new(x, y, z) else Vector3.new(x, y, z)
end

local MOVES: { [string]: (pose: Pose, t: number, layer: Layer, rig: Rig) -> () } = {}

-- the Towel Snap: an overhead crack. Up and back over the shoulder, lashed forward to about
-- shoulder height (the towel unrolls straight out in front, it cracks), a follow-through down to the
-- hold; then either back to the hold (let go) or up over the shoulder again (held: the next swing
-- of the loop starts from there, `chain`). Rotations about x raise the arm forward/up, about y turn
-- it (and the waist) to the left. The poses go on top of Roblox's "holding a tool" arm (level, in
-- front): the crack's arm sits a little below level, so the towel's line runs out in front of you,
-- above the floor - not down at your feet.
-- The combo finisher (data.finisher) winds up higher with the shoulders turned away (to the right),
-- then lashes across the body with a twist through the waist and hips, cracking a little to the
-- left of straight ahead, and holds the follow-through.
local SWING_UP = { RShoulder = Vector3.new(2.1, -0.25, 0.3), RElbow = Vector3.new(0.85, 0, 0), LShoulder = Vector3.new(0.3, 0, 0), Waist = Vector3.new(0.14, -0.2, 0), Neck = Vector3.new(0.1, 0.12, 0) }
local SWING_DOWN = { RShoulder = Vector3.new(-0.2, 0.2, -0.1), RElbow = Vector3.new(0.05, 0, 0), LShoulder = Vector3.new(-0.25, 0, 0), Waist = Vector3.new(-0.15, 0.18, 0), Neck = Vector3.new(-0.1, -0.1, 0) }
local SWING_FOLLOW = { RShoulder = Vector3.new(-0.45, 0.15, -0.05), RElbow = Vector3.new(0.25, 0, 0), LShoulder = Vector3.new(-0.1, 0, 0), Waist = Vector3.new(-0.08, 0.1, 0), Neck = Vector3.new(-0.04, -0.06, 0) }
local FIN_UP = { RShoulder = Vector3.new(2.05, -0.3, 0.35), RElbow = Vector3.new(0.75, 0, 0), LShoulder = Vector3.new(0.6, 0, -0.3), Waist = Vector3.new(0.2, -0.45, 0), Neck = Vector3.new(0.12, 0.35, 0), Root = Vector3.new(0, -0.12, 0) }
local FIN_DOWN = { RShoulder = Vector3.new(-0.12, 0.15, -0.2), RElbow = Vector3.new(0.05, 0, 0), LShoulder = Vector3.new(-0.4, 0, 0.3), Waist = Vector3.new(-0.2, 0.25, 0), Neck = Vector3.new(-0.12, -0.18, 0), Root = Vector3.new(0, 0.08, 0) }
local FIN_FOLLOW = { RShoulder = Vector3.new(-0.4, 0.4, -0.1), RElbow = Vector3.new(0.3, 0, 0), LShoulder = Vector3.new(-0.15, 0, 0.12), Waist = Vector3.new(-0.1, 0.35, 0), Neck = Vector3.new(-0.06, -0.22, 0), Root = Vector3.new(0, 0.12, 0) }
local ZERO = Vector3.zero

MOVES.swing = function(pose, t, layer, rig)
	local chain = layer.data.chain == true
	local fin = layer.data.finisher == true
	local upT, downT, followT = SWING_UP, SWING_DOWN, SWING_FOLLOW
	local wind, crack, lift = WIND, CRACK, LIFT
	if fin then
		upT, downT, followT = FIN_UP, FIN_DOWN, FIN_FOLLOW
		wind, crack, lift = WIND_F, CRACK_F, LIFT_F
	end
	for joint, up in pairs(upT) do
		local down, follow = downT[joint] or ZERO, followT[joint] or ZERO
		local plainUp = SWING_UP[joint] or ZERO
		local v: Vector3
		if t < wind then
			-- a held loop is already up there (the finisher rises from the plain hold to its own)
			local from = if chain then plainUp else ZERO
			v = from:Lerp(up, ease(t / wind))
		elseif t < crack then
			v = up:Lerp(down, ease((t - wind) / (crack - wind))) -- the lash: the crack lands at `crack`
		elseif t < lift then
			v = down:Lerp(follow, ease((t - crack) / (lift - crack)))
		else
			-- let go: settle back to the hold; held: lift it over the shoulder again for the next crack
			local rest = follow * (1 - ease((t - lift) / 0.25))
			local again = follow:Lerp(plainUp, ease((t - lift) / LIFT_TIME))
			v = rest:Lerp(again, rig.holdW)
		end
		add(pose, joint, v.X, v.Y, v.Z)
	end
end

-- drop a peel / set the duck down: a little lift first, bend and reach down, back up past the
-- start and settle
MOVES.place = function(pose, t)
	local bend = keys(t, { { 0, 0 }, { 0.08, 0.06 }, { 0.24, -0.5 }, { 0.36, -0.5 }, { 0.55, 0.05 }, { 0.68, 0 } })
	add(pose, "Waist", bend, 0, 0)
	add(pose, "RShoulder", keys(t, { { 0, 0 }, { 0.08, 0.35 }, { 0.24, -1.0 }, { 0.36, -1.0 }, { 0.55, 0.12 }, { 0.68, 0 } }), 0, 0)
	add(pose, "Neck", bend * 0.6, 0, 0)
	add(pose, "RHip", -bend * 0.5, 0, 0)
	add(pose, "LHip", -bend * 0.5, 0, 0)
	add(pose, "RKnee", bend * 0.9, 0, 0)
	add(pose, "LKnee", bend * 0.9, 0, 0)
end

-- Bubble Blaster: aim (pulled back a touch), the other hand steadies it, a recoil kick, settle
MOVES.shoot = function(pose, t)
	add(pose, "RShoulder", keys(t, { { 0, 0 }, { 0.06, -0.12 }, { 0.1, 0.4 }, { 0.24, 0.02 }, { 0.32, 0.08 }, { 0.46, 0 } }), 0, 0)
	add(pose, "LShoulder", keys(t, { { 0, 0 }, { 0.08, 1.25 }, { 0.32, 1.25 }, { 0.46, 0 } }), 0, keys(t, { { 0, 0 }, { 0.08, -0.55 }, { 0.32, -0.55 }, { 0.46, 0 } }))
	add(pose, "Waist", keys(t, { { 0, 0 }, { 0.06, -0.05 }, { 0.12, 0.08 }, { 0.46, 0 } }), keys(t, { { 0, 0 }, { 0.08, 0.18 }, { 0.46, 0 } }), 0)
	add(pose, "Root", keys(t, { { 0, 0 }, { 0.06, -0.03 }, { 0.1, 0.08 }, { 0.28, 0 } }), 0, 0)
end

-- Softener Cloud: a squeeze to aim, a few quick trigger pumps, a little shake-out
MOVES.spray = function(pose, t, layer)
	local fade = 1 - ease((t - layer.dur + 0.2) / 0.2)
	local pump = math.abs(sin(t * 22)) * 0.14 * fade
	local squeeze = keys(t, { { 0, 0 }, { 0.07, -0.12 }, { 0.14, 0 } })
	add(pose, "RShoulder", (0.2 + pump) * min(t / 0.08, 1) * fade + squeeze, 0, 0)
	add(pose, "Waist", 0, 0.12 * sin(t * 6) * fade, 0)
	add(pose, "RElbow", squeeze * -1.5, 0, 0)
end

-- Static Balloon: a crouch, thrust it up - ZAP - then rub it on your head, crackling.
-- data.charge (0..1): how charged it was (a fuller charge = a bigger thrust)
MOVES.zap = function(pose, t, layer)
	local c = 0.7 + 0.3 * (layer.data.charge or 0)
	local rub = if t > 0.25 and t < 0.75 then sin(t * 40) * 0.3 * bump((t - 0.25) / 0.5) else 0
	add(pose, "RShoulder", keys(t, { { 0, 0 }, { 0.05, -0.2 }, { 0.12, 2.4 * c }, { 0.25, 2.3 * c }, { 0.35, 1.5 }, { 0.75, 1.5 }, { 1.0, 0 } }), rub, keys(t, { { 0, 0 }, { 0.25, 0 }, { 0.35, -0.55 }, { 0.75, -0.55 }, { 1.0, 0 } }))
	add(pose, "RElbow", keys(t, { { 0, 0 }, { 0.25, 0 }, { 0.35, 1.3 }, { 0.75, 1.3 }, { 1.0, 0 } }), 0, 0)
	add(pose, "Neck", keys(t, { { 0, 0 }, { 0.05, -0.1 }, { 0.12, 0.15 }, { 0.3, 0 } }), rub * 0.5, 0)
	local crouch = keys(t, { { 0, 0 }, { 0.05, -0.35 }, { 0.12, 0.05 }, { 0.25, 0 } })
	add(pose, "RKnee", crouch, 0, 0)
	add(pose, "LKnee", crouch, 0, 0)
	add(pose, "RHip", -crouch * 0.5, 0, 0)
	add(pose, "LHip", -crouch * 0.5, 0, 0)
	add(pose, "Root", 0, 0, if t > 0.05 and t < 0.3 then sin(t * 60) * 0.05 * c else 0) -- a little shiver
end

-- Slipper Dash: a quick lean back, then lean in, arms back, a long stride; a skid at the end
MOVES.dash = function(pose, t, layer)
	local u = t / layer.dur
	local k = bump(u)
	local antic = keys(t, { { 0, 0 }, { 0.04, 0.12 }, { 0.08, 0 } })
	local skid = keys(u, { { 0, 0 }, { 0.75, 0 }, { 0.88, 0.12 }, { 1, 0 } })
	add(pose, "Root", -0.35 * k + antic + skid, 0, 0)
	add(pose, "RShoulder", -0.9 * k, 0, 0.15 * k)
	add(pose, "LShoulder", -0.9 * k, 0, -0.15 * k)
	add(pose, "RHip", 0.6 * k, 0, 0)
	add(pose, "LHip", -0.45 * k, 0, 0)
end

-- knocked back: a full tumble along the push (a wobble with Reduce motion), arms flailing
MOVES.tumble = function(pose, t, layer, rig)
	local u = t / layer.dur
	local soft = layer.data.soft == true or reduced
	local angle = if soft then 0.55 * bump(u) else TAU * ease(min(u * 1.25, 1))
	local axis = rig.tumbleAxis
	if axis then
		rig.turn = axis * angle
	end
	local flail = bump(u) * (if soft then 0.4 else 1)
	add(pose, "RShoulder", 1.4 * flail, 0, 0.6 * flail * sin(t * 25))
	add(pose, "LShoulder", 1.4 * flail, 0, -0.6 * flail * sin(t * 25 + 1))
	add(pose, "RHip", 0.5 * flail * sin(t * 18), 0, 0)
	add(pose, "LHip", -0.5 * flail * sin(t * 18), 0, 0)
end

-- slipped on a banana peel: feet fly up, land on your back, scramble up
MOVES.slip = function(pose, t, layer)
	local d = layer.dur
	local fall = keys(t, { { 0, 0 }, { 0.15, if reduced then 0.5 else 1.3 }, { d - 0.35, if reduced then 0.5 else 1.2 }, { d, 0 } })
	add(pose, "Root", fall, 0, 0)
	add(pose, "RHip", fall * 0.9, 0, 0)
	add(pose, "LHip", fall * 0.7, 0, 0)
	local flail = keys(t, { { 0, 0 }, { 0.12, 1 }, { d - 0.3, 1 }, { d, 0 } })
	add(pose, "RShoulder", 2.2 * flail, 0, 0.3 * sin(t * 26) * flail)
	add(pose, "LShoulder", 2.2 * flail, 0, -0.3 * sin(t * 26 + 1) * flail)
end

-- floating in a bubble: swimming in the air
MOVES.float = function(pose, t, layer)
	local k = min(t / 0.2, 1) * min((layer.dur - t) / 0.25, 1)
	add(pose, "RShoulder", (1.2 + 0.6 * sin(t * 9)) * k, 0, 0.3 * k)
	add(pose, "LShoulder", (1.2 + 0.6 * sin(t * 9 + PI)) * k, 0, -0.3 * k)
	add(pose, "RHip", 0.45 * sin(t * 7) * k, 0, 0)
	add(pose, "LHip", 0.45 * sin(t * 7 + PI) * k, 0, 0)
end

-- the persistent ones (weights blend in and out; dur = math.huge until stopped)
MOVES.glide = function(pose, t, layer)
	local k = layer.data.w or 0
	add(pose, "RShoulder", 2.6 * k, 0, 0.25 * k)
	add(pose, "LShoulder", 2.6 * k, 0, -0.25 * k)
	add(pose, "RElbow", 0.25 * k, 0, 0)
	add(pose, "LElbow", 0.25 * k, 0, 0)
	add(pose, "RHip", (0.25 + 0.15 * sin(t * 3)) * k, 0, 0)
	add(pose, "LHip", (0.15 + 0.15 * sin(t * 3 + 1.4)) * k, 0, 0)
	add(pose, "Root", 0, 0, 0.06 * sin(t * 1.7) * k)
end

MOVES.sleepy = function(pose, t, layer)
	local k = layer.data.w or 0
	add(pose, "Neck", (-0.35 + 0.15 * sin(t * 2.2)) * k, 0, 0.08 * sin(t * 1.1) * k)
	add(pose, "RShoulder", -0.08 * k, 0, -0.08 * k)
	add(pose, "LShoulder", -0.08 * k, 0, 0.08 * k)
	add(pose, "Waist", -0.08 * k, 0, 0)
end

MOVES.static = function(pose, t, layer)
	local k = layer.data.w or 0
	add(pose, "Neck", 0.05 * sin(t * 47) * k, 0.05 * sin(t * 39) * k, 0)
	add(pose, "RShoulder", 0, 0, 0.12 * k)
	add(pose, "LShoulder", 0, 0, -0.12 * k)
end

-- Static Balloon held down: rubbing the balloon on your head, faster and buzzier as it charges
-- (data.charge 0..1)
MOVES.charge = function(pose, t, layer)
	local k = layer.data.w or 0
	local c = clamp(layer.data.charge or 0, 0, 1)
	local rub = sin(t * (18 + 14 * c)) * (0.18 + 0.2 * c) * k
	add(pose, "RShoulder", 1.9 * k, rub, -0.35 * k)
	add(pose, "RElbow", 1.25 * k, 0, 0)
	add(pose, "Neck", -0.12 * k, rub * 0.4, 0.06 * sin(t * 9) * k)
	add(pose, "LShoulder", 0.35 * k, 0, -0.2 * k)
	add(pose, "Root", 0, 0, (if c > 0.6 then sin(t * 55) * 0.03 * (c - 0.6) / 0.4 else 0) * k) -- buzzing when full
end

-- the glide slam, on the way down: a quick tuck, then bottom-first with the arms up
MOVES.dive = function(pose, t, layer)
	local k = keys(t, { { 0, 0 }, { 0.08, 1 } }) * clamp((layer.dur - t) / 0.15, 0, 1)
	local tuck = keys(t, { { 0, 0 }, { 0.06, 1.3 }, { 0.16, 0.9 } })
	add(pose, "RShoulder", 2.8 * k, 0, 0.35 * k)
	add(pose, "LShoulder", 2.8 * k, 0, -0.35 * k)
	add(pose, "RHip", tuck * k, 0, 0)
	add(pose, "LHip", tuck * k, 0, 0)
	add(pose, "RKnee", -1.2 * k, 0, 0)
	add(pose, "LKnee", -1.2 * k, 0, 0)
	add(pose, "Root", -0.2 * k, 0, 0)
end

-- the slam lands: a deep squat with the arms flung out, then up again
MOVES.land = function(pose, t)
	local s = keys(t, { { 0, 0 }, { 0.05, 1 }, { 0.2, 0.8 }, { 0.5, 0 } })
	add(pose, "RHip", 0.7 * s, 0, 0)
	add(pose, "LHip", 0.7 * s, 0, 0)
	add(pose, "RKnee", -1.1 * s, 0, 0)
	add(pose, "LKnee", -1.1 * s, 0, 0)
	add(pose, "Waist", -0.25 * s, 0, 0)
	add(pose, "RShoulder", 0.4 * s, 0, 1.0 * s)
	add(pose, "LShoulder", 0.4 * s, 0, -1.0 * s)
	add(pose, "Neck", -0.15 * s, 0, 0)
end

-- out of the Laundry Basket with a pounce: crouch, spring up with the arms out, land
MOVES.pounce = function(pose, t)
	local crouch = keys(t, { { 0, 0 }, { 0.12, 1 }, { 0.2, 0 }, { 0.55, 0 }, { 0.62, 0.5 }, { 0.75, 0 } })
	local spring = keys(t, { { 0, 0 }, { 0.12, 0 }, { 0.22, 1 }, { 0.45, 0.9 }, { 0.6, 0 } })
	add(pose, "RHip", 0.8 * crouch - 0.2 * spring, 0, 0)
	add(pose, "LHip", 0.8 * crouch - 0.2 * spring, 0, 0)
	add(pose, "RKnee", -1.2 * crouch, 0, 0)
	add(pose, "LKnee", -1.2 * crouch, 0, 0)
	add(pose, "RShoulder", -0.6 * crouch + 2.7 * spring, 0, 0.6 * spring)
	add(pose, "LShoulder", -0.6 * crouch + 2.7 * spring, 0, -0.6 * spring)
	add(pose, "Waist", -0.3 * crouch + 0.15 * spring, 0, 0)
	add(pose, "Root", -0.1 * crouch - 0.12 * spring, 0, 0)
end

-- bowled over by a sliding peel-slipper: sliding along on your bottom, arms windmilling
MOVES.bowl = function(pose, t, layer)
	local d = layer.dur
	local k = keys(t, { { 0, 0 }, { 0.12, 1 }, { d - 0.25, 1 }, { d, 0 } })
	local lean = if reduced then 0.45 else 0.85
	add(pose, "Root", lean * k, 0, 0.12 * sin(t * 9) * k)
	add(pose, "RHip", 1.3 * k, 0, 0)
	add(pose, "LHip", 1.1 * k, 0, 0)
	add(pose, "RShoulder", (1.8 + 0.5 * sin(t * 16)) * k, 0, 0.5 * k)
	add(pose, "LShoulder", (1.8 + 0.5 * sin(t * 16 + PI)) * k, 0, -0.5 * k)
end

-- honked at by a duck: a jump of fright
MOVES.startle = function(pose, t)
	local s = keys(t, { { 0, 0 }, { 0.06, 1 }, { 0.2, 0.8 }, { 0.45, 0 } })
	add(pose, "RShoulder", 1.6 * s, 0, 0.7 * s)
	add(pose, "LShoulder", 1.6 * s, 0, -0.7 * s)
	add(pose, "Neck", 0.3 * s, 0, 0)
	add(pose, "Waist", 0.12 * s, 0, 0)
	add(pose, "Root", -0.06 * s, 0, 0)
end

-- an item upgraded: hold it up high and give it a shake, with a little hop
MOVES.cheer = function(pose, t)
	local up = keys(t, { { 0, 0 }, { 0.08, -0.2 }, { 0.22, 2.6 }, { 0.6, 2.6 }, { 0.8, 0 } })
	local b = bump(t / 0.8)
	add(pose, "RShoulder", up, 0, 0.2 * sin(t * 30) * b)
	add(pose, "LShoulder", up * 0.5, 0, -0.4 * b)
	add(pose, "Neck", 0.2 * b, 0, 0)
	local hop = keys(t, { { 0, 0 }, { 0.1, 0.35 }, { 0.22, 0 } })
	add(pose, "RKnee", -hop, 0, 0)
	add(pose, "LKnee", -hop, 0, 0)
end

-- the Softener Cloud's nap: nodding off where you stand
MOVES.nap = function(pose, t, layer)
	local d = layer.dur
	local k = keys(t, { { 0, 0 }, { 0.35, 1 }, { d - 0.25, 1 }, { d, 0 } })
	local bob = 0.1 * sin(t * 2.4)
	add(pose, "Neck", (-0.65 + bob) * k, 0, 0.18 * k)
	add(pose, "Waist", -0.25 * k, 0, 0.05 * k)
	add(pose, "RShoulder", -0.15 * k, 0, -0.1 * k)
	add(pose, "LShoulder", -0.15 * k, 0, 0.1 * k)
	add(pose, "RKnee", -0.25 * k, 0, 0)
	add(pose, "LKnee", -0.25 * k, 0, 0)
	add(pose, "Root", 0, 0, 0.05 * sin(t * 1.2) * k)
end

local DURATION: { [string]: number } = {
	swing = LIFT + 0.25, place = 0.68, shoot = 0.46, spray = 0.75, zap = 1.0, dash = 0.35, tumble = 0.8, slip = 1.2, float = 2,
	dive = 1.0, land = 0.5, pounce = 0.75, bowl = 0.9, startle = 0.45, cheer = 0.8, nap = 1.5,
}
local FINISHER_DUR = LIFT_F + 0.3
local PERSISTENT: { [string]: boolean } = { glide = true, sleepy = true, static = true, charge = true }

-- ---------- writing joints ----------

-- Lays `q` (pose space) on top of what the Animator wrote this frame. If nothing rewrote the joint
-- since our last frame (no animation drives it), our own last value is not stacked again.
local function writeJoint(j: Joint, q: CFrame?)
	local motor = j.motor
	local current = motor.Transform
	local base = if j.written ~= nil and current == j.written then j.base else current
	if q then
		local value = j.r0inv * q * j.r0 * (base :: CFrame)
		motor.Transform = value
		j.written = value
		j.base = base
	elseif j.written ~= nil then
		if current == j.written then
			motor.Transform = base :: CFrame -- nothing animates this joint: put its pose back
		end
		j.written = nil
		j.base = nil
	end
end

-- ---------- the towel ----------

local function segIndex(name: string): number?
	local n = string.match(name, "^Seg(%d)$")
	return if n then tonumber(n) else nil
end

-- the swing axis in the handle's space: tip down = positive, with a little sideways sweep
local SWING_AXIS = Vector3.new(1, 0.3, 0).Unit
-- The Blender towel (tools/blender/items/towel.py): a flat cloth, Root at the grip, then Seg1 = the
-- end gathered in the fist (kept nearly rigid) and Seg2..Seg6 along the cloth; across the cloth it
-- bends cleanly far past these limits (45 degrees per joint, 75 for Seg5 / Seg6), sideways only
-- ~20 (SWING_AXIS stays mostly across). The Part towel's Seg1..Seg6 are flat strips.
local BONE_WEIGHT = { 0.1, 1, 1, 1, 1, 1 }
local BONE_LIMIT = { 0.3, 0.78, 0.78, 0.78, 1.25, 1.25 }

local function buildTowel(rig: Rig, tool: Instance)
	rig.towelTool = tool
	rig.towelLook = tool:GetAttribute("Look")
	rig.towelBuilt = os.clock()
	rig.towelSegs = {}
	rig.towelHandle = nil
	local handle = tool:FindFirstChild("Handle")
	if not (handle and handle:IsA("BasePart")) then
		return
	end
	rig.towelHandle = handle
	local tipAtt = handle:FindFirstChild("Tip")
	rig.towelLength = if tipAtt and tipAtt:IsA("Attachment") and tipAtt.Position.Z > 1 then tipAtt.Position.Z else 4
	for _, d in ipairs(tool:GetDescendants()) do
		local index = segIndex(d.Name)
		if index then
			if d:IsA("Bone") then
				-- rest frame of the bone in its part's space (its Transform aside)
				local cf = d.CFrame
				local parent = d.Parent
				while parent and parent:IsA("Bone") do
					cf = parent.CFrame * cf
					parent = parent.Parent
				end
				local part = d:FindFirstAncestorWhichIsA("BasePart")
				if part then
					local r = cf.Rotation
					local axis = part.CFrame:VectorToObjectSpace(handle.CFrame:VectorToWorldSpace(SWING_AXIS))
					local along = handle.CFrame:PointToObjectSpace(part.CFrame * cf.Position).Z
					table.insert(rig.towelSegs, { index = index, bone = d, motor = nil, r = r, rinv = r:Inverse(), axis = axis, weight = BONE_WEIGHT[index] or 1, limit = BONE_LIMIT[index] or 0.78, along = along })
				end
			elseif d:IsA("Motor6D") then
				local part0 = d.Part0
				local along = if part0 then handle.CFrame:PointToObjectSpace(part0.CFrame * d.C0.Position).Z else 0
				table.insert(rig.towelSegs, { index = index, bone = nil, motor = d, r = CFrame.identity, rinv = CFrame.identity, axis = SWING_AXIS, weight = 1, limit = 0.9, along = along })
			end
		end
	end
	table.sort(rig.towelSegs, function(a, b)
		return a.index < b.index
	end)
end

-- Where the towel's tip is (world height) for these bends (one per towelSegs entry): the cloth
-- runs along the handle's +Z and bends tip-down about the handle's X (SWING_AXIS's sideways part
-- left out - this is only for the floor check). A model with a second skeleton (an outline) has
-- each SegN twice, bent the same: one chain is followed.
local function tipHeight(rig: Rig, handle: BasePart, angles: { number }): number
	local segs = rig.towelSegs
	local y, z, turn = 0, segs[1].along, 0
	local k = 1
	while k <= #segs do
		local seg = segs[k]
		turn += angles[k]
		local nextK = k + 1
		while nextK <= #segs and segs[nextK].index == seg.index do
			nextK += 1
		end
		local len = (if nextK <= #segs then segs[nextK].along else rig.towelLength) - seg.along
		y -= len * sin(turn)
		z += len * math.cos(turn)
		k = nextK
	end
	return (handle.CFrame * Vector3.new(0, y, z)).Y
end

-- Keeps the towel's tip at or above `above` (world height): first straightens every bend toward
-- the hand's line, just enough; if even a straight towel would reach the floor (the hand is that
-- low), curls the far end up off it, the way cloth bends where it meets the ground. `angles` is
-- changed in place.
local function clearFloor(rig: Rig, handle: BasePart, angles: { number }, above: number)
	if tipHeight(rig, handle, angles) >= above then
		return
	end
	local n = #angles
	local trial = table.create(n, 0)
	-- bisect the least change that clears (lo: still too low, hi: clears)
	local lo, hi = 0, 1
	for _ = 1, 6 do
		local k = (lo + hi) / 2
		for i, a in ipairs(angles) do
			trial[i] = a * (1 - k)
		end
		if tipHeight(rig, handle, trial) >= above then
			hi = k
		else
			lo = k
		end
	end
	for i, a in ipairs(angles) do
		angles[i] = a * (1 - hi)
	end
	if tipHeight(rig, handle, angles) >= above then
		return
	end
	local segs = rig.towelSegs
	local function curl(u: number, into: { number })
		for i = 1, n do
			into[i] = clamp(angles[i] - u * (segs[i].index - 1) / 5, -segs[i].limit, segs[i].limit)
		end
	end
	lo, hi = 0, 1.2
	for _ = 1, 6 do
		local u = (lo + hi) / 2
		curl(u, trial)
		if tipHeight(rig, handle, trial) >= above then
			hi = u
		else
			lo = u
		end
	end
	curl(hi, angles)
end

-- The floor under the character: the bottom of its feet.
local function floorOf(rig: Rig): number?
	local root = rig.root
	if not root then
		return nil
	end
	local humanoid = rig.humanoid
	local legs = if rig.r6 or not humanoid then 2 else humanoid.HipHeight
	return root.Position.Y - root.Size.Y / 2 - legs
end

-- how far segment i curls back while the towel is up over the shoulder
local function curledOf(i: number): number
	return -0.62 * (0.5 + 0.5 * i / 6)
end

-- radians segment i bends at time t after a swing started (math.huge: no swing); `chain`: the towel
-- was already curled back over the shoulder (a held loop); `finisher`: the combo finisher - a
-- longer curl back (WIND_F), a deeper curl and a bigger crack wobble
local function whip(t: number, i: number, sway: number, chain: boolean?, finisher: boolean?): number
	local w = i / 6
	local wind = if finisher then WIND_F else WIND
	local lash = (if finisher then CRACK_F else CRACK) - wind
	local depth = if finisher then 1.25 else 1
	local curled = curledOf(i)
	local deep = curled * depth
	if t < wind then
		local from = if chain then curled else DROOP
		return from + (deep - from) * ease(t / wind)
	end
	-- the lash unrolls the towel from the hand out: each segment straightens over half the lash, a
	-- little after the one before it, so the tip comes straight exactly at the crack
	local unrollT = lash * 0.5
	local tl = t - wind - (i - 1) * (lash - unrollT) / 5
	if tl <= 0 then
		return deep
	end
	local unroll = ease(tl / unrollT)
	local wobble = (0.25 + 0.5 * w) * depth * sin(tl * 34) * exp(-tl * 8) * unroll
	local settle = ease((tl - 0.15) / 0.25)
	return deep * (1 - unroll) + wobble + (DROOP + sway) * settle
end

local function updateTowel(rig: Rig, t: number, near: boolean)
	-- the held towel (re-found when it changes, is re-skinned, or its bones stream in late)
	local tool = rig.character:FindFirstChild("Item_Towel")
	local stale = tool ~= nil and (tool:GetAttribute("Look") ~= rig.towelLook or (#rig.towelSegs == 0 and os.clock() - rig.towelBuilt > 1))
	if tool ~= rig.towelTool or stale then
		if tool then
			buildTowel(rig, tool)
		else
			rig.towelTool = nil
			rig.towelSegs = {}
		end
	end
	if not rig.towelTool or #rig.towelSegs == 0 then
		return
	end
	local since = clock - rig.towelSwing
	local swinging = rig.towelSwing > 0 and (since < 0.9 or rig.holdW > 0.02)
	if not swinging and not near then
		return
	end
	-- held: after the follow-through the towel is lifted back over the shoulder with the arm (a
	-- quick back cast: it flies up and over, a beat behind the hand) and hangs down your back
	local lift = if rig.towelFinisher then LIFT_F else LIFT
	local again = if swinging then rig.holdW * ease((since - lift - 0.05) / LIFT_TIME) else 0
	local angles = {}
	for k, seg in ipairs(rig.towelSegs) do
		local sway = 0.05 * sin(t * 2.1 + seg.index * 0.7)
		local a = if swinging then whip(since, seg.index, sway, rig.towelChained, rig.towelFinisher) else DROOP + sway
		if again > 0 then
			a += (curledOf(seg.index) - a) * again
		end
		angles[k] = clamp(a * seg.weight, -seg.limit, seg.limit)
	end
	-- never into the floor (short avatars, R6's long arms, a low follow-through)
	local handle = rig.towelHandle
	local low = floorOf(rig)
	if handle and low then
		clearFloor(rig, handle, angles, low + FLOOR_GAP)
	end
	for k, seg in ipairs(rig.towelSegs) do
		local a = angles[k]
		if seg.bone then
			local q = CFrame.fromAxisAngle(seg.axis, a)
			seg.bone.Transform = seg.rinv * q * seg.r
		elseif seg.motor then
			seg.motor.Transform = CFrame.fromAxisAngle(seg.axis, a)
		end
	end
end

-- ---------- the loop ----------

local function step(dt: number)
	clock += dt * timeScale
	local now = clock
	local real = os.clock()
	local blend = min(1, dt * 8)
	local cam = workspace.CurrentCamera
	local camPos = if cam then cam.CFrame.Position else Vector3.zero
	for character, rig in pairs(rigs) do
		if character.Parent == nil then
			rigs[character] = nil
		else
			local root = rig.root
			local dist = if root then (root.Position - camPos).Magnitude else math.huge
			local pose: Pose = {}
			local any = false
			rig.turn = nil
			rig.holdW += ((if real < rig.whipHoldUntil then 1 else 0) - rig.holdW) * min(1, dt * 10)
			for i = #rig.layers, 1, -1 do
				local layer = rig.layers[i]
				local t = now - layer.t0
				local persistent = PERSISTENT[layer.kind]
				if persistent then
					local target = if layer.data.on then 1 else 0
					layer.data.w = (layer.data.w or 0) + (target - (layer.data.w or 0)) * blend
					if not layer.data.on and (layer.data.w or 0) < 0.02 then
						table.remove(rig.layers, i)
						continue
					end
				elseif t >= layer.dur and not (layer.kind == "swing" and rig.holdW > 0.02) then
					table.remove(rig.layers, i) -- (a held swing stays: the towel is up for the next crack)
					continue
				end
				if dist <= RANGE then
					local move = MOVES[layer.kind]
					if move then
						move(pose, t, layer, rig)
						any = true
					end
				end
			end
			-- holding the towel between swings: the arm rests lower, the towel hangs (updateTowel)
			local tool = rig.towelTool
			local holding = tool ~= nil and tool.Parent == character and not ItemRig.Has(character, "swing")
			rig.idleW += ((if holding then 1 else 0) - rig.idleW) * blend
			if rig.idleW > 0.01 and dist <= RANGE then
				add(pose, "RShoulder", HELD_ARM * rig.idleW, 0, 0.08 * rig.idleW)
				add(pose, "RElbow", 0.3 * rig.idleW, 0, 0)
				any = true
			end
			-- the root turn of a tumble is an axis-angle, the rest are Euler sums
			local axisAngle = rig.turn
			for name, j in pairs(rig.joints) do
				local v = pose[name]
				local q: CFrame? = nil
				if v then
					q = CFrame.Angles(v.X, v.Y, v.Z)
				end
				if name == "Root" and axisAngle and axisAngle.Magnitude > 1e-4 then
					local turn = CFrame.fromAxisAngle(axisAngle.Unit, axisAngle.Magnitude)
					q = if q then turn * q else turn
				end
				if rig.r6 and name == "Root" and pose.Waist then
					local w = pose.Waist * 0.6 -- R6 has no waist: lean the whole body a little instead
					local extra = CFrame.Angles(w.X, w.Y, w.Z)
					q = if q then q * extra else extra
				end
				if q or j.written ~= nil then
					writeJoint(j, q)
				end
			end
			updateTowel(rig, now, dist <= TOWEL_RANGE)
			-- the basket's wobble while its hider shuffles along
			local basket = rig.basket
			if basket then
				if basket.Parent == nil then
					rig.basket = nil
				elseif dist <= RANGE then
					local speed = if root then Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z).Magnitude else 0
					local k = clamp(speed / 10, 0, 1) * (if reduced then 0.4 else 1)
					basket.Transform = CFrame.new(0, 0.18 * math.abs(sin(now * 9)) * k, 0) * CFrame.Angles(0.05 * sin(now * 4.5) * k, 0, 0.09 * sin(now * 9) * k)
				end
			end
			if #rig.layers == 0 and not rig.towelTool and not rig.basket and not any then
				-- idle: put every joint back and forget the rig
				for _, j in pairs(rig.joints) do
					if j.written ~= nil then
						writeJoint(j, nil)
					end
				end
				rigs[character] = nil
			end
		end
	end
end

-- ---------- API ----------

-- Plays a move on a character (anyone's). data: tumble { dir: Vector3 (world), seconds, soft },
-- slip / float / bowl / nap / dive { seconds }, swing { finisher }, zap { charge }, persistent ones
-- { on = true / false } (charge also { charge = 0..1 }).
function ItemRig.Play(character: Model?, kind: string, data: { [string]: any }?)
	if not character then
		return
	end
	local opts = data or {}
	if PERSISTENT[kind] and opts.on == false and not rigs[character] then
		return -- nothing to switch off (and no rig to make for it)
	end
	local rig = getRig(character)
	if PERSISTENT[kind] then
		for _, layer in ipairs(rig.layers) do
			if layer.kind == kind then
				layer.data.on = opts.on ~= false
				if type(opts.charge) == "number" then
					layer.data.charge = opts.charge
				end
				return
			end
		end
		if opts.on == false then
			return
		end
		table.insert(rig.layers, { kind = kind, t0 = clock, dur = math.huge, data = { on = true, w = 0, charge = opts.charge } })
		return
	end
	local dur = DURATION[kind]
	if kind == "swing" then
		-- a swing while the last one is still held up over the shoulder starts from up there
		local chain = rig.holdW > 0.5 and ItemRig.Has(character, "swing")
		opts = table.clone(opts)
		opts.chain = chain
		rig.towelSwing = clock
		rig.towelChained = chain
		rig.towelFinisher = opts.finisher == true
		if opts.finisher == true then
			dur = FINISHER_DUR
		end
	end
	if not dur then
		return -- a towel-only swing for a kind with no body move
	end
	if type(opts.seconds) == "number" and opts.seconds > 0 then
		dur = clamp(opts.seconds, 0.2, 6)
	end
	if kind == "tumble" then
		local dir = opts.dir
		local root = rig.root
		if typeof(dir) == "Vector3" and root then
			local localDir = root.CFrame:VectorToObjectSpace(dir)
			local flatDir = Vector3.new(localDir.X, 0, localDir.Z)
			if flatDir.Magnitude > 1e-3 then
				-- up turns toward the push: the head goes first, a backward somersault
				local up = Vector3.new(0, 1, 0)
				rig.tumbleAxis = up:Cross(flatDir.Unit)
			end
		end
	end
	-- the same move again restarts it
	for i = #rig.layers, 1, -1 do
		if rig.layers[i].kind == kind then
			table.remove(rig.layers, i)
		end
	end
	table.insert(rig.layers, { kind = kind, t0 = clock, dur = dur, data = opts })
end

-- How fast the rigs' own clock runs (1 = real time, 0 = frozen: a hit-stop). Big moments only.
function ItemRig.SetTimeScale(scale: number)
	timeScale = clamp(scale, 0, 1)
end

-- The towel button is held (on) or let go. `seconds`: how long it counts as held without being told
-- again (other players: each of their held swings renews it); nil = until told otherwise.
function ItemRig.SetWhipHold(character: Model?, on: boolean, seconds: number?)
	if not character then
		return
	end
	if not on and not rigs[character] then
		return
	end
	local rig = getRig(character)
	rig.whipHoldUntil = if not on then 0 elseif seconds then os.clock() + seconds else math.huge
end

function ItemRig.Stop(character: Model?, kind: string)
	local rig = character and rigs[character]
	if not rig then
		return
	end
	for i = #rig.layers, 1, -1 do
		local layer = rig.layers[i]
		if layer.kind == kind then
			if PERSISTENT[kind] then
				layer.data.on = false
			else
				table.remove(rig.layers, i)
			end
		end
	end
end

function ItemRig.Has(character: Model?, kind: string): boolean
	local rig = character and rigs[character]
	if not rig then
		return false
	end
	for _, layer in ipairs(rig.layers) do
		if layer.kind == kind and (not PERSISTENT[kind] or layer.data.on) then
			return true
		end
	end
	return false
end

-- Keeps a rig alive for a character that holds a towel or hides under a basket (ItemFX polls).
function ItemRig.Watch(character: Model?, basket: Motor6D?)
	if not character then
		return
	end
	local rig = getRig(character)
	if basket then
		rig.basket = basket
	end
	if not rig.towelTool then
		local tool = character:FindFirstChild("Item_Towel")
		if tool then
			buildTowel(rig, tool)
		end
	end
end

-- A towel that was re-skinned (new look) gets its segments found again.
function ItemRig.RefreshTowel(character: Model?)
	local rig = character and rigs[character]
	if rig then
		rig.towelTool = nil
	end
end

function ItemRig.SetReduced(on: boolean)
	reduced = on
end

function ItemRig.Count(): number
	local n = 0
	for _ in pairs(rigs) do
		n += 1
	end
	return n
end

-- Puts every joint back (a character leaving, tests).
function ItemRig.Release(character: Model?)
	local rig = character and rigs[character]
	if not rig then
		return
	end
	for _, j in pairs(rig.joints) do
		writeJoint(j, nil)
	end
	rigs[character :: Model] = nil
end

local started = false
function ItemRig.Start()
	if started then
		return
	end
	started = true
	-- Stepped runs after the Animator has written this frame's pose: ours goes on top of it
	RunService.Stepped:Connect(function(_time, dt)
		local ok, err = pcall(step, dt)
		if not ok then
			warn("[ItemRig] " .. tostring(err))
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		if player.Character then
			ItemRig.Release(player.Character)
		end
	end)
end

-- the towel's bend per segment over a swing (the tests check it cracks straight and settles)
ItemRig.Whip = whip

return ItemRig
