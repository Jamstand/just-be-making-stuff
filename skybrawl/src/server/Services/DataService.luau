--[[
    Loads, holds and saves player profiles.

    Profiles live in memory while the player is in the server; other
    services change them through DataService.update(), which also pushes a
    fresh snapshot to the client. Saves happen on an autosave loop, when the
    player leaves, and on server shutdown.

    If a profile fails to load (DataStore outage, or Studio without API
    access), the player plays with defaults and that profile is never saved,
    so a hiccup can't overwrite real progress.

    Schema v2 adds daily missions (Missions), the ranked season the ratings
    belong to (Season, SeasonStats, SeasonBadge). migrateProfile brings any
    stored profile up to date when it loads: v2 fields, today's missions
    (paying yesterday's done-but-unclaimed ones) and a season soft reset when
    a season ended since the last visit; its notes are toasted once loaded.

    Main.server's PlayerRemoving coordinator calls DataService.onPlayerRemoving
    last, and the save itself is deferred, so every other service's profile
    writes for a leaver (a ranked loss) land first.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Cosmetics = require(Shared.Cosmetics)
local Legends = require(Shared.Legends)
local Missions = require(Shared.Missions)
local Rankings = require(Shared.Rankings)
local Ranks = require(Shared.Ranks)
local Seasons = require(Shared.Seasons)
local Util = require(Shared.Util)
local Net = require(Shared.Net)

local DataService = {}
DataService.ProfileLoaded = Util.Signal.new()
DataService.ProfileChanged = Util.Signal.new()

local profiles = {} -- [Player] = profile
local canSave = {} -- [Player] = boolean
local loading = {} -- [Player] = true while loading
local sessionStart = {} -- [Player] = os.time() when this server took the profile
local lastSettingsSave = {} -- [Player] = os.clock() of the last applied SaveSettings
local legendTokens = {} -- [Player] = { tokens, at } (SelectLegend rate limit)
local pendingSaves = 0
local store = nil
local warnedNoStore = false

-- A profile another server touched this recently is treated as still in use
-- there (usually it's finishing the save from when the player left).
local SESSION_STALE_SECONDS = Config.Data.AutosaveSeconds * 2 + 30

local DEFAULT_PROFILE = {
	Version = 2,
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
	Legend = Legends.Default,
	Missions = Missions.newState(),
	Season = 0, -- id of the season the ratings belong to (0 = not set yet)
	SeasonStats = {
		-- Legends[legendId] = { Wins = n, Played = n } (ranked, this season)
		["1v1"] = { Wins = 0, Losses = 0, Legends = {} },
		["2v2"] = { Wins = 0, Losses = 0, Legends = {} },
	},
	-- SeasonBadge (absent until a season ends): { Season = 1, Name = "Season 1", Tier1v1 = "Gold"?, Tier2v2 = "Silver"? }
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

-- Settings a match reads as it starts. A save that the once-a-second limit
-- drops still updates these, so a match started right after a toggle uses it.
local MATCH_SETTINGS = { "FightAsAvatar" }

function DataService.applyMatchSettings(settings, raw)
	if type(raw) ~= "table" then
		return
	end
	for _, key in MATCH_SETTINGS do
		if type(raw[key]) == "boolean" then
			settings[key] = raw[key]
		end
	end
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

-- Schema v2 ---------------------------------------------------------------

local MAX_STAT = 1e7

local function count(value)
	if type(value) ~= "number" or value ~= value then
		return 0
	end
	return math.clamp(math.floor(value), 0, MAX_STAT)
end

--[[
    { ["1v1"] = { Wins, Losses, Legends }, ["2v2"] = ... } with whole numbers
    in 0..1e7, legend keys that pass Legends.isValid and Wins <= Played per
    legend. Anything else is dropped or zeroed.
]]
function DataService.sanitizeSeasonStats(raw)
	local out = {}
	for _, mode in Rankings.MODES do
		local src = type(raw) == "table" and raw[mode]
		local stats = { Wins = 0, Losses = 0, Legends = {} }
		if type(src) == "table" then
			stats.Wins = count(src.Wins)
			stats.Losses = count(src.Losses)
			if type(src.Legends) == "table" then
				for legendId, entry in src.Legends do
					if Legends.isValid(legendId) and type(entry) == "table" then
						local played = count(entry.Played)
						stats.Legends[legendId] = { Wins = math.min(count(entry.Wins), played), Played = played }
					end
				end
			end
		end
		out[mode] = stats
	end
	return out
end

local function sanitizeBadge(raw)
	if type(raw) ~= "table" or type(raw.Season) ~= "number" or type(raw.Name) ~= "string" then
		return nil
	end
	return {
		Season = raw.Season,
		Name = raw.Name,
		Tier1v1 = if type(raw.Tier1v1) == "string" then raw.Tier1v1 else nil,
		Tier2v2 = if type(raw.Tier2v2) == "string" then raw.Tier2v2 else nil,
	}
end

--[[
    Makes a reconciled profile valid for v2 and current for `now` (unix
    seconds). Mutates it; returns it plus the notes to toast once the player
    is loaded:
      1. Missions, SeasonStats, Season (a non-negative integer, else 0) and
         SeasonBadge (kept only with a numeric Season and a string Name)
         are sanitized
      2. a v1 profile or one without a season joins the current season
         (no reset) and becomes Version 2
      3. Seasons.ensure: soft reset + badge when a season ended since
      4. Missions.ensureDay: today's missions; yesterday's done-but-unclaimed
         ones are paid into Coins and XP
]]
function DataService.migrateProfile(profile, userId, now)
	local notes = {}
	profile.Missions = Missions.sanitize(profile.Missions)
	profile.SeasonStats = DataService.sanitizeSeasonStats(profile.SeasonStats)
	local season = profile.Season
	if type(season) ~= "number" or season ~= season or season < 0 or season == math.huge then
		season = 0
	end
	profile.Season = math.floor(season)
	profile.SeasonBadge = sanitizeBadge(profile.SeasonBadge)

	if type(profile.Version) ~= "number" or profile.Version < 2 or profile.Season == 0 then
		profile.Season = Seasons.current(now).Id
		profile.Version = 2
	end

	local reset, change = Seasons.ensure(profile, now)
	if reset and change then
		local current = Seasons.byId(change.to) or Seasons.current(now)
		table.insert(notes, current.Name .. " has begun! Your ratings were soft-reset.")
	end

	local _, paid = Missions.ensureDay(profile.Missions, Missions.dayIndex(now), userId)
	if paid then
		profile.Coins += paid.coins
		profile.XP += paid.xp
		table.insert(notes, string.format("Mission rewards collected: +%d coins, +%d XP", paid.coins, paid.xp))
	end
	return profile, notes
end

--[[
    Everything a stored profile goes through when it loads (pure): defaults
    filled in, settings sanitized, legend and cosmetics checked, then
    migrateProfile. `data` is whatever the DataStore returned (nil for a new
    player). Returns profile, notes.
]]
function DataService.prepareProfile(data, userId, now)
	local profile = Util.reconcile(type(data) == "table" and data or {}, DEFAULT_PROFILE)
	profile.Settings = DataService.sanitizeSettings(profile.Settings)
	if not Legends.isValid(profile.Legend) then
		profile.Legend = Legends.Default
	end
	for category, id in Cosmetics.Defaults do
		profile.Owned[id] = true
		local equipped = Cosmetics.get(profile.Equipped[category])
		if not equipped or not profile.Owned[equipped.Id] then
			profile.Equipped[category] = id
		end
	end
	return DataService.migrateProfile(profile, userId, now)
end

-- Snapshot ---------------------------------------------------------------

local function seasonStatsView(stats)
	local id, wins, played = Rankings.bestLegend(stats.Legends)
	return {
		wins = stats.Wins,
		losses = stats.Losses,
		bestLegend = if id then { id = id, wins = wins, played = played } else nil,
	}
end

-- The client's copy of a profile (ProfileUpdate / GetProfile). Pure; DataService.snapshot(player) calls it with
-- whether the profile saves and os.time().
function DataService.buildSnapshot(profile, saving, now)
	local level, intoLevel, forNext = Ranks.levelFromXP(profile.XP)
	local tier1 = Ranks.tier(profile.Rating1v1)
	local tier2 = Ranks.tier(profile.Rating2v2)
	local season = Seasons.byId(profile.Season) or Seasons.current(now)
	local badge = profile.SeasonBadge
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
		Legend = profile.Legend,
		Saving = saving == true,
		Missions = Missions.view(profile.Missions, now),
		Season = { id = season.Id, name = season.Name, endsAt = season.endsAt },
		SeasonBadge = if badge
			then { season = badge.Season, name = badge.Name, tier1v1 = badge.Tier1v1, tier2v2 = badge.Tier2v2 }
			else nil,
		SeasonStats = {
			["1v1"] = seasonStatsView(profile.SeasonStats["1v1"]),
			["2v2"] = seasonStatsView(profile.SeasonStats["2v2"]),
		},
	}
end

function DataService.snapshot(player)
	local profile = profiles[player]
	if not profile then
		return nil
	end
	return DataService.buildSnapshot(profile, canSave[player] == true, os.time())
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
		-- Load and claim the profile in one step, so an older server that's
		-- still holding it can't overwrite it afterwards (see saveProfile).
		local attempts = 5
		for attempt = 1, attempts do
			local heldElsewhere = false
			local err
			ok, err = pcall(function()
				ds:UpdateAsync(keyFor(player), function(old)
					data = old
					heldElsewhere = type(old) == "table"
						and old.SessionJob ~= nil
						and old.SessionJob ~= game.JobId
						and os.time() - (old.SessionTime or 0) < SESSION_STALE_SECONDS
					if heldElsewhere and attempt < attempts then
						return nil
					end
					local claimed = type(old) == "table" and old or {}
					claimed.SessionJob = game.JobId
					claimed.SessionTime = os.time()
					return claimed
				end)
			end)
			if ok then
				if not heldElsewhere or attempt == attempts then
					break
				end
				-- Give the other server a moment to finish its last save.
				task.wait(2)
			else
				warn(
					string.format(
						"[DataService] load attempt %d failed for %s: %s",
						attempt,
						player.Name,
						tostring(err)
					)
				)
				task.wait(attempt)
			end
		end
	end
	loading[player] = nil
	if not player.Parent then
		return
	end

	local prepared, profile, notes = pcall(DataService.prepareProfile, data, player.UserId, os.time())
	if not prepared then
		-- Stored data we can't read (corrupt values): play on defaults and never overwrite what is stored.
		warn(string.format("[DataService] couldn't prepare %s's profile: %s", player.Name, tostring(profile)))
		profile, notes = DataService.prepareProfile(nil, player.UserId, os.time())
		ok = false
	end

	profiles[player] = profile
	sessionStart[player] = os.time()
	canSave[player] = ok and ds ~= nil
	if not canSave[player] then
		Net.get("Toast"):FireClient(player, "Progress can't be saved right now. You can still play!", "warn")
	end
	DataService.ProfileLoaded:Fire(player, profile)
	DataService.push(player)
	for _, note in notes do
		Net.get("Toast"):FireClient(player, note, "good")
	end
end

-- `releasing` marks the profile as free for other servers (player left).
local function saveProfile(player, releasing)
	local profile = profiles[player]
	local ds = getStore()
	if not profile or not canSave[player] or not ds then
		return false
	end
	local startedAt = sessionStart[player] or 0
	pendingSaves += 1
	local ok, err
	local takenOver = false
	for attempt = 1, 3 do
		ok, err = pcall(function()
			ds:UpdateAsync(keyFor(player), function(old)
				-- Another server loaded this profile after we did: its copy is
				-- newer, so don't overwrite it.
				if
					type(old) == "table"
					and old.SessionJob
					and old.SessionJob ~= game.JobId
					and (old.SessionTime or 0) > startedAt
				then
					takenOver = true
					return nil
				end
				profile.SessionJob = if releasing then nil else game.JobId
				profile.SessionTime = os.time()
				return profile
			end)
		end)
		if ok then
			break
		end
		warn(string.format("[DataService] save attempt %d failed for %s: %s", attempt, player.Name, tostring(err)))
		task.wait(attempt)
	end
	pendingSaves -= 1
	if takenOver then
		warn("[DataService] skipped saving", player.Name, "- another server has a newer copy")
		canSave[player] = false
	end
	return ok and not takenOver
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

-- SelectLegend: 2 calls a second per player (token bucket, burst 2).
local LEGEND_RATE = 2

local function allowLegendCall(player)
	local now = os.clock()
	local bucket = legendTokens[player]
	if not bucket then
		bucket = { tokens = LEGEND_RATE, at = now }
		legendTokens[player] = bucket
	end
	bucket.tokens = math.min(LEGEND_RATE, bucket.tokens + (now - bucket.at) * LEGEND_RATE)
	bucket.at = now
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

local function selectLegend(player, legendId)
	if not allowLegendCall(player) then
		return false, "Slow down."
	end
	if not Legends.isValid(legendId) then
		return false, "Unknown fighter."
	end
	if not profiles[player] then
		return false, "Your profile is still loading."
	end
	DataService.update(player, function(profile)
		profile.Legend = legendId
	end)
	return true
end

-- Called by Main.server's PlayerRemoving coordinator (last). Never yields: the save is deferred, so the other
-- services' writes for this player (a ranked leaver loss) land first.
function DataService.onPlayerRemoving(player)
	lastSettingsSave[player] = nil
	legendTokens[player] = nil
	task.defer(function()
		saveProfile(player, true)
		profiles[player] = nil
		canSave[player] = nil
		sessionStart[player] = nil
	end)
end

function DataService.init() end

function DataService.start()
	Players.PlayerAdded:Connect(loadProfile)
	for _, player in Players:GetPlayers() do
		task.spawn(loadProfile, player)
	end

	Net.get("GetProfile").OnServerInvoke = function(player)
		local ok, snapshot = pcall(function()
			local profile = profiles[player] or (loading[player] and DataService.waitFor(player, 10))
			if not profile then
				return nil
			end
			return DataService.snapshot(player)
		end)
		if not ok then
			warn("[DataService] GetProfile failed:", snapshot)
			return nil
		end
		return snapshot
	end

	Net.get("SaveSettings").OnServerEvent:Connect(function(player, raw)
		local now = os.clock()
		if lastSettingsSave[player] and now - lastSettingsSave[player] < 1 then
			if profiles[player] then
				DataService.applyMatchSettings(profiles[player].Settings, raw)
			end
			return
		end
		lastSettingsSave[player] = now
		local profile = profiles[player]
		if profile then
			profile.Settings = DataService.sanitizeSettings(raw)
		end
	end)

	-- Fighter select. All legends are free; the choice is read at match start.
	Net.get("SelectLegend").OnServerInvoke = function(player, legendId)
		local ok, result, message = pcall(selectLegend, player, legendId)
		if not ok then
			warn("[DataService] SelectLegend failed:", result)
			return false, "Something went wrong."
		end
		return result, message
	end

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
		for _, player in Players:GetPlayers() do
			task.spawn(saveProfile, player, true)
		end
		-- Also waits for saves already in flight (e.g. the last player leaving).
		task.wait()
		local deadline = os.clock() + 25
		while pendingSaves > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
end

return DataService
