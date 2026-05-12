--!strict
--[[
    Persistent per-player data. Stores coins, gems, upgrade tiers, owned
    passes, and the timestamp of the last daily-reward claim.

    Other server scripts access this through `_G.CoinRush.PlayerData`, which
    is populated near the bottom of this file.

    DataStores require API access. In Studio: Home -> Game Settings ->
    Security -> Enable Studio Access to API Services. Without it, every read
    and write here returns an error and the player just runs with default
    data for the duration of the session (no save).
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local PlayerDataUpdated = ReplicatedStorage.Remotes.PlayerDataUpdated

local store = DataStoreService:GetDataStore(GameConfig.DataStoreName)

_G.CoinRush = _G.CoinRush or {}

type Data = {
	Coins: number,
	Gems: number,
	Upgrades: { [string]: number },
	Passes: { [string]: boolean },
	LastDailyClaim: number,
}

local cache: { [Player]: Data } = {}
local dirty: { [Player]: boolean } = {}
local updatedBindable = Instance.new("BindableEvent")

local function defaultData(): Data
	local upgrades = {}
	for name in pairs(GameConfig.Upgrades) do
		upgrades[name] = 0
	end
	local passes = {}
	for name in pairs(GameConfig.GamePasses) do
		passes[name] = false
	end
	return {
		Coins = 0,
		Gems = 0,
		Upgrades = upgrades,
		Passes = passes,
		LastDailyClaim = 0,
	}
end

local function mergeDefaults(loaded: any): Data
	-- Defensive: an older save may be missing keys we just added.
	local d = defaultData()
	if type(loaded) ~= "table" then return d end
	if type(loaded.Coins) == "number" then d.Coins = loaded.Coins end
	if type(loaded.Gems) == "number" then d.Gems = loaded.Gems end
	if type(loaded.LastDailyClaim) == "number" then d.LastDailyClaim = loaded.LastDailyClaim end
	if type(loaded.Upgrades) == "table" then
		for name, value in pairs(loaded.Upgrades) do
			if type(value) == "number" and d.Upgrades[name] ~= nil then
				d.Upgrades[name] = value
			end
		end
	end
	if type(loaded.Passes) == "table" then
		for name, value in pairs(loaded.Passes) do
			if type(value) == "boolean" and d.Passes[name] ~= nil then
				d.Passes[name] = value
			end
		end
	end
	return d
end

local function key(player: Player): string
	return "Player_" .. tostring(player.UserId)
end

local function pushToClient(player: Player)
	local data = cache[player]
	if data then
		PlayerDataUpdated:FireClient(player, data)
		updatedBindable:Fire(player, data)
	end
end

local function markDirty(player: Player)
	dirty[player] = true
end

local function loadPlayer(player: Player)
	local loaded
	local ok, err = pcall(function()
		loaded = store:GetAsync(key(player))
	end)
	if not ok then
		warn(("[PlayerDataService] GetAsync failed for %s: %s"):format(player.Name, tostring(err)))
	end
	cache[player] = mergeDefaults(loaded)
	dirty[player] = false
	pushToClient(player)
	-- Re-push a couple times in case the client's PlayerDataUpdated listener
	-- wasn't connected yet when we fired the first time. RemoteEvents drop
	-- on the receiving side if there's no listener; this is cheap insurance.
	task.delay(1, function()
		if cache[player] then pushToClient(player) end
	end)
	task.delay(4, function()
		if cache[player] then pushToClient(player) end
	end)
end

local function saveNow(player: Player): boolean
	local data = cache[player]
	if not data then return false end
	if not dirty[player] then return true end
	local ok, err = pcall(function()
		store:SetAsync(key(player), data)
	end)
	if not ok then
		warn(("[PlayerDataService] SetAsync failed for %s: %s"):format(player.Name, tostring(err)))
		return false
	end
	dirty[player] = false
	return true
end

-- Public API ---------------------------------------------------------------

local PlayerData = {}

function PlayerData.Get(player: Player): Data?
	return cache[player]
end

function PlayerData.Increment(player: Player, field: "Coins" | "Gems", delta: number)
	local data = cache[player]
	if not data then return end
	data[field] = math.max(0, data[field] + delta)
	markDirty(player)
	pushToClient(player)
end

function PlayerData.SetUpgradeTier(player: Player, name: string, tier: number)
	local data = cache[player]
	if not data then return end
	if data.Upgrades[name] == nil then return end
	data.Upgrades[name] = tier
	markDirty(player)
	pushToClient(player)
end

function PlayerData.SetPassOwned(player: Player, name: string, owned: boolean)
	local data = cache[player]
	if not data then return end
	if data.Passes[name] == nil then return end
	if data.Passes[name] == owned then return end
	data.Passes[name] = owned
	markDirty(player)
	pushToClient(player)
end

function PlayerData.MarkDailyClaim(player: Player)
	local data = cache[player]
	if not data then return end
	data.LastDailyClaim = os.time()
	markDirty(player)
	pushToClient(player)
end

function PlayerData.Save(player: Player): boolean
	return saveNow(player)
end

function PlayerData.PushToClient(player: Player)
	pushToClient(player)
end

PlayerData.Updated = updatedBindable.Event

_G.CoinRush.PlayerData = PlayerData

-- Lifecycle ----------------------------------------------------------------

Players.PlayerAdded:Connect(loadPlayer)
for _, player in Players:GetPlayers() do
	task.spawn(loadPlayer, player)
end

Players.PlayerRemoving:Connect(function(player)
	saveNow(player)
	cache[player] = nil
	dirty[player] = nil
end)

-- Autosave loop
task.spawn(function()
	while true do
		task.wait(GameConfig.AutosaveSeconds)
		for player in pairs(cache) do
			if dirty[player] then
				saveNow(player)
			end
		end
	end
end)

-- Flush on shutdown. Roblox gives us up to ~30s of BindToClose budget.
game:BindToClose(function()
	if RunService:IsStudio() then return end
	local pending = {}
	for player in pairs(cache) do
		table.insert(pending, player)
	end
	local remaining = #pending
	if remaining == 0 then return end
	local finished = Instance.new("BindableEvent")
	for _, player in pending do
		task.spawn(function()
			saveNow(player)
			remaining -= 1
			if remaining == 0 then
				finished:Fire()
			end
		end)
	end
	finished.Event:Wait()
end)
