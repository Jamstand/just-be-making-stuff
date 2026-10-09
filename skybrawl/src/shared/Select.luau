--[[
    Legend select + map vote rules (SelectService runs the session, the
    legend-select screen shows it).

    A session table (built by SelectService) looks like:
      { id, mode, source, ranked, queueType?, label, rules, phase, endsAt,
        maps: { mapId }?, fixedMap: mapId?, votes: { [slotKey] = mapId },
        slots: { { key, name, userId, isBot, team, legend, locked, random,
                   ownLook, level?, rating?, title?, partyId?, left? } } }
    Select.viewState builds what one viewer may see of it: in ranked the
    other team's picks stay hidden until the VS splash (Select.vsState).

    Pure: no services, no clocks; randomness comes from the `rng` passed in
    (a Random).
]]

local Legends = require(script.Parent.Legends)

local Select = {}

-- Pickable legends ("Avatar" is your own look, toggled separately).
function Select.roster()
	local list = {}
	for _, id in Legends.Order do
		if id ~= "Avatar" then
			table.insert(list, id)
		end
	end
	return list
end

function Select.isValidPick(id)
	return Legends.isValid(id) or id == "Random"
end

function Select.resolveRandom(rng)
	local roster = Select.roster()
	return roster[rng:NextInteger(1, #roster)]
end

-- A random legend, preferring ones not in `avoid` (a set of legend ids).
function Select.botPick(rng, avoid)
	local roster = Select.roster()
	local free = {}
	for _, id in roster do
		if not (avoid and avoid[id]) then
			table.insert(free, id)
		end
	end
	local pool = #free > 0 and free or roster
	return pool[rng:NextInteger(1, #pool)]
end

-- `count` different maps from `pool` in random order (the whole pool, shuffled, when it is smaller).
function Select.candidates(pool, count, rng)
	local unique, seen = {}, {}
	for _, id in pool do
		if not seen[id] then
			seen[id] = true
			table.insert(unique, id)
		end
	end
	for i = #unique, 2, -1 do
		local j = rng:NextInteger(1, i)
		unique[i], unique[j] = unique[j], unique[i]
	end
	local out = {}
	for i = 1, math.min(count, #unique) do
		out[i] = unique[i]
	end
	return out
end

local function countVotes(votes, candidates)
	local counts = {}
	for _, id in candidates do
		counts[id] = 0
	end
	for _, mapId in votes or {} do
		if counts[mapId] then
			counts[mapId] += 1
		end
	end
	return counts
end

-- The winning map: most votes; ties broken with rng among the tied maps; no votes: rng among all candidates.
-- Returns mapId, { [mapId] = votes }.
function Select.tally(votes, candidates, rng)
	local counts = countVotes(votes, candidates)
	local best = 0
	for _, id in candidates do
		best = math.max(best, counts[id])
	end
	local tied = {}
	for _, id in candidates do
		if counts[id] == best then
			table.insert(tied, id)
		end
	end
	return tied[rng:NextInteger(1, #tied)], counts
end

-- Every human still in the session has locked in (false when there is nobody to wait for).
function Select.allLocked(slots)
	local any = false
	for _, slot in slots do
		if not slot.isBot and not slot.left then
			if not slot.locked then
				return false
			end
			any = true
		end
	end
	return any
end

-- Whether a viewer on `viewerTeam` may see this slot's pick before the VS splash.
function Select.canSee(slot, viewerTeam, ranked)
	return not ranked or slot.team == viewerTeam
end

-- The SelectState one viewer receives ("Begin" / "Update").
function Select.viewState(session, viewerKey)
	local viewerTeam = nil
	for _, slot in session.slots do
		if slot.key == viewerKey then
			viewerTeam = slot.team
		end
	end
	local slots = {}
	for _, slot in session.slots do
		local visible = Select.canSee(slot, viewerTeam, session.ranked)
		table.insert(slots, {
			key = slot.key,
			name = slot.name,
			userId = slot.userId or 0,
			isBot = slot.isBot == true,
			team = slot.team,
			isYou = slot.key == viewerKey,
			legend = if visible then slot.legend else nil,
			hidden = not visible,
			locked = slot.locked == true,
			random = visible and slot.random == true,
			ownLook = if visible then slot.ownLook == true else nil,
			level = slot.level,
			rating = slot.rating,
			title = slot.title,
			partyId = slot.partyId,
			left = slot.left == true,
		})
	end
	local maps = nil
	if session.maps then
		local counts = countVotes(session.votes, session.maps)
		maps = {}
		for _, id in session.maps do
			table.insert(maps, { id = id, votes = counts[id] })
		end
	end
	local rules = session.rules or {}
	return {
		id = session.id,
		mode = session.mode,
		source = session.source,
		ranked = session.ranked == true,
		queueType = session.queueType,
		label = session.label,
		rules = { winRule = rules.winRule, stocks = rules.stocks, timeLimit = rules.timeLimit },
		phase = session.phase,
		endsAt = session.endsAt,
		maps = maps,
		fixedMap = session.fixedMap,
		yourVote = session.votes and session.votes[viewerKey],
		you = viewerKey,
		slots = slots,
	}
end

-- The VsState everyone receives once picks are final: every legend revealed, players who left omitted.
-- SelectService adds `matchId` (the Match it created) before sending it.
function Select.vsState(session, mapId, vsSeconds)
	local fighters = {}
	for _, slot in session.slots do
		if not slot.left then
			table.insert(fighters, {
				key = slot.key,
				name = slot.name,
				userId = slot.userId or 0,
				isBot = slot.isBot == true,
				team = slot.team,
				legend = slot.legend,
				ownLook = slot.ownLook == true,
				rating = slot.rating,
				level = slot.level,
				title = slot.title,
			})
		end
	end
	local rules = session.rules or {}
	return {
		id = session.id,
		mode = session.mode,
		source = session.source,
		ranked = session.ranked == true,
		label = session.label,
		rules = { winRule = rules.winRule, stocks = rules.stocks, timeLimit = rules.timeLimit },
		mapId = mapId,
		startsIn = vsSeconds,
		fighters = fighters,
	}
end

return Select
