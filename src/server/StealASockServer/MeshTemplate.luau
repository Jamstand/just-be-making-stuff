-- MeshTemplate: prepares an imported mesh template (from tools/blender/build_all.py, the Creator
-- Store or Roblox's Mesh Generator) before the Factory or the Map uses it.
--
-- Blender-built templates carry tiny marker parts:
--   <Name>_Base  the origin (floor centre / sock leg axis)
--   <Name>_Unit  exactly 1 unit toward the model's FRONT
--   <Name>_Pin   (socks) where the sock hangs from its clothespin
-- and a separate <Name>_Outline inverted hull. Prepare() uses Base->Unit to undo whatever turn the
-- 3D importer applied (the front ends up facing +Z) and, if asked, to scale 1 unit to 1 stud;
-- hides the markers; and turns shadows off on outline parts (an outline that casts shadows would
-- darken the whole model). Templates without markers pass through unchanged.
local MeshTemplate = {}

local function endsWith(name: string, suffix: string): boolean
	return #name >= #suffix and string.sub(name, -#suffix) == suffix
end

local function findMarker(root: Instance, suffix: string): BasePart?
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") and endsWith(d.Name, suffix) then
			return d
		end
	end
	return nil
end

-- Clones `template` into a Model. Returns the model plus marker positions (world space, after
-- any fix-up) or nil if the template can't be used.
function MeshTemplate.Prepare(template: Instance, scaleToStuds: boolean): (Model?, { base: Vector3?, pin: Vector3?, hasMarkers: boolean })
	local clone = template:Clone()
	local model: Model
	if clone:IsA("Model") then
		model = clone
	elseif clone:IsA("BasePart") then
		model = Instance.new("Model")
		model.Name = clone.Name
		clone.Parent = model
		model.PrimaryPart = clone
	else
		clone:Destroy()
		return nil, { hasMarkers = false }
	end

	local base = findMarker(model, "_Base")
	local unit = findMarker(model, "_Unit")
	local info = { base = nil :: Vector3?, pin = nil :: Vector3?, hasMarkers = base ~= nil and unit ~= nil }
	if base and unit then
		local offset = unit.Position - base.Position
		local flat = Vector3.new(offset.X, 0, offset.Z)
		if flat.Magnitude > 1e-4 then
			-- turn about the Base marker so the front (Base -> Unit) points along +Z
			local angle = math.atan2(flat.X, flat.Z)
			local pivot = CFrame.new(base.Position)
			model:PivotTo(pivot * CFrame.Angles(0, -angle, 0) * pivot:Inverse() * model:GetPivot())
		end
		if scaleToStuds and offset.Magnitude > 1e-4 then
			model:ScaleTo(model:GetScale() / offset.Magnitude)
		end
		info.base = base.Position
		local pin = findMarker(model, "_Pin")
		info.pin = if pin then pin.Position else nil
	end

	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			if endsWith(d.Name, "_Base") or endsWith(d.Name, "_Unit") or endsWith(d.Name, "_Pin") then
				d.Transparency = 1
				d.CanCollide = false
				d.CanQuery = false
				d.CanTouch = false
				d.CastShadow = false
			elseif endsWith(d.Name, "_Outline") then
				d.CastShadow = false
				d.CanQuery = false
				d.CanTouch = false
			end
		end
	end
	return model, info
end

return MeshTemplate
