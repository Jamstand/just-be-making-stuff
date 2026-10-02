-- ClientSettings: the player's settings on this client (SettingsConfig). Starts at the defaults,
-- takes the saved values from the first State the server sends, applies the ones the UI kit owns
-- (UI size, reduce motion, volumes) and tells everyone else through Changed. Set() saves back to
-- the profile through the SaveSettings remote (debounced, only values that differ from the default).
--
-- Other modules: read with ClientSettings.Get(key) and listen with
-- ClientSettings.Changed:Connect(function(key, value) ... end) - it also fires once per key on load.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SettingsConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("SettingsConfig"))
local Theme = require(script.Parent:WaitForChild("Theme"))
local Anim = require(script.Parent:WaitForChild("Anim"))
local UISound = require(script.Parent:WaitForChild("UISound"))

local ClientSettings = {}

local changedEvent = Instance.new("BindableEvent")
ClientSettings.Changed = changedEvent.Event

local values = {} :: { [string]: any }
for key, s in pairs(SettingsConfig.Settings) do
	values[key] = s.default
end

local loaded = false
local dirty = false
local saveToken = 0

-- the settings the UI kit applies itself
local function apply(key: string)
	local v = values[key]
	if key == "uiScale" then
		Theme.SetUserScale(SettingsConfig.UIScales[v] or 1)
	elseif key == "reduceMotion" then
		Anim.Reduced = v == true
	elseif key == "musicVolume" or key == "sfxVolume" then
		UISound.SetVolumes(values.musicVolume, values.sfxVolume)
	end
end

local function valid(key: string, value: any): boolean
	local s = SettingsConfig.Settings[key]
	if not s then
		return false
	end
	if s.kind == "toggle" then
		return type(value) == "boolean"
	elseif s.kind == "slider" then
		return type(value) == "number" and value >= 0 and value <= 1
	elseif s.kind == "choice" then
		return type(value) == "string" and table.find(s.choices or {}, value) ~= nil
	end
	return false
end

function ClientSettings.Get(key: string): any
	return values[key]
end

local function save()
	saveToken += 1
	local token = saveToken
	task.delay(1.5, function()
		if token ~= saveToken then
			return -- a newer change restarts the wait
		end
		local out = {}
		for key, s in pairs(SettingsConfig.Settings) do
			if values[key] ~= s.default then
				out[key] = values[key]
			end
		end
		local remote = ReplicatedStorage:WaitForChild("Remotes"):FindFirstChild("SaveSettings")
		if remote and remote:IsA("RemoteFunction") then
			local ok = pcall(function()
				remote:InvokeServer(out)
			end)
			if ok and token == saveToken then
				dirty = false
			end
		end
	end)
end

-- Changes a setting: applies it now, tells listeners, saves it a moment later.
function ClientSettings.Set(key: string, value: any)
	if not valid(key, value) or values[key] == value then
		return
	end
	values[key] = value
	dirty = true
	apply(key)
	changedEvent:Fire(key, value)
	save()
end

-- The saved settings from the server's State. Only the first State counts: after that this client
-- is the one changing them, so later States can't undo a change that is still being saved.
function ClientSettings.Load(saved: { [string]: any }?)
	if loaded or dirty or type(saved) ~= "table" then
		return
	end
	loaded = true
	for key, s in pairs(SettingsConfig.Settings) do
		local v = saved[key]
		values[key] = if v ~= nil and valid(key, v) then v else s.default
		apply(key)
		changedEvent:Fire(key, values[key])
	end
end

-- before the first State arrives the defaults apply
for key in pairs(values) do
	apply(key)
end

return ClientSettings
