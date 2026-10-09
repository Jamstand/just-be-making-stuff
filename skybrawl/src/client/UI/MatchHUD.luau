--[[
    In-match HUD:
      - fighter cards along the bottom (damage %, stocks or score, weapon,
        the ultimate meter and the guard meter)
      - timer, countdown / GO!, KO feed, "GAME!" at the end
      - "You're out" / respawn notice
      - combo counter (your combos on the left, combos on you on the right)
      - pause menu (P key, the "Menu (P)" button, or gamepad View outside
        training): change camera mode/look/zoom mid-fight, or forfeit (in
        training: LEAVE TRAINING)

    The pause menu is a Focus layer in the overlay band with inMatch = true:
    Focus reads input for it during the match and turns fight input off
    while it is open (Focus owns Input.setEnabled). Back or the Menu action
    (Tab / View) closes it; P toggles it.

    In the training room (menus design 5.11) the mode/timer label, the
    fighter cards, the kill feed and the "Menu (P)" button are hidden (the
    training panel has its own LEAVE TRAINING); P still opens the pause
    menu, and View belongs to the training panel.

    Sizes are design px at 1080p (Layout.px; text through Layout.bindText),
    so the HUD keeps its proportions on any screen, scaled back up on phones
    (see hudScale). In training the combo counters, the respawn notice and
    the KO pop stay off too (the training HUD has its own readouts).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Combat = require(Shared.Combat)
local Maps = require(Shared.Maps)
local Weapons = require(Shared.Weapons)
local Util = require(Shared.Util)
local Net = require(Shared.Net)

local UIKit = require(script.Parent.UIKit)
local Focus = require(script.Parent.Focus)
local Layout = require(script.Parent.Layout)
local SettingsPanel = require(script.Parent.SettingsPanel)

local T = UIKit.Theme
local make = UIKit.make

local MatchHUD = {}

local B = Config.Battle
local ULT_COLOR = Color3.fromRGB(255, 196, 64)
local ULT_READY = Color3.fromRGB(255, 240, 150)
local AWAKE_COLOR = Color3.fromRGB(255, 84, 60)
local GUARD_COLOR = Color3.fromRGB(90, 170, 255)
local GUARD_LOW = Color3.fromRGB(255, 90, 90)
local REOPEN_GUARD = 0.15 -- a View press that just closed the pause menu doesn't reopen it

local player = Players.LocalPlayer
local gui = nil
local cardsFrame = nil
local cards = {} -- [fighterId] = { frame, damage, stocks, weapon, name }
local timerLabel = nil
local bigText = nil
local gameHolder = nil
local feed = nil
local notice = nil
local pauseOverlay = nil
local pauseGui = nil
local pauseLayer = nil
local resumeButton = nil
local pauseClosedAt = -math.huge
local endsAt = nil
local current = nil -- match table from MatchClient
local timerConnection = nil

--[[
    On phones Layout.px makes design px about 0.55x (n * 369 / 1080 * 1.6),
    too small for a HUD read mid-fight, so in Phone mode the HUD scales its
    sizes back up to about one point per design px (the fixed sizes it had
    before), and draws the cards a quarter smaller so four still fit across.
]]
local PHONE_HUD = 1.8
local PHONE_CARDS = 0.75
local hudScale = 1 -- PHONE_HUD in Phone mode (set by show)

-- Offsets in design px.
local function px(n)
	return Layout.px(n * hudScale)
end

-- Text sizes and stroke thicknesses in design px (UIKit and Layout.bind* apply Layout.px themselves).
local function ts(n)
	return n * hudScale
end

local function isTraining()
	return current ~= nil and (current.training == true or current.info.source == "Training")
end

local function popBig(text, color, duration)
	if not bigText then
		return
	end
	bigText.Text = text
	bigText.TextColor3 = color or T.Gold
	bigText.TextTransparency = 0
	bigText.TextStrokeTransparency = 0.2
	local scale = bigText.Parent:FindFirstChildOfClass("UIScale")
	scale.Scale = 1.6
	TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
		:Play()
	local token = {}
	bigText:SetAttribute("Token", tostring(token))
	task.delay(duration or 0.8, function()
		if bigText:GetAttribute("Token") == tostring(token) then
			TweenService:Create(bigText, TweenInfo.new(0.25), { TextTransparency = 1, TextStrokeTransparency = 1 })
				:Play()
		end
	end)
end

local function buildCard(f, order)
	local frame = UIKit.panel({
		LayoutOrder = order,
		Size = UDim2.fromOffset(px(176), px(100)),
		BackgroundColor3 = T.PanelDark,
		BackgroundTransparency = 0.12,
		Parent = cardsFrame,
	})
	local border = frame:FindFirstChildOfClass("UIStroke")
	if border then
		border.Color = f.color or T.Stroke
		Layout.bindStroke(border, ts(f.id == current.me.id and 3 or 1.5))
	end
	make("Frame", {
		BackgroundColor3 = f.color or T.Stroke,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, px(6)),
		Parent = frame,
	})
	local name = UIKit.label(f.name .. (f.isBot and " (Bot)" or ""), ts(14), {
		Position = UDim2.fromOffset(px(10), px(8)),
		Size = UDim2.new(1, -px(20), 0, px(18)),
		Font = T.BoldFont,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextWrapped = false,
		Parent = frame,
	})
	local damage = UIKit.heading("0%", ts(30), {
		Position = UDim2.fromOffset(px(10), px(26)),
		Size = UDim2.new(0.6, -px(10), 0, px(34)),
		Parent = frame,
	})
	local stocks = UIKit.label("", ts(14), {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -px(10), 0, px(30)),
		Size = UDim2.new(0.4, 0, 0, px(20)),
		TextXAlignment = Enum.TextXAlignment.Right,
		Font = T.HeadFont,
		TextColor3 = T.Gold,
		Parent = frame,
	})
	local weapon = UIKit.label("Fists", ts(12), {
		Position = UDim2.fromOffset(px(10), px(60)),
		Size = UDim2.new(1, -px(20), 0, px(16)),
		TextColor3 = T.Muted,
		Parent = frame,
	})
	local function bar(y, height, color)
		local back = make("Frame", {
			Position = UDim2.new(0, px(10), 0, px(y)),
			Size = UDim2.new(1, -px(20), 0, math.max(2, px(height))),
			BackgroundColor3 = Color3.fromRGB(10, 10, 16),
			BackgroundTransparency = 0.2,
			BorderSizePixel = 0,
			Parent = frame,
		})
		return make("Frame", {
			Size = UDim2.fromScale(0, 1),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			Parent = back,
		})
	end
	local ult = bar(78, 9, ULT_COLOR)
	local ultLabel = UIKit.label("", ts(10), {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -px(10), 0, px(60)),
		Size = UDim2.new(0.6, 0, 0, px(16)),
		TextXAlignment = Enum.TextXAlignment.Right,
		Font = T.BoldFont,
		TextColor3 = ULT_READY,
		Parent = frame,
	})
	local guard = bar(90, 4, GUARD_COLOR)
	cards[f.id] = {
		frame = frame,
		damage = damage,
		stocks = stocks,
		weapon = weapon,
		name = name,
		ult = ult,
		ultLabel = ultLabel,
		guard = guard,
	}
	MatchHUD.updateMeters(f)
end

-- The ultimate and guard meters on a fighter's card.
function MatchHUD.updateMeters(f)
	local card = f and cards[f.id]
	if not card then
		return
	end
	local ult = math.clamp((f.ult or 0) / B.UltMax, 0, 1)
	local awake = f.awakened == true
	card.ult.Size = UDim2.fromScale(awake and (f.awakenFrac or 1) or ult, 1)
	card.ult.BackgroundColor3 = awake and AWAKE_COLOR or (ult >= 1 and ULT_READY or ULT_COLOR)
	local mine = current and f == current.me
	if awake then
		card.ultLabel.Text = "AWAKENED"
		card.ultLabel.TextColor3 = AWAKE_COLOR
	elseif ult >= 1 then
		card.ultLabel.Text = mine and "ULT READY" or "ULT"
		card.ultLabel.TextColor3 = ULT_READY
	else
		card.ultLabel.Text = ""
	end
	local guard = math.clamp((f.guard or B.GuardMax) / B.GuardMax, 0, 1)
	card.guard.Size = UDim2.fromScale(guard, 1)
	card.guard.BackgroundColor3 = guard < 0.3 and GUARD_LOW or GUARD_COLOR
end

-- A big centered callout ("GUARD BREAK!", "AWAKENED!", an ultimate's name).
function MatchHUD.announce(text, color, duration)
	if bigText then
		popBig(text, color, duration)
	end
end

function MatchHUD.updateFighter(f)
	local card = f and cards[f.id]
	if not card then
		return
	end
	local out = f.eliminated or f.left
	if out then
		card.damage.Text = f.left and "LEFT" or "OUT"
		card.damage.TextColor3 = T.Muted
	elseif not f.alive then
		card.damage.Text = "KO"
		card.damage.TextColor3 = T.Danger
	else
		card.damage.Text = math.floor(f.damage) .. "%"
		card.damage.TextColor3 = Combat.damageColor(f.damage)
	end
	if current.info.winRule == "Timed" then
		card.stocks.Text = "Score " .. f.score
	else
		card.stocks.Text = string.rep("● ", math.max(0, f.stocks)):sub(1, -2)
	end
	local weapon = Weapons.get(f.weapon)
	card.weapon.Text = weapon.Name
	card.weapon.TextColor3 = Weapons.isWeapon(f.weapon) and weapon.Color or T.Muted
	card.frame.BackgroundTransparency = out and 0.5 or 0.12

	if f == current.me and not isTraining() then
		if out then
			notice.Text = f.left and "" or "You're out! Spectating..."
			notice.Visible = not f.left
		elseif not f.alive then
			notice.Text = "Respawning..."
			notice.Visible = true
		else
			notice.Visible = false
		end
	end
end

function MatchHUD.countdown(n)
	popBig(tostring(n), T.Text, 0.8)
end

function MatchHUD.go(serverEndsAt)
	endsAt = serverEndsAt
	if timerLabel then
		timerLabel.Visible = endsAt ~= nil and not isTraining()
	end
	popBig("GO!", T.Gold, 0.7)
end

function MatchHUD.ko(victim, attacker)
	if not gui or isTraining() then
		-- (training: no KO pop; its feed is hidden)
		return
	end
	local text
	if attacker then
		text = string.format("%s KO'd %s", attacker.name, victim.name)
	else
		text = victim.name .. " fell"
	end
	if victim == current.me then
		popBig("KO!", T.Danger, 1)
	elseif attacker == current.me then
		popBig("KO!", T.Gold, 0.9)
	end
	local line = UIKit.label(text, ts(15), {
		Size = UDim2.new(1, 0, 0, px(22)),
		Font = T.BoldFont,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextStrokeTransparency = 0.4,
		TextColor3 = attacker and attacker.color or T.Text,
		Parent = feed,
	})
	task.delay(4, function()
		TweenService:Create(line, TweenInfo.new(0.4), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		task.wait(0.45)
		line:Destroy()
	end)
end

-- Pause menu ----------------------------------------------------------------------

local function closePause()
	if pauseLayer then
		Focus.popLayer(pauseLayer)
		pauseLayer = nil
		pauseClosedAt = os.clock()
	end
	if pauseOverlay then
		pauseOverlay.Visible = false
	end
end

local function openPause()
	if not gui or not pauseOverlay or pauseLayer then
		return
	end
	if current and current.phase == "Ended" then
		return
	end
	pauseOverlay.Visible = true
	pauseLayer = Focus.pushLayer({
		name = "Pause",
		roots = { pauseOverlay },
		band = "overlay",
		inMatch = true,
		defaultFocus = function()
			return resumeButton
		end,
		onBack = closePause,
		actions = { Menu = closePause },
	})
end

local function togglePause()
	if pauseLayer then
		closePause()
	else
		openPause()
	end
end

-- "GAME!" at the end of the fight (Bangers 180, white with a red outline), popping in like the countdown.
local function showGame()
	if not gameHolder then
		return
	end
	local label = gameHolder:FindFirstChild("Text")
	local stroke = label and label:FindFirstChildOfClass("UIStroke")
	local scale = gameHolder:FindFirstChildOfClass("UIScale")
	if not label or not stroke or not scale then
		return
	end
	gameHolder.Visible = true
	label.TextTransparency = 0
	stroke.Transparency = 0
	scale.Scale = 1.6
	TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
		:Play()
end

function MatchHUD.ended()
	if timerLabel then
		timerLabel.Visible = false
	end
	if notice then
		notice.Visible = false
	end
	closePause()
	if bigText then
		bigText.TextTransparency = 1
		bigText.TextStrokeTransparency = 1
	end
	if not isTraining() then
		showGame()
	end
end

local function buildPause(training)
	-- Its own ScreenGui, drawn above the mobile touch controls.
	pauseGui = make("ScreenGui", {
		Name = "SkybrawlPause",
		ResetOnSpawn = false,
		DisplayOrder = 25,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = player:WaitForChild("PlayerGui"),
	})
	pauseOverlay = make("Frame", {
		Name = "Pause",
		BackgroundColor3 = T.Backdrop,
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Active = true,
		Parent = pauseGui,
	})
	local phone = Layout.mode() == "Phone"
	local panel, body = UIKit.cutPanel({
		parent = pauseOverlay,
		anchor = Vector2.new(0.5, 0.5),
		position = UDim2.fromScale(0.5, 0.5),
		size = if phone then UDim2.fromScale(0.8, 0.86) else UDim2.fromScale(0.36, 0.72),
		title = "PAUSED",
		titleSize = 54,
		zIndex = 2,
	})
	make("UISizeConstraint", { MaxSize = Vector2.new(px(760), px(820)), Parent = panel })
	UIKit.label("The fight keeps going!", 20, {
		Position = UDim2.fromScale(0.05, 0),
		Size = UDim2.fromScale(0.9, 0.07),
		TextColor3 = T.Muted,
		ZIndex = 4,
		Parent = body,
	})
	local scroll = UIKit.scroll({
		Position = UDim2.fromScale(0.05, 0.08),
		Size = UDim2.fromScale(0.9, 0.62),
		ZIndex = 4,
		Selectable = false,
		Parent = body,
	})
	UIKit.list(Enum.FillDirection.Vertical, 6).Parent = scroll
	SettingsPanel.cameraRows(scroll, 0)

	local confirming = false
	local forfeit
	-- (a slant button draws its text in an inner "Label")
	local function setForfeitText(text)
		local label = forfeit:FindFirstChild("Label", true)
		if label and label:IsA("TextLabel") then
			label.Text = text
		else
			forfeit.Text = text
		end
	end
	local function leave()
		if training then
			closePause()
			task.spawn(function()
				local ok, err = pcall(function()
					return Net.get("TrainingRequest"):InvokeServer("Leave")
				end)
				if not ok then
					warn("[MatchHUD] leaving training failed:", err)
				end
			end)
			return
		end
		if not confirming then
			confirming = true
			setForfeitText("REALLY FORFEIT?")
			task.delay(3, function()
				confirming = false
				if forfeit.Parent then
					setForfeitText("FORFEIT")
				end
			end)
			return
		end
		closePause()
		-- the server releases your character; MatchClient takes you back to the menu
		Net.get("FighterAction"):FireServer("Forfeit", {})
	end
	forfeit = UIKit.slantButton(if training then "LEAVE TRAINING" else "FORFEIT", {
		style = "dark",
		parent = body,
		anchor = Vector2.new(0, 1),
		position = UDim2.fromScale(0.05, 0.96),
		size = UDim2.fromScale(0.46, 0.16),
		textSize = 34,
		name = "PauseForfeit",
		zIndex = 4,
	}, leave)
	resumeButton = UIKit.slantButton("RESUME", {
		style = "primary",
		parent = body,
		anchor = Vector2.new(1, 1),
		position = UDim2.fromScale(0.95, 0.96),
		size = UDim2.fromScale(0.42, 0.16),
		textSize = 34,
		name = "PauseResume",
		zIndex = 4,
	}, closePause)
	Focus.linkRow({ forfeit, resumeButton })
end

function MatchHUD.show(match)
	MatchHUD.hide()
	current = match
	cards = {}
	local training = isTraining()
	local phone = Layout.mode() == "Phone"
	hudScale = if phone then PHONE_HUD else 1
	gui = make("ScreenGui", {
		Name = "SkybrawlHUD",
		ResetOnSpawn = false,
		DisplayOrder = 10,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = player:WaitForChild("PlayerGui"),
	})

	cardsFrame = make("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -px(10)),
		Size = UDim2.new(1, -px(20), 0, px(100)),
		Visible = not training,
		Parent = gui,
	}, { UIKit.list(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Bottom) })
	-- Keep cards out of the way of the mobile buttons.
	if UserInputService.TouchEnabled then
		cardsFrame.AnchorPoint = Vector2.new(0.5, 0)
		cardsFrame.Position = UDim2.new(0.5, 0, 0, px(52))
	end
	if phone then
		make("UIScale", { Scale = PHONE_CARDS, Parent = cardsFrame })
	end
	local mapInfo = Maps.get(match.info.mapId)
	local mode = Config.Modes[match.info.mode]
	UIKit.label(
		string.format(
			"%s  ·  %s%s",
			mode and mode.Label or "",
			mapInfo and mapInfo.Name or "",
			match.info.ranked and "  ·  Ranked" or ""
		),
		ts(14),
		{
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, px(8)),
			Size = UDim2.fromOffset(px(400), px(18)),
			TextXAlignment = Enum.TextXAlignment.Center,
			Font = T.BoldFont,
			TextColor3 = T.Muted,
			TextStrokeTransparency = 0.5,
			Visible = not training,
			Parent = gui,
		}
	)
	timerLabel = UIKit.heading("", ts(30), {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, px(24)),
		Size = UDim2.fromOffset(px(200), px(34)),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextStrokeTransparency = 0.3,
		Visible = false,
		Parent = gui,
	})
	-- big callouts live in a holder whose UIScale pops them (the label's own UIScale is Layout's TextFit)
	local bigHolder = make("Frame", {
		Name = "BigText",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.4),
		Size = UDim2.fromOffset(px(600), px(120)),
		Parent = gui,
	}, { make("UIScale", {}) })
	bigText = UIKit.heading("", ts(96), {
		Size = UDim2.fromScale(1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTransparency = 1,
		TextStrokeTransparency = 1,
		TextStrokeColor3 = Color3.fromRGB(20, 20, 40),
		Parent = bigHolder,
	})
	gameHolder = make("Frame", {
		Name = "Game",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.42),
		Size = UDim2.fromScale(0.7, 0.26),
		Visible = false,
		ZIndex = 3,
		Parent = gui,
	}, { make("UIScale", {}) })
	local gameText = make("TextLabel", {
		Name = "Text",
		BackgroundTransparency = 1,
		Text = "GAME!",
		Font = Enum.Font.Bangers,
		TextColor3 = Color3.new(1, 1, 1),
		TextTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 3,
		Parent = gameHolder,
	})
	Layout.bindText(gameText, 180)
	local gameStroke = make("UIStroke", {
		Color = T.Red,
		Transparency = 1,
		LineJoinMode = Enum.LineJoinMode.Round,
		Parent = gameText,
	})
	Layout.bindStroke(gameStroke, 8)

	local touch = UserInputService.TouchEnabled
	feed = make("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -px(12), 0, px(touch and 128 or 60)),
		Size = UDim2.fromOffset(px(320), px(200)),
		Visible = not training,
		Parent = gui,
	}, { UIKit.list(Enum.FillDirection.Vertical, 4, Enum.HorizontalAlignment.Right) })
	notice = UIKit.heading("", ts(26), {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, px(touch and 128 or 64)),
		Size = UDim2.fromOffset(px(500), px(34)),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextStrokeTransparency = 0.3,
		Visible = false,
		Parent = gui,
	})

	-- Cards last: updateFighter() writes to `notice` and the labels above.
	for i, f in match.order do
		buildCard(f, i)
		MatchHUD.updateFighter(f)
	end

	-- (at (12, 12) of a gui that keeps the default inset, so it stays below the Roblox top bar; at least 44 px
	-- tall, the touch target minimum: on touch it is the only way to the pause menu and FORFEIT)
	local menuButton = UIKit.button("Menu (P)", "ghost", function()
		togglePause()
	end, {
		Position = UDim2.fromOffset(12, 12),
		Size = UDim2.fromOffset(px(120), math.max(44, px(46))),
		TextSize = ts(18),
		Visible = not training,
		Parent = gui,
	})
	menuButton:SetAttribute("FocusKey", "HudMenu")
	buildPause(training)

	timerConnection = RunService.Heartbeat:Connect(function()
		if endsAt and timerLabel then
			local remaining = endsAt - workspace:GetServerTimeNow()
			timerLabel.Text = Util.formatTime(remaining)
			timerLabel.TextColor3 = remaining < 30 and T.Danger or T.Text
		end
	end)
end

-- Combo counter ------------------------------------------------------------

local comboWidgets = {}

local function comboWidget(side)
	local w = comboWidgets[side]
	if w and w.frame.Parent then
		return w
	end
	local left = side == "mine"
	local frame = make("Frame", {
		Name = left and "Combo" or "ComboTaken",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(left and 0 or 1, 0.5),
		Position = UDim2.new(left and 0 or 1, px(left and 24 or -24), 0.42, 0),
		Size = UDim2.fromOffset(px(220), px(90)),
		Parent = gui,
	})
	-- the pop scales this holder (the label's own UIScale is Layout's TextFit)
	local countHolder = make("Frame", {
		Name = "Count",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, px(58)),
		Parent = frame,
	}, { make("UIScale", { Scale = 1 }) })
	local count = make("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Font = Enum.Font.FredokaOne,
		TextXAlignment = left and Enum.TextXAlignment.Left or Enum.TextXAlignment.Right,
		TextColor3 = left and T.Gold or Color3.fromRGB(255, 120, 110),
		TextStrokeTransparency = 0.15,
		TextTransparency = 1,
		TextStrokeColor3 = Color3.fromRGB(20, 16, 30),
		Parent = countHolder,
	})
	Layout.bindText(count, ts(left and 52 or 38))
	local tag = make("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, px(56)),
		Size = UDim2.new(1, 0, 0, px(24)),
		Font = Enum.Font.GothamBlack,
		TextXAlignment = left and Enum.TextXAlignment.Left or Enum.TextXAlignment.Right,
		TextColor3 = Color3.new(1, 1, 1),
		TextStrokeTransparency = 0.3,
		TextTransparency = 1,
		Parent = frame,
	})
	Layout.bindText(tag, ts(18))
	w = { frame = frame, count = count, countHolder = countHolder, tag = tag, token = 0 }
	comboWidgets[side] = w
	return w
end

local function showCombo(side, hits, isTrue)
	if not gui or isTraining() then
		-- (training shows combos in its own COMBO readout)
		return
	end
	local w = comboWidget(side)
	w.token += 1
	local token = w.token
	w.count.Text = string.format("%d HITS", hits)
	w.tag.Text = isTrue and "TRUE COMBO" or "STRING"
	w.tag.TextColor3 = isTrue and Color3.fromRGB(120, 230, 255) or Color3.fromRGB(220, 220, 230)
	w.count.TextTransparency = 0
	w.count.TextStrokeTransparency = 0.15
	w.tag.TextTransparency = 0
	w.tag.TextStrokeTransparency = 0.3
	local scale = w.countHolder:FindFirstChildOfClass("UIScale")
	scale.Scale = 1.35
	TweenService:Create(scale, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
		:Play()
	task.delay(1.4, function()
		if w.token == token and w.frame.Parent then
			local fade = TweenInfo.new(0.3)
			TweenService:Create(w.count, fade, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
			TweenService:Create(w.tag, fade, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		end
	end)
end

-- Your attack landed as hit number `hits` of a combo.
function MatchHUD.combo(hits, isTrue)
	showCombo("mine", hits, isTrue)
end

-- Someone is comboing you.
function MatchHUD.comboTaken(hits, isTrue)
	showCombo("taken", hits, isTrue)
end

function MatchHUD.hide()
	closePause()
	endsAt = nil
	comboWidgets = {}
	if timerConnection then
		timerConnection:Disconnect()
		timerConnection = nil
	end
	if gui then
		gui:Destroy()
		gui = nil
	end
	if pauseGui then
		pauseGui:Destroy()
		pauseGui = nil
	end
	pauseOverlay = nil
	resumeButton = nil
	gameHolder = nil
	bigText = nil
	cardsFrame = nil
	timerLabel = nil
	feed = nil
	notice = nil
	cards = {}
	current = nil
end

function MatchHUD.init()
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not gui then
			return
		end
		if input.KeyCode == Enum.KeyCode.P then
			togglePause()
		elseif input.KeyCode == Enum.KeyCode.ButtonSelect and not isTraining() then
			-- View opens the pause menu; while it is open, its layer's Menu action closes it
			if not pauseLayer and os.clock() - pauseClosedAt > REOPEN_GUARD then
				openPause()
			end
		end
	end)
end

return MatchHUD
