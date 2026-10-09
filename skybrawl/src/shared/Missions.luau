--[[
    Daily missions (Config.Missions): three a UTC day, one free reroll, a
    CLAIM that pays coins and XP.

    The state lives in the profile (profile.Missions):
      { Day, Rerolled, Seq, List = { MissionEntry } }
      MissionEntry = { Id = templateId, Param = weapon/legend?, Goal, Progress, Claimed, Coins, XP }
    Missions are generated deterministically from (day, userId, seq), so a
    day's missions are the same on every server. Seq counts the missions
    generated that day (rerolls and refills use the next one).

    A new day first pays the old list's done-but-unclaimed missions (they
    are never lost; ensureDay returns what it paid and the caller adds it
    to the profile and toasts it), then rolls PerDay new ones. Days only
    move forward: a day older than the state's (a server whose clock runs
    behind) counts as the same day, so a rollover check must use
    Missions.isNewDay(state, day), never `state.Day ~= day`.

    The free reroll is one a day (the state keeps one Rerolled flag);
    Config.Missions.FreeRerolls = 0 turns it off.

    Progress comes from match stats (statsFromEntry): only eligible matches
    count (see Config.Missions): never training, never bots matches with an
    Easy bot, never custom rooms with boosted damage; damage from bots and
    custom rooms counts at half. Count stats (matches, wins, KOs, true
    combos) count whole, so "Win as Vex" can be done against bots.

    Pure: day, userId and stats are passed in; Random is seeded from them.
]]

local Config = require(script.Parent.Config)
local Legends = require(script.Parent.Legends)
local Select = require(script.Parent.Select)
local Util = require(script.Parent.Util)
local Weapons = require(script.Parent.Weapons)

local Missions = {}

Missions.DAY = 86400

local WEAPON_PHRASES = {
	Sword = "a Sword",
	Hammer = "a Hammer",
	Spear = "a Spear",
	Gauntlets = "Gauntlets",
	Scythe = "a Scythe",
	Bow = "a Bow",
}

local MAX_REWARD = 1e6

local function templateOf(id)
	for _, template in Config.Missions.Templates do
		if template.Id == id then
			return template
		end
	end
	return nil
end

local function validParam(template, param)
	if template.Param == "Weapon" then
		return table.find(Weapons.Order, param) ~= nil
	elseif template.Param == "Legend" then
		return table.find(Select.roster(), param) ~= nil
	end
	return param == nil
end

local function round5(x)
	return math.floor(x / 5 + 0.5) * 5
end

-- Rewards are set for Goals[1]; a bigger goal scales them.
local function rewardsFor(template, goal)
	local scale = goal / template.Goals[1]
	return round5(template.Coins * scale), round5(template.XP * scale)
end

local function isDone(entry)
	return entry.Progress >= entry.Goal
end

-- The UTC day number of a unix time.
function Missions.dayIndex(unixTime)
	return math.floor(unixTime / Missions.DAY)
end

-- Unix time of the midnight that ends `day`.
function Missions.resetAt(day)
	return (day + 1) * Missions.DAY
end

function Missions.newState()
	return { Day = 0, Rerolled = false, Seq = 0, List = {} }
end

--[[
    The seq-th mission of `day` for `userId`: a template not in `exclude`
    (a set of template ids; ignored if it would exclude all of them), its
    Param and a goal. Same inputs, same mission.
]]
function Missions.generate(day, userId, seq, exclude)
	-- (Studio test players have negative user ids)
	local mixed = math.floor(day) * 1000003 + math.abs(math.floor(userId)) * 7919 + math.floor(seq) * 104729
	local rng = Random.new(mixed % 2147483646 + 1)
	local pool = {}
	for _, template in Config.Missions.Templates do
		if not (exclude and exclude[template.Id]) then
			table.insert(pool, template)
		end
	end
	if #pool == 0 then
		pool = Config.Missions.Templates
	end
	local template = pool[rng:NextInteger(1, #pool)]
	local param = nil
	if template.Param == "Weapon" then
		param = Weapons.Order[rng:NextInteger(1, #Weapons.Order)]
	elseif template.Param == "Legend" then
		local roster = Select.roster()
		param = roster[rng:NextInteger(1, #roster)]
	end
	local goal = template.Goals[rng:NextInteger(1, #template.Goals)]
	local coins, xp = rewardsFor(template, goal)
	return {
		Id = template.Id,
		Param = param,
		Goal = goal,
		Progress = 0,
		Claimed = false,
		Coins = coins,
		XP = xp,
	}
end

local function currentIds(state)
	local ids = {}
	for _, entry in state.List do
		ids[entry.Id] = true
	end
	return ids
end

-- Whether `day` is past the state's day, i.e. whether ensureDay would start a new day (and pay the old one).
function Missions.isNewDay(state, day)
	return day > state.Day
end

-- Whether today's free reroll is still available.
function Missions.canReroll(state)
	return not state.Rerolled and Config.Missions.FreeRerolls >= 1
end

--[[
    Brings the state up to `day`. A new day first collects the old list's
    done-but-unclaimed missions (marks them Claimed, sums their rewards into
    `paid`), then rolls PerDay different missions (seq 1..PerDay) with a
    fresh reroll. The same day with fewer than PerDay missions fills the gaps
    (Seq + 1 each). A day older than the state's (another server's clock
    running behind) counts as the same day.
    Returns changed, paid = { coins, xp, count }? (nil when nothing was
    collected). The caller adds paid.coins/xp to the profile and toasts
    "Mission rewards collected: +<coins> coins, +<xp> XP".
]]
function Missions.ensureDay(state, day, userId)
	local changed = false
	local paid = nil
	if Missions.isNewDay(state, day) then
		local coins, xp, count = 0, 0, 0
		for _, entry in state.List do
			if not entry.Claimed and isDone(entry) then
				entry.Claimed = true
				coins += entry.Coins
				xp += entry.XP
				count += 1
			end
		end
		if count > 0 then
			paid = { coins = coins, xp = xp, count = count }
		end
		state.Day = day
		state.List = {}
		state.Seq = 0
		state.Rerolled = false
		changed = true
	end
	while #state.List < Config.Missions.PerDay do
		state.Seq += 1
		table.insert(state.List, Missions.generate(state.Day, userId, state.Seq, currentIds(state)))
		changed = true
	end
	return changed, paid
end

-- The day's free reroll: replaces an unfinished, unclaimed mission with one whose template isn't on the list.
function Missions.reroll(state, index, day, userId)
	local entry = state.List[index]
	if type(index) ~= "number" or not entry then
		return false, "Unknown mission."
	end
	if entry.Claimed or isDone(entry) then
		return false, "That mission is already done."
	end
	if not Missions.canReroll(state) then
		return false, "No free rerolls left today."
	end
	state.Seq += 1
	state.List[index] = Missions.generate(day, userId, state.Seq, currentIds(state))
	state.Rerolled = true
	return true, nil
end

-- The stat a mission counts: its template's Stat, plus ":<Param>" when it has one.
function Missions.statKey(entry)
	local template = templateOf(entry.Id)
	local stat = template and template.Stat or entry.Id
	if entry.Param ~= nil then
		return stat .. ":" .. tostring(entry.Param)
	end
	return stat
end

local function number(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return 0
	end
	return value
end

local function eligible(info)
	local M = Config.Missions
	if info.training or M.Sources[info.source] == nil then
		return false
	end
	if info.minBotDifficulty ~= nil then
		local order = Config.Bots.DifficultyOrder
		local have = table.find(order, info.minBotDifficulty)
		if not have or have < (table.find(order, M.MinBotDifficulty) or 1) then
			return false
		end
	end
	if info.source == "Custom" and (info.damageMultiplier or 1) ~= 1 then
		return false
	end
	return true
end

--[[
    The stats one player's match produced (MatchInfo `info`, MatchEntry
    `entry`), keyed like Missions.statKey: Matches, Wins, KOs, Damage,
    TrueCombos, OnlineMatches, OnlineWins (Ranked or Casual), RankedWins,
    ModeKOs:<mode> (online only), LegendMatches:<legend>,
    LegendWins:<legend>, WeaponDamage:<weapon>. Only positive values are
    listed; an ineligible match gives {}.
]]
function Missions.statsFromEntry(info, entry)
	if not eligible(info) then
		return {}
	end
	local factor = Config.Missions.Sources[info.source]
	local stats = {}
	local function add(key, value)
		if value > 0 then
			stats[key] = (stats[key] or 0) + value
		end
	end
	local won = entry.won == true
	local kos = math.floor(number(entry.kos))
	local legend = entry.legend or "Avatar"
	local online = info.source == "Ranked" or info.source == "Casual"
	add("Matches", 1)
	add("Wins", won and 1 or 0)
	add("KOs", kos)
	add("Damage", math.floor(number(entry.damageDealt) * factor))
	add("TrueCombos", math.floor(number(entry.trueCombos)))
	if online then
		add("OnlineMatches", 1)
		add("OnlineWins", won and 1 or 0)
		-- online Free-for-all is the casual queue
		if info.mode ~= "FFA" or info.source == "Casual" then
			add("ModeKOs:" .. tostring(info.mode), kos)
		end
	end
	if info.source == "Ranked" then
		add("RankedWins", won and 1 or 0)
	end
	add("LegendMatches:" .. legend, 1)
	add("LegendWins:" .. legend, won and 1 or 0)
	for weapon, damage in entry.weaponDamage or {} do
		add("WeaponDamage:" .. tostring(weapon), math.floor(number(damage) * factor))
	end
	return stats
end

-- Adds stats to the unfinished missions (capped at their goal). Returns the missions that moved:
-- { { index, progress, goal, done, justDone } } (justDone only on the update that finished it).
function Missions.applyStats(state, stats)
	local moved = {}
	for index, entry in state.List do
		if not entry.Claimed and not isDone(entry) then
			local amount = stats[Missions.statKey(entry)]
			if type(amount) == "number" and amount > 0 then
				entry.Progress = math.min(entry.Goal, entry.Progress + math.floor(amount))
				local done = isDone(entry)
				table.insert(moved, {
					index = index,
					progress = entry.Progress,
					goal = entry.Goal,
					done = done,
					justDone = done,
				})
			end
		end
	end
	return moved
end

-- Pays a finished mission once: true, coins, xp | false, reason.
function Missions.claim(state, index)
	local entry = type(index) == "number" and state.List[index]
	if not entry then
		return false, "Unknown mission."
	end
	if entry.Claimed then
		return false, "Already claimed."
	end
	if not isDone(entry) then
		return false, "That mission isn't done yet."
	end
	entry.Claimed = true
	return true, entry.Coins, entry.XP
end

--[[
    "Deal 1,500 damage with a Sword", "Win as Vex", "Win 1 ranked match".
    short: the template's Short form for narrow panels ("1,500 Sword dmg",
    with the weapon's bare name), else its Text.
]]
function Missions.describe(entry, short)
	local template = templateOf(entry.Id)
	if not template then
		return "Unknown mission"
	end
	local useShort = short == true and type(template.Short) == "string"
	local param = ""
	if template.Param == "Weapon" then
		if useShort and Weapons.isWeapon(entry.Param) then
			param = Weapons.get(entry.Param).Name
		else
			param = WEAPON_PHRASES[entry.Param] or tostring(entry.Param)
		end
	elseif template.Param == "Legend" then
		param = Legends.get(entry.Param).Name
	end
	local goal = Util.formatNumber(entry.Goal)
	local plural = entry.Goal ~= 1
	local text = string.gsub(if useShort then template.Short else template.Text, "{goal}", function()
		return goal
	end)
	text = string.gsub(text, "{param}", function()
		return param
	end)
	-- plural endings: "match{es}", "KO{s}"
	text = string.gsub(text, "{(e?s)}", function(ending)
		return if plural then ending else ""
	end)
	return text
end

local function wholeIn(value, min, max)
	if type(value) ~= "number" or value ~= value then
		return nil
	end
	return math.clamp(math.floor(value), min, max)
end

local function sanitizeEntry(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local template = templateOf(raw.Id)
	if not template then
		return nil
	end
	local param = if template.Param then raw.Param else nil
	if not validParam(template, param) then
		return nil
	end
	local goals = template.Goals
	local goal = wholeIn(raw.Goal, goals[1], goals[#goals])
	if not goal then
		return nil
	end
	local coins, xp = rewardsFor(template, goal)
	return {
		Id = template.Id,
		Param = param,
		Goal = goal,
		Progress = wholeIn(raw.Progress, 0, goal) or 0,
		Claimed = raw.Claimed == true,
		Coins = wholeIn(raw.Coins, 0, MAX_REWARD) or coins,
		XP = wholeIn(raw.XP, 0, MAX_REWARD) or xp,
	}
end

-- A valid MissionState from whatever was saved: unknown templates, bad params, duplicate templates and extra
-- entries are dropped; numbers are made whole and clamped.
function Missions.sanitize(raw)
	local state = Missions.newState()
	if type(raw) ~= "table" then
		return state
	end
	state.Day = wholeIn(raw.Day, 0, math.huge) or 0
	state.Seq = wholeIn(raw.Seq, 0, math.huge) or 0
	state.Rerolled = raw.Rerolled == true
	local seen = {}
	if type(raw.List) == "table" then
		for _, rawEntry in ipairs(raw.List) do
			local entry = sanitizeEntry(rawEntry)
			if entry and not seen[entry.Id] and #state.List < Config.Missions.PerDay then
				seen[entry.Id] = true
				table.insert(state.List, entry)
			end
		end
	end
	return state
end

-- The snapshot table the client gets (profile snapshot "Missions").
function Missions.view(state, now)
	local list, claimable = {}, 0
	for index, entry in state.List do
		local done = isDone(entry)
		if done and not entry.Claimed then
			claimable += 1
		end
		table.insert(list, {
			index = index,
			id = entry.Id,
			text = Missions.describe(entry),
			short = Missions.describe(entry, true),
			progress = entry.Progress,
			goal = entry.Goal,
			coins = entry.Coins,
			xp = entry.XP,
			done = done,
			claimed = entry.Claimed,
		})
	end
	return {
		day = state.Day,
		resetAt = Missions.resetAt(Missions.dayIndex(now)),
		rerollAvailable = Missions.canReroll(state),
		claimable = claimable,
		list = list,
	}
end

return Missions
