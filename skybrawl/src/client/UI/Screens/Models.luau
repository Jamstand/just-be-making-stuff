--[[
    Pure view logic for the menu screens (menus design 5.8): what the Online
    Play cards and hints, the Practice bot options, the Rankings pages and
    rank card, the missions reset line and hints, the Invite rows, the
    Profile season badge and the Store cards show,
    decided from plain data (snapshots and server payloads) so it can be
    tested under Lune (tests/screens.luau).

    Requires only Shared modules, through ReplicatedStorage.Shared (the
    harness can't resolve script.Parent.Parent). No instances, no clocks:
    `now` is passed in.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Legends = require(Shared.Legends)
local Maps = require(Shared.Maps)
local Missions = require(Shared.Missions)
local Party = require(Shared.Party)
local Rankings = require(Shared.Rankings)
local Ranks = require(Shared.Ranks)
local Util = require(Shared.Util)

local Models = {}

local DAY = 86400

-- Party -------------------------------------------------------------------------

-- Your party size and whether you lead it (solo: 1, true).
function Models.partyInfo(party, userId)
	if type(party) ~= "table" or type(party.members) ~= "table" or #party.members == 0 then
		return 1, true
	end
	return #party.members, party.leaderUserId == userId
end

-- Online Play -------------------------------------------------------------------

Models.ONLINE = {
	{
		queueType = "Ranked1v1",
		mode = "1v1",
		ranked = true,
		name = "1V1",
		rules = "3 stocks, solo only, matched by your 1v1 rating.",
	},
	{
		queueType = "Ranked2v2",
		mode = "2v2",
		ranked = true,
		name = "2V2",
		rules = "Team up with your party member or another solo player. Both of you gain or lose 2v2 rating.",
	},
	{
		queueType = "FFA",
		mode = "FFA",
		ranked = false,
		name = "FREE-FOR-ALL",
		rules = "Four fighters, every one for themselves. Bots fill empty spots after 20 s.",
	},
}

--[[
    One Online Play card. state = { party, userId, queue (QueueStatus?),
    profile (snapshot?), stats (QueueStats?) }. Returns
      { queueType, mode, ranked, tag, name, rules, maps ("6 MAPS"),
        party ("SOLO ONLY" | "PARTY UP TO n"), partyFits (in a party that fits),
        queued, action ("FIND MATCH" | "CANCEL SEARCH"),
        locked, lockTitle ("SOLO ONLY" | "LEADER QUEUES" | "UP TO n PLAYERS"), lockReason,
        searching ("<n> searching"), rating?, tier? }
    The queue you are in is never locked (any member may cancel the search).
]]
function Models.onlineCard(info, state)
	local size, leader = Models.partyInfo(state.party, state.userId)
	local _, max = Party.limits(info.queueType)
	local queued = type(state.queue) == "table" and state.queue.queue == info.queueType
	local ok, code, reason = Party.canStart(info.queueType, nil, size, leader)
	local locked = not ok and not queued
	local lockTitle = nil
	if locked then
		if code == "NotLeader" then
			lockTitle = "LEADER QUEUES"
		elseif max == 1 then
			lockTitle = "SOLO ONLY"
		else
			lockTitle = "UP TO " .. max .. " PLAYERS"
		end
	end
	local pool = Config.Queue.MapPools[info.mode] or Maps.Order
	local stats = type(state.stats) == "table" and state.stats or {}
	local card = {
		queueType = info.queueType,
		mode = info.mode,
		ranked = info.ranked,
		tag = info.ranked and "RANKED" or "CASUAL",
		name = info.name,
		rules = info.rules,
		maps = #pool .. " MAPS",
		party = if max == 1 then "SOLO ONLY" else "PARTY UP TO " .. max,
		partyFits = size > 1 and size <= max,
		queued = queued,
		action = queued and "CANCEL SEARCH" or "FIND MATCH",
		locked = locked,
		lockTitle = lockTitle,
		lockReason = if locked then reason else nil,
		searching = string.format("%d searching", tonumber(stats[info.queueType]) or 0),
	}
	local profile = state.profile
	if info.ranked and type(profile) == "table" then
		local rating = if info.mode == "2v2" then profile.Rating2v2 else profile.Rating1v1
		if type(rating) == "number" then
			card.rating = rating
			card.tier = Ranks.tier(rating).Name
		end
	end
	return card
end

-- The three cards in screen order.
function Models.onlineCards(state)
	local cards = {}
	for _, info in Models.ONLINE do
		table.insert(cards, Models.onlineCard(info, state))
	end
	return cards
end

--[[
    Online Play's hints for the focused card's view (Models.onlineCard; nil
    when no card is focused): Confirm says what it does there (the card's
    action: FIND MATCH, or CANCEL SEARCH on the queue you are in), with no
    Confirm hint on a locked card (Confirm only says why there) or without
    a focused card; then Back BACK, and X INVITE when you may invite
    (`canInvite`: solo or the party leader).
]]
function Models.onlineHints(view, canInvite)
	local hints = {}
	if type(view) == "table" and not view.locked then
		table.insert(hints, { action = "Confirm", label = view.action })
	end
	table.insert(hints, { action = "Back", label = "BACK" })
	if canInvite then
		table.insert(hints, { action = "X", label = "INVITE" })
	end
	return hints
end

-- Practice ------------------------------------------------------------------------

Models.BOT_FORMATS = { "Duel", "FFA", "2v2" }

local function botsLabel(format, size)
	if format == "Duel" then
		return "1v1 Duel"
	elseif format == "FFA" then
		local bots = math.max(1, 4 - size)
		return string.format("Free-for-all (%d bot%s)", bots, bots == 1 and "" or "s")
	end
	return if size >= 2 then "2v2 (vs 2 bots)" else "2v2 (bot teammate)"
end

-- The vs Bots formats for a party of `partySize`: { { value, label, fits } } (labels count the bots).
function Models.botFormats(partySize)
	local out = {}
	for _, format in Models.BOT_FORMATS do
		local _, max = Party.limits("Bots", format)
		table.insert(out, { value = format, label = botsLabel(format, partySize), fits = partySize <= max })
	end
	return out
end

-- `current` when a party of `partySize` fits it, else the first format that fits (else `current`).
function Models.pickBotFormat(current, partySize)
	local first = nil
	for _, option in Models.botFormats(partySize) do
		if option.fits then
			if option.value == current then
				return current
			end
			first = first or option.value
		end
	end
	return first or current
end

-- Whether START may send this bots match: ok, reason (Party.canStart's text).
function Models.botsStart(format, partySize, isLeader)
	local ok, _, reason = Party.canStart("Bots", format, partySize, isLeader)
	return ok, reason
end

-- The Map row: "Vote" (map vote) first, then every map.
function Models.botMaps()
	local out = { { value = "Vote", label = "Vote" } }
	for _, id in Maps.Order do
		local map = Maps.get(id)
		table.insert(out, { value = id, label = map and map.Name or id })
	end
	return out
end

-- Rankings ------------------------------------------------------------------------

local MEDALS = { "Gold", "Silver", "Bronze" }

function Models.pageCount(count, pageSize)
	return math.max(1, math.ceil(count / pageSize))
end

local function record(wins, losses)
	return string.format("%s – %s", Util.formatNumber(wins or 0), Util.formatNumber(losses or 0))
end

-- One list row as the screen shows it.
function Models.rankRow(row)
	local tier = Ranks.tier(row.rating or 0)
	return {
		rank = tostring(row.rank),
		userId = row.userId,
		name = row.name or "?",
		you = row.you == true,
		main = if Legends.isValid(row.main) then row.main else nil,
		tier = string.upper(row.tier or tier.Name),
		tierName = row.tier or tier.Name,
		rating = Util.formatNumber(row.rating or 0),
		record = record(row.wins, row.losses),
		medal = MEDALS[row.rank],
	}
end

--[[
    The rows of `page` (clamped to 1..pages) plus your pinned row.
    data = RankingsData; youName / youUserId = you (for the pinned row when
    you are not in the list). Returns { page, pages, rows = { rankRow },
    first (index of the page's first row in data.rows), pinned = rankRow }.
    The pinned row is your row from the list when you are in it, else built
    from your card with rank "—".
]]
function Models.rankingsPage(data, page, pageSize, youName, youUserId)
	local rows = type(data) == "table" and data.rows or {}
	local pages = Models.pageCount(#rows, pageSize)
	page = math.clamp(page or 1, 1, pages)
	local first = (page - 1) * pageSize + 1
	local out = {}
	for i = first, math.min(#rows, first + pageSize - 1) do
		table.insert(out, Models.rankRow(rows[i]))
	end
	local pinned = nil
	for _, row in rows do
		if row.you then
			pinned = Models.rankRow(row)
			break
		end
	end
	if not pinned then
		local card = type(data) == "table" and data.you or {}
		local main = card.main or (card.bestLegend and card.bestLegend.id)
		pinned = Models.rankRow({
			rank = "—",
			userId = youUserId,
			name = youName,
			you = true,
			main = main,
			rating = card.rating or 0,
			tier = card.tier,
			wins = card.wins,
			losses = card.losses,
		})
		pinned.rank = "—"
		pinned.medal = nil
	end
	pinned.name = pinned.name .. " (you)"
	return { page = page, pages = pages, rows = out, first = first, pinned = pinned }
end

-- The page after pressing `dir` on the first ("Up") or last ("Down") row of `page`; nil at the ends of the list.
function Models.flipPage(page, pages, dir)
	if dir == "Down" and page < pages then
		return page + 1
	elseif dir == "Up" and page > 1 then
		return page - 1
	end
	return nil
end

-- The page and the row on it holding your entry (nil when you are not in the list).
function Models.yourPage(rows, pageSize)
	for i, row in rows or {} do
		if row.you then
			return math.ceil(i / pageSize), (i - 1) % pageSize + 1
		end
	end
	return nil, nil
end

-- "SEASON 1 · ENDS IN 23D" (or 5H / 12M under a day), "SEASON 1 · ENDED" for a past or finished season.
function Models.seasonLabel(season, now)
	if type(season) ~= "table" then
		return ""
	end
	local name = string.upper(season.name or "")
	local endsAt = tonumber(season.endsAt) or math.huge
	if season.current == false or endsAt <= now then
		return name .. " · ENDED"
	end
	if endsAt == math.huge then
		return name
	end
	local left = endsAt - now
	if left >= DAY then
		return string.format("%s · ENDS IN %dD", name, math.floor(left / DAY))
	elseif left >= 3600 then
		return string.format("%s · ENDS IN %dH", name, math.floor(left / 3600))
	end
	return string.format("%s · ENDS IN %dM", name, math.max(1, math.floor(left / 60)))
end

-- Missions ------------------------------------------------------------------------------

-- "RESETS IN 7H 42M" ("RESETS IN 42M" under an hour): the time left until the missions' UTC midnight.
function Models.missionsReset(now)
	local left = math.max(0, Missions.resetAt(Missions.dayIndex(now)) - now)
	local hours = math.floor(left / 3600)
	local minutes = math.max(if hours > 0 then 0 else 1, math.floor((left % 3600) / 60))
	if hours > 0 then
		return string.format("RESETS IN %dH %dM", hours, minutes)
	end
	return string.format("RESETS IN %dM", minutes)
end

--[[
    The MISSIONS screen's hints for the focused row (`mission` =
    { claimable, rerollable }, MissionsWidget's rowState; nil when no row
    is focused): Confirm CLAIM on a claimable row, X REROLL on a row that
    can be rerolled, then Back BACK. Confirm and X do nothing on any other
    row, so they get no hint there.
]]
function Models.missionsHints(mission)
	local hints = {}
	if mission ~= nil and mission.claimable == true then
		table.insert(hints, { action = "Confirm", label = "CLAIM" })
	end
	if mission ~= nil and mission.rerollable == true then
		table.insert(hints, { action = "X", label = "REROLL" })
	end
	table.insert(hints, { action = "Back", label = "BACK" })
	return hints
end

local function percent(wins, played)
	if not played or played <= 0 then
		return nil
	end
	return math.floor(wins / played * 100 + 0.5)
end

--[[
    The rank card (RankCard, 3.1) as the screen shows it, for `scope`
    ("Global" | "Friends"). Returns
      { notRanked, tier, tierColor, rating, peak?, progress? = { fraction, from, to?, toNext },
        rank, rankLabel, wins, losses, winRate, legend? = { title, id, name, line? } }
    peak is nil when the card has none (past seasons); notRanked when the
    card has no stored entry (past season).
]]
function Models.rankCard(card, scope)
	card = type(card) == "table" and card or {}
	local rating = tonumber(card.rating) or 0
	local tier = Ranks.tier(rating)
	local tierName = card.tier or tier.Name
	local view = {
		notRanked = card.noEntry == true,
		tier = string.upper(tierName),
		tierName = tierName,
		tierColor = tier.Color,
		rating = tostring(math.floor(rating)),
		peak = if type(card.peak) == "number" then "PEAK " .. math.floor(card.peak) else nil,
		rank = if type(card.rank) == "number" then "#" .. Util.formatNumber(card.rank) else "—",
		rankLabel = if scope == "Friends" then "FRIENDS" else "GLOBAL",
		wins = Util.formatNumber(card.wins or 0),
		losses = Util.formatNumber(card.losses or 0),
		winRate = "—",
	}
	local rate = Rankings.winRate(card.wins or 0, card.losses or 0)
	if rate then
		view.winRate = rate .. "%"
	end
	if view.notRanked then
		view.tier = "NOT RANKED"
		view.rating = "—"
		view.peak = nil
		view.rank = "—"
		view.wins, view.losses, view.winRate = "—", "—", "—"
		return view
	end
	local progress = Rankings.tierProgress(rating)
	view.progress = {
		fraction = progress.fraction,
		from = string.upper(progress.tier.Name) .. " " .. progress.tier.Min,
		to = progress.next and (string.upper(progress.next.Name) .. " " .. progress.next.Min) or nil,
		toNext = if progress.next then string.format("%d to %s", progress.toNext, progress.next.Name) else "Top tier",
	}
	local best = card.bestLegend
	if type(best) == "table" and Legends.isValid(best.id) then
		local bestRate = percent(best.wins or 0, best.played or 0)
		view.legend = {
			title = "BEST LEGEND",
			id = best.id,
			name = string.upper(Legends.get(best.id).Name),
			line = string.format(
				"%d win%s%s",
				best.wins or 0,
				best.wins == 1 and "" or "s",
				bestRate and (" · " .. bestRate .. "%") or ""
			),
		}
	elseif Legends.isValid(card.main) then
		view.legend = { title = "MAIN", id = card.main, name = string.upper(Legends.get(card.main).Name) }
	end
	return view
end

-- Invite -----------------------------------------------------------------------------

Models.STATUS_TEXT = {
	Queue = "Searching",
	Select = "Picking a legend",
	Match = "In a match",
	Training = "In training",
	Room = "In a room",
}

--[[
    Invite rows from PartyRequest("List") candidates, sorted with
    Party.sortCandidates (friends first, then players in the menus, then
    names). canManage = you are solo or the leader. Each row:
      { userId, name, username ("@name"), level ("LV n"), friend, status? (chip text), busy,
        button ("INVITE" | "INVITED" | the reason upper-cased), enabled }
    Busy players (match, select, training) can be invited: the invite waits for them.
]]
function Models.inviteRows(candidates, canManage)
	local list = {}
	for _, c in candidates or {} do
		if type(c) == "table" and type(c.userId) == "number" then
			table.insert(list, c)
		end
	end
	Party.sortCandidates(list)
	local rows = {}
	for _, c in list do
		local button = "INVITE"
		if c.invited then
			button = "INVITED"
		elseif not c.canInvite then
			button = string.upper(c.reason or "Can't invite")
		end
		table.insert(rows, {
			userId = c.userId,
			name = tostring(c.name or c.username or c.userId),
			username = "@" .. tostring(c.username or c.name or ""),
			level = "LV " .. tostring(c.level or 1),
			friend = c.isFriend == true,
			status = Models.STATUS_TEXT[c.status],
			busy = c.status == "Match" or c.status == "Select" or c.status == "Training",
			button = button,
			reason = c.reason,
			enabled = canManage == true and c.canInvite == true and not c.invited,
		})
	end
	return rows
end

-- Profile ----------------------------------------------------------------------------

-- The tiers a season badge holds, in mode order: { { mode, tier } }.
function Models.seasonBadgeTiers(badge)
	local out = {}
	if type(badge) ~= "table" then
		return out
	end
	if type(badge.tier1v1) == "string" then
		table.insert(out, { mode = "1v1", tier = badge.tier1v1 })
	end
	if type(badge.tier2v2) == "string" then
		table.insert(out, { mode = "2v2", tier = badge.tier2v2 })
	end
	return out
end

-- "SEASON 1 · GOLD 1v1 · SILVER 2v2" (only the modes played that season); nil without a badge.
function Models.seasonBadgeText(badge)
	if type(badge) ~= "table" then
		return nil
	end
	local parts = { string.upper(badge.name or ("Season " .. tostring(badge.season or "?"))) }
	for _, entry in Models.seasonBadgeTiers(badge) do
		table.insert(parts, string.upper(entry.tier) .. " " .. entry.mode)
	end
	return table.concat(parts, " · ")
end

-- A Profile rank card: { tier, tierColor, rating, peak, season ("12 – 4 THIS SEASON"), note }.
function Models.profileRank(profile, mode)
	local rating = profile["Rating" .. mode] or Config.Ranked.StartRating
	local tier = Ranks.tier(rating)
	local played = profile["Ranked" .. mode .. "Played"] or 0
	local stats = profile.SeasonStats and profile.SeasonStats[mode] or {}
	local note = nil
	if played < Config.Ranked.PlacementMatches then
		note = string.format("Placements: %d / %d played", played, Config.Ranked.PlacementMatches)
	else
		note = string.format("%s ranked matches", Util.formatNumber(played))
	end
	return {
		tier = string.upper(tier.Name),
		tierName = tier.Name,
		tierColor = tier.Color,
		rating = tostring(rating),
		peak = "PEAK " .. tostring(profile["Peak" .. mode] or rating),
		season = record(stats.wins, stats.losses) .. " THIS SEASON",
		note = note,
	}
end

-- Store ------------------------------------------------------------------------------

-- A shop card's state: { state = "Equipped" | "Owned" | "Buy", label, affordable }.
function Models.shopItem(item, profile)
	local owned = type(profile) == "table" and profile.Owned ~= nil and profile.Owned[item.Id] ~= nil
	local equipped = type(profile) == "table" and profile.Equipped and profile.Equipped[item.Category] == item.Id
	if equipped then
		return { state = "Equipped", label = "EQUIPPED", affordable = true }
	elseif owned then
		return { state = "Owned", label = "EQUIP", affordable = true }
	end
	local coins = type(profile) == "table" and profile.Coins or 0
	return {
		state = "Buy",
		label = Util.formatNumber(item.Price or 0),
		affordable = coins >= (item.Price or 0),
	}
end

return Models
