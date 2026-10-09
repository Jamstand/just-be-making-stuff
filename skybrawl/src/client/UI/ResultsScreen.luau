--[[
    The results screen (menus design 5.10, mockup g), phase "Results". It
    is client-side and outlives the match: MatchClient opens it
    Config.Menu.ResultsDelay after "End" (show(data, summary), summary
    being what it copied from the match before "Leave" destroys it) and
    sets the phase; any phase change away from "Results" closes it.

    SkybrawlResultsBack (29, full bleed) is opaque (the menu sky tinted by
    the result: gold for a win / 1st, red for a loss, grey otherwise), so
    the arena vanishing at Cleanup and the camera re-park are never seen.
    SkybrawlResults (30, safe area): your legend, the banner (VICTORY,
    DEFEAT, DRAW, "2ND PLACE", MATCH ENDED) with the score chip, the
    scoreboard grouped by team (winners first), the rewards (XP bar from
    before to after, coins, event bonus, rating and the next tier, the
    missions the match moved), QUEUE AGAIN / REMATCH and MENU, and the
    "BACK TO MENU IN 0:20" countdown (MENU at 0).

    QUEUE AGAIN / bots REMATCH follow the live party (no party, or you lead
    it; otherwise disabled, "Leader queues") and re-render on PartyChanged;
    the server's QueueRequest check stays the authority. A custom room's
    host REMATCH starts the room once it is Open again (WAITING...
    meanwhile); anyone else's REMATCH goes back to the room screen. Every
    request waits until the match has let you go (ClientState.inMatch
    false). Success returns to the menu (the queue banner or the next
    select takes over); failure toasts and stays.

    Focus: an overlay layer that ignores Confirm for Config.Menu.InputGrace
    (mashing A to jump at the end of the fight can't press QUEUE AGAIN), and
    so does its Back (gamepad B is the heavy attack); QUEUE AGAIN / REMATCH
    <-> MENU, Back = MENU. A request waits at most 15 s (the auto return 5 s
    more than its 20 s while one is in flight).

    Phone: no legend, no DMG TAKEN column, compact rewards.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Legends = require(Shared.Legends)
local Net = require(Shared.Net)

local ClientState = require(script.Parent.Parent.ClientState)
local UIKit = require(script.Parent.UIKit)
local Focus = require(script.Parent.Focus)
local Layout = require(script.Parent.Layout)
local LegendView = require(script.Parent.LegendView)
local MenuShell = require(script.Parent.MenuShell)
local Models = require(script.Parent:WaitForChild("Match"):WaitForChild("Models"))

local T = UIKit.Theme
local make = UIKit.make

local ResultsScreen = {}

local player = Players.LocalPlayer

local TINTS = {
	Win = Color3.fromRGB(226, 160, 24),
	Loss = Color3.fromRGB(150, 14, 24),
	Neutral = Color3.fromRGB(90, 96, 110),
}
local BANNERS = {
	Win = { T.GoldLight, T.GoldDeep },
	Loss = { Color3.fromRGB(150, 18, 28), Color3.fromRGB(70, 6, 12) },
	Neutral = { Color3.fromRGB(120, 126, 140), Color3.fromRGB(60, 64, 76) },
}
local XP_SECONDS = 0.9
local REQUEST_WAIT = 15 -- seconds QUEUE AGAIN / REMATCH waits for the match to let you go, or for the room to reopen
local BUSY_EXTRA = 5 -- the auto return waits this much longer for a request still in flight

--[[
    Geometry (fractions of the safe-area canvas). Wide follows mockup g;
    columns are fractions of the scoreboard panel's width.
]]
local WIDE = {
	legend = { x = 0.15, feet = 0.99, body = 0.6 },
	banner = { x = 0.021, y = 0.056, w = 0.31, h = 0.12, size = 130, chip = 22 },
	board = { x = 0.333, y = 0.089, w = 0.646, h = 0.463, title = 40, info = 20, head = 16 },
	columns = {
		{ key = "kos", label = "KOs", x = 0.61 },
		{ key = "falls", label = "FALLS", x = 0.71 },
		{ key = "damageDealt", label = "DMG DEALT", x = 0.815 },
		{ key = "damageTaken", label = "DMG TAKEN", x = 0.92, muted = true },
	},
	row = { top = 0.2, h = 0.165, gap = 0.016, groupGap = 0.03, name = 28, number = 38, letter = 40 },
	rewards = { x = 0.333, y = 0.57, w = 0.646, h = 0.25, title = 40, label = 16, big = 80, coins = 48, rating = 90 },
	buttons = { y = 0.854, h = 0.078, primary = { x = 0.365, w = 0.224 }, menu = { x = 0.609, w = 0.156 }, size = 54 },
	footer = { x = 0.98, y = 0.962, size = 22, right = true },
	phone = false,
}

local PHONE = {
	legend = nil,
	banner = { x = 0.0, y = 0.03, w = 0.34, h = 0.15, size = 54, chip = 18 },
	-- (below the Roblox top bar, about 0.17 of a phone's safe area; text in design px, which Layout.px enlarges)
	board = { x = 0.36, y = 0.17, w = 0.64, h = 0.45, title = 24, info = 16, head = 14 },
	columns = {
		{ key = "kos", label = "KOs", x = 0.6 },
		{ key = "falls", label = "FALLS", x = 0.73 },
		{ key = "damageDealt", label = "DMG", x = 0.88 },
	},
	row = { top = 0.2, h = 0.175, gap = 0.012, groupGap = 0.025, name = 20, number = 26, letter = 26 },
	rewards = { x = 0.0, y = 0.635, w = 1.0, h = 0.2, title = 24, label = 15, big = 40, coins = 30, rating = 40 },
	buttons = { y = 0.855, h = 0.12, primary = { x = 0.17, w = 0.36 }, menu = { x = 0.57, w = 0.24 }, size = 30 },
	footer = { x = 0.01, y = 0.5, size = 16, right = false },
	phone = true,
}

local screen = nil -- the open screen

-- Helpers ------------------------------------------------------------------------------

-- A TextLabel sized through Layout.bindText (size in design px); props first (Size included).
local function text(content, size, props)
	local label = make("TextLabel", {
		BackgroundTransparency = 1,
		Text = content or "",
		Font = T.BodyFont,
		TextColor3 = T.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		Size = UDim2.fromScale(1, 1),
	})
	local parent = nil
	for key, value in props or {} do
		if key == "Parent" then
			parent = value
		else
			label[key] = value
		end
	end
	Layout.bindText(label, size)
	label.Parent = parent
	return label
end

local function textStroke(label, thickness, color)
	local stroke = make("UIStroke", {
		Color = color or T.Outline,
		LineJoinMode = Enum.LineJoinMode.Round,
		Parent = label,
	})
	Layout.bindStroke(stroke, thickness)
	return stroke
end

local function box(name, parent, x, y, w, h, zIndex)
	return make("Frame", {
		Name = name,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromScale(x, y),
		Size = UDim2.fromScale(w, h),
		ZIndex = zIndex or 1,
		Parent = parent,
	})
end

local function fill(name, parent, color, props)
	local frame = make("Frame", {
		Name = name,
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Parent = parent,
	})
	for key, value in props or {} do
		frame[key] = value
	end
	return frame
end

local function guis()
	local playerGui = player:WaitForChild("PlayerGui")
	local back = playerGui:FindFirstChild("SkybrawlResultsBack") or Layout.screenGui("SkybrawlResultsBack", 29, "Full")
	local front = playerGui:FindFirstChild("SkybrawlResults") or Layout.screenGui("SkybrawlResults", 30, "Safe")
	return back, front
end

-- A RemoteFunction call that never throws.
local function invoke(remoteName, ...)
	local args = table.pack(...)
	local ok, a, b = pcall(function()
		return Net.get(remoteName):InvokeServer(table.unpack(args, 1, args.n))
	end)
	if not ok then
		warn("[ResultsScreen] " .. remoteName .. " failed:", a)
		return false, "Couldn't reach the server."
	end
	return a, b
end

-- Runs fn once the match has let you go (requests sent before "Leave" would be refused as busy), or onTimeout.
local function whenOutOfMatch(fn, onTimeout)
	if not ClientState.inMatch then
		fn()
		return
	end
	local done = false
	local conn
	conn = ClientState.MatchChanged:Connect(function(inMatch)
		if not inMatch and not done then
			done = true
			conn.Disconnect()
			fn()
		end
	end)
	task.delay(REQUEST_WAIT, function()
		if not done then
			done = true
			conn.Disconnect()
			onTimeout()
		end
	end)
end

-- Banner and legend ------------------------------------------------------------------------

local function buildBanner(sc, L)
	local B = L.banner
	local banner = Models.banner(sc.data)
	-- an unrotated holder (kept clear of the top bar) around the rotated decorations
	local holder = box("Banner", sc.root, B.x, B.y, B.w, B.h * 1.75, 20)
	local plate = fill("Plate", holder, Color3.new(1, 1, 1), {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.29),
		Size = UDim2.fromScale(1, 0.57),
		Rotation = -4,
		ZIndex = 21,
	})
	make("UIGradient", {
		Color = ColorSequence.new(BANNERS[banner.tone][1], BANNERS[banner.tone][2]),
		Rotation = 90,
		Parent = plate,
	})
	local edge = make("UIStroke", { Color = T.Outline, Parent = plate })
	Layout.bindStroke(edge, 6)
	fill("Shadow", holder, T.Outline, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, Layout.px(10), 0.29, Layout.px(12)),
		Size = UDim2.fromScale(1, 0.57),
		Rotation = -4,
		BackgroundTransparency = 0.35,
		ZIndex = 20,
	})
	local title = text(banner.text, B.size, {
		Name = "Text",
		Font = Enum.Font.LuckiestGuy,
		TextXAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.29),
		Size = UDim2.fromScale(0.96, 0.6),
		Rotation = -4,
		ZIndex = 22,
		Parent = holder,
	})
	textStroke(title, 8)
	local subtitle = Models.subtitle(sc.data)
	if subtitle then
		local chip = fill("Chip", holder, T.Backdrop, {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.6, 0.78),
			Size = UDim2.fromScale(0.62, 0.22),
			Rotation = -4,
			ZIndex = 23,
		})
		text(subtitle, B.chip, {
			Name = "Text",
			Font = T.BlackFont,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromScale(0.04, 0),
			Size = UDim2.fromScale(0.92, 1),
			ZIndex = 24,
			Parent = chip,
		})
	end
	Layout.clearTop(holder, holder.Position)
end

local function buildLegend(sc, L)
	if not L.legend then
		return
	end
	local G = L.legend
	local height = G.body / 0.66
	local summary = sc.summary or {}
	local legend = if Legends.isValid(summary.legend) then summary.legend else Legends.Default
	sc.view = LegendView.new(sc.root, {
		framing = "Full",
		facing = "Right",
		animated = true,
		anchor = Vector2.new(0.5, 1),
		position = UDim2.fromScale(G.x, G.feet + 0.04 * height),
		size = UDim2.fromScale(height * 0.8, height),
		zIndex = 2,
	})
	sc.view:set({ legend = legend, userId = player.UserId, ownLook = summary.ownLook == true, flourish = true })
end

-- Scoreboard ----------------------------------------------------------------------------------

local function portraitSpec(sc, row)
	local fighter = sc.summary and sc.summary.fighters and sc.summary.fighters[row.id]
	local legend = row.legend or (fighter and fighter.legend)
	return {
		legend = if Legends.isValid(legend) then legend else "Avatar",
		userId = if row.userId and row.userId ~= 0 then row.userId else (fighter and fighter.userId) or 0,
		ownLook = row.ownLook == true,
	}
end

local function buildRow(sc, L, parent, entry, y, h)
	local R = L.row
	local row = entry.row
	local mine = row.id == sc.data.you
	local teamColor = Config.TeamColors[row.team] or T.Stroke
	local frame = fill("Row" .. row.id, parent, if mine then T.Raised:Lerp(Color3.new(1, 1, 1), 0.06) else T.Raised, {
		Position = UDim2.fromScale(0.015, y),
		Size = UDim2.fromScale(0.97, h),
		ZIndex = 6,
	})
	fill("Team", frame, teamColor, { Size = UDim2.new(0, math.max(3, Layout.px(6)), 1, 0), ZIndex = 7 })
	local letter = text(entry.letter, R.letter, {
		Name = "Letter",
		Font = Enum.Font.Bangers,
		TextColor3 = teamColor,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromScale(0.012, 0),
		Size = UDim2.fromScale(0.05, 1),
		ZIndex = 7,
		Parent = frame,
	})
	letter.Name = "Letter"
	local portraitBox = make("Frame", {
		Name = "PortraitBox",
		BackgroundColor3 = T.Backdrop,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0.07, 0.5),
		Size = UDim2.fromScale(0.78, 0.78),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		ClipsDescendants = true,
		ZIndex = 7,
		Parent = frame,
	})
	local border = make("UIStroke", { Color = T.Outline, Parent = portraitBox })
	Layout.bindStroke(border, 2)
	local portrait = LegendView.portrait(portraitBox, portraitSpec(sc, row), { zIndex = 8 })
	table.insert(sc.portraits, portrait)
	local nameRow = make("Frame", {
		Name = "NameRow",
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(0.15, 0),
		Size = UDim2.fromScale(0.42, 1),
		ZIndex = 7,
		Parent = frame,
	})
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, Layout.px(12)),
		Parent = nameRow,
	})
	text(row.name .. (if row.isBot then " (Bot)" else ""), R.name, {
		Name = "Name",
		Font = T.BoldFont,
		TextTruncate = Enum.TextTruncate.AtEnd,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromScale(0, 0.6),
		LayoutOrder = 1,
		ZIndex = 7,
		Parent = nameRow,
	})
	local function chip(label, color, textColor, order)
		local holder = make("Frame", {
			Name = "Chip",
			BackgroundTransparency = 1,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromScale(0, 0.34),
			LayoutOrder = order,
			ZIndex = 8,
			Parent = nameRow,
		})
		UIKit.tag(label, { parent = holder, fill = color, textColor = textColor, size = R.name * 0.55, zIndex = 8 })
	end
	if row.mvp or row.id == sc.data.mvpId then
		chip("♛ MVP", T.Gold, T.GoldDark, 2)
	end
	if row.left then
		chip("LEFT", T.Danger, T.Text, 3)
	end
	for _, column in L.columns do
		local value = row[column.key]
		text(tostring(math.floor(tonumber(value) or 0)), R.number, {
			Name = column.key,
			Font = Enum.Font.LuckiestGuy,
			TextColor3 = if column.muted then T.Muted else T.Text,
			TextXAlignment = Enum.TextXAlignment.Center,
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(column.x, 0),
			Size = UDim2.fromScale(0.1, 1),
			ZIndex = 7,
			Parent = frame,
		})
	end
end

local function buildBoard(sc, L)
	local Bd = L.board
	local panel = UIKit.cutPanel({
		parent = sc.root,
		position = UDim2.fromScale(Bd.x, Bd.y),
		size = UDim2.fromScale(Bd.w, Bd.h),
		title = "MATCH RESULTS",
		titleSize = Bd.title,
		zIndex = 5,
	})
	panel.Name = "Scoreboard"
	text(Models.resultsHeader(sc.data), Bd.info, {
		Name = "Info",
		Font = T.BoldFont,
		TextColor3 = T.Muted,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(0.985, 0.035),
		Size = UDim2.fromScale(0.5, 0.06),
		ZIndex = 7,
		Parent = panel,
	})
	-- column heads, in the panel (the body starts under the title)
	text("PLAYER", Bd.head, {
		Name = "HeadPlayer",
		Font = T.BlackFont,
		TextColor3 = T.Muted,
		Position = UDim2.fromScale(0.15, 0.12),
		Size = UDim2.fromScale(0.3, 0.05),
		ZIndex = 7,
		Parent = panel,
	})
	for _, column in L.columns do
		text(column.label, Bd.head, {
			Name = "Head" .. column.key,
			Font = T.BlackFont,
			TextColor3 = T.Muted,
			TextXAlignment = Enum.TextXAlignment.Center,
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(column.x, 0.12),
			Size = UDim2.fromScale(0.12, 0.05),
			ZIndex = 7,
			Parent = panel,
		})
	end
	local R = L.row
	local y = R.top
	for g, group in Models.resultGroups(sc.data) do
		if g > 1 then
			y += if sc.data.mode == "FFA" then R.gap else R.groupGap
		end
		for i, entry in group.rows do
			if i > 1 then
				y += R.gap
			end
			buildRow(sc, L, panel, entry, y, R.h)
			y += R.h
		end
	end
end

-- Rewards ---------------------------------------------------------------------------------------

local function label(parent, content, size, x, y, w, h)
	return text(content, size, {
		Name = "Label",
		Font = T.BlackFont,
		TextColor3 = T.Muted,
		Position = UDim2.fromScale(x, y),
		Size = UDim2.fromScale(w, h),
		ZIndex = 7,
		Parent = parent,
	})
end

-- The XP bar and its percent: animate from before to after (through a full bar and a "LEVEL UP!" flash on a
-- level up).
local function animateXp(sc, setBar, percent, levelLabel, levelUpTag, xp)
	local function show(v)
		setBar(v)
		percent.Text = string.format("%d%%", math.floor(math.clamp(v, 0, 1) * 100))
	end
	local value = make("NumberValue", { Value = xp.fromFraction })
	value.Changed:Connect(show)
	show(xp.fromFraction)
	task.delay(0.4, function()
		if screen ~= sc then
			return
		end
		if not xp.levelUp then
			TweenService:Create(value, TweenInfo.new(XP_SECONDS), { Value = xp.toFraction }):Play()
			return
		end
		TweenService:Create(value, TweenInfo.new(XP_SECONDS * 0.6), { Value = 1 }):Play()
		task.delay(XP_SECONDS * 0.6 + 0.03, function()
			if screen ~= sc then
				return
			end
			-- the level up: the bar starts again from empty on the new level
			value.Value = 0
			levelLabel.Text = "LV " .. xp.levelAfter
			levelUpTag.Visible = true
			TweenService:Create(value, TweenInfo.new(XP_SECONDS * 0.4), { Value = xp.toFraction }):Play()
		end)
	end)
	sc.cleanups = sc.cleanups or {}
	table.insert(sc.cleanups, value)
end

local function buildRewards(sc, L)
	local Rw = L.rewards
	local panel = UIKit.cutPanel({
		parent = sc.root,
		position = UDim2.fromScale(Rw.x, Rw.y),
		size = UDim2.fromScale(Rw.w, Rw.h),
		title = "REWARDS",
		titleSize = Rw.title,
		zIndex = 5,
	})
	panel.Name = "Rewards"
	local rewards = sc.data.rewards
	local you = Models.yourRow(sc.data)
	if type(rewards) ~= "table" then
		label(panel, "No rewards this time.", Rw.label * 1.4, 0.03, 0.45, 0.9, 0.2)
		return
	end
	local chipText = Models.eventChip(rewards)
	if chipText then
		local holder = make("Frame", {
			Name = "EventChip",
			BackgroundTransparency = 1,
			Position = UDim2.fromScale(0.2, 0.06),
			Size = UDim2.fromScale(0.6, 0.12),
			ZIndex = 7,
			Parent = panel,
		})
		UIKit.tag(chipText, { parent = holder, fill = Color3.fromRGB(120, 70, 170), size = Rw.label * 1.1, zIndex = 7 })
	end
	local phone = L.phone
	-- EXPERIENCE + coins
	local xpCol = box("Experience", panel, 0.02, 0.24, if phone then 0.3 else 0.31, 0.74, 6)
	label(xpCol, "EXPERIENCE", Rw.label, 0, 0, 1, 0.13)
	local xpLine = make("Frame", {
		Name = "XpLine",
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(0, 0.13),
		Size = UDim2.fromScale(1, 0.38),
		ZIndex = 6,
		Parent = xpCol,
	})
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Bottom,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, Layout.px(8)),
		Parent = xpLine,
	})
	text("+" .. math.floor(rewards.xp or 0), Rw.big, {
		Name = "XpGain",
		Font = Enum.Font.LuckiestGuy,
		TextColor3 = T.XP,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromScale(0, 1),
		LayoutOrder = 1,
		ZIndex = 7,
		Parent = xpLine,
	})
	text("XP", Rw.label * 1.4, {
		Name = "XpUnit",
		Font = T.BlackFont,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromScale(0, 0.45),
		LayoutOrder = 2,
		ZIndex = 7,
		Parent = xpLine,
	})
	local xp = Models.xpBar(rewards)
	local levelBox = make("Frame", {
		Name = "Level",
		BackgroundColor3 = T.Backdrop,
		BorderSizePixel = 0,
		Position = UDim2.fromScale(0, 0.52),
		Size = UDim2.fromScale(0.2, 0.12),
		ZIndex = 7,
		Parent = xpCol,
	})
	local levelLabel = text("LV " .. xp.levelBefore, Rw.label, {
		Name = "Text",
		Font = T.BlackFont,
		TextXAlignment = Enum.TextXAlignment.Center,
		ZIndex = 8,
		Parent = levelBox,
	})
	local bar, setBar = UIKit.progressBar({
		parent = xpCol,
		fill = T.XP,
		back = T.Backdrop,
		position = UDim2.fromScale(0.23, 0.55),
		size = UDim2.fromScale(0.58, 0.06),
		zIndex = 7,
	})
	bar.Name = "XpBar"
	local percent = text(xp.percent, Rw.label, {
		Name = "Percent",
		Font = T.BlackFont,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.fromScale(0.82, 0.52),
		Size = UDim2.fromScale(0.18, 0.12),
		ZIndex = 7,
		Parent = xpCol,
	})
	local levelUpHolder = make("Frame", {
		Name = "LevelUp",
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(0.5, 0.0),
		Size = UDim2.fromScale(0.5, 0.13),
		Visible = false,
		ZIndex = 8,
		Parent = xpCol,
	})
	UIKit.tag(
		"LEVEL UP!",
		{ parent = levelUpHolder, fill = T.Gold, textColor = T.GoldDark, size = Rw.label, zIndex = 8 }
	)
	animateXp(sc, setBar, percent, levelLabel, levelUpHolder, xp)
	-- coins
	local coinLine = make("Frame", {
		Name = "Coins",
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(0, 0.7),
		Size = UDim2.fromScale(1, 0.28),
		ZIndex = 6,
		Parent = xpCol,
	})
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, Layout.px(10)),
		Parent = coinLine,
	})
	local coin = fill("CoinIcon", coinLine, T.Gold, {
		Size = UDim2.fromScale(0.8, 0.8),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		LayoutOrder = 1,
		ZIndex = 7,
	})
	make("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = coin })
	local coinEdge = make("UIStroke", { Color = T.GoldDeep, Parent = coin })
	Layout.bindStroke(coinEdge, 3)
	text("+" .. math.floor(rewards.coins or 0), Rw.coins, {
		Name = "CoinGain",
		Font = Enum.Font.LuckiestGuy,
		TextColor3 = T.Gold,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromScale(0, 1),
		LayoutOrder = 2,
		ZIndex = 7,
		Parent = coinLine,
	})
	local reason = if (rewards.coins or 0) == 0 and (rewards.xp or 0) == 0
		then "Match was too short for rewards."
		else Models.coinReason(you, sc.data)
	text(reason, Rw.label * 1.2, {
		Name = "Reason",
		Font = T.BoldFont,
		TextColor3 = T.Muted,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromScale(0, 0.6),
		LayoutOrder = 3,
		ZIndex = 7,
		Parent = coinLine,
	})

	-- RATING (ranked only)
	local rating = Models.ratingBar(rewards)
	if rating then
		local col = box("Rating", panel, if phone then 0.35 else 0.36, 0.24, if phone then 0.3 else 0.3, 0.74, 6)
		label(col, rating.mode, Rw.label, 0, 0, 1, 0.13)
		local badgeBox = make("Frame", {
			Name = "TierBox",
			BackgroundTransparency = 1,
			Position = UDim2.fromScale(0, 0.15),
			Size = UDim2.fromScale(0.42, 0.42),
			SizeConstraint = Enum.SizeConstraint.RelativeYY,
			ZIndex = 7,
			Parent = col,
		})
		UIKit.tierBadge(rating.tier.Name, { parent = badgeBox, zIndex = 7 })
		local numbers = make("Frame", {
			Name = "Numbers",
			BackgroundTransparency = 1,
			Position = UDim2.fromScale(0.26, 0.13),
			Size = UDim2.fromScale(0.74, 0.34),
			ZIndex = 6,
			Parent = col,
		})
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, Layout.px(10)),
			Parent = numbers,
		})
		text(tostring(rating.rating), Rw.rating, {
			Name = "RatingValue",
			Font = Enum.Font.LuckiestGuy,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromScale(0, 1),
			LayoutOrder = 1,
			ZIndex = 7,
			Parent = numbers,
		})
		text(rating.deltaText, Rw.rating * 0.48, {
			Name = "Delta",
			Font = Enum.Font.LuckiestGuy,
			TextColor3 = if rating.delta >= 0 then T.Good else T.Danger,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromScale(0, 0.6),
			LayoutOrder = 2,
			ZIndex = 7,
			Parent = numbers,
		})
		text(rating.tierName, Rw.label * 1.3, {
			Name = "TierName",
			Font = T.BlackFont,
			TextColor3 = rating.tier.Color,
			Position = UDim2.fromScale(0.26, 0.47),
			Size = UDim2.fromScale(0.74, 0.12),
			ZIndex = 7,
			Parent = col,
		})
		local tierBar, setTierBar = UIKit.progressBar({
			parent = col,
			fill = T.Good,
			back = T.Backdrop,
			position = UDim2.fromScale(0, 0.72),
			size = UDim2.fromScale(0.62, 0.06),
			zIndex = 7,
		})
		tierBar.Name = "TierBar"
		setTierBar(rating.fraction)
		text(rating.nextText, Rw.label, {
			Name = "Next",
			Font = T.BlackFont,
			TextColor3 = T.Gold,
			TextXAlignment = Enum.TextXAlignment.Right,
			Position = UDim2.fromScale(0.64, 0.68),
			Size = UDim2.fromScale(0.36, 0.14),
			ZIndex = 7,
			Parent = col,
		})
	end

	-- MISSIONS
	local missions = Models.missionRows(rewards)
	if #missions > 0 then
		local col = box("Missions", panel, if phone then 0.68 else 0.69, 0.24, if phone then 0.3 else 0.295, 0.74, 6)
		label(col, "MISSIONS", Rw.label, 0, 0, 1, 0.13)
		local shown = if phone then 1 else #missions
		for i = 1, shown do
			local m = missions[i]
			local accent = if m.done then T.Good else T.Red
			local rowFrame = fill("Mission" .. i, col, T.Raised, {
				Position = UDim2.fromScale(0, 0.16 + (i - 1) * 0.42),
				Size = UDim2.fromScale(1, 0.38),
				ZIndex = 7,
			})
			fill("Accent", rowFrame, accent, { Size = UDim2.new(0, math.max(3, Layout.px(5)), 1, 0), ZIndex = 8 })
			text(m.text, Rw.label * 1.15, {
				Name = "Text",
				Font = T.BoldFont,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Position = UDim2.fromScale(0.05, 0.05),
				Size = UDim2.fromScale(0.92, 0.48),
				ZIndex = 8,
				Parent = rowFrame,
			})
			local _, setMission = UIKit.progressBar({
				parent = rowFrame,
				fill = accent,
				back = T.Backdrop,
				position = UDim2.fromScale(0.05, 0.66),
				size = UDim2.fromScale(0.72, 0.12),
				zIndex = 8,
			})
			setMission(m.fraction)
			text(m.label, Rw.label, {
				Name = "Progress",
				Font = T.BlackFont,
				TextColor3 = if m.done then T.Good else T.Text,
				TextXAlignment = Enum.TextXAlignment.Right,
				Position = UDim2.fromScale(0.78, 0.55),
				Size = UDim2.fromScale(0.19, 0.36),
				ZIndex = 8,
				Parent = rowFrame,
			})
		end
	end
end

-- Buttons ------------------------------------------------------------------------------------

local function close()
	local sc = screen
	if not sc then
		return
	end
	screen = nil
	if sc.layer then
		Focus.popLayer(sc.layer)
	end
	for _, conn in sc.conns do
		conn.Disconnect()
	end
	if sc.view then
		sc.view:destroy()
	end
	for _, portrait in sc.portraits do
		portrait.destroy()
	end
	for _, obj in sc.cleanups or {} do
		obj:Destroy()
	end
	for _, rootFrame in { sc.root, sc.backRoot } do
		if rootFrame then
			rootFrame:Destroy()
		end
	end
end

-- Back to the menu (only from the results: a select that took over keeps its phase).
local function toMenu(sc)
	if screen == sc and ClientState.phase == "Results" then
		ClientState.setPhase("Menu")
	end
end

local function setButtonText(button, value)
	local labelObj = button:FindFirstChild("Label", true)
	if labelObj and labelObj:IsA("TextLabel") then
		labelObj.Text = value
	elseif button:IsA("TextButton") then
		button.Text = value
	end
end

local renderButtons -- (below)

--[[
    The QUEUE AGAIN / REMATCH request. It waits (at most REQUEST_WAIT) for
    the match to let you go, and a host's REMATCH for the room to reopen;
    a failure toasts and re-renders the buttons from the live party and
    room (a leadership change that came while busy applies then).
]]
local function runPrimary(sc, button, primary)
	if sc.busy then
		return
	end
	sc.busy = true
	UIKit.setEnabled(button, false)
	local post = sc.data.postMatch or {}
	local finished = false
	local function finish(ok, message)
		if finished or screen ~= sc then
			return
		end
		finished = true
		sc.busy = false
		if ok then
			toMenu(sc)
		else
			ClientState.toast(message or "Couldn't do that right now.", "error")
			sc.primaryKey = nil
			renderButtons(sc)
		end
	end
	whenOutOfMatch(function()
		if screen ~= sc then
			return
		end
		if primary.kind == "Queue" then
			finish(invoke("QueueRequest", "Join", post.queueType))
		elseif primary.kind == "Bots" then
			finish(invoke("QueueRequest", "Join", "Bots", post.botOptions))
		elseif primary.kind == "RoomBack" then
			finished = true
			sc.busy = false
			toMenu(sc)
			ClientState.OpenScreen:Fire("CustomRooms", { view = "Room" })
		elseif primary.kind == "RoomStart" then
			local function start()
				if screen == sc then
					finish(invoke("RoomRequest", "Start"))
				end
			end
			local room = ClientState.room
			if type(room) == "table" and room.state == "Open" then
				start()
				return
			end
			setButtonText(button, "WAITING...")
			local waiting = true
			local conn
			conn = ClientState.RoomChanged:Connect(function(newRoom)
				if not waiting then
					return
				elseif screen ~= sc then
					waiting = false
					conn.Disconnect()
				elseif type(newRoom) ~= "table" or newRoom.id ~= post.roomId then
					-- the room closed or you left it
					waiting = false
					conn.Disconnect()
					finish(false, "The room is gone.")
				elseif newRoom.state == "Open" then
					waiting = false
					conn.Disconnect()
					start()
				end
			end)
			table.insert(sc.conns, conn)
			task.delay(REQUEST_WAIT, function()
				if waiting then
					waiting = false
					conn.Disconnect()
					finish(false, "The room isn't ready yet. Try again.")
				end
			end)
		end
	end, function()
		finish(false, "The match is still closing. Try again.")
	end)
end

-- (Re)builds QUEUE AGAIN / REMATCH and MENU from the live party and room (keys keep the focus).
function renderButtons(sc)
	local L = sc.layout
	local Bt = L.buttons
	local buttons = Models.resultButtons(sc.data, {
		party = ClientState.party,
		userId = player.UserId,
		room = ClientState.room,
	})
	local primary = buttons.primary
	local key = if primary then primary.kind .. "|" .. tostring(primary.enabled) else "none"
	if sc.busy or key == sc.primaryKey then
		-- (a request in flight keeps its button)
		return
	end
	sc.primaryKey = key
	if sc.primaryButton then
		sc.primaryButton:Destroy()
		sc.primaryButton = nil
	end
	if primary then
		local button = UIKit.slantButton(primary.label, {
			style = "primary",
			parent = sc.root,
			position = UDim2.fromScale(Bt.primary.x, Bt.y),
			size = UDim2.fromScale(Bt.primary.w, Bt.h),
			textSize = Bt.size,
			sublabel = primary.note,
			name = "ResultsPrimary",
			zIndex = 30,
		}, function(pressed)
			runPrimary(sc, pressed, primary)
		end)
		UIKit.setEnabled(button, primary.enabled)
		sc.primaryButton = button
	end
	if not sc.menuButton then
		sc.menuButton = UIKit.slantButton("MENU", {
			style = "dark",
			parent = sc.root,
			position = UDim2.fromScale(Bt.menu.x, Bt.y),
			size = UDim2.fromScale(Bt.menu.w, Bt.h),
			textSize = Bt.size,
			glyph = "Back",
			name = "ResultsMenu",
			zIndex = 30,
		}, function()
			toMenu(sc)
		end)
	end
	if sc.primaryButton then
		Focus.linkRow({ sc.primaryButton, sc.menuButton })
	else
		Focus.link(sc.menuButton, "Left", nil)
	end
end

-- Show / hide -------------------------------------------------------------------------------------

local function build(sc)
	local L = if Layout.mode() == "Phone" then PHONE else WIDE
	sc.layout = L
	local backGui, frontGui = guis()
	local banner = Models.banner(sc.data)
	sc.backRoot = MenuShell.buildBackdrop(backGui, TINTS[banner.tone])
	sc.backRoot.Name = "ResultsBack"
	sc.root = make("Frame", {
		Name = "Results",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = frontGui,
	})
	buildLegend(sc, L)
	buildBanner(sc, L)
	buildBoard(sc, L)
	buildRewards(sc, L)
	renderButtons(sc)
	local F = L.footer
	sc.footer = text("", F.size, {
		Name = "AutoReturn",
		Font = T.BlackFont,
		TextColor3 = T.Muted,
		TextXAlignment = if F.right then Enum.TextXAlignment.Right else Enum.TextXAlignment.Left,
		AnchorPoint = Vector2.new(if F.right then 1 else 0, 0.5),
		Position = UDim2.fromScale(F.x, F.y),
		Size = UDim2.fromScale(0.3, 0.04),
		ZIndex = 30,
		Parent = sc.root,
	})
	sc.layer = Focus.pushLayer({
		name = "Results",
		roots = { sc.root },
		band = "overlay",
		confirmDelay = Config.Menu.InputGrace,
		defaultFocus = function()
			local primary = sc.primaryButton
			if primary and not primary:GetAttribute("Disabled") then
				return primary
			end
			return sc.menuButton
		end,
		onBack = function()
			-- Back is gamepad B, the heavy attack: mashing it as the fight ends mustn't leave at once (the layer's
			-- confirmDelay holds back only Confirm)
			if os.clock() - sc.openedAt >= Config.Menu.InputGrace then
				toMenu(sc)
			end
		end,
	})
end

function ResultsScreen.hide()
	close()
end

--[[
    Opens the results for `data` (the End payload, 3.2) with `summary`
    (copied from the match at End: mapId, mode, source, you, legend,
    ownLook, fighters[id] = { name, legend, ownLook, userId, team }).
    Returns true when the screen is up (MatchClient then sets the phase to
    "Results"); false when it couldn't be built (nothing is left open, so
    the player is never stuck on a screen without a way back).
]]
function ResultsScreen.show(data, summary)
	close()
	if type(data) ~= "table" then
		return false
	end
	local sc = {
		data = data,
		summary = summary,
		conns = {},
		portraits = {},
		openedAt = os.clock(),
		busy = false,
	}
	screen = sc
	local ok, err = pcall(build, sc)
	if not ok then
		warn("[ResultsScreen] build failed:", err)
		close()
		return false
	end
	table.insert(
		sc.conns,
		ClientState.PartyChanged:Connect(function()
			if screen == sc then
				renderButtons(sc)
			end
		end)
	)
	table.insert(
		sc.conns,
		ClientState.RoomChanged:Connect(function()
			if screen == sc then
				renderButtons(sc)
			end
		end)
	)
	return true
end

function ResultsScreen.init()
	ClientState.PhaseChanged:Connect(function(phase)
		if phase ~= "Results" and screen then
			close()
		end
	end)
	-- the auto return countdown (a request in flight gets BUSY_EXTRA more seconds)
	RunService.Heartbeat:Connect(function()
		local sc = screen
		if not sc then
			return
		end
		local left = Config.Menu.ResultsAutoReturn - (os.clock() - sc.openedAt)
		if sc.footer then
			sc.footer.Text = Models.autoReturnText(math.ceil(left))
		end
		if left <= 0 and (not sc.busy or left <= -BUSY_EXTRA) then
			toMenu(sc)
		end
	end)
end

return ResultsScreen
