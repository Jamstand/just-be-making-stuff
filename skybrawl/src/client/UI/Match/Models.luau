--[[
    Pure view logic for the match flow screens (menus design 5.9, 5.10,
    5.13): legend select (slots, countdown, hint, tile tags, map vote, the
    Hover throttle), the VS splash (sides or FFA strips, the watchdog),
    the results screen (banner, subtitle, rows, buttons, rewards) and the
    phase decisions MatchClient, LegendSelect and VsSplash make on server
    events (phaseAfter, routeMatchEvent).

    Decided from plain data (server payloads, ClientState values) so it can
    be tested under Lune (tests/matchscreens.luau). Requires only Shared
    modules, through ReplicatedStorage.Shared (the harness can't resolve
    script.Parent.Parent). No instances, no clocks: `now` is passed in.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Legends = require(Shared.Legends)
local Maps = require(Shared.Maps)
local Rankings = require(Shared.Rankings)
local Ranks = require(Shared.Ranks)
local Util = require(Shared.Util)
local Weapons = require(Shared.Weapons)

local Models = {}

Models.TEAM_NAMES = { "RED", "BLUE", "GREEN", "YELLOW" }
Models.ONLINE_QUEUES = { Ranked1v1 = true, Ranked2v2 = true, FFA = true }

-- Phases ----------------------------------------------------------------------------

local CANCEL_SUFFIX = " You're back in the queue."

-- The toast for a cancelled select / VS: good when you were put back in the queue.
function Models.cancelToast(reason, requeued)
	local text = if type(reason) == "string" and reason ~= "" then reason else "Match cancelled."
	if requeued then
		return text .. CANCEL_SUFFIX, "good"
	end
	return text, "error"
end

--[[
    The toast for a match that ended before the fight and put you back in
    the queue (MatchEvent End / Leave with requeued): the End's note (why it
    ended, e.g. "Ann left before the fight." or "The match couldn't
    start.") when it has one.
]]
function Models.requeuedToast(note)
	local text = if type(note) == "string" and note ~= "" then note else "A player left before the fight."
	return Models.cancelToast(text, true)
end

--[[
    What the client phase becomes after an event. event = { type, id?,
    matchId?, reason?, requeued?, note? } with type:
      "Begin" / "Vs"   SelectEvent Begin / Vs (id = the session id)
      "Cancel"         SelectEvent Cancel (id, reason, requeued)
      "Start"          MatchEvent Start
      "MatchEnd"       MatchEvent End or Leave while no match is running (matchId, requeued, note)
      "Watchdog"       the VS splash waited too long for Start
      "Cleanup"        MatchClient finished cleaning up a match
      "SetupFailed"    MatchClient couldn't set up your fighter
    state = { phase, selectId?, vsId?, vsMatchId?, matchId? } (matchId: the
    running match's id, nil when none). Returns nil (no change) or
    { phase, toast?, toastKind? }.
]]
function Models.phaseAfter(event, state)
	local phase = state.phase
	local kind = event.type
	if kind == "Begin" then
		if phase == "Match" or phase == "Title" then
			return nil
		end
		return { phase = "Select" }
	elseif kind == "Vs" then
		if phase == "Match" or phase == "Title" then
			return nil
		end
		return { phase = "Vs" }
	elseif kind == "Cancel" then
		local mine = (phase == "Select" and event.id ~= nil and event.id == state.selectId)
			or (phase == "Vs" and event.id ~= nil and event.id == state.vsId)
		if not mine then
			return nil
		end
		local text, toastKind = Models.cancelToast(event.reason, event.requeued)
		return { phase = "Menu", toast = text, toastKind = toastKind }
	elseif kind == "MatchEnd" then
		-- the VS match died before "Start" (defensive; the server normally sends SelectEvent "Cancel" instead)
		if state.matchId ~= nil or state.vsMatchId == nil or event.matchId ~= state.vsMatchId then
			return nil
		end
		if phase ~= "Vs" and phase ~= "Select" then
			return nil
		end
		if event.requeued then
			local text, toastKind = Models.requeuedToast(event.note)
			return { phase = "Menu", toast = text, toastKind = toastKind }
		end
		return { phase = "Menu", toast = "The match couldn't start.", toastKind = "error" }
	elseif kind == "Watchdog" then
		if phase ~= "Vs" then
			return nil
		end
		return { phase = "Menu", toast = "The match didn't start. Back to the menu.", toastKind = "error" }
	elseif kind == "Start" then
		return { phase = "Match" }
	elseif kind == "Cleanup" then
		if phase ~= "Match" then
			return nil
		end
		return { phase = "Menu" }
	elseif kind == "SetupFailed" then
		if phase == "Select" or phase == "Results" then
			-- a select (or results) that took over while the fighter was being set up keeps its screen
			return nil
		end
		return { phase = "Menu", toast = "Couldn't set up your fighter.", toastKind = "error" }
	end
	return nil
end

--[[
    How MatchClient treats a MatchEvent: "start" (onStart), "orphan" (no match
    is running: only an End/Leave of the VS match matters, see phaseAfter),
    "ignore" (a late event of another match) or "handle".
]]
function Models.routeMatchEvent(kind, data, currentMatchId, running)
	if kind == "Start" then
		return "start"
	end
	if not running then
		return "orphan"
	end
	if type(data) ~= "table" or data.matchId ~= currentMatchId then
		return "ignore"
	end
	return "handle"
end

-- Seconds after the VS splash opened at which it gives up waiting for "Start".
function Models.watchdogSeconds(startsIn)
	local wait = if type(startsIn) == "number" then startsIn else Config.Select.VsSeconds
	return wait + Config.Match.LoadTimeout + Config.Menu.VsWatchdogExtra
end

function Models.watchdogDue(openedAt, startsIn, now)
	return now - openedAt >= Models.watchdogSeconds(startsIn)
end

-- Legend select --------------------------------------------------------------------

-- The grid: the roster, then My Avatar and Random (4 across, 2 down).
function Models.gridLegends()
	local list = {}
	for _, id in Legends.Order do
		if id ~= "Avatar" then
			table.insert(list, id)
		end
	end
	table.insert(list, "Avatar")
	table.insert(list, "Random")
	return list
end

-- Whole seconds left in the pick phase (never negative) and the ring's fill (1 = full time).
function Models.secondsLeft(endsAt, now)
	local left = (endsAt or now) - now
	local seconds = math.max(0, math.ceil(left - 1e-6))
	local fraction = math.clamp(left / Config.Select.Seconds, 0, 1)
	return seconds, fraction
end

-- Humans still in the session (bots and leavers don't count).
function Models.humanCount(state)
	local n = 0
	for _, slot in state.slots or {} do
		if not slot.isBot and not slot.left then
			n += 1
		end
	end
	return n
end

-- The caption under the countdown ring.
function Models.lockHint(state)
	local n = Models.humanCount(state)
	if n <= 1 then
		return "ENDS EARLY WHEN YOU LOCK IN"
	end
	return string.format("ENDS EARLY WHEN ALL %d LOCK IN", n)
end

-- "3 STOCKS · 8:00" or "TIMED · 3:00" (the rules tag).
function Models.rulesText(rules)
	rules = rules or {}
	if rules.winRule == "Timed" then
		return "TIMED · " .. Util.formatTime(rules.timeLimit or Config.Match.DefaultTimedLength)
	end
	local stocks = rules.stocks or Config.Match.DefaultStocks
	local text = string.format("%d STOCK%s", stocks, stocks == 1 and "" or "S")
	if (rules.timeLimit or 0) > 0 then
		text ..= " · " .. Util.formatTime(rules.timeLimit)
	end
	return text
end

-- Your slot in a SelectState.
function Models.youSlot(state)
	for _, slot in state.slots or {} do
		if slot.key == state.you or slot.isYou then
			return slot
		end
	end
	return nil
end

--[[
    The slot row: team modes { kind = "Teams", left = your team's slots,
    right = the others } (session order kept on each side); FFA { kind =
    "FFA", row = every slot by team number }.
]]
function Models.selectSlots(state)
	local slots = state.slots or {}
	if state.mode == "FFA" then
		local row = table.clone(slots)
		table.sort(row, function(a, b)
			return (a.team or 0) < (b.team or 0)
		end)
		return { kind = "FFA", row = row }
	end
	local you = Models.youSlot(state)
	local yourTeam = you and you.team or 1
	local left, right = {}, {}
	for _, slot in slots do
		table.insert(if slot.team == yourTeam then left else right, slot)
	end
	return { kind = "Teams", left = left, right = right }
end

--[[
    Where each slot of the slot row sits: { kind, signature, places = { {
    slot, column } } }, column 1-4 being the row's four positions. Team
    modes: your team on 1-2 (a lone fighter on 2, next to the VS), the
    others on 3-4 (alone: 3); FFA: 1-4 by team. LegendSelect matches its
    slot widgets to places by index, so a slot whose key changes (a leaver
    replaced by a bot keeps its place) is redrawn where it was; the
    signature changes only when the arrangement does (the row is rebuilt).
]]
function Models.slotPlaces(state)
	local layout = Models.selectSlots(state)
	local places = {}
	if layout.kind == "FFA" then
		for i, slot in layout.row do
			table.insert(places, { slot = slot, column = math.min(i, 4) })
		end
	else
		for i, slot in layout.left do
			table.insert(places, { slot = slot, column = if #layout.left == 1 then 2 else math.min(i, 2) })
		end
		for i, slot in layout.right do
			table.insert(places, { slot = slot, column = if #layout.right == 1 then 3 else math.min(i + 2, 4) })
		end
	end
	local parts = { layout.kind }
	for _, place in places do
		table.insert(parts, place.column .. ":" .. tostring(place.slot.team))
	end
	return { kind = layout.kind, signature = table.concat(parts, ","), places = places }
end

-- The hint bar: L1 / R1 only when there is a map to vote for.
function Models.selectHints(state)
	local items = {
		{ action = "Confirm", label = "LOCK IN" },
		{ action = "Back", label = "BACK" },
		{ action = "X", label = "RANDOM" },
		{ action = "Y", label = "AVATAR LOOK" },
	}
	if state.maps then
		table.insert(items, { action = "L1", label = "" })
		table.insert(items, { action = "R1", label = "VOTE MAP" })
	end
	return items
end

-- Letter-spaced caps ("S H A D O W   N I N J A"): a space between letters, three between words.
function Models.spaced(text)
	local words = {}
	for _, word in string.split(text or "", " ") do
		if word ~= "" then
			local letters = {}
			for _, code in utf8.codes(word) do
				table.insert(letters, utf8.char(code))
			end
			table.insert(words, table.concat(letters, " "))
		end
	end
	return table.concat(words, "   ")
end

-- A text size that shrinks for text longer than `maxChars` (base * maxChars / length), so it isn't truncated.
function Models.fitSize(text, base, maxChars)
	local length = utf8.len(text or "") or #(text or "")
	if length <= maxChars then
		return base
	end
	return math.floor(base * maxChars / length + 0.5)
end

-- A grid pick's name in caps ("RANDOM" for the Random tile).
function Models.legendName(id)
	if id == "Random" then
		return "RANDOM"
	end
	return string.upper(Legends.get(id).Name)
end

-- What a slot shows: the legend name or "HIDDEN", the state tag and its tone.
function Models.slotView(slot)
	local view = {
		name = slot.name .. (if slot.isYou then " (you)" else ""),
		legend = nil,
		legendText = "HIDDEN",
		tag = "SELECTING...",
		tone = "Muted",
		bot = slot.isBot == true,
	}
	if not slot.hidden and slot.legend then
		-- a Random lock stays a surprise until the VS splash (even the resolved legend you were dealt)
		view.legend = if slot.random then "Random" else slot.legend
		view.legendText = Models.legendName(view.legend)
	end
	if slot.left then
		view.tag, view.tone = "LEFT", "Danger"
	elseif slot.locked then
		view.tag, view.tone = "LOCKED IN", "Good"
	end
	return view
end

--[[
    Small "P<n>" tags on the grid: whose hover or pick sits on which tile.
    Your own pick isn't tagged; hidden picks (ranked opponents) can't be.
    Returns { [legendId] = { "P2", ... } } (n = the slot's place in the session).
]]
function Models.tileTags(state)
	local tags = {}
	for i, slot in state.slots or {} do
		if not slot.isYou and slot.key ~= state.you and not slot.hidden and not slot.left and slot.legend then
			local tile = if slot.random then "Random" else slot.legend
			tags[tile] = tags[tile] or {}
			table.insert(tags[tile], "P" .. i)
		end
	end
	return tags
end

--[[
    The map vote cards: { { id, name, votes, yours } } (three candidates), or
    one { id, name, fixed = true } card for a fixed map. `localVote` (a vote
    just sent, not confirmed yet) wins over the state's yourVote.
]]
function Models.mapCards(state, localVote)
	if not state.maps then
		local id = state.fixedMap
		local info = id and Maps.get(id)
		return { { id = id, name = info and info.Name or "Random map", fixed = true } }
	end
	local yours = localVote or state.yourVote
	local cards = {}
	for _, entry in state.maps do
		local info = Maps.get(entry.id)
		table.insert(cards, {
			id = entry.id,
			name = info and info.Name or entry.id,
			votes = entry.votes or 0,
			yours = entry.id == yours,
		})
	end
	return cards
end

-- "1 VOTE", "2 VOTES".
function Models.votesText(n)
	return string.format("%d VOTE%s", n, n == 1 and "" or "S")
end

-- The map L1 (delta -1) / R1 (+1) moves your vote to, wrapping; with no vote yet R1 takes the first, L1 the last.
function Models.nextVote(maps, current, delta)
	if not maps or #maps == 0 then
		return nil
	end
	local index = nil
	for i, entry in maps do
		if entry.id == current then
			index = i
		end
	end
	if not index then
		return maps[if delta < 0 then #maps else 1].id
	end
	return maps[(index - 1 + delta) % #maps + 1].id
end

--[[
    Throttles Hover sends: at most one per `interval` seconds, and the
    latest value is always sent once the interval is over (unless it is
    the value the server already has). `initial` is the legend the server
    already shows for you.
      push(value, now) -> value to send now, or nil
      poll(now)        -> the pending value once the interval is over, or nil
      reset(value)     the server has `value` (a Lock went out): nothing pending
]]
function Models.newHoverThrottle(interval, initial)
	local throttle = { sent = initial, sentAt = -math.huge, pending = nil }
	function throttle.push(value, now)
		if value == throttle.sent then
			throttle.pending = nil
			return nil
		end
		if now - throttle.sentAt >= interval then
			throttle.sent, throttle.sentAt, throttle.pending = value, now, nil
			return value
		end
		throttle.pending = value
		return nil
	end
	function throttle.poll(now)
		local value = throttle.pending
		if value == nil or now - throttle.sentAt < interval then
			return nil
		end
		throttle.pending = nil
		if value == throttle.sent then
			return nil
		end
		throttle.sent, throttle.sentAt = value, now
		return value
	end
	function throttle.reset(value)
		throttle.sent, throttle.pending = value, nil
	end
	return throttle
end

-- What the info block shows for a grid tile.
function Models.legendInfo(id)
	if id == "Random" then
		return {
			name = "RANDOM",
			title = "A SURPRISE PICK",
			color = Color3.fromRGB(107, 114, 130),
			stats = nil,
			weapons = { "???" },
			ultimate = "???",
		}
	end
	local legend = Legends.get(id)
	local stats = {}
	for _, stat in Legends.StatNames do
		table.insert(stats, { name = string.upper(stat), value = legend.Stats[stat] or 0 })
	end
	local weapons = {}
	if legend.Weapons then
		for _, weaponId in legend.Weapons do
			local info = Weapons.get(weaponId)
			table.insert(weapons, string.upper(info and info.Name or weaponId))
		end
	else
		table.insert(weapons, "ANY WEAPON")
	end
	return {
		name = string.upper(legend.Name),
		title = string.upper(legend.Title or ""),
		color = legend.Color,
		stats = stats,
		weapons = weapons,
		ultimate = string.upper(legend.Ultimate and legend.Ultimate.Name or ""),
	}
end

-- VS splash -------------------------------------------------------------------------

--[[
    How the VS splash splits the fighters. Team modes: { kind = "Teams",
    left = your team (you first), right = the other team } (front fighter
    first on each side). FFA: { kind = "FFA", strips = { { fighter, team,
    x0 } } } by team number, strip k starting at x (k - 1) / n.
]]
function Models.vsLayout(vs, userId)
	local fighters = table.clone(vs.fighters or {})
	table.sort(fighters, function(a, b)
		return (a.team or 0) < (b.team or 0)
	end)
	if vs.mode == "FFA" then
		local strips = {}
		for k, fighter in fighters do
			table.insert(strips, { fighter = fighter, team = fighter.team, x0 = (k - 1) / #fighters })
		end
		return { kind = "FFA", strips = strips }
	end
	local yourTeam = nil
	for _, fighter in fighters do
		if not fighter.isBot and fighter.userId == userId then
			yourTeam = fighter.team
		end
	end
	yourTeam = yourTeam or (fighters[1] and fighters[1].team) or 1
	local left, right = {}, {}
	for _, fighter in fighters do
		if fighter.team == yourTeam then
			if not fighter.isBot and fighter.userId == userId then
				table.insert(left, 1, fighter)
			else
				table.insert(left, fighter)
			end
		else
			table.insert(right, fighter)
		end
	end
	return { kind = "Teams", left = left, right = right }
end

-- Results ---------------------------------------------------------------------------

local function ordinal(n)
	local suffix = "TH"
	if n % 100 < 11 or n % 100 > 13 then
		suffix = ({ "ST", "ND", "RD" })[n % 10] or "TH"
	end
	return tostring(n) .. suffix
end

function Models.yourRow(data)
	for _, row in data.results or {} do
		if row.id == data.you then
			return row
		end
	end
	return nil
end

--[[
    The big banner: { text, tone } with tone "Win" (gold), "Loss" (red) or
    "Neutral" (grey). VICTORY / DEFEAT, "1ST PLACE"... in FFA, DRAW, and
    MATCH ENDED for an abandoned match.
]]
function Models.banner(data)
	local you = Models.yourRow(data)
	if data.reason == "Abandoned" or not you then
		return { text = "MATCH ENDED", tone = "Neutral" }
	end
	if data.draw then
		return { text = "DRAW", tone = "Neutral" }
	end
	if data.mode == "FFA" then
		local place = you.placement or 1
		return { text = ordinal(place) .. " PLACE", tone = if place == 1 then "Win" else "Loss" }
	end
	if you.won then
		return { text = "VICTORY", tone = "Win" }
	end
	return { text = "DEFEAT", tone = "Loss" }
end

-- KOs per team.
function Models.teamKOs(results)
	local kos = {}
	for _, row in results or {} do
		kos[row.team] = (kos[row.team] or 0) + (row.kos or 0)
	end
	return kos
end

--[[
    The chip under the banner: team modes "RED TEAM WINS · 3 - 1" (team KO
    totals, the winners' first), "DRAW · 2 - 2"; FFA "<NAME> WINS"; nil for
    an abandoned match.
]]
function Models.subtitle(data)
	if data.reason == "Abandoned" then
		return nil
	end
	local results = data.results or {}
	if data.mode == "FFA" then
		local best = nil
		for _, row in results do
			if not best or (row.placement or 99) < (best.placement or 99) then
				best = row
			end
		end
		if data.draw or not best then
			return "DRAW"
		end
		return string.upper(best.name) .. " WINS"
	end
	local kos = Models.teamKOs(results)
	local teams = {}
	for team in kos do
		table.insert(teams, team)
	end
	table.sort(teams)
	local winner = data.winnerTeam
	if data.draw or not winner or not kos[winner] then
		local a, b = kos[teams[1]] or 0, kos[teams[2]] or 0
		return string.format("DRAW · %d - %d", a, b)
	end
	local other = 0
	for _, team in teams do
		if team ~= winner then
			other += kos[team]
		end
	end
	local name = Models.TEAM_NAMES[winner] or ("TEAM " .. winner)
	return string.format("%s TEAM WINS · %d - %d", name, kos[winner], other)
end

--[[
    The scoreboard rows grouped by team, winners first (FFA: by placement).
    Returns { { team, rows = { { row, letter } } } } where letter is "W",
    "L", "D" or "-" (abandoned) in team modes and the placement in FFA.
]]
function Models.resultGroups(data)
	local results = data.results or {}
	local groups, byTeam = {}, {}
	for index, row in results do
		local group = byTeam[row.team]
		if not group then
			group = { team = row.team, rows = {}, best = math.huge, first = index }
			byTeam[row.team] = group
			table.insert(groups, group)
		end
		group.best = math.min(group.best, row.placement or math.huge)
		table.insert(group.rows, row)
	end
	table.sort(groups, function(a, b)
		if a.best ~= b.best then
			return a.best < b.best
		end
		return a.first < b.first
	end)
	local out = {}
	for _, group in groups do
		local rows = {}
		for _, row in group.rows do
			local letter
			if data.mode == "FFA" then
				letter = tostring(row.placement or "-")
			elseif data.reason == "Abandoned" then
				letter = "-"
			elseif data.draw then
				letter = "D"
			else
				letter = if row.won then "W" else "L"
			end
			table.insert(rows, { row = row, letter = letter })
		end
		table.insert(out, { team = group.team, rows = rows })
	end
	return out
end

-- "Ranked 2v2", "Free-for-all", "vs Bots · 2v2", "Custom · 1v1".
function Models.modeLabel(data)
	local mode = Config.Modes[data.mode]
	local label = mode and mode.Label or tostring(data.mode or "")
	if data.ranked then
		return "Ranked " .. label
	elseif data.source == "Bots" then
		return "vs Bots · " .. label
	elseif data.source == "Custom" then
		return "Custom · " .. label
	end
	return label
end

-- The scoreboard header line: "Ranked 2v2 · Sky-Ship Deck · 4:12".
function Models.resultsHeader(data)
	local map = data.mapId and Maps.get(data.mapId)
	local parts = { Models.modeLabel(data) }
	if map then
		table.insert(parts, map.Name)
	end
	table.insert(parts, Util.formatTime(data.duration or 0))
	return table.concat(parts, " · ")
end

--[[
    The results buttons. opts = { party, userId, room }. Returns { primary,
    menu } where primary is nil or { kind, label, enabled, note }:
      kind "Queue"      QUEUE AGAIN (online queues)          leader only ("Leader queues")
      kind "Bots"       REMATCH (vs Bots)                    leader only ("Leader starts it")
      kind "RoomStart"  REMATCH (custom room host)           RoomRequest("Start") once the room is Open
      kind "RoomBack"   BACK TO ROOM (custom room guest)     back to the room screen (the host starts it)
    Leadership comes from the live party (no party, or you lead it).
]]
function Models.resultButtons(data, opts)
	opts = opts or {}
	local post = data.postMatch or {}
	local party = opts.party
	local leads = type(party) ~= "table" or party.leaderUserId == opts.userId
	local primary = nil
	if data.source ~= "Training" then
		if post.queueType and Models.ONLINE_QUEUES[post.queueType] then
			primary = { kind = "Queue", label = "QUEUE AGAIN", enabled = leads }
		elseif post.queueType == "Bots" then
			primary = { kind = "Bots", label = "REMATCH", enabled = leads }
		elseif post.roomId then
			local room = opts.room
			if type(room) == "table" and room.id == post.roomId then
				if room.hostUserId == opts.userId then
					primary = { kind = "RoomStart", label = "REMATCH", enabled = true }
				else
					primary = { kind = "RoomBack", label = "BACK TO ROOM", enabled = true }
				end
			end
		end
	end
	if primary and not primary.enabled then
		primary.note = if primary.kind == "Queue" then "Leader queues" else "Leader starts it"
	end
	return { primary = primary, menu = { label = "MENU" } }
end

-- "BACK TO MENU IN 0:20".
function Models.autoReturnText(seconds)
	return "BACK TO MENU IN " .. Util.formatTime(math.max(0, seconds))
end

-- The coins reason under +coins: "3 KOs · win".
function Models.coinReason(row, data)
	if not row then
		return ""
	end
	local kos = row.kos or 0
	local outcome = if data.reason == "Abandoned"
		then "ended"
		elseif data.draw then "draw"
		elseif row.won then "win"
		else "loss"
	return string.format("%d KO%s · %s", kos, kos == 1 and "" or "s", outcome)
end

local function multText(mult)
	if mult == math.floor(mult) then
		return string.format("%dx", mult)
	end
	return string.format("%gx", mult)
end

-- "2x XP · Double XP Shadow Week" when an event multiplier applied, else nil.
function Models.eventChip(rewards)
	if type(rewards) ~= "table" then
		return nil
	end
	local parts = {}
	if (rewards.xpMult or 1) > 1 then
		table.insert(parts, multText(rewards.xpMult) .. " XP")
	end
	if (rewards.coinMult or 1) > 1 then
		table.insert(parts, multText(rewards.coinMult) .. " COINS")
	end
	if #parts == 0 then
		return nil
	end
	local events = rewards.events or {}
	if #events > 0 then
		table.insert(parts, table.concat(events, ", "))
	end
	return table.concat(parts, " · ")
end

--[[
    The XP bar: level and fill before and after the match. { levelBefore,
    levelAfter, fromFraction, toFraction, levelUp, percent ("78%") }. The
    bar animates fromFraction -> 1 -> 0 -> toFraction across a level up.
    The levels are the server's (rewards.levelBefore / levelAfter); the
    fills come from xpTotal and xpTotal - xp. Should xpTotal - xp not be on
    the server's level before (XP paid outside this match's own gain), the
    bar starts empty on that level instead of guessing.
]]
function Models.xpBar(rewards)
	local total = rewards.xpTotal or 0
	local before = math.max(0, total - (rewards.xp or 0))
	local derivedBefore, intoBefore, needBefore = Ranks.levelFromXP(before)
	local derivedAfter, intoAfter, needAfter = Ranks.levelFromXP(total)
	local levelBefore = if type(rewards.levelBefore) == "number" then rewards.levelBefore else derivedBefore
	local levelAfter = if type(rewards.levelAfter) == "number" then rewards.levelAfter else derivedAfter
	local from = if needBefore and needBefore > 0 then intoBefore / needBefore else 1
	if derivedBefore ~= levelBefore then
		from = 0
	end
	local to = if needAfter and needAfter > 0 then intoAfter / needAfter else 1
	return {
		levelBefore = levelBefore,
		levelAfter = levelAfter,
		fromFraction = math.clamp(from, 0, 1),
		toFraction = math.clamp(to, 0, 1),
		levelUp = levelAfter > levelBefore,
		percent = string.format("%d%%", math.floor(math.clamp(to, 0, 1) * 100)),
	}
end

--[[
    The rating column (ranked only, else nil): { mode ("2V2 RATING"),
    rating, delta, deltaText ("+18"), tier, tierName ("SILVER"), fraction
    toward the next tier, nextText ("GOLD AT 1390", or "TOP TIER") }.
]]
function Models.ratingBar(rewards)
	if type(rewards) ~= "table" or not rewards.ratingMode or not rewards.ratingAfter then
		return nil
	end
	local after = rewards.ratingAfter
	local delta = after - (rewards.ratingBefore or after)
	local progress = Rankings.tierProgress(after)
	return {
		mode = string.upper(rewards.ratingMode) .. " RATING",
		rating = after,
		delta = delta,
		deltaText = if delta >= 0 then "+" .. delta else tostring(delta),
		tier = progress.tier,
		tierName = string.upper(progress.tier.Name),
		fraction = progress.fraction,
		nextText = if progress.next
			then string.format("%s AT %d", string.upper(progress.next.Name), progress.next.Min)
			else "TOP TIER",
	}
end

-- Up to 2 missions the match moved (finished ones first): { text, fraction, label ("2 / 5" or "DONE"), done }.
function Models.missionRows(rewards)
	local list = type(rewards) == "table" and rewards.missions or nil
	if type(list) ~= "table" then
		return {}
	end
	local sorted = table.clone(list)
	table.sort(sorted, function(a, b)
		if (a.justDone == true) ~= (b.justDone == true) then
			return a.justDone == true
		end
		return (a.index or 0) < (b.index or 0)
	end)
	local rows = {}
	for i = 1, math.min(2, #sorted) do
		local m = sorted[i]
		local goal = math.max(1, m.goal or 1)
		local progress = math.min(m.progress or 0, goal)
		table.insert(rows, {
			text = m.text or "",
			fraction = progress / goal,
			label = if m.done then "DONE" else string.format("%d / %d", progress, goal),
			done = m.done == true,
		})
	end
	return rows
end

return Models
