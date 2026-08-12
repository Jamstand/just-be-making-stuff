-- MonetizationService: 4 game passes + 4 dev products through MarketplaceService.
-- While IDs are placeholders (0) or the place is unpublished, purchases run in
-- StudioTestMode: simulated through the SAME grant functions ProcessReceipt uses.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Monetize = {}
local S
local ownsCache = {}
local lastPurchase = {}
local firstSession = {} -- [player] = true if this is their first-ever session

-- The one-time Starter Pack is offered ONLY during a player's first session and
-- only if not already owned.
function Monetize.StarterOffered(player)
	local p = S.Data.Cache[player]
	if not p then return false end
	return firstSession[player] == true and not p.starterPackBought
end

-- Simulated grants are ONLY allowed inside Studio. A live server with placeholder
-- ids must never self-grant, or any exploiter could claim every pass for free.
local function testMode(item)
	return (item.id == 0 or game.GameId == 0) and RunService:IsStudio()
end

function Monetize.Owns(player, key)
	if not S then return false end -- may be probed during startup before Init sets S
	local item = S.Config.PassByKey(key)
	if not item then return false end
	local p = S.Data.Cache[player]
	if testMode(item) then
		return (p and p.testPasses[key] == true) or false
	end
	ownsCache[player] = ownsCache[player] or {}
	local cached = ownsCache[player][key]
	if cached ~= nil then return cached end
	local ok, owns = pcall(MarketplaceService.UserOwnsGamePassAsync, MarketplaceService, player.UserId, item.id)
	owns = (ok and owns) == true
	ownsCache[player][key] = owns
	return owns
end

local function applyVIPVisuals(player)
	player:SetAttribute("IsVIP", true) -- read by the client chat-tag hook
	local char = player.Character
	if not char then return end
	local head = char:FindFirstChild("Head")
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not head or head:FindFirstChild("VIPTag") then return end
	local bb = Instance.new("BillboardGui")
	bb.Name = "VIPTag"
	bb.Size = UDim2.fromScale(5, 1.2)
	bb.StudsOffset = Vector3.new(0, 2.2, 0)
	bb.AlwaysOnTop = true
	bb.MaxDistance = 120
	bb.Parent = head
	local tl = Instance.new("TextLabel")
	tl.Size = UDim2.fromScale(1, 1)
	tl.BackgroundTransparency = 1
	tl.Text = "👑 VIP"
	tl.TextColor3 = Color3.fromRGB(255, 210, 80)
	tl.TextStrokeTransparency = 0.2
	tl.TextScaled = true
	tl.Font = Enum.Font.GothamBlack
	tl.Parent = bb
	if hrp then
		local att = Instance.new("Attachment")
		att.Name = "VIPAura"
		att.Parent = hrp
		local pe = Instance.new("ParticleEmitter")
		pe.Color = ColorSequence.new(Color3.fromRGB(255, 215, 100))
		pe.Rate = 7
		pe.Lifetime = NumberRange.new(0.8, 1.6)
		pe.Speed = NumberRange.new(1, 2.5)
		pe.SpreadAngle = Vector2.new(180, 180)
		pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 0) })
		pe.LightEmission = 1
		pe.Parent = att
	end
end

function Monetize.OnPassGranted(player, key)
	ownsCache[player] = nil
	local item = S.Config.PassByKey(key)
	if key == "VIP" then applyVIPVisuals(player) end
	S.Remotes.Announce:FireAllClients({
		kind = "pass",
		text = item.icon .. " " .. player.DisplayName .. " unlocked " .. item.name .. "!",
		color = Color3.fromRGB(255, 210, 90),
	})
	S.Econ.Push(player)
	S.Data.SaveSoon(player) -- persist a paid unlock the instant it is granted
end

function Monetize.GrantProduct(player, key, targetUserId)
	if key == "LuckyBoost" then
		S.Buffs.GrantBoost(player, S.Config.Balance.BoostSeconds)
		return "⚡ Lucky Boost active!"
	elseif key == "GiftBoost" then
		local target = nil
		if type(targetUserId) == "number" then
			local ok, found = pcall(Players.GetPlayerByUserId, Players, targetUserId)
			if ok then target = found end
		end
		if not target or target == player then
			for _, other in ipairs(Players:GetPlayers()) do
				if other ~= player then target = other break end
			end
		end
		target = target or player
		S.Buffs.GrantBoost(target, S.Config.Balance.BoostSeconds)
		S.Buffs.AddServerGift(player.DisplayName)
		return "🎁 Boost gifted to " .. target.DisplayName .. "!"
	elseif key == "InstantRegrow" then
		local p = S.Data.WaitFor(player, 5)
		if p then
			p.lastHarvest = os.time() - 86400
			S.Garden.Refresh(player)
			S.Econ.Push(player)
		end
		return "🌱 Garden fully grown — go harvest!"
	elseif key == "GoldenGeode" then
		S.Geodes.SpawnGolden(player, false)
		return "🌟 Golden Geode spawned by the crater!"
	elseif key == "CoinsSmall" or key == "CoinsMedium" or key == "CoinsLarge" then
		local item = S.Config.ProductByKey(key)
		local amt = (item and item.coins) or 0
		S.Econ.AwardRaw(player, amt)
		return "💰 +" .. S.Config.Fmt(amt) .. " Coins!"
	elseif key == "StarterPack" then
		local p = S.Data.WaitFor(player, 5)
		if not p then return "Purchase pending…" end
		if p.starterPackBought then return "You already own the Starter Pack!" end
		p.starterPackBought = true
		local item = S.Config.ProductByKey(key)
		S.Econ.AwardRaw(player, (item and item.coins) or 0)
		if S.Data.SaveSoon then S.Data.SaveSoon(player) end
		S.Econ.Push(player) -- unlocks the Starter Sprite pet (derived from the flag)
		return "⭐ Starter Pack unlocked — Coins + exclusive Starter Sprite pet!"
	end
	return nil
end

function Monetize.Init(services)
	S = services

	S.Remotes.Purchase.OnServerInvoke = function(player, kind, key, targetUserId)
		if not S.Ready then return { ok = false, err = "Starting up…" } end
		if type(kind) ~= "string" or type(key) ~= "string" then
			return { ok = false, err = "Bad request" }
		end
		local now = os.clock()
		if lastPurchase[player] and now - lastPurchase[player] < 0.5 then
			return { ok = false, err = "Slow down!" }
		end
		lastPurchase[player] = now
		if kind == "pass" then
			local item = S.Config.PassByKey(key)
			if not item then return { ok = false, err = "Unknown pass" } end
			if Monetize.Owns(player, key) then return { ok = false, err = "Already owned!" } end
			if testMode(item) then
				local p = S.Data.WaitFor(player, 5)
				if not p then return { ok = false, err = "Loading..." } end
				p.testPasses[key] = true
				Monetize.OnPassGranted(player, key)
				return { ok = true, test = true, msg = item.icon .. " " .. item.name .. " unlocked! (Studio test)" }
			elseif item.id == 0 then
				return { ok = false, err = "Purchases aren't live yet — coming soon!" }
			else
				MarketplaceService:PromptGamePassPurchase(player, item.id)
				return { ok = true, prompted = true }
			end
		elseif kind == "product" then
			local item = S.Config.ProductByKey(key)
			if not item then return { ok = false, err = "Unknown product" } end
			if key == "StarterPack" and not Monetize.StarterOffered(player) then
				return { ok = false, err = "Offer expired" }
			end
			if testMode(item) then
				local msg = Monetize.GrantProduct(player, key, targetUserId)
				return { ok = true, test = true, msg = (msg or "Purchased!") .. " (Studio test)" }
			elseif item.id == 0 then
				return { ok = false, err = "Purchases aren't live yet — coming soon!" }
			else
				MarketplaceService:PromptProductPurchase(player, item.id)
				return { ok = true, prompted = true }
			end
		end
		return { ok = false, err = "Bad kind" }
	end

	-- real-purchase paths (used once IDs are filled in and the game is published)
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, purchased)
		if not purchased then return end
		for _, pass in ipairs(S.Config.GamePasses) do
			if pass.id == passId then
				local p = S.Data.WaitFor(player, 5)
				if p then Monetize.OnPassGranted(player, pass.key) end
			end
		end
	end)

	MarketplaceService.ProcessReceipt = function(receipt)
		local player = Players:GetPlayerByUserId(receipt.PlayerId)
		if not player then return Enum.ProductPurchaseDecision.NotProcessedYet end
		local p = S.Data.WaitFor(player, 10)
		if not p then return Enum.ProductPurchaseDecision.NotProcessedYet end
		-- Never acknowledge a paid purchase we cannot durably persist: if the data
		-- layer can't save, tell Roblox to re-deliver later rather than grant-and-lose.
		if not S.Data.IsUsable() then return Enum.ProductPurchaseDecision.NotProcessedYet end
		local rid = tostring(receipt.PurchaseId)
		for _, seen in ipairs(p.receipts) do
			if seen == rid then return Enum.ProductPurchaseDecision.PurchaseGranted end
		end
		local key = nil
		for _, prod in ipairs(S.Config.DevProducts) do
			if prod.id == receipt.ProductId then key = prod.key end
		end
		if not key then return Enum.ProductPurchaseDecision.NotProcessedYet end
		Monetize.GrantProduct(player, key)
		table.insert(p.receipts, rid)
		if #p.receipts > 50 then table.remove(p.receipts, 1) end
		-- Only report PurchaseGranted after the receipt id + granted effect are
		-- confirmed on disk. Otherwise roll back the receipt mark and let Roblox retry.
		if S.Data.SaveNow(player) then
			return Enum.ProductPurchaseDecision.PurchaseGranted
		else
			for i = #p.receipts, 1, -1 do
				if p.receipts[i] == rid then table.remove(p.receipts, i) break end
			end
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
	end

	-- VIP visuals on spawn + owns prefetch
	local function watchCharacter(player)
		player.CharacterAdded:Connect(function()
			task.wait(0.5)
			if Monetize.Owns(player, "VIP") then applyVIPVisuals(player) end
		end)
		if player.Character and Monetize.Owns(player, "VIP") then applyVIPVisuals(player) end
	end
	Players.PlayerAdded:Connect(watchCharacter)
	task.defer(function()
		for _, p in ipairs(Players:GetPlayers()) do watchCharacter(p) end
	end)

	-- first-session detection for the Starter Pack offer
	local function trackFirstSession(player)
		task.spawn(function()
			local p = S.Data.WaitFor(player, 15)
			if not p then return end
			if not p.firstJoinRecorded then
				p.firstJoinRecorded = true
				firstSession[player] = true
				if S.Data.SaveSoon then S.Data.SaveSoon(player) end
				S.Econ.Push(player)
				task.wait(3)
				if Monetize.StarterOffered(player) then
					S.Remotes.StarterPopup:FireClient(player)
				end
			else
				firstSession[player] = false
				S.Econ.Push(player)
			end
		end)
	end
	Players.PlayerAdded:Connect(trackFirstSession)
	task.defer(function()
		for _, p in ipairs(Players:GetPlayers()) do trackFirstSession(p) end
	end)

	Players.PlayerRemoving:Connect(function(player)
		ownsCache[player] = nil
		lastPurchase[player] = nil
		firstSession[player] = nil
	end)
end

return Monetize
