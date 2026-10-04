--[[
    Player settings (camera mode/look, controls, keybinds, audio...).
    Loaded from the saved profile once, then edited locally and saved back
    to the server a moment after the last change.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Util = require(Shared.Util)
local Net = require(Shared.Net)

local ClientState = require(script.Parent.Parent.ClientState)

local Settings = {
	values = Util.deepCopy(Config.DefaultSettings),
	Changed = Util.Signal.new(),
	Loaded = Util.Signal.new(),
}

local loaded = false
local saveToken = 0

local function scheduleSave()
	saveToken += 1
	local token = saveToken
	task.delay(1.5, function()
		if token == saveToken then
			Net.get("SaveSettings"):FireServer(Settings.values)
		end
	end)
end

function Settings.isLoaded()
	return loaded
end

function Settings.get(key)
	return Settings.values[key]
end

function Settings.set(key, value)
	if Settings.values[key] == value then
		return
	end
	Settings.values[key] = value
	Settings.Changed:Fire(key, value)
	scheduleSave()
end

function Settings.getBinds(device, action)
	local binds = Settings.values.Keybinds[device]
	local list = binds and binds[action]
	if list then
		return list
	end
	local defaults = Config.DefaultKeybinds[device]
	return defaults and defaults[action] or {}
end

function Settings.setBind(device, action, index, keyName)
	local binds = Settings.values.Keybinds
	binds[device] = binds[device] or {}
	local deviceBinds = binds[device]
	-- A key can only do one thing: take it off every action first.
	if keyName then
		for _, other in Config.InputActions do
			local list = deviceBinds[other] or table.clone(Settings.getBinds(device, other))
			local at = table.find(list, keyName)
			while at do
				table.remove(list, at)
				at = table.find(list, keyName)
			end
			deviceBinds[other] = list
		end
	end
	local list = deviceBinds[action] or table.clone(Settings.getBinds(device, action))
	if keyName then
		if index > #list then
			table.insert(list, keyName)
		else
			list[index] = keyName
		end
	elseif list[index] then
		table.remove(list, index)
	end
	deviceBinds[action] = list
	Settings.Changed:Fire("Keybinds", binds)
	scheduleSave()
end

function Settings.resetBinds()
	Settings.values.Keybinds = Util.deepCopy(Config.DefaultKeybinds)
	Settings.Changed:Fire("Keybinds", Settings.values.Keybinds)
	scheduleSave()
end

function Settings.init()
	local function load(profile)
		if loaded or not profile then
			return
		end
		loaded = true
		local saved = Util.deepCopy(profile.Settings or {})
		-- Keybind lists are reconciled per action only: a saved list (even an
		-- empty one) wins, so cleared or moved keys don't come back.
		local savedBinds = type(saved.Keybinds) == "table" and saved.Keybinds or {}
		saved.Keybinds = nil
		Settings.values = Util.reconcile(saved, Config.DefaultSettings)
		local binds = {}
		for device, defaults in Config.DefaultKeybinds do
			local deviceBinds = type(savedBinds[device]) == "table" and savedBinds[device] or {}
			binds[device] = {}
			for action, list in defaults do
				binds[device][action] = deviceBinds[action] or table.clone(list)
			end
			for action, list in deviceBinds do
				binds[device][action] = binds[device][action] or list
			end
		end
		Settings.values.Keybinds = binds
		for key, value in Settings.values do
			Settings.Changed:Fire(key, value)
		end
		Settings.Loaded:Fire()
	end
	ClientState.ProfileChanged:Connect(load)
	load(ClientState.profile)
end

return Settings
