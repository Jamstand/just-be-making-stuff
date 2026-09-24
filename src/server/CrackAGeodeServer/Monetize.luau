-- MonetizationService: 4 game passes + dev products through MarketplaceService.
-- All catalog ids are LIVE — real purchase prompts are the normal path.
-- StudioTestMode survives only as the Studio fallback for id=0 / unpublished
-- testing, simulated through the SAME grant functions ProcessReceipt uses.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Monetize = {}
local S
local ownsCache = {}
local giftTarget = {} -- [player] = validated GiftBoost recipient userId, stored when the prompt opens
local giftName = {}   -- [player] = that recipient's DisplayName (for the "X left" notice if they leave)
local firstSession = {} -- [player] = true if this is their first-ever session

-- The one-time Starter Pack is offered ONLY during a player's first session and
-- only if not already owned.
function Monetize.StarterOffered(player)
	if not S then return false end -- Econ.Snapshot can probe before our Init sets S
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
	if not ok then
		-- transient Marketplace failure: do NOT cache the miss, or a real owner
		-- would lose their pass benefits for the whole session
		return false
	end
	owns = owns == true
	ownsCache[player][key] = owns
	return owns
end

local function applyVIPVisuals(player)
	-- IsVIP is read by the client chat-tag hook and by the Nameplates module, which
	-- draws the crown itself (the server-built VIPTag billboard is gone so a plate and
	-- a tag never stack). The gold aura stays server-built so everyone sees it.
	player:SetAttribute("IsVIP", true)
	local char = player.Character
	if not char then return end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp or hrp:FindFirstChild("VIPAura") then return end
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

function Monetize.OnPassGranted(player, key)
	ownsCache[player] = nil
	local item = S.Config.PassByKey(key)
	if key == "VIP" then applyVIPVisuals(player) end
	S.Social.Broadcast("pass", {
		text = item.icon .. " " .. player.DisplayName .. " unlocked " .. item.name .. "!",
		userId = player.UserId,
		colorRGB = { 255, 210, 90 },
	})
	S.Econ.Push(player)
	S.Data.SaveSoon(player) -- persist a paid unlock the instant it is granted
end

function Monetize.GrantProduct(player, key, targetUserId)
	if key == "LuckyBoost" then
		S.Buffs.GrantBoost(player, S.Config.Balance.BoostSeconds)
		return "⚡ Lucky Boost active!"
	elseif key == "GiftBoost" then
		-- Recipient = the id validated when the prompt opened (or the Studio test arg).
		-- Never re-target to a random player: if they left before the receipt landed,
		-- the personal boost goes to the BUYER and the buyer is told who was missed.
		local target = nil
		if S.IsUserId(targetUserId) then
			local ok, found = pcall(Players.GetPlayerByUserId, Players, targetUserId)
			if ok and found and found ~= player and found.Parent == Players then target = found end
		end
		local msg
		if target then
			S.Buffs.GrantBoost(target, S.Config.Balance.BoostSeconds)
			S.Social.Tell(target, "giftReceived", {
				text = "🎁 " .. player.DisplayName .. " gifted you a 5-min Lucky Boost!",
				userId = player.UserId, -- the giver, so the toast can offer "Thank 💜"
			})
			msg = "🎁 Boost gifted to " .. target.DisplayName .. "!"
		else
			S.Buffs.GrantBoost(player, S.Config.Balance.BoostSeconds)
			if S.IsUserId(targetUserId) then
				S.Social.Tell(player, "info", (giftName[player] or "Your friend") .. " left before the gift landed — boost applied to you")
			end
			msg = "🎁 Boost applied to you — the whole server still gets +10% Luck!"
		end
		giftName[player] = nil
		local p = S.Data.Cache[player]
		if p then p.giftsGiven = (p.giftsGiven or 0) + 1 end -- cosmetic only: "Gifter" title at 3
		S.Buffs.AddServerGift(player.DisplayName) -- the ONE "gift" broadcast; its pushAll refreshes the title
		return msg
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
		return "💰 +" .. S.Config.Cur(amt) .. "!"
	elseif key == "StarterPack" then
		local p = S.Data.WaitFor(player, 5)
		if not p then return "Purchase pending…" end
		if p.starterPackBought then return "You already own the Starter Pack!" end
		p.starterPackBought = true
		local item = S.Config.ProductByKey(key)
		S.Econ.AwardRaw(player, (item and item.coins) or 0)
		if S.Data.SaveSoon then S.Data.SaveSoon(player) end
		S.Econ.Push(player) -- unlocks the Starter Sprite pet (derived from the flag)
		return "⭐ Starter Pack unlocked — Gems + exclusive Starter Sprite pet!"
	elseif string.sub(key, 1, 7) == "Unlock_" then
		-- Paid zone skip-unlock. The zone is still fully earnable via its gate; this
		-- just flips the per-player purchased flag Zones.IsUnlocked also honours.
		local item = S.Config.ProductByKey(key)
		local zoneKey = item and item.zone
		if not zoneKey then return nil end
		local p = S.Data.WaitFor(player, 5)
		if not p then return "Purchase pending…" end
		local zone = S.Config.Zones.Get(zoneKey)
		p.zonesPurchased = p.zonesPurchased or {}
		if p.zonesPurchased[zoneKey] then return "You already unlocked " .. (zone and zone.name or zoneKey) .. "!" end
		p.zonesPurchased[zoneKey] = true
		if S.Data.SaveSoon then S.Data.SaveSoon(player) end
		S.Econ.Push(player)
		S.Social.Broadcast("zone", {
			text = "🗺️ " .. player.DisplayName .. " unlocked " .. (zone and zone.name or zoneKey) .. "!",
			userId = player.UserId,
			colorRGB = (zone and zone.theme and zone.theme.accent) or { 150, 220, 255 }, -- Color3 -> {r,g,b} in Social
		})
		return "🗺️ " .. (zone and zone.name or zoneKey) .. " unlocked — warp in from the Nexus!"
	end
	return nil
end

function Monetize.Init(services)
	S = services

	-- S.Guard: Ready check, arg types (a GiftBoost target must be a well-formed user
	-- id or absent — NaN / 1.5 / 1e300 are "Bad request"), 0.5 s per-player gap, pcall.
	S.Guard(S.Remotes.Purchase, {
		gap = 0.5, args = { "string", "string", "userId?" },
		fn = function(player, kind, key, targetUserId)
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
				-- GiftBoost: validate + remember the chosen recipient NOW, because the
				-- ProcessReceipt callback only receives a receipt (no target argument).
				-- The recipient is always the player the buyer tapped — never a fallback.
				if key == "GiftBoost" then
					local tgt, tname = nil, nil
					if S.IsUserId(targetUserId) then
						local ok, found = pcall(Players.GetPlayerByUserId, Players, targetUserId)
						if ok and found and found ~= player then tgt, tname = targetUserId, found.DisplayName end
					end
					if not tgt then return { ok = false, err = "Pick a player to gift" } end
					giftTarget[player], giftName[player] = tgt, tname
				end
				if testMode(item) then
					local msg = Monetize.GrantProduct(player, key, giftTarget[player])
					giftTarget[player] = nil
					return { ok = true, test = true, msg = (msg or "Purchased!") .. " (Studio test)" }
				elseif item.id == 0 then
					return { ok = false, err = "Purchases aren't live yet — coming soon!" }
				else
					MarketplaceService:PromptProductPurchase(player, item.id)
					return { ok = true, prompted = true }
				end
			end
			return { ok = false, err = "Bad kind" }
		end,
	})

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
		-- Persist the receipt id BEFORE applying the grant. If the grant ran first
		-- and the save failed, we'd return NotProcessedYet, Roblox would re-deliver,
		-- and the grant would apply twice. With the receipt durably on disk first, a
		-- re-delivery hits the dedupe check above instead. Never-acknowledge-without-
		-- persist still holds: PurchaseGranted is only returned after a real save.
		table.insert(p.receipts, rid)
		if #p.receipts > 50 then table.remove(p.receipts, 1) end
		if not S.Data.SaveNow(player) then
			for i = #p.receipts, 1, -1 do
				if p.receipts[i] == rid then table.remove(p.receipts, i) break end
			end
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		Monetize.GrantProduct(player, key, giftTarget[player])
		giftTarget[player] = nil
		S.Data.SaveSoon(player) -- the grant's own effects ride the next save
		return Enum.ProductPurchaseDecision.PurchaseGranted
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
				-- Starter offer: once the player has cracked 5 geodes (onboarding step 2)
				-- or 120 s after join, whichever comes first — never over the first-crack
				-- moment. Polls every 5 s and stops if the offer is no longer open.
				local t0 = os.clock()
				while player.Parent == Players and Monetize.StarterOffered(player) do
					if (p.onboardStep or 0) >= 2 or os.clock() - t0 >= 120 then
						S.Remotes.StarterPopup:FireClient(player)
						break
					end
					task.wait(5)
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
		firstSession[player] = nil
		giftTarget[player] = nil
		giftName[player] = nil
	end)
end

return Monetize