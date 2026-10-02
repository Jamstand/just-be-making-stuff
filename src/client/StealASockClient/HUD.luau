-- HUD: the always-on screen - cash pill (rolling number, coins flying in), income / lock / pad
-- chips, the drawer list next to the menu column, the Server Luck timer, the carry banner, toasts,
-- server announcements and the big celebration cards. Built from the UI kit (Theme / Anim /
-- UISound) in reference px, no image assets. Nothing is rebuilt every second: SetState diffs the
-- StateView and animates only what changed (drawer rows diff by sock uid).
--
-- Layout (reference px, see Theme): cash pill at (12, 8), 300 x 62, chips under it at y = 76 (all
-- above the menu column at Menu.ColumnTop = 120); the drawer panel at (Menu.ColumnRight + 8, 120);
-- top-centre lanes, top to bottom: Server Luck chip, announcement banner, toasts (on screens too
-- narrow to fit them beside the chips they start under the chip row); the carry banner
-- bottom-centre, above the hotbar and clear of the jump button. The top bar, the top-right (Roblox
-- menu / player list) and the bottom-right stay free. Toasts and celebration cards live in a second
-- screen (SockHUDTop, above the menus) so purchase feedback shows over an open panel.
--
-- Settings honoured: Reduce motion (through Anim, and the HUD's own loops restart when it flips),
-- Pop-up messages (off = only "bad" toasts), Server announcements (off = no banner).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = require(Shared:WaitForChild("Util"))
local Config = Shared:WaitForChild("Config")
local RarityConfig = require(Config:WaitForChild("RarityConfig"))
local MutationConfig = require(Config:WaitForChild("MutationConfig"))
local ShopConfig = require(Config:WaitForChild("ShopConfig"))
local StoreConfig = require(Config:WaitForChild("StoreConfig"))

local Theme = require(script.Parent:WaitForChild("Theme"))
local Anim = require(script.Parent:WaitForChild("Anim"))
local UISound = require(script.Parent:WaitForChild("UISound"))
local Menu = require(script.Parent:WaitForChild("Menu"))
local ClientSettings = require(script.Parent:WaitForChild("ClientSettings"))

local HUD = {}

local C = Theme.Color
local rgb = Color3.fromRGB
local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)
local GOLD_TEXT = rgb(255, 236, 140) -- "+$500" pops and rewards
local SEAL_TEXT = rgb(110, 60, 8)

-- layout, reference px
local EDGE = 12
local TOP_Y = 8
local PILL_W, PILL_H = 300, 62
local CHIP_H, CHIP_GAP, CHIP_TEXT = 26, 6, 15
local DRAWER_X = Menu.ColumnRight + 8
local DRAWER_Y = Menu.ColumnTop
local DRAWER_W = 300
local DRAWER_HEAD = 42
local ROW_H, ROW_GAP = 54, 6
local PENDING_H = 30
local LUCK_W, LUCK_H = 210, 38
local ANN_H = 52
local CARRY_H = 58
local CARRY_BOTTOM = 84 -- above the Roblox hotbar (the Towel is a Tool)

local TOAST_MAX = 4
local TOAST_TIME = 3
local ANNOUNCE_TIME = 5
local QUEUE_MAX = 8

type Chip = { frame: Frame, label: TextLabel, stroke: UIStroke, width: number, shown: boolean }

type Row = {
	index: number,
	holder: Frame,
	button: TextButton,
	stroke: UIStroke,
	uid: any,
	rate: number,
	content: Frame?,
	name: TextLabel?,
	sub: TextLabel?,
	income: TextLabel?,
	seal: Frame?,
	sealText: TextLabel?,
}

type ExtraRow = { holder: Frame, card: GuiObject, text: TextLabel }

type Toast = { holder: Frame, card: Frame, text: string, token: number, closing: boolean }

type CardSpec = {
	color: Color3,
	title: string,
	sub: string?,
	reward: string?,
	icon: string?,
	tag: string?,
	big: boolean?,
}

local built = false
local lastState = nil

-- responsive sizes (relayout)
local refWidth = 1280
local laneClear = 400 -- how far right the cash pill + its chip row can reach (measured in Init)
local laneTight = false -- the top-centre lanes would hit the chip row: they start under it instead
local luckLow = false -- even the luck chip doesn't fit beside the pill (portrait)
local toastW, annW, carryW, carryBottom, drawerW = 460, 540, 480, CARRY_BOTTOM, DRAWER_W

-- screens
local root: Frame
local topRoot: Frame

-- cash pill + chips
local pill: Frame
local coin: Frame
local cashLabel: TextLabel
local chips: { Chip } = {}
local incomeChip: Chip
local lockChip: Chip
local padChip: Chip
local lockTrack: Frame
local lockFill: Frame
local targetCash = 0
local rollToken = 0
local lastCoinFly = 0
local celebrateCashUntil = 0
local ownCoinsUntil = 0 -- coins the HUD itself sent are landing until then
local foreignCoinAt = -10 -- last time another screen's coins (a sale, a claim) landed on the pill
local lockMode = ""
local lockSeenUntil, lockSpan = -1, 1
local coolSeenUntil, coolSpan = -1, 1

-- drawer
local drawer: Frame
local drawerMax: UISizeConstraint
local drawerList: ScrollingFrame
local drawerTitle: TextLabel
local drawerCount: TextLabel
local drawerOpen = not Theme.IsTouch
local drawerToken = 0
local rows: { Row } = {}
local lockRow: ExtraRow? = nil
local pendingRow: ExtraRow? = nil
local lastPending = 0

-- top-centre lanes
local luckHolder: Frame
local luckChip: Frame
local luckLabel: TextLabel
local luckShown = false
local annHolder: Frame
local annBanner: Frame
local annLabel: TextLabel
local annStroke: UIStroke
local annShown = false
local annToken = 0
local toastBox: Frame
local toasts: { Toast } = {}
local toastCount = 0

-- carry banner
local carry: Frame
local carryLabel: TextLabel
local carryStroke: UIStroke
local carryKey: string? = nil
local carryToken = 0

-- celebrations
local celebLayer: Frame
local queue: { () -> () } = {}
local queueRunning = false

-- ---------- small helpers ----------

local function num(v: any, default: number?): number
	if type(v) == "number" and v == v then
		return v
	end
	return default or 0
end

-- light top / base / dark edge of a colour (rarity candy, banners)
local function shades(color: Color3): (Color3, Color3, Color3)
	return color:Lerp(WHITE, 0.35), color, color:Lerp(BLACK, 0.5)
end

-- Theme.candy in any colour (Theme.candy takes a named style).
local function tint(frame: GuiObject, color: Color3, radius: number | UDim, thickness: number?)
	local top, bottom, edge = shades(color)
	frame.BackgroundColor3 = WHITE
	frame.BackgroundTransparency = 0
	frame.BorderSizePixel = 0
	Theme.corner(frame, radius)
	Theme.stroke(frame, edge, thickness or 3)
	Theme.gradient(frame, top, bottom)
end

local function retint(frame: GuiObject, color: Color3)
	local top, bottom, edge = shades(color)
	local stroke = frame:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = edge
	end
	local grad = frame:FindFirstChildOfClass("UIGradient")
	if grad then
		grad.Color = ColorSequence.new(top, bottom)
	end
end

-- Chunky white text with a dark rim (the concept's "$1,250"). Text sits above gloss and sheen.
local function bold(parent: Instance, text: string, size: number, edge: Color3?, thickness: number?): (TextLabel, UIStroke)
	local t = Theme.label(parent, text, size, WHITE)
	t.ZIndex = 5
	local s = Theme.textStroke(t, edge or C.Ink, thickness or 2)
	return t, s
end

-- TextScaled between two sizes, so long names shrink instead of spilling.
local function fit(label: TextLabel, maxSize: number, minSize: number)
	label.TextScaled = true
	local c = Instance.new("UITextSizeConstraint")
	c.MaxTextSize = maxSize
	c.MinTextSize = minSize
	c.Parent = label
end

local function measure(text: string, size: number): number
	return TextService:GetTextSize(text, size, Theme.Font, Vector2.new(4000, 400)).X
end

local function commas(n: number): string
	local digits = tostring(math.floor(math.abs(n)))
	local out = ""
	for i = #digits, 1, -1 do
		out = string.sub(digits, i, i) .. out
		local fromEnd = #digits - i + 1
		if fromEnd % 3 == 0 and i > 1 then
			out = "," .. out
		end
	end
	return (if n < 0 then "-" else "") .. out
end

-- "$1,250" like the concept while it fits, "$1.2M" after that.
local function cashText(v: number): string
	if math.abs(v) < 100000 then
		return "$" .. commas(v)
	end
	return "$" .. Util.FormatCash(v)
end

local function clockText(seconds: number): string
	local s = math.max(0, math.ceil(seconds))
	local h = math.floor(s / 3600)
	local m = math.floor((s % 3600) / 60)
	if h > 0 then
		return string.format("%d:%02d:%02d", h, m, s % 60)
	end
	return string.format("%d:%02d", m, s % 60)
end

local function refScale(): number
	return math.max(Theme.Scale(), 0.01)
end

local function coinCount(amount: number): number
	return math.clamp(math.floor(4 + math.log10(math.max(amount, 1)) * 1.5), 4, 14)
end

-- Slots arrive keyed by slot number; a sparse table can come through a remote with string keys.
local function slotAt(slots: any, i: number): any
	if type(slots) ~= "table" then
		return nil
	end
	local v = slots[i]
	if v == nil then
		v = slots[tostring(i)]
	end
	if type(v) == "table" and v.uid ~= nil then
		return v
	end
	return nil
end

-- A transparent slot inside a UIListLayout holding a free card, so cards can spring around their
-- own centre without fighting the layout.
local function holderFrame(name: string, height: number, order: number, parent: Instance): Frame
	local h = Instance.new("Frame")
	h.Name = name
	h.BackgroundTransparency = 1
	h.Size = UDim2.new(1, 0, 0, height)
	h.LayoutOrder = order
	h.Parent = parent
	return h
end

local function centred(gui: GuiObject)
	gui.AnchorPoint = Vector2.new(0.5, 0.5)
	gui.Position = UDim2.fromScale(0.5, 0.5)
	gui.Size = UDim2.fromScale(1, 1)
end

-- Shrinks `gui` away, then runs `after` once - also when a newer tween (a hover spring) cuts the
-- pop short, which makes Anim.popOut skip its callback.
local function popAway(gui: GuiObject, after: () -> ())
	local finished = false
	local function finish()
		if not finished then
			finished = true
			after()
		end
	end
	Anim.popOut(gui, finish)
	task.delay(0.5, finish)
end

-- Where "+$X" pops start: just under the right half of the pill, so they rise across it.
local function popPoint(): Vector2
	return pill.AbsolutePosition + Vector2.new(pill.AbsoluteSize.X * 0.7, pill.AbsoluteSize.Y + 14 * refScale())
end

-- Your Collect pad on screen (absolute px), or nil when it's off screen / not built yet.
local function padPoint(): Vector2?
	local s = lastState
	local world = workspace:FindFirstChild("StealASock")
	local bases = if world then world:FindFirstChild("Bases") else nil
	local base = if bases and s then bases:FindFirstChild("Base_" .. tostring(s.baseIndex)) else nil
	local pad = if base then base:FindFirstChild("CollectPad") else nil
	if pad and pad:IsA("BasePart") then
		return Anim.worldToScreen(pad.Position)
	end
	return nil
end

-- ---------- cash pill ----------

local function buildCash()
	pill = Instance.new("Frame")
	pill.Name = "CashPill"
	pill.AnchorPoint = Vector2.new(0.5, 0.5) -- bumps and wiggles pivot on the middle
	pill.Position = UDim2.fromOffset(EDGE + PILL_W / 2, TOP_Y + PILL_H / 2)
	pill.Size = UDim2.fromOffset(PILL_W, PILL_H)
	pill.ZIndex = 2
	Theme.candy(pill, "cream", PILL_H / 2, 3)

	-- the orange inner pill with its glossy top
	local inner = Instance.new("Frame")
	inner.Name = "Inner"
	inner.AnchorPoint = Vector2.new(0.5, 0.5)
	inner.Position = UDim2.fromScale(0.5, 0.5)
	inner.Size = UDim2.new(1, -12, 1, -12)
	inner.BackgroundColor3 = WHITE
	inner.BorderSizePixel = 0
	Theme.corner(inner, (PILL_H - 12) / 2)
	Theme.stroke(inner, rgb(184, 104, 46), 2)
	Theme.gradient(inner, rgb(250, 190, 110), rgb(226, 136, 66))
	Theme.gloss(inner, (PILL_H - 12) / 2)
	inner.Parent = pill

	-- the gold "$" coin (also where every screen's reward coins fly to)
	coin = Instance.new("Frame")
	coin.Name = "Coin"
	coin.AnchorPoint = Vector2.new(0.5, 0.5)
	coin.Position = UDim2.new(0, 33, 0.5, 0)
	coin.Size = UDim2.fromOffset(54, 54)
	coin.ZIndex = 4
	coin.BackgroundColor3 = WHITE
	coin.BorderSizePixel = 0
	Theme.corner(coin, UDim.new(0.5, 0))
	Theme.stroke(coin, rgb(150, 90, 20), 3)
	Theme.gradient(coin, rgb(255, 228, 110), rgb(244, 164, 36))
	local face = Instance.new("Frame")
	face.Name = "Face"
	face.AnchorPoint = Vector2.new(0.5, 0.5)
	face.Position = UDim2.fromScale(0.5, 0.5)
	face.Size = UDim2.fromScale(0.7, 0.7)
	face.BackgroundColor3 = WHITE
	face.BorderSizePixel = 0
	Theme.corner(face, UDim.new(0.5, 0))
	Theme.stroke(face, rgb(255, 240, 170), 2, 0.2)
	Theme.gradient(face, rgb(232, 150, 36), rgb(255, 206, 84))
	face.Parent = coin
	local dollar = bold(face, "$", 28, rgb(170, 96, 16), 2)
	dollar.Size = UDim2.fromScale(1, 1)
	Theme.gloss(coin, 27)
	coin.Parent = pill

	cashLabel = bold(pill, "$0", 40, C.Ink, 3)
	cashLabel.Name = "Cash"
	cashLabel.TextXAlignment = Enum.TextXAlignment.Left
	cashLabel.Position = UDim2.fromOffset(68, 0)
	cashLabel.Size = UDim2.new(1, -84, 1, 0)
	fit(cashLabel, 40, 18)

	pill.Parent = root
	Anim.SetCashTarget(coin)
	Anim.countTo(cashLabel, 0, cashText, 0)
	Anim.shine(coin, 4)
	-- every landing coin bumps the coin's scale: note the ones other screens sent
	Anim.scale(coin):GetPropertyChangedSignal("Scale"):Connect(function()
		if os.clock() > ownCoinsUntil then
			foreignCoinAt = os.clock()
		end
	end)
end

-- Coins from `from` into the pill coin (marked as the HUD's own).
local function coinsToPill(from: any, count: number)
	ownCoinsUntil = os.clock() + 2.5
	Anim.flyCoins(from, coin, count)
end

-- Rolls the pill to the newest cash. A delayed roll waits for flying coins to land; any newer roll
-- replaces it (both always aim at the latest value).
local function rollCash(delay: number)
	rollToken += 1
	local token = rollToken
	local function go()
		if token == rollToken then
			Anim.countTo(cashLabel, targetCash, cashText, 0.7)
		end
	end
	if delay > 0 then
		task.delay(delay, go)
	else
		go()
	end
end

local function updateCash(s, prev)
	local cash = num(s.cash)
	targetCash = cash
	if not prev then
		Anim.countTo(cashLabel, cash, cashText, 0)
		return
	end
	local delta = cash - num(prev.cash)
	if delta > 0 then
		local now = os.clock()
		local collected = num(s.uncollected) < num(prev.uncollected) - 0.5
		if collected and now - lastCoinFly > 1.2 then
			-- collected: coins fly from the pad (or the pad chip) into the coin, then the number rolls
			lastCoinFly = now
			local from: any = padPoint()
			if not from then
				from = if padChip.shown then padChip.frame else pill
			end
			coinsToPill(from, coinCount(delta))
			rollCash(0.45)
			task.delay(0.6, function()
				Anim.numberPop("+" .. cashText(delta), popPoint(), GOLD_TEXT, 30)
			end)
		elseif now < celebrateCashUntil then
			rollCash(0.5) -- a celebration card is already flying coins for this
		elseif num(s.uncollected) < 1 and num(prev.uncollected) < 1 then
			-- Coin Magnet auto-collect: steady trickle every tick, so just a soft nudge
			rollCash(0)
			Anim.bump(pill, 1.03)
		else
			rollCash(0)
			Anim.bump(pill, 1.06)
			-- a sale or claim screen usually flies its own coins and "+$X": only pop when none came
			local at = os.clock()
			task.delay(0.9, function()
				if foreignCoinAt < at - 1 then
					Anim.numberPop("+" .. cashText(delta), popPoint(), GOLD_TEXT, 30)
				end
			end)
		end
	elseif delta < 0 then
		rollCash(0)
		Anim.wiggle(pill, 3)
		cashLabel.TextColor3 = C.Bad
		Anim.tween(cashLabel, 0.5, { TextColor3 = WHITE }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0.35)
	end
end

-- ---------- chips under the pill ----------

local function makeChip(name: string, color: Color3): Chip
	local f = Instance.new("Frame")
	f.Name = name
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Size = UDim2.fromOffset(80, CHIP_H)
	f.ZIndex = 2
	Theme.candy(f, "cream", CHIP_H / 2, 2)
	local t = Theme.label(f, "", CHIP_TEXT, color)
	t.AnchorPoint = Vector2.new(0.5, 0.5)
	t.Position = UDim2.new(0.5, 0, 0.5, -1)
	t.Size = UDim2.new(1, -10, 1, 0)
	t.ZIndex = 5
	local s = Theme.textStroke(t, C.Ink, 1.5)
	s.Enabled = false
	f.Parent = root
	local chip: Chip = { frame = f, label = t, stroke = s, width = 80, shown = true }
	table.insert(chips, chip)
	return chip
end

-- Chips sit left to right under the pill; each is sized to its text.
local function layoutChips()
	local x = EDGE
	local y = TOP_Y + PILL_H + CHIP_GAP + CHIP_H / 2
	for _, chip in ipairs(chips) do
		if chip.shown then
			chip.frame.Size = UDim2.fromOffset(chip.width, CHIP_H)
			chip.frame.Position = UDim2.fromOffset(x + chip.width / 2, y)
			x += chip.width + CHIP_GAP
		end
	end
end

-- Sets a chip's text; true when its width changed. Digits are measured as 8s so a ticking
-- countdown doesn't jiggle the row.
local function setChipText(chip: Chip, text: string): boolean
	if chip.label.Text == text then
		return false
	end
	chip.label.Text = text
	local w = math.ceil(measure((string.gsub(text, "%d", "8")), CHIP_TEXT) + 26)
	if w == chip.width then
		return false
	end
	chip.width = w
	return true
end

local function buildChips()
	incomeChip = makeChip("Income", C.Money)
	lockChip = makeChip("Lock", C.Title)
	padChip = makeChip("Pad", C.Text)
	padChip.shown = false
	padChip.frame.Visible = false

	-- the thin draining bar along the bottom of the lock chip
	lockTrack = Instance.new("Frame")
	lockTrack.Name = "Track"
	lockTrack.AnchorPoint = Vector2.new(0.5, 1)
	lockTrack.Position = UDim2.new(0.5, 0, 1, -3)
	lockTrack.Size = UDim2.new(1, -18, 0, 3)
	lockTrack.BackgroundColor3 = C.Stroke
	lockTrack.BackgroundTransparency = 0.8
	lockTrack.BorderSizePixel = 0
	lockTrack.ZIndex = 6
	lockTrack.Visible = false
	Theme.corner(lockTrack, 2)
	lockTrack.Parent = lockChip.frame
	lockFill = Instance.new("Frame")
	lockFill.Name = "Fill"
	lockFill.Size = UDim2.fromScale(1, 1)
	lockFill.BackgroundColor3 = WHITE
	lockFill.BorderSizePixel = 0
	Theme.corner(lockFill, 2)
	lockFill.Parent = lockTrack

	setChipText(incomeChip, "+$0.0/s")
	setChipText(lockChip, "🔓 Drawer open")
	layoutChips()
end

local function paintLock(mode: string)
	if mode == "locked" then
		Theme.restyle(lockChip.frame, "blue")
		lockChip.label.TextColor3 = WHITE
		lockChip.stroke.Color = Theme.Styles.blue.stroke
		lockChip.stroke.Enabled = true
		lockTrack.Visible = true
		lockTrack.BackgroundColor3 = WHITE
		lockTrack.BackgroundTransparency = 0.65
		lockFill.BackgroundColor3 = WHITE
	elseif mode == "cooldown" then
		Theme.restyle(lockChip.frame, "cream")
		lockChip.label.TextColor3 = C.Muted
		lockChip.stroke.Enabled = false
		lockTrack.Visible = true
		lockTrack.BackgroundColor3 = C.Stroke
		lockTrack.BackgroundTransparency = 0.8
		lockFill.BackgroundColor3 = C.Gold2
	else
		Theme.restyle(lockChip.frame, "cream")
		lockChip.label.TextColor3 = C.Title
		lockChip.stroke.Enabled = false
		lockTrack.Visible = false
	end
end

-- Lock chip: runs every frame (the countdown and its bar tick between server pushes).
local function refreshLock(now: number)
	local s = lastState
	if not s then
		return
	end
	local lockedUntil = num(s.lockedUntil)
	local coolUntil = num(s.lockCooldownUntil)
	local mode, text
	if lockedUntil > now then
		mode = "locked"
		text = "🔒 LOCKED " .. math.ceil(lockedUntil - now) .. "s"
		if lockedUntil ~= lockSeenUntil then -- a new lock (or a re-lock): the bar starts full
			lockSeenUntil = lockedUntil
			lockSpan = math.max(lockedUntil - now, 1)
		end
		lockFill.Size = UDim2.fromScale(math.clamp((lockedUntil - now) / lockSpan, 0, 1), 1)
	elseif coolUntil > now then
		mode = "cooldown"
		text = "⏳ Slam ready " .. math.ceil(coolUntil - now) .. "s"
		if coolUntil ~= coolSeenUntil then
			coolSeenUntil = coolUntil
			coolSpan = math.max(coolUntil - now, 1)
		end
		lockFill.Size = UDim2.fromScale(math.clamp(1 - (coolUntil - now) / coolSpan, 0, 1), 1)
	else
		mode = "open"
		text = "🔓 Drawer open"
	end
	if mode ~= lockMode then
		local first = lockMode == ""
		lockMode = mode
		paintLock(mode)
		if not first then
			Anim.bump(lockChip.frame, 1.12)
		end
	end
	if setChipText(lockChip, text) then
		layoutChips()
	end
end

local function updateChips(s, prev)
	local changed = false
	local rate = num(s.rate)
	if setChipText(incomeChip, "+$" .. Util.FormatRate(rate) .. "/s") then
		changed = true
	end
	if prev and rate > num(prev.rate) then
		Anim.bump(incomeChip.frame, 1.12)
	end

	local amount = math.floor(num(s.uncollected))
	local before = if prev then math.floor(num(prev.uncollected)) else 0
	if amount >= 1 then
		if setChipText(padChip, "💰 $" .. Util.FormatCash(amount) .. " on pad") then
			changed = true
		end
		if not padChip.shown then
			padChip.shown = true
			changed = true
			Anim.popIn(padChip.frame)
		elseif amount > before and not Anim.Reduced then
			Anim.bump(padChip.frame, 1.08)
		end
	elseif padChip.shown then
		padChip.shown = false
		Anim.popOut(padChip.frame) -- a quick comeback (popIn) cancels the hide
	end
	if changed then
		layoutChips()
	end
end

-- ---------- drawer panel ----------

local function drawerPos(open: boolean): UDim2
	if open then
		return UDim2.fromOffset(DRAWER_X, DRAWER_Y)
	end
	return UDim2.fromOffset(-(drawerW + 30), DRAWER_Y)
end

local function placeTitle()
	local w1 = measure(drawerTitle.Text, 24)
	local w2 = measure(drawerCount.Text, 24)
	local total = w1 + 8 + w2
	local y = DRAWER_HEAD / 2 + 1
	drawerTitle.Size = UDim2.fromOffset(w1 + 4, 30)
	drawerTitle.Position = UDim2.new(0.5, -total / 2 + w1 / 2, 0, y)
	drawerCount.Size = UDim2.fromOffset(w2 + 4, 30)
	drawerCount.Position = UDim2.new(0.5, total / 2 - w2 / 2, 0, y)
end

local function buildDrawer()
	drawer = Instance.new("Frame")
	drawer.Name = "Drawer"
	drawer.Size = UDim2.new(0, drawerW, 1, -(DRAWER_Y + EDGE)) -- down to the bottom...
	drawer.Position = drawerPos(drawerOpen)
	drawer.Visible = drawerOpen
	Theme.candy(drawer, "cream", 20, 3)
	drawerMax = Instance.new("UISizeConstraint")
	drawerMax.MaxSize = Vector2.new(10000, DRAWER_HEAD + 60) -- ...but no taller than its rows
	drawerMax.Parent = drawer

	drawerTitle = Theme.label(drawer, "YOUR DRAWER", 24, C.Title)
	drawerTitle.Name = "Title"
	drawerTitle.AnchorPoint = Vector2.new(0.5, 0.5)
	drawerTitle.ZIndex = 5
	drawerCount = Theme.label(drawer, "0/0", 24, rgb(214, 160, 110))
	drawerCount.Name = "Count"
	drawerCount.AnchorPoint = Vector2.new(0.5, 0.5)
	drawerCount.ZIndex = 5
	placeTitle()

	drawerList = Instance.new("ScrollingFrame")
	drawerList.Name = "List"
	drawerList.BackgroundTransparency = 1
	drawerList.BorderSizePixel = 0
	drawerList.Position = UDim2.fromOffset(8, DRAWER_HEAD)
	drawerList.Size = UDim2.new(1, -16, 1, -(DRAWER_HEAD + 8))
	drawerList.CanvasSize = UDim2.new()
	drawerList.AutomaticCanvasSize = Enum.AutomaticSize.Y
	drawerList.ScrollingDirection = Enum.ScrollingDirection.Y
	drawerList.ScrollBarThickness = 5
	drawerList.ScrollBarImageColor3 = C.Stroke
	drawerList.ScrollBarImageTransparency = 0.4
	drawerList.VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar
	drawerList.ZIndex = 2
	drawerList.Parent = drawer
	Theme.padding(drawerList, 4, 4, 4, 4) -- room for row outlines and springs
	Theme.list(drawerList, ROW_GAP)

	drawer.Parent = root
end

local function showSlot(index: number)
	-- required lazily: SockCard is its own screen and never needs the HUD
	local SockCard = require(script.Parent:WaitForChild("SockCard")) :: any
	SockCard.ShowSlot(index)
end

local function makeRow(index: number): Row
	local holder = holderFrame("Slot" .. index, ROW_H, index, drawerList)
	local button = Instance.new("TextButton")
	button.Name = "Row"
	button.Text = ""
	button.AutoButtonColor = false
	centred(button)
	button.BackgroundColor3 = C.Inset
	button.BorderSizePixel = 0
	Theme.corner(button, 12)
	local stroke = Theme.stroke(button, C.Stroke, 2, 0.35)
	button.Parent = holder
	local row: Row = { index = index, holder = holder, button = button, stroke = stroke, uid = nil, rate = 0 }
	Anim.button(button, "click")
	button.Activated:Connect(function()
		if row.uid ~= nil then
			showSlot(row.index)
		end
	end)
	return row
end

local function newContent(row: Row): Frame
	local content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	centred(content)
	content.ZIndex = 2
	content.Parent = row.button
	row.content = content
	row.name, row.sub, row.income, row.seal, row.sealText = nil, nil, nil, nil, nil
	return content
end

local function subLine(view): string
	local parts = { Util.SideLabel(tostring(view.side)) }
	local m = MutationConfig.Table[tostring(view.mutation)]
	if m and m.display ~= "" then
		table.insert(parts, m.display)
	end
	if view.perfect == true then
		table.insert(parts, "PERFECT PAIR")
	elseif view.paired == true then
		table.insert(parts, "PAIRED")
	end
	return table.concat(parts, " • ")
end

-- A filled slot: glossy candy bar in the rarity colour (with the slot number and the PAIRED seal),
-- name, side • mutation • pairing, income on the right.
local function buildSock(row: Row, view)
	local color = Theme.RarityColor(tostring(view.rarity))
	local _, _, edge = shades(color)
	local content = newContent(row)

	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.AnchorPoint = Vector2.new(0, 0.5)
	bar.Position = UDim2.new(0, 6, 0.5, 0)
	bar.Size = UDim2.fromOffset(46, 38)
	tint(bar, color, 10, 2)
	Theme.gloss(bar, 10)
	bar.Parent = content
	local number = bold(bar, tostring(row.index), 18, edge, 2)
	number.Size = UDim2.fromScale(1, 1)

	local seal = Instance.new("Frame")
	seal.Name = "Seal"
	seal.AnchorPoint = Vector2.new(0.5, 0.5)
	seal.Position = UDim2.new(0.5, 0, 1, -4)
	seal.Size = UDim2.fromOffset(58, 18)
	seal.Rotation = -8
	seal.ZIndex = 6
	seal.Visible = false
	tint(seal, C.Gold, 9, 2)
	seal.Parent = bar
	local sealText = Theme.label(seal, "PAIRED", 12, SEAL_TEXT)
	sealText.Size = UDim2.fromScale(1, 1)
	sealText.ZIndex = 2

	local name = Theme.label(content, "", 17, C.Text)
	name.Name = "SockName"
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.Position = UDim2.fromOffset(62, 6)
	name.Size = UDim2.new(1, -152, 0, 22)
	fit(name, 17, 11)

	local income = Theme.label(content, "", 16, C.Money)
	income.Name = "Income"
	income.AnchorPoint = Vector2.new(1, 0)
	income.TextXAlignment = Enum.TextXAlignment.Right
	income.Position = UDim2.new(1, -8, 0, 7)
	income.Size = UDim2.fromOffset(84, 20)
	fit(income, 16, 10)

	local sub = Theme.label(content, "", 12, C.Muted, Theme.FontBody)
	sub.Name = "Sub"
	sub.TextXAlignment = Enum.TextXAlignment.Left
	sub.TextTruncate = Enum.TextTruncate.AtEnd
	sub.Position = UDim2.fromOffset(62, 30)
	sub.Size = UDim2.new(1, -70, 0, 16)

	row.name, row.sub, row.income, row.seal, row.sealText = name, sub, income, seal, sealText
end

local function buildEmpty(row: Row)
	local content = newContent(row)
	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.AnchorPoint = Vector2.new(0, 0.5)
	bar.Position = UDim2.new(0, 6, 0.5, 0)
	bar.Size = UDim2.fromOffset(46, 38)
	bar.BackgroundColor3 = C.InsetDark
	bar.BorderSizePixel = 0
	Theme.corner(bar, 10)
	Theme.stroke(bar, C.Stroke, 2, 0.55)
	bar.Parent = content
	local number = Theme.label(bar, tostring(row.index), 18, C.Muted)
	number.Size = UDim2.fromScale(1, 1)
	local empty = Theme.label(content, "empty", 15, C.Muted, Theme.FontBody)
	empty.TextXAlignment = Enum.TextXAlignment.Left
	empty.Position = UDim2.fromOffset(62, 0)
	empty.Size = UDim2.new(1, -70, 1, 0)
end

-- Same sock, new numbers: update in place (the seal pops in when it pairs up).
local function updateSock(row: Row, view, animate: boolean)
	local name, sub, income, seal, sealText = row.name, row.sub, row.income, row.seal, row.sealText
	if not (name and sub and income and seal and sealText) then
		return
	end
	name.Text = tostring(view.name)
	local rate = num(view.income)
	local rateText = "$" .. Util.FormatRate(rate) .. "/s"
	if income.Text ~= rateText then
		income.Text = rateText
		if animate and rate > row.rate then
			Anim.bump(income, 1.2)
		end
	end
	row.rate = rate
	local paired = view.paired == true or view.perfect == true
	sub.Text = subLine(view)
	sub.TextColor3 = if paired then C.Money else C.Muted
	if view.perfect == true then
		retint(seal, rgb(255, 110, 200))
		sealText.Text = "PERFECT"
		sealText.TextColor3 = WHITE
	else
		retint(seal, C.Gold)
		sealText.Text = "PAIRED"
		sealText.TextColor3 = SEAL_TEXT
	end
	if paired and not seal.Visible then
		if animate then
			Anim.popIn(seal)
			UISound.Play("pop")
		else
			seal.Visible = true
		end
	elseif not paired and seal.Visible then
		if animate then
			Anim.popOut(seal)
		else
			seal.Visible = false
		end
	end
end

-- A new sock arriving: a flash in its rarity colour and an outline that settles back.
local function glow(row: Row, color: Color3)
	local flash = Instance.new("Frame")
	flash.Name = "Glow"
	flash.BackgroundColor3 = color:Lerp(WHITE, 0.45)
	flash.BackgroundTransparency = 0.2
	flash.BorderSizePixel = 0
	flash.Size = UDim2.fromScale(1, 1)
	flash.ZIndex = 8
	Theme.corner(flash, 12)
	flash.Parent = row.button
	Anim.tween(flash, 0.9, { BackgroundTransparency = 1 }, Enum.EasingStyle.Quad).Completed:Once(function()
		flash:Destroy()
	end)
	row.stroke.Color = color
	row.stroke.Thickness = 4
	row.stroke.Transparency = 0
	Anim.tween(row.stroke, 1, { Color = C.Stroke, Thickness = 2, Transparency = 0.35 }, Enum.EasingStyle.Quad, nil, 0.4)
end

-- Diffs one row by sock uid: same sock -> update in place; different -> the old content shrinks
-- away and the new one pops in.
local function setRow(row: Row, view, animate: boolean)
	local uid = if view then view.uid else nil
	if row.content and uid == row.uid then
		if view then
			updateSock(row, view, animate)
		end
		return
	end
	local old = row.content
	local hadSock = row.uid ~= nil
	row.uid = uid
	row.rate = 0
	if view then
		buildSock(row, view)
		updateSock(row, view, false)
	else
		buildEmpty(row)
	end
	row.button.Interactable = view ~= nil
	if old then
		if animate then
			popAway(old, function()
				old:Destroy()
			end)
		else
			old:Destroy()
		end
	end
	local content = row.content
	if animate and content then
		if view then
			Anim.popIn(content, 0.08)
			glow(row, Theme.RarityColor(tostring(view.rarity)))
			if drawerOpen then
				UISound.Play("pop")
			end
		elseif hadSock then
			Anim.popIn(content, 0.12)
		end
	end
end

local function removeExtra(extra: ExtraRow)
	local holder = extra.holder
	popAway(extra.card, function()
		holder:Destroy()
	end)
end

-- The padlocked back row (slotCount < maxSlots): one row, tap anywhere for the Store.
local function makeLockRow(): ExtraRow
	local holder = holderFrame("LockedSlots", ROW_H, 1000, drawerList)
	local button = Instance.new("TextButton")
	button.Name = "Row"
	button.Text = ""
	button.AutoButtonColor = false
	centred(button)
	button.BackgroundColor3 = C.InsetDark
	button.BorderSizePixel = 0
	Theme.corner(button, 12)
	Theme.stroke(button, Theme.Styles.purple.bottom, 2, 0.15)
	button.Parent = holder

	local text = Theme.label(button, "🔒 +4 slots", 18, C.Text)
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.Position = UDim2.fromOffset(12, 6)
	text.Size = UDim2.new(1, -112, 0, 24)
	text.ZIndex = 5
	local sub = Theme.label(button, "The back row of your drawer", 12, C.Muted, Theme.FontBody)
	sub.TextXAlignment = Enum.TextXAlignment.Left
	sub.TextTruncate = Enum.TextTruncate.AtEnd
	sub.Position = UDim2.fromOffset(12, 30)
	sub.Size = UDim2.new(1, -112, 0, 16)
	sub.ZIndex = 5

	local unlock = Instance.new("Frame")
	unlock.Name = "Unlock"
	unlock.AnchorPoint = Vector2.new(1, 0.5)
	unlock.Position = UDim2.new(1, -8, 0.5, 0)
	unlock.Size = UDim2.fromOffset(88, 36)
	unlock.ZIndex = 3
	Theme.candy(unlock, "purple", 18, 2)
	Theme.gloss(unlock, 18)
	unlock.Parent = button
	local unlockText = bold(unlock, "Unlock", 18, Theme.Styles.purple.stroke, 2)
	unlockText.Size = UDim2.fromScale(1, 1)
	Anim.shine(unlock, 3.5)

	Anim.button(button, "click")
	button.Activated:Connect(function()
		-- straight to the +4 Drawer Slots pass (StoreUI doesn't require the HUD, so no cycle)
		local StoreUI = require(script.Parent:WaitForChild("StoreUI")) :: any
		StoreUI.Focus("pass", "ExtraSlots")
	end)
	return { holder = holder, card = button, text = text }
end

-- "🎁 1 waiting" - Rare Sock Drops waiting for a free slot (top of the list).
local function makePendingRow(): ExtraRow
	local holder = holderFrame("PendingDrops", PENDING_H, 0, drawerList)
	local card = Instance.new("Frame")
	card.Name = "Card"
	centred(card)
	Theme.candy(card, "gold", 12, 2)
	card.Parent = holder
	local text = Theme.label(card, "", 15, Theme.Styles.gold.text)
	text.AnchorPoint = Vector2.new(0.5, 0.5)
	text.Position = UDim2.fromScale(0.5, 0.5)
	text.Size = UDim2.new(1, -12, 1, 0)
	text.ZIndex = 5
	fit(text, 15, 10)
	return { holder = holder, card = card, text = text }
end

local function resizeDrawer()
	local items = #rows + (if lockRow then 1 else 0)
	local listH = 8 + items * ROW_H + math.max(items - 1, 0) * ROW_GAP
	if pendingRow then
		listH += PENDING_H + ROW_GAP
	end
	drawerMax.MaxSize = Vector2.new(10000, DRAWER_HEAD + 8 + listH)
end

local function updateDrawer(s, first: boolean)
	local animate = not first
	local slotCount = math.max(0, math.floor(num(s.slotCount)))
	local maxSlots = math.max(slotCount, math.floor(num(s.maxSlots, slotCount)))
	local pending = math.max(0, math.floor(num(s.pendingDrops)))

	local oldCount = #rows
	local filled = 0
	for i = 1, slotCount do
		local row = rows[i]
		local fresh = row == nil
		if not row then
			row = makeRow(i)
			rows[i] = row
		end
		local view = slotAt(s.slots, i)
		if view then
			filled += 1
		end
		setRow(row, view, animate and not fresh)
		if fresh and animate then
			Anim.popIn(row.button, (i - oldCount) * 0.05) -- new slots (+4 pass) pop in one by one
		end
	end
	for i = #rows, slotCount + 1, -1 do
		local row = table.remove(rows, i)
		if row then
			local holder = row.holder
			popAway(row.button, function()
				holder:Destroy()
			end)
		end
	end

	local count = filled .. "/" .. slotCount
	if drawerCount.Text ~= count then
		drawerCount.Text = count
		placeTitle()
		if animate then
			Anim.bump(drawerCount, 1.3)
		end
	end
	drawerCount.TextColor3 = if slotCount > 0 and filled >= slotCount then C.Bad else rgb(214, 160, 110)

	local locked = maxSlots - slotCount
	if locked > 0 then
		local r = lockRow
		if not r then
			r = makeLockRow()
			lockRow = r
			if animate then
				Anim.popIn(r.card, 0.1)
			end
		end
		r.text.Text = "🔒 +" .. locked .. " slots"
	elseif lockRow then
		removeExtra(lockRow)
		lockRow = nil
	end

	if pending > 0 then
		local r = pendingRow
		if not r then
			r = makePendingRow()
			pendingRow = r
			local card = r.card
			if animate then
				Anim.popIn(card, 0.1)
			end
			task.delay(if animate then 0.6 else 0, function() -- breathe once the pop has settled
				local current = pendingRow
				if current and current.card == card then
					Anim.pulse(card, 1.03, 1.6)
				end
			end)
		end
		r.text.Text = "🎁 " .. pending .. " waiting - free a slot!"
	elseif pendingRow then
		removeExtra(pendingRow)
		pendingRow = nil
	end
	if pending ~= lastPending then
		lastPending = pending
		Menu.SetBadge("Drawer", if pending > 0 then tostring(pending) else nil)
	end

	resizeDrawer()
end

local function setDrawer(open: boolean, animate: boolean)
	drawerOpen = open
	drawerToken += 1
	local token = drawerToken
	if open then
		drawer.Visible = true
		if animate then
			Anim.tween(drawer, 0.45, { Position = drawerPos(true) })
			for i, row in ipairs(rows) do
				if i > 10 then
					break
				end
				Anim.popIn(row.button, 0.05 + i * 0.03)
			end
			UISound.Play("whoosh")
		else
			drawer.Position = drawerPos(true)
		end
	elseif animate then
		local tw = Anim.tween(drawer, 0.28, { Position = drawerPos(false) }, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
		tw.Completed:Once(function()
			if token == drawerToken then
				drawer.Visible = false
			end
		end)
	else
		drawer.Position = drawerPos(false)
		drawer.Visible = false
	end
end

-- ---------- top-centre lanes: luck chip, announcement, toasts ----------

-- Stacks the lanes under each other; lanes that are hidden take no room. On screens too narrow for
-- them beside the cash block they start under its chip row (the slim luck chip stays up top while
-- it fits).
local function restack(instant: boolean?)
	local laneY = if laneTight then TOP_Y + PILL_H + CHIP_GAP + CHIP_H + 10 else TOP_Y
	local luckY = if laneTight and not luckLow then TOP_Y else laneY
	local function place(gui: GuiObject, at: number)
		local target = UDim2.new(0.5, 0, 0, at)
		if instant then
			gui.Position = target
		else
			Anim.tween(gui, 0.35, { Position = target })
		end
	end
	local y = laneY
	place(luckHolder, luckY)
	if luckShown and luckY == laneY then
		y += LUCK_H + 6
	end
	place(annHolder, y)
	if annShown then
		y += ANN_H + 8
	end
	place(toastBox, y)
end

local function buildTop()
	-- Server Luck chip
	luckHolder = Instance.new("Frame")
	luckHolder.Name = "Luck"
	luckHolder.BackgroundTransparency = 1
	luckHolder.AnchorPoint = Vector2.new(0.5, 0)
	luckHolder.Size = UDim2.fromOffset(LUCK_W, LUCK_H)
	luckHolder.ZIndex = 3
	luckHolder.Parent = root
	luckChip = Instance.new("Frame")
	luckChip.Name = "Chip"
	centred(luckChip)
	luckChip.Visible = false
	Theme.candy(luckChip, "green", LUCK_H / 2, 3)
	Theme.gloss(luckChip, LUCK_H / 2)
	luckChip.Parent = luckHolder
	luckLabel = bold(luckChip, "🍀 LUCK 0:00", 20, Theme.Styles.green.stroke, 2)
	luckLabel.Size = UDim2.fromScale(1, 1)

	-- announcement banner
	annHolder = Instance.new("Frame")
	annHolder.Name = "Announce"
	annHolder.BackgroundTransparency = 1
	annHolder.AnchorPoint = Vector2.new(0.5, 0)
	annHolder.Size = UDim2.fromOffset(annW, ANN_H)
	annHolder.ZIndex = 3
	annHolder.Parent = root
	annBanner = Instance.new("Frame")
	annBanner.Name = "Banner"
	centred(annBanner)
	annBanner.Visible = false
	tint(annBanner, Theme.Styles.purple.bottom, 16, 3)
	Theme.gloss(annBanner, 16)
	annBanner.Parent = annHolder
	annLabel, annStroke = bold(annBanner, "", 22, C.Ink, 2)
	annLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	annLabel.Position = UDim2.fromScale(0.5, 0.5)
	annLabel.Size = UDim2.new(1, -24, 1, -6)
	annLabel.TextWrapped = true
	fit(annLabel, 22, 12)
	Anim.shine(annBanner, 2.2) -- sweeps only while it's showing

	-- toasts (in the top screen, over the menus)
	toastBox = Instance.new("Frame")
	toastBox.Name = "Toasts"
	toastBox.BackgroundTransparency = 1
	toastBox.AnchorPoint = Vector2.new(0.5, 0)
	toastBox.Size = UDim2.fromOffset(toastW, 10)
	toastBox.Parent = topRoot
	Theme.list(toastBox, 6)
end

local function luckEnd(): number
	local t = if lastState then num(lastState.luckUntil) else 0
	local world = workspace:FindFirstChild("StealASock")
	local attr = if world then world:GetAttribute("LuckUntil") else nil -- set by the server on purchase
	if type(attr) == "number" and attr > t then
		t = attr
	end
	return t
end

local function showLuck()
	luckShown = true
	restack()
	luckChip.Position = UDim2.new(0.5, 0, 0.5, -80)
	luckChip.Visible = true
	Anim.tween(luckChip, 0.45, { Position = UDim2.fromScale(0.5, 0.5) })
	UISound.Play("whoosh")
	task.delay(0.5, function()
		if luckShown then
			Anim.pulse(luckChip, 1.06, 1.4)
		end
	end)
end

local function hideLuck()
	luckShown = false
	Anim.stop(luckChip, "pulse")
	Anim.scale(luckChip).Scale = 1
	local tw = Anim.tween(luckChip, 0.3, { Position = UDim2.new(0.5, 0, 0.5, -80) }, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
	tw.Completed:Once(function()
		if not luckShown then
			luckChip.Visible = false
		end
	end)
	restack()
end

local function refreshLuck(now: number)
	local left = luckEnd() - now
	if left > 0 then
		luckLabel.Text = "🍀 LUCK " .. clockText(left)
		if not luckShown then
			showLuck()
		end
	elseif luckShown then
		hideLuck()
	end
end

local function hideAnnounce()
	if not annShown then
		return
	end
	annShown = false
	annToken += 1
	local tw = Anim.tween(annBanner, 0.3, { Position = UDim2.new(0.5, 0, 0.5, -110) }, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
	tw.Completed:Once(function()
		if not annShown then
			annBanner.Visible = false
		end
	end)
	restack()
end

local TOAST_KINDS = {
	good = { style = "green", icon = "✔", sound = "whoosh" },
	bad = { style = "red", icon = "✖", sound = "error" },
	info = { style = "blue", icon = "ℹ", sound = "whoosh" },
}

local function closeToast(t: Toast)
	if t.closing then
		return
	end
	t.closing = true
	local i = table.find(toasts, t)
	if i then
		table.remove(toasts, i)
	end
	popAway(t.card, function()
		local tw = Anim.tween(t.holder, 0.22, { Size = UDim2.new(1, 0, 0, 0) }, Enum.EasingStyle.Quad)
		tw.Completed:Once(function()
			t.holder:Destroy()
		end)
	end)
end

local function scheduleClose(t: Toast)
	t.token += 1
	local token = t.token
	task.delay(TOAST_TIME, function()
		if t.token == token then
			closeToast(t)
		end
	end)
end

-- ---------- carry banner ----------

local function carryPos(shown: boolean): UDim2
	if shown then
		return UDim2.new(0.5, 0, 1, -carryBottom)
	end
	return UDim2.new(0.5, 0, 1, CARRY_H + 60)
end

local function buildCarry()
	carry = Instance.new("Frame")
	carry.Name = "Carry"
	carry.AnchorPoint = Vector2.new(0.5, 1) -- pulses grow up from the bottom edge
	carry.Size = UDim2.fromOffset(carryW, CARRY_H)
	carry.Position = carryPos(false)
	carry.Visible = false
	carry.ZIndex = 3
	tint(carry, Theme.Styles.red.bottom, 18, 3)
	Theme.gloss(carry, 18)
	carry.Parent = root
	carryLabel, carryStroke = bold(carry, "", 22, C.Ink, 2.5)
	carryLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	carryLabel.Position = UDim2.fromScale(0.5, 0.5)
	carryLabel.Size = UDim2.new(1, -28, 1, -8)
	carryLabel.TextWrapped = true -- two lines on narrow screens instead of tiny text
	fit(carryLabel, 24, 12)
	Anim.shine(carry, 3)
end

local function startCarryPulse(token: number)
	task.delay(0.6, function()
		if token == carryToken and carryKey then
			Anim.pulse(carry, 1.03, 1.3)
		end
	end)
end

-- ---------- celebrations ----------

local function buildCelebrate()
	celebLayer = Instance.new("Frame")
	celebLayer.Name = "Celebrations"
	celebLayer.BackgroundTransparency = 1
	celebLayer.Size = UDim2.fromScale(1, 1)
	celebLayer.ZIndex = 5
	celebLayer.Parent = topRoot
end

-- A centred candy card in `spec.color`: optional gold tag across the top edge, icon, title,
-- sub-line and a gold reward line. Tap it to dismiss early.
local function makeCard(spec: CardSpec): TextButton
	local _, _, edge = shades(spec.color)
	local width = math.min(if spec.big then 470 else 390, refWidth - 2 * EDGE)
	local card = Instance.new("TextButton")
	card.Name = "Celebration"
	card.Text = ""
	card.AutoButtonColor = false
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = if spec.big then UDim2.fromScale(0.5, 0.42) else UDim2.fromScale(0.5, 0.3)
	tint(card, spec.color, 24, 4)
	Theme.gloss(card, 24)

	local top = if spec.tag then 26 else 14
	local stack = Instance.new("Frame")
	stack.Name = "Stack"
	stack.BackgroundTransparency = 1
	stack.Position = UDim2.fromOffset(16, top)
	stack.Size = UDim2.new(1, -32, 1, -(top + 14))
	stack.ZIndex = 5
	stack.Parent = card
	local list = Theme.list(stack, 2)
	list.VerticalAlignment = Enum.VerticalAlignment.Center

	local height = top + 14
	local order = 0
	local function line(text: string, size: number, lineHeight: number, color: Color3, rim: Color3?)
		order += 1
		local t = Theme.label(stack, text, size, color)
		t.LayoutOrder = order
		t.Size = UDim2.new(1, 0, 0, lineHeight)
		t.ZIndex = 5
		fit(t, size, math.floor(size * 0.55))
		if rim then
			Theme.textStroke(t, rim, 2.5)
		end
		height += lineHeight + 2
	end
	if spec.icon then
		line(spec.icon, 40, 46, WHITE, nil)
	end
	line(spec.title, if spec.big then 36 else 32, if spec.big then 44 else 38, WHITE, edge)
	if spec.sub then
		line(spec.sub, 18, 24, WHITE, edge)
	end
	if spec.reward then
		line(spec.reward, 30, 36, GOLD_TEXT, C.Ink)
	end
	card.Size = UDim2.fromOffset(width, height)

	if spec.tag then
		local tag = Instance.new("Frame")
		tag.Name = "Tag"
		tag.AnchorPoint = Vector2.new(0.5, 0.5)
		tag.Position = UDim2.new(0.5, 0, 0, 0)
		tag.Size = UDim2.fromOffset(math.max(140, measure(spec.tag, 20) + 40), 36)
		tag.ZIndex = 8
		Theme.candy(tag, "gold", 18, 3)
		Theme.gloss(tag, 18)
		local tagText = Theme.label(tag, spec.tag, 20, Theme.Styles.gold.text)
		tagText.Size = UDim2.fromScale(1, 1)
		tagText.ZIndex = 5
		tag.Parent = card
		Anim.sway(tag, 4, 1.4)
	end

	card.Parent = celebLayer
	Anim.shine(card, 1.8)
	return card
end

-- Shows a card until it's tapped or `hold` runs out (yields; runs inside the queue).
local function playCard(spec: CardSpec, hold: number, onShown: ((TextButton) -> ())?)
	local card = makeCard(spec)
	local done = false
	card.Activated:Connect(function()
		done = true
	end)
	Anim.popIn(card)
	if onShown then
		task.delay(0.2, function()
			if card.Parent then
				onShown(card)
			end
		end)
	end
	local deadline = os.clock() + hold
	while not done and os.clock() < deadline do
		task.wait(0.05)
	end
	popAway(card, function()
		card:Destroy()
	end)
	task.wait(0.25)
end

local function screenCentre(): Vector2
	return Anim.centerOf(celebLayer)
end

local CELEBRATE = {} :: { [string]: (any) -> () }

CELEBRATE.dexNew = function(data)
	local rarity = tostring(data.rarity)
	local tier = RarityConfig.Tiers[rarity]
	local reward = num(data.reward)
	UISound.Play("newSock")
	playCard({
		color = Theme.RarityColor(rarity),
		tag = "NEW SOCK!",
		title = tostring(data.name or "New sock"),
		sub = Theme.RarityName(rarity),
		reward = if reward > 0 then "+" .. cashText(reward) else nil,
	}, 2.8, function(card)
		if reward > 0 then
			coinsToPill(card, coinCount(reward))
		end
		if tier and tier.rank >= 3 then
			Anim.confetti(Anim.centerOf(card), 70)
		end
	end)
end

CELEBRATE.pass = function(data)
	local pass = StoreConfig.Passes[tostring(data.key)]
	local display = tostring(data.display or (if pass then pass.display else "Game pass"))
	UISound.Play("confetti")
	Anim.confetti(nil, 110)
	playCard({
		color = if pass then pass.color else C.Gold2,
		icon = if pass then pass.icon else nil,
		title = "✨ " .. display .. " UNLOCKED! ✨",
		sub = if pass then pass.desc else nil,
		big = true,
	}, 3.5, function(card)
		Anim.confetti(Anim.centerOf(card), 60)
	end)
end

CELEBRATE.product = function(data)
	local key = tostring(data.key)
	local cash = num(data.cash)
	if cash > 0 then
		-- cash packs: a shower of coins into the pill and a big "+$X"
		UISound.Play("success")
		coinsToPill(screenCentre(), 14)
		task.wait(0.6)
		Anim.numberPop("+" .. cashText(cash), popPoint(), GOLD_TEXT, 36)
		task.wait(0.6)
	elseif key == "ServerLuck" then
		local product = StoreConfig.Products.ServerLuck
		local minutes = if product and product.minutes then product.minutes else 15
		UISound.Play("success")
		playCard({ color = rgb(88, 200, 110), title = "🍀 Server Luck!", sub = "Rarer socks for everyone for " .. minutes .. " min" }, 2.6, function(card)
			Anim.confetti(Anim.centerOf(card), 40)
		end)
	elseif key == "Relock" then
		UISound.Play("success")
		playCard({ color = rgb(255, 120, 90), title = "⚡ Drawer re-locked!", sub = "Thieves are shut out" }, 2.2)
	elseif key == "RareDrop" then
		-- only sent while the drop is waiting for a free slot; the landing itself is "rareDrop"
		playCard({ color = rgb(150, 90, 230), title = "🎁 Rare Sock Drop saved", sub = "It lands as soon as a slot is free" }, 2.4)
	else
		UISound.Play("success")
		playCard({ color = C.Gold2, title = tostring(data.display or "Thank you!"), sub = "Thanks for the support!" }, 2.2)
	end
end

CELEBRATE.milestone = function(data)
	local cash = num(data.cash)
	UISound.Play("confetti")
	Anim.confetti(nil, 90)
	playCard({
		color = rgb(255, 176, 48),
		tag = "MILESTONE!",
		title = tostring(data.display or "Sockdex milestone"),
		reward = if cash > 0 then "+" .. cashText(cash) else nil,
	}, 3, function(card)
		if cash > 0 and not Menu.IsOpen("Sockdex") then -- the Sockdex flies its own coins on a claim
			coinsToPill(card, coinCount(cash))
		end
	end)
end

CELEBRATE.rareDrop = function(data)
	local rarity = tostring(data.rarity)
	UISound.Play("confetti")
	playCard({
		color = Theme.RarityColor(rarity),
		tag = "RARE DROP!",
		title = "🎁 " .. tostring(data.name or "A rare sock"),
		sub = "landed in your drawer!",
	}, 3, function(card)
		Anim.confetti(Anim.centerOf(card), 80)
	end)
end

CELEBRATE.upgrade = function(data)
	local key = tostring(data.key)
	local upgrade = ShopConfig.Upgrades[key]
	local display = if upgrade then upgrade.display else key
	UISound.Play("pop")
	Anim.numberPop(display .. " Lv " .. math.floor(num(data.level)) .. "!", popPoint(), rgb(150, 236, 140), 28)
	task.wait(0.6)
end

-- One celebration at a time, in order.
local function enqueue(play: () -> ())
	if #queue >= QUEUE_MAX then
		return
	end
	table.insert(queue, play)
	if queueRunning then
		return
	end
	queueRunning = true
	task.spawn(function()
		while #queue > 0 do
			local nextPlay = table.remove(queue, 1)
			if nextPlay then
				local ok, err = pcall(nextPlay)
				if not ok then
					warn("[HUD] celebration failed: " .. tostring(err))
				end
			end
		end
		queueRunning = false
	end)
end

-- ---------- layout + loops ----------

-- The widest the chip row under the pill gets (longest texts), so the top-centre lanes can keep
-- clear of it.
local function measureLaneClear(): number
	local function chipW(texts: { string }): number
		local w = 0
		for _, text in ipairs(texts) do
			w = math.max(w, math.ceil(measure(text, CHIP_TEXT) + 26))
		end
		return w
	end
	local row = EDGE + 2 * CHIP_GAP
	row += chipW({ "+$88.8K/s" })
	row += chipW({ "🔒 LOCKED 888s", "⏳ Slam ready 88s", "🔓 Drawer open" })
	row += chipW({ "💰 $88.8K on pad" })
	return math.max(row, EDGE + PILL_W) + 10
end

-- Fits the HUD to the screen width (phones, portrait, UI size setting).
local function relayout()
	refWidth = root.AbsoluteSize.X / refScale()
	local room = refWidth - 2 * laneClear
	laneTight = room < 300
	luckLow = refWidth / 2 - LUCK_W / 2 < EDGE + PILL_W + 10
	if laneTight then
		toastW = math.min(460, refWidth - 2 * EDGE)
		annW = math.min(560, refWidth - 2 * EDGE)
	else
		toastW = math.min(460, room)
		annW = math.min(560, room)
	end
	if refWidth < 640 then -- portrait phone: full width, above the jump button
		carryW = refWidth - 2 * EDGE
		carryBottom = 170
	else
		carryW = math.clamp(refWidth - 2 * 260, 340, 500)
		carryBottom = CARRY_BOTTOM
	end
	drawerW = math.max(math.min(DRAWER_W, refWidth - DRAWER_X - EDGE), 200)
	drawer.Size = UDim2.new(0, drawerW, 1, -(DRAWER_Y + EDGE))
	if not drawerOpen then
		drawer.Position = drawerPos(false)
	end
	annHolder.Size = UDim2.fromOffset(annW, ANN_H)
	toastBox.Size = UDim2.fromOffset(toastW, 10)
	carry.Size = UDim2.fromOffset(carryW, CARRY_H)
	carry.Position = carryPos(carryKey ~= nil)
	restack(true)
end

-- Ambient loops (coin sway, pulses): restarted when Reduce motion flips, since Anim only checks it
-- when a loop starts.
local function refreshLoops()
	Anim.stop(coin, "sway")
	coin.Rotation = 0
	Anim.sway(coin, 6, 2.8)
	local pulsing = {} :: { { gui: GuiObject, amount: number, period: number } }
	if luckShown then
		table.insert(pulsing, { gui = luckChip, amount = 1.06, period = 1.4 })
	end
	if carryKey then
		table.insert(pulsing, { gui = carry, amount = 1.03, period = 1.3 })
	end
	if pendingRow then
		table.insert(pulsing, { gui = pendingRow.card, amount = 1.03, period = 1.6 })
	end
	for _, p in ipairs(pulsing) do
		Anim.stop(p.gui, "pulse")
		Anim.scale(p.gui).Scale = 1
		Anim.pulse(p.gui, p.amount, p.period)
	end
end

local luckCheckAt = 0
local function tick()
	local now = workspace:GetServerTimeNow()
	refreshLock(now)
	local clock = os.clock()
	if clock >= luckCheckAt then
		luckCheckAt = clock + 0.25
		refreshLuck(now)
	end
end

-- ---------- API ----------

function HUD.Init()
	if built then
		return
	end
	local _, mainRoot = Theme.screen("SockHUD", 5)
	root = mainRoot
	local _, overRoot = Theme.screen("SockHUDTop", 30) -- above SockMenu (10) and SockModal (20)
	topRoot = overRoot

	buildCash()
	buildChips()
	buildDrawer()
	buildTop()
	buildCarry()
	buildCelebrate()
	built = true

	laneClear = measureLaneClear()
	relayout()
	task.defer(relayout)
	root:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayout)
	local uiScale = root:FindFirstChild("SettingsScale")
	if uiScale and uiScale:IsA("UIScale") then
		uiScale:GetPropertyChangedSignal("Scale"):Connect(relayout) -- the UI size setting
	end

	ClientSettings.Changed:Connect(function(key, value)
		if key == "announcements" and value == false then
			hideAnnounce()
		elseif key == "reduceMotion" then
			refreshLoops()
		end
	end)
	refreshLoops()
	RunService.Heartbeat:Connect(tick)
end

function HUD.SetState(s)
	if not built or type(s) ~= "table" then
		return
	end
	local prev = lastState
	lastState = s
	updateCash(s, prev)
	updateChips(s, prev)
	refreshLock(workspace:GetServerTimeNow())
	updateDrawer(s, prev == nil)
	HUD.SetCarry(s.carrying)
end

function HUD.ToggleDrawer()
	if built then
		setDrawer(not drawerOpen, true)
	end
end

function HUD.SetCarry(view)
	if not built then
		return
	end
	local key = if type(view) == "table" and view.name ~= nil then tostring(view.name) .. "|" .. tostring(view.rarity) else nil
	if key == carryKey then
		return
	end
	local was = carryKey ~= nil
	carryKey = key
	carryToken += 1
	local token = carryToken
	if key then
		local color = Theme.RarityColor(tostring(view.rarity))
		local _, _, edge = shades(color)
		retint(carry, color)
		carryStroke.Color = edge
		carryLabel.Text = "🧦 Carrying " .. tostring(view.name) .. " — run to YOUR drawer!"
		if was then
			Anim.bump(carry, 1.06) -- swapped socks mid-run
		else
			Anim.stop(carry, "pulse")
			Anim.scale(carry).Scale = 1
			carry.Position = carryPos(false)
			carry.Visible = true
			Anim.tween(carry, 0.6, { Position = carryPos(true) }, Enum.EasingStyle.Back)
			UISound.Play("whoosh")
		end
		startCarryPulse(token)
	else
		Anim.stop(carry, "pulse")
		Anim.scale(carry).Scale = 1
		local tw = Anim.tween(carry, 0.3, { Position = carryPos(false) }, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
		tw.Completed:Once(function()
			if token == carryToken then
				carry.Visible = false
			end
		end)
	end
end

function HUD.Toast(text: string, kind: string?)
	if not built or type(text) ~= "string" or text == "" then
		return
	end
	local k = if kind == "good" or kind == "bad" then kind else "info"
	if k ~= "bad" and ClientSettings.Get("notifications") == false then
		return
	end
	-- the same message again: nudge the one that's up and keep it a little longer
	for _, t in ipairs(toasts) do
		if t.text == text then
			Anim.bump(t.card, 1.06)
			scheduleClose(t)
			return
		end
	end

	local spec = TOAST_KINDS[k]
	local st = Theme.Styles[spec.style]
	local textH = TextService:GetTextSize(text, 18, Theme.Font, Vector2.new(toastW - 66, 400)).Y
	local h = math.max(44, math.ceil(textH) + 18)
	toastCount += 1

	local holder = holderFrame("Toast", 0, -toastCount, toastBox) -- newest on top; grows open
	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0)
	card.Position = UDim2.new(0.5, 0, 0, -18)
	card.Size = UDim2.new(1, 0, 0, h)
	card.Active = true -- over an open panel, a tap on a toast mustn't reach the panel's backdrop
	Theme.candy(card, spec.style, 14, 3)
	Theme.gloss(card, 14)
	card.Parent = holder

	local badge = Instance.new("Frame")
	badge.Name = "Icon"
	badge.AnchorPoint = Vector2.new(0, 0.5)
	badge.Position = UDim2.new(0, 10, 0.5, 0)
	badge.Size = UDim2.fromOffset(30, 30)
	badge.BackgroundColor3 = WHITE
	badge.BorderSizePixel = 0
	badge.ZIndex = 5
	Theme.corner(badge, UDim.new(0.5, 0))
	Theme.stroke(badge, st.stroke, 2)
	badge.Parent = card
	local glyph = Theme.label(badge, spec.icon, 18, st.bottom)
	glyph.Size = UDim2.fromScale(1, 1)

	local label = bold(card, text, 18, st.stroke, 2)
	label.TextWrapped = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Position = UDim2.fromOffset(50, 0)
	label.Size = UDim2.new(1, -60, 1, 0)

	Anim.tween(holder, 0.25, { Size = UDim2.new(1, 0, 0, h) }, Enum.EasingStyle.Quad)
	Anim.tween(card, 0.4, { Position = UDim2.new(0.5, 0, 0, 0) }, Enum.EasingStyle.Back)
	Anim.popIn(card)
	UISound.Play(spec.sound)

	local t: Toast = { holder = holder, card = card, text = text, token = 0, closing = false }
	table.insert(toasts, t)
	while #toasts > TOAST_MAX do
		closeToast(toasts[1])
	end
	scheduleClose(t)
end

function HUD.Announce(text: string, color: Color3?)
	if not built or type(text) ~= "string" or text == "" then
		return
	end
	if ClientSettings.Get("announcements") == false then
		return
	end
	local c = if typeof(color) == "Color3" then color else Theme.Styles.purple.bottom
	local _, _, edge = shades(c)
	retint(annBanner, c)
	annStroke.Color = edge
	annLabel.Text = text
	annToken += 1
	local token = annToken
	if annShown then
		Anim.bump(annBanner, 1.05) -- a new one replaces the one that's up
	else
		annShown = true
		restack()
		annBanner.Position = UDim2.new(0.5, 0, 0.5, -110)
		annBanner.Visible = true
		Anim.tween(annBanner, 0.55, { Position = UDim2.fromScale(0.5, 0.5) }, Enum.EasingStyle.Back)
		UISound.Play("whoosh")
		task.delay(0.45, function()
			if token == annToken then
				Anim.wiggle(annBanner, 2.5)
			end
		end)
	end
	task.delay(ANNOUNCE_TIME, function()
		if token == annToken then
			hideAnnounce()
		end
	end)
end

-- Big moments from the server (Types.CelebrateKind). Queued so two never overlap.
function HUD.Celebrate(kind: string, data)
	if not built or type(data) ~= "table" then
		return
	end
	local play = CELEBRATE[kind]
	if not play then
		return
	end
	if kind == "upgrade" and Menu.IsOpen("Shop") then
		return -- the Shop pops its own "LEVEL n!" over the card
	end
	if num(data.cash) > 0 or num(data.reward) > 0 then
		celebrateCashUntil = os.clock() + 2.5 -- the cash pill's own "+$X" stays quiet for this one
	end
	enqueue(function()
		play(data)
	end)
end

return HUD
