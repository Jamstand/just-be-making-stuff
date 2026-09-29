-- Factory: builds a placeholder sock model from Parts (L-shaped body, googly eyes, stripe,
-- clothespin) and tags it "Sock" so meshes can replace it later. The Leg is the PrimaryPart and
-- the only anchored part; everything else is welded to it, so moving the Leg moves the sock.
local CollectionService = game:GetService("CollectionService")

local Factory = {}
local S

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

function Factory.Init(s)
	S = s
end

local function buildLabel(sock, leg: BasePart)
	local t = S.Registry.Type(sock)
	local tier = S.Config.Rarity.Tiers[t.rarity]
	local m = S.Config.Mutation.Table[sock.mutation]
	local gui = Instance.new("BillboardGui")
	gui.Name = "NameLabel"
	gui.Adornee = leg
	gui.Size = UDim2.fromOffset(180, 46)
	gui.StudsOffset = Vector3.new(0, 3.2, 0)
	gui.MaxDistance = 70
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

function Factory.Build(sock): Model
	local t = S.Registry.Type(sock)
	local m = S.Config.Mutation.Table[sock.mutation] or S.Config.Mutation.Table.None
	local color = m.color or t.color
	local material = m.material or Enum.Material.SmoothPlastic
	local dir = if sock.side == "L" then -1 else 1

	local model = Instance.new("Model")
	model.Name = "Sock_" .. sock.uid

	-- Leg: root, anchored, the part prompts attach to
	local leg = newPart("Leg", Vector3.new(1.6, 3.2, 1.6), color, material, model)
	leg.Anchored = true
	leg.CanQuery = true
	model.PrimaryPart = leg

	-- Foot: points left or right so halves are easy to tell apart; singles get a wide foot
	local foot
	if sock.side == "S" then
		foot = newPart("Foot", Vector3.new(4.2, 1.3, 1.6), color, material, model)
		foot.CFrame = CFrame.new(0, -1.6, 0)
	else
		foot = newPart("Foot", Vector3.new(2.8, 1.3, 1.6), color, material, model)
		foot.CFrame = CFrame.new(dir * 1.2, -1.6, 0)
	end
	weld(leg, foot)

	-- Stripe near the top (type accent)
	local stripe = newPart("Stripe", Vector3.new(1.7, 0.45, 1.7), t.accent, Enum.Material.SmoothPlastic, model)
	stripe.CFrame = CFrame.new(0, 1.15, 0)
	weld(leg, stripe)

	-- Googly eyes on the front (+Z)
	for i, ex in ipairs({ -0.42, 0.42 }) do
		local white = newPart("Eye" .. i, Vector3.new(0.62, 0.62, 0.62), Color3.new(1, 1, 1), Enum.Material.SmoothPlastic, model)
		white.Shape = Enum.PartType.Ball
		white.CFrame = CFrame.new(ex, 0.55, 0.75)
		weld(leg, white)
		local pupil = newPart("Pupil" .. i, Vector3.new(0.3, 0.3, 0.3), Color3.new(0, 0, 0), Enum.Material.SmoothPlastic, model)
		pupil.Shape = Enum.PartType.Ball
		pupil.CFrame = CFrame.new(ex + 0.08, 0.55, 1.0)
		weld(leg, pupil)
	end

	-- Clothespin (only shown while hanging on the line)
	local pin = newPart("Clothespin", Vector3.new(0.6, 1.5, 0.45), Color3.fromRGB(196, 146, 92), Enum.Material.Wood, model)
	pin.CFrame = CFrame.new(0, 2.25, 0)
	weld(leg, pin)

	model:SetAttribute("Uid", sock.uid)
	model:SetAttribute("TypeId", sock.typeId)
	model:SetAttribute("SockName", t.name)
	model:SetAttribute("Side", sock.side)
	model:SetAttribute("Rarity", t.rarity)
	model:SetAttribute("Mutation", sock.mutation)
	model:SetAttribute("Stink", sock.stink)
	model:SetAttribute("OwnerId", 0)
	CollectionService:AddTag(model, "Sock")

	buildLabel(sock, leg)
	sock.model = model
	return model
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
