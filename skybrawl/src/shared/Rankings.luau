--[[
    Ranked ladder helpers: store names, the packed OrderedDataStore value
    and tier progress.

    One OrderedDataStore per season and mode ("<StorePrefix>S<season>_<mode>").
    Its integer value packs everything the top-100 list shows, so the list
    costs no extra DataStore calls:
      value = rating * 1e12 + wins * 1e7 + mainLegendCode * 1e5 + losses
    (rating 0..8999, wins and losses capped at 99999). Sorting by value sorts
    by rating, then by wins. The largest value stays below 2^53, so it is
    exact in a double.

    LEGEND_CODES are frozen and append-only: stored values use them, so an
    existing code must never change (a contract test pins them).

    Pure.
]]

local Config = require(script.Parent.Config)
local Ranks = require(script.Parent.Ranks)

local Rankings = {}

Rankings.MODES = { "1v1", "2v2" }

Rankings.LEGEND_CODES = { Kestrel = 1, Brann = 2, Yuki = 3, Moss = 4, Vex = 5, Sol = 6, Avatar = 7 }

local LEGEND_BY_CODE = {}
for legend, code in Rankings.LEGEND_CODES do
	LEGEND_BY_CODE[code] = legend
end

local RATING_SCALE = 1e12
local WINS_SCALE = 1e7
local CODE_SCALE = 1e5
local MAX_COUNT = 99999
local MAX_RATING = 8999

function Rankings.storeName(seasonId, mode)
	return Config.Rankings.StorePrefix .. "S" .. tostring(seasonId) .. "_" .. mode
end

local function whole(value, max)
	if type(value) ~= "number" or value ~= value then
		return 0
	end
	return math.clamp(math.floor(value), 0, max)
end

function Rankings.encode(rating, legend, wins, losses)
	local code = Rankings.LEGEND_CODES[legend] or 0
	return whole(rating, MAX_RATING) * RATING_SCALE
		+ whole(wins, MAX_COUNT) * WINS_SCALE
		+ code * CODE_SCALE
		+ whole(losses, MAX_COUNT)
end

-- Returns rating, main legend (nil for code 0 or an unknown code), wins, losses.
function Rankings.decode(value)
	local v = math.max(0, math.floor(tonumber(value) or 0))
	local rating = v // RATING_SCALE
	v -= rating * RATING_SCALE
	local wins = v // WINS_SCALE
	v -= wins * WINS_SCALE
	local code = v // CODE_SCALE
	local losses = v - code * CODE_SCALE
	return rating, LEGEND_BY_CODE[code], wins, losses
end

-- Where a rating sits in its tier: tier, next tier (nil at the top), fraction 0..1 of the way there and the
-- rating still needed (nil at the top).
function Rankings.tierProgress(rating)
	local tiers = Config.Ranked.Tiers
	local tier = Ranks.tier(rating)
	local index = table.find(tiers, tier) or #tiers
	local nextTier = tiers[index + 1]
	if not nextTier then
		return { tier = tier, next = nil, fraction = 1, toNext = nil }
	end
	local span = nextTier.Min - tier.Min
	local fraction = if span > 0 then math.clamp((rating - tier.Min) / span, 0, 1) else 1
	return { tier = tier, next = nextTier, fraction = fraction, toNext = math.max(0, nextTier.Min - rating) }
end

-- The legend with the most ranked wins this season (then the most played, then by id), from
-- SeasonStats[mode].Legends. Returns id (nil when nothing was played), wins, played.
function Rankings.bestLegend(legends)
	local bestId, bestWins, bestPlayed = nil, 0, 0
	for id, stats in legends or {} do
		local wins, playedCount = stats.Wins or 0, stats.Played or 0
		if playedCount > 0 then
			local better = bestId == nil
				or wins > bestWins
				or (wins == bestWins and playedCount > bestPlayed)
				or (wins == bestWins and playedCount == bestPlayed and id < bestId)
			if better then
				bestId, bestWins, bestPlayed = id, wins, playedCount
			end
		end
	end
	return bestId, bestWins, bestPlayed
end

-- Whole percent of games won; nil with no games.
function Rankings.winRate(wins, losses)
	local total = wins + losses
	if total <= 0 then
		return nil
	end
	return math.floor(wins / total * 100 + 0.5)
end

return Rankings
