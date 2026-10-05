--[[
    Quick-play queues on this server.

      Ranked1v1   pairs players by 1v1 rating; the allowed rating gap widens
                  the longer you wait, and after a while anyone will do
      Ranked2v2   groups four players by 2v2 rating into balanced teams
      FFA         starts with 4 players, or with 2-3 after a short wait
                  (topped up with bots if Config.Queue.FFAFillWithBots)
      Bots        starts immediately against AI
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Maps = require(Shared.Maps)
local Util = require(Shared.Util)
local Net = require(Shared.Net)

local QueueService = {}
local services

local QUEUES = {
	Ranked1v1 = { Label = "Ranked 1v1", Mode = "1v1", Ranked = true, Source = "Ranked" },
	Ranked2v2 = { Label = "Ranked 2v2", Mode = "2v2", Ranked = true, Source = "Ranked" },
	FFA = { Label = "Free-for-all", Mode = "FFA", Ranked = false, Source = "Casual" },
}

local queues = { Ranked1v1 = {}, Ranked2v2 = {}, FFA = {} }
local queueOf = {} -- [Player] = queueType

function QueueService.init(s)
	services = s
end

function QueueService.isQueued(player)
	return queueOf[player] ~= nil
end

local function pushStatus(player)
	local queueType = queueOf[player]
	if not queueType then
		Net.get("QueueUpdate"):FireClient(player, nil)
		return
	end
	local entry
	for _, e in queues[queueType] do
		if e.player == player then
			entry = e
		end
	end
	Net.get("QueueUpdate"):FireClient(player, {
		queue = queueType,
		label = QUEUES[queueType].Label,
		waited = entry and math.floor(os.clock() - entry.joined) or 0,
		inQueue = #queues[queueType],
		waitingForArena = not services.MatchService.hasFreeArena(),
	})
end

function QueueService.leave(player)
	local queueType = queueOf[player]
	if not queueType then
		return
	end
	local list = queues[queueType]
	for i = #list, 1, -1 do
		if list[i].player == player then
			table.remove(list, i)
		end
	end
	queueOf[player] = nil
	if player.Parent then
		pushStatus(player)
	end
end

local function baseConfig(mode)
	return {
		mode = mode,
		mapId = Util.pick(Config.Queue.MapPools[mode]),
		winRule = "Stocks",
		stocks = Config.Match.DefaultStocks,
		timeLimit = Config.Match.DefaultTimeLimit,
		weapons = nil,
		damageMultiplier = 1,
		friendlyFire = false,
	}
end

local function startFromQueue(queueType, entries, extraParticipants)
	local info = QUEUES[queueType]
	local config = baseConfig(info.Mode)
	config.source = info.Source
	config.ranked = info.Ranked
	config.participants = {}
	for _, p in entries do
		table.insert(config.participants, p)
	end
	for _, p in extraParticipants or {} do
		table.insert(config.participants, p)
	end
	for _, p in config.participants do
		if p.player then
			QueueService.leave(p.player)
		end
	end
	local match, err = services.MatchService.startMatch(config)
	if not match then
		for _, p in config.participants do
			if p.player then
				Net.get("Toast"):FireClient(p.player, err or "Couldn't start the match.", "warn")
			end
		end
	end
	return match
end

local function window(entry, now)
	local waited = now - entry.joined
	if waited >= Config.Queue.AnyoneAfterSeconds then
		return math.huge
	end
	return math.min(
		Config.Queue.RatingWindowMax,
		Config.Queue.RatingWindowStart + Config.Queue.RatingWindowGrowth * waited
	)
end

local function tick1v1(now)
	-- Work on a copy: starting a match removes players from the real queue.
	local list = table.clone(queues.Ranked1v1)
	table.sort(list, function(a, b)
		return a.rating < b.rating
	end)
	local used = {}
	for i, a in list do
		if not used[a] and services.MatchService.hasFreeArena() then
			local best, bestGap
			for j = i + 1, #list do
				local b = list[j]
				if not used[b] then
					local gap = math.abs(a.rating - b.rating)
					if gap <= math.min(window(a, now), window(b, now)) and (not best or gap < bestGap) then
						best, bestGap = b, gap
					end
				end
			end
			if best then
				used[a] = true
				used[best] = true
				startFromQueue("Ranked1v1", {
					{ player = a.player, team = 1 },
					{ player = best.player, team = 2 },
				})
			end
		end
	end
end

local function tick2v2(now)
	local list = queues.Ranked2v2
	if #list < 4 then
		return
	end
	table.sort(list, function(a, b)
		return a.rating < b.rating
	end)
	local i = 1
	while i + 3 <= #list and services.MatchService.hasFreeArena() do
		local group = { list[i], list[i + 1], list[i + 2], list[i + 3] }
		local spread = group[4].rating - group[1].rating
		local allowed = math.huge
		for _, e in group do
			allowed = math.min(allowed, window(e, now))
		end
		if spread <= allowed then
			-- Highest + lowest vs the two middle players keeps teams even.
			startFromQueue("Ranked2v2", {
				{ player = group[4].player, team = 1 },
				{ player = group[1].player, team = 1 },
				{ player = group[3].player, team = 2 },
				{ player = group[2].player, team = 2 },
			})
			-- startFromQueue removed these four, so the list shifted.
		else
			i += 1
		end
	end
end

local function tickFFA(now)
	local list = queues.FFA
	if #list == 0 or not services.MatchService.hasFreeArena() then
		return
	end
	table.sort(list, function(a, b)
		return a.joined < b.joined
	end)
	local oldestWait = now - list[1].joined
	if #list >= 4 or (#list >= 2 and oldestWait >= Config.Queue.FFAStartAfterSeconds) then
		local entries = {}
		for i = 1, math.min(4, #list) do
			table.insert(entries, { player = list[i].player, team = i })
		end
		local bots = {}
		if Config.Queue.FFAFillWithBots then
			for team = #entries + 1, 4 do
				table.insert(bots, { bot = true, difficulty = Config.Queue.FFAFillDifficulty, team = team })
			end
		end
		startFromQueue("FFA", entries, bots)
	end
end

local BOT_FORMATS = {
	Duel = { mode = "1v1", allies = 0, enemies = 1 },
	FFA = { mode = "FFA", allies = 0, enemies = 3 },
	["2v2"] = { mode = "2v2", allies = 1, enemies = 2 },
}

local function startBots(player, options)
	options = type(options) == "table" and options or {}
	local format = BOT_FORMATS[options.format] and options.format or "Duel"
	local spec = BOT_FORMATS[format]
	local difficulty = Config.Bots.Difficulties[options.difficulty] and options.difficulty or "Normal"
	local config = baseConfig(spec.mode)
	if type(options.mapId) == "string" and Maps.get(options.mapId) then
		config.mapId = options.mapId
	end
	config.source = "Bots"
	config.ranked = false
	config.participants = { { player = player, team = 1 } }
	for _ = 1, spec.allies do
		table.insert(config.participants, { bot = true, difficulty = difficulty, team = 1 })
	end
	for i = 1, spec.enemies do
		local team = spec.mode == "FFA" and (i + 1) or 2
		table.insert(config.participants, { bot = true, difficulty = difficulty, team = team })
	end
	local match, err = services.MatchService.startMatch(config)
	if not match then
		return false, err
	end
	return true, "Starting!"
end

function QueueService.join(player, queueType, options)
	if services.MatchService.getMatchOf(player) then
		return false, "You're already in a match."
	end
	if services.RoomService.getRoomOf(player) then
		return false, "Leave your custom room first."
	end
	if not services.DataService.get(player) then
		return false, "Your profile is still loading."
	end
	if queueType == "Bots" then
		QueueService.leave(player)
		return startBots(player, options)
	end
	local info = QUEUES[queueType]
	if not info then
		return false, "Unknown queue."
	end
	QueueService.leave(player)
	table.insert(queues[queueType], {
		player = player,
		joined = os.clock(),
		rating = services.ProgressionService.ratingOf(player, info.Mode),
	})
	queueOf[player] = queueType
	pushStatus(player)
	return true, "Searching for " .. info.Label .. "..."
end

function QueueService.start()
	Net.get("QueueRequest").OnServerInvoke = function(player, action, queueType, options)
		if action == "Join" then
			return QueueService.join(player, queueType, options)
		elseif action == "Leave" then
			QueueService.leave(player)
			return true, "Left the queue."
		end
		return false, "Bad request."
	end

	Players.PlayerRemoving:Connect(QueueService.leave)

	task.spawn(function()
		while true do
			task.wait(Config.Queue.TickSeconds)
			local now = os.clock()
			local ok, err = pcall(function()
				tick1v1(now)
				tick2v2(now)
				tickFFA(now)
			end)
			if not ok then
				warn("[QueueService] tick failed:", err)
			end
			for player in queueOf do
				pushStatus(player)
			end
		end
	end)
end

return QueueService
