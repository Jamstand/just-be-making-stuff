--[[
    Quick-play queues on this server.

      Ranked1v1   solo players paired by 1v1 rating; the allowed rating gap
                  widens the longer they wait, and after a while anyone will do
      Ranked2v2   duos and solos grouped by 2v2 rating into balanced teams
      FFA         up to 4 players (parties stay together); starts full, or
                  with 2-3 after a short wait (topped up with bots if
                  Config.Queue.FFAFillWithBots)
      Bots        starts at once (legend select first), for a party too

    The queue holds units: a solo player or a whole party (the leader
    queues; Party.canStart decides which sizes fit). Who plays whom is
    decided by the pure Matchmaking module every tick; a group found is
    taken out of the queue silently and handed to SelectService (legend
    select + map vote), which reserves the arena.

    Any member can cancel their unit's search. Party changes, leavers and
    ranked dodges cancel or re-queue units (onPartyChanged, requeue,
    onPlayerRemoving). Players searching per queue go to every client every
    Config.Queue.StatsSeconds (QueueStats).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Maps = require(Shared.Maps)
local Party = require(Shared.Party)
local Matchmaking = require(Shared.Matchmaking)
local MatchRules = require(Shared.MatchRules)
local Net = require(Shared.Net)

local QueueService = {}
local services

local QUEUES = {
	Ranked1v1 = { Label = "Ranked 1v1", Mode = "1v1", Ranked = true, Source = "Ranked" },
	Ranked2v2 = { Label = "Ranked 2v2", Mode = "2v2", Ranked = true, Source = "Ranked" },
	FFA = { Label = "Free-for-all", Mode = "FFA", Ranked = false, Source = "Casual" },
}
local QUEUE_ORDER = { "Ranked1v1", "Ranked2v2", "FFA" }

local BOT_FORMATS = {
	Duel = "1v1",
	["2v2"] = "2v2",
	FFA = "FFA",
}

-- QueueStats goes to a player this long after they join.
local JOIN_STATS_DELAY = 2

--[[
    unit = { id, queueType, players: { Player } (leader first), leader: Player, partyId: number?,
             rating: number (average of the members' ratings), joined: number (os.clock()) }
]]
local queues = { Ranked1v1 = {}, Ranked2v2 = {}, FFA = {} }
local unitOf = {} -- [Player] = unit
local lastJoin = {} -- [Player] = os.clock() of the last "Join" request
local nextUnitId = 0

function QueueService.init(s)
	services = s
end

function QueueService.isQueued(player)
	return unitOf[player] ~= nil
end

-- Players (not units) searching per queue.
function QueueService.stats()
	local stats = {}
	for queueType, list in queues do
		local count = 0
		for _, unit in list do
			count += #unit.players
		end
		stats[queueType] = count
	end
	return stats
end

local function toast(player, text, kind)
	if player.Parent then
		Net.get("Toast"):FireClient(player, text, kind or "info")
	end
end

local function pushStatus(player)
	if not player.Parent then
		return
	end
	local unit = unitOf[player]
	if not unit then
		Net.get("QueueUpdate"):FireClient(player, nil)
		return
	end
	local info = QUEUES[unit.queueType]
	local waited = os.clock() - unit.joined
	local window = nil
	if info.Ranked then
		local w = Matchmaking.window(waited)
		window = w ~= math.huge and math.floor(w) or nil
	end
	Net.get("QueueUpdate"):FireClient(player, {
		queue = unit.queueType,
		label = info.Label,
		waited = math.floor(waited),
		inQueue = QueueService.stats()[unit.queueType],
		waitingForArena = not services.MatchService.hasFreeArena(),
		window = window,
		partySize = #unit.players,
		leaderUserId = unit.leader.UserId,
	})
end

local function averageRating(players, mode)
	local total = 0
	for _, player in players do
		total += services.ProgressionService.ratingOf(player, mode)
	end
	return #players > 0 and total / #players or Config.Ranked.StartRating
end

-- Puts a unit in its queue (joined = os.clock() for a new search, the original time for a re-queue).
local function addUnit(queueType, players, joined)
	nextUnitId += 1
	local party = services.PartyService.getParty(players[1])
	local unit = {
		id = nextUnitId,
		queueType = queueType,
		players = players,
		-- (a re-queued unit may have lost its leader to a dodge)
		leader = party and table.find(players, party.leader) and party.leader or players[1],
		partyId = party and party.id or nil,
		rating = averageRating(players, QUEUES[queueType].Mode),
		joined = joined,
	}
	table.insert(queues[queueType], unit)
	for _, player in players do
		unitOf[player] = unit
	end
	for _, player in players do
		pushStatus(player)
	end
	return unit
end

--[[
    Takes a unit out of its queue; every member gets QueueUpdate(nil).
    opts.silent: no toast (a match was found). Otherwise the members other
    than opts.by (and opts.exclude, a set) are toasted opts.reason, or
    "<by> cancelled the search.".
]]
local function removeUnit(unit, opts)
	opts = opts or {}
	local list = queues[unit.queueType]
	local index = table.find(list, unit)
	if index then
		table.remove(list, index)
	end
	for _, player in unit.players do
		if unitOf[player] == unit then
			unitOf[player] = nil
		end
		pushStatus(player)
	end
	if opts.silent then
		return
	end
	local text = opts.reason or (opts.by and (opts.by.DisplayName .. " cancelled the search."))
	if not text then
		return
	end
	for _, player in unit.players do
		if player ~= opts.by and not (opts.exclude and opts.exclude[player]) then
			toast(player, text, "warn")
		end
	end
end

-- Cancels the player's unit (any member may), toasting the others.
function QueueService.leave(player, reason)
	local unit = unitOf[player]
	if unit then
		removeUnit(unit, { reason = reason, by = player })
	end
end

local function sameSet(a, b)
	if #a ~= #b then
		return false
	end
	for _, player in a do
		if not table.find(b, player) then
			return false
		end
	end
	return true
end

local function toSet(list)
	local set = {}
	for _, item in list or {} do
		set[item] = true
	end
	return set
end

--[[
    Party membership changed (join, leave, kick, disconnect); `changed` =
    the players who joined/left/were kicked. Cancels (reason toasted to the
    unit's other members) only a unit containing a changed player and a unit
    whose players are no longer exactly their party's current members.
]]
function QueueService.onPartyChanged(party, changed, reason)
	local changedSet = toSet(changed)
	local stale = {}
	for _, list in queues do
		for _, unit in list do
			local touched = false
			for _, player in unit.players do
				if changedSet[player] then
					touched = true
				end
			end
			if not touched and party then
				for _, player in unit.players do
					if services.PartyService.getParty(player) == party then
						touched = not sameSet(unit.players, services.PartyService.membersOf(player))
						break
					end
				end
			end
			if touched then
				table.insert(stale, unit)
			end
		end
	end
	for _, unit in stale do
		removeUnit(unit, { reason = reason, exclude = changedSet })
	end
end

--[[
    Whether a player can still go back into a queue: on the server, idle,
    not searching, not in a room. `ending` = a match that is releasing its
    players right now (Match Cleanup re-queues them once MatchService has
    forgotten it), so being in that match doesn't count as busy.
]]
local function available(player, ending)
	if player.Parent == nil or unitOf[player] ~= nil then
		return false
	end
	if ending ~= nil and services.MatchService.getMatchOf(player) == ending then
		if services.SelectService.getSessionOf(player) ~= nil then
			return false
		end
	elseif services.MatchService.busyReason(player) ~= nil then
		return false
	end
	return services.RoomService.getRoomOf(player) == nil and services.DataService.get(player) ~= nil
end

--[[
    How `units` would go back in `queueType` right now: a list of
    { players, joined, keep }. Leavers are dropped first, then players who
    are gone, busy or already elsewhere (see available). keep: the
    remaining players are exactly their party (minus the leavers) and still
    fit the queue; their list is then sorted leader first, as in a fresh
    search.
]]
local function sortOut(units, queueType, leavers, ending)
	local leaverSet = toSet(leavers)
	local list = {}
	for _, original in units do
		local players = {}
		for _, player in original.players do
			if not leaverSet[player] and available(player, ending) then
				table.insert(players, player)
			end
		end
		if #players > 0 then
			local party = {}
			for _, member in services.PartyService.membersOf(players[1]) do
				if not leaverSet[member] then
					table.insert(party, member)
				end
			end
			local keep = sameSet(players, party) and Party.canStart(queueType, nil, #players, true) == true
			if keep then
				table.sort(players, function(a, b)
					return (table.find(party, a) or 0) < (table.find(party, b) or 0)
				end)
			end
			table.insert(list, { players = players, joined = original.joined, keep = keep })
		end
	end
	return list
end

--[[
    Puts units back in `queueType` keeping their `joined` time (see
    sortOut for who is kept); the players kept are toasted keptText (kind
    keptKind) when there is one, the others are told the search was
    cancelled. Returns the set of players put back ({ [Player] = true }).
]]
local function restore(units, queueType, leavers, keptText, keptKind)
	local kept = {}
	if not units or not QUEUES[queueType] then
		return kept
	end
	for _, entry in sortOut(units, queueType, leavers) do
		if entry.keep then
			addUnit(queueType, entry.players, entry.joined)
			for _, player in entry.players do
				kept[player] = true
				if keptText then
					toast(player, keptText, keptKind)
				end
			end
		else
			for _, player in entry.players do
				toast(player, "Your party changed. Search cancelled.", "warn")
			end
		end
	end
	return kept
end

--[[
    After a ranked dodge or a server error between "match found" and the
    fight (select, VS splash): everyone else goes back in the queue.
    Returns the set of players put back. No toast for them: the Cancel or
    End they were sent says "You're back in the queue." exactly when
    wouldRequeue said they would be (requeued = true); a unit that can't be
    kept is told its search was cancelled.
]]
function QueueService.requeue(units, queueType, leavers)
	return restore(units, queueType, leavers, nil, nil)
end

--[[
    Who requeue(units, queueType, leavers) would put back right now, as a
    set of players, without changing anything. `ending` = a match about to
    release its players (they count as free). Callers ask this before
    telling the players (Cancel / End requeued) and call requeue with no
    yield in between, so the message and the queue always agree.
]]
function QueueService.wouldRequeue(units, queueType, leavers, ending)
	local kept = {}
	if not units or not QUEUES[queueType] then
		return kept
	end
	for _, entry in sortOut(units, queueType, leavers, ending) do
		if entry.keep then
			for _, player in entry.players do
				kept[player] = true
			end
		end
	end
	return kept
end

-- Starting matches ---------------------------------------------------------------

local function baseConfig(queueType)
	local info = QUEUES[queueType]
	return {
		mode = info.Mode,
		source = info.Source,
		ranked = info.Ranked,
		mapId = nil,
		mapPool = Config.Queue.MapPools[info.Mode],
		winRule = "Stocks",
		stocks = Config.Match.DefaultStocks,
		timeLimit = Config.Match.DefaultTimeLimit,
		weapons = nil,
		damageMultiplier = 1,
		friendlyFire = false,
		queueType = queueType,
		units = {},
		participants = {},
	}
end

-- Hands a group to the select phase (on failure its units go back in the queue). teams[i] = the team of units[i]'s
-- players; without `teams` (FFA) every player gets a team of their own. Bots take the teams after the players'.
local function startGroup(queueType, units, teams, bots)
	for _, unit in units do
		removeUnit(unit, { silent = true })
	end
	local config = baseConfig(queueType)
	local lastTeam = 0
	for i, unit in units do
		table.insert(
			config.units,
			{ players = table.clone(unit.players), joined = unit.joined, partyId = unit.partyId }
		)
		for _, player in unit.players do
			local team = teams and teams[i] or (lastTeam + 1)
			lastTeam = math.max(lastTeam, team)
			table.insert(config.participants, { player = player, team = team })
		end
	end
	for _ = 1, bots or 0 do
		lastTeam += 1
		table.insert(config.participants, { bot = true, difficulty = Config.Queue.FFAFillDifficulty, team = lastTeam })
	end
	local session, err = services.SelectService.begin(config)
	if not session then
		restore(config.units, queueType, nil, err or "Couldn't start the match.", "warn")
	end
end

-- The groups Matchmaking finds in one queue: { units, teams?, bots? }.
local function groupsFor(queueType, units, now)
	local groups: { any } = {}
	if queueType == "Ranked1v1" then
		for _, pair in Matchmaking.pair1v1(units, now) do
			table.insert(groups, { units = pair, teams = { 1, 2 } })
		end
	elseif queueType == "Ranked2v2" then
		for _, group in Matchmaking.group2v2(units, now) do
			local list, teams = {}, {}
			for team, side in { group.team1, group.team2 } do
				for _, unit in side do
					table.insert(list, unit)
					table.insert(teams, team)
				end
			end
			table.insert(groups, { units = list, teams = teams })
		end
	else
		for _, group in Matchmaking.groupFFA(units, now) do
			table.insert(groups, { units = group.units, bots = group.bots })
		end
	end
	return groups
end

-- Every Config.Queue.TickSeconds: start what Matchmaking finds while arenas are free, then refresh every banner.
local function tick(now)
	for _, queueType in QUEUE_ORDER do
		for _, group in groupsFor(queueType, table.clone(queues[queueType]), now) do
			if not services.MatchService.hasFreeArena() then
				break
			end
			startGroup(queueType, group.units, group.teams, group.bots)
		end
	end
	for player in unitOf do
		pushStatus(player)
	end
end

-- vs Bots: legend select at once for the whole party.
local function startBots(members, options)
	local format = BOT_FORMATS[options.format] and options.format or "Duel"
	local mode = BOT_FORMATS[format]
	local difficulty = Config.Bots.Difficulties[options.difficulty] and options.difficulty or "Normal"
	local mapId = type(options.mapId) == "string" and Maps.get(options.mapId) and options.mapId or nil
	local config = {
		mode = mode,
		source = "Bots",
		ranked = false,
		mapId = mapId,
		mapPool = mapId == nil and Config.Queue.MapPools[mode] or nil,
		winRule = "Stocks",
		stocks = Config.Match.DefaultStocks,
		timeLimit = Config.Match.DefaultTimeLimit,
		weapons = nil,
		damageMultiplier = 1,
		friendlyFire = false,
		participants = MatchRules.botsParticipants(format, members, difficulty),
		queueType = "Bots",
		botOptions = { format = format, difficulty = difficulty, mapId = mapId },
	}
	local session, err = services.SelectService.begin(config)
	if not session then
		return false, err or "Couldn't start the match."
	end
	-- nobody stays in another queue while picking a legend
	for _, member in members do
		local unit = unitOf[member]
		if unit then
			removeUnit(unit, { silent = true })
		end
	end
	return true, "Get ready!"
end

function QueueService.join(player, queueType, options)
	local info = QUEUES[queueType]
	if not info and queueType ~= "Bots" then
		return false, "Unknown queue."
	end
	options = type(options) == "table" and options or {}
	local format = queueType == "Bots" and (BOT_FORMATS[options.format] and options.format or "Duel") or nil
	local members = services.PartyService.membersOf(player)
	local ok, _, text = Party.canStart(queueType, format, #members, services.PartyService.isLeader(player))
	if not ok then
		return false, text
	end
	for _, member in members do
		if services.MatchService.busyReason(member) then
			return false, member.DisplayName .. " is busy right now."
		end
	end
	for _, member in members do
		if services.RoomService.getRoomOf(member) then
			if member == player then
				return false, "Leave your custom room first."
			end
			return false, member.DisplayName .. " is in a custom room."
		end
	end
	for _, member in members do
		if not services.DataService.get(member) then
			return false, "Your profile is still loading."
		end
	end
	if queueType == "Bots" then
		return startBots(members, options)
	end
	-- already searching: the old search is replaced
	for _, member in members do
		local unit = unitOf[member]
		if unit then
			removeUnit(unit, { silent = true })
		end
	end
	addUnit(queueType, members, os.clock())
	return true, "Searching for " .. info.Label .. "..."
end

-- Called by Main.server's PlayerRemoving coordinator. Never yields.
function QueueService.onPlayerRemoving(player)
	QueueService.leave(player, player.DisplayName .. " left. Search cancelled.")
	lastJoin[player] = nil
end

function QueueService.start()
	Net.get("QueueRequest").OnServerInvoke = function(player, action, queueType, options)
		local ok, a, b = pcall(function()
			if action == "Join" then
				local now = os.clock()
				if lastJoin[player] and now - lastJoin[player] < Config.Queue.RequestCooldown then
					return false, "Slow down."
				end
				lastJoin[player] = now
				return QueueService.join(player, queueType, options)
			elseif action == "Leave" then
				-- never rate limited
				QueueService.leave(player)
				return true, "Left the queue."
			end
			return false, "Bad request."
		end)
		if not ok then
			warn("[QueueService]", action, "failed:", a)
			return false, "Something went wrong."
		end
		return a, b
	end

	Players.PlayerAdded:Connect(function(player)
		task.delay(JOIN_STATS_DELAY, function()
			if player.Parent then
				Net.get("QueueStats"):FireClient(player, QueueService.stats())
			end
		end)
	end)

	local nextTick = os.clock() + Config.Queue.TickSeconds
	local nextStats = os.clock() + Config.Queue.StatsSeconds
	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		if now >= nextTick then
			nextTick = now + Config.Queue.TickSeconds
			local ok, err = pcall(tick, now)
			if not ok then
				warn("[QueueService] tick failed:", err)
			end
		end
		if now >= nextStats then
			nextStats = now + Config.Queue.StatsSeconds
			Net.get("QueueStats"):FireAllClients(QueueService.stats())
		end
	end)
end

return QueueService
