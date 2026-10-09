--[[
    Who plays whom in the quick-play queues (QueueService runs it every tick).

    The queue holds units: one player, or a party queuing together. A unit
    looks like { players = { Player }, rating = average rating, joined =
    os.clock() when it joined, ... }; these functions only read `players`,
    `rating` and `joined`, and never split a unit.

      window      the allowed rating gap for a unit that waited `waited`
                  seconds: grows from RatingWindowStart, capped at
                  RatingWindowMax, and anyone goes after AnyoneAfterSeconds
      pair1v1     Ranked 1v1: solo units, closest rating first
      group2v2    Ranked 2v2: duo vs duo, then duo vs two solos, then four
                  solos (highest + lowest vs the middle two)
      groupFFA    Free-for-all: groups of up to 4 players in join order;
                  starts full, or with 2+ after FFAStartAfterSeconds (topped
                  up with bots when FFAFillWithBots)

    Pure: no services, no clocks (`now` is passed in, on the same clock as
    `joined`).
]]

local Config = require(script.Parent.Config)

local Q = Config.Queue

local Matchmaking = {}

function Matchmaking.window(waited)
	if waited >= Q.AnyoneAfterSeconds then
		return math.huge
	end
	return math.min(Q.RatingWindowMax, Q.RatingWindowStart + Q.RatingWindowGrowth * math.max(0, waited))
end

local function windowOf(unit, now)
	return Matchmaking.window(now - unit.joined)
end

-- The smallest window among `units`: every unit in a match must accept the gap.
local function minWindow(units, now)
	local allowed = math.huge
	for _, unit in units do
		allowed = math.min(allowed, windowOf(unit, now))
	end
	return allowed
end

local function byRating(a, b)
	if a.rating ~= b.rating then
		return a.rating < b.rating
	end
	return a.joined < b.joined
end

local function byJoined(a, b)
	return a.joined < b.joined
end

local function sizeOf(unit)
	return #unit.players
end

local function withSize(units, size)
	local list = {}
	for _, unit in units do
		if sizeOf(unit) == size then
			table.insert(list, unit)
		end
	end
	return list
end

local function without(list, used)
	local out = {}
	for _, unit in list do
		if not used[unit] then
			table.insert(out, unit)
		end
	end
	return out
end

--[[
    Solo units only. Greedy over rating order: each unit is paired with the
    closest later unit whose gap fits both windows. Returns { { a, b } } with
    a the lower rating.
]]
function Matchmaking.pair1v1(units, now)
	local list = withSize(units, 1)
	table.sort(list, byRating)
	local used = {}
	local result = {}
	for i, a in list do
		if not used[a] then
			local best, bestGap
			for j = i + 1, #list do
				local b = list[j]
				if not used[b] then
					local gap = math.abs(a.rating - b.rating)
					if gap <= math.min(windowOf(a, now), windowOf(b, now)) and (not best or gap < bestGap) then
						best, bestGap = b, gap
					end
				end
			end
			if best then
				used[a] = true
				used[best] = true
				table.insert(result, { a, best })
			end
		end
	end
	return result
end

--[[
    Teams of two players. A duo is never split. Priority:
      1. duo vs duo: neighbours in rating order whose gap fits every window
      2. duo vs two solos: oldest duo first, against the two solos whose
         average rating is closest to the duo's (within every window)
      3. four solos: a sliding window of 4 in rating order whose spread fits
         every window; highest + lowest vs the middle two
    Returns { { team1 = { unit }, team2 = { unit } } }.
]]
function Matchmaking.group2v2(units, now)
	local groups = {}
	local used = {}

	local duos = withSize(units, 2)
	table.sort(duos, byRating)
	local i = 1
	while i < #duos do
		local a, b = duos[i], duos[i + 1]
		if math.abs(a.rating - b.rating) <= minWindow({ a, b }, now) then
			used[a] = true
			used[b] = true
			table.insert(groups, { team1 = { a }, team2 = { b } })
			i += 2
		else
			i += 1
		end
	end

	local solos = withSize(units, 1)
	local leftDuos = without(duos, used)
	table.sort(leftDuos, byJoined)
	for _, duo in leftDuos do
		local free = without(solos, used)
		local best, bestGap
		for x = 1, #free do
			for y = x + 1, #free do
				local s1, s2 = free[x], free[y]
				local gap = math.abs(duo.rating - (s1.rating + s2.rating) / 2)
				if gap <= minWindow({ duo, s1, s2 }, now) and (not best or gap < bestGap) then
					best, bestGap = { s1, s2 }, gap
				end
			end
		end
		if best then
			used[duo] = true
			used[best[1]] = true
			used[best[2]] = true
			table.insert(groups, { team1 = { duo }, team2 = best })
		end
	end

	local rest = without(solos, used)
	table.sort(rest, byRating)
	local j = 1
	while j + 3 <= #rest do
		local four = { rest[j], rest[j + 1], rest[j + 2], rest[j + 3] }
		if four[4].rating - four[1].rating <= minWindow(four, now) then
			-- Highest + lowest vs the two middle players keeps the teams even.
			table.insert(groups, { team1 = { four[4], four[1] }, team2 = { four[3], four[2] } })
			j += 4
		else
			j += 1
		end
	end
	return groups
end

--[[
    Join order. Units are packed into groups of up to 4 players without
    splitting one: each group starts from the oldest unit not yet grouped and
    takes every later unit that still fits. A group starts when it has 4
    players, or 2+ players once its oldest unit waited FFAStartAfterSeconds.
    Returns { { units = { unit }, bots = n } } (bots fill the group up to 4
    when FFAFillWithBots).
]]
function Matchmaking.groupFFA(units, now)
	local list = table.clone(units)
	table.sort(list, byJoined)
	local maxPlayers = Config.Modes.FFA.MaxPlayers
	local grouped = {}
	local groups = {}
	for _, seed in list do
		if not grouped[seed] and sizeOf(seed) <= maxPlayers then
			grouped[seed] = true
			local members = { seed }
			local players = sizeOf(seed)
			for _, unit in list do
				if not grouped[unit] and players + sizeOf(unit) <= maxPlayers then
					grouped[unit] = true
					table.insert(members, unit)
					players += sizeOf(unit)
				end
			end
			local waited = now - seed.joined
			if players >= maxPlayers or (players >= 2 and waited >= Q.FFAStartAfterSeconds) then
				table.insert(groups, { units = members, bots = Q.FFAFillWithBots and (maxPlayers - players) or 0 })
			end
		end
	end
	return groups
end

return Matchmaking
