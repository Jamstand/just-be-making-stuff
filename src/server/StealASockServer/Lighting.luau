-- Lighting: "Giant's Bedroom at night". Warm lamp light, cool moonlight, soft bloom so glowing
-- socks pop out of the dark. Applied once at startup; the Map adds the actual lamp/window lights.
local LightingService = game:GetService("Lighting")

local Lighting = {}

function Lighting.Init(_S)
	local L = LightingService
	pcall(function()
		L.Technology = Enum.Technology.Future
	end)
	L.ClockTime = 0.4 -- deep night: the default skybox shows stars and a moon
	L.Brightness = 1.4
	L.Ambient = Color3.fromRGB(28, 30, 52)
	L.OutdoorAmbient = Color3.fromRGB(38, 40, 70)
	L.ExposureCompensation = 0.35
	L.EnvironmentDiffuseScale = 0.6
	L.EnvironmentSpecularScale = 0.6
	L.GlobalShadows = true
	L.ShadowSoftness = 0.4
	L.FogEnd = 100000

	for _, child in ipairs(L:GetChildren()) do
		if child:IsA("SunRaysEffect") or child:IsA("Atmosphere") or child:IsA("BloomEffect") or child:IsA("ColorCorrectionEffect") or child:IsA("DepthOfFieldEffect") then
			child:Destroy()
		end
	end

	local atmo = Instance.new("Atmosphere")
	atmo.Name = "BedroomAtmosphere"
	atmo.Density = 0.32
	atmo.Offset = 0.2
	atmo.Color = Color3.fromRGB(110, 100, 150)
	atmo.Decay = Color3.fromRGB(60, 50, 110)
	atmo.Glare = 0.25
	atmo.Haze = 1.6
	atmo.Parent = L

	local bloom = Instance.new("BloomEffect")
	bloom.Name = "BedroomBloom"
	bloom.Intensity = 0.65
	bloom.Threshold = 1.1
	bloom.Size = 28
	bloom.Parent = L

	local cc = Instance.new("ColorCorrectionEffect")
	cc.Name = "BedroomColor"
	cc.Brightness = 0.02
	cc.Contrast = 0.12
	cc.Saturation = 0.18
	cc.TintColor = Color3.fromRGB(255, 244, 232)
	cc.Parent = L
end

return Lighting
