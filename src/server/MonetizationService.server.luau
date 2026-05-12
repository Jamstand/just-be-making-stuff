-- Robux-driven monetization: DeveloperProducts (consumable, grant gems) and
-- GamePasses (one-time, grant permanent perks).
--
-- Setup checklist (Roblox creator dashboard):
--   1. Publish the place.
--   2. Create Developer Products for each gem pack; copy their IDs into
--      GameConfig.GemProducts[*].ProductId.
--   3. Create Game Passes for DoubleCoins / VIP / AutoCollect; copy IDs into
--      GameConfig.GamePasses[*].GamePassId.
--
-- Until those IDs are set, the prompt calls will simply fail at runtime, but
-- the server logic still runs cleanly.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local PromptProduct = ReplicatedStorage.Remotes.PromptProduct
local PromptGamePass = ReplicatedStorage.Remotes.PromptGamePass
local Notify = ReplicatedStorage.Remotes.Notify

local function waitForServices()
	while not (_G.PlayerDataService and _G.UpgradeService) do task.wait(0.1) end
end
waitForServices()

-- Build reverse lookup: productId -> gem reward
local productById: { [number]: { Gems: number, Key: string } } = {}
for key, info in GameConfig.GemProducts do
	if info.ProductId and info.ProductId ~= 0 then
		productById[info.ProductId] = { Gems = info.Gems, Key = key }
	end
end

local passById: { [number]: string } = {}
for key, info in GameConfig.GamePasses do
	if info.GamePassId and info.GamePassId ~= 0 then
		passById[info.GamePassId] = key
	end
end

-- Client → "I want to buy gem pack X"
PromptProduct.OnServerEvent:Connect(function(player, productKey)
	local info = GameConfig.GemProducts[productKey]
	if not info then return end
	if info.ProductId == 0 then
		Notify:FireClient(player, "This product isn't set up yet")
		return
	end
	MarketplaceService:PromptProductPurchase(player, info.ProductId)
end)

-- Client → "I want to buy gamepass X"
PromptGamePass.OnServerEvent:Connect(function(player, passKey)
	local info = GameConfig.GamePasses[passKey]
	if not info then return end
	if info.GamePassId == 0 then
		Notify:FireClient(player, "This gamepass isn't set up yet")
		return
	end
	MarketplaceService:PromptGamePassPurchase(player, info.GamePassId)
end)

-- Required callback: must return Enum.ProductPurchaseDecision.PurchaseGranted
-- exactly once per receipt id, after grant has been persisted. Otherwise
-- Roblox will retry until success or refund.
MarketplaceService.ProcessReceipt = function(receiptInfo)
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local mapping = productById[receiptInfo.ProductId]
	if not mapping then
		warn("[Monetization] unrecognized product id: " .. tostring(receiptInfo.ProductId))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local data = _G.PlayerDataService.Get(player)
	if not data then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	_G.PlayerDataService.AddGems(player, mapping.Gems)
	Notify:FireClient(player, string.format("+%d Gems!", mapping.Gems))
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

local function checkAndApplyPass(player: Player, passKey: string, passId: number)
	local data = _G.PlayerDataService.Get(player)
	if not data or data.OwnedPasses[passKey] then return end
	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
	end)
	if ok and owns then
		_G.PlayerDataService.MarkPassOwned(player, passKey)
		_G.UpgradeService.Reapply(player)
		Notify:FireClient(player, passKey .. " unlocked!")
	end
end

local function refreshAllPasses(player: Player)
	for key, info in GameConfig.GamePasses do
		if info.GamePassId and info.GamePassId ~= 0 then
			checkAndApplyPass(player, key, info.GamePassId)
		end
	end
end

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, purchased)
	if not purchased then return end
	local key = passById[passId]
	if not key then return end
	_G.PlayerDataService.MarkPassOwned(player, key)
	_G.UpgradeService.Reapply(player)
	Notify:FireClient(player, key .. " unlocked!")
end)

Players.PlayerAdded:Connect(function(player)
	-- Wait until data has loaded before checking ownership
	while not _G.PlayerDataService.Get(player) do task.wait(0.2) end
	refreshAllPasses(player)
end)

for _, player in Players:GetPlayers() do task.spawn(refreshAllPasses, player) end
