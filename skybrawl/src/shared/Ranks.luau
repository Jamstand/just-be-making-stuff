--[[
    Ranked rating (Elo) and XP levels.
]]

local Config = require(script.Parent.Config)

local R = Config.Ranked
local L = Config.Levels

local Ranks = {}

function Ranks.expected(rating, opponentRating)
	return 1 / (1 + 10 ^ ((opponentRating - rating) / 400))
end

-- score is 1 for a win, 0 for a loss, 0.5 for a draw.
function Ranks.newRating(rating, opponentRating, score, matchesPlayed)
	local k = (matchesPlayed or 0) < R.PlacementMatches and R.KPlacement or R.K
	local delta = k * (score - Ranks.expected(rating, opponentRating))
	return math.max(R.MinRating, math.floor(rating + delta + 0.5))
end

function Ranks.tier(rating)
	local best = R.Tiers[1]
	for _, tier in R.Tiers do
		if rating >= tier.Min then
			best = tier
		end
	end
	return best
end

function Ranks.xpForLevel(level)
	return L.BaseXP + L.PerLevelXP * (level - 1)
end

-- Returns level, xp into the current level, xp needed for the next one.
function Ranks.levelFromXP(totalXP)
	local level = 1
	local remaining = math.max(0, math.floor(totalXP or 0))
	while level < L.MaxLevel do
		local need = Ranks.xpForLevel(level)
		if remaining < need then
			return level, remaining, need
		end
		remaining -= need
		level += 1
	end
	return L.MaxLevel, 0, 0
end

return Ranks
