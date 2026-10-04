--[[
    Client-side match visuals:

      - Procedural attack poses: every client poses every fighter's joints
        from the attack events it receives, so no animation assets are
        needed. Poses rotate Motor6D.C0 on top of whatever locomotion
        animation is playing.
      - Weapon swing trails, dodge flicker, respawn shimmer
      - Hit sparks, damage numbers, KO effects (KOEffect cosmetics)
      - Projectile visuals (arrows, thrown weapons)

    Nothing here affects gameplay.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Weapons = require(Shared.Weapons)
local WeaponModels = require(Shared.WeaponModels)
local Cosmetics = require(Shared.Cosmetics)

local Settings = require(script.Parent.Settings)

local Visuals = {}

local effectsFolder = nil
local origin = Vector3.zero
local tracked = {} -- [model] = rig info
local projectiles = {} -- [id] = visual
local rng = Random.new()

-- Poses -------------------------------------------------------------------
--[[
    Angles are degrees in the parent part's space:
      pitch (X)  positive swings an arm forward/up, tips the body back
      yaw (Y)    twist
      roll (Z)   positive raises the right arm out to the side
    RootY lowers/raises the whole body (crouches).
    Spin/Flip turn the whole body during the strike.
]]

local REST = {}

local POSES = {
	Punch = {
		Windup = { RightArm = { 40, 0, 0 }, LeftArm = { 60, 0, 0 }, Torso = { 0, 25, 0 } },
		Strike = { RightArm = { 92, 0, 0 }, LeftArm = { 30, 0, 0 }, Torso = { 0, -25, 0 } },
	},
	Slash = {
		Windup = { RightArm = { 165, 0, -20 }, Torso = { 0, 25, 0 } },
		Strike = { RightArm = { 25, 0, 15 }, Torso = { 0, -25, 0 } },
	},
	Arc = {
		Windup = { RightArm = { -25, 0, 0 }, Root = { -8, 0, 0 } },
		Strike = { RightArm = { 175, 0, 0 }, Root = { 8, 0, 0 } },
	},
	Thrust = {
		Windup = { RightArm = { 70, 0, 0 }, Torso = { 0, 35, 0 } },
		Strike = { RightArm = { 92, 0, 0 }, Torso = { 0, -30, 0 }, Root = { -15, 0, 0 } },
	},
	Overhead = {
		Windup = { RightArm = { 205, 0, 0 }, LeftArm = { 190, 0, 0 }, Root = { 10, 0, 0 } },
		Strike = { RightArm = { 35, 0, 0 }, LeftArm = { 30, 0, 0 }, Root = { -22, 0, 0 } },
	},
	Uppercut = {
		Windup = { RightArm = { -30, 0, 0 }, Root = { -12, 0, 0 }, RootY = -0.8 },
		Strike = { RightArm = { 182, 0, 0 }, Root = { 10, 0, 0 } },
	},
	Low = {
		Windup = { RightArm = { 15, 0, 0 }, Root = { -12, 0, 0 }, RootY = -1 },
		Strike = { RightArm = { 55, 0, 25 }, Root = { -28, 0, 0 }, RootY = -1.4, RightLeg = { 35, 0, 0 } },
	},
	Sweep = {
		Windup = { RightArm = { 10, 0, 80 }, LeftArm = { 10, 0, -80 }, RootY = -1 },
		Strike = { RightArm = { 10, 0, 85 }, LeftArm = { 10, 0, -85 }, RootY = -1.4 },
		Spin = 360,
	},
	Spin = {
		Windup = { RightArm = { 20, 0, 70 }, LeftArm = { 20, 0, -70 } },
		Strike = { RightArm = { 20, 0, 85 }, LeftArm = { 20, 0, -85 } },
		Spin = 540,
	},
	Flip = {
		Windup = { RightArm = { 150, 0, 0 }, LeftArm = { 150, 0, 0 }, RightLeg = { 50, 0, 0 }, LeftLeg = { 50, 0, 0 } },
		Strike = { RightArm = { 170, 0, 0 }, LeftArm = { 170, 0, 0 }, RightLeg = { 60, 0, 0 }, LeftLeg = { 60, 0, 0 } },
		Flip = -360,
	},
	Stomp = {
		Windup = { RightArm = { 160, 0, 20 }, LeftArm = { 160, 0, -20 }, RightLeg = { 70, 0, 0 }, LeftLeg = { 70, 0, 0 } },
		Strike = { RightArm = { -20, 0, 30 }, LeftArm = { -20, 0, -30 }, RightLeg = { 0, 0, 0 }, LeftLeg = { 0, 0, 0 }, Root = { -10, 0, 0 } },
	},
	Kick = {
		Windup = { RightLeg = { -35, 0, 0 }, Root = { 6, 0, 0 } },
		Strike = { RightLeg = { 95, 0, 0 }, Root = { 18, 0, 0 }, RightArm = { -30, 0, 0 } },
	},
	Dive = {
		Windup = { RightArm = { 120, 0, 0 }, Root = { -10, 0, 0 } },
		Strike = { RightArm = { 40, 0, 0 }, Root = { -45, 0, 0 } },
	},
	Reap = {
		Windup = { RightArm = { 175, 0, 0 }, Torso = { 0, 30, 0 } },
		Strike = { RightArm = { -35, 0, 0 }, Torso = { 0, -30, 0 }, Root = { -15, 0, 0 } },
	},
	Slam = {
		Windup = { RightArm = { 195, 0, 0 }, LeftArm = { 195, 0, 0 }, Root = { 8, 0, 0 } },
		Strike = { RightArm = { 25, 0, 0 }, LeftArm = { 25, 0, 0 }, Root = { -28, 0, 0 }, RootY = -1 },
	},
	Shoot = {
		Windup = { LeftArm = { 90, 0, 0 }, RightArm = { 85, 40, 0 }, Torso = { 0, 25, 0 } },
		Strike = { LeftArm = { 92, 0, 0 }, RightArm = { 70, 5, 0 }, Torso = { 0, 20, 0 } },
	},
	Throw = {
		Windup = { RightArm = { 200, 0, 0 }, Torso = { 0, 25, 0 } },
		Strike = { RightArm = { 60, 0, 0 }, Torso = { 0, -20, 0 } },
	},
	Hurt = {
		Windup = { RightArm = { 40, 0, 45 }, LeftArm = { 40, 0, -45 }, Root = { 22, 0, 0 } },
		Strike = { RightArm = { 40, 0, 45 }, LeftArm = { 40, 0, -45 }, Root = { 22, 0, 0 } },
	},
}

local JOINTS = {
	R15 = {
		RightArm = { "RightUpperArm", "RightShoulder" },
		LeftArm = { "LeftUpperArm", "LeftShoulder" },
		Torso = { "UpperTorso", "Waist" },
		Root = { "LowerTorso", "Root" },
		RightLeg = { "RightUpperLeg", "RightHip" },
		LeftLeg = { "LeftUpperLeg", "LeftHip" },
	},
	R6 = {
		RightArm = { "Torso", "Right Shoulder" },
		LeftArm = { "Torso", "Left Shoulder" },
		Root = { "HumanoidRootPart", "RootJoint" },
		RightLeg = { "Torso", "Right Hip" },
		LeftLeg = { "Torso", "Left Hip" },
	},
}

local function getRig(model)
	local rig = tracked[model]
	if rig then
		return rig
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil
	end
	local map = humanoid.RigType == Enum.HumanoidRigType.R15 and JOINTS.R15 or JOINTS.R6
	rig = { model = model, joints = {}, anim = nil, flicker = 0, shimmer = 0, posed = false }
	for name, path in map do
		local part = model:FindFirstChild(path[1])
		local motor = part and part:FindFirstChild(path[2])
		if motor and motor:IsA("Motor6D") then
			rig.joints[name] = { motor = motor, c0 = motor.C0 }
		end
	end
	tracked[model] = rig
	return rig
end

local function angles(t)
	if not t then
		return 0, 0, 0
	end
	return t[1], t[2], t[3]
end

local function lerp(a, b, t)
	return a + (b - a) * t
end

local function easeOut(t)
	return 1 - (1 - t) * (1 - t)
end

local function applyPose(rig, from, to, alpha, spin, flip)
	for name, joint in rig.joints do
		local fp, fy, fr = angles(from[name])
		local tp, ty, tr = angles(to[name])
		local pitch, yaw, roll = lerp(fp, tp, alpha), lerp(fy, ty, alpha), lerp(fr, tr, alpha)
		local offset = Vector3.zero
		if name == "Root" then
			yaw += spin or 0
			pitch += flip or 0
			offset = Vector3.new(0, lerp(from.RootY or 0, to.RootY or 0, alpha), 0)
		end
		local c0 = joint.c0
		local rotation = CFrame.Angles(math.rad(pitch), math.rad(yaw), math.rad(roll))
		joint.motor.C0 = CFrame.new(c0.Position + offset) * rotation * c0.Rotation
	end
	rig.posed = true
end

local function resetPose(rig)
	if not rig.posed then
		return
	end
	for _, joint in rig.joints do
		if joint.motor.Parent then
			joint.motor.C0 = joint.c0
		end
	end
	rig.posed = false
end

local function setTrail(model, on)
	local weapon = model:FindFirstChild("EquippedWeapon")
	if not weapon then
		return
	end
	for _, d in weapon:GetDescendants() do
		if d:IsA("Trail") then
			d.Enabled = on
		end
	end
end

local function updateRig(rig, dt)
	local model = rig.model
	if not model.Parent then
		tracked[model] = nil
		return
	end

	-- Dodge flicker / respawn shimmer
	if rig.flicker > 0 or rig.shimmer > 0 then
		rig.flicker = math.max(0, rig.flicker - dt)
		rig.shimmer = math.max(0, rig.shimmer - dt)
		local on = rig.flicker > 0 and (math.floor(rig.flicker * 20) % 2 == 0)
		local highlight = model:FindFirstChild("SkybrawlShimmer")
		if rig.shimmer > 0 then
			if not highlight then
				highlight = Instance.new("Highlight")
				highlight.Name = "SkybrawlShimmer"
				highlight.FillColor = Color3.new(1, 1, 1)
				highlight.OutlineTransparency = 1
				highlight.DepthMode = Enum.HighlightDepthMode.Occluded
				highlight.Parent = model
			end
			highlight.FillTransparency = 0.45 + 0.35 * math.sin(os.clock() * 18)
		elseif highlight then
			highlight:Destroy()
		end
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then
				d.LocalTransparencyModifier = on and 0.6 or 0
			end
		end
	end

	local anim = rig.anim
	if not anim then
		resetPose(rig)
		return
	end
	local pose = POSES[anim.name]
	if not pose then
		rig.anim = nil
		resetPose(rig)
		return
	end

	if anim.charging then
		anim.chargeTime += dt
		if anim.chargeTime > anim.maxCharge + 0.3 then
			anim.charging = false
		end
	else
		anim.t += dt
	end
	local t = anim.t
	local startup, active, recovery = anim.startup, anim.active, anim.recovery
	local spin, flip = 0, 0
	if t < startup then
		local a = easeOut(math.clamp(t / math.max(startup, 0.01), 0, 1))
		applyPose(rig, REST, pose.Windup, a, 0, 0)
		if anim.charging then
			-- Tremble while charging a heavy.
			local shake = math.sin(os.clock() * 60) * 2
			applyPose(rig, REST, pose.Windup, 1, shake, 0)
		end
	elseif t < startup + active then
		local a = easeOut(math.clamp((t - startup) / math.max(active, 0.06), 0, 1))
		spin = (pose.Spin or 0) * a
		flip = (pose.Flip or 0) * a
		applyPose(rig, pose.Windup, pose.Strike, a, spin, flip)
	elseif t < startup + active + recovery then
		local a = math.clamp((t - startup - active) / math.max(recovery, 0.01), 0, 1)
		applyPose(rig, pose.Strike, REST, easeOut(a), 0, 0)
	else
		rig.anim = nil
		resetPose(rig)
	end

	local trailOn = rig.anim ~= nil and t > startup * 0.5 and t < startup + active + 0.06
	if trailOn ~= rig.trailOn then
		rig.trailOn = trailOn
		setTrail(model, trailOn)
	end
end

-- Starts a pose on a fighter. timing = { startup, active, recovery, charge }
function Visuals.playPose(model, name, timing)
	local rig = model and getRig(model)
	if not rig then
		return
	end
	rig.anim = {
		name = name,
		t = 0,
		startup = timing.startup or 0.1,
		active = timing.active or 0.1,
		recovery = timing.recovery or 0.2,
		charging = (timing.charge or 0) > 0,
		maxCharge = timing.charge or 0,
		chargeTime = 0,
		seq = timing.seq,
	}
end

function Visuals.releaseCharge(model, seq)
	local rig = model and tracked[model]
	local anim = rig and rig.anim
	if anim and anim.charging and (seq == nil or anim.seq == seq) then
		anim.charging = false
		-- Already wound up while charging; skip most of the windup.
		anim.t = math.max(anim.t, anim.startup * 0.7)
	end
end

function Visuals.stopPose(model)
	local rig = model and tracked[model]
	if rig then
		rig.anim = nil
	end
end

function Visuals.flicker(model, duration)
	local rig = model and getRig(model)
	if rig then
		rig.flicker = math.max(rig.flicker, duration)
	end
end

function Visuals.shimmer(model, duration)
	local rig = model and getRig(model)
	if rig then
		rig.shimmer = math.max(rig.shimmer, duration)
	end
end

local GROUND_HEAVIES = { NHeavy = true, SHeavy = true, DHeavy = true }

-- Attack started on some fighter (yours, another player's, or a bot's).
function Visuals.onAttack(model, weaponId, slot, seq)
	local move = Weapons.getAttack(weaponId, slot)
	if not move then
		return
	end
	local isGroundHeavy = GROUND_HEAVIES[slot] == true
	Visuals.playPose(model, move.Anim, {
		startup = move.Startup,
		active = move.EndsOnLand and 0.35 or move.Active,
		recovery = move.Recovery,
		charge = isGroundHeavy and move.Charge or 0,
		seq = seq,
	})
end

-- Effects -----------------------------------------------------------------

local function worldPos(x, y, z)
	return origin + Vector3.new(x, y, z or 0)
end

local function effectPart(size, cframe, color, shape)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Size = size
	p.CFrame = cframe
	if shape then
		p.Shape = shape
	end
	p.Parent = effectsFolder
	return p
end

local function fadeOut(part, duration, endSize)
	local goal = { Transparency = 1 }
	if endSize then
		goal.Size = endSize
	end
	local tween = TweenService:Create(part, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal)
	tween:Play()
	task.delay(duration + 0.05, function()
		part:Destroy()
	end)
end

local function shards(center, color, count, speed, life, size)
	for _ = 1, count do
		local angle = rng:NextNumber(0, math.pi * 2)
		local dir = Vector3.new(math.cos(angle), math.sin(angle), rng:NextNumber(-0.3, 0.3))
		local p = effectPart(Vector3.new(size, size * 0.4, size * 0.4), CFrame.lookAt(center, center + dir), color)
		local goal = { CFrame = CFrame.lookAt(center + dir * speed, center + dir * (speed + 1)), Transparency = 1, Size = Vector3.new(size * 0.3, 0.1, 0.1) }
		TweenService:Create(p, TweenInfo.new(life, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal):Play()
		task.delay(life + 0.05, function()
			p:Destroy()
		end)
	end
end

function Visuals.hitSpark(x, y, heavy, force)
	if not effectsFolder then
		return
	end
	local center = worldPos(x, y, 1.5)
	local color = heavy and Color3.fromRGB(255, 170, 60) or Color3.fromRGB(255, 255, 230)
	local size = heavy and 2.2 or 1.4
	local ball = effectPart(Vector3.one * size, CFrame.new(center), color, Enum.PartType.Ball)
	ball.Transparency = 0.1
	fadeOut(ball, 0.18, Vector3.one * size * (heavy and 4 or 3))
	shards(center, color, heavy and 9 or 5, (heavy and 7 or 4) + (force or 0) * 0.04, 0.22, heavy and 1.4 or 1)
end

function Visuals.damageNumber(x, y, amount, color)
	if not effectsFolder or not Settings.get("DamageNumbers") then
		return
	end
	local anchor = effectPart(Vector3.one * 0.1, CFrame.new(worldPos(x + rng:NextNumber(-1, 1), y + 2, 2)), Color3.new(1, 1, 1))
	anchor.Transparency = 1
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(80, 36)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 100000
	gui.Parent = anchor
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.Text = tostring(amount)
	label.TextColor3 = color or Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.2
	label.Parent = gui
	TweenService:Create(gui, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { StudsOffset = Vector3.new(0, 3, 0) }):Play()
	TweenService:Create(label, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	task.delay(0.75, function()
		anchor:Destroy()
	end)
end

function Visuals.hurt(model, hitstun)
	Visuals.playPose(model, "Hurt", { startup = 0.04, active = math.max(0.05, hitstun - 0.1), recovery = 0.1 })
	local highlight = Instance.new("Highlight")
	highlight.FillColor = Color3.fromRGB(255, 80, 80)
	highlight.FillTransparency = 0.35
	highlight.OutlineTransparency = 1
	highlight.Parent = model
	task.delay(0.1, function()
		highlight:Destroy()
	end)
end

-- KO effect at the edge of the screen where the fighter left.
function Visuals.koEffect(x, y, effectId, cameraBounds)
	if not effectsFolder then
		return
	end
	local item = Cosmetics.resolve("KOEffect", effectId)
	if cameraBounds then
		x = math.clamp(x, cameraBounds.minX + 6, cameraBounds.maxX - 6)
		y = math.clamp(y, cameraBounds.minY + 6, cameraBounds.maxY - 6)
	end
	local center = worldPos(x, y, 3)
	local color = item.Color
	local style = item.Style

	local flash = effectPart(Vector3.one * 4, CFrame.new(center), color, Enum.PartType.Ball)
	flash.Transparency = 0.05
	fadeOut(flash, 0.45, Vector3.one * 26)

	if style == "Burst" then
		shards(center, color, 18, 22, 0.6, 3)
	elseif style == "Fireworks" then
		local colors = { color, Color3.fromRGB(120, 220, 255), Color3.fromRGB(255, 230, 90) }
		for i = 0, 2 do
			task.delay(i * 0.15, function()
				local c = center + Vector3.new(rng:NextNumber(-8, 8), rng:NextNumber(-6, 6), 0)
				shards(c, colors[i + 1], 14, 14, 0.55, 1.8)
			end)
		end
	elseif style == "Petals" then
		for _ = 1, 26 do
			local p = effectPart(Vector3.new(1.2, 0.2, 0.8), CFrame.new(center) * CFrame.Angles(rng:NextNumber(0, 6), rng:NextNumber(0, 6), 0), color)
			p.Material = Enum.Material.SmoothPlastic
			local drift = Vector3.new(rng:NextNumber(-18, 18), rng:NextNumber(-14, 10), 0)
			local goal = { CFrame = CFrame.new(center + drift) * CFrame.Angles(rng:NextNumber(0, 6), rng:NextNumber(0, 6), 0), Transparency = 1 }
			TweenService:Create(p, TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), goal):Play()
			task.delay(1.25, function()
				p:Destroy()
			end)
		end
	elseif style == "Shockwave" then
		local ring = effectPart(Vector3.new(0.4, 6, 6), CFrame.new(center) * CFrame.Angles(0, math.rad(90), 0), color, Enum.PartType.Cylinder)
		ring.Transparency = 0.2
		fadeOut(ring, 0.6, Vector3.new(0.4, 60, 60))
		shards(center, color, 10, 16, 0.5, 2)
	elseif style == "Lightning" then
		local top = center + Vector3.new(rng:NextNumber(-6, 6), 60, 0)
		local last = top
		for i = 1, 7 do
			local nextPoint = top:Lerp(center, i / 7) + Vector3.new(i < 7 and rng:NextNumber(-4, 4) or 0, 0, 0)
			local length = (nextPoint - last).Magnitude
			local bolt = effectPart(Vector3.new(0.7, 0.7, length), CFrame.lookAt((last + nextPoint) / 2, nextPoint), color)
			fadeOut(bolt, 0.35)
			last = nextPoint
		end
		shards(center, color, 12, 18, 0.45, 2)
	end
end

-- Projectiles -------------------------------------------------------------

function Visuals.spawnProjectile(data)
	if not effectsFolder then
		return
	end
	local visual = { data = data, age = 0 }
	if data.kind == "Weapon" and data.weaponId then
		local ok, model = pcall(WeaponModels.build, data.weaponId, data.colorId)
		if ok then
			model.PrimaryPart.Anchored = true
			model.Parent = effectsFolder
			visual.model = model
		end
	else
		local part = effectPart(Vector3.new(0.25, 0.25, 2.4), CFrame.new(worldPos(data.x, data.y)), Color3.fromRGB(255, 240, 190))
		local trailA = Instance.new("Attachment")
		trailA.Position = Vector3.new(0, 0, 1)
		trailA.Parent = part
		local trailB = Instance.new("Attachment")
		trailB.Position = Vector3.new(0, 0.15, 1)
		trailB.Parent = part
		local trail = Instance.new("Trail")
		trail.Attachment0 = trailA
		trail.Attachment1 = trailB
		trail.Lifetime = 0.15
		trail.WidthScale = NumberSequence.new(4, 0)
		trail.Color = ColorSequence.new(Color3.fromRGB(255, 240, 190))
		trail.Transparency = NumberSequence.new(0.3, 1)
		trail.FaceCamera = true
		trail.Parent = part
		visual.part = part
	end
	projectiles[data.id] = visual
end

function Visuals.endProjectile(id, x, y)
	local visual = projectiles[id]
	if not visual then
		return
	end
	projectiles[id] = nil
	if visual.model then
		visual.model:Destroy()
	end
	if visual.part then
		visual.part:Destroy()
	end
	if x and y and effectsFolder then
		local puff = effectPart(Vector3.one, CFrame.new(worldPos(x, y, 1)), Color3.new(1, 1, 1), Enum.PartType.Ball)
		puff.Transparency = 0.4
		fadeOut(puff, 0.15, Vector3.one * 3)
	end
end

local function updateProjectiles(dt)
	for id, visual in projectiles do
		visual.age += dt
		local d = visual.data
		local t = visual.age
		if t > d.lifetime + 0.3 then
			Visuals.endProjectile(id)
		else
			local x = d.x + d.vx * t
			local y = d.y + d.vy * t - 0.5 * d.gravity * t * t
			local vy = d.vy - d.gravity * t
			local pos = worldPos(x, y)
			if visual.model then
				visual.model:PivotTo(CFrame.new(pos) * CFrame.Angles(0, 0, -t * 25 * (d.vx >= 0 and 1 or -1)) * CFrame.Angles(0, math.rad(90), 0))
			elseif visual.part then
				local dir = Vector3.new(d.vx, vy, 0)
				if dir.Magnitude > 0.01 then
					visual.part.CFrame = CFrame.lookAt(pos, pos + dir)
				end
			end
		end
	end
end

-- Lifecycle ---------------------------------------------------------------

function Visuals.startMatch(arenaOrigin)
	Visuals.stopMatch()
	origin = arenaOrigin
	effectsFolder = Instance.new("Folder")
	effectsFolder.Name = "SkybrawlEffects"
	effectsFolder.Parent = workspace
end

function Visuals.stopMatch()
	for id in projectiles do
		Visuals.endProjectile(id)
	end
	for model, rig in tracked do
		rig.anim = nil
		if model.Parent then
			resetPose(rig)
			for _, d in model:GetDescendants() do
				if d:IsA("BasePart") then
					d.LocalTransparencyModifier = 0
				end
			end
			local highlight = model:FindFirstChild("SkybrawlShimmer")
			if highlight then
				highlight:Destroy()
			end
		end
	end
	tracked = {}
	if effectsFolder then
		effectsFolder:Destroy()
		effectsFolder = nil
	end
end

function Visuals.init()
	RunService.RenderStepped:Connect(function(dt)
		for _, rig in tracked do
			updateRig(rig, dt)
		end
		updateProjectiles(dt)
	end)
end

return Visuals
