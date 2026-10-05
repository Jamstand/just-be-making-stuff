--[[
    Turns match results into coins, XP, stats and ranked rating.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Ranks = require(Shared.Ranks)
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

local function applyRating(profile, mode, opponentRating, score)
	local keys = RATING_KEYS[mode]
	local before = profile[keys.Rating]
	local after = Ranks.newRating(before, opponentRating, score, profile[keys.Played])
	profile[keys.Rating] = after
	profile[keys.Played] += 1
	profile[keys.Peak] = math.max(profile[keys.Peak], after)
	return before, after
end

--[[
    info:    { source, ranked, mode, duration, hasBots }
    entries: list of {
      player, team, won, draw, kos, falls, damageDealt,
      opponentRating   (ranked only) average rating of the other team
    }
    Returns { [player] = rewards } where rewards is shown on the results screen.
]]
function ProgressionService.applyMatch(info, entries)
	local mult = rewardMultiplier(info)
	local out = {}
	for _, entry in entries do
		local player = entry.player
		local rewards = services.DataService.update(player, function(profile)
			local levelBefore = Ranks.levelFromXP(profile.XP)
			local won = entry.won == true
			local c = Config.Rewards.Coins
			local x = Config.Rewards.XP
			local coins =
				math.floor(math.min(c.MaxPerMatch, (c.Played + c.PerKO * entry.kos + (won and c.Win or 0)) * mult))
			local xp = math.floor(
				math.min(
					x.MaxPerMatch,
					(x.Played + x.PerKO * entry.kos + (won and x.Win or 0) + x.PerDamage * entry.damageDealt) * mult
				)
			)

			profile.Coins += coins
			profile.XP += xp
			profile.Matches += 1
			if won then
				profile.Wins += 1
			elseif not entry.draw then
				profile.Losses += 1
			end
			profile.KOs += entry.kos
			profile.Falls += entry.falls
			profile.DamageDealt += entry.damageDealt

			local result = {
				coins = coins,
				xp = xp,
				levelBefore = levelBefore,
				levelAfter = (Ranks.levelFromXP(profile.XP)),
			}
			if info.ranked and RATING_KEYS[info.mode] and entry.opponentRating then
				local score = won and 1 or (entry.draw and 0.5 or 0)
				local before, after = applyRating(profile, info.mode, entry.opponentRating, score)
				result.ratingMode = info.mode
				result.ratingBefore = before
				result.ratingAfter = after
				result.tierBefore = Ranks.tier(before).Name
				result.tierAfter = Ranks.tier(after).Name
			end
			return result
		end)
		if rewards then
			out[player] = rewards
			if rewards.levelAfter > rewards.levelBefore then
				Net.get("Toast")
					:FireClient(player, string.format("Level up! You're now level %d.", rewards.levelAfter), "good")
				services.CharacterService.refreshNameplate(player)
			end
			if rewards.ratingMode == "1v1" then
				services.LeaderboardService.submit(player, rewards.ratingAfter)
			end
		end
	end
	return out
end

-- A player who quits a ranked match takes the loss immediately.
function ProgressionService.applyLeaver(player, mode, opponentRating)
	if not RATING_KEYS[mode] then
		return
	end
	services.DataService.update(player, function(profile)
		local _, after = applyRating(profile, mode, opponentRating, 0)
		profile.Matches += 1
		profile.Losses += 1
		if mode == "1v1" then
			services.LeaderboardService.submit(player, after)
		end
	end)
end

return ProgressionService
