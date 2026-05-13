--[[
    Server-validated shop. Handles:
      - PurchaseUpgrade (RemoteFunction) -> debits currency, advances tier
      - ClaimDailyReward (RemoteFunction) -> awards coins+gems on cooldown

    Currency purchases (Coins / Gems for upgrades) live here; Robux purchases
    (gem packs, game passes) live in MonetizationService.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local PurchaseUpgrade = Remotes:WaitForChild("PurchaseUpgrade")
local ClaimDailyReward = Remotes:WaitForChild("ClaimDailyReward")
local ShowToast = Remotes:WaitForChild("ShowToast")

local function waitForGlobal(name: string)
	local start = os.clock()
	while not (_G.CoinRush and _G.CoinRush[name]) do
		if os.clock() - start > 15 then
			warn(("[ShopService] %s not ready after 15s"):format(name))
			return nil
		end
		task.wait()
	end
	return _G.CoinRush[name]
end

local PlayerData = waitForGlobal("PlayerData")
local UpgradeService = waitForGlobal("UpgradeService")

local function toast(player: Player, message: string)
	ShowToast:FireClient(player, message)
end

PurchaseUpgrade.OnServerInvoke = function(player, upgradeName)
	if type(upgradeName) ~= "string" then
		return { ok = false, reason = "Invalid request" }
	end
	local config = GameConfig.Upgrades[upgradeName]
	if not config then
		return { ok = false, reason = "Unknown upgrade" }
	end
	if not PlayerData then
		return { ok = false, reason = "Server not ready" }
	end
	local data = PlayerData.Get(player)
	if not data then
		return { ok = false, reason = "Player data missing" }
	end

	local currentTier = data.Upgrades[upgradeName] or 0
	local nextTier = currentTier + 1
	local entry = config.Tiers[nextTier]
	if not entry then
		return { ok = false, reason = "Max tier" }
	end

	local currency = config.Currency
	if currency ~= "Coins" and currency ~= "Gems" then
		return { ok = false, reason = "Bad config" }
	end

	local cost = entry.Cost
	if data[currency] < cost then
		return { ok = false, reason = ("Need %d %s"):format(cost - data[currency], currency:lower()) }
	end

	PlayerData.Increment(player, currency, -cost)
	PlayerData.SetUpgradeTier(player, upgradeName, nextTier)
	if UpgradeService then
		UpgradeService.Reapply(player)
	end
	toast(player, ("Upgraded %s to tier %d"):format(config.Display, nextTier))
	return { ok = true, tier = nextTier }
end

ClaimDailyReward.OnServerInvoke = function(player)
	if not PlayerData then
		return { ok = false, reason = "Server not ready" }
	end
	local data = PlayerData.Get(player)
	if not data then
		return { ok = false, reason = "Player data missing" }
	end

	local now = os.time()
	local elapsed = now - (data.LastDailyClaim or 0)
	local cooldown = GameConfig.DailyCooldownSeconds
	if elapsed < cooldown then
		return { ok = false, reason = "Cooldown", remaining = cooldown - elapsed }
	end

	PlayerData.Increment(player, "Coins", GameConfig.DailyRewardCoins)
	PlayerData.Increment(player, "Gems", GameConfig.DailyRewardGems)
	PlayerData.MarkDailyClaim(player)
	toast(player, ("Daily reward: +%d coins, +%d gems"):format(GameConfig.DailyRewardCoins, GameConfig.DailyRewardGems))
	return { ok = true }
end
