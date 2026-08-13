-- RegionFX: per-player biome lighting. As the local player moves between the hub
-- and each warp biome, the client tweens Atmosphere / ColorCorrection / Bloom /
-- sun angle to that region's palette. Lighting is per-client, so this is free and
-- affects only this player. Palettes live in Config.Regions[i].light.

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local RegionFX = {}
local Config
local player = Players.LocalPlayer
local currentKey = nil

-- nearest region center in the XZ plane (arenas are 1000 studs apart, so the
-- nearest center is always the one the player is standing in)
local function nearestRegion(pos)
	local best, bestD
	for _, r in ipairs(Config.Regions) do
		local dx, dz = r.center.X - pos.X, r.center.Z - pos.Z
		local d = dx * dx + dz * dz
		if not bestD or d < bestD then best, bestD = r, d end
	end
	return best
end

local function apply(region, instant)
	local L = region.light
	local atmo = Lighting:FindFirstChildOfClass("Atmosphere")
	local cc = Lighting:FindFirstChild("GeodeColor") or Lighting:FindFirstChildOfClass("ColorCorrectionEffect")
	local bloom = Lighting:FindFirstChild("GeodeBloom") or Lighting:FindFirstChildOfClass("BloomEffect")
	local t = instant and 0.05 or 1.3
	local info = TweenInfo.new(t, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	if atmo then
		TweenService:Create(atmo, info, {
			Color = L.atmosphere, Haze = L.haze, Density = L.density, Glare = L.glare, Decay = L.decay,
		}):Play()
	end
	if cc then
		TweenService:Create(cc, info, {
			TintColor = L.tint, Brightness = L.brightness, Contrast = L.contrast, Saturation = L.saturation,
		}):Play()
	end
	if bloom then
		TweenService:Create(bloom, info, { Intensity = L.bloom }):Play()
	end
	TweenService:Create(Lighting, info, { ClockTime = L.clock }):Play()
end

function RegionFX.Set(regionKey)
	if not (Config and regionKey) then return end
	local region = Config.RegionByKey(regionKey)
	if region and region.key ~= currentKey then
		currentKey = region.key
		apply(region, false)
	end
end

function RegionFX.Init(config)
	Config = config
	local hub = Config.RegionByKey("Cavern") or Config.Regions[1]
	currentKey = hub.key
	apply(hub, true)

	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.25 then return end
		acc = 0
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if not hrp then return end
		local region = nearestRegion(hrp.Position)
		if region and region.key ~= currentKey then
			currentKey = region.key
			apply(region, false)
		end
	end)
end

return RegionFX
