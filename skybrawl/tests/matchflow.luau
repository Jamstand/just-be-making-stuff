--[[
    Server match flow (menus design S1): matchmaking with parties, the
    match rules helpers, parties and invites, the queue, legend select, the
    custom room changes and the Match changes (match clock, match ids,
    pre-Start cancels, character preloads, training hooks).

    Pure modules load with h.require. Services load with h.requireServer and
    a fake game (Players with friends, RunService.Heartbeat the test fires)
    plus a test-controlled os.clock; the services around them are fakes
    (MatchService, DataService, ProgressionService, ArenaService). Remote
    traffic is read back from the harness's fake remotes.
    Run from the skybrawl folder with:  lune run tests/matchflow
]]

local roblox = require("@lune/roblox")
local task = require("@lune/task")

local h = require("./harness")

local Vector3 = roblox.Vector3
local Enum = roblox.Enum

local Combat = h.require("Combat")
local Config = h.require("Config")
local Cosmetics = h.require("Cosmetics")
local FighterSim = h.require("FighterSim")
local Matchmaking = h.require("Matchmaking")
local MatchRules = h.require("MatchRules")

-- Test clock --------------------------------------------------------------------

local clock = { now = 1000 }
local fakeOs = setmetatable({
	clock = function()
		return clock.now
	end,
}, { __index = os })

-- Helpers ----------------------------------------------------------------------

local function unit(rating, size, joined, name)
	local players = {}
	for i = 1, size or 1 do
		players[i] = (name or "u") .. i
	end
	return { players = players, rating = rating, joined = joined or 0, name = name }
end

local function profileFor(legend)
	return {
		XP = 0,
		Legend = legend or "Kestrel",
		Settings = {},
		Equipped = table.clone(Cosmetics.Defaults),
	}
end

-- Calls recorded on a fake remote, optionally only those to `player`.
local function calls(remoteName, player)
	local list = {}
	for _, call in h.remote(remoteName).calls do
		if player == nil or call.player == player then
			table.insert(list, call)
		end
	end
	return list
end

local function toasts(player)
	local list = {}
	for _, call in calls("Toast", player) do
		table.insert(list, call.args[1])
	end
	return list
end

local function hasToast(player, text)
	return table.find(toasts(player), text) ~= nil
end

-- SelectEvent payloads of one kind sent to `player`.
local function selectEvents(player, kind)
	local list = {}
	for _, call in calls("SelectEvent", player) do
		if call.args[1] == kind then
			table.insert(list, call.args[2])
		end
	end
	return list
end

local function lastPartyUpdate(player)
	local list = calls("PartyUpdate", player)
	return list[#list] and list[#list].args[1]
end

local function lastQueueUpdate(player)
	local list = calls("QueueUpdate", player)
	return list[#list] and list[#list].args[1]
end

--[[
    A server with the real PartyService, QueueService, SelectService and
    RoomService and fakes around them. w:player(id, name) joins a player
    (with a profile); w:run(seconds) moves the clock in 1/16 s steps and
    fires Heartbeat each step; w:remove(player) runs the PlayerRemoving
    coordinator (opts.order to change the order).
]]
local REMOVAL_ORDER = { "SelectService", "MatchService", "QueueService", "RoomService", "PartyService" }

local function newWorld(opts)
	opts = opts or {}
	h.resetRemotes()
	clock.now = 1000
	local game = h.fakeGame()
	local players = game:GetService("Players")
	local w = {
		game = game,
		players = players,
		friends = {}, -- [userId] = { friend user ids } (read when a player joins)
		profiles = {},
		ratings = {}, -- [Player] = { ["1v1"] = n, ["2v2"] = n }
		leavers = {}, -- applyLeaver calls
		started = {}, -- startMatch calls
		released = {}, -- released arena slots
		inUse = {},
		arenas = opts.arenas or 8,
		playerMatch = {},
	}
	function players.GetFriendsAsync(_, userId)
		if w.friendsDelay then
			task.wait(w.friendsDelay) -- (the set stays "loading" meanwhile)
		end
		local items = {}
		for _, id in w.friends[userId] or {} do
			table.insert(items, { Id = id })
		end
		return {
			IsFinished = true,
			GetCurrentPage = function()
				return items
			end,
			AdvanceToNextPageAsync = function() end,
		}
	end

	local services = {}
	w.services = services
	services.DataService = {
		get = function(player)
			return w.profiles[player]
		end,
		update = function(player, fn)
			local profile = w.profiles[player]
			if profile then
				return fn(profile)
			end
			return nil
		end,
	}
	services.ProgressionService = {
		ratingOf = function(player, mode)
			return w.ratings[player] and w.ratings[player][mode] or 1000
		end,
		applyLeaver = function(player, mode, rating, legend)
			table.insert(w.leavers, { player = player, mode = mode, rating = rating, legend = legend })
		end,
	}
	services.ArenaService = {
		acquire = function()
			for slot = 1, w.arenas do
				if not w.inUse[slot] then
					w.inUse[slot] = true
					return slot, Vector3.new(slot * 2500, 300, 0)
				end
			end
			return nil
		end,
		release = function(slot)
			w.inUse[slot] = nil
			table.insert(w.released, slot)
		end,
		freeSlots = function()
			local free = 0
			for slot = 1, w.arenas do
				if not w.inUse[slot] then
					free += 1
				end
			end
			return free
		end,
	}
	services.MatchService = {
		getMatchOf = function(player)
			return w.playerMatch[player]
		end,
		busyReason = function(player)
			local match = w.playerMatch[player]
			if match then
				return match.training and "You're in the training room." or "You're in a match."
			end
			if services.SelectService.getSessionOf(player) then
				return "You're picking a legend."
			end
			return nil
		end,
		hasFreeArena = function()
			return services.ArenaService.freeSlots("Match") > 0
		end,
		startMatch = function(config, reserved)
			if w.startMatchError then
				error("boom")
			end
			local record = { config = config, reserved = reserved, busy = {} }
			for _, p in config.participants do
				if p.player then
					record.busy[p.player] = services.MatchService.busyReason(p.player)
				end
			end
			table.insert(w.started, record)
			local match = w.makeMatch and w.makeMatch(config, reserved) or { id = 100 + #w.started, config = config }
			for _, p in config.participants do
				if p.player then
					w.playerMatch[p.player] = match
				end
			end
			return match
		end,
		onPlayerRemoving = function(player)
			w.playerMatch[player] = nil
		end,
	}
	local globals = { game = game, os = fakeOs }
	for _, name in { "PartyService", "QueueService", "SelectService", "RoomService" } do
		services[name] = h.requireServer(name, globals)
	end
	for _, name in { "PartyService", "QueueService", "SelectService", "RoomService" } do
		services[name].init(services)
	end
	for _, name in { "PartyService", "QueueService", "SelectService", "RoomService" } do
		services[name].start()
	end

	function w.player(_, userId, name)
		local player = h.fakePlayer(userId, name)
		w.profiles[player] = profileFor()
		players:_add(player)
		return player
	end

	function w.run(_, seconds)
		local steps = math.max(1, math.floor(seconds * 16 + 0.5))
		local heartbeat = game:GetService("RunService").Heartbeat
		for _ = 1, steps do
			clock.now += 1 / 16
			heartbeat:Fire(1 / 16)
		end
	end

	function w.remove(_, player, order)
		for _, name in order or REMOVAL_ORDER do
			services[name].onPlayerRemoving(player)
		end
		w.profiles[player] = nil
		players:_remove(player)
	end

	function w.party(_, player, action, payload)
		return h.remote("PartyRequest").OnServerInvoke(player, action, payload)
	end

	function w.queue(_, player, action, queueType, options)
		return h.remote("QueueRequest").OnServerInvoke(player, action, queueType, options)
	end

	function w.room(_, player, action, payload)
		return h.remote("RoomRequest").OnServerInvoke(player, action, payload)
	end

	function w.select(_, player, kind, data)
		h.remote("SelectAction").OnServerEvent:Fire(player, kind, data)
	end

	-- Ann invites Ben, Ben accepts.
	function w.makeParty(_, leader, ...)
		for _, member in { ... } do
			local ok, message = w:party(leader, "Invite", member.UserId)
			h.expect(ok, "invite: " .. tostring(message))
			ok, message = w:party(member, "Accept", services.PartyService.getParty(leader).id)
			h.expect(ok, "accept: " .. tostring(message))
		end
		return services.PartyService.getParty(leader)
	end

	return w
end

-- A Match with fake services around it. w.match(config?, reserved?) builds one.
local function matchWorld()
	h.resetRemotes()
	clock.now = 50
	local game = h.fakeGame()
	local w = {
		game = game,
		profiles = {},
		playerMatch = {},
		released = {},
		requeued = {},
		asked = {}, -- wouldRequeue calls
		dropped = {}, -- [Player] = true: the fake requeue wouldn't keep them (their party changed...)
		leavers = {},
		applied = {},
	}
	local function fakeFolder()
		return {
			destroyed = false,
			Destroy = function(self)
				self.destroyed = true
			end,
			FindFirstChild = function()
				return nil
			end,
		}
	end
	w.services = {
		ArenaService = {
			acquire = function()
				return 3, Vector3.new(7500, 300, 0)
			end,
			release = function(slot)
				table.insert(w.released, slot)
			end,
			buildMap = function()
				if w.mapFails then
					error("map failed")
				end
				return fakeFolder()
			end,
		},
		MatchService = {
			getMatchOf = function(player)
				return w.playerMatch[player]
			end,
		},
		DataService = {
			get = function(player)
				return w.profiles[player]
			end,
		},
		ProgressionService = {
			ratingOf = function()
				return 1000
			end,
			applyLeaver = function(player, mode, rating, legend)
				table.insert(w.leavers, { player = player, mode = mode, rating = rating, legend = legend })
			end,
			applyMatch = function(info, entries)
				table.insert(w.applied, { info = info, entries = entries })
				return {}
			end,
		},
		CharacterService = {
			setupCharacter = function() end,
			setNameplate = function() end,
			setTeamColor = function() end,
			applyTrail = function() end,
		},
		QueueService = {
			requeue = function(units, queueType, leavers)
				table.insert(w.requeued, { units = units, queueType = queueType, leavers = leavers })
			end,
			-- keeps every unit player who isn't a leaver or in w.dropped
			wouldRequeue = function(units, queueType, leavers, ending)
				table.insert(w.asked, { units = units, queueType = queueType, leavers = leavers, ending = ending })
				local kept = {}
				for _, u in units do
					for _, player in u.players do
						if not table.find(leavers or {}, player) and not w.dropped[player] then
							kept[player] = true
						end
					end
				end
				return kept
			end,
		},
	}
	w.Match = h.requireServer("Match", { game = game, os = fakeOs })
	function w.match(config, reserved)
		local base = {
			mode = "1v1",
			source = "Ranked",
			ranked = false,
			mapId = "DuelRock",
			winRule = "Stocks",
			stocks = 3,
			timeLimit = 480,
			damageMultiplier = 1,
			friendlyFire = false,
			participants = {},
		}
		for key, value in config or {} do
			base[key] = value
		end
		return w.Match.new(7, base, w.services, reserved)
	end
	function w.player(userId, name)
		local player = h.fakePlayer(userId, name)
		w.profiles[player] = profileFor()
		return player
	end
	-- What MatchService does for a match it started: playerMatch entries, cleared on a forfeit and at Cleanup.
	function w.track(m, ...)
		for _, player in { ... } do
			w.playerMatch[player] = m
		end
		m.onPlayerLeft = function(player)
			if w.playerMatch[player] == m then
				w.playerMatch[player] = nil
			end
		end
		m.onFinished = function()
			w.finished = (w.finished or 0) + 1
			for player, other in w.playerMatch do
				if other == m then
					w.playerMatch[player] = nil
				end
			end
		end
	end
	return w
end

-- Waits (real time, up to `seconds`) until condition() holds; every 0.05 s step also moves the test clock by `advance`.
local function waitUntil(condition, seconds, advance)
	for _ = 1, math.ceil((seconds or 1) / 0.05) do
		if condition() then
			return true
		end
		clock.now += advance or 0
		task.wait(0.05)
	end
	return condition()
end

-- A fake character: alive humanoid, root part, attributes.
local function fakeCharacter()
	local attributes = {}
	local humanoid = {
		Health = 100,
		MaxHealth = 100,
		RigType = Enum.HumanoidRigType.R15,
		HipHeight = 2,
		Died = h.signal(),
	}
	local root = { Size = Vector3.new(2, 2, 1) }
	local character = { HumanoidRootPart = root, destroyed = false }
	function character.FindFirstChildOfClass(_, className)
		return className == "Humanoid" and humanoid or nil
	end
	function character.FindFirstChild(_, name)
		return name == "HumanoidRootPart" and root or nil
	end
	function character.SetAttribute(_, key, value)
		attributes[key] = value
	end
	function character.GetAttribute(_, key)
		return attributes[key]
	end
	function character.PivotTo() end
	function character.Destroy(self)
		self.destroyed = true
	end
	return character
end

--[[
    Real Matches in a newWorld: its startMatch builds one (fakes around it
    for the arena, characters and nameplates) and adds it to w.matches; the
    test runs its Start.
]]
local function useRealMatches(w)
	local Match = h.requireServer("Match", { game = w.game, os = fakeOs })
	w.matches = {}
	local services = setmetatable({
		ArenaService = setmetatable({
			buildMap = function()
				return {
					Destroy = function() end,
					FindFirstChild = function()
						return nil
					end,
				}
			end,
		}, { __index = w.services.ArenaService }),
		CharacterService = {
			setupCharacter = function() end,
			setNameplate = function() end,
			setTeamColor = function() end,
			applyTrail = function() end,
		},
	}, { __index = w.services })
	function w.makeMatch(config, reserved)
		local match = Match.new(200 + #w.matches, config, services, reserved)
		for _, p in config.participants do
			if p.player then
				match:AddPlayer(p.player, p.team, { legend = p.legend, ownLook = p.ownLook })
			end
		end
		-- what MatchService does: forget a player who forfeits, and everyone at Cleanup
		match.onPlayerLeft = function(player)
			if w.playerMatch[player] == match then
				w.playerMatch[player] = nil
			end
		end
		match.onFinished = function()
			for player, other in w.playerMatch do
				if other == match then
					w.playerMatch[player] = nil
				end
			end
		end
		table.insert(w.matches, match)
		return match
	end
end

-- Matchmaking ------------------------------------------------------------------

h.test("pair1v1 pairs solos inside the rating window", function()
	local a, b, c = unit(1000, 1, 0, "a"), unit(1050, 1, 0, "b"), unit(1500, 1, 0, "c")
	local pairs = Matchmaking.pair1v1({ c, b, a }, 0)
	h.expect(#pairs == 1, "expected one pair, got " .. #pairs)
	h.expect(pairs[1][1] == a and pairs[1][2] == b, "the lower rating comes first")
	h.expect(Matchmaking.window(0) == Config.Queue.RatingWindowStart, "window at 0 s")
end)

h.test("pair1v1 widens the window the longer they wait", function()
	local a, b = unit(1000, 1, 0, "a"), unit(1300, 1, 0, "b")
	h.expect(#Matchmaking.pair1v1({ a, b }, 5) == 0, "a 300 gap paired after 5 s (window 200)")
	h.expect(#Matchmaking.pair1v1({ a, b }, 10) == 1, "a 300 gap not paired after 10 s (window 300)")
	local far = unit(4000, 1, 0, "far")
	h.expect(#Matchmaking.pair1v1({ a, far }, Config.Queue.AnyoneAfterSeconds - 1) == 0, "the window is capped")
	h.expect(#Matchmaking.pair1v1({ a, far }, Config.Queue.AnyoneAfterSeconds) == 1, "anyone after the wait")
	h.expect(Matchmaking.window(Config.Queue.AnyoneAfterSeconds) == math.huge, "window after the wait")
end)

h.test("pair1v1 ignores parties", function()
	local solo, duo = unit(1000, 1, 0, "solo"), unit(1000, 2, 0, "duo")
	h.expect(#Matchmaking.pair1v1({ solo, duo }, 100) == 0, "a duo was paired in 1v1")
end)

h.test("group2v2 keeps a duo on one team", function()
	local d1, d2 = unit(1000, 2, 0, "d1"), unit(1040, 2, 0, "d2")
	local groups = Matchmaking.group2v2({ d1, d2 }, 0)
	h.expect(#groups == 1, "expected one group")
	local g = groups[1]
	h.expect(#g.team1 == 1 and #g.team2 == 1, "each duo is a whole team")
	h.expect((g.team1[1] == d1 and g.team2[1] == d2) or (g.team1[1] == d2 and g.team2[1] == d1), "duo vs duo")
	h.expect(#Matchmaking.group2v2({ d1, unit(1500, 2, 0, "x") }, 0) == 0, "duos outside the window matched")
end)

h.test("group2v2 puts a duo against two solos", function()
	local duo = unit(1000, 2, 0, "duo")
	local s1, s2, s3 = unit(980, 1, 0, "s1"), unit(1030, 1, 0, "s2"), unit(1600, 1, 0, "s3")
	local groups = Matchmaking.group2v2({ s3, s1, duo, s2 }, 0)
	h.expect(#groups == 1, "expected one group, got " .. #groups)
	local g = groups[1]
	h.expect(#g.team1 == 1 and g.team1[1] == duo, "the duo is team 1")
	h.expect(#g.team2 == 2 and table.find(g.team2, s1) and table.find(g.team2, s2), "the two close solos are team 2")
	local far1, far2 = unit(1500, 1, 0, "f1"), unit(1520, 1, 0, "f2")
	h.expect(#Matchmaking.group2v2({ duo, far1, far2 }, 0) == 0, "a duo met two solos outside the window")
end)

h.test("group2v2 balances four solos highest and lowest against the middle two", function()
	local a, b, c, d = unit(1000, 1, 0, "a"), unit(1020, 1, 0, "b"), unit(1040, 1, 0, "c"), unit(1060, 1, 0, "d")
	local groups = Matchmaking.group2v2({ c, a, d, b }, 0)
	h.expect(#groups == 1, "expected one group")
	local g = groups[1]
	h.expect(table.find(g.team1, d) and table.find(g.team1, a), "highest + lowest on team 1")
	h.expect(table.find(g.team2, c) and table.find(g.team2, b), "the middle two on team 2")
end)

h.test("groupFFA never splits a party", function()
	local three, two = unit(1000, 3, 0, "three"), unit(1000, 2, 1, "two")
	local groups = Matchmaking.groupFFA({ two, three }, Config.Queue.FFAStartAfterSeconds + 5)
	h.expect(#groups == 2, "expected two groups, got " .. #groups)
	for _, group in groups do
		local players = 0
		for _, u in group.units do
			players += #u.players
		end
		h.expect(players <= 4, "a group has more than 4 players")
		h.expect(#group.units == 1, "a party was combined with one that doesn't fit")
		h.expect(group.bots == 4 - players, "bots fill the group")
	end
	h.expect(groups[1].units[1] == three, "the oldest unit's group comes first")
end)

h.test("groupFFA starts 2+ players after the wait and fills with bots", function()
	local a, b = unit(1000, 1, 0, "a"), unit(1000, 1, 2, "b")
	h.expect(#Matchmaking.groupFFA({ a, b }, Config.Queue.FFAStartAfterSeconds - 1) == 0, "started too early")
	local groups = Matchmaking.groupFFA({ a, b }, Config.Queue.FFAStartAfterSeconds)
	h.expect(#groups == 1 and #groups[1].units == 2, "expected one group of two")
	h.expect(groups[1].bots == 2, "two bots fill it")
	local alone = Matchmaking.groupFFA({ unit(1000, 1, 0, "alone") }, 1000)
	h.expect(#alone == 0, "a single player started an FFA")
end)

h.test("groupFFA starts a party of 4 at once", function()
	local four = unit(1000, 4, 0, "four")
	local groups = Matchmaking.groupFFA({ four }, 0)
	h.expect(#groups == 1 and groups[1].units[1] == four and groups[1].bots == 0, "a full party waited")
end)

-- MatchRules ---------------------------------------------------------------------

h.test("botsParticipants puts the party on team 1 for 2v2 and fills with bots", function()
	local function teams(list)
		local out = {}
		for _, p in list do
			table.insert(out, (p.player and p.player or "bot") .. ":" .. p.team)
		end
		return table.concat(out, ",")
	end
	h.expect(teams(MatchRules.botsParticipants("2v2", { "a", "b" }, "Hard")) == "a:1,b:1,bot:2,bot:2", "duo")
	h.expect(teams(MatchRules.botsParticipants("2v2", { "a" }, "Hard")) == "a:1,bot:1,bot:2,bot:2", "solo")
	h.expect(teams(MatchRules.botsParticipants("Duel", { "a" }, "Easy")) == "a:1,bot:2", "duel")
	for _, p in MatchRules.botsParticipants("2v2", { "a" }, "Hard") do
		h.expect(p.player or (p.bot and p.difficulty == "Hard"), "bots get the difficulty")
	end
end)

h.test("botsParticipants gives everyone their own team in FFA", function()
	local list = MatchRules.botsParticipants("FFA", { "a", "b" }, "Normal")
	h.expect(#list == 4, "four fighters")
	local seen = {}
	for i, p in list do
		h.expect(p.team == i and not seen[p.team], "team " .. p.team .. " at " .. i)
		seen[p.team] = true
		h.expect((i <= 2) == (p.player ~= nil), "humans first, then bots")
	end
end)

h.test("mvp picks most KOs, then damage dealt", function()
	local rows = {
		{ id = "a", kos = 2, damageDealt = 50 },
		{ id = "b", kos = 3, damageDealt = 10 },
		{ id = "c", kos = 3, damageDealt = 90 },
	}
	h.expect(MatchRules.mvp(rows) == "c", "most KOs, then damage")
	h.expect(
		MatchRules.mvp({ { id = "a", kos = 0, damageDealt = 5 }, { id = "b", kos = 0, damageDealt = 0 } }) == "a",
		"damage"
	)
end)

h.test("mvp is nil when nobody did anything", function()
	h.expect(
		MatchRules.mvp({ { id = "a", kos = 0, damageDealt = 0 }, { id = "b", kos = 0, damageDealt = 0 } }) == nil,
		"mvp"
	)
	h.expect(MatchRules.mvp({}) == nil, "empty")
end)

h.test("roomTeams keeps a party together when the team has space", function()
	local function same(a, b)
		return table.concat(a, ",") == table.concat(b, ",")
	end
	h.expect(same(MatchRules.roomTeams("2v2", { { team = 1 } }, 2), { 2, 2 }), "the free team takes the party")
	h.expect(same(MatchRules.roomTeams("2v2", {}, 2), { 1, 1 }), "an empty room")
	h.expect(same(MatchRules.roomTeams("2v2", { { team = 2 } }, 3), { 1, 1, 2 }), "overflow to the other team")
	h.expect(same(MatchRules.roomTeams("1v1", {}, 2), { 1, 2 }), "1v1 sides")
	h.expect(same(MatchRules.roomTeams("FFA", { { team = 1 }, { team = 3 } }, 2), { 2, 4 }), "FFA free teams")
	h.expect(MatchRules.easiestBot({ "Hard", "Normal" }) == "Normal" and MatchRules.easiestBot({}) == nil, "easiestBot")
end)

-- Match --------------------------------------------------------------------------

h.test("Match:now runs at the time scale and stays continuous when it changes", function()
	local w = matchWorld()
	local m = w.match()
	h.expect(m:now() == 50, "starts at os.clock")
	clock.now = 52
	h.expect(m:now() == 52, "scale 1 follows os.clock")
	m:SetTimeScale(0.5)
	h.expect(m:now() == 52, "continuous at the change")
	clock.now = 54
	h.expect(m:now() == 53, "half speed")
	m:SetTimeScale(1)
	clock.now = 55
	h.expect(m:now() == 54, "back to full speed without a jump")
	local sent = calls("MatchEvent")
	h.expect(#sent == 0, "TimeScale went to a match without players")
end)

h.test("Match.new releases its slot when the map fails to build", function()
	local w = matchWorld()
	w.mapFails = true
	local ok = pcall(w.match)
	h.expect(not ok, "Match.new didn't fail")
	h.expect(#w.released == 1 and w.released[1] == 3, "the acquired slot wasn't released")
	local reservedOk = pcall(w.match, nil, { slot = 5, origin = Vector3.new(0, 0, 0) })
	h.expect(not reservedOk and #w.released == 1, "a reserved slot was released by the match")
	w.mapFails = false
	local m = w.match(nil, { slot = 5, origin = Vector3.new(1, 2, 3), startAt = 60 })
	h.expect(m.slot == 5 and not m.ownsSlot and m.startAt == 60, "reserved slot and startAt")
end)

h.test("every MatchEvent carries the match id", function()
	local w = matchWorld()
	local m = w.match({ training = {} })
	local ann = w.player(1, "Ann")
	local f = m:AddPlayer(ann, 1)
	m:Broadcast("Countdown", { n = 3 })
	m:Send(ann, "Leave")
	m:SetTimeScale(0.5)
	m:SetDamage(f, 40)
	m:SetDamage(f, 0 / 0)
	m:SetLegend(f, "Vex", true)
	local sent = calls("MatchEvent", ann)
	h.expect(#sent == 5, "expected 5 events, got " .. #sent)
	for _, call in sent do
		h.expect(type(call.args[2]) == "table" and call.args[2].matchId == m.id, call.args[1] .. " without matchId")
	end
	h.expect(sent[4].args[2].total == 40 and f.damage == 40, "Damage event")
	h.expect(sent[5].args[1] == "Legend" and sent[5].args[2].legend == "Vex" and sent[5].args[2].ownLook, "Legend")
end)

h.test("a pre-Start abandon sends SelectEvent Cancel instead of End", function()
	local w = matchWorld()
	local ann, ben = w.player(1, "Ann"), w.player(2, "Ben")
	local cid, dee = w.player(3, "Cid"), w.player(4, "Dee")
	local units = {
		{ players = { ann }, joined = 1 },
		{ players = { ben }, joined = 1 },
		{ players = { cid }, joined = 1 },
		{ players = { dee }, joined = 1 },
	}
	local m = w.match({ mode = "2v2", ranked = true, selectId = 9, units = units, queueType = "Ranked2v2" })
	m:AddPlayer(ann, 1)
	m:AddPlayer(ben, 2)
	m:AddPlayer(cid, 1)
	m:AddPlayer(dee, 2)
	w.track(m, ann, ben, cid, dee)
	m.startSent[ann], m.startSent[cid] = true, true
	-- Cid's and Dee's units can't go back (their parties changed meanwhile): nobody tells them otherwise
	w.dropped[cid], w.dropped[dee] = true, true
	m:Finish("Abandoned", 0, { requeue = true, reason = "Eve left before the fight." })
	local annEvents = calls("MatchEvent", ann)
	h.expect(#annEvents == 2 and annEvents[1].args[1] == "End" and annEvents[2].args[1] == "Leave", "Ann: End, Leave")
	local endData = annEvents[1].args[2]
	h.expect(endData.requeued == true and endData.returnIn == 0 and endData.matchId == m.id, "End fields")
	h.expect(endData.note == "Eve left before the fight.", "End note")
	h.expect(endData.postMatch.queueType == "Ranked2v2" and endData.mapId == "DuelRock", "postMatch")
	h.expect(calls("MatchEvent", cid)[1].args[2].requeued == false, "Cid's End says he's back in the queue")
	h.expect(#calls("MatchEvent", ben) == 0, "Ben got a MatchEvent before Start")
	local cancels = selectEvents(ben, "Cancel")
	h.expect(#cancels == 1, "Ben got no Cancel")
	h.expect(cancels[1].id == 9 and cancels[1].reason == "Eve left before the fight." and cancels[1].requeued, "Cancel")
	local deeCancel = selectEvents(dee, "Cancel")[1]
	h.expect(deeCancel and deeCancel.requeued == false, "Dee's Cancel says she's back in the queue")
	h.expect(#w.asked == 1 and w.asked[1].ending == m and #w.asked[1].leavers == 0, "wouldRequeue")
	h.expect(#w.released == 1 and #w.requeued == 1 and w.requeued[1].units == units, "slot and requeue")
end)

h.test("Forfeit on an ended match sends nothing", function()
	local w = matchWorld()
	local m = w.match({ ranked = true, selectId = 4 })
	local ann = w.player(1, "Ann")
	local f = m:AddPlayer(ann, 1)
	w.playerMatch[ann] = m
	m:Finish("Abandoned", 3)
	local before = #calls("MatchEvent") + #calls("SelectEvent") + #calls("Toast")
	m:Forfeit(f)
	m:RemovePlayer(ann)
	local after = #calls("MatchEvent") + #calls("SelectEvent") + #calls("Toast")
	h.expect(after == before, "Forfeit sent something after the end")
	h.expect(not f.left and #w.leavers == 0, "Forfeit changed an ended match")
end)

h.test("a preload is never followed by a second LoadCharacterAsync", function()
	local w = matchWorld()
	local m = w.match()
	local ann = w.player(1, "Ann")
	local loads = 0
	function ann.LoadCharacterAsync(self)
		loads += 1
		task.wait(0.15)
		self.Character = fakeCharacter()
	end
	-- Ben still has a live character: no load at all
	local ben = w.player(2, "Ben")
	ben.Character = fakeCharacter()
	function ben.LoadCharacterAsync()
		error("Ben was loaded")
	end
	m:AddPlayer(ann, 1, { ownLook = true })
	m:AddPlayer(ben, 2, { legend = "Avatar" })
	w.playerMatch[ann], w.playerMatch[ben] = m, m
	task.spawn(m.Start, m)
	h.expect(m.playerFighters[ann].loading, "no preload started")
	for _ = 1, 40 do
		if m.startSent[ann] then
			break
		end
		task.wait(0.05)
	end
	h.expect(m.startSent[ann] and m.startSent[ben], "Start wasn't sent")
	h.expect(loads == 1, "LoadCharacterAsync ran " .. loads .. " times")
	h.expect(m.playerFighters[ann].model == ann.Character, "the preloaded character wasn't used")
	h.expect(m.playerFighters[ben].legend == "Avatar", "the select pick wasn't used")
	local start = calls("MatchEvent", ann)[1].args[2]
	h.expect(start.training == false and start.timeScale == 1 and start.matchId == m.id, "Start fields")
	local character = ann.Character
	m:Finish("Abandoned", 0)
	h.expect(ann.Character == nil and character.destroyed, "Cleanup didn't release the character")
end)

h.test("Respawn carries the fighter's damage", function()
	local w = matchWorld()
	local order = {}
	local room = {}
	function room.Attach(_, match)
		table.insert(order, "Attach:" .. match.id)
	end
	function room.OnRespawn(_, f)
		table.insert(order, "OnRespawn")
		f.damage = 42
	end
	local m = w.match({ training = room, winRule = "Timed", stocks = 0, timeLimit = 0 })
	local ann = w.player(1, "Ann")
	m:AddPlayer(ann, 1)
	local dummy = m:AddBot("Normal", 2, "Training Dummy", "Brann", { dummy = true })
	h.expect(dummy.isDummy and dummy.legend == "Brann" and dummy.title == "Training Dummy", "dummy bot")
	dummy.state = FighterSim.newState(0, 0, 1)
	m.phase = "Playing"
	dummy.alive = false
	dummy.damage = 80
	m:Respawn(dummy)
	local events = calls("MatchEvent", ann)
	local respawn = events[#events].args[2]
	h.expect(events[#events].args[1] == "Respawn" and respawn.damage == 42, "Respawn lost the kept damage")
	h.expect(order[1] == "Attach:7" and order[2] == "OnRespawn", "hooks: " .. table.concat(order, ","))
	dummy.damage = 77
	m:PlaceFighter(dummy, 5, 6, -1, 0)
	events = calls("MatchEvent", ann)
	local placed = events[#events].args[2]
	h.expect(placed.damage == 77 and placed.x == 5 and placed.facing == -1 and dummy.alive, "PlaceFighter")
end)

h.test("hits record damage per weapon and count a true combo once", function()
	local w = matchWorld()
	local m = w.match()
	local attacker = m:AddBot("Normal", 1)
	local target = m:AddBot("Normal", 2)
	for _ = 1, 4 do
		h.expect(m:ApplyHit(attacker, target, Combat.ThrowMove, 0, 1, nil, true, "Sword"), "a hit didn't land")
	end
	m:ApplyHit(attacker, target, Combat.ThrowMove, 0, 1)
	h.expect(attacker.trueCombos == 1, "true combos: " .. attacker.trueCombos)
	h.expect(attacker.maxCombo == 5, "max combo: " .. attacker.maxCombo)
	h.expect(attacker.damageByWeapon.Sword > 0 and attacker.damageByWeapon.Unarmed > 0, "damage per weapon")
	local total = attacker.damageByWeapon.Sword + attacker.damageByWeapon.Unarmed
	h.expect(math.abs(total - attacker.damageDealt) < 1e-6, "weapon damage doesn't add up to damage dealt")
	-- a combo that breaks before the third hit isn't true
	clock.now += 30
	local other = m:AddBot("Normal", 2)
	m:ApplyHit(attacker, other, Combat.ThrowMove, 0, 1)
	clock.now += other.hitstunUntil - m:now() + 0.1 -- after the hitstun, inside the combo grace
	m:ApplyHit(attacker, other, Combat.ThrowMove, 0, 1)
	m:ApplyHit(attacker, other, Combat.ThrowMove, 0, 1)
	h.expect(other.comboCount == 3 and not other.comboTrue and attacker.trueCombos == 1, "a string counted as true")
end)

h.test("a finished match reports mission stats, the mvp and the post-match options", function()
	local w = matchWorld()
	local m = w.match({
		source = "Bots",
		mode = "FFA",
		queueType = "Bots",
		botOptions = { format = "FFA", difficulty = "Hard" },
		selectId = 3,
	})
	local ann = w.player(1, "Ann")
	local f = m:AddPlayer(ann, 1, { legend = "Yuki" })
	local easy = m:AddBot("Easy", 2)
	m:AddBot("Hard", 3)
	m.startSent[ann] = true
	w.playerMatch[ann] = m
	m.phase = "Playing"
	m.playStartedAt = clock.now
	f.kos = 2
	f.damageByWeapon.Spear = 30
	easy.kos = 1
	clock.now += 40
	m:Finish("Decided")
	h.expect(#w.applied == 1, "rewards weren't applied")
	local info, entry = w.applied[1].info, w.applied[1].entries[1]
	h.expect(info.minBotDifficulty == "Easy" and info.queueType == "Bots" and info.training == false, "info")
	h.expect(info.duration == 40 and info.mapId == "DuelRock" and info.damageMultiplier == 1, "info fields")
	h.expect(entry.legend == "Yuki" and entry.weaponDamage.Spear == 30 and entry.trueCombos == 0, "entry")
	h.expect(entry.placement ~= nil and entry.damageTaken == 0 and entry.ownLook == false, "entry fields")
	local endData = calls("MatchEvent", ann)[1].args[2]
	h.expect(endData.mvpId == f.id and endData.returnIn == Config.Match.EndLingerSeconds, "mvp and linger")
	h.expect(endData.postMatch.queueType == "Bots" and endData.postMatch.botOptions.difficulty == "Hard", "postMatch")
	local mvps = 0
	for _, row in endData.results do
		h.expect(row.userId ~= nil and row.legend ~= nil and row.damageTaken ~= nil, "result row fields")
		if row.mvp then
			mvps += 1
		end
	end
	h.expect(mvps == 1, "one mvp row")
end)

h.test("a fighter whose character can't load is dropped without a loss and everyone is re-queued", function()
	local w = matchWorld()
	local ann, ben = w.player(1, "Ann"), w.player(2, "Ben")
	local units = { { players = { ann }, joined = 1 }, { players = { ben }, joined = 1 } }
	local m = w.match({ ranked = true, selectId = 5, units = units, queueType = "Ranked1v1" })
	local loads = 0
	function ann.LoadCharacterAsync()
		loads += 1 -- returns without a character (the server couldn't build one)
	end
	ben.Character = fakeCharacter()
	local benCharacter = ben.Character
	m:AddPlayer(ann, 1, { ownLook = true })
	m:AddPlayer(ben, 2, { legend = "Avatar" })
	w.track(m, ann, ben)
	task.spawn(m.Start, m)
	h.expect(
		waitUntil(function()
			return m.phase == "Ended"
		end, 2, 1),
		"the match didn't end"
	)
	h.expect(loads == 2, "loads: " .. loads .. " (the preload, then one more try)")
	h.expect(#w.leavers == 0, "a fighter the server couldn't load took a loss")
	local annCancel = selectEvents(ann, "Cancel")[1]
	h.expect(annCancel and annCancel.id == 5 and annCancel.reason == "Couldn't load your fighter.", "Ann's Cancel")
	-- (not a leaver: she goes back in the queue with Ben, and is told so)
	h.expect(annCancel.requeued == true, "Ann wasn't told she's re-queued")
	local benCancel = selectEvents(ben, "Cancel")[1]
	h.expect(benCancel and benCancel.reason == "A fighter couldn't load." and benCancel.requeued, "Ben's Cancel")
	for _, call in calls("MatchEvent") do
		h.expect(call.args[1] ~= "Start" and call.args[1] ~= "End", call.args[1] .. " went out before Start")
	end
	h.expect(#w.requeued == 1 and w.requeued[1].units == units, "the units weren't re-queued")
	h.expect(#w.requeued[1].leavers == 0, "the fighter who couldn't load counts as a leaver")
	h.expect(benCharacter.destroyed and ben.Character == nil, "Ben's character wasn't released")
	h.expect(#w.released == 1 and w.playerMatch[ben] == nil, "Cleanup didn't run")
end)

h.test("a ranked dodge before Start costs a loss, sends Cancel and re-queues the others", function()
	local function setup(w)
		local ann, ben = w.player(1, "Ann"), w.player(2, "Ben")
		local units = { { players = { ann }, joined = 1 }, { players = { ben }, joined = 1 } }
		local m = w.match({ ranked = true, selectId = 6, units = units, queueType = "Ranked1v1" })
		ann.Character, ben.Character = fakeCharacter(), fakeCharacter()
		local f = m:AddPlayer(ann, 1, { legend = "Moss" })
		m:AddPlayer(ben, 2)
		w.track(m, ann, ben)
		return m, f, ann, ben
	end
	-- the "Forfeit" action (or a death) on the VS splash
	local w = matchWorld()
	local m, f, ann, ben = setup(w)
	local annCharacter, benCharacter = ann.Character, ben.Character
	m:Forfeit(f)
	h.expect(#w.leavers == 1 and w.leavers[1].player == ann and w.leavers[1].legend == "Moss", "no leaver loss")
	h.expect(w.leavers[1].rating == 1000 and w.leavers[1].mode == "1v1", "leaver loss fields")
	h.expect(#calls("MatchEvent", ann) == 0, "Ann got a MatchEvent (Leave) before Start")
	local annCancel = selectEvents(ann, "Cancel")[1]
	h.expect(annCancel and annCancel.id == 6 and annCancel.reason == "You left the match.", "Ann's Cancel")
	h.expect(not annCancel.requeued, "Ann was told she's re-queued")
	h.expect(annCharacter.destroyed and ann.Character == nil, "Ann's character wasn't released")
	local benCancel = selectEvents(ben, "Cancel")[1]
	h.expect(benCancel and benCancel.reason == "Ann left before the fight." and benCancel.requeued, "Ben's Cancel")
	h.expect(benCharacter.destroyed, "Ben's character wasn't released at Cleanup")
	h.expect(m.cleanedUp and #w.released == 1, "not cleaned up at once")
	h.expect(#w.requeued == 1 and #w.requeued[1].leavers == 1 and w.requeued[1].leavers[1] == ann, "requeue leavers")

	-- leaving the server: the same loss and requeue, nothing sent to the leaver, their character left to Roblox
	w = matchWorld()
	m, f, ann, ben = setup(w)
	annCharacter = ann.Character
	m:RemovePlayer(ann)
	h.expect(#w.leavers == 1 and w.leavers[1].legend == "Moss", "no leaver loss on disconnect")
	h.expect(#calls("SelectEvent", ann) == 0 and #calls("MatchEvent", ann) == 0, "a message to a leaving player")
	h.expect(not annCharacter.destroyed, "a leaving player's character was released")
	h.expect(selectEvents(ben, "Cancel")[1].requeued and #w.requeued == 1, "Ben wasn't re-queued")

	-- a casual forfeit by a player who already moved on to another match leaves that match's character alone
	w = matchWorld()
	m = w.match({ mode = "FFA", source = "Casual", selectId = 7 })
	ann, ben = w.player(1, "Ann"), w.player(2, "Ben")
	ann.Character, ben.Character = fakeCharacter(), fakeCharacter()
	annCharacter = ann.Character
	f = m:AddPlayer(ann, 1)
	m:AddPlayer(ben, 2)
	w.track(m, ann, ben)
	w.playerMatch[ann] = { id = 99 }
	m:Forfeit(f)
	h.expect(not annCharacter.destroyed and ann.Character == annCharacter, "another match's character was released")
	h.expect(m.phase == "Loading" and #w.leavers == 0, "a casual forfeit before the fight ended the match")
end)

h.test("Cleanup leaves a player who already moved on to another match alone", function()
	local w = matchWorld()
	local m = w.match()
	local ann, ben = w.player(1, "Ann"), w.player(2, "Ben")
	ann.Character, ben.Character = fakeCharacter(), fakeCharacter()
	local annCharacter, benCharacter = ann.Character, ben.Character
	m:AddPlayer(ann, 1, { ownLook = true })
	m:AddPlayer(ben, 2, { ownLook = true })
	w.track(m, ann, ben)
	m.startSent[ann], m.startSent[ben] = true, true
	local other = { id = 99 }
	w.playerMatch[ann] = other
	m:Finish("Abandoned", 0)
	local annEvents = calls("MatchEvent", ann)
	h.expect(annEvents[#annEvents].args[1] ~= "Leave", "Ann got Leave from her old match")
	h.expect(not annCharacter.destroyed and w.playerMatch[ann] == other, "Ann's new match lost her")
	local benEvents = calls("MatchEvent", ben)
	h.expect(benEvents[#benEvents].args[1] == "Leave" and benCharacter.destroyed, "Ben wasn't released")
end)

h.test("Start lists fighters already out, and Ready sends their Left again", function()
	local w = matchWorld()
	-- the bot's model can't be built
	w.game:GetService("Players").CreateHumanoidModelFromDescriptionAsync = function()
		error("avatar service down")
	end
	local m = w.match(
		{ mode = "FFA", source = "Casual", selectId = 4 },
		{ slot = 5, origin = Vector3.new(0, 300, 0), startAt = clock.now + 3 }
	)
	local ann, ben, cid = w.player(1, "Ann"), w.player(2, "Ben"), w.player(3, "Cid")
	for _, player in { ann, ben, cid } do
		player.Character = fakeCharacter()
	end
	local fAnn = m:AddPlayer(ann, 1, { ownLook = true })
	local fBen = m:AddPlayer(ben, 2, { ownLook = true })
	m:AddPlayer(cid, 3, { ownLook = true })
	local bot = m:AddBot("Normal", 4)
	w.track(m, ann, ben, cid)
	task.spawn(m.Start, m)
	h.expect(bot.spawnFailed and not bot.alive, "the bot's model was built")
	-- Ann leaves the server on the VS splash: her "Left" reaches clients that have no match yet (they drop it)
	m:RemovePlayer(ann)
	ann.Parent = nil
	h.expect(m.phase == "Loading" and fAnn.left, "Ann's leave ended the casual match")
	clock.now += 3.1
	h.expect(
		waitUntil(function()
			return m.startSent[ben] == true
		end, 1),
		"Start wasn't sent"
	)
	local events = calls("MatchEvent", ben)
	local startAt
	for i, call in events do
		if call.args[1] == "Start" then
			startAt = i
		end
	end
	h.expect(startAt and events[1].args[1] == "Left", "Ben's events: Left before Start")
	local listed = {}
	for _, fi in events[startAt].args[2].fighters do
		listed[fi.id] = fi
	end
	local annInfo, botInfo, benInfo = listed[fAnn.id], listed[bot.id], listed[fBen.id]
	h.expect(annInfo.left == true and annInfo.eliminated == true and annInfo.alive == false, "Ann isn't out")
	h.expect(botInfo.left == false and botInfo.eliminated == true and botInfo.alive == false, "the bot isn't out")
	h.expect(benInfo.left == false and benInfo.eliminated == false and benInfo.alive == true, "Ben is out")
	-- Ben's client has its match now ("Ready"): the Left it dropped comes again (not for the bot: it never left, and
	-- "Start" already lists it as out)
	m:OnAction(ben, "Ready", {})
	local again = {}
	for i = startAt + 1, #calls("MatchEvent", ben) do
		local call = calls("MatchEvent", ben)[i]
		h.expect(call.args[1] == "Left", "after Ready: " .. call.args[1])
		again[call.args[2].fighterId] = true
	end
	h.expect(again[fAnn.id] and not again[bot.id] and not again[fBen.id], "Left wasn't sent again")
	local count = #calls("MatchEvent", ben)
	m:OnAction(ben, "Ready", {})
	h.expect(#calls("MatchEvent", ben) == count, "a second Ready sent the Left events again")
	m:Finish("Abandoned", 0)
end)

h.test("Start keeps the characters on the spawn pad until startAt", function()
	local w = matchWorld()
	local m = w.match(nil, { slot = 5, origin = Vector3.new(0, 300, 0), startAt = clock.now + 3 })
	local ann = w.player(1, "Ann")
	ann.Character = fakeCharacter()
	local pivots = 0
	function ann.Character.PivotTo()
		pivots += 1
	end
	m:AddPlayer(ann, 1, { ownLook = true })
	w.track(m, ann)
	task.spawn(m.Start, m)
	task.wait(0.2)
	h.expect(not m.startSent[ann] and #calls("MatchEvent", ann) == 0, "Start went out before startAt")
	h.expect(pivots == 0, "the character was placed in the arena before startAt (it would fall)")
	clock.now += 3.1
	h.expect(
		waitUntil(function()
			return m.startSent[ann] == true
		end, 1),
		"Start wasn't sent after startAt"
	)
	h.expect(pivots == 1, "the character wasn't placed")
	m:Finish("Abandoned", 0)
end)

h.test("a preload that finishes after its fighter is gone is released", function()
	-- the match ended (and was cleaned up) while the character loaded
	local w = matchWorld()
	local m = w.match()
	local ann = w.player(1, "Ann")
	local loaded
	function ann.LoadCharacterAsync(self)
		task.wait(0.15)
		loaded = fakeCharacter()
		self.Character = loaded
	end
	m:AddPlayer(ann, 1, { ownLook = true })
	w.track(m, ann)
	task.spawn(m.Start, m)
	m:Finish("Abandoned", 0)
	h.expect(
		waitUntil(function()
			return loaded ~= nil
		end, 1),
		"the load never finished"
	)
	h.expect(loaded.destroyed and ann.Character == nil, "the character of an ended match stayed")

	-- the preload came back empty; the second try returns after the end
	w = matchWorld()
	m = w.match()
	ann = w.player(1, "Ann")
	loaded = nil
	local loads = 0
	function ann.LoadCharacterAsync(self)
		loads += 1
		if loads == 1 then
			return
		end
		task.wait(0.15)
		loaded = fakeCharacter()
		self.Character = loaded
	end
	m:AddPlayer(ann, 1, { ownLook = true })
	w.track(m, ann)
	task.spawn(m.Start, m)
	m:Finish("Abandoned", 0)
	h.expect(
		waitUntil(function()
			return loaded ~= nil
		end, 1),
		"the second load never finished"
	)
	task.wait(0.15)
	h.expect(loads == 2 and loaded.destroyed and ann.Character == nil, "the second try's character stayed")

	-- a casual match goes on without a fighter whose load timed out; the late character is released
	w = matchWorld()
	m = w.match({ mode = "FFA", source = "Casual", selectId = 8 })
	local ben
	ann, ben = w.player(1, "Ann"), w.player(2, "Ben")
	loaded = nil
	function ann.LoadCharacterAsync(self)
		task.wait(0.4)
		loaded = fakeCharacter()
		self.Character = loaded
	end
	ben.Character = fakeCharacter()
	local fAnn = m:AddPlayer(ann, 1, { ownLook = true })
	m:AddPlayer(ben, 2, { ownLook = true })
	w.track(m, ann, ben)
	task.spawn(m.Start, m)
	clock.now += 9 -- past the load deadline
	h.expect(
		waitUntil(function()
			return fAnn.left == true and m.startSent[ben] == true
		end, 1),
		"Ann wasn't dropped"
	)
	h.expect(m.phase ~= "Ended" and #w.leavers == 0, "the casual match ended")
	h.expect(selectEvents(ann, "Cancel")[1].reason == "Couldn't load your fighter.", "Ann's Cancel")
	h.expect(
		waitUntil(function()
			return loaded ~= nil
		end, 1),
		"Ann's load never finished"
	)
	h.expect(loaded.destroyed and ann.Character == nil, "the late character stayed on the spawn pad")
	m:Finish("Abandoned", 0)
end)

h.test("slow character loads share one deadline", function()
	local w = matchWorld()
	local m = w.match({ mode = "FFA", source = "Casual", selectId = 9 })
	local ann, ben, cid = w.player(1, "Ann"), w.player(2, "Ben"), w.player(3, "Cid")
	for _, player in { ann, ben } do
		function player.LoadCharacterAsync() end -- never produces a character
	end
	cid.Character = fakeCharacter()
	local fAnn = m:AddPlayer(ann, 1, { ownLook = true })
	local fBen = m:AddPlayer(ben, 2, { ownLook = true })
	m:AddPlayer(cid, 3, { ownLook = true })
	w.track(m, ann, ben, cid)
	task.spawn(m.Start, m)
	clock.now += 8.5 -- just past the deadline every load started with
	h.expect(
		waitUntil(function()
			return fAnn.left == true and fBen.left == true and m.startSent[cid] == true
		end, 1),
		"the second slow load got a deadline of its own"
	)
	m:Finish("Abandoned", 0)
end)

h.test("a failing reward or leaver call never leaves a match half-finished", function()
	local w = matchWorld()
	w.services.ProgressionService.applyMatch = function()
		error("S2 bug")
	end
	local m = w.match({ source = "Casual", mode = "FFA" })
	local ann = w.player(1, "Ann")
	m:AddPlayer(ann, 1)
	w.track(m, ann)
	m.startSent[ann] = true
	m.phase = "Playing"
	m.playStartedAt = clock.now
	clock.now += 60
	m:Finish("Decided", 0)
	local events = calls("MatchEvent", ann)
	h.expect(#events == 2 and events[1].args[1] == "End" and events[2].args[1] == "Leave", "End and Leave")
	h.expect(events[1].args[2].rewards == nil, "rewards from a failed applyMatch")
	h.expect(#w.released == 1 and w.finished == 1 and w.playerMatch[ann] == nil, "Cleanup didn't run")

	w = matchWorld()
	w.services.ProgressionService.applyLeaver = function()
		error("S2 bug")
	end
	local ben
	ann, ben = w.player(1, "Ann"), w.player(2, "Ben")
	local units = { { players = { ann }, joined = 1 }, { players = { ben }, joined = 1 } }
	m = w.match({ ranked = true, selectId = 2, units = units, queueType = "Ranked1v1" })
	local f = m:AddPlayer(ann, 1)
	m:AddPlayer(ben, 2)
	w.track(m, ann, ben)
	m:Forfeit(f)
	h.expect(m.phase == "Ended" and #w.released == 1 and #w.requeued == 1, "the dodge didn't end the match")
	h.expect(selectEvents(ben, "Cancel")[1].requeued, "Ben wasn't told")

	-- one player's release failing at Cleanup doesn't keep the slot
	w = matchWorld()
	w.services.MatchService.getMatchOf = function()
		error("bad lookup")
	end
	m = w.match()
	ann = w.player(1, "Ann")
	m:AddPlayer(ann, 1)
	m.onFinished = function()
		w.finished = 1
	end
	m:Finish("Abandoned", 0)
	h.expect(#w.released == 1 and w.finished == 1, "Cleanup stopped at the failing player")
end)

h.test("training controls keep a usable weapon and refuse bad drops and positions", function()
	local w = matchWorld()
	local m = w.match({ training = {}, queueType = "FFA", autoWeapons = false })
	local ann = w.player(1, "Ann")
	local f = m:AddPlayer(ann, 1, { legend = "Kestrel" })
	f.weapon = "Sword"
	m:SetLegend(f, "Sol")
	local events = calls("MatchEvent", ann)
	local weapon = events[#events - 1]
	h.expect(weapon.args[1] == "Weapon" and weapon.args[2].weapon == "Sword" and f.weapon == "Sword", "re-mount")
	m:SetLegend(f, "Brann")
	events = calls("MatchEvent", ann)
	h.expect(events[#events - 1].args[2].weapon == "Unarmed" and f.weapon == "Unarmed", "Brann kept the sword")
	h.expect(m:SpawnPickup("Banana", 0, 0) == nil and next(m.pickups) == nil, "an unknown weapon dropped")
	-- a knocked-out bot placed during the fight is unanchored again
	local bot = m:AddBot("Normal", 2)
	bot.state = FighterSim.newState(0, 0, 1)
	bot.root = { Anchored = true }
	bot.feetOffset = 3
	m.phase = "Playing"
	m:PlaceFighter(bot, 4, 5, 1, 0)
	h.expect(bot.root.Anchored == false and bot.lastX == 4 and bot.alive, "the bot stayed anchored")
	m:PlaceFighter(bot, 0 / 0, 5)
	h.expect(bot.lastX == 4, "a NaN position was used")
	-- no automatic drops in a room that turned them off
	m.nextPickupAt = 0
	m:stepPickups(0.1, m:now())
	h.expect(next(m.pickups) == nil, "a weapon dropped by itself")
	-- a training match never offers QUEUE AGAIN
	m.startSent[ann] = true
	w.track(m, ann)
	m:Finish("Abandoned", 0)
	local endEvent
	for _, call in calls("MatchEvent", ann) do
		if call.args[1] == "End" then
			endEvent = call.args[2]
		end
	end
	h.expect(endEvent and endEvent.postMatch.queueType == nil, "training results offer QUEUE AGAIN")
end)

h.test("slow motion scales the training step and the respawn delay", function()
	local w = matchWorld()
	local steps = {}
	local room = {
		Step = function(_, sdt)
			table.insert(steps, sdt)
		end,
	}
	local m = w.match({ training = room, winRule = "Timed", stocks = 0, timeLimit = 0, autoWeapons = false })
	local ann = w.player(1, "Ann")
	local f = m:AddPlayer(ann, 1)
	m.phase = "Playing"
	m:SetTimeScale(0.5)
	m:Step(0.1)
	h.expect(#steps == 1 and math.abs(steps[1] - 0.05) < 1e-9, "the training step got " .. tostring(steps[1]))
	m:AddBot("Normal", 2, "Training Dummy", "Brann", { dummy = true })
	m:SetTimeScale(8) -- (faster than training allows, so the real wait is short)
	m:KO(f, 0, -1000)
	h.expect(not f.alive and m.phase == "Playing", "KO")
	h.expect(
		waitUntil(function()
			return f.alive
		end, 0.6),
		"the respawn didn't come at the scaled delay"
	)
	m:Finish("Abandoned", 0)
end)

h.test("startMatch starts the match only after its caller is done", function()
	h.resetRemotes()
	clock.now = 50
	local game = h.fakeGame()
	local MatchService = h.requireServer("MatchService", { game = game, os = fakeOs })
	local released = {}
	local services = {
		ArenaService = {
			buildMap = function()
				return {
					Destroy = function() end,
					FindFirstChild = function()
						return nil
					end,
				}
			end,
			release = function(slot)
				table.insert(released, slot)
			end,
		},
		SelectService = {
			getSessionOf = function()
				return nil
			end,
		},
		DataService = {
			get = function()
				return profileFor()
			end,
		},
		CharacterService = {
			setTeamColor = function() end,
			applyTrail = function() end,
		},
	}
	services.MatchService = MatchService
	MatchService.init(services)
	local ann = h.fakePlayer(1, "Ann")
	ann.Character = fakeCharacter()
	local match = MatchService.startMatch({
		mode = "1v1",
		source = "Custom",
		mapId = "DuelRock",
		winRule = "Stocks",
		stocks = 3,
		timeLimit = 0,
		damageMultiplier = 1,
		participants = { { player = ann, team = 1, ownLook = true } },
		selectId = 3,
	}, { slot = 4, origin = Vector3.new(0, 300, 0), startAt = clock.now + 3 })
	h.expect(match and MatchService.getMatchOf(ann) == match, "the player isn't in the match")
	h.expect(MatchService.busyReason(ann) == "You're in a match.", "busyReason")
	h.expect(ann.Character:GetAttribute("FighterId") == nil, "Start ran before startMatch returned")
	task.wait(0.05)
	h.expect(ann.Character:GetAttribute("FighterId") ~= nil, "Start never ran")
	match:Finish("Abandoned", 0)
	h.expect(MatchService.getMatchOf(ann) == nil and released[1] == 4, "Cleanup didn't free the player and the slot")
	-- a match that ends before its Start runs loads nobody
	local ben = h.fakePlayer(2, "Ben")
	local loads = 0
	function ben.LoadCharacterAsync()
		loads += 1
	end
	match = MatchService.startMatch({
		mode = "1v1",
		source = "Custom",
		mapId = "DuelRock",
		winRule = "Stocks",
		stocks = 3,
		timeLimit = 0,
		damageMultiplier = 1,
		participants = { { player = ben, team = 1, ownLook = true } },
		selectId = 4,
	}, { slot = 5, origin = Vector3.new(0, 300, 0) })
	match:Finish("Abandoned", 0)
	task.wait(0.05)
	h.expect(loads == 0, "an ended match loaded a character")
end)

h.test("a match whose Start throws re-queues its queue players before the fight", function()
	local function run(config)
		h.resetRemotes()
		clock.now = 50
		local game = h.fakeGame()
		local MatchService = h.requireServer("MatchService", { game = game, os = fakeOs })
		local requeued = {}
		local services = {
			ArenaService = {
				buildMap = function()
					return {
						Destroy = function() end,
						FindFirstChild = function()
							return nil
						end,
					}
				end,
				release = function() end,
			},
			SelectService = {
				getSessionOf = function()
					return nil
				end,
			},
			DataService = {
				get = function()
					return profileFor()
				end,
			},
			ProgressionService = {
				ratingOf = function()
					return 1000
				end,
			},
			CharacterService = {
				setTeamColor = function()
					error("CharacterService bug")
				end,
				applyTrail = function() end,
			},
			QueueService = {
				requeue = function(units, queueType, leavers)
					table.insert(requeued, { units = units, queueType = queueType, leavers = leavers })
				end,
				wouldRequeue = function(units, _, _, ending)
					local kept = {}
					for _, u in units do
						for _, player in u.players do
							kept[player] = MatchService.getMatchOf(player) == ending
						end
					end
					return kept
				end,
			},
		}
		services.MatchService = MatchService
		MatchService.init(services)
		local ann, ben = h.fakePlayer(1, "Ann"), h.fakePlayer(2, "Ben")
		ann.Character, ben.Character = fakeCharacter(), fakeCharacter()
		config.units = config.queueType ~= "Bots"
				and { { players = { ann }, joined = 4 }, { players = { ben }, joined = 5 } }
			or nil
		local base = {
			mapId = "DuelRock",
			winRule = "Stocks",
			stocks = 3,
			timeLimit = 0,
			damageMultiplier = 1,
			participants = { { player = ann, team = 1, ownLook = true }, { player = ben, team = 2, ownLook = true } },
			selectId = 8,
		}
		for key, value in base do
			config[key] = value
		end
		local match = MatchService.startMatch(config, { slot = 4, origin = Vector3.new(0, 300, 0) })
		h.expect(match, "no match")
		h.expect(
			waitUntil(function()
				return match.phase == "Ended"
			end, 1),
			"the match didn't end"
		)
		h.expect(MatchService.getMatchOf(ann) == nil and MatchService.getMatchOf(ben) == nil, "players kept")
		return selectEvents(ann, "Cancel")[1], selectEvents(ben, "Cancel")[1], requeued, config
	end
	local annCancel, benCancel, requeued, config =
		run({ mode = "1v1", source = "Ranked", ranked = true, queueType = "Ranked1v1" })
	for _, cancel in { annCancel, benCancel } do
		h.expect(cancel and cancel.reason == "The match couldn't start." and cancel.requeued == true, "Cancel")
	end
	h.expect(#requeued == 1 and requeued[1].units == config.units and #requeued[1].leavers == 0, "requeue")
	-- vs Bots has no queue to go back to
	annCancel, _, requeued = run({ mode = "1v1", source = "Bots", ranked = false, queueType = "Bots" })
	h.expect(annCancel and annCancel.requeued == false and #requeued == 0, "a bots match was re-queued")
end)

h.test("an avatar that can't be read gets a default model at once, then one retry", function()
	local Instance = roblox.Instance
	local game = h.fakeGame()
	local players = game:GetService("Players")
	local physics = game:GetService("PhysicsService")
	function physics.RegisterCollisionGroup() end
	function physics.CollisionGroupSetCollidable() end
	local folder = Instance.new("Folder")
	local storage = game:GetService("ReplicatedStorage")
	local waitForChild = storage.WaitForChild
	function storage.WaitForChild(self, name)
		if name == "AvatarModels" then
			return folder
		end
		return waitForChild(self, name)
	end
	local state = { readFails = true, buildFails = 0 }
	function players.GetHumanoidDescriptionFromUserIdAsync()
		if state.readFails then
			error("avatar service down")
		end
		local desc = Instance.new("HumanoidDescription")
		desc.Name = "Real"
		return desc
	end
	function players.CreateHumanoidModelFromDescriptionAsync(_, desc)
		if state.buildFails > 0 then
			state.buildFails -= 1
			error("build failed")
		end
		local model = Instance.new("Model")
		model:SetAttribute("Look", desc.Name)
		local root = Instance.new("Part")
		root.Name = "HumanoidRootPart"
		root.Parent = model
		return model
	end
	-- the 5 s retry wait takes 0.02 s here
	local fastTask = setmetatable({
		wait = function()
			return task.wait(0.02)
		end,
	}, { __index = task })
	local CharacterService = h.requireServer("CharacterService", { game = game, task = fastTask })
	CharacterService.init({ DataService = { ProfileLoaded = h.signal() } })
	CharacterService.start()
	local function join(userId)
		local player = h.fakePlayer(userId, "P" .. userId)
		player.CharacterAdded = h.signal()
		players:_add(player)
		return player
	end
	local function look(userId)
		local model = folder:FindFirstChild(tostring(userId))
		return model and model:GetAttribute("Look")
	end
	local ann = join(11)
	h.expect(look(11) == "HumanoidDescription", "no default model at once: " .. tostring(look(11)))
	local root = folder:FindFirstChild("11"):FindFirstChild("HumanoidRootPart")
	h.expect(root.Anchored and not root.CanCollide and not root.CanQuery and not root.CanTouch, "not inert")
	state.readFails = false
	task.wait(0.1)
	h.expect(look(11) == "Real", "the retry didn't bring the real look: " .. tostring(look(11)))
	-- still unreadable on the retry: the default model stays as it is
	state.readFails = true
	join(12)
	local first = folder:FindFirstChild("12")
	task.wait(0.1)
	h.expect(first and folder:FindFirstChild("12") == first, "the retry swapped the default model")
	-- a failed build is retried once
	state.readFails = false
	state.buildFails = 1
	join(13)
	h.expect(look(13) == nil, "a failed build left a model")
	task.wait(0.1)
	h.expect(look(13) == "Real", "a failed build wasn't retried")
	-- Studio test players get the default look, without a retry
	state.readFails = true
	join(-1)
	h.expect(look(-1) == "HumanoidDescription", "no model for a test player")
	CharacterService.onPlayerRemoving(ann)
	h.expect(folder:FindFirstChild("11") == nil, "the model of a player who left stayed")
end)

h.test("arena pools hand out match and training slots separately", function()
	local ArenaService = h.requireServer("ArenaService")
	local seen = {}
	for _ = 1, Config.Match.MaxArenas do
		local slot = ArenaService.acquire()
		h.expect(slot and slot <= Config.Match.MaxArenas and not seen[slot], "match slot")
		seen[slot] = true
	end
	h.expect(ArenaService.acquire("Match") == nil and ArenaService.freeSlots() == 0, "the match pool isn't full")
	h.expect(ArenaService.freeSlots("Training") == Config.Training.MaxRooms, "training slots were taken")
	local slot, origin = ArenaService.acquire("Training")
	h.expect(slot == Config.Match.MaxArenas + 1, "first training slot: " .. tostring(slot))
	h.expect(origin.X == slot * Config.Match.ArenaSpacing and origin.Y == Config.Match.ArenaHeight, "origin")
	ArenaService.release(slot)
	ArenaService.release(1)
	h.expect(ArenaService.freeSlots("Match") == 1 and ArenaService.acquire() == 1, "release")
end)

h.test("FriendCache answers from the friend set and asks Roblox while it loads", function()
	local game = h.fakeGame()
	local players = game:GetService("Players")
	local fetches = 0
	function players.GetFriendsAsync()
		fetches += 1
		return {
			IsFinished = true,
			GetCurrentPage = function()
				return { { Id = 5 }, { Id = 6 } }
			end,
			AdvanceToNextPageAsync = function() end,
		}
	end
	local FriendCache = h.requireServer("FriendCache", { game = game, os = fakeOs })
	local early = h.fakePlayer(9, "Early")
	early._friends[7] = true
	early.Parent = nil -- not on this server's Players: no set gets loaded
	h.expect(FriendCache.isFriend(early, 7) and #FriendCache.friendIds(early) == 0, "fallback while loading")
	local ann = h.fakePlayer(1, "Ann")
	players:_add(ann)
	h.expect(fetches == 1, "the set wasn't loaded on join")
	h.expect(FriendCache.isFriend(ann, 5) and not FriendCache.isFriend(ann, 7), "set lookup")
	local ids = FriendCache.friendIds(ann)
	table.sort(ids)
	h.expect(#ids == 2 and ids[1] == 5 and ids[2] == 6, "friendIds")
	clock.now += Config.Rankings.FriendsCacheSeconds + 1
	FriendCache.isFriend(ann, 5)
	h.expect(fetches == 2, "an old set wasn't refreshed")
	FriendCache.onPlayerRemoving(ann)
	ann.Parent = nil
	h.expect(#FriendCache.friendIds(ann) == 0, "a forgotten player still has friends")
	-- a request still running for a player who left asks Roblox each time: nothing is cached for them again
	local asks = 0
	function ann.IsFriendsWithAsync()
		asks += 1
		return true
	end
	h.expect(FriendCache.isFriend(ann, 7) and FriendCache.isFriend(ann, 7), "answer after the leave")
	h.expect(asks == 2 and fetches == 2, "something was cached for a player who left: " .. asks .. " asks")
end)

-- Parties ------------------------------------------------------------------------

h.test("the invite list sorts friends first and says who can be invited", function()
	local w = newWorld()
	w.friends[1] = { 4 }
	local ann = w:player(1, "Ann")
	local ben, cid, dee = w:player(2, "Ben"), w:player(3, "Cid"), w:player(4, "Dee")
	w:makeParty(ann, ben)
	h.expect(w:party(ann, "Invite", cid.UserId), "invite Cid")
	w.playerMatch[dee] = { id = 1 }
	local ok, result = w:party(ann, "List")
	h.expect(ok and #result.players == 3, "list")
	local rows = result.players
	h.expect(rows[1].userId == 4 and rows[1].isFriend and rows[1].status == "Match", "friends first")
	h.expect(rows[1].canInvite, "busy players can be invited")
	local byId = {}
	for _, row in rows do
		byId[row.userId] = row
	end
	h.expect(byId[2].inYourParty and not byId[2].canInvite and byId[2].reason == "In your party", "Ben")
	h.expect(byId[3].invited and byId[3].reason == "Invited", "Cid")
	local _, memberView = w:party(ben, "List")
	for _, row in memberView.players do
		h.expect(not row.canInvite, "a member who isn't the leader can invite")
	end
end)

h.test("accepting while queued cancels both searches", function()
	local w = newWorld()
	local ann, ben = w:player(1, "Ann"), w:player(2, "Ben")
	local ok, message = w:party(ann, "Invite", ben.UserId)
	h.expect(ok, "invite: " .. tostring(message))
	h.expect(w:queue(ann, "Join", "FFA"), "Ann couldn't queue")
	h.expect(w:queue(ben, "Join", "Ranked1v1"), "Ben couldn't queue")
	local party = w.services.PartyService.getParty(ann)
	ok, message = w:party(ben, "Accept", party.id)
	h.expect(ok, "accept: " .. tostring(message))
	h.expect(not w.services.QueueService.isQueued(ann), "Ann's party search wasn't cancelled")
	h.expect(not w.services.QueueService.isQueued(ben), "Ben's own search wasn't cancelled")
	h.expect(hasToast(ann, "Party changed. Search cancelled."), "Ann wasn't told")
	h.expect(lastQueueUpdate(ann) == nil and lastQueueUpdate(ben) == nil, "QueueUpdate(nil)")
	h.expect(#party.members == 2 and party.members[2] == ben, "Ben isn't in the party")
	local state = lastPartyUpdate(ben).party
	h.expect(state.id == party.id and state.leaderUserId == 1 and #state.members == 2, "Ben's PartyUpdate")
end)

h.test("leader leaving passes leadership and cancels the unit", function()
	local w = newWorld()
	local ann, ben, cid = w:player(1, "Ann"), w:player(2, "Ben"), w:player(3, "Cid")
	local party = w:makeParty(ann, ben, cid)
	h.expect(w:queue(ann, "Join", "FFA"), "the party couldn't queue")
	h.expect(lastQueueUpdate(cid).partySize == 3, "one unit for the party")
	h.expect(w:party(ann, "Leave"), "Ann couldn't leave")
	h.expect(party.leader == ben and party.members[1] == ben, "Ben didn't become the leader")
	h.expect(w.services.PartyService.isLeader(ben) and not w.services.PartyService.isLeader(cid), "isLeader")
	for _, player in { ben, cid } do
		h.expect(not w.services.QueueService.isQueued(player), player.Name .. " still searching")
		h.expect(hasToast(player, "Ann left the party. Search cancelled."), player.Name .. ": no cancel toast")
		h.expect(hasToast(player, "Ben is the party leader now."), player.Name .. ": no leader toast")
	end
	h.expect(lastPartyUpdate(ann).party == nil, "Ann still sees the party")
	h.expect(lastPartyUpdate(cid).party.leaderUserId == 2, "Cid's PartyUpdate")
end)

h.test("invite expiry disbands a solo party without cancelling its search", function()
	local w = newWorld()
	local ann, ben = w:player(1, "Ann"), w:player(2, "Ben")
	h.expect(w:queue(ann, "Join", "FFA"), "Ann couldn't queue")
	h.expect(w:party(ann, "Invite", ben.UserId), "invite")
	h.expect(w.services.PartyService.getParty(ann) ~= nil, "no party after the first invite")
	h.expect(lastPartyUpdate(ben).invites[1].expiresAt ~= nil, "Ben's invite has no countdown")
	w:run(Config.Party.InviteSeconds + 1.5)
	h.expect(w.services.PartyService.getParty(ann) == nil, "the solo party wasn't disbanded")
	h.expect(#lastPartyUpdate(ben).invites == 0, "Ben still has the invite")
	h.expect(w.services.QueueService.isQueued(ann), "the disband cancelled Ann's search")
	for _, text in toasts(ann) do
		h.expect(not string.find(text, "cancel"), "Ann got a cancel toast: " .. text)
	end
end)

h.test("an invite to a player in a match waits and starts its countdown when they are back", function()
	local w = newWorld()
	local ann, ben = w:player(1, "Ann"), w:player(2, "Ben")
	w.playerMatch[ben] = { id = 1 }
	local ok, message = w:party(ann, "Invite", ben.UserId)
	h.expect(ok and message == "Invite sent. Ben will see it after their match.", "message: " .. tostring(message))
	local invite = lastPartyUpdate(ben).invites[1]
	h.expect(invite and invite.expiresAt == nil, "a busy player's invite has a countdown")
	h.expect(lastPartyUpdate(ann).party.pending[1].waiting == true, "pending isn't waiting")
	ok, message = w:party(ben, "Accept", invite.partyId)
	h.expect(not ok and message == "Finish your match first.", "accept while busy: " .. tostring(message))
	w:run(Config.Party.InviteSeconds * 2)
	h.expect(lastPartyUpdate(ben).invites[1].expiresAt == nil, "the countdown started during the match")
	w.playerMatch[ben] = nil
	w:run(1.5)
	invite = lastPartyUpdate(ben).invites[1]
	h.expect(invite and invite.expiresAt ~= nil, "the countdown didn't start")
	h.expect(lastPartyUpdate(ann).party.pending[1].waiting == false, "still waiting")
	h.expect(w:party(ben, "Accept", invite.partyId), "Ben couldn't accept")
end)

h.test("kicking yourself is refused", function()
	local w = newWorld()
	local ann, ben = w:player(1, "Ann"), w:player(2, "Ben")
	w:makeParty(ann, ben)
	local ok, message = w:party(ann, "Kick", ann.UserId)
	h.expect(not ok and message == "Use Leave instead.", "self kick: " .. tostring(message))
	ok, message = w:party(ben, "Kick", ann.UserId)
	h.expect(not ok and message == "Only the party leader can do that.", "member kick: " .. tostring(message))
	h.expect(w:party(ann, "Kick", ben.UserId), "the leader couldn't kick")
	h.expect(lastPartyUpdate(ben).party == nil and hasToast(ben, "You were removed from the party."), "Ben")
end)

h.test("a declined invite can't be re-sent during the cooldown", function()
	local w = newWorld()
	local ann, ben = w:player(1, "Ann"), w:player(2, "Ben")
	h.expect(w:party(ann, "Invite", ben.UserId), "invite")
	local partyId = w.services.PartyService.getParty(ann).id
	h.expect(w:party(ben, "Decline", partyId) == true, "decline")
	h.expect(hasToast(ann, "Ben declined."), "Ann wasn't told")
	h.expect(w.services.PartyService.getParty(ann) == nil, "the empty solo party stayed")
	local ok, message = w:party(ann, "Invite", ben.UserId)
	h.expect(not ok and message == "Ben can't be invited again yet.", "re-invite: " .. tostring(message))
	w:run(Config.Party.ReinviteCooldown + 1)
	ok, message = w:party(ann, "Invite", ben.UserId)
	h.expect(ok, "re-invite after the cooldown: " .. tostring(message))
end)

h.test("the last member leaving disbands the party and drops its invites", function()
	local w = newWorld()
	local ann, ben, cid = w:player(1, "Ann"), w:player(2, "Ben"), w:player(3, "Cid")
	local party = w:makeParty(ann, ben)
	h.expect(w:party(ann, "Invite", cid.UserId), "invite Cid")
	h.expect(w:party(ann, "Leave"), "Ann leave")
	h.expect(w.services.PartyService.getParty(ben) == party, "a party of one with an invite was disbanded")
	h.expect(#lastPartyUpdate(cid).invites == 1, "Cid's invite went with Ann")
	h.expect(w:party(ben, "Leave"), "Ben leave")
	h.expect(w.services.PartyService.getParty(ben) == nil, "the empty party still exists")
	h.expect(#lastPartyUpdate(cid).invites == 0, "Cid still has the invite")
	h.expect(lastPartyUpdate(ben).party == nil, "Ben still sees the party")
end)

h.test("a member's status change is pushed to the party", function()
	local w = newWorld()
	local ann, ben = w:player(1, "Ann"), w:player(2, "Ben")
	w:makeParty(ann, ben)
	local function benStatus()
		for _, member in lastPartyUpdate(ann).party.members do
			if member.userId == ben.UserId then
				return member.status
			end
		end
		return nil
	end
	h.expect(benStatus() == "Menu", "status: " .. tostring(benStatus()))
	w.playerMatch[ben] = { id = 1 }
	w:run(1.5)
	h.expect(benStatus() == "Match", "Ann wasn't told Ben is in a match: " .. tostring(benStatus()))
end)

h.test("an expired invite can't be re-sent during the cooldown", function()
	local w = newWorld()
	local ann, ben, cid = w:player(1, "Ann"), w:player(2, "Ben"), w:player(3, "Cid")
	w:makeParty(ann, cid)
	h.expect(w:party(ann, "Invite", ben.UserId), "invite")
	w:run(Config.Party.InviteSeconds + 1.5)
	h.expect(#lastPartyUpdate(ben).invites == 0, "the invite didn't expire")
	local ok, message = w:party(ann, "Invite", ben.UserId)
	h.expect(not ok and message == "Ben can't be invited again yet.", "re-invite after expiry: " .. tostring(message))
	w:run(Config.Party.ReinviteCooldown)
	h.expect(w:party(ann, "Invite", ben.UserId), "re-invite after the cooldown")
end)

h.test("a waiting invite is dropped after WaitingInviteSeconds", function()
	local w = newWorld()
	local ann, ben, cid = w:player(1, "Ann"), w:player(2, "Ben"), w:player(3, "Cid")
	w:makeParty(ann, cid)
	w.playerMatch[ben] = { id = 1 }
	h.expect(w:party(ann, "Invite", ben.UserId), "invite")
	w:run(Config.Party.WaitingInviteSeconds - 2)
	h.expect(#lastPartyUpdate(ben).invites == 1, "the waiting invite was dropped early")
	w:run(3)
	h.expect(#lastPartyUpdate(ben).invites == 0, "the waiting invite was kept")
	h.expect(#lastPartyUpdate(ann).party.pending == 0, "Ann still sees it pending")
end)

h.test("a disconnect drops the leaver's invites both ways", function()
	local w = newWorld()
	local ann, ben, cid, dee = w:player(1, "Ann"), w:player(2, "Ben"), w:player(3, "Cid"), w:player(4, "Dee")
	h.expect(w:party(ann, "Invite", cid.UserId), "Ann invites Cid")
	h.expect(w:party(dee, "Invite", ann.UserId), "Dee invites Ann")
	w:remove(ann)
	h.expect(#lastPartyUpdate(cid).invites == 0, "Cid still has the invite of a player who left")
	h.expect(w.services.PartyService.getParty(dee) == nil, "Dee's party kept an invite to a player who left")
	h.expect(lastPartyUpdate(dee).party == nil, "Dee still sees the party")
	-- a leader who leaves: the next member leads and keeps the invites
	local eve = w:player(5, "Eve")
	local party = w:makeParty(ben, cid)
	h.expect(w:party(ben, "Invite", eve.UserId), "Ben invites Eve")
	w:remove(ben)
	h.expect(party.leader == cid and hasToast(cid, "Cid is the party leader now."), "Cid doesn't lead")
	local invite = lastPartyUpdate(eve).invites[1]
	h.expect(invite and invite.fromUserId == cid.UserId, "Eve's invite went with Ben")
	h.expect(w:party(cid, "Leave"), "Cid leave")
	h.expect(#lastPartyUpdate(eve).invites == 0, "the empty party's invite stayed")
end)

h.test("accepting leaves the old party, and is refused while busy", function()
	local w = newWorld()
	local ann, ben, cid = w:player(1, "Ann"), w:player(2, "Ben"), w:player(3, "Cid")
	local old = w:makeParty(cid, ben)
	h.expect(w:party(ann, "Invite", ben.UserId), "invite")
	local invite = lastPartyUpdate(ben).invites[1]
	h.expect(invite and invite.expiresAt ~= nil, "no countdown")
	w.playerMatch[ben] = { id = 1 }
	local ok, message = w:party(ben, "Accept", invite.partyId)
	h.expect(not ok and message == "Finish your match first.", "accepted while busy: " .. tostring(message))
	w.playerMatch[ben] = nil
	ok, message = w:party(ben, "Accept", invite.partyId)
	h.expect(ok, "accept: " .. tostring(message))
	h.expect(not table.find(old.members, ben) and w.services.PartyService.getParty(cid) == nil, "Ben's old party")
	h.expect(w.services.PartyService.getParty(ben) == w.services.PartyService.getParty(ann), "Ben isn't with Ann")
end)

h.test("invites are capped per invitee and party requests are rate limited", function()
	local w = newWorld()
	local ben = w:player(2, "Ben")
	for i = 1, Config.Party.MaxIncomingInvites do
		local inviter = w:player(100 + i, "P" .. i)
		h.expect(w:party(inviter, "Invite", ben.UserId), "invite " .. i)
	end
	local zed = w:player(200, "Zed")
	local ok, message = w:party(zed, "Invite", ben.UserId)
	h.expect(not ok and message == "Ben has too many invites right now.", tostring(message))
	for i = 2, Config.Party.RequestBurst do
		h.expect(w:party(zed, "List"), "request " .. i .. " was limited")
	end
	ok, message = w:party(zed, "List")
	h.expect(not ok and message == "Slow down.", "no rate limit: " .. tostring(message))
	w:run(1)
	h.expect(w:party(zed, "List"), "the budget didn't refill")
end)

-- Queue ----------------------------------------------------------------------------

h.test("queue joins follow the party rules", function()
	local w = newWorld()
	local ann, ben = w:player(1, "Ann"), w:player(2, "Ben")
	w:makeParty(ann, ben)
	local ok, message = w:queue(ben, "Join", "FFA")
	h.expect(not ok and message == "Only the party leader can start a search.", tostring(message))
	ok, message = w:queue(ann, "Join", "Ranked1v1")
	h.expect(not ok and message == "Ranked 1v1 is for 1 player. Leave your party to queue.", tostring(message))
	w:run(1)
	w.playerMatch[ben] = { id = 1, training = true }
	ok, message = w:queue(ann, "Join", "Ranked2v2")
	h.expect(not ok and message == "Ben is busy right now.", tostring(message))
	w.playerMatch[ben] = nil
	w:run(1)
	ok, message = w:queue(ann, "Join", "Ranked2v2")
	h.expect(ok and message == "Searching for Ranked 2v2...", tostring(message))
	local status = lastQueueUpdate(ben)
	h.expect(status.partySize == 2 and status.leaderUserId == 1 and status.window == 100, "Ben's QueueStatus")
	h.expect(w:queue(ben, "Leave"), "a member can cancel")
	h.expect(not w.services.QueueService.isQueued(ann), "the whole unit wasn't cancelled")
	h.expect(hasToast(ann, "Ben cancelled the search."), "Ann wasn't told")
	w:run(1)
	ok, message = w:queue(ann, "Join", "Bots", { format = "2v2", difficulty = "Easy", mapId = "SkyShip" })
	h.expect(ok and message == "Get ready!", tostring(message))
	local session = w.services.SelectService.getSessionOf(ben)
	h.expect(session and session.fixedMap == "SkyShip" and session.config.botOptions.format == "2v2", "bots session")
	h.expect(#session.slots == 4 and session.slots[1].team == 1 and session.slots[2].team == 1, "the duo on team 1")
end)

h.test("QueueRequest Leave is never rate limited", function()
	local w = newWorld()
	local ann = w:player(1, "Ann")
	h.expect(w:queue(ann, "Join", "FFA"), "join")
	local ok, message = w:queue(ann, "Join", "FFA")
	h.expect(not ok and message == "Slow down.", "a second Join wasn't limited: " .. tostring(message))
	for i = 1, 3 do
		ok, message = w:queue(ann, "Leave")
		h.expect(ok and message == "Left the queue.", "Leave " .. i .. ": " .. tostring(message))
	end
	h.expect(not w.services.QueueService.isQueued(ann), "still queued")
	w:run(Config.Queue.RequestCooldown + 0.1)
	h.expect(w:queue(ann, "Join", "FFA"), "join after the cooldown")
end)

h.test("a found match removes units without a cancel toast", function()
	local w = newWorld()
	local ann, ben = w:player(1, "Ann"), w:player(2, "Ben")
	h.expect(w:queue(ann, "Join", "Ranked1v1"), "Ann join")
	h.expect(w:queue(ben, "Join", "Ranked1v1"), "Ben join")
	h.expect(w.services.QueueService.stats().Ranked1v1 == 2, "stats")
	w:run(Config.Queue.TickSeconds + 0.1)
	for _, player in { ann, ben } do
		h.expect(not w.services.QueueService.isQueued(player), player.Name .. " still queued")
		h.expect(lastQueueUpdate(player) == nil, player.Name .. ": no QueueUpdate(nil)")
		h.expect(#toasts(player) == 0, player.Name .. " got a toast: " .. tostring(toasts(player)[1]))
		h.expect(#selectEvents(player, "Begin") == 1, player.Name .. ": no Begin")
	end
	local session = w.services.SelectService.getSessionOf(ann)
	h.expect(session and session.config.queueType == "Ranked1v1" and #session.config.units == 2, "session")
	h.expect(session.config.mapPool == Config.Queue.MapPools["1v1"] and #session.maps == 3, "map vote")
	local view = selectEvents(ann, "Begin")[1]
	h.expect(view.ranked and view.label == "Ranked 1v1" and view.you == "p1", "Begin view")
end)

h.test("requeue puts back only players who are free to search", function()
	local w = newWorld()
	local ann, ben, cid, dee = w:player(1, "Ann"), w:player(2, "Ben"), w:player(3, "Cid"), w:player(4, "Dee")
	h.expect(w:room(ben, "Create", { mode = "FFA" }), "Ben's room")
	h.expect(w:queue(cid, "Join", "FFA"), "Cid's search")
	w.profiles[dee] = nil
	local units = {}
	for _, player in { ann, ben, cid, dee } do
		table.insert(units, { players = { player }, joined = clock.now - 5 })
	end
	w.services.QueueService.requeue(units, "Ranked1v1", nil)
	h.expect(w.services.QueueService.stats().Ranked1v1 == 1, "Ranked1v1: " .. w.services.QueueService.stats().Ranked1v1)
	local status = lastQueueUpdate(ann)
	h.expect(status and status.queue == "Ranked1v1" and status.waited == 5, "Ann wasn't re-queued with her time")
	h.expect(lastQueueUpdate(cid).queue == "FFA", "Cid's own search was replaced")
	h.expect(not w.services.QueueService.isQueued(ben), "a player in a room was re-queued")
	h.expect(not w.services.QueueService.isQueued(dee), "a player without a profile was re-queued")
end)

h.test("a search needs every party member out of custom rooms", function()
	local w = newWorld()
	local ann, ben = w:player(1, "Ann"), w:player(2, "Ben")
	h.expect(w:room(ben, "Create", { mode = "FFA" }), "Ben's room")
	local ok, message = w:queue(ben, "Join", "FFA")
	h.expect(not ok and message == "Leave your custom room first.", tostring(message))
	w:makeParty(ann, ben)
	ok, message = w:queue(ann, "Join", "FFA")
	h.expect(not ok and message == "Ben is in a custom room.", tostring(message))
end)

h.test("a member's disconnect cancels the search with a toast, and Bots replaces a search", function()
	local w = newWorld()
	local ann, ben = w:player(1, "Ann"), w:player(2, "Ben")
	w:makeParty(ann, ben)
	h.expect(w:queue(ann, "Join", "FFA"), "the party couldn't queue")
	h.expect(lastQueueUpdate(ann).window == nil, "FFA has a rating window")
	w:remove(ben)
	h.expect(not w.services.QueueService.isQueued(ann), "Ann is still searching")
	h.expect(hasToast(ann, "Ben left. Search cancelled."), "Ann wasn't told")
	w:run(1)
	h.expect(w:queue(ann, "Join", "FFA"), "Ann's own search")
	w:run(1)
	h.expect(w:queue(ann, "Join", "Bots", { format = "Duel" }), "bots")
	h.expect(not w.services.QueueService.isQueued(ann), "Ann is still in the FFA queue while picking a legend")
	h.expect(w.services.SelectService.getSessionOf(ann) ~= nil, "no bots session")
end)

h.test("a select that can't begin puts the units back with their joined time", function()
	local w = newWorld()
	local ann, ben = w:player(1, "Ann"), w:player(2, "Ben")
	h.expect(w:queue(ann, "Join", "Ranked1v1") and w:queue(ben, "Join", "Ranked1v1"), "join")
	w.profiles[ben].Equipped = nil -- building Ben's select slot throws
	w:run(Config.Queue.TickSeconds + 0.1)
	for _, player in { ann, ben } do
		h.expect(w.services.QueueService.isQueued(player), player.Name .. " lost the search")
		h.expect(hasToast(player, "Something went wrong."), player.Name .. " wasn't told")
		h.expect(w.services.SelectService.getSessionOf(player) == nil, player.Name .. " is in a session")
		h.expect(#selectEvents(player, "Begin") == 0, player.Name .. " got Begin")
	end
	h.expect(next(w.inUse) == nil, "the arena slot leaked")
	h.expect(lastQueueUpdate(ann).waited == 1, "the joined time was lost")
end)

h.test("the queue waits while every arena is busy", function()
	local w = newWorld({ arenas = 0 })
	local ann, ben = w:player(1, "Ann"), w:player(2, "Ben")
	h.expect(w:queue(ann, "Join", "Ranked1v1") and w:queue(ben, "Join", "Ranked1v1"), "join")
	w:run(Config.Queue.TickSeconds * 2 + 0.1)
	for _, player in { ann, ben } do
		h.expect(w.services.QueueService.isQueued(player), player.Name .. " lost the search")
		h.expect(#toasts(player) == 0, player.Name .. " got a toast: " .. tostring(toasts(player)[1]))
		h.expect(lastQueueUpdate(player).waitingForArena == true, player.Name .. ": waitingForArena")
	end
end)

-- Select ---------------------------------------------------------------------------

h.test("select ends 0.75 s after all lock and an unlock resets it", function()
	local w = newWorld()
	local ann = w:player(1, "Ann")
	local ok, message = w:queue(ann, "Join", "Bots", { format = "Duel", difficulty = "Hard" })
	h.expect(ok and message == "Get ready!", "bots: " .. tostring(message))
	local begin = selectEvents(ann, "Begin")[1]
	h.expect(begin.label == "vs Bots · Hard" and #begin.slots == 2, "Begin")
	h.expect(begin.slots[2].isBot and begin.slots[2].locked, "the bot isn't locked")
	w:select(ann, "Lock", { legend = "Vex" })
	w:run(0.5)
	h.expect(#w.started == 0, "finalized before the delay")
	w:select(ann, "Unlock", {})
	w:run(0.5)
	h.expect(#w.started == 0, "the unlock didn't reset the delay")
	w:select(ann, "Lock", { legend = "Sol" })
	w:run(0.625)
	h.expect(#w.started == 0, "finalized early after the second lock")
	w:run(0.25)
	h.expect(#w.started == 1, "not finalized after the delay")
	local config = w.started[1].config
	h.expect(config.participants[1].legend == "Sol" and config.participants[2].legend ~= nil, "picks")
	h.expect(w.profiles[ann].Legend == "Sol", "the pick wasn't saved")
	h.expect(table.find(Config.Queue.MapPools["1v1"], config.mapId), "map from the pool")
	local vs = selectEvents(ann, "Vs")[1]
	h.expect(vs and vs.matchId == 101 and vs.mapId == config.mapId and #vs.fighters == 2, "Vs")
end)

h.test("a ranked select leaver takes a loss and the others are requeued with their joined time", function()
	local w = newWorld()
	local ann, ben = w:player(1, "Ann"), w:player(2, "Ben")
	w.ratings[ben] = { ["1v1"] = 1040 }
	h.expect(w:queue(ann, "Join", "Ranked1v1"), "Ann join")
	h.expect(w:queue(ben, "Join", "Ranked1v1"), "Ben join")
	w:run(Config.Queue.TickSeconds + 0.1)
	local session = w.services.SelectService.getSessionOf(ann)
	h.expect(session, "no session")
	w:select(ann, "Hover", { legend = "Moss" })
	w:run(5)
	w:remove(ann)
	h.expect(#w.leavers == 1, "no leaver loss")
	local loss = w.leavers[1]
	h.expect(loss.player == ann and loss.mode == "1v1" and loss.rating == 1040 and loss.legend == "Moss", "loss")
	local cancel = selectEvents(ben, "Cancel")[1]
	h.expect(cancel and cancel.reason == "Ann left." and cancel.requeued and cancel.id == session.id, "Cancel")
	h.expect(w.services.QueueService.isQueued(ben), "Ben wasn't re-queued")
	local status = lastQueueUpdate(ben)
	h.expect(status.queue == "Ranked1v1" and status.waited == 6, "joined time lost: waited " .. status.waited)
	-- (the Cancel's requeued flag is what tells him; a server toast too would say it twice)
	for _, text in toasts(ben) do
		h.expect(not string.find(text, "back in the queue", 1, true), "Ben was told twice: " .. text)
	end
	h.expect(next(w.inUse) == nil, "the arena slot is still reserved")
	h.expect(w.services.SelectService.getSessionOf(ben) == nil, "Ben is still in the session")
end)

h.test("a duo partner of a select dodger stays queued in either removal order", function()
	for _, order in
		{
			REMOVAL_ORDER,
			{ "PartyService", "RoomService", "QueueService", "MatchService", "SelectService" },
		}
	do
		local w = newWorld()
		local ann, ben = w:player(1, "Ann"), w:player(2, "Ben")
		local cid, dee = w:player(3, "Cid"), w:player(4, "Dee")
		w:makeParty(ann, ben)
		h.expect(w:queue(ann, "Join", "Ranked2v2"), "the duo couldn't queue")
		h.expect(w:queue(cid, "Join", "Ranked2v2") and w:queue(dee, "Join", "Ranked2v2"), "solos")
		w:run(Config.Queue.TickSeconds + 0.1)
		local session = w.services.SelectService.getSessionOf(ben)
		h.expect(session and session.config.mode == "2v2", "no 2v2 session")
		local teamOf = {}
		for _, p in session.config.participants do
			teamOf[p.player] = p.team
		end
		h.expect(teamOf[ann] == teamOf[ben] and teamOf[cid] == teamOf[dee] and teamOf[ann] ~= teamOf[cid], "teams")
		w:remove(ann, order)
		local label = order[1]
		h.expect(w.services.QueueService.isQueued(ben), label .. ": Ben wasn't re-queued")
		local status = lastQueueUpdate(ben)
		h.expect(status.partySize == 1 and status.leaderUserId == 2, label .. ": Ben's unit")
		h.expect(w.services.QueueService.isQueued(cid) and w.services.QueueService.isQueued(dee), label .. ": solos")
		h.expect(w.services.QueueService.stats().Ranked2v2 == 3, label .. ": stats")
		h.expect(#w.leavers == 1 and w.leavers[1].player == ann, label .. ": leaver loss")
	end
end)

h.test("requeue drops a unit whose party changed", function()
	local w = newWorld()
	local ann, ben = w:player(1, "Ann"), w:player(2, "Ben")
	local cid, dee = w:player(3, "Cid"), w:player(4, "Dee")
	w:makeParty(ann, ben)
	h.expect(w:queue(ann, "Join", "Ranked2v2"), "duo")
	h.expect(w:queue(cid, "Join", "Ranked2v2") and w:queue(dee, "Join", "Ranked2v2"), "solos")
	w:run(Config.Queue.TickSeconds + 0.1)
	h.expect(w.services.SelectService.getSessionOf(ann), "no session")
	h.expect(w:party(ben, "Leave"), "Ben couldn't leave the party")
	w:remove(cid)
	for _, player in { ann, ben } do
		h.expect(not w.services.QueueService.isQueued(player), player.Name .. " was re-queued")
		h.expect(hasToast(player, "Your party changed. Search cancelled."), player.Name .. " wasn't told")
		local cancel = selectEvents(player, "Cancel")[1]
		h.expect(cancel and cancel.requeued == false, player.Name .. "'s Cancel says they're back in the queue")
	end
	h.expect(w.services.QueueService.isQueued(dee), "Dee wasn't re-queued")
	h.expect(selectEvents(dee, "Cancel")[1].requeued == true, "Dee wasn't told she's back in the queue")
end)

h.test("a select dodge doesn't promise a search to a player whose party changed during select", function()
	local w = newWorld()
	local ann, ben, cid = w:player(1, "Ann"), w:player(2, "Ben"), w:player(3, "Cid")
	-- an invite still pending doesn't stop Ann's solo search
	h.expect(w:party(ann, "Invite", cid.UserId), "invite")
	h.expect(w:queue(ann, "Join", "Ranked1v1") and w:queue(ben, "Join", "Ranked1v1"), "join")
	w:run(Config.Queue.TickSeconds + 0.1)
	h.expect(w.services.SelectService.getSessionOf(ann), "no session")
	-- Cid accepts from the menus while Ann picks her legend
	h.expect(w:party(cid, "Accept", w.services.PartyService.getParty(ann).id), "accept")
	h.expect(w.services.SelectService.getSessionOf(ann), "the accept ended the select")
	w:remove(ben)
	local cancel = selectEvents(ann, "Cancel")[1]
	h.expect(cancel and cancel.reason == "Ben left." and cancel.requeued == false, "Ann was promised a search")
	h.expect(hasToast(ann, "Your party changed. Search cancelled."), "Ann wasn't told her search was cancelled")
	h.expect(not w.services.QueueService.isQueued(ann) and lastQueueUpdate(ann) == nil, "Ann was re-queued")
end)

h.test("a ranked fighter whose character can't load goes back in the queue and is told so", function()
	local w = newWorld()
	useRealMatches(w)
	local ann, ben = w:player(1, "Ann"), w:player(2, "Ben")
	function ann.LoadCharacterAsync() end -- never produces a character
	ben.Character = fakeCharacter()
	h.expect(w:queue(ann, "Join", "Ranked1v1") and w:queue(ben, "Join", "Ranked1v1"), "join")
	w:run(Config.Queue.TickSeconds + 0.1)
	w:run(Config.Select.Seconds + 0.2)
	local match = w.matches[1]
	h.expect(match and match.config.queueType == "Ranked1v1", "no match")
	task.spawn(match.Start, match)
	h.expect(
		waitUntil(function()
			return match.phase == "Ended"
		end, 2, 1),
		"the match didn't end"
	)
	local annCancel = selectEvents(ann, "Cancel")[1]
	h.expect(annCancel and annCancel.reason == "Couldn't load your fighter.", "Ann's Cancel")
	h.expect(annCancel.requeued == true, "Ann wasn't told she's back in the queue")
	local benCancel = selectEvents(ben, "Cancel")[1]
	h.expect(benCancel and benCancel.reason == "A fighter couldn't load." and benCancel.requeued, "Ben's Cancel")
	for _, player in { ann, ben } do
		h.expect(w.services.QueueService.isQueued(player), player.Name .. " isn't back in the queue")
		h.expect(lastQueueUpdate(player).queue == "Ranked1v1", player.Name .. "'s queue")
	end
	h.expect(#w.leavers == 0, "a fighter the server couldn't load took a loss")
	h.expect(next(w.playerMatch) == nil, "a player is still in the match")
end)

h.test("a ranked dodge on the VS splash doesn't promise a search to a player whose party changed", function()
	local w = newWorld()
	useRealMatches(w)
	local ann, ben, cid = w:player(1, "Ann"), w:player(2, "Ben"), w:player(3, "Cid")
	h.expect(w:party(ann, "Invite", cid.UserId), "invite")
	h.expect(w:queue(ann, "Join", "Ranked1v1") and w:queue(ben, "Join", "Ranked1v1"), "join")
	w:run(Config.Queue.TickSeconds + 0.1)
	w:run(Config.Select.Seconds + 0.2)
	local match = w.matches[1]
	h.expect(match and match.phase == "Loading", "no match on the VS splash")
	h.expect(w:party(cid, "Accept", w.services.PartyService.getParty(ann).id), "accept")
	match:Forfeit(match.playerFighters[ben])
	h.expect(match.phase == "Ended" and #w.leavers == 1 and w.leavers[1].player == ben, "Ben's dodge")
	local cancel = selectEvents(ann, "Cancel")[1]
	h.expect(cancel and cancel.reason == "Ben left before the fight.", "Ann's Cancel")
	h.expect(cancel.requeued == false, "Ann was promised a search")
	h.expect(hasToast(ann, "Your party changed. Search cancelled."), "Ann wasn't told her search was cancelled")
	h.expect(not w.services.QueueService.isQueued(ann), "Ann was re-queued")
	local benCancel = selectEvents(ben, "Cancel")[1]
	h.expect(benCancel and benCancel.reason == "You left the match." and benCancel.requeued == false, "Ben")
	h.expect(not w.services.QueueService.isQueued(ben), "the dodger was re-queued")
end)

h.test("a casual leaver becomes a bot", function()
	local w = newWorld()
	local ann, ben, cid = w:player(1, "Ann"), w:player(2, "Ben"), w:player(3, "Cid")
	for _, player in { ann, ben, cid } do
		h.expect(w:queue(player, "Join", "FFA"), player.Name .. " join")
	end
	w:run(Config.Queue.FFAStartAfterSeconds + 1)
	local session = w.services.SelectService.getSessionOf(ann)
	h.expect(session and #session.slots == 4, "no FFA session with a bot")
	local annTeam = session.players[ann].team
	w:remove(ann)
	h.expect(#w.leavers == 0, "a casual leaver took a loss")
	h.expect(#selectEvents(ben, "Cancel") == 0, "the session was cancelled")
	h.expect(w.services.SelectService.getSessionOf(ben) == session, "Ben left the session")
	local bots = 0
	for _, slot in session.slots do
		if slot.isBot then
			bots += 1
			h.expect(slot.locked and slot.userId == 0, "bot slot")
		end
	end
	h.expect(bots == 2, "expected 2 bots, got " .. bots)
	local replaced
	for _, p in session.config.participants do
		if p.bot and p.team == annTeam then
			replaced = p
		end
		h.expect(p.player ~= ann, "Ann is still a participant")
	end
	h.expect(replaced and replaced.difficulty == Config.Queue.FFAFillDifficulty, "the bot took Ann's team")
	w:run(0.2)
	local update = selectEvents(ben, "Update")
	local slots = update[#update].slots
	local left = 0
	for _, slot in slots do
		if slot.userId == 1 then
			left += 1
		end
	end
	h.expect(left == 0, "Ann's slot is still shown")
end)

h.test("a custom select cancel reopens the room and releases the slot", function()
	local w = newWorld()
	local ann, ben = w:player(1, "Ann"), w:player(2, "Ben")
	local ok, room = w:room(ann, "Create", { mode = "1v1", mapId = "SkyShip" })
	h.expect(ok, "create: " .. tostring(room))
	ok = w:room(ben, "Join", room.id)
	h.expect(ok, "join")
	ok, room = w:room(ann, "Start")
	h.expect(ok and room.state == "InMatch", "start: " .. tostring(room))
	local session = w.services.SelectService.getSessionOf(ann)
	h.expect(session and session.fixedMap == "SkyShip" and session.maps == nil, "fixed map: no vote")
	h.expect(selectEvents(ann, "Begin")[1].label == room.name, "the label is the room name")
	h.expect(w.inUse[session.slot], "no slot reserved")
	w:remove(ben)
	local cancel = selectEvents(ann, "Cancel")[1]
	h.expect(cancel and cancel.reason == "Not enough fighters left." and not cancel.requeued, "Cancel")
	h.expect(not w.inUse[session.slot] and table.find(w.released, session.slot), "the slot wasn't released")
	local updates = calls("RoomUpdate", ann)
	local state = updates[#updates].args[1]
	h.expect(state and state.state == "Open" and #state.members == 1, "the room didn't reopen without Ben")
	h.expect(w.services.SelectService.getSessionOf(ann) == nil, "Ann is still busy")
end)

h.test("busy flags clear only after the match exists", function()
	local w = newWorld()
	local ann = w:player(1, "Ann")
	h.expect(w:queue(ann, "Join", "Bots", { format = "FFA" }), "bots FFA")
	h.expect(w.services.MatchService.busyReason(ann) == "You're picking a legend.", "not busy in select")
	h.expect(w.services.PartyService.statusOf(ann) == "Select", "party status")
	w:run(Config.Select.Seconds + 0.2)
	h.expect(#w.started == 1, "no match")
	h.expect(w.started[1].busy[ann] == "You're picking a legend.", "free while the match was being created")
	h.expect(w.started[1].reserved.slot ~= nil and w.started[1].reserved.startAt ~= nil, "reserved slot")
	h.expect(w.services.SelectService.getSessionOf(ann) == nil, "the session wasn't cleared")
	h.expect(w.services.MatchService.busyReason(ann) == "You're in a match.", "free after the select")
	h.expect(#selectEvents(ann, "Vs") == 1, "no Vs")
	h.expect(w.inUse[w.started[1].reserved.slot], "the match's slot was released")
end)

h.test("a select error cancels the session and frees the slot", function()
	local w = newWorld()
	local ann, ben = w:player(1, "Ann"), w:player(2, "Ben")
	h.expect(w:queue(ann, "Join", "Ranked1v1") and w:queue(ben, "Join", "Ranked1v1"), "join")
	w:run(Config.Queue.TickSeconds + 0.1)
	local session = w.services.SelectService.getSessionOf(ann)
	h.expect(session, "no session")
	w.startMatchError = true
	w:run(Config.Select.Seconds + 0.2)
	for _, player in { ann, ben } do
		local cancel = selectEvents(player, "Cancel")[1]
		h.expect(cancel and cancel.reason == "Something went wrong." and cancel.requeued, player.Name .. ": Cancel")
		h.expect(w.services.SelectService.getSessionOf(player) == nil, player.Name .. " is still busy")
		h.expect(w.services.QueueService.isQueued(player), player.Name .. " wasn't re-queued")
	end
	h.expect(not w.inUse[session.slot], "the slot leaked")
end)

h.test("hovers are applied at most every HoverInterval, the latest one wins", function()
	local w = newWorld()
	local ann = w:player(1, "Ann")
	h.expect(w:queue(ann, "Join", "Bots", { format = "Duel" }), "bots")
	local session = w.services.SelectService.getSessionOf(ann)
	w:select(ann, "Hover", { legend = "Vex" })
	h.expect(session.players[ann].legend == "Vex", "the first hover wasn't applied")
	w:select(ann, "Hover", { legend = "Moss" })
	w:select(ann, "Hover", { legend = "Sol" })
	h.expect(session.players[ann].legend == "Vex", "a hover inside the interval was applied at once")
	w:run(Config.Select.HoverInterval + 0.05)
	h.expect(session.players[ann].legend == "Sol", "the latest hover wasn't applied after the interval")
end)

h.test("SelectAction is rate limited per player", function()
	local w = newWorld()
	local ann = w:player(1, "Ann")
	h.expect(w:queue(ann, "Join", "Bots", { format = "Duel" }), "bots")
	local session = w.services.SelectService.getSessionOf(ann)
	h.expect(session.maps and #session.maps >= 2, "no vote")
	for i = 1, 9 do
		-- odd votes for the first map, even votes for the second; the 9th is over the burst
		w:select(ann, "Vote", { mapId = session.maps[(i + 1) % 2 + 1] })
	end
	h.expect(session.votes.p1 == session.maps[2], "the 9th action in a burst was applied")
	w:run(1)
	w:select(ann, "Vote", { mapId = session.maps[1] })
	h.expect(session.votes.p1 == session.maps[1], "the budget didn't refill")
end)

h.test("a Random hover is resolved when nobody locks", function()
	local w = newWorld()
	local Legends = h.require("Legends")
	local ann = w:player(1, "Ann")
	h.expect(w:queue(ann, "Join", "Bots", { format = "Duel" }), "bots")
	local session = w.services.SelectService.getSessionOf(ann)
	w:select(ann, "Hover", { legend = "Random" })
	w:run(Config.Select.Seconds + 0.2)
	h.expect(#w.started == 1, "no match")
	local legend = w.started[1].config.participants[1].legend
	h.expect(legend ~= "Random" and Legends.isValid(legend), "the match got legend " .. tostring(legend))
	h.expect(session.players[ann].random and session.players[ann].locked, "the slot isn't a locked random pick")
	h.expect(w.profiles[ann].Legend == legend, "the resolved pick wasn't saved")
end)

h.test("custom select cancels when a team side empties or only bots are left", function()
	local w = newWorld()
	local ann, ben = w:player(1, "Ann"), w:player(2, "Ben")
	local ok, room = w:room(ann, "Create", { mode = "2v2", mapId = "SkyShip" })
	h.expect(ok, "create")
	h.expect(w:room(ben, "Join", room.id), "join")
	h.expect(w:room(ben, "SetTeam", { team = 2 }), "Ben to team 2")
	h.expect(w:room(ann, "SetTeam", { team = 1 }), "Ann to team 1")
	ok, room = w:room(ann, "AddBot", { difficulty = "Easy" })
	h.expect(ok, "add bot")
	for _, member in room.members do
		if member.bot then
			h.expect(w:room(ann, "SetTeam", { memberId = member.id, team = 1 }), "bot to team 1")
		end
	end
	h.expect(w:room(ann, "Start"), "start")
	local session = w.services.SelectService.getSessionOf(ann)
	w:remove(ben)
	local cancel = selectEvents(ann, "Cancel")[1]
	h.expect(cancel and cancel.reason == "Not enough fighters left.", "an empty side didn't cancel")
	h.expect(not w.inUse[session.slot], "the slot wasn't released")

	-- a room's last human leaves: a session of bots alone is cancelled
	w = newWorld()
	ann = w:player(1, "Ann")
	h.expect(w:room(ann, "Create", { mode = "FFA" }), "create")
	h.expect(w:room(ann, "AddBot", {}) and w:room(ann, "AddBot", {}), "add bots")
	h.expect(w:room(ann, "Start"), "start")
	session = w.services.SelectService.getSessionOf(ann)
	w:remove(ann)
	h.expect(session.phase == "Cancelled" and not w.inUse[session.slot], "a bots-only session kept its arena")
	w:run(Config.Select.Seconds + 1)
	h.expect(#w.started == 0, "a match without players started")
end)

h.test("begin refuses busy players and configs without players, and frees the slot on an error", function()
	local w = newWorld()
	local ann = w:player(1, "Ann")
	local SelectService = w.services.SelectService
	local function config()
		return {
			mode = "1v1",
			source = "Custom",
			participants = { { player = ann, team = 1 }, { bot = true, difficulty = "Easy", team = 2 } },
		}
	end
	local session, err = SelectService.begin({ participants = { { bot = true, team = 1 }, { bot = true, team = 2 } } })
	h.expect(session == nil and err == "Bad match config.", "bots only: " .. tostring(err))
	w.playerMatch[ann] = { id = 1 }
	session, err = SelectService.begin(config())
	h.expect(session == nil and err == "Ann is busy right now.", "busy: " .. tostring(err))
	w.playerMatch[ann] = nil
	w.profiles[ann].Equipped = nil -- building the session throws
	session, err = SelectService.begin(config())
	h.expect(session == nil and err == "Something went wrong.", "error: " .. tostring(err))
	h.expect(next(w.inUse) == nil and SelectService.getSessionOf(ann) == nil, "the failed begin kept something")
	h.expect(#calls("SelectEvent", ann) == 0, "Ann got a SelectEvent")
end)

h.test("a select dodge whose leaver loss fails still cancels and re-queues", function()
	local w = newWorld()
	w.services.ProgressionService.applyLeaver = function()
		error("S2 bug")
	end
	local ann, ben = w:player(1, "Ann"), w:player(2, "Ben")
	h.expect(w:queue(ann, "Join", "Ranked1v1") and w:queue(ben, "Join", "Ranked1v1"), "join")
	w:run(Config.Queue.TickSeconds + 0.1)
	local session = w.services.SelectService.getSessionOf(ben)
	h.expect(session, "no session")
	w:remove(ann)
	local cancel = selectEvents(ben, "Cancel")[1]
	h.expect(cancel and cancel.reason == "Ann left." and cancel.requeued, "Ben's Cancel")
	h.expect(w.services.QueueService.isQueued(ben) and w.services.SelectService.getSessionOf(ben) == nil, "Ben")
	h.expect(session.phase == "Cancelled" and next(w.inUse) == nil, "the session kept going with a leaver")
end)

h.test("an error after the match exists abandons that match instead of cancelling", function()
	local w = newWorld()
	local ann, ben = w:player(1, "Ann"), w:player(2, "Ben")
	h.expect(w:queue(ann, "Join", "Ranked1v1") and w:queue(ben, "Join", "Ranked1v1"), "join")
	w:run(Config.Queue.TickSeconds + 0.1)
	local session = w.services.SelectService.getSessionOf(ann)
	h.expect(session, "no session")
	local finishes = {}
	w.makeMatch = function(config)
		return setmetatable({
			config = config,
			Finish = function(_, ...)
				table.insert(finishes, table.pack(...))
			end,
		}, {
			__index = function(_, key)
				error("broken match field " .. tostring(key))
			end,
		})
	end
	w:run(Config.Select.Seconds + 0.2)
	h.expect(#w.started == 1 and #finishes == 1, "the match wasn't abandoned")
	local args = finishes[1]
	h.expect(args[1] == "Abandoned" and args[2] == 0, "Finish args")
	h.expect(args[3].requeue == true and args[3].reason == "Something went wrong.", "Finish opts")
	for _, player in { ann, ben } do
		h.expect(w.services.SelectService.getSessionOf(player) == nil, player.Name .. " is still in the session")
		h.expect(
			#selectEvents(player, "Cancel") == 0,
			player.Name .. " got a Cancel from the session (the match sends it)"
		)
		h.expect(not w.services.QueueService.isQueued(player), player.Name .. " was re-queued by the session")
	end
	h.expect(w.inUse[session.slot], "the session released the match's slot")
end)

-- Rooms ----------------------------------------------------------------------------

h.test("room party joins check every member's friends and rating rules", function()
	local w = newWorld()
	local host = w:player(10, "Host")
	w.friends[1] = { 10 }
	w.friends[3] = { 10 }
	local ann, ben, cid = w:player(1, "Ann"), w:player(2, "Ben"), w:player(3, "Cid")
	local ok, room = w:room(host, "Create", { mode = "FFA", friendsOnly = true })
	h.expect(ok, "create")
	w:makeParty(ann, ben)
	local message
	ok, message = w:room(ben, "Join", room.id)
	h.expect(
		not ok and message == "Only your party leader can join rooms. Leave the party to join on your own.",
		"member"
	)
	ok, message = w:room(ann, "Join", room.id)
	h.expect(
		not ok and message == "Ben can't join this room: That room is for the host's friends only.",
		tostring(message)
	)
	h.expect(w.services.RoomService.getRoomOf(ann) == nil, "Ann went in without her party")

	h.expect(w:party(ben, "Leave"), "Ben leave")
	w:run(Config.Party.RequestBurst) -- refill the request budget
	w:makeParty(ann, cid)
	w.ratings[cid] = { ["1v1"] = 900 }
	local ok2, ranked = w:room(host, "Create", { mode = "FFA", minRating = 1000 })
	h.expect(not ok2, "the host is still in the first room") -- one room at a time
	h.expect(w:room(host, "Leave"), "host leave")
	ok2, ranked = w:room(host, "Create", { mode = "FFA", minRating = 1000 })
	h.expect(ok2, "create rated room")
	ok, message = w:room(ann, "Join", ranked.id)
	h.expect(
		not ok and message == "Cid can't join this room: Your rating (900) is below this room's minimum (1000).",
		tostring(message)
	)
	w.ratings[cid] = { ["1v1"] = 1200 }
	ok, message = w:room(ann, "Join", ranked.id)
	h.expect(ok, "a party that passes every rule: " .. tostring(message))
	local teams = {}
	for _, member in message.members do
		h.expect(not teams[member.team], "two fighters on one FFA team")
		teams[member.team] = true
	end
	h.expect(#message.members == 3, "the party didn't come along")
	h.expect(w.services.RoomService.getRoomOf(cid) ~= nil, "Cid isn't in the room")
end)

h.test("a Random custom room votes from its mode's map pool", function()
	local w = newWorld()
	local ann = w:player(1, "Ann")
	local ok, room = w:room(ann, "Create", { mode = "2v2" })
	h.expect(ok and room.settings.mapId == "Random", "a new room's map is Random")
	h.expect(w:room(ann, "AddBot", { difficulty = "Easy" }), "add bot")
	ok = w:room(ann, "Start")
	h.expect(ok, "start")
	local session = w.services.SelectService.getSessionOf(ann)
	h.expect(session and session.fixedMap == nil and #session.maps == Config.Select.MapChoices, "no vote")
	h.expect(session.config.mapPool == Config.Queue.MapPools["2v2"], "the room's mode's pool wasn't used")
	for _, mapId in session.maps do
		h.expect(table.find(Config.Queue.MapPools["2v2"], mapId), mapId .. " isn't in the 2v2 pool")
	end
	local begin = selectEvents(ann, "Begin")[1]
	h.expect(begin.maps and #begin.maps == 3 and begin.maps[1].votes == 0 and begin.fixedMap == nil, "Begin maps")
	w:select(ann, "Vote", { mapId = session.maps[2] })
	w:select(ann, "Vote", { mapId = "NotAMap" })
	h.expect(session.votes.p1 == session.maps[2], "vote")
	w:select(ann, "Lock", { legend = "Random" })
	h.expect(session.players[ann].random and session.players[ann].legend ~= "Random", "Random resolves at lock")
	w:run(1)
	h.expect(#w.started == 1 and w.started[1].config.mapId == session.maps[2], "the voted map wasn't used")
	h.expect(w.started[1].config.roomId == room.id, "roomId")
end)

h.test("a party's room Create checks every member against the room's rules", function()
	local w = newWorld()
	local ann, ben = w:player(1, "Ann"), w:player(2, "Ben")
	w:makeParty(ann, ben)
	local ok, message = w:room(ann, "Create", { mode = "FFA", friendsOnly = true })
	h.expect(
		not ok and message == "Ben can't join this room: That room is for the host's friends only.",
		tostring(message)
	)
	w.ratings[ben] = { ["1v1"] = 900 }
	ok, message = w:room(ann, "Create", { mode = "FFA", minRating = 1000 })
	h.expect(
		not ok and message == "Ben can't join this room: Your rating (900) is below this room's minimum (1000).",
		tostring(message)
	)
	w.ratings[ann] = { ["1v1"] = 500 } -- the host's own rating doesn't count
	w.ratings[ben] = nil
	ok, message = w:room(ann, "Create", { mode = "FFA", minRating = 1000 })
	h.expect(ok and #message.members == 2, "a party that passes: " .. tostring(message))
end)

h.test("a room Create checks the party again after the name filter", function()
	local w = newWorld()
	local textService = w.game:GetService("TextService")
	function textService.FilterStringAsync(_, text)
		task.wait(0.05)
		return {
			GetNonChatStringForBroadcastAsync = function()
				return text
			end,
		}
	end
	local ann, ben = w:player(1, "Ann"), w:player(2, "Ben")
	w:makeParty(ann, ben)
	local result
	task.spawn(function()
		result = table.pack(w:room(ann, "Create", { mode = "FFA", name = "Fun" }))
	end)
	h.expect(result == nil, "Create didn't wait for the filter")
	h.expect(w:party(ben, "Leave"), "Ben couldn't leave")
	task.wait(0.15)
	h.expect(result and not result[1] and result[2] == "Your party changed. Try again.", tostring(result and result[2]))
	h.expect(w.services.RoomService.getRoomOf(ann) == nil and w.services.RoomService.getRoomOf(ben) == nil, "a room")

	-- a search started during the wait is cancelled when the room is made: never both
	result = nil
	task.spawn(function()
		result = table.pack(w:room(ann, "Create", { mode = "FFA", name = "Fun" }))
	end)
	h.expect(w:queue(ann, "Join", "FFA"), "Ann couldn't queue during the wait")
	task.wait(0.15)
	h.expect(result and result[1] and result[2].name == "Fun", "Create failed: " .. tostring(result and result[2]))
	h.expect(w.services.RoomService.getRoomOf(ann) ~= nil, "no room")
	h.expect(not w.services.QueueService.isQueued(ann), "Ann is in a room and searching")
end)

h.test("a room join checks the party again after the friends check", function()
	local w = newWorld()
	local host = w:player(10, "Host")
	local ok, room = w:room(host, "Create", { mode = "FFA", friendsOnly = true })
	h.expect(ok, "create")
	w.friendsDelay = 0.3 -- friend sets of players who join now are still loading: the check asks Roblox
	local ann, dee = w:player(1, "Ann"), w:player(4, "Dee")
	for _, player in { ann, dee } do
		function player.IsFriendsWithAsync(_, userId)
			task.wait(0.05)
			return userId == 10
		end
	end
	w:makeParty(ann, dee)
	local result
	task.spawn(function()
		result = table.pack(w:room(ann, "Join", room.id))
	end)
	h.expect(result == nil, "the friends check didn't yield")
	w:remove(dee)
	task.wait(0.3)
	h.expect(result and not result[1] and result[2] == "Dee left.", tostring(result and result[2]))
	h.expect(w.services.RoomService.getRoomOf(dee) == nil, "a player who left joined the room")
	h.expect(w.services.RoomService.getRoomOf(ann) == nil, "Ann joined without her party")
end)

h.finish()
