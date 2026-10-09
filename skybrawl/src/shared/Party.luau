--[[
    Party rules shared by the server (PartyService, QueueService, RoomService)
    and the menus (which grey out what a party can't start).

    Allowed party sizes per queue:
      Ranked1v1  1        Bots Duel  1
      Ranked2v2  1-2      Bots 2v2   1-2
      FFA        1-4      Bots FFA   1-3
      Custom     1-4 (custom rooms)

    Pure: no services, no clocks.
]]

local Config = require(script.Parent.Config)

local Party = {}

Party.MaxSize = Config.Party.MaxSize

local LIMITS = {
	Ranked1v1 = { 1, 1 },
	Ranked2v2 = { 1, 2 },
	FFA = { 1, Config.Party.MaxSize },
	Custom = { 1, Config.Party.MaxSize },
}

local BOTS_LIMITS = {
	Duel = { 1, 1 },
	["2v2"] = { 1, 2 },
	FFA = { 1, 3 },
}

local LABELS = {
	Ranked1v1 = "Ranked 1v1",
	Ranked2v2 = "Ranked 2v2",
	FFA = "Free-for-all",
	Custom = "Custom rooms",
}

local function formatOf(format)
	return BOTS_LIMITS[format] and format or "Duel"
end

-- Smallest and largest party that may start `queueType` (Bots: per format, Duel when unknown).
function Party.limits(queueType, botsFormat)
	if queueType == "Bots" then
		local limits = BOTS_LIMITS[formatOf(botsFormat)]
		return limits[1], limits[2]
	end
	local limits = LIMITS[queueType]
	if not limits then
		return 1, 1
	end
	return limits[1], limits[2]
end

local function labelFor(queueType, format)
	if queueType == "Bots" then
		return "vs Bots (" .. formatOf(format) .. ")"
	end
	return LABELS[queueType] or tostring(queueType)
end

--[[
    Whether a party of `partySize` may start `queueType`. Returns ok, code, text:
      NotLeader  "Only the party leader can start a search."
      TooMany    "<Label> is for 1 player. Leave your party to queue." (max 1), else
                 "<Label> allows up to <max> players. Your party has <size>."
]]
function Party.canStart(queueType, format, partySize, isLeader)
	if not isLeader then
		return false, "NotLeader", "Only the party leader can start a search."
	end
	local _, max = Party.limits(queueType, format)
	if partySize > max then
		local label = labelFor(queueType, format)
		if max == 1 then
			return false, "TooMany", label .. " is for 1 player. Leave your party to queue."
		end
		return false, "TooMany", string.format("%s allows up to %d players. Your party has %d.", label, max, partySize)
	end
	return true, nil, nil
end

-- Members plus outgoing invites must stay under the party size.
function Party.canInvite(memberCount, pendingCount)
	if memberCount + pendingCount >= Party.MaxSize then
		return false, "Your party is full."
	end
	return true, nil
end

-- Sorts invite candidates in place: friends first, then players in the menus, then by name (case-insensitive).
function Party.sortCandidates(list)
	table.sort(list, function(a, b)
		local fa, fb = a.isFriend == true, b.isFriend == true
		if fa ~= fb then
			return fa
		end
		local ma, mb = a.status == "Menu", b.status == "Menu"
		if ma ~= mb then
			return ma
		end
		local na, nb = string.lower(tostring(a.name)), string.lower(tostring(b.name))
		if na ~= nb then
			return na < nb
		end
		return (a.userId or 0) < (b.userId or 0)
	end)
	return list
end

return Party
