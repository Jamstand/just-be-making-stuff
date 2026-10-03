-- ItemRig: procedural character animation for the item bar, on every client for every player
-- (ItemFX asks for it). Nothing here is an animation asset and nothing replicates:
--   * body moves (swing, throw, place, shoot, spray, zap, dash, slip, tumble, float, glide, sleepy,
--     static) are written into the character's Motor6D.Transform on RunService.Stepped, which runs
--     AFTER the Animator each frame: our rotation is laid on top of whatever the default Animate
--     script plays (walk, idle, toolnone), so the two never fight; when a move ends we stop writing
--     and the Animator's own pose is back the next frame (or we put back the last one it wrote).
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
--      ItemRig.SetWhipHold(character, on, seconds?),
--      ItemRig.SetReduced(on), ItemRig.Count() -> active rigs (tests)
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local ItemRig = {}

local sin, exp, clamp, min = math.sin, math.exp, math.clamp, math.min
local PI = math.pi
local TAU = math.pi * 2

local RANGE = 160 -- studs from the camera: farther characters skip the moves (they'd be dots)
local TOWEL_RANGE = 70 -- studs: a held towel droops and sways only this close
local WIND = 0.12 -- swing: wind-up seconds; the crack comes ~0.1 s later (ItemFX.CRACK_T = 0.22)
local DROOP = 0.2 -- radians per towel segment at rest (the towel hangs from the hand)
local LIFT = 0.32 -- swing: when the follow-through ends and, while held, the arm lifts the towel again
local HELD_ARM = -0.5 -- radians the arm rests lower than Roblox's "holding a tool" pose

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

type TowelSeg = { index: number, bone: Bone?, motor: Motor6D?, r: CFrame, rinv: CFrame, axis: Vector3, weight: number, limit: number }

type Rig = {
	character: Model,
	r6: boolean,
	joints: { [string]: Joint },
	layers: { Layer },
	root: BasePart?,
	towelTool: Instance?,
	towelLook: any,
	towelBuilt: number,
	towelSegs: { TowelSeg },
	towelSwing: number, -- os.clock() of the last swing (0 = none)
	towelChained: boolean, -- that swing started with the towel already up (a held loop)
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
			towelTool = nil,
			towelLook = nil,
			towelBuilt = 0,
			towelSegs = {},
			towelSwing = 0,
			towelChained = false,
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

-- the Towel Snap: an overhead crack. Up and back over the shoulder, lashed down in front, a
-- follow-through; then either back to the hold (let go) or up over the shoulder again (held: the
-- next swing of the loop starts from there, `chain`). Rotations about x raise the arm forward/up.
local SWING_UP = { RShoulder = Vector3.new(2.2, -0.25, 0.3), RElbow = Vector3.new(1.05, 0, 0), LShoulder = Vector3.new(0.3, 0, 0), Waist = Vector3.new(0.14, -0.2, 0), Neck = Vector3.new(0.1, -0.08, 0) }
local SWING_DOWN = { RShoulder = Vector3.new(-1.0, 0.25, -0.15), RElbow = Vector3.new(0, 0, 0), LShoulder = Vector3.new(-0.25, 0, 0), Waist = Vector3.new(-0.2, 0.18, 0), Neck = Vector3.new(-0.12, 0.08, 0) }
local SWING_FOLLOW = { RShoulder = Vector3.new(-0.75, 0.15, -0.1), RElbow = Vector3.new(0.25, 0, 0), LShoulder = Vector3.new(-0.1, 0, 0), Waist = Vector3.new(-0.1, 0.1, 0), Neck = Vector3.new(-0.05, 0.04, 0) }

MOVES.swing = function(pose, t, layer, rig)
	local chain = layer.data.chain == true
	for joint, up in pairs(SWING_UP) do
		local down, follow = SWING_DOWN[joint], SWING_FOLLOW[joint]
		local v: Vector3
		if t < WIND then
			v = if chain then up else up * ease(t / WIND) -- a held loop is already up there
		elseif t < 0.22 then
			v = up:Lerp(down, ease((t - WIND) / (0.22 - WIND))) -- the lash: the crack lands at 0.22
		elseif t < LIFT then
			v = down:Lerp(follow, ease((t - 0.22) / (LIFT - 0.22)))
		else
			-- let go: settle back to the hold; held: lift it over the shoulder again for the next crack
			local rest = follow * (1 - ease((t - LIFT) / 0.25))
			local again = follow:Lerp(up, ease((t - LIFT) / 0.55))
			v = rest:Lerp(again, rig.holdW)
		end
		add(pose, joint, v.X, v.Y, v.Z)
	end
end

-- drop a peel / set the duck down: bend, reach down, come back up
MOVES.place = function(pose, t)
	local bend = keys(t, { { 0, 0 }, { 0.2, -0.45 }, { 0.32, -0.45 }, { 0.6, 0 } })
	add(pose, "Waist", bend, 0, 0)
	add(pose, "RShoulder", keys(t, { { 0, 0 }, { 0.2, -0.95 }, { 0.32, -0.95 }, { 0.6, 0 } }), 0, 0)
	add(pose, "Neck", bend * 0.6, 0, 0)
	add(pose, "RHip", -bend * 0.5, 0, 0)
	add(pose, "LHip", -bend * 0.5, 0, 0)
	add(pose, "RKnee", bend * 0.9, 0, 0)
	add(pose, "LKnee", bend * 0.9, 0, 0)
end

-- Bubble Blaster: the other hand steadies it, a little recoil
MOVES.shoot = function(pose, t)
	add(pose, "RShoulder", keys(t, { { 0, 0 }, { 0.05, 0.3 }, { 0.2, 0.05 }, { 0.42, 0 } }), 0, 0)
	add(pose, "LShoulder", keys(t, { { 0, 0 }, { 0.08, 1.25 }, { 0.3, 1.25 }, { 0.42, 0 } }), 0, keys(t, { { 0, 0 }, { 0.08, -0.55 }, { 0.3, -0.55 }, { 0.42, 0 } }))
	add(pose, "Waist", 0, keys(t, { { 0, 0 }, { 0.08, 0.18 }, { 0.42, 0 } }), 0)
	add(pose, "Root", keys(t, { { 0, 0 }, { 0.05, 0.06 }, { 0.25, 0 } }), 0, 0)
end

-- Softener Cloud: a few quick trigger pumps
MOVES.spray = function(pose, t, layer)
	local fade = 1 - ease((t - layer.dur + 0.2) / 0.2)
	local pump = math.abs(sin(t * 22)) * 0.14 * fade
	add(pose, "RShoulder", (0.2 + pump) * min(t / 0.08, 1) * fade, 0, 0)
	add(pose, "Waist", 0, 0.12 * sin(t * 6) * fade, 0)
end

-- Static Balloon: thrust it up - ZAP - then rub it on your head, crackling
MOVES.zap = function(pose, t)
	local rub = if t > 0.25 and t < 0.75 then sin(t * 40) * 0.3 * bump((t - 0.25) / 0.5) else 0
	add(pose, "RShoulder", keys(t, { { 0, 0 }, { 0.1, 2.3 }, { 0.25, 2.3 }, { 0.35, 1.5 }, { 0.75, 1.5 }, { 1.0, 0 } }), rub, keys(t, { { 0, 0 }, { 0.25, 0 }, { 0.35, -0.55 }, { 0.75, -0.55 }, { 1.0, 0 } }))
	add(pose, "RElbow", keys(t, { { 0, 0 }, { 0.25, 0 }, { 0.35, 1.3 }, { 0.75, 1.3 }, { 1.0, 0 } }), 0, 0)
	add(pose, "Neck", 0, rub * 0.5, 0)
	add(pose, "Root", 0, 0, if t > 0.05 and t < 0.3 then sin(t * 60) * 0.05 else 0) -- a little shiver
end

-- Slipper Dash: lean in, arms back, a long stride
MOVES.dash = function(pose, t, layer)
	local k = bump(t / layer.dur)
	add(pose, "Root", -0.35 * k, 0, 0)
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

local DURATION: { [string]: number } = {
	swing = LIFT + 0.25, place = 0.6, shoot = 0.42, spray = 0.75, zap = 1.0, dash = 0.35, tumble = 0.8, slip = 1.2, float = 2,
}
local PERSISTENT: { [string]: boolean } = { glide = true, sleepy = true, static = true }

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
	local handle = tool:FindFirstChild("Handle")
	if not (handle and handle:IsA("BasePart")) then
		return
	end
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
					table.insert(rig.towelSegs, { index = index, bone = d, motor = nil, r = r, rinv = r:Inverse(), axis = axis, weight = BONE_WEIGHT[index] or 1, limit = BONE_LIMIT[index] or 0.78 })
				end
			elseif d:IsA("Motor6D") then
				table.insert(rig.towelSegs, { index = index, bone = nil, motor = d, r = CFrame.identity, rinv = CFrame.identity, axis = SWING_AXIS, weight = 1, limit = 0.9 })
			end
		end
	end
end

-- how far segment i curls back while the towel is up over the shoulder
local function curledOf(i: number): number
	return -0.62 * (0.5 + 0.5 * i / 6)
end

-- radians segment i bends at time t after a swing started (math.huge: no swing); `chain`: the towel
-- was already curled back over the shoulder (a held loop)
local function whip(t: number, i: number, sway: number, chain: boolean?): number
	local w = i / 6
	local curled = curledOf(i)
	if t < WIND then
		return if chain then curled else DROOP + (curled - DROOP) * ease(t / WIND)
	end
	local tl = t - WIND - (i - 1) * 0.018 -- the lash reaches each segment a little later
	if tl <= 0 then
		return curled
	end
	local unroll = ease(tl / 0.06)
	local wobble = (0.25 + 0.5 * w) * sin(tl * 34) * exp(-tl * 8) * unroll
	local settle = ease((tl - 0.15) / 0.25)
	return curled * (1 - unroll) + wobble + (DROOP + sway) * settle
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
	local since = os.clock() - rig.towelSwing
	local swinging = rig.towelSwing > 0 and (since < 0.8 or rig.holdW > 0.02)
	if not swinging and not near then
		return
	end
	-- held: after the follow-through the towel curls back over the shoulder with the arm
	local again = if swinging then rig.holdW * ease((since - LIFT) / 0.55) else 0
	for _, seg in ipairs(rig.towelSegs) do
		local sway = 0.05 * sin(t * 2.1 + seg.index * 0.7)
		local a = if swinging then whip(since, seg.index, sway, rig.towelChained) else DROOP + sway
		if again > 0 then
			a += (curledOf(seg.index) - a) * again
		end
		a = clamp(a * seg.weight, -seg.limit, seg.limit)
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
	local now = os.clock()
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
			rig.holdW += ((if now < rig.whipHoldUntil then 1 else 0) - rig.holdW) * min(1, dt * 10)
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
-- slip / float { seconds }, persistent ones { on = true / false }.
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
				return
			end
		end
		if opts.on == false then
			return
		end
		table.insert(rig.layers, { kind = kind, t0 = os.clock(), dur = math.huge, data = { on = true, w = 0 } })
		return
	end
	local dur = DURATION[kind]
	if kind == "swing" then
		-- a swing while the last one is still held up over the shoulder starts from up there
		local chain = rig.holdW > 0.5 and ItemRig.Has(character, "swing")
		opts = table.clone(opts)
		opts.chain = chain
		rig.towelSwing = os.clock()
		rig.towelChained = chain
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
	table.insert(rig.layers, { kind = kind, t0 = os.clock(), dur = dur, data = opts })
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
