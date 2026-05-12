-- Handles client requests to buy upgrade tiers with Coins/Gems.
-- All purchase validation happens server-side.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local ShopCatalog = require(ReplicatedStorage.Shared.ShopCatalog)
local PurchaseUpgrade = ReplicatedStorage.Remotes.PurchaseUpgrade
local Notify = ReplicatedStorage.Remotes.Notify

local function waitForServices()
	while not (_G.PlayerDataService and _G.UpgradeService) do task.wait(0.1) end
end

waitForServices()

local function reply(success: boolean, message: string)
	return { success = success, message = message }
end

PurchaseUpgrade.OnServerInvoke = function(player, upgradeName)
	if type(upgradeName) ~= "string" then return reply(false, "Invalid upgrade") end
	local entry = ShopCatalog.Upgrades[upgradeName]
	local cap = GameConfig.Upgrades[upgradeName]
	if not entry or not cap then return reply(false, "Unknown upgrade") end

	local data = _G.PlayerDataService.Get(player)
	if not data then return reply(false, "Data not loaded") end

	local currentTier = data.Upgrades[upgradeName] or 0
	if currentTier >= cap.MaxTier then return reply(false, "Already max tier") end

	local nextTier = currentTier + 1
	local cost = entry.Costs[nextTier]
	if not cost then return reply(false, "No price for that tier") end

	if entry.CurrencyType == "Coins" then
		if not _G.PlayerDataService.SpendCoins(player, cost) then
			Notify:FireClient(player, "Not enough coins")
			return reply(false, "Not enough coins")
		end
	elseif entry.CurrencyType == "Gems" then
		if not _G.PlayerDataService.SpendGems(player, cost) then
			Notify:FireClient(player, "Not enough gems")
			return reply(false, "Not enough gems")
		end
	else
		return reply(false, "Bad currency type")
	end

	_G.PlayerDataService.SetUpgradeTier(player, upgradeName, nextTier)
	_G.UpgradeService.Reapply(player)
	Notify:FireClient(player, string.format("%s upgraded to tier %d", entry.DisplayName, nextTier))
	return reply(true, "Purchased")
end
