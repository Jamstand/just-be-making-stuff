--[[
    Pure view logic for the client shell (menus design 5.1-5.7): what the
    main menu, its chrome (player card, queue banner, party bar, featured
    tiles, daily missions) and the title screen show for a given state.
    No Instances here, so tests/ui can check it under Lune; the UI modules
    only draw what these functions return.

    Requires Shared modules only, through ReplicatedStorage (the test
    harness can't resolve script.Parent.Parent).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Events = require(Shared.Events)
local Legends = require(Shared.Legends)
local Maps = require(Shared.Maps)
local Ranks = require(Shared.Ranks)
local Seasons = require(Shared.Seasons)
local Select = require(Shared.Select)
local Util = require(Shared.Util)

local MenuModels = {}

-- The main menu's buttons, top to bottom (Wide), and the screen each opens.
MenuModels.BUTTONS = {
	{ id = "OnlinePlay", label = "ONLINE PLAY", icon = "swords" },
	{ id = "Practice", label = "PRACTICE", icon = "target" },
	{ id = "CustomRooms", label = "CUSTOM ROOMS", icon = "grid" },
	{ id = "Legends", label = "LEGENDS", icon = "person" },
	{ id = "Store", label = "STORE", icon = "bag" },
	{ id = "Rankings", label = "RANKINGS", icon = "trophy" },
	{ id = "Profile", label = "PROFILE", icon = "card" },
	{ id = "Settings", label = "SETTINGS", icon = "gear" },
}

-- The line under the button stack for the focused button.
MenuModels.DESCRIPTIONS = {
	OnlinePlay = "Ranked 1v1, Ranked 2v2 and Free-for-all against players on this server.",
	Practice = "Fight bots or test combos in the Training Room.",
	CustomRooms = "Make your own rules and play with friends.",
	Legends = "Pick your legend and see their moves.",
	Store = "Weapon colors, trails, KO effects and titles.",
	Rankings = "Ranked ladders for this season.",
	Profile = "Your stats and season badge.",
	Settings = "Camera, controls, gameplay and audio.",
	Missions = "Daily missions: rewards for the matches you play.",
}

-- Phases in which Roblox's chat window is hidden (section 2 item 5).
local CHAT_HIDDEN = { Title = true, Select = true, Vs = true }

local RANKED_QUEUES = { Ranked1v1 = true, Ranked2v2 = true }

-- Countdown text: "6d 4h", "7h 42m", "12m", "40s".
function MenuModels.timeLeft(seconds)
	seconds = math.max(0, math.floor(seconds))
	if seconds >= 86400 then
		return string.format("%dd %dh", seconds // 86400, (seconds % 86400) // 3600)
	elseif seconds >= 3600 then
		return string.format("%dh %dm", seconds // 3600, (seconds % 3600) // 60)
	elseif seconds >= 60 then
		return string.format("%dm", seconds // 60)
	end
	return string.format("%ds", seconds)
end

-- Roblox chat shows in Menu, Results and Match; it is hidden on the title, legend select and VS splash.
function MenuModels.chatEnabled(phase)
	return not CHAT_HIDDEN[phase]
end

--[[
    The FEATURED tiles at `now` (unix seconds): the active Config.Events
    first (in list order, with their time left), then Config.News. Each:
    { id, kind ("Event" | "News"), tag, title, body, color, image, screen,
    params, endsIn? }.
]]
function MenuModels.featuredTiles(now)
	local tiles = {}
	for _, event in Events.active(Config.Events, now) do
		table.insert(tiles, {
			id = event.Id,
			kind = "Event",
			tag = event.Tag or "EVENT",
			title = event.Title or "",
			body = event.Body or "",
			color = event.Color or Color3.fromRGB(236, 47, 59),
			image = event.Image or "",
			screen = event.Screen,
			params = event.ScreenParams,
			endsIn = Events.endsIn(event, now),
		})
	end
	for _, news in Config.News do
		table.insert(tiles, {
			id = news.Id,
			kind = "News",
			tag = news.Tag or "NEWS",
			title = news.Title or "",
			body = news.Body or "",
			color = news.Color or Color3.fromRGB(236, 47, 59),
			image = news.Image or "",
			screen = news.Screen,
			params = news.ScreenParams,
		})
	end
	return tiles
end

--[[
    The DAILY MISSIONS panel for a snapshot's Missions table (3.5) at `now`:
    { loading, resetIn, claimable, footer, expired, rows }. Each row: {
    index, text, short (the mission's short form for the phone panel when
    the snapshot has one, else its text), progress, goal, fraction, done,
    claimed, claimable, rerollable, status ("1/2" | "DONE"), tag ("CLAIM" |
    "CLAIMED" | nil), coins, xp, barColor ("Red" | "Gold") }. expired: the
    list's day is over (now >= resetAt) and the new one hasn't arrived;
    nothing is rerollable then (the server would refuse it). Loading (no
    profile yet): no rows.
]]
function MenuModels.missionRows(missions, now)
	if type(missions) ~= "table" or type(missions.list) ~= "table" then
		return { loading = true, resetIn = "", claimable = 0, footer = "", expired = false, rows = {} }
	end
	local expired = type(missions.resetAt) == "number" and now >= missions.resetAt
	local rows = {}
	for _, mission in missions.list do
		local goal = math.max(1, mission.goal or 1)
		local progress = math.clamp(mission.progress or 0, 0, goal)
		local done = mission.done == true
		local claimed = mission.claimed == true
		local text = mission.text or ""
		table.insert(rows, {
			index = mission.index,
			text = text,
			short = if type(mission.short) == "string" and mission.short ~= "" then mission.short else text,
			progress = progress,
			goal = goal,
			fraction = if done then 1 else progress / goal,
			done = done,
			claimed = claimed,
			claimable = done and not claimed,
			rerollable = missions.rerollAvailable == true and not done and not claimed and not expired,
			status = if done
				then "DONE"
				else string.format("%s/%s", Util.formatNumber(progress), Util.formatNumber(goal)),
			tag = if claimed then "CLAIMED" elseif done then "CLAIM" else nil,
			coins = mission.coins or 0,
			xp = mission.xp or 0,
			barColor = if done then "Gold" else "Red",
		})
	end
	local footer
	if Config.Missions.FreeRerolls <= 0 then
		footer = "No rerolls"
	elseif missions.rerollAvailable then
		footer = "1 free reroll left today"
	else
		footer = "Reroll used"
	end
	return {
		loading = false,
		resetIn = MenuModels.timeLeft((missions.resetAt or now) - now),
		claimable = missions.claimable or 0,
		footer = footer,
		expired = expired,
		rows = rows,
	}
end

--[[
    The queue banner for a QueueStatus (3.1), `since` seconds after it
    arrived: { title ("SEARCHING" | "WAITING FOR AN ARENA"), label, timer
    ("0:23", counting on locally), count ("3 in queue"), window
    ("±240 rating", ranked queues only, while the server reports one),
    ranked }.
]]
function MenuModels.queueLine(status, since)
	local ranked = RANKED_QUEUES[status.queue] == true
	local window = nil
	if ranked and type(status.window) == "number" then
		window = string.format("±%d rating", math.floor(status.window + 0.5))
	end
	return {
		title = if status.waitingForArena then "WAITING FOR AN ARENA" else "SEARCHING",
		label = status.label or "",
		timer = Util.formatTime((status.waited or 0) + math.max(0, math.floor(since or 0))),
		count = string.format("%d in queue", status.inQueue or 0),
		window = window,
		ranked = ranked,
	}
end

-- The player card's numbers for a snapshot (nil while loading).
function MenuModels.playerCard(profile)
	if type(profile) ~= "table" then
		return nil
	end
	local forNext = profile.XPForNext or 0
	local fraction = if forNext > 0 then math.clamp((profile.XPInLevel or 0) / forNext, 0, 1) else 1
	local rating = profile.Rating1v1 or Config.Ranked.StartRating
	local tier = Ranks.tier(rating)
	return {
		level = string.format("LV %d", profile.Level or 1),
		xpFraction = fraction,
		xpPercent = string.format("%d%%", math.floor(fraction * 100)),
		tier = tier.Name,
		tierUpper = string.upper(tier.Name),
		tierColor = tier.Color,
		rating = tostring(rating),
		coins = Util.formatNumber(profile.Coins or 0),
	}
end

-- True when you may invite: solo, or the leader of a party that has room (members + pending invites).
function MenuModels.canInvite(party, userId)
	if not party then
		return true
	end
	if party.leaderUserId ~= userId then
		return false
	end
	local count = #(party.members or {}) + #(party.pending or {})
	return count < (party.maxSize or Config.Party.MaxSize)
end

--[[
    The party bar's slots (Config.Party.MaxSize of them) for your party
    state: slot 1 is you, then the other members, then your party's pending
    invites, then empty slots. Each: { kind ("You" | "Member" | "Invited" |
    "Invite" | "Empty"), key, userId?, name?, legend?, isLeader?, status?,
    waiting?, label? }. The first empty slot reads "INVITE" for a player
    who may invite ("Invite" slots open the Invite screen); a party member
    who isn't the leader gets disabled "Empty" slots.
]]
function MenuModels.partySlots(party, _invites, you)
	local maxSize = (party and party.maxSize) or Config.Party.MaxSize
	local slots = {}
	local me = nil
	for _, member in (party and party.members) or {} do
		if member.userId == you.userId then
			me = member
		end
	end
	table.insert(slots, {
		kind = "You",
		key = "p" .. tostring(you.userId),
		userId = you.userId,
		name = you.name,
		legend = (me and me.legend) or you.legend or Legends.Default,
		isLeader = party ~= nil and party.leaderUserId == you.userId,
		inParty = party ~= nil,
	})
	for _, member in (party and party.members) or {} do
		if member.userId ~= you.userId and #slots < maxSize then
			table.insert(slots, {
				kind = "Member",
				key = "p" .. tostring(member.userId),
				userId = member.userId,
				name = member.name,
				legend = member.legend,
				isLeader = member.isLeader == true,
				status = member.status,
			})
		end
	end
	for _, pending in (party and party.pending) or {} do
		if #slots < maxSize then
			table.insert(slots, {
				kind = "Invited",
				key = "i" .. tostring(pending.userId),
				userId = pending.userId,
				name = pending.name,
				waiting = pending.waiting == true,
				label = if pending.waiting then "INVITED · IN A MATCH" else "INVITED...",
			})
		end
	end
	local mayInvite = MenuModels.canInvite(party, you.userId)
	local first = true
	while #slots < maxSize do
		table.insert(slots, {
			kind = if mayInvite then "Invite" else "Empty",
			key = "e" .. tostring(#slots + 1),
			label = if mayInvite and first then "INVITE" else "+",
		})
		first = false
	end
	return slots
end

-- Where focus goes when the focused party slot's key leaves the bar (its person left, or an empty place filled):
-- the slot now at `index` when it is an INVITE slot, else your own slot (1), never someone else's.
function MenuModels.partyFocusAfter(slots, index)
	local there = slots[index]
	if there and there.kind == "Invite" then
		return index
	end
	return 1
end

-- A member's status chip text ("" for the menus).
function MenuModels.statusText(status)
	if status == "Queue" then
		return "SEARCHING"
	elseif status == "Select" then
		return "PICKING"
	elseif status == "Match" then
		return "IN A MATCH"
	elseif status == "Training" then
		return "TRAINING"
	elseif status == "Room" then
		return "IN A ROOM"
	end
	return ""
end

--[[
    Invite prompts. The invite to prompt for now: the first one with a
    running countdown (busy ones have no expiresAt yet) from a party not in
    `answered` (a set of partyIds). Answers go by party, as PartyRequest's
    Accept / Decline do: an invite's expiresAt can't tell it apart, since
    the server converts it to server time again on every push, so the
    value differs a little each time.
]]
function MenuModels.promptInvite(invites, now, answered)
	for _, invite in invites or {} do
		local skip = answered ~= nil and answered[invite.partyId] == true
		if not skip and type(invite.expiresAt) == "number" and invite.expiresAt > now then
			return invite
		end
	end
	return nil
end

-- Forgets the answers (a set of partyIds) of parties with no invite in `invites`: a later invite prompts again.
function MenuModels.pruneAnswers(answered, invites)
	local live = {}
	for _, invite in invites or {} do
		live[invite.partyId] = true
	end
	for partyId in answered do
		if not live[partyId] then
			answered[partyId] = nil
		end
	end
end

--[[
    The main menu's hint bar: Confirm SELECT, Back CANCEL SEARCH while
    queued, X INVITE when allowed, Y CHANGE. While a mission row is focused
    (`mission` = { claimable, rerollable }) the labels say what its keys do
    there: Confirm CLAIM on a claimable row, X REROLL on a row that can be
    rerolled (the row's own X wins over INVITE then).
]]
function MenuModels.mainHints(queued, canInvite, mission)
	local claim = mission ~= nil and mission.claimable == true
	local reroll = mission ~= nil and mission.rerollable == true
	local hints = { { action = "Confirm", label = if claim then "CLAIM" else "SELECT" } }
	if queued then
		table.insert(hints, { action = "Back", label = "CANCEL SEARCH" })
	end
	if reroll then
		table.insert(hints, { action = "X", label = "REROLL" })
	elseif canInvite then
		table.insert(hints, { action = "X", label = "INVITE" })
	end
	table.insert(hints, { action = "Y", label = "CHANGE" })
	return hints
end

-- The menus' backdrop map: Config.Menu.BackdropMap, or for "Random" a random map that has a painted sky.
function MenuModels.backdropMap(choice, rng)
	if choice == "Random" then
		local painted = {}
		for _, mapId in Maps.Order do
			local images = Config.Art.SkyImages[mapId]
			local sky = if type(images) == "table" then images.Sky else images
			if type(sky) == "string" and sky ~= "" then
				table.insert(painted, mapId)
			end
		end
		if #painted > 0 then
			return painted[rng:NextInteger(1, #painted)]
		end
		return "SkyShip"
	end
	if type(choice) == "string" and Maps.List[choice] then
		return choice
	end
	return "SkyShip"
end

-- The title screen's corner labels: "<Season> · v<version>" and "<n> LEGENDS · <m> MAPS".
function MenuModels.titleLabels(now)
	local season = Seasons.current(now)
	return string.format("%s · v%s", string.upper(season.Name), Config.GameVersion),
		string.format("%d LEGENDS · %d MAPS", #Select.roster(), #Maps.Order)
end

return MenuModels
