--[[
    Small match rules shared by the server's match flow (and testable on
    their own):

      mvp                the results row with the most KOs, then damage dealt
      botsParticipants   who plays on which team in a vs Bots match
      roomTeams          teams for a party joining a custom room together
      easiestBot         the easiest bot difficulty in a match (missions
                         anti-farming)

    Pure: no services, no clocks.
]]

local Config = require(script.Parent.Config)

local MatchRules = {}

-- The id of the row with the most KOs, then the most damage dealt; nil when nobody did anything. Ties keep the
-- earlier row (results come best team first).
function MatchRules.mvp(rows)
	local best
	for _, row in rows do
		local kos, damage = row.kos or 0, row.damageDealt or 0
		if kos > 0 or damage > 0 then
			if not best or kos > best.kos or (kos == best.kos and damage > best.damage) then
				best = { id = row.id, kos = kos, damage = damage }
			end
		end
	end
	return best and best.id or nil
end

local BOT_FORMATS = {
	Duel = { humans = 1 },
	["2v2"] = { humans = 2, teamSize = 2 },
	FFA = { humans = 3 },
}

--[[
    Participants for a vs Bots match (humans: the players, leader first):
      Duel  humans[1] on team 1, one bot on team 2
      2v2   the humans (1-2) on team 1, bots fill team 1 to 2, two bots on team 2
      FFA   humans on teams 1..n, bots on teams n+1..4
    Humans beyond what the format holds are left out (Party.canStart stops that earlier).
]]
function MatchRules.botsParticipants(format, humans, difficulty)
	local spec = BOT_FORMATS[format] or BOT_FORMATS.Duel
	local participants = {}
	local count = math.min(#humans, spec.humans)
	local function bot(team)
		table.insert(participants, { bot = true, difficulty = difficulty, team = team })
	end
	if format == "FFA" then
		for i = 1, count do
			table.insert(participants, { player = humans[i], team = i })
		end
		for team = count + 1, Config.Modes.FFA.MaxPlayers do
			bot(team)
		end
	elseif format == "2v2" then
		for i = 1, count do
			table.insert(participants, { player = humans[i], team = 1 })
		end
		for _ = count + 1, spec.teamSize do
			bot(1)
		end
		bot(2)
		bot(2)
	else
		table.insert(participants, { player = humans[1], team = 1 })
		bot(2)
	end
	return participants
end

--[[
    Teams for `joiningCount` players joining a room together (a party, the
    leader first). Team modes: everyone goes on the team with the most free
    space while it has room (TeamSize), the rest on the other team. FFA: each
    joiner takes the lowest free team number. `existing` = the room's members
    ({ team = n }).
]]
function MatchRules.roomTeams(mode, existing, joiningCount)
	local counts = {}
	for _, member in existing do
		counts[member.team] = (counts[member.team] or 0) + 1
	end
	local teams = {}
	if mode == "FFA" or not (Config.Modes[mode] and Config.Modes[mode].TeamSize) then
		local maxTeams = Config.Modes.FFA.MaxPlayers
		for _ = 1, joiningCount do
			local team = 1
			for candidate = 1, maxTeams do
				if not counts[candidate] then
					team = candidate
					break
				end
			end
			counts[team] = (counts[team] or 0) + 1
			table.insert(teams, team)
		end
		return teams
	end
	local size = Config.Modes[mode].TeamSize
	local first = (counts[2] or 0) < (counts[1] or 0) and 2 or 1
	local second = first == 1 and 2 or 1
	for _ = 1, joiningCount do
		local team
		if (counts[first] or 0) < size then
			team = first
		elseif (counts[second] or 0) < size then
			team = second
		else
			team = (counts[1] or 0) <= (counts[2] or 0) and 1 or 2
		end
		counts[team] = (counts[team] or 0) + 1
		table.insert(teams, team)
	end
	return teams
end

-- The easiest difficulty in the list by Config.Bots.DifficultyOrder; nil when the list is empty. An unknown
-- difficulty counts as the easiest (and is returned as is), so it can never make a match look harder than it was.
function MatchRules.easiestBot(difficulties)
	local easiest, easiestRank
	for _, difficulty in difficulties do
		local rank = table.find(Config.Bots.DifficultyOrder, difficulty) or 0
		if not easiest or rank < easiestRank then
			easiest, easiestRank = difficulty, rank
		end
	end
	return easiest
end

return MatchRules
