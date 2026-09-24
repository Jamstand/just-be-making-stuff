-- Crack a Geode! — procedural HUD + panels (clientUI owner; ONE file by decision B.6).
--   HUD card (gems / rate / luck / "Rebirth N · zone ×M" + "+" Shop pill), buff + next-event
--   chips, ServerGoal chip, objective tracker (GoalCard chain), Meteor co-op bar + results
--   card, 9-button rail, cooldown-gated CRACK; Upgrades, Shop, Index, Daily, Pets, Awards,
--   Players (Online / Top Gems / Top Rebirths + Friends) and Settings panels on the shared
--   panel factory (SG.panel + 52 px strip with a live balance); scrim + Escape / B close;
--   UI.Modal / UI.Confirm; toast lane with roles; the Announce router (CONTRACT §3.5);
--   UI._invoke / UI._bindInvoke around every RemoteFunction call; rail glows + badges.
--   Countdowns run on server time (clockOffset = snap.now - os.time()). Layout contract:
--   GeodeHUD attributes PanelOpen / LeftStackBottom / CentreBandLeft / CentreBandRight.
--   Quality arrives through UI.Init(config, remotes, deps) — no other client module is required.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local SG = require(game:GetService("ReplicatedStorage"):WaitForChild("StyleGuide"))

local UI = {}
local Config, Remotes, Quality
local player = Players.LocalPlayer
local gui
local snap = nil
local displayGems = 0

local Color = SG.Color
local BG, BG2 = Color.Bg1, Color.Bg2
local ACCENT, GOOD, TEXT, MUTED = Color.Violet, Color.Green, Color.Text, Color.TextDim
local GOLD, INFO, WARN = Color.Gold, Color.Info, Color.Warn

local panels = {}          -- name -> outer frame (Upgrades, Shop, Index, Daily, Pets, Achievements [, Modal])
local refs = {}
local balanceLabels = {}   -- one "You have N 💎" label per panel title strip
local responsivePanels = {} -- { outer, w, h, body }
local IS_TOUCH = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
UI.IsTouch = IS_TOUCH
UI._menuOverlay = false
UI._anyOpen = false

local STRIP_H = 52               -- panel title strip height
local updateSeq = 0             -- bumped per UI.Update; lets outcome toasts wait for the fresh snapshot
local afterUpdate = nil
local crackReadyAt = 0           -- os.clock() when the next crack is allowed (UI.CrackReadyAt)
local currentZone = nil          -- UI.SetZone(key)
local settings = nil             -- UI.GetSettings(); seeded from Config.Social.SettingsDefault
local unreadFeed = 0             -- feed-routed announces since the Players button was last tapped
local clockOffset = 0            -- snap.now - os.time(); every countdown uses server time
local panelRefresh = {}          -- name -> refresh fn (filled in Init); runs on open when the panel is dirty
local panelDirty = {}            -- name -> true when a snapshot arrived while the panel was closed

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
local function corner(el, key) return SG.corner(el, key or "md") end
local function stroke(el, color, weight, transparency) return SG.stroke(el, color or ACCENT, weight or "base", transparency) end
-- type-role label (TextScaled with the role's px floor/ceiling; see SG.text)
local function text(role, props, parent) return SG.text(role, props, parent) end
-- wrapped paragraph at the role's max px (TextScaled + wrapping would shrink it)
local function para(role, props, parent)
	local t = SG.Type[role] or SG.Type.Body
	local base = {
		BackgroundTransparency = 1, BorderSizePixel = 0, TextColor3 = TEXT, Font = t.font,
		TextSize = t.max + (IS_TOUCH and 1 or 0), TextWrapped = true, TextStrokeTransparency = 0.7,
		TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
	}
	for k, v in pairs(props) do base[k] = v end
	return mk("TextLabel", base, parent)
end
local function rowH() return IS_TOUCH and SG.Size.RowH or SG.Size.RowHDesk end
local function btnH() return IS_TOUCH and SG.Size.BtnHTouch or SG.Size.BtnH end
local function closeSz() return IS_TOUCH and SG.Size.CloseBtnTouch or SG.Size.CloseBtn end
-- {r,g,b} table from the server (pet / collectible colours) -> Color3
local function rgb(c)
	if type(c) == "table" and c[1] and c[2] and c[3] then return Color3.fromRGB(c[1], c[2], c[3]) end
	return TEXT
end
-- new remotes are optional (older server): never index Remotes.X directly for them
local function remote(name) return Remotes and Remotes:FindFirstChild(name) or nil end
local function fmtSecs(s)
	s = math.max(0, math.floor((tonumber(s) or 0) + 0.5))
	return string.format("%d:%02d", math.floor(s / 60), s % 60)
end
local function serverNow() return os.time() + clockOffset end
-- change-only text write (the HUD refreshes every push; most lines do not change)
local function setText(label, str) if label and label.Text ~= str then label.Text = str end end
-- transparent tap area over a non-button element (list rows, chips, slider tracks, the
-- tracker card): the only TextButtons outside SG.button besides the scrim / rail / CRACK.
local function hitArea(parent, cb, props)
	local b = mk("TextButton", { Name = "Hit", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "",
		AutoButtonColor = false, BorderSizePixel = 0, ZIndex = (parent:IsA("GuiObject") and parent.ZIndex or 1) + 3 }, parent)
	if props then for k, v in pairs(props) do b[k] = v end end
	if cb then b.Activated:Connect(cb) end
	return b
end
-- meteor bar base height (a single row; desktop grows it for the share bars while active)
local function metBase() return IS_TOUCH and 44 or 36 end
-- my zone key: RegionFX (UI.SetZone) first, then the server-set attribute, then the hub
local function ownZoneKey()
	local z = currentZone or player:GetAttribute("Zone")
	return type(z) == "string" and z ~= "" and z or "Cavern"
end

-- ===== toast lane (UI-2) =====
-- Bottom-centre lane above the CRACK button (touch) / hotbar (desktop). Max 3 visible,
-- FIFO eviction, 2.6 s life, identical text deduped within 1 s, "Slow down!" swallowed.
local ROLE_COLOR = { ok = Color.Green, err = Color.Red, info = Color.Info, warn = Color.Warn, gold = Color.Gold }
local toastSeq, toastLast = 0, {}
local TOAST_LIFE = 2.6

local function liveChildren(parent)
	local live = {}
	for _, c in ipairs(parent:GetChildren()) do
		if c:IsA("GuiObject") then live[#live + 1] = c end
	end
	table.sort(live, function(a, b) return a.LayoutOrder < b.LayoutOrder end)
	return live
end

local function fadeOut(el, dur)
	for _, d in ipairs(el:GetDescendants()) do
		if d:IsA("TextLabel") or d:IsA("TextButton") then
			TweenService:Create(d, TweenInfo.new(dur), { TextTransparency = 1, TextStrokeTransparency = 1, BackgroundTransparency = 1 }):Play()
		elseif d:IsA("UIStroke") then
			TweenService:Create(d, TweenInfo.new(dur), { Transparency = 1 }):Play()
		elseif d:IsA("GuiObject") then
			TweenService:Create(d, TweenInfo.new(dur), { BackgroundTransparency = 1 }):Play()
		end
	end
	if el:IsA("TextLabel") then
		TweenService:Create(el, TweenInfo.new(dur), { TextTransparency = 1, TextStrokeTransparency = 1, BackgroundTransparency = 1 }):Play()
	else
		TweenService:Create(el, TweenInfo.new(dur), { BackgroundTransparency = 1 }):Play()
	end
	Debris:AddItem(el, dur + 0.05)
end

local function pushToast(str, color, action)
	if type(str) ~= "string" or str == "" or str == "Slow down!" then return end
	local lane = refs.toastLane
	if not lane then return end
	local now = os.clock()
	if toastLast[str] and now - toastLast[str] < 1 then return end
	toastLast[str] = now
	local live = liveChildren(lane)
	while #live >= 3 do
		local old = table.remove(live, 1)
		old:Destroy()
	end
	toastSeq += 1
	local h = IS_TOUCH and SG.Size.ToastHTouch or SG.Size.ToastH
	local pill = mk("Frame", { Name = "Toast", Size = UDim2.new(0.9, 0, 0, h), BackgroundColor3 = BG, BackgroundTransparency = 0.15,
		BorderSizePixel = 0, LayoutOrder = toastSeq, ZIndex = 30 }, lane)
	corner(pill, "md")
	stroke(pill, color, "base", 0.2)
	mk("UISizeConstraint", { MinSize = Vector2.new(240, h), MaxSize = Vector2.new(520, h) }, pill)
	local actionW = 0
	if type(action) == "table" and type(action.fn) == "function" then
		actionW = 108
		local b = SG.button(tostring(action.label or "Open"), "ghost", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -4, 0.5, 0),
			Size = UDim2.fromOffset(actionW - 8, IS_TOUCH and h or (h - 4)), ZIndex = 32 }, pill)
		b.Activated:Connect(function()
			pill:Destroy()
			task.spawn(action.fn)
		end)
	end
	-- fixed Body size; wraps to a second line inside the 44/48 px pill, ellipsis after that
	text("Body", { Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -16 - actionW, 1, 0), Text = str, TextColor3 = color,
		TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 31 }, pill)
	local sc = mk("UIScale", { Scale = 0.9 }, pill)
	TweenService:Create(sc, SG.Motion.pop, { Scale = 1 }):Play()
	task.delay(TOAST_LIFE, function()
		if pill.Parent then fadeOut(pill, 0.3) end
	end)
end

-- kind ∈ ok|err|info|warn|gold (a Color3 second argument is still accepted -> info;
-- any SG.KindColor key also works). action = { label, fn }.
function UI.Toast(str, kind, action)
	local color
	if type(kind) == "string" then
		color = ROLE_COLOR[kind] or SG.KindColor[kind] or ROLE_COLOR.info
	else
		color = ROLE_COLOR.info
	end
	pushToast(type(str) == "string" and str or tostring(str), color, action)
end

-- ===== headline banners + the Announce router (UI-2, CONTRACT §3.5) =====
local bannerLast = {}
-- own-milestone feed kinds the client already toasts itself (doBuy's Rebirth / Ascend outcome
-- toasts): these go to the Feed only, so one action never stacks two or three pills
local OWN_FEED_QUIET = { rebirth = true, ascend = true }
local function headline(str, color)
	local stack = refs.banners
	if not stack or type(str) ~= "string" or str == "" then return end
	local now = os.clock()
	if bannerLast[str] and now - bannerLast[str] < 5 then return end
	bannerLast[str] = now
	local live = liveChildren(stack)
	while #live >= 3 do
		local old = table.remove(live, 1)
		old:Destroy()
	end
	toastSeq += 1
	local b = text("Heading", { Size = UDim2.new(1, 0, 0, IS_TOUCH and 34 or 30), Text = str, TextColor3 = color, fit = true,
		BackgroundColor3 = BG, BackgroundTransparency = 0.15, LayoutOrder = toastSeq, ZIndex = 12 }, stack)
	corner(b, "sm")
	stroke(b, color, "hair", 0.5)
	mk("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }, b)
	task.delay(3.5, function()
		if b.Parent then fadeOut(b, 0.3) end
	end)
end

-- colorRGB > legacy Color3 > SG.KindColor[kind] > Text
local function announceColor(data)
	if data.colorRGB ~= nil then return SG.kindColor(data.kind, data.colorRGB) end
	if typeof(data.color) == "Color3" then return data.color end
	return SG.kindColor(data.kind)
end

local function refreshPlayersBadge()
	if refs.playersBtn then
		SG.badge(refs.playersBtn, unreadFeed > 9 and "9+" or (unreadFeed > 0 and tostring(unreadFeed) or ""))
	end
end

-- toast actions by kind (§3.5); userId must be another player and the hook must exist
local function announceAction(data)
	local kind, uid = data.kind, data.userId
	local other = type(uid) == "number" and uid == uid and uid ~= player.UserId
	if kind == "welcome" and panels.Players then
		return { label = "Say hi 👋", fn = function() UI.ShowPanel("Players") end }
	elseif kind == "giftReceived" and other and UI.OnCheer then
		return { label = "Thank 💜", fn = function() UI.OnCheer(uid, 6) end }
	elseif kind == "info" and other and UI.OnCheer then
		return { label = "Cheer 👏", fn = function() UI.OnCheer(uid, 1) end }
	end
	return nil
end

-- Wire shape: { kind, text, colorRGB?, userId?, personal?, feedOnly?, priority?, t? }.
-- 1. personal -> toast  2. feedOnly -> ignored (Feed owns it)  3. KindRoute[kind]:
-- headline -> banner stack; feed -> toast only for OWN milestones; toast -> toast
-- 4. no route / legacy payload -> headline. Nothing is ever dropped.
function UI.Banner(data)
	if type(data) ~= "table" or type(data.text) ~= "string" then return end
	local color = announceColor(data)
	if data.personal == true then
		pushToast(data.text, color, announceAction(data))
		return
	end
	if data.feedOnly == true then return end
	local route = nil
	local kr = Config and Config.Social and Config.Social.KindRoute
	if kr and data.kind ~= nil then route = kr[data.kind] end
	if route == "headline" then
		headline(data.text, color)
	elseif route == "feed" then
		if data.userId == player.UserId then
			-- own milestone -> toast, unless the client toasted this action's outcome already
			if not OWN_FEED_QUIET[data.kind] then pushToast(data.text, color, nil) end
		else
			unreadFeed += 1
			refreshPlayersBadge()
		end
	elseif route == "toast" then
		pushToast(data.text, color, announceAction(data))
	else
		headline(data.text, color)
	end
end
UI.Announce = UI.Banner

-- ===== RemoteFunction helpers (UI-2) =====
-- pcall + table check; failure -> one "Something went wrong" toast and {ok=false}.
-- "Slow down!" replies come back untouched and every caller's toast path swallows them.
function UI._invoke(rf, ...)
	if not rf then
		UI.Toast("Something went wrong", "err")
		return { ok = false, err = "Unavailable" }
	end
	local ok, res = pcall(rf.InvokeServer, rf, ...)
	if not ok or type(res) ~= "table" then
		if not ok then warn("[UI] invoke failed:", rf.Name, res) end
		UI.Toast("Something went wrong", "err")
		return { ok = false, err = "Something went wrong" }
	end
	return res
end

-- Per-button pending state: the button is disabled while fn runs (fn does the invoke),
-- re-entry is blocked, and `after` (usually the panel refresh) re-applies true states.
function UI._bindInvoke(btn, fn, after)
	local pending = false
	btn.Activated:Connect(function()
		if pending or btn:GetAttribute("SGDisabled") == true then return end
		pending = true
		SG.setEnabled(btn, false)
		local ok, err = pcall(fn)
		if not ok then warn("[UI] button handler failed:", err) end
		pending = false
		if btn.Parent then
			SG.setEnabled(btn, true)
			if type(after) == "function" then pcall(after) end
		end
	end)
end

-- run fn once the snapshot that follows the current one has arrived (outcome toasts
-- read exact server values). If UI.Update already ran since `seq`, run now.
local function afterSnap(seq, fn)
	if updateSeq > seq then fn() else afterUpdate = fn end
end

-- ===== modal + confirm (UI-1) =====
-- A modal is registered as panels.Modal so the scrim, Escape / B, tap-outside and the
-- one-panel-at-a-time rule all apply. It is rebuilt per call and destroyed on close.
-- true when a panel other than `except` is showing (SG.close hides asynchronously)
local function otherPanelOpen(except)
	for _, p in pairs(panels) do
		if p ~= except and p.Visible then return true end
	end
	return false
end

-- Dismissing a modal (Cancel / Close / Escape / B / scrim) hands the screen back to the panel
-- it was opened from (refs.modalReturnTo, remembered by UI.Modal) instead of dropping the
-- player to the HUD. immediate = a new modal is replacing this one: no return (UI.Modal carries
-- the field over so Profile -> Gift confirm -> Cancel still lands on Players).
local function closeModal(immediate)
	local m = panels.Modal
	if not m then return end
	panels.Modal = nil
	local back = refs.modalReturnTo
	refs.modalReturnTo = nil
	if m.Visible and not immediate then
		SG.close(m, function() if m.Parent then m:Destroy() end end)
		local target = back and panels[back] or nil
		if target and not target.Visible and not otherPanelOpen(m) then SG.open(target) end
	else
		m:Destroy()
	end
	UI._ApplyOpenState()
end
UI._CloseModal = closeModal

-- spec = { title, body:string|builder(frame), width?, buttons = {{ text, role, fn, hold?, enabled?, keepOpen?, keepReturn? }} }
-- hold=true renders a 0.8 s hold-to-confirm fill on touch (a plain tap on desktop).
-- keepReturn=false marks a button that leaves for elsewhere (its fn opens another panel), so
-- dismissing through it does not reopen the panel the modal came from.
function UI.Modal(spec)
	spec = spec or {}
	if not gui then return nil end
	local back = refs.modalReturnTo -- a modal opened from a modal keeps the original panel
	closeModal(true)
	local vp = (gui.AbsoluteSize.X > 1) and gui.AbsoluteSize or viewport()
	local w = math.min(spec.width or 380, vp.X - 32)
	local outer = SG.panel({ Name = "Modal", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(w, 0), AutomaticSize = Enum.AutomaticSize.Y, Visible = false, ZIndex = 22 }, gui)
	mk("UIPadding", { PaddingTop = UDim.new(0, 16), PaddingBottom = UDim.new(0, 16), PaddingLeft = UDim.new(0, 16), PaddingRight = UDim.new(0, 16) }, outer)
	mk("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Center }, outer)
	text("Display", { Size = UDim2.new(1, 0, 0, 30), Text = tostring(spec.title or ""), TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = 1, ZIndex = 23, fit = true }, outer)
	if type(spec.body) == "string" then
		para("Body", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Text = spec.body, LayoutOrder = 2, ZIndex = 23 }, outer)
	elseif type(spec.body) == "function" then
		local holder = mk("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = 2, ZIndex = 23 }, outer)
		pcall(spec.body, holder)
	end
	local made = {}
	local buttons = spec.buttons or {}
	if #buttons > 0 then
		local bh = btnH()
		local rowF = mk("Frame", { Size = UDim2.new(1, 0, 0, bh), BackgroundTransparency = 1, LayoutOrder = 3, ZIndex = 23 }, outer)
		mk("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder,
			HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center,
		}, rowF)
		local n = #buttons
		for i, b in ipairs(buttons) do
			local btn = SG.button(tostring(b.text or "OK"), b.role or "primary", { Size = UDim2.new(1 / n, -math.ceil(8 * (n - 1) / n), 1, 0), LayoutOrder = i, ZIndex = 24 }, rowF)
			made[i] = btn
			if b.enabled == false then SG.setEnabled(btn, false) end
			local function fire()
				if btn:GetAttribute("SGDisabled") == true then return end
				if b.keepReturn == false then refs.modalReturnTo = nil end -- this button leaves for elsewhere
				if not b.keepOpen then closeModal(false) end
				if type(b.fn) == "function" then task.spawn(b.fn) end
			end
			if b.hold and IS_TOUCH then
				local fill = mk("Frame", { Name = "HoldFill", Size = UDim2.fromScale(0, 1), BackgroundColor3 = Color3.new(1, 1, 1),
					BackgroundTransparency = 0.7, BorderSizePixel = 0, ZIndex = btn.ZIndex }, btn)
				corner(fill, "md")
				local tween = nil
				local function cancel()
					if tween then tween:Cancel(); tween = nil end
					fill.Size = UDim2.fromScale(0, 1)
				end
				btn.MouseButton1Down:Connect(function()
					if btn:GetAttribute("SGDisabled") == true then return end
					cancel()
					local my = TweenService:Create(fill, TweenInfo.new(0.8, Enum.EasingStyle.Linear), { Size = UDim2.fromScale(1, 1) })
					tween = my
					my.Completed:Connect(function(state)
						if state == Enum.PlaybackState.Completed and tween == my then
							tween = nil
							fill.Size = UDim2.fromScale(0, 1)
							fire()
						end
					end)
					my:Play()
				end)
				btn.MouseButton1Up:Connect(cancel)
				btn.MouseLeave:Connect(cancel)
				btn.Text = btn.Text .. " · hold"
			else
				btn.Activated:Connect(fire)
			end
		end
	end
	panels.Modal = outer
	outer:GetPropertyChangedSignal("Visible"):Connect(function()
		if not outer.Visible and panels.Modal == outer then
			-- hidden by TogglePanel / ShowPanel navigation (not a dismissal): nothing to return to
			panels.Modal = nil
			refs.modalReturnTo = nil
			task.defer(function() if outer.Parent then outer:Destroy() end end)
		end
		UI._ApplyOpenState()
	end)
	for n, p in pairs(panels) do
		if p ~= outer and p.Visible then
			if n ~= "Modal" then back = n end -- the panel this modal covers: return there on dismiss
			SG.close(p)
		end
	end
	refs.modalReturnTo = back
	SG.open(outer)
	UI._ApplyOpenState()
	return { frame = outer, buttons = made, close = function() closeModal(false) end }
end

-- spec = { title, body, confirmText?, confirmRole?, cancelText?, onConfirm, onCancel?, hold? (default true), confirmEnabled? }
function UI.Confirm(spec)
	spec = spec or {}
	return UI.Modal({
		title = spec.title, body = spec.body, width = spec.width,
		buttons = {
			{ text = spec.cancelText or "Cancel", role = "ghost", fn = spec.onCancel },
			{ text = spec.confirmText or "Confirm", role = spec.confirmRole or "danger", fn = spec.onConfirm,
			  hold = spec.hold ~= false, enabled = spec.confirmEnabled ~= false },
		},
	})
end

-- ===== panel scaffolding (UI-1) =====

-- Panel titles: leading emoji are swapped for the real uploaded icon art when it exists.
local HEADER_ICONS = {
	["⛏️"] = "pickaxe", ["🛒"] = "shop", ["📖"] = "index", ["🎁"] = "gift", ["📅"] = "gift",
	["📋"] = "quest", ["🐾"] = "paw", ["🏆"] = "trophy", ["🏅"] = "trophy",
	["🌌"] = "rebirth", ["💎"] = "gem", ["👥"] = "players", ["⚙️"] = "gear",
}
local function headerParts(title)
	for emoji, key in pairs(HEADER_ICONS) do
		if title:sub(1, #emoji) == emoji and SG.Icons[key] and SG.Icons[key] ~= 0 then
			return key, (title:sub(#emoji + 1):gsub("^%s+", ""))
		end
	end
	return nil, title
end

-- Scroll panel on SG.panel: content renders at FULL size and scrolls when the screen is
-- short (touch never shrinks below scale 1.0 for height). A 52 px title strip floats over
-- the body: icon + Display title, "You have N 💎" balance (UI-3) and a 48/40 px close.
-- Builders start their content at y = STRIP_H + 8 and call finishPanel(body, y).
local function makeScrollPanel(name, title, contentHeight)
	local w = SG.Size.PanelW
	local outer = SG.panel({ Name = name, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(w, contentHeight), Visible = false, ClipsDescendants = true, ZIndex = 20 }, gui)
	local body = mk("ScrollingFrame", { Name = "Content", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0,
		CanvasSize = UDim2.fromOffset(0, contentHeight), ScrollBarThickness = IS_TOUCH and 8 or 6,
		ScrollBarImageColor3 = ACCENT, ScrollingDirection = Enum.ScrollingDirection.Y, ZIndex = 21 }, outer)
	local strip = mk("Frame", { Name = "Strip", Size = UDim2.new(1, 0, 0, STRIP_H), BackgroundColor3 = BG, BackgroundTransparency = 0.04, BorderSizePixel = 0, ZIndex = 25 }, outer)
	corner(strip, "xl")
	-- square off the strip's bottom corners so it meets the body flush
	mk("Frame", { Name = "StripFill", Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.new(1, 0, 0.5, 0),
		BackgroundColor3 = BG, BackgroundTransparency = 0.04, BorderSizePixel = 0, ZIndex = 25 }, strip)
	mk("Frame", { Name = "StripLine", AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(1, 0, 0, 1),
		BackgroundColor3 = ACCENT, BackgroundTransparency = 0.6, BorderSizePixel = 0, ZIndex = 26 }, strip)
	local iconKey, titleText = headerParts(title)
	if iconKey then SG.icon(iconKey, { Position = UDim2.fromOffset(14, 12), Size = UDim2.fromOffset(28, 28), ZIndex = 26 }, strip) end
	local cs = closeSz()
	text("Display", { Position = UDim2.fromOffset(iconKey and 48 or 16, 10), Size = UDim2.new(0.5, -20, 0, 32), Text = titleText,
		TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 26, fit = true }, strip)
	local bal = text("Number", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -(cs + 18), 0.5, 0), Size = UDim2.new(0.44, 0, 0, 26),
		Text = "", TextColor3 = GOLD, TextXAlignment = Enum.TextXAlignment.Right, ZIndex = 26, fit = true }, strip)
	local balC = bal:FindFirstChildOfClass("UITextSizeConstraint")
	if balC then balC.MaxTextSize = 18 end
	balanceLabels[#balanceLabels + 1] = bal
	local close = SG.button("×", "ghost", { Name = "Close", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0), Size = UDim2.fromOffset(cs, cs), ZIndex = 26 }, strip)
	close.Activated:Connect(function() UI.TogglePanel(nil) end)
	table.insert(responsivePanels, { outer = outer, w = w, h = contentHeight, body = body })
	panels[name] = outer
	outer:GetPropertyChangedSignal("Visible"):Connect(function()
		-- a snapshot that arrived while this panel was closed is applied on open
		if outer.Visible and panelDirty[name] then
			panelDirty[name] = nil
			local fn = panelRefresh[name]
			if fn then pcall(fn) end
		end
		UI._ApplyOpenState()
	end)
	return body
end

-- final content height after a builder laid out its rows
local function finishPanel(body, y)
	body.CanvasSize = UDim2.fromOffset(0, y)
	for _, p in ipairs(responsivePanels) do
		if p.body == body then
			p.h = y
			p.outer.Size = UDim2.fromOffset(p.w, y)
		end
	end
end

function UI.AnyPanelOpen()
	for _, p in pairs(panels) do
		if p.Visible then return true end
	end
	return false
end

function UI.TogglePanel(name)
	UI._RefreshPanels() -- fresh fit for the current screen before opening
	-- Escape / B / scrim while a modal is up: dismiss the modal and return to its panel (UX-7)
	if name == nil and panels.Modal and panels.Modal.Visible and refs.modalReturnTo then
		closeModal(false)
		return
	end
	for n, panel in pairs(panels) do
		if n == name then
			if panel.Visible then SG.close(panel) else SG.open(panel) end
		elseif panel.Visible then
			SG.close(panel)
		end
	end
end

function UI.ShowPanel(name)
	UI._RefreshPanels()
	for n, panel in pairs(panels) do
		if n == name then
			if not panel.Visible then SG.open(panel) end
		elseif panel.Visible then
			SG.close(panel)
		end
	end
end

-- px the touch rail must leave free at the bottom for the CoreGui jump button
local function jumpReserve()
	if not IS_TOUCH then return 0 end
	local ok, h = pcall(function()
		local pg = player:FindFirstChild("PlayerGui")
		local jb = pg and pg:FindFirstChild("TouchGui")
		jb = jb and jb:FindFirstChild("TouchControlFrame")
		jb = jb and jb:FindFirstChild("JumpButton")
		return jb and jb.AbsoluteSize.Y or nil
	end)
	if ok and type(h) == "number" and h > 0 then return h + 16 end
	return 100
end

-- Banners and the meteor bar live in the centre band between the HUD stack and the
-- rail; when that band is narrower than 240 px they drop into the LeftStack instead.
local function placeBand(bandL, bandR, cardW)
	local bandW = bandR - bandL
	local inBand = bandW >= 240
	local mode = inBand and "band" or "stack"
	local banners, meteor = refs.banners, refs.meteorFrame
	if not (banners and meteor and refs.leftStack) then return end
	if refs.bandMode ~= mode then
		refs.bandMode = mode
		if inBand then
			banners.Parent = gui; meteor.Parent = gui
			banners.AnchorPoint = Vector2.new(0.5, 0); meteor.AnchorPoint = Vector2.new(0.5, 0)
		else
			banners.AnchorPoint = Vector2.new(0, 0); meteor.AnchorPoint = Vector2.new(0, 0)
			banners.LayoutOrder = 4; meteor.LayoutOrder = 5
			banners.Parent = refs.leftStack; meteor.Parent = refs.leftStack
		end
	end
	if inBand then
		local cx = (bandL + bandR) / 2
		banners.AutomaticSize = Enum.AutomaticSize.None
		banners.Position = UDim2.fromOffset(cx, 8)
		banners.Size = UDim2.fromOffset(math.min(600, bandW), 120)
		meteor.Position = UDim2.fromOffset(cx, 132)
		meteor.Size = UDim2.fromOffset(math.min(420, bandW), refs.meteorH or metBase())
	else
		-- inside the stack the frame grows with its banners so an empty stack leaves no gap
		banners.AutomaticSize = Enum.AutomaticSize.Y
		banners.Size = UDim2.fromOffset(cardW, 0)
		meteor.Size = UDim2.fromOffset(cardW, refs.meteorH or metBase())
	end
end

-- Responsive layout for panels + the rail, and the GeodeHUD layout attributes.
function UI._RefreshPanels()
	if not gui then return end
	local availW, availH
	if gui.AbsoluteSize.Y > 1 then
		availW, availH = gui.AbsoluteSize.X, gui.AbsoluteSize.Y
	else
		local vp = viewport()
		local inset = GuiService:GetGuiInset()
		availW, availH = vp.X, math.max(160, vp.Y - inset.Y)
	end

	-- rail first (its rendered width feeds the panel region)
	local menuW = 0
	if refs.sideMenu and refs.sideMenuScale and refs.sideMenuDims then
		local dm = refs.sideMenuDims
		local function gridSize(cols)
			local rows = math.ceil(dm.count / cols)
			return dm.btnW * cols + dm.pad * (cols - 1), dm.btnH * rows + dm.pad * (rows - 1)
		end
		local w, h = gridSize(dm.cols)
		if not IS_TOUCH and dm.cols == 1 and h > availH - 20 then w, h = gridSize(2) end
		refs.sideMenu.Size = UDim2.fromOffset(w, h)
		local maxH = IS_TOUCH and (availH - 8 - jumpReserve()) or (availH - 20)
		local ms = math.min(1, maxH / h)
		local minScale = SG.Size.MinTouch / dm.btnH -- never render a rail button below 48 px
		ms = math.clamp(ms, math.min(minScale, 1), 1)
		refs.sideMenuScale.Scale = ms
		-- shrinking: hide the labels first so the icons keep their size
		local showLabels = ms >= 0.999
		for _, item in ipairs(refs.sideMenu:GetChildren()) do
			local b = item:FindFirstChild("Btn")
			local lbl = b and b:FindFirstChild("Label")
			if lbl then lbl.Visible = showLabels end
		end
		menuW = w * ms + 20
	end

	-- panel region: beside the rail only when the full-width panel fits there at scale 1
	-- (a 667 px phone would otherwise shrink every 48 px control to ~42 px), else overlay
	local freeW = availW - menuW - 12
	UI._menuOverlay = freeW < SG.Size.PanelW + 16
	local regionW = UI._menuOverlay and availW or freeW
	local capH = availH * 0.85
	for _, p in ipairs(responsivePanels) do
		local s
		if IS_TOUCH then
			s = math.clamp(math.min(1, (regionW - 16) / p.w), 0.85, 1)
		else
			s = math.clamp(math.min(capH / p.h, (regionW - 16) / p.w), 0.85, 1)
			if availH >= 1000 then
				s = math.clamp(math.min((regionW - 16) / p.w, capH / p.h), 0.85, 1.3)
			end
		end
		p.outer:SetAttribute("FitScale", s)
		local fit = p.outer:FindFirstChildOfClass("UIScale") or mk("UIScale", {}, p.outer)
		if p.outer.Visible then fit.Scale = s end
		p.outer.Size = UDim2.fromOffset(math.min(p.w, (regionW - 16) / s), math.min(p.h, capH / s))
		p.outer.Position = UDim2.fromOffset(regionW / 2, availH / 2)
	end

	-- layout attributes (Feed / Effects read only these)
	local stackW, stackBottom = 0, 12
	if refs.leftStack then
		stackW = refs.leftStack.AbsoluteSize.X
		stackBottom = 12 + refs.leftStack.AbsoluteSize.Y
	end
	local bandL = stackW + 20
	local bandR = availW - menuW - 8
	gui:SetAttribute("LeftStackBottom", stackBottom)
	gui:SetAttribute("CentreBandLeft", bandL)
	gui:SetAttribute("CentreBandRight", bandR)
	placeBand(bandL, bandR, refs.cardW or 240)

	UI._ApplyOpenState()
end

-- While any panel / modal is open: scrim on, CRACK button + backpack hidden, HUD chips
-- and goal card hidden (the gem card stays on desktop; the whole stack hides only in
-- overlay mode), rail slid off the edge in overlay mode. Everything restores on close.
function UI._ApplyOpenState()
	if not gui then return end
	local anyOpen = UI.AnyPanelOpen()
	UI._anyOpen = anyOpen
	gui:SetAttribute("PanelOpen", anyOpen)
	if refs.scrim then
		refs.scrim.Visible = anyOpen
		refs.scrim.Active = anyOpen
	end
	if refs.leftStack then
		if UI._menuOverlay then
			refs.leftStack.Visible = not anyOpen
		else
			refs.leftStack.Visible = true
			if refs.chips then refs.chips.Visible = not anyOpen end
			if refs.goalCard then refs.goalCard.Visible = (not anyOpen) and refs.goalWanted == true end
		end
	end
	local crack = gui:FindFirstChild("CrackWrap")
	if crack then crack.Visible = not anyOpen end
	pcall(function()
		game:GetService("StarterGui"):SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, not anyOpen)
	end)
	if refs.sideMenu then
		local hideMenu = anyOpen and UI._menuOverlay == true
		local rest = IS_TOUCH and UDim2.new(1, -10, 0, 8) or UDim2.new(1, -10, 0.5, 0)
		local target = rest
		if hideMenu then
			target = UDim2.new(1, refs.sideMenu.AbsoluteSize.X + 30, rest.Y.Scale, rest.Y.Offset)
		end
		TweenService:Create(refs.sideMenu, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = target }):Play()
	end
end

-- ===== panels =====
-- refresh functions are forward-declared: builders bind them as the `after` step of
-- UI._bindInvoke so true button states are re-applied once a call returns.
local refreshUpgrades, refreshShop, refreshIndex, refreshDaily, refreshPets, refreshAchievements
local refreshPlayers, refreshSettings

local function fmtMult(m)
	m = tonumber(m) or 1
	if m < 100 then return string.format("%.1f", m) end
	return Config.Fmt(m)
end

-- price button: buy role when affordable, else ghost + disabled; the sub label gains
-- "Need N more" so the gap is readable without hunting for the balance.
local function priceButton(btn, cost, sub, subText)
	local gems = (snap and snap.gems) or 0
	cost = tonumber(cost) or 0
	btn.Text = Config.Cur(cost)
	local can = gems >= cost
	SG.setRole(btn, can and "buy" or "ghost")
	SG.setEnabled(btn, can)
	if sub then
		-- the gap leads so it survives the one-line ellipsis on long sub-lines (Rebirth row)
		sub.Text = can and subText or ("Need " .. Config.Cur(cost - gems) .. " more · " .. subText)
	end
end

-- Buy + outcome toast read from the snapshot the server pushes right after the buy.
local function doBuy(action)
	local seq = updateSeq
	local res = UI._invoke(remote("Buy"), action)
	if res.ok then
		afterSnap(seq, function()
			if not snap then return end
			if action == "Power" then
				UI.Toast(string.format("⛏️ Power Lv %d → crack every %.2f s", snap.power or 0, snap.cooldown or 0), "ok")
			elseif action == "Luck" then
				UI.Toast(string.format("🍀 Luck Lv %d → ×%.2f", snap.luck or 0, snap.luckFactor or 1), "ok")
			elseif action == "Rebirth" then
				UI.Toast("🔄 Rebirth " .. tostring(snap.rebirths or 0) .. " — income ×" .. fmtMult(snap.mult) .. "!", "gold")
			elseif action == "Ascend" then
				UI.Toast("🌌 Ascended! ×" .. Config.Fmt((Config.Balance.AscendMult or 2.5) ^ (snap.ascensions or 0)) .. " base forever · +1 Shard", "gold")
			end
		end)
	elseif res.err and res.err ~= "Slow down!" then
		UI.Toast(res.err, "err")
	end
end

-- ===== upgrades panel =====
local function buildUpgrades()
	local rh, bh = rowH(), btnH()
	local panel = makeScrollPanel("Upgrades", "⛏️ UPGRADES", 700)
	local y = STRIP_H + 8
	local function row(h)
		local r = SG.row({ Position = UDim2.fromOffset(14, y), Size = UDim2.new(1, -28, 0, h), ZIndex = 21 }, panel)
		y += h + 8
		return r
	end
	local LEFT = Enum.TextXAlignment.Left
	local function statRow(icon, key, role)
		local r = row(rh)
		refs[key .. "Label"] = text("Heading", { Position = UDim2.fromOffset(12, 6), Size = UDim2.new(0.58, 0, 0, 22), Text = icon .. " …", TextXAlignment = LEFT, ZIndex = 22 }, r)
		refs[key .. "Sub"] = text("Caption", { Position = UDim2.fromOffset(12, 30), Size = UDim2.new(0.58, 0, 0, 18), Text = "", TextColor3 = MUTED, TextXAlignment = LEFT, ZIndex = 22 }, r)
		refs[key .. "Btn"] = SG.button("…", role or "ghost", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0), Size = UDim2.fromOffset(148, bh), ZIndex = 22 }, r)
		return r
	end

	statRow("⛏️", "power")
	statRow("🍀", "luck")

	-- rebirth row with progress bar
	local rb = row(rh + 14)
	refs.rebirthLabel = text("Heading", { Position = UDim2.fromOffset(12, 6), Size = UDim2.new(0.58, 0, 0, 22), Text = "🔄 Rebirth", TextXAlignment = LEFT, ZIndex = 22 }, rb)
	refs.rebirthSub = text("Caption", { Position = UDim2.fromOffset(12, 30), Size = UDim2.new(0.58, 0, 0, 18), Text = "", TextColor3 = MUTED, TextXAlignment = LEFT, ZIndex = 22 }, rb)
	local barBG = mk("Frame", { Position = UDim2.fromOffset(12, rh), Size = UDim2.new(0.58, 0, 0, 8), BackgroundColor3 = Color.Track, BorderSizePixel = 0, ZIndex = 22 }, rb)
	corner(barBG, "pill")
	refs.rebirthFill = mk("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = ACCENT, BorderSizePixel = 0, ZIndex = 23 }, barBG)
	corner(refs.rebirthFill, "pill")
	refs.rebirthBtn = SG.button("…", "ghost", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0), Size = UDim2.fromOffset(148, bh), ZIndex = 22 }, rb)

	-- ascension row
	statRow("🌌", "asc", "ghost")
	refs.ascLabel.Text = "🌌 Ascend"
	refs.ascBtn.Text = "🌌 Ascend"

	-- perks: full-width rows with the description visible BEFORE spending a shard
	refs.perkHeader = text("Heading", { Position = UDim2.fromOffset(16, y), Size = UDim2.new(1, -32, 0, 22), Text = "✨ Perks", TextXAlignment = LEFT, ZIndex = 21 }, panel)
	y += 28
	refs.perkRows = {}
	for _, perk in ipairs(Config.Perks) do
		local r = row(rh)
		text("Display", { Position = UDim2.fromOffset(6, 0), Size = UDim2.fromOffset(42, rh), Text = perk.icon, ZIndex = 22, fit = true }, r)
		text("Heading", { Position = UDim2.fromOffset(52, 6), Size = UDim2.new(1, -52 - 164, 0, 20), Text = perk.name, TextXAlignment = LEFT, ZIndex = 22 }, r)
		text("Caption", { Position = UDim2.fromOffset(52, 28), Size = UDim2.new(1, -52 - 164, 0, 18), Text = perk.desc, TextColor3 = MUTED, TextXAlignment = LEFT, ZIndex = 22 }, r)
		local btn = SG.button("Unlock · 1 Shard", "buy", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0), Size = UDim2.fromOffset(152, bh), ZIndex = 22 }, r)
		local owned = SG.chip("✅ Owned", GOOD, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), Visible = false, ZIndex = 22 }, r)
		refs.perkRows[perk.key] = { btn = btn, owned = owned }
		UI._bindInvoke(btn, function()
			local res = UI._invoke(remote("Buy"), "Perk:" .. perk.key)
			if res.ok then
				UI.Toast(perk.icon .. " " .. perk.name .. " unlocked — " .. perk.desc, "ok")
			elseif res.err and res.err ~= "Slow down!" then
				UI.Toast(res.err, "err")
			end
		end, refreshUpgrades)
	end
	finishPanel(panel, y + 8)

	UI._bindInvoke(refs.powerBtn, function() doBuy("Power") end, refreshUpgrades)
	UI._bindInvoke(refs.luckBtn, function() doBuy("Luck") end, refreshUpgrades)

	-- Rebirth / Ascend wipe progress: always confirm (hold-to-confirm on touch)
	refs.rebirthBtn.Activated:Connect(function()
		if not snap or refs.rebirthBtn:GetAttribute("SGDisabled") == true then return end
		local n = (snap.rebirths or 0) + 1
		UI.Confirm({
			title = "🔄 Rebirth " .. n .. "?",
			body = "Resets: Gems, Power Lv " .. tostring(snap.power or 0) .. ", Luck Lv " .. tostring(snap.luck or 0)
				.. "\nGains: ×" .. tostring(Config.Balance.RebirthMultBase) .. " income, compounding — and Rebirth pets unlock as you go"
				.. "\nCost: " .. Config.Cur(snap.rebirthCost or 0),
			confirmText = "Rebirth", confirmEnabled = (snap.gems or 0) >= (snap.rebirthCost or math.huge),
			onConfirm = function() doBuy("Rebirth") end,
		})
	end)
	refs.ascBtn.Activated:Connect(function()
		if not snap or refs.ascBtn:GetAttribute("SGDisabled") == true then return end
		UI.Confirm({
			title = "🌌 Ascend?",
			body = "Resets: Gems, Power Lv, Luck Lv and Rebirths (" .. tostring(snap.rebirths or 0) .. " → 0)"
				.. "\nGains: ×" .. tostring(Config.Balance.AscendMult or 2.5) .. " base income forever + 1 Ascension Shard"
				.. "\nYour pets stay unlocked.",
			confirmText = "Ascend", confirmEnabled = (snap.rebirths or 0) >= Config.Balance.AscensionAtRebirth,
			onConfirm = function() doBuy("Ascend") end,
		})
	end)
end

function refreshUpgrades()
	if not (snap and refs.powerBtn) then return end
	local gems = snap.gems or 0
	refs.powerLabel.Text = "⛏️ Power Lv " .. tostring(snap.power or 0)
	priceButton(refs.powerBtn, snap.powerCost, refs.powerSub, string.format("Crack every %.2f s", snap.cooldown or 0))
	refs.luckLabel.Text = "🍀 Luck Lv " .. tostring(snap.luck or 0)
	priceButton(refs.luckBtn, snap.luckCost, refs.luckSub, string.format("Luck ×%.2f", snap.luckFactor or 1))
	refs.rebirthLabel.Text = "🔄 Rebirth " .. tostring((snap.rebirths or 0) + 1)
	refs.rebirthFill.Size = UDim2.fromScale(math.clamp(gems / math.max(1, snap.rebirthCost or 1), 0, 1), 1)
	priceButton(refs.rebirthBtn, snap.rebirthCost, refs.rebirthSub, -- short: the bar shows progress, the confirm lists the details
		"Recrystallize · ×" .. tostring(Config.Balance.RebirthMultBase) .. " income · resets Gems, Power & Luck")
	local ascAt = Config.Balance.AscensionAtRebirth
	local canAsc = (snap.rebirths or 0) >= ascAt
	local ascN = snap.ascensions or 0
	refs.ascLabel.Text = "🌌 Ascend" .. (ascN > 0 and (" · ×" .. Config.Fmt((Config.Balance.AscendMult or 2.5) ^ ascN) .. " base") or "")
	refs.ascSub.Text = canAsc
		and ("×" .. tostring(Config.Balance.AscendMult or 2.5) .. " base forever · +1 Shard · resets Rebirths")
		or ("At Rebirth " .. ascAt .. " (you're at Rebirth " .. tostring(snap.rebirths or 0) .. ")")
	SG.setRole(refs.ascBtn, canAsc and "premium" or "ghost")
	SG.setEnabled(refs.ascBtn, canAsc)
	refs.perkHeader.Text = "✨ Perks — Shards: " .. tostring(snap.shards or 0)
	for key, pr in pairs(refs.perkRows) do
		local owned = snap.perks ~= nil and snap.perks[key] == true
		pr.owned.Visible = owned
		pr.btn.Visible = not owned
		if not owned then
			local can = (snap.shards or 0) > 0
			SG.setRole(pr.btn, can and "buy" or "ghost")
			SG.setEnabled(pr.btn, can)
		end
	end
end

-- ===== shop panel =====
local function purchase(kind, key, targetUserId)
	local res = UI._invoke(remote("Purchase"), kind, key, targetUserId)
	if res.ok then
		if res.msg then UI.Toast(res.msg, "ok") end
	elseif res.err and res.err ~= "Slow down!" then
		UI.Toast(res.err, "err")
	end
end

local function buildShop()
	local bh = btnH()
	local panel = makeScrollPanel("Shop", "🛒 SHOP", 760)
	panel.AutomaticCanvasSize = Enum.AutomaticSize.Y
	panel.CanvasSize = UDim2.new()
	mk("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Center }, panel)
	mk("UIPadding", { PaddingTop = UDim.new(0, STRIP_H + 8), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), PaddingBottom = UDim.new(0, 12) }, panel)
	local order = 0
	local function nextOrder() order += 1; return order end
	local cardH = math.max(72, bh + 16)
	refs.passBtns, refs.zoneBtns = {}, {}

	local LEFT, TOP = Enum.TextXAlignment.Left, Enum.TextYAlignment.Top
	-- Starter Pack offer card (first session only; toggled in refreshShop)
	local sp = Config.ProductByKey("StarterPack")
	if sp then
		local card = SG.row({ Size = UDim2.new(1, -6, 0, cardH + 30), LayoutOrder = nextOrder(), Visible = false, ZIndex = 22 }, panel)
		stroke(card, GOLD, "base", 0.1)
		text("Heading", { Position = UDim2.fromOffset(10, 6), Size = UDim2.new(1, -20, 0, 20), Text = "⭐ STARTER PACK — FIRST-SESSION OFFER",
			TextColor3 = Color.GoldSoft, TextXAlignment = LEFT, ZIndex = 23, fit = true }, card)
		text("Body", { Position = UDim2.fromOffset(10, 28), Size = UDim2.new(1, -20 - 196, 0, cardH - 8), Text = sp.desc, TextColor3 = TEXT,
			TextWrapped = true, TextXAlignment = LEFT, TextYAlignment = TOP, ZIndex = 23, fit = true }, card)
		local btn = SG.button("GET IT — R$ " .. sp.price, "premium", { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -8, 1, -8), Size = UDim2.fromOffset(184, bh), ZIndex = 23 }, card)
		UI._bindInvoke(btn, function() purchase("product", "StarterPack", nil) end, refreshShop)
		refs.starterCard = card
	end

	local function section(str)
		text("Caption", { Size = UDim2.new(1, -12, 0, 22), Text = str, TextColor3 = MUTED, TextXAlignment = LEFT, LayoutOrder = nextOrder(), ZIndex = 22 }, panel)
	end
	local function item(entry, kind)
		local h = cardH + (entry.key == "DoubleGems" and 18 or 0)
		local card = SG.row({ Size = UDim2.new(1, -6, 0, h), LayoutOrder = nextOrder(), ZIndex = 22 }, panel)
		text("Heading", { Position = UDim2.fromOffset(10, 6), Size = UDim2.new(1, -150, 0, 20), Text = entry.icon .. " " .. entry.name, TextXAlignment = LEFT, ZIndex = 23 }, card)
		text("Caption", { Position = UDim2.fromOffset(10, 28), Size = UDim2.new(1, -150, 0, cardH - 34), Text = entry.desc, TextColor3 = MUTED,
			TextWrapped = true, TextXAlignment = LEFT, TextYAlignment = TOP, ZIndex = 23, fit = true }, card)
		if entry.key == "DoubleGems" then
			refs.doubleGemsNote = text("Caption", { Position = UDim2.fromOffset(10, cardH - 4), Size = UDim2.new(1, -150, 0, 16), Text = "",
				TextColor3 = Color.GoldSoft, TextXAlignment = LEFT, Visible = false, ZIndex = 23 }, card)
		end
		local btn = SG.button("R$ " .. entry.price, "premium", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0), Size = UDim2.fromOffset(124, bh), ZIndex = 23 }, card)
		local owned = SG.chip("✅ OWNED", GOOD, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), Visible = false, ZIndex = 23 }, card)
		if kind == "pass" then refs.passBtns[entry.key] = { btn = btn, owned = owned } end
		if entry.zoneUnlock and entry.zone then
			owned.Text = "✅ UNLOCKED"
			refs.zoneBtns[entry.zone] = { btn = btn, owned = owned }
		end
		UI._bindInvoke(btn, function()
			if entry.key == "GiftBoost" then
				-- the recipient is always an explicit tap on a Players row (never a picker guess)
				UI.ShowPanel("Players")
				UI.Toast("Pick a miner to gift from the Players list 🎁", "info")
				return
			end
			purchase(kind, entry.key, nil)
		end, refreshShop)
	end

	section("GAME PASSES — permanent")
	for _, pass in ipairs(Config.GamePasses) do item(pass, "pass") end
	section("GEMS & POWER-UPS")
	for _, prod in ipairs(Config.DevProducts) do
		if not prod.starter and not prod.zoneUnlock then item(prod, "product") end
	end
	local zonesShown = false
	for _, prod in ipairs(Config.DevProducts) do
		if prod.zoneUnlock then
			if not zonesShown then
				zonesShown = true
				section("ZONES — skip the gate (every zone is also earnable free)")
			end
			item(prod, "product")
		end
	end
	refs.shopNote = text("Caption", { Size = UDim2.new(1, -12, 0, 26), Text = "Purchases support the game — thank you! 💜", TextColor3 = MUTED, LayoutOrder = nextOrder(), ZIndex = 22 }, panel)
end

function refreshShop()
	if not (snap and refs.passBtns) then return end
	for key, e in pairs(refs.passBtns) do
		local owned = snap.passes ~= nil and snap.passes[key] == true
		e.btn.Visible = not owned
		e.owned.Visible = owned
	end
	for zone, e in pairs(refs.zoneBtns) do
		local owned = (snap.zonesPurchased ~= nil and snap.zonesPurchased[zone]) and true or false
		e.btn.Visible = not owned
		e.owned.Visible = owned
	end
	if refs.starterCard then refs.starterCard.Visible = (snap.starterOffered == true) end
end

-- ===== collection index panel =====
local MUT_TAGS = { "⬜", "✨", "💟", "🌟" }
local MUT_NAMES = { "Normal", "Glowing", "Giant", "Celestial" }
local function buildIndex()
	local panel = makeScrollPanel("Index", "📖 INDEX", 680)
	local y = STRIP_H + 8
	local LEFT = Enum.TextXAlignment.Left
	refs.indexHeader = text("Body", { Position = UDim2.fromOffset(18, y), Size = UDim2.new(1, -36, 0, 20), Text = "0/28 collected · each full row = +10% Luck",
		TextColor3 = MUTED, TextXAlignment = LEFT, ZIndex = 21 }, panel)
	y += 26
	-- legend as a column-header row over the mutation cells
	local cellX, cellW, cellGap, cellH = 150, 68, 76, 44
	for m = 1, 4 do
		text("Caption", { Position = UDim2.fromOffset(cellX + (m - 1) * cellGap, y), Size = UDim2.fromOffset(cellGap - 2, 18), -- full column pitch: "🌟 Celestial" fits without wrapping
			Text = MUT_TAGS[m] .. " " .. MUT_NAMES[m], TextColor3 = MUTED, ZIndex = 21, fit = true }, panel)
	end
	y += 22
	refs.cells = {}
	for r = 1, 7 do
		local rar = Config.Rarities[r]
		local rowY = y + (r - 1) * (cellH + 8)
		text("Heading", { Position = UDim2.fromOffset(18, rowY), Size = UDim2.fromOffset(124, cellH), Text = rar.name, TextColor3 = rar.color, TextXAlignment = LEFT, ZIndex = 21 }, panel)
		for m = 1, 4 do
			local cell = mk("Frame", { Position = UDim2.fromOffset(cellX + (m - 1) * cellGap, rowY), Size = UDim2.fromOffset(cellW, cellH),
				BackgroundColor3 = BG2, BorderSizePixel = 0, ZIndex = 21 }, panel)
			corner(cell, "sm")
			local cl = text("Heading", { Size = UDim2.fromScale(1, 1), Text = "?", TextColor3 = MUTED, ZIndex = 22, fit = true }, cell)
			refs.cells[(r - 1) * 4 + m] = { frame = cell, label = cl, rarity = r, mutation = m }
		end
	end
	y += 7 * (cellH + 8) + 6
	-- per-zone completion as five labelled mini bars
	text("Caption", { Position = UDim2.fromOffset(18, y), Size = UDim2.new(1, -36, 0, 18), Text = "PER-ZONE COMPLETION", TextColor3 = MUTED, TextXAlignment = LEFT, ZIndex = 21 }, panel)
	y += 22
	refs.zoneBars = {}
	if Config.Zones and Config.Zones.list then
		for _, zone in ipairs(Config.Zones.list) do
			text("Caption", { Position = UDim2.fromOffset(18, y), Size = UDim2.fromOffset(150, 18), Text = zone.icon .. " " .. zone.name, TextXAlignment = LEFT, ZIndex = 21 }, panel)
			local track = mk("Frame", { Position = UDim2.fromOffset(176, y + 5), Size = UDim2.new(1, -176 - 74, 0, 8), BackgroundColor3 = Color.Track, BorderSizePixel = 0, ZIndex = 21 }, panel)
			corner(track, "pill")
			local fill = mk("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = Color.Cyan, BorderSizePixel = 0, ZIndex = 22 }, track)
			corner(fill, "pill")
			local pct = text("Caption", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -18, 0, y), Size = UDim2.fromOffset(50, 18), Text = "0%",
				TextColor3 = MUTED, TextXAlignment = Enum.TextXAlignment.Right, ZIndex = 21 }, panel)
			refs.zoneBars[zone.key] = { fill = fill, pct = pct }
			y += 24
		end
	end
	finishPanel(panel, y + 12)
end

function refreshIndex()
	if not (snap and refs.cells) then return end
	local count = 0
	local mask = tonumber(snap.indexMask) or 0
	for _, cell in pairs(refs.cells) do
		local bitIndex = (cell.rarity - 1) * 4 + (cell.mutation - 1)
		local found = bit32.band(mask, bit32.lshift(1, bitIndex)) ~= 0
		if found then
			count += 1
			cell.frame.BackgroundColor3 = Config.Rarities[cell.rarity].color
			cell.label.Text = MUT_TAGS[cell.mutation]
			cell.label.TextColor3 = Color.TextInk
		else
			cell.frame.BackgroundColor3 = BG2
			cell.label.Text = "?"
			cell.label.TextColor3 = MUTED
		end
	end
	refs.indexHeader.Text = count .. "/28 collected · each full row = +10% Luck"
	if refs.zoneBars and type(snap.zoneIndexPct) == "table" then
		for key, zb in pairs(refs.zoneBars) do
			local f = math.clamp(tonumber(snap.zoneIndexPct[key]) or 0, 0, 1)
			zb.fill.Size = UDim2.fromScale(f, 1)
			zb.pct.Text = math.floor(f * 100 + 0.5) .. "%"
		end
	end
end

-- ===== daily panel (login rewards + quests) =====
local function buildDaily()
	local bh = btnH()
	local panel = makeScrollPanel("Daily", "📅 DAILY", 560)
	local y = STRIP_H + 8
	local LEFT = Enum.TextXAlignment.Left

	text("Heading", { Position = UDim2.fromOffset(14, y), Size = UDim2.new(1, -28, 0, 20), Text = "🎁 LOGIN REWARD", TextColor3 = GOLD, TextXAlignment = LEFT, ZIndex = 23 }, panel)
	y += 24
	local cellRow = mk("Frame", { Position = UDim2.fromOffset(12, y), Size = UDim2.new(1, -24, 0, 60), BackgroundTransparency = 1, ZIndex = 23 }, panel)
	mk("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4),
		HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, cellRow)
	refs.dailyCells = {}
	for d = 1, 7 do
		local cell = mk("Frame", { Size = UDim2.new(1 / 7, -4, 1, 0), BackgroundColor3 = BG2, BorderSizePixel = 0, LayoutOrder = d, ZIndex = 23 }, cellRow)
		corner(cell, "sm")
		local day = text("Caption", { Position = UDim2.fromOffset(0, 4), Size = UDim2.new(1, 0, 0, 14), Text = "Day " .. d, TextColor3 = MUTED, ZIndex = 24 }, cell)
		local amt = text("Heading", { Position = UDim2.fromOffset(0, 20), Size = UDim2.new(1, -2, 0, 20), Text = "", ZIndex = 24, fit = true }, cell)
		local star = text("Caption", { Position = UDim2.fromOffset(0, 42), Size = UDim2.new(1, 0, 0, 14), Text = "", ZIndex = 24 }, cell)
		refs.dailyCells[d] = { frame = cell, day = day, amt = amt, star = star }
	end
	y += 68
	refs.dailyClaim = SG.button("CLAIM", "buy", { Position = UDim2.fromOffset(12, y), Size = UDim2.new(1, -24, 0, bh), ZIndex = 23 }, panel)
	refs.dailyClaimed = SG.chip("✅ Claimed — back tomorrow!", GOOD, { Position = UDim2.fromOffset(12, y + math.floor((bh - SG.Size.Chip) / 2)), Visible = false, ZIndex = 23 }, panel)
	UI._bindInvoke(refs.dailyClaim, function()
		local res = UI._invoke(remote("ClaimDaily"))
		-- success feedback is the server's personal "🎁 Day N reward: +N" Tell (+ the streak
		-- card): one pill per action, so no client outcome toast here
		if not res.ok and res.err and res.err ~= "Slow down!" then
			UI.Toast(res.err, "err")
		end
	end, refreshDaily)
	y += bh + 6
	text("Caption", { Position = UDim2.fromOffset(14, y), Size = UDim2.new(1, -28, 0, 16), Text = "Miss a day and the streak restarts", TextColor3 = MUTED, TextXAlignment = LEFT, ZIndex = 23 }, panel)
	y += 24

	text("Heading", { Position = UDim2.fromOffset(14, y), Size = UDim2.new(1, -28, 0, 20), Text = "📋 DAILY QUESTS", TextColor3 = INFO, TextXAlignment = LEFT, ZIndex = 23 }, panel)
	y += 24
	refs.dailyNote = text("Caption", { Position = UDim2.fromOffset(14, y), Size = UDim2.new(1, -28, 0, 16), Text = "Complete all 3 → 🌟 Rare Geode!", TextColor3 = GOLD, TextXAlignment = LEFT, ZIndex = 23 }, panel)
	y += 22
	refs.dailyQuests = {}
	for i = 1, 3 do
		local row = SG.row({ Position = UDim2.fromOffset(12, y), Size = UDim2.new(1, -24, 0, 58), ZIndex = 23 }, panel)
		local desc = text("Heading", { Position = UDim2.fromOffset(10, 5), Size = UDim2.new(1, -144, 0, 18), Text = "", TextXAlignment = LEFT, ZIndex = 24 }, row)
		local reward = text("Heading", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 5), Size = UDim2.fromOffset(124, 18), Text = "",
			TextColor3 = GOLD, TextXAlignment = Enum.TextXAlignment.Right, ZIndex = 24 }, row)
		local barBG = mk("Frame", { Position = UDim2.fromOffset(10, 30), Size = UDim2.new(1, -20, 0, 8), BackgroundColor3 = Color.Track, BorderSizePixel = 0, ZIndex = 24 }, row)
		corner(barBG, "pill")
		local fill = mk("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = INFO, BorderSizePixel = 0, ZIndex = 25 }, barBG)
		corner(fill, "pill")
		local prog = text("Caption", { Position = UDim2.fromOffset(10, 40), Size = UDim2.new(1, -20, 0, 14), Text = "", TextColor3 = MUTED, TextXAlignment = LEFT, ZIndex = 24 }, row)
		y += 64
		refs.dailyQuests[i] = { row = row, desc = desc, reward = reward, fill = fill, prog = prog }
	end
	finishPanel(panel, y + 8)
end

function refreshDaily()
	local d = snap and snap.daily
	if not (d and refs.dailyCells) then return end
	local today = tonumber(d.streakDay) or 1
	for i = 1, 7 do
		local cell = refs.dailyCells[i]
		local r = d.ladder and d.ladder[i]
		if cell and r then
			cell.amt.Text = Config.Fmt(r.gems or 0)
			local special = r.golden and "🌟" or (r.luck and "🍀" or "")
			if i == today then
				cell.frame.BackgroundColor3 = Color.TodayFill
				cell.frame.BackgroundTransparency = 0
				cell.day.Text = "Today"
				cell.day.TextColor3 = TEXT
				cell.amt.TextColor3 = TEXT
				cell.star.Text = d.claimable and (special ~= "" and special or "🎁") or "✓"
			elseif i < today then
				cell.frame.BackgroundColor3 = Color.GreenDim
				cell.frame.BackgroundTransparency = 0.35
				cell.day.Text = "Day " .. i
				cell.day.TextColor3 = TEXT
				cell.amt.TextColor3 = TEXT
				cell.star.Text = "✓"
			else
				cell.frame.BackgroundColor3 = BG2
				cell.frame.BackgroundTransparency = 0.5
				cell.day.Text = "Day " .. i
				cell.day.TextColor3 = MUTED
				cell.amt.TextColor3 = MUTED
				cell.star.Text = special
			end
		end
	end
	local claimable = d.claimable == true
	refs.dailyClaim.Visible = claimable
	refs.dailyClaimed.Visible = not claimable
	if claimable then refs.dailyClaim.Text = "CLAIM DAY " .. tostring(today) end
	SG.setGlow(refs.dailyClaim, claimable)
	for i = 1, 3 do
		local q = d.quests and d.quests[i]
		local row = refs.dailyQuests[i]
		if q and row then
			row.row.Visible = true
			row.desc.Text = (q.done and "✅ " or "") .. tostring(q.desc or "")
			row.reward.Text = "+" .. Config.Cur(q.gems or 0)
			row.fill.Size = UDim2.fromScale(math.clamp((q.progress or 0) / math.max(1, q.goal or 1), 0, 1), 1)
			row.fill.BackgroundColor3 = q.done and GOOD or INFO
			row.prog.Text = Config.Fmt(q.progress or 0) .. " / " .. Config.Fmt(q.goal or 0)
		elseif row then
			row.row.Visible = false
		end
	end
	refs.dailyNote.Text = d.setDone and "🌟 All quests done — Rare Geode earned!" or "Complete all 3 → 🌟 Rare Geode!"
end

-- ===== pets panel (rebirth pets + collectibles) =====
local function buildPets()
	local rh, bh = rowH(), btnH()
	local panel = makeScrollPanel("Pets", "🐾 PETS", 1200)
	local y = STRIP_H + 8
	local LEFT = Enum.TextXAlignment.Left
	refs.petsHeader = text("Body", { Position = UDim2.fromOffset(14, y), Size = UDim2.new(1, -28, 0, 36), Text = "", TextColor3 = GOLD, TextWrapped = true, TextXAlignment = LEFT, ZIndex = 23, fit = true }, panel)
	y += 42
	text("Heading", { Position = UDim2.fromOffset(14, y), Size = UDim2.new(1, -28, 0, 20), Text = "🔄 REBIRTH PETS — permanent Gem bonus", TextColor3 = MUTED, TextXAlignment = LEFT, ZIndex = 23 }, panel)
	y += 24
	refs.petRows = {}
	for i = 1, 12 do -- 10 rebirth pets + VIP + Starter Pack pets
		local row = SG.row({ Position = UDim2.fromOffset(12, y), Size = UDim2.new(1, -24, 0, rh), ZIndex = 23 }, panel)
		local icon = text("Display", { Position = UDim2.fromOffset(6, 0), Size = UDim2.fromOffset(42, rh), Text = "", ZIndex = 24, fit = true }, row)
		local name = text("Heading", { Position = UDim2.fromOffset(52, 6), Size = UDim2.new(1, -52 - 176, 0, 20), Text = "", TextXAlignment = LEFT, ZIndex = 24 }, row)
		local sub = text("Caption", { Position = UDim2.fromOffset(52, 28), Size = UDim2.new(1, -52 - 176, 0, 18), Text = "", TextColor3 = MUTED, TextXAlignment = LEFT, ZIndex = 24 }, row)
		local btn = SG.button("EQUIP", "primary", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0), Size = UDim2.fromOffset(128, bh), ZIndex = 24 }, row)
		local chip = SG.chip("", MUTED, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), Visible = false, ZIndex = 24 }, row)
		local tierIdx = i
		UI._bindInvoke(btn, function()
			local res = UI._invoke(remote("EquipPet"), tierIdx)
			if res.ok then
				local t = snap and snap.pets and snap.pets.tiers and snap.pets.tiers[tierIdx]
				UI.Toast(t and (t.emoji .. " " .. t.name .. " equipped · +" .. tostring(t.bonusPct) .. "% Gems") or "Pet equipped!", "ok")
			elseif res.err and res.err ~= "Slow down!" then
				UI.Toast(res.err, "err")
			end
		end, refreshPets)
		y += rh + 6
		refs.petRows[i] = { row = row, icon = icon, name = name, sub = sub, btn = btn, chip = chip }
	end

	y += 8
	text("Heading", { Position = UDim2.fromOffset(14, y), Size = UDim2.new(1, -28, 0, 20), Text = "✨ COLLECTIBLES", TextColor3 = GOLD, TextXAlignment = LEFT, ZIndex = 23 }, panel)
	y += 22
	refs.collectHeader = text("Caption", { Position = UDim2.fromOffset(14, y), Size = UDim2.new(1, -28, 0, 16), Text = "Crack geodes to find zone pets · fuse 3 of a kind → next tier",
		TextColor3 = MUTED, TextXAlignment = LEFT, ZIndex = 23 }, panel)
	y += 22
	refs.collectRows = {}
	for i = 1, 5 do
		local row = SG.row({ Position = UDim2.fromOffset(12, y), Size = UDim2.new(1, -24, 0, rh), Visible = false, ZIndex = 23 }, panel)
		local icon = text("Display", { Position = UDim2.fromOffset(6, 0), Size = UDim2.fromOffset(42, rh), Text = "", ZIndex = 24, fit = true }, row)
		local nm = text("Heading", { Position = UDim2.fromOffset(52, 6), Size = UDim2.new(1, -52 - 180, 0, 20), Text = "", TextXAlignment = LEFT, ZIndex = 24 }, row)
		local counts = text("Caption", { Position = UDim2.fromOffset(52, 28), Size = UDim2.new(1, -52 - 180, 0, 18), Text = "", TextColor3 = MUTED, TextXAlignment = LEFT, ZIndex = 24 }, row)
		local btn = SG.button("Fuse", "buy", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0), Size = UDim2.fromOffset(160, bh), ZIndex = 24 }, row)
		local chip = SG.chip("Need 3 to fuse", MUTED, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), Visible = false, ZIndex = 24 }, row)
		refs.collectRows[i] = { row = row, icon = icon, name = nm, counts = counts, btn = btn, chip = chip, zone = nil, fuseVariant = nil }
		UI._bindInvoke(btn, function()
			local rr = refs.collectRows[i]
			if not (rr.zone and rr.fuseVariant) then return end
			local res = UI._invoke(remote("FusePet"), rr.zone, rr.fuseVariant)
			-- success feedback is the server's own-milestone "pet" broadcast ("✨ X fused a
			-- Golden …!"), toasted by UI.Banner: one pill per action
			if not res.ok and res.err and res.err ~= "Slow down!" then
				UI.Toast(res.err, "err")
			end
		end, refreshPets)
		y += rh + 6
	end
	finishPanel(panel, y + 8)
end

function refreshPets()
	local pt = snap and snap.pets
	if not (pt and refs.petRows) then return end
	for i, rowRef in ipairs(refs.petRows) do
		local t = pt.tiers and pt.tiers[i]
		if t then
			rowRef.row.Visible = true
			rowRef.icon.Text = t.unlocked and t.emoji or "🔒"
			rowRef.name.Text = t.name
			rowRef.name.TextColor3 = t.unlocked and rgb(t.color) or MUTED
			-- short enough for the one-line 224 px Caption box (the lock chip already says Starter Pack / VIP)
			local reqText = t.starter and "⭐ Starter Pack" or (t.vip and "👑 VIP pet" or ("Rebirth " .. tostring(t.req)))
			rowRef.sub.Text = reqText .. " · +" .. tostring(t.bonusPct) .. "% Gems"
			if t.equipped then
				rowRef.btn.Visible = false
				rowRef.chip.Visible = true
				rowRef.chip.Text = "✅ EQUIPPED"
				rowRef.chip.TextColor3 = GOOD
			elseif t.unlocked then
				rowRef.btn.Visible = true
				rowRef.chip.Visible = false
				rowRef.btn.Text = "EQUIP"
				SG.setRole(rowRef.btn, "primary")
				SG.setEnabled(rowRef.btn, true)
			else
				rowRef.btn.Visible = false
				rowRef.chip.Visible = true
				rowRef.chip.Text = t.starter and "🔒 Starter Pack" or (t.vip and "🔒 VIP" or ("🔒 Rebirth " .. tostring(t.req)))
				rowRef.chip.TextColor3 = MUTED
			end
		else
			rowRef.row.Visible = false
		end
	end
	-- header: lifetime rebirths (never "you're at Rebirth 0" for an ascended player)
	local life = tonumber(pt.lifetimeRebirths) or tonumber(snap.rebirths) or tonumber(pt.rebirths) or 0
	local asc = tonumber(snap.ascensions) or 0
	local you = "Lifetime Rebirths " .. tostring(life) .. (asc > 0 and (" · Ascension " .. tostring(asc)) or "")
	if pt.nextName then
		refs.petsHeader.Text = "🎯 Next: " .. pt.nextName .. " at Rebirth " .. tostring(pt.nextReq) .. "  ·  " .. you
	else
		refs.petsHeader.Text = "🏆 All rebirth pets unlocked — " .. you
	end

	local cp = snap.collectPets
	if cp and refs.collectRows then
		local pets = cp.pets or {}
		refs.collectHeader.Text = (#pets > 0)
			and ("Active bonus: +" .. math.floor((cp.bonus or 0) * 100 + 0.5) .. "% Gems (best pet) · fuse 3 of a kind → next tier")
			or "Crack geodes to find zone pets · fuse 3 of a kind → next tier"
		for i, rr in ipairs(refs.collectRows) do
			local cpp = pets[i]
			if cpp then
				rr.row.Visible = true
				rr.zone = cpp.zone
				rr.icon.Text = cpp.emoji or "🐾"
				rr.name.Text = cpp.name or "?"
				rr.name.TextColor3 = rgb(cpp.color)
				local c = cpp.counts or {}
				rr.counts.Text = "Normal " .. tostring(c[1] or 0) .. " · Golden " .. tostring(c[2] or 0) .. " · Rainbow " .. tostring(c[3] or 0)
				-- prefer the HIGHEST fusable variant (Golden → Rainbow before Normal → Golden)
				local fv = nil
				if (c[2] or 0) >= 3 then fv = 2 elseif (c[1] or 0) >= 3 then fv = 1 end
				rr.fuseVariant = fv
				if fv then
					rr.btn.Visible = true
					rr.chip.Visible = false
					rr.btn.Text = fv == 1 and "Fuse 3 → Golden" or "Fuse 3 → Rainbow"
					SG.setRole(rr.btn, "buy")
					SG.setEnabled(rr.btn, true)
				else
					rr.btn.Visible = false
					rr.chip.Visible = true
				end
			else
				rr.row.Visible = false
				rr.zone = nil
				rr.fuseVariant = nil
			end
		end
	end
end

-- ===== awards panel =====
local function buildAchievements()
	local bh = btnH()
	local panel = makeScrollPanel("Achievements", "🏅 AWARDS", 600)
	panel.AutomaticCanvasSize = Enum.AutomaticSize.Y
	panel.CanvasSize = UDim2.new()
	mk("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Center }, panel)
	mk("UIPadding", { PaddingTop = UDim.new(0, STRIP_H + 8), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), PaddingBottom = UDim.new(0, 12) }, panel)
	local cardH = math.max(76, bh + 16)
	refs.achRows = {}
	local LEFT = Enum.TextXAlignment.Left
	for i = 1, 8 do
		local card = SG.row({ Size = UDim2.new(1, -6, 0, cardH), LayoutOrder = i, Visible = false, ZIndex = 22 }, panel)
		local icon = text("Display", { Position = UDim2.fromOffset(6, 0), Size = UDim2.fromOffset(46, cardH), Text = "", ZIndex = 23, fit = true }, card)
		local name = text("Heading", { Position = UDim2.fromOffset(58, 6), Size = UDim2.new(1, -58 - 150, 0, 20), Text = "", TextXAlignment = LEFT, ZIndex = 23 }, card)
		local prog = text("Caption", { Position = UDim2.fromOffset(58, 28), Size = UDim2.new(1, -58 - 150, 0, 16), Text = "", TextColor3 = MUTED, TextXAlignment = LEFT, ZIndex = 23 }, card)
		local barBG = mk("Frame", { Position = UDim2.fromOffset(58, cardH - 18), Size = UDim2.new(1, -58 - 160, 0, 8), BackgroundColor3 = Color.Track, BorderSizePixel = 0, ZIndex = 23 }, card)
		corner(barBG, "pill")
		local fill = mk("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = GOLD, BorderSizePixel = 0, ZIndex = 24 }, barBG)
		corner(fill, "pill")
		local btn = SG.button("CLAIM", "buy", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0), Size = UDim2.fromOffset(132, bh), ZIndex = 23 }, card)
		local chip = SG.chip("", MUTED, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), Visible = false, ZIndex = 23 }, card)
		refs.achRows[i] = { card = card, icon = icon, name = name, prog = prog, fill = fill, btn = btn, chip = chip, key = nil }
		UI._bindInvoke(btn, function()
			local rowRef = refs.achRows[i]
			if not rowRef.key then return end
			local res = UI._invoke(remote("ClaimAchievement"), rowRef.key)
			-- success feedback is the server's personal "🏅 Name — Tier N! +N" Tell: one pill per action
			if not res.ok and res.err and res.err ~= "Slow down!" then
				UI.Toast(res.err, "err")
			end
		end, refreshAchievements)
	end
end

function refreshAchievements()
	local list = snap and snap.achievements
	if not (list and refs.achRows) then return end
	for i, rowRef in ipairs(refs.achRows) do
		local a = list[i]
		if a then
			rowRef.card.Visible = true
			rowRef.key = a.key
			rowRef.icon.Text = a.icon or "🏅"
			rowRef.name.Text = a.name or ""
			local done = 0
			local tiers = a.tiers or {}
			for _, t in ipairs(tiers) do if t.claimed then done += 1 end end
			local nextTier = tiers[done + 1]
			if nextTier then
				rowRef.prog.Text = Config.Fmt(a.cur or 0) .. " / " .. Config.Fmt(nextTier.goal or 0) .. "  →  +" .. Config.Cur(nextTier.gems or 0)
				rowRef.fill.Size = UDim2.fromScale(math.clamp((a.cur or 0) / math.max(1, nextTier.goal or 1), 0, 1), 1)
				if a.claimable then
					rowRef.btn.Visible = true
					rowRef.chip.Visible = false
					rowRef.btn.Text = "CLAIM"
					SG.setRole(rowRef.btn, "buy")
					SG.setEnabled(rowRef.btn, true)
					SG.setGlow(rowRef.btn, true)
				else
					rowRef.btn.Visible = false
					SG.setGlow(rowRef.btn, false)
					rowRef.chip.Visible = true
					rowRef.chip.Text = "Tier " .. tostring(done + 1) .. "/" .. tostring(#tiers)
					rowRef.chip.TextColor3 = MUTED
				end
			else
				rowRef.prog.Text = "✅ All tiers complete!"
				rowRef.fill.Size = UDim2.fromScale(1, 1)
				rowRef.btn.Visible = false
				SG.setGlow(rowRef.btn, false)
				rowRef.chip.Visible = true
				rowRef.chip.Text = "✓ DONE"
				rowRef.chip.TextColor3 = GOOD
			end
		else
			rowRef.card.Visible = false
			rowRef.key = nil
		end
	end
end

-- ===== players panel (UI-4 online tab · UI-5 leaderboards) =====
-- Online rows rebuild ONLY from PlayerAdded / PlayerRemoving + one AttributeChanged
-- connection per player, coalesced 0.5 s and only while the panel is visible (a closed
-- panel just remembers it is dirty — no timer runs). Boards call GetLeaderboard on open
-- and at most once per 30 s per kind (failures cached too); rows are pooled SG.rows.
local playerConns = {}        -- [player] = AttributeChanged connection
local playersDirty, playersTimer = true, false
local playersTab = "Online"   -- "Online" | "gems" | "rebirths"
local friendsOnly = false
local cheerOpenFor = nil      -- userId whose cheer strip is expanded
local cheerLockUntil = 0      -- os.clock(): strip disabled until then (Config.Social.CheerGap)
local thumbCache = {}         -- [userId] = content url ("" while loading / after a failure)
local friendCache = {}        -- [userId] = boolean (LocalPlayer:IsFriendsWith, once per session)
local lbCache = {}            -- [kind] = { at = os.clock(), res = reply }
local lbPending = {}          -- [kind] = true while a call is in flight
local ROW_ACT = 48            -- Gift / Cheer / Profile / reaction buttons: the 48 px floor everywhere

local function markPlayersDirty()
	playersDirty = true
	local p = panels.Players
	if not (p and p.Visible) or playersTimer then return end
	playersTimer = true
	task.delay(0.5, function()
		playersTimer = false
		if playersDirty and panels.Players and panels.Players.Visible and playersTab == "Online" then
			refreshPlayers()
		end
	end)
end

local function watchPlayer(pl)
	if playerConns[pl] then return end
	playerConns[pl] = pl.AttributeChanged:Connect(markPlayersDirty)
	markPlayersDirty()
end

local function zoneOf(pl)
	local z = pl:GetAttribute("Zone")
	return type(z) == "string" and z ~= "" and z or "Cavern"
end

-- text-first rows: the emoji face shows at once, the HeadShot fills in when it lands
local function fetchThumb(uid, img)
	local cached = thumbCache[uid]
	if cached then
		if cached ~= "" then img.Image = cached; img.Visible = true end
		return
	end
	thumbCache[uid] = ""
	task.spawn(function()
		local ok, url, ready = pcall(Players.GetUserThumbnailAsync, Players, uid, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size48x48)
		if ok and ready and type(url) == "string" and url ~= "" then
			thumbCache[uid] = url
			if img.Parent and img:GetAttribute("Uid") == uid then
				img.Image = url
				img.Visible = true
			end
		end
	end)
end

local function onlineRow(i)
	local pool = refs.onlineRows
	if pool[i] then return pool[i] end
	local h = IS_TOUCH and 56 or 52
	local textR = 3 * (ROW_ACT + 4) + 8 -- right inset for the three action buttons
	local row = SG.row({ Size = UDim2.new(1, 0, 0, h), LayoutOrder = i * 2, ZIndex = 22 }, refs.onlineBox)
	local face = text("Display", { Position = UDim2.fromOffset(4, (h - 48) / 2), Size = UDim2.fromOffset(48, 48), Text = "🙂", ZIndex = 23, fit = true }, row)
	local img = mk("ImageLabel", { Position = UDim2.fromOffset(4, (h - 48) / 2), Size = UDim2.fromOffset(48, 48), BackgroundTransparency = 1,
		BorderSizePixel = 0, Visible = false, ZIndex = 24 }, row)
	corner(img, "pill")
	local name = text("Heading", { Position = UDim2.fromOffset(58, 5), Size = UDim2.new(1, -58 - textR - 96, 0, 22), Text = "", TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 23 }, row)
	local tier = SG.chip("R0", ACCENT, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -textR, 0, 3), ZIndex = 23 }, row)
	local sub = text("Caption", { Position = UDim2.fromOffset(58, 30), Size = UDim2.new(1, -58 - textR, 0, 18), Text = "", TextColor3 = MUTED, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 23 }, row)
	local function act(label, role, slot)
		return SG.button(label, role, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -(4 + slot * (ROW_ACT + 4)), 0.5, 0), Size = UDim2.fromOffset(ROW_ACT, ROW_ACT), ZIndex = 23 }, row)
	end
	local profileB, cheerB, giftB = act("👤", "ghost", 0), act("👏", "primary", 1), act("🎁", "premium", 2)
	-- cheer strip: the six fixed reactions, expanded under the row
	local strip = mk("Frame", { Size = UDim2.new(1, 0, 0, 56), BackgroundTransparency = 1, LayoutOrder = i * 2 + 1, Visible = false, ZIndex = 22 }, refs.onlineBox)
	mk("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center }, strip)
	local emojis = {}
	for k, e in ipairs((Config.Social and Config.Social.Reactions) or { "👏" }) do
		emojis[k] = SG.button(e, "ghost", { Size = UDim2.fromOffset(ROW_ACT, ROW_ACT), LayoutOrder = k, ZIndex = 23 }, strip)
	end
	local r = { row = row, face = face, img = img, name = name, tier = tier, sub = sub, profileB = profileB, cheerB = cheerB,
		giftB = giftB, strip = strip, emojis = emojis, uid = nil, who = "" }
	pool[i] = r
	-- handlers read r.uid: the row is pooled and re-assigned on every rebuild
	profileB.Activated:Connect(function()
		if r.uid and profileB:GetAttribute("SGDisabled") ~= true then UI.OpenProfile(r.uid) end
	end)
	cheerB.Activated:Connect(function()
		if not r.uid or cheerB:GetAttribute("SGDisabled") == true then return end
		cheerOpenFor = (cheerOpenFor ~= r.uid) and r.uid or nil
		refreshPlayers()
	end)
	giftB.Activated:Connect(function()
		if not r.uid or giftB:GetAttribute("SGDisabled") == true then return end
		local uid, who = r.uid, r.who
		local gift = Config.ProductByKey("GiftBoost")
		local price = tostring(gift and gift.price or 25)
		UI.Confirm({
			title = "🎁 Gift a Lucky Boost?",
			body = "Gift a 5-min Lucky Boost to " .. who .. " · R$ " .. price .. "\nEveryone on the server also gets +10% Server Luck.",
			confirmText = "Gift · R$ " .. price, confirmRole = "premium", hold = false,
			onConfirm = function() purchase("product", "GiftBoost", uid) end,
		})
	end)
	for k, e in ipairs(emojis) do
		e.Activated:Connect(function()
			if not r.uid or e:GetAttribute("SGDisabled") == true then return end
			if not UI.OnCheer then
				UI.Toast("Cheers are not available right now", "warn")
				return
			end
			UI.OnCheer(r.uid, k)
			-- + 0.25 s = SocialFX.Send's debounce, strictly longer than the server's S.Guard gap,
			-- so a tap the instant the strip unlocks is never dropped silently
			local gap = ((Config.Social and tonumber(Config.Social.CheerGap)) or 2) + 0.25
			cheerLockUntil = os.clock() + gap
			for _, b in ipairs(emojis) do SG.setEnabled(b, false) end
			task.delay(gap, function()
				if strip.Visible and os.clock() >= cheerLockUntil then
					for _, b in ipairs(emojis) do SG.setEnabled(b, true) end
				end
			end)
		end)
	end
	return r
end

local refreshBoard -- UI-5, below

function refreshPlayers()
	if not refs.onlineBox then return end
	local online = playersTab == "Online"
	for key, b in pairs(refs.tabBtns) do SG.setRole(b, key == playersTab and "primary" or "ghost") end
	refs.onlineBox.Visible = online
	refs.boardBox.Visible = not online
	refs.lbHeader.Visible = not online
	refs.lbFooter.Visible = not online
	refs.lbHint.Visible = false
	refs.boardEmpty.Visible = false
	if not online then
		refs.playersEmpty.Visible = false
		refreshBoard()
		return
	end
	playersDirty = false
	local list = Players:GetPlayers()
	local myZone = ownZoneKey()
	-- same zone first, then Rebirths desc, then name
	table.sort(list, function(a, b)
		local az, bz = zoneOf(a) == myZone, zoneOf(b) == myZone
		if az ~= bz then return az end
		local ar, br = tonumber(a:GetAttribute("Rebirths")) or 0, tonumber(b:GetAttribute("Rebirths")) or 0
		if ar ~= br then return ar > br end
		return a.DisplayName < b.DisplayName
	end)
	for i, pl in ipairs(list) do
		local r = onlineRow(i)
		local uid, isMe = pl.UserId, pl == player
		r.uid, r.who = uid, pl.DisplayName
		r.row.Visible = true
		r.img.Visible = false
		r.img:SetAttribute("Uid", uid)
		fetchThumb(uid, r.img)
		r.name.Text = pl.DisplayName .. (isMe and " · You" or "")
		local reb, asc = tonumber(pl:GetAttribute("Rebirths")) or 0, tonumber(pl:GetAttribute("Ascensions")) or 0
		local col = SG.Tier(reb, asc)
		r.tier.Text = "R" .. tostring(math.floor(reb)) .. (asc > 0 and (" · A" .. tostring(math.floor(asc))) or "")
		r.tier.TextColor3 = col
		local st = r.tier:FindFirstChildOfClass("UIStroke")
		if st then st.Color = col end
		local parts = {}
		local z = Config.Zones and Config.Zones.Get and Config.Zones.Get(zoneOf(pl))
		if z then parts[#parts + 1] = z.icon .. " " .. z.name end
		local petName = pl:GetAttribute("PetName")
		if type(petName) == "string" and petName ~= "" then
			parts[#parts + 1] = tostring(pl:GetAttribute("PetEmoji") or "🐾") .. " " .. petName
		end
		if pl:GetAttribute("IsVIP") == true then parts[#parts + 1] = "👑 VIP" end
		if pl.MembershipType == Enum.MembershipType.Premium then parts[#parts + 1] = "⭐ Premium" end
		local title = pl:GetAttribute("Title")
		if type(title) == "string" and title ~= "" then parts[#parts + 1] = "🏷️ " .. title end
		r.sub.Text = table.concat(parts, " · ")
		-- no actions on your own row
		r.giftB.Visible, r.cheerB.Visible, r.profileB.Visible = not isMe, not isMe, not isMe
		local open = cheerOpenFor == uid and not isMe
		r.strip.Visible = open
		if open then
			local locked = os.clock() < cheerLockUntil
			for _, b in ipairs(r.emojis) do SG.setEnabled(b, not locked) end
		end
	end
	for i = #list + 1, #refs.onlineRows do
		local r = refs.onlineRows[i]
		r.row.Visible, r.strip.Visible, r.uid = false, false, nil
	end
	refs.playersEmpty.Visible = #list <= 1
end

-- ----- leaderboards (UI-5) -----
local function boardRow(i)
	local pool = refs.boardRows
	if pool[i] then return pool[i] end
	local h = IS_TOUCH and 48 or 44
	local row = SG.row({ Size = UDim2.new(1, 0, 0, h), LayoutOrder = i, Visible = false, ZIndex = 22 }, refs.boardBox)
	local rank = text("Number", { Position = UDim2.fromOffset(8, 0), Size = UDim2.fromOffset(52, h), Text = "", TextColor3 = MUTED, ZIndex = 23, fit = true }, row)
	local rc = rank:FindFirstChildOfClass("UITextSizeConstraint")
	if rc then rc.MaxTextSize = 18 end
	local name = text("Heading", { Position = UDim2.fromOffset(66, 0), Size = UDim2.new(1, -66 - 150, 1, 0), Text = "", TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 23 }, row)
	local val = text("Heading", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 0), Size = UDim2.fromOffset(134, h), Text = "", TextColor3 = GOLD,
		TextXAlignment = Enum.TextXAlignment.Right, ZIndex = 23 }, row)
	local st = stroke(row, GOLD, "base", 1) -- own row highlight (transparency 0.1 when it is you)
	local r = { row = row, rank = rank, name = name, val = val, stroke = st, uid = nil }
	pool[i] = r
	hitArea(row, function()
		if r.uid and r.uid ~= player.UserId and Players:GetPlayerByUserId(r.uid) then UI.OpenProfile(r.uid) end
	end)
	return r
end

local function boardValue(kind, v)
	v = tonumber(v) or 0
	if kind == "gems" then return Config.Cur(v) end
	return "🔄 " .. Config.Fmt(v) -- lifetime rebirths; never "Rebirth N" (ascended players)
end

local function renderBoard(kind, res)
	local rows = (type(res) == "table" and type(res.rows) == "table") and res.rows or {}
	local shown, now = 0, serverNow()
	for rankIdx, e in ipairs(rows) do
		if shown >= 50 then break end
		local uid = tonumber(e.userId)
		if not friendsOnly or (uid ~= nil and friendCache[uid] == true) then
			shown += 1
			local r = boardRow(shown)
			local me = uid == player.UserId
			r.uid = uid
			r.row.Visible = true
			r.rank.Text = "#" .. tostring(rankIdx)
			r.name.Text = tostring(e.name or "Miner") .. (me and " · You" or "")
			r.name.TextColor3 = me and GOLD or TEXT
			r.stroke.Transparency = me and 0.1 or 1
			r.val.Text = boardValue(kind, e.value)
		end
	end
	for i = shown + 1, #refs.boardRows do
		refs.boardRows[i].row.Visible = false
		refs.boardRows[i].uid = nil
	end
	local ok = type(res) == "table" and res.ok == true
	if ok and res.global then
		local age = math.max(0, now - (tonumber(res.updatedAt) or now))
		refs.lbStatus.Text = "🌍 Global · updated " .. (age < 60 and "just now" or (tostring(math.floor(age / 60)) .. "m ago"))
	elseif ok then
		refs.lbStatus.Text = "🖥️ This server"
		refs.lbHint.Visible = true
	else
		local err = type(res) == "table" and res.err or nil
		refs.lbStatus.Text = (type(err) == "string" and err ~= "Something went wrong" and err ~= "Unavailable") and err or "⏳ Boards unavailable right now"
	end
	if ok then
		local mine = boardValue(kind, res.myValue)
		if type(res.myRank) == "number" then
			refs.lbFooter.Text = "You: #" .. tostring(res.myRank) .. " · " .. mine
		else
			refs.lbFooter.Text = "Top 50+ — keep cracking! · You: " .. mine
		end
	else
		refs.lbFooter.Text = ""
	end
	if shown == 0 then
		refs.boardEmpty.Text = friendsOnly and "Add friends to see them here" or (ok and "Be the first on the board!" or "")
		refs.boardEmpty.Visible = refs.boardEmpty.Text ~= ""
	else
		refs.boardEmpty.Visible = false
	end
end

-- LocalPlayer:IsFriendsWith yields (web call): resolve the flags for these rows once, then render
local function withFriendFlags(rows, after)
	task.spawn(function()
		for _, e in ipairs(rows) do
			local uid = tonumber(e.userId)
			if uid and friendCache[uid] == nil then
				if uid == player.UserId then
					friendCache[uid] = false
				else
					local ok, v = pcall(player.IsFriendsWith, player, uid)
					friendCache[uid] = ok and v == true
				end
			end
		end
		after()
	end)
end

function refreshBoard()
	local kind = playersTab
	local function show(res)
		if not (panels.Players and panels.Players.Visible and playersTab == kind) then return end
		if friendsOnly then
			withFriendFlags((type(res) == "table" and res.rows) or {}, function()
				if panels.Players and panels.Players.Visible and playersTab == kind then renderBoard(kind, res) end
			end)
		else
			renderBoard(kind, res)
		end
	end
	local c = lbCache[kind]
	if c and os.clock() - c.at < 30 then
		show(c.res)
		return
	end
	if lbPending[kind] then return end
	lbPending[kind] = true
	refs.lbStatus.Text = "⏳ Loading…"
	task.spawn(function()
		local res = UI._invoke(remote("GetLeaderboard"), kind)
		lbPending[kind] = nil
		if res.err == "Slow down!" then -- two tabs inside the 1 s server gap: retry quietly
			task.delay(1.2, function()
				if panels.Players and panels.Players.Visible and playersTab == kind then refreshBoard() end
			end)
			return
		end
		lbCache[kind] = { at = os.clock(), res = res } -- failures cached too: one toast per 30 s at most
		show(res)
	end)
end

local function buildPlayers()
	local th = IS_TOUCH and 48 or 44
	local panel = makeScrollPanel("Players", "👥 PLAYERS", 640)
	panel.AutomaticCanvasSize = Enum.AutomaticSize.Y
	panel.CanvasSize = UDim2.new()
	mk("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Center }, panel)
	mk("UIPadding", { PaddingTop = UDim.new(0, STRIP_H + 8), PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12), PaddingBottom = UDim.new(0, 56) }, panel)
	-- tabs
	local tabs = mk("Frame", { Size = UDim2.new(1, 0, 0, th), BackgroundTransparency = 1, LayoutOrder = 1, ZIndex = 22 }, panel)
	mk("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, tabs)
	refs.tabBtns = {}
	for order, def in ipairs({ { "Online", "Online" }, { "gems", "Top Gems" }, { "rebirths", "Top Rebirths" } }) do
		local key = def[1]
		local b = SG.button(def[2], "ghost", { Size = UDim2.new(1 / 3, -4, 1, 0), LayoutOrder = order, ZIndex = 23 }, tabs)
		refs.tabBtns[key] = b
		b.Activated:Connect(function()
			playersTab = key
			cheerOpenFor = nil
			refreshPlayers()
		end)
	end
	-- board header: source pill + Friends filter
	local hdr = mk("Frame", { Size = UDim2.new(1, 0, 0, th), BackgroundTransparency = 1, LayoutOrder = 2, Visible = false, ZIndex = 22 }, panel)
	refs.lbHeader = hdr
	refs.lbStatus = SG.chip("", INFO, { Position = UDim2.fromOffset(0, math.floor((th - SG.Size.Chip) / 2)), ZIndex = 23 }, hdr)
	refs.lbFriends = SG.button("👫 Friends", "ghost", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(132, th), ZIndex = 23 }, hdr)
	refs.lbFriends.Activated:Connect(function()
		friendsOnly = not friendsOnly
		SG.setRole(refs.lbFriends, friendsOnly and "primary" or "ghost")
		refreshPlayers()
	end)
	refs.lbHint = text("Caption", { Size = UDim2.new(1, 0, 0, 16), Text = "Global boards appear once the game is published", TextColor3 = MUTED,
		TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = 3, Visible = false, ZIndex = 22 }, panel)
	-- online list + empty state
	refs.onlineBox = mk("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = 4, ZIndex = 22 }, panel)
	mk("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, refs.onlineBox)
	refs.onlineRows = {}
	refs.playersEmpty = para("Body", { Size = UDim2.new(1, -8, 0, 40), Text = "You're the first one here — the feed fills up as miners arrive.",
		TextColor3 = MUTED, LayoutOrder = 5, Visible = false, ZIndex = 22 }, panel)
	-- board list + empty state
	refs.boardBox = mk("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = 6, Visible = false, ZIndex = 22 }, panel)
	mk("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, refs.boardBox)
	refs.boardRows = {}
	refs.boardEmpty = text("Body", { Size = UDim2.new(1, 0, 0, 40), Text = "", TextColor3 = MUTED, LayoutOrder = 7, Visible = false, ZIndex = 22 }, panel)
	-- sticky own-rank footer on the outer frame (outside the scroll)
	local outer = panel.Parent
	refs.lbFooter = text("Heading", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(1, 0, 0, 44), Text = "", TextColor3 = GOLD,
		BackgroundColor3 = BG, BackgroundTransparency = 0.06, Visible = false, ZIndex = 25 }, outer)
	corner(refs.lbFooter, "xl")
	-- rebuild sources: PlayerAdded / Removing + ONE AttributeChanged per player (no polling)
	for _, pl in ipairs(Players:GetPlayers()) do watchPlayer(pl) end
	Players.PlayerAdded:Connect(watchPlayer)
	Players.PlayerRemoving:Connect(function(pl)
		local c = playerConns[pl]
		if c then c:Disconnect() end
		playerConns[pl] = nil
		if cheerOpenFor == pl.UserId then cheerOpenFor = nil end
		markPlayersDirty()
	end)
	outer:GetPropertyChangedSignal("Visible"):Connect(function()
		if outer.Visible then
			refreshPlayers()
		else
			cheerOpenFor = nil
		end
	end)
end

-- ===== settings panel (UI-8) =====
-- Music / SFX sliders (drag on the track or ±10), three toggles, Reset, device line.
-- A change applies locally at once (UI.OnSettingsChanged) and reaches the server through
-- SetSettings debounced SettingsGap + 0.5 s trailing — strictly LONGER than the server's
-- S.Guard gap (= SettingsGap), so network jitter can never land the final push < gap after
-- the previous one and have it dropped silently. Initial values: the Config defaults,
-- replaced by snap.settings from the first GetState unless already touched.
local settingsSeeded, settingsTouched, settingsPushTimer = false, false, false
local activeSlider = nil -- slider being dragged (UserInputService.InputChanged / InputEnded in Init)

local function pushSettingsSoon()
	if settingsPushTimer then return end
	settingsPushTimer = true
	local gap = ((Config.Social and tonumber(Config.Social.SettingsGap)) or 2) + 0.5
	task.delay(gap, function()
		settingsPushTimer = false
		local r = remote("SetSettings")
		if r and r:IsA("RemoteEvent") then pcall(r.FireServer, r, UI.GetSettings()) end
	end)
end

local function settingsChanged()
	settingsTouched = true
	if UI.OnSettingsChanged then pcall(UI.OnSettingsChanged, UI.GetSettings()) end
	refreshSettings()
	pushSettingsSoon()
end

local function setSetting(key, value)
	if settings == nil or settings[key] == value then return end
	settings[key] = value
	settingsChanged()
end

local function buildSettings()
	local rh, bh = rowH(), btnH()
	local panel = makeScrollPanel("Settings", "⚙️ SETTINGS", 600)
	local y = STRIP_H + 8
	refs.sliders, refs.toggles = {}, {}
	local function slider(key, label)
		local r = SG.row({ Position = UDim2.fromOffset(14, y), Size = UDim2.new(1, -28, 0, 96), ZIndex = 21 }, panel)
		y += 104
		text("Heading", { Position = UDim2.fromOffset(12, 6), Size = UDim2.new(1, -110, 0, 22), Text = label, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 22 }, r)
		local val = text("Number", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 6), Size = UDim2.fromOffset(80, 22), Text = "0", TextColor3 = GOLD,
			TextXAlignment = Enum.TextXAlignment.Right, ZIndex = 22, fit = true }, r)
		local vc = val:FindFirstChildOfClass("UITextSizeConstraint")
		if vc then vc.MaxTextSize = 18 end
		local minus = SG.button("−10", "ghost", { Position = UDim2.fromOffset(8, 40), Size = UDim2.fromOffset(60, 48), ZIndex = 22 }, r)
		local plus = SG.button("+10", "ghost", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -8, 0, 40), Size = UDim2.fromOffset(60, 48), ZIndex = 22 }, r)
		local track = mk("Frame", { Position = UDim2.fromOffset(92, 60), Size = UDim2.new(1, -184, 0, 8), BackgroundColor3 = Color.Track, BorderSizePixel = 0, ZIndex = 22 }, r)
		corner(track, "pill")
		local fill = mk("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = ACCENT, BorderSizePixel = 0, ZIndex = 23 }, track)
		corner(fill, "pill")
		local ts = IS_TOUCH and 28 or 22
		local thumb = mk("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.fromOffset(ts, ts), BackgroundColor3 = TEXT, BorderSizePixel = 0, ZIndex = 24 }, track)
		corner(thumb, "pill")
		stroke(thumb, ACCENT, "base", 0.1)
		local s = { key = key, val = val, fill = fill, thumb = thumb }
		refs.sliders[key] = s
		function s.fromX(x)
			local rel = math.clamp((x - track.AbsolutePosition.X) / math.max(1, track.AbsoluteSize.X), 0, 1)
			setSetting(key, math.floor(rel * 100 + 0.5))
		end
		-- 48 px drag area over the 8 px track; the drag continues in Init's InputChanged
		local hit = hitArea(r, nil, { Position = UDim2.fromOffset(76, 40), Size = UDim2.new(1, -152, 0, 48), ZIndex = 25 })
		hit.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				activeSlider = s
				s.fromX(input.Position.X)
			end
		end)
		minus.Activated:Connect(function() setSetting(key, math.clamp((tonumber(settings and settings[key]) or 0) - 10, 0, 100)) end)
		plus.Activated:Connect(function() setSetting(key, math.clamp((tonumber(settings and settings[key]) or 0) + 10, 0, 100)) end)
	end
	slider("music", "🎵 Music")
	slider("sfx", "🔊 Sound effects")
	local function toggle(key, label, desc)
		local r = SG.row({ Position = UDim2.fromOffset(14, y), Size = UDim2.new(1, -28, 0, rh), ZIndex = 21 }, panel)
		y += rh + 8
		text("Heading", { Position = UDim2.fromOffset(12, 6), Size = UDim2.new(1, -140, 0, 22), Text = label, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 22 }, r)
		text("Caption", { Position = UDim2.fromOffset(12, 30), Size = UDim2.new(1, -140, 0, 18), Text = desc, TextColor3 = MUTED, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 22 }, r)
		local b = SG.button("OFF", "ghost", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0), Size = UDim2.fromOffset(112, bh), ZIndex = 22 }, r)
		refs.toggles[key] = b
		b.Activated:Connect(function() setSetting(key, not (settings and settings[key] == true)) end)
	end
	toggle("reduceFx", "🎇 Reduce FX", "Fewer flashes, shakes and particles")
	toggle("socialPings", "👏 Social pings", "Cheers and reactions over players")
	toggle("hideFeed", "📣 Hide activity feed", "Hide the live feed of what miners are doing")
	refs.deviceLine = text("Caption", { Position = UDim2.fromOffset(16, y), Size = UDim2.new(1, -32, 0, 18), Text = "", TextColor3 = MUTED, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 21 }, panel)
	y += 26
	local reset = SG.button("Reset to defaults", "ghost", { Position = UDim2.fromOffset(14, y), Size = UDim2.new(1, -28, 0, bh), ZIndex = 21 }, panel)
	reset.Activated:Connect(function()
		local changed = false
		for k, v in pairs((Config.Social and Config.Social.SettingsDefault) or {}) do
			if settings[k] ~= v then settings[k] = v; changed = true end
		end
		if changed then settingsChanged() end
	end)
	y += bh
	finishPanel(panel, y + 12)
end

function refreshSettings()
	if not (refs.sliders and settings) then return end
	for key, s in pairs(refs.sliders) do
		local v = math.clamp(tonumber(settings[key]) or 0, 0, 100)
		setText(s.val, tostring(v))
		s.fill.Size = UDim2.fromScale(v / 100, 1)
		s.thumb.Position = UDim2.new(v / 100, 0, 0.5, 0)
	end
	for key, b in pairs(refs.toggles) do
		local on = settings[key] == true
		setText(b, on and "ON" or "OFF")
		SG.setRole(b, on and "primary" or "ghost")
	end
	local tier = (Quality and tonumber(Quality.Tier)) or (IS_TOUCH and 1 or 2)
	setText(refs.deviceLine, "Device: " .. (IS_TOUCH and "Touch" or "Desktop") .. " · Quality tier " .. tostring(tier))
end

-- first GetState: snap.settings (already merged over the defaults by the server) seeds the
-- panel once; init.client applies it through UI.OnSettingsChanged, so nothing fires here
local function seedSettings(s)
	if settingsSeeded or settingsTouched or type(s) ~= "table" or settings == nil then return end
	settingsSeeded = true
	for k, def in pairs(settings) do
		local v = s[k]
		if v ~= nil and type(v) == type(def) then settings[k] = v end
	end
	refreshSettings()
end

-- ===== HUD =====
local lastShownGems = nil

-- rail states that depend on the snapshot (UI-3): runs on EVERY push even while the
-- panels themselves are dirty-flagged closed — glows and count badges must never lag.
local function refreshRail()
	if not snap then return end
	if refs.harvestBtn then
		local overgrown = snap.gardenOvergrown == true
		local gv = tonumber(snap.gardenValue) or 0
		SG.badge(refs.harvestBtn, overgrown and "FULL!" or Config.Fmt(gv))
		SG.setEnabled(refs.harvestBtn, gv > 0)
		SG.setGlow(refs.harvestBtn, overgrown)
	end
	if refs.upgradesBtn then
		local gems = snap.gems or 0
		SG.setGlow(refs.upgradesBtn, gems >= (snap.powerCost or math.huge) or gems >= (snap.luckCost or math.huge))
	end
	if refs.shopBtn then SG.setGlow(refs.shopBtn, snap.starterOffered == true) end
	local d = snap.daily
	if refs.dailyBtn and type(d) == "table" then
		local claimable = d.claimable == true
		SG.setGlow(refs.dailyBtn, claimable)
		SG.badge(refs.dailyBtn, claimable and "1" or "")
	end
	local list = snap.achievements
	if refs.achBtn and type(list) == "table" then
		local n = 0
		for _, a in ipairs(list) do
			if a.claimable then n += 1 end
		end
		SG.setGlow(refs.achBtn, n > 0)
		SG.badge(refs.achBtn, n > 0 and tostring(n) or "")
	end
	-- Pets: something fusable (3 of a kind) or a stronger unlocked pet is not the equipped one
	local pt, cp = snap.pets, snap.collectPets
	if refs.petsBtn then
		local glow = false
		if type(cp) == "table" and type(cp.pets) == "table" then
			for _, cpp in ipairs(cp.pets) do
				local c = cpp.counts or {}
				if (c[1] or 0) >= 3 or (c[2] or 0) >= 3 then glow = true end
			end
		end
		if type(pt) == "table" and type(pt.best) == "number" and type(pt.equipped) == "number" and pt.best > 0 and pt.best ~= pt.equipped then
			glow = true
		end
		SG.setGlow(refs.petsBtn, glow)
	end
	refreshPlayersBadge()
end

local function buildHUD()
	local cardW, cardH = (IS_TOUCH and 300 or 240), (IS_TOUCH and 112 or 100)
	refs.cardW = cardW

	-- scrim: below panels (20), Active only while one is open; tap = close
	refs.scrim = mk("TextButton", {
		Name = "Scrim", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color.Scrim, BackgroundTransparency = 0.45,
		BorderSizePixel = 0, Text = "", AutoButtonColor = false, Visible = false, Active = false, ZIndex = 19,
	}, gui)
	refs.scrim.Activated:Connect(function() UI.TogglePanel(nil) end)

	-- toast lane: bottom-centre, above the CRACK button (touch) / hotbar (desktop)
	local th = IS_TOUCH and SG.Size.ToastHTouch or SG.Size.ToastH
	refs.toastLane = mk("Frame", {
		Name = "ToastLane", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -(IS_TOUCH and 140 or 90)),
		Size = UDim2.new(1, 0, 0, 3 * (th + 6)), BackgroundTransparency = 1, ZIndex = 30,
	}, gui)
	mk("UIListLayout", {
		Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Bottom,
	}, refs.toastLane)

	-- left stack: HUD card, NEXT GOAL card and buff chips flow top-to-bottom
	local leftStack = mk("Frame", {
		Name = "LeftStack", Position = UDim2.fromOffset(12, 12), Size = UDim2.fromOffset(cardW, 0),
		AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1,
	}, gui)
	mk("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Left }, leftStack)
	refs.leftStack = leftStack
	local card = mk("Frame", {
		Name = "GemCard", LayoutOrder = 1, Size = UDim2.fromOffset(cardW, cardH), BackgroundColor3 = BG, BackgroundTransparency = 0.15, BorderSizePixel = 0,
	}, leftStack)
	corner(card, "md")
	stroke(card)
	SG.icon("gem", { Name = "GemIcon", Position = UDim2.fromOffset(10, 8), Size = UDim2.fromOffset(36, 36), ZIndex = 2 }, card)
	local LEFT = Enum.TextXAlignment.Left
	refs.gems = text("Number", { Position = UDim2.fromOffset(52, 6), Size = UDim2.new(1, -112, 0, 40), Text = "0", TextXAlignment = LEFT, fit = true }, card)
	local gc = refs.gems:FindFirstChildOfClass("UITextSizeConstraint")
	if gc then gc.MaxTextSize = 34 end
	mk("UIScale", { Name = "Pulse" }, refs.gems)
	refs.rate = text("Caption", { Position = UDim2.fromOffset(12, 46), Size = UDim2.new(1, -24, 0, 16), Text = "", TextColor3 = MUTED, TextXAlignment = LEFT }, card)
	refs.luckLine = text("Caption", { Position = UDim2.fromOffset(12, 63), Size = UDim2.new(1, -24, 0, 16), Text = "", TextColor3 = MUTED, TextXAlignment = LEFT }, card)
	refs.zoneLine = text("Caption", { Position = UDim2.fromOffset(12, 80), Size = UDim2.new(1, -24, 0, 16), Text = "", TextColor3 = MUTED, TextXAlignment = LEFT }, card)
	-- "+" shortcut to the Shop: a 36 px buy pill inside a 48 px hit wrapper (pure navigation)
	local plusHit = hitArea(card, function() UI.ShowPanel("Shop") end,
		{ Name = "PlusHit", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -4, 0, 2), Size = UDim2.fromOffset(48, 48), ZIndex = 3 })
	local plus = mk("Frame", { Name = "Plus", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(36, 36),
		BackgroundColor3 = SG.lighten(GOOD, 0.12), BorderSizePixel = 0, ZIndex = 4 }, plusHit)
	corner(plus, "pill")
	stroke(plus, SG.Button.buy.stroke, "base", 0.05)
	text("Display", { Size = UDim2.fromScale(1, 1), Text = "+", TextColor3 = Color.TextInk, TextStrokeTransparency = 1, ZIndex = 5, fit = true }, plus)

	-- objective tracker card (onboarding -> daily reward -> quest -> rebirth -> award -> pet); tap opens the panel
	local goal = mk("Frame", { Name = "GoalCard", LayoutOrder = 2, Size = UDim2.fromOffset(cardW, 58), BackgroundColor3 = BG, BackgroundTransparency = 0.1,
		BorderSizePixel = 0, Visible = false, ZIndex = 8 }, leftStack)
	corner(goal, "md")
	stroke(goal, GOOD, "base", 0.2)
	refs.goalHead = text("Caption", { Position = UDim2.fromOffset(14, 5), Size = UDim2.new(1, -28, 0, 15), Text = "🎯 NEXT GOAL", TextColor3 = GOOD, TextXAlignment = LEFT, ZIndex = 9 }, goal)
	hitArea(goal, function()
		if refs.trackerPanel and panels[refs.trackerPanel] then UI.TogglePanel(refs.trackerPanel) end
	end)
	refs.goalText = text("Heading", { Position = UDim2.fromOffset(14, 21), Size = UDim2.new(1, -28, 0, 22), Text = "", TextXAlignment = LEFT, ZIndex = 9, fit = true }, goal)
	local gbarBG = mk("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 14, 1, -6), Size = UDim2.new(1, -28, 0, 5),
		BackgroundColor3 = Color.Track, BorderSizePixel = 0, Visible = false, ZIndex = 9 }, goal)
	corner(gbarBG, "pill")
	refs.goalFill = mk("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = GOOD, BorderSizePixel = 0, ZIndex = 10 }, gbarBG)
	corner(refs.goalFill, "pill")
	refs.goalBar = gbarBG
	refs.goalCard = goal

	-- buff chips (sized to the card)
	local chips = mk("Frame", {
		Name = "Chips", LayoutOrder = 3, Size = UDim2.fromOffset(cardW, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1,
	}, leftStack)
	mk("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, chips)
	refs.chips = chips
	local chipOrder = 0
	local function chip(name, color)
		chipOrder += 1
		local c = text("Body", { Size = UDim2.fromOffset(cardW, 24), Text = "", TextColor3 = color, BackgroundColor3 = BG, BackgroundTransparency = 0.25,
			Visible = false, TextXAlignment = LEFT, LayoutOrder = chipOrder }, chips)
		corner(c, "sm")
		mk("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, c)
		refs[name] = c
	end
	chip("chipBoost", Color.GoldSoft)
	chip("chipStreak", WARN)
	chip("chipServer", GOOD)
	chip("chipGolden", GOLD)
	chip("chipNext", INFO)
	chip("shardChip", Color.Cyan)
	-- server goal chip: icon + label, "progress / goal · you: N · countdown", 4 px bar;
	-- pulses on completion; tap -> toast with the reward text (UI.ServerGoal feeds it)
	local goalChip = mk("Frame", { Name = "GoalChip", Size = UDim2.fromOffset(cardW, IS_TOUCH and 46 or 42), BackgroundColor3 = BG, BackgroundTransparency = 0.2,
		BorderSizePixel = 0, Visible = false, LayoutOrder = 9 }, chips)
	corner(goalChip, "sm")
	stroke(goalChip, GOOD, "hair", 0.4)
	mk("UIScale", { Name = "Pulse" }, goalChip)
	refs.sgHead = text("Caption", { Position = UDim2.fromOffset(8, 3), Size = UDim2.new(1, -16, 0, 16), Text = "", TextColor3 = GOOD, TextXAlignment = LEFT, ZIndex = 2 }, goalChip)
	refs.sgSub = text("Caption", { Position = UDim2.fromOffset(8, 20), Size = UDim2.new(1, -16, 0, 14), Text = "", TextColor3 = MUTED, TextXAlignment = LEFT, ZIndex = 2 }, goalChip)
	local sgTrack = mk("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 8, 1, -4), Size = UDim2.new(1, -16, 0, 4), BackgroundColor3 = Color.Track, BorderSizePixel = 0, ZIndex = 2 }, goalChip)
	corner(sgTrack, "pill")
	refs.sgFill = mk("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = GOOD, BorderSizePixel = 0, ZIndex = 3 }, sgTrack)
	corner(refs.sgFill, "pill")
	hitArea(goalChip, function()
		local g = UI._serverGoal
		if type(g) == "table" then
			UI.Toast("🎯 Server goal reward: " .. tostring(g.rewardText or "Server Luck for everyone") .. " — everyone online wins!", "ok")
		end
	end)
	refs.goalChip = goalChip

	-- rail: 3×3 grid top-right on touch (clear of the jump button), one column on desktop
	local cols = IS_TOUCH and 3 or 1
	local btnW = IS_TOUCH and 62 or 74
	local bH = IS_TOUCH and 56 or 64
	local pad = IS_TOUCH and 5 or 7
	local col = mk("Frame", {
		Name = "SideMenu", AnchorPoint = IS_TOUCH and Vector2.new(1, 0) or Vector2.new(1, 0.5),
		Position = IS_TOUCH and UDim2.new(1, -10, 0, 8) or UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.fromOffset(btnW, bH), BackgroundTransparency = 1,
	}, gui)
	refs.sideMenu = col
	refs.sideMenuDims = { btnW = btnW, btnH = bH, pad = pad, count = 0, cols = cols }
	refs.sideMenuScale = mk("UIScale", { Name = "Fit" }, col)
	mk("UIGridLayout", {
		CellSize = UDim2.fromOffset(btnW, bH), CellPadding = UDim2.fromOffset(pad, pad),
		SortOrder = Enum.SortOrder.LayoutOrder, FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		VerticalAlignment = IS_TOUCH and Enum.VerticalAlignment.Top or Enum.VerticalAlignment.Center,
	}, col)
	local sideOrder = 0
	local function sideBtn(iconKey, label, cb)
		sideOrder += 1
		local item = mk("Frame", { Name = label, LayoutOrder = sideOrder, Size = UDim2.fromOffset(btnW, bH), BackgroundTransparency = 1 }, col)
		local shadow = mk("Frame", {
			Name = "Shadow", BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.55,
			Position = UDim2.fromOffset(2, 4), Size = UDim2.fromScale(1, 1), BorderSizePixel = 0,
		}, item)
		corner(shadow, "md")
		local b = mk("TextButton", {
			Name = "Btn", Size = UDim2.fromScale(1, 1), Text = "", BackgroundColor3 = SG.lighten(ACCENT, 0.12),
			AutoButtonColor = false, BorderSizePixel = 0, ZIndex = 2,
		}, item)
		corner(b, "md")
		SG.stroke(b, Color.Cyan, "bold", 0.08)
		SG.shade(b)
		SG.gloss(b, "sm")
		SG.icon(iconKey, {
			Name = "Icon", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 3),
			Size = UDim2.fromOffset(bH - 22, bH - 22), ZIndex = 4,
		}, b)
		text("Caption", {
			Name = "Label", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -2), Size = UDim2.new(1, -4, 0, 14),
			Text = label, Font = SG.Font.Display, TextStrokeTransparency = 0.4, ZIndex = 4, fit = true,
		}, b)
		SG.pressFX(b)
		if cb then b.Activated:Connect(cb) end
		return b
	end
	refs.dailyBtn = sideBtn("gift", "Daily", function() UI.TogglePanel("Daily") end)
	refs.petsBtn = sideBtn("paw", "Pets", function() UI.TogglePanel("Pets") end)
	refs.shopBtn = sideBtn("shop", "Shop", function() UI.TogglePanel("Shop") end)
	refs.upgradesBtn = sideBtn("pickaxe", "Upgrades", function() UI.TogglePanel("Upgrades") end)
	refs.indexBtn = sideBtn("index", "Index", function() UI.TogglePanel("Index") end)
	refs.achBtn = sideBtn("trophy", "Awards", function() UI.TogglePanel("Achievements") end)
	refs.harvestBtn = sideBtn("sprout", "Garden", nil)
	refs.playersBtn = sideBtn("players", "Players", function()
		unreadFeed = 0
		refreshPlayersBadge()
		UI.TogglePanel("Players")
	end)
	refs.settingsBtn = sideBtn("gear", "Settings", function() UI.TogglePanel("Settings") end)
	refs.sideMenuDims.count = sideOrder
	SG.badge(refs.harvestBtn, "0")
	SG.setEnabled(refs.harvestBtn, false) -- until a snapshot says there is something to harvest
	UI._bindInvoke(refs.harvestBtn, function()
		local res = UI._invoke(remote("HarvestGarden"))
		-- success feedback is the server's personal "🌱 Garden harvest: +N!" Tell: one pill per action
		if not res.ok and res.err and res.err ~= "Slow down!" then
			UI.Toast(res.err, "err")
		end
	end, refreshRail)

	-- Big thumb-reachable CRACK button (touch only): hold to crack the nearest geode
	if IS_TOUCH then
		local crackWrap = mk("Frame", {
			Name = "CrackWrap", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 78, 1, -14),
			Size = UDim2.fromOffset(118, 118), BackgroundTransparency = 1, ZIndex = 5,
		}, gui)
		local crackShadow = mk("Frame", {
			Name = "Shadow", BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.5,
			Position = UDim2.fromOffset(3, 6), Size = UDim2.fromScale(1, 1), BorderSizePixel = 0, ZIndex = 5,
		}, crackWrap)
		corner(crackShadow, "pill")
		local crackBtn = mk("TextButton", {
			Name = "CrackBtn", Size = UDim2.fromScale(1, 1), Text = "",
			BackgroundColor3 = SG.lighten(ACCENT, 0.15), AutoButtonColor = false, BorderSizePixel = 0, ZIndex = 6,
		}, crackWrap)
		corner(crackBtn, "pill")
		SG.stroke(crackBtn, Color.Cyan, "chunk", 0.05)
		SG.shade(crackBtn)
		local crackGloss = mk("Frame", {
			Name = "Gloss", BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 8), Size = UDim2.new(0.66, 0, 0.3, 0), ZIndex = 7,
		}, crackBtn)
		corner(crackGloss, "pill")
		mk("UIGradient", { Rotation = 90, Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 1) }) }, crackGloss)
		SG.icon("geodeClosed", {
			Name = "Icon", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 12), Size = UDim2.fromOffset(56, 56), ZIndex = 8,
		}, crackBtn)
		text("Display", {
			Name = "Label", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -22), Size = UDim2.new(1, -16, 0, 22),
			Text = "CRACK", TextStrokeTransparency = 0.3, ZIndex = 8, fit = true,
		}, crackBtn)
		-- cooldown bar (4 px) refills over the cooldown; the stroke turns Gold + pulses when ready
		local cdTrack = mk("Frame", {
			Name = "Cooldown", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -13), Size = UDim2.new(0.46, 0, 0, 4),
			BackgroundColor3 = Color.Track, BorderSizePixel = 0, ZIndex = 8,
		}, crackBtn)
		corner(cdTrack, "pill")
		refs.crackFill = mk("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = GOLD, BorderSizePixel = 0, ZIndex = 9 }, cdTrack)
		corner(refs.crackFill, "pill")
		SG.pressFX(crackBtn)
		refs.crackBtn = crackBtn
		refs.crackStroke = crackBtn:FindFirstChildOfClass("UIStroke")
		-- cooldown-gated: a press fires only when the mirror says ready (own CrackFX sets the real
		-- cooldown; a press arms a 0.25 s provisional lock AFTER the swing hook — see PickaxeFX)
		local function tryCrack()
			if os.clock() < crackReadyAt then return end
			if UI.OnCrackInput then UI.OnCrackInput() end
			crackReadyAt = os.clock() + 0.25
			Remotes.CrackRequest:FireServer()
		end
		local held = false
		crackBtn.MouseButton1Down:Connect(function()
			if held then return end
			held = true
			tryCrack()
			task.spawn(function() -- hold loop: spawned on press, exits on release / leave
				while held and crackBtn.Parent do
					task.wait(0.06)
					if held and crackBtn.Parent then tryCrack() end
				end
			end)
		end)
		crackBtn.MouseButton1Up:Connect(function() held = false end)
		crackBtn.MouseLeave:Connect(function() held = false end)
	end

	-- headline banner stack (centre band; ≤3, clipped)
	local banners = mk("Frame", {
		Name = "Banners", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 8), Size = UDim2.new(0.9, 0, 0, 120),
		BackgroundTransparency = 1, ClipsDescendants = true, ZIndex = 12,
	}, gui)
	mk("UISizeConstraint", { MinSize = Vector2.new(240, 0), MaxSize = Vector2.new(600, 120) }, banners)
	mk("UIListLayout", { Padding = UDim.new(0, 4), HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, banners)
	refs.banners = banners

	-- meteor bar (centre band): one text row + HP bar; on desktop up to three share
	-- mini-bars grow the frame while the meteor is active (touch stays a single 44 px row)
	local mh = metBase()
	local meteor = mk("Frame", {
		Name = "MeteorBar", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 132), Size = UDim2.fromOffset(420, mh),
		BackgroundColor3 = BG, BackgroundTransparency = 0.15, BorderSizePixel = 0, Visible = false, ZIndex = 12,
	}, gui)
	corner(meteor, "sm")
	stroke(meteor, WARN)
	refs.meteorFrame = meteor
	refs.meteorText = text("Heading", { Size = UDim2.new(1, -12, 0, mh - 12), Position = UDim2.fromOffset(6, 0), Text = "", TextColor3 = WARN, ZIndex = 13, fit = true }, meteor)
	local mbarBG = mk("Frame", {
		AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, mh - 11), Size = UDim2.new(0.94, 0, 0, 6),
		BackgroundColor3 = Color.Track, BorderSizePixel = 0, ZIndex = 13,
	}, meteor)
	corner(mbarBG, "pill")
	refs.meteorFill = mk("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = WARN, BorderSizePixel = 0, ZIndex = 14 }, mbarBG)
	corner(refs.meteorFill, "pill")
	refs.shareRows = {}
	for i = 1, 3 do
		local sr = mk("Frame", { Position = UDim2.new(0.03, 0, 0, mh + 2 + (i - 1) * 14), Size = UDim2.new(0.94, 0, 0, 12), BackgroundTransparency = 1, Visible = false, ZIndex = 13 }, meteor)
		local lbl = text("Caption", { Size = UDim2.new(0.5, 0, 1, 0), Text = "", TextColor3 = TEXT, TextXAlignment = LEFT, ZIndex = 14 }, sr)
		local tr = mk("Frame", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.new(0.48, 0, 0, 4), BackgroundColor3 = Color.Track, BorderSizePixel = 0, ZIndex = 14 }, sr)
		corner(tr, "pill")
		local fl = mk("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = Color.GoldSoft, BorderSizePixel = 0, ZIndex = 15 }, tr)
		corner(fl, "pill")
		refs.shareRows[i] = { frame = sr, label = lbl, fill = fl }
	end
end

-- ----- HUD dynamics (UI-6): card lines, tracker, chips tick, server goal, meteor -----

function UI._refreshHudCard()
	if not (snap and refs.rate) then return end
	setText(refs.rate, "≈" .. Config.Fmt(snap.rate or 0) .. " 💎/s · ×" .. fmtMult(snap.mult) .. " income")
	setText(refs.luckLine, string.format("Luck ×%.2f · Crack every %.1f s", snap.luckFactor or 1, snap.cooldown or 0))
	local z = Config.Zones and Config.Zones.Get and Config.Zones.Get(ownZoneKey())
	local zoneStr = z and (" · " .. z.icon .. " " .. z.name .. " ×" .. tostring(z.multiplier)) or ""
	setText(refs.zoneLine, "Rebirth " .. tostring(snap.rebirths or 0) .. zoneStr)
end

-- objective tracker priority chain (§0): onboarding step -> claimable daily reward ->
-- closest-to-complete quest -> rebirth >= 50 % -> claimable / next award tier -> next pet
local function computeTracker()
	if not snap then return nil end
	local ob = snap.onboard
	if type(ob) == "table" then
		return { head = "🎯 NEXT GOAL", text = tostring(ob.text or ""), progress = ob.progress, target = ob.target,
			panel = ((tonumber(ob.index) or 0) >= 3) and "Upgrades" or nil }
	end
	local d = snap.daily
	if type(d) == "table" then
		if d.claimable then
			return { head = "🎁 DAILY REWARD", text = "Day " .. tostring(d.streakDay or 1) .. " reward is ready — tap to claim", panel = "Daily" }
		end
		local best, bestF = nil, -1
		for _, q in ipairs(d.quests or {}) do
			if not q.done then
				local f = (tonumber(q.progress) or 0) / math.max(1, tonumber(q.goal) or 1)
				if f > bestF then best, bestF = q, f end
			end
		end
		if best then
			return { head = "📋 DAILY QUEST", text = tostring(best.desc or ""), progress = best.progress, target = best.goal, panel = "Daily" }
		end
	end
	local cost, gems = tonumber(snap.rebirthCost) or 0, tonumber(snap.gems) or 0
	if cost > 0 and gems / cost >= 0.5 then
		return { head = "🔄 REBIRTH", text = "Rebirth " .. tostring((snap.rebirths or 0) + 1) .. " · ×" .. tostring(Config.Balance.RebirthMultBase) .. " income",
			progress = math.min(gems, cost), target = cost, panel = "Upgrades" }
	end
	local list = snap.achievements
	if type(list) == "table" then
		local best, bestF = nil, -1
		for _, a in ipairs(list) do
			if a.claimable then
				return { head = "🏅 AWARD READY", text = tostring(a.icon or "🏅") .. " " .. tostring(a.name or "") .. " — tap to claim", panel = "Achievements" }
			end
			for _, t in ipairs(a.tiers or {}) do
				if not t.done then
					local f = (tonumber(a.cur) or 0) / math.max(1, tonumber(t.goal) or 1)
					if f > bestF then best, bestF = { a = a, t = t }, f end
					break
				end
			end
		end
		if best then
			return { head = "🏅 NEXT AWARD", text = tostring(best.a.icon or "🏅") .. " " .. tostring(best.a.name or "") .. " · +" .. Config.Cur(best.t.gems or 0),
				progress = best.a.cur, target = best.t.goal, panel = "Achievements" }
		end
	end
	local pt = snap.pets
	if type(pt) == "table" and pt.nextName then
		local life = tonumber(pt.lifetimeRebirths) or tonumber(snap.rebirths) or 0
		return { head = "🐾 NEXT PET", text = tostring(pt.nextName) .. " at Rebirth " .. tostring(pt.nextReq), progress = life, target = pt.nextReq, panel = "Pets" }
	end
	return nil
end

local function refreshTracker()
	if not refs.goalCard then return end
	local tr = computeTracker()
	refs.goalWanted = tr ~= nil
	refs.trackerPanel = tr and tr.panel or nil
	if tr then
		setText(refs.goalHead, tr.head)
		local prog, target = tonumber(tr.progress), tonumber(tr.target)
		if prog and target then
			setText(refs.goalText, tr.text .. "  (" .. Config.Fmt(prog) .. "/" .. Config.Fmt(target) .. ")")
			refs.goalBar.Visible = true
			refs.goalFill.Size = UDim2.fromScale(math.clamp(prog / math.max(1, target), 0, 1), 1)
		else
			setText(refs.goalText, tr.text)
			refs.goalBar.Visible = false
		end
	end
	refs.goalCard.Visible = refs.goalWanted and not UI._anyOpen
end

-- server goal chip text; hides once a finished goal's rest is over and nothing new arrived
local function tickServerGoal(now)
	local gc, g = refs.goalChip, UI._serverGoal
	if not gc then return end
	if type(g) ~= "table" then
		if gc.Visible then gc.Visible = false end
		return
	end
	local goal = math.max(1, tonumber(g.goal) or 1)
	local prog = tonumber(g.progress) or 0
	local mine = (snap and tonumber(snap.serverGoalMine)) or tonumber(g.mine) or 0
	local nextAt = tonumber(g.nextAt) or 0
	local head, sub
	if g.active then
		head = tostring(g.icon or "🎯") .. " " .. tostring(g.label or "Server goal")
		local ends = tonumber(g.endsAt)
		sub = Config.Fmt(prog) .. " / " .. Config.Fmt(goal) .. " · you: " .. Config.Fmt(mine) .. (ends and (" · " .. fmtSecs(ends - now)) or "")
	elseif nextAt > 0 and now > nextAt + 5 then
		if gc.Visible then gc.Visible = false end -- stale: the next goal never arrived (old server / left rest)
		return
	elseif g.missed then
		head = "⏳ Server goal missed"
		sub = nextAt > 0 and ("New goal in " .. fmtSecs(nextAt - now)) or "New goal soon"
	else
		head = "✅ SERVER GOAL COMPLETE!"
		sub = tostring(g.rewardText or "Server Luck for everyone") .. (nextAt > 0 and (" · next in " .. fmtSecs(nextAt - now)) or "")
	end
	setText(refs.sgHead, head)
	setText(refs.sgSub, sub)
	local f = g.active and math.clamp(prog / goal, 0, 1) or 1
	if refs.sgFill.Size.X.Scale ~= f then refs.sgFill.Size = UDim2.fromScale(f, 1) end
	if not gc.Visible then gc.Visible = true end
end

local function setChip(name, active, str)
	local c = refs[name]
	if not c then return end
	if c.Visible ~= active then c.Visible = active end
	if active and c.Text ~= str then c.Text = str end
end

-- 4 Hz: every countdown on server time; writes only on text change
local function tickChips()
	local now = serverNow()
	if snap then
		local boostUntil = tonumber(snap.boostUntil) or 0
		setChip("chipBoost", boostUntil > now, "⚡ Lucky Boost " .. fmtSecs(boostUntil - now))
		local streakUntil = tonumber(snap.streakLuckUntil) or 0
		setChip("chipStreak", streakUntil > now, "🔥 Streak ×2 Luck " .. fmtSecs(streakUntil - now))
		local serverPct = tonumber(snap.serverLuckPct) or 0
		local serverUntil = tonumber(snap.serverLuckUntil) or 0
		local serverOn = serverPct > 0 and (serverUntil == 0 or serverUntil > now)
		setChip("chipServer", serverOn, "🎁 Server Luck +" .. math.floor(serverPct * 100 + 0.5) .. "%"
			.. (serverUntil > 0 and (" · " .. fmtSecs(serverUntil - now)) or ""))
		local goldenUntil = tonumber(snap.goldenUntil) or 0
		local goldenOn = snap.goldenHour == true or goldenUntil > now
		setChip("chipGolden", goldenOn, goldenUntil > now and ("🌟 GOLDEN HOUR " .. fmtSecs(goldenUntil - now)) or "🌟 GOLDEN HOUR +50% Luck!")
		-- next event: the sooner of Meteor / Golden Hour, only inside 5 min (0 = unknown / live)
		local nm, ng = tonumber(snap.nextMeteorAt) or 0, tonumber(snap.nextGoldenAt) or 0
		local nextAt, label = 0, ""
		if nm > now then nextAt, label = nm, "☄️ Meteor in " end
		if ng > now and (nextAt == 0 or ng < nextAt) then nextAt, label = ng, "🌤️ Golden Hour in " end
		setChip("chipNext", nextAt > 0 and nextAt - now < 300, label .. fmtSecs(nextAt - now))
	end
	tickServerGoal(now)
	-- meteor phases with a live clock
	local f = refs.meteorFrame
	if f and f.Visible then
		if refs.meteorPhase == "warning" and refs.meteorWarnEnd then
			setText(refs.meteorText, "☄️ METEOR in " .. fmtSecs(refs.meteorWarnEnd - os.clock()) .. " — get to the crater!")
		elseif refs.meteorPhase == "dead" and refs.meteorNextAt then
			setText(refs.meteorText, "☄️ Meteor sank — next in " .. fmtSecs(refs.meteorNextAt - now))
		end
	end
end

local function setMeteorHeight(h)
	local f = refs.meteorFrame
	if not f then return end
	refs.meteorH = h
	if f.Size.Y.Offset ~= h then f.Size = UDim2.fromOffset(f.Size.X.Offset, h) end
end

-- 4 s results card after the boom: top-5 shares (own row gold) + Cheer on the MVP
local function showMeteorResults(data)
	local results = type(data.results) == "table" and data.results or {}
	local vp = (gui and gui.AbsoluteSize.X > 1) and gui.AbsoluteSize or viewport()
	local rows = math.min(5, #results)
	local mvp = tonumber(data.mvpUserId)
	local mvpPlayer = mvp and mvp ~= player.UserId and Players:GetPlayerByUserId(mvp) or nil
	local withBtn = mvpPlayer ~= nil and UI.OnCheer ~= nil
	local bh = btnH()
	local function cardH(n) return 50 + math.max(1, n) * 24 + (withBtn and (bh + 16) or 12) end
	-- phones: at most 3 rows, fewer if the card (top ≥ 8) would still reach the CRACK button
	-- (CrackWrap starts at H-132) — the Cheer button must never sit over CRACK at ZIndex 28
	local bottomLimit = vp.Y - (IS_TOUCH and 150 or 100)
	if IS_TOUCH then
		rows = math.min(rows, 3)
		while rows > 1 and 8 + cardH(rows) > bottomLimit + 10 do rows -= 1 end
	end
	local h = cardH(rows)
	local top = math.max(8, math.min(vp.Y * 0.36 - h / 2, bottomLimit - h))
	local card = mk("Frame", { Name = "MeteorResults", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, top),
		Size = UDim2.fromOffset(math.min(380, vp.X - 32), h), BackgroundColor3 = BG, BackgroundTransparency = 0.06, BorderSizePixel = 0, ZIndex = 28 }, gui)
	corner(card, "md")
	stroke(card, Color.GoldSoft, "base", 0.1)
	text("Display", { Position = UDim2.fromOffset(0, 10), Size = UDim2.new(1, 0, 0, 30), Text = "💥 METEOR CRACKED!", TextColor3 = Color.GoldSoft, ZIndex = 29, fit = true }, card)
	if rows == 0 then
		text("Body", { Position = UDim2.fromOffset(16, 48), Size = UDim2.new(1, -32, 0, 22), Text = "Nobody tapped it in time!", TextColor3 = MUTED, ZIndex = 29 }, card)
	end
	for i = 1, rows do
		local e = results[i]
		local me = tonumber(e.userId) == player.UserId
		text("Body", { Position = UDim2.fromOffset(16, 48 + (i - 1) * 24), Size = UDim2.new(1, -32, 0, 22), TextColor3 = me and GOLD or TEXT, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 29,
			Text = tostring(i) .. ". " .. tostring(e.name or "Miner") .. (me and " (You)" or "") .. " — " .. tostring(tonumber(e.pct) or 0) .. "% · +" .. Config.Cur(e.gained or 0) }, card)
	end
	if withBtn then
		local b = SG.button("👏 Cheer " .. mvpPlayer.DisplayName, "primary", { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -8), Size = UDim2.new(1, -32, 0, bh), ZIndex = 29 }, card)
		b.Activated:Connect(function()
			if UI.OnCheer then UI.OnCheer(mvp, 1) end
			if card.Parent then fadeOut(card, 0.2) end
		end)
	end
	task.delay(4, function() if card.Parent then fadeOut(card, 0.4) end end)
end

-- ===== public API =====
function UI.Update(newSnap)
	if type(newSnap) ~= "table" then return end
	snap = newSnap
	updateSeq += 1
	if type(snap.now) == "number" then clockOffset = snap.now - os.time() end
	local balance = "You have " .. Config.Cur(snap.gems or 0)
	if balance ~= refs.lastBalance then
		refs.lastBalance = balance
		for _, l in ipairs(balanceLabels) do l.Text = balance end
	end
	-- panels refresh only while visible (a closed panel is flagged and refreshed on open);
	-- rail glows / badges and the HUD card run on every push
	for name, fn in pairs(panelRefresh) do
		local p = panels[name]
		if p and p.Visible then fn() else panelDirty[name] = true end
	end
	UI._refreshHudCard()
	refreshRail()
	refreshTracker()
	seedSettings(snap.settings) -- GetState-only field; no-op on the per-crack push

	-- Grotto shard counter (Sunken explorer gate)
	local sc = (type(snap.zoneShards) == "table" and tonumber(snap.zoneShards.Sunken)) or 0
	setChip("shardChip", sc > 0 and sc < 5, "🔹 Grotto Shards " .. sc .. "/5")
	tickChips()
	if afterUpdate then
		local f = afterUpdate
		afterUpdate = nil
		pcall(f)
	end
end

function UI.OnCrack(data)
	if type(data) ~= "table" or data.userId ~= player.UserId then return end
	crackReadyAt = os.clock() + ((snap and tonumber(snap.cooldown)) or 0)
	local pulse = refs.gems and refs.gems:FindFirstChild("Pulse")
	if pulse then
		pulse.Scale = 1.15
		TweenService:Create(pulse, SG.Motion.pop, { Scale = 1 }):Play()
	end
	-- 2× Gems: one informative line on the Shop card per session, never a toast nag
	if snap and data.rarity and data.rarity >= Config.LuckyTierIndex and data.gained
		and snap.passes and not snap.passes.DoubleGems and refs.doubleGemsNote and not UI._upsellShown then
		UI._upsellShown = true
		refs.doubleGemsNote.Text = "💡 2× Gems would've made your last rare find +" .. Config.Cur(data.gained) .. "!"
		refs.doubleGemsNote.Visible = true
	end
end

-- MeteorState: warning {t} · impact · active {hp, maxHp, helpers, shares} (≤ 4 Hz) ·
-- boom {results, mvpUserId} · dead {nextAt}. Share keys are STRING userIds.
function UI.Meteor(data)
	local f = refs.meteorFrame
	if not (f and type(data) == "table") then return end
	local phase = data.phase
	refs.meteorPhase = phase
	local function hideShares()
		for _, sr in ipairs(refs.shareRows or {}) do sr.frame.Visible = false end
		setMeteorHeight(metBase())
	end
	if phase == "warning" then
		f.Visible = true
		hideShares()
		refs.meteorWarnEnd = os.clock() + (tonumber(data.t) or 30)
		setText(refs.meteorText, "☄️ METEOR in " .. fmtSecs(tonumber(data.t) or 30) .. " — get to the crater!")
		refs.meteorFill.Size = UDim2.fromScale(1, 1)
	elseif phase == "impact" then
		f.Visible = true
		hideShares()
		setText(refs.meteorText, "☄️ CRACK THE METEOR GEODE!")
	elseif phase == "active" then
		f.Visible = true
		local hp, maxHp = tonumber(data.hp) or 0, math.max(1, tonumber(data.maxHp) or 1)
		local helpers = tonumber(data.helpers) or 0
		local shares = type(data.shares) == "table" and data.shares or {}
		local mine = tonumber(shares[tostring(player.UserId)]) or 0
		setText(refs.meteorText, "☄️ METEOR " .. Config.Fmt(hp) .. " / " .. Config.Fmt(maxHp) .. " · " .. tostring(helpers)
			.. (helpers == 1 and " helper" or " helpers") .. " · You: " .. tostring(mine) .. "%")
		refs.meteorFill.Size = UDim2.fromScale(math.clamp(hp / maxHp, 0, 1), 1)
		if IS_TOUCH then
			hideShares() -- a single 44 px row on phones
		else
			local list = {}
			for k, pct in pairs(shares) do list[#list + 1] = { uid = tonumber(k), pct = tonumber(pct) or 0 } end
			table.sort(list, function(a, b) return a.pct > b.pct end)
			local n = math.min(3, #list)
			for i = 1, 3 do
				local sr, e = refs.shareRows[i], list[i]
				if e and i <= n then
					local pl = e.uid and Players:GetPlayerByUserId(e.uid)
					setText(sr.label, (pl and pl.DisplayName or "Miner") .. (e.uid == player.UserId and " (You)" or "") .. " · " .. tostring(e.pct) .. "%")
					sr.fill.Size = UDim2.fromScale(math.clamp(e.pct / 100, 0, 1), 1)
					sr.frame.Visible = true
				else
					sr.frame.Visible = false
				end
			end
			setMeteorHeight(metBase() + (n > 0 and (4 + n * 14) or 0))
		end
	elseif phase == "boom" then
		f.Visible = true
		hideShares()
		setText(refs.meteorText, "💥 SUPERNOVA!!!")
		refs.meteorFill.Size = UDim2.fromScale(0, 1)
		task.delay(3, function() if refs.meteorPhase == "boom" then f.Visible = false end end)
		showMeteorResults(data)
	elseif phase == "dead" then
		hideShares()
		if type(data.nextAt) == "number" then
			f.Visible = true
			refs.meteorNextAt = data.nextAt
			setText(refs.meteorText, "☄️ Meteor sank — next in " .. fmtSecs(data.nextAt - serverNow()))
			refs.meteorFill.Size = UDim2.fromScale(0, 1)
			task.delay(4, function() if refs.meteorPhase == "dead" then f.Visible = false end end)
		else
			f.Visible = false
		end
	end
end

function UI.GoldenHour(data)
	if type(data) ~= "table" then return end
	if snap then
		snap.goldenHour = data.active == true
		if data.active and type(data.remaining) == "number" then
			snap.goldenUntil = os.time() + clockOffset + data.remaining
		elseif not data.active then
			snap.goldenUntil = 0
		end
	end
end

function UI.Streak(data)
	data = type(data) == "table" and data or {}
	local vp = (gui and gui.AbsoluteSize.X > 1) and gui.AbsoluteSize or viewport()
	local card = mk("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.38),
		Size = UDim2.fromOffset(math.min(360, vp.X - 32), 130), BackgroundColor3 = BG, BackgroundTransparency = 0.06,
		BorderSizePixel = 0, ZIndex = 28,
	}, gui)
	corner(card, "md")
	stroke(card, WARN, "base", 0.1)
	text("Display", {
		Position = UDim2.fromOffset(0, 12), Size = UDim2.new(1, 0, 0, 34), Text = "🔥 DAY " .. tostring(data.day or 1) .. " STREAK!",
		TextColor3 = Color.GoldSoft, ZIndex = 29, fit = true,
	}, card)
	local msg
	if data.golden then
		msg = "🌟 A GOLDEN GEODE has spawned for you by the crater!"
	elseif data.minutes then
		msg = "✨ ×2 Luck for " .. tostring(data.minutes) .. " minutes!"
	else
		msg = "Come back tomorrow to grow your streak!"
	end
	text("Heading", {
		Position = UDim2.fromOffset(16, 52), Size = UDim2.new(1, -32, 0, 60), Text = msg, TextWrapped = true, ZIndex = 29, fit = true,
	}, card)
	task.delay(7, function()
		if card.Parent then
			TweenService:Create(card, TweenInfo.new(0.5), { Position = card.Position - UDim2.fromOffset(0, 40) }):Play()
			fadeOut(card, 0.5)
		end
	end)
end

-- ----- hooks + surfaces other modules call (all safe against an older server) -----
-- RegionFX.OnChanged -> instant HUD zone line (the server `region` toast stays the welcome)
function UI.SetZone(zoneKey)
	if type(zoneKey) == "string" and zoneKey ~= "" then currentZone = zoneKey end
	UI._refreshHudCard()
	markPlayersDirty() -- the Online sort puts my zone first
end

-- ServerGoal remote + GetState().serverGoal: render at once; pulse the chip on completion
function UI.ServerGoal(data)
	if type(data) ~= "table" then return end
	local prev = UI._serverGoal
	UI._serverGoal = data
	if data.active == false and data.completedAt ~= nil and not (type(prev) == "table" and prev.completedAt == data.completedAt) and refs.goalChip then
		local s = refs.goalChip:FindFirstChild("Pulse")
		if s then
			s.Scale = 1.06
			TweenService:Create(s, SG.Motion.pop, { Scale = 1 }):Play()
		end
	end
	tickServerGoal(serverNow())
end

function UI.CrackReadyAt()
	return crackReadyAt
end

function UI.GetSettings()
	local out = {}
	if settings then for k, v in pairs(settings) do out[k] = v end end
	return out
end

-- '👏 X cheered you!' with a one-tap cheer back
function UI.OnCheerReceived(data)
	if type(data) ~= "table" then return end
	local from = data.fromUserId
	local sender = type(from) == "number" and Players:GetPlayerByUserId(from) or nil
	local name = sender and sender.DisplayName or "Someone"
	local reactions = Config and Config.Social and Config.Social.Reactions
	local emoji = (reactions and reactions[data.idx]) or "👏"
	local action = nil
	if UI.OnCheer and sender and from ~= player.UserId then
		action = { label = "Cheer back", fn = function() UI.OnCheer(from, data.idx or 1) end }
	end
	pushToast(emoji .. " " .. name .. " cheered you!", Color.Magenta, action)
end

-- profile modal from GetProfile (public fields only; the server allow-lists them)
function UI.OpenProfile(userId)
	if type(userId) ~= "number" or userId ~= userId then return end
	local rf = remote("GetProfile")
	if not rf then
		UI.Toast("Something went wrong", "err")
		return
	end
	task.spawn(function()
		local res = UI._invoke(rf, userId)
		if not res.ok then
			if res.err and res.err ~= "Slow down!" and res.err ~= "Something went wrong" then UI.Toast(res.err, "err") end
			return
		end
		local name = tostring(res.name or "Miner")
		local tier = "Rebirth " .. tostring(res.rebirths or 0) .. (((tonumber(res.ascensions) or 0) > 0) and (" · Ascension " .. tostring(res.ascensions)) or "")
		local rar = Config.Rarities[tonumber(res.bestRarity) or 0]
		local lines = {
			"💎 Total Gems: " .. Config.Cur(res.totalGems or 0),
			"⭐ Best crystal: " .. (rar and rar.name or "—"),
			"📖 Index " .. math.floor((tonumber(res.indexPct) or 0) * 100 + 0.5) .. "% · 🐾 Pets " .. tostring(res.petsOwned or 0) .. " · 🏅 Award tiers " .. tostring(res.achTiers or 0),
			"👏 Cheers received " .. tostring(res.cheersReceived or 0) .. " · 🎁 Gifts given " .. tostring(res.giftsGiven or 0),
		}
		if res.zone and Config.Zones and Config.Zones.Get then
			local z = Config.Zones.Get(res.zone)
			if z then lines[#lines + 1] = "📍 " .. z.icon .. " " .. z.name end
		end
		if type(res.rank) == "table" and (res.rank.gems or res.rank.rebirths) then
			local parts = {}
			if res.rank.gems then parts[#parts + 1] = "#" .. tostring(res.rank.gems) .. " Gems" end
			if res.rank.rebirths then parts[#parts + 1] = "#" .. tostring(res.rank.rebirths) .. " Rebirths" end
			lines[#lines + 1] = "🏆 Rank: " .. table.concat(parts, " · ")
		end
		local buttons = {}
		if userId ~= player.UserId then
			if UI.OnCheer then
				buttons[#buttons + 1] = { text = "👏 Cheer", role = "primary", fn = function() UI.OnCheer(userId, 1) end }
			end
			local gift = Config.ProductByKey("GiftBoost")
			if gift then
				-- short label: three buttons share one ~110 px-each row; the price is in the confirm body
				buttons[#buttons + 1] = { text = "🎁 Gift", role = "premium", fn = function()
					UI.Confirm({
						title = "🎁 Gift a Lucky Boost?",
						body = "Gift a 5-min Lucky Boost to " .. name .. " — and everyone gets +10% Server Luck. R$ " .. tostring(gift.price) .. ".",
						confirmText = "Gift", confirmRole = "premium", hold = false,
						onConfirm = function() purchase("product", "GiftBoost", userId) end,
					})
				end }
			end
		end
		buttons[#buttons + 1] = { text = "Close", role = "ghost" }
		UI.Modal({
			title = (res.isVIP and "👑 " or "") .. name .. ((res.title and res.title ~= "") and (" · " .. tostring(res.title)) or ""),
			body = tier .. "\n" .. table.concat(lines, "\n"),
			buttons = buttons,
		})
	end)
end

-- first-run sequencing (UI-3 + lead notes B.1): a reward is waiting -> glow + toast with
-- "Open". The returning-player auto-open (DailyPopup.returning, 3 s, nothing open) is
-- init.client's; a first-session player never gets one.
function UI.DailyReady()
	if refs.dailyBtn then SG.setGlow(refs.dailyBtn, true) end
	UI.Toast("🎁 Daily reward ready", "gold", { label = "Open", fn = function() UI.ShowPanel("Daily") end })
end

function UI.StarterReady()
	if refs.shopBtn then SG.setGlow(refs.shopBtn, true) end
	UI.Toast("⭐ Starter Pack offer in the Shop — first session only!", "gold", { label = "Shop", fn = function() UI.ShowPanel("Shop") end })
end

-- deps = { quality = Quality } (optional): IsTouch / Tier read from it, else the touch heuristic.
function UI.Init(config, remotes, deps)
	Config, Remotes = config, remotes
	Quality = (type(deps) == "table" and deps.quality) or nil
	if Quality and Quality.IsTouch ~= nil then
		IS_TOUCH = Quality.IsTouch == true
	elseif Quality and Quality.IsMobile ~= nil then
		IS_TOUCH = Quality.IsMobile == true
	else
		IS_TOUCH = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
	end
	UI.IsTouch = IS_TOUCH
	settings = {}
	local def = Config.Social and Config.Social.SettingsDefault
	if type(def) == "table" then
		for k, v in pairs(def) do settings[k] = v end
	end

	gui = Instance.new("ScreenGui")
	gui.Name = "GeodeHUD"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 10
	gui:SetAttribute("PanelOpen", false)
	gui:SetAttribute("LeftStackBottom", 12)
	gui:SetAttribute("CentreBandLeft", 0)
	gui:SetAttribute("CentreBandRight", 0)
	gui.Parent = player:WaitForChild("PlayerGui")

	buildHUD()
	buildUpgrades()
	buildShop()
	buildIndex()
	buildDaily()
	buildPets()
	buildAchievements()
	buildPlayers()
	buildSettings()
	-- snapshot-driven panels: refreshed on every push while visible, else on open
	panelRefresh.Upgrades, panelRefresh.Shop, panelRefresh.Index = refreshUpgrades, refreshShop, refreshIndex
	panelRefresh.Daily, panelRefresh.Pets, panelRefresh.Achievements = refreshDaily, refreshPets, refreshAchievements
	refreshSettings()

	-- Escape / gamepad B close whatever is open (the scrim handles tap-outside)
	UserInputService.InputBegan:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.ButtonB then
			if UI._anyOpen then UI.TogglePanel(nil) end
		end
	end)
	-- slider drags continue anywhere on screen until the press ends
	UserInputService.InputChanged:Connect(function(input)
		if activeSlider and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			activeSlider.fromX(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			activeSlider = nil
		end
	end)

	UI._RefreshPanels()
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(UI._RefreshPanels)
	-- the camera often reports 1×1 during boot and settles AFTER the gui does,
	-- so re-layout on viewport changes too (rotation, window resize, boot race)
	local function watchCamera()
		local cam = workspace.CurrentCamera
		if cam then cam:GetPropertyChangedSignal("ViewportSize"):Connect(UI._RefreshPanels) end
	end
	watchCamera()
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		watchCamera()
		UI._RefreshPanels()
	end)
	task.defer(UI._RefreshPanels) -- re-run once AbsoluteSize settles after first render
	-- chips appearing / disappearing move the stack's bottom edge (Feed reads it)
	refs.leftStack:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		gui:SetAttribute("LeftStackBottom", 12 + refs.leftStack.AbsoluteSize.Y)
		gui:SetAttribute("CentreBandLeft", refs.leftStack.AbsoluteSize.X + 20)
	end)
	-- the touch rail must clear the jump button, which CoreGui creates after us
	if IS_TOUCH then
		task.delay(1, UI._RefreshPanels)
		task.delay(4, UI._RefreshPanels)
	end

	-- heartbeat: gem count-up (dt-based, change-only writes), the CRACK cooldown bar while a
	-- cooldown is pending, and the chip tick at 4 Hz — steady state does almost nothing
	local chipAcc, crackWasReady = 0, true
	RunService.Heartbeat:Connect(function(dt)
		if snap then
			local target = tonumber(snap.gems) or 0
			if displayGems ~= target then
				displayGems += (target - displayGems) * math.min(1, (dt or 0.016) * 10)
				if math.abs(target - displayGems) < 1 then displayGems = target end
				local shown = math.floor(displayGems + 0.5)
				if shown ~= lastShownGems then
					lastShownGems = shown
					refs.gems.Text = Config.Fmt(shown)
				end
			end
		end
		if refs.crackFill then
			local remaining = crackReadyAt - os.clock()
			local ready = remaining <= 0
			if ready ~= crackWasReady then
				crackWasReady = ready
				if refs.crackStroke then
					TweenService:Create(refs.crackStroke, TweenInfo.new(0.2), { Color = ready and GOLD or Color.Cyan }):Play()
				end
				if ready then
					refs.crackFill.Size = UDim2.fromScale(1, 1)
					local s = refs.crackBtn and refs.crackBtn:FindFirstChildOfClass("UIScale")
					if s then
						s.Scale = 1.08
						TweenService:Create(s, SG.Motion.pop, { Scale = 1 }):Play()
					end
				end
			end
			if not ready then
				local cd = math.max(0.25, (snap and tonumber(snap.cooldown)) or 1)
				refs.crackFill.Size = UDim2.fromScale(math.clamp(1 - remaining / cd, 0, 1), 1)
			end
		end
		chipAcc += dt
		if chipAcc >= 0.25 then
			chipAcc = 0
			tickChips()
		end
	end)
end

return UI
