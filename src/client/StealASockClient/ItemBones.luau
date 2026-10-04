-- ItemBones: the items' moving parts and the golden sparkle auras, on every client.
-- The Blender item models carry a skeleton (tools/blender/items; docs/ITEMS.md) and this animates
-- the bones by name through Bone.Transform (local to this client, nothing replicates), in the hand,
-- on the floor (peel, duck), overhead (the glider's sheet) and over a hider (the basket):
--   BananaPeel     Stem, Flap1..Flap4         the flaps flop when it's dropped or slipped on and
--                                             quiver at rest; in the hand they dangle
--   BubbleBlaster  Trigger, Ring, Tank        the trigger pulls, the ring spins and wobbles on each
--                                             shot, the soap sloshes as you run
--   AlarmDuck      Body, Head, Bill, Tail     it waddles as it moves (Body rocks), the head turns to
--                                             the intruder, the bill opens on honks, the tail waggles
--   SoftenerBottle Trigger                    pumps while spraying
--   DashSlippers   Ribbon, SlipperL/R, WingL/R  the slippers swing, the heel wings flap on a dash
--   DryerSheet     Canopy, Corner1..Corner4   the canopy ripples and its corners flap
--   LaundryBasket  Top                        squash and stretch as the hider shuffles, a bounce
--   StaticBalloon  String1..3, Balloon        the string sways, the balloon bobs and jiggles harder
--                                             as it charges, a recoil when it zaps
-- The `<Name>_Gold` models have the same bones. A model without them (the Part builds, a model not
-- imported yet) just has no moving parts - everything else still works.
-- Moves are rotations about the model's own axes (x right, y up, z front; a tool's Handle is turned
-- like its model) or about a bone's own direction ("bend": lifts its tip up, "twist": spins it),
-- turned into each bone's space once when it is found, so a bone's roll in Blender doesn't matter.
-- Golden items (tool / world object attribute Gold, or Level >= ItemConfig.MaxLevel) get a soft gold
-- sparkle aura: one ParticleEmitter each, made once, on only near the camera (16 at most; Low
-- graphics halves it).
-- API (ItemFX drives it): ItemBones.Track(model, kind, info), ItemBones.Kick(model, event, data?),
--   ItemBones.Step(dt, camPos), ItemBones.Sweep(), ItemBones.SetLow(on), ItemBones.KindOf(name),
--   ItemBones.Count() / ItemBones.Auras() (tests)
local ItemBones = {}

local sin, exp, abs, clamp, min = math.sin, math.exp, math.abs, math.clamp, math.min
local TAU = math.pi * 2
local X_AXIS = Vector3.new(1, 0, 0)
local Y_AXIS = Vector3.new(0, 1, 0)
local Z_AXIS = Vector3.new(0, 0, 1)

local RANGE = 80 -- studs from the camera: farther props keep still
local FORGET = 0.6 -- seconds without a Track before a prop is let go (its bones put back)
local AURA_MAX = 16
local AURA_RATE = 6
local GOLD = Color3.fromRGB(255, 214, 90)
local SPARKLES = "rbxasset://textures/particles/sparkles_main.dds"

-- the bones each model's moves use (Root is never moved: it's the grip / floor point)
local BONES: { [string]: { string } } = {
	BananaPeel = { "Stem", "Flap1", "Flap2", "Flap3", "Flap4" },
	BubbleBlaster = { "Trigger", "Ring", "Tank" },
	AlarmDuck = { "Body", "Head", "Bill", "Tail" },
	SoftenerBottle = { "Trigger" },
	DashSlippers = { "Ribbon", "SlipperL", "SlipperR", "WingL", "WingR" },
	DryerSheet = { "Canopy", "Corner1", "Corner2", "Corner3", "Corner4" },
	LaundryBasket = { "Top" },
	StaticBalloon = { "String1", "String2", "String3", "Balloon" },
}

-- world objects (workspace.StealASock.Items) by name prefix -> the model kind
local WORLD: { [string]: string } = { BananaPeel = "BananaPeel", AlarmDuck = "AlarmDuck", Glider = "DryerSheet", Basket = "LaundryBasket" }

type BoneRef = {
	bone: Bone,
	M: CFrame, -- model space -> the bone's own space (rotation)
	Minv: CFrame,
	side: Vector3, -- model space: the axis that lifts the bone's tip (its direction x up)
	dir: Vector3, -- model space: the bone's direction (head -> tail)
}

export type Prop = {
	model: Model,
	kind: string,
	frame: BasePart?, -- what "model space" is: a tool's Handle; nil = the model's pivot
	bones: { [string]: { BoneRef } },
	boned: boolean,
	seen: number,
	events: { [string]: number }, -- event -> this module's clock
	data: { [string]: any },
	charge: number,
	moving: number, -- 0..1, smoothed: how fast the prop moves
	lastPos: Vector3?,
	inHand: boolean,
	gold: boolean,
	hidden: boolean,
	spin: number,
	headYaw: number,
	aura: ParticleEmitter?,
	posed: boolean,
}

local props: { [Model]: Prop } = {}
local clock = 0
local low = false

-- ---------- bones ----------

local function frameOf(prop: Prop): CFrame
	local f = prop.frame
	if f and f.Parent then
		return f.CFrame
	end
	return prop.model:GetPivot()
end

local function refOf(bone: Bone, frameCF: CFrame): BoneRef?
	local cf = bone.CFrame
	local parent = bone.Parent
	while parent and parent:IsA("Bone") do
		cf = parent.CFrame * cf
		parent = parent.Parent
	end
	local part = bone:FindFirstAncestorWhichIsA("BasePart")
	if not part then
		return nil
	end
	local r = cf.Rotation
	local toPart = part.CFrame.Rotation:Inverse() * frameCF.Rotation -- model space -> part space
	local M = r:Inverse() * toPart
	local Minv = M:Inverse()
	local dir = Minv:VectorToWorldSpace(Y_AXIS)
	local side = dir:Cross(Y_AXIS)
	side = if side.Magnitude > 0.2 then side.Unit else X_AXIS
	return { bone = bone, M = M, Minv = Minv, side = side, dir = dir }
end

local function findBones(prop: Prop)
	prop.bones = {}
	prop.boned = false
	local want = BONES[prop.kind]
	if not want then
		return
	end
	local frameCF = frameOf(prop)
	for _, d in ipairs(prop.model:GetDescendants()) do
		if d:IsA("Bone") and table.find(want, d.Name) then
			local ref = refOf(d, frameCF)
			if ref then
				local list = prop.bones[d.Name]
				if not list then
					list = {}
					prop.bones[d.Name] = list
				end
				table.insert(list, ref)
				prop.boned = true
			end
		end
	end
end

-- q: a rotation in model space; offset: a move in model space
local function put(ref: BoneRef, q: CFrame, offset: Vector3?)
	local inBone = ref.M * q * ref.Minv
	if offset then
		ref.bone.Transform = CFrame.new(ref.M:VectorToWorldSpace(offset)) * inBone
	else
		ref.bone.Transform = inBone
	end
end

-- turn every bone called `name` about a model-space axis
local function turn(prop: Prop, name: string, axis: Vector3, angle: number, offset: Vector3?)
	local list = prop.bones[name]
	if list then
		local q = CFrame.fromAxisAngle(axis, angle)
		for _, ref in ipairs(list) do
			put(ref, q, offset)
		end
	end
end

-- lift (+) or droop (-) the tip of every bone called `name`
local function bend(prop: Prop, name: string, angle: number, extraTwist: number?)
	local list = prop.bones[name]
	if list then
		for _, ref in ipairs(list) do
			local q = CFrame.fromAxisAngle(ref.side, angle)
			if extraTwist and extraTwist ~= 0 then
				q = q * CFrame.fromAxisAngle(ref.dir, extraTwist)
			end
			put(ref, q, nil)
		end
	end
end

local function rest(prop: Prop)
	for _, list in pairs(prop.bones) do
		for _, ref in ipairs(list) do
			if ref.bone.Parent then
				ref.bone.Transform = CFrame.identity
			end
		end
	end
	prop.posed = false
end

local function since(prop: Prop, event: string): number
	local at = prop.events[event]
	return if at then clock - at else math.huge
end

-- a damped wobble that starts at an event: amplitude, decay, speed
local function ring(e: number, amp: number, decay: number, speed: number): number
	if e > 3 then
		return 0
	end
	return amp * exp(-e * decay) * sin(e * speed)
end

-- ---------- the moves of each model ----------

local MOVES: { [string]: (prop: Prop, t: number, dt: number) -> () } = {}

MOVES.BananaPeel = function(prop, t)
	local flop = ring(since(prop, "drop"), 0.55, 4, 20) + ring(since(prop, "slip"), 0.9, 3.5, 16)
	for i = 1, 4 do
		local a: number
		if prop.inHand then
			a = -0.45 + 0.12 * sin(t * 2.3 + i) -- dangling from the stem
		else
			a = 0.04 * sin(t * 3.1 + i * 1.7) -- a little quiver on the floor
		end
		bend(prop, "Flap" .. i, a + flop * (if i % 2 == 0 then 1 else 0.8))
	end
	bend(prop, "Stem", 0.06 * sin(t * 2.7) + flop * 0.25)
end

MOVES.BubbleBlaster = function(prop, t, dt)
	local es = since(prop, "shot")
	local pull = if es < 0.05 then es / 0.05 elseif es < 0.25 then 1 - (es - 0.05) / 0.2 else 0
	turn(prop, "Trigger", X_AXIS, -0.5 * pull)
	local spinSpeed = 0.8 + (if es < 0.5 then 16 * (1 - es / 0.5) else 0)
	prop.spin = (prop.spin + dt * spinSpeed) % TAU
	local wob = ring(es, 0.2, 5, 30)
	local list = prop.bones.Ring
	if list then
		local q = CFrame.fromAxisAngle(Z_AXIS, prop.spin) * CFrame.fromAxisAngle(X_AXIS, wob)
		for _, ref in ipairs(list) do
			put(ref, q, nil)
		end
	end
	local slosh = 0.08 * sin(t * 5) * prop.moving + ring(es, 0.22, 4, 14)
	turn(prop, "Tank", X_AXIS, slosh, nil)
end

MOVES.AlarmDuck = function(prop, t, dt)
	local k = prop.moving
	local waddle = sin(t * 11)
	local hop = ring(since(prop, "drop"), 0.25, 6, 14)
	turn(prop, "Body", Z_AXIS, 0.16 * waddle * k + 0.03 * sin(t * 1.7), Vector3.new(0, 0.06 * abs(waddle) * k + abs(hop), 0))
	-- the head turns to whoever it honked at, else looks around
	local honk = since(prop, "honk")
	local quack = since(prop, "quack")
	local target = prop.data.target
	local yaw = 0.5 * sin(t * 0.6)
	if typeof(target) == "Vector3" and (min(honk, quack) < 3 or k > 0.2) then
		local rel = frameOf(prop):PointToObjectSpace(target)
		if Vector3.new(rel.X, 0, rel.Z).Magnitude > 0.5 then
			yaw = clamp(math.atan2(rel.X, rel.Z), -1.2, 1.2)
		end
	end
	prop.headYaw += (yaw - prop.headYaw) * min(1, dt * 8)
	turn(prop, "Head", Y_AXIS, prop.headYaw, nil)
	local e = min(honk, quack)
	local open = if e < 0.35 then sin(math.pi * e / 0.35) else 0
	bend(prop, "Bill", -0.55 * open)
	local tail = 0.35 * sin(t * 14) * k + 0.08 * sin(t * 3) + ring(e, 0.3, 5, 20)
	turn(prop, "Tail", Y_AXIS, tail, nil)
end

MOVES.SoftenerBottle = function(prop)
	local es = since(prop, "spray")
	local pump = if es < 0.8 then abs(sin(es * 22)) * (1 - es / 0.8) else 0
	turn(prop, "Trigger", X_AXIS, -0.45 * pump, nil)
end

MOVES.DashSlippers = function(prop, t)
	local ed = since(prop, "dash")
	local kick = if ed < 0.7 then exp(-ed * 4) else 0
	turn(prop, "Ribbon", X_AXIS, 0.08 * sin(t * 2.4) + 0.2 * kick * sin(ed * 12), nil)
	local swing = 0.15 + 0.1 * prop.moving
	turn(prop, "SlipperL", X_AXIS, swing * sin(t * 3) + 0.6 * kick * sin(ed * 14), nil)
	turn(prop, "SlipperR", X_AXIS, swing * sin(t * 3 + 1.3) + 0.6 * kick * sin(ed * 14 + 0.8), nil)
	local flap = if ed < 0.7 then sin(ed * 40) * 0.7 * (1 - ed / 0.7) else 0.06 * sin(t * 5)
	turn(prop, "WingL", Z_AXIS, flap, nil)
	turn(prop, "WingR", Z_AXIS, -flap, nil)
end

MOVES.DryerSheet = function(prop, t)
	local amp = if prop.inHand then 0.3 else 1
	local wind = 1 + prop.moving
	turn(prop, "Canopy", X_AXIS, 0.05 * sin(t * 5) * amp * wind, Vector3.new(0, 0.08 * sin(t * 6) * amp, 0))
	for i = 1, 4 do
		bend(prop, "Corner" .. i, (0.22 * sin(t * 9 + i * 1.6) * wind - 0.05) * amp)
	end
end

MOVES.LaundryBasket = function(prop, t)
	local k = prop.moving
	local squash = 0.12 * sin(t * 9) * k
	local bounce = ring(since(prop, "pounce"), 0.7, 5, 14) + ring(since(prop, "drop"), 0.3, 6, 16)
	turn(prop, "Top", X_AXIS, 0.04 * sin(t * 4.5) * k, Vector3.new(0, squash + bounce, 0))
end

MOVES.StaticBalloon = function(prop, t)
	local c = prop.charge
	local sway = 1 + prop.moving
	for i = 1, 3 do
		local jitter = if c > 0 then 0.05 * c * sin(t * 37 + i * 2) else 0
		local list = prop.bones["String" .. i]
		if list then
			local q = CFrame.fromAxisAngle(X_AXIS, 0.1 * sin(t * 2.2 + i * 0.8) * sway + jitter)
				* CFrame.fromAxisAngle(Z_AXIS, 0.08 * sin(t * 1.7 + i) * sway)
			for _, ref in ipairs(list) do
				put(ref, q, nil)
			end
		end
	end
	local recoil = ring(since(prop, "zap"), 0.4, 5, 18)
	local jiggle = 0.05 * c * sin(t * 40) + recoil
	local list = prop.bones.Balloon
	if list then
		local q = CFrame.fromAxisAngle(X_AXIS, jiggle) * CFrame.fromAxisAngle(Z_AXIS, 0.04 * c * sin(t * 33))
		local offset = Vector3.new(0, 0.12 * sin(t * 2.6) + 0.25 * c + abs(recoil) * 0.3, 0)
		for _, ref in ipairs(list) do
			put(ref, q, offset)
		end
	end
end

-- ---------- golden aura ----------

local function auraPart(prop: Prop): BasePart?
	if prop.frame and prop.frame.Parent then
		return prop.frame
	end
	local primary = prop.model.PrimaryPart
	if primary then
		return primary
	end
	for _, d in ipairs(prop.model:GetDescendants()) do
		if d:IsA("BasePart") and d.Transparency < 1 then
			return d
		end
	end
	return nil
end

local function setAura(prop: Prop, on: boolean)
	local e = prop.aura
	if on and not (e and e.Parent) then
		local part = auraPart(prop)
		if not part then
			return
		end
		-- one per part, ever: a prop tracked again (re-equipped, back in range) reuses it
		local old = part:FindFirstChild("ItemGoldAura")
		local oldEmitter = old and old:FindFirstChild("ItemGoldAura")
		if oldEmitter and oldEmitter:IsA("ParticleEmitter") then
			prop.aura = oldEmitter
			oldEmitter.Enabled = true
			return
		end
		local att = Instance.new("Attachment")
		att.Name = "ItemGoldAura"
		att.Parent = part
		local pe = Instance.new("ParticleEmitter")
		pe.Name = "ItemGoldAura"
		pe.Texture = SPARKLES
		pe.Color = ColorSequence.new(GOLD)
		pe.LightEmission = 1
		pe.LightInfluence = 0
		pe.Lifetime = NumberRange.new(0.5, 0.9)
		pe.Speed = NumberRange.new(0.4, 1.4)
		pe.SpreadAngle = Vector2.new(180, 180)
		pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 0) })
		pe.RotSpeed = NumberRange.new(-120, 120)
		pe.Rotation = NumberRange.new(0, 360)
		pe.Acceleration = Vector3.new(0, 0.8, 0)
		pe.Parent = att
		prop.aura = pe
		e = pe
	end
	if e then
		local rate = if low then AURA_RATE / 2 else AURA_RATE
		if prop.kind == "LaundryBasket" or prop.kind == "DryerSheet" then
			rate *= 2 -- the big ones
		end
		e.Rate = rate
		e.Enabled = on
	end
end

-- ---------- API ----------

-- The model kind of a world object (workspace.StealASock.Items child), or nil.
function ItemBones.KindOf(name: string): string?
	local prefix = string.match(name, "^(%a+)_")
	return if prefix then WORLD[prefix] else nil
end

-- Keeps a prop animated (ItemFX calls it 5 times a second for every item near the camera).
-- info: { frame: BasePart? (a tool's Handle), inHand: boolean?, gold: boolean?, hidden: boolean?,
-- charge: number? }
function ItemBones.Track(model: Model?, kind: string, info: { [string]: any }?): Prop?
	if not model or not BONES[kind] then
		return nil
	end
	local opts = info or {}
	local prop = props[model]
	local frame = if typeof(opts.frame) == "Instance" and opts.frame:IsA("BasePart") then opts.frame else nil
	if not frame then
		-- a world object the server moves (the duck) or welds to someone (canopy, basket) has an
		-- ItemRoot turned like the model: it follows the physics, the model's stored pivot may not
		local root = model:FindFirstChild("ItemRoot")
		frame = if root and root:IsA("BasePart") then root else nil
	end
	if not prop or prop.kind ~= kind then
		prop = {
			model = model,
			kind = kind,
			frame = frame,
			bones = {},
			boned = false,
			seen = 0,
			events = {},
			data = {},
			charge = 0,
			moving = 0,
			lastPos = nil,
			inHand = false,
			gold = false,
			hidden = false,
			spin = 0,
			headYaw = 0,
			aura = nil,
			posed = false,
		}
		props[model] = prop
		findBones(prop)
	end
	local p = prop :: Prop
	p.frame = frame or p.frame
	p.seen = os.clock()
	p.inHand = opts.inHand == true
	p.gold = opts.gold == true
	p.hidden = opts.hidden == true
	if type(opts.charge) == "number" then
		p.charge = clamp(opts.charge, 0, 1)
	end
	return p
end

-- Something happened to a prop: "drop", "slip", "shot", "spray", "dash", "honk", "quack",
-- "pounce", "zap" (data: honk / quack { target = Vector3 }).
function ItemBones.Kick(model: Model?, event: string, data: { [string]: any }?)
	if not model then
		return
	end
	local prop = props[model]
	if not prop then
		local kind = ItemBones.KindOf(model.Name)
		if not kind then
			return
		end
		prop = ItemBones.Track(model, kind, nil)
		if not prop then
			return
		end
	end
	local p = prop :: Prop
	p.events[event] = clock
	if data then
		for k, v in pairs(data) do
			p.data[k] = v
		end
	end
end

function ItemBones.SetCharge(model: Model?, charge: number)
	local prop = model and props[model]
	if prop then
		prop.charge = clamp(charge, 0, 1)
	end
end

function ItemBones.SetLow(on: boolean)
	low = on
end

-- Every frame (ItemFX), with the effects' (time-scaled) dt and the real one (how fast props move).
function ItemBones.Step(dt: number, camPos: Vector3, realDt: number?)
	clock += dt
	local rdt = realDt or dt
	local auras = 0
	for model, prop in pairs(props) do
		if model.Parent == nil then
			props[model] = nil
		else
			local pos = frameOf(prop).Position
			local last = prop.lastPos
			if last and rdt > 0 then
				local speed = (pos - last).Magnitude / rdt
				prop.moving += (clamp(speed / 8, 0, 1) - prop.moving) * min(1, rdt * 6)
			end
			prop.lastPos = pos
			local near = (pos - camPos).Magnitude <= RANGE
			if prop.boned then
				if near then
					local move = MOVES[prop.kind]
					if move then
						move(prop, clock, dt)
						prop.posed = true
					end
				elseif prop.posed then
					rest(prop)
				end
			end
			local wantAura = prop.gold and near and not prop.hidden and auras < AURA_MAX
			if wantAura then
				auras += 1
			end
			if wantAura or prop.aura then
				setAura(prop, wantAura)
			end
		end
	end
end

-- Lets go of props nobody tracked lately (put away, out of range, gone): bones back, aura off.
function ItemBones.Sweep()
	local t = os.clock()
	for model, prop in pairs(props) do
		if model.Parent == nil or t - prop.seen > FORGET then
			if model.Parent then
				rest(prop)
			end
			if prop.aura then
				prop.aura.Enabled = false
			end
			props[model] = nil
		end
	end
end

function ItemBones.Get(model: Model?): Prop?
	return if model then props[model] else nil
end

function ItemBones.Count(): number
	local n = 0
	for _ in pairs(props) do
		n += 1
	end
	return n
end

function ItemBones.Auras(): number
	local n = 0
	for _, prop in pairs(props) do
		if prop.aura and prop.aura.Enabled then
			n += 1
		end
	end
	return n
end

return ItemBones
