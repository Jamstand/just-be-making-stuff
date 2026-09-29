-- Lighting: "Giant's Bedroom at night". Warm lamp light, cool moonlight, soft bloom so glowing
-- socks pop out of the dark. Applied once at startup; the Map adds the actual lamp/window lights.
local LightingService = game:GetService("Lighting")

local Lighting = {}

function Lighting.Init(_S)
	local L = LightingService
	pcall(function()
		L.Technology = Enum.Technology.Future
	end)
	-- Target: docs/concept/bedroom_keyframe.png - warm lamp key light, cool purple shadows,
	-- saturated flat colours, and nothing ever black.
	L.ClockTime = 0.4 -- deep night: the default skybox shows stars and a moon
	L.Brightness = 2.4
	L.Ambient = Color3.fromRGB(98, 92, 132) -- lifts the shadows to purple instead of black
	L.OutdoorAmbient = Color3.fromRGB(112, 106, 152)
	L.ExposureCompensation = 0.55
	L.EnvironmentDiffuseScale = 0.5
	L.EnvironmentSpecularScale = 0.25 -- flat, toy-like surfaces (less shine)
	L.GlobalShadows = true
	L.ShadowSoftness = 0.55
	L.FogEnd = 100000

	for _, child in ipairs(L:GetChildren()) do
		if child:IsA("SunRaysEffect") or child:IsA("Atmosphere") or child:IsA("BloomEffect") or child:IsA("ColorCorrectionEffect") or child:IsA("DepthOfFieldEffect") then
			child:Destroy()
		end
	end

	local atmo = Instance.new("Atmosphere")
	atmo.Name = "BedroomAtmosphere"
	atmo.Density = 0.12
	atmo.Offset = 0.1
	atmo.Color = Color3.fromRGB(135, 115, 185)
	atmo.Decay = Color3.fromRGB(80, 60, 130)
	atmo.Glare = 0.1
	atmo.Haze = 0.6
	atmo.Parent = L

	local bloom = Instance.new("BloomEffect")
	bloom.Name = "BedroomBloom"
	bloom.Intensity = 0.5
	bloom.Threshold = 1.4
	bloom.Size = 22
	bloom.Parent = L

	local cc = Instance.new("ColorCorrectionEffect")
	cc.Name = "BedroomColor"
	cc.Brightness = 0.03
	cc.Contrast = 0.18
	cc.Saturation = 0.38 -- the concept art is very saturated
	cc.TintColor = Color3.fromRGB(255, 242, 228)
	cc.Parent = L
end

return Lighting
