-- ServerGoalsService: rotating cooperative server goals paying ONLY the existing
-- server-luck buff (Buffs.AddServerGift) — never gems.
--
--   * Goals rotate round-robin through Config.Social.Goals. On start
--       target = max(goalMin, ceil(goal * clamp(online / 5, SCALE_MIN, 2)))
--       endsAt = now + GoalWindow.
--   * Event(player, event, n) adds to the progress + the per-player contribution map
--       (in-memory, keyed by userId) when `event` matches the live goal's event.
--   * Completion -> one Buffs.AddServerGift("the whole server", { kind = "goal", text })
--       (the existing +10 % server luck for ServerLuckDuration; the ONLY reward), then
--       GoalRest s idle, then the next goal. Expiry -> feedOnly "goal" row
--       ("Goal missed — new goal in 60 s") and the same rest.
--   * Broadcast: a 1 s ticker fires Remotes.ServerGoal:FireAllClients(state) only when
--       dirty (progress moved); phase changes (start / complete / miss) flush at once.
--
--   ServerGoals.Init(S)
--   ServerGoals.Event(player, event:"crack"|"rare"|"rebirth", n)  -- no-op when S unset
--   ServerGoals.State(player) -> payload + mine   (nil until the first goal starts)
--   ServerGoals.Mine(player)  -> int
--   ServerGoals.Advance(n) / ServerGoals.Complete()  -- Studio TestHook (`goal`, `goalComplete`)
--
--   Wire payload (ServerGoal remote + GetState().serverGoal):
--     { key, icon, label, progress:int, goal:int, active:boolean, rewardText:string,
--       endsAt:int?, completedAt:int?, missed:boolean?, nextAt:int? }   (+ mine on GetState)

local Players = game:GetService("Players")

local ServerGoals = {}
local S, Config, Remotes

-- online / PER_PLAYERS is clamped to [SCALE_MIN, SCALE_MAX]. SCALE_MIN is 0.3 (not 0.4)
-- so a solo server lands exactly on every goal's goalMin floor (150 / 3 / 1) — the
-- plan's acceptance criterion — instead of 200 / 4 / 2.
local PER_PLAYERS = 5
local SCALE_MIN, SCALE_MAX = 0.3, 2

local current = nil  -- { key, icon, event, label, progress, goal, startedAt, endsAt, contrib = {[userId]=n}, active, completedAt?, missed? }
local restUntil = 0  -- os.time() when the next goal may start (0 = none pending)
local nextIdx = 1    -- round-robin cursor into Config.Social.Goals
local dirty = false
local lastFlush = 0  -- os.clock() of the last FireAllClients

local function social()
	return (Config and Config.Social) or {}
end

local function goalDefs()
	local g = social().Goals
	return type(g) == "table" and g or {}
end

local function rewardText()
	local bal = (Config and Config.Balance) or {}
	local pct = math.floor((tonumber(bal.ServerLuckPerGift) or 0.1) * 100 + 0.5)
	local mins = math.floor((tonumber(bal.ServerLuckDuration) or 120) / 60 + 0.5)
	return string.format("+%d%% Server Luck for %d min", pct, mins)
end

local function payload()
	if not current then return nil end
	return {
		key = current.key,
		icon = current.icon,
		label = current.label,
		progress = math.floor(current.progress),
		goal = current.goal,
		active = current.active == true,
		rewardText = rewardText(),
		endsAt = current.active and current.endsAt or nil,
		completedAt = current.completedAt,
		missed = current.missed or nil,
		nextAt = (restUntil > 0) and restUntil or nil, -- when the next goal starts (rest phase)
	}
end

local function flush()
	dirty = false
	lastFlush = os.clock()
	local data = payload()
	if data and Remotes and Remotes:FindFirstChild("ServerGoal") then
		Remotes.ServerGoal:FireAllClients(data)
	end
end

local function startNext(now)
	local defs = goalDefs()
	if #defs == 0 then return end
	if nextIdx > #defs then nextIdx = 1 end
	local def = defs[nextIdx]
	nextIdx += 1
	local online = #Players:GetPlayers()
	local scale = math.clamp(online / PER_PLAYERS, SCALE_MIN, SCALE_MAX)
	local target = math.max(tonumber(def.goalMin) or 1, math.ceil((tonumber(def.goal) or 1) * scale))
	current = {
		key = tostring(def.key or "goal"),
		icon = tostring(def.icon or "🎯"),
		event = def.event,
		label = string.format(def.label or "%d together", target),
		progress = 0,
		goal = target,
		startedAt = now,
		endsAt = now + (tonumber(social().GoalWindow) or 900),
		contrib = {},
		active = true,
	}
	restUntil = 0
	flush()
end

local function complete(now)
	if not (current and current.active) then return false end
	current.active = false
	current.completedAt = now
	restUntil = now + (tonumber(social().GoalRest) or 60)
	-- the ONLY reward: the existing server-luck stack; AddServerGift is the single
	-- broadcast (kind "goal" -> headline) and pushes every snapshot now + on expiry
	if S.Buffs and S.Buffs.AddServerGift then
		S.Buffs.AddServerGift("the whole server", {
			kind = "goal",
			text = "🎯 SERVER GOAL COMPLETE — " .. rewardText() .. "!",
		})
	end
	flush()
	return true
end

local function expire(now)
	if not (current and current.active) then return end
	current.active = false
	current.missed = true
	local rest = tonumber(social().GoalRest) or 60
	restUntil = now + rest
	if S.Social and S.Social.Broadcast then
		S.Social.Broadcast("goal", { text = "⏳ Goal missed — new goal in " .. rest .. " s", feedOnly = true })
	end
	flush()
end

local function addProgress(n, userId)
	if not (current and current.active) then return false end
	n = tonumber(n) or 0
	if n ~= n or n <= 0 or n == math.huge then return false end
	current.progress += n
	if userId then current.contrib[userId] = (current.contrib[userId] or 0) + n end
	dirty = true
	if current.progress >= current.goal then
		current.progress = current.goal
		complete(os.time())
	end
	return true
end

-- Hook sites: Geodes.TryCrack ("crack", + "rare" when rarityIdx >= 5), the Golden
-- Geode ("rare"), the onboarding starter crack ("crack"), Econ.Buy("Rebirth").
-- Node ClickDetectors are live before S.Ready, so this stays a no-op until Init.
function ServerGoals.Event(player, event, n)
	if not S then return end
	if not (current and current.active) then return end
	if type(event) ~= "string" or event ~= current.event then return end
	local userId = (typeof(player) == "Instance") and player.UserId or nil
	addProgress(n == nil and 1 or n, userId)
end

function ServerGoals.Mine(player)
	if not (current and typeof(player) == "Instance") then return 0 end
	return math.floor(current.contrib[player.UserId] or 0)
end

function ServerGoals.State(player)
	if not S then return nil end
	local data = payload()
	if not data then return nil end
	data.mine = ServerGoals.Mine(player)
	return data
end

-- ===== Studio TestHook =====

-- goal(n): advance the live goal by n (no contributor)
function ServerGoals.Advance(n)
	if not (current and current.active) then return { ok = false, err = "no active goal" } end
	addProgress(n == nil and 1 or n, nil)
	return { ok = true, state = payload() }
end

-- goalComplete: force-complete the live goal (exactly one AddServerGift, no gems)
function ServerGoals.Complete()
	if not (current and current.active) then return { ok = false, err = "no active goal" } end
	current.progress = current.goal
	dirty = true
	complete(os.time())
	return { ok = true, key = current.key }
end

-- ===== ticker =====

local function tick()
	local now = os.time()
	if current and current.active then
		if now >= current.endsAt then expire(now) end
	elseif #Players:GetPlayers() > 0 and (restUntil == 0 or now >= restUntil) then
		startNext(now) -- first goal, or the next one after the rest (only with someone online)
	end
	if dirty and os.clock() - lastFlush >= 1 then flush() end
end

function ServerGoals.Init(services)
	S = services
	Config, Remotes = S.Config, S.Remotes

	-- 1 s ticker: expiry / rest -> next goal / dirty flush (≤ 1 ServerGoal event/s for
	-- progress; phase changes go out immediately). Body pcall'd so it never dies.
	task.spawn(function()
		while true do
			task.wait(1)
			local ok, err = pcall(tick)
			if not ok then warn("[ServerGoals] tick failed: " .. tostring(err)) end
		end
	end)
end

return ServerGoals
