--[[
    Loads, holds and saves player profiles.

    Profiles live in memory while the player is in the server; other
    services change them through DataService.update(), which also pushes a
    fresh snapshot to the client. Saves happen on an autosave loop, when the
    player leaves, and on server shutdown.

    If a profile fails to load (DataStore outage, or Studio without API
    access), the player plays with defaults and that profile is never saved,
    so a hiccup can't overwrite real progress.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Cosmetics = require(Shared.Cosmetics)
local Ranks = require(Shared.Ranks)
local Util = require(Shared.Util)
local Net = require(Shared.Net)

local DataService = {}
DataService.ProfileLoaded = Util.Signal.new()
DataService.ProfileChanged = Util.Signal.new()

local profiles = {} -- [Player] = profile
local canSave = {} -- [Player] = boolean
local loading = {} -- [Player] = true while loading
local store = nil
local warnedNoStore = false

local DEFAULT_PROFILE = {
	Version = 1,
	Coins = 0,
	XP = 0,
	Rating1v1 = Config.Ranked.StartRating,
	Rating2v2 = Config.Ranked.StartRating,
	Peak1v1 = Config.Ranked.StartRating,
	Peak2v2 = Config.Ranked.StartRating,
	Ranked1v1Played = 0,
	Ranked2v2Played = 0,
	Matches = 0,
	Wins = 0,
	Losses = 0,
	KOs = 0,
	Falls = 0,
	DamageDealt = 0,
	Owned = {},
	Equipped = Util.deepCopy(Cosmetics.Defaults),
	Settings = {},
}
for _, id in Cosmetics.Defaults do
	DEFAULT_PROFILE.Owned[id] = true
end

local function getStore()
	if store then
		return store
	end
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(Config.Data.StoreName)
	end)
	if ok then
		store = result
		return store
	end
	if not warnedNoStore then
		warnedNoStore = true
		warn("[DataService] DataStores unavailable; progress won't save this session:", result)
	end
	return nil
end

local function keyFor(player)
	return "u_" .. player.UserId
end

-- Settings --------------------------------------------------------------

local function validKeyName(name)
	if type(name) ~= "string" or #name > 24 then
		return false
	end
	local ok, value = pcall(function()
		return Enum.KeyCode[name]
	end)
	if ok and value then
		return true
	end
	ok, value = pcall(function()
		return Enum.UserInputType[name]
	end)
	return ok and value ~= nil
end

local function sanitizeKeybinds(binds)
	local out = {}
	if type(binds) ~= "table" then
		return out
	end
	for _, device in { "Keyboard", "Gamepad" } do
		local src = binds[device]
		if type(src) == "table" then
			local dst = {}
			for _, action in Config.InputActions do
				local list = src[action]
				if type(list) == "table" then
					local clean = {}
					for i = 1, math.min(#list, 3) do
						if validKeyName(list[i]) then
							table.insert(clean, list[i])
						end
					end
					dst[action] = clean
				end
			end
			out[device] = dst
		end
	end
	return out
end

-- Keeps only known settings with the right types.
function DataService.sanitizeSettings(raw)
	local out = {}
	if type(raw) ~= "table" then
		return out
	end
	for key, default in Config.DefaultSettings do
		local value = raw[key]
		if key == "Keybinds" then
			if value ~= nil then
				out.Keybinds = sanitizeKeybinds(value)
			end
		elseif value ~= nil and type(value) == type(default) then
			if type(value) == "string" then
				if #value <= 32 then
					out[key] = value
				end
			elseif type(value) == "number" then
				if value == value and math.abs(value) < 1000 then
					out[key] = value
				end
			else
				out[key] = value
			end
		end
	end
	return out
end

-- Snapshot ---------------------------------------------------------------

function DataService.snapshot(player)
	local profile = profiles[player]
	if not profile then
		return nil
	end
	local level, intoLevel, forNext = Ranks.levelFromXP(profile.XP)
	local tier1 = Ranks.tier(profile.Rating1v1)
	local tier2 = Ranks.tier(profile.Rating2v2)
	return {
		Coins = profile.Coins,
		XP = profile.XP,
		Level = level,
		XPInLevel = intoLevel,
		XPForNext = forNext,
		Rating1v1 = profile.Rating1v1,
		Rating2v2 = profile.Rating2v2,
		Peak1v1 = profile.Peak1v1,
		Peak2v2 = profile.Peak2v2,
		Tier1v1 = tier1.Name,
		Tier2v2 = tier2.Name,
		Ranked1v1Played = profile.Ranked1v1Played,
		Ranked2v2Played = profile.Ranked2v2Played,
		Matches = profile.Matches,
		Wins = profile.Wins,
		Losses = profile.Losses,
		KOs = profile.KOs,
		Falls = profile.Falls,
		DamageDealt = profile.DamageDealt,
		Owned = table.clone(profile.Owned),
		Equipped = table.clone(profile.Equipped),
		Settings = Util.deepCopy(profile.Settings),
		Saving = canSave[player] == true,
	}
end

function DataService.push(player)
	local snapshot = DataService.snapshot(player)
	if snapshot then
		Net.get("ProfileUpdate"):FireClient(player, snapshot)
	end
end

-- Load / save -------------------------------------------------------------

local function loadProfile(player)
	loading[player] = true
	local data = nil
	local ok = false
	local ds = getStore()
	if ds then
		for attempt = 1, 3 do
			ok, data = pcall(function()
				return ds:GetAsync(keyFor(player))
			end)
			if ok then
				break
			end
			warn(string.format("[DataService] load attempt %d failed for %s: %s", attempt, player.Name, tostring(data)))
			task.wait(attempt)
		end
	end
	loading[player] = nil
	if not player.Parent then
		return
	end

	local profile = Util.reconcile(type(data) == "table" and data or {}, DEFAULT_PROFILE)
	profile.Settings = DataService.sanitizeSettings(profile.Settings)
	for category, id in Cosmetics.Defaults do
		profile.Owned[id] = true
		local equipped = Cosmetics.get(profile.Equipped[category])
		if not equipped or not profile.Owned[equipped.Id] then
			profile.Equipped[category] = id
		end
	end

	profiles[player] = profile
	canSave[player] = ok and ds ~= nil
	if not canSave[player] then
		Net.get("Toast"):FireClient(player, "Progress can't be saved right now. You can still play!", "warn")
	end
	DataService.ProfileLoaded:Fire(player, profile)
	DataService.push(player)
end

local function saveProfile(player)
	local profile = profiles[player]
	local ds = getStore()
	if not profile or not canSave[player] or not ds then
		return false
	end
	local ok, err
	for attempt = 1, 3 do
		ok, err = pcall(function()
			ds:UpdateAsync(keyFor(player), function()
				return profile
			end)
		end)
		if ok then
			return true
		end
		warn(string.format("[DataService] save attempt %d failed for %s: %s", attempt, player.Name, tostring(err)))
		task.wait(attempt)
	end
	return false
end

-- API ---------------------------------------------------------------------

function DataService.get(player)
	return profiles[player]
end

function DataService.waitFor(player, timeout)
	local deadline = os.clock() + (timeout or 15)
	while not profiles[player] and player.Parent and os.clock() < deadline do
		task.wait(0.1)
	end
	return profiles[player]
end

-- Runs fn(profile) and pushes the new snapshot. Returns fn's results.
function DataService.update(player, fn)
	local profile = profiles[player]
	if not profile then
		return nil
	end
	local results = table.pack(fn(profile))
	DataService.ProfileChanged:Fire(player, profile)
	DataService.push(player)
	return table.unpack(results, 1, results.n)
end

function DataService.isSaving(player)
	return canSave[player] == true
end

function DataService.init() end

function DataService.start()
	Players.PlayerAdded:Connect(loadProfile)
	for _, player in Players:GetPlayers() do
		task.spawn(loadProfile, player)
	end

	Players.PlayerRemoving:Connect(function(player)
		-- Deferred so match/room cleanup (which may record a loss) runs first.
		task.defer(function()
			saveProfile(player)
			profiles[player] = nil
			canSave[player] = nil
		end)
	end)

	Net.get("GetProfile").OnServerInvoke = function(player)
		local profile = profiles[player] or (loading[player] and DataService.waitFor(player, 10))
		if not profile then
			return nil
		end
		return DataService.snapshot(player)
	end

	local lastSettingsSave = {}
	Net.get("SaveSettings").OnServerEvent:Connect(function(player, raw)
		local now = os.clock()
		if lastSettingsSave[player] and now - lastSettingsSave[player] < 1 then
			return
		end
		lastSettingsSave[player] = now
		local profile = profiles[player]
		if profile then
			profile.Settings = DataService.sanitizeSettings(raw)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastSettingsSave[player] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(Config.Data.AutosaveSeconds)
			for _, player in Players:GetPlayers() do
				task.spawn(saveProfile, player)
			end
		end
	end)

	game:BindToClose(function()
		if RunService:IsStudio() and not getStore() then
			return
		end
		local pending = 0
		for _, player in Players:GetPlayers() do
			pending += 1
			task.spawn(function()
				saveProfile(player)
				pending -= 1
			end)
		end
		local deadline = os.clock() + 25
		while pending > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
end

return DataService
