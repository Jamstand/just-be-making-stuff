--[[
    Rankings screen data (GetRankings, menus design 3.1 / 4.10): the rows
    of a ladder and your rank card, built from what LeaderboardService
    fetched.

      buildRows    a GetSortedAsync page of a season store (packed values,
                   see Rankings.encode) -> RankRow list, you marked
      buildCard    your RankCard: the current season from your live
                   profile, a past season from your stored entry (the
                   packed value, or your row when it is in the list)
      friendsRows  friends (and you) from live profiles or stored values,
                   sorted by rating, then wins

    A RankRow is { rank, userId, name, username, rating, tier, main?, wins,
    losses, you }. Names come from `names[userId] = { name, username }`;
    unknown players read "Player <id>".

    Pure.
]]

local Rankings = require(script.Parent.Rankings)
local Ranks = require(script.Parent.Ranks)

local RankingsView = {}

-- Profile keys per ladder.
local PROFILE_KEYS = {
	["1v1"] = { Rating = "Rating1v1", Peak = "Peak1v1", Played = "Ranked1v1Played" },
	["2v2"] = { Rating = "Rating2v2", Peak = "Peak2v2", Played = "Ranked2v2Played" },
}

local function whole(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return 0
	end
	return math.max(0, math.floor(value))
end

local function nameOf(names, userId)
	local known = names and names[userId]
	local name = type(known) == "table" and type(known.name) == "string" and known.name or nil
	local username = type(known) == "table" and type(known.username) == "string" and known.username or nil
	return name or ("Player " .. userId), username or ("Player" .. userId)
end

local function row(rank, userId, name, username, rating, main, wins, losses, youUserId)
	return {
		rank = rank,
		userId = userId,
		name = name,
		username = username,
		rating = rating,
		tier = Ranks.tier(rating).Name,
		main = main,
		wins = wins,
		losses = losses,
		you = userId == youUserId,
	}
end

-- A store key (tostring(UserId)) or user id as a number; nil for anything else. Studio test players have
-- negative ids (they never reach a store, but do show in the rows built from live profiles).
local function userIdOf(key)
	local id = tonumber(key)
	if not id or id ~= id or id ~= math.floor(id) or id == 0 or math.abs(id) == math.huge then
		return nil
	end
	return id
end

--[[
    The rows of a GetSortedAsync page, in page order (rank = position).
    `entries` = { { key, value } } (key = tostring(UserId), value = packed);
    entries whose key is not a user id are skipped.
]]
function RankingsView.buildRows(entries, names, youUserId)
	local rows = {}
	for _, entry in entries or {} do
		local userId = type(entry) == "table" and userIdOf(entry.key)
		if userId then
			local rating, main, wins, losses = Rankings.decode(entry.value)
			local name, username = nameOf(names, userId)
			table.insert(rows, row(#rows + 1, userId, name, username, rating, main, wins, losses, youUserId))
		end
	end
	return rows
end

--[[
    Your RankCard for `mode`. `rows` are the rows shown with it; `rank` is
    your row's rank there (nil when you are not in them).
      current = true: rating, peak, tier, this season's wins/losses, played
        (Ranked<mode>Played) and bestLegend from the live profile.
      current = false: rating, tier, wins, losses and main from `ownValue`
        (your packed entry in that season's store) or else your row in
        `rows`; peak, played and bestLegend are nil. With neither: noEntry =
        true (rating 0, nothing played).
]]
function RankingsView.buildCard(profile, mode, rows, current, ownValue)
	local yourRow = nil
	for _, r in rows or {} do
		if r.you then
			yourRow = r
			break
		end
	end
	local card
	if current then
		local keys = PROFILE_KEYS[mode] or PROFILE_KEYS["1v1"]
		local rating = whole(profile[keys.Rating])
		local stats = type(profile.SeasonStats) == "table" and profile.SeasonStats[mode] or nil
		stats = type(stats) == "table" and stats or {}
		local bestId, bestWins, bestPlayed = Rankings.bestLegend(stats.Legends)
		card = {
			rating = rating,
			tier = Ranks.tier(rating).Name,
			peak = whole(profile[keys.Peak]),
			wins = whole(stats.Wins),
			losses = whole(stats.Losses),
			played = whole(profile[keys.Played]),
			bestLegend = if bestId then { id = bestId, wins = bestWins, played = bestPlayed } else nil,
		}
	else
		local rating, main, wins, losses
		if type(ownValue) == "number" then
			rating, main, wins, losses = Rankings.decode(ownValue)
		elseif yourRow then
			rating, main, wins, losses = yourRow.rating, yourRow.main, yourRow.wins, yourRow.losses
		end
		if rating == nil then
			card = { rating = 0, tier = Ranks.tier(0).Name, wins = 0, losses = 0, noEntry = true }
		else
			card = { rating = rating, tier = Ranks.tier(rating).Name, wins = wins, losses = losses, main = main }
		end
	end
	card.rank = yourRow and yourRow.rank or nil
	return card
end

--[[
    Friends' rows (you included): `list` = { { userId, name, username,
    value? (packed), rating?, wins?, losses?, main? } }. A packed value
    wins over the plain fields; entries with neither a value nor a rating
    are dropped, and a user id listed twice counts once (the first).
    Sorted by rating, then wins (like the stores), then user id; rank =
    position.
]]
function RankingsView.friendsRows(list, youUserId)
	local items, seen = {}, {}
	for _, item in list or {} do
		local userId = type(item) == "table" and userIdOf(item.userId)
		if userId and not seen[userId] then
			local rating, main, wins, losses
			if type(item.value) == "number" then
				rating, main, wins, losses = Rankings.decode(item.value)
			elseif type(item.rating) == "number" then
				rating, main, wins, losses = whole(item.rating), item.main, whole(item.wins), whole(item.losses)
			end
			if rating then
				seen[userId] = true
				local name = type(item.name) == "string" and item.name or nil
				local username = type(item.username) == "string" and item.username or nil
				local fallbackName, fallbackUsername = nameOf(nil, userId)
				table.insert(items, {
					userId = userId,
					name = name or fallbackName,
					username = username or fallbackUsername,
					rating = rating,
					main = if type(main) == "string" then main else nil,
					wins = wins,
					losses = losses,
				})
			end
		end
	end
	table.sort(items, function(a, b)
		if a.rating ~= b.rating then
			return a.rating > b.rating
		elseif a.wins ~= b.wins then
			return a.wins > b.wins
		end
		return a.userId < b.userId
	end)
	local rows = {}
	for i, item in items do
		table.insert(
			rows,
			row(i, item.userId, item.name, item.username, item.rating, item.main, item.wins, item.losses, youUserId)
		)
	end
	return rows
end

return RankingsView
