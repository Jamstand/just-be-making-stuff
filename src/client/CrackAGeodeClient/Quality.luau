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

	-- 1) Shadows and depth-of-field are the biggest mobile GPU costs. The stylized-
	-- realism look keeps its PBR materials and warm light pools; only the shadow
	-- casting and distant blur are sacrificed on phones (desktop keeps both).
	Lighting.GlobalShadows = false
	local dof = Lighting:FindFirstChild("GeodeDoF")
	if dof then dof.Enabled = false end
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
	-- Brighten ambient so the cavern stays readable with fewer dynamic lights
	-- (lifted from the StyleGuide's slate/indigo base, not the old violet).
	Lighting.Ambient = Color3.fromRGB(40, 38, 58)
	Lighting.OutdoorAmbient = Color3.fromRGB(34, 32, 50)

	local root = Workspace:WaitForChild("CrackAGeode", 20)
	if not root then return end

	-- 2) Halve particle rates on everything present now.
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("ParticleEmitter") then tuneEmitter(d) end
	end

	-- 3) Dynamic light budget: keep only the KEEP nearest PointLights enabled,
	-- re-evaluated every 3s. A static brightest-first cull failed two ways in the
	-- stylized-realism perf pass: runtime-built lights (geode nodes, zone arenas)
	-- replicate after the cull (139 enabled lights leaked), and replication-order
	-- budgets starve whichever zone the player actually visits (Astral was down
	-- to 2 lights). Proximity solves both; enabled-but-distant lights are the
	-- expensive case this avoids. Transient crack-flash lights under
	-- CrackAGeode.FX are exempt — they die within ~2s and carry the core
	-- feedback moment.
	local KEEP = 16
	local fxFolder = root:FindFirstChild("FX")
	task.spawn(function()
		while root.Parent do
			local cam = Workspace.CurrentCamera
			local origin = cam and cam.CFrame.Position or Vector3.zero
			local lights = {}
			for _, d in ipairs(root:GetDescendants()) do
				if d:IsA("PointLight") and not (fxFolder and d:IsDescendantOf(fxFolder)) then
					local holder = d.Parent
					if holder and holder:IsA("BasePart") then
						lights[#lights + 1] = { d, (holder.Position - origin).Magnitude }
					end
				end
			end
			table.sort(lights, function(a, b) return a[2] < b[2] end)
			for i, entry in ipairs(lights) do
				entry[1].Enabled = i <= KEEP
			end
			task.wait(3)
		end
	end)

	-- 4) New replicated FX (meteor trail, golden geode, crack bursts) get tuned too.
	root.DescendantAdded:Connect(function(d)
		if d:IsA("ParticleEmitter") then
			task.defer(function()
				if d.Parent then tuneEmitter(d) end
			end)
		end
	end)
end

return Quality