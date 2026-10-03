-- Data: ProfileStore (session-locked) persistence + leaderstats, and the SaveSettings remote.
-- Profile.Data layout is TEMPLATE below. Other modules never touch the DataStore directly.
local Players = game:GetService("Players")

local ProfileStore = require(script.Parent:WaitForChild("ProfileStore"))

local Data = {}
local S

local STORE_NAME = "StealASock_v1" -- bump only with a migration; it renames the whole DataStore

local TEMPLATE = {
	cash = 100, -- replaced by EconomyConfig.StartingCash in Init
	rebirths = 0,
	socks = {}, -- { {typeId, side, mutation, stink}, ... } (no gaps - ProfileStore requirement)
	sockdex = {}, -- typeId -> {L = bool, R = bool, S = bool, paired = bool, perfect = bool} (Dex.luau)
	perks = {}, -- Phase 4: cached gamepass perks
	stats = { pairsCompleted = 0, socksStolen = 0, socksLost = 0, cashCollected = 0 },
	upgrades = { Towel = 0, Speed = 0, Lock = 0, Collect = 0 }, -- Item Shop levels (ShopConfig)
	settings = {}, -- SettingsConfig key -> value, only the ones changed from the default
	receipts = {}, -- recent developer-product PurchaseIds, oldest first (Monetize.ProcessReceipt)
	pendingDrops = 0, -- Rare Sock Drops bought while the drawer was full; delivered when a slot frees
	dexClaimed = {}, -- DexConfig milestone key -> true
	items = {}, -- ItemConfig key -> true: items unlocked for good (Items.luau; the Towel is everyone's, never stored)
	loadout = { "", "", "" }, -- the ItemConfig.LoadoutSize items next to the towel in the item bar, "" = empty slot
}

local SETTINGS_GAP = 1 -- seconds between SaveSettings calls per player

local store = nil
local profiles: { [Player]: any } = {}

-- Is `value` allowed for this SettingsConfig entry?
local function validSetting(setting, value: any): boolean
	if setting.kind == "toggle" then
		return type(value) == "boolean"
	elseif setting.kind == "slider" then
		return type(value) == "number" and value >= 0 and value <= 1 -- NaN fails both checks
	elseif setting.kind == "choice" then
		return type(value) == "string" and table.find(setting.choices or {}, value) ~= nil
	end
	return false
end

-- SaveSettings(settings): the changed settings only. Every key must be a SettingsConfig key with
-- a value of the right kind, or nothing is saved. Default values are dropped.
local function saveSettings(player: Player, settings: any)
	if not S.Ready then
		return { ok = false, err = "Starting up…" }
	end
	if type(settings) ~= "table" then
		return { ok = false, err = "Bad request" }
	end
	if not S.RateLimit.Check(player, "saveSettings", SETTINGS_GAP) then
		return { ok = false, err = "Slow down a little!" }
	end
	local profile = profiles[player]
	if not profile then
		return { ok = false, err = "Your drawer isn't ready yet" }
	end
	local Settings = S.Config.Settings
	local clean = {}
	local count = 0
	for key, value in pairs(settings) do
		count += 1
		local setting = type(key) == "string" and Settings.Settings[key]
		if count > #Settings.Order or not setting or not validSetting(setting, value) then
			return { ok = false, err = "Bad request" }
		end
		if value ~= setting.default then
			clean[key] = value
		end
	end
	profile.Data.settings = clean
	return { ok = true }
end

function Data.Init(s)
	S = s
	TEMPLATE.cash = S.Config.Economy.StartingCash
	store = ProfileStore.New(STORE_NAME, TEMPLATE)
	S.Remotes.SaveSettings.OnServerInvoke = function(player: Player, settings: any)
		local ok, result = pcall(saveSettings, player, settings)
		if not ok then
			warn("[Data] SaveSettings failed: " .. tostring(result))
			return { ok = false, err = "Something went wrong - try again" }
		end
		return result
	end
end

local function buildLeaderstats(player: Player, profile)
	local folder = Instance.new("Folder")
	folder.Name = "leaderstats"
	local cash = Instance.new("IntValue")
	cash.Name = "Cash"
	cash.Value = math.floor(profile.Data.cash)
	cash.Parent = folder
	local rebirths = Instance.new("IntValue")
	rebirths.Name = "Rebirths"
	rebirths.Value = profile.Data.rebirths
	rebirths.Parent = folder
	folder.Parent = player
end

-- Yields. Returns true when the profile is active; false if the player was kicked or left.
function Data.Load(player: Player): boolean
	local profile = store:StartSessionAsync("p_" .. player.UserId, {
		Cancel = function()
			return player.Parent ~= Players
		end,
	})
	if profile == nil then
		player:Kick("Your sock drawer couldn't be loaded. Please rejoin!")
		return false
	end
	profile:AddUserId(player.UserId)
	profile:Reconcile()
	profile.OnSessionEnd:Connect(function()
		if profiles[player] == profile then
			profiles[player] = nil
			player:Kick("Your drawer was opened on another server. Please rejoin!")
		end
	end)
	if player.Parent ~= Players then
		profile:EndSession()
		return false
	end
	profiles[player] = profile
	buildLeaderstats(player, profile)
	return true
end

function Data.Get(player: Player)
	return profiles[player]
end

function Data.Release(player: Player)
	local profile = profiles[player]
	if profile then
		profiles[player] = nil
		profile:EndSession()
	end
end

function Data.SyncLeaderstats(player: Player)
	local profile = profiles[player]
	local stats = player:FindFirstChild("leaderstats")
	if not profile or not stats then
		return
	end
	local cash = stats:FindFirstChild("Cash")
	if cash then
		cash.Value = math.floor(profile.Data.cash)
	end
	local rebirths = stats:FindFirstChild("Rebirths")
	if rebirths then
		rebirths.Value = profile.Data.rebirths
	end
end

function Data.GetCash(player: Player): number
	local profile = profiles[player]
	return if profile then profile.Data.cash else 0
end

function Data.AddCash(player: Player, amount: number)
	local profile = profiles[player]
	if not profile or amount <= 0 then
		return
	end
	profile.Data.cash += amount
	profile.Data.stats.cashCollected += amount
	Data.SyncLeaderstats(player)
end

-- Returns true and deducts when the player can afford it.
function Data.TrySpend(player: Player, amount: number): boolean
	local profile = profiles[player]
	if not profile or amount < 0 or profile.Data.cash < amount then
		return false
	end
	profile.Data.cash -= amount
	Data.SyncLeaderstats(player)
	return true
end

return Data
