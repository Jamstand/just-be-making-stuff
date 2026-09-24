-- Quality: the client's single device / quality / settings bus.
-- Flags are set synchronously at require time so every module can read them in
-- its Init; runtime changes (the Settings panel) go through ApplySettings and fan
-- out through Quality.Changed with the field name. Init() keeps the mobile
-- lighting / particle / light-budget tune from the perf pass (touch clients only —
-- all of it is client-local, desktop keeps the full look).
--
--   Quality.IsTouch            touch-only client (phone / tablet without a mouse)
--   Quality.IsMobile           alias of IsTouch (legacy readers)
--   Quality.Tier               0 (Reduce FX on) / 1 (touch) / 2 (desktop)
--   Quality.ReduceFX           Settings.reduceFx
--   Quality.Settings           { music, sfx, reduceFx, socialPings, hideFeed } (validated)
--   Quality.Changed            BindableEvent.Event fired with the changed field:
--                              "music"|"sfx"|"reduceFx"|"socialPings"|"hideFeed"|"ReduceFX"|"Tier"
--   Quality.ApplySettings(t)   whitelist + clamp (music/sfx 0..100 ints, booleans), unknown keys
--                              dropped; stores, fires Changed per field; returns Settings
--   Quality.Init()             mobile lighting tune + proximity light budget (touch only)

local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Quality = {}

-- ===== flags (synchronous, at require time) =====
local DEFAULTS = { music = 22, sfx = 100, reduceFx = false, socialPings = true, hideFeed = false }
do
	-- Config.Social.SettingsDefault is the shared source; the literal above is the
	-- fallback for a Config that predates it.
	local ok, Config = pcall(function()
		return require(ReplicatedStorage:WaitForChild("Config", 5))
	end)
	if ok and type(Config) == "table" and Config.Social and type(Config.Social.SettingsDefault) == "table" then
		for k, v in pairs(Config.Social.SettingsDefault) do DEFAULTS[k] = v end
	end
end

Quality.IsTouch = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
Quality.IsMobile = Quality.IsTouch
local BASE_TIER = Quality.IsTouch and 1 or 2

Quality.Settings = {}
for k, v in pairs(DEFAULTS) do Quality.Settings[k] = v end
Quality.ReduceFX = Quality.Settings.reduceFx == true
Quality.Tier = Quality.ReduceFX and 0 or BASE_TIER

local changedEvent = Instance.new("BindableEvent")
changedEvent.Name = "QualityChanged"
Quality.Changed = changedEvent.Event

-- ===== settings =====
local NUMERIC = { music = true, sfx = true }
local BOOLEAN = { reduceFx = true, socialPings = true, hideFeed = true }

function Quality.ApplySettings(tbl)
	if type(tbl) ~= "table" then return Quality.Settings end
	local changed = {}
	for key in pairs(NUMERIC) do
		local v = tbl[key]
		if v ~= nil then
			local n = tonumber(v)
			if n and n == n then -- reject NaN / non-numbers
				n = math.clamp(math.floor(n), 0, 100)
				if Quality.Settings[key] ~= n then
					Quality.Settings[key] = n
					changed[#changed + 1] = key
				end
			end
		end
	end
	for key in pairs(BOOLEAN) do
		local v = tbl[key]
		if type(v) == "boolean" and Quality.Settings[key] ~= v then
			Quality.Settings[key] = v
			changed[#changed + 1] = key
		end
	end
	local reduce = Quality.Settings.reduceFx == true
	local tier = reduce and 0 or BASE_TIER
	local reduceChanged = Quality.ReduceFX ~= reduce
	local tierChanged = Quality.Tier ~= tier
	Quality.ReduceFX = reduce
	Quality.Tier = tier
	for _, key in ipairs(changed) do changedEvent:Fire(key) end
	if reduceChanged then changedEvent:Fire("ReduceFX") end
	if tierChanged then changedEvent:Fire("Tier") end
	return Quality.Settings
end

-- ===== mobile tune =====
local function tuneEmitter(pe)
	if pe:GetAttribute("_mobileTuned") then return end
	pe:SetAttribute("_mobileTuned", true)
	pe.Rate = pe.Rate * 0.45
end

function Quality.Init()
	-- flags are already live (set above at require time); the tune below is
	-- touch-only because desktop GPUs carry the full look comfortably.
	if not Quality.IsTouch then return end

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
	-- feedback moment. Reduce FX (tier 0) tightens the budget further.
	local fxFolder = root:FindFirstChild("FX")
	task.spawn(function()
		while root.Parent do
			local keep = Quality.Tier <= 0 and 10 or 16
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
				entry[1].Enabled = i <= keep
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
