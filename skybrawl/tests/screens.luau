--[[
    Tests for the menu screens' pure view logic (src/client/UI/Screens/Models):
    Online Play cards, Practice bot formats, Rankings pages, season label and
    rank card, Invite rows, the Profile season badge and Store cards.
    Run from the skybrawl folder with:  lune run tests/screens
]]

local h = require("./harness")

local Config = h.require("Config")
local Events = h.require("Events")
local Models = h.requireClientFile("UI/Screens/Models")

local ME = 1
local NOW = Events.parse("2026-10-20T12:00:00Z")

local function party(leader, others)
	local members = { { userId = leader, name = "P" .. leader, isLeader = true, status = "Menu" } }
	for _, id in others do
		table.insert(members, { userId = id, name = "P" .. id, isLeader = false, status = "Menu" })
	end
	return { id = 7, leaderUserId = leader, members = members, pending = {}, maxSize = 4 }
end

local function cardOf(cards, queueType)
	for _, card in cards do
		if card.queueType == queueType then
			return card
		end
	end
	error("no card for " .. queueType)
end

local function rows(count, youAt)
	local out = {}
	for i = 1, count do
		table.insert(out, {
			rank = i,
			userId = 100 + i,
			name = "Player" .. i,
			username = "player" .. i,
			rating = 2300 - i * 10,
			tier = "Diamond",
			main = "Vex",
			wins = 50 - i,
			losses = i,
			you = i == youAt,
		})
	end
	return out
end

print("Online Play")

h.test("online play locks 1v1 for a party of 2 with the SOLO ONLY reason", function()
	local cards = Models.onlineCards({ party = party(ME, { 2 }), userId = ME, stats = { Ranked2v2 = 4 } })
	local duel, duo, ffa = cardOf(cards, "Ranked1v1"), cardOf(cards, "Ranked2v2"), cardOf(cards, "FFA")
	h.expect(duel.locked, "1v1 should be locked for a party of 2")
	h.expect(duel.lockTitle == "SOLO ONLY", "lock title " .. tostring(duel.lockTitle))
	h.expect(duel.lockReason == "Ranked 1v1 is for 1 player. Leave your party to queue.", tostring(duel.lockReason))
	h.expect(duel.party == "SOLO ONLY" and not duel.partyFits, "1v1 party chip")
	h.expect(not duo.locked and duo.partyFits and duo.party == "PARTY UP TO 2", "2v2 fits a party of 2")
	h.expect(not ffa.locked and ffa.partyFits and ffa.party == "PARTY UP TO 4", "FFA fits a party of 2")
	h.expect(duo.searching == "4 searching" and ffa.searching == "0 searching", "searching counts")
	h.expect(duo.maps == #Config.Queue.MapPools["2v2"] .. " MAPS", "maps chip " .. duo.maps)
	h.expect(duo.tag == "RANKED" and ffa.tag == "CASUAL", "tags")
	-- solo: nothing is locked and no party check shows
	for _, card in Models.onlineCards({ party = nil, userId = ME }) do
		h.expect(not card.locked and not card.partyFits, card.queueType .. " locked or checked while solo")
	end
	-- a party of 3 is too big for 2v2
	local three = cardOf(Models.onlineCards({ party = party(ME, { 2, 3 }), userId = ME }), "Ranked2v2")
	h.expect(three.locked and three.lockTitle == "UP TO 2 PLAYERS", "2v2 lock for 3: " .. tostring(three.lockTitle))
	h.expect(three.lockReason == "Ranked 2v2 allows up to 2 players. Your party has 3.", tostring(three.lockReason))
end)

h.test("online play locks every card for party members who are not the leader", function()
	local cards = Models.onlineCards({ party = party(2, { ME }), userId = ME })
	h.expect(#cards == 3, "three cards")
	for _, card in cards do
		h.expect(card.locked, card.queueType .. " should be locked")
		h.expect(card.lockTitle == "LEADER QUEUES", card.queueType .. " lock title " .. tostring(card.lockTitle))
		h.expect(card.lockReason == "Only the party leader can start a search.", tostring(card.lockReason))
		h.expect(card.action == "FIND MATCH", "action")
	end
	-- the leader's own view of the same party
	local leaderCards = Models.onlineCards({ party = party(2, { ME }), userId = 2 })
	h.expect(not cardOf(leaderCards, "FFA").locked, "the leader can queue FFA")
end)

h.test("online play shows CANCEL SEARCH on the queue you are in", function()
	local queue = { queue = "FFA", label = "Free-for-all", waited = 5, inQueue = 3, partySize = 2, leaderUserId = 2 }
	-- even a member who isn't the leader can cancel the party's search
	local cards = Models.onlineCards({ party = party(2, { ME }), userId = ME, queue = queue })
	local ffa = cardOf(cards, "FFA")
	h.expect(ffa.queued and ffa.action == "CANCEL SEARCH", "FFA action " .. ffa.action)
	h.expect(not ffa.locked, "the queue you are in is never locked")
	h.expect(cardOf(cards, "Ranked2v2").action == "FIND MATCH", "other cards keep FIND MATCH")
	local solo = Models.onlineCards({ userId = ME, queue = { queue = "Ranked1v1" } })
	h.expect(cardOf(solo, "Ranked1v1").action == "CANCEL SEARCH", "solo 1v1 cancel")
	h.expect(cardOf(solo, "FFA").action == "FIND MATCH", "solo FFA find")
end)

h.test("online play shows your rating and tier on ranked cards only", function()
	local profile = { Rating1v1 = 1432, Rating2v2 = 1218 }
	local cards = Models.onlineCards({ userId = ME, profile = profile })
	local duel, duo, ffa = cardOf(cards, "Ranked1v1"), cardOf(cards, "Ranked2v2"), cardOf(cards, "FFA")
	h.expect(duel.rating == 1432 and duel.tier == "Gold", "1v1 rating " .. tostring(duel.tier))
	h.expect(duo.rating == 1218 and duo.tier == "Silver", "2v2 rating " .. tostring(duo.tier))
	h.expect(ffa.rating == nil and ffa.tier == nil, "FFA has no rating")
end)

print("Practice")

h.test("practice bot formats respect the party size", function()
	local function fits(size)
		local out = {}
		for _, option in Models.botFormats(size) do
			out[option.value] = option.fits
		end
		return out
	end
	local solo, duo, trio, four = fits(1), fits(2), fits(3), fits(4)
	h.expect(solo.Duel and solo.FFA and solo["2v2"], "a solo player fits every format")
	h.expect(not duo.Duel and duo.FFA and duo["2v2"], "a party of 2 fits FFA and 2v2 only")
	h.expect(not trio.Duel and trio.FFA and not trio["2v2"], "a party of 3 fits FFA only")
	h.expect(not four.Duel and not four.FFA and not four["2v2"], "a party of 4 fits nothing")
	h.expect(Models.pickBotFormat("Duel", 1) == "Duel", "solo keeps Duel")
	h.expect(Models.pickBotFormat("Duel", 2) == "FFA", "a party of 2 moves off Duel")
	h.expect(Models.pickBotFormat("2v2", 2) == "2v2", "a party of 2 keeps 2v2")
	h.expect(Models.pickBotFormat("2v2", 3) == "FFA", "a party of 3 moves to FFA")
	h.expect(Models.pickBotFormat("FFA", 4) == "FFA", "nothing fits: keep the choice")
	local ok, reason = Models.botsStart("Duel", 2, true)
	h.expect(not ok and reason == "vs Bots (Duel) is for 1 player. Leave your party to queue.", tostring(reason))
	ok, reason = Models.botsStart("FFA", 2, false)
	h.expect(not ok and reason == "Only the party leader can start a search.", tostring(reason))
	h.expect((Models.botsStart("2v2", 2, true)), "the leader of 2 can start 2v2")
	-- labels count the bots for the party
	local labels = {}
	for _, option in Models.botFormats(2) do
		labels[option.value] = option.label
	end
	h.expect(labels.FFA == "Free-for-all (2 bots)", labels.FFA)
	h.expect(Models.botFormats(1)[2].label == "Free-for-all (3 bots)", "solo FFA label")
	h.expect(Models.botMaps()[1].value == "Vote", "the map row starts with Vote")
end)

print("Rankings")

h.test("rankings pages hold 10 rows and your row is pinned", function()
	local pageSize = Config.Rankings.PageSize
	h.expect(pageSize == 10, "page size")
	local data = { rows = rows(25, 14), you = { rating = 2160, tier = "Diamond", wins = 36, losses = 14 } }
	local page = Models.rankingsPage(data, 1, pageSize, "Me")
	h.expect(page.pages == 3 and #page.rows == 10, "3 pages of 10, got " .. page.pages .. "/" .. #page.rows)
	h.expect(page.rows[1].rank == "1" and page.rows[1].medal == "Gold", "first row")
	h.expect(page.rows[3].medal == "Bronze" and page.rows[4].medal == nil, "medals for the top 3")
	h.expect(page.pinned.rank == "14" and page.pinned.name == "Player14 (you)", "pinned " .. page.pinned.name)
	local last = Models.rankingsPage(data, 3, pageSize, "Me")
	h.expect(#last.rows == 5 and last.rows[1].rank == "21", "last page")
	h.expect(Models.rankingsPage(data, 9, pageSize, "Me").page == 3, "pages clamp")
	-- not in the list: rank "—" from your card
	local outside = Models.rankingsPage({ rows = rows(25), you = data.you }, 1, pageSize, "Me")
	h.expect(outside.pinned.rank == "—", "rank outside the list " .. outside.pinned.rank)
	h.expect(outside.pinned.name == "Me (you)" and outside.pinned.record == "36 – 14", outside.pinned.record)
	h.expect(outside.pinned.rating == "2,160", "pinned rating " .. outside.pinned.rating)
	-- phone pages of 6
	h.expect(Models.rankingsPage(data, 1, 6, "Me").pages == 5, "phone pages")
	local yourPage, yourRow = Models.yourPage(data.rows, pageSize)
	h.expect(yourPage == 2 and yourRow == 4, "your page " .. tostring(yourPage) .. "/" .. tostring(yourRow))
	h.expect(Models.yourPage(rows(5), pageSize) == nil, "no page when you are not listed")
	-- an empty list still has one page
	local empty = Models.rankingsPage({ rows = {}, you = {} }, 1, pageSize, "Me")
	h.expect(empty.pages == 1 and #empty.rows == 0 and empty.pinned.rank == "—", "empty list")
end)

h.test("rankings flips the page at the list ends", function()
	h.expect(Models.flipPage(1, 3, "Down") == 2, "down from page 1")
	h.expect(Models.flipPage(2, 3, "Up") == 1, "up from page 2")
	h.expect(Models.flipPage(3, 3, "Down") == nil, "no page after the last")
	h.expect(Models.flipPage(1, 3, "Up") == nil, "no page before the first")
	h.expect(Models.flipPage(1, 1, "Down") == nil, "one page never flips")
end)

h.test("rankings season label says ENDS IN or ENDED", function()
	local season = { id = 1, name = "Season 1", endsAt = NOW + 23 * 86400 + 600, current = true }
	h.expect(Models.seasonLabel(season, NOW) == "SEASON 1 · ENDS IN 23D", Models.seasonLabel(season, NOW))
	season.endsAt = NOW + 5 * 3600 + 30
	h.expect(Models.seasonLabel(season, NOW) == "SEASON 1 · ENDS IN 5H", Models.seasonLabel(season, NOW))
	season.endsAt = NOW + 90
	h.expect(Models.seasonLabel(season, NOW) == "SEASON 1 · ENDS IN 1M", Models.seasonLabel(season, NOW))
	season.endsAt = NOW - 1
	h.expect(Models.seasonLabel(season, NOW) == "SEASON 1 · ENDED", "a finished current season")
	local past = { id = 1, name = "Season 1", endsAt = NOW + 999, current = false }
	h.expect(Models.seasonLabel(past, NOW) == "SEASON 1 · ENDED", "a past season")
	local endless = { id = 1, name = "Season 1", endsAt = math.huge, current = true }
	h.expect(Models.seasonLabel(endless, NOW) == "SEASON 1", "an endless season")
end)

h.test("missions reset label counts down to the UTC midnight", function()
	local midnight = 20000 * 86400
	h.expect(Models.missionsReset(midnight - (7 * 3600 + 42 * 60)) == "RESETS IN 7H 42M", "7h 42m before midnight")
	h.expect(Models.missionsReset(midnight - 42 * 60 - 30) == "RESETS IN 42M", "under an hour")
	h.expect(Models.missionsReset(midnight - 20) == "RESETS IN 1M", "the last minute still says 1M")
	h.expect(Models.missionsReset(midnight) == "RESETS IN 24H 0M", "right after the reset")
end)

h.test("a past-season rank card hides peak and shows NOT RANKED without an entry", function()
	local past = Models.rankCard({ rating = 1500, tier = "Gold", wins = 20, losses = 10, main = "Vex" }, "Global")
	h.expect(past.peak == nil, "past seasons have no peak")
	h.expect(not past.notRanked and past.tier == "GOLD" and past.rating == "1500", "past card tier")
	h.expect(past.legend and past.legend.title == "MAIN" and past.legend.name == "VEX", "past card shows MAIN")
	h.expect(past.rank == "—" and past.winRate == "67%", "rank and win rate " .. past.winRate)
	local none = Models.rankCard({ rating = 0, tier = "Tin", wins = 0, losses = 0, noEntry = true }, "Global")
	h.expect(none.notRanked and none.tier == "NOT RANKED", "no entry reads NOT RANKED")
	h.expect(none.peak == nil and none.progress == nil and none.legend == nil, "nothing else on an empty card")
	-- the current season shows peak, progress and the best legend
	local current = Models.rankCard({
		rank = 1284,
		rating = 1432,
		tier = "Gold",
		peak = 1480,
		wins = 48,
		losses = 31,
		played = 79,
		bestLegend = { id = "Kestrel", wins = 31, played = 48 },
	}, "Global")
	h.expect(current.peak == "PEAK 1480" and current.rank == "#1,284", "current card " .. current.rank)
	h.expect(current.progress.from == "GOLD 1390" and current.progress.to == "PLATINUM 1680", "progress ends")
	h.expect(current.progress.toNext == "248 to Platinum", current.progress.toNext)
	h.expect(current.legend.title == "BEST LEGEND" and current.legend.line == "31 wins · 65%", current.legend.line)
	h.expect(Models.rankCard({ rank = 3, rating = 1000 }, "Friends").rankLabel == "FRIENDS", "friends label")
	h.expect(Models.rankCard({ rating = 2500, tier = "Diamond" }, "Global").progress.toNext == "Top tier", "top tier")
end)

print("Invite")

h.test("invite rows sort friends first and let you invite busy players", function()
	local list = {
		{ userId = 10, name = "zed", username = "zed", level = 3, isFriend = false, status = "Menu", canInvite = true },
		{ userId = 11, name = "Amy", username = "amy", level = 9, isFriend = true, status = "Match", canInvite = true },
		{ userId = 12, name = "bob", username = "bob", level = 5, isFriend = true, status = "Menu", canInvite = true },
		{
			userId = 13,
			name = "Cat",
			username = "cat",
			level = 2,
			isFriend = false,
			status = "Menu",
			canInvite = false,
			invited = true,
			reason = "Invited",
		},
		{
			userId = 14,
			name = "Dan",
			username = "dan",
			level = 2,
			isFriend = false,
			status = "Room",
			canInvite = false,
			reason = "Declined recently",
		},
	}
	local out = Models.inviteRows(list, true)
	local order = {}
	for _, row in out do
		table.insert(order, row.name)
	end
	h.expect(table.concat(order, ",") == "bob,Amy,Cat,zed,Dan", "order " .. table.concat(order, ","))
	local amy = out[2]
	h.expect(amy.friend and amy.busy and amy.status == "In a match", "busy friend chip")
	h.expect(amy.enabled and amy.button == "INVITE", "busy players can be invited")
	h.expect(out[1].status == nil and out[1].username == "@bob" and out[1].level == "LV 5", "idle row")
	h.expect(out[3].button == "INVITED" and not out[3].enabled, "already invited")
	h.expect(out[5].button == "DECLINED RECENTLY" and not out[5].enabled, "a reason disables the button")
	h.expect(out[5].status == "In a room", "room chip")
	for _, row in Models.inviteRows(list, false) do
		h.expect(not row.enabled, "members who can't manage the party can't invite")
	end
	h.expect(#Models.inviteRows({}, true) == 0, "empty list")
end)

print("Profile and Store")

h.test("profile season badge text lists the tiers that were played", function()
	local both = { season = 1, name = "Season 1", tier1v1 = "Gold", tier2v2 = "Silver" }
	h.expect(Models.seasonBadgeText(both) == "SEASON 1 · GOLD 1v1 · SILVER 2v2", Models.seasonBadgeText(both))
	local only2 = { season = 1, name = "Season 1", tier2v2 = "Bronze" }
	h.expect(Models.seasonBadgeText(only2) == "SEASON 1 · BRONZE 2v2", Models.seasonBadgeText(only2))
	h.expect(#Models.seasonBadgeTiers(only2) == 1 and Models.seasonBadgeTiers(only2)[1].mode == "2v2", "tiers")
	h.expect(Models.seasonBadgeText(nil) == nil, "no badge, no text")
end)

h.test("profile rank cards show placements and this season's record", function()
	local profile = {
		Rating1v1 = 1432,
		Peak1v1 = 1480,
		Ranked1v1Played = 4,
		Rating2v2 = 1000,
		Peak2v2 = 1000,
		Ranked2v2Played = 40,
		SeasonStats = { ["1v1"] = { wins = 3, losses = 1 }, ["2v2"] = { wins = 0, losses = 0 } },
	}
	local duel = Models.profileRank(profile, "1v1")
	h.expect(duel.tier == "GOLD" and duel.peak == "PEAK 1480", "1v1 card")
	h.expect(duel.season == "3 – 1 THIS SEASON", duel.season)
	h.expect(duel.note == "Placements: 4 / 10 played", duel.note)
	h.expect(Models.profileRank(profile, "2v2").note == "40 ranked matches", "2v2 note")
end)

h.test("store cards show equipped, owned and the price", function()
	local item = { Id = "RedTrail", Category = "Trail", Price = 1500 }
	local profile = { Coins = 1000, Owned = {}, Equipped = {} }
	local buy = Models.shopItem(item, profile)
	h.expect(buy.state == "Buy" and buy.label == "1,500" and not buy.affordable, "price")
	profile.Owned.RedTrail = true
	h.expect(Models.shopItem(item, profile).label == "EQUIP", "owned")
	profile.Equipped.Trail = "RedTrail"
	h.expect(Models.shopItem(item, profile).label == "EQUIPPED", "equipped")
	h.expect(Models.shopItem(item, nil).state == "Buy", "no profile yet")
end)

h.finish()
