-- Factory: builds every sock from Parts. Body = L-shaped leg + heel + foot with googly eyes; each
-- roster type adds signature FEATURES (fangs, monocle, beard, pogo stick, headphones, tentacles...);
-- rarity adds glow; mutations add their own look. Models are tagged "Sock" (CollectionService)
-- so meshes can replace them later. The Leg is the PrimaryPart and the only anchored part;
-- everything else is welded to it, so moving the Leg moves the whole sock.
local CollectionService = game:GetService("CollectionService")

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

-- ---------- build ----------

function Factory.Init(s)
	S = s
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

	-- Clothespin (only shown while hanging on the line)
	local pin = attach(ctx, "Clothespin", Vector3.new(0.6, 1.5, 0.45), CFrame.new(0, legH / 2 + 0.55, 0), Color3.fromRGB(196, 146, 92), Enum.Material.Wood)
	pin.Name = "Clothespin"

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
