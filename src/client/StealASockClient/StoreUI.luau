-- StoreUI: the Robux Store (StoreConfig) - game passes on the "Passes" tab, developer products on
-- the "Boosts" tab, switched by a segmented control whose highlight springs across.
-- Pass cards: a glowing, swaying emoji, name, what it does and a Robux price button (green, shine);
-- once owned the button becomes a rotated "OWNED ✓" stamp and the card gets a gold rim. The
-- best-value pass wears a swaying BEST ribbon. Product cards also show what they'd do for THIS
-- player right now: cash packs "≈ $X" from your income, Server Luck a live countdown while it's
-- running, Rare Sock Drop how many drops still wait for a free slot.
--
-- Buying calls StorePurchase(kind, key). The server opens Roblox's purchase prompt (or, in Studio
-- while an id is 0, simulates the purchase); the grant arrives later through the State (passes) and
-- the Celebrate remote, so the button shows "Waiting..." until then, until the prompt is closed
-- without buying, or for 20 s at most. Every price shown comes from StoreConfig.
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = require(Shared:WaitForChild("Util"))
local StoreConfig = require(Shared:WaitForChild("Config"):WaitForChild("StoreConfig"))

local Theme = require(script.Parent:WaitForChild("Theme"))
local Anim = require(script.Parent:WaitForChild("Anim"))
local UISound = require(script.Parent:WaitForChild("UISound"))
local Menu = require(script.Parent:WaitForChild("Menu"))

local StoreUI = {}

local CARD_HEIGHT = 232
local GAP = 14 -- between cards
local TWO_COLUMNS_FROM = 600 -- card area width (reference px) that fits two columns
local TAB_HEIGHT = 60
local FOOTER_HEIGHT = 22
local WAIT_SECONDS = 20 -- longest a button waits for a prompted purchase to be granted
local REMOTE_TIMEOUT = 10 -- seconds before a button whose request never came back is usable again
local FOCUS_SECONDS = 2 -- StoreUI.Focus only steers an open that happens this soon after it
local FEATURED = (StoreConfig :: any).Featured or "DoubleCash" -- the pass with the BEST ribbon
local DESC_COLOR = Theme.Color.Text:Lerp(Theme.Color.Muted, 0.45)

local TABS = {
	{ name = "Passes", label = "🎟️ Passes", kind = "pass", order = StoreConfig.PassOrder, defs = StoreConfig.Passes :: any },
	{ name = "Boosts", label = "⚡ Boosts", kind = "product", order = StoreConfig.ProductOrder, defs = StoreConfig.Products :: any },
}

type Card = {
	kind: string, -- "pass" | "product"
	key: string,
	def: any, -- StoreConfig.Pass / StoreConfig.Product
	slot: Frame,
	inner: Frame,
	glow: Frame,
	icon: Frame,
	info: TextLabel,
	infoKind: string?, -- "cash" | "luck" | "drop" | nil
	button: TextButton,
	note: TextLabel,
	stamp: Frame?,
	ribbon: Frame?,
	owned: boolean,
	busy: boolean,
	buyToken: number,
	waiting: boolean,
	waitToken: number,
	noteToken: number,
	pulsing: boolean,
	shownCount: number,
}

type Page = {
	name: string,
	index: number,
	tab: TextButton,
	scroll: ScrollingFrame,
	grid: UIGridLayout,
	cards: { Card },
}

local player = Players.LocalPlayer
local pages = {} :: { [string]: Page }
local pageList = {} :: { Page }
local byKey = { pass = {}, product = {} } :: { [string]: { [string]: Card } }
local luckCards = {} :: { Card }
local lastState: any = nil
local isOpen = false
local built = false
local activeTab = TABS[1].name
local highlight: Frame? = nil
local focusCard: Card? = nil
local focusAt = 0

-- ---------- small helpers ----------

local function cashInfo(n: number): string
	return "You'd get ≈ $" .. Util.FormatCash(math.floor(n))
end

-- 754 -> "12:34", 3723 -> "1:02:03"
local function clock(seconds: number): string
	local total = math.max(0, math.ceil(seconds))
	local h = total // 3600
	local m = (total % 3600) // 60
	local s = total % 60
	if h > 0 then
		return string.format("%d:%02d:%02d", h, m, s)
	end
	return string.format("%d:%02d", m, s)
end

-- Shrinks a label's text to fit its box (at most `max`, never below `min`).
local function fit(label: TextLabel, max: number, min: number)
	label.TextScaled = true
	local c = Instance.new("UITextSizeConstraint")
	c.MaxTextSize = max
	c.MinTextSize = min
	c.Parent = label
end

-- A layout cell holding a centred frame, so pops and bumps grow from the middle and never fight
-- the layout. Returns (cell, inner).
local function cell(parent: Instance, layoutOrder: number, name: string): (Frame, Frame)
	local slot = Instance.new("Frame")
	slot.Name = name
	slot.BackgroundTransparency = 1
	slot.LayoutOrder = layoutOrder
	slot.ZIndex = 12
	slot.Parent = parent
	local inner = Instance.new("Frame")
	inner.Name = "Inner"
	inner.AnchorPoint = Vector2.new(0.5, 0.5)
	inner.Position = UDim2.fromScale(0.5, 0.5)
	inner.Size = UDim2.fromScale(1, 1)
	inner.BorderSizePixel = 0
	inner.ZIndex = 12
	inner.Parent = slot
	return slot, inner
end

local function setShine(button: GuiObject, on: boolean, period: number?)
	local sheen = button:FindFirstChild("Sheen")
	if on and not sheen then
		Anim.shine(button, period)
	elseif not on and sheen then
		sheen:Destroy()
	end
end

local function storeRemote(): RemoteFunction?
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	local remote = folder and folder:FindFirstChild("StorePurchase")
	if remote and remote:IsA("RemoteFunction") then
		return remote
	end
	return nil
end

local function tabOf(card: Card): string
	return if card.kind == "pass" then TABS[1].name else TABS[2].name
end

-- Decorative loops run only for the cards on screen.
local function loopsOn(card: Card): boolean
	return isOpen and activeTab == tabOf(card)
end

local function shinePeriod(card: Card): number
	return if card.kind == "pass" then 2.8 else 4.2
end

local function inners(page: Page): { GuiObject }
	local list = {} :: { GuiObject }
	for _, card in ipairs(page.cards) do
		table.insert(list, card.inner)
	end
	return list
end

-- ---------- card state ----------

local function setLoops(card: Card, on: boolean)
	if on then
		Anim.sway(card.icon, 5, 2.1 + card.slot.LayoutOrder * 0.17)
		Anim.pulse(card.glow, 1.1, 1.8)
		if card.ribbon then
			Anim.sway(card.ribbon, 7, 1.4)
		end
		if card.pulsing then
			Anim.pulse(card.info, 1.06, 1.2)
		end
	else
		Anim.stop(card.icon, "sway")
		card.icon.Rotation = 0
		Anim.stop(card.glow, "pulse")
		Anim.scale(card.glow).Scale = 1
		if card.ribbon then
			Anim.stop(card.ribbon, "sway")
			card.ribbon.Rotation = -6
		end
		Anim.stop(card.info, "pulse")
		Anim.scale(card.info).Scale = 1
	end
	if not card.waiting then -- (a waiting button keeps its shimmer)
		setShine(card.button, on and not card.owned and not card.busy, shinePeriod(card))
	end
end

local function showNote(card: Card, text: string, color: Color3, seconds: number?)
	card.noteToken += 1
	local token = card.noteToken
	local note = card.note
	note.Text = text
	note.TextColor3 = color
	note.TextTransparency = 1
	Anim.tween(note, 0.15, { TextTransparency = 0 }, Enum.EasingStyle.Quad)
	Anim.bump(note, 1.12)
	task.delay(seconds or 2.6, function()
		if card.noteToken == token then
			Anim.tween(note, 0.35, { TextTransparency = 1 }, Enum.EasingStyle.Quad)
		end
	end)
end

-- The green Robux price button (hidden once a pass is owned).
local function restoreButton(card: Card)
	local button = card.button
	setShine(button, false)
	if card.owned then
		button.Visible = false
		return
	end
	button.Visible = true
	Theme.restyle(button, "green")
	button.Text = Theme.robux(card.def.price)
	setShine(button, loopsOn(card), shinePeriod(card))
end

local function buildStamp(card: Card): Frame
	local stamp = Instance.new("Frame")
	stamp.Name = "Owned"
	stamp.AnchorPoint = Vector2.new(0.5, 0.5)
	stamp.Position = card.button.Position
	stamp.Size = UDim2.fromOffset(210, 54)
	stamp.Rotation = -7
	stamp.BackgroundColor3 = Theme.Color.White
	stamp.BackgroundTransparency = 0.3
	stamp.BorderSizePixel = 0
	stamp.ZIndex = 14
	stamp.Visible = false
	Theme.corner(stamp, 12)
	Theme.stroke(stamp, Theme.Color.Money, 4)
	local text = Theme.label(stamp, "OWNED ✓", 30, Theme.Color.Money)
	text.Name = "Text"
	text.Size = UDim2.fromScale(1, 1)
	text.ZIndex = 15
	stamp.Parent = card.inner
	return stamp
end

-- A pass is yours: the button turns into the OWNED stamp (slammed in when `animate`), gold rim.
local function setOwned(card: Card, animate: boolean)
	if card.owned then
		return
	end
	card.owned = true
	card.waiting = false
	card.waitToken += 1
	setShine(card.button, false)
	card.button.Visible = false
	local rim = card.inner:FindFirstChildOfClass("UIStroke")
	if rim then
		rim.Color = Theme.Color.Gold2
		rim.Thickness = 4
	end
	local grad = card.inner:FindFirstChildOfClass("UIGradient")
	if grad then
		grad.Color = ColorSequence.new(Theme.Color.Inset, Theme.Color.Inset:Lerp(Theme.Color.Gold, 0.45))
	end
	local stamp = card.stamp or buildStamp(card)
	card.stamp = stamp
	stamp.Visible = true
	local s = Anim.scale(stamp)
	if animate then
		s.Scale = if Anim.Reduced then 1.1 else 1.9
		Anim.tween(s, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
		Anim.bump(card.inner, 1.05)
		UISound.Play("pop")
	else
		s.Scale = 1
	end
end

local function stopWaiting(card: Card)
	if not card.waiting then
		return
	end
	card.waiting = false
	card.waitToken += 1
	restoreButton(card)
end

-- Roblox's purchase prompt is up: a blue "Waiting..." button with a quick shimmer until the grant
-- (State / Celebrate), the prompt closing without a purchase, or WAIT_SECONDS.
local function startWaiting(card: Card)
	card.waiting = true
	card.waitToken += 1
	local token = card.waitToken
	local button = card.button
	setShine(button, false)
	Theme.restyle(button, "blue")
	Anim.shine(button, 0.2) -- (Anim skips the sweep under Reduce motion)
	task.spawn(function()
		local dots = 0
		while card.waiting and card.waitToken == token do
			dots = dots % 3 + 1
			button.Text = "Waiting" .. string.rep(".", dots)
			task.wait(0.4)
		end
	end)
	task.delay(WAIT_SECONDS, function()
		if card.waiting and card.waitToken == token then
			stopWaiting(card)
		end
	end)
end

local function refreshLuck(card: Card)
	local info = card.info
	local endsAt = if lastState and type(lastState.luckUntil) == "number" then lastState.luckUntil else 0
	local left = endsAt - workspace:GetServerTimeNow()
	local active = left > 0
	local minutes = tostring(card.def.minutes or 0)
	if active then
		info.Text = "🍀 ACTIVE " .. clock(left) .. " — buy to add " .. minutes .. " min"
		info.TextColor3 = Theme.Color.Money
	else
		info.Text = "Lasts " .. minutes .. " min · for everyone in the server"
		info.TextColor3 = DESC_COLOR
	end
	if active ~= card.pulsing then
		card.pulsing = active
		if active and loopsOn(card) then
			Anim.pulse(info, 1.06, 1.2)
		elseif not active then
			Anim.stop(info, "pulse")
			Anim.scale(info).Scale = 1
		end
	end
end

-- The product's "what it does for you right now" line.
local function refreshInfo(card: Card, animate: boolean)
	local info = card.info
	if card.infoKind == "cash" then
		local rate = if lastState and type(lastState.rate) == "number" then lastState.rate else 0
		local amount = math.max(card.def.cashMin or 0, math.floor(rate * (card.def.cashSeconds or 0)))
		info.TextColor3 = Theme.Color.Money
		Anim.countTo(info, amount, cashInfo, if animate then nil else 0)
	elseif card.infoKind == "luck" then
		refreshLuck(card)
	elseif card.infoKind == "drop" then
		local waiting = if lastState and type(lastState.pendingDrops) == "number" then lastState.pendingDrops else 0
		info.TextColor3 = Theme.Color.Title
		info.Text = if waiting > 0 then "🎁 " .. waiting .. " waiting for a free slot" else ""
		if waiting > card.shownCount and animate then
			Anim.bump(info, 1.15)
		end
		card.shownCount = waiting
	end
end

-- ---------- buying ----------

local function failed(card: Card, text: string)
	if isOpen then
		Anim.wiggle(card.button)
		UISound.Play("error")
	end
	showNote(card, text, Theme.Color.Bad, 2.8)
end

local function onBuy(card: Card)
	if card.busy or card.waiting or card.owned then
		return
	end
	local remote = storeRemote()
	if not remote then
		failed(card, "The store is still opening - try again")
		return
	end
	card.busy = true
	card.buyToken += 1
	local token = card.buyToken
	setShine(card.button, false)
	card.button.Text = "• • •"
	task.delay(REMOTE_TIMEOUT, function()
		-- the server never answered: give the button back (a late answer is still shown)
		if card.busy and card.buyToken == token then
			card.busy = false
			restoreButton(card)
		end
	end)
	task.spawn(function()
		local ok, result = pcall(function()
			return remote:InvokeServer(card.kind, card.key)
		end)
		if card.buyToken ~= token then
			return -- a newer tap owns the button now (grants still arrive through State / Celebrate)
		end
		card.busy = false
		if not ok or type(result) ~= "table" then
			restoreButton(card)
			failed(card, "Couldn't reach the store - try again")
			return
		end
		if result.ok ~= true then
			restoreButton(card)
			failed(card, if type(result.err) == "string" then result.err else "Not available right now")
			return
		end
		if result.prompted == true and not card.owned then
			startWaiting(card)
			return
		end
		restoreButton(card)
		if result.simulated == true then
			showNote(card, "Studio test purchase", DESC_COLOR, 3)
			if isOpen then
				Anim.bump(card.inner, 1.04)
			end
		elseif type(result.msg) == "string" then
			showNote(card, result.msg, Theme.Color.Money, 3)
		end
	end)
end

local function cardById(kind: string, id: number): Card?
	if id == 0 then
		return nil
	end
	for _, card in pairs(byKey[kind]) do
		if card.def.id == id then
			return card
		end
	end
	return nil
end

-- Celebrate {kind, data}: the HUD does the banner and confetti; this panel finishes the button.
local function onCelebrate(kind, data)
	if kind == "rareDrop" then
		-- a drop that lands at once only sends "rareDrop" (no "product"): finish its button too
		local drop = byKey.product.RareDrop
		if drop then
			stopWaiting(drop)
		end
		return
	end
	if (kind ~= "pass" and kind ~= "product") or type(data) ~= "table" or type(data.key) ~= "string" then
		return
	end
	local card = byKey[kind][data.key]
	if not card then
		return
	end
	if kind == "pass" then
		setOwned(card, loopsOn(card))
		return
	end
	stopWaiting(card)
	if not loopsOn(card) then
		return
	end
	-- (the HUD flies the coins and pops "+$X" for cash packs; this card just answers the tap)
	Anim.bump(card.inner, 1.06)
	local cash = if type(data.cash) == "number" and data.cash > 0 then data.cash else nil
	showNote(card, if cash then "+$" .. Util.FormatCash(cash) .. " - thank you! ✓" else "Thank you! ✓", Theme.Color.Money, 3)
end

-- ---------- tabs ----------

local function selectTab(name: string, animate: boolean)
	local page = pages[name]
	if not page then
		return
	end
	local previous = pages[activeTab]
	activeTab = name
	if highlight then
		local target = UDim2.new((page.index - 1) / #pageList, 4, 0, 4)
		if animate then
			Anim.tween(highlight, 0.45, { Position = target }, Enum.EasingStyle.Back)
		else
			highlight.Position = target
		end
	end
	for _, p in ipairs(pageList) do
		local on = p == page
		p.tab.TextColor3 = if on then Theme.Color.White else Theme.Color.Text
		local stroke = p.tab:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Enabled = on
		end
		p.scroll.Visible = on
		if not on then
			for _, card in ipairs(p.cards) do
				setLoops(card, false)
			end
		end
	end
	if not isOpen then
		return
	end
	for _, card in ipairs(page.cards) do
		setLoops(card, true)
	end
	if animate then
		page.scroll.CanvasPosition = Vector2.zero
		if not Anim.Reduced then
			-- the new page glides in from the side it sits on while its cards pop in
			local fromRight = previous == nil or page.index > previous.index
			page.scroll.Position = UDim2.fromOffset(if fromRight then 56 else -56, 0)
			Anim.tween(page.scroll, 0.4, { Position = UDim2.new() })
		end
		Anim.stagger(inners(page), 0.05)
	end
end

-- Scrolls a card into view and bounces it.
local function spotlight(card: Card)
	local page = pages[tabOf(card)]
	if not page then
		return
	end
	local cols = math.max(page.grid.FillDirectionMaxCells, 1)
	local row = math.ceil(card.slot.LayoutOrder / cols) - 1
	page.scroll.CanvasPosition = Vector2.new(0, row * (CARD_HEIGHT + GAP))
	task.delay(0.4, function()
		if loopsOn(card) then
			Anim.bump(card.inner, 1.08)
			UISound.Play("pop")
		end
	end)
end

-- ---------- building ----------

local function buildCard(page: Page, kind: string, key: string, def: any, index: number): Card
	local slot, inner = cell(page.scroll, index, key)
	inner.BackgroundColor3 = Theme.Color.White
	Theme.corner(inner, 18)
	Theme.stroke(inner, Theme.Color.Stroke, 3)
	Theme.gradient(inner, Theme.Color.Inset, Theme.Color.Inset:Lerp(def.color, 0.18))

	-- glowing icon: a soft halo (pulses) behind a swaying emoji badge
	local holder = Instance.new("Frame")
	holder.Name = "IconHolder"
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromOffset(14 + 44, 14 + 44)
	holder.Size = UDim2.fromOffset(88, 88)
	holder.ZIndex = 13
	holder.Parent = inner
	local glow = Instance.new("Frame")
	glow.Name = "Glow"
	glow.AnchorPoint = Vector2.new(0.5, 0.5)
	glow.Position = UDim2.fromScale(0.5, 0.5)
	glow.Size = UDim2.fromScale(1, 1)
	glow.BackgroundColor3 = def.color
	glow.BackgroundTransparency = 0.62
	glow.BorderSizePixel = 0
	glow.ZIndex = 13
	Theme.corner(glow, UDim.new(0.5, 0))
	Theme.stroke(glow, def.color, 6, 0.55)
	glow.Parent = holder
	local icon = Theme.icon(holder, def.icon, 70, def.color)
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.5)
	icon.ZIndex = 14

	local name = Theme.label(inner, def.display, 26, Theme.Color.Text)
	name.Name = "Title"
	name.Position = UDim2.fromOffset(116, 12)
	name.Size = UDim2.new(1, -128, 0, 30)
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.ZIndex = 13
	fit(name, 26, 14)

	local desc = Theme.label(inner, def.desc, 15, DESC_COLOR, Theme.FontBody)
	desc.Name = "Desc"
	desc.Position = UDim2.fromOffset(116, 44)
	desc.Size = UDim2.new(1, -128, 0, if kind == "pass" then 84 else 58) -- passes have no info line
	desc.TextXAlignment = Enum.TextXAlignment.Left
	desc.TextYAlignment = Enum.TextYAlignment.Top
	desc.TextWrapped = true
	desc.ZIndex = 13
	fit(desc, 15, 9)

	local info = Theme.label(inner, "", 15, DESC_COLOR, Theme.FontBody)
	info.Name = "Info"
	info.AnchorPoint = Vector2.new(0.5, 0.5)
	info.Position = UDim2.new(0.5, 0, 0, 110 + 12)
	info.Size = UDim2.new(1, -28, 0, 24)
	info.ZIndex = 13
	fit(info, 15, 9)

	-- 60 reference px tall: ~44 px on a phone
	local button = Theme.button(inner, Theme.robux(def.price), "green", UDim2.new(1, -28, 0, 60), 28)
	button.Name = "Buy"
	button.AnchorPoint = Vector2.new(0.5, 0.5)
	button.Position = UDim2.new(0.5, 0, 0, 142 + 30)
	button.ZIndex = 13
	Anim.button(button, "click")

	local note = Theme.label(inner, "", 14, Theme.Color.Bad, Theme.FontBody)
	note.Name = "Note"
	note.AnchorPoint = Vector2.new(0.5, 0.5)
	note.Position = UDim2.new(0.5, 0, 0, 206 + 9)
	note.Size = UDim2.new(1, -28, 0, 18)
	note.TextTransparency = 1
	note.ZIndex = 13
	fit(note, 14, 9)

	local ribbon: Frame? = nil
	if kind == "pass" and key == FEATURED then
		local r = Instance.new("Frame")
		r.Name = "Best"
		r.AnchorPoint = Vector2.new(0.5, 0.5)
		r.Position = UDim2.fromOffset(52, 12)
		r.Size = UDim2.fromOffset(84, 30)
		r.Rotation = -6
		r.ZIndex = 16
		Theme.candy(r, "red", 10, 2.5)
		Theme.gloss(r, 10)
		local t = Theme.label(r, "BEST", 18, Theme.Color.White)
		t.Name = "Text"
		t.Size = UDim2.fromScale(1, 1)
		t.ZIndex = 18 -- above the ribbon's gloss
		Theme.textStroke(t, Theme.Styles.red.stroke, 2)
		r.Parent = inner
		ribbon = r
	end

	local infoKind: string? = nil
	if kind == "product" then
		if def.cashSeconds or def.cashMin then
			infoKind = "cash"
		elseif def.minutes then
			infoKind = "luck"
		elseif def.minRank then
			infoKind = "drop"
		end
	end

	local card: Card = {
		kind = kind,
		key = key,
		def = def,
		slot = slot,
		inner = inner,
		glow = glow,
		icon = icon,
		info = info,
		infoKind = infoKind,
		button = button,
		note = note,
		stamp = nil,
		ribbon = ribbon,
		owned = false,
		busy = false,
		buyToken = 0,
		waiting = false,
		waitToken = 0,
		noteToken = 0,
		pulsing = false,
		shownCount = 0,
	}
	button.Activated:Connect(function()
		onBuy(card)
	end)
	byKey[kind][key] = card
	if infoKind == "luck" then
		table.insert(luckCards, card)
	end
	refreshInfo(card, false)
	return card
end

-- The segmented control: a pill with a springy highlight behind the active tab.
local function buildTabs(content: Frame): { TextButton }
	local bar = Instance.new("Frame")
	bar.Name = "Tabs"
	bar.AnchorPoint = Vector2.new(0.5, 0)
	bar.Position = UDim2.new(0.5, 0, 0, 2)
	bar.Size = UDim2.new(1, -8, 0, TAB_HEIGHT)
	bar.BackgroundColor3 = Theme.Color.White
	bar.BorderSizePixel = 0
	bar.ZIndex = 12
	Theme.corner(bar, UDim.new(0.5, 0))
	Theme.stroke(bar, Theme.Color.Stroke, 3)
	Theme.gradient(bar, Theme.Color.InsetDark, Theme.Color.Panel2)
	local maxSize = Instance.new("UISizeConstraint")
	maxSize.MaxSize = Vector2.new(440, TAB_HEIGHT)
	maxSize.Parent = bar
	bar.Parent = content

	local hl = Instance.new("Frame")
	hl.Name = "Highlight"
	hl.Position = UDim2.fromOffset(4, 4)
	hl.Size = UDim2.new(1 / #TABS, -8, 1, -8)
	hl.ZIndex = 13
	Theme.candy(hl, "purple", 26, 3)
	Theme.gloss(hl, 26)
	hl.Parent = bar
	highlight = hl

	local buttons = {}
	for i, tab in ipairs(TABS) do
		local b = Instance.new("TextButton")
		b.Name = tab.name .. "Tab"
		b.AutoButtonColor = false
		b.BackgroundTransparency = 1
		b.AnchorPoint = Vector2.new(0.5, 0.5)
		b.Position = UDim2.fromScale((i - 0.5) / #TABS, 0.5)
		b.Size = UDim2.fromScale(1 / #TABS, 1)
		b.Font = Theme.Font
		b.Text = tab.label
		b.TextSize = 24
		b.TextColor3 = Theme.Color.Text
		b.ZIndex = 14
		local stroke = Theme.textStroke(b, Theme.Styles.purple.stroke, 2)
		stroke.Enabled = false
		b.Parent = bar
		Anim.button(b, "tab")
		b.Activated:Connect(function()
			if activeTab ~= tab.name then
				selectTab(tab.name, true)
			end
		end)
		table.insert(buttons, b)
	end
	return buttons
end

local function buildPage(host: Frame, name: string): (ScrollingFrame, UIGridLayout)
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = name
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Size = UDim2.fromScale(1, 1)
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.ScrollBarThickness = 8
	scroll.ScrollBarImageColor3 = Theme.Color.Stroke
	scroll.ScrollBarImageTransparency = 0.3
	scroll.VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar
	scroll.ZIndex = 12
	scroll.Visible = false
	scroll.Parent = host
	Theme.padding(scroll, 8, 14, 8, 16) -- room for outlines, the BEST ribbon and bumps at the edges

	local grid = Instance.new("UIGridLayout")
	grid.CellPadding = UDim2.fromOffset(GAP, GAP)
	grid.CellSize = UDim2.new(0.5, -(GAP / 2 + 1), 0, CARD_HEIGHT)
	grid.FillDirection = Enum.FillDirection.Horizontal
	grid.FillDirectionMaxCells = 2
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Center
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = scroll
	return scroll, grid
end

-- Two columns when the card area is wide enough, one on narrow (portrait) screens.
local function fitColumns(area: GuiObject, panel: GuiObject)
	local function apply()
		-- AbsoluteSize includes the UI scale and the panel's pop animation: take both back out
		local pop = panel:FindFirstChild("AnimScale")
		local popScale = if pop and pop:IsA("UIScale") and pop.Scale > 0.05 then pop.Scale else 1
		local width = area.AbsoluteSize.X / math.max(Theme.Scale() * popScale, 0.01)
		local cols = if width >= TWO_COLUMNS_FROM then 2 else 1
		for _, page in ipairs(pageList) do
			if page.grid.FillDirectionMaxCells ~= cols then
				page.grid.FillDirectionMaxCells = cols
				page.grid.CellSize = UDim2.new(1 / cols, if cols == 2 then -(GAP / 2 + 1) else 0, 0, CARD_HEIGHT)
			end
		end
	end
	area:GetPropertyChangedSignal("AbsoluteSize"):Connect(apply)
	task.defer(apply)
end

-- ---------- state, open / close ----------

local function applyState(animate: boolean)
	if not lastState then
		return
	end
	local passes = if type(lastState.passes) == "table" then lastState.passes else {}
	for key, card in pairs(byKey.pass) do
		if passes[key] == true and not card.owned then
			setOwned(card, animate and loopsOn(card))
		end
	end
	for _, card in pairs(byKey.product) do
		refreshInfo(card, animate and loopsOn(card))
	end
end

local function onOpen()
	applyState(false) -- catch up quietly, then play the entrance
	isOpen = true
	local target = if focusCard and os.clock() - focusAt < FOCUS_SECONDS then focusCard else nil
	focusCard = nil
	selectTab(if target then tabOf(target) else activeTab, false) -- also starts the loops
	local page = pages[activeTab]
	if page then
		page.scroll.Position = UDim2.new()
		Anim.stagger(inners(page), 0.06)
	end
	if target then
		spotlight(target)
	end
end

local function onClose()
	isOpen = false
	for _, page in ipairs(pageList) do
		for _, card in ipairs(page.cards) do
			setLoops(card, false)
		end
	end
end

-- ---------- API ----------

function StoreUI.Init()
	Menu.AddButton("Store", "💎", "Store", "purple", 3)
	local panel, content = Menu.Panel("Store", "STORE", Vector2.new(780, 560), "purple", onOpen, onClose)

	local tabButtons = buildTabs(content)

	local host = Instance.new("Frame")
	host.Name = "Pages"
	host.BackgroundTransparency = 1
	host.ClipsDescendants = true
	host.Position = UDim2.fromOffset(0, TAB_HEIGHT + 10)
	host.Size = UDim2.new(1, 0, 1, -(TAB_HEIGHT + 10 + FOOTER_HEIGHT))
	host.ZIndex = 12
	host.Parent = content

	for i, tab in ipairs(TABS) do
		local scroll, grid = buildPage(host, tab.name)
		local page: Page = { name = tab.name, index = i, tab = tabButtons[i], scroll = scroll, grid = grid, cards = {} }
		pages[tab.name] = page
		table.insert(pageList, page)
		for j, key in ipairs(tab.order) do
			local def = tab.defs[key]
			if def then
				table.insert(page.cards, buildCard(page, tab.kind, key, def, j))
			else
				warn("[StoreUI] StoreConfig order lists " .. key .. " but there is no entry for it")
			end
		end
	end
	fitColumns(host, panel)

	local footer = Theme.label(content, "Prices in Robux. Purchases are final.", 14, Theme.Color.Muted, Theme.FontBody)
	footer.Name = "Footer"
	footer.AnchorPoint = Vector2.new(0.5, 1)
	footer.Position = UDim2.fromScale(0.5, 1)
	footer.Size = UDim2.new(1, 0, 0, FOOTER_HEIGHT - 2)
	footer.ZIndex = 12

	selectTab(activeTab, false)
	built = true
	applyState(false)

	-- grants (the HUD celebrates; this panel finishes its buttons)
	task.spawn(function()
		local celebrate = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Celebrate")
		if celebrate:IsA("RemoteEvent") then
			celebrate.OnClientEvent:Connect(onCelebrate)
		end
	end)
	-- Roblox's prompt closed without a purchase: stop waiting right away
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(who, passId, purchased)
		local card = if who == player then cardById("pass", passId) else nil
		if card and card.waiting and not purchased then
			stopWaiting(card)
		end
	end)
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, purchased)
		local card = if userId == player.UserId then cardById("product", productId) else nil
		if card and card.waiting and not purchased then
			stopWaiting(card)
		end
	end)
	-- the padlocked back row of your drawer sells the Extra Slots pass: open the Store right on it
	ProximityPromptService.PromptTriggered:Connect(function(prompt)
		if prompt.Name == "UnlockSlotsPrompt" then
			StoreUI.Focus("pass", "ExtraSlots")
		end
	end)
	-- Server Luck countdown (between States)
	local nextTick = 0
	RunService.Heartbeat:Connect(function()
		if not isOpen or os.clock() < nextTick then
			return
		end
		nextTick = os.clock() + 0.25
		for _, card in ipairs(luckCards) do
			refreshLuck(card)
		end
	end)
end

function StoreUI.SetState(state)
	if type(state) ~= "table" then
		return
	end
	lastState = state
	if built then
		applyState(isOpen)
	end
end

-- Opens the Store on one item and bounces it (kind "pass" | "product", a StoreConfig key).
function StoreUI.Focus(kind: string, key: string)
	local group = byKey[kind]
	local card = group and group[key]
	if not card then
		return
	end
	if isOpen then
		if activeTab ~= tabOf(card) then
			selectTab(tabOf(card), true)
		end
		spotlight(card)
	else
		focusCard = card
		focusAt = os.clock()
		Menu.Open("Store")
	end
end

return StoreUI
