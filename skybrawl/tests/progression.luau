--[[
    Tests for server progression (menus design 4.8-4.10, track S2): match
    rewards with events and seasons (ProgressionService), daily missions
    (MissionService), the rankings view helpers (RankingsView) and the
    seasonal ranked ladders (LeaderboardService: season stores, request
    budgets and the fallback limit, shared and timed-out fetches, failed
    fetches, friends fetches, the no-DataStore and Studio fallbacks, the
    shutdown flush).

    Services load through h.requireServer with a fake game (DataStoreService,
    UserService), a test-controlled os.time / os.clock, a fake DataService
    holding real v2 profiles (DataService.prepareProfile) and a fake
    FriendCache.
    Run from the skybrawl folder with:  lune run tests/progression
]]

local serde = require("@lune/serde")
local realTask = require("@lune/task")
local Enum = require("@lune/roblox").Enum

local h = require("./harness")

local Config = h.require("Config")
local Events = h.require("Events")
local Missions = h.require("Missions")
local Rankings = h.require("Rankings")
local RankingsView = h.require("RankingsView")
local Ranks = h.require("Ranks")
local Seasons = h.require("Seasons")
local DataService = h.requireServer("DataService")

local DAY = 86400
-- 2026-10-20 12:00 UTC: inside Season 1 (ends 2026-12-01), no event running
local NOW = Events.parse("2026-10-20T12:00:00Z")
local TODAY = Missions.dayIndex(NOW)
local SHADOW_WEEK = Events.parse("2026-10-12T12:00:00Z") -- "Double XP Shadow Week" (Vex) is on
local LAUNCH_WEEKEND = Events.parse("2026-10-17T12:00:00Z") -- "Launch Weekend" (1.5x coins) is on
local S1_END = Events.parse("2026-12-01T00:00:00Z")

local function deepEqual(a, b)
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b
	end
	for k, v in a do
		if not deepEqual(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function describeValue(value)
	if type(value) == "table" then
		return serde.encode("json", value)
	end
	return tostring(value)
end

local function expectEqual(got, want, what)
	h.expect(deepEqual(got, want), string.format("%s: got %s, want %s", what, describeValue(got), describeValue(want)))
end

local function merge(base, over)
	local out = table.clone(base)
	for k, v in over or {} do
		out[k] = v
	end
	return out
end

local function templateOf(id)
	for _, template in Config.Missions.Templates do
		if template.Id == id then
			return template
		end
	end
	return nil
end

-- A MissionEntry as the profile stores it.
local function mission(id, goal, progress, opts)
	opts = opts or {}
	local template = templateOf(id)
	return {
		Id = id,
		Param = opts.param,
		Goal = goal,
		Progress = progress or 0,
		Claimed = opts.claimed == true,
		Coins = opts.coins or template.Coins,
		XP = opts.xp or template.XP,
	}
end

-- Environment -------------------------------------------------------------------

local function newStore(env, name)
	local store = { name = name, data = {}, sets = {}, gets = {}, sortedCalls = 0 }
	function store.SetAsync(_, key, value)
		if store.failWrites then
			error("502: write rejected")
		end
		table.insert(store.sets, { key = key, value = value })
		store.data[key] = value
		if env.onSet then
			env.onSet()
		end
	end
	function store.GetAsync(_, key)
		table.insert(store.gets, key)
		if env.getDelay then
			realTask.wait(env.getDelay)
		end
		if store.failReads then
			error("403: no API access")
		end
		return store.data[key]
	end
	function store.GetSortedAsync(_, ascending, pageSize)
		store.sortedCalls += 1
		if env.sortedDelay then
			realTask.wait(env.sortedDelay)
		end
		if store.failReads then
			error("403: no API access")
		end
		local items = {}
		for key, value in store.data do
			table.insert(items, { key = key, value = value })
		end
		table.sort(items, function(a, b)
			if ascending then
				return a.value < b.value
			end
			return a.value > b.value
		end)
		while #items > pageSize do
			table.remove(items)
		end
		return {
			GetCurrentPage = function()
				return items
			end,
		}
	end
	return store
end

-- A DataService stand-in over real profiles: get / update (no snapshots) / isSaving (every loaded profile
-- saves unless notSaving[player]).
local function fakeDataService(profiles, notSaving)
	local fake = {}
	function fake.get(player)
		return profiles[player]
	end
	function fake.isSaving(player)
		return profiles[player] ~= nil and not notSaving[player]
	end
	function fake.update(player, fn)
		local profile = profiles[player]
		if not profile then
			return nil
		end
		local results = table.pack(fn(profile))
		return table.unpack(results, 1, results.n)
	end
	return fake
end

-- A task library whose long waits park the thread forever (service loops), so start() can run under Lune.
local parkingTask = setmetatable({
	wait = function(seconds)
		if seconds and seconds >= 1 then
			coroutine.yield()
		end
		return realTask.wait(seconds)
	end,
}, { __index = realTask })

--[[
    MissionService, ProgressionService and LeaderboardService wired to each
    other and to fakes. env.now is os.time(); env.clockOffset is added to
    the real os.clock(); env.budget[request type name] is what
    GetRequestBudgetForRequestType answers (nil for the types not listed);
    env.studio is RunService:IsStudio(); env.onClose is what start() bound
    to BindToClose. opts: now, noDataStore, parkWaits.
]]
local function newEnv(opts)
	opts = opts or {}
	h.resetRemotes()
	local game = h.fakeGame()
	local env = {
		game = game,
		now = opts.now or NOW,
		clockOffset = 0,
		profiles = {},
		notSaving = {}, -- [Player] = true: DataService.isSaving says no
		stores = {},
		budget = { GetAsync = 100, GetSortedAsync = 100, SetIncrementSortedAsync = 100 },
		budgetTypes = {},
		warnings = {},
		friendIds = {},
		nameCalls = 0,
		nameplates = 0,
	}
	local fakeOs = setmetatable({
		time = function()
			return env.now
		end,
		clock = function()
			return os.clock() + env.clockOffset
		end,
	}, { __index = os })

	function env.store(name)
		if not env.stores[name] then
			env.stores[name] = newStore(env, name)
		end
		return env.stores[name]
	end
	local dataStores = game:GetService("DataStoreService")
	function dataStores.GetOrderedDataStore(_, name)
		if opts.noDataStore then
			error("You must publish this place to the web to access DataStore.")
		end
		return env.store(name)
	end
	function dataStores.GetRequestBudgetForRequestType(_, requestType)
		table.insert(env.budgetTypes, requestType)
		return env.budget[requestType.Name]
	end
	game:GetService("RunService").IsStudio = function()
		return env.studio == true
	end
	function game.BindToClose(_, fn)
		env.onClose = fn
	end
	local userService = game:GetService("UserService")
	function userService.GetUserInfosByUserIdsAsync(_, ids)
		env.nameCalls += 1
		local infos = {}
		for _, id in ids do
			table.insert(infos, { Id = id, Username = "user" .. id, DisplayName = "Friend" .. id })
		end
		return infos
	end

	local globals = {
		game = game,
		os = fakeOs,
		warn = function(...)
			local parts = {}
			for _, part in { ... } do
				table.insert(parts, tostring(part))
			end
			table.insert(env.warnings, table.concat(parts, " "))
		end,
		task = if opts.parkWaits then parkingTask else nil,
	}
	local services = {
		DataService = fakeDataService(env.profiles, env.notSaving),
		CharacterService = {
			refreshNameplate = function()
				env.nameplates += 1
			end,
		},
		FriendCache = {
			friendIds = function(player)
				return env.friendIds[player] or {}
			end,
		},
	}
	for _, name in { "MissionService", "ProgressionService", "LeaderboardService" } do
		services[name] = h.requireServer(name, globals)
	end
	for _, name in { "MissionService", "ProgressionService", "LeaderboardService" } do
		services[name].init(services)
	end
	env.services = services
	env.Missions = services.MissionService
	env.Progression = services.ProgressionService
	env.Leaderboard = services.LeaderboardService

	-- A player on this server with a fresh v2 profile (prepared at env.now) unless `withProfile` is false.
	function env.player(userId, name, withProfile)
		local player = h.fakePlayer(userId, name)
		game:GetService("Players"):_add(player)
		if withProfile ~= false then
			env.profiles[player] = DataService.prepareProfile(nil, userId, env.now)
		end
		return player, env.profiles[player]
	end
	return env
end

local function toastsFor(player)
	local out = {}
	for _, call in h.remote("Toast").calls do
		if call.player == player then
			table.insert(out, call.args[1])
		end
	end
	return out
end

local function hasToast(player, text)
	return table.find(toastsFor(player), text) ~= nil
end

local function info(over)
	return merge({
		source = "Casual",
		ranked = false,
		mode = "FFA",
		duration = 120,
		hasBots = false,
		queueType = "FFA",
		mapId = "SkyShip",
		training = false,
		damageMultiplier = 1,
	}, over)
end

local function rankedInfo(mode, over)
	return info(merge({ source = "Ranked", ranked = true, mode = mode, queueType = "Ranked" .. mode }, over))
end

local function entry(player, over)
	return merge({
		player = player,
		team = 1,
		won = false,
		draw = false,
		kos = 0,
		falls = 0,
		damageDealt = 0,
		damageTaken = 0,
		legend = "Kestrel",
		ownLook = false,
		placement = 1,
		weaponDamage = {},
		trueCombos = 0,
		maxCombo = 0,
	}, over)
end

local STORE_1V1 = Rankings.storeName(1, "1v1")

print("Rewards and events")

h.test("event multipliers double XP only for the event's legend", function()
	local env = newEnv({ now = SHADOW_WEEK })
	local vexPlayer, vex = env.player(1, "VexMain")
	local kesPlayer, kes = env.player(2, "KesMain")
	local stats = { won = true, kos = 2, damageDealt = 100 }
	-- base: XP 40 + 2 * 15 + 50 + 100 * 0.1 = 130, coins 20 + 2 * 8 + 30 = 66
	local rewards = env.Progression.applyMatch(info(), {
		entry(vexPlayer, merge(stats, { legend = "Vex" })),
		entry(kesPlayer, merge(stats, { legend = "Kestrel", team = 2 })),
	})
	local r1, r2 = rewards[vexPlayer], rewards[kesPlayer]
	h.expect(r1.xp == 260 and r1.coins == 66 and r1.xpMult == 2 and r1.coinMult == 1, "Vex: " .. describeValue(r1))
	expectEqual(r1.events, { "Double XP Shadow Week" }, "Vex events")
	h.expect(r2.xp == 130 and r2.coins == 66 and r2.xpMult == 1 and r2.coinMult == 1, "Kestrel: " .. describeValue(r2))
	expectEqual(r2.events, {}, "Kestrel events")
	h.expect(vex.XP == 260 and kes.XP == 130 and vex.Coins == 66, "profiles weren't paid the rewards")
	h.expect(r1.xpTotal == vex.XP and r1.levelAfter == (Ranks.levelFromXP(vex.XP)), "xpTotal / levelAfter")
end)

h.test("event bonus applies after the per-match caps", function()
	local env = newEnv()
	local big = { won = true, kos = 20, damageDealt = 5000 }
	-- capped at 150 coins / 400 XP first, then the event multipliers
	local coins, xp = env.Progression.computeRewards(big, 1, 2, 1.5)
	h.expect(coins == 225 and xp == 800, string.format("coins %d xp %d", coins, xp))
	-- bots (x0.4): 210 * 0.4 = 84 coins; min(400, 890 * 0.4) = 356 XP, doubled by the event
	coins, xp = env.Progression.computeRewards(big, 0.4, 2, 1)
	h.expect(coins == 84 and xp == 712, string.format("bots: coins %d xp %d", coins, xp))
	coins, xp = env.Progression.computeRewards(big, 1, 1, 1)
	h.expect(coins == 150 and xp == 400, "no event")
	coins, xp = env.Progression.computeRewards(big, 1, 0 / 0, 99)
	h.expect(coins == 150 * Config.EventMaxMult and xp == 400, "junk multipliers")

	-- through applyMatch during "Launch Weekend" (1.5x coins for everyone)
	env.now = LAUNCH_WEEKEND
	local player = env.player(3, "Rich")
	local rewards = env.Progression.applyMatch(info(), { entry(player, big) })[player]
	h.expect(rewards.coins == 225 and rewards.xp == 400 and rewards.coinMult == 1.5, describeValue(rewards))
	expectEqual(rewards.events, { "Launch Weekend" }, "events")
end)

h.test("training and short matches pay nothing", function()
	local env = newEnv()
	local player, profile = env.player(4, "Trainee")
	local before = table.clone(profile)
	local missionsBefore = serde.encode("json", profile.Missions)
	local rewards =
		env.Progression.applyMatch(info({ source = "Training", training = true, mode = "1v1", duration = 300 }), {
			entry(player, { won = true, kos = 5, damageDealt = 900 }),
		})
	expectEqual(rewards, {}, "training rewards")
	h.expect(profile.Matches == before.Matches and profile.XP == before.XP, "training changed the profile")

	local short = env.Progression.applyMatch(info({ duration = 5 }), {
		entry(player, { won = true, kos = 5, damageDealt = 900 }),
	})[player]
	h.expect(short.coins == 0 and short.xp == 0, "a short match paid " .. describeValue(short))
	h.expect(short.missions == nil, "a short match moved missions")
	h.expect(serde.encode("json", profile.Missions) == missionsBefore, "a short match changed the missions")
	h.expect(profile.Matches == before.Matches + 1 and profile.Coins == before.Coins, "short match stats")
end)

h.test("applyMatch accepts a match entry without the new fields", function()
	local env = newEnv()
	local player, profile = env.player(5, "Legacy")
	-- what Match sent before the menus: no legend, weaponDamage, trueCombos, training or minBotDifficulty
	local legacyInfo = { source = "Ranked", ranked = true, mode = "1v1", duration = 90, hasBots = false }
	local legacyEntry = {
		player = player,
		team = 1,
		won = true,
		draw = false,
		kos = 3,
		falls = 1,
		damageDealt = 200,
		opponentRating = 1000,
	}
	local rewards = env.Progression.applyMatch(legacyInfo, { legacyEntry })[player]
	h.expect(rewards and rewards.coins > 0 and rewards.ratingMode == "1v1", "rewards: " .. describeValue(rewards))
	h.expect(type(rewards.missions) == "table", "missions list")
	expectEqual(profile.SeasonStats["1v1"].Legends, { Avatar = { Wins = 1, Played = 1 } }, "legend defaults to Avatar")
end)

h.test("a mission error never costs the match rewards", function()
	local env = newEnv()
	local player, profile = env.player(6, "Unlucky")
	env.services.MissionService = {
		onMatch = function()
			error("missions broke")
		end,
	}
	local rewards = env.Progression.applyMatch(info(), { entry(player, { won = true, kos = 2 }) })[player]
	h.expect(rewards and rewards.coins > 0 and rewards.missions == nil, "rewards: " .. describeValue(rewards))
	h.expect(profile.Coins == rewards.coins and profile.Matches == 1, "the match wasn't paid")
	h.expect(string.find(table.concat(env.warnings, "\n"), "missions broke", 1, true), "no warning")
end)

print("Ranked seasons")

h.test("ranked results update season wins, losses and legend stats", function()
	local env = newEnv()
	local winner, winnerProfile = env.player(10, "Winner")
	local loser, loserProfile = env.player(11, "Loser")
	local rewards = env.Progression.applyMatch(rankedInfo("1v1"), {
		entry(winner, { won = true, kos = 3, legend = "Vex", opponentRating = 1000 }),
		entry(loser, { team = 2, legend = "Sol", falls = 3, opponentRating = 1000 }),
	})
	expectEqual(winnerProfile.SeasonStats["1v1"], {
		Wins = 1,
		Losses = 0,
		Legends = { Vex = { Wins = 1, Played = 1 } },
	}, "winner season stats")
	expectEqual(loserProfile.SeasonStats["1v1"], {
		Wins = 0,
		Losses = 1,
		Legends = { Sol = { Wins = 0, Played = 1 } },
	}, "loser season stats")
	h.expect(winnerProfile.SeasonStats["2v2"].Wins == 0, "the other ladder moved")
	local r = rewards[winner]
	h.expect(r.ratingMode == "1v1" and r.ratingAfter > r.ratingBefore and r.tierAfter ~= nil, "rating fields")
	h.expect(winnerProfile.Rating1v1 == r.ratingAfter and winnerProfile.Ranked1v1Played == 1, "rating applied")

	-- both ladders reach the season store now
	env.Progression.applyMatch(rankedInfo("2v2"), {
		entry(winner, { won = true, legend = "Moss", opponentRating = 1000 }),
	})
	h.expect(winnerProfile.SeasonStats["2v2"].Legends.Moss.Wins == 1, "2v2 legend stats")
	local queued = env.Leaderboard.pendingFor(STORE_1V1)
	h.expect(queued and queued[10] == Rankings.encode(winnerProfile.Rating1v1, "Vex", 1, 0), "1v1 submit")
	h.expect(queued[11] == Rankings.encode(loserProfile.Rating1v1, "Sol", 0, 1), "loser submit")
	local queued2 = env.Leaderboard.pendingFor(Rankings.storeName(1, "2v2"))
	h.expect(queued2 and queued2[10] == Rankings.encode(winnerProfile.Rating2v2, "Moss", 1, 0), "2v2 submit")
end)

h.test("a draw changes neither wins nor losses", function()
	local env = newEnv()
	local player, profile = env.player(12, "Even")
	local before = { Wins = profile.Wins, Losses = profile.Losses }
	env.Progression.applyMatch(rankedInfo("1v1"), {
		entry(player, { draw = true, legend = "Yuki", opponentRating = 1000 }),
	})
	local stats = profile.SeasonStats["1v1"]
	h.expect(stats.Wins == 0 and stats.Losses == 0, "season W-L moved on a draw")
	expectEqual(stats.Legends.Yuki, { Wins = 0, Played = 1 }, "a draw is still a game played")
	h.expect(profile.Wins == before.Wins and profile.Losses == before.Losses, "lifetime W-L moved on a draw")
	h.expect(profile.Ranked1v1Played == 1, "rating games")
end)

h.test("a leaver's loss counts toward season losses", function()
	local env = newEnv()
	local player, profile = env.player(13, "Dodger")
	env.Progression.applyLeaver(player, "2v2", 1100, "Sol")
	expectEqual(profile.SeasonStats["2v2"], {
		Wins = 0,
		Losses = 1,
		Legends = { Sol = { Wins = 0, Played = 1 } },
	}, "2v2 season stats")
	h.expect(profile.Rating2v2 < Config.Ranked.StartRating and profile.Ranked2v2Played == 1, "rating loss")
	h.expect(profile.Losses == 1 and profile.Matches == 1, "lifetime stats")
	local queued = env.Leaderboard.pendingFor(Rankings.storeName(1, "2v2"))
	h.expect(queued and queued[13] == Rankings.encode(profile.Rating2v2, "Sol", 0, 1), "leaver submit")

	-- "Random" (a pick that never resolved) and nil count the loss without a legend
	env.Progression.applyLeaver(player, "1v1", 1000, "Random")
	env.Progression.applyLeaver(player, "1v1", 0 / 0, nil)
	expectEqual(profile.SeasonStats["1v1"], { Wins = 0, Losses = 2, Legends = {} }, "1v1 season stats")
	env.Progression.applyLeaver(player, "FFA", 1000, "Vex")
	h.expect(profile.Losses == 3, "an FFA leave is not ranked")
end)

h.test("applyMatch after the season end resets first", function()
	local env = newEnv()
	local player, profile = env.player(14, "Veteran")
	profile.Rating1v1 = 1500
	profile.Peak1v1 = 1600
	profile.SeasonStats["1v1"] = { Wins = 10, Losses = 5, Legends = { Vex = { Wins = 6, Played = 9 } } }
	env.now = S1_END + DAY
	local rewards = env.Progression.applyMatch(rankedInfo("1v1"), {
		entry(player, { won = true, legend = "Vex", opponentRating = 1250 }),
	})[player]
	h.expect(profile.Season == 2, "season " .. profile.Season)
	h.expect(rewards.ratingBefore == Seasons.softReset(1500), "rated before the soft reset: " .. rewards.ratingBefore)
	expectEqual(profile.SeasonBadge, { Season = 1, Name = "Season 1", Tier1v1 = "Gold" }, "badge")
	expectEqual(profile.SeasonStats["1v1"], {
		Wins = 1,
		Losses = 0,
		Legends = { Vex = { Wins = 1, Played = 1 } },
	}, "the new season's stats")
	h.expect(hasToast(player, "Season 2 has begun! Your ratings were soft-reset."), "season toast")
	h.expect(env.Leaderboard.pendingFor(Rankings.storeName(2, "1v1"))[14] ~= nil, "submitted to Season 2")
	h.expect(env.Leaderboard.pendingFor(STORE_1V1) == nil, "submitted to Season 1")

	-- a leaver loss right after a season ends resets first too
	local other, otherProfile = env.player(15, "Late")
	otherProfile.Season = 1
	otherProfile.Rating2v2 = 1400
	env.Progression.applyLeaver(other, "2v2", 1000, "Kestrel")
	h.expect(otherProfile.Season == 2 and otherProfile.SeasonStats["2v2"].Losses == 1, "leaver season")
	h.expect(hasToast(other, "Season 2 has begun! Your ratings were soft-reset."), "leaver season toast")
end)

h.test("a junk opponent rating rates against StartRating", function()
	local env = newEnv()
	local start = Config.Ranked.StartRating
	local player, profile = env.player(16, "Lucky")
	env.Progression.applyMatch(rankedInfo("1v1"), { entry(player, { won = true, opponentRating = 0 / 0 }) })
	h.expect(profile.Rating1v1 == Ranks.newRating(start, start, 1, 0), "NaN: " .. profile.Rating1v1)
	local leaver, leaverProfile = env.player(17, "Quitter")
	env.Progression.applyLeaver(leaver, "1v1", 0, "Vex")
	h.expect(leaverProfile.Rating1v1 == Ranks.newRating(start, start, 0, 0), "0: " .. leaverProfile.Rating1v1)
	env.Progression.applyLeaver(leaver, "2v2", math.huge, nil)
	h.expect(leaverProfile.Rating2v2 == Ranks.newRating(start, start, 0, 0), "inf: " .. leaverProfile.Rating2v2)
end)

h.test("one bad entry never costs the others their rewards", function()
	local env = newEnv()
	local good, profile = env.player(18, "Fine")
	local bad = env.player(19, "Broken")
	local update = env.services.DataService.update
	env.services.DataService.update = function(player, fn)
		if player == bad then
			error("profile exploded")
		end
		return update(player, fn)
	end
	local rewards = env.Progression.applyMatch(info(), {
		entry(bad, { won = true }),
		entry(good, { team = 2, kos = 1 }),
	})
	h.expect(rewards[good] and rewards[bad] == nil and profile.Matches == 1, "the good entry wasn't paid")
	h.expect(pcall(env.Progression.applyLeaver, bad, "1v1", 1000, "Vex"), "applyLeaver threw")
	local logged = 0
	for _, line in env.warnings do
		if string.find(line, "profile exploded", 1, true) then
			logged += 1
		end
	end
	h.expect(logged == 2, "logged " .. logged .. " times")
end)

print("Missions")

h.test("mission progress comes from a match entry and reports justDone once", function()
	local env = newEnv()
	local player, profile = env.player(20, "Grinder")
	profile.Missions.List = {
		mission("KOs", 8, 6),
		mission("Damage", 2000, 0),
		mission("LegendWin", 1, 0, { param = "Vex" }),
	}
	local match = entry(player, { won = true, kos = 3, damageDealt = 500, legend = "Vex" })
	local moved = env.Progression.applyMatch(info(), { match })[player].missions
	expectEqual(moved, {
		{ index = 1, text = "KO 8 opponents", progress = 8, goal = 8, done = true, justDone = true },
		{ index = 2, text = "Deal 2,000 damage", progress = 500, goal = 2000, done = false, justDone = false },
		{ index = 3, text = "Win as Vex", progress = 1, goal = 1, done = true, justDone = true },
	}, "moved missions")
	h.expect(hasToast(player, "Mission complete: KO 8 opponents"), "KOs toast")
	h.expect(hasToast(player, "Mission complete: Win as Vex"), "legend win toast")
	h.expect(not hasToast(player, "Mission complete: Deal 2,000 damage"), "an unfinished mission toasted")

	local toastCount = #toastsFor(player)
	local again = env.Progression.applyMatch(info(), { match })[player].missions
	expectEqual(again, {
		{ index = 2, text = "Deal 2,000 damage", progress = 1000, goal = 2000, done = false, justDone = false },
	}, "second match")
	for i = toastCount + 1, #toastsFor(player) do
		h.expect(not string.find(toastsFor(player)[i], "Mission complete", 1, true), "completion toasted twice")
	end
	h.expect(profile.Missions.List[1].Claimed == false, "a completed mission was claimed by itself")

	-- bots with an Easy bot never count
	local before = profile.Missions.List[2].Progress
	local easy = info({ source = "Bots", hasBots = true, minBotDifficulty = "Easy" })
	h.expect(#env.Progression.applyMatch(easy, { match })[player].missions == 0, "Easy bots moved missions")
	h.expect(profile.Missions.List[2].Progress == before, "Easy bots progress")
end)

h.test("a match after midnight pays yesterday's unclaimed missions", function()
	local env = newEnv({ now = NOW - DAY })
	local player, profile = env.player(21, "NightOwl")
	local yesterday = profile.Missions.List
	h.expect(profile.Missions.Day == TODAY - 1 and #yesterday == 3, "yesterday's missions")
	yesterday[1].Progress = yesterday[1].Goal -- done, not claimed: paid at the rollover
	yesterday[2].Progress = yesterday[2].Goal
	yesterday[2].Claimed = true -- already paid
	local yesterdayProgress = { yesterday[1].Progress, yesterday[2].Progress, yesterday[3].Progress }
	local owed = { coins = yesterday[1].Coins, xp = yesterday[1].XP }
	profile.XP = 115 -- 5 XP short of level 2: the payout alone is a level up
	local coinsBefore, xpBefore = profile.Coins, profile.XP

	-- today's missions come from the day and user id: a match that moves every one it can
	local preview = serde.decode("json", serde.encode("json", profile.Missions))
	Missions.ensureDay(preview, TODAY, 21)
	local over = { won = true, kos = 4, damageDealt = 700, trueCombos = 2, legend = "Moss", weaponDamage = {} }
	for _, m in preview.List do
		if m.Id == "LegendWin" or m.Id == "LegendMatches" then
			over.legend = m.Param
		elseif m.Id == "WeaponDamage" then
			over.weaponDamage[m.Param] = 400
		end
	end
	local match = entry(player, over)

	env.now = NOW
	local rewards = env.Progression.applyMatch(info(), { match })[player]
	h.expect(profile.Coins == coinsBefore + rewards.coins + owed.coins, "coins " .. profile.Coins)
	h.expect(profile.XP == xpBefore + rewards.xp + owed.xp and rewards.xpTotal == profile.XP, "xp " .. profile.XP)
	local text = string.format("Mission rewards collected: +%d coins, +%d XP", owed.coins, owed.xp)
	h.expect(hasToast(player, text), "no payout toast: " .. table.concat(toastsFor(player), " | "))
	h.expect(profile.Missions.Day == TODAY and not profile.Missions.Rerolled, "today's missions")
	-- the match counted for today's missions, not yesterday's
	expectEqual(
		{ yesterday[1].Progress, yesterday[2].Progress, yesterday[3].Progress },
		yesterdayProgress,
		"yesterday's progress"
	)
	local stats = Missions.statsFromEntry(info(), match)
	local movable = 0
	for i, m in profile.Missions.List do
		h.expect(m.Id == preview.List[i].Id, "today's list " .. i)
		local want = math.min(m.Goal, stats[Missions.statKey(m)] or 0)
		h.expect(m.Progress == want, string.format("%s: %d, want %d", m.Id, m.Progress, want))
		movable += if want > 0 then 1 else 0
	end
	h.expect(movable >= 2 and #rewards.missions == movable, "moved " .. describeValue(rewards.missions))
	-- the payout is in levelBefore (the results XP bar starts at xpTotal - xp), and its level up is toasted
	h.expect(rewards.levelBefore == (Ranks.levelFromXP(xpBefore + owed.xp)) and rewards.levelBefore > 1, "levelBefore")
	h.expect(rewards.levelBefore == (Ranks.levelFromXP(rewards.xpTotal - rewards.xp)), "levelBefore vs the XP bar")
	h.expect(hasToast(player, string.format("Level up! You're now level %d.", rewards.levelAfter)), "level up toast")
	h.expect(env.nameplates == 1, "nameplate")
	-- onMatch on its own rolls the day first too
	local alone = DataService.prepareProfile(nil, 21, NOW - DAY)
	local moved = env.Missions.onMatch(alone, info(), match)
	h.expect(alone.Missions.Day == TODAY and #moved == movable, "onMatch alone: " .. describeValue(moved))
	-- paid once
	local coins = profile.Coins
	env.Progression.applyMatch(info({ duration = 5 }), { match })
	env.Progression.applyMatch(info(), { entry(player) })
	h.expect(profile.Coins == coins + env.Progression.computeRewards(entry(player), 1, 1, 1), "paid twice")
end)

h.test("reroll and claim follow the mission rules", function()
	local env = newEnv()
	local player, profile = env.player(22, "Picky")
	local list = profile.Missions.List
	local function call(action, index)
		env.clockOffset += 1 -- stay under the rate limit
		return env.Missions.request(player, action, index, profile.Missions.Day)
	end
	local oldIds = { [list[1].Id] = true, [list[2].Id] = true, [list[3].Id] = true }
	local expected = serde.decode("json", serde.encode("json", profile.Missions))
	Missions.reroll(expected, 1, expected.Day, 22)
	local ok, message = call("Reroll", 1)
	h.expect(ok == true and message == "Mission rerolled.", "reroll: " .. tostring(message))
	h.expect(not oldIds[list[1].Id] and profile.Missions.Rerolled, "the reroll repeated a template")
	expectEqual(list[1], expected.List[1], "the rerolled mission (generated from the stored day)")
	ok, message = call("Reroll", 2)
	h.expect(ok == false and message == "No free rerolls left today.", "second reroll: " .. tostring(message))

	ok, message = call("Claim", 2)
	h.expect(ok == false and message == "That mission isn't done yet.", "claim unfinished: " .. tostring(message))
	list[2].Progress = list[2].Goal
	profile.XP = 115 -- 5 XP short of level 2
	local coins = profile.Coins
	ok, message = call("Claim", 2)
	h.expect(ok == true and message == string.format("+%d coins, +%d XP", list[2].Coins, list[2].XP), message)
	h.expect(profile.Coins == coins + list[2].Coins and profile.XP == 115 + list[2].XP, "claim paid")
	local level = Ranks.levelFromXP(profile.XP)
	h.expect(level > 1 and hasToast(player, string.format("Level up! You're now level %d.", level)), "level up")
	h.expect(env.nameplates == 1, "nameplate")
	ok, message = call("Claim", 2)
	h.expect(ok == false and message == "Already claimed.", "claim twice: " .. tostring(message))
	ok, message = call("Reroll", 2)
	h.expect(ok == false and message == "That mission is already done.", "reroll claimed: " .. tostring(message))

	for _, case in { { "Claim", 7 }, { "Claim", "1" }, { "Reroll", 0 / 0 }, { "Reroll", nil } } do
		ok, message = call(case[1], case[2])
		h.expect(ok == false and message == "Unknown mission.", "bad index: " .. tostring(message))
	end
	ok, message = call("Steal", 1)
	h.expect(ok == false and message == "Bad request.", "bad action: " .. tostring(message))
	ok, message = call({}, 1)
	h.expect(ok == false and message == "Bad request.", "junk action")
	local stranger = env.player(23, "Loading", false)
	ok, message = env.Missions.request(stranger, "Claim", 1)
	h.expect(ok == false and message == "Your profile is still loading.", "no profile: " .. tostring(message))

	-- 2 requests a second, burst 3
	local spammer = env.player(24, "Spammer")
	for i = 1, 3 do
		ok, message = env.Missions.request(spammer, "Claim", 9)
		h.expect(message == "Unknown mission.", "request " .. i .. " was limited")
	end
	ok, message = env.Missions.request(spammer, "Claim", 9)
	h.expect(ok == false and message == "Slow down.", "the 4th request wasn't limited")
	env.clockOffset += 0.5
	ok, message = env.Missions.request(spammer, "Claim", 9)
	h.expect(message == "Unknown mission.", "the bucket didn't refill")
end)

h.test("a request made on yesterday's list is refused after midnight, and yesterday is still paid", function()
	local env = newEnv({ now = NOW - DAY })
	local player, profile = env.player(25, "Sleepy")
	profile.Missions.List[1].Progress = profile.Missions.List[1].Goal
	local owed = profile.Missions.List[1].Coins
	local coins = profile.Coins
	env.now = NOW
	-- yesterday's done mission #1 is paid by the rollover; #1 now is a fresh mission of today nobody has seen
	local ok, message = env.Missions.request(player, "Claim", 1)
	h.expect(ok == false and message == "Your missions changed. Take another look.", "claim: " .. tostring(message))
	h.expect(profile.Coins == coins + owed and profile.Missions.Day == TODAY, "rollover payout")
	h.expect(
		#toastsFor(player) >= 1 and string.find(toastsFor(player)[1], "Mission rewards collected", 1, true),
		"toast"
	)
	-- today's list is the profile's now: a request on it goes through
	env.clockOffset += 1
	ok, message = env.Missions.request(player, "Reroll", 2, TODAY)
	h.expect(ok == true and message == "Mission rerolled.", "reroll on today's list: " .. tostring(message))
end)

h.test("a reroll pressed on yesterday's row just after midnight keeps today's free reroll", function()
	local env = newEnv({ now = NOW - DAY })
	local player, profile = env.player(26, "Owl")
	local yesterday = profile.Missions.Day
	-- 5 s after midnight the rollover loop has moved the profile on, but the client still shows yesterday's list
	env.now = Missions.resetAt(yesterday) + 5
	env.Missions.rollover(player)
	h.expect(profile.Missions.Day == TODAY, "the rollover didn't move the profile")
	local today = table.clone(profile.Missions.List)
	local ok, message = env.Missions.request(player, "Reroll", 2, yesterday)
	h.expect(ok == false and message == "Your missions changed. Take another look.", "stale: " .. tostring(message))
	h.expect(not profile.Missions.Rerolled and profile.Missions.List[2] == today[2], "a mission of today was rerolled")
	env.clockOffset += 1
	for _, junk in { "1", {}, 0 / 0 } do
		ok, message = env.Missions.request(player, "Reroll", 2, junk)
		h.expect(ok == false and message == "Your missions changed. Take another look.", "junk day")
		env.clockOffset += 1
	end
	ok, message = env.Missions.request(player, "Reroll", 2, TODAY)
	h.expect(ok == true and message == "Mission rerolled." and profile.Missions.Rerolled, tostring(message))
end)

h.test("the rollover check pays yesterday's missions and starts a new season", function()
	local env = newEnv()
	local player, profile = env.player(26, "Idle")
	profile.Missions.List[1].Progress = profile.Missions.List[1].Goal
	local owed = { coins = profile.Missions.List[1].Coins, xp = profile.Missions.List[1].XP }
	local coins = profile.Coins
	env.Missions.rollover(player)
	h.expect(#toastsFor(player) == 0 and profile.Coins == coins, "the same day rolled over")

	env.now = NOW + DAY
	env.Missions.rollover(player)
	env.Missions.rollover(player)
	h.expect(profile.Missions.Day == TODAY + 1 and profile.Coins == coins + owed.coins, "day rollover")
	local text = string.format("Mission rewards collected: +%d coins, +%d XP", owed.coins, owed.xp)
	local payouts = 0
	for _, t in toastsFor(player) do
		if string.find(t, "Mission rewards collected", 1, true) then
			payouts += 1
		end
	end
	h.expect(hasToast(player, text) and payouts == 1, "rollover toasts: " .. table.concat(toastsFor(player), " | "))

	-- a clock that runs behind never goes back a day
	env.now = NOW
	env.Missions.rollover(player)
	h.expect(profile.Missions.Day == TODAY + 1, "went back a day")

	profile.Rating1v1 = 1400
	profile.SeasonStats["1v1"].Wins = 3
	env.now = S1_END + 60
	env.Missions.rollover(player)
	env.Missions.rollover(player)
	h.expect(profile.Season == 2 and profile.Rating1v1 == Seasons.softReset(1400), "season rollover")
	local seasonToasts = 0
	for _, t in toastsFor(player) do
		if t == "Season 2 has begun! Your ratings were soft-reset." then
			seasonToasts += 1
		end
	end
	h.expect(seasonToasts == 1, "season toasts: " .. seasonToasts)
	h.expect(env.Missions.rollover(env.player(27, "Nobody", false)) == nil, "no profile")
end)

h.test("a rollover payout that crosses a level toasts it", function()
	local env = newEnv()
	local player, profile = env.player(28, "Leveler")
	profile.Missions.List[1].Progress = profile.Missions.List[1].Goal
	profile.XP = 115 -- 5 XP short of level 2
	env.now = NOW + DAY
	env.Missions.rollover(player)
	local level = Ranks.levelFromXP(profile.XP)
	h.expect(level > 1 and hasToast(player, string.format("Level up! You're now level %d.", level)), "level up")
	h.expect(env.nameplates == 1, "nameplate")
end)

h.test("a payout level up at match end is toasted even when the match itself levels nothing", function()
	local env = newEnv({ now = NOW - DAY })
	local player, profile = env.player(29, "Payday")
	local done = profile.Missions.List[1]
	done.Progress = done.Goal
	profile.XP = math.max(0, Ranks.xpForLevel(1) - done.XP) -- the payout reaches level 2
	env.now = NOW
	local rewards = env.Progression.applyMatch(info(), { entry(player) })[player]
	h.expect(rewards.levelBefore == 2 and rewards.levelAfter == 2, "levels " .. rewards.levelBefore)
	h.expect(hasToast(player, "Level up! You're now level 2."), "level up toast")
	h.expect(env.nameplates == 1, "nameplate")
end)

print("Rankings view")

h.test("leaderboard rows decode the main legend and W-L and mark you", function()
	local entries = {
		{ key = "10", value = Rankings.encode(2214, "Vex", 312, 98) },
		{ key = "20", value = Rankings.encode(2140, nil, 280, 117) },
		{ key = "junk", value = 5 },
		{ key = "30", value = Rankings.encode(1432, "Kestrel", 48, 31) },
	}
	local names = { [10] = { name = "zeroframe", username = "zero_frame" }, [30] = { name = "SkyRunner" } }
	local rows = RankingsView.buildRows(entries, names, 20)
	h.expect(#rows == 3, "rows: " .. #rows)
	expectEqual(rows[1], {
		rank = 1,
		userId = 10,
		name = "zeroframe",
		username = "zero_frame",
		rating = 2214,
		tier = "Diamond",
		main = "Vex",
		wins = 312,
		losses = 98,
		you = false,
	}, "row 1")
	expectEqual(rows[2], {
		rank = 2,
		userId = 20,
		name = "Player 20",
		username = "Player20",
		rating = 2140,
		tier = "Diamond",
		wins = 280,
		losses = 117,
		you = true,
	}, "row 2 (you, no main, no name)")
	h.expect(rows[3].rank == 3 and rows[3].tier == "Gold" and rows[3].main == "Kestrel", "row 3")
	h.expect(rows[3].name == "SkyRunner" and rows[3].username == "Player30" and not rows[3].you, "row 3 names")
	h.expect(#RankingsView.buildRows({}, {}, 1) == 0 and #RankingsView.buildRows(nil, nil, 1) == 0, "empty")
end)

h.test("your rank shows only inside the top 100", function()
	local profile = DataService.prepareProfile(nil, 57, NOW)
	profile.Rating1v1 = 1432
	profile.Peak1v1 = 1480
	profile.Ranked1v1Played = 79
	profile.SeasonStats["1v1"] = { Wins = 48, Losses = 31, Legends = { Kestrel = { Wins = 31, Played = 48 } } }
	local entries = {}
	for i = 1, 100 do
		table.insert(entries, { key = tostring(i), value = Rankings.encode(3000 - i, "Sol", 10, 10) })
	end
	local inside = RankingsView.buildCard(profile, "1v1", RankingsView.buildRows(entries, {}, 57), true)
	h.expect(inside.rank == 57, "rank inside the list: " .. tostring(inside.rank))
	local outside = RankingsView.buildCard(profile, "1v1", RankingsView.buildRows(entries, {}, 1284), true)
	h.expect(outside.rank == nil, "a rank outside the list")
	expectEqual(outside, {
		rating = 1432,
		tier = "Gold",
		peak = 1480,
		wins = 48,
		losses = 31,
		played = 79,
		bestLegend = { id = "Kestrel", wins = 31, played = 48 },
	}, "the current season's card")
	local fresh = RankingsView.buildCard(DataService.prepareProfile(nil, 1, NOW), "2v2", {}, true)
	h.expect(fresh.bestLegend == nil and fresh.wins == 0 and fresh.rating == Config.Ranked.StartRating, "fresh card")
end)

h.test("friends rows sort by rating and include you", function()
	local rows = RankingsView.friendsRows({
		{ userId = 2, name = "Two", username = "two", value = Rankings.encode(1500, "Sol", 3, 1) },
		{ userId = 1, name = "Me", username = "me", rating = 1200, wins = 1, losses = 1, main = "Vex" },
		{ userId = 3, value = Rankings.encode(1500, "Moss", 5, 2) },
		{ userId = 4, name = "NoRating" },
		{ userId = 2, rating = 9999 },
		{ userId = "x", rating = 3000 },
	}, 1)
	h.expect(#rows == 3, "rows: " .. #rows)
	local order = {}
	for _, row in rows do
		table.insert(order, row.userId .. "#" .. row.rank)
	end
	expectEqual(order, { "3#1", "2#2", "1#3" }, "order (rating, then wins)")
	h.expect(rows[1].name == "Player 3" and rows[1].main == "Moss" and rows[1].wins == 5, "decoded friend")
	expectEqual(rows[3], {
		rank = 3,
		userId = 1,
		name = "Me",
		username = "me",
		rating = 1200,
		tier = "Silver",
		main = "Vex",
		wins = 1,
		losses = 1,
		you = true,
	}, "your row")
	h.expect(not rows[1].you and not rows[2].you, "only you are you")
end)

h.test("a past-season card comes from the stored entry and has no peak", function()
	local profile = DataService.prepareProfile(nil, 9, S1_END + DAY)
	profile.Peak1v1 = 1800
	local card = RankingsView.buildCard(profile, "1v1", {}, false, Rankings.encode(1432, "Kestrel", 48, 31))
	expectEqual(card, { rating = 1432, tier = "Gold", wins = 48, losses = 31, main = "Kestrel" }, "stored entry")
	-- your row in the list (no separate read needed)
	local rows = RankingsView.buildRows({
		{ key = "8", value = Rankings.encode(1700, "Sol", 70, 30) },
		{ key = "9", value = Rankings.encode(1500, "Yuki", 40, 20) },
	}, {}, 9)
	card = RankingsView.buildCard(profile, "1v1", rows, false, nil)
	expectEqual(card, { rank = 2, rating = 1500, tier = "Gold", wins = 40, losses = 20, main = "Yuki" }, "from the row")
	card = RankingsView.buildCard(profile, "1v1", {}, false, nil)
	h.expect(card.noEntry == true and card.peak == nil and card.played == nil and card.rank == nil, "no entry")
	h.expect(card.bestLegend == nil and card.main == nil, "no entry legends")
end)

print("Leaderboards")

h.test("season store names follow the profile's season", function()
	local env = newEnv()
	local player, profile = env.player(42, "Climber")
	profile.SeasonStats["1v1"] = { Wins = 4, Losses = 2, Legends = { Yuki = { Wins = 3, Played = 5 } } }
	profile.Rating1v1 = 1300
	env.Leaderboard.submit(player, "1v1", profile)
	local value = Rankings.encode(1300, "Yuki", 4, 2)
	h.expect(env.Leaderboard.pendingFor("SkybrawlRanked_v1_S1_1v1")[42] == value, "Season 1 store")
	profile.Season = 2
	env.Leaderboard.submit(player, "1v1", profile)
	h.expect(env.Leaderboard.pendingFor("SkybrawlRanked_v1_S2_1v1")[42] == value, "Season 2 store")
	env.Leaderboard.flush()
	expectEqual(env.stores["SkybrawlRanked_v1_S1_1v1"].sets, { { key = "42", value = value } }, "S1 write")
	expectEqual(env.stores["SkybrawlRanked_v1_S2_1v1"].sets, { { key = "42", value = value } }, "S2 write")
	h.expect(env.Leaderboard.pendingFor("SkybrawlRanked_v1_S1_1v1") == nil, "written values stay queued")
	-- without a profile argument it reads the live profile; unknown modes and season 0 are ignored
	profile.Season = 1
	env.Leaderboard.submit(player, "2v2")
	h.expect(env.Leaderboard.pendingFor(Rankings.storeName(1, "2v2"))[42] ~= nil, "live profile")
	env.Leaderboard.submit(player, "FFA", profile)
	h.expect(env.Leaderboard.pendingFor(Rankings.storeName(1, "FFA")) == nil, "FFA")
	profile.Season = 0
	env.Leaderboard.submit(player, "1v1", profile)
	h.expect(env.Leaderboard.pendingFor(Rankings.storeName(0, "1v1")) == nil, "season 0")
end)

h.test("a profile that isn't saving never reaches the ladder", function()
	local env = newEnv()
	local player, profile = env.player(60, "Unsaved")
	env.notSaving[player] = true
	profile.Rating1v1 = 1000 -- the defaults it plays on after a failed load
	env.Leaderboard.submit(player, "1v1", profile)
	env.Progression.applyMatch(rankedInfo("1v1"), { entry(player, { won = true, opponentRating = 1000 }) })
	env.Progression.applyLeaver(player, "2v2", 1000, "Vex")
	h.expect(env.Leaderboard.pendingFor(STORE_1V1) == nil, "a profile that isn't saving was queued (1v1)")
	h.expect(env.Leaderboard.pendingFor(Rankings.storeName(1, "2v2")) == nil, "queued (2v2)")
	-- nor do friends' rankings see it (the stored standing stays the one they read)
	local friend = env.player(61, "Buddy")
	env.friendIds[friend] = { 60 }
	local store = env.store(STORE_1V1)
	store.data["60"] = Rankings.encode(1850, "Yuki", 40, 12)
	local ok, data = env.Leaderboard.getRankings(friend, { mode = "1v1", scope = "Friends" })
	local row
	for _, r in ok and data.rows or {} do
		if r.userId == 60 then
			row = r
		end
	end
	h.expect(row and row.rating == 1850 and row.wins == 40, "the stored standing was replaced: " .. describeValue(row))
	h.expect(profile.SeasonStats["1v1"].Wins == 1, "the profile still counts the result")
end)

h.test("submits from Studio players are skipped", function()
	local env = newEnv()
	local player, profile = env.player(-1, "Player1")
	env.Leaderboard.submit(player, "1v1", profile)
	env.Progression.applyMatch(rankedInfo("1v1"), { entry(player, { won = true, opponentRating = 1000 }) })
	env.Progression.applyLeaver(player, "2v2", 1000, "Vex")
	h.expect(env.Leaderboard.pendingFor(STORE_1V1) == nil, "a Studio player was queued")
	env.Leaderboard.flush()
	for name, store in env.stores do
		h.expect(#store.sets == 0, "a Studio player was written to " .. name)
	end
	h.expect(profile.SeasonStats["1v1"].Wins == 1, "the profile still counts the result")
end)

h.test("the flush checks the sorted-write budget", function()
	local env = newEnv()
	for id = 31, 33 do
		local player, profile = env.player(id, "P" .. id)
		env.Leaderboard.submit(player, "1v1", profile)
	end
	local store = env.store(STORE_1V1)
	env.budget.SetIncrementSortedAsync = Config.Rankings.MinBudget
	env.Leaderboard.flush()
	h.expect(#store.sets == 0, "wrote at the minimum budget")
	local left = 0
	for _ in env.Leaderboard.pendingFor(STORE_1V1) do
		left += 1
	end
	h.expect(left == 3, "values dropped while the budget was low")

	-- each write spends one request: two fit above the minimum
	env.budget.SetIncrementSortedAsync = Config.Rankings.MinBudget + 2
	env.onSet = function()
		env.budget.SetIncrementSortedAsync -= 1
	end
	env.Leaderboard.flush()
	h.expect(#store.sets == 2, "writes: " .. #store.sets)
	env.budget.SetIncrementSortedAsync = 100
	env.Leaderboard.flush()
	h.expect(#store.sets == 3 and env.Leaderboard.pendingFor(STORE_1V1) == nil, "the rest wasn't written")
	-- one check before every write, and one that stopped each of the first two flushes; each asks OrderedWrite
	-- first (no answer here), then the legacy SetIncrementSortedAsync
	local asked = { OrderedWrite = 0, SetIncrementSortedAsync = 0 }
	for _, requestType in env.budgetTypes do
		h.expect(asked[requestType.Name] ~= nil, "checked " .. tostring(requestType))
		asked[requestType.Name] += 1
	end
	h.expect(asked.OrderedWrite == 5 and asked.SetIncrementSortedAsync == 5, "budget checks: " .. describeValue(asked))
end)

h.test("a failed ranked write is logged once and dropped", function()
	local env = newEnv()
	local store = env.store(STORE_1V1)
	store.failWrites = true
	for id = 34, 35 do
		local player, profile = env.player(id, "P" .. id)
		env.Leaderboard.submit(player, "1v1", profile)
	end
	env.Leaderboard.flush()
	h.expect(env.Leaderboard.pendingFor(STORE_1V1) == nil, "a rejected write stayed queued")
	local logged = 0
	for _, line in env.warnings do
		if string.find(line, "couldn't write to " .. STORE_1V1, 1, true) then
			logged += 1
		end
	end
	h.expect(logged == 1, "logged " .. logged .. " times")
end)

h.test("concurrent friends requests share one fetch", function()
	local env = newEnv()
	local player = env.player(50, "Me")
	local store = env.store(STORE_1V1)
	store.data["101"] = Rankings.encode(1300, "Sol", 7, 3)
	store.data["103"] = Rankings.encode(1600, "Vex", 20, 4)
	env.friendIds[player] = { 101, 102, 103, 50 }
	env.getDelay = 0.05
	local results = {}
	for i = 1, 2 do
		realTask.spawn(function()
			local ok, data = env.Leaderboard.getRankings(player, { mode = "1v1", scope = "Friends" })
			results[i] = { ok = ok, data = data }
		end)
	end
	local deadline = os.clock() + 5
	while not (results[1] and results[2]) and os.clock() < deadline do
		realTask.wait(0.01)
	end
	h.expect(results[1] and results[2], "a request never answered")
	table.sort(store.gets)
	expectEqual(store.gets, { "101", "102", "103" }, "GetAsync calls")
	for i = 1, 2 do
		local data = results[i].data
		h.expect(results[i].ok and data.scope == "Friends" and data.status == "ok", "request " .. i)
		local order = {}
		for _, row in data.rows do
			table.insert(order, row.name .. (row.you and "*" or ""))
		end
		expectEqual(order, { "Friend103", "Friend101", "Me*" }, "rows of request " .. i)
		h.expect(data.you.rank == 3 and data.you.rating == Config.Ranked.StartRating, "your card")
	end
	h.expect(env.nameCalls == 1, "name lookups: " .. env.nameCalls)

	-- inside the cooldown: the cached copy; another requester shares the stored values
	env.Leaderboard.getRankings(player, { mode = "1v1", scope = "Friends" })
	local friend = env.player(51, "Pal")
	env.friendIds[friend] = { 101, 103 }
	local ok, data = env.Leaderboard.getRankings(friend, { mode = "1v1", scope = "Friends" })
	h.expect(ok and #data.rows == 3 and #store.gets == 3, "values weren't shared: " .. #store.gets)
	-- a friend on this server shows their live profile
	local live, liveProfile = env.player(103, "LiveFriend")
	liveProfile.Rating1v1 = 1900
	liveProfile.SeasonStats["1v1"].Wins = 1
	env.clockOffset += Config.Rankings.FriendsCooldown
	ok, data = env.Leaderboard.getRankings(friend, { mode = "1v1", scope = "Friends" })
	h.expect(
		ok and data.rows[1].userId == 103 and data.rows[1].rating == 1900 and data.rows[1].name == "LiveFriend",
		"live"
	)
	h.expect(live ~= nil and #store.gets == 3, "a live friend was read from the store")
end)

h.test("friends rankings stop at the GetAsync reserve and say partial", function()
	local env = newEnv()
	local player = env.player(52, "Popular")
	env.store(STORE_1V1).data["201"] = Rankings.encode(1500, "Sol", 1, 0)
	env.friendIds[player] = { 201, 202 }
	env.budget.GetAsync = Config.Rankings.FriendsReserve
	local ok, data = env.Leaderboard.getRankings(player, { mode = "1v1", scope = "Friends" })
	h.expect(ok and data.status == "partial" and #data.rows == 1 and data.rows[1].you, "partial: " .. data.status)
	h.expect(#env.store(STORE_1V1).gets == 0, "read below the reserve")
	env.budget.GetAsync = 100
	env.clockOffset += Config.Rankings.FriendsCooldown
	ok, data = env.Leaderboard.getRankings(player, { mode = "1v1", scope = "Friends" })
	h.expect(ok and data.status == "ok" and #data.rows == 2, "after the budget recovered: " .. data.status)
end)

h.test("global rankings are fetched once, named once and cached", function()
	local env = newEnv()
	local player = env.player(60, "Me")
	local store = env.store(STORE_1V1)
	store.data["61"] = Rankings.encode(2000, "Vex", 50, 10)
	store.data["60"] = Rankings.encode(1500, "Sol", 20, 10)
	store.data["62"] = Rankings.encode(1200, nil, 5, 5)
	local ok, data = env.Leaderboard.getRankings(player, { mode = "1v1", scope = "Global" })
	h.expect(ok and data.status == "ok" and #data.rows == 3, "global: " .. describeValue(data))
	h.expect(data.rows[1].name == "Friend61" and data.rows[2].you and data.rows[2].name == "Me", "names")
	h.expect(data.you.rank == 2 and data.you.rating == Config.Ranked.StartRating, "card from the live profile")
	h.expect(data.updatedAt == NOW and data.season.current and data.season.id == 1, "season / updatedAt")
	expectEqual(data.seasons, { { id = 1, name = "Season 1" } }, "seasons")
	env.Leaderboard.getRankings(player, { mode = "1v1", scope = "Global" })
	env.Leaderboard.getRankings(env.player(63, "Other"), { mode = "1v1", scope = "Global" })
	h.expect(store.sortedCalls == 1 and env.nameCalls == 1, "fetches: " .. store.sortedCalls .. " / " .. env.nameCalls)
	-- the background refresh fetches again
	env.Leaderboard.refresh()
	h.expect(store.sortedCalls == 2 and env.nameCalls == 1, "refresh")
	-- at the GetSortedAsync minimum the cached rows stay
	env.budget.GetSortedAsync = Config.Rankings.MinBudget
	env.Leaderboard.refresh()
	ok, data = env.Leaderboard.getRankings(player, { mode = "1v1", scope = "Global" })
	h.expect(store.sortedCalls == 2 and ok and #data.rows == 3, "fetched at the minimum budget")
end)

h.test("a past season's list and card come from its store", function()
	local env = newEnv({ now = S1_END + DAY })
	local player, profile = env.player(70, "Returning")
	local store = env.store(STORE_1V1)
	store.data["71"] = Rankings.encode(2100, "Vex", 90, 10)
	store.data["72"] = Rankings.encode(1900, "Sol", 60, 20)
	store.data["70"] = Rankings.encode(1432, "Kestrel", 48, 31)
	local topSize = Config.Rankings.TopSize
	Config.Rankings.TopSize = 2 -- you are third, outside the list
	local ok, data = env.Leaderboard.getRankings(player, { mode = "1v1", scope = "Global", season = 1 })
	Config.Rankings.TopSize = topSize
	h.expect(ok and #data.rows == 2 and not data.season.current and data.season.name == "Season 1", describeValue(data))
	expectEqual(data.seasons, { { id = 2, name = "Season 2" }, { id = 1, name = "Season 1" } }, "seasons")
	expectEqual(data.you, { rating = 1432, tier = "Gold", wins = 48, losses = 31, main = "Kestrel" }, "card")
	expectEqual(store.gets, { "70" }, "your own entry read")
	h.expect(profile.Season == 2, "the profile isn't in Season 2")

	-- the 2v2 store of Season 1 has no entry for you (flipping 1v1 -> 2v2 right away fetches the other store)
	ok, data = env.Leaderboard.getRankings(player, { mode = "2v2", scope = "Global", season = 1 })
	h.expect(ok and data.status == "ok" and data.you.noEntry == true and #data.rows == 0, describeValue(data.you))
	-- another player: a cached list costs nothing; the current season's two lists answer back to back
	local other = env.player(73, "Quick")
	ok = env.Leaderboard.getRankings(other, { mode = "1v1", scope = "Global", season = 1 })
	h.expect(ok and store.sortedCalls == 1, "a cached past season was fetched again")
	local ok1, one = env.Leaderboard.getRankings(other, { mode = "1v1", scope = "Global" })
	local ok2, two = env.Leaderboard.getRankings(other, { mode = "2v2", scope = "Global" })
	h.expect(ok1 and one.status == "ok" and ok2 and two.status == "ok", "1v1 then 2v2: " .. tostring(two))
end)

h.test("GetRankings checks the request and the season", function()
	local env = newEnv()
	local player = env.player(80, "Asker")
	for _, request in
		{
			"1v1",
			{},
			{ mode = "3v3", scope = "Global" },
			{ mode = "1v1", scope = "Local" },
			{ mode = "1v1", scope = "Global", season = 2 }, -- not started yet
			{ mode = "1v1", scope = "Global", season = "1" },
			{ mode = "1v1", scope = "Global", season = 0 / 0 },
		}
	do
		local ok, message = env.Leaderboard.getRankings(player, request)
		h.expect(ok == false and message == "Bad request.", "accepted " .. describeValue(request))
	end
	local ok, data = env.Leaderboard.getRankings(player, { mode = "2v2", scope = "Global", season = 1 })
	h.expect(ok and data.mode == "2v2" and data.season.current and data.season.endsAt == S1_END, "season 1")
	local ok2, message =
		env.Leaderboard.getRankings(env.player(81, "Loading", false), { mode = "1v1", scope = "Global" })
	h.expect(ok2 == false and message == "Your profile is still loading.", "no profile: " .. tostring(message))
end)

h.test("without a DataStore the rankings list players on this server", function()
	local env = newEnv({ noDataStore = true })
	local me, myProfile = env.player(5, "Host")
	local studio, studioProfile = env.player(-2, "Player2")
	env.player(7, "StillLoading", false)
	myProfile.Rating1v1 = 1300
	studioProfile.Rating1v1 = 1100
	studioProfile.SeasonStats["1v1"] = { Wins = 2, Losses = 1, Legends = { Moss = { Wins = 2, Played = 3 } } }
	local ok, data = env.Leaderboard.getRankings(me, { mode = "1v1", scope = "Global" })
	h.expect(ok and data.status == "unavailable", "status " .. tostring(data and data.status))
	h.expect(#data.rows == 2 and data.rows[1].you and data.rows[1].rating == 1300, "rows: " .. describeValue(data.rows))
	h.expect(data.rows[2].userId == -2 and data.rows[2].main == "Moss" and data.rows[2].wins == 2, "Studio player")
	h.expect(data.you.rank == 1 and data.you.rating == 1300, "card")
	ok, data = env.Leaderboard.getRankings(studio, { mode = "1v1", scope = "Friends" })
	h.expect(ok and data.status == "unavailable" and #data.rows == 1 and data.rows[1].you, "friends: only you")
	-- a friend on this server shows once they have a ranked result this season
	env.friendIds[studio] = { 5 }
	ok, data = env.Leaderboard.getRankings(studio, { mode = "1v1", scope = "Friends" })
	h.expect(ok and data.status == "unavailable" and #data.rows == 1, "a friend without a ranked game")
	myProfile.SeasonStats["1v1"].Losses = 1
	env.clockOffset += Config.Rankings.FriendsCooldown
	ok, data = env.Leaderboard.getRankings(studio, { mode = "1v1", scope = "Friends" })
	h.expect(ok and #data.rows == 2 and data.you.rank == 2, "friends on this server")
	-- submits are dropped quietly
	env.Leaderboard.submit(me, "1v1", myProfile)
	env.Leaderboard.flush()
	h.expect(env.Leaderboard.pendingFor(STORE_1V1) == nil, "queued without a DataStore")
	local logged = 0
	for _, line in env.warnings do
		if string.find(line, "ranked boards unavailable", 1, true) then
			logged += 1
		end
	end
	h.expect(logged == 1, "logged " .. logged .. " times")
end)

h.test("budget checks ask the ordered request types first", function()
	local env = newEnv()
	local player, profile = env.player(100, "Modern")
	local store = env.store(STORE_1V1)
	store.data["101"] = Rankings.encode(1500, "Sol", 2, 1)
	env.friendIds[player] = { 101 }
	-- OrderedRead answers (at the reserve), so the legacy GetAsync budget isn't asked
	env.budget.OrderedRead = Config.Rankings.FriendsReserve
	local ok, data = env.Leaderboard.getRankings(player, { mode = "1v1", scope = "Friends" })
	h.expect(ok and data.status == "partial" and #store.gets == 0, "read at the OrderedRead reserve")
	for _, requestType in env.budgetTypes do
		h.expect(requestType == Enum.DataStoreRequestType.OrderedRead, "asked " .. tostring(requestType))
	end
	env.budget.OrderedRead = 100
	env.clockOffset += Config.Rankings.FriendsCooldown
	ok, data = env.Leaderboard.getRankings(player, { mode = "1v1", scope = "Friends" })
	h.expect(ok and data.status == "ok" and #data.rows == 2, "with the OrderedRead budget")
	-- OrderedList and OrderedWrite likewise
	env.budget.OrderedList = Config.Rankings.MinBudget
	env.Leaderboard.refresh()
	h.expect(store.sortedCalls == 0, "listed at the OrderedList minimum")
	env.budget.OrderedWrite = Config.Rankings.MinBudget
	env.Leaderboard.submit(player, "1v1", profile)
	env.Leaderboard.flush()
	h.expect(#store.sets == 0, "wrote at the OrderedWrite minimum")
	env.budget.OrderedWrite = 100
	env.Leaderboard.flush()
	h.expect(#store.sets == 1, "with the OrderedWrite budget")
end)

h.test("a budget that is never reported falls back to a fixed limit", function()
	local env = newEnv({ now = S1_END + DAY })
	-- every request type answers 0 (as the docs say OrderedList does)
	env.budget = {}
	for _, requestType in Enum.DataStoreRequestType:GetEnumItems() do
		env.budget[requestType.Name] = 0
	end
	local player = env.player(110, "Early")
	local s2 = env.store(Rankings.storeName(2, "1v1"))
	local past = env.store(STORE_1V1)
	past.data["111"] = Rankings.encode(1500, "Sol", 2, 1)
	-- the background refresh always goes out (it takes the 2 list tokens)
	env.Leaderboard.refresh()
	env.Leaderboard.refresh()
	h.expect(s2.sortedCalls == 2, "refreshes: " .. s2.sortedCalls)
	-- other fetches wait for a token (2 a minute)
	local ok, data = env.Leaderboard.getRankings(player, { mode = "1v1", scope = "Global", season = 1 })
	h.expect(ok and data.status == "partial" and past.sortedCalls == 0, "fetched without a token")
	env.clockOffset += 30
	ok, data = env.Leaderboard.getRankings(player, { mode = "1v1", scope = "Global", season = 1 })
	h.expect(ok and data.status == "ok" and #data.rows == 1 and past.sortedCalls == 1, "after a token came back")
	h.expect(#past.gets == 1, "your own entry wasn't read")
	-- writes: 20 a minute
	for id = 1, 25 do
		local other, profile = env.player(1000 + id, "W" .. id)
		profile.Season = 1
		env.Leaderboard.submit(other, "1v1", profile)
	end
	env.Leaderboard.flush()
	h.expect(#past.sets == 20, "writes: " .. #past.sets)
	env.clockOffset += 60
	env.Leaderboard.flush()
	h.expect(#past.sets == 25 and env.Leaderboard.pendingFor(STORE_1V1) == nil, "the rest: " .. #past.sets)
	local logged = 0
	for _, line in env.warnings do
		if string.find(line, "request budget reported", 1, true) then
			logged += 1
		end
	end
	h.expect(logged == 3, "logged " .. logged .. " times (once per kind)")
	-- once a type has answered, 0 means spent
	env.budget.GetSortedAsync = 100
	env.Leaderboard.refresh()
	env.budget.GetSortedAsync = 0
	env.Leaderboard.refresh()
	h.expect(s2.sortedCalls == 3, "listed with a spent budget: " .. s2.sortedCalls)
end)

h.test("a failed or skipped fetch keeps the older rows and is retried after GlobalCooldown", function()
	local env = newEnv()
	local player = env.player(120, "Steady")
	local store = env.store(STORE_1V1)
	store.data["121"] = Rankings.encode(1800, "Vex", 9, 1)
	env.Leaderboard.refresh()
	store.failReads = true
	env.Leaderboard.refresh()
	local ok, data = env.Leaderboard.getRankings(player, { mode = "1v1", scope = "Global" })
	h.expect(ok and data.status == "partial" and #data.rows == 1 and data.updatedAt == NOW, "older rows kept")
	h.expect(store.sortedCalls == 2, "a fresh list was fetched on request")
	-- a list too old is fetched on request, but a store is tried at most once per GlobalCooldown
	env.clockOffset += Config.Rankings.RefreshSeconds * 2
	ok, data = env.Leaderboard.getRankings(player, { mode = "1v1", scope = "Global" })
	h.expect(ok and data.status == "partial" and #data.rows == 1 and store.sortedCalls == 3, "stale list")
	local other = env.player(122, "Impatient")
	for _, who in { player, other } do
		ok, data = env.Leaderboard.getRankings(who, { mode = "1v1", scope = "Global" })
		h.expect(ok and data.status == "partial" and #data.rows == 1, "inside the cooldown: " .. tostring(data))
	end
	h.expect(store.sortedCalls == 3, "tried again inside GlobalCooldown")
	store.failReads = false
	env.clockOffset += Config.Rankings.GlobalCooldown
	ok, data = env.Leaderboard.getRankings(other, { mode = "1v1", scope = "Global" })
	h.expect(ok and data.status == "ok" and store.sortedCalls == 4, "after the cooldown")
	-- a refresh skipped for the budget says partial too
	env.budget.GetSortedAsync = Config.Rankings.MinBudget
	env.Leaderboard.refresh()
	ok, data = env.Leaderboard.getRankings(other, { mode = "1v1", scope = "Global" })
	h.expect(ok and data.status == "partial" and #data.rows == 1 and store.sortedCalls == 4, "skipped refresh")
	local logged = 0
	for _, line in env.warnings do
		if string.find(line, "couldn't read " .. STORE_1V1, 1, true) then
			logged += 1
		end
	end
	h.expect(logged == 1, "logged " .. logged .. " times")
end)

h.test("concurrent Global requests share one fetch", function()
	local env = newEnv({ now = S1_END + DAY })
	local store = env.store(STORE_1V1)
	store.data["131"] = Rankings.encode(1600, "Sol", 5, 5)
	env.sortedDelay = 0.05
	local results = {}
	for i = 1, 3 do
		local player = env.player(130 + i * 10, "Waiter" .. i)
		realTask.spawn(function()
			local ok, data = env.Leaderboard.getRankings(player, { mode = "1v1", scope = "Global", season = 1 })
			results[i] = { ok = ok, data = data }
		end)
	end
	local deadline = os.clock() + 5
	while not (results[1] and results[2] and results[3]) and os.clock() < deadline do
		realTask.wait(0.01)
	end
	for i = 1, 3 do
		local result = results[i]
		h.expect(result and result.ok and result.data.status == "ok" and #result.data.rows == 1, "request " .. i)
	end
	h.expect(store.sortedCalls == 1 and env.nameCalls == 1, "fetches: " .. store.sortedCalls .. " / " .. env.nameCalls)
end)

h.test("friends rankings answer partial after FriendsTimeout", function()
	local env = newEnv()
	local player = env.player(170, "Patient")
	local store = env.store(STORE_1V1)
	store.data["171"] = Rankings.encode(1500, "Sol", 2, 1)
	env.friendIds[player] = { 171 }
	local timeout = Config.Rankings.FriendsTimeout
	Config.Rankings.FriendsTimeout = 0.1
	env.getDelay = 0.4
	local started = os.clock()
	local ok, data = env.Leaderboard.getRankings(player, { mode = "1v1", scope = "Friends" })
	local took = os.clock() - started
	Config.Rankings.FriendsTimeout = timeout
	h.expect(ok and data.status == "partial" and #data.rows == 1 and data.rows[1].you, "partial: " .. data.status)
	h.expect(took < 0.3, "answered after " .. took .. " s")
	-- the read finishes later; the next fetch uses it without reading again
	realTask.wait(0.4)
	env.getDelay = nil
	env.clockOffset += Config.Rankings.FriendsCooldown
	ok, data = env.Leaderboard.getRankings(player, { mode = "1v1", scope = "Friends" })
	h.expect(ok and data.status == "ok" and #data.rows == 2 and #store.gets == 1, "later: " .. #store.gets)
end)

h.test("overlapping friends requests read each friend once", function()
	local env = newEnv()
	local a = env.player(180, "A")
	local b = env.player(181, "B")
	local store = env.store(STORE_1V1)
	for id = 182, 185 do
		store.data[tostring(id)] = Rankings.encode(1200 + id, "Sol", 1, 0)
	end
	env.friendIds[a] = { 182, 183, 184 }
	env.friendIds[b] = { 183, 184, 185 }
	env.getDelay = 0.05
	local results = {}
	for i, player in { a, b } do
		realTask.spawn(function()
			local ok, data = env.Leaderboard.getRankings(player, { mode = "1v1", scope = "Friends" })
			results[i] = { ok = ok, data = data }
		end)
	end
	local deadline = os.clock() + 5
	while not (results[1] and results[2]) and os.clock() < deadline do
		realTask.wait(0.01)
	end
	for i = 1, 2 do
		local result = results[i]
		h.expect(result and result.ok and result.data.status == "ok" and #result.data.rows == 4, "request " .. i)
	end
	table.sort(store.gets)
	expectEqual(store.gets, { "182", "183", "184", "185" }, "GetAsync calls")
end)

h.test("friends on this server count once they play ranked, also past FriendsMax", function()
	local env = newEnv()
	local player = env.player(190, "Popular")
	local ids = {}
	for i = 1, Config.Rankings.FriendsMax + 10 do
		table.insert(ids, 10000 + i)
	end
	env.friendIds[player] = ids
	-- two friends on this server past the cap: one drew a ranked game this season, one never played ranked
	local _, liveProfile = env.player(10055, "LiveFriend")
	liveProfile.Rating1v1 = 1900
	liveProfile.SeasonStats["1v1"].Legends.Vex = { Wins = 0, Played = 1 }
	env.player(10056, "IdleFriend")
	local ok, data = env.Leaderboard.getRankings(player, { mode = "1v1", scope = "Friends" })
	h.expect(ok and #data.rows == 2, "rows: " .. describeValue(data.rows))
	h.expect(data.rows[1].userId == 10055 and data.rows[1].rating == 1900 and data.rows[1].main == "Vex", "live")
	local gets = env.store(STORE_1V1).gets
	h.expect(#gets == Config.Rankings.FriendsMax, "GetAsync calls: " .. #gets)
	h.expect(not table.find(gets, "10055") and not table.find(gets, "10056"), "a live friend was read")
end)

h.test("Studio without API access lists players on this server in both scopes", function()
	local env = newEnv()
	env.studio = true
	local me = env.player(200, "Host")
	local _, palProfile = env.player(201, "Pal")
	palProfile.SeasonStats["1v1"].Wins = 1
	env.player(202, "Stranger")
	env.friendIds[me] = { 201, 203 }
	env.store(STORE_1V1).failReads = true
	local ok, data = env.Leaderboard.getRankings(me, { mode = "1v1", scope = "Friends" })
	h.expect(ok and data.status == "unavailable" and #data.rows == 2, "friends: " .. describeValue(data.rows))
	ok, data = env.Leaderboard.getRankings(me, { mode = "1v1", scope = "Global" })
	h.expect(ok and data.status == "unavailable" and #data.rows == 3, "global: " .. describeValue(data.rows))
	-- outside Studio the same errors are partial answers
	local live = newEnv()
	local host = live.player(200, "Host")
	local _, friendProfile = live.player(201, "Pal")
	friendProfile.SeasonStats["1v1"].Wins = 1
	live.friendIds[host] = { 201, 203 }
	live.store(STORE_1V1).failReads = true
	ok, data = live.Leaderboard.getRankings(host, { mode = "1v1", scope = "Friends" })
	h.expect(ok and data.status == "partial" and #data.rows == 2, "live friends: " .. data.status)
	ok, data = live.Leaderboard.getRankings(host, { mode = "1v1", scope = "Global" })
	h.expect(ok and data.status == "partial" and #data.rows == 0, "live global: " .. data.status)
end)

h.test("friends show as soon as the friend cache has them, and leaving drops the cache", function()
	local env = newEnv()
	local player = env.player(210, "Newcomer")
	local store = env.store(STORE_1V1)
	store.data["211"] = Rankings.encode(1500, "Sol", 2, 1)
	store.data["212"] = Rankings.encode(1400, "Moss", 1, 1)
	-- FriendCache still loading: no ids, so nothing is kept
	local ok, data = env.Leaderboard.getRankings(player, { mode = "1v1", scope = "Friends" })
	h.expect(ok and #data.rows == 1, "while loading")
	env.friendIds[player] = { 211 }
	ok, data = env.Leaderboard.getRankings(player, { mode = "1v1", scope = "Friends" })
	h.expect(ok and #data.rows == 2, "right after loading")
	-- inside FriendsCooldown the cached rows answer; onPlayerRemoving drops them
	env.friendIds[player] = { 211, 212 }
	ok, data = env.Leaderboard.getRankings(player, { mode = "1v1", scope = "Friends" })
	h.expect(ok and #data.rows == 2, "the cached copy")
	env.Leaderboard.onPlayerRemoving(player)
	ok, data = env.Leaderboard.getRankings(player, { mode = "1v1", scope = "Friends" })
	h.expect(ok and #data.rows == 3, "the friends cache survived onPlayerRemoving")
end)

h.test("a submitted standing reaches friends' rankings before it is written", function()
	local env = newEnv()
	local mover = env.player(250, "Mover")
	local friend = env.player(251, "Buddy")
	env.Progression.applyMatch(rankedInfo("1v1"), { entry(mover, { won = true, opponentRating = 1000 }) })
	env.game:GetService("Players"):_remove(mover)
	env.friendIds[friend] = { 250 }
	local ok, data = env.Leaderboard.getRankings(friend, { mode = "1v1", scope = "Friends" })
	h.expect(ok and #data.rows == 2 and data.rows[1].userId == 250 and data.rows[1].wins == 1, describeValue(data))
	local store = env.store(STORE_1V1)
	h.expect(#store.gets == 0 and #store.sets == 0, "read or written: " .. #store.gets .. " / " .. #store.sets)
end)

h.test("a past-season card that couldn't be read says partial", function()
	local env = newEnv({ now = S1_END + DAY })
	local player = env.player(270, "Veteran")
	local store = env.store(STORE_1V1)
	store.data["271"] = Rankings.encode(2000, "Vex", 50, 5)
	store.data["270"] = Rankings.encode(1432, "Kestrel", 48, 31)
	local topSize = Config.Rankings.TopSize
	Config.Rankings.TopSize = 1 -- you are outside the list
	env.budget.GetAsync = Config.Rankings.FriendsReserve
	local ok, data = env.Leaderboard.getRankings(player, { mode = "1v1", scope = "Global", season = 1 })
	Config.Rankings.TopSize = topSize
	h.expect(ok and data.status == "partial" and data.you.noEntry and #store.gets == 0, "at the reserve")
	-- a read that throws isn't retried inside GlobalCooldown
	env.budget.GetAsync = 100
	store.failReads = true
	env.Leaderboard.getRankings(player, { mode = "1v1", scope = "Global", season = 1 })
	ok, data = env.Leaderboard.getRankings(player, { mode = "1v1", scope = "Global", season = 1 })
	h.expect(ok and data.status == "partial" and #store.gets == 1, "retried: " .. #store.gets)
	store.failReads = false
	env.clockOffset += Config.Rankings.GlobalCooldown
	ok, data = env.Leaderboard.getRankings(player, { mode = "1v1", scope = "Global", season = 1 })
	h.expect(ok and data.status == "ok" and data.you.rating == 1432 and #store.gets == 2, describeValue(data.you))
end)

h.test("GetRankings moves a profile out of an ended season first", function()
	local env = newEnv()
	local player, profile = env.player(220, "Late")
	profile.Rating1v1 = 1400
	env.now = S1_END + 60
	local ok, data = env.Leaderboard.getRankings(player, { mode = "1v1", scope = "Global" })
	h.expect(ok and data.season.id == 2 and profile.Season == 2, "season " .. profile.Season)
	h.expect(data.you.rating == Seasons.softReset(1400), "card: " .. data.you.rating)
	h.expect(hasToast(player, "Season 2 has begun! Your ratings were soft-reset."), "season toast")
end)

h.test("the shutdown flush writes what is queued", function()
	local env = newEnv({ parkWaits = true })
	env.Leaderboard.start()
	local player, profile = env.player(260, "LastGame")
	env.Leaderboard.submit(player, "1v1", profile)
	h.expect(type(env.onClose) == "function", "nothing bound to BindToClose")
	env.onClose()
	local value = Rankings.encode(profile.Rating1v1, nil, 0, 0)
	expectEqual(env.store(STORE_1V1).sets, { { key = "260", value = value } }, "writes")
	h.expect(env.Leaderboard.pendingFor(STORE_1V1) == nil, "still queued")
end)

h.test("the name cache starts over without losing the names of the list being built", function()
	local env = newEnv()
	local player = env.player(300, "Reader")
	local store = env.store(STORE_1V1)
	local function fill(first, count)
		table.clear(store.data)
		for id = first, first + count - 1 do
			store.data[tostring(id)] = Rankings.encode(1000 + id % 500, nil, 0, 0)
		end
	end
	-- 1,970 different players named (the cache holds 2,000), then a list of 50 of the last ones and 50 new ones
	for i = 0, 18 do
		fill(100000 + i * 100, 100)
		env.Leaderboard.refresh()
	end
	fill(200000, 70)
	env.Leaderboard.refresh()
	fill(200020, 100)
	env.Leaderboard.refresh()
	local ok, data = env.Leaderboard.getRankings(player, { mode = "1v1", scope = "Global" })
	h.expect(ok and #data.rows == 100 and env.nameCalls == 21, "rows " .. #data.rows .. ", calls " .. env.nameCalls)
	for _, row in data.rows do
		h.expect(row.name == "Friend" .. row.userId, "unnamed row " .. row.name)
	end
end)

h.test("GetRankings is rate limited per player", function()
	local env = newEnv({ parkWaits = true })
	local player = env.player(91, "Flipper")
	local other = env.player(92, "Calm")
	env.Leaderboard.start()
	local getRankings = h.remote("GetRankings").OnServerInvoke
	local burst = Config.Rankings.RequestBurst
	for i = 1, burst do
		local ok, data = getRankings(player, { mode = if i % 2 == 0 then "2v2" else "1v1", scope = "Global" })
		h.expect(ok == true and type(data) == "table", "call " .. i .. " was limited")
	end
	local ok, message = getRankings(player, { mode = "1v1", scope = "Global" })
	h.expect(ok == false and message == "Slow down.", "call " .. (burst + 1) .. " wasn't limited")
	h.expect(getRankings(other, { mode = "1v1", scope = "Global" }) == true, "another player was limited")
	env.clockOffset += 1 / Config.Rankings.RequestsPerSecond
	h.expect(getRankings(player, { mode = "1v1", scope = "Global" }) == true, "the bucket didn't refill")
	ok, message = getRankings(player, { mode = "1v1", scope = "Global" })
	h.expect(ok == false and message == "Slow down.", "refilled more than one call")
	-- leaving drops the bucket: a player who comes back starts with a full one
	env.Leaderboard.onPlayerRemoving(player)
	h.expect(getRankings(player, { mode = "1v1", scope = "Global" }) == true, "the bucket outlived the player")
end)

h.test("MissionRequest and GetRankings answer through their remotes and never throw", function()
	local env = newEnv({ parkWaits = true })
	local player = env.player(90, "Remote")
	env.Missions.start()
	env.Leaderboard.start()
	local missionRequest = h.remote("MissionRequest").OnServerInvoke
	local getRankings = h.remote("GetRankings").OnServerInvoke
	local ok, message = missionRequest(player, "Reroll", 1, env.profiles[player].Missions.Day)
	h.expect(ok == true and message == "Mission rerolled.", "MissionRequest: " .. tostring(message))
	local okRankings, data = getRankings(player, { mode = "1v1", scope = "Global" })
	h.expect(okRankings == true and data.status == "ok", "GetRankings")
	ok, message = getRankings(player, nil)
	h.expect(ok == false and message == "Bad request.", "GetRankings nil")
	env.services.DataService.get = function()
		error("boom")
	end
	env.clockOffset += 5
	ok, message = missionRequest(player, "Claim", 1)
	h.expect(ok == false and message == "Something went wrong.", "MissionRequest error: " .. tostring(message))
	ok, message = getRankings(player, { mode = "1v1", scope = "Global" })
	h.expect(ok == false and message == "Something went wrong.", "GetRankings error: " .. tostring(message))
	-- the background refresh ran once at start
	h.expect(env.store(STORE_1V1).sortedCalls >= 1, "no refresh at start")
	env.Leaderboard.onPlayerRemoving(player)
end)

h.finish()
