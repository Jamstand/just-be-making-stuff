-- ShopUI: the Item Shop, two tabs under your cash (a segmented control whose highlight springs
-- across, like the Store's):
--  * Upgrades - permanent upgrades bought with in-game cash (ShopConfig). One card per upgrade: a
--    swaying icon, name, what it does, level pips, "now -> next" and a big price button - green
--    with a shine when you can afford it, grey when you can't (tapping it says how much is
--    missing), gold MAX when maxed. The Towel Snap card also shows the towel look its next level
--    brings (the 3D towel, or a drawn one in the look's colours, and the look's name).
--  * Items - the item bar's items (ItemConfig, all but the towel everyone has). One card per item:
--    its 3D model, name, what it does and its cooldown. Locked: a cash button (BuyItem; the same
--    affordable / can't-afford behaviour as the upgrades) and a Robux shortcut (StorePurchase
--    "product", the item's one-time developer product, price from StoreConfig). Unlocked: "Add to
--    bar" / "In bar ✓", which opens a picker of the LoadoutSize bar slots (SetLoadout; picking a
--    slot another item is in swaps them, "Take it out" empties its slot).
-- The server checks every price and applies every effect; the client only asks.
--
-- Motion: on open the cards stagger in (upgrade pips pop in one by one); switching tabs glides the
-- new page in from its side. A cash purchase flies coins from the cash pill into the card and pops
-- "LEVEL n!" / "UNLOCKED!"; the HUD shows the big item-unlock card (Celebrate "item"). Decorative
-- loops (icon sways, pulses, shines) only run for the page on screen; Anim honours Reduce motion.
-- ShopUI.OpenItems() opens the shop on the Items tab (the item bar's empty "+" slots).
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Util = require(Shared:WaitForChild("Util"))
local ShopConfig = require(Config:WaitForChild("ShopConfig"))
local ItemConfig = require(Config:WaitForChild("ItemConfig"))
local StoreConfig = require(Config:WaitForChild("StoreConfig"))

local Theme = require(script.Parent:WaitForChild("Theme"))
local Anim = require(script.Parent:WaitForChild("Anim"))
local UISound = require(script.Parent:WaitForChild("UISound"))
local Menu = require(script.Parent:WaitForChild("Menu"))

-- 3D item pictures: optional (a missing file must not hang the shop; cards then show emoji)
local ItemIcon = nil
do
	local module = script.Parent:WaitForChild("ItemIcon", 5)
	local ok, result = pcall(function()
		return if module then require(module) else nil
	end)
	if ok then
		ItemIcon = result
	else
		warn("[ShopUI] ItemIcon failed to load: " .. tostring(result))
	end
end

local ShopUI = {}

local CARD_HEIGHT = 222
local GAP = 12 -- between cards
local TWO_COLUMNS_FROM = 600 -- card area width (reference px) that fits two columns
local PILL_ROW = 66 -- the cash pill's row
local TAB_HEIGHT = 62 -- the tabs (62 reference px: 44 px on a phone)
local TAB_MAX_W = 420
local WIDE_HEADER_FROM = 560 -- content width (reference px) with the tabs beside the cash pill
local HINT_HEIGHT = 24 -- the line under the header
local BUTTON_H = 62 -- card buttons (62 x 0.72 = 44.6 px on a phone)
local CONFIRM_SECONDS = 3 -- a State older than our own purchase can't take a level back for this long
local REMOTE_TIMEOUT = 10 -- seconds before a button whose request never came back is usable again
local WAIT_SECONDS = 20 -- longest a Robux button waits for a prompted purchase to be granted
local PICKER_W = 420
local PICKER_SLOT = 96
local DESC_COLOR = Theme.Color.Text:Lerp(Theme.Color.Muted, 0.45)
local MUTED_HEX = "#" .. Theme.Color.Muted:ToHex()
local MONEY_HEX = "#" .. Theme.Color.Money:ToHex()
local TITLE_HEX = "#" .. Theme.Color.Title:ToHex()

local TABS = {
	{ name = "Upgrades", label = "🔧 Upgrades" },
	{ name = "Items", label = "🎒 Items" },
}

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

type ItemCard = {
	key: string,
	def: any, -- ItemConfig.Item
	product: any?, -- StoreConfig.Product: the Robux unlock
	slot: Frame,
	inner: Frame,
	stage: Frame, -- the halo the picture sits on
	badge: TextLabel, -- 🔒 / ✓
	info: TextLabel,
	cash: TextButton,
	robux: TextButton?,
	barButton: TextButton,
	note: TextLabel,
	unlocked: boolean,
	inBar: number?, -- the bar slot it's in
	style: string, -- the cash button's style
	barStyle: string,
	busy: boolean,
	buyToken: number,
	noteToken: number,
	confirmedAt: number,
	waiting: boolean,
	waitToken: number,
}

type Page = {
	name: string,
	index: number,
	tab: TextButton,
	dot: Frame,
	scroll: ScrollingFrame,
	grid: UIGridLayout,
}

local player = Players.LocalPlayer
local cardList = {} :: { Card }
local itemCards = {} :: { ItemCard }
local itemByKey = {} :: { [string]: ItemCard }
local pages = {} :: { [string]: Page }
local pageList = {} :: { Page }
local activeTab = TABS[1].name
local highlight: Frame? = nil
local lastState: any = nil
local isOpen = false
local built = false
local cashLabel: TextLabel? = nil
local hintLabel: TextLabel? = nil
local coin: Frame? = nil
local towelPreview: { holder: Frame, icon: any?, caption: TextLabel, look: string? }? = nil
local pendingLoadout: { string }? = nil -- our own SetLoadout, until the State catches up
local pendingAt = 0

-- the bar slot picker (an overlay over the shop)
local picker: Frame? = nil
local pickerTitle: TextLabel
local pickerNote: TextLabel
local pickerRemove: TextButton
local pickerSlots = {} :: { { button: TextButton, icon: any?, glyph: TextLabel, caption: TextLabel } }
local pickerCard: ItemCard? = nil
local pickerBusy = false

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

-- Theme.restyle only outlines white text; the grey style's off-white text needs it too.
local function outlineGrey(button: TextButton)
	local holders = { button } :: { Instance }
	local label = button:FindFirstChild("Label")
	if label then
		table.insert(holders, label)
	end
	for _, holder in ipairs(holders) do
		for _, child in ipairs(holder:GetChildren()) do
			if child:IsA("UIStroke") and child.ApplyStrokeMode == Enum.ApplyStrokeMode.Contextual then
				child.Enabled = true
			end
		end
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

-- A ring and a few sparkles bursting out of `at` (the pip a purchase just filled, an unlocked item).
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

-- A note line under a card's buttons that fades in, bumps and fades away again.
local function flashNote(owner: { noteToken: number }, note: TextLabel, text: string, color: Color3, seconds: number?)
	owner.noteToken += 1
	local token = owner.noteToken
	note.Text = text
	note.TextColor3 = color
	note.TextTransparency = 1
	Anim.tween(note, 0.15, { TextTransparency = 0 }, Enum.EasingStyle.Quad)
	Anim.bump(note, 1.12)
	task.delay(seconds or 2.4, function()
		if owner.noteToken == token then
			Anim.tween(note, 0.35, { TextTransparency = 1 }, Enum.EasingStyle.Quad)
		end
	end)
end

local function remoteFn(name: string): RemoteFunction?
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	local remote = folder and folder:FindFirstChild(name)
	if remote and remote:IsA("RemoteFunction") then
		return remote
	end
	return nil
end

local function upgradesOn(): boolean
	return isOpen and activeTab == "Upgrades"
end

local function itemsOn(): boolean
	return isOpen and activeTab == "Items"
end

-- The bar's loadout: our own pick until the State has caught up, else the State's.
local function currentLoadout(): { string }
	local out = {}
	local source = if pendingLoadout and os.clock() - pendingAt < CONFIRM_SECONDS then pendingLoadout else (if lastState and type(lastState.loadout) == "table" then lastState.loadout else {})
	for i = 1, ItemConfig.LoadoutSize do
		local key = source[i]
		out[i] = if type(key) == "string" then key else ""
	end
	return out
end

-- ---------- upgrade cards ----------

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
	flashNote(card, card.note, text, color, seconds)
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
		outlineGrey(button)
	end
	setShine(button, upgradesOn() and style ~= "grey", if style == "gold" then 4.5 else 2.6)
end

-- The Towel Snap card's preview: the look the next level brings (the Royal Towel pass keeps Royal).
local function refreshTowelPreview(animate: boolean)
	local preview = towelPreview
	local towel = nil
	for _, card in ipairs(cardList) do
		if card.key == "Towel" then
			towel = card
		end
	end
	if not preview or not towel then
		return
	end
	local looks = ItemConfig.TowelLooks
	local look, caption
	if lastState and lastState.towelLook == ItemConfig.TowelRoyal then
		look, caption = ItemConfig.TowelRoyal, "Yours: "
	elseif towel.level + 2 <= #looks then
		look, caption = looks[towel.level + 2], "Next: "
	else
		look, caption = looks[#looks], "Max: "
	end
	preview.caption.Text = caption .. (if ItemIcon then ItemIcon.LookName(look) else look)
	if look ~= preview.look then
		preview.look = look
		if preview.icon then
			preview.icon:Set("Towel", look)
		end
		if animate then
			Anim.bump(preview.holder, 1.2)
			burst(preview.holder, Theme.Color.Gold)
		end
	end
end

local function refreshCard(card: Card, animate: boolean)
	setPips(card, animate)
	card.levelLine.Text = levelText(card)
	refreshButton(card, animate)
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
		refreshTowelPreview(false)
		return
	end
	setPips(card, true)
	local pip = card.pips[card.level]
	if pip then
		burst(pip, card.def.color)
	end
	card.levelLine.Text = levelText(card)
	refreshTowelPreview(true)
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
	local remote = remoteFn("BuyUpgrade")
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

-- The Towel Snap card's corner: the towel look its next level brings, and its name.
local function buildTowelPreview(inner: Frame)
	local holder = Instance.new("Frame")
	holder.Name = "TowelLook"
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.new(1, -12 - 34, 0, 8 + 32)
	holder.Size = UDim2.fromOffset(64, 64)
	holder.BackgroundColor3 = Theme.Color.White
	holder.BackgroundTransparency = 0.35
	holder.BorderSizePixel = 0
	holder.ZIndex = 13
	Theme.corner(holder, UDim.new(0.5, 0))
	Theme.stroke(holder, Theme.Color.Gold2, 2.5)
	holder.Parent = inner
	local icon = if ItemIcon then ItemIcon.new(holder) else nil
	if icon then
		icon.Frame.Size = UDim2.fromScale(0.92, 0.92)
	else
		local glyph = Theme.label(holder, ItemConfig.Items.Towel.icon, 30, Theme.Color.White)
		glyph.Size = UDim2.fromScale(1, 1)
	end
	local caption = Theme.label(inner, "", 12, Theme.Color.Gold2, Theme.FontBody)
	caption.Name = "TowelLookName"
	caption.AnchorPoint = Vector2.new(0.5, 0)
	caption.Position = UDim2.new(1, -12 - 34, 0, 74)
	caption.Size = UDim2.fromOffset(92, 14)
	caption.ZIndex = 13
	fit(caption, 12, 8)
	towelPreview = { holder = holder, icon = icon, caption = caption, look = nil }
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

	-- the Towel Snap card keeps its top-right corner for the next towel look
	local textRight = if key == "Towel" then 100 + 84 else 100

	local name = Theme.label(inner, def.display, 24, Theme.Color.Text)
	name.Name = "Title"
	name.Position = UDim2.fromOffset(88, 8)
	name.Size = UDim2.new(1, -textRight, 0, 30)
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.ZIndex = 13
	fit(name, 24, 14)

	local desc = Theme.label(inner, def.desc, 14, DESC_COLOR, Theme.FontBody)
	desc.Name = "Desc"
	desc.Position = UDim2.fromOffset(88, 38)
	desc.Size = UDim2.new(1, -textRight, 0, 44)
	desc.TextXAlignment = Enum.TextXAlignment.Left
	desc.TextYAlignment = Enum.TextYAlignment.Top
	desc.TextWrapped = true
	desc.ZIndex = 13
	fit(desc, 14, 9)

	if key == "Towel" then
		buildTowelPreview(inner)
	end

	local pips = buildPips(inner, #def.levels, 90)

	local levelLine = Theme.label(inner, "", 15, Theme.Color.Text, Theme.FontBody)
	levelLine.Name = "Level"
	levelLine.RichText = true
	levelLine.Position = UDim2.fromOffset(12, 112)
	levelLine.Size = UDim2.new(1, -24, 0, 20)
	levelLine.ZIndex = 13
	fit(levelLine, 15, 9)

	local button = Theme.button(inner, "", "green", UDim2.new(1, -24, 0, BUTTON_H), 28)
	button.Name = "Buy"
	button.AnchorPoint = Vector2.new(0.5, 0.5)
	button.Position = UDim2.new(0.5, 0, 0, 135 + BUTTON_H / 2)
	button.ZIndex = 13
	Anim.button(button, "click")

	local note = Theme.label(inner, "", 14, Theme.Color.Bad, Theme.FontBody)
	note.Name = "Note"
	note.AnchorPoint = Vector2.new(0.5, 0.5)
	note.Position = UDim2.new(0.5, 0, 0, 200 + 9)
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

-- ---------- item cards ----------

local function itemNote(card: ItemCard, text: string, color: Color3, seconds: number?)
	flashNote(card, card.note, text, color, seconds)
end

local function itemFailed(card: ItemCard, button: GuiObject, text: string)
	if isOpen then
		Anim.wiggle(button)
		UISound.Play("error")
	end
	itemNote(card, text, Theme.Color.Bad, 2.8)
end

local function cooldownText(card: ItemCard): string
	return "⏱ " .. tostring(card.def.cooldown) .. "s cooldown"
end

-- Buttons and badge for the card's state: locked (cash + Robux) or unlocked (Add to bar / In bar).
local function refreshItemCard(card: ItemCard, animate: boolean)
	local loadout = currentLoadout()
	local at = table.find(loadout, card.key)
	card.inBar = at
	card.info.Text = cooldownText(card) .. (if card.unlocked and at then "  ·  in your bar" else "")
	if card.unlocked then
		card.cash.Visible = false
		if card.robux then
			card.robux.Visible = false
		end
		card.barButton.Visible = true
		local style = if at then "cream" else "blue"
		card.barButton.Text = if at then "In bar ✓" else "Add to bar"
		if style ~= card.barStyle then
			card.barStyle = style
			Theme.restyle(card.barButton, style)
			if animate then
				Anim.bump(card.barButton, 1.08)
			end
		end
		setShine(card.cash, false)
		return
	end
	card.barButton.Visible = false
	card.cash.Visible = true
	if card.robux then
		card.robux.Visible = true
	end
	if card.busy then
		return
	end
	local style = if currentCash() >= card.def.price then "green" else "grey"
	card.cash.Text = money(card.def.price)
	if style ~= card.style then
		local was = card.style
		card.style = style
		Theme.restyle(card.cash, style)
		if animate and style == "green" and was == "grey" then
			Anim.bump(card.cash, 1.12)
		end
	end
	if style == "grey" then
		outlineGrey(card.cash)
	end
	setShine(card.cash, itemsOn() and style == "green", 2.6)
	if card.robux and not card.waiting then
		card.robux.Text = if card.product then Theme.robux(card.product.price) else ""
	end
end

local function setUnlocked(card: ItemCard, on: boolean, animate: boolean)
	if card.unlocked == on then
		return
	end
	card.unlocked = on
	card.badge.Text = if on then "✓" else "🔒"
	card.badge.TextColor3 = if on then Theme.Color.Money else Theme.Color.Text
	if on then
		card.waiting = false
		card.waitToken += 1
	end
	refreshItemCard(card, false)
	if animate and on then
		Anim.popIn(card.barButton)
		Anim.bump(card.inner, 1.05)
		Anim.bump(card.badge, 1.5)
		burst(card.stage, card.def.color)
	end
end

local function stopWaiting(card: ItemCard)
	if not card.waiting then
		return
	end
	card.waiting = false
	card.waitToken += 1
	local robux = card.robux
	if robux then
		setShine(robux, false)
		Theme.restyle(robux, "purple")
	end
	refreshItemCard(card, false)
end

-- Roblox's purchase prompt is up: a blue "Waiting..." Robux button with a quick shimmer until the
-- unlock arrives (Celebrate / State), the prompt closes without a purchase, or WAIT_SECONDS.
local function startWaiting(card: ItemCard)
	local robux = card.robux
	if not robux then
		return
	end
	card.waiting = true
	card.waitToken += 1
	local token = card.waitToken
	Theme.restyle(robux, "blue")
	Anim.shine(robux, 0.2)
	task.spawn(function()
		local dots = 0
		while card.waiting and card.waitToken == token do
			dots = dots % 3 + 1
			robux.Text = "Waiting" .. string.rep(".", dots)
			task.wait(0.4)
		end
	end)
	task.delay(WAIT_SECONDS, function()
		if card.waiting and card.waitToken == token then
			stopWaiting(card)
		end
	end)
end

local function itemBought(card: ItemCard)
	card.confirmedAt = os.clock()
	local open = itemsOn()
	setUnlocked(card, true, open)
	if not open then
		return
	end
	if coin then
		Anim.flyCoins(coin, card.stage, 7)
	end
	local above = Anim.centerOf(card.inner) - Vector2.new(0, 40 * Theme.Scale())
	Anim.numberPop("UNLOCKED!", above, card.def.color, 34)
	UISound.Play("buy")
end

-- Cash unlock (BuyItem). Same rules as the upgrade buttons.
local function onBuyItem(card: ItemCard)
	if card.busy or card.unlocked then
		return
	end
	local price = card.def.price
	local cash = currentCash()
	if cash < price then
		Anim.wiggle(card.cash)
		UISound.Play("error")
		itemNote(card, "Need $" .. Util.FormatCash(math.ceil(price - cash)) .. " more", Theme.Color.Bad)
		return
	end
	local remote = remoteFn("BuyItem")
	if not remote then
		itemFailed(card, card.cash, "The shop is still opening - try again")
		return
	end
	card.busy = true
	card.buyToken += 1
	local token = card.buyToken
	card.cash.Text = "• • •"
	setShine(card.cash, false)
	task.delay(REMOTE_TIMEOUT, function()
		if card.busy and card.buyToken == token then
			card.busy = false
			refreshItemCard(card, false)
		end
	end)
	task.spawn(function()
		local ok, result = pcall(function()
			return remote:InvokeServer(card.key)
		end)
		if card.buyToken ~= token then
			return
		end
		card.busy = false
		if ok and type(result) == "table" and result.ok == true then
			itemBought(card)
			return
		end
		refreshItemCard(card, false)
		itemFailed(card, card.cash, if ok and type(result) == "table" and type(result.err) == "string" then result.err else "Couldn't buy that - try again")
	end)
end

-- Robux unlock: the item's one-time developer product, through the Store's StorePurchase. The
-- unlock itself arrives later (Celebrate "item" + the State).
local function onRobux(card: ItemCard)
	local robux = card.robux
	if not robux or not card.product or card.busy or card.waiting or card.unlocked then
		return
	end
	local remote = remoteFn("StorePurchase")
	if not remote then
		itemFailed(card, robux, "The store is still opening - try again")
		return
	end
	card.busy = true
	card.buyToken += 1
	local token = card.buyToken
	robux.Text = "• • •"
	task.delay(REMOTE_TIMEOUT, function()
		if card.busy and card.buyToken == token then
			card.busy = false
			refreshItemCard(card, false)
		end
	end)
	task.spawn(function()
		local ok, result = pcall(function()
			return remote:InvokeServer("product", card.product.key)
		end)
		if card.buyToken ~= token then
			return
		end
		card.busy = false
		if not ok or type(result) ~= "table" then
			refreshItemCard(card, false)
			itemFailed(card, robux, "Couldn't reach the store - try again")
			return
		end
		if result.ok ~= true then
			refreshItemCard(card, false)
			itemFailed(card, robux, if type(result.err) == "string" then result.err else "Not available right now")
			return
		end
		if result.prompted == true and not card.unlocked then
			startWaiting(card)
			return
		end
		refreshItemCard(card, false)
		if result.simulated == true then
			itemNote(card, "Studio test purchase", DESC_COLOR, 3)
		elseif type(result.msg) == "string" then
			itemNote(card, result.msg, Theme.Color.Money, 3)
		end
	end)
end

-- ---------- the bar slot picker ----------

local function pickerSetBusy(on: boolean)
	pickerBusy = on
	if on then
		pickerNote.Text = "Saving your bar..."
		pickerNote.TextColor3 = DESC_COLOR
	end
end

local function fillPicker(card: ItemCard)
	local loadout = currentLoadout()
	pickerTitle.Text = "Where does " .. card.def.display .. " go?"
	for i, s in ipairs(pickerSlots) do
		local key = loadout[i] or ""
		local item = if key ~= "" then ItemConfig.Items[key] else nil
		local mine = key == card.key
		if s.icon then
			s.icon:Set(if item then key else nil)
		end
		s.glyph.Visible = item == nil
		s.caption.Text = if item then item.display else "Empty"
		s.caption.TextColor3 = if mine then Theme.Color.Money else Theme.Color.Text
		Theme.restyle(s.button, if mine then "gold" else (if item then "cream" else "grey"))
		s.button.Text = ""
	end
	pickerRemove.Visible = table.find(loadout, card.key) ~= nil
	pickerNote.Text = "Tap a slot. An item already there swaps places."
	pickerNote.TextColor3 = DESC_COLOR
	local frame = picker :: Frame
	frame.Size = UDim2.new(0.94, 0, 0, if pickerRemove.Visible then 300 else 226)
end

-- Sends the new loadout; on success closes the picker and updates the card at once.
local function sendLoadout(card: ItemCard, loadout: { string }, from: GuiObject, doneText: string)
	if pickerBusy then
		return
	end
	local remote = remoteFn("SetLoadout")
	if not remote then
		Anim.wiggle(from)
		UISound.Play("error")
		pickerNote.Text = "The shop is still opening - try again"
		pickerNote.TextColor3 = Theme.Color.Bad
		return
	end
	pickerSetBusy(true)
	local done = false
	task.delay(REMOTE_TIMEOUT, function()
		if not done then
			done = true
			pickerSetBusy(false)
		end
	end)
	task.spawn(function()
		local ok, result = pcall(function()
			return remote:InvokeServer(loadout)
		end)
		if done then
			return
		end
		done = true
		pickerSetBusy(false)
		if ok and type(result) == "table" and result.ok == true then
			pendingLoadout = loadout
			pendingAt = os.clock()
			UISound.Play("pop")
			if pickerCard == card then
				Menu.HideOverlay()
			end
			for _, c in ipairs(itemCards) do
				refreshItemCard(c, true)
			end
			Anim.bump(card.inner, 1.05)
			itemNote(card, doneText, Theme.Color.Money, 2.6)
			return
		end
		Anim.wiggle(from)
		UISound.Play("error")
		pickerNote.Text = if ok and type(result) == "table" and type(result.err) == "string" then result.err else "Couldn't change your bar - try again"
		pickerNote.TextColor3 = Theme.Color.Bad
	end)
end

local function pickSlot(index: number)
	local card = pickerCard
	if not card or pickerBusy then
		return
	end
	local loadout = currentLoadout()
	local from = table.find(loadout, card.key)
	if from == index then
		Menu.HideOverlay() -- it's already there
		return
	end
	if from then
		loadout[from] = loadout[index] -- swap with whatever was in that slot
	end
	loadout[index] = card.key
	sendLoadout(card, loadout, pickerSlots[index].button, "In your bar ✓")
end

local function removeFromBar()
	local card = pickerCard
	if not card or pickerBusy then
		return
	end
	local loadout = currentLoadout()
	local at = table.find(loadout, card.key)
	if not at then
		Menu.HideOverlay()
		return
	end
	loadout[at] = ""
	sendLoadout(card, loadout, pickerRemove, "Taken out of your bar")
end

local function buildPicker()
	local frame = Instance.new("Frame")
	frame.Name = "BarPicker"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.new(0.94, 0, 0, 300)
	frame.ZIndex = 41
	frame.Visible = false
	frame.Active = true -- taps on blank parts stop here instead of closing it
	Theme.candy(frame, "cream", 22, 4)
	local maxSize = Instance.new("UISizeConstraint")
	maxSize.MaxSize = Vector2.new(PICKER_W, 400)
	maxSize.Parent = frame
	frame.Parent = Menu.Layer()

	local close = Theme.closeButton(frame)
	close.Size = UDim2.fromOffset(62, 62) -- a full touch target (44 px on a phone)
	Anim.button(close, "close")
	close.Activated:Connect(function()
		Menu.HideOverlay()
	end)

	pickerTitle = Theme.label(frame, "", 24, Theme.Color.Title)
	pickerTitle.Name = "Title"
	pickerTitle.Position = UDim2.fromOffset(40, 14)
	pickerTitle.Size = UDim2.new(1, -80, 0, 32)
	fit(pickerTitle, 24, 14)

	local row = Instance.new("Frame")
	row.Name = "Slots"
	row.BackgroundTransparency = 1
	row.Position = UDim2.fromOffset(16, 56)
	row.Size = UDim2.new(1, -32, 0, PICKER_SLOT + 26)
	row.Parent = frame
	local n = ItemConfig.LoadoutSize
	for i = 1, n do
		local holder = Instance.new("Frame")
		holder.Name = "Slot" .. i
		holder.BackgroundTransparency = 1
		holder.AnchorPoint = Vector2.new(0.5, 0)
		holder.Position = UDim2.new((i - 0.5) / n, 0, 0, 0)
		holder.Size = UDim2.new(1 / n, -10, 1, 0)
		holder.Parent = row
		local button = Theme.button(holder, "", "cream", UDim2.new(1, 0, 0, PICKER_SLOT), 20)
		button.Name = "Pick"
		local square = Instance.new("UIAspectRatioConstraint") -- square tiles; narrow screens shrink them
		square.AspectRatio = 1
		square.Parent = button
		button.AnchorPoint = Vector2.new(0.5, 0)
		button.Position = UDim2.fromScale(0.5, 0)
		local picture = Instance.new("Frame")
		picture.Name = "Picture"
		picture.BackgroundTransparency = 1
		picture.AnchorPoint = Vector2.new(0.5, 0.5)
		picture.Position = UDim2.fromScale(0.5, 0.5)
		picture.Size = UDim2.fromScale(0.78, 0.78)
		picture.ZIndex = 5
		picture.Parent = button
		local icon = if ItemIcon then ItemIcon.new(picture) else nil
		local glyph = Theme.label(picture, "+", 40, Theme.Color.White)
		glyph.Name = "Plus"
		glyph.Size = UDim2.fromScale(1, 1)
		glyph.ZIndex = 6
		local key = Theme.label(button, tostring(i + 1), 15, Theme.Color.White)
		key.Name = "Key"
		key.AnchorPoint = Vector2.new(0, 0)
		key.Position = UDim2.fromOffset(6, 4)
		key.Size = UDim2.fromOffset(20, 20)
		key.ZIndex = 7
		key.Visible = not Theme.IsTouch
		Theme.textStroke(key, Theme.Color.Ink, 2)
		local caption = Theme.label(holder, "", 15, Theme.Color.Text, Theme.FontBody)
		caption.Name = "Caption"
		caption.AnchorPoint = Vector2.new(0.5, 1)
		caption.Position = UDim2.fromScale(0.5, 1)
		caption.Size = UDim2.new(1, 0, 0, 20)
		fit(caption, 15, 9)
		Anim.button(button, "click")
		button.Activated:Connect(function()
			pickSlot(i)
		end)
		table.insert(pickerSlots, { button = button, icon = icon, glyph = glyph, caption = caption })
	end

	pickerNote = Theme.label(frame, "", 14, DESC_COLOR, Theme.FontBody)
	pickerNote.Name = "Note"
	pickerNote.Position = UDim2.fromOffset(20, 56 + PICKER_SLOT + 32)
	pickerNote.Size = UDim2.new(1, -40, 0, 20)
	fit(pickerNote, 14, 9)

	pickerRemove = Theme.button(frame, "Take it out of the bar", "red", UDim2.new(1, -48, 0, BUTTON_H), 22)
	pickerRemove.Name = "Remove"
	pickerRemove.AnchorPoint = Vector2.new(0.5, 1)
	pickerRemove.Position = UDim2.new(0.5, 0, 1, -18)
	Anim.button(pickerRemove, "click")
	pickerRemove.Activated:Connect(removeFromBar)

	picker = frame
end

local function openPicker(card: ItemCard)
	if not card.unlocked then
		return
	end
	if not picker then
		buildPicker()
	end
	pickerCard = card
	fillPicker(card)
	Menu.ShowOverlay(picker :: Frame, function()
		pickerCard = nil
	end)
end

local function buildItemCard(parent: Instance, key: string, index: number): ItemCard?
	local def = ItemConfig.Items[key]
	if not def then
		warn("[ShopUI] ItemConfig.Order lists " .. key .. " but ItemConfig.Items has no entry for it")
		return nil
	end
	local product = if def.product then StoreConfig.Products[def.product] else nil
	local slot, inner = cell(parent, index, key)
	inner.BackgroundColor3 = Theme.Color.White
	Theme.corner(inner, 18)
	Theme.stroke(inner, Theme.Color.Stroke, 3)
	Theme.gradient(inner, Theme.Color.Inset, Theme.Color.Inset:Lerp(def.color, 0.22))

	-- the 3D item on a soft halo in its colour, a padlock / tick on the corner
	local stage = Instance.new("Frame")
	stage.Name = "Stage"
	stage.AnchorPoint = Vector2.new(0.5, 0.5)
	stage.Position = UDim2.fromOffset(12 + 44, 12 + 44)
	stage.Size = UDim2.fromOffset(88, 88)
	stage.BackgroundColor3 = def.color
	stage.BackgroundTransparency = 0.55
	stage.BorderSizePixel = 0
	stage.ZIndex = 13
	Theme.corner(stage, UDim.new(0.5, 0))
	Theme.stroke(stage, def.color:Lerp(Theme.Color.Stroke, 0.35), 3, 0.2)
	stage.Parent = inner
	if ItemIcon then
		local icon = ItemIcon.new(stage, { key = key })
		icon.Frame.Size = UDim2.fromScale(0.92, 0.92)
	else
		local glyph = Theme.label(stage, def.icon, 46, Theme.Color.White)
		glyph.Size = UDim2.fromScale(1, 1)
	end
	local badge = Theme.label(inner, "🔒", 16, Theme.Color.Text)
	badge.Name = "Badge"
	badge.AnchorPoint = Vector2.new(0.5, 0.5)
	badge.Position = UDim2.fromOffset(12 + 80, 12 + 80)
	badge.Size = UDim2.fromOffset(30, 30)
	badge.BackgroundColor3 = Theme.Color.Inset
	badge.BackgroundTransparency = 0
	badge.ZIndex = 15
	Theme.corner(badge, UDim.new(0.5, 0))
	Theme.stroke(badge, Theme.Color.Stroke, 2)

	local name = Theme.label(inner, def.display, 24, Theme.Color.Text)
	name.Name = "Title"
	name.Position = UDim2.fromOffset(112, 10)
	name.Size = UDim2.new(1, -124, 0, 30)
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.ZIndex = 13
	fit(name, 24, 14)

	local desc = Theme.label(inner, def.desc, 14, DESC_COLOR, Theme.FontBody)
	desc.Name = "Desc"
	desc.Position = UDim2.fromOffset(112, 40)
	desc.Size = UDim2.new(1, -124, 0, 50)
	desc.TextXAlignment = Enum.TextXAlignment.Left
	desc.TextYAlignment = Enum.TextYAlignment.Top
	desc.TextWrapped = true
	desc.ZIndex = 13
	fit(desc, 14, 9)

	local info = Theme.label(inner, "", 14, Theme.Color.Title, Theme.FontBody)
	info.Name = "Info"
	info.Position = UDim2.fromOffset(112, 92)
	info.Size = UDim2.new(1, -124, 0, 22)
	info.TextXAlignment = Enum.TextXAlignment.Left
	info.ZIndex = 13
	fit(info, 14, 9)

	local buttonY = 126
	local cash = Theme.button(inner, money(def.price), "green", if product then UDim2.new(0.5, -18, 0, BUTTON_H) else UDim2.new(1, -24, 0, BUTTON_H), 26)
	cash.Name = "BuyCash"
	cash.Position = UDim2.fromOffset(12, buttonY)
	cash.ZIndex = 13
	Anim.button(cash, "click")
	local robux: TextButton? = nil
	if product then
		local r = Theme.button(inner, Theme.robux(product.price), "purple", UDim2.new(0.5, -18, 0, BUTTON_H), 26)
		r.Name = "BuyRobux"
		r.Position = UDim2.new(0.5, 6, 0, buttonY)
		r.ZIndex = 13
		Anim.button(r, "click")
		robux = r
	end
	local barButton = Theme.button(inner, "Add to bar", "blue", UDim2.new(1, -24, 0, BUTTON_H), 26)
	barButton.Name = "Bar"
	barButton.Position = UDim2.fromOffset(12, buttonY)
	barButton.ZIndex = 13
	barButton.Visible = false
	Anim.button(barButton, "click")

	local note = Theme.label(inner, "", 14, Theme.Color.Bad, Theme.FontBody)
	note.Name = "Note"
	note.AnchorPoint = Vector2.new(0.5, 0.5)
	note.Position = UDim2.new(0.5, 0, 0, buttonY + BUTTON_H + 4 + 9)
	note.Size = UDim2.new(1, -24, 0, 18)
	note.TextTransparency = 1
	note.ZIndex = 13
	fit(note, 14, 9)

	local card: ItemCard = {
		key = key,
		def = def,
		product = product,
		slot = slot,
		inner = inner,
		stage = stage,
		badge = badge,
		info = info,
		cash = cash,
		robux = robux,
		barButton = barButton,
		note = note,
		unlocked = false,
		inBar = nil,
		style = "green",
		barStyle = "blue",
		busy = false,
		buyToken = 0,
		noteToken = 0,
		confirmedAt = 0,
		waiting = false,
		waitToken = 0,
	}
	cash.Activated:Connect(function()
		onBuyItem(card)
	end)
	if robux then
		robux.Activated:Connect(function()
			onRobux(card)
		end)
	end
	barButton.Activated:Connect(function()
		openPicker(card)
	end)
	refreshItemCard(card, false)
	return card
end

-- ---------- header, tabs, pages ----------

local function anyAffordableUpgrade(): boolean
	for _, card in ipairs(cardList) do
		local price = priceOf(card)
		if price and currentCash() >= price then
			return true
		end
	end
	return false
end

local function anyAffordableItem(): boolean
	for _, card in ipairs(itemCards) do
		if not card.unlocked and currentCash() >= card.def.price then
			return true
		end
	end
	return false
end

local function updateBadge()
	local upgrades = lastState ~= nil and anyAffordableUpgrade()
	local items = lastState ~= nil and anyAffordableItem()
	for _, page in ipairs(pageList) do
		local on = if page.name == "Items" then items else upgrades
		if on ~= page.dot.Visible then
			if on then
				Anim.popIn(page.dot)
			else
				page.dot.Visible = false
			end
		end
	end
	if isOpen then
		Menu.SetBadge("Shop", nil)
	else
		Menu.SetBadge("Shop", if upgrades or items then "!" else nil)
	end
end

local function updateHint()
	local hint = hintLabel
	if not hint then
		return
	end
	if activeTab == "Items" then
		hint.Text = string.format('<font color="%s">Unlock items for good!</font>  ·  %d ride in your bar next to the towel', TITLE_HEX, ItemConfig.LoadoutSize)
	else
		local rate = if lastState and type(lastState.rate) == "number" then lastState.rate else 0
		hint.Text = string.format('<font color="%s">Upgrades are permanent!</font>  ·  <font color="%s">+$%s/s from your drawer</font>', TITLE_HEX, MONEY_HEX, Util.FormatRate(rate))
	end
end

local function updateHeader(animate: boolean)
	if not lastState then
		return
	end
	if cashLabel then
		Anim.countTo(cashLabel, currentCash(), money, if animate then nil else 0)
	end
	updateHint()
end

-- The cash pill (where purchase coins fly from).
local function buildPill(header: Frame)
	-- the concept's cash pill: tan candy, gold "$" coin, chunky white number
	local pill = Instance.new("Frame")
	pill.Name = "Cash"
	pill.Position = UDim2.fromOffset(4, 6)
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
end

local selectTab: (string, boolean) -> ()

-- The segmented control: a pill with a springy highlight behind the active tab.
local function buildTabs(header: Frame): Frame
	local bar = Instance.new("Frame")
	bar.Name = "Tabs"
	bar.Size = UDim2.fromOffset(TAB_MAX_W, TAB_HEIGHT)
	bar.BackgroundColor3 = Theme.Color.White
	bar.BorderSizePixel = 0
	bar.ZIndex = 12
	Theme.corner(bar, UDim.new(0.5, 0))
	Theme.stroke(bar, Theme.Color.Stroke, 3)
	Theme.gradient(bar, Theme.Color.InsetDark, Theme.Color.Panel2)
	bar.Parent = header

	local hl = Instance.new("Frame")
	hl.Name = "Highlight"
	hl.Position = UDim2.fromOffset(4, 4)
	hl.Size = UDim2.new(1 / #TABS, -8, 1, -8)
	hl.ZIndex = 13
	Theme.candy(hl, "green", 26, 3)
	Theme.gloss(hl, 26)
	hl.Parent = bar
	highlight = hl

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
		local stroke = Theme.textStroke(b, Theme.Styles.green.stroke, 2)
		stroke.Enabled = false
		b.Parent = bar
		-- something here you can afford: a little red dot on the tab
		local dot = Instance.new("Frame")
		dot.Name = "Dot"
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.Position = UDim2.new(1, -16, 0, 12)
		dot.Size = UDim2.fromOffset(16, 16)
		dot.ZIndex = 15
		dot.Visible = false
		Theme.candy(dot, "red", 8, 2)
		dot.Parent = b
		Anim.button(b, "tab")
		b.Activated:Connect(function()
			if activeTab ~= tab.name then
				selectTab(tab.name, true)
			end
		end)
		local page = pages[tab.name]
		if page then
			page.tab = b
			page.dot = dot
		end
	end
	return bar
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
	Theme.padding(scroll, 8, 10, 8, 16) -- room for outlines and bumps at the edges

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

-- The panel's width in reference px, without the UI scale and the panel's pop animation.
local function refWidthOf(gui: GuiObject, panel: GuiObject): number
	local pop = panel:FindFirstChild("AnimScale")
	local popScale = if pop and pop:IsA("UIScale") and pop.Scale > 0.05 then pop.Scale else 1
	return gui.AbsoluteSize.X / math.max(Theme.Scale() * popScale, 0.01)
end

-- Wide panels: the tabs sit beside the cash pill. Narrow (portrait) ones: under it, full width.
-- Card pages: two columns when there's room, one on narrow screens.
local function fitLayout(content: Frame, header: Frame, tabs: Frame, hint: TextLabel, host: Frame, panel: GuiObject)
	local function apply()
		local width = refWidthOf(content, panel)
		if width <= 0 then
			return
		end
		local wide = width >= WIDE_HEADER_FROM
		local headerH
		if wide then
			local tabW = math.min(width - 256, TAB_MAX_W)
			tabs.AnchorPoint = Vector2.new(1, 0)
			tabs.Position = UDim2.new(1, -2, 0, (PILL_ROW - TAB_HEIGHT) / 2)
			tabs.Size = UDim2.fromOffset(tabW, TAB_HEIGHT)
			headerH = PILL_ROW
		else
			tabs.AnchorPoint = Vector2.new(0.5, 0)
			tabs.Position = UDim2.new(0.5, 0, 0, PILL_ROW + 2)
			tabs.Size = UDim2.fromOffset(math.min(width - 8, TAB_MAX_W), TAB_HEIGHT)
			headerH = PILL_ROW + 2 + TAB_HEIGHT + 2
		end
		header.Size = UDim2.new(1, 0, 0, headerH)
		hint.Position = UDim2.fromOffset(4, headerH)
		host.Position = UDim2.fromOffset(0, headerH + HINT_HEIGHT)
		host.Size = UDim2.new(1, 0, 1, -(headerH + HINT_HEIGHT))
		local cols = if width >= TWO_COLUMNS_FROM then 2 else 1
		for _, page in ipairs(pageList) do
			if page.grid.FillDirectionMaxCells ~= cols then
				page.grid.FillDirectionMaxCells = cols
				page.grid.CellSize = UDim2.new(1 / cols, if cols == 2 then -(GAP / 2 + 1) else 0, 0, CARD_HEIGHT)
			end
		end
	end
	content:GetPropertyChangedSignal("AbsoluteSize"):Connect(apply)
	task.defer(apply)
end

-- ---------- state ----------

-- Cash, levels, unlocks, the bar and affordability from the last State; `animate` plays the changes.
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
			setPips(card, animate and upgradesOn() and up)
			card.levelLine.Text = levelText(card)
		end
		refreshButton(card, animate and upgradesOn())
	end
	refreshTowelPreview(animate and upgradesOn())
	local items = if type(lastState.items) == "table" then lastState.items else {}
	for _, card in ipairs(itemCards) do
		local unlocked = items[card.key] == true or (card.unlocked and os.clock() - card.confirmedAt < CONFIRM_SECONDS)
		if unlocked ~= card.unlocked then
			setUnlocked(card, unlocked, animate and itemsOn())
		end
		if unlocked and card.waiting then
			stopWaiting(card)
		end
		refreshItemCard(card, animate and itemsOn())
	end
end

-- ---------- tabs, open / close ----------

local function setUpgradeLoops(on: boolean)
	for i, card in ipairs(cardList) do
		if on then
			Anim.sway(card.icon, 6, 2.2 + i * 0.17)
		else
			Anim.stop(card.icon, "sway")
			card.icon.Rotation = 0
		end
		refreshButton(card, false)
	end
end

local function setItemLoops(on: boolean)
	for i, card in ipairs(itemCards) do
		if on then
			Anim.pulse(card.stage, 1.05, 2.2 + i * 0.13)
		else
			Anim.stop(card.stage, "pulse")
			Anim.scale(card.stage).Scale = 1
		end
		refreshItemCard(card, false)
	end
end

-- The open page's entrance: cards stagger in (upgrade pips pop in one by one).
local function entrance(name: string)
	local inners = {} :: { GuiObject }
	if name == "Items" then
		for _, card in ipairs(itemCards) do
			table.insert(inners, card.inner)
		end
	else
		for i, card in ipairs(cardList) do
			table.insert(inners, card.inner)
			local delay = (i - 1) * 0.07
			for j, pip in ipairs(card.pips) do
				popFromZero(pip, delay + 0.18 + j * 0.06)
			end
		end
	end
	Anim.stagger(inners, if name == "Items" then 0.05 else 0.07)
end

selectTab = function(name: string, animate: boolean)
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
	end
	updateHint()
	setUpgradeLoops(upgradesOn())
	setItemLoops(itemsOn())
	if not isOpen or not animate then
		return
	end
	page.scroll.CanvasPosition = Vector2.zero
	if not Anim.Reduced then
		-- the new page glides in from the side it sits on while its cards pop in
		local fromRight = previous == nil or page.index > previous.index
		page.scroll.Position = UDim2.fromOffset(if fromRight then 56 else -56, 0)
		Anim.tween(page.scroll, 0.4, { Position = UDim2.new() })
	end
	entrance(name)
end

local function onOpen()
	isOpen = true
	-- bring everything up to date without animating (this also starts the loops), then the entrance
	applyState(false)
	selectTab(activeTab, false)
	local page = pages[activeTab]
	if page then
		page.scroll.Position = UDim2.new()
	end
	entrance(activeTab)
	updateBadge()
end

local function onClose()
	isOpen = false
	setUpgradeLoops(false)
	setItemLoops(false)
	updateBadge()
end

-- Celebrate {kind, data}: the HUD shows the big card; this panel finishes the item's buttons.
local function onCelebrate(kind, data)
	if kind ~= "item" or type(data) ~= "table" or type(data.key) ~= "string" then
		return
	end
	local card = itemByKey[data.key]
	if not card then
		return
	end
	stopWaiting(card)
	card.confirmedAt = os.clock()
	setUnlocked(card, true, itemsOn())
	updateBadge()
end

-- ---------- API ----------

function ShopUI.Init()
	Menu.AddButton("Shop", "🛒", "Shop", "green", 2)
	local panel, content = Menu.Panel("Shop", "ITEM SHOP", Vector2.new(740, 540), "green", onOpen, onClose)

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, PILL_ROW)
	header.ZIndex = 12
	header.Parent = content
	buildPill(header)

	local hint = Theme.label(content, "", 15, Theme.Color.Money, Theme.FontBody)
	hint.Name = "Hint"
	hint.RichText = true
	hint.Position = UDim2.fromOffset(4, PILL_ROW)
	hint.Size = UDim2.new(1, -8, 0, HINT_HEIGHT - 2)
	hint.ZIndex = 12
	fit(hint, 15, 9)
	hintLabel = hint

	local host = Instance.new("Frame")
	host.Name = "Pages"
	host.BackgroundTransparency = 1
	host.ClipsDescendants = true -- pages glide in from the side
	host.Position = UDim2.fromOffset(0, PILL_ROW + HINT_HEIGHT)
	host.Size = UDim2.new(1, 0, 1, -(PILL_ROW + HINT_HEIGHT))
	host.ZIndex = 12
	host.Parent = content

	for i, tab in ipairs(TABS) do
		local scroll, grid = buildPage(host, tab.name)
		local page = { name = tab.name, index = i, scroll = scroll, grid = grid } :: any
		pages[tab.name] = page
		table.insert(pageList, page)
	end
	local tabs = buildTabs(header)
	fitLayout(content, header, tabs, hint, host, panel)

	for i, key in ipairs(ShopConfig.Order) do
		local card = buildCard(pages.Upgrades.scroll, key, i)
		if card then
			table.insert(cardList, card)
		end
	end
	local order = 0
	for _, key in ipairs(ItemConfig.Order) do
		if key ~= "Towel" then
			order += 1
			local card = buildItemCard(pages.Items.scroll, key, order)
			if card then
				table.insert(itemCards, card)
				itemByKey[key] = card
			end
		end
	end

	selectTab(activeTab, false)
	built = true
	applyState(false)
	updateBadge()

	-- item unlocks (the HUD celebrates; this panel finishes the card)
	task.spawn(function()
		local celebrate = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Celebrate")
		if celebrate:IsA("RemoteEvent") then
			celebrate.OnClientEvent:Connect(onCelebrate)
		end
	end)
	-- Roblox's prompt closed without a purchase: stop waiting right away
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, purchased)
		if userId ~= player.UserId or purchased or productId == 0 then
			return
		end
		for _, card in ipairs(itemCards) do
			if card.waiting and card.product and card.product.id == productId then
				stopWaiting(card)
			end
		end
	end)
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

-- Opens the Item Shop on its Items tab (the item bar's empty "+" slots).
function ShopUI.OpenItems()
	if not built then
		return
	end
	if Menu.IsOpen("Shop") then
		if activeTab ~= "Items" then
			selectTab("Items", true)
		end
		return
	end
	activeTab = "Items"
	Menu.Open("Shop")
end

return ShopUI
