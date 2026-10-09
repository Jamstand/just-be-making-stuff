--[[
    The search banner at the top centre of the menus (menus design 5.7),
    shown while ClientState.queue is set: a pulsing red ring, "SEARCHING",
    the mode, a timer (the server's `waited` plus the seconds since that
    update, counted locally), "<n> in queue", the rating window for ranked
    queues, and CANCEL (QueueRequest "Leave"; any member of a party cancels
    the whole search). CANCEL is a focus stop inside the banner, which
    every menu screen's Focus layer includes; on the main menu it shows the
    Back glyph, since Back cancels the search there. On phones the banner is
    a pill: dot, mode, timer and an X.

    When the search ends because a match was found the banner just hides
    (the MATCH FOUND flash belongs to legend select).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)

local Client = script.Parent.Parent
local ClientState = require(Client:WaitForChild("ClientState"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))
local Focus = require(script.Parent:WaitForChild("Focus"))
local Layout = require(script.Parent:WaitForChild("Layout"))
local MenuModels = require(script.Parent:WaitForChild("MenuModels"))

local T = UIKit.Theme
local make = UIKit.make

local QueueBanner = {}

local function label(name, parent, props, size)
	local obj = make("TextLabel", {
		Name = name,
		BackgroundTransparency = 1,
		Text = "",
		Font = T.BlackFont,
		TextColor3 = T.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = parent.ZIndex + 1,
		Parent = parent,
	})
	for key, value in props do
		obj[key] = value
	end
	Layout.bindText(obj, size)
	return obj
end

-- A red ring with a dot, pulsing while the banner shows.
local function pulseRing(parent, props)
	local ring = make("Frame", {
		Name = "Pulse",
		BackgroundTransparency = 1,
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		ZIndex = parent.ZIndex + 1,
		Parent = parent,
	})
	for key, value in props do
		ring[key] = value
	end
	make("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = ring })
	local stroke = make("UIStroke", { Color = T.Red, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = ring })
	Layout.bindStroke(stroke, 4)
	local dot = make("Frame", {
		Name = "Dot",
		BackgroundColor3 = T.Red,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.5, 0.5),
		ZIndex = ring.ZIndex,
		Parent = ring,
	})
	make("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = dot })
	local tween = TweenService:Create(
		stroke,
		TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Transparency = 0.75 }
	)
	tween:Play()
	ring.Destroying:Connect(function()
		tween:Cancel()
	end)
	return ring
end

local function cancelSearch()
	local ok, message = Net.get("QueueRequest"):InvokeServer("Leave")
	if not ok and message then
		ClientState.toast(message, "error")
	end
end

-- Returns { root, cancelButton() (nil while not queued), setRoot(isMainMenu) }.
function QueueBanner.new(canvas, _host)
	local root = make("Frame", {
		Name = "QueueBanner",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 14,
		Visible = false,
		Parent = canvas,
	})
	local cancel = nil
	local backGlyph = nil
	local isRoot = true
	local update = nil -- (status, since)
	local receivedAt = os.clock()

	local function buildWide()
		root.Size = UDim2.fromScale(0.333, 0.07)
		Layout.clearTop(root, UDim2.fromScale(0.5, 0.024))
		local slab = UIKit.slantFrame({ parent = root, fill = T.Panel, outline = 3, zIndex = root.ZIndex })
		local content = slab.Content
		make("Frame", {
			Name = "Accent",
			BackgroundColor3 = T.Red,
			BorderSizePixel = 0,
			Position = UDim2.fromScale(0, 0.92),
			Size = UDim2.fromScale(0.45, 0.08),
			ZIndex = content.ZIndex + 1,
			Parent = content,
		})
		pulseRing(content, { Position = UDim2.fromScale(0.01, 0.2), Size = UDim2.fromScale(0.6, 0.6) })
		local title = label("Title", content, {
			Font = T.BlackFont,
			TextColor3 = T.Muted,
			Position = UDim2.fromScale(0.12, 0.06),
			Size = UDim2.fromScale(0.3, 0.26),
		}, 16)
		local mode = label("Mode", content, {
			Font = T.HeadFont,
			Position = UDim2.fromScale(0.12, 0.28),
			Size = UDim2.fromScale(0.3, 0.66),
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, 44)
		local timer = label("Timer", content, {
			Font = T.LogoFont,
			Position = UDim2.fromScale(0.42, 0.1),
			Size = UDim2.fromScale(0.15, 0.8),
		}, 50)
		local count = label("Count", content, {
			Font = T.BoldFont,
			TextColor3 = T.Muted,
			Position = UDim2.fromScale(0.58, 0.14),
			Size = UDim2.fromScale(0.2, 0.36),
		}, 16)
		local window = label("Window", content, {
			Font = T.BoldFont,
			TextColor3 = T.Muted,
			Position = UDim2.fromScale(0.58, 0.5),
			Size = UDim2.fromScale(0.2, 0.36),
		}, 16)
		-- (a blank icon slot: the Back glyph goes there on the main menu)
		cancel = UIKit.slantButton("CANCEL", {
			parent = content,
			name = "QueueCancel",
			style = "dark",
			icon = " ",
			textSize = 30,
			glyph = false,
			anchor = Vector2.new(1, 0.5),
			position = UDim2.fromScale(1, 0.5),
			size = UDim2.fromScale(0.22, 0.78),
			zIndex = content.ZIndex + 1,
		}, cancelSearch)
		-- a holder, since the glyph itself shows / hides with the input mode
		backGlyph = make("Frame", {
			Name = "BackGlyph",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			ZIndex = content.ZIndex + 8,
			Parent = cancel:FindFirstChild("Icon", true),
		})
		UIKit.glyph("Back", { parent = backGlyph, zIndex = content.ZIndex + 8 })
		return function(status, since)
			local line = MenuModels.queueLine(status, since)
			title.Text = line.title
			mode.Text = string.upper(line.label)
			timer.Text = line.timer
			count.Text = line.count
			window.Text = line.window or ""
		end
	end

	local function buildPhone()
		local x, y, w, h = Layout.phoneRect(345, 9, 182, 33)
		root.Size = UDim2.fromScale(w, h)
		Layout.clearTop(root, UDim2.fromScale(x + w / 2, y))
		local slab = UIKit.slantFrame({ parent = root, fill = T.Panel, outline = 3, zIndex = root.ZIndex })
		local content = slab.Content
		local dot = make("Frame", {
			Name = "Dot",
			BackgroundColor3 = T.Red,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.fromScale(0.02, 0.5),
			Size = UDim2.fromScale(0.36, 0.36),
			SizeConstraint = Enum.SizeConstraint.RelativeYY,
			ZIndex = content.ZIndex + 1,
			Parent = content,
		})
		make("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = dot })
		local mode = label("Mode", content, {
			Font = T.HeadFont,
			Position = UDim2.fromScale(0.12, 0),
			Size = UDim2.fromScale(0.5, 1),
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, 34)
		local timer = label("Timer", content, {
			Font = T.LogoFont,
			Position = UDim2.fromScale(0.6, 0),
			Size = UDim2.fromScale(0.22, 1),
		}, 32)
		cancel = UIKit.slantButton("X", {
			parent = content,
			name = "QueueCancel",
			style = "ghost",
			textSize = 34,
			glyph = false,
			anchor = Vector2.new(1, 0.5),
			position = UDim2.fromScale(1, 0.5),
			size = UDim2.fromScale(0.18, 0.9),
			zIndex = content.ZIndex + 1,
		}, cancelSearch)
		backGlyph = nil
		return function(status, since)
			local line = MenuModels.queueLine(status, since)
			mode.Text = string.upper(line.label)
			timer.Text = line.timer
		end
	end

	local function render()
		local status = ClientState.queue
		root.Visible = status ~= nil
		if status and update then
			update(status, os.clock() - receivedAt)
		end
		if backGlyph then
			backGlyph.Visible = isRoot
		end
	end

	local function build()
		if cancel then
			Focus.unregister(cancel)
		end
		for _, child in root:GetChildren() do
			child:Destroy()
		end
		update = if Layout.mode() == "Phone" then buildPhone() else buildWide()
		render()
	end

	build()
	Layout.Changed:Connect(build)
	Focus.ModeChanged:Connect(render)
	ClientState.QueueChanged:Connect(function()
		receivedAt = os.clock()
		render()
	end)
	-- the timer counts on between the server's updates
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc >= 0.25 and root.Visible and ClientState.phase == "Menu" then
			acc = 0
			render()
		end
	end)

	return {
		root = root,
		cancelButton = function()
			if ClientState.queue and cancel and cancel.Parent then
				return cancel
			end
			return nil
		end,
		setRoot = function(value)
			isRoot = value
			render()
		end,
	}
end

return QueueBanner
