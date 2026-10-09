--[[
    Seasonal ranked ladders and the Rankings screen's data (menus design
    4.10). There is no in-world board.

    One OrderedDataStore per season and mode (Rankings.storeName). A ranked
    result (ProgressionService) calls submit, which queues the player's
    packed value (rating, main legend, wins, losses: Rankings.encode) under
    the store of the profile's season; the queue is written every
    Config.Rankings.FlushSeconds and on shutdown, while the write budget
    lasts (leftovers wait for the next flush).

    GetRankings({ mode, scope, season? }) answers with RankingsData:
      Global   the season's top Config.Rankings.TopSize from one
               GetSortedAsync page (the current season refreshes every
               RefreshSeconds in the background; past seasons are fetched
               on demand and kept PastSeasonCacheSeconds). A store is
               fetched at most once per GlobalCooldown (server-wide); other
               requests get the cached copy. A skipped or failed fetch keeps
               the older rows with status "partial". Names come from one
               UserService call per fetch, cached per user.
      Friends  you and your friends (FriendCache) who have a rating that
               season: friends on this server from their live profiles
               (current season, no DataStore call), the others (at most
               FriendsMax) from their stored entry (GetAsync in parallel
               batches; values shared by every requester for
               FriendsCacheSeconds, a read already in flight is waited for;
               stopping at FriendsTimeout or when the read budget falls to
               FriendsReserve: status "partial").
    Your card comes from your live profile (current season) or your stored
    entry (past seasons). Without DataStores (Studio without API access:
    no store, or reads that throw in Studio) the rows are the players on
    this server (status "unavailable").

    Every DataStore call is in pcall and checks its request budget first
    (see mayCall). Fetches already in flight are shared: a request waits for
    them (at most 10 s) instead of starting another.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserService = game:GetService("UserService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Rankings = require(Shared.Rankings)
local RankingsView = require(Shared.RankingsView)
local Seasons = require(Shared.Seasons)
local Net = require(Shared.Net)

local FriendCache = require(script.Parent.FriendCache)

local LeaderboardService = {}
local services

local FETCH_WAIT = 10 -- seconds a request waits for a fetch already in flight
local NAME_CACHE_MAX = 2000 -- the name cache starts over beyond this many users

--[[
    Request budgets. OrderedDataStore calls have their own request types
    (OrderedRead: GetAsync, OrderedList: GetSortedAsync, OrderedWrite:
    SetAsync); the docs call the older names the design used (GetAsync,
    GetSortedAsync, SetIncrementSortedAsync) legacy, and say a query for
    OrderedList returns 0. So each kind asks its types in this order and
    the first positive answer is the budget. A kind whose types have never
    answered above 0 on this server has an unknown budget: its calls then
    go through our own server-wide limit (FALLBACK_PER_MINUTE a minute, the
    same as burst, under each type's base limit) instead of stopping. Once a
    kind has answered, 0 means spent.
]]
local BUDGET_TYPES = {
	read = { "OrderedRead", "GetAsync" },
	list = { "OrderedList", "GetSortedAsync" },
	write = { "OrderedWrite", "SetIncrementSortedAsync" },
}
-- Base limits a minute per server: OrderedRead 60, OrderedList 5, OrderedWrite 30 (each plus more per player).
-- The background refresh (2 GetSortedAsync calls per RefreshSeconds) always goes out; `list` limits the rest.
local FALLBACK_PER_MINUTE = { read = 30, list = 2, write = 20 }

local RATING_KEYS = {
	["1v1"] = "Rating1v1",
	["2v2"] = "Rating2v2",
}

local stores = {} -- [storeName] = OrderedDataStore
local noDataStore = false -- GetOrderedDataStore failed: no DataStores on this server
local denied = {} -- [storeName] = true: a read threw in Studio (no API access); cleared by a read that works
local warned = {} -- [key] = true (each problem is logged once)
local requestTypes = {} -- [kind] = { EnumItem } (the BUDGET_TYPES this engine has)
local reported = {} -- [kind] = true once one of its types answered a budget above 0
local fallback = {} -- [kind] = { tokens, at } (our own limit while the budget is unknown)
local pending = {} -- [storeName] = { [userId] = packed value } waiting for the flush
local flushing = false
local global = {} -- [storeName] = { entries, status, updatedAt, fetchedAt?, attemptedAt?, fetching }
local values = {} -- [storeName] = { [userId] = { value = packed | false (no entry), at = os.clock() } }
local reading = {} -- [storeName] = { [userId] = true } (GetAsync calls in flight, shared by every requester)
local failed = {} -- [storeName] = { [userId] = os.clock() } (reads that threw: not retried for GlobalCooldown)
local friends = {} -- [Player] = { [storeName] = { rows, status, updatedAt, ownValue?, fetchedAt?, fetching } }
local names = {} -- [userId] = { name, username }
local nameCount = 0

local function warnOnce(key, ...)
	if not warned[key] then
		warned[key] = true
		warn(...)
	end
end

-- FriendCache is a plain module; Main also hands it out as services.FriendCache (tests replace it there).
local function friendCache()
	return services and services.FriendCache or FriendCache
end

local function getStore(name)
	if stores[name] then
		return stores[name]
	end
	if noDataStore then
		return nil
	end
	local ok, result = pcall(function()
		return DataStoreService:GetOrderedDataStore(name)
	end)
	if ok and result then
		stores[name] = result
		return result
	end
	noDataStore = true
	warnOnce("store", "[LeaderboardService] ranked boards unavailable (no DataStore access):", result)
	return nil
end

-- A read of `name` threw: logged once; in Studio it almost always means no API access, so the store reads as
-- unavailable until a read works.
local function readFailed(name, what, err)
	warnOnce(what .. " " .. name, "[LeaderboardService] couldn't read", name, err)
	if RunService:IsStudio() then
		denied[name] = true
	end
end

-- Budgets ----------------------------------------------------------------------------

local function typesOf(kind)
	local list = requestTypes[kind]
	if not list then
		list = {}
		for _, typeName in BUDGET_TYPES[kind] do
			local ok, item = pcall(function()
				return (Enum.DataStoreRequestType :: any)[typeName]
			end)
			if ok and item then
				table.insert(list, item)
			end
		end
		requestTypes[kind] = list
	end
	return list
end

-- The engine's budget for `kind` (see BUDGET_TYPES): a number, or nil while it is unknown.
local function budget(kind)
	for _, requestType in typesOf(kind) do
		local ok, value = pcall(function()
			return DataStoreService:GetRequestBudgetForRequestType(requestType)
		end)
		if ok and type(value) == "number" and value > 0 then
			reported[kind] = true
			return value
		end
	end
	return if reported[kind] then 0 else nil
end

--[[
    Whether a `kind` call may go out now: with a known budget, when it is
    above `floor`; with an unknown one, when our own limit has a token left
    (`force`: the fixed-rate background refresh goes out regardless).
]]
local function mayCall(kind, floor, force)
	local known = budget(kind)
	if known then
		return known > floor
	end
	warnOnce("budget " .. kind, "[LeaderboardService] no", kind, "request budget reported; using a fixed limit")
	local rate = FALLBACK_PER_MINUTE[kind]
	local now = os.clock()
	local bucket = fallback[kind]
	if not bucket then
		bucket = { tokens = rate, at = now }
		fallback[kind] = bucket
	end
	bucket.tokens = math.min(rate, bucket.tokens + (now - bucket.at) * rate / 60)
	bucket.at = now
	if bucket.tokens >= 1 then
		bucket.tokens -= 1
		return true
	end
	return force == true
end

local function waitForFetch(entry)
	local deadline = os.clock() + FETCH_WAIT
	while entry.fetching and os.clock() < deadline do
		task.wait(0.1)
	end
end

-- Values (friends' and your own stored entries) --------------------------------

local function remember(storeName, userId, value)
	local list = values[storeName]
	if not list then
		list = {}
		values[storeName] = list
	end
	list[userId] = { value = value, at = os.clock() }
end

-- The stored packed value: a number, false (no entry), or nil (not known or too old).
local function cachedValue(storeName, userId)
	local list = values[storeName]
	local known = list and list[userId]
	if not known or os.clock() - known.at >= Config.Rankings.FriendsCacheSeconds then
		return nil
	end
	return known.value
end

-- One GetAsync (run in its own thread); `inFlight` is reading[storeName].
local function readOne(store, storeName, userId, inFlight)
	local ok, value = pcall(function()
		return store:GetAsync(tostring(userId))
	end)
	if ok then
		remember(storeName, userId, tonumber(value) or false)
		denied[storeName] = nil
	else
		failed[storeName] = failed[storeName] or {}
		failed[storeName][userId] = os.clock()
		readFailed(storeName, "get", value)
	end
	inFlight[userId] = nil
end

--[[
    Reads the entries of `ids` the value cache doesn't know: GetAsync in
    parallel batches of FriendsBatch while the read budget is above
    FriendsReserve, until FriendsTimeout. Ids another request is already
    reading are waited for, not read twice; ids whose read threw less than
    GlobalCooldown ago are not retried. Returns whether every one is known.
]]
local function readValues(storeName, ids)
	local R = Config.Rankings
	local now = os.clock()
	local inFlight = reading[storeName]
	if not inFlight then
		inFlight = {}
		reading[storeName] = inFlight
	end
	local errors = failed[storeName]
	local wanted, missing = {}, {}
	for _, id in ids do
		if cachedValue(storeName, id) == nil then
			table.insert(wanted, id)
			local failedAt = errors and errors[id]
			if not inFlight[id] and not (failedAt and now - failedAt < R.GlobalCooldown) then
				table.insert(missing, id)
			end
		end
	end
	if #wanted == 0 then
		return true
	end
	local store = getStore(storeName)
	if not store then
		return false
	end
	local deadline = now + R.FriendsTimeout
	local function waitFor(list)
		while os.clock() < deadline do
			local busy = false
			for _, id in list do
				if inFlight[id] then
					busy = true
					break
				end
			end
			if not busy then
				return
			end
			task.wait(0.05)
		end
	end

	local stopped = false
	local first = 1
	while first <= #missing and not stopped and os.clock() < deadline do
		local batch = {}
		for i = first, math.min(#missing, first + R.FriendsBatch - 1) do
			local id = missing[i]
			-- (another request may have read it, or started to, while this one waited)
			if not inFlight[id] and cachedValue(storeName, id) == nil then
				if not mayCall("read", R.FriendsReserve) then
					stopped = true
					break
				end
				inFlight[id] = true
				table.insert(batch, id)
				task.spawn(readOne, store, storeName, id, inFlight)
			end
		end
		waitFor(batch)
		first += R.FriendsBatch
	end
	waitFor(wanted) -- reads other requests started
	for _, id in wanted do
		if cachedValue(storeName, id) == nil then
			return false
		end
	end
	return true
end

-- Names ------------------------------------------------------------------------

-- Fills `names` for `ids`: players on this server directly, the rest with one UserService call (yields).
local function resolveNames(ids)
	if nameCount + #ids > NAME_CACHE_MAX then
		-- start over first, so every name of this call lands in the new cache
		table.clear(names)
		nameCount = 0
	end
	local missing = {}
	for _, id in ids do
		if not names[id] then
			local player = Players:GetPlayerByUserId(id)
			if player then
				names[id] = { name = player.DisplayName, username = player.Name }
				nameCount += 1
			elseif id > 0 then
				table.insert(missing, id)
			end
		end
	end
	if #missing == 0 then
		return
	end
	local ok, infos = pcall(function()
		return UserService:GetUserInfosByUserIdsAsync(missing)
	end)
	if not ok or type(infos) ~= "table" then
		-- RankingsView falls back to "Player <id>"; a later fetch asks again.
		warnOnce("names", "[LeaderboardService] couldn't load player names:", infos)
		return
	end
	for _, info in infos do
		if type(info) == "table" and type(info.Id) == "number" and not names[info.Id] then
			names[info.Id] = { name = tostring(info.DisplayName), username = tostring(info.Username) }
			nameCount += 1
		end
	end
end

-- Rows from live profiles -------------------------------------------------------

local function statsOf(profile, mode)
	local stats = type(profile.SeasonStats) == "table" and profile.SeasonStats[mode] or nil
	return type(stats) == "table" and stats or {}
end

-- A RankingsView.friendsRows item from a profile of a player on this server.
local function liveItem(player, profile, mode)
	local stats = statsOf(profile, mode)
	return {
		userId = player.UserId,
		name = player.DisplayName,
		username = player.Name,
		rating = profile[RATING_KEYS[mode]],
		wins = stats.Wins or 0,
		losses = stats.Losses or 0,
		main = (Rankings.bestLegend(stats.Legends)),
	}
end

--[[
    Whether a live profile has a ranked result in `mode` in season
    `seasonId` (what gives a player an entry in that season's store): a win
    or loss, or a game played with a legend (draws count only there).
]]
local function hasRating(profile, mode, seasonId)
	if profile.Season ~= seasonId then
		return false
	end
	local stats = statsOf(profile, mode)
	if (tonumber(stats.Wins) or 0) + (tonumber(stats.Losses) or 0) > 0 then
		return true
	end
	for _, legend in type(stats.Legends) == "table" and stats.Legends or {} do
		if type(legend) == "table" and (tonumber(legend.Played) or 0) > 0 then
			return true
		end
	end
	return false
end

--[[
    Without DataStores: the players on this server. With `friendIds`, only
    you and those friends who have a rating this season (as Friends does
    with stores).
]]
local function serverRows(player, mode, seasonId, isCurrent, friendIds)
	if not isCurrent then
		return {} -- past seasons live only in the stores
	end
	local allowed = nil
	if friendIds then
		allowed = {}
		for _, id in friendIds do
			allowed[id] = true
		end
	end
	local list = {}
	for _, other in Players:GetPlayers() do
		local profile = services.DataService.get(other)
		local listed = other == player
			or not allowed
			or (allowed[other.UserId] and profile and hasRating(profile, mode, seasonId))
		if profile and listed then
			table.insert(list, liveItem(other, profile, mode))
		end
	end
	return RankingsView.friendsRows(list, player.UserId)
end

-- Global -------------------------------------------------------------------------

local function globalEntry(name)
	local entry = global[name]
	if not entry then
		entry = { entries = {}, status = "partial", updatedAt = 0, fetching = false }
		global[name] = entry
	end
	return entry
end

--[[
    Fetches a store's top list into `entry` (yields; the caller checked that
    no fetch is in flight). `background`: the fixed-rate refresh, which goes
    out even while the list budget is unknown. A fetch that is skipped
    (budget) or fails keeps the older rows with status "partial" ("unavailable"
    when the store can't be read in Studio).
]]
local function fetchGlobal(entry, name, background)
	entry.fetching = true
	entry.attemptedAt = os.clock()
	local ok, err = pcall(function()
		local store = getStore(name)
		if not store then
			entry.status = "unavailable"
			return
		end
		if not mayCall("list", Config.Rankings.MinBudget, background) then
			entry.status = "partial" -- the next refresh or request tries again
			return
		end
		local pages = store:GetSortedAsync(false, Config.Rankings.TopSize)
		local list, ids = {}, {}
		for _, item in pages:GetCurrentPage() do
			local value = tonumber(item.value)
			local id = tonumber(item.key)
			if value and id then
				table.insert(list, { key = tostring(item.key), value = value })
				table.insert(ids, id)
			end
		end
		denied[name] = nil
		resolveNames(ids)
		entry.entries = list
		entry.status = "ok"
		entry.updatedAt = os.time()
		entry.fetchedAt = os.clock()
	end)
	if not ok then
		readFailed(name, "sorted", err)
		entry.status = if denied[name] then "unavailable" else "partial"
	end
	entry.fetching = false
end

--[[
    The Global rows for a request: the cached list, fetched first when it is
    missing or old (the current season's normally comes from the background
    refresh) unless the store was tried less than GlobalCooldown ago; a
    fetch in flight is waited for. Returns rows, status, updatedAt, ownValue?.
]]
local function globalView(player, name, seasonId, mode, isCurrent)
	if not getStore(name) then
		return serverRows(player, mode, seasonId, isCurrent, nil), "unavailable", os.time(), nil
	end
	local R = Config.Rankings
	local lifetime = if isCurrent then R.RefreshSeconds * 2 else R.PastSeasonCacheSeconds
	local entry = globalEntry(name) -- (kept in hand: prune may drop it from `global` while this waits)
	local now = os.clock()
	if entry.fetching then
		waitForFetch(entry)
	else
		local fresh = entry.fetchedAt and now - entry.fetchedAt < lifetime
		local tried = entry.attemptedAt and now - entry.attemptedAt < R.GlobalCooldown
		if not fresh and not tried then
			fetchGlobal(entry, name, false)
		end
	end
	if entry.status == "unavailable" then
		return serverRows(player, mode, seasonId, isCurrent, nil), "unavailable", os.time(), nil
	end
	local status = entry.status
	local rows = RankingsView.buildRows(entry.entries, names, player.UserId)
	local ownValue = nil
	if not isCurrent then
		local listed = false
		for _, row in rows do
			listed = listed or row.you
		end
		if not listed and player.UserId > 0 then
			-- your own entry in that season's store: one cached GetAsync
			if not readValues(name, { player.UserId }) then
				status = "partial" -- the card says NOT RANKED only because the read didn't work
			end
			ownValue = cachedValue(name, player.UserId) or nil
		end
	end
	return rows, status, entry.updatedAt, ownValue
end

-- Friends ------------------------------------------------------------------------

-- One friends fetch for (player, store): rows, status, ownValue?, whether the player had any friend ids (yields).
local function fetchFriends(player, name, seasonId, mode, isCurrent)
	local ids, seen = {}, {}
	for _, id in friendCache().friendIds(player) do
		if type(id) == "number" and id ~= player.UserId and not seen[id] then
			seen[id] = true
			table.insert(ids, id)
		end
	end
	if not getStore(name) then
		return serverRows(player, mode, seasonId, isCurrent, ids), "unavailable", nil, #ids > 0
	end

	local list, stored = {}, {}
	if isCurrent then
		local profile = services.DataService.get(player)
		if profile then
			table.insert(list, liveItem(player, profile, mode))
		end
	elseif player.UserId > 0 then
		table.insert(stored, player.UserId) -- your own entry in that season's store
	end
	-- friends on this server (current season) cost no DataStore call: all of them; the others up to FriendsMax
	local others = 0
	for _, id in ids do
		local other = isCurrent and Players:GetPlayerByUserId(id)
		local profile = other and services.DataService.get(other)
		if profile then
			if hasRating(profile, mode, seasonId) then
				table.insert(list, liveItem(other, profile, mode))
			end
		elseif others < Config.Rankings.FriendsMax then
			others += 1
			table.insert(stored, id)
		end
	end

	local status = if readValues(name, stored) then "ok" else "partial"
	if denied[name] then
		return serverRows(player, mode, seasonId, isCurrent, ids), "unavailable", nil, #ids > 0
	end
	local found = {}
	for _, id in stored do
		if cachedValue(name, id) then
			table.insert(found, id)
		end
	end
	resolveNames(found)
	for _, id in found do
		local known = names[id]
		table.insert(list, {
			userId = id,
			name = known and known.name,
			username = known and known.username,
			value = cachedValue(name, id),
		})
	end
	local ownValue = if isCurrent then nil else (cachedValue(name, player.UserId) or nil)
	return RankingsView.friendsRows(list, player.UserId), status, ownValue, #ids > 0
end

--[[
    The Friends rows for a request, cached per (requester, season, mode):
    refetched at most every FriendsCooldown; a request while that fetch is
    in flight waits for it. A fetch without any friend ids (FriendCache
    still loading, or no friends) costs nothing and is not kept, so friends
    show as soon as the cache has them. Returns rows, status, updatedAt,
    ownValue?.
]]
local function friendsView(player, name, seasonId, mode, isCurrent)
	local mine = friends[player]
	if not mine then
		mine = {}
		friends[player] = mine
	end
	local entry = mine[name]
	if entry and entry.fetching then
		waitForFetch(entry)
	elseif not (entry and entry.fetchedAt and os.clock() - entry.fetchedAt < Config.Rankings.FriendsCooldown) then
		if not entry then
			entry = { rows = {}, status = "partial", updatedAt = 0, fetching = false }
			mine[name] = entry
		end
		entry.fetching = true
		local ok, rows, status, ownValue, hadFriends = pcall(fetchFriends, player, name, seasonId, mode, isCurrent)
		if ok then
			entry.rows, entry.status, entry.ownValue = rows, status, ownValue
			entry.updatedAt = os.time()
		else
			warnOnce("friends", "[LeaderboardService] friends rankings failed:", rows)
			entry.status = "partial"
		end
		entry.fetchedAt = if ok and not hadFriends then nil else os.clock()
		entry.fetching = false
	end
	return entry.rows, entry.status, entry.updatedAt, entry.ownValue
end

-- API ------------------------------------------------------------------------------

--[[
    Queues `player`'s standing in `mode` for their profile's season store
    (Seasons.ensure has just made it current): rating, best legend of the
    season (MAIN), season wins and losses. Studio test players (UserId <= 0)
    never write to a ranked store.
]]
function LeaderboardService.submit(player, mode, profile)
	if player.UserId <= 0 or not RATING_KEYS[mode] then
		return
	end
	profile = profile or (services and services.DataService.get(player))
	if type(profile) ~= "table" or type(profile.Season) ~= "number" or profile.Season < 1 then
		return
	end
	local stats = statsOf(profile, mode)
	local main = Rankings.bestLegend(stats.Legends)
	local value = Rankings.encode(profile[RATING_KEYS[mode]], main, stats.Wins or 0, stats.Losses or 0)
	local name = Rankings.storeName(profile.Season, mode)
	pending[name] = pending[name] or {}
	pending[name][player.UserId] = value
	-- friends' rankings (and a past-season card) see it right away, also after the player leaves
	remember(name, player.UserId, value)
end

--[[
    Writes the queued values (SetAsync per user) while the write budget
    (OrderedWrite, else the legacy SetIncrementSortedAsync; see mayCall)
    stays above MinBudget; the rest wait for the next flush. A write that
    errors is logged once per store and dropped. Without DataStores the
    queue is dropped. Yields; a flush already running makes this a no-op.
]]
function LeaderboardService.flush()
	if flushing then
		return
	end
	flushing = true
	local ok, err = pcall(function()
		for name in table.clone(pending) do
			local batch = pending[name]
			local store = getStore(name)
			if not store then
				pending[name] = nil
				continue
			end
			for userId in table.clone(batch) do
				if not mayCall("write", Config.Rankings.MinBudget) then
					return
				end
				local value = batch[userId]
				if value ~= nil then
					batch[userId] = nil
					local written, writeErr = pcall(function()
						store:SetAsync(tostring(userId), value)
					end)
					if not written then
						warnOnce("set " .. name, "[LeaderboardService] couldn't write to", name, writeErr)
					end
				end
			end
			if next(batch) == nil and pending[name] == batch then
				pending[name] = nil
			end
		end
	end)
	flushing = false
	if not ok then
		warn("[LeaderboardService] flush failed:", err)
	end
end

-- What is queued for `storeName` (tests and debugging).
function LeaderboardService.pendingFor(storeName)
	return pending[storeName]
end

--[[
    The GetRankings handler body: request = { mode = "1v1" | "2v2", scope =
    "Global" | "Friends", season = a started season id? (nil = current) }
    -> true, RankingsData | false, message.
]]
function LeaderboardService.getRankings(player, request)
	if type(request) ~= "table" then
		return false, "Bad request."
	end
	local mode, scope = request.mode, request.scope
	if not RATING_KEYS[mode] or (scope ~= "Global" and scope ~= "Friends") then
		return false, "Bad request."
	end
	local now = os.time()
	local current = Seasons.current(now)
	local started = Seasons.started(now)
	local season = current
	if request.season ~= nil then
		season = nil
		for _, s in started do
			if s.Id == request.season then
				season = s
			end
		end
		if not season then
			return false, "Bad request."
		end
	end
	if not services.DataService.get(player) then
		return false, "Your profile is still loading."
	end
	local isCurrent = season.Id == current.Id
	if isCurrent and Seasons.isBehind(services.DataService.get(player), now) then
		-- a season ended in the last few seconds: move the profile now rather than on the next 30 s check
		services.MissionService.rollover(player)
	end

	local name = Rankings.storeName(season.Id, mode)
	local rows, status, updatedAt, ownValue
	if scope == "Global" then
		rows, status, updatedAt, ownValue = globalView(player, name, season.Id, mode, isCurrent)
	else
		rows, status, updatedAt, ownValue = friendsView(player, name, season.Id, mode, isCurrent)
	end
	local profile = services.DataService.get(player)
	if not profile then
		return false, "Your profile is still loading."
	end
	local seasons = {}
	for _, s in started do
		table.insert(seasons, { id = s.Id, name = s.Name })
	end
	return true,
		{
			mode = mode,
			scope = scope,
			season = { id = season.Id, name = season.Name, endsAt = season.endsAt, current = isCurrent },
			seasons = seasons,
			status = status,
			updatedAt = updatedAt,
			rows = rows,
			you = RankingsView.buildCard(profile, mode, rows, isCurrent, ownValue),
		}
end

-- Refreshes the current season's two Global lists (yields). A list already being fetched is left to that fetch.
function LeaderboardService.refresh()
	local season = Seasons.current(os.time())
	for _, mode in Rankings.MODES do
		local name = Rankings.storeName(season.Id, mode)
		local entry = globalEntry(name)
		if not entry.fetching then
			fetchGlobal(entry, name, true)
		end
	end
end

-- Drops old cache entries (past-season lists, stored values, failed reads, friends lists) and players who left.
local function prune()
	local R = Config.Rankings
	local now = os.clock()
	local season = Seasons.current(os.time())
	local currentNames = {}
	for _, mode in Rankings.MODES do
		currentNames[Rankings.storeName(season.Id, mode)] = true
	end
	for name, entry in global do
		local old = not entry.fetchedAt or now - entry.fetchedAt >= R.PastSeasonCacheSeconds
		if not currentNames[name] and not entry.fetching and old then
			global[name] = nil
		end
	end
	for name, list in values do
		for userId, known in list do
			if now - known.at >= R.FriendsCacheSeconds then
				list[userId] = nil
			end
		end
		if next(list) == nil then
			values[name] = nil
		end
	end
	for name, list in failed do
		for userId, at in list do
			if now - at >= R.GlobalCooldown then
				list[userId] = nil
			end
		end
		if next(list) == nil then
			failed[name] = nil
		end
	end
	for player, mine in friends do
		if not player.Parent then
			friends[player] = nil
		else
			for name, entry in mine do
				if not entry.fetching and entry.fetchedAt and now - entry.fetchedAt >= R.FriendsCacheSeconds then
					mine[name] = nil
				end
			end
		end
	end
end

-- Called by Main.server's PlayerRemoving coordinator. Never yields; queued writes stay and are flushed.
function LeaderboardService.onPlayerRemoving(player)
	friends[player] = nil
end

function LeaderboardService.init(s)
	services = s
end

function LeaderboardService.start()
	Net.get("GetRankings").OnServerInvoke = function(player, request)
		local ok, result, data = pcall(LeaderboardService.getRankings, player, request)
		if not ok then
			warn("[LeaderboardService] GetRankings failed:", result)
			return false, "Something went wrong."
		end
		return result, data
	end

	task.spawn(function()
		while true do
			local ok, err = pcall(LeaderboardService.refresh)
			if not ok then
				warn("[LeaderboardService] refresh failed:", err)
			end
			pcall(prune)
			task.wait(Config.Rankings.RefreshSeconds)
		end
	end)
	task.spawn(function()
		while true do
			task.wait(Config.Rankings.FlushSeconds)
			LeaderboardService.flush()
		end
	end)
	game:BindToClose(function()
		-- let a flush that is already writing finish, then write what is left
		local deadline = os.clock() + 20
		while flushing and os.clock() < deadline do
			task.wait(0.1)
		end
		LeaderboardService.flush()
	end)
end

return LeaderboardService
