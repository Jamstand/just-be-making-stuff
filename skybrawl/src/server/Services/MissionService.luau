--[[
    Daily missions on the server (menus design 4.8). The rules live in the
    pure Missions module; this service wires them to profiles:

      MissionRequest   "Reroll" / "Claim" a mission by index (rate limited);
                       refused when the list the player saw is another day's
      rollDay          ProgressionService calls it first inside its
                       profile update when a match pays rewards: a new UTC
                       day pays yesterday's missions before the match's
                       levelBefore is read
      onMatch          then, in the same update: rolls the day (a no-op
                       after rollDay; a match after midnight counts for the
                       new day), then adds the match's stats
      rollover loop    every 30 s for every loaded profile: a new UTC day
                       pays yesterday's done-but-unclaimed missions and
                       rolls new ones; a season that ended moves the
                       profile into the new one (soft reset)

    Whatever a day rollover pays is added to Coins/XP right there and
    toasted ("Mission rewards collected: ..."), so a mission is never lost
    and paid once. Rollover checks use Missions.isNewDay and
    Seasons.isBehind (days and seasons only move forward).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Missions = require(Shared.Missions)
local Ranks = require(Shared.Ranks)
local Seasons = require(Shared.Seasons)
local Net = require(Shared.Net)

local MissionService = {}
local services

local ROLLOVER_SECONDS = 30
local REQUEST_BURST = 3

local buckets = {} -- [Player] = { tokens, at } (MissionRequest rate limit)

local function toast(player, text, kind)
	Net.get("Toast"):FireClient(player, text, kind or "good")
end

local function paidText(paid)
	return string.format("Mission rewards collected: +%d coins, +%d XP", paid.coins, paid.xp)
end

-- Rolls the profile's missions to `day` and adds whatever the old day paid. Returns paid?.
local function rollTo(profile, userId, day)
	local _, paid = Missions.ensureDay(profile.Missions, day, userId)
	if paid then
		profile.Coins += paid.coins
		profile.XP += paid.xp
	end
	return paid
end

-- After XP changed outside a match: the level-up toast and nameplate, as ProgressionService does.
local function levelChanged(player, levelBefore, levelAfter)
	if levelAfter > levelBefore then
		toast(player, string.format("Level up! You're now level %d.", levelAfter))
		services.CharacterService.refreshNameplate(player)
	end
end

--[[
    Called by ProgressionService first thing inside its DataService.update
    closure when the match pays rewards: brings the missions to today,
    paying yesterday's done-but-unclaimed ones into Coins/XP. Returns paid
    ({ coins, xp, count }?; the caller toasts it), nil for a profile without
    missions.
]]
function MissionService.rollDay(profile, userId)
	if type(profile) ~= "table" or type(profile.Missions) ~= "table" then
		return nil
	end
	return rollTo(profile, userId, Missions.dayIndex(os.time()))
end

--[[
    Called by ProgressionService inside its DataService.update closure when
    the match pays rewards (multiplier > 0). Rolls the day first (paying
    yesterday's done-but-unclaimed missions into the profile), then adds
    the match's stats (Missions.statsFromEntry decides what counts).
    Returns the missions the match moved ({ MissionProgress }, possibly
    empty) and what the rollover paid ({ coins, xp, count }?; the caller
    toasts it after the update). A profile without missions gives nil.
]]
function MissionService.onMatch(profile, info, entry)
	if type(profile) ~= "table" or type(profile.Missions) ~= "table" or type(entry) ~= "table" then
		return nil, nil
	end
	local userId = entry.player and entry.player.UserId or 0
	local paid = rollTo(profile, userId, Missions.dayIndex(os.time()))
	local moved = Missions.applyStats(profile.Missions, Missions.statsFromEntry(info or {}, entry))
	local out = {}
	for _, m in moved do
		table.insert(out, {
			index = m.index,
			text = Missions.describe(profile.Missions.List[m.index]),
			progress = m.progress,
			goal = m.goal,
			done = m.done,
			justDone = m.justDone,
		})
	end
	return out, paid
end

-- MissionRequest token bucket: Config.Missions.RequestsPerSecond a second, burst REQUEST_BURST (real time).
local function allowRequest(player)
	local rate = Config.Missions.RequestsPerSecond
	local now = os.clock()
	local bucket = buckets[player]
	if not bucket then
		bucket = { tokens = REQUEST_BURST, at = now }
		buckets[player] = bucket
	end
	bucket.tokens = math.min(REQUEST_BURST, bucket.tokens + (now - bucket.at) * rate)
	bucket.at = now
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

local actions = {}

function actions.Reroll(profile, userId, index)
	local ok, reason = Missions.reroll(profile.Missions, index, profile.Missions.Day, userId)
	if not ok then
		return false, reason
	end
	return true, "Mission rerolled."
end

function actions.Claim(profile, _userId, index)
	local ok, coins, xp = Missions.claim(profile.Missions, index)
	if not ok then
		return false, coins
	end
	profile.Coins += coins
	profile.XP += xp
	return true, string.format("+%d coins, +%d XP", coins, xp)
end

--[[
    The MissionRequest handler body: (action "Reroll" | "Claim", index,
    day?) -> ok, message. `day` is the Missions day of the list the player
    acted on (their snapshot's missions.day). The day is rolled first
    (paying yesterday's missions); then the request is refused ("Your
    missions changed. Take another look.") when it was made on another
    day's list: this roll started a new day (nobody has seen its list yet),
    or `day` isn't the profile's day (the client hadn't got the list a
    rollover just pushed). So an index pressed on yesterday's row never
    rerolls or claims one of today's missions. The update pushes the
    current list either way.
]]
function MissionService.request(player, action, index, day)
	if not allowRequest(player) then
		return false, "Slow down."
	end
	local handler = type(action) == "string" and actions[action]
	if not handler then
		return false, "Bad request."
	end
	if not services.DataService.get(player) then
		return false, "Your profile is still loading."
	end
	local userId = player.UserId
	local ok, message, paid, levelBefore, levelAfter = services.DataService.update(player, function(profile)
		local before = Ranks.levelFromXP(profile.XP)
		local dayBefore = profile.Missions.Day
		local rolled = rollTo(profile, userId, Missions.dayIndex(os.time()))
		-- a day that starts right here can't have been seen yet
		if profile.Missions.Day ~= dayBefore or (day ~= nil and day ~= dayBefore) then
			return false, "Your missions changed. Take another look.", rolled, before, (Ranks.levelFromXP(profile.XP))
		end
		local done, text = handler(profile, userId, index)
		return done, text, rolled, before, (Ranks.levelFromXP(profile.XP))
	end)
	if paid then
		toast(player, paidText(paid))
	end
	if levelBefore and levelAfter then
		levelChanged(player, levelBefore, levelAfter)
	end
	return ok == true, message
end

--[[
    One player's rollover check (the 30 s loop): a new UTC day rolls the
    missions and pays yesterday's done-but-unclaimed ones; a profile from a
    season that has ended moves into the current one. Each change is a
    DataService.update with its toast. Never yields.
]]
function MissionService.rollover(player)
	local profile = services.DataService.get(player)
	if not profile then
		return
	end
	local now = os.time()
	local day = Missions.dayIndex(now)
	if Missions.isNewDay(profile.Missions, day) then
		local paid, levelBefore, levelAfter = services.DataService.update(player, function(p)
			local before = Ranks.levelFromXP(p.XP)
			local rolled = rollTo(p, player.UserId, day)
			return rolled, before, (Ranks.levelFromXP(p.XP))
		end)
		if paid then
			toast(player, paidText(paid))
			levelChanged(player, levelBefore, levelAfter)
		end
	end
	if Seasons.isBehind(profile, now) then
		local changed, change = services.DataService.update(player, function(p)
			return Seasons.ensure(p, now)
		end)
		if changed and change then
			local season = Seasons.byId(change.to) or Seasons.current(now)
			toast(player, season.Name .. " has begun! Your ratings were soft-reset.")
		end
	end
end

function MissionService.init(s)
	services = s
end

function MissionService.start()
	Net.get("MissionRequest").OnServerInvoke = function(player, action, index, day)
		local ok, result, message = pcall(MissionService.request, player, action, index, day)
		if not ok then
			warn("[MissionService]", action, "failed:", result)
			return false, "Something went wrong."
		end
		return result, message
	end

	task.spawn(function()
		while true do
			task.wait(ROLLOVER_SECONDS)
			for _, player in Players:GetPlayers() do
				local ok, err = pcall(MissionService.rollover, player)
				if not ok then
					warn("[MissionService] rollover failed for", player.Name, err)
				end
			end
			-- Rate-limit state of players who left (MissionService has no PlayerRemoving hook).
			for player in buckets do
				if not player.Parent then
					buckets[player] = nil
				end
			end
		end
	end)
end

return MissionService
