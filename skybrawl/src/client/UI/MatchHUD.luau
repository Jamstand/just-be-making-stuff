--[[
    In-match HUD:
      - fighter cards along the bottom (damage %, stocks or score, weapon)
      - timer, countdown / GO!, KO feed
      - "You're out" / respawn notice
      - combo counter (your combos on the left, combos on you on the right)
      - pause menu (button or P key): change camera mode/look/zoom
        mid-fight, or forfeit
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
local SettingsPanel = require(script.Parent.SettingsPanel)

local T = UIKit.Theme
local make = UIKit.make

local MatchHUD = {}

local player = Players.LocalPlayer
local gui = nil
local cardsFrame = nil
local cards = {} -- [fighterId] = { frame, damage, stocks, weapon, name }
local timerLabel = nil
local bigText = nil
local feed = nil
local notice = nil
local pauseOverlay = nil
local pauseGui = nil
local endsAt = nil
local current = nil -- match table from MatchClient
local timerConnection = nil

local function popBig(text, color, duration)
	bigText.Text = text
	bigText.TextColor3 = color or T.Gold
	bigText.TextTransparency = 0
	bigText.TextStrokeTransparency = 0.2
	local scale = bigText:FindFirstChildOfClass("UIScale")
	scale.Scale = 1.6
	TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	local token = {}
	bigText:SetAttribute("Token", tostring(token))
	task.delay(duration or 0.8, function()
		if bigText:GetAttribute("Token") == tostring(token) then
			TweenService:Create(bigText, TweenInfo.new(0.25), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		end
	end)
end

local function buildCard(f, order)
	local frame = UIKit.panel({
		LayoutOrder = order,
		Size = UDim2.fromOffset(176, 82),
		BackgroundColor3 = T.PanelDark,
		BackgroundTransparency = 0.12,
		Parent = cardsFrame,
	})
	frame:FindFirstChildOfClass("UIStroke").Color = f.color or T.Stroke
	frame:FindFirstChildOfClass("UIStroke").Thickness = f.id == current.me.id and 3 or 1.5
	make("Frame", {
		BackgroundColor3 = f.color or T.Stroke,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 6),
		Parent = frame,
	}, { UIKit.corner(4) })
	local name = UIKit.label(f.name .. (f.isBot and " (Bot)" or ""), 14, {
		Position = UDim2.fromOffset(10, 8),
		Size = UDim2.new(1, -20, 0, 18),
		Font = T.BoldFont,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextWrapped = false,
		Parent = frame,
	})
	local damage = UIKit.heading("0%", 30, {
		Position = UDim2.fromOffset(10, 26),
		Size = UDim2.new(0.6, -10, 0, 34),
		Parent = frame,
	})
	local stocks = UIKit.label("", 14, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 30),
		Size = UDim2.new(0.4, 0, 0, 20),
		TextXAlignment = Enum.TextXAlignment.Right,
		Font = T.HeadFont,
		TextColor3 = T.Gold,
		Parent = frame,
	})
	local weapon = UIKit.label("Fists", 12, {
		Position = UDim2.fromOffset(10, 60),
		Size = UDim2.new(1, -20, 0, 16),
		TextColor3 = T.Muted,
		Parent = frame,
	})
	cards[f.id] = { frame = frame, damage = damage, stocks = stocks, weapon = weapon, name = name }
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

	if f == current.me then
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
	timerLabel.Visible = endsAt ~= nil
	popBig("GO!", T.Gold, 0.7)
end

function MatchHUD.ko(victim, attacker)
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
	local line = UIKit.label(text, 15, {
		Size = UDim2.new(1, 0, 0, 22),
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

function MatchHUD.ended()
	if timerLabel then
		timerLabel.Visible = false
	end
	if notice then
		notice.Visible = false
	end
	if pauseOverlay then
		pauseOverlay.Visible = false
	end
end

local function togglePause(force)
	if not gui or not pauseOverlay then
		return
	end
	if force ~= nil then
		pauseOverlay.Visible = force
	else
		pauseOverlay.Visible = not pauseOverlay.Visible
	end
end

local function buildPause()
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
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Active = true,
		Parent = pauseGui,
	})
	local panel = UIKit.panel({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0.9, 0, 0.8, 0),
		BackgroundColor3 = T.PanelDark,
		Parent = pauseOverlay,
	})
	make("UISizeConstraint", { MaxSize = Vector2.new(560, 560), Parent = panel })
	UIKit.padding(16, 12).Parent = panel
	UIKit.heading("Paused (the fight keeps going!)", 22, { Size = UDim2.new(1, 0, 0, 30), Parent = panel })
	local scroll = UIKit.scroll({
		Position = UDim2.fromOffset(0, 38),
		Size = UDim2.new(1, 0, 1, -96),
		Parent = panel,
	})
	UIKit.list(Enum.FillDirection.Vertical, 6).Parent = scroll
	SettingsPanel.cameraRows(scroll, 0)

	local footer = make("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 46),
		Parent = panel,
	})
	local confirming = false
	local forfeit
	forfeit = UIKit.button("Forfeit", "danger", function()
		if not confirming then
			confirming = true
			forfeit.Text = "Really forfeit?"
			task.delay(3, function()
				confirming = false
				forfeit.Text = "Forfeit"
			end)
			return
		end
		Net.get("FighterAction"):FireServer("Forfeit")
		pauseOverlay.Visible = false
	end, { Size = UDim2.fromOffset(170, 42), Parent = footer })
	UIKit.button("Resume", "primary", function()
		togglePause(false)
	end, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromOffset(140, 42), Parent = footer })
end

function MatchHUD.show(match)
	current = match
	if gui then
		gui:Destroy()
	end
	if pauseGui then
		pauseGui:Destroy()
		pauseGui = nil
	end
	cards = {}
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
		Position = UDim2.new(0.5, 0, 1, -10),
		Size = UDim2.new(1, -20, 0, 82),
		Parent = gui,
	}, { UIKit.list(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Bottom) })
	-- Keep cards out of the way of the mobile buttons.
	if UserInputService.TouchEnabled then
		cardsFrame.AnchorPoint = Vector2.new(0.5, 0)
		cardsFrame.Position = UDim2.new(0.5, 0, 0, 52)
		make("UIScale", { Scale = 0.75, Parent = cardsFrame })
	end
	local mapInfo = Maps.get(match.info.mapId)
	UIKit.label(string.format("%s  ·  %s%s", Config.Modes[match.info.mode].Label, mapInfo and mapInfo.Name or "", match.info.ranked and "  ·  Ranked" or ""), 14, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 8),
		Size = UDim2.fromOffset(400, 18),
		TextXAlignment = Enum.TextXAlignment.Center,
		Font = T.BoldFont,
		TextColor3 = T.Muted,
		TextStrokeTransparency = 0.5,
		Parent = gui,
	})
	timerLabel = UIKit.heading("", 30, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 24),
		Size = UDim2.fromOffset(200, 34),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextStrokeTransparency = 0.3,
		Visible = false,
		Parent = gui,
	})
	bigText = UIKit.heading("", 96, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.4),
		Size = UDim2.fromOffset(600, 120),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTransparency = 1,
		TextStrokeTransparency = 1,
		TextStrokeColor3 = Color3.fromRGB(20, 20, 40),
		Parent = gui,
	})
	make("UIScale", { Parent = bigText })
	local touch = UserInputService.TouchEnabled
	feed = make("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, touch and 128 or 60),
		Size = UDim2.fromOffset(320, 200),
		Parent = gui,
	}, { UIKit.list(Enum.FillDirection.Vertical, 4, Enum.HorizontalAlignment.Right) })
	notice = UIKit.heading("", 26, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, touch and 128 or 64),
		Size = UDim2.fromOffset(500, 34),
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

	UIKit.button("Menu (P)", "ghost", function()
		togglePause()
	end, {
		Position = UDim2.fromOffset(12, 12),
		Size = UDim2.fromOffset(100, 34),
		TextSize = 15,
		Parent = gui,
	})
	buildPause()

	if timerConnection then
		timerConnection:Disconnect()
	end
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
		Position = UDim2.new(left and 0 or 1, left and 24 or -24, 0.42, 0),
		Size = UDim2.fromOffset(220, 90),
		Parent = gui,
	})
	local count = make("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 58),
		Font = Enum.Font.FredokaOne,
		TextSize = left and 52 or 38,
		TextXAlignment = left and Enum.TextXAlignment.Left or Enum.TextXAlignment.Right,
		TextColor3 = left and T.Gold or Color3.fromRGB(255, 120, 110),
		TextStrokeTransparency = 0.15,
		TextTransparency = 1,
		TextStrokeColor3 = Color3.fromRGB(20, 16, 30),
		Parent = frame,
	}, { make("UIScale", { Scale = 1 }) })
	local tag = make("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 56),
		Size = UDim2.new(1, 0, 0, 24),
		Font = Enum.Font.GothamBlack,
		TextSize = 18,
		TextXAlignment = left and Enum.TextXAlignment.Left or Enum.TextXAlignment.Right,
		TextColor3 = Color3.new(1, 1, 1),
		TextStrokeTransparency = 0.3,
		TextTransparency = 1,
		Parent = frame,
	})
	w = { frame = frame, count = count, tag = tag, token = 0 }
	comboWidgets[side] = w
	return w
end

local function showCombo(side, hits, isTrue)
	if not gui then
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
	local scale = w.count:FindFirstChildOfClass("UIScale")
	scale.Scale = 1.35
	TweenService:Create(scale, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
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
		end
	end)
end

return MatchHUD
