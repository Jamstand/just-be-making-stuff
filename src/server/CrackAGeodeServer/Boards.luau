-- BoardsService: global leaderboards (OrderedDataStore, ≤ 50 rows per kind), the
-- two physical leaderboard walls + the live rarity feed wall near spawn.
--
--   Stores   CrackAGeode_LB_gems_v<Config.Version>      value = totalGems
--            CrackAGeode_LB_rebirths_v<Config.Version>  value = lifetime rebirths
--            (Econ.LifetimeRebirths: Ascend resets p.rebirths, so the board reads the
--            permanent count; equals totalRebirths on every migrated profile)
--   Writes   per player ≤ 1 write moment per Config.Social.LeaderboardWriteGap (+ on
--            PlayerRemoving), only when a value changed, pcall'd, gated on
--            Data.IsUsable(). Values floored and clamped to 0 .. 2^53-1 before SetAsync.
--            NEVER from Studio (RunService:IsStudio()) and never for UserId <= 0 (Test ->
--            Local Server players are -1, -2, ...): with "Studio access to API services"
--            on, Data is usable and a TestHook-inflated profile would otherwise land in
--            the production stores every live server reads. Reads still run in Studio.
--   Reads    both kinds every LeaderboardRefresh s: GetSortedAsync(false, LeaderboardTop)
--            -> cache { rows, byUser, updatedAt }. Names = DisplayName when online, else
--            Players:GetNameFromUserIdAsync (pcall, cached per userId), fallback "Miner".
--   Degrade  DataStores unusable (Studio, unpublished): no OrderedDataStore call is ever
--            made (so no second warning); GetLeaderboard replies global=false with
--            session rows from Data.Cache and the walls say THIS SERVER.
--
--   Boards.Get(player, kind) -> GetLeaderboard reply
--     { ok, kind, rows = {{userId, name, value}} (≤ 50), myRank:int?, myValue:int,
--       global:boolean, updatedAt:int }          (bound via S.Guard: gap 1, args {"string"})
--   Boards.MyRank(player) -> { gems = int?, rebirths = int? }   (cache lookup only, no I/O;
--     Econ.Snapshot.myRank + GetProfile.rank read this on every push)
--   Boards.Feed(name, rarName, mutKey)   (unchanged: the RarityFeed wall)

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local Boards = {}
local IS_STUDIO = RunService:IsStudio()
local S, Config
local feed = {}

local KINDS = { "gems", "rebirths" }
local MAX_VALUE = 2 ^ 53 - 1
local WALL_ROWS = 8
local WALL_REFRESH = 12  -- s: physical walls + the session ranking cache
local WRITE_POLL = 10    -- s: how often the write loop looks for changed values
local NAME_FALLBACK = "Miner"

local stores = {}      -- [kind] = OrderedDataStore (opened lazily, only when Data is usable)
local global = {}      -- [kind] = { rows = {{userId, name, value}}, byUser = {[userId] = rank}, updatedAt }
local session = {}     -- [kind] = same shape, rebuilt from Data.Cache every WALL_REFRESH s
local nameCache = {}   -- [userId] = username (offline rows)
local lastWritten = {} -- [userId] = { [kind] = value } — the last value that reached the store
local lastWriteAt = {} -- [userId] = os.clock() of the last write moment
local latest = {}      -- [userId] = { [kind] = value } — captured by the write loop (PlayerRemoving fallback)

local function social()
	return (Config and Config.Social) or {}
end

local function usable()
	return S ~= nil and S.Data ~= nil and S.Data.IsUsable ~= nil and S.Data.IsUsable() == true
end

-- Board value for a profile: a non-negative integer ≤ 2^53-1 (OrderedDataStore rule).
local function valueFor(p, kind)
	local v
	if kind == "gems" then
		v = p.totalGems
	elseif S.Econ and S.Econ.LifetimeRebirths then
		v = S.Econ.LifetimeRebirths(p)
	else
		v = p.totalRebirths or p.rebirths
	end
	v = tonumber(v) or 0
	if v ~= v or v == math.huge or v == -math.huge then v = 0 end
	return math.clamp(math.floor(v), 0, MAX_VALUE)
end

local function storeFor(kind)
	if stores[kind] then return stores[kind] end
	if not usable() then return nil end
	local ok, ds = pcall(DataStoreService.GetOrderedDataStore, DataStoreService,
		"CrackAGeode_LB_" .. kind .. "_v" .. tostring(Config.Version))
	if ok and ds then stores[kind] = ds end
	return stores[kind]
end

-- DisplayName when online; otherwise the username (pcall + cache), fallback "Miner".
local function nameFor(userId)
	local online = Players:GetPlayerByUserId(userId)
	if online then return online.DisplayName end
	local cached = nameCache[userId]
	if cached then return cached end
	local ok, name = pcall(Players.GetNameFromUserIdAsync, Players, userId)
	if ok and type(name) == "string" and name ~= "" then
		nameCache[userId] = name
		return name
	end
	return NAME_FALLBACK
end

-- ===== physical walls =====

-- FindFirstChild all the way down: a wall with a missing gui/list is skipped, never an error.
local function setList(boardName, text)
	local cg = workspace:FindFirstChild("CrackAGeode")
	local boards = cg and cg:FindFirstChild("Boards")
	local b = boards and boards:FindFirstChild(boardName)
	local gui = b and b:FindFirstChild("Gui")
	local list = gui and gui:FindFirstChild("List")
	if list and (list:IsA("TextLabel") or list:IsA("TextButton")) then
		list.Text = text
	end
end

function Boards.Feed(name, rarName, mutKey)
	table.insert(feed, 1, "⭐ " .. name .. " — " .. (mutKey and (mutKey .. " ") or "") .. rarName)
	if #feed > 9 then table.remove(feed) end
	setList("RarityFeed", table.concat(feed, "\n"))
end

-- ===== session ranking (this server only) =====

local function buildSession()
	local list = {}
	for player, p in pairs(S.Data.Cache) do
		if typeof(player) == "Instance" and player.Parent == Players and type(p) == "table" then
			list[#list + 1] = { player = player, gems = valueFor(p, "gems"), rebirths = valueFor(p, "rebirths") }
		end
	end
	local top = tonumber(social().LeaderboardTop) or 50
	for _, kind in ipairs(KINDS) do
		table.sort(list, function(a, b)
			if a[kind] ~= b[kind] then return a[kind] > b[kind] end
			return a.player.UserId < b.player.UserId
		end)
		local rows, byUser = {}, {}
		for i = 1, math.min(#list, top) do
			local e = list[i]
			rows[i] = { userId = e.player.UserId, name = e.player.DisplayName, value = e[kind] }
			byUser[e.player.UserId] = i
		end
		session[kind] = { rows = rows, byUser = byUser, updatedAt = os.time() }
	end
end

-- The cache a reader should see right now: global when Data is usable AND a read has
-- landed, else the session ranking. Second value = whether it is the global one.
local function sourceFor(kind)
	-- a populated global cache wins; an EMPTY global board (fresh place, or Studio
	-- where writes are disabled) falls back to this server's session rows so the
	-- panel never shows a blank list
	local g = usable() and global[kind]
	if g and g.rows and #g.rows > 0 then return g, true end
	if not session[kind] then buildSession() end
	return session[kind], false
end

local function wallText(kind)
	local src, isGlobal = sourceFor(kind)
	local lines = { isGlobal and "— GLOBAL —" or "— THIS SERVER —" }
	for i = 1, math.min(#src.rows, WALL_ROWS) do
		local r = src.rows[i]
		local val = (kind == "gems") and Config.Fmt(r.value) or (tostring(r.value) .. " 🔄")
		lines[#lines + 1] = i .. ". " .. r.name .. " — " .. val
	end
	if #src.rows == 0 then lines[#lines + 1] = "Be the first!" end
	return table.concat(lines, "\n")
end

local function refreshWalls()
	buildSession()
	setList("TopGems", wallText("gems"))
	setList("TopRebirths", wallText("rebirths"))
end

-- ===== OrderedDataStore reads / writes =====

local function readGlobal(kind)
	local ds = storeFor(kind)
	if not ds then return false end
	local top = tonumber(social().LeaderboardTop) or 50
	local ok, pages = pcall(ds.GetSortedAsync, ds, false, top)
	if not ok or not pages then return false end
	local ok2, page = pcall(pages.GetCurrentPage, pages)
	if not ok2 or type(page) ~= "table" then return false end
	local rows, byUser = {}, {}
	for _, entry in ipairs(page) do
		local userId = tonumber(entry.key)
		local value = tonumber(entry.value) or 0
		if userId and not byUser[userId] then
			rows[#rows + 1] = { userId = userId, name = nameFor(userId), value = value }
			byUser[userId] = #rows
		end
	end
	global[kind] = { rows = rows, byUser = byUser, updatedAt = os.time() }
	return true
end

local function writeValue(userId, kind, value)
	local ds = storeFor(kind)
	if not ds then return false end
	local ok = pcall(ds.SetAsync, ds, tostring(userId), value)
	if ok then
		lastWritten[userId] = lastWritten[userId] or {}
		lastWritten[userId][kind] = value
	end
	return ok
end

-- One write moment per player per LeaderboardWriteGap (force = PlayerRemoving), and
-- only the kinds whose value changed since the last write that landed.
local function maybeWrite(player, force)
	if not usable() then return end
	-- Studio sessions and Test-Server players (negative UserIds) never touch the live stores
	if IS_STUDIO or player.UserId <= 0 then return end
	local uid = player.UserId
	local p = S.Data.Cache[player]
	local vals
	if p then
		vals = { gems = valueFor(p, "gems"), rebirths = valueFor(p, "rebirths") }
		latest[uid] = vals
	else
		vals = latest[uid] -- Data already released the profile (PlayerRemoving order)
	end
	if not vals then return end
	local gap = tonumber(social().LeaderboardWriteGap) or 60
	if not force and lastWriteAt[uid] and os.clock() - lastWriteAt[uid] < gap then return end
	local written = lastWritten[uid] or {}
	local due = {}
	for _, kind in ipairs(KINDS) do
		if written[kind] ~= vals[kind] then due[#due + 1] = kind end
	end
	if #due == 0 then return end
	lastWriteAt[uid] = os.clock()
	task.spawn(function()
		for _, kind in ipairs(due) do
			writeValue(uid, kind, vals[kind])
		end
	end)
end

-- ===== public API =====

function Boards.Get(player, kind)
	if kind ~= "gems" and kind ~= "rebirths" then return { ok = false, err = "Unknown board" } end
	if typeof(player) ~= "Instance" then return { ok = false, err = "Bad request" } end
	local p = S.Data.Cache[player]
	local myValue = p and valueFor(p, kind) or 0
	local src, isGlobal = sourceFor(kind)
	return {
		ok = true,
		kind = kind,
		rows = src.rows,
		myRank = src.byUser[player.UserId],
		myValue = myValue,
		global = isGlobal,
		updatedAt = src.updatedAt,
	}
end

-- Map lookups only (called on every Econ.Push). nil rank = outside the top rows.
function Boards.MyRank(player)
	local out = {}
	if typeof(player) ~= "Instance" then return out end
	for _, kind in ipairs(KINDS) do
		local src = sourceFor(kind) -- same board the panel shows (global, else session)
		if src then out[kind] = src.byUser[player.UserId] end
	end
	return out
end

function Boards.Init(services)
	S = services
	Config = S.Config
	setList("RarityFeed", "Crack geodes to make history!")

	-- GetLeaderboard: S.Guard does Ready + {"string"} + 1 s gap + pcall; Get whitelists kind
	if S.Guard then
		S.Guard("GetLeaderboard", {
			gap = 1, args = { "string" },
			fn = function(player, kind)
				return Boards.Get(player, kind)
			end,
		})
	end

	-- leaving players: one forced write (changed values only), then forget them
	Players.PlayerRemoving:Connect(function(player)
		local uid = player.UserId
		pcall(maybeWrite, player, true)
		task.delay(30, function()
			if Players:GetPlayerByUserId(uid) then return end -- rejoined: keep their state
			lastWritten[uid], lastWriteAt[uid], latest[uid] = nil, nil, nil
		end)
	end)

	-- physical walls (+ the session ranking cache) every WALL_REFRESH s; the body is
	-- pcall'd so one missing gui can never stop every board
	task.spawn(function()
		while true do
			local ok, err = pcall(refreshWalls)
			if not ok then warn("[Boards] wall refresh failed: " .. tostring(err)) end
			task.wait(WALL_REFRESH)
		end
	end)

	-- global reads: both kinds every LeaderboardRefresh s (2 reads / 75 s per server);
	-- nothing runs while Data is unusable (Studio keeps its single [Data] warning)
	task.spawn(function()
		task.wait(3)
		while true do
			if usable() then
				for _, kind in ipairs(KINDS) do
					local ok, err = pcall(readGlobal, kind)
					if not ok then warn("[Boards] global read failed for " .. kind .. ": " .. tostring(err)) end
				end
				pcall(refreshWalls)
			end
			task.wait(tonumber(social().LeaderboardRefresh) or 75)
		end
	end)

	-- global writes: poll every WRITE_POLL s; each player gets ≤ 1 write moment per
	-- LeaderboardWriteGap and only when a value changed
	task.spawn(function()
		while true do
			task.wait(WRITE_POLL)
			if usable() then
				for _, player in ipairs(Players:GetPlayers()) do
					pcall(maybeWrite, player, false)
				end
			end
		end
	end)
end

return Boards
