-- Client performance scaler: on touch (mobile) devices, cut the GPU/CPU-heavy
-- effects the cavern doesn't need at full strength. All changes are client-local
-- (they only affect this player's render), so desktop players keep the full look.

local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local Quality = {}
Quality.IsMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

local function tuneEmitter(pe)
	if pe:GetAttribute("_mobileTuned") then return end
	pe:SetAttribute("_mobileTuned", true)
	pe.Rate = pe.Rate * 0.45
end

function Quality.Init()
	if not Quality.IsMobile then return end

	-- 1) Shadows are among the biggest mobile GPU costs; the neon-lit look survives.
	Lighting.GlobalShadows = false
	local bloom = Lighting:FindFirstChild("GeodeBloom")
	if bloom then
		bloom.Intensity = math.min(bloom.Intensity, 0.7)
		bloom.Size = math.min(bloom.Size, 40)
	end
	local atmo = Lighting:FindFirstChild("GeodeAtmosphere")
	if atmo then
		atmo.Density = math.min(atmo.Density, 0.26)
		atmo.Haze = math.min(atmo.Haze, 1.2)
	end
	-- Brighten ambient so the cavern stays readable with fewer dynamic lights.
	Lighting.Ambient = Color3.fromRGB(60, 56, 84)
	Lighting.OutdoorAmbient = Color3.fromRGB(44, 40, 66)

	local root = Workspace:WaitForChild("CrackAGeode", 20)
	if not root then return end

	-- 2) Thin out dynamic lights (keep the brightest) and halve particle rates.
	local lights = {}
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("ParticleEmitter") then
			tuneEmitter(d)
		elseif d:IsA("PointLight") then
			table.insert(lights, d)
		end
	end
	table.sort(lights, function(a, b)
		return (a.Brightness * a.Range) > (b.Brightness * b.Range)
	end)
	local KEEP = 12
	for i = KEEP + 1, #lights do
		lights[i].Enabled = false
	end

	-- 3) New replicated FX (meteor trail, golden geode, crack bursts) get tuned too.
	root.DescendantAdded:Connect(function(d)
		if d:IsA("ParticleEmitter") then
			task.defer(function()
				if d.Parent then tuneEmitter(d) end
			end)
		end
	end)
end

return Quality
