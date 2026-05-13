--[[
    Robux purchase flows:
      - DeveloperProduct (gem packs): client fires PromptGemProduct ->
        server prompts MarketplaceService -> ProcessReceipt grants gems.
      - GamePass: client fires PromptGamePass -> server prompts ->
        PromptGamePassPurchaseFinished marks ownership.

    Robux purchases ALWAYS FAIL in Studio test mode. Test these in the
    published place via the real Roblox client.

    Idempotency on ProcessReceipt:
      We follow Roblox's documented pattern (grant -> save -> return
      PurchaseGranted). In the unlikely case the server crashes between
      the save succeeding and us returning PurchaseGranted, Roblox will
      retry on the next join and the player may receive an extra grant.
      For production-scale work, wire in a separate "PurchaseReceipts"
      DataStore keyed by receiptInfo.PurchaseId.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local PromptGemProduct = Remotes:WaitForChild("PromptGemProduct")
local PromptGamePass = Remotes:WaitForChild("PromptGamePass")
local ShowToast = Remotes:WaitForChild("ShowToast")

local function waitForGlobal(name: string)
	local start = os.clock()
	while not (_G.CoinRush and _G.CoinRush[name]) do
		if os.clock() - start > 15 then
			warn(("[MonetizationService] %s not ready after 15s"):format(name))
			return nil
		end
		task.wait()
	end
	return _G.CoinRush[name]
end

local PlayerData = waitForGlobal("PlayerData")
local UpgradeService = waitForGlobal("UpgradeService")

-- Build lookup tables from config ----------------------------------------

local productIdToKey: { [number]: string } = {}
local gamePassIdToKey: { [number]: string } = {}

local function rebuildLookups()
	table.clear(productIdToKey)
	table.clear(gamePassIdToKey)
	for key, product in GameConfig.GemProducts do
		if type(product.ProductId) == "number" and product.ProductId > 0 then
			productIdToKey[product.ProductId] = key
		end
	end
	for key, pass in GameConfig.GamePasses do
		if type(pass.GamePassId) == "number" and pass.GamePassId > 0 then
			gamePassIdToKey[pass.GamePassId] = key
		end
	end
end

rebuildLookups()

-- Dev product prompts ----------------------------------------------------

PromptGemProduct.OnServerEvent:Connect(function(player, productKey)
	if type(productKey) ~= "string" then return end
	local product = GameConfig.GemProducts[productKey]
	if not product then return end
	if product.ProductId <= 0 then
		ShowToast:FireClient(player, "Not configured yet — paste a ProductId in GameConfig.")
		return
	end
	local ok, err = pcall(function()
		MarketplaceService:PromptProductPurchase(player, product.ProductId)
	end)
	if not ok then
		warn("[MonetizationService] PromptProductPurchase failed:", err)
	end
end)

-- ProcessReceipt grants gems --------------------------------------------

MarketplaceService.ProcessReceipt = function(receiptInfo)
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local productKey = productIdToKey[receiptInfo.ProductId]
	if not productKey then
		warn(("[MonetizationService] Unknown ProductId %d"):format(receiptInfo.ProductId))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if not PlayerData then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local data = PlayerData.Get(player)
	if not data then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local product = GameConfig.GemProducts[productKey]
	PlayerData.Increment(player, "Gems", product.Gems)
	if not PlayerData.Save(player) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	ShowToast:FireClient(player, ("+%d gems"):format(product.Gems))
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- Game pass prompts ------------------------------------------------------

PromptGamePass.OnServerEvent:Connect(function(player, passKey)
	if type(passKey) ~= "string" then return end
	local pass = GameConfig.GamePasses[passKey]
	if not pass then return end
	if pass.GamePassId <= 0 then
		ShowToast:FireClient(player, "Not configured yet — paste a GamePassId in GameConfig.")
		return
	end

	if PlayerData then
		local data = PlayerData.Get(player)
		if data and data.Passes[passKey] then
			ShowToast:FireClient(player, "You already own this pass.")
			return
		end
	end

	local ok, err = pcall(function()
		MarketplaceService:PromptGamePassPurchase(player, pass.GamePassId)
	end)
	if not ok then
		warn("[MonetizationService] PromptGamePassPurchase failed:", err)
	end
end)

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, wasPurchased)
	if not wasPurchased then return end
	local key = gamePassIdToKey[gamePassId]
	if not key then return end
	if PlayerData then
		PlayerData.SetPassOwned(player, key, true)
	end
	if UpgradeService then
		UpgradeService.Reapply(player)
	end
	ShowToast:FireClient(player, ("Unlocked: %s"):format(GameConfig.GamePasses[key].Display))
end)

-- On join, refresh ownership for each configured pass --------------------

local function refreshOwnership(player: Player)
	if not PlayerData then return end
	local changed = false
	for key, pass in GameConfig.GamePasses do
		if pass.GamePassId <= 0 then continue end
		local owned = false
		local ok, result = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, pass.GamePassId)
		end)
		if ok then
			owned = result == true
		end
		local data = PlayerData.Get(player)
		if data and data.Passes[key] ~= owned then
			PlayerData.SetPassOwned(player, key, owned)
			changed = true
		end
	end
	if changed and UpgradeService then
		UpgradeService.Reapply(player)
	end
end

Players.PlayerAdded:Connect(function(player)
	-- Wait for PlayerDataService to load the player's data before reconciling.
	task.wait(2)
	refreshOwnership(player)
end)

for _, player in Players:GetPlayers() do
	task.spawn(function()
		task.wait(2)
		refreshOwnership(player)
	end)
end
