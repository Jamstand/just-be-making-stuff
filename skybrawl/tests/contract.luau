--[[
    Contract tests for the menus foundation: the remotes and project file,
    Config's menu sections, the pure shared modules (Party, Select,
    Missions, Events, Seasons, Rankings), ClientState, DataService's
    profile v2 (migration, season stats, snapshot) and the test harness.
    Run from the skybrawl folder with:  lune run tests/contract
]]

local fs = require("@lune/fs")
local serde = require("@lune/serde")

local h = require("./harness")

local Config = h.require("Config")
local Legends = h.require("Legends")
local Weapons = h.require("Weapons")
local Party = h.require("Party")
local Select = h.require("Select")
local Missions = h.require("Missions")
local Events = h.require("Events")
local Seasons = h.require("Seasons")
local Rankings = h.require("Rankings")
local DataService = h.requireServer("DataService")

local DAY = 86400
-- 2026-10-20 12:00 UTC: inside Season 1 (it ends 2026-12-01)
local NOW = Events.parse("2026-10-20T12:00:00Z")
local TODAY = Missions.dayIndex(NOW)

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

local function templateOf(id)
	for _, template in Config.Missions.Templates do
		if template.Id == id then
			return template
		end
	end
	return nil
end

local function entry(id, goal, progress, opts)
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

print("Remotes and project")

h.test("every remote in Net's header is declared in default.project.json", function()
	local project = serde.decode("json", fs.readFile("default.project.json"))
	local declared = project.tree.ReplicatedStorage.Remotes
	local header = string.match(fs.readFile("src/shared/Net.luau"), "^%-%-%[%[(.-)%]%]")
	h.expect(header, "Net.luau has no header comment")
	local listed, section = {}, nil
	for line in string.gmatch(header, "[^\n]+") do
		if string.match(line, "^%s*RemoteEvents%s*$") then
			section = "RemoteEvent"
		elseif string.match(line, "^%s*RemoteFunctions%s*$") then
			section = "RemoteFunction"
		else
			local name = string.match(line, "^%s+(%u%w+)%s+[SC]%->[SC]%s")
			if name and section then
				listed[name] = section
			end
		end
	end
	for name, class in listed do
		local entryJson = declared[name]
		h.expect(entryJson ~= nil, name .. " is in Net's header but not in default.project.json")
		h.expect(entryJson["$className"] == class, name .. " is a " .. class .. " in Net's header")
	end
	for name, entryJson in declared do
		if string.sub(name, 1, 1) ~= "$" then
			h.expect(listed[name] == entryJson["$className"], name .. " is declared but missing from Net's header")
		end
	end
	local new = {
		PartyUpdate = "RemoteEvent",
		QueueStats = "RemoteEvent",
		SelectEvent = "RemoteEvent",
		SelectAction = "RemoteEvent",
		PartyRequest = "RemoteFunction",
		MissionRequest = "RemoteFunction",
		GetRankings = "RemoteFunction",
		TrainingRequest = "RemoteFunction",
	}
	for name, class in new do
		h.expect(listed[name] == class, name .. " missing")
	end
end)

h.test("characters do not auto-load and the spawn pad is invisible", function()
	local tree = serde.decode("json", fs.readFile("default.project.json")).tree
	h.expect(tree.Players and tree.Players["$className"] == "Players", "no Players service in the project")
	h.expect(tree.Players["$properties"].CharacterAutoLoads == false, "characters still auto-load")
	local pad = tree.Workspace.SpawnLocation["$properties"]
	h.expect(pad.Transparency == 1, "the spawn pad is visible")
	h.expect(pad.CanQuery == false and pad.CanTouch == false, "the spawn pad can be queried or touched")
	h.expect(pad.Anchored == true and pad.Duration == 0, "the spawn pad must stay anchored with no forcefield")
	expectEqual(pad.Position, { 0, 0.5, 18 }, "spawn pad position")
	local avatars = tree.ReplicatedStorage.AvatarModels
	h.expect(avatars and avatars["$className"] == "Folder", "no ReplicatedStorage.AvatarModels folder")
end)

print("Config")

h.test("Config has the menu sections with their defaults", function()
	h.expect(Config.GameVersion == "0.9", "GameVersion")
	h.expect(Config.Match.EndLingerSeconds == 3, "Match.EndLingerSeconds")
	h.expect(Config.Match.ResultsSeconds ~= nil, "Match.ResultsSeconds stays until the Integration track")
	h.expect(Config.Queue.StatsSeconds == 2 and Config.Queue.RequestCooldown == 0.5, "Queue additions")
	expectEqual(Config.Party, {
		MaxSize = 4,
		InviteSeconds = 30,
		WaitingInviteSeconds = 600,
		ReinviteCooldown = 30,
		MaxIncomingInvites = 10,
		RequestsPerSecond = 4,
		RequestBurst = 6,
	}, "Config.Party")
	expectEqual(Config.Select, {
		Seconds = 15,
		AllLockedDelay = 0.75,
		VsSeconds = 3,
		MapChoices = 3,
		ActionsPerSecond = 8,
		BroadcastInterval = 0.1,
		HoverInterval = 0.2,
	}, "Config.Select")
	expectEqual(Config.Training, {
		MaxRooms = 8,
		MapId = "DuelRock",
		DummyLegend = "Brann",
		DummyName = "Training Dummy",
		DummyModes = { "Stand", "Jump", "Dodge", "Block", "Fight" },
		DefaultMode = "Stand",
		DefaultDifficulty = "Normal",
		Speeds = { 1, 0.5, 0.25 },
		DamageStep = 10,
		JumpInterval = 0.9,
		DodgeRange = 12,
		DummyRecovers = true,
		SnapshotRate = 20,
		RequestsPerSecond = 10,
		MaxManualPickups = 6,
		Hotkeys = {
			Keyboard = { Panel = "Tab", Reset = "R", Spawn = "V" },
			Gamepad = { Panel = "ButtonSelect", Reset = "ButtonR3", Spawn = "ButtonL3" },
		},
	}, "Config.Training")
	local M = Config.Missions
	h.expect(M.PerDay == 3 and M.FreeRerolls == 1 and M.TrueComboHits == 3, "Missions basics")
	h.expect(M.RequestsPerSecond == 2 and M.MinBotDifficulty == "Normal", "Missions limits")
	expectEqual(M.Sources, { Ranked = 1, Casual = 1, Bots = 0.5, Custom = 0.5 }, "Missions.Sources")
	local ids = {}
	for _, template in M.Templates do
		table.insert(ids, template.Id)
	end
	expectEqual(ids, {
		"OnlineWins",
		"OnlineMatches",
		"RankedWins",
		"WeaponDamage",
		"FFAKOs",
		"LegendWin",
		"LegendMatches",
		"TrueCombos",
		"KOs",
		"Damage",
	}, "mission templates")
	expectEqual(templateOf("WeaponDamage"), {
		Id = "WeaponDamage",
		Text = "Deal {goal} damage with {param}",
		Stat = "WeaponDamage",
		Param = "Weapon",
		Goals = { 1000, 1500 },
		Coins = 70,
		XP = 80,
	}, "WeaponDamage template")
	h.expect(templateOf("FFAKOs").Stat == "ModeKOs:FFA", "FFAKOs counts online FFA KOs")
	h.expect(#Config.Events == 2 and Config.Events[1].Id == "ShadowWeek", "Config.Events")
	h.expect(Config.Events[1].XPMult == 2 and Config.Events[1].Legend == "Vex", "ShadowWeek")
	h.expect(Config.Events[2].CoinMult == 1.5 and Config.Events[2].Ends == "2026-10-19T00:00:00Z", "LaunchCoins")
	h.expect(Config.EventMaxMult == 3, "EventMaxMult")
	h.expect(#Config.News == 3 and Config.News[2].Screen == "Practice", "Config.News")
	expectEqual(Config.Menu, {
		BackdropMap = "SkyShip",
		FeaturedSeconds = 6,
		ResultsDelay = 1.5,
		ResultsAutoReturn = 20,
		InputGrace = 0.5,
		VsWatchdogExtra = 5,
	}, "Config.Menu")
	expectEqual(Config.Seasons, {
		List = {
			{ Id = 1, Name = "Season 1", Ends = "2026-12-01T00:00:00Z" },
			{ Id = 2, Name = "Season 2", Ends = "2027-03-01T00:00:00Z" },
		},
		SoftResetFactor = 0.5,
	}, "Config.Seasons")
	expectEqual(Config.Rankings, {
		StorePrefix = "SkybrawlRanked_v1_",
		TopSize = 100,
		PageSize = 10,
		RefreshSeconds = 120,
		PastSeasonCacheSeconds = 600,
		FlushSeconds = 30,
		FriendsMax = 50,
		FriendsCacheSeconds = 300,
		FriendsBatch = 10,
		FriendsTimeout = 5,
		GlobalCooldown = 2,
		FriendsCooldown = 15,
		MinBudget = 5,
		FriendsReserve = 20,
	}, "Config.Rankings")
	h.expect(Config.Rewards.SourceMultiplier.Training == 0, "training pays nothing")
	expectEqual(
		Config.Art.Portraits,
		{ Kestrel = "", Brann = "", Yuki = "", Moss = "", Vex = "", Sol = "" },
		"Art.Portraits"
	)
	expectEqual(Config.Art.MenuWeapons, { Brann = "Gauntlets" }, "Art.MenuWeapons")
	expectEqual(Config.Music, { Menu = "", Volume = 0.5, FadeSeconds = 1.5 }, "Config.Music")
	h.expect(Config.DefaultSettings.MusicVolume == 0.5, "MusicVolume setting")
	for name, id in
		{
			MenuHover = "rbxasset://sounds/clickfast.wav",
			MenuConfirm = "rbxasset://sounds/button.wav",
			MenuBack = "rbxasset://sounds/switch.wav",
			LockIn = "rbxasset://sounds/unsheath.wav",
			Tick = "rbxasset://sounds/electronicpingshort.wav",
			MatchFound = "rbxasset://sounds/victory.wav",
		}
	do
		h.expect(Config.Sounds[name] == id, "Sounds." .. name)
	end
	-- deprecated keys stay until the Integration track removes them
	h.expect(Config.Data.LeaderboardStore and Config.Data.LeaderboardSize, "old leaderboard keys removed early")
end)

print("Party")

h.test("Party.limits matches the queue rules", function()
	local cases = {
		{ "Ranked1v1", nil, 1, 1 },
		{ "Ranked2v2", nil, 1, 2 },
		{ "FFA", nil, 1, 4 },
		{ "Bots", "Duel", 1, 1 },
		{ "Bots", "2v2", 1, 2 },
		{ "Bots", "FFA", 1, 3 },
		{ "Bots", nil, 1, 1 },
		{ "Custom", nil, 1, 4 },
	}
	for _, case in cases do
		local min, max = Party.limits(case[1], case[2])
		h.expect(min == case[3] and max == case[4], string.format("%s %s: %d-%d", case[1], tostring(case[2]), min, max))
	end
	h.expect(Party.MaxSize == 4, "Party.MaxSize")
end)

h.test("Party.canStart rejects non-leaders and oversized parties with the right text", function()
	local ok, code, text = Party.canStart("FFA", nil, 2, false)
	h.expect(not ok and code == "NotLeader" and text == "Only the party leader can start a search.", "non-leader")
	ok, code, text = Party.canStart("Ranked1v1", nil, 2, true)
	h.expect(not ok and code == "TooMany", "1v1 party of 2")
	h.expect(text == "Ranked 1v1 is for 1 player. Leave your party to queue.", text)
	ok, code, text = Party.canStart("Ranked2v2", nil, 3, true)
	h.expect(not ok and text == "Ranked 2v2 allows up to 2 players. Your party has 3.", tostring(text))
	_, _, text = Party.canStart("Bots", "2v2", 3, true)
	h.expect(text == "vs Bots (2v2) allows up to 2 players. Your party has 3.", tostring(text))
	_, _, text = Party.canStart("Bots", "FFA", 4, true)
	h.expect(text == "vs Bots (FFA) allows up to 3 players. Your party has 4.", tostring(text))
	_, _, text = Party.canStart("Bots", "Duel", 2, true)
	h.expect(text == "vs Bots (Duel) is for 1 player. Leave your party to queue.", tostring(text))
	_, _, text = Party.canStart("Custom", nil, 5, true)
	h.expect(text == "Custom rooms allows up to 4 players. Your party has 5.", tostring(text))
	ok = Party.canStart("FFA", nil, 4, true)
	h.expect(ok, "a party of 4 can queue FFA")
	ok = Party.canStart("Ranked1v1", nil, 1, true)
	h.expect(ok, "a solo player can queue 1v1")
end)

h.test("Party.canInvite stops at the max size", function()
	h.expect(Party.canInvite(1, 0), "solo can invite")
	h.expect(Party.canInvite(2, 1), "3 of 4 can invite")
	local ok, reason = Party.canInvite(3, 1)
	h.expect(not ok and reason == "Your party is full.", "members + invites at 4")
	h.expect(not Party.canInvite(4, 0), "a full party")
	h.expect(not Party.canInvite(1, 3), "pending invites count")
end)

h.test("Party.sortCandidates puts friends first, then idle players, then names", function()
	local list = {
		{ userId = 1, name = "zed", isFriend = true, status = "Match" },
		{ userId = 2, name = "Amy", isFriend = false, status = "Menu" },
		{ userId = 3, name = "bob", isFriend = true, status = "Menu" },
		{ userId = 4, name = "Carl", isFriend = false, status = "Queue" },
		{ userId = 5, name = "al", isFriend = false, status = "Menu" },
		{ userId = 6, name = "Ann", isFriend = false, status = "Room" },
	}
	local sorted = Party.sortCandidates(list)
	h.expect(sorted == list, "sorts in place and returns the list")
	local names = {}
	for _, c in list do
		table.insert(names, c.name)
	end
	expectEqual(names, { "bob", "zed", "al", "Amy", "Ann", "Carl" }, "order")
end)

print("Select")

local MAP_POOL = Config.Queue.MapPools.FFA

h.test("Select.candidates returns unique maps from the pool", function()
	local firsts = {}
	for seed = 1, 60 do
		local pool = table.clone(MAP_POOL)
		table.insert(pool, MAP_POOL[1]) -- a duplicate in the pool
		local picked = Select.candidates(pool, 3, h.Random.new(seed))
		h.expect(#picked == 3, "picked " .. #picked)
		local seen = {}
		for _, id in picked do
			h.expect(not seen[id], "picked " .. id .. " twice")
			h.expect(table.find(MAP_POOL, id), id .. " is not in the pool")
			seen[id] = true
		end
		firsts[picked[1]] = true
	end
	local distinct = 0
	for _ in firsts do
		distinct += 1
	end
	h.expect(distinct > 2, "candidates are not random")
end)

h.test("Select.candidates returns the whole pool when it is smaller", function()
	local picked = Select.candidates({ "SkyShip", "DuelRock" }, 3, h.Random.new(4))
	h.expect(#picked == 2, "picked " .. #picked)
	h.expect(table.find(picked, "SkyShip") and table.find(picked, "DuelRock"), "lost a map")
end)

h.test("Select.tally picks the most voted map", function()
	local votes = { p1 = "SkyShip", p2 = "SkyShip", p3 = "DuelRock", p4 = "Nowhere" }
	for seed = 1, 30 do
		local mapId, counts = Select.tally(votes, { "SkyShip", "DuelRock", "TwinIsles" }, h.Random.new(seed))
		h.expect(mapId == "SkyShip", "picked " .. mapId)
		expectEqual(counts, { SkyShip = 2, DuelRock = 1, TwinIsles = 0 }, "counts")
	end
end)

h.test("Select.tally breaks ties only among the tied maps", function()
	local seen = {}
	local rng = h.Random.new(11)
	for _ = 1, 200 do
		local mapId = Select.tally({ p1 = "SkyShip", p2 = "DuelRock" }, { "SkyShip", "DuelRock", "TwinIsles" }, rng)
		h.expect(mapId ~= "TwinIsles", "a map nobody voted for won a tie")
		seen[mapId] = true
	end
	h.expect(seen.SkyShip and seen.DuelRock, "a tie always went the same way")
end)

h.test("Select.tally picks among all candidates when nobody voted", function()
	local seen = {}
	local rng = h.Random.new(12)
	for _ = 1, 200 do
		seen[Select.tally({}, { "SkyShip", "DuelRock", "TwinIsles" }, rng)] = true
	end
	h.expect(seen.SkyShip and seen.DuelRock and seen.TwinIsles, "not every candidate can win")
end)

h.test("Select.resolveRandom and botPick never return Avatar", function()
	local roster = Select.roster()
	h.expect(#roster == #Legends.Order - 1 and not table.find(roster, "Avatar"), "roster")
	h.expect(Select.isValidPick("Random") and Select.isValidPick("Avatar") and Select.isValidPick("Vex"), "valid picks")
	h.expect(not Select.isValidPick("Nobody") and not Select.isValidPick(nil), "invalid picks")
	local seen = {}
	local rng = h.Random.new(13)
	for _ = 1, 400 do
		local a, b = Select.resolveRandom(rng), Select.botPick(rng)
		h.expect(a ~= "Avatar" and b ~= "Avatar", "picked Avatar")
		h.expect(table.find(roster, a) and table.find(roster, b), "picked outside the roster")
		seen[a] = true
	end
	for _, id in roster do
		h.expect(seen[id], "Random never resolves to " .. id)
	end
	local avoid = { Kestrel = true, Brann = true, Yuki = true, Moss = true, Vex = true }
	for _ = 1, 30 do
		h.expect(Select.botPick(rng, avoid) == "Sol", "botPick ignored avoid")
	end
	local all = table.clone(avoid)
	all.Sol = true
	local pick = Select.botPick(h.Random.new(3), all)
	h.expect(table.find(roster, pick), "botPick with everything taken still picks a legend")
end)

h.test("Select.allLocked ignores bots and players who left", function()
	local slots = {
		{ key = "p1", isBot = false, locked = true },
		{ key = "b1", isBot = true, locked = false },
		{ key = "p2", isBot = false, locked = false, left = true },
	}
	h.expect(Select.allLocked(slots), "a bot or a leaver held the select")
	table.insert(slots, { key = "p3", isBot = false, locked = false })
	h.expect(not Select.allLocked(slots), "an unlocked human didn't count")
	h.expect(not Select.allLocked({ { key = "b1", isBot = true, locked = true } }), "no humans counts as locked")
end)

local function rankedSession(ranked, source)
	return {
		id = 7,
		mode = "2v2",
		source = source or "Ranked",
		ranked = ranked,
		queueType = ranked and "Ranked2v2" or nil,
		label = "Ranked 2v2",
		rules = { winRule = "Stocks", stocks = 3, timeLimit = 480 },
		phase = "Pick",
		endsAt = 1000,
		maps = { "SkyShip", "DuelRock", "TwinIsles" },
		votes = { p1 = "DuelRock", p3 = "DuelRock", p4 = "SkyShip" },
		slots = {
			{
				key = "p1",
				name = "Ann",
				userId = 1,
				isBot = false,
				team = 1,
				legend = "Vex",
				locked = true,
				ownLook = true,
			},
			{
				key = "p2",
				name = "Bo",
				userId = 2,
				isBot = false,
				team = 1,
				legend = "Sol",
				locked = false,
				partyId = 3,
			},
			{
				key = "p3",
				name = "Cy",
				userId = 3,
				isBot = false,
				team = 2,
				legend = "Moss",
				locked = true,
				random = true,
				ownLook = true,
				rating = 1300,
			},
			{ key = "p4", name = "Di", userId = 4, isBot = false, team = 2, legend = "Yuki", locked = false },
		},
	}
end

h.test("Select.viewState hides ranked opponents' picks but not teammates'", function()
	local view = Select.viewState(rankedSession(true), "p1")
	h.expect(view.id == 7 and view.you == "p1" and view.ranked == true and view.phase == "Pick", "header fields")
	h.expect(view.queueType == "Ranked2v2" and view.endsAt == 1000 and view.yourVote == "DuelRock", "session fields")
	expectEqual(view.rules, { winRule = "Stocks", stocks = 3, timeLimit = 480 }, "rules")
	expectEqual(view.maps, {
		{ id = "SkyShip", votes = 1 },
		{ id = "DuelRock", votes = 2 },
		{ id = "TwinIsles", votes = 0 },
	}, "map votes")
	local byKey = {}
	for _, slot in view.slots do
		byKey[slot.key] = slot
	end
	h.expect(view.slots[1].key == "p1" and view.slots[4].key == "p4", "slots keep the session order")
	h.expect(byKey.p1.isYou and byKey.p1.legend == "Vex" and byKey.p1.ownLook == true, "your own slot")
	h.expect(not byKey.p2.isYou and byKey.p2.legend == "Sol" and not byKey.p2.hidden, "a teammate's pick")
	h.expect(byKey.p2.partyId == 3, "partyId")
	for _, key in { "p3", "p4" } do
		local slot = byKey[key]
		h.expect(slot.hidden and slot.legend == nil and slot.ownLook == nil, key .. "'s pick leaked")
		h.expect(slot.random == false, key .. "'s Random leaked")
	end
	h.expect(byKey.p3.locked and not byKey.p4.locked, "locks are visible")
	h.expect(byKey.p3.rating == 1300 and byKey.p3.name == "Cy", "opponent card")
	-- from the other side
	local other = Select.viewState(rankedSession(true), "p3")
	for _, slot in other.slots do
		h.expect((slot.team == 2) == not slot.hidden, slot.key .. " visibility from team 2")
	end
	local fixed = rankedSession(true)
	fixed.maps = nil
	fixed.fixedMap = "SkyShip"
	local fixedView = Select.viewState(fixed, "p1")
	h.expect(fixedView.maps == nil and fixedView.fixedMap == "SkyShip", "fixed map")
end)

h.test("Select.viewState shows every pick in casual, bots and custom", function()
	for _, source in { "Casual", "Bots", "Custom" } do
		local view = Select.viewState(rankedSession(false, source), "p1")
		h.expect(view.source == source and view.ranked == false, source)
		for _, slot in view.slots do
			h.expect(not slot.hidden and slot.legend ~= nil, source .. ": " .. slot.key .. " is hidden")
		end
		h.expect(view.slots[3].random == true and view.slots[3].ownLook == true, source .. ": p3's flags")
	end
end)

h.test("Select.vsState reveals every legend", function()
	local session = rankedSession(true)
	session.phase = "Vs"
	session.slots[4].left = true
	local vs = Select.vsState(session, "DuelRock", Config.Select.VsSeconds)
	h.expect(vs.id == 7 and vs.mapId == "DuelRock" and vs.startsIn == 3 and vs.ranked, "header")
	h.expect(#vs.fighters == 3, "a player who left is still listed")
	local legends = {}
	for _, fighter in vs.fighters do
		legends[fighter.key] = fighter.legend
		h.expect(type(fighter.ownLook) == "boolean", "ownLook")
	end
	expectEqual(legends, { p1 = "Vex", p2 = "Sol", p3 = "Moss" }, "legends")
end)

print("Missions")

h.test("Missions.dayIndex flips at UTC midnight", function()
	local before = Events.parse("2026-10-09T23:59:59Z")
	local after = Events.parse("2026-10-10T00:00:00Z")
	h.expect(Missions.dayIndex(before) == 20735, "day of 2026-10-09")
	h.expect(Missions.dayIndex(after) == 20736, "day of 2026-10-10")
	h.expect(Missions.resetAt(Missions.dayIndex(before)) == after, "resetAt is the next midnight")
	h.expect(Missions.DAY == 86400, "DAY")
end)

h.test("Missions.generate is deterministic per user, day and seq", function()
	local a = Missions.generate(TODAY, 1234, 1)
	expectEqual(Missions.generate(TODAY, 1234, 1), a, "same inputs")
	local function same(m)
		return m.Id == a.Id and m.Param == a.Param and m.Goal == a.Goal
	end
	local dayDiffers, userDiffers, seqDiffers = 0, 0, 0
	for i = 1, 20 do
		if not same(Missions.generate(TODAY + i, 1234, 1)) then
			dayDiffers += 1
		end
		local other = Missions.generate(TODAY, 1234 + i * 7, 1)
		h.expect(templateOf(other.Id) ~= nil, "unknown template")
		if not same(other) then
			userDiffers += 1
		end
		if not same(Missions.generate(TODAY, 1234, 1 + i)) then
			seqDiffers += 1
		end
	end
	h.expect(dayDiffers > 10, "missions don't change from day to day")
	h.expect(userDiffers > 10, "every player gets the same missions")
	h.expect(seqDiffers > 10, "rerolls and refills repeat the first mission")
	local studio = Missions.generate(TODAY, -1, 2)
	expectEqual(Missions.generate(TODAY, -1, 2), studio, "Studio user ids")
	-- exclude everything but one template
	local exclude = {}
	for _, template in Config.Missions.Templates do
		exclude[template.Id] = template.Id ~= "WeaponDamage"
	end
	for seq = 1, 10 do
		local m = Missions.generate(TODAY, 99, seq, exclude)
		h.expect(m.Id == "WeaponDamage", "exclude ignored")
		h.expect(table.find(Weapons.Order, m.Param), "weapon param " .. tostring(m.Param))
		h.expect(table.find({ 1000, 1500 }, m.Goal), "goal")
		h.expect(m.Coins == (m.Goal == 1000 and 70 or 105), "coins scale with the goal: " .. m.Coins)
		h.expect(m.XP == (m.Goal == 1000 and 80 or 120), "xp scales with the goal")
		h.expect(m.Progress == 0 and m.Claimed == false, "fresh")
	end
end)

h.test("Missions.ensureDay gives 3 different templates and resets the reroll on a new day", function()
	for userId = 1, 40 do
		local state = Missions.newState()
		local changed, paid = Missions.ensureDay(state, TODAY, userId)
		h.expect(changed and paid == nil, "first day")
		h.expect(state.Day == TODAY and state.Seq == 3 and state.Rerolled == false, "state fields")
		h.expect(#state.List == 3, "missions: " .. #state.List)
		local ids = {}
		for _, m in state.List do
			h.expect(not ids[m.Id], "template " .. m.Id .. " twice")
			ids[m.Id] = true
		end
		state.Rerolled = true
		Missions.ensureDay(state, TODAY + 1, userId)
		h.expect(state.Day == TODAY + 1 and state.Rerolled == false and #state.List == 3, "next day")
	end
end)

h.test("Missions.ensureDay refills missing entries on the same day", function()
	local state = Missions.newState()
	Missions.ensureDay(state, TODAY, 77)
	local kept = { state.List[1].Id, state.List[3].Id }
	table.remove(state.List, 2)
	local changed, paid = Missions.ensureDay(state, TODAY, 77)
	h.expect(changed and paid == nil, "refill")
	h.expect(#state.List == 3 and state.Seq == 4, "seq " .. state.Seq)
	h.expect(state.List[1].Id == kept[1] and state.List[2].Id == kept[2], "kept missions moved")
	h.expect(state.List[3].Id ~= kept[1] and state.List[3].Id ~= kept[2], "refill repeated a template")
	changed = Missions.ensureDay(state, TODAY, 77)
	h.expect(not changed, "a full list changed")
	-- a server whose clock is behind doesn't roll back to yesterday
	h.expect(not Missions.isNewDay(state, TODAY - 1) and not Missions.isNewDay(state, TODAY), "isNewDay")
	h.expect(Missions.isNewDay(state, TODAY + 1), "isNewDay missed tomorrow")
	changed = Missions.ensureDay(state, TODAY - 1, 77)
	h.expect(not changed and state.Day == TODAY, "rolled back a day")
end)

h.test("a new day pays done unclaimed missions once", function()
	local state = {
		Day = TODAY - 1,
		Rerolled = true,
		Seq = 3,
		List = {
			entry("KOs", 8, 8, { coins = 70, xp = 90 }),
			entry("Damage", 2000, 2000, { claimed = true }),
			entry("TrueCombos", 5, 2),
		},
	}
	local old = state.List
	local changed, paid = Missions.ensureDay(state, TODAY, 5)
	h.expect(changed, "new day")
	expectEqual(paid, { coins = 70, xp = 90, count = 1 }, "paid")
	h.expect(old[1].Claimed, "the paid mission wasn't marked claimed")
	for _, m in state.List do
		h.expect(m.Progress == 0 and not m.Claimed, "new missions start fresh")
	end
	_, paid = Missions.ensureDay(state, TODAY, 5)
	h.expect(paid == nil, "paid twice the same day")
	_, paid = Missions.ensureDay(state, TODAY + 1, 5)
	h.expect(paid == nil, "paid unfinished missions")
end)

h.test("Missions.reroll allows one free reroll a day and never repeats a current template", function()
	for userId = 1, 40 do
		local state = Missions.newState()
		Missions.ensureDay(state, TODAY, userId)
		local before = {}
		for _, m in state.List do
			before[m.Id] = true
		end
		local ok, err = Missions.reroll(state, 2, TODAY, userId)
		h.expect(ok and err == nil, "reroll refused: " .. tostring(err))
		h.expect(not before[state.List[2].Id], "the reroll repeated a current template")
		h.expect(state.Rerolled and state.Seq == 4, "reroll bookkeeping")
		h.expect(state.List[1].Id ~= state.List[3].Id, "other missions changed")
		ok, err = Missions.reroll(state, 1, TODAY, userId)
		h.expect(not ok and err == "No free rerolls left today.", "second reroll: " .. tostring(err))
	end
	-- the reroll is the same on every server
	local a, b = Missions.newState(), Missions.newState()
	Missions.ensureDay(a, TODAY, 9)
	Missions.ensureDay(b, TODAY, 9)
	h.expect(Missions.view(a, NOW).rerollAvailable, "rerollAvailable before the reroll")
	Missions.reroll(a, 1, TODAY, 9)
	Missions.reroll(b, 1, TODAY, 9)
	expectEqual(a, b, "deterministic reroll")
	h.expect(not Missions.view(a, NOW).rerollAvailable, "rerollAvailable after the reroll")
	-- FreeRerolls = 0 turns rerolls off
	local saved = Config.Missions.FreeRerolls
	Config.Missions.FreeRerolls = 0
	local none = Missions.newState()
	Missions.ensureDay(none, TODAY, 9)
	local ok, err = Missions.reroll(none, 1, TODAY, 9)
	local available = Missions.view(none, NOW).rerollAvailable
	Config.Missions.FreeRerolls = saved
	h.expect(not ok and err == "No free rerolls left today." and not none.Rerolled, "rerolled with FreeRerolls = 0")
	h.expect(not available, "rerollAvailable with FreeRerolls = 0")
end)

h.test("Missions.reroll refuses done and claimed missions", function()
	local state = {
		Day = TODAY,
		Rerolled = false,
		Seq = 3,
		List = {
			entry("KOs", 8, 8),
			entry("Damage", 2000, 2000, { claimed = true }),
			entry("TrueCombos", 5, 1),
		},
	}
	local ok, err = Missions.reroll(state, 1, TODAY, 1)
	h.expect(not ok and err == "That mission is already done.", "done: " .. tostring(err))
	ok, err = Missions.reroll(state, 2, TODAY, 1)
	h.expect(not ok and err == "That mission is already done.", "claimed: " .. tostring(err))
	ok, err = Missions.reroll(state, 9, TODAY, 1)
	h.expect(not ok and err == "Unknown mission.", "unknown: " .. tostring(err))
	ok, err = Missions.reroll(state, "1", TODAY, 1)
	h.expect(not ok and err == "Unknown mission.", "string index: " .. tostring(err))
	h.expect(not state.Rerolled, "a refused reroll used the free one")
	h.expect(Missions.reroll(state, 3, TODAY, 1), "an unfinished mission can be rerolled")
end)

local function matchInfo(source, mode, extra)
	local info = {
		source = source,
		ranked = source == "Ranked",
		mode = mode,
		duration = 120,
		hasBots = source == "Bots",
		mapId = "SkyShip",
		training = source == "Training",
		damageMultiplier = 1,
	}
	for k, v in extra or {} do
		info[k] = v
	end
	return info
end

local function matchEntry(extra)
	local e = {
		team = 1,
		won = true,
		draw = false,
		kos = 3,
		falls = 1,
		damageDealt = 250.7,
		damageTaken = 100,
		legend = "Vex",
		ownLook = false,
		placement = 1,
		weaponDamage = { Sword = 120.5, Unarmed = 30 },
		trueCombos = 2,
		maxCombo = 5,
	}
	for k, v in extra or {} do
		e[k] = v
	end
	return e
end

h.test("Missions.statsFromEntry counts online wins, weapon damage, FFA KOs, legend wins and true combos", function()
	local stats = Missions.statsFromEntry(matchInfo("Casual", "FFA"), matchEntry())
	expectEqual(stats, {
		Matches = 1,
		Wins = 1,
		KOs = 3,
		Damage = 250,
		TrueCombos = 2,
		OnlineMatches = 1,
		OnlineWins = 1,
		["ModeKOs:FFA"] = 3,
		["LegendMatches:Vex"] = 1,
		["LegendWins:Vex"] = 1,
		["WeaponDamage:Sword"] = 120,
		["WeaponDamage:Unarmed"] = 30,
	}, "casual FFA win")
	local ranked = Missions.statsFromEntry(matchInfo("Ranked", "1v1"), matchEntry({ won = false, trueCombos = 0 }))
	h.expect(ranked.RankedWins == nil and ranked.Wins == nil and ranked.OnlineWins == nil, "a loss counted as a win")
	h.expect(ranked.OnlineMatches == 1 and ranked["ModeKOs:1v1"] == 3, "ranked match stats")
	h.expect(ranked.TrueCombos == nil and ranked["LegendWins:Vex"] == nil, "zero stats are left out")
	local rankedWin = Missions.statsFromEntry(matchInfo("Ranked", "2v2"), matchEntry())
	h.expect(rankedWin.RankedWins == 1 and rankedWin.OnlineWins == 1, "ranked win")
	-- absent MatchEntry fields default safely
	local bare = Missions.statsFromEntry(matchInfo("Casual", "FFA"), { won = false, kos = 1, damageDealt = 10 })
	h.expect(bare["LegendMatches:Avatar"] == 1 and bare.KOs == 1 and bare.TrueCombos == nil, "missing fields")
end)

h.test("Missions.statsFromEntry ignores training", function()
	expectEqual(Missions.statsFromEntry(matchInfo("Training", "1v1"), matchEntry()), {}, "training")
	local info = matchInfo("Casual", "1v1", { training = true })
	expectEqual(Missions.statsFromEntry(info, matchEntry()), {}, "a match flagged as training")
	expectEqual(Missions.statsFromEntry(matchInfo("Mystery", "1v1"), matchEntry()), {}, "an unknown source")
end)

h.test("statsFromEntry ignores Easy bots and boosted custom rooms", function()
	local easy = matchInfo("Bots", "1v1", { minBotDifficulty = "Easy" })
	expectEqual(Missions.statsFromEntry(easy, matchEntry()), {}, "Easy bots")
	local normal = matchInfo("Bots", "1v1", { minBotDifficulty = "Normal" })
	h.expect(Missions.statsFromEntry(normal, matchEntry()).Wins == 1, "Normal bots count")
	local hard = matchInfo("Bots", "1v1", { minBotDifficulty = "Hard" })
	h.expect(Missions.statsFromEntry(hard, matchEntry()).Wins == 1, "Hard bots count")
	local boosted = matchInfo("Custom", "1v1", { damageMultiplier = 1.5 })
	expectEqual(Missions.statsFromEntry(boosted, matchEntry()), {}, "boosted custom room")
	local weak = matchInfo("Custom", "1v1", { damageMultiplier = 0.5 })
	expectEqual(Missions.statsFromEntry(weak, matchEntry()), {}, "weakened custom room")
	h.expect(Missions.statsFromEntry(matchInfo("Custom", "1v1"), matchEntry()).Wins == 1, "standard custom room")
	local customEasy = matchInfo("Custom", "2v2", { minBotDifficulty = "Easy" })
	expectEqual(Missions.statsFromEntry(customEasy, matchEntry()), {}, "custom room with an Easy bot")
end)

h.test("statsFromEntry halves bots and custom damage but counts wins whole", function()
	for _, source in { "Bots", "Custom" } do
		local info = matchInfo(source, "1v1", { minBotDifficulty = source == "Bots" and "Normal" or nil })
		local stats = Missions.statsFromEntry(info, matchEntry({ damageDealt = 301, weaponDamage = { Bow = 101 } }))
		h.expect(stats.Damage == 150 and stats["WeaponDamage:Bow"] == 50, source .. " damage isn't halved")
		h.expect(stats.Wins == 1 and stats["LegendWins:Vex"] == 1 and stats.Matches == 1, source .. " wins")
		h.expect(stats.KOs == 3 and stats.TrueCombos == 2, source .. " counts")
		h.expect(stats.OnlineMatches == nil and stats.OnlineWins == nil, source .. " counted as online")
	end
end)

h.test("FFA KOs count only in casual FFA", function()
	local casual = Missions.statsFromEntry(matchInfo("Casual", "FFA"), matchEntry())
	h.expect(casual["ModeKOs:FFA"] == 3, "casual FFA")
	local bots = Missions.statsFromEntry(matchInfo("Bots", "FFA", { minBotDifficulty = "Normal" }), matchEntry())
	h.expect(bots["ModeKOs:FFA"] == nil and bots.KOs == 3, "bots FFA")
	local custom = Missions.statsFromEntry(matchInfo("Custom", "FFA"), matchEntry())
	h.expect(custom["ModeKOs:FFA"] == nil, "custom FFA")
	local state = { Day = TODAY, Rerolled = false, Seq = 1, List = { entry("FFAKOs", 5, 0) } }
	h.expect(Missions.statKey(state.List[1]) == "ModeKOs:FFA", "FFAKOs stat key")
	h.expect(#Missions.applyStats(state, bots) == 0, "bots moved the FFA KO mission")
	h.expect(#Missions.applyStats(state, casual) == 1 and state.List[1].Progress == 3, "casual didn't")
end)

h.test("Missions.applyStats caps progress at the goal and reports completions once", function()
	local state = {
		Day = TODAY,
		Rerolled = false,
		Seq = 3,
		List = {
			entry("KOs", 8, 6),
			entry("WeaponDamage", 1000, 100, { param = "Sword" }),
			entry("LegendWin", 1, 0, { param = "Yuki" }),
		},
	}
	h.expect(Missions.statKey(state.List[2]) == "WeaponDamage:Sword", "weapon stat key")
	h.expect(Missions.statKey(state.List[3]) == "LegendWins:Yuki", "legend stat key")
	local moved = Missions.applyStats(state, { KOs = 5, ["WeaponDamage:Sword"] = 120, ["LegendWins:Vex"] = 1 })
	expectEqual(moved, {
		{ index = 1, progress = 8, goal = 8, done = true, justDone = true },
		{ index = 2, progress = 220, goal = 1000, done = false, justDone = false },
	}, "first match")
	h.expect(state.List[1].Progress == 8, "progress went past the goal")
	h.expect(state.List[3].Progress == 0, "another legend's win counted")
	moved = Missions.applyStats(state, { KOs = 4, ["WeaponDamage:Sword"] = 900 })
	expectEqual(moved, {
		{ index = 2, progress = 1000, goal = 1000, done = true, justDone = true },
	}, "second match")
	moved = Missions.applyStats(state, { KOs = 4, ["WeaponDamage:Sword"] = 900 })
	h.expect(#moved == 0, "a finished mission reported again")
end)

h.test("Missions.claim pays once", function()
	local state = {
		Day = TODAY,
		Rerolled = false,
		Seq = 3,
		List = { entry("KOs", 8, 8, { coins = 70, xp = 90 }), entry("Damage", 2000, 10) },
	}
	local ok, coins, xp = Missions.claim(state, 1)
	h.expect(ok and coins == 70 and xp == 90, "claim")
	local again, reason = Missions.claim(state, 1)
	h.expect(not again and reason == "Already claimed.", tostring(reason))
	ok, reason = Missions.claim(state, 2)
	h.expect(not ok and reason == "That mission isn't done yet.", tostring(reason))
	ok, reason = Missions.claim(state, 3)
	h.expect(not ok and reason == "Unknown mission.", tostring(reason))
	local view = Missions.view(state, NOW)
	h.expect(view.list[1].claimed and view.list[1].done and view.claimable == 0, "view after the claim")
end)

h.test("Missions.describe formats goals and params", function()
	local cases = {
		{ entry("WeaponDamage", 1500, 0, { param = "Sword" }), "Deal 1,500 damage with a Sword" },
		{ entry("WeaponDamage", 1000, 0, { param = "Gauntlets" }), "Deal 1,000 damage with Gauntlets" },
		{ entry("LegendWin", 1, 0, { param = "Vex" }), "Win as Vex" },
		{ entry("LegendMatches", 3, 0, { param = "Yuki" }), "Play 3 matches as Yuki" },
		{ entry("FFAKOs", 8, 0), "KO 8 opponents in online Free-for-all" },
		{ entry("Damage", 3000, 0), "Deal 3,000 damage" },
	}
	for _, case in cases do
		local text = Missions.describe(case[1])
		h.expect(text == case[2], text)
	end
end)

h.test("Missions.sanitize drops junk entries and unknown templates", function()
	local raw = {
		Day = "yesterday",
		Seq = -3,
		Rerolled = "yes",
		List = {
			{ Id = "Nope", Goal = 3 },
			"junk",
			{ Id = "KOs", Goal = 12, Progress = 99, Claimed = true, Coins = -5, XP = 1e9 },
			{ Id = "WeaponDamage", Param = "Laser", Goal = 1000 },
			{ Id = "LegendWin", Param = "Avatar", Goal = 1 },
			{ Id = "LegendMatches", Goal = 3 },
			{ Id = "Damage", Goal = 2000.7, Progress = -4, Param = "Sword" },
			{ Id = "KOs", Goal = 8 },
			{ Id = "TrueCombos", Goal = 0 / 0 },
			{ Id = "OnlineWins", Goal = 99, Progress = 1.5 },
			{ Id = "RankedWins", Goal = 1 },
		},
	}
	local state = Missions.sanitize(raw)
	h.expect(state.Day == 0 and state.Seq == 0 and state.Rerolled == false, "header fields")
	expectEqual(state.List, {
		{ Id = "KOs", Goal = 12, Progress = 12, Claimed = true, Coins = 0, XP = 1e6 },
		{ Id = "Damage", Goal = 2000, Progress = 0, Claimed = false, Coins = 60, XP = 80 },
		{ Id = "OnlineWins", Goal = 3, Progress = 1, Claimed = false, Coins = 180, XP = 225 },
	}, "entries")
	expectEqual(Missions.sanitize(nil), Missions.newState(), "nil")
	expectEqual(Missions.sanitize({ List = "x" }), Missions.newState(), "a list that isn't a list")
	local good = Missions.newState()
	Missions.ensureDay(good, TODAY, 3)
	expectEqual(Missions.sanitize(good), good, "a valid state changed")
end)

print("Events")

h.test("Events.parse reads UTC ISO dates", function()
	h.expect(Events.parse("1970-01-01T00:00:00Z") == 0, "epoch")
	h.expect(Events.parse("2026-10-09T00:00:00Z") == 1791504000, "2026-10-09")
	h.expect(Events.parse("2026-10-09") == 1791504000, "date only")
	h.expect(Events.parse("2026-10-09T12:34:56Z") == 1791549296, "time of day")
	h.expect(Events.parse("2027-03-01T00:00:00Z") == 1803859200, "after February")
	h.expect(Events.parse("2000-02-29") == 951782400, "leap day")
	h.expect(Events.parse("1969-12-31T23:59:59Z") == -1, "before the epoch")
	for _, bad in { "2001-02-29", "2026-13-01", "2026-00-10", "2026-10-32", "2026-10-09T24:00:00Z", "junk", "", 5 } do
		h.expect(Events.parse(bad) == nil, "parsed " .. tostring(bad))
	end
	h.expect(Events.parse(nil) == nil, "parsed nil")
end)

local function event(id, starts, ends, extra)
	local e = { Id = id, Starts = starts, Ends = ends }
	for k, v in extra or {} do
		e[k] = v
	end
	return e
end

h.test("Events.active respects start and end", function()
	local starts, ends = Events.parse("2026-10-09"), Events.parse("2026-10-16")
	local list = {
		event("A", "2026-10-09", "2026-10-16"),
		event("Bad", "2026-10-09", "soon"),
		event("B", "2026-10-01", "2026-10-30T00:00:00Z"),
	}
	local function ids(now)
		local out = {}
		for _, e in Events.active(list, now) do
			table.insert(out, e.Id)
		end
		return table.concat(out, ",")
	end
	h.expect(ids(starts - 1) == "B", "before the start: " .. ids(starts - 1))
	h.expect(ids(starts) == "A,B", "at the start: " .. ids(starts))
	h.expect(ids(ends - 1) == "A,B", "just before the end")
	h.expect(ids(ends) == "B", "at the end: " .. ids(ends))
	h.expect(Events.endsIn(list[1], starts) == 7 * DAY, "endsIn")
	h.expect(Events.endsIn(list[1], ends + 50) == 0, "endsIn after the end")
	h.expect(Events.endsIn(list[2], starts) == 0, "endsIn of a bad date")
	h.expect(Events.isActive(Config.Events[1], Events.parse("2026-10-10")), "ShadowWeek runs on its dates")
end)

h.test("Events.multipliers takes the best matching event and honours the legend filter", function()
	local on, off = "2026-10-01", "2026-11-01"
	local list = {
		event("VexXP", on, off, { XPMult = 2, Legend = "Vex" }),
		event("AllXP", on, off, { XPMult = 1.5 }),
		event("Coins", on, off, { CoinMult = 1.5 }),
		event("SolXP", on, off, { XPMult = 5, Legend = "Sol" }),
		event("Over", "2026-09-01", "2026-09-02", { XPMult = 3, CoinMult = 3 }),
		event("Junk", on, off, { XPMult = "lots", CoinMult = 0 / 0 }),
	}
	local now = Events.parse("2026-10-15")
	local function check(legend, wantXp, wantCoins, wantIds)
		local xp, coins, applied = Events.multipliers(list, now, legend)
		local ids = {}
		for _, e in applied do
			table.insert(ids, e.Id)
		end
		h.expect(
			xp == wantXp and coins == wantCoins and table.concat(ids, ",") == wantIds,
			string.format("%s: %s, %s, %s", tostring(legend), xp, coins, table.concat(ids, ","))
		)
	end
	check("Vex", 2, 1.5, "VexXP,Coins")
	check("Kestrel", 1.5, 1.5, "AllXP,Coins")
	check("Sol", Config.EventMaxMult, 1.5, "Coins,SolXP")
	check(nil, 1.5, 1.5, "AllXP,Coins")
	local xp, coins, applied = Events.multipliers(list, Events.parse("2027-01-01"), "Vex")
	h.expect(xp == 1 and coins == 1 and #applied == 0, "no active event")
end)

print("Seasons")

local S1_END = Events.parse("2026-12-01T00:00:00Z")
local S2_END = Events.parse("2027-03-01T00:00:00Z")

h.test("Seasons.current picks the first season that has not ended", function()
	h.expect(Seasons.current(NOW).Id == 1, "October 2026")
	h.expect(Seasons.current(S1_END - 1).Id == 1, "the last second of season 1")
	h.expect(Seasons.current(S1_END).Id == 2, "season 2 starts when season 1 ends")
	h.expect(Seasons.current(S2_END + 1000).Id == 2, "after the last season it stays current")
	local s2 = Seasons.byId(2)
	h.expect(s2.Name == "Season 2" and s2.startsAt == S1_END and s2.endsAt == S2_END, "season 2 dates")
	h.expect(Seasons.byId(1).startsAt == 0 and Seasons.byId(9) == nil, "byId")
	local started = Seasons.started(S1_END + 5)
	h.expect(#started == 2 and started[1].Id == 2 and started[2].Id == 1, "started, newest first")
	h.expect(#Seasons.started(NOW) == 1, "season 2 hasn't started in October")
end)

h.test("Seasons.current has a default season when the list is empty", function()
	local saved = Config.Seasons.List
	Config.Seasons.List = {}
	local ok, err = pcall(function()
		local current = Seasons.current(NOW)
		h.expect(current.Id == 1 and current.Name == "Season 1", "default season")
		h.expect(current.startsAt == 0 and current.endsAt == math.huge, "it never ends")
		h.expect(Seasons.byId(1) ~= nil and #Seasons.started(NOW) == 1, "it is listed")
	end)
	Config.Seasons.List = saved
	h.expect(ok, tostring(err))
end)

h.test("Seasons.softReset pulls ratings toward the start rating", function()
	h.expect(Seasons.softReset(1000) == 1000, "start rating")
	h.expect(Seasons.softReset(1400) == 1200, "high rating")
	h.expect(Seasons.softReset(1401) == 1201, "rounding")
	h.expect(Seasons.softReset(600) == 800, "low rating")
	local saved = Config.Seasons.SoftResetFactor
	Config.Seasons.SoftResetFactor = 1.5
	local floored = Seasons.softReset(400)
	Config.Seasons.SoftResetFactor = saved
	h.expect(floored == Config.Ranked.MinRating, "MinRating floor: " .. floored)
end)

local function seasonProfile(season, extra)
	local profile = {
		Season = season,
		Rating1v1 = 1450,
		Rating2v2 = 1200,
		Peak1v1 = 1700,
		Peak2v2 = 1250,
		SeasonStats = {
			["1v1"] = { Wins = 0, Losses = 2, Legends = { Vex = { Wins = 0, Played = 2 } } },
			["2v2"] = { Wins = 3, Losses = 0, Legends = {} },
		},
	}
	for k, v in extra or {} do
		profile[k] = v
	end
	return profile
end

h.test("Seasons.ensure keeps last season's end-of-season tiers as a badge and resets season stats", function()
	local profile = seasonProfile(1)
	local changed, change = Seasons.ensure(profile, S1_END + 10)
	h.expect(changed, "no reset")
	expectEqual(change, { from = 1, to = 2 }, "change")
	expectEqual(
		profile.SeasonBadge,
		{ Season = 1, Name = "Season 1", Tier1v1 = "Gold", Tier2v2 = "Silver" },
		"badge (end-of-season tiers, not peaks)"
	)
	h.expect(profile.Rating1v1 == 1225 and profile.Rating2v2 == 1100, "soft reset")
	h.expect(profile.Peak1v1 == 1225 and profile.Peak2v2 == 1100, "peaks follow the reset")
	expectEqual(profile.SeasonStats, {
		["1v1"] = { Wins = 0, Losses = 0, Legends = {} },
		["2v2"] = { Wins = 0, Losses = 0, Legends = {} },
	}, "season stats")
	h.expect(profile.Season == 2, "season id")
	-- only one mode played: only that tier
	local solo = seasonProfile(1)
	solo.SeasonStats["2v2"] = { Wins = 0, Losses = 0, Legends = {} }
	Seasons.ensure(solo, S1_END + 10)
	h.expect(solo.SeasonBadge.Tier1v1 == "Gold" and solo.SeasonBadge.Tier2v2 == nil, "one-mode badge")
	-- nothing played: the previous badge stays
	local old = { Season = 0, Name = "Season 0", Tier1v1 = "Diamond" }
	local idle = seasonProfile(1, { SeasonBadge = old })
	idle.SeasonStats = {
		["1v1"] = { Wins = 0, Losses = 0, Legends = {} },
		["2v2"] = { Wins = 0, Losses = 0, Legends = {} },
	}
	h.expect(Seasons.ensure(idle, S1_END + 10), "an idle profile still moves season")
	h.expect(idle.SeasonBadge == old and idle.Season == 2, "the old badge was replaced")
end)

h.test("Seasons.ensure leaves a profile in the current season alone", function()
	local profile = seasonProfile(1)
	local copy = table.clone(profile)
	h.expect(not Seasons.ensure(profile, NOW), "reset inside the season")
	expectEqual(profile, copy, "profile changed")
	local unset = seasonProfile(0)
	h.expect(not Seasons.ensure(unset, S1_END + 10), "a profile without a season was reset")
	local ahead = seasonProfile(2)
	h.expect(not Seasons.ensure(ahead, NOW), "a server behind the season boundary rolled a profile back")
	h.expect(ahead.Season == 2 and ahead.Rating1v1 == 1450, "the newer season's profile changed")
	h.expect(not Seasons.isBehind(ahead, NOW) and not Seasons.isBehind(profile, NOW), "isBehind")
	h.expect(not Seasons.isBehind(unset, S1_END + 10), "isBehind without a season")
	h.expect(Seasons.isBehind(seasonProfile(1), S1_END + 10), "isBehind missed an ended season")
end)

print("Rankings")

h.test("Rankings.encode and decode round-trip and sort by rating, then wins", function()
	local value = Rankings.encode(1500, "Vex", 12, 7)
	local rating, legend, wins, losses = Rankings.decode(value)
	h.expect(rating == 1500 and legend == "Vex" and wins == 12 and losses == 7, "round trip")
	rating, legend = Rankings.decode(Rankings.encode(1500, nil, 0, 0))
	h.expect(rating == 1500 and legend == nil, "no main legend")
	h.expect(select(2, Rankings.decode(Rankings.encode(1500, "Nobody", 1, 1))) == nil, "unknown legend")
	rating, legend, wins, losses = Rankings.decode(Rankings.encode(1234.9, "Sol", 4.7, 123456))
	h.expect(rating == 1234 and wins == 4 and losses == 99999 and legend == "Sol", "floors and caps")
	h.expect(Rankings.decode(Rankings.encode(99999, nil, 0, 0)) == 8999, "rating cap")
	h.expect(Rankings.decode(Rankings.encode(-50, nil, 0, 0)) == 0, "rating floor")
	local top = Rankings.encode(8999, "Avatar", 99999, 99999)
	h.expect(top < 2 ^ 53 and top == math.floor(top), "the largest value isn't exact")
	rating, legend, wins, losses = Rankings.decode(top)
	h.expect(rating == 8999 and legend == "Avatar" and wins == 99999 and losses == 99999, "largest round trip")
	local a = Rankings.encode(1500, "Kestrel", 3, 50)
	local b = Rankings.encode(1500, "Sol", 4, 0)
	local c = Rankings.encode(1501, nil, 0, 99)
	h.expect(a < b and b < c, "sorts by rating, then wins")
	h.expect(Rankings.storeName(2, "1v1") == "SkybrawlRanked_v1_S2_1v1", Rankings.storeName(2, "1v1"))
	expectEqual(Rankings.MODES, { "1v1", "2v2" }, "MODES")
end)

h.test("Rankings legend codes never change", function()
	expectEqual(
		Rankings.LEGEND_CODES,
		{ Kestrel = 1, Brann = 2, Yuki = 3, Moss = 4, Vex = 5, Sol = 6, Avatar = 7 },
		"LEGEND_CODES"
	)
	for _, id in Legends.Order do
		h.expect(Rankings.LEGEND_CODES[id], id .. " has no code (append one, never renumber)")
	end
end)

h.test("Rankings.tierProgress reports the next tier and the distance", function()
	local p = Rankings.tierProgress(1000)
	h.expect(p.tier.Name == "Bronze" and p.next.Name == "Silver", "tiers")
	h.near(p.fraction, (1000 - 910) / (1130 - 910), 1e-9, "fraction")
	h.expect(p.toNext == 130, "toNext " .. tostring(p.toNext))
	p = Rankings.tierProgress(0)
	h.expect(p.tier.Name == "Tin" and p.fraction == 0 and p.toNext == 910, "bottom")
	p = Rankings.tierProgress(2100)
	h.expect(p.tier.Name == "Diamond" and p.next == nil and p.fraction == 1 and p.toNext == nil, "top")
end)

h.test("Rankings.bestLegend picks the most ranked wins", function()
	local id, wins, played = Rankings.bestLegend({
		Vex = { Wins = 3, Played = 5 },
		Sol = { Wins = 4, Played = 9 },
		Moss = { Wins = 4, Played = 6 },
		Yuki = { Wins = 0, Played = 0 },
	})
	h.expect(id == "Sol" and wins == 4 and played == 9, "best " .. tostring(id))
	id, wins, played = Rankings.bestLegend({ Vex = { Wins = 0, Played = 2 } })
	h.expect(id == "Vex" and wins == 0 and played == 2, "no wins yet")
	-- most wins beats most played; equal wins: more played, then the id
	id, wins, played = Rankings.bestLegend({ Vex = { Wins = 3, Played = 20 }, Sol = { Wins = 4, Played = 5 } })
	h.expect(id == "Sol" and wins == 4 and played == 5, "most played beat most wins: " .. tostring(id))
	id = Rankings.bestLegend({ Vex = { Wins = 4, Played = 9 }, Sol = { Wins = 4, Played = 6 } })
	h.expect(id == "Vex", "equal wins: more played wins, got " .. tostring(id))
	id = Rankings.bestLegend({ Vex = { Wins = 4, Played = 6 }, Sol = { Wins = 4, Played = 6 } })
	h.expect(id == "Sol", "a full tie goes by id, got " .. tostring(id))
	id = Rankings.bestLegend({})
	h.expect(id == nil, "nothing played")
	h.expect(Rankings.bestLegend(nil) == nil, "nil")
	h.expect(Rankings.winRate(3, 1) == 75 and Rankings.winRate(1, 2) == 33, "winRate")
	h.expect(Rankings.winRate(0, 0) == nil, "winRate with no games")
end)

print("Profiles")

h.test("DataService.migrateProfile upgrades a version 1 profile without a season reset", function()
	local stored = {
		Version = 1,
		Coins = 50,
		XP = 10,
		Rating1v1 = 1500,
		Peak1v1 = 1600,
		Rating2v2 = 900,
		Legend = "Vex",
		Settings = { SfxVolume = 0.3 },
	}
	local profile, notes = DataService.prepareProfile(stored, 42, NOW)
	h.expect(profile.Version == 2 and profile.Season == 1, "version / season")
	h.expect(profile.Rating1v1 == 1500 and profile.Peak1v1 == 1600 and profile.Rating2v2 == 900, "ratings reset")
	h.expect(profile.SeasonBadge == nil, "a badge out of nowhere")
	h.expect(profile.Coins == 50 and profile.XP == 10 and profile.Legend == "Vex", "kept fields")
	h.expect(#notes == 0, "notes: " .. table.concat(notes, " | "))
	h.expect(profile.Missions.Day == TODAY and #profile.Missions.List == 3, "today's missions")
	h.expect(profile.SeasonStats["1v1"].Wins == 0 and profile.SeasonStats["2v2"].Losses == 0, "season stats")
	-- a v1 profile loading in season 2 joins it directly: no reset for a season it never had
	local late = DataService.prepareProfile({ Version = 1, Rating1v1 = 1500 }, 42, S1_END + DAY)
	h.expect(late.Season == 2 and late.Rating1v1 == 1500, "a v1 profile was soft-reset")
	-- a new player
	local fresh, freshNotes = DataService.prepareProfile(nil, 7, NOW)
	h.expect(fresh.Version == 2 and fresh.Season == 1 and #fresh.Missions.List == 3 and #freshNotes == 0, "new")
	local again, againNotes = DataService.migrateProfile(fresh, 7, NOW)
	h.expect(again == fresh and #againNotes == 0, "migrating twice changed something")
end)

h.test("DataService.migrateProfile rolls today's missions and pays yesterday's unclaimed ones", function()
	local stored = {
		Version = 2,
		Season = 1,
		Coins = 100,
		XP = 0,
		Missions = {
			Day = TODAY - 1,
			Rerolled = true,
			Seq = 3,
			List = {
				entry("KOs", 8, 8, { coins = 70, xp = 90 }),
				entry("Damage", 2000, 2000, { claimed = true }),
				entry("TrueCombos", 5, 1),
			},
		},
	}
	local profile, notes = DataService.prepareProfile(stored, 42, NOW)
	h.expect(profile.Coins == 170 and profile.XP == 90, "paid " .. profile.Coins .. " / " .. profile.XP)
	expectEqual(notes, { "Mission rewards collected: +70 coins, +90 XP" }, "notes")
	local m = profile.Missions
	h.expect(m.Day == TODAY and m.Rerolled == false and #m.List == 3, "today's list")
	for _, e in m.List do
		h.expect(e.Progress == 0 and not e.Claimed, "a new mission isn't fresh")
	end
	local _, notes2 = DataService.migrateProfile(profile, 42, NOW)
	h.expect(#notes2 == 0 and profile.Coins == 170, "paid twice")
end)

h.test("DataService.migrateProfile soft-resets a profile from an ended season", function()
	local stored = seasonProfile(1, { Version = 2 })
	local profile, notes = DataService.prepareProfile(stored, 42, S1_END + DAY)
	h.expect(profile.Season == 2 and profile.Rating1v1 == 1225, "no reset")
	h.expect(profile.SeasonBadge.Season == 1 and profile.SeasonBadge.Tier2v2 == "Silver", "badge")
	expectEqual(notes, { "Season 2 has begun! Your ratings were soft-reset." }, "notes")
	local junk = DataService.prepareProfile({ Version = 2, Season = -4, SeasonBadge = { Season = "1" } }, 1, NOW)
	h.expect(junk.Season == 1 and junk.SeasonBadge == nil, "junk season fields")
end)

h.test("DataService.sanitizeSeasonStats drops bad legends and numbers", function()
	local stats = DataService.sanitizeSeasonStats({
		["1v1"] = {
			Wins = 5.7,
			Losses = -3,
			Legends = {
				Vex = { Wins = 9, Played = 4 },
				Bogus = { Wins = 1, Played = 1 },
				Sol = "junk",
				Moss = { Wins = 0 / 0, Played = 1e9 },
			},
		},
		["2v2"] = "junk",
		["3v3"] = { Wins = 4 },
	})
	expectEqual(stats, {
		["1v1"] = {
			Wins = 5,
			Losses = 0,
			Legends = { Vex = { Wins = 4, Played = 4 }, Moss = { Wins = 0, Played = 1e7 } },
		},
		["2v2"] = { Wins = 0, Losses = 0, Legends = {} },
	}, "sanitized")
	expectEqual(DataService.sanitizeSeasonStats(nil), {
		["1v1"] = { Wins = 0, Losses = 0, Legends = {} },
		["2v2"] = { Wins = 0, Losses = 0, Legends = {} },
	}, "nil")
end)

h.test("DataService.buildSnapshot includes missions, season and season stats", function()
	local profile = DataService.prepareProfile({ Coins = 5, XP = 500 }, 42, NOW)
	profile.SeasonStats["1v1"] = { Wins = 4, Losses = 2, Legends = { Vex = { Wins = 3, Played = 4 } } }
	profile.SeasonBadge = { Season = 0, Name = "Beta", Tier1v1 = "Gold" }
	profile.Missions.List[1].Progress = profile.Missions.List[1].Goal
	local snap = DataService.buildSnapshot(profile, true, NOW)
	h.expect(snap.Coins == 5 and snap.Level > 1 and snap.Tier1v1 == "Bronze" and snap.Saving == true, "old fields")
	local m = snap.Missions
	h.expect(m.day == TODAY and m.resetAt == (TODAY + 1) * DAY, "missions day / reset")
	h.expect(m.rerollAvailable == true and m.claimable == 1 and #m.list == 3, "missions summary")
	local row = m.list[1]
	h.expect(row.index == 1 and row.done and not row.claimed and type(row.text) == "string", "mission row")
	h.expect(row.id == profile.Missions.List[1].Id and row.coins > 0 and row.xp > 0, "mission row rewards")
	expectEqual(snap.Season, { id = 1, name = "Season 1", endsAt = S1_END }, "season")
	expectEqual(snap.SeasonBadge, { season = 0, name = "Beta", tier1v1 = "Gold" }, "badge")
	expectEqual(snap.SeasonStats["1v1"], {
		wins = 4,
		losses = 2,
		bestLegend = { id = "Vex", wins = 3, played = 4 },
	}, "1v1 season stats")
	expectEqual(snap.SeasonStats["2v2"], { wins = 0, losses = 0 }, "2v2 season stats")
	h.expect(DataService.buildSnapshot(profile, false, NOW).Saving == false, "Saving flag")
	profile.SeasonBadge = nil
	h.expect(DataService.buildSnapshot(profile, true, NOW).SeasonBadge == nil, "no badge")
end)

h.test("sanitizeSettings keeps MusicVolume as a number", function()
	h.expect(DataService.sanitizeSettings({ MusicVolume = 0.25 }).MusicVolume == 0.25, "lost MusicVolume")
	h.expect(DataService.sanitizeSettings({ MusicVolume = 0 }).MusicVolume == 0, "lost a muted MusicVolume")
	for _, junk in { "loud", true, {}, 0 / 0, 5000 } do
		h.expect(DataService.sanitizeSettings({ MusicVolume = junk }).MusicVolume == nil, "kept " .. tostring(junk))
	end
end)

h.test("a stored profile that can't be prepared loads on defaults and is never saved", function()
	h.resetRemotes()
	local game = h.fakeGame()
	-- yesterday's done mission gets paid into a corrupt Coins value: prepareProfile throws
	local stored = {
		Version = 2,
		Season = 1,
		Coins = "lots",
		Missions = { Day = Missions.dayIndex(os.time()) - 1, Rerolled = false, Seq = 1, List = { entry("KOs", 8, 8) } },
	}
	local writes = 0
	local store = {}
	function store.UpdateAsync(_, _key, fn)
		local result = fn(stored)
		if result ~= nil then
			stored = result
			writes += 1
		end
		return result
	end
	game:GetService("DataStoreService").GetDataStore = function()
		return store
	end
	local warnings = {}
	local Service = h.requireServer("DataService", {
		game = game,
		warn = function(...)
			table.insert(warnings, table.concat({ ... }, " "))
		end,
		-- the autosave loop parks instead of keeping Lune alive
		task = setmetatable({
			wait = function()
				coroutine.yield()
			end,
		}, { __index = require("@lune/task") }),
	})
	Service.start()
	local player = h.fakePlayer(21, "Corrupt")
	game:GetService("Players"):_add(player)
	local profile = Service.get(player)
	h.expect(profile and type(profile.Coins) == "number" and profile.Coins == 0, "no default profile")
	h.expect(#profile.Missions.List == Config.Missions.PerDay, "the default profile has no missions")
	h.expect(not Service.snapshot(player).Saving, "a profile that can't be read is saved over")
	h.expect(stored.Coins == "lots" and writes == 1, "the stored profile was overwritten")
	h.expect(string.find(table.concat(warnings, "\n"), "couldn't prepare Corrupt's profile", 1, true), "no warning")
	local toasted = false
	for _, call in h.remote("Toast").calls do
		toasted = toasted or call.player == player and string.find(call.args[1], "can't be saved", 1, true) ~= nil
	end
	h.expect(toasted, "no can't-save toast")
end)

print("Client state and harness")

h.test("the harness workspace answers GetServerTimeNow as a method", function()
	local t = h.workspace:GetServerTimeNow()
	h.expect(type(t) == "number" and math.abs(t - os.time()) <= 1, "workspace:GetServerTimeNow()")
	local ClientState = h.requireClientFile("ClientState")
	h.expect(math.abs(ClientState.serverNow() - os.time()) <= 1, "ClientState.serverNow()")
	local fixed = h.requireClientFile("ClientState", {
		workspace = {
			GetServerTimeNow = function()
				return 1234
			end,
		},
	})
	h.expect(fixed.serverNow() == 1234, "a test's own workspace")
end)

h.test("the harness resolves sibling services, fake shared modules and fake players", function()
	local MatchService = h.requireServer("MatchService")
	h.expect(type(MatchService.startMatch) == "function", "MatchService didn't load with its sibling Match")
	local remote = {}
	local fakeNet = {
		get = function()
			return remote
		end,
	}
	local game = h.fakeGame({ shared = { Net = fakeNet } })
	local PartyService = h.requireServer("PartyService", { game = game })
	PartyService.start()
	h.expect(type(remote.OnServerInvoke) == "function", "the fake Net wasn't handed out")
	local players = game:GetService("Players")
	h.expect(players == game:GetService("Players"), "one stub per service")
	local joined, left = {}, {}
	players.PlayerAdded:Connect(function(player)
		table.insert(joined, player.Name)
	end)
	players.PlayerRemoving:Connect(function(player)
		table.insert(left, player.Name)
	end)
	local kim = h.fakePlayer(7, "Kim")
	h.expect(kim.Parent == h.game:GetService("Players"), "a fake player isn't on the server")
	h.expect(#h.game:GetService("Players"):GetPlayers() == 0, "a fake player joined h.game's list by itself")
	players:_add(kim)
	h.expect(joined[1] == "Kim" and #players:GetPlayers() == 1 and kim.Parent == players, "PlayerAdded")
	players:_remove(kim)
	h.expect(left[1] == "Kim" and #players:GetPlayers() == 0 and kim.Parent == nil, "PlayerRemoving")
	h.expect(kim.DisplayName == "Kim" and kim.UserId == 7 and not kim:IsFriendsWith(8), "fake player")
	kim._friends[8] = true
	h.expect(kim:IsFriendsWith(8), "IsFriendsWith")
	h.expect(game:GetService("RunService").Heartbeat ~= nil, "Heartbeat")
	h.expect(game:GetService("Players").LocalPlayer.Parent == players, "LocalPlayer")
end)

h.test("h.Random is deterministic per seed and nearby seeds start differently", function()
	local a, b = h.Random.new(42), h.Random.new(42)
	for _ = 1, 10 do
		h.expect(a:NextInteger(1, 1000) == b:NextInteger(1, 1000), "same seed, different draws")
	end
	local firsts, seen = {}, 0
	for seed = 1, 20 do
		local value = h.Random.new(seed):NextInteger(1, 6)
		h.expect(value >= 1 and value <= 6, "NextInteger out of range: " .. value)
		if not firsts[value] then
			firsts[value] = true
			seen += 1
		end
	end
	h.expect(seen >= 4, "seeds 1..20 start on " .. seen .. " different values of 6")
	local x = h.Random.new():NextNumber()
	h.expect(x >= 0 and x < 1 and x == h.Random.new(12345):NextNumber(), "the default seed")
	for seed = -3, 3 do
		local n = h.Random.new(seed):NextNumber(2, 3)
		h.expect(n >= 2 and n <= 3, "NextNumber out of range for seed " .. seed)
	end
end)

h.test('server stubs answer "Not ready." until their track lands', function()
	h.resetRemotes()
	local player = h.fakePlayer(3, "Ann")
	for service, remote in { TrainingService = "TrainingRequest", MissionService = "MissionRequest" } do
		h.requireServer(service).start()
		local ok, message = h.remote(remote).OnServerInvoke(player, "Start", {})
		h.expect(ok == false and message == "Not ready.", service)
	end
	local PartyService = h.requireServer("PartyService")
	PartyService.start()
	local ok, list = h.remote("PartyRequest").OnServerInvoke(player, "List")
	h.expect(ok and #list.players == 0, "PartyRequest List")
	h.expect(PartyService.isLeader(player) and PartyService.membersOf(player)[1] == player, "solo party")
	local SelectService = h.requireServer("SelectService")
	local session, err = SelectService.begin({})
	h.expect(session == nil and err == "Not ready." and SelectService.getSessionOf(player) == nil, "SelectService")
	local MissionService = h.requireServer("MissionService")
	h.expect(MissionService.onMatch({}, {}, {}) == nil, "MissionService.onMatch")
	MissionService.init({})
	local rankingsOk, rankingsMessage = h.remote("GetRankings").OnServerInvoke(player, { mode = "1v1" })
	h.expect(rankingsOk == false and rankingsMessage == "Not ready.", "GetRankings")
	local FriendCache = h.requireServer("FriendCache")
	player._friends[9] = true
	h.expect(FriendCache.isFriend(player, 9) and not FriendCache.isFriend(player, 10), "FriendCache.isFriend")
	h.expect(#FriendCache.friendIds(player) == 0, "FriendCache.friendIds")
end)

h.test("ClientState stores party, queue stats and the select session, and ignores stale Cancels", function()
	h.resetRemotes()
	local ClientState = h.requireClientFile("ClientState")
	ClientState.init()
	h.expect(ClientState.OpenPanel == ClientState.OpenScreen, "OpenPanel isn't the OpenScreen signal")
	local relayed = {}
	local previous = {}
	ClientState.SelectEvent:Connect(function(kind, data, previousSelect, previousVs)
		table.insert(relayed, kind .. ":" .. tostring(data.id))
		table.insert(previous, { select = previousSelect and previousSelect.id, vs = previousVs and previousVs.id })
	end)
	local partyEvents = {}
	ClientState.PartyChanged:Connect(function(party, invites)
		table.insert(partyEvents, { party, invites })
	end)
	h.remote("PartyUpdate").OnClientEvent:Fire({ party = { id = 4 }, invites = { { partyId = 9 } } })
	h.expect(ClientState.party.id == 4 and #ClientState.invites == 1, "party")
	h.expect(#partyEvents == 1 and partyEvents[1][1].id == 4 and #partyEvents[1][2] == 1, "PartyChanged")
	h.remote("QueueStats").OnClientEvent:Fire({ Ranked1v1 = 2, Ranked2v2 = 0, FFA = 5 })
	h.expect(ClientState.queueStats.FFA == 5, "queue stats")

	local select = h.remote("SelectEvent").OnClientEvent
	select:Fire("Begin", { id = 5, phase = "Pick" })
	select:Fire("Update", { id = 5, phase = "Pick", n = 2 })
	h.expect(ClientState.select.n == 2, "Update didn't refresh the session")
	select:Fire("Update", { id = 4 })
	h.expect(ClientState.select.id == 5, "an Update of another session replaced yours")
	select:Fire("Cancel", { id = 3, reason = "old" })
	h.expect(ClientState.select and ClientState.select.id == 5, "a stale Cancel cleared the session")
	select:Fire("Vs", { id = 5, matchId = 11 })
	h.expect(ClientState.vs.matchId == 11, "vs")
	select:Fire("Cancel", { id = 5, reason = "left" })
	h.expect(ClientState.select == nil and ClientState.vs == nil, "a matching Cancel kept the session")
	expectEqual(relayed, { "Begin:5", "Update:5", "Update:4", "Cancel:3", "Vs:5", "Cancel:5" }, "relayed events")
	-- listeners get select and vs as they were before each event (a matching Cancel has already cleared them)
	h.expect(previous[1].select == nil and previous[2].select == 5, "previous select")
	h.expect(previous[5].select == 5 and previous[5].vs == nil, "previous state of the Vs")
	h.expect(previous[6].select == 5 and previous[6].vs == 5, "previous state of the matching Cancel")
end)

h.test("UIKit.assetId turns ids into asset URLs and junk into empty strings", function()
	local UIKit = h.requireClientFile("UI/UIKit")
	for _, case in
		{
			{ 123, "rbxassetid://123" },
			{ "123", "rbxassetid://123" },
			{ " 77 ", "rbxassetid://77" },
			{ "rbxassetid://9", "rbxassetid://9" },
			{ "", "" },
			{ 1.5, "" },
			{ math.huge, "" },
			{ 0 / 0, "" },
			{ -4, "" },
			{ 2 ^ 60, "" },
			{ {}, "" },
		}
	do
		local got = UIKit.assetId(case[1])
		h.expect(got == case[2], string.format("assetId(%s) = %q", tostring(case[1]), got))
	end
end)

h.test("ClientState.setPhase fires PhaseChanged once and clears vs when leaving Vs", function()
	local ClientState = h.requireClientFile("ClientState")
	h.expect(ClientState.phase == "Title", "starts on the title")
	local changes = {}
	ClientState.PhaseChanged:Connect(function(phase, previous)
		table.insert(changes, previous .. ">" .. phase)
	end)
	ClientState.setPhase("Menu")
	ClientState.setPhase("Menu")
	ClientState.setPhase("Vs")
	ClientState.vs = { id = 1 }
	ClientState.setPhase("Match")
	h.expect(ClientState.vs == nil, "vs kept after the VS splash")
	expectEqual(changes, { "Title>Menu", "Menu>Vs", "Vs>Match" }, "PhaseChanged")
end)

h.finish()
