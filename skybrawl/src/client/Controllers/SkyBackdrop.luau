--[[
    The painted background behind a match, in up to three layers
    (Config.Art.SkyLayers): the far sky, the map's distant landmarks, and
    near clouds/haze. Each layer is an image on a plane behind all of the
    map's 3D scenery. Every frame each plane is fitted to the camera's view at
    its depth, so the painting always fills the screen whatever the camera
    mode, look or zoom, and is slid against the camera's pan by its own
    parallax amount, so the nearer layers drift more.

    Images come from Config.Art.SkyImages[mapId] ({ Sky = id, Landmarks = id,
    Haze = id }, or a single id for just the sky). Layers without an image are
    skipped; with no Sky image the server's gradient backdrop shows instead.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Maps = require(Shared.Maps)

local SkyBackdrop = {}

-- How far (in half-views) the camera usually pans from the stage's center;
-- each layer is drawn big enough to slide that far without showing an edge.
local PAN_RANGE = 1.5
local SLACK = 0.06 -- extra size for camera shake and tilt
local MAX_SIZE = 2048 -- the largest part size Roblox allows

local CORNERS = { Vector2.new(-1, -1), Vector2.new(1, -1), Vector2.new(-1, 1), Vector2.new(1, 1) }

local layers = {} -- { part, gui, depth, parallax, margin }
local connection = nil
local origin = Vector3.zero
local center = Vector3.zero

-- A map's layer images by layer name ("" or missing = no image).
function SkyBackdrop.images(mapId)
	local entry = Config.Art.SkyImages[mapId]
	if type(entry) == "string" then
		return { Sky = entry }
	end
	return entry or {}
end

-- How much bigger than the view a layer is drawn, so its parallax slide
-- never shows an edge.
function SkyBackdrop.margin(parallax)
	return 1 + parallax * PAN_RANGE + SLACK
end

function SkyBackdrop.stop()
	if connection then
		connection:Disconnect()
		connection = nil
	end
	for _, layer in layers do
		layer.part:Destroy()
	end
	table.clear(layers)
end

-- The part of the plane z = planeZ the camera sees: the bounding box of its
-- four corner rays. Nil if the camera isn't looking toward the plane.
local function viewBox(camera, planeZ)
	local cf = camera.CFrame
	local pos = cf.Position
	local viewport = camera.ViewportSize
	local aspect = viewport.Y > 0 and viewport.X / viewport.Y or 16 / 9
	local ty = math.tan(math.rad(camera.FieldOfView) / 2)
	local tx = ty * aspect
	local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
	for _, corner in CORNERS do
		local dir = cf:VectorToWorldSpace(Vector3.new(corner.X * tx, corner.Y * ty, -1))
		if dir.Z > -1e-3 or pos.Z <= planeZ then
			return nil
		end
		local hit = pos + dir * ((planeZ - pos.Z) / dir.Z)
		minX = math.min(minX, hit.X)
		minY = math.min(minY, hit.Y)
		maxX = math.max(maxX, hit.X)
		maxY = math.max(maxY, hit.Y)
	end
	return Vector2.new((minX + maxX) / 2, (minY + maxY) / 2), Vector2.new((maxX - minX) / 2, (maxY - minY) / 2)
end

local function update()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	-- How far the view of the fighters' lane has panned from the stage's
	-- center, in half-views.
	local laneCenter, laneHalf = viewBox(camera, origin.Z)
	if not laneCenter then
		return
	end
	local pan = (laneCenter - Vector2.new(center.X, center.Y)) / laneHalf

	for _, layer in layers do
		local planeZ = origin.Z - layer.depth
		local viewCenter, half = viewBox(camera, planeZ)
		if viewCenter then
			-- The layer scrolls `parallax` times as fast as the stage does.
			local spare = layer.margin - 1 - SLACK
			local slide = Vector2.new(
				math.clamp(pan.X * layer.parallax, -spare, spare),
				math.clamp(pan.Y * layer.parallax, -spare, spare)
			)
			local position = viewCenter - slide * half
			local size = half * 2 * layer.margin
			layer.part.Size = Vector3.new(math.min(MAX_SIZE, size.X), math.min(MAX_SIZE, size.Y), 0.2)
			layer.part.CFrame = CFrame.new(position.X, position.Y, planeZ)
			layer.gui.CanvasSize = Vector2.new(1024, math.floor(1024 * size.Y / size.X))
		end
	end
end

local function makeLayer(spec, image, order)
	local part = Instance.new("Part")
	part.Name = "SkybrawlSky" .. spec.Name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Parent = workspace

	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Back -- faces +Z, toward the camera
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.LightInfluence = 0
	gui.MaxDistance = 100000
	gui.ZOffset = order
	gui.Parent = part
	local label = Instance.new("ImageLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.ScaleType = Enum.ScaleType.Crop
	label.Image = string.match(image, "^%d+$") and ("rbxassetid://" .. image) or image
	label.Parent = gui

	return {
		part = part,
		gui = gui,
		depth = spec.Depth,
		parallax = spec.Parallax,
		margin = SkyBackdrop.margin(spec.Parallax),
	}
end

function SkyBackdrop.start(mapId, arenaOrigin)
	SkyBackdrop.stop()
	local map = Maps.get(mapId)
	if not map then
		return
	end
	local images = SkyBackdrop.images(mapId)
	origin = arenaOrigin
	local cam = map.Camera
	center = arenaOrigin + Vector3.new((cam[1] + cam[3]) / 2, (cam[2] + cam[4]) / 2, 0)

	for order, spec in Config.Art.SkyLayers do
		local image = images[spec.Name]
		if image and image ~= "" then
			table.insert(layers, makeLayer(spec, image, order))
		end
	end
	if #layers == 0 then
		return
	end
	connection = RunService.RenderStepped:Connect(update)
	update()
end

return SkyBackdrop
