--[[
    One friend set per player, shared by RoomService (friends-only rooms),
    PartyService (invite list) and LeaderboardService (friends rankings).

    The set is built in the background when a player joins
    (Players:GetFriendsAsync, every page, at most MAX_FRIENDS ids), kept
    Config.Rankings.FriendsCacheSeconds and then refreshed in the background
    the next time someone asks (the old set keeps answering meanwhile).
    While a player's set is still loading (or failed to load), isFriend asks
    Roblox per pair (player:IsFriendsWith, cached Config.Rooms.FriendCacheSeconds)
    and friendIds returns {}.

    A plain module, not a service (no init/start): it connects PlayerAdded
    when first required, and Main.server's PlayerRemoving coordinator calls
    onPlayerRemoving.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local FriendCache = {}

local MAX_FRIENDS = 200
-- After a failed load, ask Roblox again this much later.
-- TODO(I): move to Config.Rankings.FriendsRetrySeconds (tuning value the design doesn't give).
local RETRY_SECONDS = 60

-- [Player] = { ids: { [userId] = true }?, list: { number }?, loadedAt: number?, loading: boolean, retryAt: number? }
local sets = {}
local pairCache = {} -- [Player] = { [userId] = { value: boolean, time: number } }

local function fetch(player)
	local ids, list = {}, {}
	local pages = Players:GetFriendsAsync(player.UserId)
	while true do
		for _, item in pages:GetCurrentPage() do
			if #list >= MAX_FRIENDS then
				return ids, list
			end
			if type(item.Id) == "number" and not ids[item.Id] then
				ids[item.Id] = true
				table.insert(list, item.Id)
			end
		end
		if pages.IsFinished or #list >= MAX_FRIENDS then
			return ids, list
		end
		pages:AdvanceToNextPageAsync()
	end
end

-- Starts a background (re)load of the player's set unless one is running.
local function startLoad(player)
	local entry = sets[player]
	if not entry then
		entry = { loading = false }
		sets[player] = entry
	end
	if entry.loading then
		return
	end
	if player.UserId <= 0 then
		-- Studio test players have no Roblox friends.
		entry.ids, entry.list, entry.loadedAt = {}, {}, os.clock()
		return
	end
	entry.loading = true
	task.spawn(function()
		local ok, ids, list = pcall(fetch, player)
		if sets[player] ~= entry then
			return -- forgotten meanwhile (the player left)
		end
		entry.loading = false
		if ok then
			entry.ids, entry.list, entry.loadedAt, entry.retryAt = ids, list, os.clock(), nil
		else
			entry.retryAt = os.clock() + RETRY_SECONDS
			if not entry.ids then
				warn("[FriendCache] couldn't load friends of", player.Name, ids)
			end
		end
	end)
end

-- The player's loaded set (refreshing it in the background when it is old), or nil while there is none.
local function setOf(player)
	local entry = sets[player]
	if not entry then
		if player.Parent then
			startLoad(player)
		end
		return nil
	end
	if not entry.loading and player.Parent then
		local now = os.clock()
		local stale = entry.loadedAt and now - entry.loadedAt >= Config.Rankings.FriendsCacheSeconds
		local retry = not entry.ids and (entry.retryAt == nil or now >= entry.retryAt)
		if stale or retry then
			startLoad(player)
		end
	end
	return entry.ids and entry
end

-- One pcall'd IsFriendsWith per pair, cached (the fallback while the set loads).
local function askRoblox(player, userId)
	local cache = pairCache[player]
	if not cache then
		cache = {}
		pairCache[player] = cache
	end
	local hit = cache[userId]
	if hit and os.clock() - hit.time < Config.Rooms.FriendCacheSeconds then
		return hit.value
	end
	local ok, value = pcall(function()
		return player:IsFriendsWith(userId)
	end)
	value = ok and value == true
	cache[userId] = { value = value, time = os.clock() }
	return value
end

-- Whether `userId` is one of the player's Roblox friends. A set lookup once the set has loaded; may yield before.
function FriendCache.isFriend(player, userId)
	if type(userId) ~= "number" then
		return false
	end
	local set = setOf(player)
	if set then
		return set.ids[userId] == true
	end
	return askRoblox(player, userId)
end

-- The player's friends' user ids ({} while loading).
function FriendCache.friendIds(player)
	local set = setOf(player)
	return set and table.clone(set.list) or {}
end

function FriendCache.forget(player)
	sets[player] = nil
	pairCache[player] = nil
end

function FriendCache.onPlayerRemoving(player)
	FriendCache.forget(player)
end

Players.PlayerAdded:Connect(startLoad)
for _, player in Players:GetPlayers() do
	startLoad(player)
end

return FriendCache
