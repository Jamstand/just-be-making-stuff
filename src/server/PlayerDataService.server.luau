-- Persistent per-player data: currencies, upgrades, daily reward, owned passes.
-- In-memory snapshot is the source of truth during a session; we save on
-- a 60s autosave cadence and on PlayerRemoving. Other services read/write
-- through the API exposed on _G.PlayerDataService.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local DataUpdated = ReplicatedStorage.Remotes.DataUpdated

local store = DataStoreService:GetDataStore(GameConfig.DataStoreName)

local DEFAULTS = {
	Coins = 0,
	Gems = 0,
	Upgrades = { Speed = 0, Jump = 0, Multiplier = 0, Magnet = 0 },
	OwnedPasses = {},
	LastDailyClaim = 0,
	TotalCoinsCollected = 0,
}

local cache: { [number]: any } = {}
local PlayerDataService = {}

local function deepCopy(t)
	if type(t) ~= "table" then return t end
	local copy = {}
	for k, v in t do copy[k] = deepCopy(v) end
	return copy
end

local function mergeDefaults(data)
	for key, default in DEFAULTS do
		if data[key] == nil then
			data[key] = deepCopy(default)
		elseif type(default) == "table" and type(data[key]) == "table" then
			for k, v in default do
				if data[key][k] == nil then data[key][k] = deepCopy(v) end
			end
		end
	end
	return data
end

local function load(player: Player)
	local key = "u_" .. player.UserId
	local ok, result = pcall(function() return store:GetAsync(key) end)
	local data = (ok and type(result) == "table") and result or deepCopy(DEFAULTS)
	if not ok then
		warn(("[PlayerData] load failed for %s: %s"):format(player.Name, tostring(result)))
	end
	mergeDefaults(data)
	cache[player.UserId] = data
	return data
end

local function save(player: Player)
	local data = cache[player.UserId]
	if not data then return end
	local key = "u_" .. player.UserId
	local ok, err = pcall(function()
		store:UpdateAsync(key, function() return data end)
	end)
	if not ok then
		warn(("[PlayerData] save failed for %s: %s"):format(player.Name, tostring(err)))
	end
end

function PlayerDataService.Get(player: Player)
	return cache[player.UserId]
end

function PlayerDataService.Push(player: Player)
	local data = cache[player.UserId]
	if not data then return end
	DataUpdated:FireClient(player, data)
end

function PlayerDataService.AddCoins(player: Player, amount: number)
	local data = cache[player.UserId]
	if not data then return end
	data.Coins += amount
	if amount > 0 then data.TotalCoinsCollected += amount end
	local leaderstats = player:FindFirstChild("leaderstats")
	if leaderstats then
		local stat = leaderstats:FindFirstChild("Coins")
		if stat then stat.Value = data.Coins end
	end
	PlayerDataService.Push(player)
end

function PlayerDataService.AddGems(player: Player, amount: number)
	local data = cache[player.UserId]
	if not data then return end
	data.Gems += amount
	local leaderstats = player:FindFirstChild("leaderstats")
	if leaderstats then
		local stat = leaderstats:FindFirstChild("Gems")
		if stat then stat.Value = data.Gems end
	end
	PlayerDataService.Push(player)
end

function PlayerDataService.SpendCoins(player: Player, amount: number): boolean
	local data = cache[player.UserId]
	if not data or data.Coins < amount then return false end
	data.Coins -= amount
	local leaderstats = player:FindFirstChild("leaderstats")
	if leaderstats then
		local stat = leaderstats:FindFirstChild("Coins")
		if stat then stat.Value = data.Coins end
	end
	PlayerDataService.Push(player)
	return true
end

function PlayerDataService.SpendGems(player: Player, amount: number): boolean
	local data = cache[player.UserId]
	if not data or data.Gems < amount then return false end
	data.Gems -= amount
	local leaderstats = player:FindFirstChild("leaderstats")
	if leaderstats then
		local stat = leaderstats:FindFirstChild("Gems")
		if stat then stat.Value = data.Gems end
	end
	PlayerDataService.Push(player)
	return true
end

function PlayerDataService.SetUpgradeTier(player: Player, upgradeName: string, tier: number)
	local data = cache[player.UserId]
	if not data then return end
	data.Upgrades[upgradeName] = tier
	PlayerDataService.Push(player)
end

function PlayerDataService.MarkPassOwned(player: Player, passKey: string)
	local data = cache[player.UserId]
	if not data then return end
	data.OwnedPasses[passKey] = true
	PlayerDataService.Push(player)
end

function PlayerDataService.SetLastDailyClaim(player: Player, timestamp: number)
	local data = cache[player.UserId]
	if not data then return end
	data.LastDailyClaim = timestamp
	PlayerDataService.Push(player)
end

Players.PlayerAdded:Connect(function(player)
	load(player)
	PlayerDataService.Push(player)
end)

for _, player in Players:GetPlayers() do
	task.spawn(function()
		load(player)
		PlayerDataService.Push(player)
	end)
end

Players.PlayerRemoving:Connect(function(player)
	save(player)
	cache[player.UserId] = nil
end)

game:BindToClose(function()
	for _, player in Players:GetPlayers() do save(player) end
	if RunService:IsStudio() then task.wait(1) else task.wait(5) end
end)

task.spawn(function()
	while true do
		task.wait(GameConfig.AutosaveSeconds)
		for _, player in Players:GetPlayers() do save(player) end
	end
end)

_G.PlayerDataService = PlayerDataService
