--[[
    The 2D match camera. Players pick both parts in Settings:

    Camera mode (what it follows)
      FrameAll    pans and zooms to keep every fighter on screen
      FollowMe    centered on your fighter
      Lookahead   follows you, leaning toward where you're heading
      DuelFocus   frames you and your nearest opponent
      FixedStage  never moves; shows the whole arena

    Camera look (how it's drawn)
      Flat        far away with a narrow lens (near-orthographic 2D)
      Classic     normal lens, flat-on (2.5D)
      Tilted      slightly above the stage looking down (2.5D)
      Wide        wide lens with strong perspective

    Plus zoom, smoothing and screen shake.

    MatchClient supplies positions through setProvider(); while you're
    KO'd or eliminated the camera falls back to framing everyone.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local Settings = require(script.Parent.Settings)

local CameraController = {}

local BIND_NAME = "SkybrawlCamera"
local camera = workspace.CurrentCamera

local active = false
local origin = Vector3.zero
local bounds = nil
local provider = nil

local current = nil -- { x, y, h }
local shakeAmount = 0
local shakeSeed = 0

local function lookFor(id)
	for _, look in Config.Camera.Looks do
		if look.Id == id then
			return look
		end
	end
	return Config.Camera.Looks[1]
end

local function frameRect(minX, minY, maxX, maxY, aspect)
	local pad = Config.Camera.FramePadding
	local width = maxX - minX + pad * 2
	local height = maxY - minY + pad * 2
	local h = math.max(height, width / aspect, Config.Camera.MinViewHeight)
	return (minX + maxX) / 2, (minY + maxY) / 2 + 2, h
end

local function boundsView(aspect)
	local b = bounds
	return (b.minX + b.maxX) / 2, (b.minY + b.maxY) / 2, math.max(b.maxY - b.minY, (b.maxX - b.minX) / aspect)
end

-- Works out where the camera wants to be this frame (local coordinates).
local function desiredView(aspect)
	local data = provider and provider()
	local mode = Settings.get("CameraMode")
	local me = data and data.me
	local height = Config.Physics.FighterHeight

	if mode == "FixedStage" then
		return boundsView(aspect)
	end

	local function frameAll()
		local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
		local any = false
		for _, f in data and data.fighters or {} do
			if f.alive then
				any = true
				minX = math.min(minX, f.x)
				maxX = math.max(maxX, f.x)
				minY = math.min(minY, f.y)
				maxY = math.max(maxY, f.y + height)
			end
		end
		if not any then
			return boundsView(aspect)
		end
		return frameRect(minX, minY, maxX, maxY, aspect)
	end

	if not me or not me.alive then
		return frameAll()
	end

	if mode == "FrameAll" then
		return frameAll()
	elseif mode == "FollowMe" then
		return me.x, me.y + 6, Config.Camera.FollowViewHeight
	elseif mode == "Lookahead" then
		local lead = me.facing * 7 + math.clamp(me.vx * 0.3, -12, 12)
		local rise = math.clamp(me.vy * 0.12, -6, 8)
		return me.x + lead, me.y + 6 + rise, Config.Camera.FollowViewHeight * 1.08
	elseif mode == "DuelFocus" then
		local best, bestDist
		for _, f in data.fighters do
			if f.alive and f.enemy then
				local d = math.abs(f.x - me.x) + math.abs(f.y - me.y)
				if not best or d < bestDist then
					best, bestDist = f, d
				end
			end
		end
		if not best then
			return me.x, me.y + 6, Config.Camera.FollowViewHeight
		end
		return frameRect(
			math.min(me.x, best.x),
			math.min(me.y, best.y),
			math.max(me.x, best.x),
			math.max(me.y, best.y) + height,
			aspect
		)
	end
	return frameAll()
end

local function clampToBounds(x, y, h, aspect)
	local b = bounds
	local maxH = math.max(b.maxY - b.minY, (b.maxX - b.minX) / aspect)
	h = math.min(h, maxH)
	local halfH = h / 2
	local halfW = h * aspect / 2
	if halfW * 2 >= b.maxX - b.minX then
		x = (b.minX + b.maxX) / 2
	else
		x = math.clamp(x, b.minX + halfW, b.maxX - halfW)
	end
	if halfH * 2 >= b.maxY - b.minY then
		y = (b.minY + b.maxY) / 2
	else
		y = math.clamp(y, b.minY + halfH, b.maxY - halfH)
	end
	return x, y, h
end

local function update(dt)
	if not active then
		return
	end
	local viewport = camera.ViewportSize
	local aspect = viewport.Y > 0 and viewport.X / viewport.Y or 16 / 9
	local tx, ty, th = desiredView(aspect)
	th = th / math.clamp(Settings.get("CameraZoom") or 1, 0.5, 2)
	tx, ty, th = clampToBounds(tx, ty, th, aspect)

	if not current then
		current = { x = tx, y = ty, h = th }
	end
	local smoothing = math.clamp(Settings.get("CameraSmoothing") or 0.5, 0, 1)
	local rate = 16 - smoothing * 13
	local alpha = 1 - math.exp(-rate * dt)
	current.x += (tx - current.x) * alpha
	current.y += (ty - current.y) * alpha
	current.h += (th - current.h) * alpha

	local look = lookFor(Settings.get("CameraLook"))
	local fov = look.FOV
	local distance = (current.h / 2) / math.tan(math.rad(fov) / 2)
	local pitch = math.rad(look.Pitch or 0)

	local target = origin + Vector3.new(current.x, current.y, 0)
	local position = target + Vector3.new(0, math.sin(pitch) * distance, math.cos(pitch) * distance)

	-- Screen shake, in screen-space studs relative to view height.
	if shakeAmount > 0.01 and Settings.get("ScreenShake") then
		shakeSeed += dt * 40
		local scale = shakeAmount * current.h / 60
		local offset = Vector3.new(math.noise(shakeSeed, 1.3) * scale, math.noise(2.1, shakeSeed) * scale, 0)
		target += offset
		position += offset
	end
	shakeAmount *= math.exp(-9 * dt)

	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = fov
	camera.CFrame = CFrame.lookAt(position, target)
end

function CameraController.shake(amount)
	shakeAmount = math.min(Config.Camera.ShakeMax, shakeAmount + amount)
end

function CameraController.setProvider(fn)
	provider = fn
end

function CameraController.start(arenaOrigin, world)
	origin = arenaOrigin
	bounds = world.camera
	current = nil
	shakeAmount = 0
	active = true
	camera = workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable
	RunService:UnbindFromRenderStep(BIND_NAME)
	RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, update)
end

function CameraController.stop()
	active = false
	provider = nil
	RunService:UnbindFromRenderStep(BIND_NAME)
	camera = workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Custom
	camera.FieldOfView = 70
	local character = Players.LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		camera.CameraSubject = humanoid
	end
end

function CameraController.isActive()
	return active
end

function CameraController.init() end

return CameraController
