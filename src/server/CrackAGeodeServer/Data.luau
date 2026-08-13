-- DataService: session-locked, retry-backed player persistence.
--
-- Guarantees:
--   1. SESSION LOCK  — at most one live server persists a profile at a time.
--      Stealing is allowed ONLY when a lock is stale (crashed owner); a routine
--      save NEVER clobbers a foreign lock. Prevents item-dupe / rollback.
--   2. RETRY         — every DataStore op retries with capped exponential backoff.
--   3. CRASH-SAFE    — UpdateAsync only; stale-lock reclaim; per-player commit
--      coalescing so a late save can never resurrect a released lock; BindToClose
--      flushes within the shutdown budget; important events save synchronously.
--   4. NON-DESTRUCTIVE — loads preserve unknown fields; the acquire budget spans
--      LOCK_STALE so a live owner is never stolen from.
--
-- Degrades to in-memory when DataStores are unavailable. Concurrency logic is in
-- PURE functions (_normalize/_acquire/_commit) for unit testing.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local Data = {}
local S
local store = nil
local usable = false

local cache = {}          -- [player] = live profile table (hot path reads this)
Data.Cache = cache
local sessionOwned = {}    -- [player] = true once we hold the DataStore lock
local loading = {}         -- [player] = true while an acquire is in flight
local lastWrite = {}       -- [player] = os.clock() of last successful write
local pendingSave = {}     -- [player] = true if a save is owed (coalesced)
local commitBusy = {}      -- [player] = true while a commit UpdateAsync is running
local closed = {}          -- [player] = true once removal/shutdown began (release is terminal)

local JOB = game.JobId
if JOB == nil or JOB == "" then JOB = "studio-" .. tostring(game.PlaceId) end

-- ===== tunables =====
local KEY_PREFIX = "u"
local LOCK_STALE = 90       -- s: a lock older than this is assumed dead & reclaimable
local HEARTBEAT = 30        -- s: autosave cadence (also refreshes our lock heartbeat)
local LOAD_BUDGET = LOCK_STALE + 24 -- s: acquire keeps trying this long so a stale (crashed)
                                    --    lock is reclaimed and a LIVE lock is never stolen
local LOAD_WAIT = 6         -- s between acquire attempts while a live lock is held
local OP_TRIES = 5          -- retry attempts per DataStore op (normal)
local OP_TRIES_FAST = 2     -- retry attempts under shutdown
local OP_BASE_DELAY = 1     -- s: backoff base
local OP_MAX_DELAY = 4      -- s: backoff cap (keeps shutdown bounded)
local MIN_WRITE_GAP = 6     -- s: never write the same key faster than this (DS throttle)
local IMPORTANT_MIN_GAP = 7 -- s: min spacing for event-triggered saves
Data.LoadTimeout = LOAD_BUDGET + 10

local DEFAULT = {
	gems = 0, totalGems = 0, power = 0, luck = 0,
	rebirths = 0, ascensions = 0, shards = 0, perks = {},
	indexMask = 0, cracks = 0, bestRarity = 0,
	pityRuby = 0, pityStar = 0,
	lastHarvest = 0, lastLogout = 0, savedEarnRate = 5,
	streakDay = 0, lastStreakDate = "", rewardClaimedDate = "",
	questDate = "", questProgress = {}, questClaimed = {}, questSetDone = false,
	boostUntil = 0, streakLuckUntil = 0,
	lastVIPBoostDate = "",
	equippedPet = 0,
	zoneShards = {}, foundShards = {}, -- explorer-gate: Sunken Grotto shard progress
	petInv = {}, zoneIndex = {}, achClaimed = {}, -- Phase 3: collectible pets / per-zone index / achievements
	zonesPurchased = {}, zoneVipPets = {}, -- Phase 4: paid zone skip-unlocks / owned zone-exclusive VIP pets
	firstJoinRecorded = false, starterPackBought = false,
	onboardStep = 0, onboardDone = false,
	testPasses = {}, receipts = {},
}

-- Studio-only simulated grants must never persist (would hand out free passes).
local NON_PERSISTED = { testPasses = true }

local function deepCopy(t)
	local out = {}
	for k, v in pairs(t) do
		out[k] = (type(v) == "table") and deepCopy(v) or v
	end
	return out
end

-- ===== PURE core (unit-testable) =====

function Data._normalize(raw)
	if type(raw) ~= "table" then
		return { data = nil, session = nil }
	end
	if raw.data ~= nil or raw.session ~= nil then
		return { data = raw.data, session = raw.session }
	end
	if raw.gems ~= nil or raw.rebirths ~= nil or raw.indexMask ~= nil then
		return { data = raw, session = nil } -- legacy bare-profile migration
	end
	return { data = nil, session = nil }
end

-- Acquire transform. Returns (record|nil, status). nil => CANCEL (live foreign lock).
-- Steals ONLY a stale foreign lock. status ∈ acquired|stole|locked.
function Data._acquire(raw, jobId, placeId, now)
	local rec = Data._normalize(raw)
	local s = rec.session
	if s and s.jobId ~= jobId and (now - (s.heartbeat or 0)) < LOCK_STALE then
		return nil, "locked"
	end
	local status = (s and s.jobId ~= jobId) and "stole" or "acquired"
	rec.session = { jobId = jobId, placeId = placeId, heartbeat = now }
	return rec, status
end

-- Commit transform. Returns (record|nil, status). A routine save NEVER clobbers a
-- foreign lock (stale OR fresh) — only _acquire may steal. status ∈ saved|released|foreign.
function Data._commit(raw, jobId, placeId, now, payload, release)
	local rec = Data._normalize(raw)
	local s = rec.session
	if s and s.jobId ~= jobId then
		return nil, "foreign"
	end
	rec.data = payload
	if release then
		rec.session = nil
		return rec, "released"
	else
		rec.session = { jobId = jobId, placeId = placeId, heartbeat = now }
		return rec, "saved"
	end
end

local function toStored(profile)
	local out = {}
	for k, v in pairs(profile) do
		if not NON_PERSISTED[k] then
			out[k] = (type(v) == "table") and deepCopy(v) or v
		end
	end
	return out
end

local function fromStored(blob)
	local profile = deepCopy(DEFAULT)
	if type(blob) == "table" then
		for k, v in pairs(blob) do
			if DEFAULT[k] ~= nil and not NON_PERSISTED[k] then
				profile[k] = v
			end
		end
	end
	return profile
end

-- ===== DataStore plumbing =====

local function keyFor(userId)
	return KEY_PREFIX .. userId
end

local function retry(label, fn, maxTries)
	maxTries = maxTries or OP_TRIES
	local attempt = 0
	while true do
		attempt += 1
		local ok, res = pcall(fn)
		if ok then
			return true, res
		end
		if attempt >= maxTries then
			warn(("[Data] %s failed after %d tries: %s"):format(label, attempt, tostring(res)))
			return false, res
		end
		task.wait(math.min(OP_MAX_DELAY, OP_BASE_DELAY * 2 ^ (attempt - 1)) + math.random() * 0.4)
	end
end

-- Acquire the session lock and load the profile. Returns (profile, owned).
-- Budget spans LOCK_STALE so a crashed owner's lock is reclaimed and a live one
-- is never stolen. Never unconditionally force-steals.
local function acquire(player)
	local userId = player.UserId
	local deadline = os.clock() + LOAD_BUDGET
	repeat
		local status
		local ok, result = retry("acquire " .. userId, function()
			return store:UpdateAsync(keyFor(userId), function(raw)
				local rec, st = Data._acquire(raw, JOB, game.PlaceId, os.time())
				status = st
				return rec -- nil cancels (live foreign lock)
			end)
		end)
		if ok and result ~= nil then
			if status == "stole" then
				warn("[Data] reclaimed a stale session lock for " .. userId)
			end
			return fromStored(result.data), true
		elseif ok and result == nil then
			task.wait(LOAD_WAIT) -- live foreign lock; wait for release or staleness
		else
			return deepCopy(DEFAULT), false -- op failed; session-only
		end
	until os.clock() >= deadline
	warn("[Data] could not acquire lock for " .. userId .. " within budget — session-only this session")
	return deepCopy(DEFAULT), false
end

-- Commit the profile. Coalesced per player so no two non-release writes race, and
-- a non-release write is guarded so it can never land after the session closed.
-- Returns true only if a real write persisted (for SaveNow callers).
local function commit(player, release, fast)
	if not usable then return false end
	if release then
		if not sessionOwned[player] then return false end
	else
		if closed[player] or not sessionOwned[player] then return false end
		if commitBusy[player] then
			pendingSave[player] = true -- coalesce; the in-flight commit re-runs
			return false
		end
	end
	local profile = cache[player]
	if not profile then return false end
	commitBusy[player] = true
	local payload = toStored(profile)
	local userId = player.UserId
	local status
	local ok = retry((release and "release " or "save ") .. userId, function()
		return store:UpdateAsync(keyFor(userId), function(raw)
			-- terminal-close guard: never resurrect a released lock with a late save
			if not release and (closed[player] or not sessionOwned[player]) then
				return nil
			end
			local rec, st = Data._commit(raw, JOB, game.PlaceId, os.time(), payload, release)
			status = st
			return rec
		end)
	end, fast and OP_TRIES_FAST or OP_TRIES)
	commitBusy[player] = false

	if status == "foreign" then
		warn("[Data] save aborted for " .. userId .. ": lock held by another server (superseded)")
		sessionOwned[player] = false
		pendingSave[player] = nil
		return false
	end

	local persisted = ok and (status == "saved" or status == "released")
	if persisted then
		lastWrite[player] = os.clock()
		pendingSave[player] = nil
	end
	-- follow up if more changes were coalesced while we were writing
	if not release and pendingSave[player] and sessionOwned[player] and not closed[player] then
		pendingSave[player] = nil
		task.spawn(commit, player, false)
	end
	return persisted
end

-- ===== public API =====

function Data.Get(player)
	return cache[player]
end

function Data.IsUsable()
	return usable
end

function Data.WaitFor(player, timeout)
	local budget = timeout or Data.LoadTimeout
	local t0 = os.clock()
	while not cache[player] and player.Parent and os.clock() - t0 < budget do
		task.wait(0.1)
	end
	return cache[player]
end

-- Throttled event-triggered save (rebirth/ascend/perk/harvest). Fire-and-forget.
function Data.SaveSoon(player)
	if not (usable and sessionOwned[player]) then return end
	if os.clock() - (lastWrite[player] or 0) >= IMPORTANT_MIN_GAP then
		task.spawn(commit, player, false)
	else
		pendingSave[player] = true
	end
end

-- Synchronous confirmed save; returns true only if the write durably persisted.
-- Used by ProcessReceipt so a paid item is never acknowledged before it is saved.
function Data.SaveNow(player)
	if not (usable and sessionOwned[player]) then return false end
	local guard = 0
	while commitBusy[player] and guard < 100 do
		task.wait(0.1)
		guard += 1
	end
	return commit(player, false)
end

local function onAdded(player)
	if loading[player] or cache[player] then return end
	if not usable then
		cache[player] = deepCopy(DEFAULT) -- in-memory fallback
		return
	end
	loading[player] = true
	local ok, profile, owned = pcall(acquire, player)
	loading[player] = nil
	if not ok then
		warn("[Data] acquire error for " .. player.UserId .. ": " .. tostring(profile))
		profile, owned = deepCopy(DEFAULT), false
	end
	if not player.Parent then
		if owned then
			cache[player] = profile
			sessionOwned[player] = true
			closed[player] = true
			profile.lastLogout = os.time()
			commit(player, true)
		end
		cache[player] = nil
		sessionOwned[player] = nil
		return
	end
	cache[player] = profile
	sessionOwned[player] = owned
	lastWrite[player] = os.clock()
end

local function onRemoving(player)
	closed[player] = true -- set BEFORE the release so late saves cancel (no ghost lock)
	local profile = cache[player]
	if profile then
		profile.lastLogout = os.time()
		commit(player, true)
	end
	cache[player] = nil
	sessionOwned[player] = nil
	loading[player] = nil
	lastWrite[player] = nil
	pendingSave[player] = nil
	commitBusy[player] = nil
	closed[player] = nil
end

local function snapshotPlayers()
	local list = {}
	for player in pairs(cache) do
		table.insert(list, player)
	end
	return list
end

function Data.Init(services)
	S = services

	-- Probe with retry so one transient blip doesn't disable saving for the whole
	-- server; bail fast on the permanent Studio-no-API / unpublished error.
	local lastErr
	for attempt = 1, OP_TRIES do
		local ok, err = pcall(function()
			store = DataStoreService:GetDataStore("CrackAGeode_v" .. S.Config.Version)
			store:GetAsync("__probe__")
		end)
		if ok then
			usable = true
			break
		end
		lastErr = err
		local msg = tostring(err)
		if msg:find("not allowed") or msg:find("Studio access") or msg:find("publish") then
			break -- permanent in this environment; don't waste retries
		end
		task.wait(math.min(OP_MAX_DELAY, OP_BASE_DELAY * 2 ^ (attempt - 1)))
	end
	if not usable then
		warn("[Data] DataStores unavailable — progress is session-only. (" .. tostring(lastErr) .. ")")
	end

	Players.PlayerAdded:Connect(function(player)
		task.spawn(onAdded, player)
	end)
	for _, p in ipairs(Players:GetPlayers()) do
		task.spawn(onAdded, p)
	end
	Players.PlayerRemoving:Connect(onRemoving)

	-- autosave + heartbeat: snapshot keys (never iterate the live cache across a
	-- yield), spawn+pcall each commit, and respect the per-key write gap.
	task.spawn(function()
		while true do
			task.wait(HEARTBEAT)
			for _, player in ipairs(snapshotPlayers()) do
				if sessionOwned[player] and not closed[player]
					and os.clock() - (lastWrite[player] or 0) >= MIN_WRITE_GAP then
					task.spawn(function() pcall(commit, player, false) end)
				end
			end
		end
	end)

	-- deferred-important-save catcher
	task.spawn(function()
		while true do
			task.wait(2)
			for _, player in ipairs(snapshotPlayers()) do
				if pendingSave[player] and sessionOwned[player] and not closed[player]
					and os.clock() - (lastWrite[player] or 0) >= IMPORTANT_MIN_GAP then
					task.spawn(function() pcall(commit, player, false) end)
				end
			end
		end
	end)

	-- shutdown flush: fast retries + a hard cap so we return before the ~30s kill
	game:BindToClose(function()
		local list = snapshotPlayers()
		if #list == 0 then return end
		local pending = #list
		local done = Instance.new("BindableEvent")
		for _, player in ipairs(list) do
			closed[player] = true
			task.spawn(function()
				local profile = cache[player]
				if profile then
					profile.lastLogout = os.time()
					pcall(commit, player, true, true) -- fast mode
				end
				pending -= 1
				if pending <= 0 then done:Fire() end
			end)
		end
		task.delay(25, function() done:Fire() end) -- never block past the budget
		done.Event:Wait()
	end)
end

return Data
