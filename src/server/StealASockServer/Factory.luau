-- Factory: builds every sock from Parts. Body = L-shaped leg + heel + foot with googly eyes; each
-- roster type adds signature FEATURES (fangs, monocle, beard, pogo stick, headphones, tentacles...);
-- rarity adds glow; mutations add their own look. Models are tagged "Sock" (CollectionService)
-- so meshes can replace them later. The Leg is the PrimaryPart and the only anchored part;
-- everything else is welded to it, so moving the Leg moves the whole sock.
local CollectionService = game:GetService("CollectionService")

local MeshTemplate = require(script.Parent:WaitForChild("MeshTemplate"))

local Factory = {}
local S

type Ctx = {
	model: Model,
	leg: BasePart,
	foot: BasePart,
	color: Color3,
	accent: Color3,
	material: Enum.Material,
	dir: number, -- -1 left, +1 right, 0 single
	scale: number,
	sock: any,
}

local BLACK = Color3.new(0, 0, 0)
local WHITE = Color3.new(1, 1, 1)

local function newPart(name: string, size: Vector3, color: Color3, material: Enum.Material, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = material
	p.Anchored = false
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function weld(root: BasePart, p: BasePart)
	local w = Instance.new("WeldConstraint")
	w.Part0 = root
	w.Part1 = p
	w.Parent = p
end

-- moves an already-welded part: drop the old weld, set the CFrame, weld again
local function reposition(ctx: Ctx, p: BasePart, cf: CFrame)
	local w = p:FindFirstChildOfClass("WeldConstraint")
	if w then
		w:Destroy()
	end
	p.CFrame = ctx.leg.CFrame * cf
	weld(ctx.leg, p)
end

-- adds a part positioned in the sock's local space (origin = Leg centre)
local function attach(ctx: Ctx, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, shape: Enum.PartType?): Part
	local p = newPart(name, size, color, material or Enum.Material.SmoothPlastic, ctx.model)
	if shape then
		p.Shape = shape
	end
	p.CFrame = ctx.leg.CFrame * cf
	weld(ctx.leg, p)
	return p
end

local function emitter(parent: BasePart, name: string, color: Color3, rate: number, size: number, speed: number, lifetime: number, spread: number?, light: number?): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Name = name
	e.Color = ColorSequence.new(color)
	e.Rate = rate
	e.Size = NumberSequence.new(size)
	e.Speed = NumberRange.new(speed * 0.6, speed)
	e.Lifetime = NumberRange.new(lifetime * 0.7, lifetime)
	e.SpreadAngle = Vector2.new(spread or 180, spread or 180)
	e.LightEmission = light or 0.5
	e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
	e.Parent = parent
	return e
end

local function light(parent: BasePart, color: Color3, range: number, brightness: number): PointLight
	local l = Instance.new("PointLight")
	l.Color = color
	l.Range = range
	l.Brightness = brightness
	l.Shadows = false
	l.Parent = parent
	return l
end

-- ---------- signature features ----------

local FEATURES: { [string]: (ctx: Ctx) -> () } = {}

FEATURES.sadstripe = function(ctx)
	attach(ctx, "Stripe", Vector3.new(1.7, 0.4, 1.7), CFrame.new(0, 1.0, 0) * CFrame.Angles(0, 0, 0.12), ctx.accent)
end
FEATURES.sadbrows = function(ctx)
	attach(ctx, "Brow", Vector3.new(0.5, 0.12, 0.12), CFrame.new(-0.42, 0.95, 0.8) * CFrame.Angles(0, 0, 0.5), BLACK)
	attach(ctx, "Brow", Vector3.new(0.5, 0.12, 0.12), CFrame.new(0.42, 0.95, 0.8) * CFrame.Angles(0, 0, -0.5), BLACK)
end
FEATURES.small = function(ctx)
	-- Ankle Biter: pudgy and short; handled by scale in Build
end
FEATURES.fangs = function(ctx)
	attach(ctx, "Fang", Vector3.new(0.22, 0.4, 0.15), CFrame.new(-0.22, 0.05, 0.86), WHITE)
	attach(ctx, "Fang", Vector3.new(0.22, 0.4, 0.15), CFrame.new(0.22, 0.05, 0.86), WHITE)
	attach(ctx, "Mouth", Vector3.new(0.9, 0.16, 0.1), CFrame.new(0, 0.25, 0.84), Color3.fromRGB(120, 30, 40))
end
FEATURES.crusty = function(ctx)
	for i = 1, 6 do
		local a = i * 1.1
		attach(ctx, "Crust", Vector3.new(0.25, 0.25, 0.25), CFrame.new(math.cos(a) * 0.8, -0.9 + (i % 3) * 0.5, math.sin(a) * 0.8), Color3.fromRGB(150, 120, 70), Enum.Material.Slate)
	end
end
FEATURES.stiff = function(ctx)
	ctx.foot.Size = Vector3.new(2.2, 1.3, 1.6)
	reposition(ctx, ctx.foot, CFrame.new(ctx.dir * 0.8, -ctx.leg.Size.Y / 2, 0))
end
FEATURES.sweatband = function(ctx)
	attach(ctx, "Sweatband", Vector3.new(1.8, 0.45, 1.8), CFrame.new(0, 1.25, 0), Color3.fromRGB(230, 60, 60), Enum.Material.Fabric)
	attach(ctx, "SweatbandStripe", Vector3.new(1.82, 0.12, 1.82), CFrame.new(0, 1.25, 0), WHITE)
end
FEATURES.damp = function(ctx)
	local drip = emitter(ctx.leg, "Drips", Color3.fromRGB(120, 180, 255), 1.5, 0.18, 0.5, 1.2, 30, 0)
	drip.Acceleration = Vector3.new(0, -12, 0)
	drip.EmissionDirection = Enum.NormalId.Bottom
end
FEATURES.argyle = function(ctx)
	for i, y in ipairs({ 0.9, 0.2, -0.5 }) do
		attach(ctx, "Diamond", Vector3.new(0.55, 0.55, 0.08), CFrame.new(if i % 2 == 0 then 0.4 else -0.4, y, 0.82) * CFrame.Angles(0, 0, math.pi / 4), ctx.accent)
	end
end
FEATURES.monocle = function(ctx)
	local ring = attach(ctx, "Monocle", Vector3.new(0.12, 0.85, 0.85), CFrame.new(0.42, 0.55, 1.1) * CFrame.Angles(0, math.pi / 2, 0), Color3.fromRGB(230, 200, 90), Enum.Material.Metal, Enum.PartType.Cylinder)
	ring.CanCollide = false
	attach(ctx, "MonocleChain", Vector3.new(0.08, 0.9, 0.08), CFrame.new(0.85, 0.1, 0.95) * CFrame.Angles(0, 0, 0.4), Color3.fromRGB(230, 200, 90), Enum.Material.Metal)
end
FEATURES.toes = function(ctx)
	for i = 1, 5 do
		local z = -0.6 + (i - 1) * 0.3
		attach(ctx, "Toe", Vector3.new(0.42, 0.42, 0.42), CFrame.new(ctx.dir * 2.7, -1.75 + (i % 2) * 0.1, z), ctx.color, ctx.material, Enum.PartType.Ball)
	end
end
FEATURES.beard = function(ctx)
	attach(ctx, "Beard", Vector3.new(1.1, 0.9, 0.5), CFrame.new(0, -0.15, 0.75), Color3.fromRGB(225, 225, 230), Enum.Material.Fabric)
	attach(ctx, "Moustache", Vector3.new(1.0, 0.18, 0.2), CFrame.new(0, 0.28, 0.9), Color3.fromRGB(225, 225, 230), Enum.Material.Fabric)
end
FEATURES.toga = function(ctx)
	attach(ctx, "Toga", Vector3.new(1.9, 1.6, 0.35), CFrame.new(-0.2, -0.3, -0.75) * CFrame.Angles(0, 0, 0.35), WHITE, Enum.Material.Fabric)
	attach(ctx, "Laurel", Vector3.new(1.9, 0.3, 1.9), CFrame.new(0, 1.45, 0), Color3.fromRGB(90, 170, 80), Enum.Material.Grass)
end
FEATURES.thinking = function(ctx)
	attach(ctx, "Brow", Vector3.new(0.5, 0.12, 0.12), CFrame.new(-0.42, 0.98, 0.8), BLACK)
	attach(ctx, "Brow", Vector3.new(0.5, 0.12, 0.12), CFrame.new(0.42, 1.12, 0.8) * CFrame.Angles(0, 0, 0.35), BLACK)
end
FEATURES.tall = function(ctx)
	-- Knee-High Kevin: handled by scale in Build (the body is stretched, not scaled)
end
FEATURES.gripdots = function(ctx)
	for i = 1, 4 do
		attach(ctx, "GripDot", Vector3.new(0.3, 0.12, 0.3), CFrame.new(ctx.dir * (0.3 + i * 0.45), -2.3, if i % 2 == 0 then 0.4 else -0.4), Color3.fromRGB(240, 240, 250), Enum.Material.Rubber)
	end
end
FEATURES.stress = function(ctx)
	attach(ctx, "Brow", Vector3.new(0.5, 0.12, 0.12), CFrame.new(-0.42, 0.95, 0.8) * CFrame.Angles(0, 0, -0.5), BLACK)
	attach(ctx, "Brow", Vector3.new(0.5, 0.12, 0.12), CFrame.new(0.42, 0.95, 0.8) * CFrame.Angles(0, 0, 0.5), BLACK)
	attach(ctx, "Mouth", Vector3.new(0.1, 0.5, 0.5), CFrame.new(0, 0.05, 0.84) * CFrame.Angles(0, math.pi / 2, 0), BLACK, nil, Enum.PartType.Cylinder)
	for i = 1, 3 do
		attach(ctx, "Sweat", Vector3.new(0.22, 0.32, 0.22), CFrame.new(-0.9 + i * 0.6, 1.1, 0.7), Color3.fromRGB(120, 190, 255), Enum.Material.Glass, Enum.PartType.Ball)
	end
	-- squeezing itself: two tiny arms hugging the body
	attach(ctx, "Arm", Vector3.new(1.6, 0.3, 0.3), CFrame.new(0, -0.4, 0.85), ctx.color, ctx.material)
end
FEATURES.pogo = function(ctx)
	attach(ctx, "PogoStick", Vector3.new(0.25, 2.2, 0.25), CFrame.new(ctx.dir * 0.6, -3.1, 0), Color3.fromRGB(230, 60, 60), Enum.Material.Metal)
	attach(ctx, "PogoFoot", Vector3.new(0.7, 0.2, 0.7), CFrame.new(ctx.dir * 0.6, -4.2, 0), Color3.fromRGB(60, 60, 70), Enum.Material.Metal)
	for i = 1, 3 do
		attach(ctx, "PogoSpring", Vector3.new(0.5, 0.12, 0.5), CFrame.new(ctx.dir * 0.6, -3.5 - i * 0.22, 0), Color3.fromRGB(200, 200, 210), Enum.Material.Metal)
	end
	attach(ctx, "PogoHandle", Vector3.new(1.4, 0.2, 0.2), CFrame.new(ctx.dir * 0.6, 0.6, 0.95), Color3.fromRGB(60, 60, 70), Enum.Material.Metal)
end
FEATURES.headphones = function(ctx)
	attach(ctx, "HeadBand", Vector3.new(2.1, 0.25, 0.3), CFrame.new(0, 1.7, 0), Color3.fromRGB(40, 40, 50))
	attach(ctx, "Cup", Vector3.new(0.4, 0.8, 0.8), CFrame.new(-1.0, 1.2, 0), Color3.fromRGB(255, 0, 200), Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
	attach(ctx, "Cup", Vector3.new(0.4, 0.8, 0.8), CFrame.new(1.0, 1.2, 0), Color3.fromRGB(255, 0, 200), Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
	attach(ctx, "Shades", Vector3.new(1.5, 0.35, 0.15), CFrame.new(0, 0.55, 0.9), Color3.fromRGB(20, 20, 30), Enum.Material.Glass)
end
FEATURES.sheet = function(ctx)
	local disc = attach(ctx, "DryerSheet", Vector3.new(0.12, 1.6, 1.6), CFrame.new(0, -2.0, 1.1) * CFrame.Angles(0, 0, math.pi / 2), Color3.fromRGB(240, 240, 250), Enum.Material.Fabric, Enum.PartType.Cylinder)
	disc.Name = "Turntable"
	attach(ctx, "Needle", Vector3.new(0.08, 0.08, 0.9), CFrame.new(0.5, -1.85, 1.0) * CFrame.Angles(0, 0.6, 0), Color3.fromRGB(60, 60, 70), Enum.Material.Metal)
end
FEATURES.tentacles = function(ctx)
	for i = 1, 8 do
		local a = i / 8 * math.pi * 2
		local cf = CFrame.new(0, -1.2, 0) * CFrame.Angles(0, a, 0) * CFrame.new(0, 0, 1.3) * CFrame.Angles(0.9, 0, 0)
		attach(ctx, "Tentacle", Vector3.new(0.7, 2.0, 0.7), cf, ctx.color, ctx.material)
		attach(ctx, "TentacleTip", Vector3.new(0.75, 0.75, 0.75), cf * CFrame.new(0, -1.1, 0.25), ctx.accent, ctx.material, Enum.PartType.Ball)
	end
	ctx.foot.Transparency = 1
end
FEATURES.armor = function(ctx)
	attach(ctx, "Plate", Vector3.new(1.8, 1.4, 0.2), CFrame.new(0, -0.1, 0.9), Color3.fromRGB(220, 220, 230), Enum.Material.Foil)
	attach(ctx, "Plate", Vector3.new(1.8, 1.4, 0.2), CFrame.new(0, -0.1, -0.9), Color3.fromRGB(220, 220, 230), Enum.Material.Foil)
	attach(ctx, "Helmet", Vector3.new(1.9, 0.9, 1.9), CFrame.new(0, 1.75, 0), Color3.fromRGB(220, 220, 230), Enum.Material.Foil)
	attach(ctx, "Plume", Vector3.new(0.25, 0.9, 0.25), CFrame.new(0, 2.5, 0), Color3.fromRGB(230, 60, 60), Enum.Material.Fabric)
end
FEATURES.flies = function(ctx)
	local flies = emitter(ctx.leg, "Flies", Color3.fromRGB(20, 20, 20), 8, 0.14, 3, 1.4, 180, 0)
	flies.Acceleration = Vector3.new(0, 1, 0)
	flies.Drag = 2
end
FEATURES.stinklines = function(ctx)
	local stink = emitter(ctx.leg, "Stink", Color3.fromRGB(140, 220, 90), 5, 0.6, 1.5, 1.6, 40, 0.3)
	stink.EmissionDirection = Enum.NormalId.Top
	stink.Acceleration = Vector3.new(0, 1, 0)
end
FEATURES.longneck = function(ctx)
	-- The Sock Ness Monster: a long neck rising out of a laundry basket
	attach(ctx, "Neck", Vector3.new(1.0, 3.6, 1.0), CFrame.new(0, 3.2, 0) * CFrame.Angles(0, 0, 0.15), ctx.color, ctx.material)
	attach(ctx, "Head", Vector3.new(1.5, 1.2, 2.2), CFrame.new(0.4, 5.2, 0.4) * CFrame.Angles(0, -0.4, 0), ctx.color, ctx.material)
	attach(ctx, "NeckEye", Vector3.new(0.4, 0.4, 0.4), CFrame.new(0.9, 5.4, 1.2), WHITE, nil, Enum.PartType.Ball)
	attach(ctx, "NeckPupil", Vector3.new(0.2, 0.2, 0.2), CFrame.new(0.95, 5.4, 1.38), BLACK, nil, Enum.PartType.Ball)
	for i = 1, 4 do
		attach(ctx, "Spine", Vector3.new(0.3, 0.5, 0.2), CFrame.new(-0.1, 2.0 + i * 0.7, -0.5), ctx.accent)
	end
	local basket = attach(ctx, "Basket", Vector3.new(2.2, 3.2, 3.2), CFrame.new(0, -1.2, 0) * CFrame.Angles(0, 0, math.pi / 2), Color3.fromRGB(196, 160, 96), Enum.Material.Wood, Enum.PartType.Cylinder)
	basket.Name = "Basket"
	ctx.foot.Transparency = 1
end
FEATURES.lightning = function(ctx)
	ctx.leg.Material = Enum.Material.Neon
	ctx.foot.Material = Enum.Material.Neon
	for i = 1, 6 do
		local a = i / 6 * math.pi * 2
		attach(ctx, "Fuzz", Vector3.new(0.2, 0.9, 0.2), CFrame.new(math.cos(a) * 0.6, 1.9, math.sin(a) * 0.6) * CFrame.Angles(math.sin(a) * 0.5, 0, math.cos(a) * 0.5), Color3.fromRGB(120, 220, 255), Enum.Material.Neon)
	end
	local sparks = emitter(ctx.leg, "Sparks", Color3.fromRGB(150, 230, 255), 14, 0.12, 8, 0.5, 180, 1)
	sparks.LightInfluence = 0
	light(ctx.leg, Color3.fromRGB(120, 220, 255), 12, 1.2)
end
FEATURES.lintcrown = function(ctx)
	attach(ctx, "CrownBase", Vector3.new(1.9, 0.4, 1.9), CFrame.new(0, 1.8, 0), Color3.fromRGB(255, 215, 0), Enum.Material.Metal)
	for i = 1, 5 do
		local a = i / 5 * math.pi * 2
		attach(ctx, "CrownSpike", Vector3.new(0.3, 0.8, 0.3), CFrame.new(math.cos(a) * 0.75, 2.35, math.sin(a) * 0.75), Color3.fromRGB(255, 215, 0), Enum.Material.Neon)
	end
end
FEATURES.lintbody = function(ctx)
	ctx.leg.Material = Enum.Material.Fabric
	ctx.foot.Material = Enum.Material.Fabric
	for i = 1, 5 do
		local a = i * 1.3
		attach(ctx, "LintBall", Vector3.new(0.6, 0.6, 0.6), CFrame.new(math.cos(a) * 0.85, -0.6 + i * 0.35, math.sin(a) * 0.85), Color3.fromRGB(165, 165, 172), Enum.Material.Fabric, Enum.PartType.Ball)
	end
end
FEATURES.tophat = function(ctx)
	attach(ctx, "HatBrim", Vector3.new(0.2, 2.4, 2.4), CFrame.new(0, 1.7, 0) * CFrame.Angles(0, 0, math.pi / 2), Color3.fromRGB(20, 20, 20), Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
	attach(ctx, "HatTop", Vector3.new(1.4, 1.6, 1.6), CFrame.new(0, 2.6, 0) * CFrame.Angles(0, 0, math.pi / 2), Color3.fromRGB(20, 20, 20), Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
	attach(ctx, "HatBand", Vector3.new(0.4, 1.66, 1.66), CFrame.new(0, 2.1, 0) * CFrame.Angles(0, 0, math.pi / 2), Color3.fromRGB(255, 215, 0), Enum.Material.Metal, Enum.PartType.Cylinder)
	attach(ctx, "Monocle", Vector3.new(0.12, 0.85, 0.85), CFrame.new(0.42, 0.55, 1.1) * CFrame.Angles(0, math.pi / 2, 0), Color3.fromRGB(255, 215, 0), Enum.Material.Metal, Enum.PartType.Cylinder)
end
FEATURES.goldthread = function(ctx)
	ctx.leg.Material = Enum.Material.Metal
	ctx.foot.Material = Enum.Material.Metal
	for i = 1, 3 do
		attach(ctx, "Thread", Vector3.new(1.7, 0.08, 1.7), CFrame.new(0, -0.9 + i * 0.6, 0), Color3.fromRGB(255, 240, 150), Enum.Material.Neon)
	end
end
FEATURES.cashspray = function(ctx)
	local cash = emitter(ctx.leg, "Cash", Color3.fromRGB(90, 230, 120), 6, 0.4, 6, 1.5, 60, 0.2)
	cash.EmissionDirection = Enum.NormalId.Top
	cash.Acceleration = Vector3.new(0, -10, 0)
	cash.Rotation = NumberRange.new(0, 360)
	cash.RotSpeed = NumberRange.new(-180, 180)
end
FEATURES.lost = function(ctx)
	ctx.leg.Transparency = 0.3
	ctx.foot.Transparency = 0.3
	local ghost = emitter(ctx.leg, "Ghost", Color3.fromRGB(190, 190, 255), 5, 0.5, 1, 2, 180, 0.6)
	ghost.Acceleration = Vector3.new(0, 1.5, 0)
	local gui = Instance.new("BillboardGui")
	gui.Name = "LostMark"
	gui.Adornee = ctx.leg
	gui.Size = UDim2.fromOffset(60, 60)
	gui.StudsOffset = Vector3.new(0, 2.6, 0)
	gui.MaxDistance = 120
	gui.LightInfluence = 0
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.Font = Enum.Font.FredokaOne
	t.TextScaled = true
	t.TextColor3 = Color3.fromRGB(200, 200, 255)
	t.Text = "?"
	t.Parent = gui
	gui.Parent = ctx.leg
	light(ctx.leg, Color3.fromRGB(120, 120, 255), 10, 0.8)
end
FEATURES.puppet = function(ctx)
	attach(ctx, "Mouth", Vector3.new(1.4, 0.5, 0.9), CFrame.new(0, -0.1, 0.75), Color3.fromRGB(180, 30, 50))
	attach(ctx, "Teeth", Vector3.new(1.3, 0.14, 0.2), CFrame.new(0, 0.17, 1.05), WHITE)
	attach(ctx, "Tongue", Vector3.new(0.5, 0.15, 0.6), CFrame.new(0, -0.3, 1.0), Color3.fromRGB(240, 100, 130))
	attach(ctx, "Hair", Vector3.new(1.2, 0.5, 1.2), CFrame.new(0, 1.75, 0), Color3.fromRGB(255, 120, 40), Enum.Material.Fabric)
end

-- ---------- the second wave: the 13 socks that came after the first 21 ----------
-- These measure from the Leg's own size, so they sit right on the short socks (Bambino) too.

local GOLD = Color3.fromRGB(242, 193, 78)
local CYLINDER = Enum.PartType.Cylinder
local BALL = Enum.PartType.Ball
local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2) -- a Cylinder's axis is X: this stands it up
local FACING = CFrame.Angles(0, math.pi / 2, 0) -- and this points it out of the face (+Z)

local function topOf(ctx: Ctx): number
	return ctx.leg.Size.Y / 2 + 0.05 -- the top of the cuff
end

local function eyeLevel(ctx: Ctx): number
	return ctx.leg.Size.Y / 2 - 1.05
end

-- thin vertical stripes round the leg, none across the face
local function verticalStripes(ctx: Ctx, color: Color3)
	local h = ctx.leg.Size.Y
	for i = 0, 7 do
		local a = i / 8 * math.pi * 2 + 0.2
		if math.cos(a) < 0.9 then
			attach(ctx, "Pinstripe", Vector3.new(0.06, h - 0.7, 0.06), CFrame.new(math.sin(a) * 0.81, -0.25, math.cos(a) * 0.81), color)
		end
	end
end

-- heavy half-closed lids over the googly eyes
local function eyelids(ctx: Ctx)
	for _, ex in ipairs({ -0.42, 0.42 }) do
		attach(ctx, "Lid", Vector3.new(0.7, 0.3, 0.7), CFrame.new(ex, eyeLevel(ctx) + 0.18, 0.72), ctx.color, ctx.material)
	end
end

FEATURES.polkadots = function(ctx)
	local k = ctx.leg.Size.Y / 3.2
	for _, p in ipairs({ { -0.8, -0.7, 0.1 }, { 0.8, -0.2, -0.3 }, { -0.5, 0.3, -0.62 }, { 0.45, -1.0, 0.62 }, { 0.75, 0.6, 0.25 }, { -0.75, -1.3, -0.3 } }) do
		attach(ctx, "PolkaDot", Vector3.new(0.34, 0.34, 0.34), CFrame.new(p[1], p[2] * k, p[3]), WHITE, nil, BALL)
	end
	local footY = -ctx.leg.Size.Y / 2
	attach(ctx, "PolkaDot", Vector3.new(0.34, 0.34, 0.34), CFrame.new(ctx.dir * 1.5, footY + 0.62, 0.35), WHITE, nil, BALL)
	attach(ctx, "PolkaDot", Vector3.new(0.28, 0.28, 0.28), CFrame.new(ctx.dir * 2.1, footY + 0.5, -0.45), WHITE, nil, BALL)
end
FEATURES.hairbow = function(ctx)
	local y = topOf(ctx) + 0.2
	attach(ctx, "BowKnot", Vector3.new(0.32, 0.32, 0.32), CFrame.new(0, y, 0.1), ctx.accent, nil, BALL)
	for _, s in ipairs({ -1, 1 }) do
		attach(ctx, "BowLoop", Vector3.new(0.2, 0.55, 0.55), CFrame.new(s * 0.36, y + 0.05, 0.1) * FACING * CFrame.Angles(s * 0.3, 0, 0), ctx.accent, nil, CYLINDER)
		attach(ctx, "BowEnd", Vector3.new(0.14, 0.4, 0.08), CFrame.new(s * 0.14, y - 0.22, 0.15) * CFrame.Angles(0, 0, s * 0.4), ctx.accent)
	end
end
FEATURES.pajamas = function(ctx)
	verticalStripes(ctx, WHITE)
end
FEATURES.nightcap = function(ctx)
	local y = topOf(ctx)
	local back = -ctx.dir -- the tail flops over to the heel side
	attach(ctx, "CapBand", Vector3.new(0.35, 1.8, 1.8), CFrame.new(0, y + 0.1, 0) * UPRIGHT, ctx.accent, Enum.Material.Fabric, CYLINDER)
	attach(ctx, "Nightcap", Vector3.new(1.3, 0.6, 1.3), CFrame.new(back * 0.15, y + 0.5, 0) * CFrame.Angles(0, 0, back * 0.3), ctx.accent, Enum.Material.Fabric)
	attach(ctx, "Nightcap", Vector3.new(0.8, 0.5, 0.8), CFrame.new(back * 0.7, y + 0.75, 0) * CFrame.Angles(0, 0, back * 0.9), ctx.accent, Enum.Material.Fabric)
	attach(ctx, "Nightcap", Vector3.new(0.5, 0.5, 0.5), CFrame.new(back * 1.15, y + 0.45, 0) * CFrame.Angles(0, 0, back * 1.4), ctx.accent, Enum.Material.Fabric)
	attach(ctx, "Pompom", Vector3.new(0.5, 0.5, 0.5), CFrame.new(back * 1.35, y + 0.05, 0), WHITE, Enum.Material.Fabric, BALL)
	for _, p in ipairs({ { 0.3, 0.55 }, { -0.25, 0.4 } }) do
		attach(ctx, "CapStar", Vector3.new(0.12, 0.12, 0.05), CFrame.new(back * p[1], y + p[2], 0.67) * CFrame.Angles(0, 0, math.pi / 4), Color3.fromRGB(255, 220, 90), Enum.Material.Neon)
	end
	eyelids(ctx) -- always sleepy
end
FEATURES.pacifier = function(ctx)
	local y = eyeLevel(ctx) - 0.42
	attach(ctx, "Pacifier", Vector3.new(0.12, 0.7, 0.7), CFrame.new(0, y, 0.86) * FACING, ctx.accent, nil, CYLINDER)
	attach(ctx, "PacifierRing", Vector3.new(0.08, 0.38, 0.38), CFrame.new(0, y, 0.98) * FACING, WHITE, nil, CYLINDER)
	attach(ctx, "PacifierKnob", Vector3.new(0.18, 0.18, 0.18), CFrame.new(0, y, 1.04), ctx.accent, nil, BALL)
end
FEATURES.babycurl = function(ctx)
	local y = topOf(ctx)
	local brown = Color3.fromRGB(150, 96, 50)
	attach(ctx, "Curl", Vector3.new(0.26, 0.26, 0.26), CFrame.new(0, y + 0.1, 0.2), brown, Enum.Material.Fabric, BALL)
	attach(ctx, "Curl", Vector3.new(0.22, 0.22, 0.22), CFrame.new(0.12, y + 0.3, 0.15), brown, Enum.Material.Fabric, BALL)
	attach(ctx, "Curl", Vector3.new(0.18, 0.18, 0.18), CFrame.new(0.02, y + 0.45, 0.05), brown, Enum.Material.Fabric, BALL)
end
FEATURES.furcuff = function(ctx)
	local y = ctx.leg.Size.Y / 2 - 0.2
	attach(ctx, "FurCuff", Vector3.new(2.0, 0.6, 2.0), CFrame.new(0, y, 0), WHITE, Enum.Material.Fabric)
	for i = 1, 8 do
		local a = i / 8 * math.pi * 2
		attach(ctx, "Fluff", Vector3.new(0.5, 0.5, 0.5), CFrame.new(math.cos(a) * 0.95, y + (i % 2) * 0.12, math.sin(a) * 0.95), WHITE, Enum.Material.Fabric, BALL)
	end
	-- a holly sprig: two leaves, three berries
	attach(ctx, "Holly", Vector3.new(0.4, 0.12, 0.2), CFrame.new(0.55, y + 0.15, 0.98) * CFrame.Angles(0, 0, 0.5), ctx.accent)
	attach(ctx, "Holly", Vector3.new(0.4, 0.12, 0.2), CFrame.new(0.92, y + 0.1, 0.78) * CFrame.Angles(0, 0.6, -0.4), ctx.accent)
	for j = 1, 3 do
		attach(ctx, "Berry", Vector3.new(0.16, 0.16, 0.16), CFrame.new(0.66 + j * 0.08, y + 0.05 + (j % 2) * 0.1, 1.02), Color3.fromRGB(220, 30, 40), nil, BALL)
	end
end
FEATURES.jinglebell = function(ctx)
	local footY = -ctx.leg.Size.Y / 2
	local x = ctx.dir * 2.95
	attach(ctx, "BellLoop", Vector3.new(0.3, 0.06, 0.06), CFrame.new(ctx.dir * 2.72, footY + 0.05, 0), GOLD, Enum.Material.Metal)
	attach(ctx, "Bell", Vector3.new(0.48, 0.48, 0.48), CFrame.new(x, footY - 0.2, 0), GOLD, Enum.Material.Metal, BALL)
	attach(ctx, "BellSlot", Vector3.new(0.3, 0.05, 0.05), CFrame.new(x, footY - 0.3, 0.22), Color3.fromRGB(70, 50, 20))
	-- a white snowflake on the leg
	for i = 0, 2 do
		attach(ctx, "Snowflake", Vector3.new(0.06, 0.4, 0.06), CFrame.new(ctx.dir * 0.82, -0.6, 0.1) * CFrame.Angles(i * math.pi / 3, 0, 0), WHITE)
	end
end
FEATURES.ninjamask = function(ctx)
	local h = ctx.leg.Size.Y / 2
	local ey = eyeLevel(ctx)
	local hood = ctx.color:Lerp(BLACK, 0.4)
	local above = h + 0.1 - (ey + 0.36)
	attach(ctx, "Hood", Vector3.new(1.8, above, 1.8), CFrame.new(0, ey + 0.36 + above / 2, 0), hood, Enum.Material.Fabric)
	attach(ctx, "Hood", Vector3.new(1.72, 0.4, 1.72), CFrame.new(0, ey - 0.56, 0), hood, Enum.Material.Fabric)
	attach(ctx, "HoodBack", Vector3.new(1.5, 1.6, 0.12), CFrame.new(0, ey - 0.3, -0.86), hood, Enum.Material.Fabric)
	for _, s in ipairs({ -1, 1 }) do
		attach(ctx, "Brow", Vector3.new(0.5, 0.1, 0.1), CFrame.new(s * 0.42, ey + 0.42, 0.93) * CFrame.Angles(0, 0, s * 0.35), BLACK)
	end
end
FEATURES.headband = function(ctx)
	local y = eyeLevel(ctx) + 0.5
	attach(ctx, "Headband", Vector3.new(1.86, 0.22, 1.86), CFrame.new(0, y, 0), ctx.accent, Enum.Material.Fabric)
	attach(ctx, "BandKnot", Vector3.new(0.3, 0.3, 0.3), CFrame.new(0, y, -0.95), ctx.accent, Enum.Material.Fabric, BALL)
	for _, s in ipairs({ -1, 1 }) do
		attach(ctx, "BandTail", Vector3.new(0.18, 1.0, 0.06), CFrame.new(s * 0.25, y - 0.5, -1.0) * CFrame.Angles(0.25, 0, s * 0.35), ctx.accent, Enum.Material.Fabric)
	end
	attach(ctx, "Shuriken", Vector3.new(0.3, 0.3, 0.06), CFrame.new(0.55, y, 0.94) * CFrame.Angles(0, 0, math.pi / 4), Color3.fromRGB(200, 205, 215), Enum.Material.Metal)
	attach(ctx, "AnkleWrap", Vector3.new(1.66, 0.2, 1.66), CFrame.new(0, -ctx.leg.Size.Y / 2 + 0.75, 0) * CFrame.Angles(0, 0, 0.1), Color3.fromRGB(150, 150, 160), Enum.Material.Fabric)
end
FEATURES.sailorstripes = function(ctx)
	local h = ctx.leg.Size.Y / 2
	for _, y in ipairs({ -h + 0.9, -h + 1.4 }) do
		attach(ctx, "SailorStripe", Vector3.new(1.66, 0.28, 1.66), CFrame.new(0, y, 0), ctx.accent, Enum.Material.Fabric)
	end
end
FEATURES.tricorn = function(ctx)
	local y = topOf(ctx)
	local black = Color3.fromRGB(28, 26, 34)
	attach(ctx, "TricornCrown", Vector3.new(0.7, 1.3, 1.3), CFrame.new(0, y + 0.35, 0) * UPRIGHT, black, nil, CYLINDER)
	for i = 0, 2 do
		local around = CFrame.new(0, y + 0.15, 0) * CFrame.Angles(0, i / 3 * math.pi * 2, 0)
		attach(ctx, "TricornBrim", Vector3.new(1.3, 0.14, 0.7), around * CFrame.new(0, 0, 0.75) * CFrame.Angles(-0.35, 0, 0), black)
		attach(ctx, "TricornTrim", Vector3.new(1.32, 0.06, 0.06), around * CFrame.new(0, 0.12, 1.08) * CFrame.Angles(-0.35, 0, 0), GOLD, Enum.Material.Metal)
	end
	attach(ctx, "Skull", Vector3.new(0.26, 0.26, 0.26), CFrame.new(0, y + 0.4, 0.68), WHITE, nil, BALL)
end
FEATURES.eyepatch = function(ctx)
	local ey = eyeLevel(ctx)
	local side = if ctx.dir ~= 0 then ctx.dir else 1
	attach(ctx, "EyePatch", Vector3.new(0.1, 0.6, 0.6), CFrame.new(-0.42 * side, ey, 1.02) * FACING, BLACK, nil, CYLINDER)
	attach(ctx, "PatchStrap", Vector3.new(1.84, 0.08, 1.84), CFrame.new(0, ey + 0.2, 0) * CFrame.Angles(0, 0, 0.3 * side), BLACK)
	-- and a gold hoop earring on the toe side
	attach(ctx, "Earring", Vector3.new(0.06, 0.36, 0.36), CFrame.new(side * 0.86, ey - 0.35, 0.2), GOLD, Enum.Material.Metal, CYLINDER)
end
FEATURES.toque = function(ctx)
	local y = topOf(ctx)
	attach(ctx, "ToqueBand", Vector3.new(0.6, 1.6, 1.6), CFrame.new(0, y + 0.3, 0) * UPRIGHT, WHITE, Enum.Material.Fabric, CYLINDER)
	attach(ctx, "ToquePuff", Vector3.new(1.9, 1.9, 1.9), CFrame.new(0, y + 1.1, 0), WHITE, Enum.Material.Fabric, BALL)
end
FEATURES.mustachio = function(ctx)
	local y = eyeLevel(ctx) - 0.42
	for _, s in ipairs({ -1, 1 }) do
		attach(ctx, "Mustachio", Vector3.new(0.34, 0.34, 0.34), CFrame.new(s * 0.18, y, 0.9), BLACK, Enum.Material.Fabric, BALL)
		attach(ctx, "Mustachio", Vector3.new(0.28, 0.28, 0.28), CFrame.new(s * 0.45, y + 0.06, 0.84), BLACK, Enum.Material.Fabric, BALL)
		attach(ctx, "Mustachio", Vector3.new(0.2, 0.2, 0.2), CFrame.new(s * 0.65, y + 0.16, 0.74), BLACK, Enum.Material.Fabric, BALL)
	end
end
FEATURES.tricolor = function(ctx)
	local y = ctx.leg.Size.Y / 2 - 0.2
	for i, c in ipairs({ Color3.fromRGB(46, 160, 80), WHITE, Color3.fromRGB(217, 68, 63) }) do
		attach(ctx, "Tricolor", Vector3.new(1.8, 0.16, 1.8), CFrame.new(0, y + 0.32 - i * 0.16, 0), c, Enum.Material.Fabric)
	end
	-- a fork stuck in the cuff, spaghetti twirled on it, one strand dangling
	local pasta = Color3.fromRGB(240, 200, 110)
	local x = ctx.dir * 0.95
	attach(ctx, "Fork", Vector3.new(0.1, 1.0, 0.1), CFrame.new(x, y + 0.3, 0.3) * CFrame.Angles(0, 0, -ctx.dir * 0.3), Color3.fromRGB(200, 204, 212), Enum.Material.Metal)
	attach(ctx, "Spaghetti", Vector3.new(0.4, 0.4, 0.4), CFrame.new(x + ctx.dir * 0.12, y + 0.75, 0.3), pasta, Enum.Material.Fabric, BALL)
	attach(ctx, "Noodle", Vector3.new(0.06, 0.7, 0.06), CFrame.new(x + ctx.dir * 0.3, y + 0.35, 0.35), pasta, Enum.Material.Fabric)
end
FEATURES.vampcape = function(ctx)
	local h = ctx.leg.Size.Y / 2
	local ey = eyeLevel(ctx)
	local black = Color3.fromRGB(24, 20, 30)
	attach(ctx, "Cape", Vector3.new(2.0, h * 2 - 0.2, 0.12), CFrame.new(0, -0.15, -0.92) * CFrame.Angles(-0.08, 0, 0), black, Enum.Material.Fabric)
	attach(ctx, "CapeLining", Vector3.new(1.85, h * 2 - 0.4, 0.06), CFrame.new(0, -0.15, -0.84) * CFrame.Angles(-0.08, 0, 0), ctx.accent, Enum.Material.Fabric)
	for _, s in ipairs({ -1, 1 }) do
		attach(ctx, "Collar", Vector3.new(0.9, 1.1, 0.1), CFrame.new(s * 0.5, h + 0.25, -0.75) * CFrame.Angles(0, s * 0.5, -s * 0.25), black, Enum.Material.Fabric)
		attach(ctx, "CapeSide", Vector3.new(0.1, h * 2 - 0.6, 0.9), CFrame.new(s * 0.98, -0.3, -0.35), black, Enum.Material.Fabric)
	end
	attach(ctx, "Clasp", Vector3.new(0.26, 0.26, 0.26), CFrame.new(0, ey - 0.75, 0.85), GOLD, Enum.Material.Metal, BALL)
	-- slicked-back hair with a widow's peak
	attach(ctx, "Hair", Vector3.new(1.8, 0.25, 1.8), CFrame.new(0, h + 0.15, 0), black)
	attach(ctx, "WidowsPeak", Vector3.new(0.4, 0.4, 0.12), CFrame.new(0, h - 0.05, 0.86) * CFrame.Angles(0, 0, math.pi / 4), black)
end
FEATURES.wizardhat = function(ctx)
	local y = topOf(ctx)
	attach(ctx, "WizardBrim", Vector3.new(0.12, 2.4, 2.4), CFrame.new(0, y + 0.06, 0) * UPRIGHT, ctx.color, Enum.Material.Fabric, CYLINDER)
	attach(ctx, "WizardBand", Vector3.new(0.22, 1.5, 1.5), CFrame.new(0, y + 0.2, 0) * UPRIGHT, ctx.accent, Enum.Material.Metal, CYLINDER)
	-- a tall cone whose tip flops forward
	local yy = y + 0.3
	for _, c in ipairs({ { 1.4, 0.5, 0 }, { 1.05, 0.5, 0.05 }, { 0.75, 0.45, 0.2 }, { 0.5, 0.4, 0.45 } }) do
		attach(ctx, "WizardHat", Vector3.new(c[1], c[2], c[1]), CFrame.new(0, yy + c[2] / 2, c[3]) * CFrame.Angles(c[3] * 0.8, 0, 0), ctx.color, Enum.Material.Fabric)
		yy += c[2] * 0.9
	end
	attach(ctx, "HatStar", Vector3.new(0.35, 0.35, 0.1), CFrame.new(0, yy + 0.05, 0.75) * CFrame.Angles(0, 0, math.pi / 4), ctx.accent, Enum.Material.Neon)
end
FEATURES.stars = function(ctx)
	local k = ctx.leg.Size.Y / 3.2
	for _, p in ipairs({ { -0.81, -0.8, 0.1 }, { 0.81, -0.1, -0.3 }, { 0.3, -1.1, 0.81 }, { -0.4, 0.2, -0.81 }, { 0.6, 0.9, -0.55 } }) do
		attach(ctx, "Star", Vector3.new(0.22, 0.22, 0.22), CFrame.new(p[1], p[2] * k, p[3]) * CFrame.Angles(math.pi / 4, math.pi / 4, 0), ctx.accent, Enum.Material.Neon)
	end
	for _, p in ipairs({ { 0.81, -1.0, 0.3 }, { -0.7, -0.2, 0.45 } }) do
		attach(ctx, "Moon", Vector3.new(0.24, 0.24, 0.24), CFrame.new(p[1], p[2] * k, p[3]), ctx.accent, Enum.Material.Neon, BALL)
	end
end
FEATURES.spacehelmet = function(ctx)
	local h = ctx.leg.Size.Y / 2
	local silver = Color3.fromRGB(200, 205, 215)
	attach(ctx, "HelmetRing", Vector3.new(0.5, 2.1, 2.1), CFrame.new(0, h - 0.1, 0) * UPRIGHT, silver, Enum.Material.Metal, CYLINDER)
	attach(ctx, "Antenna", Vector3.new(0.07, 0.8, 0.07), CFrame.new(0.45, h + 0.5, -0.3), silver, Enum.Material.Metal)
	attach(ctx, "AntennaBall", Vector3.new(0.22, 0.22, 0.22), CFrame.new(0.45, h + 0.95, -0.3), Color3.fromRGB(230, 50, 50), Enum.Material.Neon, BALL)
	-- the blue mission patch on the side, an orange suit stripe
	attach(ctx, "MissionPatch", Vector3.new(0.06, 0.55, 0.55), CFrame.new(ctx.dir * 0.82, -0.3, 0.1), Color3.fromRGB(60, 110, 220), nil, CYLINDER)
	attach(ctx, "SuitStripe", Vector3.new(1.66, 0.18, 1.66), CFrame.new(0, -0.9, 0), ctx.accent)
end
FEATURES.jetpack = function(ctx)
	for _, s in ipairs({ -1, 1 }) do
		local x = s * 0.38
		attach(ctx, "JetTank", Vector3.new(1.4, 0.62, 0.62), CFrame.new(x, -0.1, -1.08) * UPRIGHT, Color3.fromRGB(240, 242, 246), Enum.Material.SmoothPlastic, CYLINDER)
		attach(ctx, "JetBand", Vector3.new(0.14, 0.66, 0.66), CFrame.new(x, 0.25, -1.08) * UPRIGHT, ctx.accent, nil, CYLINDER)
		attach(ctx, "JetNozzle", Vector3.new(0.3, 0.4, 0.4), CFrame.new(x, -0.95, -1.08) * UPRIGHT, Color3.fromRGB(70, 72, 80), Enum.Material.Metal, CYLINDER)
	end
end
FEATURES.dragonwings = function(ctx)
	local red = Color3.fromRGB(200, 40, 40)
	local rib = Color3.fromRGB(130, 20, 25)
	for _, s in ipairs({ -1, 1 }) do
		local hinge = CFrame.new(s * 0.7, 0.6, -0.9) * CFrame.Angles(0, s * 0.6, s * 0.35)
		attach(ctx, "Wing", Vector3.new(1.4, 1.0, 0.08), hinge * CFrame.new(s * 0.7, 0, 0), red)
		for k = 0, 1 do
			attach(ctx, "WingRib", Vector3.new(1.2, 0.08, 0.1), hinge * CFrame.new(s * 0.65, 0.3 - k * 0.45, 0) * CFrame.Angles(0, 0, s * (0.3 - k * 0.5)), rib)
		end
	end
	-- the yellow scaly belly below the face
	for i = 0, 2 do
		attach(ctx, "Belly", Vector3.new(0.9, 0.22, 0.1), CFrame.new(0, eyeLevel(ctx) - 0.8 - i * 0.32, 0.82), ctx.accent)
	end
end
FEATURES.horns = function(ctx)
	local y = topOf(ctx)
	local cream = Color3.fromRGB(245, 232, 200)
	for _, s in ipairs({ -1, 1 }) do
		attach(ctx, "Horn", Vector3.new(0.26, 0.55, 0.26), CFrame.new(s * 0.45, y + 0.22, 0.15) * CFrame.Angles(0, 0, -s * 0.35), cream)
		attach(ctx, "HornTip", Vector3.new(0.16, 0.3, 0.16), CFrame.new(s * 0.6, y + 0.55, 0.15) * CFrame.Angles(0, 0, -s * 0.7), cream)
	end
	-- a row of back spikes from the cuff down to the heel
	for i = 0, 3 do
		attach(ctx, "Spike", Vector3.new(0.12, 0.3, 0.3), CFrame.new(0, y - 0.4 - i * 0.7, -0.85) * CFrame.Angles(math.pi / 4, 0, 0), ctx.accent)
	end
end
FEATURES.dragontail = function(ctx)
	local back = -ctx.dir -- it curls out from the heel along the floor
	local y = -ctx.leg.Size.Y / 2 - 0.4
	attach(ctx, "Tail", Vector3.new(0.5, 0.45, 0.9), CFrame.new(back * 0.75, y, -0.6) * CFrame.Angles(0, back * 0.4, 0), ctx.color, ctx.material)
	attach(ctx, "Tail", Vector3.new(0.4, 0.36, 0.8), CFrame.new(back * 0.95, y - 0.05, -1.35) * CFrame.Angles(0, -back * 0.1, 0), ctx.color, ctx.material)
	attach(ctx, "Tail", Vector3.new(0.3, 0.28, 0.7), CFrame.new(back * 0.75, y - 0.1, -1.95) * CFrame.Angles(0, -back * 0.6, 0), ctx.color, ctx.material)
	attach(ctx, "TailSpade", Vector3.new(0.45, 0.12, 0.45), CFrame.new(back * 0.45, y - 0.1, -2.3) * CFrame.Angles(0, math.pi / 4, 0), ctx.accent)
end
FEATURES.nemes = function(ctx)
	local h = ctx.leg.Size.Y / 2
	local ey = eyeLevel(ctx)
	local lapis = Color3.fromRGB(38, 70, 160)
	attach(ctx, "Nemes", Vector3.new(1.95, 0.55, 1.95), CFrame.new(0, h + 0.05, 0), ctx.accent, Enum.Material.Fabric)
	for i = 0, 1 do
		attach(ctx, "NemesStripe", Vector3.new(1.97, 0.1, 1.97), CFrame.new(0, h - 0.1 + i * 0.25, 0), lapis, Enum.Material.Fabric)
	end
	for _, s in ipairs({ -1, 1 }) do
		attach(ctx, "Lappet", Vector3.new(0.3, 1.4, 0.6), CFrame.new(s * 0.95, ey - 0.15, 0.35), ctx.accent, Enum.Material.Fabric)
		for _, dy in ipairs({ -0.25, -0.55 }) do
			attach(ctx, "LappetStripe", Vector3.new(0.32, 0.1, 0.62), CFrame.new(s * 0.95, ey + dy, 0.35), lapis, Enum.Material.Fabric)
		end
		attach(ctx, "Eyeliner", Vector3.new(0.3, 0.07, 0.07), CFrame.new(s * 0.72, ey + 0.05, 0.8) * CFrame.Angles(0, 0, s * 0.35), BLACK)
	end
	attach(ctx, "Cobra", Vector3.new(0.16, 0.38, 0.12), CFrame.new(0, h + 0.15, 1.0), ctx.accent, Enum.Material.Metal)
	-- the broad collar of turquoise and lapis beads under the face
	attach(ctx, "BeadCollar", Vector3.new(0.2, 2.0, 2.0), CFrame.new(0, ey - 0.8, 0) * UPRIGHT, Color3.fromRGB(64, 200, 190), nil, CYLINDER)
	attach(ctx, "BeadCollar", Vector3.new(0.12, 2.06, 2.06), CFrame.new(0, ey - 0.95, 0) * UPRIGHT, lapis, nil, CYLINDER)
end
FEATURES.bandages = function(ctx)
	local h = ctx.leg.Size.Y / 2
	local wrap = ctx.color:Lerp(Color3.fromRGB(120, 100, 70), 0.12)
	for i = 0, 4 do
		attach(ctx, "Wrap", Vector3.new(1.64, 0.18, 1.64), CFrame.new(0, -h + 0.45 + i * 0.42, 0) * CFrame.Angles(0, 0, if i % 2 == 0 then 0.12 else -0.12), wrap, Enum.Material.Fabric)
	end
	attach(ctx, "LooseEnd", Vector3.new(0.25, 0.8, 0.05), CFrame.new(ctx.dir * 0.85, -h + 0.6, 0.3) * CFrame.Angles(0, 0, ctx.dir * 0.3), wrap, Enum.Material.Fabric)
end
FEATURES.pharaohbeard = function(ctx)
	local ey = eyeLevel(ctx)
	attach(ctx, "PharaohBeard", Vector3.new(0.28, 0.9, 0.28), CFrame.new(0, ey - 0.85, 0.92), ctx.accent, Enum.Material.Metal)
	for i = 0, 2 do
		attach(ctx, "Braid", Vector3.new(0.3, 0.06, 0.3), CFrame.new(0, ey - 0.6 - i * 0.25, 0.92), Color3.fromRGB(150, 110, 40), Enum.Material.Metal)
	end
end
FEATURES.pinstripes = function(ctx)
	verticalStripes(ctx, Color3.fromRGB(150, 150, 165))
	-- the tuxedo front: a white shirt V between black lapels, a bow tie, a thin moustache
	local ey = eyeLevel(ctx)
	attach(ctx, "Shirt", Vector3.new(0.6, 1.0, 0.06), CFrame.new(0, ey - 1.1, 0.82), WHITE)
	for _, s in ipairs({ -1, 1 }) do
		attach(ctx, "Lapel", Vector3.new(0.35, 1.05, 0.07), CFrame.new(s * 0.38, ey - 1.1, 0.83) * CFrame.Angles(0, 0, s * 0.25), Color3.fromRGB(20, 20, 26))
		attach(ctx, "BowTie", Vector3.new(0.26, 0.2, 0.1), CFrame.new(s * 0.15, ey - 0.62, 0.88) * CFrame.Angles(0, 0, s * 0.3), BLACK)
	end
	attach(ctx, "Moustache", Vector3.new(0.5, 0.06, 0.06), CFrame.new(0, ey - 0.38, 0.88), BLACK)
	attach(ctx, "WatchChain", Vector3.new(0.05, 0.05, 0.7), CFrame.new(ctx.dir * 0.84, ey - 1.3, 0.25) * CFrame.Angles(0.3, 0, 0), GOLD, Enum.Material.Metal)
	eyelids(ctx) -- heavy, half-lidded
end
FEATURES.fedora = function(ctx)
	local y = topOf(ctx)
	local grey = Color3.fromRGB(120, 120, 130)
	attach(ctx, "FedoraBrim", Vector3.new(0.12, 2.5, 2.5), CFrame.new(0, y + 0.06, 0) * UPRIGHT, grey, Enum.Material.Fabric, CYLINDER)
	attach(ctx, "FedoraCrown", Vector3.new(0.8, 1.5, 1.5), CFrame.new(0, y + 0.5, 0) * UPRIGHT, grey, Enum.Material.Fabric, CYLINDER)
	attach(ctx, "FedoraBand", Vector3.new(0.22, 1.54, 1.54), CFrame.new(0, y + 0.22, 0) * UPRIGHT, Color3.fromRGB(20, 20, 24), Enum.Material.Fabric, CYLINDER)
	attach(ctx, "FedoraDent", Vector3.new(0.9, 0.12, 0.25), CFrame.new(0, y + 0.92, 0), grey:Lerp(BLACK, 0.25), Enum.Material.Fabric)
end
FEATURES.rose = function(ctx)
	local ey = eyeLevel(ctx)
	local x = 0.5 * (if ctx.dir ~= 0 then ctx.dir else 1)
	attach(ctx, "Rose", Vector3.new(0.3, 0.3, 0.3), CFrame.new(x, ey - 0.85, 0.9), Color3.fromRGB(211, 32, 63), Enum.Material.Fabric, BALL)
	attach(ctx, "RoseLeaf", Vector3.new(0.25, 0.08, 0.12), CFrame.new(x + 0.18, ey - 1.0, 0.88) * CFrame.Angles(0, 0, -0.5), Color3.fromRGB(40, 140, 60))
end

-- ---------- rarity + mutation looks ----------

local function applyRarity(ctx: Ctx)
	local tier = S.Registry.Tier(ctx.sock)
	if tier.rank >= 4 then
		light(ctx.leg, tier.color, 9 + tier.rank, 0.5 + tier.rank * 0.12)
	end
	if tier.rank >= 5 then
		local sparkle = emitter(ctx.leg, "Sparkle", tier.color, 4 + tier.rank, 0.22, 1.5, 1.4, 180, 1)
		sparkle.LightInfluence = 0
	end
	if tier.rank == 6 then
		local halo = attach(ctx, "Halo", Vector3.new(0.12, 2.4, 2.4), CFrame.new(0, 2.9, 0) * CFrame.Angles(0, 0, math.pi / 2), Color3.fromRGB(255, 230, 120), Enum.Material.Neon, Enum.PartType.Cylinder)
		halo.Transparency = 0.25
	end
	if tier.rank == 7 then
		local smoke = emitter(ctx.leg, "Aura", Color3.fromRGB(60, 30, 100), 8, 0.9, 1, 1.8, 180, 0.4)
		smoke.Acceleration = Vector3.new(0, 1.2, 0)
	end
end

local function applyMutation(ctx: Ctx)
	local m = ctx.sock.mutation
	if m == "None" then
		return
	end
	if m == "Fuzzy" then
		for i = 1, 5 do
			local a = i * 1.25
			attach(ctx, "Fuzz", Vector3.new(0.5, 0.5, 0.5), CFrame.new(math.cos(a) * 0.9, -0.8 + i * 0.4, math.sin(a) * 0.9), ctx.color, Enum.Material.Fabric, Enum.PartType.Ball)
		end
	elseif m == "Static" then
		local sparks = emitter(ctx.leg, "Static", Color3.fromRGB(160, 230, 255), 10, 0.1, 7, 0.4, 180, 1)
		sparks.LightInfluence = 0
		light(ctx.leg, Color3.fromRGB(140, 220, 255), 8, 0.8)
	elseif m == "Glow" then
		ctx.leg.Material = Enum.Material.Neon
		ctx.foot.Material = Enum.Material.Neon
		light(ctx.leg, ctx.color, 12, 1.4)
	elseif m == "Holey" then
		attach(ctx, "Hole", Vector3.new(1.8, 0.7, 0.7), CFrame.new(0, -0.3, 0) * CFrame.Angles(0, math.pi / 2, 0), BLACK, Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
		local halo = attach(ctx, "HoleyHalo", Vector3.new(0.1, 1.8, 1.8), CFrame.new(0, 2.6, 0) * CFrame.Angles(0, 0, math.pi / 2), Color3.fromRGB(255, 250, 180), Enum.Material.Neon, Enum.PartType.Cylinder)
		halo.Transparency = 0.2
		light(ctx.leg, Color3.fromRGB(255, 250, 200), 10, 0.8)
	elseif m == "GoldenThread" then
		ctx.leg.Material = Enum.Material.Metal
		ctx.foot.Material = Enum.Material.Metal
		emitter(ctx.leg, "GoldSparkle", Color3.fromRGB(255, 225, 120), 6, 0.2, 1.2, 1.2, 180, 1).LightInfluence = 0
		light(ctx.leg, Color3.fromRGB(255, 215, 0), 10, 1)
	elseif m == "Rainbow" then
		emitter(ctx.leg, "RainbowSparkle", Color3.fromRGB(255, 255, 255), 8, 0.2, 1.5, 1.2, 180, 1).LightInfluence = 0
		light(ctx.leg, Color3.fromRGB(255, 180, 255), 12, 1.2)
		ctx.model:SetAttribute("Rainbow", true) -- the client cycles the hue
	elseif m == "LintGalaxy" then
		ctx.leg.Material = Enum.Material.Neon
		ctx.foot.Material = Enum.Material.Neon
		local stars = emitter(ctx.leg, "Stars", Color3.fromRGB(255, 255, 255), 12, 0.12, 0.6, 2.5, 180, 1)
		stars.LightInfluence = 0
		local nebula = emitter(ctx.leg, "Nebula", Color3.fromRGB(150, 60, 220), 6, 1.2, 0.6, 2, 180, 0.6)
		nebula.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 1) })
		light(ctx.leg, Color3.fromRGB(150, 80, 255), 16, 1.6)
	end
end

-- ---------- label ----------

local function buildLabel(sock, leg: BasePart)
	local t = S.Registry.Type(sock)
	local tier = S.Config.Rarity.Tiers[t.rarity]
	local m = S.Config.Mutation.Table[sock.mutation]
	local gui = Instance.new("BillboardGui")
	gui.Name = "NameLabel"
	gui.Adornee = leg
	gui.Size = UDim2.fromOffset(170, 44)
	gui.StudsOffset = Vector3.new(0, leg.Size.Y / 2 + 2.2, 0)
	gui.MaxDistance = 40 -- line socks: the buy prompt already names them; Base widens this in a drawer
	gui.LightInfluence = 0
	local name = Instance.new("TextLabel")
	name.Name = "Name"
	name.Size = UDim2.new(1, 0, 0.55, 0)
	name.BackgroundTransparency = 1
	name.Font = Enum.Font.FredokaOne
	name.TextScaled = true
	name.TextColor3 = tier.color
	name.TextStrokeTransparency = 0.15
	name.Text = S.Registry.DisplayName(sock)
	name.Parent = gui
	if tier.rank >= 3 then
		local stroke = Instance.new("UIStroke")
		stroke.Color = tier.color
		stroke.Thickness = 1.5
		stroke.Transparency = 0.4
		stroke.Parent = name
	end
	local sub = Instance.new("TextLabel")
	sub.Name = "Sub"
	sub.Size = UDim2.new(1, 0, 0.45, 0)
	sub.Position = UDim2.fromScale(0, 0.55)
	sub.BackgroundTransparency = 1
	sub.Font = Enum.Font.GothamBold
	sub.TextScaled = true
	sub.TextColor3 = Color3.new(1, 1, 1)
	sub.TextStrokeTransparency = 0.3
	sub.Text = tier.display .. (if m and m.display ~= "" then " • " .. m.display else "")
	sub.Parent = gui
	gui.Parent = leg
end

-- ---------- real meshes (optional) ----------
-- Put a Model or MeshPart named after the type id (e.g. "Argylo", or "Argylo_L" / "Argylo_R" for
-- different halves) into ReplicatedStorage.SockMeshes and the Factory uses it as the body instead
-- of the Part build. Features are skipped (the mesh already has them); rarity glow, mutation
-- looks, the label and every game hook still apply. See docs/ART_PIPELINE.md.
local meshFolder: Folder? = nil

local function findMeshTemplate(sock): Instance?
	if not meshFolder then
		return nil
	end
	local sided = meshFolder:FindFirstChild(sock.typeId .. "_" .. sock.side)
	return sided or meshFolder:FindFirstChild(sock.typeId)
end

-- Builds the sock body from a mesh template. Returns the invisible root ("Leg") part, or nil.
--  * Blender templates (with _Base/_Unit/_Pin markers): 1 unit = 1 stud, the root is sized and
--    placed exactly like a Part-built sock's Leg (pin above, foot below), so hanging height,
--    slot placement, labels and sway all line up with every other sock.
--  * Other templates (Creator Store / Mesh Generator): normalised to the Part body's height and
--    rooted at their bounding box, with a small L/R tag when one mesh serves both halves.
local function buildFromMesh(template: Instance, model: Model, sock): (BasePart?, BasePart?)
	local holder, info = MeshTemplate.Prepare(template, true)
	if not holder then
		return nil, nil
	end
	-- Rigged meshes keep their Bones (each client's SockAnim bends them through Bone.Transform);
	-- an Animator from the import would overwrite those every frame, so it goes.
	for _, d in ipairs(holder:GetDescendants()) do
		if d:IsA("Animator") or d:IsA("AnimationController") then
			d:Destroy()
		end
	end
	local leg
	if info.hasMarkers and info.base then
		local base = info.base :: Vector3
		local pin = info.pin or (base + Vector3.new(0, 4.3, 0))
		-- Part sock: Leg centre -> pin = Y/2 + 0.55 and Leg centre -> foot bottom = Y/2 + 0.65
		local legY = math.max(pin.Y - base.Y - 1.2, 1)
		leg = newPart("Leg", Vector3.new(1.6, legY, 1.6), Color3.new(1, 1, 1), Enum.Material.SmoothPlastic, model)
		leg.CFrame = CFrame.new(base.X, base.Y + legY / 2 + 0.65, base.Z)
	else
		local _, size = holder:GetBoundingBox()
		if size.Y <= 0 then
			holder:Destroy()
			return nil, nil
		end
		holder:ScaleTo(holder:GetScale() * (4.5 / size.Y)) -- leg + foot of the Part body
		local cf
		cf, size = holder:GetBoundingBox()
		leg = newPart("Leg", Vector3.new(math.max(size.X, 1), size.Y, math.max(size.Z, 1)), Color3.new(1, 1, 1), Enum.Material.SmoothPlastic, model)
		leg.CFrame = cf
		local sided = string.sub(template.Name, -2) == "_L" or string.sub(template.Name, -2) == "_R"
		if sock.side ~= "S" and not sided then
			local tag = newPart("SideTag", Vector3.new(0.9, 0.9, 0.1), Color3.new(1, 1, 1), Enum.Material.Neon, model)
			tag.CFrame = cf * CFrame.new(if sock.side == "L" then -size.X / 2 - 0.3 else size.X / 2 + 0.3, -size.Y / 2 + 0.6, 0)
			weld(leg, tag)
			local gui = Instance.new("SurfaceGui")
			gui.Face = Enum.NormalId.Front
			gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
			gui.PixelsPerStud = 60
			gui.LightInfluence = 0
			local t = Instance.new("TextLabel")
			t.Size = UDim2.fromScale(1, 1)
			t.BackgroundTransparency = 1
			t.Font = Enum.Font.FredokaOne
			t.TextScaled = true
			t.TextColor3 = Color3.fromRGB(40, 30, 60)
			t.Text = sock.side
			t.Parent = gui
			gui.Parent = tag
		end
	end
	leg.Transparency = 1
	leg.Anchored = true
	leg.CanQuery = true
	model.PrimaryPart = leg
	for _, d in ipairs(holder:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
			weld(leg, d)
		end
	end
	holder.Name = "Mesh"
	holder.Parent = model
	return leg, leg
end

local function isMarker(name: string): boolean
	local tail = string.match(name, "_%a+$")
	return tail == "_Base" or tail == "_Unit" or tail == "_Pin"
end

-- Clothespin (only shown while hanging on the line). `cuffY` = the top of the sock in the Leg's local
-- space. Uses ReplicatedStorage.SockMeshes.Clothespin (tools/blender/props/clothespin.py: 1 unit =
-- 1 stud, origin at the jaw tips) when it is there, else a wooden block. Always named "Clothespin".
local function addClothespin(ctx: Ctx, cuffY: number)
	local template = meshFolder and meshFolder:FindFirstChild("Clothespin")
	if template then
		local holder, info = MeshTemplate.Prepare(template, true)
		if holder and info.hasMarkers and info.base then
			-- jaw tips overlap the cuff a little; the front of the pin faces the sock's front (+Z)
			local rel = CFrame.new(info.base :: Vector3):ToObjectSpace(holder:GetPivot())
			holder:PivotTo(ctx.leg.CFrame * CFrame.new(0, cuffY - 0.3, 0) * rel)
			for _, d in ipairs(holder:GetDescendants()) do
				if d:IsA("BasePart") then
					d.Anchored = false
					d.CanCollide = false
					d.CanQuery = false
					d.CanTouch = false
					d.Massless = true
					d.CastShadow = false
					weld(ctx.leg, d)
				end
			end
			holder.Name = "Clothespin"
			holder.Parent = ctx.model
			return
		elseif holder then
			holder:Destroy()
		end
	end
	local pin = attach(ctx, "Clothespin", Vector3.new(0.6, 1.5, 0.45), CFrame.new(0, cuffY + 0.5, 0), Color3.fromRGB(196, 146, 92), Enum.Material.Wood)
	pin.Name = "Clothespin"
end

-- ---------- build ----------

function Factory.Init(s)
	S = s
	local rs = game:GetService("ReplicatedStorage")
	local folder = rs:FindFirstChild("SockMeshes")
	if not (folder and folder:IsA("Folder")) then
		folder = Instance.new("Folder")
		folder.Name = "SockMeshes"
		folder.Parent = rs
	end
	meshFolder = folder :: Folder
	local count = #folder:GetChildren()
	if count > 0 then
		print("[Factory] " .. count .. " sock mesh template(s) found in ReplicatedStorage.SockMeshes")
	end
end

local function has(list: { string }?, name: string): boolean
	if not list then
		return false
	end
	return table.find(list, name) ~= nil
end

function Factory.Build(sock): Model
	local t = S.Registry.Type(sock)
	local m = S.Config.Mutation.Table[sock.mutation] or S.Config.Mutation.Table.None
	local color = m.color or t.color
	local material = m.material or Enum.Material.Fabric
	local dir = if sock.side == "L" then -1 elseif sock.side == "R" then 1 else 0
	local look = t.look or {}

	local model = Instance.new("Model")
	model.Name = "Sock_" .. sock.uid

	-- Real mesh available? Use it and skip the Part body + features.
	local template = findMeshTemplate(sock)
	if template then
		local meshLeg, meshFoot = buildFromMesh(template, model, sock)
		if meshLeg and meshFoot then
			local ctx: Ctx = { model = model, leg = meshLeg, foot = meshFoot, color = color, accent = t.accent, material = material, dir = dir, scale = 1, sock = sock }
			-- the mesh's leg root stops 0.45 under the sock's top (see buildFromMesh)
			addClothespin(ctx, meshLeg.Size.Y / 2 + 0.45)
			applyRarity(ctx)
			applyMutation(ctx)
			model:ScaleTo(S.Config.Economy.SockScale)
			model:SetAttribute("Uid", sock.uid)
			model:SetAttribute("TypeId", sock.typeId)
			model:SetAttribute("SockName", t.name)
			model:SetAttribute("Side", sock.side)
			model:SetAttribute("Rarity", t.rarity)
			model:SetAttribute("RarityRank", S.Config.Rarity.Tiers[t.rarity].rank)
			model:SetAttribute("Mutation", sock.mutation)
			model:SetAttribute("Stink", sock.stink)
			model:SetAttribute("OwnerId", 0)
			model:SetAttribute("Motion", t.motion or "bob")
			model:SetAttribute("State", "gone")
			model:SetAttribute("FromMesh", true)
			CollectionService:AddTag(model, "Sock")
			buildLabel(sock, meshLeg)
			sock.model = model
			return model
		end
	end

	-- Leg: root, anchored, the part prompts attach to
	local legH = if has(look, "tall") then 5.2 else (if has(look, "small") then 2.4 else 3.2)
	local leg = newPart("Leg", Vector3.new(1.6, legH, 1.6), color, material, model)
	leg.Anchored = true
	leg.CanQuery = true
	model.PrimaryPart = leg

	local ctx: Ctx = { model = model, leg = leg, foot = nil :: any, color = color, accent = t.accent, material = material, dir = dir, scale = 1, sock = sock }

	-- Cuff (ribbed top), heel bump and foot
	attach(ctx, "Cuff", Vector3.new(1.75, 0.5, 1.75), CFrame.new(0, legH / 2 - 0.2, 0), color, material)
	local footY = -legH / 2
	local foot
	if sock.side == "S" then
		foot = newPart("Foot", Vector3.new(4.2, 1.3, 1.6), color, material, model)
		foot.CFrame = leg.CFrame * CFrame.new(0, footY, 0)
	else
		foot = newPart("Foot", Vector3.new(2.9, 1.3, 1.6), color, material, model)
		foot.CFrame = leg.CFrame * CFrame.new(dir * 1.2, footY, 0)
		attach(ctx, "Heel", Vector3.new(0.9, 0.9, 1.6), CFrame.new(-dir * 0.5, footY + 0.3, 0), t.accent, material)
		attach(ctx, "ToeCap", Vector3.new(0.7, 1.32, 1.62), CFrame.new(dir * 2.35, footY, 0), t.accent, material)
	end
	weld(leg, foot)
	ctx.foot = foot

	-- Default stripe unless the type has its own stripe feature
	if not has(look, "sadstripe") and not has(look, "sweatband") and not has(look, "lintcrown") then
		attach(ctx, "Stripe", Vector3.new(1.7, 0.4, 1.7), CFrame.new(0, legH / 2 - 0.8, 0), t.accent)
	end

	-- Googly eyes on the front (+Z)
	local eyeY = legH / 2 - 1.05
	for i, ex in ipairs({ -0.42, 0.42 }) do
		local white = attach(ctx, "Eye" .. i, Vector3.new(0.66, 0.66, 0.66), CFrame.new(ex, eyeY, 0.72), WHITE, nil, Enum.PartType.Ball)
		white.Name = "Eye"
		attach(ctx, "Pupil", Vector3.new(0.3, 0.3, 0.3), CFrame.new(ex + 0.08, eyeY - 0.02, 0.98), BLACK, nil, Enum.PartType.Ball)
	end

	addClothespin(ctx, legH / 2 + 0.05) -- top of the Cuff

	for _, feature in ipairs(look) do
		local builder = FEATURES[feature]
		if builder then
			builder(ctx)
		else
			warn("[Factory] unknown look feature '" .. feature .. "' on " .. t.id)
		end
	end
	applyRarity(ctx)
	applyMutation(ctx)
	model:ScaleTo(S.Config.Economy.SockScale)

	model:SetAttribute("Uid", sock.uid)
	model:SetAttribute("TypeId", sock.typeId)
	model:SetAttribute("SockName", t.name)
	model:SetAttribute("Side", sock.side)
	model:SetAttribute("Rarity", t.rarity)
	model:SetAttribute("RarityRank", S.Config.Rarity.Tiers[t.rarity].rank)
	model:SetAttribute("Mutation", sock.mutation)
	model:SetAttribute("Stink", sock.stink)
	model:SetAttribute("OwnerId", 0)
	model:SetAttribute("Motion", t.motion or "bob")
	model:SetAttribute("State", "gone")
	CollectionService:AddTag(model, "Sock")

	buildLabel(sock, leg)
	sock.model = model
	return model
end

-- How far away the floating name can be read (line socks stay short so the line isn't a wall of text).
function Factory.SetLabelDistance(model: Model, distance: number)
	local leg = model.PrimaryPart
	local gui = leg and leg:FindFirstChild("NameLabel")
	if gui and gui:IsA("BillboardGui") then
		gui.MaxDistance = distance
	end
end

function Factory.SetClothespin(model: Model, visible: boolean)
	local pin = model:FindFirstChild("Clothespin")
	if pin and pin:IsA("BasePart") then
		pin.Transparency = if visible then 0 else 1
	elseif pin then
		-- mesh pin: show every part but the hidden markers
		for _, d in ipairs(pin:GetDescendants()) do
			if d:IsA("BasePart") and not isMarker(d.Name) then
				d.Transparency = if visible then 0 else 1
			end
		end
	end
end

-- Re-anchors the Leg and removes any carry weld (used when a sock goes back into a drawer).
function Factory.Ground(model: Model)
	local leg = model.PrimaryPart
	if not leg then
		return
	end
	local carryWeld = leg:FindFirstChild("CarryWeld")
	if carryWeld then
		carryWeld:Destroy()
	end
	leg.Anchored = true
end

return Factory
