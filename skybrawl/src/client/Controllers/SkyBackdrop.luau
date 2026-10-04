--[[
    The painted sky behind a match. A plane far behind the stage that is
    resized every frame to just fill the camera's view, so the whole
    painting is always on screen whatever the camera mode, look or zoom. It
    drifts a little against the camera for parallax.

    Uses Config.Art.SkyImages[mapId]; with no image set, the server's
    gradient backdrop shows instead.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Maps = require(Shared.Maps)

local SkyBackdrop = {}

local DEPTH = 210 -- studs behind the fighters' lane (in front of the server's gradient at 220)
local MARGIN = 1.18 -- covers camera tilt and the parallax drift
local PARALLAX = 0.12

local part = nil
local gui = nil
local connection = nil
local origin = Vector3.zero
local center = Vector3.zero

function SkyBackdrop.stop()
	if connection then
		connection:Disconnect()
		connection = nil
	end
	if part then
		part:Destroy()
		part = nil
		gui = nil
	end
end

local function update()
	local camera = workspace.CurrentCamera
	if not camera or not part then
		return
	end
	local camPos = camera.CFrame.Position
	local planeZ = origin.Z - DEPTH
	local distance = math.max(10, camPos.Z - planeZ)
	local halfH = distance * math.tan(math.rad(camera.FieldOfView) / 2) * MARGIN
	local viewport = camera.ViewportSize
	local aspect = viewport.Y > 0 and viewport.X / viewport.Y or 16 / 9
	local halfW = halfH * aspect
	local drift = (Vector3.new(camPos.X, camPos.Y, 0) - Vector3.new(center.X, center.Y, 0)) * PARALLAX
	local position = Vector3.new(camPos.X - drift.X, camPos.Y - drift.Y, planeZ)
	part.Size = Vector3.new(math.min(2048, halfW * 2), math.min(2048, halfH * 2), 0.2)
	part.CFrame = CFrame.new(position)
	gui.CanvasSize = Vector2.new(1024, math.floor(1024 * halfH / halfW))
end

function SkyBackdrop.start(mapId, arenaOrigin)
	SkyBackdrop.stop()
	local image = Config.Art.SkyImages[mapId]
	local map = Maps.get(mapId)
	if not map or not image or image == "" then
		return
	end
	origin = arenaOrigin
	local cam = map.Camera
	center = arenaOrigin + Vector3.new((cam[1] + cam[3]) / 2, (cam[2] + cam[4]) / 2, 0)

	part = Instance.new("Part")
	part.Name = "SkybrawlSky"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Parent = workspace

	gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Back -- faces +Z, toward the camera
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.LightInfluence = 0
	gui.Parent = part
	local label = Instance.new("ImageLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.ScaleType = Enum.ScaleType.Crop
	label.Image = string.match(image, "^%d+$") and ("rbxassetid://" .. image) or image
	label.Parent = gui

	connection = RunService.RenderStepped:Connect(update)
	update()
end

return SkyBackdrop
