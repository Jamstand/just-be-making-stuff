-- DexUI: the Sockdex, the collection book.
--  * Top: "12 / 20 found • 60%" and a progress bar that fills smoothly, with the four DexConfig
--    milestones as chests along it at their percent: grey = locked, gold + pulsing + shine = tap to
--    claim (ClaimDex remote -> pop, coins fly to the cash pill, confetti), green tick = claimed.
--    Hover or tap a chest for its name and reward.
--  * Grid: every sock type in rarity order (RarityConfig.Order, then SockConfig order). Found types
--    are cream cards with a rarity band, the sock, its name and L / R (or 1) badges for the halves
--    you've had, plus ★ paired / ★★ perfect; the rest are dark silhouettes with only a rarity hint.
--    Tap a found card for its SockCard. Cards stagger in when the book opens.
--  * NEW: types found this session (State diff + the "dexNew" Celebrate) wear a swaying NEW! tag
--    until the book has been looked at; the column button's bubble counts those plus milestones
--    waiting to be claimed.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Util = require(Shared:WaitForChild("Util"))
local SockConfig = require(Config:WaitForChild("SockConfig"))
local RarityConfig = require(Config:WaitForChild("RarityConfig"))
local DexConfig = require(Config:WaitForChild("DexConfig"))

local Theme = require(script.Parent:WaitForChild("Theme"))
local Anim = require(script.Parent:WaitForChild("Anim"))
local UISound = require(script.Parent:WaitForChild("UISound"))
local Menu = require(script.Parent:WaitForChild("Menu"))
local SockCard = require(script.Parent:WaitForChild("SockCard"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local DexUI = {}

local WHITE = Color3.new(1, 1, 1)
local TOP_H = 68 -- progress block
local CARD_H = 162
local CARD_MIN_W = 132
local GAP = 10
local PAD = 8
local SCROLLBAR = 8
local ICON = 70
local REMOTE_TIMEOUT = 12

type Card = {
	typeId: string,
	cell: Frame,
	face: TextButton,
	body: Frame?,
	sig: string,
	tag: Frame?,
}

type Marker = {
	milestone: { key: string, percent: number, cash: number, display: string },
	hit: TextButton,
	medal: Frame,
	glyph: TextLabel,
	state: string,
	busy: boolean,
}

-- every type in book order: rarity first, then roster order (unknown rarities last)
local ordered = {}
do
	local placed = {}
	for _, rarity in ipairs(RarityConfig.Order) do
		for _, t in ipairs(SockConfig.List) do
			if t.rarity == rarity then
				table.insert(ordered, t)
				placed[t.id] = true
			end
		end
	end
	for _, t in ipairs(SockConfig.List) do
		if not placed[t.id] then
			table.insert(ordered, t)
		end
	end
end
local TOTAL = #SockConfig.List

local panel: Frame
local grid: ScrollingFrame
local topBlock: Frame -- progress block (summary + bar)
local summaryBox: Frame
local narrowTop: boolean? = nil -- portrait phones: the bar gets its own row under the summary
local gridLayout: UIGridLayout
local countLabel: TextLabel
local percentLabel: TextLabel
local fill: Frame
local trackHolder: Frame
local tip: Frame
local tipTitle: TextLabel
local tipSub: TextLabel
local cards = {} :: { [string]: Card }
local cardList = {} :: { Card }
local markers = {} :: { Marker }

local latest = nil -- last StateView
local built = false
local initialized = false -- the first State marks everything already found as seen
local known = {} :: { [string]: boolean } -- types found as of the last State
local unseen = {} :: { [string]: boolean } -- found this session, not looked at yet
local claimedLocal = {} :: { [string]: boolean } -- claimed here; the next State confirms it
local viewing = false
local lastBadge: string? = nil
local lastCellW = -1
local lastPct = -1
local tipOwner: Marker? = nil
local tipToken = 0

-- ---------- helpers ----------

local function invoke(name: string, ...: any): { [string]: any }
	local remote = Remotes:FindFirstChild(name)
	if not (remote and remote:IsA("RemoteFunction")) then
		return { ok = false, err = "Not available yet - try again soon" }
	end
	local rf = remote :: RemoteFunction
	local args = table.pack(...)
	local result = nil
	local done = Instance.new("BindableEvent")
	task.spawn(function()
		local ok, res = pcall(function()
			return rf:InvokeServer(table.unpack(args, 1, args.n))
		end)
		if result == nil then
			result = if ok and type(res) == "table" then res else { ok = false, err = "Something went wrong - try again" }
			done:Fire()
		end
	end)
	task.delay(REMOTE_TIMEOUT, function()
		if result == nil then
			result = { ok = false, err = "No answer - try again" }
			done:Fire()
		end
	end)
	if result == nil then
		done.Event:Wait()
	end
	done:Destroy()
	return result
end

local function dexOf(state): { [string]: any }
	local dex = state and state.dex
	return if type(dex) == "table" then dex else {}
end

local function foundCount(state): number
	local n = 0
	for typeId in pairs(dexOf(state)) do
		if SockConfig.ById[typeId] then
			n += 1
		end
	end
	return n
end

local function isClaimed(key: string): boolean
	local claimed = latest and latest.dexClaimed
	return claimedLocal[key] == true or (type(claimed) == "table" and claimed[key] == true)
end

local function reached(m): boolean
	return foundCount(latest) * 100 >= m.percent * TOTAL
end

local function claimableCount(): number
	if not latest then
		return 0
	end
	local n = 0
	for _, m in ipairs(DexConfig.Milestones) do
		if reached(m) and not isClaimed(m.key) then
			n += 1
		end
	end
	return n
end

local function refreshBadge()
	local n = claimableCount()
	if not viewing then
		for _ in pairs(unseen) do
			n += 1
		end
	end
	local text = if n > 0 then tostring(n) else nil
	if text ~= lastBadge then
		lastBadge = text
		Menu.SetBadge("Sockdex", text)
	end
end

-- ---------- cards ----------

local function setNew(card: Card, on: boolean)
	if on and not card.tag then
		local tag = Instance.new("Frame")
		tag.Name = "NewTag"
		tag.AnchorPoint = Vector2.new(0.5, 0.5)
		tag.Position = UDim2.fromOffset(20, 4)
		tag.Size = UDim2.fromOffset(52, 24)
		tag.ZIndex = 6
		Theme.candy(tag, "red", 12, 2)
		local t = Theme.label(tag, "NEW!", 15, WHITE)
		t.Size = UDim2.fromScale(1, 1)
		t.ZIndex = 8
		Theme.textStroke(t, Theme.Styles.red.stroke, 1.5)
		tag.Parent = card.face
		card.tag = tag
		Anim.popIn(tag, 0.1)
		Anim.sway(tag, 8, 1.2)
	elseif not on and card.tag then
		local tag = card.tag
		card.tag = nil
		Anim.stop(tag, "sway")
		Anim.popOut(tag, function()
			tag:Destroy()
		end)
	end
end

local function signature(entry): string
	if type(entry) ~= "table" then
		return "-"
	end
	return "+" .. (if entry.L then "L" else "") .. (if entry.R then "R" else "") .. (if entry.S then "S" else "")
		.. (if entry.paired then "p" else "") .. (if entry.perfect then "P" else "")
end

-- Rebuilds a card's contents when its Sockdex entry changed. Returns true if it changed after the
-- first paint (so the caller can make it bounce).
local function paint(card: Card, entry): boolean
	local sig = signature(entry)
	if sig == card.sig then
		return false
	end
	local first = card.sig == ""
	card.sig = sig
	if card.body then
		card.body:Destroy()
	end
	local sockType = SockConfig.ById[card.typeId]
	local found = type(entry) == "table"
	local rarityColor = if sockType.rarity == "Secret" then Color3.fromRGB(120, 104, 190) else Theme.RarityColor(sockType.rarity)
	local face = card.face
	local rim = face:FindFirstChildOfClass("UIStroke")
	local shade = face:FindFirstChildOfClass("UIGradient")
	if found then
		face.BackgroundColor3 = Theme.Color.Inset
		if rim then
			rim.Color = rarityColor:Lerp(Theme.Color.Stroke, 0.2)
			rim.Transparency = 0
		end
		if shade then
			shade.Color = ColorSequence.new(WHITE, Color3.fromRGB(236, 222, 200))
		end
	else
		face.BackgroundColor3 = Color3.fromRGB(70, 58, 104)
		if rim then
			rim.Color = rarityColor:Lerp(Theme.Color.Backdrop, 0.55)
			rim.Transparency = 0.1
		end
		if shade then
			shade.Color = ColorSequence.new(WHITE, Color3.fromRGB(196, 190, 214))
		end
	end

	local body = Instance.new("Frame")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.Size = UDim2.fromScale(1, 1)
	body.Parent = face
	card.body = body

	-- rarity band across the top (flat bottom edge via a filler strip)
	local bandColor = if found then rarityColor else rarityColor:Lerp(Theme.Color.Backdrop, 0.5)
	local band = Instance.new("Frame")
	band.Name = "Band"
	band.BackgroundColor3 = bandColor
	band.BorderSizePixel = 0
	band.Size = UDim2.new(1, 0, 0, 24)
	Theme.corner(band, 16) -- same radius as the card, so the band's top corners follow its rim
	band.Parent = body
	local filler = Instance.new("Frame")
	filler.BackgroundColor3 = bandColor
	filler.BorderSizePixel = 0
	filler.Position = UDim2.new(0, 0, 1, -10)
	filler.Size = UDim2.new(1, 0, 0, 10)
	filler.Parent = band
	local bandText = Theme.label(band, string.upper(Theme.RarityName(sockType.rarity)), 14, WHITE)
	bandText.Size = UDim2.fromScale(1, 1)
	bandText.ZIndex = 3
	bandText.TextTransparency = if found then 0 else 0.25
	Theme.textStroke(bandText, rarityColor:Lerp(Theme.Color.Ink, 0.65), 1.5)

	local art = SockCard.Icon(body, card.typeId, ICON, nil, if sockType.single then "S" else "R", not found)
	art.Position = UDim2.new(0.5, -ICON / 2, 0, 27)

	local name = Theme.label(body, if found then sockType.name else "???", 16, if found then Theme.Color.Text else Color3.fromRGB(184, 172, 214))
	name.Name = "SockName"
	name.Position = UDim2.new(0, 6, 0, 99)
	name.Size = UDim2.new(1, -12, 0, 34)
	name.TextWrapped = true
	name.TextScaled = true
	local nameMax = Instance.new("UITextSizeConstraint")
	nameMax.MaxTextSize = 16
	nameMax.Parent = name

	if found then
		local halvesRow = Instance.new("Frame")
		halvesRow.Name = "Halves"
		halvesRow.BackgroundTransparency = 1
		halvesRow.Position = UDim2.new(0, 0, 1, -27)
		halvesRow.Size = UDim2.new(1, 0, 0, 20)
		halvesRow.Parent = body
		Theme.list(halvesRow, 5, true)
		if sockType.single then
			SockCard.HalfBadge(halvesRow, "1", entry.S == true, 20)
		else
			SockCard.HalfBadge(halvesRow, "L", entry.L == true, 20).LayoutOrder = 1
			SockCard.HalfBadge(halvesRow, "R", entry.R == true, 20).LayoutOrder = 2
		end
		if entry.paired or entry.perfect then
			local star = Instance.new("Frame")
			star.Name = "Star"
			star.AnchorPoint = Vector2.new(1, 0)
			star.Position = UDim2.new(1, -5, 0, 29)
			star.Size = UDim2.fromOffset(if entry.perfect then 44 else 28, 22)
			star.ZIndex = 4
			Theme.candy(star, "gold", 11, 2)
			local starText = Theme.label(star, if entry.perfect then "★★" else "★", 15, Theme.Styles.gold.text)
			starText.Size = UDim2.fromScale(1, 1)
			starText.ZIndex = 5
			star.Parent = body
		end
	end
	return not first
end

local function onCardTap(card: Card)
	if card.sig == "-" or card.sig == "" then
		Anim.wiggle(card.face, 6) -- not found yet
		return
	end
	if unseen[card.typeId] then
		unseen[card.typeId] = nil
		setNew(card, false)
		refreshBadge()
	end
	SockCard.ShowType(card.typeId)
end

local function buildCard(t, order: number): Card
	local cell = Instance.new("Frame")
	cell.Name = t.id
	cell.BackgroundTransparency = 1
	cell.LayoutOrder = order
	local face = Instance.new("TextButton")
	face.Name = "Face"
	face.Text = ""
	face.AutoButtonColor = false
	face.AnchorPoint = Vector2.new(0.5, 0.5) -- springs scale about the centre
	face.Position = UDim2.fromScale(0.5, 0.5)
	face.Size = UDim2.fromScale(1, 1)
	face.BorderSizePixel = 0
	Theme.corner(face, 16)
	Theme.stroke(face, Theme.Color.Stroke, 3)
	Theme.gradient(face, WHITE, WHITE)
	face.Parent = cell
	cell.Parent = grid
	local card: Card = { typeId = t.id, cell = cell, face = face, body = nil, sig = "", tag = nil }
	Anim.button(face, "click")
	face.Activated:Connect(function()
		onCardTap(card)
	end)
	return card
end

-- ---------- progress bar + milestones ----------

local function hideTip()
	tipOwner = nil
	tipToken += 1
	tip.Visible = false
end

local function showTip(marker: Marker, override: string?, hold: number?)
	local m = marker.milestone
	tipOwner = marker
	tipToken += 1
	local token = tipToken
	tipTitle.Text = m.display
	local status
	if isClaimed(m.key) then
		status = "Claimed ✓"
	elseif reached(m) then
		status = "Tap to claim!"
	else
		status = "Find " .. tostring(math.ceil(m.percent * TOTAL / 100)) .. " types"
	end
	tipSub.Text = override or (tostring(m.percent) .. "% • $" .. Util.FormatCash(m.cash) .. " • " .. status)
	local x = m.percent / 100
	tip.AnchorPoint = Vector2.new(x, 0)
	tip.Position = UDim2.new(x, 0, 1, 0)
	if not tip.Visible then
		Anim.popIn(tip)
	end
	if hold then
		task.delay(hold, function()
			if token == tipToken then
				hideTip()
			end
		end)
	end
end

local MARKER_STYLES = { locked = "grey", claimable = "gold", claimed = "green" }
local MARKER_GLYPHS = { locked = "🎁", claimable = "🎁", claimed = "✓" }

local function paintMarker(marker: Marker, stateName: string)
	if marker.state == stateName then
		return
	end
	marker.state = stateName
	Theme.restyle(marker.medal, MARKER_STYLES[stateName])
	marker.glyph.Text = MARKER_GLYPHS[stateName]
	marker.glyph.TextTransparency = if stateName == "locked" then 0.35 else 0
	Anim.stop(marker.medal, "pulse")
	Anim.scale(marker.medal).Scale = 1
	local sheen = marker.medal:FindFirstChild("Sheen")
	if sheen then
		sheen:Destroy()
	end
	if stateName == "claimable" then
		Anim.pulse(marker.medal, 1.14, 1)
		Anim.shine(marker.medal, 1.6)
	end
end

local function markerState(m): string
	if isClaimed(m.key) then
		return "claimed"
	elseif reached(m) then
		return "claimable"
	end
	return "locked"
end

local function claim(marker: Marker)
	if marker.busy then
		return
	end
	marker.busy = true
	local m = marker.milestone
	marker.glyph.Text = "…"
	Anim.stop(marker.medal, "pulse")
	task.spawn(function()
		local res = invoke("ClaimDex", m.key)
		marker.busy = false
		if res.ok == true then
			claimedLocal[m.key] = true
			hideTip()
			paintMarker(marker, "claimed")
			Anim.bump(marker.medal, 1.4)
			local at = Anim.centerOf(marker.medal)
			local target = Anim.CashTarget()
			if target then
				Anim.flyCoins(at, target, 12)
			end
			local cash = if type(res.cash) == "number" then res.cash else m.cash
			Anim.numberPop("+$" .. Util.FormatCash(cash), at, Theme.Color.Gold, 36)
			Anim.confetti(at, 50)
			UISound.Play("confetti")
		else
			marker.state = "" -- repaint whatever it really is now
			paintMarker(marker, markerState(m))
			Anim.wiggle(marker.hit)
			UISound.Play("error")
			showTip(marker, if type(res.err) == "string" and res.err ~= "" then res.err else "Couldn't claim - try again", 2.5)
		end
		refreshBadge()
	end)
end

local function buildMarker(m): Marker
	local hit = Instance.new("TextButton")
	hit.Name = m.key
	hit.Text = ""
	hit.AutoButtonColor = false
	hit.BackgroundTransparency = 1
	hit.AnchorPoint = Vector2.new(0.5, 0.5)
	hit.Position = UDim2.new(m.percent / 100, 0, 0.5, 0)
	hit.Size = UDim2.fromOffset(64, 64) -- a phone-sized tap target round a 50 px chest
	hit.ZIndex = 3
	local medal = Instance.new("Frame")
	medal.Name = "Chest"
	medal.AnchorPoint = Vector2.new(0.5, 0.5)
	medal.Position = UDim2.fromScale(0.5, 0.5)
	medal.Size = UDim2.fromOffset(50, 50)
	Theme.candy(medal, "grey", 25, 3)
	Theme.gloss(medal, 25)
	medal.Parent = hit
	local glyph = Theme.label(medal, "🎁", 26, WHITE)
	glyph.Name = "Glyph"
	glyph.Size = UDim2.fromScale(1, 1)
	glyph.ZIndex = 4
	local pct = Instance.new("Frame")
	pct.Name = "Percent"
	pct.AnchorPoint = Vector2.new(0.5, 0.5)
	pct.Position = UDim2.new(0.5, 0, 1, 0)
	pct.Size = UDim2.fromOffset(40, 17)
	pct.ZIndex = 5
	Theme.candy(pct, "cream", 8, 2)
	local pctText = Theme.label(pct, tostring(m.percent) .. "%", 12, Theme.Color.Text)
	pctText.Size = UDim2.fromScale(1, 1)
	pctText.ZIndex = 6
	pct.Parent = medal
	hit.Parent = trackHolder
	local marker: Marker = { milestone = m, hit = hit, medal = medal, glyph = glyph, state = "", busy = false }
	Anim.button(hit, "click")
	hit.MouseEnter:Connect(function()
		showTip(marker)
	end)
	hit.MouseLeave:Connect(function()
		if tipOwner == marker then
			hideTip()
		end
	end)
	hit.Activated:Connect(function()
		if marker.state == "claimable" then
			claim(marker)
		else
			showTip(marker, nil, 2.5)
			if marker.state == "locked" then
				Anim.wiggle(marker.medal, 6)
			end
		end
	end)
	return marker
end

local function updateProgress(animate: boolean)
	local found = foundCount(latest)
	local pct = if TOTAL > 0 then found / TOTAL else 0
	Anim.countTo(countLabel, found, function(n)
		return string.format("%d / %d", math.floor(n + 0.5), TOTAL)
	end)
	percentLabel.Text = "found • " .. tostring(math.floor(pct * 100 + 0.5)) .. "%"
	if pct ~= lastPct then
		lastPct = pct
		fill.Visible = pct > 0
		if animate then
			Anim.tween(fill, 0.7, { Size = UDim2.fromScale(pct, 1) })
		else
			fill.Size = UDim2.fromScale(pct, 1)
		end
	end
	for _, marker in ipairs(markers) do
		if not marker.busy then
			paintMarker(marker, markerState(marker.milestone))
		end
	end
end

-- ---------- layout ----------

-- Picks the column count from the grid's width in reference px (the panel narrows on small screens).
local function relayout()
	if not built then
		return
	end
	local s = Theme.Scale() * Anim.scale(panel).Scale
	if s <= 0.01 then
		return
	end
	local w = grid.AbsoluteSize.X / s - SCROLLBAR - PAD * 2
	if w <= 0 then
		return
	end
	-- narrow screens (portrait phones): summary on top, the bar on its own full-width row, so the
	-- four milestone chests stay far enough apart to tap
	local narrow = w < 440
	if narrow ~= narrowTop then
		narrowTop = narrow
		local topH = if narrow then TOP_H + 58 else TOP_H
		topBlock.Size = UDim2.new(1, 0, 0, topH)
		if narrow then
			summaryBox.AnchorPoint = Vector2.new(0.5, 0)
			summaryBox.Position = UDim2.new(0.5, 0, 0, 0)
			trackHolder.Position = UDim2.fromOffset(24, 58)
			trackHolder.Size = UDim2.new(1, -24 - 34, 0, TOP_H)
		else
			summaryBox.AnchorPoint = Vector2.new(0, 0.5)
			summaryBox.Position = UDim2.new(0, 0, 0.5, 0)
			trackHolder.Position = UDim2.fromOffset(150, 0)
			trackHolder.Size = UDim2.new(1, -150 - 34, 1, 0)
		end
		grid.Position = UDim2.fromOffset(0, topH + 6)
		grid.Size = UDim2.new(1, 0, 1, -(topH + 6))
	end
	local cols = math.clamp(math.floor((w + GAP) / (CARD_MIN_W + GAP)), 2, 6)
	local cellW = math.floor((w - (cols - 1) * GAP) / cols)
	if cellW ~= lastCellW then
		lastCellW = cellW
		gridLayout.CellSize = UDim2.fromOffset(cellW, CARD_H)
	end
end

local function paintAll(bounce: boolean)
	local dex = dexOf(latest)
	for _, card in ipairs(cardList) do
		if paint(card, dex[card.typeId]) and bounce then
			Anim.bump(card.face, 1.1)
		end
	end
end

local function markNew(typeId: string)
	known[typeId] = true
	local card = cards[typeId]
	if not card or unseen[typeId] then
		return
	end
	unseen[typeId] = true
	setNew(card, true)
	refreshBadge()
end

local function onOpen()
	viewing = true
	relayout()
	paintAll(false)
	-- the bar refills from empty and the count rolls up every time the book opens
	lastPct = -1
	fill.Size = UDim2.fromScale(0, 1)
	Anim.countTo(countLabel, 0, function(n)
		return string.format("%d / %d", math.floor(n + 0.5), TOTAL)
	end, 0)
	updateProgress(true)
	local faces = {}
	for _, card in ipairs(cardList) do
		table.insert(faces, card.face)
	end
	Anim.stagger(faces, 0.02)
	refreshBadge()
end

local function onClose()
	viewing = false
	hideTip()
	for typeId in pairs(unseen) do
		local card = cards[typeId]
		if card then
			setNew(card, false)
		end
	end
	table.clear(unseen)
	refreshBadge()
end

-- ---------- public API ----------

function DexUI.Init()
	Menu.AddButton("Sockdex", "📖", "Sockdex", "blue", 4)
	local content
	panel, content = Menu.Panel("Sockdex", "SOCKDEX", Vector2.new(800, 560), "blue", onOpen, onClose)

	-- progress block
	local top = Instance.new("Frame")
	top.Name = "Progress"
	top.BackgroundTransparency = 1
	top.Size = UDim2.new(1, 0, 0, TOP_H)
	top.ZIndex = 5 -- the milestone tip floats over the grid
	top.Parent = content
	topBlock = top

	local summary = Instance.new("Frame")
	summary.Name = "Summary"
	summary.AnchorPoint = Vector2.new(0, 0.5)
	summary.Position = UDim2.new(0, 0, 0.5, 0)
	summary.Size = UDim2.fromOffset(124, 58)
	summary.BackgroundColor3 = Theme.Color.Inset
	summary.BorderSizePixel = 0
	Theme.corner(summary, 14)
	Theme.stroke(summary, Theme.Color.Stroke, 2, 0.5)
	summary.Parent = top
	summaryBox = summary
	countLabel = Theme.label(summary, "0 / " .. TOTAL, 26, Theme.Color.Title)
	countLabel.Name = "Count"
	countLabel.Position = UDim2.fromOffset(0, 4)
	countLabel.Size = UDim2.new(1, 0, 0, 30)
	countLabel.TextScaled = true
	local countMax = Instance.new("UITextSizeConstraint")
	countMax.MaxTextSize = 26
	countMax.Parent = countLabel
	percentLabel = Theme.label(summary, "found • 0%", 13, Theme.Color.Muted, Theme.FontBody)
	percentLabel.Name = "Percent"
	percentLabel.Position = UDim2.fromOffset(0, 34)
	percentLabel.Size = UDim2.new(1, 0, 0, 18)

	trackHolder = Instance.new("Frame")
	trackHolder.Name = "Bar"
	trackHolder.BackgroundTransparency = 1
	trackHolder.Position = UDim2.fromOffset(150, 0)
	trackHolder.Size = UDim2.new(1, -150 - 34, 1, 0) -- room for the 100% chest's half past the end
	trackHolder.Parent = top
	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0, 0.5)
	track.Position = UDim2.new(0, 0, 0.5, 0)
	track.Size = UDim2.new(1, 0, 0, 30)
	track.BackgroundColor3 = Theme.Color.InsetDark
	track.BorderSizePixel = 0
	Theme.corner(track, UDim.new(0.5, 0))
	Theme.stroke(track, Theme.Color.Stroke, 3)
	track.Parent = trackHolder
	fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.Visible = false
	Theme.candy(fill, "green", 15, 0)
	local fillStroke = fill:FindFirstChildOfClass("UIStroke")
	if fillStroke then
		fillStroke.Enabled = false
	end
	Theme.gloss(fill, 15)
	fill.Parent = track
	for _, m in ipairs(DexConfig.Milestones) do
		table.insert(markers, buildMarker(m))
	end

	tip = Instance.new("Frame")
	tip.Name = "Tip"
	tip.Size = UDim2.fromOffset(250, 58)
	tip.ZIndex = 10
	tip.Visible = false
	Theme.candy(tip, "cream", 14, 3)
	tip.Parent = trackHolder
	tipTitle = Theme.label(tip, "", 19, Theme.Color.Title)
	tipTitle.Position = UDim2.fromOffset(8, 5)
	tipTitle.Size = UDim2.new(1, -16, 0, 24)
	tipTitle.ZIndex = 11
	tipSub = Theme.label(tip, "", 14, Theme.Color.Text, Theme.FontBody)
	tipSub.Position = UDim2.fromOffset(8, 30)
	tipSub.Size = UDim2.new(1, -16, 0, 22)
	tipSub.TextScaled = true
	tipSub.ZIndex = 11
	local subMax = Instance.new("UITextSizeConstraint")
	subMax.MaxTextSize = 14
	subMax.Parent = tipSub

	-- the book
	grid = Instance.new("ScrollingFrame")
	grid.Name = "Grid"
	grid.BackgroundTransparency = 1
	grid.BorderSizePixel = 0
	grid.Position = UDim2.fromOffset(0, TOP_H + 6)
	grid.Size = UDim2.new(1, 0, 1, -(TOP_H + 6))
	grid.ScrollBarThickness = SCROLLBAR
	grid.ScrollBarImageColor3 = Theme.Color.Stroke
	grid.ScrollingDirection = Enum.ScrollingDirection.Y
	grid.VerticalScrollBarInset = Enum.ScrollBarInset.Always
	grid.AutomaticCanvasSize = Enum.AutomaticSize.Y
	grid.CanvasSize = UDim2.new()
	grid.Parent = content
	Theme.padding(grid, PAD, 12, PAD, 12) -- top room for the NEW! tags
	gridLayout = Instance.new("UIGridLayout")
	gridLayout.CellPadding = UDim2.fromOffset(GAP, GAP)
	gridLayout.CellSize = UDim2.fromOffset(CARD_MIN_W, CARD_H)
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	gridLayout.Parent = grid

	for i, t in ipairs(ordered) do
		local card = buildCard(t, i)
		cards[t.id] = card
		table.insert(cardList, card)
		paint(card, nil)
	end
	built = true
	grid:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayout)
	task.defer(relayout)

	-- first-time finds arrive as a Celebrate too (maybe before the State that has them)
	task.spawn(function()
		local celebrate = Remotes:WaitForChild("Celebrate", 60)
		if celebrate and celebrate:IsA("RemoteEvent") then
			celebrate.OnClientEvent:Connect(function(kind, data)
				if kind == "dexNew" and type(data) == "table" and type(data.typeId) == "string" and SockConfig.ById[data.typeId] then
					markNew(data.typeId)
				end
			end)
		end
	end)
end

function DexUI.SetState(state)
	if type(state) ~= "table" then
		return
	end
	latest = state
	local dex = dexOf(state)
	if not initialized then
		initialized = true
		for typeId in pairs(dex) do
			known[typeId] = true
		end
	else
		for typeId in pairs(dex) do
			if not known[typeId] then
				markNew(typeId)
			end
		end
	end
	local claimed = state.dexClaimed
	for key in pairs(claimedLocal) do
		if type(claimed) == "table" and claimed[key] then
			claimedLocal[key] = nil
		end
	end
	if built then
		paintAll(viewing)
		updateProgress(viewing)
	end
	refreshBadge()
end

return DexUI
