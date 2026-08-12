-- BuffService: personal Lucky Boosts, stacking server-wide gift luck,
-- the Golden Hour lighting cycle, daily streaks, and VIP daily freebies.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")

local Buffs = {}
local S
local serverGifts = {}
local goldenUntil = 0

function Buffs.ServerLuckPct()
	local now, n = os.time(), 0
	for _, exp in ipairs(serverGifts) do
		if exp > now then n += 1 end
	end
	return math.min(S.Config.Balance.ServerLuckMax, n * S.Config.Balance.ServerLuckPerGift)
end

function Buffs.AddServerGift(byName)
	table.insert(serverGifts, os.time() + S.Config.Balance.ServerLuckDuration)
	S.Remotes.Announce:FireAllClients({
		kind = "gift",
		text = "🎁 +10% SERVER LUCK — thanks, " .. byName .. "!",
		color = Color3.fromRGB(120, 255, 170),
	})
	-- everyone's HUD should reflect the new server luck
	for _, player in ipairs(Players:GetPlayers()) do
		S.Econ.Push(player)
	end
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
		S.Econ.AwardRaw(player, 5000) -- VIP daily Coin bonus
		S.Remotes.Announce:FireClient(player, {
			kind = "vip",
			text = "👑 VIP daily bonus: +5,000 Coins & a free Lucky Boost!",
			color = Color3.fromRGB(255, 210, 90),
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
	task.spawn(function()
		while true do
			local interval = workspace:GetAttribute("GoldenHourInterval") or S.Config.Balance.GoldenHourInterval
			task.wait(math.max(35, interval - 30))
			S.Remotes.Announce:FireAllClients({
				kind = "warn",
				text = "🌤️ GOLDEN HOUR in 30 seconds — +50% Luck for everyone!",
				color = Color3.fromRGB(255, 225, 140),
			})
			task.wait(30)
			local duration = S.Config.Balance.GoldenHourDuration
			goldenUntil = os.time() + duration
			S.Remotes.GoldenHour:FireAllClients({ active = true, remaining = duration })
			S.Remotes.Announce:FireAllClients({
				kind = "golden",
				text = "🌟 GOLDEN HOUR! +50% Luck for 2 minutes!",
				color = Color3.fromRGB(255, 225, 140),
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
