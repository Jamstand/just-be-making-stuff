--[[
    Tests for the match flow screens' pure view logic
    (src/client/UI/Match/Models): legend select slots, countdown, hint and
    map vote, the Hover throttle, the VS layout and watchdog, the results
    banner, subtitle, rows, buttons and rating bar, and the phase decisions
    MatchClient, LegendSelect and VsSplash make on server events.
    Run from the skybrawl folder with:  lune run tests/matchscreens
]]

local h = require("./harness")

local Config = h.require("Config")
local Models = h.requireClientFile("UI/Match/Models")

local ME = 1

local function slot(key, team, opts)
	opts = opts or {}
	return {
		key = key,
		name = opts.name or key,
		userId = opts.userId or 0,
		isBot = opts.isBot == true,
		team = team,
		isYou = opts.isYou == true,
		legend = opts.legend,
		hidden = opts.hidden == true,
		locked = opts.locked == true,
		random = opts.random == true,
		left = opts.left == true,
	}
end

local function row(id, team, opts)
	opts = opts or {}
	return {
		id = id,
		name = opts.name or id,
		userId = opts.userId or 0,
		team = team,
		isBot = false,
		legend = "Kestrel",
		ownLook = false,
		placement = opts.placement or 1,
		kos = opts.kos or 0,
		falls = 0,
		damageDealt = 0,
		damageTaken = 0,
		stocks = 0,
		score = 0,
		won = opts.won == true,
		left = false,
		mvp = false,
	}
end

local function party(leader, others)
	local members = { { userId = leader, name = "P" .. leader, isLeader = true } }
	for _, id in others do
		table.insert(members, { userId = id, name = "P" .. id, isLeader = false })
	end
	return { id = 3, leaderUserId = leader, members = members, pending = {}, maxSize = 4 }
end

print("Results")

h.test("results banner reads VICTORY, DEFEAT, DRAW, the FFA place or MATCH ENDED", function()
	local results = { row("a", 1, { won = true }), row("b", 2, { placement = 2 }) }
	h.expect(Models.banner({ results = results, you = "a", mode = "1v1", reason = "Decided" }).text == "VICTORY")
	h.expect(Models.banner({ results = results, you = "a", mode = "1v1" }).tone == "Win", "victory is gold")
	local defeat = Models.banner({ results = results, you = "b", mode = "1v1", reason = "Decided" })
	h.expect(defeat.text == "DEFEAT" and defeat.tone == "Loss", "defeat")
	local draw = Models.banner({ results = results, you = "b", mode = "2v2", draw = true, reason = "Time" })
	h.expect(draw.text == "DRAW" and draw.tone == "Neutral", "draw")
	local ffa = {
		row("a", 1, { placement = 3 }),
		row("b", 2, { placement = 1, won = true }),
		row("c", 3, { placement = 2 }),
		row("d", 4, { placement = 4 }),
	}
	h.expect(Models.banner({ results = ffa, you = "b", mode = "FFA" }).text == "1ST PLACE", "1st")
	h.expect(Models.banner({ results = ffa, you = "c", mode = "FFA" }).text == "2ND PLACE", "2nd")
	local third = Models.banner({ results = ffa, you = "a", mode = "FFA" })
	h.expect(third.text == "3RD PLACE" and third.tone == "Loss", "3rd")
	h.expect(Models.banner({ results = ffa, you = "d", mode = "FFA" }).text == "4TH PLACE", "4th")
	local ended = Models.banner({ results = results, you = "a", mode = "1v1", reason = "Abandoned" })
	h.expect(ended.text == "MATCH ENDED" and ended.tone == "Neutral", "abandoned")
end)

h.test("results buttons: QUEUE AGAIN online, REMATCH for bots and custom, MENU always", function()
	local function buttons(postMatch, opts)
		return Models.resultButtons({ source = "Ranked", postMatch = postMatch }, opts or { userId = ME })
	end
	for _, queueType in { "Ranked1v1", "Ranked2v2", "FFA" } do
		local b = buttons({ queueType = queueType })
		h.expect(b.primary.kind == "Queue" and b.primary.label == "QUEUE AGAIN", queueType .. " queue again")
		h.expect(b.primary.enabled and b.menu.label == "MENU", queueType .. " enabled + menu")
	end
	local bots = buttons({ queueType = "Bots", botOptions = { format = "Duel", difficulty = "Hard" } })
	h.expect(bots.primary.kind == "Bots" and bots.primary.label == "REMATCH", "bots rematch")
	local room = { id = 9, hostUserId = ME, state = "Open" }
	local host = buttons({ roomId = 9 }, { userId = ME, room = room })
	h.expect(host.primary.kind == "RoomStart" and host.primary.label == "REMATCH", "host rematch")
	local guest = buttons({ roomId = 9 }, { userId = 2, room = { id = 9, hostUserId = ME } })
	h.expect(guest.primary.kind == "RoomBack" and guest.primary.label == "REMATCH", "guest back to the room")
	local gone = buttons({ roomId = 9 }, { userId = 2, room = nil })
	h.expect(gone.primary == nil and gone.menu.label == "MENU", "out of the room: MENU only")
	local training = Models.resultButtons({ source = "Training", postMatch = {} }, { userId = ME })
	h.expect(training.primary == nil and training.menu.label == "MENU", "training: MENU only")
end)

h.test("results queue again follows the live party leader", function()
	local data = { source = "Ranked", postMatch = { queueType = "Ranked2v2" } }
	local leader = Models.resultButtons(data, { userId = ME, party = party(ME, { 2 }) })
	h.expect(leader.primary.enabled and leader.primary.note == nil, "the leader may queue")
	local member = Models.resultButtons(data, { userId = ME, party = party(2, { ME }) })
	h.expect(not member.primary.enabled and member.primary.note == "Leader queues", "members can't")
	-- leadership passed to you after the match: the live party decides, not the match
	local promoted = Models.resultButtons(data, { userId = ME, party = party(ME, {}) })
	h.expect(promoted.primary.enabled, "new leader may queue")
	local bots = Models.resultButtons(
		{ source = "Bots", postMatch = { queueType = "Bots" } },
		{ userId = ME, party = party(2, { ME }) }
	)
	h.expect(not bots.primary.enabled and bots.primary.note == "Leader queues", "bots rematch is the leader's too")
end)

h.test("results rows group by team with the winners first", function()
	local data = {
		mode = "2v2",
		reason = "Decided",
		winnerTeam = 2,
		results = {
			row("a", 1, { placement = 2, kos = 1 }),
			row("b", 2, { placement = 1, won = true, kos = 2 }),
			row("c", 1, { placement = 2 }),
			row("d", 2, { placement = 1, won = true }),
		},
	}
	local groups = Models.resultGroups(data)
	h.expect(#groups == 2, "two teams")
	h.expect(groups[1].team == 2 and groups[2].team == 1, "winners first")
	h.expect(groups[1].rows[1].row.id == "b" and groups[1].rows[2].row.id == "d", "team 2 rows in order")
	h.expect(groups[2].rows[1].row.id == "a" and groups[2].rows[2].row.id == "c", "team 1 rows in order")
	h.expect(groups[1].rows[1].letter == "W" and groups[2].rows[2].letter == "L", "W / L letters")
	local ffa = Models.resultGroups({
		mode = "FFA",
		results = { row("x", 3, { placement = 2 }), row("y", 1, { placement = 1 }), row("z", 2, { placement = 3 }) },
	})
	h.expect(#ffa == 3 and ffa[1].rows[1].row.id == "y" and ffa[3].rows[1].row.id == "z", "FFA by placement")
	h.expect(ffa[1].rows[1].letter == "1" and ffa[2].rows[1].letter == "2", "FFA shows the placement")
	local abandoned =
		Models.resultGroups({ mode = "1v1", reason = "Abandoned", results = { row("a", 1), row("b", 2) } })
	h.expect(abandoned[1].rows[1].letter == "-", "abandoned has no W/L")
end)

h.test("results subtitle counts team KOs", function()
	local data = {
		mode = "2v2",
		reason = "Decided",
		winnerTeam = 1,
		results = {
			row("a", 1, { kos = 3, won = true }),
			row("b", 1, { kos = 0, won = true }),
			row("c", 2, { kos = 1 }),
			row("d", 2, { kos = 0 }),
		},
	}
	h.expect(Models.subtitle(data) == "RED TEAM WINS · 3 - 1", tostring(Models.subtitle(data)))
	data.winnerTeam = 2
	h.expect(Models.subtitle(data) == "BLUE TEAM WINS · 1 - 3", tostring(Models.subtitle(data)))
	data.draw, data.winnerTeam = true, nil
	h.expect(Models.subtitle(data) == "DRAW · 3 - 1", tostring(Models.subtitle(data)))
	local ffa = {
		mode = "FFA",
		reason = "Decided",
		results = { row("a", 1, { placement = 2 }), row("b", 2, { placement = 1, name = "NovaKick" }) },
	}
	h.expect(Models.subtitle(ffa) == "NOVAKICK WINS", tostring(Models.subtitle(ffa)))
	h.expect(Models.subtitle({ mode = "1v1", reason = "Abandoned", results = {} }) == nil, "abandoned: no chip")
end)

h.test("rating bar text names the next tier", function()
	local bar = Models.ratingBar({ ratingMode = "2v2", ratingBefore = 1218, ratingAfter = 1236 })
	h.expect(bar.mode == "2V2 RATING" and bar.rating == 1236, "mode and rating")
	h.expect(bar.deltaText == "+18" and bar.delta == 18, "delta " .. bar.deltaText)
	h.expect(bar.tierName == "SILVER", "tier " .. bar.tierName)
	h.expect(bar.nextText == "GOLD AT 1390", "next " .. bar.nextText)
	h.near(bar.fraction, (1236 - 1130) / (1390 - 1130), 1e-6, "fraction toward gold")
	local loss = Models.ratingBar({ ratingMode = "1v1", ratingBefore = 1400, ratingAfter = 1385 })
	h.expect(loss.deltaText == "-15" and loss.tierName == "SILVER" and loss.nextText == "GOLD AT 1390", "a loss")
	local top = Models.ratingBar({ ratingMode = "1v1", ratingBefore = 2100, ratingAfter = 2120 })
	h.expect(top.nextText == "TOP TIER" and top.fraction == 1, "top tier")
	h.expect(Models.ratingBar({ coins = 10, xp = 20 }) == nil, "unranked: no rating column")
end)

h.test("results extras: header, coin reason, event chip, XP bar, missions and the auto return", function()
	local data = { mode = "2v2", ranked = true, source = "Ranked", mapId = "SkyShip", duration = 252 }
	h.expect(Models.resultsHeader(data) == "Ranked 2v2 · Sky-Ship Deck · 4:12", Models.resultsHeader(data))
	local bots = { mode = "1v1", source = "Bots", mapId = "DuelRock", duration = 61 }
	h.expect(Models.resultsHeader(bots) == "vs Bots · 1v1 · Duel Rock · 1:01", Models.resultsHeader(bots))
	h.expect(Models.coinReason(row("a", 1, { kos = 3, won = true }), {}) == "3 KOs · win", "coin reason")
	h.expect(Models.coinReason(row("a", 1, { kos = 1 }), {}) == "1 KO · loss", "one KO")
	h.expect(
		Models.eventChip({ xpMult = 2, coinMult = 1, events = { "Double XP Shadow Week" } })
			== "2x XP · Double XP Shadow Week"
	)
	h.expect(
		Models.eventChip({ xpMult = 1, coinMult = 1.5, events = { "Launch Weekend" } })
			== "1.5x COINS · Launch Weekend"
	)
	h.expect(Models.eventChip({ xpMult = 1, coinMult = 1, events = {} }) == nil, "no event")
	-- 120 + 60 * (level - 1): level 1 needs 120 XP, level 2 needs 180
	local xp = Models.xpBar({ xp = 100, xpTotal = 150 })
	h.expect(xp.levelBefore == 1 and xp.levelAfter == 2 and xp.levelUp, "level up")
	h.near(xp.fromFraction, 50 / 120, 1e-6, "from")
	h.near(xp.toFraction, 30 / 180, 1e-6, "to")
	h.expect(xp.percent == "16%", xp.percent)
	-- the server's levels win: XP paid outside the match's own gain (xpTotal - xp is on level 1, the server says
	-- 2) starts the bar empty on the server's level
	local paid = Models.xpBar({ xp = 20, xpTotal = 130, levelBefore = 2, levelAfter = 2 })
	h.expect(paid.levelBefore == 2 and paid.levelAfter == 2 and not paid.levelUp, "server levels")
	h.expect(paid.fromFraction == 0, "starts empty: " .. paid.fromFraction)
	h.near(paid.toFraction, 10 / 180, 1e-6, "ends on the real fill")
	local agreed = Models.xpBar({ xp = 100, xpTotal = 150, levelBefore = 1, levelAfter = 2 })
	h.near(agreed.fromFraction, 50 / 120, 1e-6, "agreeing levels keep the real start")
	local missions = Models.missionRows({
		missions = {
			{ index = 1, text = "KO 5", progress = 2, goal = 5, done = false, justDone = false },
			{ index = 2, text = "Win 2", progress = 2, goal = 2, done = true, justDone = true },
			{ index = 3, text = "Deal", progress = 10, goal = 2000, done = false, justDone = false },
		},
	})
	h.expect(#missions == 2 and missions[1].text == "Win 2" and missions[1].label == "DONE", "done first")
	h.expect(missions[2].label == "2 / 5", missions[2].label)
	h.expect(Models.autoReturnText(20) == "BACK TO MENU IN 0:20", Models.autoReturnText(20))
end)

print("Legend select")

h.test("select slots put your team on the left", function()
	local state = {
		mode = "2v2",
		you = "p1",
		slots = {
			slot("p5", 1, { name = "A" }),
			slot("p6", 1, { name = "B" }),
			slot("p1", 2, { isYou = true }),
			slot("b1", 2, { isBot = true }),
		},
	}
	local layout = Models.selectSlots(state)
	h.expect(layout.kind == "Teams", "team layout")
	h.expect(#layout.left == 2 and layout.left[1].key == "p1" and layout.left[2].key == "b1", "your team left")
	h.expect(#layout.right == 2 and layout.right[1].key == "p5", "the others right")
	local ffa = Models.selectSlots({
		mode = "FFA",
		you = "p1",
		slots = { slot("p1", 3, { isYou = true }), slot("p2", 1), slot("b1", 4), slot("p3", 2) },
	})
	h.expect(ffa.kind == "FFA" and #ffa.row == 4, "FFA row")
	h.expect(ffa.row[1].key == "p2" and ffa.row[3].key == "p1" and ffa.row[4].key == "b1", "FFA by team")
	-- hidden picks read HIDDEN and locks read LOCKED IN
	local hidden = Models.slotView(slot("p5", 1, { hidden = true, locked = true }))
	h.expect(hidden.legendText == "HIDDEN" and hidden.tag == "LOCKED IN" and hidden.legend == nil, "hidden")
	local you = Models.slotView(slot("p1", 2, { isYou = true, name = "Me", legend = "Vex" }))
	h.expect(you.name == "Me (you)" and you.legendText == "VEX" and you.tag == "SELECTING...", "you")
	h.expect(Models.slotView(slot("p3", 1, { left = true })).tag == "LEFT", "leaver")
	local random = Models.slotView(slot("p4", 1, { legend = "Sol", random = true, locked = true }))
	h.expect(random.legend == "Random" and random.legendText == "RANDOM", "a Random lock stays a surprise")
	h.expect(Models.slotView(slot("p4", 1, { legend = "Random" })).legendText == "RANDOM", "hovering Random")
end)

h.test("a leaver's slot taken over by a bot keeps its place in the row", function()
	local state = {
		mode = "FFA",
		you = "p1",
		slots = { slot("p1", 1, { isYou = true }), slot("p2", 2, { legend = "Sol" }), slot("p3", 3), slot("p4", 4) },
	}
	local before = Models.slotPlaces(state)
	h.expect(#before.places == 4 and before.places[2].slot.key == "p2" and before.places[2].column == 2, "FFA")
	-- SelectService swaps the leaver's slot for a locked bot with a new key, in the same place
	state.slots[2] = slot("b1", 2, { isBot = true, name = "Bolt", legend = "Brann", locked = true })
	local after = Models.slotPlaces(state)
	h.expect(after.signature == before.signature, "same arrangement: no rebuild")
	h.expect(after.places[2].slot.key == "b1" and after.places[2].column == 2, "the bot is drawn where p2 was")
	local view = Models.slotView(after.places[2].slot)
	h.expect(view.bot and view.name == "Bolt" and view.legendText == "BRANN" and view.tag == "LOCKED IN", "bot view")
	-- team modes: your team on 1-2, the others on 3-4; a lone fighter sits next to the VS
	local teams = Models.slotPlaces({
		mode = "2v2",
		you = "p1",
		slots = { slot("p5", 1), slot("p6", 1), slot("p1", 2, { isYou = true }), slot("p7", 2) },
	})
	local columns = {}
	for _, place in teams.places do
		columns[place.slot.key] = place.column
	end
	h.expect(columns.p1 == 1 and columns.p7 == 2 and columns.p5 == 3 and columns.p6 == 4, "2v2 columns")
	local duel =
		Models.slotPlaces({ mode = "1v1", you = "p1", slots = { slot("p1", 1, { isYou = true }), slot("p2", 2) } })
	h.expect(duel.places[1].column == 2 and duel.places[2].column == 3, "1v1 next to the VS")
	-- a slot going away (or changing team) changes the arrangement
	table.remove(state.slots, 4)
	h.expect(Models.slotPlaces(state).signature ~= before.signature, "a smaller row is rebuilt")
end)

h.test("select countdown reads the seconds left from endsAt", function()
	local seconds, fraction = Models.secondsLeft(1015, 1000)
	h.expect(seconds == 15, "15 s left: " .. seconds)
	h.near(fraction, 1, 1e-9, "full ring")
	seconds, fraction = Models.secondsLeft(1015, 1004.2)
	h.expect(seconds == 11, "10.8 s rounds up to 11: " .. seconds)
	h.near(fraction, 10.8 / Config.Select.Seconds, 1e-9, "ring fraction")
	h.expect(Models.secondsLeft(1015, 1014.99) == 1, "a sliver is 1")
	h.expect(Models.secondsLeft(1015, 1015) == 0, "zero at the deadline")
	local after, empty = Models.secondsLeft(1015, 1020)
	h.expect(after == 0 and empty == 0, "never negative")
	h.expect(Models.rulesText({ winRule = "Stocks", stocks = 3, timeLimit = 480 }) == "3 STOCKS · 8:00")
	h.expect(Models.rulesText({ winRule = "Timed", stocks = 0, timeLimit = 180 }) == "TIMED · 3:00")
end)

h.test("select hint shows how many humans must lock in", function()
	local state = {
		slots = {
			slot("p1", 1, { isYou = true }),
			slot("p2", 1),
			slot("p3", 2),
			slot("p4", 2),
			slot("b1", 2, { isBot = true }),
		},
	}
	h.expect(Models.lockHint(state) == "ENDS EARLY WHEN ALL 4 LOCK IN", Models.lockHint(state))
	state.slots[4].left = true
	h.expect(Models.lockHint(state) == "ENDS EARLY WHEN ALL 3 LOCK IN", "leavers don't count")
	local solo = { slots = { slot("p1", 1, { isYou = true }), slot("b1", 2, { isBot = true }) } }
	h.expect(Models.lockHint(solo) == "ENDS EARLY WHEN YOU LOCK IN", Models.lockHint(solo))
end)

h.test("hover sends are throttled and the last value is always sent", function()
	local interval = Config.Select.HoverInterval
	local throttle = Models.newHoverThrottle(interval, "Kestrel")
	h.expect(throttle.push("Kestrel", 0) == nil, "the server already has Kestrel")
	h.expect(throttle.push("Brann", 0) == "Brann", "first change goes at once")
	h.expect(throttle.push("Yuki", 0.05) == nil, "inside the interval: held")
	h.expect(throttle.push("Moss", 0.1) == nil, "still held")
	h.expect(throttle.poll(0.15) == nil, "not before the interval ends")
	h.expect(throttle.poll(interval) == "Moss", "the latest value follows")
	h.expect(throttle.poll(interval + 1) == nil, "nothing left")
	-- moving away and back inside the interval sends nothing more
	throttle.push("Vex", interval + 1)
	h.expect(throttle.push("Sol", interval + 1.05) == nil, "held")
	h.expect(throttle.push("Vex", interval + 1.1) == nil, "back to the sent value")
	h.expect(throttle.poll(interval * 3 + 2) == nil, "nothing to follow up")
	-- a lock resets it
	throttle.push("Sol", 10)
	throttle.reset("Yuki")
	h.expect(throttle.push("Yuki", 10.01) == nil and throttle.poll(11) == nil, "after a lock")
	-- at most one send per interval over a burst of moves
	local sends = 0
	local t2 = Models.newHoverThrottle(interval, "Kestrel")
	local roster = { "Brann", "Yuki", "Moss", "Vex", "Sol" }
	for i = 0, 49 do
		local now = i * 0.02
		if t2.push(roster[i % 5 + 1], now) or t2.poll(now) then
			sends += 1
		end
	end
	h.expect(sends <= math.ceil(1 / interval) + 1, "too many sends: " .. sends)
	local last = t2.poll(5)
	h.expect(last == nil or last == roster[49 % 5 + 1], "the final hover is the one sent")
	h.expect(t2.sent == roster[49 % 5 + 1], "server ends on the last hover: " .. tostring(t2.sent))
end)

h.test("map vote cards, vote cycling and tile tags", function()
	local state = {
		you = "p1",
		maps = {
			{ id = "SkyShip", votes = 2 },
			{ id = "VolcanicForge", votes = 1 },
			{ id = "JungleTemple", votes = 0 },
		},
		yourVote = "SkyShip",
		slots = {
			slot("p1", 1, { isYou = true, legend = "Vex" }),
			slot("p2", 1, { legend = "Sol" }),
			-- (a hidden slot never carries its legend; if one did, it still mustn't leak onto the grid)
			slot("p3", 2, { hidden = true, legend = "Moss" }),
			slot("b1", 2, { isBot = true, legend = "Brann", random = true }),
		},
	}
	local cards = Models.mapCards(state)
	h.expect(#cards == 3 and cards[1].name == "Sky-Ship Deck" and cards[1].yours and cards[1].votes == 2, "cards")
	h.expect(Models.mapCards(state, "JungleTemple")[3].yours, "a vote just sent shows at once")
	h.expect(Models.votesText(1) == "1 VOTE" and Models.votesText(2) == "2 VOTES", "votes text")
	local fixed = Models.mapCards({ fixedMap = "DuelRock" })
	h.expect(#fixed == 1 and fixed[1].fixed and fixed[1].name == "Duel Rock", "fixed map")
	h.expect(Models.nextVote(state.maps, "SkyShip", 1) == "VolcanicForge", "R1")
	h.expect(Models.nextVote(state.maps, "SkyShip", -1) == "JungleTemple", "L1 wraps")
	h.expect(
		Models.nextVote(state.maps, nil, 1) == "SkyShip" and Models.nextVote(state.maps, nil, -1) == "JungleTemple"
	)
	local tags = Models.tileTags(state)
	h.expect(tags.Sol and tags.Sol[1] == "P2", "teammate tag")
	h.expect(tags.Vex == nil, "no tag for you")
	h.expect(tags.Random and tags.Random[1] == "P4" and tags.Brann == nil, "random picks tag the Random tile")
	h.expect(tags.Moss == nil, "hidden picks are never tagged")
	local grid = Models.gridLegends()
	h.expect(#grid == 8 and grid[1] == "Kestrel" and grid[7] == "Avatar" and grid[8] == "Random", "grid order")
	-- the hint bar offers L1 / R1 only when there is a vote
	local function actions(items)
		local list = {}
		for _, item in items do
			table.insert(list, item.action)
		end
		return table.concat(list, " ")
	end
	h.expect(actions(Models.selectHints(state)) == "Confirm Back X Y L1 R1", actions(Models.selectHints(state)))
	h.expect(actions(Models.selectHints({ fixedMap = "DuelRock" })) == "Confirm Back X Y", "fixed map: no vote hints")
end)

h.test("info block text: spaced titles and names that shrink instead of being cut", function()
	h.expect(Models.spaced("SHADOW NINJA") == "S H A D O W   N I N J A", Models.spaced("SHADOW NINJA"))
	h.expect(Models.spaced("YOURSELF") == "Y O U R S E L F", Models.spaced("YOURSELF"))
	h.expect(Models.spaced("") == "", "empty")
	h.expect(Models.fitSize("KESTREL", 120, 7) == 120, "short names keep their size")
	h.expect(Models.fitSize("MY AVATAR", 120, 7) == 93, "long names shrink: " .. Models.fitSize("MY AVATAR", 120, 7))
end)

print("Phases")

h.test("a cancel during VS returns to the menu", function()
	local vs = { phase = "Vs", vsId = 7, vsMatchId = 40 }
	local result = Models.phaseAfter({ type = "Cancel", id = 7, reason = "A fighter couldn't load." }, vs)
	h.expect(result and result.phase == "Menu", "back to the menu")
	h.expect(result.toast == "A fighter couldn't load." and result.toastKind == "error", tostring(result.toast))
	local requeued = Models.phaseAfter({ type = "Cancel", id = 7, reason = "NovaKick left.", requeued = true }, vs)
	h.expect(requeued.toast == "NovaKick left. You're back in the queue." and requeued.toastKind == "good")
	h.expect(Models.phaseAfter({ type = "Cancel", id = 6, reason = "old" }, vs) == nil, "another session's cancel")
	local select = { phase = "Select", selectId = 9 }
	h.expect(Models.phaseAfter({ type = "Cancel", id = 9, reason = "x" }, select).phase == "Menu", "select cancel")
	h.expect(Models.phaseAfter({ type = "Cancel", id = 9 }, { phase = "Match", selectId = 9 }) == nil, "not in Match")
	h.expect(Models.phaseAfter({ type = "Begin", id = 9 }, { phase = "Results" }).phase == "Select", "begin")
	h.expect(Models.phaseAfter({ type = "Start" }, { phase = "Vs" }).phase == "Match", "start")
	h.expect(Models.phaseAfter({ type = "Cleanup" }, { phase = "Match" }).phase == "Menu", "cleanup in Match")
	h.expect(Models.phaseAfter({ type = "Cleanup" }, { phase = "Results" }) == nil, "results stay")
end)

h.test("select and VS never interrupt a match, and a failed setup keeps a newer screen", function()
	for _, kind in { "Begin", "Vs" } do
		for _, phase in { "Match", "Title" } do
			h.expect(Models.phaseAfter({ type = kind, id = 4 }, { phase = phase }) == nil, kind .. " in " .. phase)
		end
		h.expect(Models.phaseAfter({ type = kind, id = 4 }, { phase = "Menu" }) ~= nil, kind .. " from the menu")
	end
	local failed = Models.phaseAfter({ type = "SetupFailed" }, { phase = "Vs" })
	h.expect(failed and failed.phase == "Menu" and failed.toast == "Couldn't set up your fighter.", "from VS")
	h.expect(failed.toastKind == "error", "an error")
	h.expect(Models.phaseAfter({ type = "SetupFailed" }, { phase = "Menu" }).phase == "Menu", "training from the menu")
	h.expect(Models.phaseAfter({ type = "SetupFailed" }, { phase = "Select" }) == nil, "a newer select stays")
	h.expect(Models.phaseAfter({ type = "SetupFailed" }, { phase = "Results" }) == nil, "results stay")
end)

h.test("End or Leave of the VS match before Start returns to the menu", function()
	local state = { phase = "Vs", vsId = 7, vsMatchId = 40, matchId = nil }
	local ended = Models.phaseAfter({ type = "MatchEnd", matchId = 40 }, state)
	h.expect(ended and ended.phase == "Menu" and ended.toast == "The match couldn't start.", "end before start")
	local requeued = Models.phaseAfter({ type = "MatchEnd", matchId = 40, requeued = true }, state)
	h.expect(requeued.toast == "A player left before the fight. You're back in the queue.", "requeued")
	h.expect(requeued.toastKind == "good", "requeued is good news")
	h.expect(Models.phaseAfter({ type = "MatchEnd", matchId = 39 }, state) == nil, "another match")
	h.expect(Models.phaseAfter({ type = "MatchEnd", matchId = 40 }, { phase = "Menu", vsMatchId = 40 }) == nil)
	h.expect(
		Models.phaseAfter({ type = "MatchEnd", matchId = 40 }, { phase = "Vs", vsMatchId = 40, matchId = 40 }) == nil
	)
	h.expect(Models.routeMatchEvent("End", { matchId = 40 }, nil, false) == "orphan", "no match running")
end)

h.test("events of another match are ignored", function()
	h.expect(Models.routeMatchEvent("Hit", { matchId = 11 }, 12, true) == "ignore", "old match")
	h.expect(Models.routeMatchEvent("End", { matchId = 11 }, 12, true) == "ignore", "old End")
	h.expect(Models.routeMatchEvent("Leave", { matchId = 11 }, 12, true) == "ignore", "old Leave")
	h.expect(Models.routeMatchEvent("Hit", { matchId = 12 }, 12, true) == "handle", "this match")
	h.expect(Models.routeMatchEvent("Start", { matchId = 13 }, 12, true) == "start", "a new Start")
	h.expect(Models.routeMatchEvent("KO", nil, 12, true) == "ignore", "no data")
end)

h.test("the VS watchdog fires after startsIn + load timeout + 5 s", function()
	local limit = 3 + Config.Match.LoadTimeout + Config.Menu.VsWatchdogExtra
	h.expect(Config.Menu.VsWatchdogExtra == 5, "the extra is 5 s")
	h.expect(Models.watchdogSeconds(3) == limit, "limit " .. Models.watchdogSeconds(3))
	h.expect(Models.watchdogSeconds(nil) == Config.Select.VsSeconds + limit - 3, "default startsIn")
	h.expect(not Models.watchdogDue(100, 3, 100 + limit - 0.01), "not yet")
	h.expect(Models.watchdogDue(100, 3, 100 + limit), "due")
	local fired = Models.phaseAfter({ type = "Watchdog" }, { phase = "Vs" })
	h.expect(fired.phase == "Menu" and fired.toast == "The match didn't start. Back to the menu.", "toast")
	h.expect(fired.toastKind == "error", "an error")
	h.expect(Models.phaseAfter({ type = "Watchdog" }, { phase = "Match" }) == nil, "a started match stays")
end)

h.test("vs layout splits teams into two sides and FFA into four strips", function()
	local function fighter(key, team, userId, isBot)
		return { key = key, name = key, team = team, userId = userId, isBot = isBot == true, legend = "Sol" }
	end
	local vs = {
		mode = "2v2",
		fighters = { fighter("p5", 1, 5), fighter("p6", 1, 6), fighter("b1", 2, 0, true), fighter("p1", 2, ME) },
	}
	local layout = Models.vsLayout(vs, ME)
	h.expect(layout.kind == "Teams" and #layout.left == 2 and #layout.right == 2, "two sides of two")
	h.expect(layout.left[1].key == "p1" and layout.left[2].key == "b1", "you in front on the left")
	h.expect(layout.right[1].key == "p5", "the others on the right")
	local ffa = Models.vsLayout({
		mode = "FFA",
		fighters = { fighter("a", 3, 3), fighter("b", 1, ME), fighter("c", 4, 0, true), fighter("d", 2, 2) },
	}, ME)
	h.expect(ffa.kind == "FFA" and #ffa.strips == 4, "four strips")
	for k, strip in ffa.strips do
		h.expect(strip.team == k, "strip " .. k .. " is team " .. k)
		h.near(strip.x0, (k - 1) * 0.25, 1e-9, "strip edge")
	end
	local duel = Models.vsLayout({ mode = "1v1", fighters = { fighter("p2", 1, 2), fighter("p1", 2, ME) } }, ME)
	h.expect(duel.left[1].key == "p1" and duel.right[1].key == "p2", "1v1: you left")
end)

h.finish()
