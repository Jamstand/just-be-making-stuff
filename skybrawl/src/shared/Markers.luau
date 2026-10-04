--[[
    Undoing Studio's importer. Every exported FBX (fighters, weapons, map
    kits) carries three tiny meshes: Marker_Origin, Marker_Up (straight up)
    and Marker_Front, `distance` studs apart in the art's own space. Wherever
    and however the importer placed, scaled or turned the model, they give
    back the art's frame and scale.

      fighters, weapons   Marker_Front is -Z (the way the fighter faces / the
                          weapon's edge side)
      map kits            Marker_Front is +Z (toward the 2D camera)
]]

local Markers = {}

local function find(model, name)
	local m = model:FindFirstChild(name, true)
	if m and m:IsA("BasePart") then
		return m.Position
	end
	return nil
end

function Markers.isMarker(instance)
	return string.sub(instance.Name, 1, 7) == "Marker_"
end

--[[
    Returns basis (CFrame of the art's origin and axes in the model's current
    world space) and scale (studs per art unit), or the model's pivot and 1
    if it has no markers. frontAxis is -1 when Marker_Front lies on -Z.
]]
function Markers.basis(model, distance, frontAxis)
	local o, u, f = find(model, "Marker_Origin"), find(model, "Marker_Up"), find(model, "Marker_Front")
	if not (o and u and f) then
		return model:GetPivot(), 1
	end
	local up = u - o
	local scale = up.Magnitude / distance
	if scale < 1e-5 then
		return model:GetPivot(), 1
	end
	local y = up.Unit
	local front = (f - o) - y * (f - o):Dot(y)
	if front.Magnitude < 1e-5 then
		return model:GetPivot(), 1
	end
	local z = front.Unit * (frontAxis or 1)
	return CFrame.fromMatrix(o, y:Cross(z), y, z), scale
end

--[[
    Every BasePart in the model (markers skipped) as
    { source, cframe (in art space, unit scale), size (unit scale) }.
]]
function Markers.read(model, distance, frontAxis)
	local basis, scale = Markers.basis(model, distance, frontAxis)
	local parts = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and not Markers.isMarker(d) then
			local rel = basis:ToObjectSpace(d.CFrame)
			table.insert(parts, {
				source = d,
				name = d.Name,
				cframe = CFrame.new(rel.Position / scale) * rel.Rotation,
				size = d.Size / scale,
			})
		end
	end
	return parts, scale
end

-- A clean copy of an imported part (keeps its mesh, texture and SurfaceAppearance).
function Markers.cloneMesh(source)
	local part = source:Clone()
	for _, child in part:GetChildren() do
		if not child:IsA("SurfaceAppearance") then
			child:Destroy()
		end
	end
	return part
end

-- Strips a piece's texture so Neon shows its Color as a flat glow.
function Markers.makeGlow(part)
	local surface = part:FindFirstChildOfClass("SurfaceAppearance")
	if surface then
		surface:Destroy()
	end
	if part:IsA("MeshPart") then
		pcall(function()
			part.TextureID = ""
		end)
	end
end

return Markers
