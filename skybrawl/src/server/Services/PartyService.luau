--[[
    Parties and invites (per server).

    A party exists from the leader's first invite and holds up to
    Config.Party.MaxSize players (members + pending invites). The leader
    (always members[1]; when they leave, the next member in join order
    takes over) starts searches, bots matches and room joins for everyone;
    members follow (QueueService and RoomService ask isLeader/membersOf).

    Invites: anyone on the server can be invited. A player in a match,
    select or training gets a waiting invite: no countdown until they are
    back in the menus, a queue or a room (then Config.Party.InviteSeconds),
    and it is dropped after WaitingInviteSeconds. A declined or expired
    invite can't be re-sent by that party for ReinviteCooldown seconds.
    Accepting is refused while busy.

    A party left with 1 member and no pending invites is disbanded; one left
    empty is disbanded at once. Member changes cancel the searches they touch
    (QueueService.onPartyChanged); a disband by itself never cancels one.

    Every change pushes PartyUpdate { party, invites } (the whole state) to
    the members and invitees concerned. Times in it are server times
    (workspace:GetServerTimeNow()); internally they are os.clock().
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Legends = require(Shared.Legends)
local Party = require(Shared.Party)
local Ranks = require(Shared.Ranks)
local Net = require(Shared.Net)

local FriendCache = require(script.Parent.FriendCache)

local PartyService = {}
local services

local P = Config.Party
local TICK_SECONDS = 1

--[[
    parties[id] = { id, leader: Player, members: { Player } (leader first, then join order),
                    pending: { [Player] = invite } }
    invite = { from: Player, sentAt: number, expiresAt: number?, waitingSince: number? }
    (os.clock() times; expiresAt nil = waiting for a busy invitee)
]]
local parties = {}
local partyOf = {} -- [Player] = party
local invitesTo = {} -- [Player] = { [partyId] = true }   (the invite record lives in party.pending)
local cooldown = {} -- [partyId] = { [userId] = os.clock() until which re-inviting is refused }
-- A solo party disbanded with re-invite cooldowns running passes them on to its leader's next party.
local carriedCooldown = {} -- [Player] = { [userId] = until }
local lastStatus = {} -- [Player] = PartyStatus last pushed
local buckets = {} -- [Player] = { tokens, at }
local nextPartyId = 0

local BUSY = { Match = true, Select = true, Training = true }

function PartyService.init(s)
	services = s
end

-- Queries ------------------------------------------------------------------------

function PartyService.getParty(player)
	return partyOf[player]
end

-- True when solo too.
function PartyService.isLeader(player)
	local party = partyOf[player]
	return party == nil or party.leader == player
end

-- { player } when solo; leader first otherwise.
function PartyService.membersOf(player)
	local party = partyOf[player]
	return party and table.clone(party.members) or { player }
end

-- "Menu" | "Queue" | "Select" | "Match" | "Training" | "Room"
function PartyService.statusOf(player)
	local match = services.MatchService.getMatchOf(player)
	if match then
		return match.training and "Training" or "Match"
	end
	if services.SelectService.getSessionOf(player) then
		return "Select"
	end
	if services.QueueService.isQueued(player) then
		return "Queue"
	end
	if services.RoomService.getRoomOf(player) then
		return "Room"
	end
	return "Menu"
end

local function countPending(party)
	local n = 0
	for _ in party.pending do
		n += 1
	end
	return n
end

local function countIncoming(player)
	local n = 0
	for _ in invitesTo[player] or {} do
		n += 1
	end
	return n
end

-- The os.clock() time until which `party` (or the solo `player` about to make one) can't re-invite `target`.
local function cooldownUntil(party, player, target)
	local list = party and cooldown[party.id] or carriedCooldown[player]
	return list and list[target.UserId] or 0
end

-- Payloads -----------------------------------------------------------------------

local function serverTime(clockTime)
	return workspace:GetServerTimeNow() + (clockTime - os.clock())
end

local function memberView(party, player)
	local profile = services.DataService.get(player)
	return {
		userId = player.UserId,
		name = player.DisplayName,
		level = profile and Ranks.levelFromXP(profile.XP) or 1,
		legend = profile and Legends.isValid(profile.Legend) and profile.Legend or Legends.Default,
		isLeader = party.leader == player,
		status = PartyService.statusOf(player),
	}
end

local function partyState(party)
	local members = {}
	for _, member in party.members do
		table.insert(members, memberView(party, member))
	end
	local pending = {}
	for target, invite in party.pending do
		table.insert(pending, {
			userId = target.UserId,
			name = target.DisplayName,
			expiresAt = invite.expiresAt and serverTime(invite.expiresAt) or nil,
			waiting = invite.expiresAt == nil,
			sentAt = invite.sentAt,
		})
	end
	table.sort(pending, function(a, b)
		return a.sentAt < b.sentAt
	end)
	for _, entry in pending do
		entry.sentAt = nil
	end
	return {
		id = party.id,
		leaderUserId = party.leader.UserId,
		members = members,
		pending = pending,
		maxSize = P.MaxSize,
	}
end

local function invitesFor(player)
	local list = {}
	for partyId in invitesTo[player] or {} do
		local party = parties[partyId]
		local invite = party and party.pending[player]
		if invite then
			local from = table.find(party.members, invite.from) and invite.from or party.leader
			table.insert(list, {
				partyId = party.id,
				fromUserId = from.UserId,
				fromName = from.DisplayName,
				size = #party.members,
				expiresAt = invite.expiresAt and serverTime(invite.expiresAt) or nil,
			})
		end
	end
	table.sort(list, function(a, b)
		return a.partyId < b.partyId
	end)
	return list
end

local function toast(player, text, kind)
	if player.Parent then
		Net.get("Toast"):FireClient(player, text, kind or "info")
	end
end

function PartyService.pushPlayer(player)
	if not player.Parent then
		return
	end
	local party = partyOf[player]
	lastStatus[player] = PartyService.statusOf(player)
	Net.get("PartyUpdate"):FireClient(player, {
		party = party and partyState(party) or nil,
		invites = invitesFor(player),
	})
end

-- PartyUpdate to every member and every pending invitee.
function PartyService.push(party)
	for _, member in party.members do
		PartyService.pushPlayer(member)
	end
	for target in party.pending do
		PartyService.pushPlayer(target)
	end
end

-- Changes -------------------------------------------------------------------------

local function newParty(leader)
	nextPartyId += 1
	local party = { id = nextPartyId, leader = leader, members = { leader }, pending = {} }
	parties[party.id] = party
	partyOf[leader] = party
	-- a solo party's re-invite cooldowns live on with its leader
	cooldown[party.id] = carriedCooldown[leader]
	carriedCooldown[leader] = nil
	return party
end

-- Removes the party; its pending invites are dropped and everyone concerned is told.
local function disband(party)
	parties[party.id] = nil
	local invitees = {}
	for target in party.pending do
		if invitesTo[target] then
			invitesTo[target][party.id] = nil
		end
		table.insert(invitees, target)
	end
	party.pending = {}
	local members = party.members
	if #members == 1 then
		carriedCooldown[members[1]] = cooldown[party.id]
	end
	cooldown[party.id] = nil
	for _, member in members do
		if partyOf[member] == party then
			partyOf[member] = nil
		end
	end
	for _, member in members do
		PartyService.pushPlayer(member)
	end
	for _, target in invitees do
		PartyService.pushPlayer(target)
	end
end

-- After invites changed: a party of 1 without invites is disbanded, else everyone sees the new state.
local function settle(party)
	if parties[party.id] ~= party then
		return
	end
	if #party.members <= 1 and next(party.pending) == nil then
		disband(party)
	else
		PartyService.push(party)
	end
end

-- Drops one invite (and starts the re-invite cooldown when it was declined or expired).
local function dropInvite(party, target, withCooldown)
	if not party.pending[target] then
		return
	end
	party.pending[target] = nil
	if invitesTo[target] then
		invitesTo[target][party.id] = nil
		if next(invitesTo[target]) == nil then
			invitesTo[target] = nil
		end
	end
	if withCooldown then
		cooldown[party.id] = cooldown[party.id] or {}
		cooldown[party.id][target.UserId] = os.clock() + P.ReinviteCooldown
	end
	PartyService.pushPlayer(target)
end

--[[
    Takes `player` out of `party`. cause: "Leave" | "Kick" | "Switch" (they
    accepted another party's invite) | "Disconnect". Leadership passes to the
    next member; an empty party is disbanded at once, a party of 1 without
    invites too. Searches that included the player are cancelled.
]]
local function removeMember(party, player, cause)
	local index = table.find(party.members, player)
	if not index then
		return
	end
	table.remove(party.members, index)
	partyOf[player] = nil
	if #party.members == 0 then
		disband(party)
	else
		local newLeader = party.leader == player
		if newLeader then
			party.leader = party.members[1]
		end
		settle(party)
		if newLeader and parties[party.id] == party then
			for _, member in party.members do
				toast(member, party.leader.DisplayName .. " is the party leader now.", "info")
			end
		end
	end
	if cause ~= "Disconnect" then
		PartyService.pushPlayer(player)
	end
	local reason = cause == "Kick" and (player.DisplayName .. " was removed from the party. Search cancelled.")
		or (player.DisplayName .. " left the party. Search cancelled.")
	services.QueueService.onPartyChanged(party, { player }, reason)
end

-- Requests ------------------------------------------------------------------------

local actions = {}

function actions.List(player)
	local party = partyOf[player]
	local mayInvite = party == nil or party.leader == player
	local full = party ~= nil and not Party.canInvite(#party.members, countPending(party))
	local now = os.clock()
	local list = {}
	for _, other in Players:GetPlayers() do
		if other ~= player then
			local profile = services.DataService.get(other)
			local status = PartyService.statusOf(other)
			local inYourParty = party ~= nil and partyOf[other] == party
			local invited = party ~= nil and party.pending[other] ~= nil
			local reason
			if inYourParty then
				reason = "In your party"
			elseif invited then
				reason = "Invited"
			elseif not mayInvite then
				reason = "Leader invites"
			elseif full then
				reason = "Party full"
			elseif cooldownUntil(party, player, other) > now then
				reason = "Declined recently"
			elseif countIncoming(other) >= P.MaxIncomingInvites then
				reason = "Too many invites"
			end
			table.insert(list, {
				userId = other.UserId,
				name = other.DisplayName,
				username = other.Name,
				level = profile and Ranks.levelFromXP(profile.XP) or 1,
				isFriend = FriendCache.isFriend(player, other.UserId),
				status = status,
				inYourParty = inYourParty,
				invited = invited,
				canInvite = reason == nil,
				reason = reason,
			})
		end
	end
	return true, { players = Party.sortCandidates(list) }
end

function actions.Invite(player, userId)
	if type(userId) ~= "number" then
		return false, "Bad request."
	end
	local party = partyOf[player]
	if party and party.leader ~= player then
		return false, "Only the party leader can invite players."
	end
	local target = Players:GetPlayerByUserId(userId)
	if not target or target == player then
		return false, "That player isn't on this server."
	end
	local name = target.DisplayName
	if party and partyOf[target] == party then
		return false, name .. " is already in your party."
	end
	local existing = party and party.pending[target]
	if not existing then
		local ok, text = Party.canInvite(party and #party.members or 1, party and countPending(party) or 0)
		if not ok then
			return false, text
		end
		if countIncoming(target) >= P.MaxIncomingInvites then
			return false, name .. " has too many invites right now."
		end
	end
	if cooldownUntil(party, player, target) > os.clock() then
		return false, name .. " can't be invited again yet."
	end
	party = party or newParty(player)
	local now = os.clock()
	local busy = BUSY[PartyService.statusOf(target)] == true
	-- re-inviting refreshes the expiry
	party.pending[target] = {
		from = player,
		sentAt = existing and existing.sentAt or now,
		expiresAt = not busy and (now + P.InviteSeconds) or nil,
		waitingSince = busy and now or nil,
	}
	invitesTo[target] = invitesTo[target] or {}
	invitesTo[target][party.id] = true
	PartyService.push(party)
	if busy then
		return true, "Invite sent. " .. name .. " will see it after their match."
	end
	return true, "Invite sent to " .. name .. "."
end

function actions.Accept(player, partyId)
	if type(partyId) ~= "number" then
		return false, "Bad request."
	end
	local party = parties[partyId]
	local invite = party and party.pending[player]
	if not invite then
		return false, "That invite is no longer valid."
	end
	if BUSY[PartyService.statusOf(player)] or invite.expiresAt == nil then
		return false, "Finish your match first."
	end
	if os.clock() >= invite.expiresAt then
		dropInvite(party, player, true)
		settle(party)
		return false, "That invite has expired."
	end
	if #party.members >= P.MaxSize then
		return false, "That party is full."
	end
	-- Leave the current party first (an empty one is disbanded at once, its searches cancelled).
	local old = partyOf[player]
	if old then
		removeMember(old, player, "Switch")
	end
	dropInvite(party, player, false)
	table.insert(party.members, player)
	partyOf[player] = party
	for _, member in party.members do
		if member ~= player then
			toast(member, player.DisplayName .. " joined the party.", "good")
		end
	end
	PartyService.push(party)
	-- cancels the caller's own search and the party's search that no longer matches its members
	services.QueueService.onPartyChanged(party, { player }, "Party changed. Search cancelled.")
	return true, "You joined " .. party.leader.DisplayName .. "'s party."
end

function actions.Decline(player, partyId)
	local party = type(partyId) == "number" and parties[partyId] or nil
	local invite = party and party.pending[player]
	if party and invite then
		dropInvite(party, player, true)
		local inviter = table.find(party.members, invite.from) and invite.from or party.leader
		toast(inviter, player.DisplayName .. " declined.", "info")
		settle(party)
	end
	return true
end

function actions.Leave(player)
	local party = partyOf[player]
	if not party then
		return false, "You're not in a party."
	end
	removeMember(party, player, "Leave")
	return true, "You left the party."
end

function actions.Kick(player, userId)
	local party = partyOf[player]
	if not party or party.leader ~= player then
		return false, "Only the party leader can do that."
	end
	if type(userId) ~= "number" then
		return false, "Bad request."
	end
	if userId == player.UserId then
		return false, "Use Leave instead."
	end
	local target
	for _, member in party.members do
		if member.UserId == userId then
			target = member
		end
	end
	if not target then
		return false, "That player isn't in your party."
	end
	removeMember(party, target, "Kick")
	toast(target, "You were removed from the party.", "warn")
	return true, target.DisplayName .. " was removed from the party."
end

-- Per-player token bucket (real time).
local function allow(player)
	local now = os.clock()
	local bucket = buckets[player]
	if not bucket then
		bucket = { tokens = P.RequestBurst, at = now }
		buckets[player] = bucket
	end
	bucket.tokens = math.min(P.RequestBurst, bucket.tokens + (now - bucket.at) * P.RequestsPerSecond)
	bucket.at = now
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

-- Background -------------------------------------------------------------------

--[[
    Once a second: waiting invites start their countdown when the invitee
    is free again; expired and too-old waiting invites are dropped (with the
    re-invite cooldown); parties of 1 without invites are disbanded; a party
    whose members' status changed is pushed again.
]]
local function tick(now)
	for _, lists in { cooldown, carriedCooldown } do
		for key, list in lists do
			for userId, untilTime in list do
				if untilTime <= now then
					list[userId] = nil
				end
			end
			if next(list) == nil then
				lists[key] = nil
			end
		end
	end
	for _, party in table.clone(parties) do
		if parties[party.id] == party then
			local changed = false
			for target, invite in table.clone(party.pending) do
				if invite.expiresAt == nil then
					if not BUSY[PartyService.statusOf(target)] then
						invite.expiresAt = now + P.InviteSeconds
						invite.waitingSince = nil
						changed = true
					elseif now - invite.waitingSince >= P.WaitingInviteSeconds then
						dropInvite(party, target, true)
						changed = true
					end
				elseif now >= invite.expiresAt then
					dropInvite(party, target, true)
					changed = true
				end
			end
			for _, member in party.members do
				if lastStatus[member] ~= PartyService.statusOf(member) then
					changed = true
				end
			end
			if #party.members <= 1 and next(party.pending) == nil then
				disband(party)
			elseif changed then
				PartyService.push(party)
			end
		end
	end
end

-- Called by Main.server's PlayerRemoving coordinator. Never yields.
function PartyService.onPlayerRemoving(player)
	-- their incoming invites
	for partyId in table.clone(invitesTo[player] or {}) do
		local party = parties[partyId]
		if party then
			dropInvite(party, player, false)
			settle(party)
		end
	end
	invitesTo[player] = nil
	-- their party (its pending invites go with it when they were the last member)
	local party = partyOf[player]
	if party then
		removeMember(party, player, "Disconnect")
	end
	lastStatus[player] = nil
	buckets[player] = nil
	carriedCooldown[player] = nil
end

function PartyService.start()
	Net.get("PartyRequest").OnServerInvoke = function(player, action, payload)
		if not allow(player) then
			return false, "Slow down."
		end
		local handler = type(action) == "string" and actions[action]
		if not handler then
			return false, "Bad request."
		end
		local ok, a, b = pcall(handler, player, payload)
		if not ok then
			warn("[PartyService]", action, "failed:", a)
			return false, "Something went wrong."
		end
		return a, b
	end

	local nextTick = os.clock() + TICK_SECONDS
	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		if now < nextTick then
			return
		end
		nextTick = now + TICK_SECONDS
		local ok, err = pcall(tick, now)
		if not ok then
			warn("[PartyService] tick failed:", err)
		end
	end)
end

return PartyService
