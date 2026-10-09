--[[
    Legend select + map vote + VS timing, between "match found" and the
    Match (every mode except training).

    begin(config) reserves an arena slot, marks the players busy and sends
    SelectEvent "Begin" (each viewer's own SelectState: in ranked the other
    team's picks stay hidden, Select.viewState). Players hover, lock (or
    lock Random), toggle their own look and vote for one of
    Config.Select.MapChoices maps (SelectAction); changes go out as
    "Update" at most every BroadcastInterval. Bots are locked from the
    start. The pick phase ends at Config.Select.Seconds, or AllLockedDelay
    after every human locked in (an unlock resets that).

    finalize: unlocked players lock their hover, Random resolves, the vote
    is tallied, picks are saved as the profile's legend, then
    MatchService.startMatch builds the arena while everyone watches the VS
    splash ("Vs", Config.Select.VsSeconds). Players count as busy until the
    Match exists (busyReason asks getSessionOf).

    Leavers (onPlayerRemoving): ranked -> a loss for the leaver and everyone
    else back in the queue; casual FFA and bots -> a bot takes the slot;
    custom -> the slot is dropped (cancelled when the room's start rules no
    longer hold); a session left without humans is cancelled. Any error
    ends the session (cancelled, or its match abandoned once it exists),
    which always frees the slot and the players.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Legends = require(Shared.Legends)
local Maps = require(Shared.Maps)
local Select = require(Shared.Select)
local Cosmetics = require(Shared.Cosmetics)
local Ranks = require(Shared.Ranks)
local Util = require(Shared.Util)
local Net = require(Shared.Net)

local SelectService = {}
local services

local S = Config.Select
-- How often a session in its pick phase is stepped.
local STEP_SECONDS = 0.05

local LABELS = {
	Ranked1v1 = "Ranked 1v1",
	Ranked2v2 = "Ranked 2v2",
	FFA = "Free-for-all",
}

local sessions = {} -- [id] = session (pick phase)
local sessionOf = {} -- [Player] = session
local buckets = {} -- [Player] = { tokens, at }
local nextId = 0

function SelectService.init(s)
	services = s
end

function SelectService.getSessionOf(player)
	return sessionOf[player]
end

local function send(player, kind, data)
	if player.Parent then
		Net.get("SelectEvent"):FireClient(player, kind, data)
	end
end

-- Every human still in the session (not left), with their slot.
local function humans(session)
	local list = {}
	for player, slot in session.players do
		if not slot.left then
			table.insert(list, { player = player, slot = slot })
		end
	end
	return list
end

local function broadcastUpdate(session)
	session.dirty = false
	session.lastBroadcast = os.clock()
	for _, entry in humans(session) do
		send(entry.player, "Update", Select.viewState(session, entry.slot.key))
	end
end

local function labelFor(config)
	if config.source == "Custom" then
		return config.roomName or "Custom room"
	elseif config.queueType == "Bots" then
		local difficulty = config.botOptions and config.botOptions.difficulty or "Normal"
		return "vs Bots · " .. difficulty
	end
	return LABELS[config.queueType] or (Config.Modes[config.mode] and Config.Modes[config.mode].Label) or "Match"
end

local function releaseSlot(session)
	if not session.slotTaken and session.slot then
		session.slotTaken = true
		services.ArenaService.release(session.slot)
	end
end

local function forget(session)
	sessions[session.id] = nil
	for player in session.players do
		if sessionOf[player] == session then
			sessionOf[player] = nil
		end
	end
end

--[[
    Ends a session without a match. Frees the slot (unless a Match took
    it) and the players, tells the remaining humans (SelectEvent "Cancel"),
    reopens a custom room, and with opts.requeue puts the queue units back
    (opts.leavers are dropped from them). A Cancel says requeued = true only
    to the players the requeue really keeps (a unit whose party changed is
    told its search was cancelled instead).
]]
function SelectService.cancel(session, reason, opts)
	if session.phase == "Cancelled" then
		return
	end
	opts = opts or {}
	session.phase = "Cancelled"
	releaseSlot(session)
	local remaining = humans(session)
	forget(session)
	local config = session.config
	local requeue = opts.requeue == true and config.units ~= nil and config.queueType ~= nil
	-- (decided before anyone is told, with no yield until the requeue below; a failing lookup promises nobody a
	-- search, and never stops the Cancels)
	local kept = {}
	if requeue then
		local ok, result = pcall(services.QueueService.wouldRequeue, config.units, config.queueType, opts.leavers)
		if ok and type(result) == "table" then
			kept = result
		else
			warn("[SelectService] wouldRequeue failed:", result)
		end
	end
	for _, entry in remaining do
		send(entry.player, "Cancel", { id = session.id, reason = reason, requeued = kept[entry.player] == true })
	end
	if config.roomId then
		services.RoomService.onSelectCancelled(config.roomId)
	end
	if requeue then
		services.QueueService.requeue(config.units, config.queueType, opts.leavers)
	end
end

local function requeueOnError(session)
	local queueType = session.config.queueType
	return queueType ~= nil and queueType ~= "Bots"
end

-- Picks are final: lock everyone, tally the map, save legends, create the Match. Never yields.
local function finalize(session)
	local config = session.config
	session.phase = "Vs"
	for _, slot in session.slots do
		if not slot.left and not slot.isBot then
			if slot.legend == "Random" then
				slot.legend = Select.resolveRandom(session.rng)
				slot.random = true
			end
			slot.locked = true
		end
	end
	local mapId = session.fixedMap or Select.tally(session.votes, session.maps, session.rng)
	for _, slot in session.slots do
		local p = slot.participant
		if p and not slot.left then
			p.legend = slot.legend
			if slot.isBot then
				p.name = slot.name
			else
				p.ownLook = slot.ownLook == true
			end
		end
	end
	config.mapId = mapId
	for player, slot in session.players do
		if not slot.left then
			local legend = slot.legend
			-- the last pick is preselected next time (and shown on the main menu)
			local profile = services.DataService.get(player)
			if profile and profile.Legend ~= legend and Legends.isValid(legend) then
				services.DataService.update(player, function(data)
					data.Legend = legend
				end)
			end
		end
	end

	-- (built before the match exists, so a failure here still just cancels the session)
	local vs = Select.vsState(session, mapId, S.VsSeconds)

	local match, err = services.MatchService.startMatch(
		config,
		{ slot = session.slot, origin = session.origin, startAt = os.clock() + S.VsSeconds }
	)
	if not match then
		SelectService.cancel(session, err or "The match couldn't start.", { requeue = requeueOnError(session) })
		return
	end
	session.slotTaken = true -- the match releases it now
	session.match = match
	vs.matchId = match.id
	for _, entry in humans(session) do
		send(entry.player, "Vs", vs)
	end
	-- only now (the players are in the match, so never "free" in between)
	forget(session)
end

local function applyHover(session, slot, legend)
	if not slot.locked and slot.legend ~= legend then
		slot.legend = legend
		session.dirty = true
	end
end

-- One step of a session in its pick phase.
local function step(session, now)
	for player, pending in session.pendingHover do
		local slot = session.players[player]
		if not slot or slot.left then
			session.pendingHover[player] = nil
		elseif now - (session.hoverAt[player] or -math.huge) >= S.HoverInterval then
			session.pendingHover[player] = nil
			session.hoverAt[player] = now
			applyHover(session, slot, pending)
		end
	end
	if session.dirty and now - session.lastBroadcast >= S.BroadcastInterval then
		broadcastUpdate(session)
	end
	if Select.allLocked(session.slots) then
		session.lockedAt = session.lockedAt or now
		if now - session.lockedAt >= S.AllLockedDelay then
			finalize(session)
			return
		end
	else
		session.lockedAt = nil
	end
	if now >= session.deadline then
		finalize(session)
	end
end

--[[
    Steps a session; an error ends it. Without a match the session is
    cancelled (slot and players freed, units re-queued). When finalize
    failed after the Match was created, the match owns the slot and the
    players: it is abandoned, which tells everyone still on the VS splash
    (SelectEvent "Cancel") and frees them at its Cleanup.
]]
local function safeStep(session, now)
	local ok, err = pcall(step, session, now)
	if ok then
		return
	end
	warn("[SelectService] session", session.id, "failed:", err)
	local match = session.match
	if match then
		forget(session)
		local ended, endErr = pcall(match.Finish, match, "Abandoned", 0, {
			requeue = requeueOnError(session),
			reason = "Something went wrong.",
		})
		if not ended then
			warn("[SelectService] couldn't end the match of session", session.id, endErr)
		end
	elseif session.phase ~= "Cancelled" then
		local cancelled, cancelErr =
			pcall(SelectService.cancel, session, "Something went wrong.", { requeue = requeueOnError(session) })
		if not cancelled then
			warn("[SelectService] couldn't cancel session", session.id, cancelErr)
		end
	end
end

-- Steps every session in its pick phase (Heartbeat calls this every STEP_SECONDS).
local function stepAll(now)
	for _, session in table.clone(sessions) do
		if session.phase == "Pick" and now - session.lastStep >= STEP_SECONDS then
			session.lastStep = now
			safeStep(session, now)
		end
	end
end

-- Builds a session for `config` on a reserved arena slot (no module state is touched, so a failure leaves nothing
-- behind). Returns the session and each player's "Begin" view.
local function newSession(config, arenaSlot, origin)
	nextId += 1
	local rng = Random.new()
	local session = {
		id = nextId,
		mode = config.mode,
		source = config.source,
		ranked = config.ranked == true,
		queueType = config.queueType,
		label = labelFor(config),
		rules = { winRule = config.winRule, stocks = config.stocks, timeLimit = config.timeLimit },
		phase = "Pick",
		endsAt = workspace:GetServerTimeNow() + S.Seconds,
		votes = {},
		slots = {},
		-- server only
		config = config,
		slot = arenaSlot,
		origin = origin,
		rng = rng,
		deadline = os.clock() + S.Seconds,
		lockedAt = nil,
		dirty = false,
		lastBroadcast = -math.huge,
		lastStep = -math.huge,
		players = {}, -- [Player] = slot
		pendingHover = {}, -- [Player] = legend applied once HoverInterval has passed
		hoverAt = {}, -- [Player] = os.clock() of the last applied hover
		botCount = 0,
	}

	local taken = {}
	local botParticipants = {}
	for _, p in config.participants do
		if p.player then
			local player = p.player
			local profile = services.DataService.get(player)
			local legend = Select.isValidPick(p.legend) and p.legend
				or (profile and Legends.isValid(profile.Legend) and profile.Legend)
				or Legends.Default
			local title = profile and Cosmetics.resolve("Title", profile.Equipped.Title)
			local party = services.PartyService.getParty(player)
			local slot = {
				key = "p" .. player.UserId,
				name = player.DisplayName,
				userId = player.UserId,
				isBot = false,
				team = p.team,
				legend = legend,
				locked = false,
				random = false,
				ownLook = profile ~= nil and profile.Settings.FightAsAvatar == true,
				level = profile and Ranks.levelFromXP(profile.XP) or 1,
				rating = session.ranked and services.ProgressionService.ratingOf(player, config.mode) or nil,
				title = title and title.Name or nil,
				partyId = party and party.id or nil,
				left = false,
				participant = p,
			}
			taken[legend] = true
			session.players[player] = slot
			table.insert(session.slots, slot)
		elseif p.bot then
			table.insert(botParticipants, p)
		end
	end
	for _, p in botParticipants do
		session.botCount += 1
		local legend = Select.botPick(rng, taken)
		taken[legend] = true
		table.insert(session.slots, {
			key = "b" .. session.botCount,
			name = p.name or Util.pick(Config.Bots.Names, rng),
			userId = 0,
			isBot = true,
			team = p.team,
			legend = legend,
			locked = true,
			random = false,
			ownLook = false,
			title = (Config.Bots.Difficulties[p.difficulty] and p.difficulty or "Normal") .. " Bot",
			left = false,
			participant = p,
		})
	end
	-- session order: team 1 first, then team 2... (players before bots within a team)
	local order = {}
	for i, slot in session.slots do
		order[slot] = i
	end
	table.sort(session.slots, function(a, b)
		if a.team ~= b.team then
			return a.team < b.team
		end
		return order[a] < order[b]
	end)

	if config.mapId then
		session.fixedMap = config.mapId
	else
		session.maps = Select.candidates(config.mapPool or Maps.Order, S.MapChoices, rng)
	end

	local views = {}
	for player, slot in session.players do
		views[player] = Select.viewState(session, slot.key)
	end
	return session, views
end

--[[
    Starts the pick phase for a match config (MatchService's MatchConfig;
    mapId nil = vote among maps from config.mapPool). Returns the session,
    or nil and the reason (a bad config without players, a player is busy,
    no arena is free, or building the session failed: then the slot is
    released again and nobody is marked busy).
]]
function SelectService.begin(config)
	if type(config) ~= "table" or type(config.participants) ~= "table" then
		return nil, "Bad match config."
	end
	local anyHuman = false
	for _, p in config.participants do
		if type(p) ~= "table" then
			return nil, "Bad match config."
		end
		if p.player then
			anyHuman = true
			if sessionOf[p.player] or services.MatchService.busyReason(p.player) or not p.player.Parent then
				return nil, p.player.DisplayName .. " is busy right now."
			end
		end
	end
	if not anyHuman then
		return nil, "Bad match config."
	end
	local arenaSlot, origin = services.ArenaService.acquire("Match")
	if not arenaSlot then
		return nil, "All arenas are busy. Try again in a moment."
	end
	local built, session, views = pcall(newSession, config, arenaSlot, origin)
	if not built then
		warn("[SelectService] couldn't begin a session:", session)
		services.ArenaService.release(arenaSlot)
		return nil, "Something went wrong."
	end
	config.selectId = session.id

	-- The session is live from here (the step loop ends it however it goes), then each player gets their view.
	sessions[session.id] = session
	for player in session.players do
		sessionOf[player] = session
	end
	for player in session.players do
		local sent, err = pcall(send, player, "Begin", views[player])
		if not sent then
			warn("[SelectService] couldn't send Begin to", player.Name, err)
		end
	end
	return session
end

-- Actions --------------------------------------------------------------------------

local actions = {}

function actions.Hover(session, player, slot, data)
	if slot.locked or not Select.isValidPick(data.legend) then
		return
	end
	local now = os.clock()
	if now - (session.hoverAt[player] or -math.huge) >= S.HoverInterval then
		session.hoverAt[player] = now
		session.pendingHover[player] = nil
		applyHover(session, slot, data.legend)
	else
		-- applied by the loop once the interval has passed (the latest value wins)
		session.pendingHover[player] = data.legend
	end
end

function actions.Lock(session, player, slot, data)
	if slot.locked or not Select.isValidPick(data.legend) then
		return
	end
	session.pendingHover[player] = nil
	if data.legend == "Random" then
		slot.legend = Select.resolveRandom(session.rng)
		slot.random = true
	else
		slot.legend = data.legend
		slot.random = false
	end
	slot.locked = true
	session.dirty = true
end

function actions.Unlock(session, _player, slot)
	if not slot.locked then
		return
	end
	-- too late once the all-locked delay is over
	if session.lockedAt and os.clock() - session.lockedAt >= S.AllLockedDelay then
		return
	end
	slot.locked = false
	slot.random = false
	session.lockedAt = nil
	session.dirty = true
end

function actions.Look(session, _player, slot, data)
	if type(data.on) ~= "boolean" or slot.ownLook == data.on then
		return
	end
	slot.ownLook = data.on
	session.dirty = true
end

function actions.Vote(session, _player, slot, data)
	if not session.maps or type(data.mapId) ~= "string" or not table.find(session.maps, data.mapId) then
		return
	end
	if session.votes[slot.key] ~= data.mapId then
		session.votes[slot.key] = data.mapId
		session.dirty = true
	end
end

-- Per-player token bucket (real time).
local function allow(player)
	local now = os.clock()
	local bucket = buckets[player]
	if not bucket then
		bucket = { tokens = S.ActionBurst, at = now }
		buckets[player] = bucket
	end
	bucket.tokens = math.min(S.ActionBurst, bucket.tokens + (now - bucket.at) * S.ActionsPerSecond)
	bucket.at = now
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

local function onAction(player, kind, data)
	local session = sessionOf[player]
	local handler = type(kind) == "string" and actions[kind]
	if not session or session.phase ~= "Pick" or not handler or type(data) ~= "table" then
		return
	end
	local slot = session.players[player]
	if not slot or slot.left or not allow(player) then
		return
	end
	handler(session, player, slot, data)
end

-- Leavers -------------------------------------------------------------------------

local function teamSidesFilled(session)
	local teams = {}
	for _, p in session.config.participants do
		teams[p.team] = true
	end
	return teams[1] == true and teams[2] == true
end

-- Called by Main.server's PlayerRemoving coordinator (first). Never yields.
function SelectService.onPlayerRemoving(player)
	buckets[player] = nil
	local session = sessionOf[player]
	if not session or session.phase ~= "Pick" then
		return
	end
	local slot = session.players[player]
	local config = session.config
	sessionOf[player] = nil
	session.pendingHover[player] = nil
	session.votes[slot.key] = nil
	session.dirty = true
	if config.ranked then
		-- a dodge: the leaver takes a loss, the others go back in the queue (never a free win)
		slot.left = true
		local total, count = 0, 0
		for _, other in session.slots do
			if other.team ~= slot.team and other.rating then
				total += other.rating
				count += 1
			end
		end
		local opponentRating = count > 0 and total / count or Config.Ranked.StartRating
		-- (a failing loss never stops the cancel: the others must not be left in a session with a leaver)
		local applied, err = pcall(
			services.ProgressionService.applyLeaver,
			player,
			config.mode,
			opponentRating,
			slot.legend ~= "Random" and slot.legend or nil
		)
		if not applied then
			warn("[SelectService] applyLeaver failed:", err)
		end
		SelectService.cancel(session, player.DisplayName .. " left.", { requeue = true, leavers = { player } })
	elseif config.source == "Custom" then
		slot.left = true
		local index = table.find(config.participants, slot.participant)
		if index then
			table.remove(config.participants, index)
		end
		local teamMode = config.mode ~= "FFA"
		if #humans(session) == 0 then
			-- only bots are left: nobody to tell
			SelectService.cancel(session, "Everyone left.")
		elseif #config.participants < 2 or (teamMode and not teamSidesFilled(session)) then
			SelectService.cancel(session, "Not enough fighters left.")
		end
	else
		-- casual FFA and bots: a bot takes over the slot
		session.players[player] = nil
		local difficulty = config.source == "Bots" and config.botOptions and config.botOptions.difficulty
			or Config.Queue.FFAFillDifficulty
		local taken = {}
		for _, other in session.slots do
			taken[other.legend] = true
		end
		session.botCount += 1
		local participant = { bot = true, difficulty = difficulty, team = slot.team }
		local index = table.find(config.participants, slot.participant)
		if index then
			config.participants[index] = participant
		else
			table.insert(config.participants, participant)
		end
		slot.key = "b" .. session.botCount
		slot.name = Util.pick(Config.Bots.Names, session.rng)
		slot.userId = 0
		slot.isBot = true
		slot.legend = Select.botPick(session.rng, taken)
		slot.locked = true
		slot.random = false
		slot.ownLook = false
		slot.level = nil
		slot.rating = nil
		slot.title = difficulty .. " Bot"
		slot.partyId = nil
		slot.participant = participant
		if next(session.players) == nil then
			SelectService.cancel(session, "Everyone left.")
		end
	end
end

function SelectService.start()
	Net.get("SelectAction").OnServerEvent:Connect(function(player, kind, data)
		local ok, err = pcall(onAction, player, kind, data)
		if not ok then
			warn("[SelectService] action failed:", err)
		end
	end)
	RunService.Heartbeat:Connect(function()
		stepAll(os.clock())
	end)
end

return SelectService
