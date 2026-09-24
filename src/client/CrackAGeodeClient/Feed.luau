-- Feed: the persistent activity column (plan CM-4). Every server broadcast whose
-- Config.Social.KindRoute is `feed` or `headline` (or carries feedOnly=true), plus
-- rows built from Cheer events, lands in a 30-entry ring seeded from GetState
-- (snap.feed) so a joiner sees the last 30 server events immediately. UI.Banner
-- owns toasts and banners; Feed never records a `personal` payload.
--
--   Rendering (dirty flag + 0.5 s coalescing rebuild, zero per-frame Luau):
--     desktop  bottom-left column, anchor (0,1) at (12,-12), 3/5/6 rows by Quality.Tier;
--     touch    directly under the HUD stack (GeodeHUD.LeftStackBottom + 8) with as many
--              rows as fit above H-170 (the CRACK button / joystick band), otherwise a
--              single "📣 N new" pill. Tapping a row or the pill opens the 30-row overlay
--              (ZIndex 30 inside GeodeFeed, tap-outside / × closes); an overlay row with
--              a userId → Feed.OnTapUser(userId).
--     Rows settle to a dimmed rest look 20 s after arrival (delayed engine tweens).
--     Hidden while GeodeHUD.PanelOpen or Quality.Settings.hideFeed.
--   Layout is read ONLY through the GeodeHUD attributes PanelOpen / LeftStackBottom /
--   CentreBandLeft / CentreBandRight (never UI frames). Each live row (not seeded
--   history) is mirrored to TextChatService.TextChannels.RBXSystem in pcall so the
--   chat log keeps it; the mirror is skipped while the feed is hidden by settings.
--   The Cheer event and its server feed broadcast describe one moment, so a cheer
--   row from the same sender within 3 s (or identical text within 5 s) is one row.
--
--   Feed.Init(Config, Quality)
--   Feed.Push(data)          Announce payload {kind,text,colorRGB?,userId?,personal?,feedOnly?,t?}
--   Feed.PushCheer(data)     Cheer payload {fromUserId,toUserId,idx,t?} → "👏 A cheered B"
--   Feed.Seed(list)          snap.feed (oldest first): replaces the history, keeps newer live rows
--   Feed.SetHidden(bool)     Settings "Hide activity feed"
--   Feed.Open() / Feed.Close() / Feed.Toggle()   the history overlay (additive helpers)
--   Feed.OnTapUser = function(userId) end   -- assigned by init.client (→ UI.OpenProfile)

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local TextChatService = game:GetService("TextChatService")
local GuiService = game:GetService("GuiService")
local StarterGui = game:GetService("StarterGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SG = require(ReplicatedStorage:WaitForChild("StyleGuide"))

local Feed = {}
Feed.OnTapUser = nil

local Config, Quality
local player = Players.LocalPlayer

local RING = 30
local COALESCE = 0.5
local FADE_AFTER = 20            -- s: a row settles to its rest look
local DEDUPE_TEXT = 5            -- s: identical text inside this window is one row
local DEDUPE_CHEER = 3           -- s: Cheer event + its feed broadcast are one row
local BOTTOM_CLEAR_TOUCH = 170   -- px above the bottom edge kept free on touch (CRACK / joystick)
local ROWS_BY_TIER = { [0] = 3, [1] = 5, [2] = 6 }
local MAX_ROWS = 6
local ROW_PAD = 4
local PILL_H_TOUCH, PILL_H_DESK = 32, 28
local FALLBACK_STACK_BOTTOM = { touch = 190, desktop = 260 } -- legacy UI (no attribute)
local FRESH_TEXT, FRESH_BG = 0, 0.22
local REST_TEXT, REST_BG = 0.4, 0.55
local HUD_ATTRS = { "PanelOpen", "LeftStackBottom", "CentreBandLeft", "CentreBandRight" }

local gui, column, pill
local rows = {}        -- pooled column rows: { frame, label, stroke, tweenText?, tweenBg? }
local overlay = nil    -- { catcher, card, list, empty, rows = {}, open = false }
local ring = {}        -- oldest first: { kind, text, colorRGB, userId, t, arrivedAt, shownAt, live }
local hidden = false   -- Quality.Settings.hideFeed / Feed.SetHidden
local panelOpen = false
local pending = false
local unseen = 0       -- live rows since the column / overlay last showed them
local hud = nil
local blocked = {}     -- [userId] = true: rows attributed to a blocked player never show

-- ===== helpers =====
local function isTouch()
	return (Quality and Quality.IsTouch) == true
end

local function tier()
	local t = Quality and Quality.Tier
	return type(t) == "number" and t or 2
end

local function maxRows()
	return ROWS_BY_TIER[tier()] or MAX_ROWS
end

local function rowH()
	return isTouch() and 32 or 28
end

local function kindColor(kind, colorRGB)
	if SG.kindColor then return SG.kindColor(kind, colorRGB) end
	return SG.Color.Text
end

-- KindRoute[kind]; the second value says whether a routing table exists at all
local function routeOf(kind)
	local social = Config and Config.Social
	local routes = social and social.KindRoute
	if type(routes) ~= "table" then return nil, false end
	return (kind ~= nil and routes[kind]) or nil, true
end

-- any non-zero integer: Studio "Test → Local Server" players carry negative UserIds
local function validUserId(x)
	if type(x) == "number" and x == x and x == math.floor(x) and x ~= 0 then return x end
	return nil
end

local function serverTime(t)
	local n = tonumber(t)
	if n and n == n then return n end
	return os.time()
end

local function nameOf(userId)
	local pl = Players:GetPlayerByUserId(userId)
	return pl and pl.DisplayName or "a miner"
end

local function screen()
	if gui and gui.AbsoluteSize.Y > 1 then return gui.AbsoluteSize.X, gui.AbsoluteSize.Y end
	local cam = workspace.CurrentCamera
	if cam and cam.ViewportSize.Y > 1 then
		local inset = GuiService:GetGuiInset()
		return cam.ViewportSize.X, math.max(160, cam.ViewportSize.Y - inset.Y)
	end
	return 1280, 720
end

local function hudAttr(name)
	if hud and hud.Parent then
		local v = hud:GetAttribute(name)
		if type(v) == "number" and v == v then return v end
	end
	return nil
end

local function stackBottom()
	local v = hudAttr("LeftStackBottom")
	if v then return v end
	return isTouch() and FALLBACK_STACK_BOTTOM.touch or FALLBACK_STACK_BOTTOM.desktop
end

local function ageText(t, now)
	if type(t) ~= "number" then return "" end
	local d = now - t
	if d < 45 then return "now" end
	if d < 3600 then return tostring(math.floor(d / 60 + 0.5)) .. "m" end
	return tostring(math.floor(d / 3600)) .. "h"
end

local function mirror(text)
	pcall(function()
		if TextChatService.ChatVersion ~= Enum.ChatVersion.TextChatService then return end
		local channels = TextChatService:FindFirstChild("TextChannels")
		local sys = channels and channels:FindFirstChild("RBXSystem")
		if sys then sys:DisplaySystemMessage(text) end
	end)
end

local function cancelTweens(r)
	if r.tweenText then r.tweenText:Cancel(); r.tweenText = nil end
	if r.tweenBg then r.tweenBg:Cancel(); r.tweenBg = nil end
end

-- ===== column rows =====
local function makeRow(order)
	local frame = SG.new("TextButton", {
		Name = "Row" .. order, Size = UDim2.new(1, 0, 0, rowH()), BackgroundColor3 = SG.Color.Bg1,
		BackgroundTransparency = FRESH_BG, BorderSizePixel = 0, Text = "", AutoButtonColor = false,
		LayoutOrder = order, Visible = false, ZIndex = 2,
	}, column)
	SG.corner(frame, "sm")
	local stroke = SG.stroke(frame, SG.Color.Violet, "hair", 0.5)
	local label = SG.text("Body", {
		Name = "Text", Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -20, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 3,
	}, frame)
	frame.Activated:Connect(function() Feed.Open() end)
	return { frame = frame, label = label, stroke = stroke }
end

local function styleRow(r, e, now)
	cancelTweens(r)
	local color = kindColor(e.kind, e.colorRGB)
	if r.label.Text ~= e.text then r.label.Text = e.text end
	r.label.TextColor3 = color
	r.stroke.Color = color
	local age = now - e.shownAt
	if age >= FADE_AFTER then
		r.label.TextTransparency = REST_TEXT
		r.frame.BackgroundTransparency = REST_BG
	else
		r.label.TextTransparency = FRESH_TEXT
		r.frame.BackgroundTransparency = FRESH_BG
		local info = TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, FADE_AFTER - age)
		r.tweenText = TweenService:Create(r.label, info, { TextTransparency = REST_TEXT })
		r.tweenBg = TweenService:Create(r.frame, info, { BackgroundTransparency = REST_BG })
		r.tweenText:Play()
		r.tweenBg:Play()
	end
	r.frame.Visible = true
end

local function layoutColumn(now)
	local W, H = screen()
	local touch = isTouch()
	local h = rowH()
	local pitch = h + ROW_PAD
	local want = math.min(maxRows(), #ring)
	local colW = math.min(touch and 300 or 320, W - 24)
	local n, showPill, top = 0, false, 0
	if touch then
		top = stackBottom() + 8
		local avail = (H - BOTTOM_CLEAR_TOUCH) - top
		n = math.clamp(math.floor((avail + ROW_PAD) / pitch), 0, want)
		showPill = n == 0 and #ring > 0 and avail >= PILL_H_TOUCH
		column.AnchorPoint = Vector2.new(0, 0)
		column.Position = UDim2.fromOffset(12, top)
	else
		local avail = (H - 12) - (stackBottom() + 8)
		n = math.clamp(math.floor((avail + ROW_PAD) / pitch), 0, want)
		column.AnchorPoint = Vector2.new(0, 1)
		column.Position = UDim2.new(0, 12, 1, -12)
	end
	column.Size = UDim2.fromOffset(colW, n > 0 and (n * pitch - ROW_PAD) or 0)
	for i = 1, MAX_ROWS do
		local r = rows[i]
		if i <= n then
			if not r then
				r = makeRow(i)
				rows[i] = r
			end
			if r.frame.Size.Y.Offset ~= h then r.frame.Size = UDim2.new(1, 0, 0, h) end
			styleRow(r, ring[#ring - n + i], now)
		elseif r then
			cancelTweens(r)
			r.frame.Visible = false
		end
	end
	if n > 0 then unseen = 0 end
	column.Visible = n > 0
	pill.Visible = showPill
	if showPill then
		pill.Size = UDim2.fromOffset(0, touch and PILL_H_TOUCH or PILL_H_DESK)
		pill.Position = UDim2.fromOffset(12, top)
		pill.Text = unseen > 0 and ("📣 " .. unseen .. " new") or "📣 Activity"
	end
end

-- ===== overlay (30-row history) =====
local function makeOverlayRow(i)
	local h = isTouch() and 44 or 32
	local frame = SG.new("TextButton", {
		Name = "Row" .. i, Size = UDim2.new(1, -6, 0, h), BackgroundColor3 = SG.Color.Bg2,
		BackgroundTransparency = 0.1, BorderSizePixel = 0, Text = "", AutoButtonColor = false,
		LayoutOrder = i, Visible = false, ZIndex = 32,
	}, overlay.list)
	SG.corner(frame, "sm")
	local label = SG.text("Body", {
		Name = "Text", Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -66, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 33,
	}, frame)
	local age = SG.text("Caption", {
		Name = "Age", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 0),
		Size = UDim2.new(0, 46, 1, 0), TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = SG.Color.TextDim, ZIndex = 33,
	}, frame)
	local r = { frame = frame, label = label, age = age, userId = nil }
	frame.Activated:Connect(function()
		local uid = r.userId
		local fn = Feed.OnTapUser
		if uid and type(fn) == "function" then
			Feed.Close()
			local ok, err = pcall(fn, uid)
			if not ok then warn("[Feed] OnTapUser: " .. tostring(err)) end
		end
	end)
	return r
end

local function buildOverlay()
	local catcher = SG.new("TextButton", {
		Name = "FeedCatcher", Size = UDim2.fromScale(1, 1), BackgroundColor3 = SG.Color.Scrim or SG.Color.Bg0,
		BackgroundTransparency = 0.6, BorderSizePixel = 0, Text = "", AutoButtonColor = false,
		ZIndex = 29, Visible = false,
	}, gui)
	local card = SG.panel({ Name = "FeedOverlay", ZIndex = 30, Visible = false, Active = true }, gui)
	SG.text("Heading", {
		Name = "Title", Position = UDim2.fromOffset(14, 8), Size = UDim2.new(1, -80, 0, 28),
		Text = "📣 ACTIVITY", TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 31,
	}, card)
	local closeSize = isTouch() and (SG.Size.CloseBtnTouch or 48) or (SG.Size.CloseBtn or 40)
	local close = SG.new("TextButton", {
		Name = "Close", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -6, 0, 6),
		Size = UDim2.fromOffset(closeSize, closeSize), BackgroundColor3 = SG.Color.Bg2,
		BackgroundTransparency = 0.2, BorderSizePixel = 0, Text = "×", TextColor3 = SG.Color.Text,
		Font = SG.Font.Display, TextScaled = true, AutoButtonColor = false, ZIndex = 31,
	}, card)
	SG.corner(close, "md")
	SG.new("UITextSizeConstraint", { MaxTextSize = 26 }, close)
	local list = SG.new("ScrollingFrame", {
		Name = "List", Position = UDim2.fromOffset(10, 44), Size = UDim2.new(1, -20, 1, -54),
		BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 4,
		AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y, ZIndex = 31,
	}, card)
	SG.new("UIListLayout", { Padding = UDim.new(0, ROW_PAD), SortOrder = Enum.SortOrder.LayoutOrder }, list)
	local empty = SG.text("Body", {
		Name = "Empty", Position = UDim2.fromOffset(14, 48), Size = UDim2.new(1, -28, 0, 40),
		Text = "Nothing yet — the feed fills up as miners crack, rebirth and cheer.",
		TextColor3 = SG.Color.TextDim, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left,
		Visible = false, ZIndex = 31,
	}, card)
	catcher.Activated:Connect(function() Feed.Close() end)
	close.Activated:Connect(function() Feed.Close() end)
	overlay = { catcher = catcher, card = card, list = list, empty = empty, rows = {}, open = false }
end

local function layoutOverlay()
	local W, H = screen()
	local card = overlay.card
	local h = isTouch() and 44 or 32
	if isTouch() then
		-- inside the centre band (HUD stack left, rail right); full width when the band is narrow
		local left = hudAttr("CentreBandLeft") or 16
		local right = hudAttr("CentreBandRight") or (W - 16)
		if right - left < 240 then left, right = 16, W - 16 end
		local w = math.clamp(right - left - 8, 200, 440)
		card.AnchorPoint = Vector2.new(0.5, 0)
		card.Position = UDim2.fromOffset((left + right) / 2, 8)
		card.Size = UDim2.fromOffset(w, math.max(120, H - 8 - 132)) -- stops above the CRACK button
	else
		card.AnchorPoint = Vector2.new(0, 1)
		card.Position = UDim2.new(0, 12, 1, -12)
		local rowsH = 56 + math.max(1, #ring) * (h + ROW_PAD) + 8
		card.Size = UDim2.fromOffset(math.min(380, W - 24), math.min(math.floor(H * 0.7), rowsH))
	end
end

local function fillOverlay()
	local now = os.time()
	local count = #ring
	for i = 1, RING do
		local r = overlay.rows[i]
		local e = ring[count - i + 1] -- newest first
		if e then
			if not r then
				r = makeOverlayRow(i)
				overlay.rows[i] = r
			end
			r.userId = e.userId
			if r.label.Text ~= e.text then r.label.Text = e.text end
			r.label.TextColor3 = kindColor(e.kind, e.colorRGB)
			r.age.Text = ageText(e.t, now)
			r.frame.Visible = true
		elseif r then
			r.frame.Visible = false
		end
	end
	overlay.empty.Visible = count == 0
end

function Feed.Open()
	if not gui then return end
	if hidden or panelOpen then return end
	if not overlay then buildOverlay() end
	overlay.open = true
	unseen = 0
	layoutOverlay()
	fillOverlay()
	overlay.catcher.Visible = true
	overlay.list.CanvasPosition = Vector2.zero
	SG.open(overlay.card)
	if pill.Visible then pill.Text = "📣 Activity" end
end

function Feed.Close()
	if not (overlay and overlay.open) then return end
	overlay.open = false
	overlay.catcher.Visible = false
	local card = overlay.card
	local s = card:FindFirstChildOfClass("UIScale")
	if not s then
		card.Visible = false
		return
	end
	-- own fade-close: only hide if nobody reopened the overlay during the tween
	local tw = TweenService:Create(s, SG.Motion.close, { Scale = 0.82 })
	tw.Completed:Once(function()
		if not overlay.open then
			card.Visible = false
			s.Scale = 1
		end
	end)
	tw:Play()
end

function Feed.Toggle()
	if overlay and overlay.open then Feed.Close() else Feed.Open() end
end

-- ===== rebuild (coalesced) =====
local function rebuild()
	pending = false
	if not gui then return end
	local visible = not hidden and not panelOpen
	if gui.Enabled ~= visible then gui.Enabled = visible end
	if not visible then
		Feed.Close()
		return
	end
	layoutColumn(os.clock())
	if overlay and overlay.open then
		layoutOverlay()
		fillOverlay()
	end
end

local function markDirty()
	if pending then return end
	pending = true
	task.delay(COALESCE, rebuild)
end

-- ===== ring =====
local function isDuplicate(row, now)
	for i = #ring, math.max(1, #ring - 8), -1 do
		local e = ring[i]
		if now - e.arrivedAt > DEDUPE_TEXT then break end
		if e.text == row.text then return true end
		if row.kind == "cheer" and e.kind == "cheer" and row.userId ~= nil and e.userId == row.userId
			and now - e.arrivedAt <= DEDUPE_CHEER then
			return true
		end
	end
	return false
end

local function accept(row, live)
	if row.userId and blocked[row.userId] then return false end
	local now = os.clock()
	row.arrivedAt = now
	row.shownAt = live and now or (now - FADE_AFTER)
	row.live = live
	if isDuplicate(row, now) then return false end
	ring[#ring + 1] = row
	while #ring > RING do table.remove(ring, 1) end
	if live then
		unseen += 1
		if not hidden then mirror(row.text) end
	end
	markDirty()
	return true
end

-- ===== public API =====
function Feed.Push(data)
	if type(data) ~= "table" or data.personal == true then return false end
	local text = data.text
	if type(text) ~= "string" or text == "" then return false end
	local kind = type(data.kind) == "string" and data.kind or nil
	local route, hasRoutes = routeOf(kind)
	-- feed/headline broadcasts and feedOnly rows; a Config without KindRoute (pre-Social)
	-- has nothing to route by, so every non-personal broadcast is kept
	if hasRoutes and not (data.feedOnly == true or route == "feed" or route == "headline") then
		return false
	end
	return accept({
		kind = kind, text = text, colorRGB = data.colorRGB,
		userId = validUserId(data.userId), t = serverTime(data.t),
	}, true)
end

function Feed.PushCheer(data)
	if type(data) ~= "table" then return false end
	local from, to = validUserId(data.fromUserId), validUserId(data.toUserId)
	if not from or not to then return false end
	local reactions = Config and Config.Social and Config.Social.Reactions
	local idx = tonumber(data.idx)
	local emoji = (type(reactions) == "table" and idx and reactions[idx]) or "👏"
	return accept({
		kind = "cheer", text = emoji .. " " .. nameOf(from) .. " cheered " .. nameOf(to),
		userId = from, t = serverTime(data.t),
	}, true)
end

function Feed.Seed(list)
	if type(list) ~= "table" then return end
	local now = os.clock()
	local merged = {}
	for _, e in ipairs(list) do
		if type(e) == "table" and type(e.text) == "string" and e.text ~= "" and e.personal ~= true then
			local t = tonumber(e.t)
			merged[#merged + 1] = {
				kind = type(e.kind) == "string" and e.kind or nil, text = e.text, colorRGB = e.colorRGB,
				userId = validUserId(e.userId), t = (t and t == t) and t or nil,
				arrivedAt = now, shownAt = now - FADE_AFTER, live = false,
			}
		end
	end
	local seededCount = #merged
	-- rows that arrived live before GetState returned stay unless the history has them
	for _, r in ipairs(ring) do
		local dup = false
		for i = 1, seededCount do
			local s = merged[i]
			if s.text == r.text and (s.t == nil or r.t == nil or s.t == r.t) then
				dup = true
				break
			end
		end
		if not dup then merged[#merged + 1] = r end
	end
	while #merged > RING do table.remove(merged, 1) end
	ring = merged
	markDirty()
end

function Feed.SetHidden(on)
	local h = on == true
	if hidden == h then return end
	hidden = h
	if gui then gui.Enabled = not hidden and not panelOpen end
	markDirty()
end

-- ===== init =====
-- blocked users: cached once (StarterGui core, else the async API), live updates when
-- the core exposes them; every call is pcall'd because the core may not be ready
local function loadBlocked()
	task.spawn(function()
		local ok, ids = pcall(function() return StarterGui:GetCore("GetBlockedUserIds") end)
		if not (ok and type(ids) == "table") then
			ok, ids = pcall(function() return player:GetBlockedUserIdsAsync() end)
		end
		if ok and type(ids) == "table" then
			for _, id in ipairs(ids) do
				if type(id) == "number" then blocked[id] = true end
			end
		end
		pcall(function()
			StarterGui:GetCore("PlayerBlockedEvent").Event:Connect(function(pl)
				if typeof(pl) == "Instance" and pl:IsA("Player") then blocked[pl.UserId] = true end
			end)
		end)
		pcall(function()
			StarterGui:GetCore("PlayerUnblockedEvent").Event:Connect(function(pl)
				if typeof(pl) == "Instance" and pl:IsA("Player") then blocked[pl.UserId] = nil end
			end)
		end)
	end)
end

local function bindHud(pg)
	local function attach(h)
		if hud == h then return end
		hud = h
		panelOpen = h:GetAttribute("PanelOpen") == true
		for _, name in ipairs(HUD_ATTRS) do
			h:GetAttributeChangedSignal(name):Connect(function()
				if name == "PanelOpen" then
					panelOpen = h:GetAttribute("PanelOpen") == true
					-- hide at once (a panel is opening over the HUD stack); layout follows coalesced
					if gui then gui.Enabled = not hidden and not panelOpen end
				end
				markDirty()
			end)
		end
		markDirty()
	end
	local h = pg:FindFirstChild("GeodeHUD")
	if h then attach(h) end
	pg.ChildAdded:Connect(function(c)
		if c.Name == "GeodeHUD" then attach(c) end
	end)
end

function Feed.Init(config, quality)
	Config, Quality = config, quality
	if Quality and type(Quality.Settings) == "table" then hidden = Quality.Settings.hideFeed == true end

	local pg = player:WaitForChild("PlayerGui")
	gui = SG.new("ScreenGui", {
		Name = "GeodeFeed", ResetOnSpawn = false, DisplayOrder = 9,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling, Enabled = not hidden,
	})
	column = SG.new("Frame", {
		Name = "Column", BackgroundTransparency = 1, Size = UDim2.fromOffset(300, 0),
		Position = UDim2.fromOffset(12, 200), ZIndex = 1, Visible = false,
	}, gui)
	SG.new("UIListLayout", {
		Padding = UDim.new(0, ROW_PAD), SortOrder = Enum.SortOrder.LayoutOrder,
		VerticalAlignment = Enum.VerticalAlignment.Bottom,
	}, column)
	pill = SG.new("TextButton", {
		Name = "Pill", Size = UDim2.fromOffset(0, PILL_H_TOUCH), AutomaticSize = Enum.AutomaticSize.X,
		Position = UDim2.fromOffset(12, 200), BackgroundColor3 = SG.Color.Bg1, BackgroundTransparency = 0.15,
		BorderSizePixel = 0, Text = "📣 Activity", TextColor3 = SG.Color.Cyan, Font = SG.Font.Heading,
		TextSize = 13, TextStrokeTransparency = 0.8, AutoButtonColor = false, Visible = false, ZIndex = 2,
	}, gui)
	SG.corner(pill, "pill")
	SG.stroke(pill, SG.Color.Cyan, "hair", 0.4)
	SG.new("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }, pill)
	pill.Activated:Connect(function() Feed.Toggle() end)
	gui.Parent = pg

	bindHud(pg)
	loadBlocked()
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(markDirty)
	if Quality and Quality.Changed then
		Quality.Changed:Connect(function(field)
			if field == "hideFeed" then
				Feed.SetHidden(Quality.Settings and Quality.Settings.hideFeed == true)
			elseif field == "Tier" then
				markDirty()
			end
		end)
	end
	markDirty()
end

return Feed
