-- Procedural HUD: gems count-up, buff chips, banners, meteor bar,
-- Upgrades / Shop / Collection Index panels, streak popup, toasts.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local SG = require(game:GetService("ReplicatedStorage"):WaitForChild("StyleGuide"))

local UI = {}
local Config, Remotes
local player = Players.LocalPlayer
local gui
local snap = nil
local displayGems = 0

local BG = SG.Color.Bg1
local BG2 = SG.Color.Bg2
local ACCENT = SG.Color.Violet
local GOOD = SG.Color.Green
local TEXT = SG.Color.Text
local MUTED = SG.Color.TextDim

local panels = {}
local refs = {}

local UserInputService = game:GetService("UserInputService")
local IS_TOUCH = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
UI.IsTouch = IS_TOUCH
local responsivePanels = {} -- { { panel, scale, w, h } }
local function viewport()
	local cam = workspace.CurrentCamera
	if cam and cam.ViewportSize.X > 1 then return cam.ViewportSize end
	if gui and gui.AbsoluteSize.X > 1 then return gui.AbsoluteSize end
	return Vector2.new(1280, 720)
end

local function mk(class, props, parent)
	local inst = Instance.new(class)
	for k, v in pairs(props) do inst[k] = v end
	inst.Parent = parent
	return inst
end
local function corner(el, px)
	mk("UICorner", { CornerRadius = UDim.new(0, px or 14) }, el)
end
local function stroke(el, color, thickness)
	mk("UIStroke", { Color = color or ACCENT, Thickness = thickness or 2, Transparency = 0.2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, el)
end
local function label(props, parent)
	props.BackgroundTransparency = props.BackgroundTransparency or 1
	props.TextColor3 = props.TextColor3 or TEXT
	props.Font = props.Font or Enum.Font.GothamBold
	props.TextScaled = (props.TextScaled ~= false)
	return mk("TextLabel", props, parent)
end

function UI.Toast(text, color)
	local t = label({
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 0.86, 0),
		Size = UDim2.fromOffset(420, 34),
		Text = text,
		TextColor3 = color or TEXT,
		TextStrokeTransparency = 0.3,
		Font = Enum.Font.GothamBlack,
		ZIndex = 30,
	}, gui)
	TweenService:Create(t, TweenInfo.new(2.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Position = t.Position - UDim2.fromOffset(0, 26),
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	}):Play()
	Debris:AddItem(t, 2.3)
end

-- ===== panel scaffolding =====
local function makePanel(name, title, height)
	-- Outer frame centres via plain anchor+Size (no UIScale) so it stays perfectly
	-- centred; the inner content (fixed design size) is shrunk to fit by a UIScale.
	local outer = mk("Frame", {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(470, height),
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 20,
	}, gui)
	local panel = mk("Frame", {
		Name = "Content",
		Size = UDim2.fromOffset(470, height),
		BackgroundColor3 = BG,
		BackgroundTransparency = 0.05,
		ZIndex = 20,
	}, outer)
	corner(panel, 14)
	stroke(panel)
	local uiscale = mk("UIScale", {}, panel)
	label({
		Position = UDim2.fromOffset(18, 10), Size = UDim2.new(1, -80, 0, 30),
		Text = title, TextXAlignment = Enum.TextXAlignment.Left,
		Font = Enum.Font.GothamBlack, ZIndex = 21,
	}, panel)
	local closeSz = IS_TOUCH and 40 or 30
	local close = mk("TextButton", {
		AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 10),
		Size = UDim2.fromOffset(closeSz, closeSz), BackgroundColor3 = BG2, Text = "✕",
		TextColor3 = MUTED, Font = Enum.Font.GothamBold, TextScaled = true, ZIndex = 21,
	}, panel)
	corner(close, 8)
	close.MouseButton1Click:Connect(function() UI.TogglePanel(nil) end)
	table.insert(responsivePanels, { outer = outer, scale = uiscale, w = 470, h = height, mode = "scale" })
	panels[name] = outer
	return panel
end

-- Scroll panel: content renders at FULL size and scrolls vertically when the
-- screen is too short. Keeps modal touch targets full-size on phones (unlike the
-- scaled panel, which shrinks buttons to fit). A static title strip floats over
-- the scrolling body, so builders keep their existing row offsets unchanged.
local function makeScrollPanel(name, title, contentHeight)
	local outer = mk("Frame", {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(470, contentHeight),
		BackgroundColor3 = BG,
		BackgroundTransparency = 0.05,
		Visible = false,
		ClipsDescendants = true,
		ZIndex = 20,
	}, gui)
	corner(outer, 14)
	stroke(outer)
	local body = mk("ScrollingFrame", {
		Name = "Content",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.fromOffset(0, contentHeight),
		ScrollBarThickness = IS_TOUCH and 8 or 6,
		ScrollBarImageColor3 = ACCENT,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ZIndex = 21,
	}, outer)
	local strip = mk("Frame", {
		Size = UDim2.new(1, 0, 0, 44), BackgroundColor3 = BG, BackgroundTransparency = 0.05, ZIndex = 25,
	}, outer)
	label({
		Position = UDim2.fromOffset(18, 8), Size = UDim2.new(1, -80, 0, 28),
		Text = title, TextXAlignment = Enum.TextXAlignment.Left, Font = Enum.Font.GothamBlack, ZIndex = 26,
	}, strip)
	local closeSz = IS_TOUCH and 40 or 30
	local close = mk("TextButton", {
		AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -8, 0, 5),
		Size = UDim2.fromOffset(closeSz, closeSz), BackgroundColor3 = BG2, Text = "✕",
		TextColor3 = MUTED, Font = Enum.Font.GothamBold, TextScaled = true, ZIndex = 26,
	}, strip)
	corner(close, 8)
	close.MouseButton1Click:Connect(function() UI.TogglePanel(nil) end)
	table.insert(responsivePanels, { outer = outer, mode = "cap", w = 470, h = contentHeight, body = body })
	panels[name] = outer
	return body
end

function UI.TogglePanel(name)
	for n, panel in pairs(panels) do
		if n == name then
			if panel.Visible then SG.close(panel) else SG.open(panel) end
		elseif panel.Visible then
			SG.close(panel)
		end
	end
end

function UI.ShowPanel(name)
	for n, panel in pairs(panels) do
		if n == name then
			if not panel.Visible then SG.open(panel) end
		elseif panel.Visible then
			SG.close(panel)
		end
	end
end

-- Scale every centered panel to fit the current viewport (shrinks on small
-- screens, grows a little on big ones). Contents scale with the frame so touch
-- targets stay proportional and nothing overflows a phone screen.
function UI._RefreshPanels()
	local vp = viewport()
	local inset = game:GetService("GuiService"):GetGuiInset()
	local availW = vp.X
	local availH = math.max(160, vp.Y - inset.Y) -- usable height below the top bar
	for _, p in ipairs(responsivePanels) do
		if p.mode == "cap" then
			-- scroll panel: cap the frame to the viewport; content scrolls, buttons stay full-size
			p.outer.Size = UDim2.fromOffset(math.min(p.w, availW * 0.94), math.min(p.h, availH * 0.96))
		else
			-- scaled panel: shrink the fixed-size content to fit
			local s = math.clamp(math.min(availW * 0.92 / p.w, availH * 0.92 / p.h), 0.45, 1.1)
			p.scale.Scale = s
			p.outer.Size = UDim2.fromOffset(p.w * s, p.h * s)
		end
	end
end

-- ===== upgrades panel =====
local function buildUpgrades()
	local panel = makeScrollPanel("Upgrades", "⛏️ UPGRADES", 460)
	local y = 48
	local function row(h)
		local r = mk("Frame", {
			Position = UDim2.fromOffset(14, y), Size = UDim2.new(1, -28, 0, h),
			BackgroundColor3 = BG2, BackgroundTransparency = 0.1, ZIndex = 21,
		}, panel)
		corner(r, 10)
		y += h + 8
		return r
	end
	local function statRow(icon, key)
		local r = row(52)
		refs[key .. "Label"] = label({
			Position = UDim2.fromOffset(12, 4), Size = UDim2.new(0.62, 0, 0, 24),
			Text = icon .. " ...", TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 22,
		}, r)
		refs[key .. "Sub"] = label({
			Position = UDim2.fromOffset(12, 28), Size = UDim2.new(0.62, 0, 0, 18),
			Text = "", TextColor3 = MUTED, Font = Enum.Font.Gotham, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 22,
		}, r)
		local btn = mk("TextButton", {
			AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0),
			Size = UDim2.fromOffset(140, 46), BackgroundColor3 = BG, Text = "...",
			TextColor3 = TEXT, Font = Enum.Font.GothamBlack, TextScaled = true, ZIndex = 22,
		}, r)
		corner(btn, 9)
		refs[key .. "Btn"] = btn
		return r
	end

	statRow("⛏️", "power")
	statRow("🍀", "luck")

	-- rebirth row with progress bar
	local rb = row(66)
	refs.rebirthLabel = label({
		Position = UDim2.fromOffset(12, 4), Size = UDim2.new(0.6, 0, 0, 24),
		Text = "🔄 Recrystallize", TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 22,
	}, rb)
	refs.rebirthSub = label({
		Position = UDim2.fromOffset(12, 27), Size = UDim2.new(0.6, 0, 0, 16),
		Text = "×1.5 income, compounding! • resets upgrades", TextColor3 = MUTED, Font = Enum.Font.Gotham,
		TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 22,
	}, rb)
	local barBG = mk("Frame", {
		Position = UDim2.fromOffset(12, 48), Size = UDim2.new(0.6, 0, 0, 10),
		BackgroundColor3 = BG, ZIndex = 22,
	}, rb)
	corner(barBG, 5)
	refs.rebirthFill = mk("Frame", {
		Size = UDim2.fromScale(0, 1), BackgroundColor3 = ACCENT, ZIndex = 23,
	}, barBG)
	corner(refs.rebirthFill, 5)
	local rbBtn = mk("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.fromOffset(140, 46), BackgroundColor3 = BG, Text = "...",
		TextColor3 = TEXT, Font = Enum.Font.GothamBlack, TextScaled = true, ZIndex = 22,
	}, rb)
	corner(rbBtn, 9)
	refs.rebirthBtn = rbBtn

	-- ascension row
	local asc = row(52)
	refs.ascLabel = label({
		Position = UDim2.fromOffset(12, 4), Size = UDim2.new(0.6, 0, 0, 24),
		Text = "🌌 Ascend", TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 22,
	}, asc)
	refs.ascSub = label({
		Position = UDim2.fromOffset(12, 28), Size = UDim2.new(0.6, 0, 0, 18),
		Text = "At Rebirth 15: x2 base forever, +1 Shard", TextColor3 = MUTED, Font = Enum.Font.Gotham,
		TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 22,
	}, asc)
	local ascBtn = mk("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.fromOffset(140, 46), BackgroundColor3 = BG, Text = "🌌 Ascend",
		TextColor3 = TEXT, Font = Enum.Font.GothamBlack, TextScaled = true, ZIndex = 22,
	}, asc)
	corner(ascBtn, 9)
	refs.ascBtn = ascBtn

	-- perks
	refs.perkHeader = label({
		Position = UDim2.fromOffset(16, y), Size = UDim2.new(1, -32, 0, 22),
		Text = "✨ Perks", TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 21,
	}, panel)
	y += 26
	local grid = mk("Frame", {
		Position = UDim2.fromOffset(14, y), Size = UDim2.new(1, -28, 0, 96),
		BackgroundTransparency = 1, ZIndex = 21,
	}, panel)
	mk("UIGridLayout", {
		CellSize = UDim2.fromOffset(86, 44), CellPadding = UDim2.fromOffset(4, 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, grid)
	refs.perkBtns = {}
	for idx, perk in ipairs(Config.Perks) do
		local b = mk("TextButton", {
			BackgroundColor3 = BG2, Text = perk.icon .. " " .. perk.name,
			TextColor3 = TEXT, Font = Enum.Font.GothamBold, TextScaled = true,
			LayoutOrder = idx, ZIndex = 22,
		}, grid)
		corner(b, 8)
		refs.perkBtns[perk.key] = b
		b.MouseButton1Click:Connect(function()
			local res = Remotes.Buy:InvokeServer("Perk:" .. perk.key)
			UI.Toast(res.ok and (perk.icon .. " " .. perk.name .. " unlocked!") or res.err, res.ok and GOOD or Color3.fromRGB(255, 120, 120))
		end)
	end

	local function buyAction(action)
		return function()
			local res = Remotes.Buy:InvokeServer(action)
			if res.ok then
				UI.Toast("✅ " .. action .. "!", GOOD)
			else
				UI.Toast(res.err or "Failed", Color3.fromRGB(255, 120, 120))
			end
		end
	end
	refs.powerBtn.MouseButton1Click:Connect(buyAction("Power"))
	refs.luckBtn.MouseButton1Click:Connect(buyAction("Luck"))
	refs.rebirthBtn.MouseButton1Click:Connect(buyAction("Rebirth"))
	refs.ascBtn.MouseButton1Click:Connect(buyAction("Ascend"))
end

local function refreshUpgrades()
	if not snap then return end
	local affordable = GOOD
	refs.powerLabel.Text = "⛏️ Power Lv " .. snap.power
	refs.powerSub.Text = string.format("Crack speed: %.2fs", snap.cooldown)
	refs.powerBtn.Text = Config.Fmt(snap.powerCost) .. " 💎"
	refs.powerBtn.BackgroundColor3 = snap.gems >= snap.powerCost and affordable or BG
	refs.luckLabel.Text = "🍀 Luck Lv " .. snap.luck
	refs.luckSub.Text = string.format("Luck factor: x%.2f", snap.luckFactor)
	refs.luckBtn.Text = Config.Fmt(snap.luckCost) .. " 💎"
	refs.luckBtn.BackgroundColor3 = snap.gems >= snap.luckCost and affordable or BG
	refs.rebirthLabel.Text = "🔄 Recrystallize (Rebirth " .. snap.rebirths .. ")"
	refs.rebirthFill.Size = UDim2.fromScale(math.clamp(snap.gems / snap.rebirthCost, 0, 1), 1)
	refs.rebirthBtn.Text = Config.Fmt(snap.rebirthCost) .. " 💎"
	refs.rebirthBtn.BackgroundColor3 = snap.gems >= snap.rebirthCost and affordable or BG
	local canAsc = snap.rebirths >= Config.Balance.AscensionAtRebirth
	refs.ascLabel.Text = "🌌 Ascend (x" .. Config.Fmt((Config.Balance.AscendMult or 2.5) ^ snap.ascensions) .. " base)"
	refs.ascBtn.BackgroundColor3 = canAsc and affordable or BG
	refs.perkHeader.Text = "✨ Perks — Shards: " .. snap.shards
	for key, btn in pairs(refs.perkBtns) do
		local owned = snap.perks[key]
		btn.BackgroundColor3 = owned and Color3.fromRGB(60, 90, 70) or (snap.shards > 0 and BG2 or BG)
		btn.TextColor3 = owned and GOOD or TEXT
	end
end

-- ===== shop panel =====
local function buildShop()
	local panel = makeScrollPanel("Shop", "🛒 SHOP", 740)
	-- flow layout so the conditional Starter card collapses cleanly when hidden
	panel.AutomaticCanvasSize = Enum.AutomaticSize.Y
	panel.CanvasSize = UDim2.new()
	mk("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = Enum.HorizontalAlignment.Center }, panel)
	mk("UIPadding", { PaddingTop = UDim.new(0, 48), PaddingLeft = UDim.new(0, 6),
		PaddingRight = UDim.new(0, 6), PaddingBottom = UDim.new(0, 12) }, panel)
	local order = 0
	local function nextOrder() order += 1; return order end

	-- special Starter Pack offer card (first-session only; toggled in refreshShop)
	local sp = Config.ProductByKey("StarterPack")
	if sp then
		local card = mk("Frame", { Size = UDim2.new(1, -6, 0, 92), BackgroundColor3 = Color3.fromRGB(58, 44, 20),
			BackgroundTransparency = 0.03, LayoutOrder = nextOrder(), Visible = false, ZIndex = 22 }, panel)
		corner(card, 12)
		stroke(card, Color3.fromRGB(255, 210, 90), 2.4)
		label({ Position = UDim2.fromOffset(10, 6), Size = UDim2.new(1, -20, 0, 16),
			Text = "⭐ STARTER PACK — FIRST-SESSION OFFER", TextColor3 = Color3.fromRGB(255, 222, 130),
			Font = Enum.Font.GothamBlack, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 23 }, card)
		label({ Position = UDim2.fromOffset(10, 26), Size = UDim2.new(1, -20, 0, 34), Text = sp.desc,
			Font = Enum.Font.Gotham, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top, ZIndex = 23 }, card)
		local btn = mk("TextButton", { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -8, 1, -8),
			Size = UDim2.fromOffset(170, 40), BackgroundColor3 = Color3.fromRGB(70, 175, 95),
			Text = "GET IT — R$ " .. sp.price, TextColor3 = TEXT, Font = Enum.Font.GothamBlack, TextScaled = true, ZIndex = 23 }, card)
		corner(btn, 10)
		mk("UITextSizeConstraint", { MaxTextSize = 18 }, btn)
		btn.MouseButton1Click:Connect(function()
			local res = Remotes.Purchase:InvokeServer("product", "StarterPack")
			if res.ok and res.msg then UI.Toast(res.msg, GOOD)
			elseif not res.ok then UI.Toast(res.err or "Failed", Color3.fromRGB(255, 120, 120)) end
		end)
		refs.starterCard = card
	end

	local function section(text)
		label({ Size = UDim2.new(1, -12, 0, 24), Text = text, TextColor3 = MUTED,
			TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = nextOrder(), ZIndex = 22 }, panel)
	end
	local function item(entry, kind)
		local card = mk("Frame", { Size = UDim2.new(1, -6, 0, 68), BackgroundColor3 = BG2,
			BackgroundTransparency = 0.08, LayoutOrder = nextOrder(), ZIndex = 22 }, panel)
		corner(card, 10)
		label({ Position = UDim2.fromOffset(10, 5), Size = UDim2.new(1, -140, 0, 24),
			Text = entry.icon .. " " .. entry.name, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 23 }, card)
		label({ Position = UDim2.fromOffset(10, 31), Size = UDim2.new(1, -140, 0, 32), Text = entry.desc,
			TextColor3 = MUTED, Font = Enum.Font.Gotham, TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, ZIndex = 23 }, card)
		local btn = mk("TextButton", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0),
			Size = UDim2.fromOffset(110, 46), BackgroundColor3 = Color3.fromRGB(60, 160, 90),
			Text = "R$ " .. entry.price, TextColor3 = TEXT, Font = Enum.Font.GothamBlack, TextScaled = true, ZIndex = 23 }, card)
		corner(btn, 10)
		if kind == "pass" then
			refs.passBtns = refs.passBtns or {}
			refs.passBtns[entry.key] = btn
		end
		btn.MouseButton1Click:Connect(function()
			local targetUserId = nil
			if entry.key == "GiftBoost" then
				for _, other in ipairs(Players:GetPlayers()) do
					if other ~= player then targetUserId = other.UserId break end
				end
			end
			local res = Remotes.Purchase:InvokeServer(kind, entry.key, targetUserId)
			if res.ok and res.msg then UI.Toast(res.msg, GOOD)
			elseif not res.ok then UI.Toast(res.err or "Failed", Color3.fromRGB(255, 120, 120)) end
		end)
	end
	section("GAME PASSES — permanent")
	for _, pass in ipairs(Config.GamePasses) do item(pass, "pass") end
	section("COINS & POWER-UPS")
	for _, prod in ipairs(Config.DevProducts) do
		if not prod.starter then item(prod, "product") end
	end
	refs.shopNote = label({ Size = UDim2.new(1, -12, 0, 30),
		Text = "🧪 Studio test mode — publish & set IDs in Config for real Robux",
		TextColor3 = MUTED, Font = Enum.Font.Gotham, TextWrapped = true, LayoutOrder = nextOrder(), ZIndex = 22 }, panel)
end

local function refreshShop()
	if not snap then return end
	if refs.passBtns then
		for key, btn in pairs(refs.passBtns) do
			if snap.passes[key] then
				btn.Text = "✅ OWNED"
				btn.BackgroundColor3 = BG
			end
		end
	end
	if refs.starterCard then refs.starterCard.Visible = (snap.starterOffered == true) end
	if refs.shopBtn then
		refs.shopBtn.BackgroundColor3 = (snap.starterOffered == true) and Color3.fromRGB(72, 56, 22) or BG
	end
end

-- ===== collection index panel =====
local MUT_TAGS = { "⬜", "✨", "💟", "🌟" }
local function buildIndex()
	local panel = makeScrollPanel("Index", "📖 COLLECTION INDEX", 522)
	refs.indexHeader = label({
		Position = UDim2.fromOffset(18, 40), Size = UDim2.new(1, -36, 0, 20),
		Text = "0/28 collected • each full row = +10% Luck", TextColor3 = MUTED,
		Font = Enum.Font.Gotham, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 21,
	}, panel)
	refs.cells = {}
	for r = 1, 7 do
		local rar = Config.Rarities[r]
		label({
			Position = UDim2.fromOffset(18, 64 + (r - 1) * 55), Size = UDim2.fromOffset(120, 45),
			Text = rar.name, TextColor3 = rar.color, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 21,
		}, panel)
		for m = 1, 4 do
			local cell = mk("Frame", {
				Position = UDim2.fromOffset(150 + (m - 1) * 76, 64 + (r - 1) * 55),
				Size = UDim2.fromOffset(68, 45), BackgroundColor3 = BG2, ZIndex = 21,
			}, panel)
			corner(cell, 8)
			local cl = label({
				Size = UDim2.fromScale(1, 1), Text = "?", TextColor3 = MUTED, ZIndex = 22,
			}, cell)
			refs.cells[(r - 1) * 4 + m] = { frame = cell, label = cl, rarity = r, mutation = m }
		end
	end
	refs.zonePctLabel = label({ Position = UDim2.fromOffset(18, 450), Size = UDim2.new(1, -36, 0, 56),
		Text = "", TextColor3 = MUTED, Font = Enum.Font.Gotham, TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = true, ZIndex = 21 }, panel)
end

local function refreshIndex()
	if not (snap and refs.cells) then return end
	local count = 0
	for _, cell in pairs(refs.cells) do
		local bitIndex = (cell.rarity - 1) * 4 + (cell.mutation - 1)
		local found = bit32.band(snap.indexMask, bit32.lshift(1, bitIndex)) ~= 0
		if found then
			count += 1
			cell.frame.BackgroundColor3 = Config.Rarities[cell.rarity].color
			cell.label.Text = MUT_TAGS[cell.mutation]
			cell.label.TextColor3 = Color3.fromRGB(20, 16, 30)
		else
			cell.frame.BackgroundColor3 = BG2
			cell.label.Text = "?"
			cell.label.TextColor3 = MUTED
		end
	end
	refs.indexHeader.Text = count .. "/28 collected • each full row = +10% Luck • ⬜ normal ✨ Glowing 💟 Giant 🌟 Celestial"
	if refs.zonePctLabel and snap.zoneIndexPct and Config.Zones then
		local parts = {}
		for _, zone in ipairs(Config.Zones.list) do
			parts[#parts + 1] = zone.icon .. " " .. math.floor((snap.zoneIndexPct[zone.key] or 0) * 100) .. "%"
		end
		refs.zonePctLabel.Text = "PER-ZONE COMPLETION:  " .. table.concat(parts, "   ")
	end
end

-- ===== daily panel (login rewards + quests) =====
local GOLD = Color3.fromRGB(255, 210, 90)
local QBLUE = Color3.fromRGB(150, 205, 255)
local function buildDaily()
	local panel = makeScrollPanel("Daily", "📅 DAILY", 440)
	local y = 52

	-- login reward ladder
	label({ Position = UDim2.fromOffset(14, y), Size = UDim2.new(1, -28, 0, 18),
		Text = "🎁 LOGIN REWARD", TextColor3 = GOLD, Font = Enum.Font.GothamBlack,
		TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 23 }, panel)
	y += 24
	local cellRow = mk("Frame", { Position = UDim2.fromOffset(12, y), Size = UDim2.new(1, -24, 0, 50),
		BackgroundTransparency = 1, ZIndex = 23 }, panel)
	mk("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4),
		HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, cellRow)
	refs.dailyCells = {}
	for d = 1, 7 do
		local cell = mk("Frame", { Size = UDim2.new(1 / 7, -4, 1, 0), BackgroundColor3 = BG2, ZIndex = 23 }, cellRow)
		corner(cell, 8)
		label({ Position = UDim2.fromOffset(0, 3), Size = UDim2.new(1, 0, 0, 11), Text = "Day " .. d,
			TextColor3 = MUTED, Font = Enum.Font.Gotham, ZIndex = 24 }, cell)
		local amt = label({ Position = UDim2.fromOffset(0, 15), Size = UDim2.new(1, -2, 0, 18), Text = "",
			Font = Enum.Font.GothamBold, ZIndex = 24 }, cell)
		local star = label({ Position = UDim2.fromOffset(0, 33), Size = UDim2.new(1, 0, 0, 14), Text = "", ZIndex = 24 }, cell)
		refs.dailyCells[d] = { frame = cell, amt = amt, star = star }
	end
	y += 58
	refs.dailyClaim = mk("TextButton", { Position = UDim2.fromOffset(12, y), Size = UDim2.new(1, -24, 0, 44),
		BackgroundColor3 = GOOD, Text = "CLAIM", TextColor3 = Color3.fromRGB(12, 30, 20),
		Font = Enum.Font.GothamBlack, TextScaled = true, AutoButtonColor = true, ZIndex = 23 }, panel)
	corner(refs.dailyClaim, 10)
	mk("UITextSizeConstraint", { MaxTextSize = 20 }, refs.dailyClaim)
	refs.dailyClaim.MouseButton1Click:Connect(function()
		local res = Remotes.ClaimDaily:InvokeServer()
		UI.Toast(res.ok and ("🎁 Claimed!  +" .. Config.Fmt(res.gems) .. " 💎") or (res.err or "Failed"),
			res.ok and GOOD or MUTED)
	end)
	y += 54

	-- daily quests
	label({ Position = UDim2.fromOffset(14, y), Size = UDim2.new(1, -28, 0, 18),
		Text = "📋 DAILY QUESTS", TextColor3 = QBLUE, Font = Enum.Font.GothamBlack,
		TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 23 }, panel)
	y += 22
	refs.dailyNote = label({ Position = UDim2.fromOffset(14, y), Size = UDim2.new(1, -28, 0, 15),
		Text = "Complete all 3 → 🌟 Rare Geode!", TextColor3 = GOLD, Font = Enum.Font.Gotham,
		TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 23 }, panel)
	y += 22
	refs.dailyQuests = {}
	for i = 1, 3 do
		local row = mk("Frame", { Position = UDim2.fromOffset(12, y), Size = UDim2.new(1, -24, 0, 54),
			BackgroundColor3 = BG2, BackgroundTransparency = 0.1, ZIndex = 23 }, panel)
		corner(row, 10)
		local desc = label({ Position = UDim2.fromOffset(10, 5), Size = UDim2.new(1, -130, 0, 18), Text = "",
			TextXAlignment = Enum.TextXAlignment.Left, Font = Enum.Font.GothamBold, ZIndex = 24 }, row)
		local reward = label({ AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 5), Size = UDim2.fromOffset(114, 18),
			Text = "", TextColor3 = GOLD, TextXAlignment = Enum.TextXAlignment.Right, Font = Enum.Font.GothamBold, ZIndex = 24 }, row)
		local barBG = mk("Frame", { Position = UDim2.fromOffset(10, 30), Size = UDim2.new(1, -20, 0, 10), BackgroundColor3 = BG, ZIndex = 24 }, row)
		corner(barBG, 5)
		local fill = mk("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = QBLUE, ZIndex = 25 }, barBG)
		corner(fill, 5)
		local prog = label({ Position = UDim2.fromOffset(10, 40), Size = UDim2.new(1, -20, 0, 12), Text = "",
			TextColor3 = MUTED, Font = Enum.Font.Gotham, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 24 }, row)
		y += 60
		refs.dailyQuests[i] = { row = row, desc = desc, reward = reward, fill = fill, prog = prog }
	end

	panel.CanvasSize = UDim2.fromOffset(0, y + 12)
end

local function refreshDaily()
	local d = snap and snap.daily
	if not (d and refs.dailyCells) then return end
	for i = 1, 7 do
		local cell = refs.dailyCells[i]
		local r = d.ladder[i]
		if cell and r then
			cell.amt.Text = Config.Fmt(r.gems)
			cell.star.Text = r.golden and "🌟" or (r.luck and "🍀" or "")
			local isToday = (i == d.streakDay)
			cell.frame.BackgroundColor3 = isToday and Color3.fromRGB(58, 108, 78) or BG2
			cell.amt.TextColor3 = isToday and GOOD or TEXT
		end
	end
	if d.claimable then
		refs.dailyClaim.Text = "CLAIM DAY " .. d.streakDay
		refs.dailyClaim.BackgroundColor3 = GOOD
		refs.dailyClaim.AutoButtonColor = true
	else
		refs.dailyClaim.Text = "✅ Claimed — back tomorrow!"
		refs.dailyClaim.BackgroundColor3 = BG2
		refs.dailyClaim.AutoButtonColor = false
	end
	for i = 1, 3 do
		local q = d.quests[i]
		local row = refs.dailyQuests[i]
		if q and row then
			row.desc.Text = (q.done and "✅ " or "") .. q.desc
			row.reward.Text = "+" .. Config.Fmt(q.gems) .. " 💎"
			row.fill.Size = UDim2.fromScale(math.clamp(q.progress / math.max(1, q.goal), 0, 1), 1)
			row.fill.BackgroundColor3 = q.done and GOOD or QBLUE
			row.prog.Text = Config.Fmt(q.progress) .. " / " .. Config.Fmt(q.goal)
		end
	end
	refs.dailyNote.Text = d.setDone and "🌟 All quests done — Rare Geode earned!" or "Complete all 3 → 🌟 Rare Geode!"
	if refs.dailyBtn then
		local attention = d.claimable
		refs.dailyBtn.BackgroundColor3 = attention and Color3.fromRGB(46, 92, 62) or BG
	end
end

-- ===== rebirth pets panel =====
local function buildPets()
	local panel = makeScrollPanel("Pets", "🐾 REBIRTH PETS", 470)
	local y = 50
	refs.petsHeader = label({ Position = UDim2.fromOffset(14, y), Size = UDim2.new(1, -28, 0, 30),
		Text = "", TextColor3 = GOLD, Font = Enum.Font.GothamBold, TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true, ZIndex = 23 }, panel)
	y += 36
	refs.petRows = {}
	for i = 1, 12 do -- 10 rebirth pets + VIP + Starter Pack pets
		local row = mk("Frame", { Position = UDim2.fromOffset(12, y), Size = UDim2.new(1, -24, 0, 50),
			BackgroundColor3 = BG2, BackgroundTransparency = 0.1, ZIndex = 23 }, panel)
		corner(row, 10)
		local icon = label({ Position = UDim2.fromOffset(8, 0), Size = UDim2.fromOffset(40, 50), Text = "", ZIndex = 24 }, row)
		local name = label({ Position = UDim2.fromOffset(52, 6), Size = UDim2.new(1, -178, 0, 20), Text = "",
			TextXAlignment = Enum.TextXAlignment.Left, Font = Enum.Font.GothamBold, ZIndex = 24 }, row)
		local sub = label({ Position = UDim2.fromOffset(52, 28), Size = UDim2.new(1, -178, 0, 16), Text = "",
			TextColor3 = MUTED, Font = Enum.Font.Gotham, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 24 }, row)
		local btn = mk("TextButton", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0),
			Size = UDim2.fromOffset(112, 40), BackgroundColor3 = BG, Text = "", TextColor3 = TEXT,
			Font = Enum.Font.GothamBold, TextScaled = true, ZIndex = 24 }, row)
		corner(btn, 8)
		mk("UITextSizeConstraint", { MaxTextSize = 15 }, btn)
		local tierIdx = i
		btn.MouseButton1Click:Connect(function()
			local res = Remotes.EquipPet:InvokeServer(tierIdx)
			if not res.ok then UI.Toast(res.err or "Locked", MUTED) end
		end)
		y += 56
		refs.petRows[i] = { row = row, icon = icon, name = name, sub = sub, btn = btn }
	end

	-- COLLECTIBLE PETS (drops + fusion, Phase 3)
	y += 8
	label({ Position = UDim2.fromOffset(14, y), Size = UDim2.new(1, -28, 0, 20),
		Text = "✨ COLLECTIBLES — fuse 3 → next tier", TextColor3 = GOLD, Font = Enum.Font.GothamBlack,
		TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 23 }, panel)
	y += 24
	refs.collectHeader = label({ Position = UDim2.fromOffset(14, y), Size = UDim2.new(1, -28, 0, 16),
		Text = "Crack geodes to find zone pets!", TextColor3 = MUTED, Font = Enum.Font.Gotham, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 23 }, panel)
	y += 22
	refs.collectRows = {}
	for i = 1, 5 do
		local row = mk("Frame", { Position = UDim2.fromOffset(12, y), Size = UDim2.new(1, -24, 0, 50),
			BackgroundColor3 = BG2, BackgroundTransparency = 0.1, Visible = false, ZIndex = 23 }, panel)
		corner(row, 10)
		local icon = label({ Position = UDim2.fromOffset(8, 0), Size = UDim2.fromOffset(40, 50), Text = "", ZIndex = 24 }, row)
		local nm = label({ Position = UDim2.fromOffset(52, 6), Size = UDim2.new(1, -170, 0, 20), Text = "",
			TextXAlignment = Enum.TextXAlignment.Left, Font = Enum.Font.GothamBold, ZIndex = 24 }, row)
		local counts = label({ Position = UDim2.fromOffset(52, 28), Size = UDim2.new(1, -170, 0, 16), Text = "",
			TextColor3 = MUTED, Font = Enum.Font.Gotham, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 24 }, row)
		local btn = mk("TextButton", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0),
			Size = UDim2.fromOffset(104, 40), BackgroundColor3 = BG, Text = "", TextColor3 = TEXT,
			Font = Enum.Font.GothamBold, TextScaled = true, ZIndex = 24 }, row)
		corner(btn, 8)
		mk("UITextSizeConstraint", { MaxTextSize = 14 }, btn)
		refs.collectRows[i] = { row = row, icon = icon, name = nm, counts = counts, btn = btn, zone = nil, fuseVariant = nil }
		btn.MouseButton1Click:Connect(function()
			local rr = refs.collectRows[i]
			if not (rr.zone and rr.fuseVariant) then return end
			local res = Remotes.FusePet:InvokeServer(rr.zone, rr.fuseVariant)
			UI.Toast(res.ok and "✨ Fused!" or (res.err or "Can't fuse"), res.ok and GOLD or MUTED)
		end)
		y += 56
	end

	panel.CanvasSize = UDim2.fromOffset(0, y + 12)
end

local function refreshPets()
	local pt = snap and snap.pets
	if not (pt and refs.petRows) then return end
	for i, rowRef in ipairs(refs.petRows) do
		local t = pt.tiers[i]
		if t then
			rowRef.icon.Text = t.unlocked and t.emoji or "🔒"
			rowRef.name.Text = t.name
			rowRef.name.TextColor3 = t.unlocked and Color3.fromRGB(t.color[1], t.color[2], t.color[3]) or MUTED
			local reqText = t.starter and "⭐ Starter Exclusive" or (t.vip and "👑 VIP Exclusive" or ("Rebirth " .. tostring(t.req)))
			rowRef.sub.Text = reqText .. "  •  +" .. t.bonusPct .. "% Coins"
			if t.equipped then
				rowRef.btn.Text = "✅ EQUIPPED"; rowRef.btn.BackgroundColor3 = Color3.fromRGB(60, 90, 70); rowRef.btn.AutoButtonColor = false
			elseif t.unlocked then
				rowRef.btn.Text = "EQUIP"; rowRef.btn.BackgroundColor3 = ACCENT; rowRef.btn.AutoButtonColor = true
			else
				rowRef.btn.Text = t.starter and "🔒 Pack" or (t.vip and "🔒 VIP" or ("🔒 R" .. tostring(t.req))); rowRef.btn.BackgroundColor3 = BG; rowRef.btn.AutoButtonColor = false
			end
		end
	end
	refs.petsHeader.Text = pt.nextName
		and ("🎯 Next: " .. pt.nextName .. " at Rebirth " .. pt.nextReq .. "   (you're at Rebirth " .. pt.rebirths .. ")")
		or "🏆 All pets unlocked — you're a legend!"

	local cp = snap.collectPets
	if cp and refs.collectRows then
		refs.collectHeader.Text = (#cp.pets > 0) and ("Active bonus: +" .. math.floor(cp.bonus * 100) .. "% Coins  (best owned pet)") or "Crack geodes to find zone pets!"
		for i, rr in ipairs(refs.collectRows) do
			local cpp = cp.pets[i]
			if cpp then
				rr.row.Visible = true
				rr.zone = cpp.zone
				rr.icon.Text = cpp.emoji
				rr.name.Text = cpp.name
				rr.name.TextColor3 = Color3.fromRGB(cpp.color[1], cpp.color[2], cpp.color[3])
				rr.counts.Text = "N×" .. cpp.counts[1] .. "  ✨G×" .. cpp.counts[2] .. "  🌈R×" .. cpp.counts[3]
				local fv = nil
				if cpp.counts[1] >= 3 then fv = 1 elseif cpp.counts[2] >= 3 then fv = 2 end
				rr.fuseVariant = fv
				if fv then
					rr.btn.Text = fv == 1 and "FUSE→G" or "FUSE→R"; rr.btn.BackgroundColor3 = GOOD; rr.btn.AutoButtonColor = true
				else
					rr.btn.Text = "Need 3"; rr.btn.BackgroundColor3 = BG; rr.btn.AutoButtonColor = false
				end
			else
				rr.row.Visible = false
				rr.zone = nil
			end
		end
	end
end

-- ===== achievements panel =====
local function buildAchievements()
	local panel = makeScrollPanel("Achievements", "🏅 ACHIEVEMENTS", 520)
	panel.AutomaticCanvasSize = Enum.AutomaticSize.Y
	panel.CanvasSize = UDim2.new()
	mk("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Center }, panel)
	mk("UIPadding", { PaddingTop = UDim.new(0, 48), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), PaddingBottom = UDim.new(0, 12) }, panel)
	refs.achRows = {}
	for i = 1, 8 do
		local card = mk("Frame", { Size = UDim2.new(1, -6, 0, 72), BackgroundColor3 = BG2, BackgroundTransparency = 0.1, LayoutOrder = i, Visible = false, ZIndex = 22 }, panel)
		corner(card, 12)
		local icon = label({ Position = UDim2.fromOffset(8, 6), Size = UDim2.fromOffset(44, 44), Text = "", ZIndex = 23 }, card)
		local name = label({ Position = UDim2.fromOffset(58, 6), Size = UDim2.new(1, -186, 0, 20), Text = "", TextXAlignment = Enum.TextXAlignment.Left, Font = Enum.Font.GothamBold, ZIndex = 23 }, card)
		local prog = label({ Position = UDim2.fromOffset(58, 28), Size = UDim2.new(1, -186, 0, 14), Text = "", TextColor3 = MUTED, Font = Enum.Font.Gotham, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 23 }, card)
		local barBG = mk("Frame", { Position = UDim2.fromOffset(58, 48), Size = UDim2.new(1, -196, 0, 8), BackgroundColor3 = BG, ZIndex = 23 }, card)
		corner(barBG, 4)
		local fill = mk("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = GOLD, ZIndex = 24 }, barBG)
		corner(fill, 4)
		local btn = mk("TextButton", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0), Size = UDim2.fromOffset(120, 46), BackgroundColor3 = BG, Text = "", TextColor3 = TEXT, Font = Enum.Font.GothamBlack, TextScaled = true, ZIndex = 23 }, card)
		corner(btn, 9)
		mk("UITextSizeConstraint", { MaxTextSize = 16 }, btn)
		refs.achRows[i] = { card = card, icon = icon, name = name, prog = prog, fill = fill, btn = btn, key = nil }
		btn.MouseButton1Click:Connect(function()
			local key = refs.achRows[i].key
			if not key then return end
			local res = Remotes.ClaimAchievement:InvokeServer(key)
			UI.Toast(res.ok and ("🏅 +" .. Config.Fmt(res.gems) .. " 💎!") or (res.err or "Not yet"), res.ok and GOLD or MUTED)
		end)
	end
end

local function refreshAchievements()
	local list = snap and snap.achievements
	if not (list and refs.achRows) then return end
	for i, rowRef in ipairs(refs.achRows) do
		local a = list[i]
		if a then
			rowRef.card.Visible = true
			rowRef.key = a.key
			rowRef.icon.Text = a.icon
			rowRef.name.Text = a.name
			local done = 0
			for _, t in ipairs(a.tiers) do if t.claimed then done += 1 end end
			local nextTier = a.tiers[done + 1]
			if nextTier then
				rowRef.prog.Text = a.cur .. " / " .. nextTier.goal .. "   →  +" .. Config.Fmt(nextTier.gems) .. " 💎   (Tier " .. (done + 1) .. "/" .. #a.tiers .. ")"
				rowRef.fill.Size = UDim2.fromScale(math.clamp(a.cur / math.max(1, nextTier.goal), 0, 1), 1)
				if a.claimable then
					rowRef.btn.Text = "CLAIM"; rowRef.btn.BackgroundColor3 = GOOD; rowRef.btn.AutoButtonColor = true
				else
					rowRef.btn.Text = "Tier " .. (done + 1); rowRef.btn.BackgroundColor3 = BG; rowRef.btn.AutoButtonColor = false
				end
			else
				rowRef.prog.Text = "✅ All tiers complete!"
				rowRef.fill.Size = UDim2.fromScale(1, 1)
				rowRef.btn.Text = "✓ DONE"; rowRef.btn.BackgroundColor3 = Color3.fromRGB(60, 90, 70); rowRef.btn.AutoButtonColor = false
			end
		else
			rowRef.card.Visible = false
			rowRef.key = nil
		end
	end
end

-- ===== HUD =====
local function buildHUD()
	local cardW, cardH = (IS_TOUCH and 300 or 240), (IS_TOUCH and 104 or 86)
	local card = mk("Frame", {
		Position = UDim2.fromOffset(12, 14), Size = UDim2.fromOffset(cardW, cardH),
		BackgroundColor3 = BG, BackgroundTransparency = 0.15,
	}, gui)
	corner(card, 12)
	stroke(card)
	refs.gems = label({
		Position = UDim2.fromOffset(12, 6), Size = UDim2.new(1, -24, 0, 40),
		Text = "💎 0", Font = Enum.Font.GothamBlack, TextXAlignment = Enum.TextXAlignment.Left,
	}, card)
	mk("UIScale", { Name = "Pulse" }, refs.gems)
	refs.rate = label({
		Position = UDim2.fromOffset(12, 46), Size = UDim2.new(1, -24, 0, 16),
		Text = "", TextColor3 = MUTED, Font = Enum.Font.Gotham, TextXAlignment = Enum.TextXAlignment.Left,
	}, card)
	refs.luckLine = label({
		Position = UDim2.fromOffset(12, 63), Size = UDim2.new(1, -24, 0, 16),
		Text = "", TextColor3 = MUTED, Font = Enum.Font.Gotham, TextXAlignment = Enum.TextXAlignment.Left,
	}, card)

	-- buff chips
	local chips = mk("Frame", {
		Position = UDim2.fromOffset(12, 106), Size = UDim2.fromOffset(240, 96),
		BackgroundTransparency = 1,
	}, gui)
	mk("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, chips)
	local function chip(name, color)
		local c = label({
			Size = UDim2.fromOffset(240, 22), Text = "", TextColor3 = color,
			BackgroundColor3 = BG, BackgroundTransparency = 0.25, Visible = false,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, chips)
		corner(c, 8)
		mk("UIPadding", { PaddingLeft = UDim.new(0, 8) }, c)
		refs[name] = c
	end
	chip("chipBoost", Color3.fromRGB(255, 235, 140))
	chip("chipStreak", Color3.fromRGB(255, 170, 110))
	chip("chipServer", Color3.fromRGB(140, 255, 180))
	chip("chipGolden", Color3.fromRGB(255, 220, 120))
	chip("shardChip", Color3.fromRGB(90, 230, 210))

	-- right-side menu buttons (thumb-reachable on the right edge). Compact on touch
	-- so the 4-button column fits a short landscape phone without clipping the top.
	local btnW = IS_TOUCH and 64 or 74
	local btnH = IS_TOUCH and 50 or 62
	local pad = IS_TOUCH and 5 or 7
	local col = mk("Frame", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -6, 0.5, 0),
		Size = UDim2.fromOffset(btnW, (btnH + pad) * 7), BackgroundTransparency = 1,
	}, gui)
	mk("UIListLayout", { Padding = UDim.new(0, pad), SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Right }, col)
	local function sideBtn(icon, text, cb)
		local b = mk("TextButton", {
			Size = UDim2.fromOffset(btnW, btnH), BackgroundColor3 = BG, BackgroundTransparency = 0.12,
			Text = icon .. "\n" .. text, TextColor3 = TEXT, Font = Enum.Font.GothamBold,
			TextScaled = true, AutoButtonColor = true,
		}, col)
		corner(b, 12)
		stroke(b, ACCENT, 1.2)
		mk("UITextSizeConstraint", { MaxTextSize = 19 }, b)
		b.MouseButton1Click:Connect(cb)
		return b
	end
	refs.dailyBtn = sideBtn("📅", "Daily", function() UI.TogglePanel("Daily") end)
	refs.petsBtn = sideBtn("🐾", "Pets", function() UI.TogglePanel("Pets") end)
	refs.shopBtn = sideBtn("🛒", "Shop", function() UI.TogglePanel("Shop") end)
	sideBtn("⛏️", "Upgrades", function() UI.TogglePanel("Upgrades") end)
	sideBtn("📖", "Index", function() UI.TogglePanel("Index") end)
	refs.achBtn = sideBtn("🏅", "Awards", function() UI.TogglePanel("Achievements") end)
	refs.harvestBtn = sideBtn("🌱", "Garden", function()
		local res = Remotes.HarvestGarden:InvokeServer()
		if not res.ok then UI.Toast(res.err or "Nothing to harvest", MUTED) end
	end)

	-- Big thumb-reachable CRACK button (touch only): hold to crack the nearest
	-- in-range geode. Placed above the default jump button in the lower-right.
	if IS_TOUCH then
		local crackBtn = mk("TextButton", {
			-- center-bottom-right: right-thumb reachable, clear of the menu column,
			-- the left joystick, and the default jump button
			AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 78, 1, -14),
			Size = UDim2.fromOffset(116, 116), BackgroundColor3 = Color3.fromRGB(150, 92, 236),
			Text = "⛏️\nCRACK", TextColor3 = TEXT, Font = Enum.Font.GothamBlack,
			TextScaled = true, AutoButtonColor = true, ZIndex = 6,
		}, gui)
		mk("UICorner", { CornerRadius = UDim.new(1, 0) }, crackBtn)
		stroke(crackBtn, Color3.fromRGB(210, 170, 255), 2.5)
		mk("UITextSizeConstraint", { MaxTextSize = 26 }, crackBtn)
		local held = false
		crackBtn.MouseButton1Down:Connect(function() held = true end)
		crackBtn.MouseButton1Up:Connect(function() held = false end)
		crackBtn.MouseLeave:Connect(function() held = false end)
		task.spawn(function()
			while crackBtn.Parent do
				if held then Remotes.CrackRequest:FireServer() end
				task.wait(0.12)
			end
		end)
	end

	-- banner stack
	local banners = mk("Frame", {
		AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 8),
		Size = UDim2.new(0.9, 0, 0, 120), BackgroundTransparency = 1,
	}, gui)
	mk("UISizeConstraint", { MaxSize = Vector2.new(600, 120) }, banners)
	mk("UIListLayout", { Padding = UDim.new(0, 4), HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, banners)
	refs.banners = banners

	-- onboarding "NEXT GOAL" card (top-centre, shown only during the first-run flow)
	local GREEN = Color3.fromRGB(120, 255, 170)
	local goal = mk("Frame", {
		Name = "GoalCard", AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 60), Size = UDim2.new(0.92, 0, 0, 56),
		BackgroundColor3 = BG, BackgroundTransparency = 0.1, Visible = false, ZIndex = 8,
	}, gui)
	corner(goal, 12)
	stroke(goal, GREEN, 1.8)
	mk("UISizeConstraint", { MaxSize = Vector2.new(430, 56) }, goal)
	label({
		Position = UDim2.fromOffset(14, 5), Size = UDim2.new(1, -28, 0, 15),
		Text = "🎯 NEXT GOAL", TextColor3 = GREEN, Font = Enum.Font.GothamBlack,
		TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 9,
	}, goal)
	refs.goalText = label({
		Position = UDim2.fromOffset(14, 21), Size = UDim2.new(1, -28, 0, 22),
		Text = "", Font = Enum.Font.GothamBold, TextXAlignment = Enum.TextXAlignment.Left,
		TextScaled = true, ZIndex = 9,
	}, goal)
	mk("UITextSizeConstraint", { MaxTextSize = 18 }, refs.goalText)
	local gbarBG = mk("Frame", {
		AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 14, 1, -6), Size = UDim2.new(1, -28, 0, 5),
		BackgroundColor3 = BG2, Visible = false, ZIndex = 9,
	}, goal)
	corner(gbarBG, 3)
	refs.goalFill = mk("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = GREEN, ZIndex = 10 }, gbarBG)
	corner(refs.goalFill, 3)
	refs.goalBar = gbarBG
	refs.goalCard = goal

	-- meteor bar
	local meteor = mk("Frame", {
		AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 132),
		Size = UDim2.fromOffset(420, 36), BackgroundColor3 = BG, BackgroundTransparency = 0.15,
		Visible = false,
	}, gui)
	corner(meteor, 10)
	stroke(meteor, Color3.fromRGB(255, 160, 80))
	refs.meteorFrame = meteor
	refs.meteorText = label({
		Size = UDim2.fromScale(1, 0.55), Text = "", TextColor3 = Color3.fromRGB(255, 200, 140),
		Font = Enum.Font.GothamBlack, ZIndex = 22,
	}, meteor)
	local mbarBG = mk("Frame", {
		AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -5),
		Size = UDim2.new(0.94, 0, 0, 8), BackgroundColor3 = BG2, ZIndex = 22,
	}, meteor)
	corner(mbarBG, 4)
	refs.meteorFill = mk("Frame", {
		Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(255, 150, 70), ZIndex = 23,
	}, mbarBG)
	corner(refs.meteorFill, 4)
end

-- ===== public API =====
function UI.Banner(data)
	local color = data.color
	if not color and data.colorRGB then
		color = Color3.fromRGB(data.colorRGB[1], data.colorRGB[2], data.colorRGB[3])
	end
	local b = label({
		Size = UDim2.new(1, 0, 0, 30), Text = data.text, TextColor3 = color or TEXT,
		BackgroundColor3 = BG, BackgroundTransparency = 0.25, TextStrokeTransparency = 0.6,
		Font = Enum.Font.GothamBlack,
	}, refs.banners)
	corner(b, 10)
	Debris:AddItem(b, 4.5)
end

function UI.Update(newSnap)
	snap = newSnap
	refreshUpgrades()
	refreshShop()
	refreshIndex()
	local multStr = snap.mult < 100 and string.format("%.1f", snap.mult) or Config.Fmt(snap.mult)
	refs.rate.Text = "×" .. multStr .. " mult • ~" .. Config.Fmt(snap.rate) .. "/s"
	refs.luckLine.Text = string.format("🍀 luck x%.2f • ⛏️ %.2fs", snap.luckFactor, snap.cooldown)
	local overgrown = snap.gardenOvergrown
	refs.harvestBtn.Text = "🌱\n" .. (overgrown and "OVERGROWN!" or Config.Fmt(snap.gardenValue))
	refs.harvestBtn.TextColor3 = overgrown and Color3.fromRGB(255, 220, 100) or TEXT

	-- onboarding goal card
	local ob = snap.onboard
	if ob then
		refs.goalCard.Visible = true
		if ob.target and ob.progress then
			refs.goalText.Text = ob.text .. "  (" .. Config.Fmt(ob.progress) .. "/" .. Config.Fmt(ob.target) .. ")"
			refs.goalBar.Visible = true
			refs.goalFill.Size = UDim2.fromScale(math.clamp(ob.progress / math.max(1, ob.target), 0, 1), 1)
		else
			refs.goalText.Text = ob.text
			refs.goalBar.Visible = false
		end
	else
		refs.goalCard.Visible = false
	end

	-- Grotto shard counter (Sunken explorer gate)
	if refs.shardChip then
		local sc = (snap.zoneShards and snap.zoneShards.Sunken) or 0
		refs.shardChip.Visible = (sc > 0 and sc < 5)
		if refs.shardChip.Visible then refs.shardChip.Text = "🔹 Grotto Shards " .. sc .. "/5" end
	end

	refreshDaily()
	refreshPets()
	refreshAchievements()
end

function UI.OnCrack(data)
	if data.userId ~= player.UserId then return end
	local pulse = refs.gems:FindFirstChild("Pulse")
	if pulse then
		pulse.Scale = 1.15
		TweenService:Create(pulse, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	end
	-- crack-result pass advertising: on a rare find, if 2× Coins isn't owned yet,
	-- show what the pass WOULD have paid — throttled so it informs, never nags.
	if snap and data.rarity and data.rarity >= Config.LuckyTierIndex
		and data.gained and snap.passes and not snap.passes.DoubleGems then
		local now = os.clock()
		if not UI._lastUpsell or now - UI._lastUpsell > 45 then
			UI._lastUpsell = now
			UI.Toast("💰 2× Coins pass would've made that " .. Config.Fmt(data.gained * 2) .. "!", GOLD)
		end
	end
end

function UI.Meteor(data)
	local f = refs.meteorFrame
	if data.phase == "warning" then
		f.Visible = true
		refs.meteorText.Text = "☄️ METEOR GEODE INCOMING — GET TO THE CRATER!"
		refs.meteorFill.Size = UDim2.fromScale(1, 1)
	elseif data.phase == "impact" then
		f.Visible = true
		refs.meteorText.Text = "☄️ CRACK THE METEOR GEODE!"
	elseif data.phase == "active" then
		f.Visible = true
		refs.meteorText.Text = "☄️ METEOR GEODE — " .. Config.Fmt(data.hp) .. " / " .. Config.Fmt(data.maxHp)
		refs.meteorFill.Size = UDim2.fromScale(math.clamp(data.hp / data.maxHp, 0, 1), 1)
	elseif data.phase == "boom" then
		refs.meteorText.Text = "💥 SUPERNOVA!!!"
		refs.meteorFill.Size = UDim2.fromScale(0, 1)
		task.delay(3, function() f.Visible = false end)
	elseif data.phase == "dead" then
		f.Visible = false
	end
end

function UI.GoldenHour(data)
	if snap then snap.goldenHour = data.active end
end

function UI.Streak(data)
	local card = mk("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.38),
		Size = UDim2.fromOffset(360, 130), BackgroundColor3 = BG, BackgroundTransparency = 0.06,
		ZIndex = 28,
	}, gui)
	corner(card, 14)
	stroke(card, Color3.fromRGB(255, 180, 90), 2)
	label({
		Position = UDim2.fromOffset(0, 12), Size = UDim2.new(1, 0, 0, 34),
		Text = "🔥 DAY " .. (data.day or 1) .. " STREAK!", Font = Enum.Font.GothamBlack,
		TextColor3 = Color3.fromRGB(255, 200, 120), ZIndex = 29,
	}, card)
	local msg
	if data.golden then
		msg = "🌟 A GOLDEN GEODE has spawned for you by the crater!"
	elseif data.minutes then
		msg = "✨ x2 Luck for " .. data.minutes .. " minutes!"
	else
		msg = "Come back tomorrow to grow your streak!"
	end
	label({
		Position = UDim2.fromOffset(16, 52), Size = UDim2.new(1, -32, 0, 60),
		Text = msg, Font = Enum.Font.GothamBold, TextWrapped = true, ZIndex = 29,
	}, card)
	task.delay(7, function()
		if card.Parent then
			TweenService:Create(card, TweenInfo.new(0.5), { BackgroundTransparency = 1, Position = card.Position - UDim2.fromOffset(0, 40) }):Play()
			for _, d in ipairs(card:GetDescendants()) do
				if d:IsA("TextLabel") then
					TweenService:Create(d, TweenInfo.new(0.5), { TextTransparency = 1 }):Play()
				elseif d:IsA("UIStroke") then
					TweenService:Create(d, TweenInfo.new(0.5), { Transparency = 1 }):Play()
				end
			end
			Debris:AddItem(card, 0.6)
		end
	end)
end

function UI.Init(config, remotes)
	Config, Remotes = config, remotes
	gui = Instance.new("ScreenGui")
	gui.Name = "GeodeHUD"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 10
	gui.Parent = player:WaitForChild("PlayerGui")

	buildHUD()
	buildUpgrades()
	buildShop()
	buildIndex()
	buildDaily()
	buildPets()
	buildAchievements()

	-- Neon Geode: chunky glossy look + press-punch on every button, from the shared style
	for _, d in ipairs(gui:GetDescendants()) do
		if d:IsA("TextButton") then
			d.AutoButtonColor = false
			if not d:FindFirstChildOfClass("UICorner") then SG.corner(d, "md") end
			if d.BackgroundTransparency < 0.6 and not d:FindFirstChildOfClass("UIGradient") then
				SG.gradient(d, SG.lighten(d.BackgroundColor3, 0.2), d.BackgroundColor3, 90)
			end
			SG.pressFX(d)
		end
	end

	UI._RefreshPanels()
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(UI._RefreshPanels)
	task.defer(UI._RefreshPanels) -- re-run once AbsoluteSize settles after first render

	-- heartbeat: gem count-up + live buff chips
	RunService.Heartbeat:Connect(function()
		if not snap then return end
		displayGems += (snap.gems - displayGems) * 0.18
		if math.abs(snap.gems - displayGems) < 1 then displayGems = snap.gems end
		refs.gems.Text = "💎 " .. Config.Fmt(math.floor(displayGems + 0.5))
		local now = os.time()
		local function setChip(chip, active, text)
			refs[chip].Visible = active
			if active then refs[chip].Text = text end
		end
		setChip("chipBoost", snap.boostUntil > now, "⚡ Lucky Boost " .. math.max(0, snap.boostUntil - now) .. "s")
		setChip("chipStreak", snap.streakLuckUntil > now, "🔥 Streak x2 Luck " .. math.floor(math.max(0, snap.streakLuckUntil - now) / 60) .. "m")
		setChip("chipServer", snap.serverLuckPct > 0, "🎁 Server Luck +" .. math.floor(snap.serverLuckPct * 100) .. "%")
		setChip("chipGolden", snap.goldenHour == true, "🌟 GOLDEN HOUR +50% Luck!")
	end)
end

return UI
