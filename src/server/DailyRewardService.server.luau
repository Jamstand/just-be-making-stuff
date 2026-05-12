local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local ClaimDailyReward = ReplicatedStorage.Remotes.ClaimDailyReward
local Notify = ReplicatedStorage.Remotes.Notify

local function waitForData() while not _G.PlayerDataService do task.wait(0.1) end end
waitForData()

ClaimDailyReward.OnServerInvoke = function(player)
	local data = _G.PlayerDataService.Get(player)
	if not data then return { success = false, message = "Data not loaded" } end

	local now = os.time()
	local elapsed = now - (data.LastDailyClaim or 0)
	if elapsed < GameConfig.DailyReward.IntervalSeconds then
		local wait = GameConfig.DailyReward.IntervalSeconds - elapsed
		return { success = false, message = string.format("Come back in %dh %dm", math.floor(wait / 3600), math.floor((wait % 3600) / 60)) }
	end

	_G.PlayerDataService.AddCoins(player, GameConfig.DailyReward.CoinAmount)
	_G.PlayerDataService.AddGems(player, GameConfig.DailyReward.GemAmount)
	_G.PlayerDataService.SetLastDailyClaim(player, now)
	Notify:FireClient(player, string.format("Daily: +%d coins, +%d gems", GameConfig.DailyReward.CoinAmount, GameConfig.DailyReward.GemAmount))
	return { success = true, message = "Claimed" }
end
