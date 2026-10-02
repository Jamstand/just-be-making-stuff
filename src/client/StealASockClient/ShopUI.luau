-- ShopUI: the Item Shop - permanent upgrades bought with in-game cash (ShopConfig). A header with
-- your cash (rolling number) and income, then one card per upgrade: a swaying icon, name, what it
-- does, level pips, "now -> next" and a big price button - green with a shine when you can afford
-- it, grey when you can't (tapping it says how much is missing), gold MAX when maxed.
-- Buying asks the server (BuyUpgrade); the server checks the price and applies every effect.
--
-- Motion: on open the cards stagger in and each card's pips pop in one by one. A purchase fills
-- the new pip with a burst, bumps the card, flies coins from the cash header into the button and
-- pops "LEVEL n!" (confetti when it maxes out). Decorative loops (icon sway, shines) only run
-- while the panel is open; Anim honours Reduce motion for all of them.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = require(Shared:WaitForChild("Util"))
local ShopConfig = require(Shared:WaitForChild("Config"):WaitForChild("ShopConfig"))

local Theme = require(script.Parent:WaitForChild("Theme"))
local Anim = require(script.Parent:WaitForChild("Anim"))
local UISound = require(script.Parent:WaitForChild("UISound"))
local Menu = require(script.Parent:WaitForChild("Menu"))

local ShopUI = {}

local CARD_HEIGHT = 222
local GAP = 12 -- between cards
local TWO_COLUMNS_FROM = 600 -- card area width (reference px) that fits two columns
local HEADER_HEIGHT = 62
local CONFIRM_SECONDS = 3 -- a State older than our own purchase can't take a level back for this long
local REMOTE_TIMEOUT = 10 -- seconds before a button whose request never came back is usable again
local DESC_COLOR = Theme.Color.Text:Lerp(Theme.Color.Muted, 0.45)
local MUTED_HEX = "#" .. Theme.Color.Muted:ToHex()
local MONEY_HEX = "#" .. Theme.Color.Money:ToHex()

type Card = {
	key: string,
	def: any, -- ShopConfig.Upgrade
	slot: Frame,
	inner: Frame,
	icon: Frame,
	pips: { Frame },
	filled: { boolean },
	levelLine: TextLabel,
	button: TextButton,
	note: TextLabel,
	level: number,
	style: string,
	busy: boolean,
	buyToken: number,
	noteToken: number,
	confirmedAt: number,
}

local cardList = {} :: { Card }
local lastState: any = nil
local isOpen = false
local built = false
local cashLabel: TextLabel? = nil
local rateLabel: TextLabel? = nil
local coin: Frame? = nil

-- ---------- small helpers ----------

local function money(n: number): string
	return "$" .. Util.FormatCash(math.floor(n))
end

local function currentCash(): number
	return if lastState and type(lastState.cash) == "number" then lastState.cash else 0
end

local function escape(s: string): string
	local out = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
	return out
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

-- Pops a gui up from nothing after `delay` (pips appearing one by one). Reduced motion: just shows it.
local function popFromZero(gui: GuiObject, delay: number)
	local s = Anim.scale(gui)
	if Anim.Reduced then
		s.Scale = 1
		return
	end
	s.Scale = 0
	Anim.tween(s, 0.4, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, delay)
end

-- A ring and a few sparkles bursting out of `at` (the pip a purchase just filled).
local function burst(at: GuiObject, color: Color3)
	if Anim.Reduced then
		return
	end
	local ring = Instance.new("Frame")
	ring.Name = "Burst"
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.Size = UDim2.fromScale(1, 1)
	ring.BackgroundTransparency = 1
	ring.ZIndex = at.ZIndex + 3
	Theme.corner(ring, 10)
	local ringStroke = Theme.stroke(ring, color, 4)
	ring.Parent = at
	local grow = Anim.tween(ring, 0.5, { Size = UDim2.new(1, 30, 1, 30) }, Enum.EasingStyle.Quint)
	Anim.tween(ringStroke, 0.5, { Transparency = 1, Thickness = 1 }, Enum.EasingStyle.Quad)
	grow.Completed:Once(function()
		ring:Destroy()
	end)
	for i = 1, 6 do
		local star = Theme.label(at, "✦", 18, if i % 2 == 0 then Theme.Color.Gold else color)
		star.Name = "Sparkle"
		star.AnchorPoint = Vector2.new(0.5, 0.5)
		star.Position = UDim2.fromScale(0.5, 0.5)
		star.Size = UDim2.fromOffset(22, 22)
		star.ZIndex = at.ZIndex + 4
		local angle = (i / 6) * math.pi * 2 + math.random() * 0.5
		local dist = 30 + math.random() * 18
		local fly = Anim.tween(star, 0.6, {
			Position = UDim2.new(0.5, math.cos(angle) * dist, 0.5, math.sin(angle) * dist),
			Rotation = math.random(-120, 120),
			TextTransparency = 1,
		}, Enum.EasingStyle.Quint)
		fly.Completed:Once(function()
			star:Destroy()
		end)
	end
end

-- ---------- card state ----------

local function priceOf(card: Card): number?
	local nextLevel = card.def.levels[card.level + 1]
	return if nextLevel then nextLevel.price else nil
end

local function levelText(card: Card): string
	local levels = card.def.levels
	local level = card.level
	if level <= 0 then
		return string.format('<font color="%s">Base</font>  →  <font color="%s">%s</font>', MUTED_HEX, MONEY_HEX, escape(levels[1].label))
	elseif level >= #levels then
		return string.format('<font color="%s">MAX</font>  ·  %s', MUTED_HEX, escape(levels[#levels].label))
	end
	return string.format('%s  <font color="%s">→</font>  <font color="%s">%s</font>', escape(levels[level].label), MUTED_HEX, MONEY_HEX, escape(levels[level + 1].label))
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
	task.delay(seconds or 2.4, function()
		if card.noteToken == token then
			Anim.tween(note, 0.35, { TextTransparency = 1 }, Enum.EasingStyle.Quad)
		end
	end)
end

-- Fills the pips up to `level`; newly filled ones flash their colour in and bump.
local function setPips(card: Card, animate: boolean)
	for i, pip in ipairs(card.pips) do
		local filled = i <= card.level
		if filled ~= card.filled[i] then
			card.filled[i] = filled
			local color = if filled then card.def.color else Theme.Color.InsetDark
			if animate then
				Anim.tween(pip, 0.25, { BackgroundColor3 = color }, Enum.EasingStyle.Quad)
				if filled then
					Anim.bump(pip, 1.45)
				end
			else
				pip.BackgroundColor3 = color
			end
		end
	end
end

-- Price button: green + shine (affordable), grey (not), gold MAX (maxed). Leaves a busy button alone.
local function refreshButton(card: Card, animate: boolean)
	if card.busy then
		return
	end
	local button = card.button
	local price = priceOf(card)
	local style
	if not price then
		style = "gold"
		button.Text = "MAX"
	else
		style = if currentCash() >= price then "green" else "grey"
		button.Text = money(price)
	end
	if style ~= card.style then
		local was = card.style
		card.style = style
		Theme.restyle(button, style)
		if animate and style == "green" and was == "grey" then
			Anim.bump(button, 1.12) -- you can afford it now
		end
	end
	if style == "grey" then
		-- Theme.restyle only outlines white text; the grey style's off-white text needs it too
		for _, child in ipairs(button:GetChildren()) do
			if child:IsA("UIStroke") and child.ApplyStrokeMode == Enum.ApplyStrokeMode.Contextual then
				child.Enabled = true
			end
		end
	end
	setShine(button, isOpen and style ~= "grey", if style == "gold" then 4.5 else 2.6)
end

local function refreshCard(card: Card, animate: boolean)
	setPips(card, animate)
	card.levelLine.Text = levelText(card)
	refreshButton(card, animate)
end

local function anyAffordable(): boolean
	if not lastState then
		return false
	end
	for _, card in ipairs(cardList) do
		local price = priceOf(card)
		if price and currentCash() >= price then
			return true
		end
	end
	return false
end

local function updateBadge()
	if isOpen then
		Menu.SetBadge("Shop", nil)
	else
		Menu.SetBadge("Shop", if anyAffordable() then "!" else nil)
	end
end

local function updateHeader(animate: boolean)
	if not lastState then
		return
	end
	if cashLabel then
		Anim.countTo(cashLabel, currentCash(), money, if animate then nil else 0)
	end
	if rateLabel then
		local rate = if type(lastState.rate) == "number" then lastState.rate else 0
		rateLabel.Text = "+$" .. Util.FormatRate(rate) .. "/s from your drawer"
	end
end

-- ---------- buying ----------

local function buyRemote(): RemoteFunction?
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	local remote = folder and folder:FindFirstChild("BuyUpgrade")
	if remote and remote:IsA("RemoteFunction") then
		return remote
	end
	return nil
end

local function failed(card: Card, text: string)
	if isOpen then
		Anim.wiggle(card.button)
		UISound.Play("error")
	end
	showNote(card, text, Theme.Color.Bad, 2.8)
end

local function bought(card: Card, level: number)
	card.level = math.max(card.level, level)
	card.confirmedAt = os.clock()
	if not isOpen then
		card.busy = false
		refreshCard(card, false)
		return
	end
	setPips(card, true)
	local pip = card.pips[card.level]
	if pip then
		burst(pip, card.def.color)
	end
	card.levelLine.Text = levelText(card)
	Anim.bump(card.inner, 1.05)
	if coin then
		Anim.flyCoins(coin, card.button, 7)
	end
	local maxed = card.level >= #card.def.levels
	local above = Anim.centerOf(card.inner) - Vector2.new(0, 40 * Theme.Scale())
	Anim.numberPop(if maxed then "MAXED OUT!" else "LEVEL " .. card.level .. "!", above, card.def.color, 34)
	UISound.Play("buy")
	if maxed then
		Anim.confetti(Anim.centerOf(card.inner), 45)
		UISound.Play("confetti")
	end
	-- a short "✓" beat on the button; by then the State with the new cash has usually arrived
	card.button.Text = "✓"
	task.delay(0.7, function()
		card.busy = false
		refreshButton(card, true)
	end)
end

local function onBuy(card: Card)
	if card.busy then
		return
	end
	local price = priceOf(card)
	if not price then
		Anim.bump(card.button, 1.08)
		showNote(card, "Fully upgraded!", Theme.Color.Gold2)
		return
	end
	local cash = currentCash()
	if cash < price then
		Anim.wiggle(card.button)
		UISound.Play("error")
		showNote(card, "Need $" .. Util.FormatCash(math.ceil(price - cash)) .. " more", Theme.Color.Bad)
		return
	end
	local remote = buyRemote()
	if not remote then
		failed(card, "The shop is still opening - try again")
		return
	end
	card.busy = true
	card.buyToken += 1
	local token = card.buyToken
	card.button.Text = "• • •"
	setShine(card.button, false)
	task.delay(REMOTE_TIMEOUT, function()
		-- the server never answered: give the button back (a late answer is still shown)
		if card.busy and card.buyToken == token then
			card.busy = false
			refreshButton(card, false)
		end
	end)
	task.spawn(function()
		local ok, result = pcall(function()
			return remote:InvokeServer(card.key)
		end)
		if card.buyToken ~= token then
			return -- a newer tap owns the button now (the State still brings the level)
		end
		if ok and type(result) == "table" and result.ok == true then
			bought(card, if type(result.level) == "number" then result.level else card.level + 1)
			return
		end
		card.busy = false
		refreshButton(card, false)
		local err = if ok and type(result) == "table" and type(result.err) == "string" then result.err else "Couldn't buy that - try again"
		failed(card, err)
	end)
end

-- ---------- building ----------

local function buildPips(inner: Frame, count: number, y: number): { Frame }
	local row = Instance.new("Frame")
	row.Name = "Pips"
	row.BackgroundTransparency = 1
	row.Position = UDim2.fromOffset(12, y)
	row.Size = UDim2.new(1, -24, 0, 18)
	row.ZIndex = 13
	row.Parent = inner
	Theme.list(row, 6, true)
	local pips = {}
	for i = 1, count do
		local holder, pip = cell(row, i, "Pip" .. i)
		holder.Size = UDim2.new(1 / count, -math.ceil(6 * (count - 1) / count), 1, 0)
		pip.BackgroundColor3 = Theme.Color.InsetDark
		pip.ZIndex = 13
		Theme.corner(pip, 8)
		Theme.stroke(pip, Theme.Color.Stroke, 2)
		Theme.gloss(pip, 8)
		table.insert(pips, pip)
	end
	return pips
end

local function buildCard(parent: Instance, key: string, index: number): Card?
	local def = ShopConfig.Upgrades[key]
	if not def then
		warn("[ShopUI] ShopConfig.Order lists " .. key .. " but ShopConfig.Upgrades has no entry for it")
		return nil
	end
	local slot, inner = cell(parent, index, key)
	inner.BackgroundColor3 = Theme.Color.White
	Theme.corner(inner, 18)
	Theme.stroke(inner, Theme.Color.Stroke, 3)
	Theme.gradient(inner, Theme.Color.Inset, Theme.Color.Inset:Lerp(def.color, 0.18))

	local icon = Theme.icon(inner, def.icon, 64, def.color)
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromOffset(12 + 32, 10 + 32)
	icon.ZIndex = 13

	local name = Theme.label(inner, def.display, 24, Theme.Color.Text)
	name.Name = "Title"
	name.Position = UDim2.fromOffset(88, 8)
	name.Size = UDim2.new(1, -100, 0, 30)
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.ZIndex = 13
	fit(name, 24, 14)

	local desc = Theme.label(inner, def.desc, 14, DESC_COLOR, Theme.FontBody)
	desc.Name = "Desc"
	desc.Position = UDim2.fromOffset(88, 38)
	desc.Size = UDim2.new(1, -100, 0, 44)
	desc.TextXAlignment = Enum.TextXAlignment.Left
	desc.TextYAlignment = Enum.TextYAlignment.Top
	desc.TextWrapped = true
	desc.ZIndex = 13
	fit(desc, 14, 9)

	local pips = buildPips(inner, #def.levels, 88)

	local levelLine = Theme.label(inner, "", 15, Theme.Color.Text, Theme.FontBody)
	levelLine.Name = "Level"
	levelLine.RichText = true
	levelLine.Position = UDim2.fromOffset(12, 112)
	levelLine.Size = UDim2.new(1, -24, 0, 20)
	levelLine.ZIndex = 13
	fit(levelLine, 15, 9)

	-- 60 reference px tall: ~44 px on a phone
	local button = Theme.button(inner, "", "green", UDim2.new(1, -24, 0, 60), 28)
	button.Name = "Buy"
	button.AnchorPoint = Vector2.new(0.5, 0.5)
	button.Position = UDim2.new(0.5, 0, 0, 136 + 30)
	button.ZIndex = 13
	Anim.button(button, "click")

	local note = Theme.label(inner, "", 14, Theme.Color.Bad, Theme.FontBody)
	note.Name = "Note"
	note.AnchorPoint = Vector2.new(0.5, 0.5)
	note.Position = UDim2.new(0.5, 0, 0, 199 + 9)
	note.Size = UDim2.new(1, -24, 0, 18)
	note.TextTransparency = 1
	note.ZIndex = 13
	fit(note, 14, 9)

	local filled = {}
	for i = 1, #pips do
		filled[i] = false
	end
	local card: Card = {
		key = key,
		def = def,
		slot = slot,
		inner = inner,
		icon = icon,
		pips = pips,
		filled = filled,
		levelLine = levelLine,
		button = button,
		note = note,
		level = 0,
		style = "green",
		busy = false,
		buyToken = 0,
		noteToken = 0,
		confirmedAt = 0,
	}
	button.Activated:Connect(function()
		onBuy(card)
	end)
	refreshCard(card, false)
	return card
end

local function buildHeader(content: Frame)
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, HEADER_HEIGHT)
	header.ZIndex = 12
	header.Parent = content

	-- the concept's cash pill: tan candy, gold "$" coin, chunky white number
	local pill = Instance.new("Frame")
	pill.Name = "Cash"
	pill.Position = UDim2.fromOffset(4, 4)
	pill.Size = UDim2.fromOffset(236, 54)
	pill.ZIndex = 12
	Theme.candy(pill, "cream", 27, 3)
	local grad = pill:FindFirstChildOfClass("UIGradient")
	if grad then
		grad.Color = ColorSequence.new(Color3.fromRGB(222, 162, 98), Color3.fromRGB(188, 122, 64))
	end
	Theme.gloss(pill, 27)
	pill.Parent = header

	local c = Theme.icon(pill, "$", 44, Theme.Color.Gold)
	c.Name = "Coin"
	c.AnchorPoint = Vector2.new(0.5, 0.5)
	c.Position = UDim2.new(0, 8 + 22, 0.5, 0)
	c.ZIndex = 14 -- above the pill's gloss
	local glyph = c:FindFirstChild("Glyph")
	if glyph and glyph:IsA("TextLabel") then
		Theme.textStroke(glyph, Theme.Color.Gold2, 2)
	end
	coin = c

	local amount = Theme.label(pill, "$0", 30, Theme.Color.White)
	amount.Name = "Amount"
	amount.Position = UDim2.fromOffset(60, 0)
	amount.Size = UDim2.new(1, -70, 1, 0)
	amount.TextXAlignment = Enum.TextXAlignment.Left
	amount.ZIndex = 14
	fit(amount, 30, 14)
	Theme.textStroke(amount, Theme.Color.Ink, 2.5)
	cashLabel = amount

	local hint = Theme.label(header, "Upgrades are permanent!", 20, Theme.Color.Title)
	hint.Name = "Hint"
	hint.Position = UDim2.fromOffset(256, 6)
	hint.Size = UDim2.new(1, -260, 0, 26)
	hint.TextXAlignment = Enum.TextXAlignment.Left
	hint.ZIndex = 12
	fit(hint, 20, 12)

	local rate = Theme.label(header, "Earn cash with the socks in your drawer", 15, Theme.Color.Money, Theme.FontBody)
	rate.Name = "Rate"
	rate.Position = UDim2.fromOffset(256, 33)
	rate.Size = UDim2.new(1, -260, 0, 22)
	rate.TextXAlignment = Enum.TextXAlignment.Left
	rate.ZIndex = 12
	fit(rate, 15, 10)
	rateLabel = rate
end

-- Two columns when the card area is wide enough, one on narrow (portrait) screens.
local function fitColumns(area: GuiObject, grid: UIGridLayout, panel: GuiObject)
	local function apply()
		-- AbsoluteSize includes the UI scale and the panel's pop animation: take both back out
		local pop = panel:FindFirstChild("AnimScale")
		local popScale = if pop and pop:IsA("UIScale") and pop.Scale > 0.05 then pop.Scale else 1
		local width = area.AbsoluteSize.X / math.max(Theme.Scale() * popScale, 0.01)
		local cols = if width >= TWO_COLUMNS_FROM then 2 else 1
		if grid.FillDirectionMaxCells ~= cols then
			grid.FillDirectionMaxCells = cols
			grid.CellSize = UDim2.new(1 / cols, if cols == 2 then -(GAP / 2 + 1) else 0, 0, CARD_HEIGHT)
		end
	end
	area:GetPropertyChangedSignal("AbsoluteSize"):Connect(apply)
	task.defer(apply)
end

-- Cash, levels and affordability from the last State; `animate` plays the changes.
local function applyState(animate: boolean)
	if not lastState then
		return
	end
	updateHeader(animate)
	local upgrades = if type(lastState.upgrades) == "table" then lastState.upgrades else {}
	for _, card in ipairs(cardList) do
		local level = if type(upgrades[card.key]) == "number" then upgrades[card.key] else 0
		if level < card.level and os.clock() - card.confirmedAt < CONFIRM_SECONDS then
			level = card.level -- this State left the server before our purchase did
		end
		if level ~= card.level then
			local up = level > card.level
			card.level = level
			setPips(card, animate and up)
			card.levelLine.Text = levelText(card)
		end
		refreshButton(card, animate)
	end
end

-- ---------- open / close ----------

local function onOpen()
	isOpen = true
	Menu.SetBadge("Shop", nil)
	-- bring everything up to date without animating (this also starts the shines), then the entrance
	applyState(false)
	local inners = {} :: { GuiObject }
	for i, card in ipairs(cardList) do
		table.insert(inners, card.inner)
		local delay = (i - 1) * 0.07
		for j, pip in ipairs(card.pips) do
			popFromZero(pip, delay + 0.18 + j * 0.06)
		end
		Anim.sway(card.icon, 6, 2.2 + i * 0.17)
	end
	Anim.stagger(inners, 0.07)
end

local function onClose()
	isOpen = false
	for _, card in ipairs(cardList) do
		Anim.stop(card.icon, "sway")
		card.icon.Rotation = 0
		setShine(card.button, false)
	end
	updateBadge()
end

-- ---------- API ----------

function ShopUI.Init()
	Menu.AddButton("Shop", "🛒", "Shop", "green", 2)
	local panel, content = Menu.Panel("Shop", "ITEM SHOP", Vector2.new(740, 540), "green", onOpen, onClose)

	buildHeader(content)

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Cards"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Position = UDim2.fromOffset(0, HEADER_HEIGHT + 4)
	scroll.Size = UDim2.new(1, 0, 1, -(HEADER_HEIGHT + 4))
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.ScrollBarThickness = 8
	scroll.ScrollBarImageColor3 = Theme.Color.Stroke
	scroll.ScrollBarImageTransparency = 0.3
	scroll.VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar
	scroll.ZIndex = 12
	scroll.Parent = content
	Theme.padding(scroll, 8, 10, 8, 16) -- room for outlines and bumps at the edges

	local grid = Instance.new("UIGridLayout")
	grid.CellPadding = UDim2.fromOffset(GAP, GAP)
	grid.CellSize = UDim2.new(0.5, -(GAP / 2 + 1), 0, CARD_HEIGHT)
	grid.FillDirection = Enum.FillDirection.Horizontal
	grid.FillDirectionMaxCells = 2
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Center
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = scroll
	fitColumns(scroll, grid, panel)

	for i, key in ipairs(ShopConfig.Order) do
		local card = buildCard(scroll, key, i)
		if card then
			table.insert(cardList, card)
		end
	end
	built = true
	applyState(false)
	updateBadge()
end

function ShopUI.SetState(state)
	if type(state) ~= "table" then
		return
	end
	lastState = state
	if not built then
		return
	end
	applyState(isOpen)
	updateBadge()
end

return ShopUI
