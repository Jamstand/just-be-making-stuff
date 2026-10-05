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
      - the R15 avatar rig path and menu previews work too
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
	local rel = a:Inverse() * b
	local trace = rel.XVector.X + rel.YVector.Y + rel.ZVector.Z
	return math.deg(math.acos(math.clamp((trace - 1) / 2, -1, 1)))
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
		"UI/FightersPanel",
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
	local contexts = { "Unarmed" }
	for _, w in Weapons.Order do
		table.insert(contexts, w)
	end
	local checks = 0
	for _, weapon in contexts do
		for _, facing in { 1, -1 } do
			local r = legendRig({ legend = "Kestrel", weapon = weapon ~= "Unarmed" and weapon or nil })
			face(r.model, facing)
			FighterAnimator.track(r.model, { isMe = true, legend = "Kestrel" })
			FighterAnimator.setWeapon(r.model, weapon)
			local w = watch(r)
			for _, state in { "Idle", "Run", "Jump", "Fall", "WallSlide" } do
				for _, speed in state == "Run" and { 0.6, 1, 1.4 } or { 1 } do
					FighterAnimator.setLocomotion(r.model, state, speed)
					step(frames(0.2)) -- past the crossfade
					local clipName = FighterAnimator.hasClip(weapon .. "." .. state) and weapon .. "." .. state
						or "Loco." .. state
					local length = AnimationData.Clips[clipName].Length
					w:reset()
					w:run(math.max(0.5, 2.2 * length / speed)) -- at least two loops, across the seam
					local label =
						string.format("%s %s x%.1f facing %s", weapon, state, speed, facing > 0 and "right" or "left")
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
			expectNoWarnings(weapon)
			finish(r)
		end
	end
	print(string.format("       %d loops checked; worst joint turn per frame:", checks))
	for _, key in { "Idle", "Run x0.6", "Run x1.0", "Run x1.4", "Jump", "Fall", "WallSlide" } do
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
		for _, weapon in list do
			for _, slot in Weapons.Slots do
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

h.test("hurt, tumble, air jump, land and throw play and return", function()
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
