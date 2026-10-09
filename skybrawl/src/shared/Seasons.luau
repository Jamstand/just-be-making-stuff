--[[
    Ranked seasons (Config.Seasons). A season runs from the previous one's
    end (0 for the first) to its own Ends (UTC). After the last one ends it
    stays current (the menus show "ENDED") until a new entry is added; an
    empty list is one endless "Season 1".

    Seasons.ensure moves a profile into the current season: the tiers of
    the season it played become its SeasonBadge, its ratings are soft-reset
    toward Ranked.StartRating and its season stats start over. Profiles are
    moved lazily (on load, by MissionService's loop and before every ranked
    result), so a player offline for two seasons gets one reset. Seasons
    only move forward: a loop checks Seasons.isBehind(profile, now), never
    `profile.Season ~= Seasons.current(now).Id`.

    Pure: `now` (unix seconds, UTC) is always passed in.
]]

local Config = require(script.Parent.Config)
local Events = require(script.Parent.Events)
local Ranks = require(script.Parent.Ranks)

local Seasons = {}

local DEFAULT = { Id = 1, Name = "Season 1", startsAt = 0, endsAt = math.huge }

-- Seasons in order: { Id, Name, startsAt, endsAt } (unix seconds; a bad Ends never ends).
function Seasons.list()
	local out = {}
	local startsAt = 0
	for _, entry in Config.Seasons.List do
		local endsAt = Events.parse(entry.Ends) or math.huge
		table.insert(out, { Id = entry.Id, Name = entry.Name, startsAt = startsAt, endsAt = endsAt })
		startsAt = endsAt
	end
	if #out == 0 then
		table.insert(out, table.clone(DEFAULT))
	end
	return out
end

-- The first season that hasn't ended; after the last one ends, the last one.
function Seasons.current(now)
	local list = Seasons.list()
	for _, season in list do
		if season.endsAt > now then
			return season
		end
	end
	return list[#list]
end

function Seasons.byId(id)
	for _, season in Seasons.list() do
		if season.Id == id then
			return season
		end
	end
	return nil
end

-- Seasons that have started, newest first.
function Seasons.started(now)
	local out = {}
	local list = Seasons.list()
	for i = #list, 1, -1 do
		if list[i].startsAt <= now then
			table.insert(out, list[i])
		end
	end
	return out
end

-- Pulls a rating toward the start rating by Config.Seasons.SoftResetFactor.
function Seasons.softReset(rating)
	local start = Config.Ranked.StartRating
	local value = math.floor(start + (rating - start) * Config.Seasons.SoftResetFactor + 0.5)
	return math.max(Config.Ranked.MinRating, value)
end

local function played(stats)
	return type(stats) == "table" and ((stats.Wins or 0) + (stats.Losses or 0)) > 0
end

local function emptySeasonStats()
	return {
		["1v1"] = { Wins = 0, Losses = 0, Legends = {} },
		["2v2"] = { Wins = 0, Losses = 0, Legends = {} },
	}
end

-- Whether Seasons.ensure would move `profile` (its Season is an earlier one than the current season). Seasons
-- only move forward: a profile from a newer season than this server knows (clock behind) is not behind.
function Seasons.isBehind(profile, now)
	local from = profile.Season
	return type(from) == "number" and from ~= 0 and from < Seasons.current(now).Id
end

--[[
    Moves `profile` into the current season when it belongs to an earlier
    one (Seasons.isBehind): SeasonBadge = the end-of-season tiers
    (Ranks.tier of the ratings before the reset, not the peaks) of the
    modes played that season (the previous badge stays when neither was),
    then Rating1v1/2v2 soft-reset, Peak1v1/2v2 = the new ratings,
    SeasonStats cleared, Season = current. A profile with no season yet
    (0), already current, or from a season this server doesn't know as
    ended (a newer one) is left alone.
    Returns changed, { from, to }?.
]]
function Seasons.ensure(profile, now)
	if not Seasons.isBehind(profile, now) then
		return false, nil
	end
	local current = Seasons.current(now)
	local from = profile.Season
	local stats = profile.SeasonStats or {}
	local played1, played2 = played(stats["1v1"]), played(stats["2v2"])
	if played1 or played2 then
		local season = Seasons.byId(from)
		profile.SeasonBadge = {
			Season = from,
			Name = season and season.Name or ("Season " .. from),
			Tier1v1 = if played1 then Ranks.tier(profile.Rating1v1).Name else nil,
			Tier2v2 = if played2 then Ranks.tier(profile.Rating2v2).Name else nil,
		}
	end
	profile.Rating1v1 = Seasons.softReset(profile.Rating1v1)
	profile.Rating2v2 = Seasons.softReset(profile.Rating2v2)
	profile.Peak1v1 = profile.Rating1v1
	profile.Peak2v2 = profile.Rating2v2
	profile.SeasonStats = emptySeasonStats()
	profile.Season = current.Id
	return true, { from = from, to = current.Id }
end

return Seasons
