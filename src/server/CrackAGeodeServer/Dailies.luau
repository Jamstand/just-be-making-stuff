-- DailiesService: daily login rewards (7-day streak ladder) + 3 rotating daily
-- quests. Quests are chosen deterministically from the date, so all players see
-- the same 3 each day and they rotate daily. Completing all 3 awards a Rare Geode.

local Players = game:GetService("Players")

local Dailies = {}
local S, Config, Data, Econ, Remotes

local function today() return os.date("!%Y-%m-%d") end
local function dayNumber() return math.floor(os.time() / 86400) end

-- 7-day login reward ladder (escalating Gems; special perks on some days)
local LADDER = {
	{ gems = 250 },
	{ gems = 500 },
	{ gems = 1000, luckMins = 10 },
	{ gems = 2500 },
	{ gems = 5000, luckMins = 15 },
	{ gems = 10000 },
	{ gems = 25000, golden = true }, -- day 7: big Gems + a Golden (rare) Geode
}

local QUEST_POOL = {
	{ id = "crack120",  etype = "crack",   goal = 120,   gems = 2500, desc = "Crack %d geodes" },
	{ id = "crack300",  etype = "crack",   goal = 300,   gems = 5500, desc = "Crack %d geodes" },
	{ id = "earn15k",   etype = "earn",    goal = 15000, gems = 3000, desc = "Earn %s Gems" },
	{ id = "earn75k",   etype = "earn",    goal = 75000, gems = 7000, desc = "Earn %s Gems" },
	{ id = "upgrade6",  etype = "upgrade", goal = 6,     gems = 2000, desc = "Buy %d upgrades" },
	{ id = "upgrade12", etype = "upgrade", goal = 12,    gems = 4000, desc = "Buy %d upgrades" },
	{ id = "rare2",     etype = "rare",    goal = 2,     gems = 4000, desc = "Find %d Rare crystals (Emerald+)" },
	{ id = "rebirth1",  etype = "rebirth", goal = 1,     gems = 3500, desc = "Recrystallize (Rebirth) %d×" },
	{ id = "meteor1",   etype = "meteor",  goal = 1,     gems = 3000, desc = "Help crack a Meteor Geode" },
}

-- Deterministic 3-quest pick for a given day (same for everyone, rotates daily).
-- Small LCG constants keep every product well under 2^53 (no float precision loss).
local function questsForDay(dn)
	local idx = {}
	for i = 1, #QUEST_POOL do idx[i] = i end
	local s = (dn % 65521) + 1
	local function rnd() s = (s * 75 + 74) % 65521; return s end
	rnd(); rnd()
	for i = #idx, 2, -1 do
		local j = (rnd() % i) + 1
		idx[i], idx[j] = idx[j], idx[i]
	end
	return { QUEST_POOL[idx[1]], QUEST_POOL[idx[2]], QUEST_POOL[idx[3]] }
end

local function questDesc(q)
	if q.etype == "earn" then return string.format(q.desc, Config.Fmt(q.goal)) end
	return string.format(q.desc, q.goal)
end

local function syncQuests(p)
	local t = today()
	if p.questDate ~= t then
		p.questDate = t
		p.questProgress = {}
		p.questClaimed = {}   -- per-quest coin-reward-granted flags
		p.questSetDone = false
	end
end

-- ===== login streak / reward =====

function Dailies.StreakOnJoin(p)
	local t = today()
	if p.lastStreakDate ~= t then
		local yest = os.date("!%Y-%m-%d", os.time() - 86400)
		p.streakDay = (p.lastStreakDate == yest) and ((p.streakDay % 7) + 1) or 1
		p.lastStreakDate = t
	end
end

function Dailies.RewardClaimable(p)
	return p.rewardClaimedDate ~= today()
end

function Dailies.Claim(player)
	local p = Data.Cache[player]
	if not p then return { ok = false, err = "Loading…" } end
	if not Dailies.RewardClaimable(p) then return { ok = false, err = "Already claimed today!" } end
	local day = math.clamp(p.streakDay, 1, 7)
	local reward = LADDER[day]
	p.rewardClaimedDate = today()
	Econ.AwardRaw(player, reward.gems)
	if reward.luckMins then
		p.streakLuckUntil = os.time() + reward.luckMins * 60
	end
	if reward.golden and S.Geodes then
		S.Geodes.SpawnGolden(player, true)
	end
	Remotes.Announce:FireClient(player, {
		kind = "daily",
		text = "🎁 Day " .. day .. " reward: +" .. Config.Fmt(reward.gems) .. " 💎" .. (reward.golden and "  + Golden Geode!" or ""),
		color = Color3.fromRGB(255, 220, 120),
	})
	if Data.SaveSoon then Data.SaveSoon(player) end
	Econ.Push(player)
	return { ok = true, day = day, gems = reward.gems }
end

-- ===== quest event tracking =====

function Dailies.Event(player, etype, amount)
	local p = Data.Cache[player]
	if not p then return end
	syncQuests(p)
	local qs = questsForDay(dayNumber())
	local completedSomething = false
	local allDone = true
	for _, q in ipairs(qs) do
		local prog = p.questProgress[q.id] or 0
		if q.etype == etype and prog < q.goal then
			prog = math.min(q.goal, prog + (amount or 1))
			p.questProgress[q.id] = prog
			if prog >= q.goal and not p.questClaimed[q.id] then
				p.questClaimed[q.id] = true
				Econ.AwardRaw(player, q.gems)
				completedSomething = true
				Remotes.Announce:FireClient(player, {
					kind = "quest",
					text = "✅ Quest done: " .. questDesc(q) .. "  +" .. Config.Fmt(q.gems) .. " 💎",
					color = Color3.fromRGB(150, 205, 255),
				})
			end
		end
		if (p.questProgress[q.id] or 0) < q.goal then allDone = false end
	end
	if allDone and not p.questSetDone then
		p.questSetDone = true
		completedSomething = true
		if S.Geodes then S.Geodes.SpawnGolden(player, true) end -- the Rare Geode reward
		Remotes.Announce:FireAllClients({
			kind = "quest",
			text = "🌟 " .. player.DisplayName .. " cleared all Daily Quests — Rare Geode earned!",
			color = Color3.fromRGB(255, 210, 90),
		})
	end
	if completedSomething then
		if Data.SaveSoon then Data.SaveSoon(player) end
		Econ.Push(player)
	end
end

-- ===== snapshot state for the client =====

function Dailies.State(player)
	if not (Data and Config) then return nil end
	local p = Data.Cache[player]
	if not p then return nil end
	syncQuests(p)
	local ladder = {}
	for i, r in ipairs(LADDER) do
		ladder[i] = { gems = r.gems, golden = r.golden == true, luck = r.luckMins ~= nil }
	end
	local quests = {}
	for _, q in ipairs(questsForDay(dayNumber())) do
		local prog = p.questProgress[q.id] or 0
		quests[#quests + 1] = { desc = questDesc(q), progress = prog, goal = q.goal, gems = q.gems, done = prog >= q.goal }
	end
	return {
		streakDay = math.clamp(p.streakDay, 1, 7),
		claimable = Dailies.RewardClaimable(p),
		ladder = ladder,
		quests = quests,
		setDone = p.questSetDone == true,
	}
end

function Dailies.Init(services)
	S = services
	Config, Data, Econ, Remotes = S.Config, S.Data, S.Econ, S.Remotes

	local function onJoin(player)
		task.spawn(function()
			local p = Data.WaitFor(player, 15)
			if not p then return end
			Dailies.StreakOnJoin(p)
			syncQuests(p)
			Econ.Push(player)
			if Dailies.RewardClaimable(p) then
				task.wait(2) -- let the HUD build first
				Remotes.DailyPopup:FireClient(player)
			end
		end)
	end
	Players.PlayerAdded:Connect(onJoin)
	task.defer(function()
		for _, p in ipairs(Players:GetPlayers()) do onJoin(p) end
	end)

	Remotes.ClaimDaily.OnServerInvoke = function(player)
		return Dailies.Claim(player)
	end
end

return Dailies
