-- Items.Looks: what every item looks like. Each one comes from its Blender model in
-- ReplicatedStorage.ItemMeshes (tools/blender/items, see docs/ITEMS.md) and falls back to a Part
-- build in the same colours while that model isn't imported, so every item works on day one.
--
-- Model conventions (tools/blender/items/__init__.py): 1 unit = 1 stud, the FRONT faces +Z after
-- MeshTemplate.Prepare, `<Name>_Grip` = where the right hand holds it, `<Name>_Tip` = where an effect
-- comes out, `<Name>_Glow` parts are made Neon. The towels carry a skeleton (Root, Seg1..Seg6) that
-- each client whips through Bone.Transform; the Part towel has Motor6Ds named Seg1..Seg6 instead.
--
-- A held item is a Tool whose invisible Handle sits exactly on the grip point, turned like the
-- model, so every tool uses the same Grip (the front points forward out of the fist). Re-skinning
-- (Towel Snap levels, the Royal Towel) swaps the welded "Visual" model and keeps the Handle.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MeshTemplate = require(script.Parent.Parent:WaitForChild("MeshTemplate"))

local Looks = {}
local S

local GRIP = CFrame.Angles(0, math.pi, 0) -- handle space -> the hand's grip frame (front +Z forward)
local CARRY_BASKET = 0.32 -- the Laundry Basket is scaled down this much while carried

local meshFolder: Instance? = nil

-- The towel's colours by look (the Part towel; the Blender towels are hand-painted)
local TOWELS: { [string]: { body: Color3, trim: Color3, alt: Color3?, tip: Color3, material: Enum.Material?, tassel: boolean? } } = {
	Plain    = { body = Color3.fromRGB(130, 195, 255), trim = Color3.fromRGB(255, 255, 255), tip = Color3.fromRGB(150, 210, 255) },
	Striped  = { body = Color3.fromRGB(250, 250, 255), trim = Color3.fromRGB(235, 70, 80),   alt = Color3.fromRGB(70, 130, 240), tip = Color3.fromRGB(235, 70, 80) },
	Beach    = { body = Color3.fromRGB(255, 214, 70),  trim = Color3.fromRGB(40, 190, 190),  alt = Color3.fromRGB(255, 140, 60), tip = Color3.fromRGB(40, 190, 190) },
	Spa      = { body = Color3.fromRGB(255, 252, 248), trim = Color3.fromRGB(255, 170, 200), tip = Color3.fromRGB(255, 190, 215) },
	Sports   = { body = Color3.fromRGB(60, 175, 90),   trim = Color3.fromRGB(255, 255, 255), alt = Color3.fromRGB(245, 250, 245), tip = Color3.fromRGB(255, 255, 255) },
	Champion = { body = Color3.fromRGB(190, 30, 45),   trim = Color3.fromRGB(255, 200, 60),  tip = Color3.fromRGB(255, 210, 80), material = Enum.Material.Fabric },
	Royal    = { body = Color3.fromRGB(110, 50, 170),  trim = Color3.fromRGB(255, 205, 70),  tip = Color3.fromRGB(255, 215, 90), tassel = true },
}

local function endsWith(name: string, suffix: string): boolean
	return #name >= #suffix and string.sub(name, -#suffix) == suffix
end

local function isMarker(name: string): boolean
	return endsWith(name, "_Base") or endsWith(name, "_Unit") or endsWith(name, "_Pin") or endsWith(name, "_Grip") or endsWith(name, "_Tip")
end

local function newPart(model: Model, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	if shape then
		p.Shape = shape
	end
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CastShadow = false
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Parent = model
	return p
end

local function ball(model: Model, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?): Part
	return newPart(model, name, size, cf, color, material, Enum.PartType.Ball)
end

-- Every part of a world object or held item: no physics of its own.
local function quiet(model: Instance, anchored: boolean)
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = anchored
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
			if endsWith(d.Name, "_Outline") then
				d.CastShadow = false
			end
		end
	end
end

-- ---------- Part builds (used until the Blender models are imported) ----------
-- Built around the grip (or the floor centre for world objects) at the origin, front +Z.

local function newModel(name: string): Model
	local m = Instance.new("Model")
	m.Name = name
	m.WorldPivot = CFrame.identity
	return m
end

-- The towel: a fat folded end in the fist and six tapering segments on Motor6Ds named Seg1..Seg6
-- (each client bends them like the Blender towel's bones), with trim bands and a tip.
local function buildTowel(look: string): Model
	local spec = TOWELS[look] or TOWELS.Plain
	local m = newModel("Towel_" .. look)
	local material = spec.material or Enum.Material.Fabric
	local root = newPart(m, "TowelRoot", Vector3.new(0.75, 0.75, 1.1), CFrame.new(0, 0, 0.15), spec.body, material)
	newPart(m, "TowelHem", Vector3.new(0.8, 0.8, 0.14), CFrame.new(0, 0, -0.35), spec.trim, material)
	newPart(m, "TowelHem", Vector3.new(0.8, 0.8, 0.14), CFrame.new(0, 0, 0.55), spec.trim, material)
	local segLen = 0.6
	local prev: BasePart = root
	local prevEnd = 0.7 - 0.15 -- the root's front face in its own space
	for i = 1, 6 do
		local thick = 0.62 - (i - 1) * 0.08
		local z0 = 0.7 + (i - 1) * segLen
		local color = if spec.alt and i % 2 == 0 then spec.alt else spec.body
		local seg = newPart(m, "TowelSeg" .. i, Vector3.new(thick, thick, segLen + 0.04), CFrame.new(0, 0, z0 + segLen / 2), color, material)
		seg:SetAttribute("Jointed", true)
		if i % 2 == 1 or look == "Champion" or look == "Royal" then
			local band = newPart(m, "TowelBand", Vector3.new(thick + 0.06, thick + 0.06, 0.12), CFrame.new(0, 0, z0 + 0.12), spec.trim, material)
			band:SetAttribute("WeldTo", seg.Name)
		end
		local motor = Instance.new("Motor6D")
		motor.Name = "Seg" .. i
		motor.Part0 = prev
		motor.Part1 = seg
		motor.C0 = CFrame.new(0, 0, prevEnd)
		motor.C1 = CFrame.new(0, 0, -segLen / 2)
		motor.Parent = seg
		prev = seg
		prevEnd = segLen / 2
	end
	local tipZ = 0.7 + 6 * segLen
	local tip = ball(m, "TowelTip", if spec.tassel then Vector3.new(0.34, 0.34, 0.5) else Vector3.new(0.24, 0.24, 0.3), CFrame.new(0, 0, tipZ), spec.tip, if spec.tassel then Enum.Material.Metal else material)
	tip:SetAttribute("WeldTo", prev.Name)
	if look == "Royal" or look == "Champion" then
		-- the stitched crown / gold star on the folded end
		local star = newPart(m, "TowelBadge", Vector3.new(0.3, 0.06, 0.3), CFrame.new(0, 0.4, 0.15) * CFrame.Angles(0, math.pi / 4, 0), spec.trim, Enum.Material.Metal)
		star:SetAttribute("WeldTo", root.Name)
	end
	m:SetAttribute("TipZ", tipZ)
	return m
end

local FALLBACKS: { [string]: () -> Model } = {}

FALLBACKS.DashSlippers = function()
	local m = newModel("DashSlippers")
	local purple, pink, bolt = Color3.fromRGB(190, 160, 255), Color3.fromRGB(255, 150, 200), Color3.fromRGB(255, 225, 80)
	newPart(m, "Ribbon", Vector3.new(0.9, 0.12, 0.12), CFrame.new(0, -0.1, 0), pink, Enum.Material.Fabric)
	for _, x in ipairs({ -0.38, 0.38 }) do
		ball(m, "Slipper", Vector3.new(0.6, 0.5, 1.4), CFrame.new(x, -0.55, 0.35), purple, Enum.Material.Fabric)
		ball(m, "Pom", Vector3.new(0.35, 0.35, 0.35), CFrame.new(x, -0.3, 0.85), Color3.fromRGB(255, 255, 255), Enum.Material.Fabric)
		newPart(m, "Bolt", Vector3.new(0.1, 0.06, 0.6), CFrame.new(x, -0.3, 0.4) * CFrame.Angles(0, 0.4, 0), bolt, Enum.Material.Neon)
	end
	return m
end

FALLBACKS.BananaPeel = function()
	-- origin = floor centre (on the floor) and also where the stem is held
	local m = newModel("BananaPeel")
	local yellow, brown = Color3.fromRGB(255, 220, 70), Color3.fromRGB(120, 80, 40)
	for i = 0, 3 do
		local a = i * math.pi / 2 + math.pi / 4
		newPart(m, "Petal", Vector3.new(0.45, 0.14, 0.95), CFrame.Angles(0, a, 0) * CFrame.new(0, 0.08, 0.5) * CFrame.Angles(-0.25, 0, 0), yellow)
	end
	ball(m, "Core", Vector3.new(0.6, 0.35, 0.6), CFrame.new(0, 0.18, 0), Color3.fromRGB(255, 245, 200))
	newPart(m, "Stem", Vector3.new(0.14, 0.3, 0.14), CFrame.new(0, 0.42, 0), brown)
	return m
end

FALLBACKS.BubbleBlaster = function()
	local m = newModel("BubbleBlaster")
	local body, tank, ring = Color3.fromRGB(120, 210, 255), Color3.fromRGB(190, 240, 255), Color3.fromRGB(255, 130, 200)
	newPart(m, "Grip", Vector3.new(0.32, 0.8, 0.4), CFrame.new(0, -0.25, -0.1) * CFrame.Angles(-0.25, 0, 0), Color3.fromRGB(255, 200, 60))
	newPart(m, "Body", Vector3.new(0.5, 0.5, 1.5), CFrame.new(0, 0.3, 0.45), body)
	local glass = ball(m, "Tank", Vector3.new(0.55, 0.55, 0.55), CFrame.new(0, 0.75, 0.2), tank, Enum.Material.Glass)
	glass.Transparency = 0.3
	for i = 0, 7 do
		local a = i * math.pi / 4
		ball(m, "Ring", Vector3.new(0.18, 0.18, 0.18), CFrame.new(math.cos(a) * 0.38, 0.3 + math.sin(a) * 0.38, 1.3), ring)
	end
	m:SetAttribute("TipZ", 1.3)
	m:SetAttribute("TipY", 0.3)
	return m
end

FALLBACKS.AlarmDuck = function()
	-- origin = under its body (floor / palm)
	local m = newModel("AlarmDuck")
	local yellow = Color3.fromRGB(255, 210, 50)
	ball(m, "Body", Vector3.new(1.1, 0.8, 1.3), CFrame.new(0, 0.4, 0), yellow)
	ball(m, "Head", Vector3.new(0.65, 0.65, 0.65), CFrame.new(0, 0.95, 0.35), yellow)
	newPart(m, "Beak", Vector3.new(0.35, 0.14, 0.3), CFrame.new(0, 0.9, 0.75), Color3.fromRGB(255, 140, 40))
	ball(m, "Eye", Vector3.new(0.12, 0.12, 0.12), CFrame.new(-0.16, 1.05, 0.62), Color3.fromRGB(20, 20, 30))
	ball(m, "Eye", Vector3.new(0.12, 0.12, 0.12), CFrame.new(0.16, 1.05, 0.62), Color3.fromRGB(20, 20, 30))
	ball(m, "AlarmDuck_Glow", Vector3.new(0.3, 0.3, 0.3), CFrame.new(0, 1.32, 0.3), Color3.fromRGB(255, 60, 60), Enum.Material.Neon)
	return m
end

FALLBACKS.SoftenerBottle = function()
	local m = newModel("SoftenerBottle")
	local pink = Color3.fromRGB(255, 170, 220)
	newPart(m, "Bottle", Vector3.new(0.7, 1.1, 0.5), CFrame.new(0, -0.55, 0), pink)
	newPart(m, "Label", Vector3.new(0.5, 0.45, 0.06), CFrame.new(0, -0.55, 0.27), Color3.fromRGB(255, 255, 255))
	newPart(m, "Head", Vector3.new(0.35, 0.35, 0.6), CFrame.new(0, 0.15, 0.1), Color3.fromRGB(250, 250, 255))
	newPart(m, "Nozzle", Vector3.new(0.14, 0.14, 0.25), CFrame.new(0, 0.2, 0.5), Color3.fromRGB(200, 120, 180))
	newPart(m, "Trigger", Vector3.new(0.1, 0.35, 0.1), CFrame.new(0, -0.05, 0.38) * CFrame.Angles(0.3, 0, 0), Color3.fromRGB(200, 120, 180))
	m:SetAttribute("TipZ", 0.62)
	m:SetAttribute("TipY", 0.2)
	return m
end

FALLBACKS.SoftenerPuff = function()
	local m = newModel("SoftenerPuff")
	local colors = { Color3.fromRGB(255, 200, 235), Color3.fromRGB(225, 200, 255), Color3.fromRGB(255, 225, 245) }
	for i, offset in ipairs({ Vector3.new(0, 0.9, 0), Vector3.new(0.9, 0.7, 0.2), Vector3.new(-0.8, 0.75, -0.3), Vector3.new(0.2, 0.7, -0.9), Vector3.new(-0.3, 1.3, 0.4) }) do
		local p = ball(m, "Puff", Vector3.new(1.8, 1.4, 1.8) * (1 - i * 0.06), CFrame.new(offset), colors[(i % 3) + 1], Enum.Material.SmoothPlastic)
		p.Transparency = 0.2
	end
	return m
end

FALLBACKS.DryerSheet = function()
	-- a little parachute canopy: origin = its centre underneath
	local m = newModel("DryerSheet")
	local white, blue = Color3.fromRGB(250, 250, 255), Color3.fromRGB(150, 205, 255)
	newPart(m, "Sheet", Vector3.new(1.6, 0.08, 2.6), CFrame.new(0, 0.55, 0), white, Enum.Material.Fabric)
	newPart(m, "Sheet", Vector3.new(1.2, 0.08, 2.6), CFrame.new(-1.3, 0.35, 0) * CFrame.Angles(0, 0, 0.35), white, Enum.Material.Fabric)
	newPart(m, "Sheet", Vector3.new(1.2, 0.08, 2.6), CFrame.new(1.3, 0.35, 0) * CFrame.Angles(0, 0, -0.35), white, Enum.Material.Fabric)
	for i = -1, 1 do
		ball(m, "Flower", Vector3.new(0.35, 0.1, 0.35), CFrame.new(i * 0.9, 0.62, i * 0.5), blue, Enum.Material.Fabric)
	end
	return m
end

FALLBACKS.LaundryBasket = function()
	-- upside down: origin = floor centre, 4.5 wide, 5.5 tall
	local m = newModel("LaundryBasket")
	local plastic, dark = Color3.fromRGB(120, 200, 255), Color3.fromRGB(70, 140, 200)
	local w, h, t = 4.5, 5.5, 0.25
	newPart(m, "Top", Vector3.new(w, t, w), CFrame.new(0, h - t / 2, 0), plastic, Enum.Material.Plastic)
	for i = 0, 3 do
		local a = i * math.pi / 2
		newPart(m, "Wall", Vector3.new(w, h - t, t), CFrame.Angles(0, a, 0) * CFrame.new(0, (h - t) / 2, w / 2 - t / 2), plastic, Enum.Material.Plastic)
		for row = 1, 3 do
			for col = -1, 1 do
				newPart(m, "Hole", Vector3.new(0.7, 0.45, 0.05), CFrame.Angles(0, a, 0) * CFrame.new(col * 1.25, row * 1.3, w / 2 + 0.01), dark, Enum.Material.Plastic)
			end
		end
	end
	newPart(m, "HandleSlot", Vector3.new(1.2, 0.4, 0.06), CFrame.new(0, h - 0.8, w / 2 + 0.02), Color3.fromRGB(40, 80, 120), Enum.Material.Plastic)
	return m
end

FALLBACKS.StaticBalloon = function()
	local m = newModel("StaticBalloon")
	local red = Color3.fromRGB(255, 80, 95)
	newPart(m, "String", Vector3.new(0.06, 2.4, 0.06), CFrame.new(0, 1.2, 0), Color3.fromRGB(255, 255, 255))
	ball(m, "Knot", Vector3.new(0.22, 0.22, 0.22), CFrame.new(0, 2.45, 0), red)
	ball(m, "Balloon", Vector3.new(1.4, 1.65, 1.4), CFrame.new(0, 3.3, 0), red)
	newPart(m, "Bolt", Vector3.new(0.18, 0.7, 0.06), CFrame.new(0, 3.35, 0.69) * CFrame.Angles(0, 0, 0.35), Color3.fromRGB(255, 255, 255), Enum.Material.Neon)
	ball(m, "Shine", Vector3.new(0.3, 0.45, 0.2), CFrame.new(-0.35, 3.7, 0.55), Color3.fromRGB(255, 220, 225), Enum.Material.Neon)
	return m
end

-- ---------- mesh templates ----------

-- A prepared copy of ItemMeshes.<name> (front +Z, 1 unit = 1 stud) and its markers, or nil.
local function fromMesh(name: string, scale: number?): (Model?, { grip: Vector3?, tip: Vector3?, base: Vector3? })
	local template = meshFolder and meshFolder:FindFirstChild(name)
	if not template then
		return nil, {}
	end
	local ok, model, info = pcall(MeshTemplate.Prepare, template, true)
	if not ok or not model then
		warn("[Items] couldn't use the " .. name .. " model: " .. tostring(model))
		return nil, {}
	end
	if scale and scale ~= 1 then
		model:ScaleTo(model:GetScale() * scale)
	end
	for _, d in ipairs(model:GetDescendants()) do
		-- an Animator would overwrite the towel's Bone.Transform (each client whips it)
		if d:IsA("Animator") or d:IsA("AnimationController") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			if isMarker(d.Name) then
				d.Transparency = 1
				d.CastShadow = false
			elseif endsWith(d.Name, "_Glow") then
				d.Material = Enum.Material.Neon
			end
		end
	end
	return model, {
		grip = MeshTemplate.MarkerPosition(model, "_Grip"),
		tip = MeshTemplate.MarkerPosition(model, "_Tip"),
		base = MeshTemplate.MarkerPosition(model, "_Base") or (info and info.base),
	}
end

-- The model to show for an item: its mesh, or the Part build. Returns the model and its points in
-- the model's own space (grip and tip; origin = grip / floor centre for the Part builds).
local function visual(modelName: string, towelLook: string?, scale: number?): (Model, CFrame, Vector3?)
	local model, info = fromMesh(modelName, scale)
	if model then
		local grip = info.grip or info.base or model:GetPivot().Position
		local gripCF = CFrame.new(grip)
		local tip = if info.tip then gripCF:PointToObjectSpace(info.tip) else nil
		return model, gripCF, tip
	end
	local built: Model
	if towelLook then
		built = buildTowel(towelLook)
	else
		local builder = FALLBACKS[modelName]
		built = if builder then builder() else newModel(modelName)
	end
	if scale and scale ~= 1 then
		built:ScaleTo(scale)
	end
	built:SetAttribute("Fallback", true)
	local tipZ = built:GetAttribute("TipZ")
	local tipY = built:GetAttribute("TipY")
	local tip = if type(tipZ) == "number" then Vector3.new(0, if type(tipY) == "number" then tipY else 0, tipZ) * (scale or 1) else nil
	return built, built:GetPivot(), tip
end

-- Welds every part of `model` to `root` (keeping where they are). Part-towel segments ride their
-- Motor6Ds; their trims say which segment they belong to (WeldTo).
local function weldAll(model: Model, root: BasePart)
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and d ~= root and not d:GetAttribute("Jointed") then
			local target = root
			local onto = d:GetAttribute("WeldTo")
			if type(onto) == "string" then
				local seg = model:FindFirstChild(onto)
				if seg and seg:IsA("BasePart") then
					target = seg
				end
			end
			local w = Instance.new("WeldConstraint")
			w.Part0 = target
			w.Part1 = d
			w.Parent = d
		end
	end
end

-- ---------- API ----------

function Looks.Init(s)
	S = s
	local folder = ReplicatedStorage:FindFirstChild("ItemMeshes")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "ItemMeshes"
		folder.Parent = ReplicatedStorage
	end
	meshFolder = folder
	local count = #folder:GetChildren()
	if count > 0 then
		print("[Items] " .. count .. " item model(s) found in ReplicatedStorage.ItemMeshes")
	end
end

-- The ItemMeshes name a key + look shows in the hand.
function Looks.ModelName(key: string, look: string?): string
	if key == "Towel" then
		return "Towel_" .. (look or "Plain")
	end
	local item = S.Config.Item.Items[key]
	return item and item.model or key
end

-- Puts a fresh visual of the item into the tool, welded to its Handle (the old one goes).
function Looks.Dress(tool: Tool, key: string, look: string?)
	local handle = tool:FindFirstChild("Handle")
	if not (handle and handle:IsA("BasePart")) then
		return
	end
	local old = tool:FindFirstChild("Visual")
	if old then
		old:Destroy()
	end
	local tipAtt = handle:FindFirstChild("Tip")
	if tipAtt then
		tipAtt:Destroy()
	end
	local scale = if key == "LaundryBasket" then CARRY_BASKET else nil
	local model, gripCF, tip = visual(Looks.ModelName(key, look), if key == "Towel" then (look or "Plain") else nil, scale)
	quiet(model, false)
	-- move the model so its grip lands on the handle (both turned the same way)
	model:PivotTo(handle.CFrame * gripCF:Inverse() * model:GetPivot())
	model.Name = "Visual"
	weldAll(model, handle)
	model.Parent = tool
	local att = Instance.new("Attachment")
	att.Name = "Tip"
	att.Position = tip or Vector3.new(0, 0, 1)
	att.Parent = handle
	tool:SetAttribute("Look", look or "")
end

-- A bar item's Tool (Item_<key>): invisible Handle on the grip, the model welded to it.
function Looks.BuildTool(key: string, look: string?): Tool
	local item = S.Config.Item.Items[key]
	local tool = Instance.new("Tool")
	tool.Name = "Item_" .. key
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool.ManualActivationOnly = false -- a click in the world fires Activated on the client (ItemClient)
	tool.ToolTip = item and item.display or key
	tool.Grip = GRIP
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.4, 0.4, 0.4)
	handle.Transparency = 1
	handle.CanCollide = false
	handle.CanQuery = false
	handle.CanTouch = false
	handle.Massless = true
	handle.CastShadow = false
	handle.Parent = tool
	Looks.Dress(tool, key, look)
	tool:SetAttribute("ItemKey", key)
	return tool
end

-- A world object (peel, duck, cloud puff, canopy, basket). Returns the model (anchored or not)
-- and its floor/grip point in its own space: place it with PivotTo(target * point:Inverse() * pivot).
function Looks.World(name: string, anchored: boolean, scale: number?): (Model, CFrame)
	local model, info = fromMesh(name, scale)
	local point: CFrame
	if model then
		local p = info.base or info.grip or model:GetPivot().Position
		if name == "DryerSheet" and info.grip then
			p = info.grip -- the canopy hangs from the centre underneath
		end
		point = CFrame.new(p)
	else
		local builder = FALLBACKS[name]
		model = if builder then builder() else newModel(name)
		if scale and scale ~= 1 then
			model:ScaleTo(scale)
		end
		model:SetAttribute("Fallback", true)
		point = CFrame.identity
	end
	quiet(model, anchored)
	return model, point
end

-- Places a world object so its point sits at `target`.
function Looks.Place(model: Model, point: CFrame, target: CFrame)
	model:PivotTo(target * point:Inverse() * model:GetPivot())
end

-- Welds a world object to a character part (carried canopy, basket over a hider). The basket
-- rides a Motor6D so each client can wobble it. Returns the joint.
function Looks.Attach(model: Model, to: BasePart, offset: CFrame, point: CFrame, jointName: string?): Instance
	Looks.Place(model, point, to.CFrame * offset)
	local rootPart = Instance.new("Part")
	rootPart.Name = "ItemRoot"
	rootPart.Size = Vector3.new(0.2, 0.2, 0.2)
	rootPart.Transparency = 1
	rootPart.CanCollide = false
	rootPart.CanQuery = false
	rootPart.CanTouch = false
	rootPart.Massless = true
	rootPart.CFrame = to.CFrame * offset
	rootPart.Parent = model
	weldAll(model, rootPart)
	local joint: Instance
	if jointName then
		local motor = Instance.new("Motor6D")
		motor.Name = jointName
		motor.Part0 = to
		motor.Part1 = rootPart
		motor.C0 = offset
		motor.C1 = CFrame.identity
		motor.Parent = rootPart
		joint = motor
	else
		local w = Instance.new("WeldConstraint")
		w.Part0 = to
		w.Part1 = rootPart
		w.Parent = rootPart
		joint = w
	end
	return joint
end

return Looks
