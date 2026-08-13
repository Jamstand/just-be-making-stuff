-- NexusFX: the locked-zone teasing at the Warp Nexus. For each portal (tagged with
-- a ZoneKey attribute), builds a floating card showing the zone's exclusive pet,
-- its coin multiplier, and a LIVE progress bar toward its exact unlock condition.
-- Cards update per-player from the snapshot and flip to "UNLOCKED" once earned.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Zones = require(ReplicatedStorage:WaitForChild("Zones"))
local SG = require(ReplicatedStorage:WaitForChild("StyleGuide"))
local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local NexusFX = {}
local cards = {} -- [zoneKey] = refs
local upsell = nil -- the hub 2×/Lucky pass upsell refs
local lastSnap = nil -- cache so cards built after the first snapshot still populate

-- fire a purchase prompt (pass or product) without blocking the click handler
local function prompt(kind, key)
	local pf = Remotes:FindFirstChild("Purchase")
	if pf then task.spawn(function() pcall(function() pf:InvokeServer(kind, key) end) end) end
end

local function buildCard(pad, zone)
	local anchor = Instance.new("Part")
	anchor.Anchored = true; anchor.CanCollide = false; anchor.CanQuery = false
	anchor.Transparency = 1; anchor.Size = Vector3.new(1, 1, 1)
	anchor.CFrame = CFrame.new(pad.Position + Vector3.new(0, 13, 0))
	anchor.Parent = workspace.CurrentCamera -- local-only, survives respawn, no replication

	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromScale(13, 12)
	bb.MaxDistance = 170
	bb.LightInfluence = 0
	bb.Parent = anchor

	local card = SG.panel({ Size = UDim2.fromScale(1, 1) }, bb)
	SG.new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10),
		PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8) }, card)
	SG.new("UIListLayout", { Padding = UDim.new(0, 4), HorizontalAlignment = Enum.HorizontalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder }, card)

	SG.label({ Size = UDim2.new(1, 0, 0, 22), Text = zone.icon .. " " .. zone.name,
		TextColor3 = zone.theme.accent, Font = SG.Font.Display, LayoutOrder = 1 }, card)

	local pet = zone.exclusivePet
	SG.label({ Size = UDim2.new(1, 0, 0, 18),
		Text = (pet and (pet.emoji .. " " .. pet.name) or "") .. "   ×" .. zone.multiplier .. " Coins",
		TextColor3 = SG.Color.Gold, Font = SG.Font.Heading, LayoutOrder = 2 }, card)

	local barWrap = SG.new("Frame", { Size = UDim2.new(1, 0, 0, 20), BackgroundColor3 = SG.Color.Track,
		BorderSizePixel = 0, LayoutOrder = 3 }, card)
	SG.corner(barWrap, "sm")
	local fill = SG.new("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = zone.theme.accent,
		BorderSizePixel = 0 }, barWrap)
	SG.corner(fill, "sm")
	SG.gradient(fill, SG.lighten(zone.theme.accent, 0.2), zone.theme.accent, 0)
	local barLabel = SG.label({ Size = UDim2.fromScale(1, 1), Text = "", TextColor3 = SG.Color.Text,
		Font = SG.Font.Number, ZIndex = 2 }, barWrap)
	SG.new("UITextSizeConstraint", { MaxTextSize = 15 }, barLabel)

	local reqLabel = SG.label({ Size = UDim2.new(1, 0, 0, 14), Text = "", TextColor3 = SG.Color.TextDim,
		Font = SG.Font.Body, LayoutOrder = 4 }, card)

	-- zone-exclusive VIP pet line (owned state filled in Update)
	local vipLabel = SG.label({ Size = UDim2.new(1, 0, 0, 14), Text = "", TextColor3 = SG.Color.Gold,
		Font = SG.Font.Body, LayoutOrder = 5 }, card)

	-- paid skip-unlock button (shown only while locked & a price exists). The gate
	-- bar above still earns it free — this is the shortcut, never the only path.
	local buyBtn
	if zone.unlockPrice then
		buyBtn = SG.button("💎 Unlock now · " .. zone.unlockPrice .. " R$", "buy",
			{ Size = UDim2.new(1, -18, 0, 30), LayoutOrder = 6 }, card)
		buyBtn.Activated:Connect(function() prompt("product", "Unlock_" .. zone.key) end)
	end

	return { card = card, fill = fill, barLabel = barLabel, reqLabel = reqLabel, vipLabel = vipLabel, buyBtn = buyBtn }
end

-- the hub-wide pass upsell: advertises 2× Coins & Lucky right at the Nexus; each
-- button hides once that pass is owned, and the whole card hides when both are.
local function buildUpsell(centerPos)
	local anchor = Instance.new("Part")
	anchor.Anchored = true; anchor.CanCollide = false; anchor.CanQuery = false
	anchor.Transparency = 1; anchor.Size = Vector3.new(1, 1, 1)
	anchor.CFrame = CFrame.new(centerPos + Vector3.new(0, 24, 0))
	anchor.Parent = workspace.CurrentCamera

	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromScale(16, 6)
	bb.MaxDistance = 240
	bb.LightInfluence = 0
	bb.Parent = anchor

	local card = SG.panel({ Size = UDim2.fromScale(1, 1) }, bb)
	SG.new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10),
		PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8) }, card)
	SG.new("UIListLayout", { Padding = UDim.new(0, 6), HorizontalAlignment = Enum.HorizontalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder }, card)
	SG.label({ Size = UDim2.new(1, 0, 0, 22), Text = "⚡ Boost every zone", TextColor3 = SG.Color.Gold,
		Font = SG.Font.Display, LayoutOrder = 1 }, card)
	local row = SG.new("Frame", { Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1, LayoutOrder = 2 }, card)
	SG.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8),
		HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, row)
	local coinsBtn = SG.button("💰 2× Coins", "premium", { Size = UDim2.new(0, 150, 1, 0), LayoutOrder = 1 }, row)
	coinsBtn.Activated:Connect(function() prompt("pass", "DoubleGems") end)
	local luckBtn = SG.button("🍀 Lucky", "primary", { Size = UDim2.new(0, 150, 1, 0), LayoutOrder = 2 }, row)
	luckBtn.Activated:Connect(function() prompt("pass", "DoubleLuck") end)
	return { card = card, coinsBtn = coinsBtn, luckBtn = luckBtn }
end

function NexusFX._updateUpsell()
	if not (upsell and lastSnap) then return end
	local passes = lastSnap.passes or {}
	upsell.coinsBtn.Visible = not passes.DoubleGems
	upsell.luckBtn.Visible = not passes.DoubleLuck
	upsell.card.Visible = not (passes.DoubleGems and passes.DoubleLuck)
end

function NexusFX.Update(snap)
	if snap then lastSnap = snap end
	if not lastSnap then return end
	local stats = Zones.StatsFor(lastSnap)
	-- vip ownership lookup from the snapshot
	local vipOwned = {}
	local cp = lastSnap.collectPets
	if cp and cp.vip then
		for _, v in ipairs(cp.vip) do vipOwned[v.zone] = v end
	end
	for key, refs in pairs(cards) do
		local zone = Zones.Get(key)
		if zone then
			local unlocked = Zones.IsUnlocked(zone, stats)
			if unlocked then
				refs.fill.Size = UDim2.fromScale(1, 1)
				refs.barLabel.Text = "✓ UNLOCKED"
				refs.reqLabel.Text = "Step on the portal to warp in"
			else
				local prog = Zones.Progress(zone, stats)
				refs.fill.Size = UDim2.fromScale(prog.pct, 1)
				refs.barLabel.Text = prog.label
				refs.reqLabel.Text = "🔒 " .. prog.text
			end
			-- zone-exclusive VIP pet line
			local vp = zone.vipPet
			if vp then
				local owned = vipOwned[key] and vipOwned[key].owned
				refs.vipLabel.Text = owned and (vp.emoji .. " " .. vp.name .. " ✓ owned")
					or (vp.emoji .. " " .. vp.name .. " — VIP perk or rare drop")
			end
			-- the paid unlock button only makes sense while the zone is locked
			if refs.buyBtn then refs.buyBtn.Visible = not unlocked end
		end
	end
	NexusFX._updateUpsell()
end

function NexusFX.Init()
	task.spawn(function()
		local cg = workspace:WaitForChild("CrackAGeode", 20)
		local regions = cg and cg:WaitForChild("Regions", 20)
		local nexus = regions and regions:WaitForChild("WarpNexus", 20)
		if not nexus then return end
		local sum, count = Vector3.zero, 0
		for _, pad in ipairs(nexus:GetDescendants()) do
			if pad:IsA("BasePart") and pad:GetAttribute("ZoneKey") then
				local key = pad:GetAttribute("ZoneKey")
				local zone = Zones.Get(key)
				if zone and not cards[key] then
					cards[key] = buildCard(pad, zone)
				end
				sum += pad.Position; count += 1
			end
		end
		if count > 0 and not upsell then
			upsell = buildUpsell(sum / count)
		end
		NexusFX.Update() -- populate the just-built cards + upsell from the cached snapshot
	end)
end

return NexusFX
