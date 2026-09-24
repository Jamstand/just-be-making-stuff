-- BuffService: personal Lucky Boosts, stacking server-wide gift luck,
-- the Golden Hour lighting cycle, daily streaks, and VIP daily freebies.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")

local Buffs = {}
local S
local serverGifts = {}
local goldenUntil = 0
local nextGoldenAt = 0 -- os.time() the next Golden Hour starts (tracked by the cycle loop)

function Buffs.ServerLuckPct()
	local now, n = os.time(), 0
	for _, exp in ipairs(serverGifts) do
		if exp > now then n += 1 end
	end
	return math.min(S.Config.Balance.ServerLuckMax, n * S.Config.Balance.ServerLuckPerGift)
end

-- ===== timers for the HUD chips (all server os.time(); 0 = inactive / unknown) =====

-- When the last live server-luck stack expires (0 when none is active).
function Buffs.ServerLuckUntil()
	local now, best = os.time(), 0
	for _, exp in ipairs(serverGifts) do
		if exp > now and exp > best then best = exp end
	end
	return best
end

-- When the current Golden Hour ends (0 when inactive).
function Buffs.GoldenUntil()
	return (os.time() < goldenUntil) and goldenUntil or 0
end

-- When the next Golden Hour starts (0 while one is running).
function Buffs.NextGoldenAt()
	if os.time() < goldenUntil then return 0 end
	return nextGoldenAt
end

local function goldenCycleLength()
	local interval = workspace:GetAttribute("GoldenHourInterval") or S.Config.Balance.GoldenHourInterval
	return math.max(35, (tonumber(interval) or 1800) - 30) + 30
end

local function pushAll()
	for _, player in ipairs(Players:GetPlayers()) do
		S.Econ.Push(player)
	end
end

-- Stack one +10% server-luck gift. opts = { kind?, text? } lets ServerGoals reuse the
-- buff under its own headline; either way exactly ONE broadcast goes out.
function Buffs.AddServerGift(byName, opts)
	local now = os.time()
	for i = #serverGifts, 1, -1 do -- prune expired stacks so the list never grows
		if serverGifts[i] <= now then table.remove(serverGifts, i) end
	end
	local duration = S.Config.Balance.ServerLuckDuration
	table.insert(serverGifts, now + duration)
	local kind = (type(opts) == "table" and type(opts.kind) == "string") and opts.kind or "gift"
	local text = (type(opts) == "table" and type(opts.text) == "string") and opts.text
		or ("🎁 +" .. math.floor(S.Config.Balance.ServerLuckPerGift * 100 + 0.5) .. "% SERVER LUCK — thanks, " .. tostring(byName) .. "!")
	S.Social.Broadcast(kind, { text = text, colorRGB = { 120, 255, 170 } })
	-- everyone's HUD should reflect the new server luck now AND its expiry (idle
	-- clients otherwise keep a stale chip until their next crack)
	pushAll()
	task.delay(duration + 0.5, pushAll)
end

function Buffs.GoldenHourActive()
	return os.time() < goldenUntil
end

function Buffs.GrantBoost(player, seconds)
	local p = S.Data.WaitFor(player, 5)
	if not p then return end
	local now = os.time()
	p.boostUntil = math.min(math.max(p.boostUntil, now) + seconds, now + S.Config.Balance.BoostCapSeconds)
	S.Econ.Push(player)
end

local function handleJoin(player)
	local p = S.Data.WaitFor(player)
	if not p then return end

	-- (daily login streak + rewards now owned by the Dailies module)
	local today = os.date("!%Y-%m-%d")

	-- VIP daily free boost
	if S.Monetize.Owns(player, "VIP") and p.lastVIPBoostDate ~= today then
		p.lastVIPBoostDate = today
		Buffs.GrantBoost(player, S.Config.Balance.BoostSeconds)
		S.Econ.AwardRaw(player, 5000) -- VIP daily Gem bonus
		S.Social.Tell(player, "vip", {
			text = "👑 VIP daily bonus: +5,000 Gems & a free Lucky Boost!",
			colorRGB = { 255, 210, 90 },
		})
	end

	S.Econ.Push(player)
end

function Buffs.Init(services)
	S = services

	Players.PlayerAdded:Connect(function(player)
		task.spawn(handleJoin, player)
	end)
	-- defer the start-up sweep so every module's Init has set its services first
	task.defer(function()
		for _, p in ipairs(Players:GetPlayers()) do
			task.spawn(handleJoin, p)
		end
	end)

	-- Golden Hour cycle: warn 30s ahead, then a 2-minute +50% luck window with gold lighting
	nextGoldenAt = os.time() + goldenCycleLength()
	task.spawn(function()
		while true do
			local total = goldenCycleLength()
			nextGoldenAt = os.time() + total -- the HUD "Golden Hour in M:SS" clock
			task.wait(total - 30)
			S.Social.Broadcast("warn", {
				text = "🌤️ GOLDEN HOUR in 30 seconds — +50% Luck for everyone!",
				colorRGB = { 255, 225, 140 },
			})
			task.wait(30)
			local duration = S.Config.Balance.GoldenHourDuration
			goldenUntil = os.time() + duration
			S.Remotes.GoldenHour:FireAllClients({ active = true, remaining = duration })
			S.Social.Broadcast("golden", {
				text = "🌟 GOLDEN HOUR! +50% Luck for 2 minutes!",
				colorRGB = { 255, 225, 140 },
			})
			local cc = Lighting:FindFirstChild("GeodeColor")
			if cc then
				TweenService:Create(cc, TweenInfo.new(2), { TintColor = Color3.fromRGB(255, 228, 175) }):Play()
			end
			for _, player in ipairs(Players:GetPlayers()) do S.Econ.Push(player) end
			task.wait(duration)
			if cc then
				TweenService:Create(cc, TweenInfo.new(2), { TintColor = Color3.fromRGB(245, 240, 255) }):Play()
			end
			S.Remotes.GoldenHour:FireAllClients({ active = false })
			for _, player in ipairs(Players:GetPlayers()) do S.Econ.Push(player) end
		end
	end)
end

return Buffs