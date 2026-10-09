--[[
    Turns match results into coins, XP, stats, ranked rating, season stats
    and mission progress (menus design 4.9).

    For every player of a finished match, inside one profile update:
      1. the season first: a result that lands just after a season ended
         goes to the new season (Seasons.ensure soft-resets, then rates);
         then, when the match pays rewards, the mission day (a new UTC day
         pays yesterday's missions now, so levelBefore and xpTotal - xp
         both include that payout)
      2. base coins and XP (per-match caps, the source multiplier), then the
         best live event multiplier for the legend played (Config.Events)
      3. ranked: rating, plus this season's wins/losses and per-legend stats
      4. missions (MissionService.onMatch) when the match pays rewards
    Toasts (season, missions, level up) go out after the update, and ranked
    results are submitted to the season's ladder (LeaderboardService).
    Training matches and matches shorter than the minimum pay nothing.
    Each player is applied in a pcall: one bad entry never costs the others
    their rewards or stops the caller (Match:Finish).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Events = require(Shared.Events)
local Legends = require(Shared.Legends)
local Ranks = require(Shared.Ranks)
local Seasons = require(Shared.Seasons)
local Net = require(Shared.Net)

local ProgressionService = {}
local services

local RATING_KEYS = {
	["1v1"] = { Rating = "Rating1v1", Played = "Ranked1v1Played", Peak = "Peak1v1" },
	["2v2"] = { Rating = "Rating2v2", Played = "Ranked2v2Played", Peak = "Peak2v2" },
}

function ProgressionService.init(s)
	services = s
end

function ProgressionService.start() end

function ProgressionService.ratingOf(player, mode)
	local keys = RATING_KEYS[mode] or RATING_KEYS["1v1"]
	local profile = services.DataService.get(player)
	return profile and profile[keys.Rating] or Config.Ranked.StartRating
end

local function rewardMultiplier(info)
	if (info.duration or 0) < Config.Rewards.MinMatchSecondsForRewards then
		return 0
	end
	local source = info.source
	if source == "Custom" and info.hasBots then
		source = "Bots"
	end
	return Config.Rewards.SourceMultiplier[source] or 1
end

local function number(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return 0
	end
	return value
end

-- An opponent rating to rate against: StartRating when it is missing, junk or not positive.
local function opponentOf(rating)
	local value = number(rating)
	return if value > 0 then value else Config.Ranked.StartRating
end

-- An event multiplier as Events.multipliers gives it (1 when missing or junk).
local function multiplier(value)
	if type(value) ~= "number" or value ~= value or value < 1 then
		return 1
	end
	return math.min(value, Config.EventMaxMult)
end

--[[
    Coins and XP one match entry earns: the base amounts with the per-match
    caps and the source multiplier `mult` (as before events existed), then
    the event multipliers on top (so an event can lift a match past the
    cap). Pure.
]]
function ProgressionService.computeRewards(entry, mult, xpMult, coinMult)
	local c = Config.Rewards.Coins
	local x = Config.Rewards.XP
	local won = entry.won == true
	local kos = number(entry.kos)
	local damage = number(entry.damageDealt)
	local coins = math.floor(math.min(c.MaxPerMatch, (c.Played + c.PerKO * kos + (won and c.Win or 0)) * mult))
	local xp = math.floor(
		math.min(x.MaxPerMatch, (x.Played + x.PerKO * kos + (won and x.Win or 0) + x.PerDamage * damage) * mult)
	)
	return math.floor(coins * multiplier(coinMult)), math.floor(xp * multiplier(xpMult))
end

local function applyRating(profile, mode, opponentRating, score)
	local keys = RATING_KEYS[mode]
	local before = profile[keys.Rating]
	local after = Ranks.newRating(before, opponentRating, score, profile[keys.Played])
	profile[keys.Rating] = after
	profile[keys.Played] += 1
	profile[keys.Peak] = math.max(profile[keys.Peak], after)
	return before, after
end

-- profile.SeasonStats[mode], created when missing (profiles are sanitized on load, so normally it exists).
local function seasonStats(profile, mode)
	if type(profile.SeasonStats) ~= "table" then
		profile.SeasonStats = {}
	end
	local stats = profile.SeasonStats[mode]
	if type(stats) ~= "table" then
		stats = { Wins = 0, Losses = 0, Legends = {} }
		profile.SeasonStats[mode] = stats
	end
	if type(stats.Legends) ~= "table" then
		stats.Legends = {}
	end
	return stats
end

-- A ranked result in this season's stats: score 1 = win, 0 = loss, 0.5 = draw (neither).
local function recordSeason(profile, mode, legend, score)
	local stats = seasonStats(profile, mode)
	if score == 1 then
		stats.Wins += 1
	elseif score == 0 then
		stats.Losses += 1
	end
	if Legends.isValid(legend) then
		local entry = stats.Legends[legend]
		if type(entry) ~= "table" then
			entry = { Wins = 0, Played = 0 }
			stats.Legends[legend] = entry
		end
		entry.Played += 1
		if score == 1 then
			entry.Wins += 1
		end
	end
end

local function toast(player, text, kind)
	Net.get("Toast"):FireClient(player, text, kind or "good")
end

local function seasonToast(player, change)
	if change then
		local season = Seasons.byId(change.to) or Seasons.current(os.time())
		toast(player, season.Name .. " has begun! Your ratings were soft-reset.")
	end
end

-- One player's match result: the profile update, then toasts and the ladder. Fills out[player].
local function applyEntry(info, mult, entry, out)
	local player = entry.player
	local legend = entry.legend or "Avatar"
	local rewards, paid, seasonChange, startLevel = services.DataService.update(player, function(profile)
		local now = os.time()
		local _, change = Seasons.ensure(profile, now)
		local levelAtStart = Ranks.levelFromXP(profile.XP) -- for the level-up toast, which counts the payout too
		local rolled = nil
		if mult > 0 then
			-- (a mission problem must never cost the player their match rewards)
			local ok, dayPaid = pcall(services.MissionService.rollDay, profile, player.UserId)
			if ok then
				rolled = dayPaid
			else
				warn("[ProgressionService] mission day roll failed:", dayPaid)
			end
		end
		local levelBefore = Ranks.levelFromXP(profile.XP)
		local won = entry.won == true

		local xpMult, coinMult, applied = 1, 1, {}
		if mult > 0 then
			xpMult, coinMult, applied = Events.multipliers(Config.Events, now, legend)
		end
		local coins, xp = ProgressionService.computeRewards(entry, mult, xpMult, coinMult)

		profile.Coins += coins
		profile.XP += xp
		profile.Matches += 1
		if won then
			profile.Wins += 1
		elseif not entry.draw then
			profile.Losses += 1
		end
		profile.KOs += number(entry.kos)
		profile.Falls += number(entry.falls)
		profile.DamageDealt += number(entry.damageDealt)

		local result = {
			coins = coins,
			xp = xp,
			levelBefore = levelBefore,
			xpMult = xpMult,
			coinMult = coinMult,
			events = {},
		}
		for _, event in applied do
			table.insert(result.events, event.Title)
		end
		if info.ranked and RATING_KEYS[info.mode] and entry.opponentRating then
			local score = won and 1 or (entry.draw and 0.5 or 0)
			local ratingBefore, ratingAfter = applyRating(profile, info.mode, opponentOf(entry.opponentRating), score)
			recordSeason(profile, info.mode, legend, score)
			result.ratingMode = info.mode
			result.ratingBefore = ratingBefore
			result.ratingAfter = ratingAfter
			result.tierBefore = Ranks.tier(ratingBefore).Name
			result.tierAfter = Ranks.tier(ratingAfter).Name
		end

		if mult > 0 then
			-- (the day is already rolled above, so onMatch's own roll pays nothing more)
			local ok, moved, dayPaid = pcall(services.MissionService.onMatch, profile, info, entry)
			if ok then
				result.missions = moved
				rolled = rolled or dayPaid
			else
				warn("[ProgressionService] mission progress failed:", moved)
			end
		end
		result.xpTotal = profile.XP
		result.levelAfter = (Ranks.levelFromXP(profile.XP))
		return result, rolled, change, levelAtStart
	end)
	if not rewards then
		return
	end
	out[player] = rewards
	seasonToast(player, seasonChange)
	if paid then
		toast(player, string.format("Mission rewards collected: +%d coins, +%d XP", paid.coins, paid.xp))
	end
	for _, mission in rewards.missions or {} do
		if mission.justDone then
			toast(player, "Mission complete: " .. mission.text)
		end
	end
	if rewards.levelAfter > startLevel then
		toast(player, string.format("Level up! You're now level %d.", rewards.levelAfter))
		services.CharacterService.refreshNameplate(player)
	end
	if rewards.ratingMode then
		services.LeaderboardService.submit(player, rewards.ratingMode, services.DataService.get(player))
	end
end

--[[
    info:    MatchInfo { source, ranked, mode, duration, hasBots, queueType?,
             mapId?, training?, minBotDifficulty?, damageMultiplier? }
    entries: MatchEntry list { player, team, won, draw, kos, falls,
             damageDealt, damageTaken?, opponentRating? (ranked), legend?,
             ownLook?, placement?, weaponDamage?, trueCombos?, maxCombo? }
    Returns { [player] = Rewards } for the results screen (menus design 3.2).
    Fields a match doesn't send default safely (legend "Avatar", no weapon
    damage, no true combos; a junk opponent rating rates against
    StartRating). Never throws: an entry that fails is logged and left out.
]]
function ProgressionService.applyMatch(info, entries)
	if info.source == "Training" or info.training == true then
		return {}
	end
	local mult = rewardMultiplier(info)
	local out = {}
	for _, entry in entries do
		local ok, err = pcall(applyEntry, info, mult, entry, out)
		if not ok then
			warn("[ProgressionService] couldn't apply a match result:", err)
		end
	end
	return out
end

--[[
    A player who quits a ranked match (or dodges in select / before the
    fight) takes the loss immediately: rating, a season loss and a game
    played with `legend` (when it is a legend id). The season moves first,
    as in applyMatch. Never throws (it runs from PlayerRemoving and forfeits).
]]
function ProgressionService.applyLeaver(player, mode, opponentRating, legend)
	if not RATING_KEYS[mode] then
		return
	end
	local opponent = opponentOf(opponentRating)
	local ok, err = pcall(function()
		local updated, seasonChange = services.DataService.update(player, function(profile)
			local _, change = Seasons.ensure(profile, os.time())
			applyRating(profile, mode, opponent, 0)
			recordSeason(profile, mode, legend, 0)
			profile.Matches += 1
			profile.Losses += 1
			return true, change
		end)
		if updated then
			seasonToast(player, seasonChange)
			services.LeaderboardService.submit(player, mode, services.DataService.get(player))
		end
	end)
	if not ok then
		warn("[ProgressionService] couldn't apply a leaver loss:", err)
	end
end

return ProgressionService
