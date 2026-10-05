--[[
    Custom rooms: player-hosted matches with their own rules.

    Hosts choose mode, win rule (stocks or timed), map, which weapons drop,
    a damage multiplier and friendly fire, and can add bots. Rooms can be:
      private      hidden from the browser; join with the 6-letter code
      friendsOnly  only the host's Roblox friends can see and join
      skill range  only players whose rating is inside [minRating, maxRating]

    The browser filters by mode, map, win rule, open slots, skill
    eligibility, friends' rooms and name search.

    Custom matches are unranked and pay reduced coins/XP (Config.Rewards).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Maps = require(Shared.Maps)
local Weapons = require(Shared.Weapons)
local Ranks = require(Shared.Ranks)
local Util = require(Shared.Util)
local Net = require(Shared.Net)

local RoomService = {}
local services

local rooms = {} -- [id] = room
local roomOf = {} -- [Player] = room
local nextId = 0
local nextBotId = 0
local friendCache = {} -- [Player] = { [hostUserId] = { value, time } }
local creating = {} -- [Player] = true while a Create request is in flight
local rng = Random.new()

local R = Config.Rooms

function RoomService.init(s)
	services = s
end

function RoomService.getRoomOf(player)
	return roomOf[player]
end

-- Helpers -----------------------------------------------------------------

local function isFriend(player, hostUserId)
	if player.UserId == hostUserId then
		return true
	end
	local cache = friendCache[player]
	if not cache then
		cache = {}
		friendCache[player] = cache
	end
	local hit = cache[hostUserId]
	if hit and os.clock() - hit.time < R.FriendCacheSeconds then
		return hit.value
	end
	local ok, value = pcall(function()
		return player:IsFriendsWith(hostUserId)
	end)
	value = ok and value == true
	cache[hostUserId] = { value = value, time = os.clock() }
	return value
end

local function ratingFor(player, mode)
	return services.ProgressionService.ratingOf(player, mode == "2v2" and "2v2" or "1v1")
end

local function filterName(text, player)
	local ok, result = pcall(function()
		local filtered = TextService:FilterStringAsync(text, player.UserId)
		return filtered:GetNonChatStringForBroadcastAsync()
	end)
	if ok and type(result) == "string" and #result > 0 then
		return result
	end
	return player.DisplayName .. "'s Room"
end

local function newCode()
	for _ = 1, 20 do
		local code = Util.randomCode(R.CodeLength, rng)
		local taken = false
		for _, room in rooms do
			if room.code == code then
				taken = true
			end
		end
		if not taken then
			return code
		end
	end
	return Util.randomCode(R.CodeLength + 2, rng)
end

local function clampNumber(value, min, max, default)
	if type(value) ~= "number" or value ~= value then
		return default
	end
	return math.clamp(value, min, max)
end

local function pickBool(value, default)
	if type(value) == "boolean" then
		return value
	end
	return default == true
end

local DEFAULT_SETTINGS = {
	mode = "FFA",
	winRule = "Stocks",
	stocks = 3,
	timeLimit = 180,
	mapId = "Random",
	damageMultiplier = 1,
	friendlyFire = false,
	private = false,
	friendsOnly = false,
	minRating = nil,
	maxRating = nil,
	maxPlayers = 4,
}

-- Validates host-provided settings. `old` supplies anything missing.
local function sanitizeSettings(raw, old)
	raw = type(raw) == "table" and raw or {}
	old = old or DEFAULT_SETTINGS
	local s = {}
	s.mode = Config.Modes[raw.mode] and raw.mode or old.mode
	local modeInfo = Config.Modes[s.mode]
	if s.mode == "FFA" then
		s.maxPlayers =
			math.floor(clampNumber(raw.maxPlayers, 2, modeInfo.MaxPlayers, old.maxPlayers or modeInfo.MaxPlayers))
	else
		s.maxPlayers = modeInfo.MaxPlayers
	end
	s.winRule = (raw.winRule == "Stocks" or raw.winRule == "Timed") and raw.winRule or old.winRule
	s.stocks = math.floor(clampNumber(raw.stocks, R.StocksMin, R.StocksMax, old.stocks))
	s.timeLimit = math.floor(clampNumber(raw.timeLimit, R.TimeMin, R.TimeMax, old.timeLimit))
	s.mapId = (raw.mapId == "Random" or Maps.get(raw.mapId)) and raw.mapId or old.mapId
	local mult = clampNumber(raw.damageMultiplier, R.DamageMultMin, R.DamageMultMax, old.damageMultiplier)
	s.damageMultiplier = math.floor(mult * 4 + 0.5) / 4
	s.friendlyFire = pickBool(raw.friendlyFire, old.friendlyFire)
	s.private = pickBool(raw.private, old.private)
	s.friendsOnly = pickBool(raw.friendsOnly, old.friendsOnly)

	if type(raw.weapons) == "table" then
		s.weapons = {}
		for _, weaponId in Weapons.Order do
			if raw.weapons[weaponId] == true then
				s.weapons[weaponId] = true
			end
		end
	else
		s.weapons = old.weapons and table.clone(old.weapons) or nil
	end
	if not s.weapons then
		s.weapons = {}
		for _, weaponId in Weapons.Order do
			s.weapons[weaponId] = true
		end
	end

	if raw.minRating == false or raw.maxRating == false then
		s.minRating, s.maxRating = nil, nil
	else
		local minR = raw.minRating ~= nil and clampNumber(raw.minRating, 0, 4000, nil) or old.minRating
		local maxR = raw.maxRating ~= nil and clampNumber(raw.maxRating, 0, 4000, nil) or old.maxRating
		if minR and maxR and minR > maxR then
			minR, maxR = maxR, minR
		end
		s.minRating = minR and math.floor(minR) or nil
		s.maxRating = maxR and math.floor(maxR) or nil
	end
	return s
end

local function humanCount(room)
	local n = 0
	for _, m in room.members do
		if m.player then
			n += 1
		end
	end
	return n
end

local function teamCounts(room)
	local counts = {}
	for _, m in room.members do
		counts[m.team] = (counts[m.team] or 0) + 1
	end
	return counts
end

-- Picks a team for a new member that fits the room's mode.
local function freeTeam(room)
	local counts = teamCounts(room)
	local mode = room.settings.mode
	if mode == "FFA" then
		for team = 1, 4 do
			if not counts[team] then
				return team
			end
		end
		return 1
	end
	local size = Config.Modes[mode].TeamSize
	local a, b = counts[1] or 0, counts[2] or 0
	if a <= b and a < size then
		return 1
	elseif b < size then
		return 2
	end
	return a <= b and 1 or 2
end

local function reassignTeams(room)
	-- Drop bots first when the room shrinks, then re-deal teams to whoever's left.
	while #room.members > room.settings.maxPlayers do
		local removed = false
		for i = #room.members, 1, -1 do
			if room.members[i].bot then
				table.remove(room.members, i)
				removed = true
				break
			end
		end
		if not removed then
			break
		end
	end
	local old = room.members
	room.members = {}
	for _, m in old do
		m.team = freeTeam(room)
		table.insert(room.members, m)
	end
end

local function publicState(room)
	local members = {}
	for _, m in room.members do
		local entry = {
			id = m.id,
			team = m.team,
			isBot = m.bot == true,
			difficulty = m.difficulty,
			isHost = m.player ~= nil and m.player == room.host,
		}
		if m.player then
			entry.name = m.player.DisplayName
			entry.userId = m.player.UserId
			local profile = services.DataService.get(m.player)
			if profile then
				entry.level = Ranks.levelFromXP(profile.XP)
				entry.rating = ratingFor(m.player, room.settings.mode)
			end
		else
			entry.name = m.name
		end
		table.insert(members, entry)
	end
	return {
		id = room.id,
		code = room.code,
		name = room.name,
		hostUserId = room.host and room.host.UserId or 0,
		settings = room.settings,
		state = room.state,
		members = members,
	}
end

local function pushRoom(room)
	local state = publicState(room)
	for _, m in room.members do
		if m.player and m.player.Parent then
			Net.get("RoomUpdate"):FireClient(m.player, state)
		end
	end
end

local function closeRoom(room)
	rooms[room.id] = nil
	for _, m in room.members do
		if m.player then
			roomOf[m.player] = nil
			if m.player.Parent then
				Net.get("RoomUpdate"):FireClient(m.player, nil)
			end
		end
	end
end

local function removeMember(room, player, kicked)
	for i, m in room.members do
		if m.player == player then
			table.remove(room.members, i)
			break
		end
	end
	roomOf[player] = nil
	if player.Parent then
		Net.get("RoomUpdate"):FireClient(player, nil)
		if kicked then
			Net.get("Toast"):FireClient(player, "You were removed from the room.", "warn")
		end
	end
	if humanCount(room) == 0 then
		closeRoom(room)
		return
	end
	if room.host == player then
		for _, m in room.members do
			if m.player then
				room.host = m.player
				Net.get("Toast"):FireClient(m.player, "You're the host now.", "info")
				break
			end
		end
	end
	pushRoom(room)
end

-- Join checks shared by browser joins and code joins.
local function canJoin(player, room, viaCode)
	if room.state ~= "Open" then
		return false, "That room is in a match. Try again when it's done."
	end
	if #room.members >= room.settings.maxPlayers then
		return false, "That room is full."
	end
	if room.settings.private and not viaCode then
		return false, "That room is private. Ask the host for the code."
	end
	-- Friends-only applies to code joins too; a leaked code doesn't bypass it.
	if room.settings.friendsOnly and not isFriend(player, room.host.UserId) then
		return false, "That room is for the host's friends only."
	end
	local rating = ratingFor(player, room.settings.mode)
	if room.settings.minRating and rating < room.settings.minRating then
		return false,
			string.format("Your rating (%d) is below this room's minimum (%d).", rating, room.settings.minRating)
	end
	if room.settings.maxRating and rating > room.settings.maxRating then
		return false,
			string.format("Your rating (%d) is above this room's maximum (%d).", rating, room.settings.maxRating)
	end
	return true
end

local function busyReason(player)
	if creating[player] then
		return "Your room is still being created."
	end
	if services.MatchService.getMatchOf(player) then
		return "You're in a match."
	end
	if roomOf[player] then
		return "Leave your current room first."
	end
	if not services.DataService.get(player) then
		return "Your profile is still loading."
	end
	return nil
end

-- Actions -----------------------------------------------------------------

local actions = {}

function actions.List(player, filters)
	filters = type(filters) == "table" and filters or {}
	local search = type(filters.search) == "string" and filters.search:lower():sub(1, 30) or ""
	local list = {}
	for _, room in rooms do
		local s = room.settings
		local visible = not s.private
		local friend = room.host and isFriend(player, room.host.UserId) or false
		if visible and s.friendsOnly and not friend then
			visible = false
		end
		if visible and filters.mode and filters.mode ~= "Any" and s.mode ~= filters.mode then
			visible = false
		end
		if visible and filters.mapId and filters.mapId ~= "Any" and s.mapId ~= filters.mapId then
			visible = false
		end
		if visible and filters.winRule and filters.winRule ~= "Any" and s.winRule ~= filters.winRule then
			visible = false
		end
		local full = #room.members >= s.maxPlayers
		if visible and filters.hideFull and full then
			visible = false
		end
		if visible and filters.hideInMatch and room.state ~= "Open" then
			visible = false
		end
		local rating = ratingFor(player, s.mode)
		local eligible = (not s.minRating or rating >= s.minRating) and (not s.maxRating or rating <= s.maxRating)
		if visible and filters.eligibleOnly and not eligible then
			visible = false
		end
		if visible and filters.friendsOnly and not friend then
			visible = false
		end
		if visible and search ~= "" and not room.name:lower():find(search, 1, true) then
			visible = false
		end
		if visible then
			local weaponCount = 0
			for _ in s.weapons do
				weaponCount += 1
			end
			table.insert(list, {
				id = room.id,
				name = room.name,
				hostName = room.host and room.host.DisplayName or "?",
				mode = s.mode,
				mapId = s.mapId,
				winRule = s.winRule,
				stocks = s.stocks,
				timeLimit = s.timeLimit,
				players = #room.members,
				maxPlayers = s.maxPlayers,
				inMatch = room.state ~= "Open",
				friendsOnly = s.friendsOnly,
				minRating = s.minRating,
				maxRating = s.maxRating,
				eligible = eligible,
				isFriend = friend,
				weaponCount = weaponCount,
				damageMultiplier = s.damageMultiplier,
			})
		end
	end
	table.sort(list, function(a, b)
		if a.isFriend ~= b.isFriend then
			return a.isFriend
		end
		if a.inMatch ~= b.inMatch then
			return not a.inMatch
		end
		return a.id > b.id
	end)
	return true, list
end

function actions.Create(player, raw)
	local busy = busyReason(player)
	if busy then
		return false, busy
	end
	services.QueueService.leave(player)
	local count = 0
	for _ in rooms do
		count += 1
	end
	if count >= R.MaxRooms then
		return false, "This server has too many rooms. Join one instead!"
	end
	raw = type(raw) == "table" and raw or {}
	local name = type(raw.name) == "string" and raw.name:sub(1, R.NameMaxLength) or ""
	name = name:gsub("^%s+", ""):gsub("%s+$", "")
	-- Filtering yields; block other requests from this player meanwhile.
	creating[player] = true
	local ok, filtered = pcall(function()
		return #name > 0 and filterName(name, player) or (player.DisplayName .. "'s Room")
	end)
	creating[player] = nil
	if not player.Parent then
		return false, "You left."
	end
	nextId += 1
	local room = {
		id = nextId,
		code = newCode(),
		name = ok and filtered or (player.DisplayName .. "'s Room"),
		host = player,
		settings = sanitizeSettings(raw, nil),
		members = {},
		state = "Open",
	}
	table.insert(room.members, { id = "u" .. player.UserId, player = player, team = 1 })
	rooms[room.id] = room
	roomOf[player] = room
	pushRoom(room)
	return true, publicState(room)
end

local function join(player, room, viaCode)
	local busy = busyReason(player)
	if busy then
		return false, busy
	end
	local ok, reason = canJoin(player, room, viaCode)
	if not ok then
		return false, reason
	end
	services.QueueService.leave(player)
	table.insert(room.members, { id = "u" .. player.UserId, player = player, team = freeTeam(room) })
	roomOf[player] = room
	pushRoom(room)
	return true, publicState(room)
end

function actions.Join(player, roomId)
	local room = type(roomId) == "number" and rooms[roomId]
	if not room then
		return false, "That room no longer exists."
	end
	return join(player, room, false)
end

function actions.JoinCode(player, code)
	if type(code) ~= "string" then
		return false, "Enter a room code."
	end
	code = code:upper():gsub("%s", "")
	for _, room in rooms do
		if room.code == code then
			return join(player, room, true)
		end
	end
	return false, "No room with that code."
end

function actions.Leave(player)
	local room = roomOf[player]
	if room then
		removeMember(room, player, false)
	end
	return true
end

local function hostRoom(player)
	local room = roomOf[player]
	if not room then
		return nil, "You're not in a room."
	end
	if room.host ~= player then
		return nil, "Only the host can do that."
	end
	if room.state ~= "Open" then
		return nil, "Wait for the current match to finish."
	end
	return room
end

function actions.Update(player, raw)
	local room, err = hostRoom(player)
	if not room then
		return false, err
	end
	local oldMode = room.settings.mode
	local oldMax = room.settings.maxPlayers
	local newSettings = sanitizeSettings(raw, room.settings)
	if humanCount(room) > newSettings.maxPlayers then
		return false,
			string.format(
				"That mode fits %d players, but %d are in the room.",
				newSettings.maxPlayers,
				humanCount(room)
			)
	end
	room.settings = newSettings
	if type(raw) == "table" and type(raw.name) == "string" then
		local name = raw.name:sub(1, R.NameMaxLength):gsub("^%s+", ""):gsub("%s+$", "")
		if #name > 0 then
			room.name = filterName(name, player)
		end
	end
	if room.settings.mode ~= oldMode or room.settings.maxPlayers < oldMax then
		reassignTeams(room)
	end
	pushRoom(room)
	return true, publicState(room)
end

function actions.SetTeam(player, payload)
	local room = roomOf[player]
	if not room or room.state ~= "Open" or type(payload) ~= "table" then
		return false, "Can't change teams right now."
	end
	if room.settings.mode == "FFA" then
		return false, "There are no teams in free-for-all."
	end
	local targetId = payload.memberId or ("u" .. player.UserId)
	if targetId ~= "u" .. player.UserId and room.host ~= player then
		return false, "Only the host can move other players."
	end
	local team = payload.team == 2 and 2 or 1
	local counts = teamCounts(room)
	local size = Config.Modes[room.settings.mode].TeamSize
	for _, m in room.members do
		if m.id == targetId then
			if m.team ~= team and (counts[team] or 0) >= size then
				return false, "That team is full."
			end
			m.team = team
			pushRoom(room)
			return true, publicState(room)
		end
	end
	return false, "Couldn't find that player."
end

function actions.Kick(player, memberId)
	local room, err = hostRoom(player)
	if not room then
		return false, err
	end
	for _, m in room.members do
		if m.id == memberId and m.player and m.player ~= player then
			removeMember(room, m.player, true)
			return true, publicState(room)
		end
	end
	return false, "Couldn't find that player."
end

function actions.AddBot(player, payload)
	local room, err = hostRoom(player)
	if not room then
		return false, err
	end
	if #room.members >= room.settings.maxPlayers then
		return false, "The room is full."
	end
	payload = type(payload) == "table" and payload or {}
	nextBotId += 1
	local difficulty = Config.Bots.Difficulties[payload.difficulty] and payload.difficulty or "Normal"
	table.insert(room.members, {
		id = "bot" .. nextBotId,
		bot = true,
		difficulty = difficulty,
		name = Util.pick(Config.Bots.Names, rng) .. " (Bot)",
		team = freeTeam(room),
	})
	pushRoom(room)
	return true, publicState(room)
end

function actions.RemoveBot(player, memberId)
	local room, err = hostRoom(player)
	if not room then
		return false, err
	end
	for i, m in room.members do
		if m.id == memberId and m.bot then
			table.remove(room.members, i)
			pushRoom(room)
			return true, publicState(room)
		end
	end
	return false, "Couldn't find that bot."
end

function actions.Start(player)
	local room, err = hostRoom(player)
	if not room then
		return false, err
	end
	local s = room.settings
	if #room.members < 2 then
		return false, "You need at least 2 fighters. Add a bot!"
	end
	if #room.members > s.maxPlayers then
		return false, "Too many fighters for this mode."
	end
	if s.mode ~= "FFA" then
		local counts = teamCounts(room)
		if not counts[1] or not counts[2] then
			return false, "Both teams need at least one fighter."
		end
		local size = Config.Modes[s.mode].TeamSize
		if counts[1] > size or counts[2] > size then
			return false, string.format("Teams can have at most %d fighter%s.", size, size == 1 and "" or "s")
		end
	end
	for _, m in room.members do
		if m.player and services.MatchService.getMatchOf(m.player) then
			return false, m.player.DisplayName .. " is still in another match."
		end
	end
	if not services.MatchService.hasFreeArena() then
		return false, "All arenas are busy. Try again in a moment."
	end

	local mapId = s.mapId
	if mapId == "Random" then
		mapId = Util.pick(Maps.Order, rng)
	end
	local participants = {}
	for _, m in room.members do
		if m.player then
			table.insert(participants, { player = m.player, team = m.team })
		else
			table.insert(participants, { bot = true, difficulty = m.difficulty, team = m.team, name = m.name })
		end
	end
	local config = {
		mode = s.mode,
		source = "Custom",
		ranked = false,
		mapId = mapId,
		winRule = s.winRule,
		stocks = s.stocks,
		timeLimit = s.winRule == "Timed" and s.timeLimit or Config.Match.DefaultTimeLimit,
		weapons = s.weapons,
		damageMultiplier = s.damageMultiplier,
		friendlyFire = s.friendlyFire,
		participants = participants,
		roomId = room.id,
	}
	room.state = "InMatch"
	pushRoom(room)
	local match, startErr = services.MatchService.startMatch(config)
	if not match then
		room.state = "Open"
		pushRoom(room)
		return false, startErr
	end
	return true, publicState(room)
end

function RoomService.onMatchFinished(roomId)
	local room = rooms[roomId]
	if not room then
		return
	end
	room.state = "Open"
	for i = #room.members, 1, -1 do
		local m = room.members[i]
		if m.player and not m.player.Parent then
			table.remove(room.members, i)
		end
	end
	if humanCount(room) == 0 then
		closeRoom(room)
	else
		pushRoom(room)
	end
end

function RoomService.start()
	Net.get("RoomRequest").OnServerInvoke = function(player, action, payload)
		local handler = type(action) == "string" and actions[action]
		if not handler then
			return false, "Bad request."
		end
		local ok, a, b = pcall(handler, player, payload)
		if not ok then
			warn("[RoomService]", action, "failed:", a)
			return false, "Something went wrong."
		end
		return a, b
	end

	Players.PlayerRemoving:Connect(function(player)
		local room = roomOf[player]
		if room then
			removeMember(room, player, false)
		end
		friendCache[player] = nil
		creating[player] = nil
	end)
end

return RoomService
