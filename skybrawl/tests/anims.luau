--[[
    Drives the real animation player (client FighterAnimator) headlessly,
    under Lune, on a fake legend rig built from Motor6Ds, and checks that
    every animation the game can ask for plays, flows and returns cleanly.
    Run from the skybrawl folder with:  lune run tests/anims

      - the client code calls animator functions that exist, and every
        movement state and dodge kind the sim emits has a clip
      - every locomotion loop (Idle/Run/Jump/Fall/WallSlide, per weapon, at
        every run speed, both facings) plays without pops: the biggest
        joint turn between two frames stays small, including across the
        loop seam, and the pose actually moves
      - state changes crossfade smoothly
      - every dodge and the dash play, change the pose, end on time and
        blend back into the locomotion
      - every attack of every legend x weapon x slot plays with the move's
        timing, charges and releases, ends early on landing or when cut
        short in the air, drives the weapon trail, and returns
      - hurt, tumble, air jump, land and throw play and return
      - hit-stop freezes the pose, then resumes
      - facing left mirrors the pose exactly and moves a one-handed weapon
        to the other hand (and back)
      - other players' locomotion is read correctly from their movement
      - the R15 avatar rig path and menu previews work too; previews
        survive the end of a match, ignore the training time scale, and
        still (portrait) rigs are posed once and then cost nothing
]]

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")

local h = require("./harness")

local CFrame, Vector3, Instance, Enum, Color3 =
	roblox.CFrame, roblox.Vector3, roblox.Instance, roblox.Enum, roblox.Color3

local Config = h.require("Config")
local Legends = h.require("Legends")
local Weapons = h.require("Weapons")
local FighterSim = h.require("FighterSim")
local AnimationData = h.require("AnimationData")
local FighterRigs = h.require("FighterRigs")

local DT = 1 / 60
local JOINTS = AnimationData.Joints

-- Fake services -------------------------------------------------------------

local now = 0 -- the animator's os.clock
local frame = nil -- the PreRender callback
local warnings = {}

local function easeValue(a, style, dir)
	local f
	local name = style.Name
	if name == "Linear" then
		return a
	elseif name == "Quad" then
		f = function(x)
			return x * x
		end
	elseif name == "Cubic" then
		f = function(x)
			return x * x * x
		end
	elseif name == "Sine" then
		f = function(x)
			return 1 - math.cos(x * math.pi / 2)
		end
	else
		error("test easing has no " .. name)
	end
	local d = dir.Name
	if d == "In" then
		return f(a)
	elseif d == "Out" then
		return 1 - f(1 - a)
	end
	return a < 0.5 and f(2 * a) / 2 or 1 - f(2 - 2 * a) / 2
end

local sharedProxy = setmetatable({}, {
	__index = function(_, child)
		return { __module = child }
	end,
})
local fakeGame = {
	GetService = function(_, name)
		if name == "RunService" then
			return {
				PreRender = {
					Connect = function(_, fn)
						frame = fn
						return {
							Disconnect = function()
								frame = nil
							end,
						}
					end,
				},
			}
		elseif name == "TweenService" then
			return {
				GetValue = function(_, a, style, dir)
					return easeValue(a, style, dir)
				end,
			}
		end
		return {
			WaitForChild = function()
				return sharedProxy
			end,
			FindFirstChild = function()
				return nil
			end,
		}
	end,
}

local FighterAnimator = h.requireClient("FighterAnimator", {
	game = fakeGame,
	Instance = Instance,
	Enum = Enum,
	Color3 = Color3,
	os = {
		clock = function()
			return now
		end,
	},
	warn = function(...)
		local parts = {}
		for _, v in { ... } do
			table.insert(parts, tostring(v))
		end
		table.insert(warnings, table.concat(parts, " "))
	end,
})
FighterAnimator.init()
h.expect(frame ~= nil, "FighterAnimator.init did not connect to PreRender")

local workspaceFolder = Instance.new("Folder")
workspaceFolder.Name = "Workspace"

local function step(frames)
	for _ = 1, frames or 1 do
		now += DT
		frame(DT)
	end
end

local function frames(seconds)
	return math.ceil(seconds / DT + 1e-6)
end

-- Fake rigs -----------------------------------------------------------------

local function vec(t)
	return Vector3.new(t[1], t[2], t[3])
end

local function face(model, facing)
	local hrp = model:FindFirstChild("HumanoidRootPart")
	local pos = hrp.Position
	hrp.CFrame = CFrame.lookAt(pos, pos + Vector3.new(facing, 0, 0))
end

local function place(model, x, y)
	local hrp = model:FindFirstChild("HumanoidRootPart")
	local pos = Vector3.new(x, y, 0)
	local facing = hrp.CFrame.LookVector.X >= 0 and 1 or -1
	hrp.Position = pos
	hrp.CFrame = CFrame.lookAt(pos, pos + Vector3.new(facing, 0, 0))
end

-- A character carrying a legend's VisualRig (what LegendRig.build makes),
-- with Grip attachments and, optionally, a one-handed weapon in the right
-- hand with a swing trail.
local function legendRig(opts)
	opts = opts or {}
	local model = Instance.new("Model")
	model.Name = opts.name or "Fighter"
	model:SetAttribute("Legend", opts.legend or "Kestrel")
	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R15
	humanoid.HipHeight = 2
	humanoid.Parent = model
	local hrp = Instance.new("Part")
	hrp.Name = "HumanoidRootPart"
	hrp.Size = Vector3.new(2, 2, 1)
	hrp.Position = Vector3.zero
	hrp.CFrame = CFrame.lookAt(Vector3.zero, Vector3.new(1, 0, 0))
	hrp.Parent = model

	local rig = Instance.new("Model")
	rig.Name = "VisualRig"
	rig:SetAttribute("RigScale", Config.Art.FighterHeight / 6)
	local root = Instance.new("Part")
	root.Name = "RigRoot"
	root.Parent = rig
	local motors = {}
	for _, joint in FighterRigs.Joints do
		local part = Instance.new("Part")
		part.Name = joint.Part1
		part.Parent = rig
		local motor = Instance.new("Motor6D")
		motor.Name = joint.Name
		motor.C0 = CFrame.new(vec(joint.Pivot))
		motor.Transform = CFrame.identity
		motor.Parent = part
		motors[joint.Name] = motor
	end
	for _, side in { "Right", "Left" } do
		local grip = Instance.new("Attachment")
		grip.Name = "Grip"
		grip.CFrame = CFrame.new(0, -0.4, 0) * CFrame.Angles(math.rad(-90), 0, 0)
		grip.Parent = rig:FindFirstChild(side .. "Hand")
	end
	rig.Parent = model

	local weld, trail = nil, nil
	if opts.weapon then
		local folder = Instance.new("Folder")
		folder.Name = "EquippedWeapon"
		for _, side in opts.twoHanded and { "Right", "Left" } or { "Right" } do
			local weapon = Instance.new("Model")
			weapon.Name = side
			local body = Instance.new("Part")
			body.Name = "Body"
			body.Parent = weapon
			weapon.PrimaryPart = body
			local w = Instance.new("Weld")
			w.Name = "GripWeld"
			w.Part0 = rig:FindFirstChild(side .. "Hand")
			w.Part1 = body
			w.Parent = body
			local t = Instance.new("Trail")
			t.Enabled = false
			t.Parent = body
			weapon.Parent = folder
			if side == "Right" then
				weld, trail = w, t
			end
		end
		folder.Parent = model
	end
	model.Parent = workspaceFolder
	return { model = model, motors = motors, hrp = hrp, weld = weld, trail = trail, rig = rig }
end

-- A plain R15 avatar: parts named like R15 with Motor6Ds named like R15
-- joints. Some C0s carry a rotation, so the animator has to convert.
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
local function avatarRig()
	local model = Instance.new("Model")
	model.Name = "Avatar"
	model:SetAttribute("Legend", "Avatar")
	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R15
	humanoid.HipHeight = 2.1
	humanoid.Parent = model
	local hrp = Instance.new("Part")
	hrp.Name = "HumanoidRootPart"
	hrp.Size = Vector3.new(2, 2, 1)
	hrp.Position = Vector3.zero
	hrp.CFrame = CFrame.lookAt(Vector3.zero, Vector3.new(1, 0, 0))
	hrp.Parent = model
	local motors = {}
	local i = 0
	for joint, partName in R15_PART do
		i += 1
		local part = Instance.new("Part")
		part.Name = partName
		part.Parent = model
		local motor = Instance.new("Motor6D")
		motor.Name = joint
		-- a mix of plain and rotated C0 frames
		motor.C0 = i % 3 == 0 and CFrame.Angles(math.rad(90), 0, math.rad(-90)) or CFrame.new(0, 0.5, 0)
		motor.Transform = CFrame.identity
		motor.Parent = part
		motors[joint] = motor
	end
	model.Parent = workspaceFolder
	return { model = model, motors = motors, hrp = hrp }
end

-- Measuring ---------------------------------------------------------------------

local function finiteCFrame(cf)
	local p, x, y, z = cf.Position, cf.XVector, cf.YVector, cf.ZVector
	for _, v in { p, x, y, z } do
		if v.X ~= v.X or v.Y ~= v.Y or v.Z ~= v.Z or math.abs(v.X) == math.huge or math.abs(v.Y) == math.huge then
			return false
		end
	end
	return true
end

local function angleBetween(a, b)
	-- atan2 of the rotation's sine and cosine: accurate for tiny angles too,
	-- where acos of the trace loses everything to float32 rounding
	local rel = a:Inverse() * b
	local x, y, z = rel.XVector, rel.YVector, rel.ZVector
	local cos = (x.X + y.Y + z.Z - 1) / 2
	local sin = Vector3.new(y.Z - z.Y, z.X - x.Z, x.Y - y.X).Magnitude / 2
	return math.deg(math.atan2(sin, cos))
end

-- Watches a rig's joints frame by frame: how far each joint turns between
-- frames (degrees), so pops and stalls show up.
local Watch = {}
Watch.__index = Watch

local function watch(r)
	local self = setmetatable({ rig = r, prev = {}, series = {} }, Watch)
	self:reset()
	return self
end

function Watch:reset()
	for name, motor in self.rig.motors do
		self.prev[name] = motor.Transform
		self.series[name] = {}
	end
	self.maxTurn, self.maxTurnJoint, self.moved = 0, nil, 0
end

function Watch:step()
	step(1)
	for name, motor in self.rig.motors do
		local cf = motor.Transform
		h.expect(finiteCFrame(cf), name .. " transform is not finite")
		local turn = angleBetween(self.prev[name], cf)
		table.insert(self.series[name], turn)
		if turn > self.maxTurn then
			self.maxTurn, self.maxTurnJoint = turn, name
		end
		self.moved += turn
		self.prev[name] = cf
	end
end

function Watch:run(seconds)
	for _ = 1, frames(seconds) do
		self:step()
	end
end

-- A pop: one frame where a joint turns far more than it did the frame
-- before and after (fast swings are steady; a snap is a lone spike).
-- Returns a description of the worst one, or nil.
function Watch:spike(floor)
	local worst, desc = 0, nil
	for name, series in self.series do
		for i = 2, #series - 1 do
			local turn = series[i]
			local around = math.max(series[i - 1], series[i + 1])
			if turn > floor and turn > 3 * around + 15 and turn - around > worst then
				worst = turn - around
				desc = string.format(
					"%s snapped %.1f deg in one frame (%.1f before, %.1f after)",
					name,
					turn,
					series[i - 1],
					series[i + 1]
				)
			end
		end
	end
	return desc
end

-- The longest run of frames where a whole set of joints barely moves (a
-- hitch in a cycle).
function Watch:longestStall(joints, below)
	local longest, current = 0, 0
	for i = 1, #self.series[joints[1]] do
		local fastest = 0
		for _, joint in joints do
			fastest = math.max(fastest, self.series[joint][i])
		end
		current = fastest < below and current + 1 or 0
		longest = math.max(longest, current)
	end
	return longest
end

-- Max joint difference between two rigs' current poses.
local function poseGap(a, b)
	local worst = 0
	for name, motor in a.motors do
		worst = math.max(worst, angleBetween(motor.Transform, b.motors[name].Transform))
	end
	return worst
end

local function expectNoWarnings(where)
	h.expect(#warnings == 0, where .. ": animator warned: " .. table.concat(warnings, " | "))
end

-- A rig that only idles, to compare against after actions.
local function newPair(opts)
	local r = legendRig(opts)
	local ref = legendRig({ legend = opts and opts.legend, weapon = opts and opts.weapon })
	FighterAnimator.track(r.model, { isMe = true, legend = opts and opts.legend })
	FighterAnimator.track(ref.model, { isMe = true, legend = opts and opts.legend })
	if opts and opts.weapon then
		FighterAnimator.setWeapon(r.model, opts.weapon)
		FighterAnimator.setWeapon(ref.model, opts.weapon)
	end
	step(frames(0.3)) -- settle the first crossfade on both
	return r, ref
end

local function finish(...)
	for _, r in { ... } do
		FighterAnimator.untrack(r.model)
		r.model:Destroy()
	end
end

-- Thresholds (degrees of joint turn per frame at 60 fps) ------------------------
-- Joints may move fast (a jab's strike crosses 80 deg in a frame), so the
-- caps only catch garbage; pops are caught as spikes against neighbouring
-- frames, and run-cycle hitches as stalls.
local LOOP_MAX_TURN = 40 -- a run at 1.4x peaks around 30
local FADE_MAX_TURN = 45 -- state crossfades
local ACTION_MAX_TURN = 72 -- clips are capped at 55 deg a frame, blends can add a little; a snap is 100-180
local SPIKE_FLOOR = 25 -- a spike has to be at least this big to count
local LOOP_MIN_MOTION = 30 -- total degrees of joint motion over a loop: it isn't frozen
local SETTLE = 0.22 -- longest blend back into the loop (the animator's MAX_FADE) plus a frame
local RUN_STALL_FRAMES = 3 -- a leg (hip and knee) may hover under 1.5 deg/frame for at most this long at 1x

print("Wiring")

local clientSources = {}
for _, file in
	{
		"Controllers/MatchClient",
		"Controllers/Visuals",
		"Controllers/FighterAnimator",
		"Controllers/TrainingClient",
		"UI/FightersPanel",
		"UI/LegendView",
		"Main.client",
	}
do
	clientSources[file] = fs.readFile("src/client/" .. file .. ".luau")
end

h.test("every animator function the client calls exists", function()
	local seen = 0
	for file, source in clientSources do
		if file ~= "Controllers/FighterAnimator" then
			for name in string.gmatch(source, "FighterAnimator%.(%a+)%(") do
				h.expect(
					type(FighterAnimator[name]) == "function",
					file .. " calls FighterAnimator." .. name .. ", which doesn't exist"
				)
				seen += 1
			end
		end
	end
	h.expect(seen >= 20, "expected the client to call the animator in many places, found " .. seen)
end)

h.test("every movement state and dodge kind the sim produces has a clip", function()
	local sim = fs.readFile("src/shared/FighterSim.luau")
	local body = string.match(sim, "function FighterSim%.animState%(s%)(.-)\nend")
	local states = { WallSlide = true } -- MatchClient adds this one
	for state in string.gmatch(body, 'return "(%a+)"') do
		states[state] = true
	end
	h.expect(states.Run and states.Idle and states.Jump and states.Fall, "animState lost a state")
	for state in states do
		h.expect(FighterAnimator.hasClip("Loco." .. state), "no Loco." .. state)
		for _, weapon in Weapons.Order do
			-- weapon variants are optional (the animator falls back to Loco.*)
			local _ = FighterAnimator.hasClip(weapon .. "." .. state)
		end
	end
	local kinds = {}
	for kind in string.gmatch(sim, 'type = "Dodge", kind = "(%a+)"') do
		kinds[kind] = true
	end
	h.expect(kinds.Spot and kinds.Dash and kinds.Air and kinds.AirSpot and kinds.Chase, "the sim lost a dodge kind")
	local names = {
		Spot = "Loco.Dodge",
		AirSpot = "Loco.AirSpot",
		Air = "Loco.AirDodge",
		Chase = "Loco.Chase",
		Dash = "Loco.Dash",
	}
	for kind in kinds do
		h.expect(names[kind] and FighterAnimator.hasClip(names[kind]), "dodge kind " .. kind .. " has no clip")
	end
	local animatorSource = clientSources["Controllers/FighterAnimator"]
	for kind in kinds do
		h.expect(string.find(animatorSource, kind .. " = ", 1, true), "FighterAnimator.dodge doesn't handle " .. kind)
	end
end)

h.test("every legend x weapon x slot resolves to a clip through the animator's lookup", function()
	local count = 0
	for _, legendId in Legends.Order do
		local weapons = Legends.List[legendId].Weapons or Weapons.Order
		for _, weapon in weapons do
			for _, slot in Weapons.Slots do
				local move = Legends.getAttack(legendId, weapon, slot)
				h.expect(move, legendId .. " " .. weapon .. " " .. slot .. " has no move")
				local has = FighterAnimator.hasClip(move.AnimKey) or FighterAnimator.hasClip(weapon .. "." .. slot)
				h.expect(has, legendId .. " " .. weapon .. " " .. slot .. " has no clip")
				count += 1
			end
		end
		for _, slot in Weapons.Slots do
			h.expect(FighterAnimator.hasClip("Unarmed." .. slot), "Unarmed." .. slot .. " missing")
		end
	end
	print(string.format("       %d legend/weapon/slot attacks resolve", count))
end)

print("Locomotion")

local loopReport = {}

h.test("every locomotion loop plays smoothly for every weapon, speed and facing", function()
	-- the shared loops on Kestrel, and Brann's own (his heavy guard)
	local contexts = { { "Kestrel", "Unarmed" } }
	for _, w in Weapons.Order do
		table.insert(contexts, { "Kestrel", w })
	end
	for _, w in { "Unarmed", table.unpack(Legends.List.Brann.Weapons) } do
		table.insert(contexts, { "Brann", w })
	end
	local checks = 0
	for _, context in contexts do
		local legend, weapon = context[1], context[2]
		for _, facing in { 1, -1 } do
			local r = legendRig({ legend = legend, weapon = weapon ~= "Unarmed" and weapon or nil })
			face(r.model, facing)
			local rig = FighterAnimator.track(r.model, { isMe = true, legend = legend })
			FighterAnimator.setWeapon(r.model, weapon)
			local w = watch(r)
			for _, state in { "Idle", "Run", "Jump", "Fall", "WallSlide", "Block", "Stunned", "Tumble" } do
				for _, speed in state == "Run" and { 0.6, 1, 1.4 } or { 1 } do
					FighterAnimator.setLocomotion(r.model, state, speed)
					step(frames(0.2)) -- past the crossfade
					local length = rig.loco.clip.length
					w:reset()
					w:run(math.max(0.5, 2.2 * length / speed)) -- at least two loops, across the seam
					local label = string.format(
						"%s %s %s x%.1f facing %s",
						legend,
						weapon,
						state,
						speed,
						facing > 0 and "right" or "left"
					)
					h.expect(
						w.maxTurn <= LOOP_MAX_TURN,
						string.format("%s: %s turned %.1f deg in one frame", label, w.maxTurnJoint, w.maxTurn)
					)
					local spike = w:spike(SPIKE_FLOOR)
					h.expect(spike == nil, label .. ": " .. tostring(spike))
					if state == "Idle" or state == "Run" then
						h.expect(w.moved >= LOOP_MIN_MOTION, label .. " barely moves: " .. w.moved)
					end
					if state == "Run" then
						for _, side in { "Left", "Right" } do
							local stall = w:longestStall({ side .. "Hip", side .. "Knee" }, 1.5 * speed)
							local allowed = math.ceil(RUN_STALL_FRAMES / speed)
							h.expect(
								stall <= allowed,
								string.format("%s: the %s leg hitches (%d frames nearly still)", label, side, stall)
							)
						end
					end
					local key = state .. (state == "Run" and string.format(" x%.1f", speed) or "")
					loopReport[key] = math.max(loopReport[key] or 0, w.maxTurn)
					checks += 1
				end
			end
			expectNoWarnings(legend .. " " .. weapon)
			finish(r)
		end
	end
	print(string.format("       %d loops checked; worst joint turn per frame:", checks))
	for _, key in
		{ "Idle", "Run x0.6", "Run x1.0", "Run x1.4", "Jump", "Fall", "WallSlide", "Block", "Stunned", "Tumble" }
	do
		print(string.format("         %-10s %5.1f deg", key, loopReport[key] or 0))
	end
end)

local fadeReport = {}

h.test("state changes crossfade without pops", function()
	for _, weapon in { "Unarmed", "Sword", "Bow" } do
		local r = legendRig({ legend = "Yuki", weapon = weapon ~= "Unarmed" and weapon or nil })
		FighterAnimator.track(r.model, { isMe = true, legend = "Yuki" })
		FighterAnimator.setWeapon(r.model, weapon)
		step(frames(0.3))
		local w = watch(r)
		local worst, worstAt = 0, ""
		local sequence = {
			"Run",
			"Jump",
			"Fall",
			"Idle",
			"Run",
			"Fall",
			"WallSlide",
			"Jump",
			"Idle",
			"WallSlide",
			"Run",
			"Jump",
			"WallSlide",
			"Fall",
		}
		local prev = "Idle"
		for _, state in sequence do
			FighterAnimator.setLocomotion(r.model, state, 1.2)
			w:reset()
			w:run(0.3)
			local label = prev .. " -> " .. state
			local spike = w:spike(SPIKE_FLOOR)
			h.expect(spike == nil, weapon .. " " .. label .. ": " .. tostring(spike))
			if w.maxTurn > worst then
				worst, worstAt = w.maxTurn, label .. " (" .. tostring(w.maxTurnJoint) .. ")"
			end
			prev = state
		end
		h.expect(worst <= FADE_MAX_TURN, string.format("%s: %s turned %.1f deg in one frame", weapon, worstAt, worst))
		fadeReport[weapon] = worst
		-- switching weapons mid-run re-picks the loop smoothly
		FighterAnimator.setLocomotion(r.model, "Run", 1)
		step(frames(0.3))
		w:reset()
		FighterAnimator.setWeapon(r.model, weapon == "Sword" and "Hammer" or "Sword")
		w:run(0.3)
		h.expect(
			w.maxTurn <= FADE_MAX_TURN,
			string.format("%s: weapon swap while running turned %.1f deg in one frame", weapon, w.maxTurn)
		)
		expectNoWarnings(weapon)
		finish(r)
	end
	print(
		string.format(
			"       worst crossfade turn per frame: Unarmed %.1f, Sword %.1f, Bow %.1f deg",
			fadeReport.Unarmed,
			fadeReport.Sword,
			fadeReport.Bow
		)
	)
end)

-- The animator's locomotion lookup, worked out from the baked clip names.
local function expectedLoco(legend, weapon, state)
	local chain = { legend .. ".Loco." .. state, "Loco." .. state }
	if weapon ~= "Unarmed" then
		chain = { legend .. "." .. weapon .. "." .. state, weapon .. "." .. state, table.unpack(chain) }
	end
	for _, name in chain do
		if AnimationData.Clips[name] then
			return name
		end
	end
	return nil
end

h.test("a legend's own locomotion and one-shot clips come first, the shared ones fill in", function()
	-- Brann's mech arms get their own guard and block; the rest is shared
	h.expect(expectedLoco("Brann", "Unarmed", "Idle") == "Brann.Loco.Idle", "Brann has no guard of his own")
	h.expect(expectedLoco("Brann", "Unarmed", "Block") == "Brann.Loco.Block", "Brann has no block of his own")
	local r = legendRig({ legend = "Brann" })
	local rig = FighterAnimator.track(r.model, { isMe = true, legend = "Brann" })
	local function playing(state, weapon)
		FighterAnimator.setLocomotion(r.model, state)
		step(1)
		return rig.loco.clip.name, string.format("Brann %s %s played %s", weapon, state, rig.loco.clip.name)
	end
	for state, want in
		{ Idle = "Brann.Loco.Idle", Block = "Brann.Loco.Block", Run = "Loco.Run", Tumble = "Loco.Tumble" }
	do
		local got, label = playing(state, "Unarmed")
		h.expect(got == want, label .. ", expected " .. want)
	end
	-- armed: his own weapon clips, the shared weapon clips, then his own
	-- full-body clips before the shared ones
	FighterAnimator.setWeapon(r.model, "Gauntlets")
	for state, want in
		{
			Idle = "Brann.Gauntlets.Idle",
			Run = "Gauntlets.Run",
			Knockdown = "Brann.Loco.Knockdown",
			WallSlide = "Loco.WallSlide",
		}
	do
		local got, label = playing(state, "Gauntlets")
		h.expect(got == want, label .. ", expected " .. want)
	end
	h.expect(
		AnimationData.Clips["Brann.Gauntlets.Knockdown"] == nil and AnimationData.Clips["Gauntlets.Knockdown"] == nil,
		"the armed fall-through to Brann.Loco.Knockdown is no longer tested"
	)
	-- one-shot clips: his own dodge, landing, air jump and get-up, the shared dash
	FighterAnimator.setWeapon(r.model, "Unarmed")
	for _, case in
		{
			{ "Brann.Loco.Dodge", FighterAnimator.dodge, "Spot" },
			{ "Brann.Loco.Land", FighterAnimator.land },
			{ "Brann.Loco.AirJump", FighterAnimator.airJump },
			{ "Brann.Loco.GetUp", FighterAnimator.down, "GetUp" },
			{ "Loco.Dash", FighterAnimator.dodge, "Dash" },
		}
	do
		FighterAnimator.stopAction(r.model)
		step(frames(0.3))
		case[2](r.model, case[3])
		local got = rig.action and rig.action.clip.name
		h.expect(got == case[1], string.format("Brann played %s, expected %s", tostring(got), case[1]))
	end
	finish(r)
	-- legends without their own clips get the shared ones
	local k = legendRig({ legend = "Kestrel" })
	local krig = FighterAnimator.track(k.model, { isMe = true, legend = "Kestrel" })
	FighterAnimator.setLocomotion(k.model, "Block")
	FighterAnimator.land(k.model)
	step(1)
	h.expect(krig.loco.clip.name == "Loco.Block", "Kestrel blocked with " .. krig.loco.clip.name)
	h.expect(krig.action and krig.action.clip.name == "Loco.Land", "Kestrel landed with another clip")
	finish(k)
	-- every legend, weapon and state follows the lookup order
	local checked = 0
	for _, legendId in Legends.Order do
		for _, weapon in { "Unarmed", table.unpack(Legends.List[legendId].Weapons or {}) } do
			local f = legendRig({ legend = legendId, weapon = weapon ~= "Unarmed" and weapon or nil })
			local frig = FighterAnimator.track(f.model, { isMe = true, legend = legendId })
			FighterAnimator.setWeapon(f.model, weapon)
			for _, state in { "Idle", "Run", "Jump", "Fall", "WallSlide", "Block", "Stunned", "Knockdown", "Tumble" } do
				FighterAnimator.setLocomotion(f.model, state)
				step(1)
				local want = expectedLoco(legendId, weapon, state)
				h.expect(
					frig.loco.clip.name == want,
					string.format("%s %s %s played %s, expected %s", legendId, weapon, state, frig.loco.clip.name, want)
				)
				checked += 1
			end
			finish(f)
		end
	end
	-- fighting as your own avatar still squares up like the legend
	local a = avatarRig()
	a.model:SetAttribute("Legend", "Brann")
	local arig = FighterAnimator.track(a.model, { isMe = true, legend = "Brann" })
	step(1)
	h.expect(arig.loco.clip.name == "Brann.Loco.Idle", "avatar as Brann idles with " .. arig.loco.clip.name)
	finish(a)
	expectNoWarnings("legend clips")
	print(string.format("       %d legend/weapon/state lookups checked", checked))
end)

h.test("Brann's own dodge and landing play smoothly and return to his guard", function()
	for _, facing in { 1, -1 } do
		for _, case in
			{
				{ "dodge", FighterAnimator.dodge, "Spot", Config.Physics.SpotDodgeTime },
				{ "land", FighterAnimator.land, nil, AnimationData.Clips["Brann.Loco.Land"].Length },
			}
		do
			local name, fn, arg, duration = case[1], case[2], case[3], case[4]
			local r, ref = newPair({ legend = "Brann" })
			face(r.model, facing)
			face(ref.model, facing)
			step(1)
			local w = watch(r)
			fn(r.model, arg)
			local gapMid = 0
			for _ = 1, frames(duration * 0.5) do
				w:step()
				gapMid = math.max(gapMid, poseGap(r, ref))
			end
			h.expect(gapMid > 5, name .. " barely changed the pose (" .. gapMid .. " deg)")
			w:run(duration * 0.5 + 0.02)
			h.expect(
				w.maxTurn <= ACTION_MAX_TURN,
				string.format("Brann %s: %s turned %.1f deg in one frame", name, w.maxTurnJoint, w.maxTurn)
			)
			local spike = w:spike(SPIKE_FLOOR)
			h.expect(spike == nil, "Brann " .. name .. ": " .. tostring(spike))
			w:reset()
			w:run(SETTLE)
			local gap = poseGap(r, ref)
			h.expect(gap < 0.5, string.format("Brann %s left the pose %.1f deg off his guard", name, gap))
			expectNoWarnings("Brann " .. name)
			finish(r, ref)
		end
	end
end)

h.test("attacks settle into the fighter's own guard: no swing to the shared stance and back", function()
	-- Shared moves are authored to end in the shared stance (Brann's hammer
	-- over the shoulder); over the recovery's last span the animator eases
	-- into the guard he's in instead. Kestrel idles in the shared stance.
	local checked = 0
	for _, case in
		{
			{ "Brann", "Hammer", "NLight" },
			{ "Brann", "Hammer", "SAir" },
			{ "Brann", "Hammer", "NHeavy" },
			{ "Brann", "Gauntlets", "DLight" },
			{ "Brann", "Unarmed", "SLight" },
			{ "Kestrel", "Sword", "NLight" },
		}
	do
		local legendId, weapon, slot = case[1], case[2], case[3]
		h.expect(Legends.getAttack(legendId, weapon, slot) ~= nil, `{legendId} has no {weapon} {slot}`)
		for _, facing in { 1, -1 } do
			local label = string.format("%s %s %s facing %s", legendId, weapon, slot, facing > 0 and "right" or "left")
			local r, ref = newPair({ legend = legendId, weapon = weapon ~= "Unarmed" and weapon or nil })
			local rig = FighterAnimator.track(r.model)
			face(r.model, facing)
			face(ref.model, facing)
			step(1)
			FighterAnimator.playAttack(r.model, weapon, slot, 1, false)
			local keys = rig.action.clip.keys
			local lastSpan = keys[#keys - 1].t -- re-timed clips are keyed in seconds
			while rig.action and rig.action.t < lastSpan do
				step(1)
			end
			-- the gap to the idling twin only shrinks, down to nothing when the
			-- move ends
			local w = watch(r)
			local gap, grew = poseGap(r, ref), 0
			while rig.action do
				w:step()
				local cur = poseGap(r, ref)
				grew = math.max(grew, cur - gap)
				gap = cur
			end
			h.expect(grew < 1, string.format("%s: the recovery swung %.1f deg away from the guard", label, grew))
			h.expect(gap < 0.5, string.format("%s: the recovery ended %.1f deg off the guard", label, gap))
			-- so the blend out has nothing left to do
			w:reset()
			w:run(SETTLE)
			h.expect(w.maxTurn < 3, string.format("%s: the blend out turned %.1f deg in a frame", label, w.maxTurn))
			h.expect(poseGap(r, ref) < 0.5, label .. ": the pose is off the loop after the attack")
			expectNoWarnings(label)
			finish(r, ref)
			checked += 1
		end
	end
	print(string.format("       %d recoveries checked", checked))
end)

print("Dodges and dashes")

h.test("every dodge kind and the dash play, end on time and return to the loop", function()
	local kinds = { "Spot", "AirSpot", "Air", "Chase", "Dash" }
	local durations = {
		Spot = Config.Physics.SpotDodgeTime,
		AirSpot = Config.Physics.SpotDodgeTime,
		Air = Config.Physics.AirDodgeTime + 0.08,
		Chase = Config.Combat.ChaseDodgeTime + 0.06,
		Dash = AnimationData.Clips["Loco.Dash"].Length,
	}
	for _, facing in { 1, -1 } do
		for _, kind in kinds do
			local r, ref = newPair({ legend = "Vex", weapon = "Scythe" })
			face(r.model, facing)
			face(ref.model, facing)
			step(1)
			local w = watch(r)
			FighterAnimator.dodge(r.model, kind)
			-- during the dodge the pose leaves the idle loop
			local gapMid = 0
			for _ = 1, frames(durations[kind] * 0.5) do
				w:step()
				step(0)
				gapMid = math.max(gapMid, poseGap(r, ref))
			end
			h.expect(gapMid > 15, kind .. " dodge barely changed the pose (" .. gapMid .. " deg)")
			w:run(durations[kind] * 0.5 + 0.02)
			h.expect(
				w.maxTurn <= ACTION_MAX_TURN,
				string.format("%s dodge: %s turned %.1f deg in one frame", kind, w.maxTurnJoint, w.maxTurn)
			)
			local spike = w:spike(SPIKE_FLOOR)
			h.expect(spike == nil, kind .. " dodge: " .. tostring(spike))
			-- ...and is back in step with the loop after the blend out
			w:reset()
			w:run(SETTLE)
			h.expect(
				w.maxTurn <= FADE_MAX_TURN,
				string.format("%s dodge blend-out turned %.1f deg in one frame", kind, w.maxTurn)
			)
			local gap = poseGap(r, ref)
			h.expect(gap < 0.5, string.format("%s dodge left the pose %.1f deg off the loop afterwards", kind, gap))
			expectNoWarnings(kind)
			finish(r, ref)
		end
	end
end)

print("Attacks")

local GROUND_HEAVIES = { NHeavy = true, SHeavy = true, DHeavy = true }

-- Plays one attack to the end the way the game does, checking it along the
-- way. `how` = "plain" | "charge" | "autoRelease" | "land" | "cut".
local function playAttack(legendId, weapon, slot, facing, how, stats)
	local move = Legends.getAttack(legendId, weapon, slot)
	local r, ref = newPair({ legend = legendId, weapon = weapon ~= "Unarmed" and weapon or nil })
	face(r.model, facing)
	face(ref.model, facing)
	step(1)
	local charging = how == "charge" or how == "autoRelease"
	local w = watch(r)
	local label =
		string.format("%s %s %s (%s, facing %s)", legendId, weapon, slot, how, facing > 0 and "right" or "left")
	stats.seq = (stats.seq or 0) + 1
	FighterAnimator.playAttack(r.model, weapon, slot, stats.seq, charging)

	local total = move.Startup + move.Active + move.Recovery
	if how == "charge" then
		w:run(move.Startup * 0.6) -- wind up part way, then let go
		FighterAnimator.releaseCharge(r.model, stats.seq)
	elseif how == "autoRelease" then
		w:run((move.Charge or 0) + 0.3 + 0.01) -- the animator lets go on its own
	end
	-- play through the attack, watching the trail
	local trailOn, trailOffAfter = false, true
	local ran = 0
	local target = total
	if how == "land" then
		target = move.Startup + 0.1
	elseif how == "cut" then
		target = move.Startup + move.Active * 0.5
	end
	for _ = 1, frames(target) do
		w:step()
		ran += DT
		if r.trail and r.trail.Enabled then
			trailOn = true
		end
	end
	if how == "land" then
		FighterAnimator.landed(r.model) -- skips to recovery
		w:run(move.Recovery + 0.02)
	elseif how == "cut" then
		FighterAnimator.endAttack(r.model, stats.seq) -- landing cut an air attack short
	else
		w:run(0.02)
	end
	if w.maxTurn > ACTION_MAX_TURN then
		table.insert(
			stats.problems,
			string.format("%s: %s turned %.1f deg in one frame", label, w.maxTurnJoint, w.maxTurn)
		)
	end
	local spike = w:spike(60) -- flicks within the speed cap are fine
	if spike then
		table.insert(stats.problems, label .. ": " .. spike)
	end
	stats.maxTurn = math.max(stats.maxTurn or 0, w.maxTurn)
	if r.trail and how ~= "cut" and how ~= "land" and move.Active >= 0.03 then
		h.expect(trailOn, label .. ": the weapon trail never switched on during the swing")
	end
	-- blend out, then the pose is back in step with the loop
	w:reset()
	w:run(SETTLE)
	h.expect(
		w.maxTurn <= FADE_MAX_TURN + 6,
		string.format("%s: blend-out turned %.1f deg in one frame", label, w.maxTurn)
	)
	step(1)
	if r.trail then
		trailOffAfter = not r.trail.Enabled
	end
	h.expect(trailOffAfter, label .. ": the weapon trail stayed on after the attack")
	local gap = poseGap(r, ref)
	h.expect(gap < 0.5, string.format("%s: pose is %.1f deg off the loop after the attack", label, gap))
	expectNoWarnings(label)
	finish(r, ref)
	stats.count = (stats.count or 0) + 1
end

h.test("every attack of every legend plays with its timing and returns", function()
	local stats = { problems = {} }
	for _, legendId in Legends.Order do
		local weapons = Legends.List[legendId].Weapons or Weapons.Order
		local list = table.clone(weapons)
		table.insert(list, "Unarmed")
		local slots = table.clone(Weapons.Slots)
		table.insert(slots, "Ultimate")
		for _, weapon in list do
			for _, slot in slots do
				local move = Legends.getAttack(legendId, weapon, slot)
				local hows = { "plain" }
				if GROUND_HEAVIES[slot] and (move.Charge or 0) > 0 then
					table.insert(hows, "charge")
					table.insert(hows, "autoRelease")
				end
				if move.EndsOnLand then
					table.insert(hows, "land")
				end
				if move.Air then
					table.insert(hows, "cut")
				end
				for _, how in hows do
					playAttack(legendId, weapon, slot, how == "plain" and -1 or 1, how, stats)
				end
			end
		end
	end
	print(
		string.format("       %d attack plays checked; worst joint turn per frame %.1f deg", stats.count, stats.maxTurn)
	)
	h.expect(
		#stats.problems == 0,
		#stats.problems .. " attack plays snapped:\n         " .. table.concat(stats.problems, "\n         ")
	)
end)

h.test("attacks play on both facings and the mirrored pose is an exact mirror", function()
	local mirrorOf = {}
	for _, name in JOINTS do
		local other = name
		if string.sub(name, 1, 4) == "Left" then
			other = "Right" .. string.sub(name, 5)
		elseif string.sub(name, 1, 5) == "Right" then
			other = "Left" .. string.sub(name, 6)
		end
		mirrorOf[name] = other
	end
	local flip = CFrame.new(0, 0, 0, -1, 0, 0, 0, 1, 0, 0, 0, 1)
	local checked = 0
	for _, legendId in { "Kestrel", "Brann", "Sol" } do
		for _, weapon in Legends.List[legendId].Weapons do
			for _, slot in { "NLight", "SAir", "DHeavy", "NHeavy" } do
				local right = legendRig({ legend = legendId, weapon = weapon })
				local left = legendRig({ legend = legendId, weapon = weapon })
				face(left.model, -1)
				FighterAnimator.track(right.model, { isMe = true, legend = legendId })
				FighterAnimator.track(left.model, { isMe = true, legend = legendId })
				FighterAnimator.setWeapon(right.model, weapon)
				FighterAnimator.setWeapon(left.model, weapon)
				step(frames(0.3))
				FighterAnimator.playAttack(right.model, weapon, slot, 1, false)
				FighterAnimator.playAttack(left.model, weapon, slot, 1, false)
				local move = Legends.getAttack(legendId, weapon, slot)
				for _ = 1, frames(move.Startup + move.Active + move.Recovery) do
					step(1)
					for name, motor in right.motors do
						local expected = flip * motor.Transform * flip
						local got = left.motors[mirrorOf[name]].Transform
						local gap = angleBetween(expected, got)
						h.expect(
							gap < 0.05,
							string.format("%s %s %s: %s is %.2f deg off its mirror", legendId, weapon, slot, name, gap)
						)
						h.expect(
							(expected.Position - got.Position).Magnitude < 1e-3,
							legendId .. " " .. slot .. ": mirrored root offset differs"
						)
					end
					checked += 1
				end
				finish(right, left)
			end
		end
	end
	expectNoWarnings("mirror")
	print(string.format("       %d mirrored frames compared", checked))
end)

print("Reactions")

h.test("hurt, tumble, air jump, land, throw and the battle states play and return", function()
	local cases = {
		{
			"hurt (recoil)",
			function(m)
				FighterAnimator.hurt(m, 0.3, 30)
			end,
			0.3,
		},
		{
			"hurt (tumble)",
			function(m)
				FighterAnimator.hurt(m, 0.7, 90)
			end,
			0.7,
		},
		{
			"air jump",
			function(m)
				FighterAnimator.airJump(m)
			end,
			AnimationData.Clips["Loco.AirJump"].Length,
		},
		{
			"land",
			function(m)
				FighterAnimator.land(m)
			end,
			AnimationData.Clips["Loco.Land"].Length,
		},
		{
			"throw",
			function(m)
				FighterAnimator.throw(m)
			end,
			AnimationData.Clips["Loco.Throw"].Length,
		},
		{
			"ragdoll",
			function(m)
				FighterAnimator.hurt(m, 0.4, 40, true)
			end,
			0.4 + Config.Battle.TumbleHold,
		},
		{
			"knockdown",
			function(m)
				FighterAnimator.down(m, "Knockdown")
			end,
			Config.Battle.KnockdownTime,
		},
		{
			"get up",
			function(m)
				FighterAnimator.down(m, "GetUp")
			end,
			Config.Battle.GetUpTime,
		},
		{
			"tech roll",
			function(m)
				FighterAnimator.down(m, "Tech", 1)
			end,
			Config.Battle.TechRollTime,
		},
		{
			"tech in place",
			function(m)
				FighterAnimator.down(m, "Tech", 0)
			end,
			Config.Battle.TechRollTime,
		},
		{
			"guard break daze",
			function(m)
				FighterAnimator.stunned(m, Config.Battle.GuardBreakStun)
			end,
			Config.Battle.GuardBreakStun,
		},
		{
			"awaken",
			function(m)
				FighterAnimator.awaken(m, Config.Battle.AwakenFreeze)
			end,
			Config.Battle.AwakenFreeze,
		},
	}
	for _, case in cases do
		local name, fn, duration = case[1], case[2], case[3]
		local r, ref = newPair({ legend = "Moss", weapon = "Spear" })
		local w = watch(r)
		fn(r.model)
		local gapMid = 0
		for _ = 1, frames(duration * 0.5) do
			w:step()
			gapMid = math.max(gapMid, poseGap(r, ref))
		end
		h.expect(gapMid > 5, name .. " barely changed the pose (" .. gapMid .. " deg)")
		w:run(duration * 0.5 + 0.02)
		h.expect(
			w.maxTurn <= ACTION_MAX_TURN,
			string.format("%s: %s turned %.1f deg in one frame", name, w.maxTurnJoint, w.maxTurn)
		)
		local spike = w:spike(SPIKE_FLOOR)
		h.expect(spike == nil, name .. ": " .. tostring(spike))
		w:reset()
		w:run(SETTLE)
		local gap = poseGap(r, ref)
		h.expect(gap < 0.5, string.format("%s left the pose %.1f deg off the loop afterwards", name, gap))
		expectNoWarnings(name)
		finish(r, ref)
	end
	-- land() only plays when nothing else is going on
	local r, ref = newPair({ legend = "Moss", weapon = "Spear" })
	FighterAnimator.playAttack(r.model, "Spear", "NLight", 1, false)
	step(2)
	local before = {}
	for name, motor in r.motors do
		before[name] = motor.Transform
	end
	FighterAnimator.land(r.model)
	step(1)
	local move = Legends.getAttack("Moss", "Spear", "NLight")
	-- still attacking: the pose keeps following the attack, not a land clip
	FighterAnimator.stopAction(r.model)
	step(frames(0.2))
	h.expect(poseGap(r, ref) < 0.5, "stopAction didn't return to the loop")
	h.expect(move ~= nil and before.Root ~= nil, "sanity")
	finish(r, ref)
end)

h.test("hit-stop freezes the pose and then resumes", function()
	local r = legendRig({ legend = "Brann", weapon = "Hammer" })
	FighterAnimator.track(r.model, { isMe = true, legend = "Brann" })
	FighterAnimator.setWeapon(r.model, "Hammer")
	step(frames(0.3))
	FighterAnimator.playAttack(r.model, "Hammer", "SLight", 1, false)
	step(3)
	FighterAnimator.hitstop(r.model, 0.1)
	local frozen = {}
	for name, motor in r.motors do
		frozen[name] = motor.Transform
	end
	for _ = 1, frames(0.1) - 2 do -- (the last frame lands right where hit-stop ends)
		step(1)
		for name, motor in r.motors do
			-- (Lune keeps CFrames in 32-bit floats, hence the slack)
			h.expect(angleBetween(frozen[name], motor.Transform) < 0.1, "pose moved during hit-stop: " .. name)
		end
	end
	step(3)
	local moved = false
	for name, motor in r.motors do
		if angleBetween(frozen[name], motor.Transform) > 0.5 then
			moved = true
		end
	end
	h.expect(moved, "pose never resumed after hit-stop")
	expectNoWarnings("hitstop")
	finish(r)
end)

print("Weapon hand")

h.test("facing left moves a one-handed weapon to the left hand, and back", function()
	local r = legendRig({ legend = "Kestrel", weapon = "Sword" })
	FighterAnimator.track(r.model, { isMe = true, legend = "Kestrel" })
	FighterAnimator.setWeapon(r.model, "Sword")
	step(2)
	local rightHand = r.rig:FindFirstChild("RightHand")
	local leftHand = r.rig:FindFirstChild("LeftHand")
	h.expect(r.weld.Part0 == rightHand, "weapon should start in the right hand")
	face(r.model, -1)
	step(1)
	h.expect(r.weld.Part0 == leftHand, "weapon didn't move to the left hand when facing left")
	h.expect(r.weld.C0 == leftHand:FindFirstChild("Grip").CFrame, "weapon grip wasn't re-aimed for the left hand")
	face(r.model, 1)
	step(1)
	h.expect(r.weld.Part0 == rightHand, "weapon didn't move back to the right hand")
	finish(r)

	-- two-handed weapons (gauntlets) stay put
	local g = legendRig({ legend = "Brann", weapon = "Gauntlets", twoHanded = true })
	FighterAnimator.track(g.model, { isMe = true, legend = "Brann" })
	FighterAnimator.setWeapon(g.model, "Gauntlets")
	face(g.model, -1)
	step(2)
	h.expect(g.weld.Part0 == g.rig:FindFirstChild("RightHand"), "a two-handed weapon's right piece left the right hand")
	expectNoWarnings("hands")
	finish(g)
end)

print("Other fighters, avatars and previews")

-- Which locomotion clip a rig is playing, by matching its pose.
local function classify(r, candidates)
	local best, bestGap = nil, math.huge
	local scale = Config.Art.FighterHeight / 6
	for _, name in candidates do
		local clip = AnimationData.Clips[name]
		local steps = 60
		for i = 0, steps do
			local t = clip.Length * i / steps
			-- sample the clip the way the animator does
			local keys = clip.Keys
			local k0, k1 = keys[1], keys[1]
			if t >= keys[#keys].T then
				k0, k1 = keys[#keys], keys[#keys]
			else
				for j = 1, #keys - 1 do
					if t < keys[j + 1].T then
						k0, k1 = keys[j], keys[j + 1]
						break
					end
				end
			end
			local a = k0 == k1 and 0 or (t - k0.T) / math.max(k1.T - k0.T, 1e-6)
			if k0.E == "Constant" then
				a = 0
			elseif k0.E ~= "Linear" then
				local style, dir = string.match(k0.E, "^(%a+)%.?(%a*)$")
				a = easeValue(
					math.clamp(a, 0, 1),
					Enum.EasingStyle[style],
					Enum.EasingDirection[dir ~= "" and dir or "InOut"]
				)
			end
			local worst = 0
			for ji, joint in JOINTS do
				local o = (ji - 1) * 3
				local c0 = CFrame.Angles(math.rad(k0.R[o + 1]), math.rad(k0.R[o + 2]), math.rad(k0.R[o + 3]))
				local c1 = CFrame.Angles(math.rad(k1.R[o + 1]), math.rad(k1.R[o + 2]), math.rad(k1.R[o + 3]))
				local cf = a == 0 and c0 or c0:Lerp(c1, a)
				local got = r.motors[joint].Transform
				if ji == 1 then
					local off0 = k0.O and vec(k0.O) or Vector3.zero
					local off1 = k1.O and vec(k1.O) or Vector3.zero
					cf = CFrame.new(off0:Lerp(off1, a) * scale) * cf
				end
				worst = math.max(worst, angleBetween(cf.Rotation, got.Rotation))
			end
			if worst < bestGap then
				best, bestGap = name, worst
			end
		end
	end
	return best, bestGap
end

h.test("other players' running, jumping and falling is read from their movement", function()
	local Maps = h.require("Maps")
	local mapId = "SkyholdKeep"
	local world = Maps.getWorld(mapId)
	local origin = Vector3.new(2500, 120, 0)
	FighterAnimator.startMatch(mapId, origin)
	local ground = Maps.groundBelow(world, 0, 1)
	h.expect(ground ~= nil, "no ground at x = 0 on " .. mapId)
	local feet = 3 -- HipHeight 2 + half the root's height
	local r = legendRig({ legend = "Sol", weapon = "Sword" })
	place(r.model, origin.X, origin.Y + ground + feet)
	FighterAnimator.track(r.model, { isMe = false, legend = "Sol" })
	FighterAnimator.setWeapon(r.model, "Sword")
	local candidates = { "Sword.Idle", "Sword.Run", "Sword.Jump", "Sword.Fall" }

	local function expectState(expected, label)
		step(frames(0.4))
		local got, gap = classify(r, candidates)
		h.expect(
			got == expected,
			string.format("%s: playing %s (gap %.1f), expected %s", label, tostring(got), gap, expected)
		)
	end
	-- standing still
	expectState("Sword.Idle", "standing")
	-- running right along the ground at 20 studs/s
	local x = 0
	for _ = 1, frames(0.6) do
		x += 20 * DT
		place(r.model, origin.X + x, origin.Y + ground + feet)
		step(1)
	end
	local got, gap = classify(r, candidates)
	h.expect(got == "Sword.Run", string.format("running: playing %s (gap %.1f)", tostring(got), gap))
	-- rising fast
	local y = ground + feet
	for _ = 1, frames(0.4) do
		y += 30 * DT
		place(r.model, origin.X + x, origin.Y + y)
		step(1)
	end
	got, gap = classify(r, candidates)
	h.expect(got == "Sword.Jump", string.format("rising: playing %s (gap %.1f)", tostring(got), gap))
	-- falling
	for _ = 1, frames(0.4) do
		y -= 30 * DT
		place(r.model, origin.X + x, origin.Y + y)
		step(1)
	end
	got, gap = classify(r, candidates)
	h.expect(got == "Sword.Fall", string.format("falling: playing %s (gap %.1f)", tostring(got), gap))
	-- back on the ground, standing
	place(r.model, origin.X + x, origin.Y + ground + feet)
	expectState("Sword.Idle", "landed")
	expectNoWarnings("others")
	finish(r)
	FighterAnimator.stopMatch()
end)

h.test("the R15 avatar rig animates through rotated joints without errors", function()
	local r = avatarRig()
	FighterAnimator.track(r.model, { isMe = true, legend = "Avatar" })
	local w = watch(r)
	for _, state in { "Idle", "Run", "Jump", "Fall" } do
		FighterAnimator.setLocomotion(r.model, state, 1)
		step(frames(0.2))
		w:reset()
		w:run(1.0)
		h.expect(
			w.maxTurn <= LOOP_MAX_TURN,
			string.format("avatar %s: %s turned %.1f deg in one frame", state, w.maxTurnJoint, w.maxTurn)
		)
		h.expect(w:spike(SPIKE_FLOOR) == nil, "avatar " .. state .. ": " .. tostring(w:spike(SPIKE_FLOOR)))
		h.expect(w.moved > 0, "avatar " .. state .. " never moved")
	end
	for _, slot in Weapons.Slots do
		FighterAnimator.playAttack(r.model, "Unarmed", slot, 1, false)
		local move = Legends.getAttack("Avatar", "Unarmed", slot)
		w:reset()
		w:run(move.Startup + move.Active + move.Recovery + 0.2)
		h.expect(
			w.maxTurn <= ACTION_MAX_TURN,
			string.format("avatar Unarmed %s: %s turned %.1f deg in one frame", slot, w.maxTurnJoint, w.maxTurn)
		)
	end
	FighterAnimator.dodge(r.model, "Spot")
	w:run(0.5)
	FighterAnimator.hurt(r.model, 0.5, 100)
	w:run(0.7)
	expectNoWarnings("avatar")
	finish(r)
end)

h.test("fighting as your own avatar plays your legend's signature and ultimate clips on it", function()
	-- FightAsAvatar: no VisualRig, but the character's Legend is still the legend
	local r = avatarRig()
	r.model:SetAttribute("Legend", "Sol")
	local rig = FighterAnimator.track(r.model, { isMe = true, legend = "Sol" })
	h.expect(rig.visual == nil, "the avatar got bound to a visual rig")
	local w = watch(r)
	for _, case in { { "Sword", "NHeavy" }, { "Hammer", "DHeavy" }, { "Sword", "Ultimate" } } do
		local weapon, slot = case[1], case[2]
		local move = Legends.getAttack("Sol", weapon, slot)
		FighterAnimator.setWeapon(r.model, weapon)
		FighterAnimator.playAttack(r.model, weapon, slot, 1, false)
		local clip = rig.action and rig.action.clip
		h.expect(clip and clip.name == move.AnimKey, slot .. " played " .. tostring(clip and clip.name))
		w:reset()
		w:run(move.Startup + move.Active + move.Recovery + 0.2)
		h.expect(w.moved > 0, "avatar Sol " .. slot .. " never moved")
		h.expect(
			w.maxTurn <= ACTION_MAX_TURN,
			string.format("avatar Sol %s: %s turned %.1f deg in one frame", slot, w.maxTurnJoint, w.maxTurn)
		)
	end
	expectNoWarnings("avatar look")
	finish(r)
end)

-- Skinned legends --------------------------------------------------------------

local JOINT_OF_PART = {}
local PIVOT_OF = {}
for _, joint in FighterRigs.Joints do
	JOINT_OF_PART[joint.Part1] = joint.Name
	PIVOT_OF[joint.Name] = vec(joint.Pivot)
end

-- A skinned legend as LegendRig builds it: scaled proxy joints, plus a
-- "Skin" mesh whose bones sit on the joints with their own rest axes (an
-- importer may turn them any way), and the legend's sway bones.
local function skinnedRig(legendId, swaySpecs)
	local r = legendRig({ legend = legendId })
	local rig = r.rig
	local s = rig:GetAttribute("RigScale")
	local root = rig:FindFirstChild("RigRoot")
	rig.PrimaryPart = root
	rig:SetAttribute("Legend", legendId)
	for _, joint in FighterRigs.Joints do
		r.motors[joint.Name].C0 = CFrame.new(vec(joint.Pivot) * s)
	end
	local skin = Instance.new("Model")
	skin.Name = "Skin"
	local body = Instance.new("MeshPart")
	body.Name = "Body"
	body.CFrame = CFrame.Angles(math.rad(-90), 0, 0) -- e.g. a Z-up import
	body.Parent = skin
	local bones, rest = {}, {}
	local function addBone(name, parentName, pos, k)
		local bone = Instance.new("Bone")
		bone.Name = name
		local frame = CFrame.new(pos) * CFrame.Angles(0.4 + 0.1 * k, 0.7 - 0.05 * k, -0.4)
		local parentFrame = if parentName then rest[parentName] else body.CFrame
		bone.CFrame = parentFrame:ToObjectSpace(frame)
		bone.Parent = if parentName then bones[parentName] else body
		bones[name], rest[name] = bone, frame
	end
	for k, joint in FighterRigs.Joints do
		addBone(joint.Name, JOINT_OF_PART[joint.Part0], vec(joint.Pivot) * s, k)
	end
	for _, spec in swaySpecs do
		local parentName = spec.Parent
		for k = 1, #spec.Points - 1 do
			addBone(spec.Name .. k, parentName, vec(spec.Points[k]) * s, k)
			parentName = spec.Name .. k
		end
	end
	skin.Parent = rig
	r.bones, r.rest, r.scale, r.root = bones, rest, s, root
	return r
end

-- A bone's animated frame relative to the rig root: parent * CFrame * Transform.
local function boneWorld(r, name)
	local cf = CFrame.identity
	local node = r.bones[name]
	while node:IsA("Bone") do
		cf = node.CFrame * node.Transform * cf
		node = node.Parent
	end
	return r.root.CFrame:ToObjectSpace(node.CFrame * cf)
end

-- Where each joint's frame is, from the motors (relative to the rig root).
local function jointFrames(r)
	local out = {}
	for _, joint in FighterRigs.Joints do
		local parent = JOINT_OF_PART[joint.Part0]
		local t = r.motors[joint.Name].Transform
		if parent then
			out[joint.Name] = out[parent] * CFrame.new((PIVOT_OF[joint.Name] - PIVOT_OF[parent]) * r.scale) * t
		else
			out[joint.Name] = CFrame.new(PIVOT_OF[joint.Name] * r.scale) * t
		end
	end
	return out
end

local TEST_SWAYS = {
	{
		Name = "Cape",
		Parent = "Waist",
		Points = { { 0, 4.6, 0.5 }, { 0, 3.6, 0.6 }, { 0, 2.6, 0.7 } },
		Stiffness = 0.3,
		Damping = 0.2,
		Limit = 60,
		Behind = 1,
	},
}

h.test("skinned legends: every bone follows its joint, whatever its rest axes", function()
	local saved = FighterRigs.Fighters.Kestrel.Sways
	FighterRigs.Fighters.Kestrel.Sways = TEST_SWAYS
	local r = skinnedRig("Kestrel", TEST_SWAYS)
	FighterAnimator.track(r.model, { isMe = true, legend = "Kestrel", weapon = "Sword" })
	FighterAnimator.setWeapon(r.model, "Sword")
	local worstTurn, worstMove, worstBone = 0, 0, ""
	local function check()
		local joints = jointFrames(r)
		for name in PIVOT_OF do
			local expected = joints[name] * r.rest[name].Rotation
			local got = boneWorld(r, name)
			local turn = angleBetween(expected, got)
			if turn > worstTurn then
				worstTurn, worstBone = turn, name
			end
			worstMove = math.max(worstMove, (expected.Position - got.Position).Magnitude)
		end
	end
	FighterAnimator.setLocomotion(r.model, "Run", 1)
	for _ = 1, 20 do
		step(1)
		check()
	end
	for _, slot in { "NLight", "SHeavy", "DAir" } do
		FighterAnimator.playAttack(r.model, "Sword", slot, 1)
		for _ = 1, 30 do
			step(1)
			check()
		end
	end
	h.expect(worstTurn < 0.5, string.format("%s's bone turned %.2f deg away from its joint", worstBone, worstTurn))
	h.expect(worstMove < 1e-3, string.format("a bone sat %.4f studs off its joint", worstMove))
	finish(r)
	FighterRigs.Fighters.Kestrel.Sways = saved
	expectNoWarnings("skinned bones")
end)

h.test("skinned legends: sway bones trail fast moves, stay in their limits and settle", function()
	local saved = FighterRigs.Fighters.Kestrel.Sways
	FighterRigs.Fighters.Kestrel.Sways = TEST_SWAYS
	local r = skinnedRig("Kestrel", TEST_SWAYS)
	FighterAnimator.track(r.model, { isMe = true, legend = "Kestrel" })
	local limit = TEST_SWAYS[1].Limit
	local function swayAngles()
		local worst = 0
		for k = 1, 2 do
			local t = r.bones["Cape" .. k].Transform
			for _, v in { t.Position, t.LookVector, t.UpVector } do
				h.expect(v.X == v.X and v.Y == v.Y and v.Z == v.Z, "a sway bone went NaN")
			end
			worst = math.max(worst, angleBetween(CFrame.identity, t))
		end
		return worst
	end
	step(frames(0.3))
	-- dash sideways, then stop dead
	local swung = 0
	for i = 1, frames(0.4) do
		r.root.CFrame = CFrame.new(i * 0.6, 0, 0)
		step(1)
		local a = swayAngles()
		swung = math.max(swung, a)
		h.expect(a <= limit + 1, string.format("the cape swung %.1f deg, past its %d deg limit", a, limit))
	end
	h.expect(swung > 5, "the cape didn't trail the dash")
	step(frames(2.5))
	local settled = swayAngles()
	h.expect(settled < 8, string.format("the cape didn't settle (%.1f deg off rest)", settled))
	FighterAnimator.untrack(r.model)
	for name, bone in r.bones do
		h.expect(angleBetween(bone.Transform, CFrame.identity) < 1e-6, "untrack left bone " .. name .. " posed")
	end
	r.model:Destroy()
	FighterRigs.Fighters.Kestrel.Sways = saved
	expectNoWarnings("sway")
end)

local APRON_SWAYS = {
	{
		Name = "Apron",
		Parent = "Root",
		Points = { { 0, 2.8, -0.66 }, { 0, 2.05, -0.7 }, { 0, 1.3, -0.72 } },
		Stiffness = 0.4,
		Damping = 0.25,
		Limit = 50,
		Behind = -1,
	},
}

h.test("skinned legends: cloth hanging from the hips is pushed aside by the thighs", function()
	local saved = FighterRigs.Fighters.Kestrel.Sways
	FighterRigs.Fighters.Kestrel.Sways = APRON_SWAYS
	local r = skinnedRig("Kestrel", APRON_SWAYS)
	FighterAnimator.track(r.model, { isMe = true, legend = "Kestrel" })
	local radius = 0.58 * r.scale
	local closest = math.huge
	local function clearance()
		local joints = jointFrames(r)
		local a, b = boneWorld(r, "Apron1").Position, boneWorld(r, "Apron2").Position
		for _, side in { "Left", "Right" } do
			local hip, knee = joints[side .. "Hip"].Position, joints[side .. "Knee"].Position
			for _, q in { (a + b) / 2, b } do
				local ab = knee - hip
				local t = math.clamp((q - hip):Dot(ab) / ab:Dot(ab), 0, 1)
				local d = (q - (hip + ab * t)).Magnitude
				closest = math.min(closest, d)
			end
		end
	end
	FighterAnimator.setLocomotion(r.model, "Run", 1.4)
	for _ = 1, frames(1) do
		step(1)
		clearance()
	end
	for _, slot in { "NLight", "SLight", "DLight", "NAir", "SAir", "DAir", "NHeavy", "SHeavy" } do
		FighterAnimator.playAttack(r.model, "Unarmed", slot, 1)
		for _ = 1, frames(0.8) do
			step(1)
			clearance()
		end
	end
	h.expect(
		closest >= radius * 0.9,
		string.format("the apron sank into a thigh (%.2f studs from it, keeps %.2f)", closest, radius)
	)
	h.expect(closest < radius * 1.2, "no knee came near the apron, so this didn't test anything")
	finish(r)
	FighterRigs.Fighters.Kestrel.Sways = saved
	expectNoWarnings("apron")
end)

h.test("menu previews animate and ignore the character's facing", function()
	for _, legendId in Legends.Order do
		if legendId ~= "Avatar" then
			local weapon = Legends.List[legendId].Weapons[1]
			local r = legendRig({ legend = legendId, weapon = weapon })
			face(r.model, -1)
			FighterAnimator.track(r.model, { preview = true, legend = legendId, weapon = weapon })
			FighterAnimator.setLocomotion(r.model, "Idle")
			step(2)
			h.expect(r.weld.Part0 == r.rig:FindFirstChild("RightHand"), legendId .. " preview swapped hands")
			local w = watch(r)
			w:run(1.5)
			h.expect(w.moved > 0 and w.maxTurn <= LOOP_MAX_TURN, legendId .. " preview idle is off")
			h.expect(r.model:FindFirstChild("SkyOutline") == nil, legendId .. " preview got a match outline")
			finish(r)
		end
	end
	expectNoWarnings("previews")
end)

h.test("stopMatch keeps menu previews tracked and drops match rigs", function()
	local preview = legendRig({ legend = "Vex" })
	local previewRig = FighterAnimator.track(preview.model, { preview = true, legend = "Vex" })
	FighterAnimator.setLocomotion(preview.model, "Idle")
	local fighter = legendRig({ legend = "Sol" })
	FighterAnimator.track(fighter.model, { isMe = true, legend = "Sol" })
	step(10)
	FighterAnimator.stopMatch()
	for name, motor in fighter.motors do
		h.expect(
			angleBetween(motor.Transform, CFrame.identity) < 1e-6,
			"stopMatch left the fighter's " .. name .. " posed"
		)
	end
	h.expect(FighterAnimator.track(preview.model, { preview = true }) == previewRig, "stopMatch dropped the preview")
	local w = watch(preview)
	w:run(1)
	h.expect(w.moved > 0, "the preview stopped animating after the match")
	local f = watch(fighter)
	f:run(0.5)
	h.expect(f.moved == 0, "the match rig still animates after stopMatch")
	finish(preview, fighter)
	expectNoWarnings("stopMatch")
end)

h.test("setTimeScale slows match rigs but not previews", function()
	local preview = legendRig({ legend = "Kestrel" })
	local previewRig = FighterAnimator.track(preview.model, { preview = true, legend = "Kestrel" })
	local fighter = legendRig({ legend = "Kestrel" })
	local fighterRig = FighterAnimator.track(fighter.model, { isMe = true, legend = "Kestrel" })
	FighterAnimator.setTimeScale(0.5)
	local p0, f0 = previewRig.loco.t, fighterRig.loco.t
	step(60)
	h.near(previewRig.loco.t - p0, 1, 1e-6, "preview clock at time scale 0.5")
	h.near(fighterRig.loco.t - f0, 0.5, 1e-6, "match rig clock at time scale 0.5")
	FighterAnimator.setTimeScale(0.25)
	f0 = fighterRig.loco.t
	step(60)
	h.near(fighterRig.loco.t - f0, 0.25, 1e-6, "match rig clock at time scale 0.25")
	FighterAnimator.stopMatch() -- resets the scale
	local again = legendRig({ legend = "Kestrel" })
	local againRig = FighterAnimator.track(again.model, { isMe = true, legend = "Kestrel" })
	local a0 = againRig.loco.t
	step(30)
	h.near(againRig.loco.t - a0, 0.5, 1e-6, "stopMatch didn't reset the time scale")
	-- junk scales play at 1x
	for _, junk in { math.huge, 0 / 0, -1, "fast" } do
		FighterAnimator.setTimeScale(junk)
		a0 = againRig.loco.t
		step(30)
		h.near(againRig.loco.t - a0, 0.5, 1e-6, "time scale " .. tostring(junk))
	end
	finish(preview, fighter, again)
	expectNoWarnings("time scale")
end)

h.test("a still rig is posed once and skipped afterwards", function()
	local r = legendRig({ legend = "Moss" })
	local rig = FighterAnimator.still(r.model, { legend = "Moss" })
	h.expect(rig.preview and rig.still, "still() didn't make a still preview")
	local posed = false
	local pose = {}
	for name, motor in r.motors do
		pose[name] = motor.Transform
		if angleBetween(motor.Transform, CFrame.identity) > 0.5 then
			posed = true
		end
	end
	h.expect(posed, "the still rig wasn't posed in its idle")
	local t0 = rig.loco.t
	step(30)
	for name, motor in r.motors do
		-- (re-multiplying equal frames leaves ~1e-6 deg of float noise)
		h.expect(angleBetween(motor.Transform, pose[name]) < 1e-3, "the still rig's " .. name .. " moved")
	end
	h.expect(rig.loco.t == t0, "the frame loop updated a still rig")
	FighterAnimator.stopMatch()
	h.expect(FighterAnimator.track(r.model, { preview = true }) == rig, "stopMatch dropped a still preview")
	FighterAnimator.untrack(r.model)
	for name, motor in r.motors do
		h.expect(angleBetween(motor.Transform, CFrame.identity) < 1e-6, "untrack left " .. name .. " posed")
	end
	-- a still rig whose model is removed is forgotten
	local gone = legendRig({ legend = "Moss" })
	local goneRig = FighterAnimator.still(gone.model, { legend = "Moss" })
	gone.model.Parent = nil
	step(1)
	h.expect(FighterAnimator.track(gone.model, { preview = true }) ~= goneRig, "a removed still rig stayed tracked")
	FighterAnimator.untrack(gone.model)
	-- built before it is parented (LegendView builds, then parents): posed once it gets its parent
	local late = legendRig({ legend = "Moss" })
	late.model.Parent = nil
	local lateRig = FighterAnimator.still(late.model, { legend = "Moss" })
	step(10)
	for name, motor in late.motors do
		h.expect(angleBetween(motor.Transform, CFrame.identity) < 1e-6, "an unparented still rig posed " .. name)
	end
	h.expect(FighterAnimator.track(late.model, { preview = true }) == lateRig, "an unparented still rig was dropped")
	late.model.Parent = workspaceFolder
	step(1)
	for name, motor in late.motors do
		h.expect(angleBetween(motor.Transform, pose[name]) < 1e-3, "the late still rig's " .. name .. " isn't idle")
	end
	h.expect(lateRig.loco.t == t0, "the late still rig's clock moved")
	step(30)
	for name, motor in late.motors do
		h.expect(angleBetween(motor.Transform, pose[name]) < 1e-3, "the late still rig's " .. name .. " moved")
	end
	-- a preview that never gets a parent is dropped after a while
	local never = legendRig({ legend = "Moss" })
	never.model.Parent = nil
	local neverRig = FighterAnimator.still(never.model, { legend = "Moss" })
	step(frames(6))
	h.expect(FighterAnimator.track(never.model, { preview = true }) ~= neverRig, "a never-parented rig stayed tracked")
	finish(late, never)
	r.model:Destroy()
	gone.model:Destroy()
	expectNoWarnings("still")
end)

h.test("match fighters get an outline only when Config.Art.Outlines is on; untrack cleans up", function()
	local saved = Config.Art.Outlines
	for _, on in { false, true } do
		Config.Art.Outlines = on
		local r = legendRig({ legend = "Yuki", weapon = "Bow" })
		FighterAnimator.track(r.model, { isMe = true, legend = "Yuki" })
		step(1)
		local outline = r.model:FindFirstChild("SkyOutline")
		if on then
			h.expect(outline ~= nil and outline.Adornee == r.rig, "no outline on the visual rig")
		else
			h.expect(outline == nil, "outline added with Config.Art.Outlines off")
		end
		FighterAnimator.untrack(r.model)
		h.expect(r.model:FindFirstChild("SkyOutline") == nil, "untrack left the outline")
		for name, motor in r.motors do
			h.expect(angleBetween(motor.Transform, CFrame.identity) < 1e-6, "untrack left " .. name .. " posed")
		end
		r.model:Destroy()
	end
	Config.Art.Outlines = saved
	expectNoWarnings("untrack")
end)

h.finish()
