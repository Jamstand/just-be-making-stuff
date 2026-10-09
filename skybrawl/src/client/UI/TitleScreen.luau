--[[
    The title screen (menus design 5.6; mockup a), shown once per join.

    SkybrawlTitleBack (DisplayOrder 39, full bleed): the menus' painted sky
    at 0.42 brightness, the six legends in three depth layers (back: Moss
    and Vex; middle: Yuki and Brann; front: Kestrel and Sol, each pair a
    little brighter and bigger, the left three facing right, the right three
    facing left, feet on the bottom edge) and a dark fade at the bottom.

    SkybrawlTitle (40, DeviceSafeInsets): the SKYBRAWL logo (LuckiestGuy 250
    through Layout.bindText, gold gradient, thick black outline, a black
    drop copy, tilted -4 degrees over a red banner with a black "PLATFORM
    FIGHTER" label; kept below the Roblox top bar), the PRESS ANY BUTTON bar
    (drawn as a focused slant button, pulsing), the input icons row and the
    corner labels (season and version, legends and maps).

    Any keyboard key or gamepad button that isn't game-processed (not the
    thumbsticks), or a click / tap anywhere (a full-screen transparent
    button: clicks and taps on GUI are game-processed, so they arrive
    through it), dismisses it after a 0.4 s grace (a key held through
    loading doesn't skip it): MenuConfirm and a 0.35 s fade; the phase
    becomes "Menu" deferred, after every handler of that input has run, so
    the menu shows under the fading title (and Focus also ignores the key
    in the frame the menu's layer appears, so it can't press ONLINE PLAY);
    the views are destroyed when the fade ends.

    On phones the hero text (logo, its outline and drop, PLATFORM FIGHTER,
    PRESS ANY BUTTON) skips the 1.6x phone text factor, so the logo keeps
    mockup a's proportions inside its holder.
]]

local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Client = script.Parent.Parent
local ClientState = require(Client:WaitForChild("ClientState"))
local Sound = require(Client:WaitForChild("Controllers"):WaitForChild("Sound"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))
local Layout = require(script.Parent:WaitForChild("Layout"))
local LegendView = require(script.Parent:WaitForChild("LegendView"))
local MenuShell = require(script.Parent:WaitForChild("MenuShell"))
local MenuModels = require(script.Parent:WaitForChild("MenuModels"))

local T = UIKit.Theme
local make = UIKit.make

local TitleScreen = {}

local GRACE = 0.4
local FADE = 0.35
local PULSE = 0.8

-- Back to front: { brightness, { legend, x, height, facing } x 2 }.
local LAYERS = {
	{ 0.72, { { "Moss", 0.07, 0.76, "Right" }, { "Vex", 0.93, 0.76, "Left" } } },
	{ 0.85, { { "Yuki", 0.21, 0.81, "Right" }, { "Brann", 0.79, 0.81, "Left" } } },
	{ 1, { { "Kestrel", 0.37, 0.88, "Right" }, { "Sol", 0.63, 0.88, "Left" } } },
}

local INPUTS = { "ANY KEY", "CLICK", "TAP", "ANY BUTTON" }

-- Design px for the hero text: on phones without the 1.6x text factor (it would overflow the logo's holder).
local function hero(n)
	return if Layout.mode() == "Phone" then n / Layout.PHONE_TEXT else n
end

local shownOnce = false

-- Fades every visible part under `root` out over FADE seconds (no CanvasGroup: the 3D views stay crisp).
local function fadeOut(root)
	local info = TweenInfo.new(FADE)
	for _, obj in root:GetDescendants() do
		local goal = {}
		if obj:IsA("GuiObject") and obj.BackgroundTransparency < 1 then
			goal.BackgroundTransparency = 1
		end
		if obj:IsA("ImageLabel") or obj:IsA("ViewportFrame") then
			goal.ImageTransparency = 1
		elseif obj:IsA("TextLabel") then
			goal.TextTransparency = 1
		elseif obj:IsA("UIStroke") then
			goal.Transparency = 1
		end
		if next(goal) then
			TweenService:Create(obj, info, goal):Play()
		end
	end
end

local function label(name, parent, props, size)
	local obj = make("TextLabel", {
		Name = name,
		BackgroundTransparency = 1,
		Text = "",
		Font = T.BoldFont,
		TextColor3 = T.Muted,
		ZIndex = parent.ZIndex + 1,
		Parent = parent,
	})
	for key, value in props do
		obj[key] = value
	end
	Layout.bindText(obj, size)
	return obj
end

local function buildBack(gui)
	local root = make("Frame", {
		Name = "Back",
		BackgroundColor3 = T.Backdrop,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = gui,
	})
	MenuShell.buildSky(root, 0.42)
	local groups = {}
	for i, layer in LAYERS do
		local entries = {}
		for _, item in layer[2] do
			table.insert(entries, { spec = { legend = item[1] }, x = item[2], height = item[3], facing = item[4] })
		end
		table.insert(groups, LegendView.group(root, { brightness = layer[1], zIndex = 2 + i }, entries))
	end
	local fade = make("Frame", {
		Name = "BottomFade",
		BackgroundColor3 = Color3.new(0, 0, 0),
		BorderSizePixel = 0,
		Position = UDim2.fromScale(0, 0.62),
		Size = UDim2.fromScale(1, 0.38),
		ZIndex = 10,
		Parent = root,
	})
	make("UIGradient", {
		Rotation = 90,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.55, 0.55),
			NumberSequenceKeypoint.new(1, 0.1),
		}),
		Parent = fade,
	})
	return root, groups
end

local function buildLogo(parent)
	-- the banner, logo and label are plain rotated decorations (nothing clipped under them)
	local holder = make("Frame", {
		Name = "LogoHolder",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromScale(0.62, 0.33),
		ZIndex = 2,
		Parent = parent,
	})
	Layout.clearTop(holder, UDim2.fromScale(0.5, 0.09))
	local banner = make("Frame", {
		Name = "Banner",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.52, 0.8),
		Size = UDim2.new(0.49 / 0.62, 0, 0.11 / 0.33, 0),
		Rotation = -4,
		ZIndex = 2,
		Parent = holder,
	})
	make("UIGradient", { Color = ColorSequence.new(T.RedLight, T.RedDark), Rotation = 90, Parent = banner })
	Layout.bindStroke(make("UIStroke", { Color = T.Outline, Parent = banner }), hero(6))
	local tag = make("Frame", {
		Name = "Platform",
		BackgroundColor3 = Color3.new(0, 0, 0),
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(0.93, 0.98),
		Size = UDim2.fromScale(0.36, 0.16),
		Rotation = -4,
		ZIndex = 4,
		Parent = holder,
	})
	label("Text", tag, {
		Text = "PLATFORM FIGHTER",
		Font = T.HeadFont,
		TextColor3 = T.Text,
		Size = UDim2.fromScale(1, 1),
	}, hero(46))
	local function logoText(name, color, offset, zIndex)
		local text = make("TextLabel", {
			Name = name,
			BackgroundTransparency = 1,
			Text = "SKYBRAWL",
			Font = T.LogoFont,
			TextColor3 = color,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0.42, offset),
			Size = UDim2.fromScale(1, 0.72),
			Rotation = -4,
			ZIndex = zIndex,
			Parent = holder,
		})
		Layout.bindText(text, hero(250))
		Layout.bindStroke(make("UIStroke", { Color = T.Outline, Parent = text }), hero(17))
		return text
	end
	logoText("Drop", Color3.new(0, 0, 0), Layout.px(hero(10)), 3)
	local logo = logoText("Logo", Color3.new(1, 1, 1), 0, 5)
	make("UIGradient", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, T.LogoGradient[1]),
			ColorSequenceKeypoint.new(0.5, T.LogoGradient[2]),
			ColorSequenceKeypoint.new(1, T.LogoGradient[3]),
		}),
		Rotation = 90,
		Parent = logo,
	})
	return holder
end

-- The PRESS ANY BUTTON bar: a slant button drawn focused (red, white ring), pulsing as a whole.
local function buildPrompt(parent)
	local group = make("CanvasGroup", {
		Name = "Prompt",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.83),
		-- padded so the outline and shadow aren't clipped by the group
		Size = UDim2.fromScale(0.36 * 1.2, 0.078 * 1.8),
		ZIndex = 5,
		Parent = parent,
	})
	-- the focused look: red, a white ring inside the black outline (no shadow: its group would nest in this one)
	local bar = UIKit.slantFrame({
		parent = group,
		gradient = { T.RedLight, T.RedDark },
		outline = 4,
		ring = 4,
		anchor = Vector2.new(0.5, 0.5),
		position = UDim2.fromScale(0.5, 0.5),
		size = UDim2.fromScale(1 / 1.2, 1 / 1.8),
		zIndex = 5,
	})
	label("Text", bar.Content, {
		Text = "PRESS ANY BUTTON",
		Font = T.HeadFont,
		TextColor3 = T.Text,
		Size = UDim2.fromScale(1, 1),
		ZIndex = bar.Content.ZIndex + 2,
	}, hero(60))
	local tween = TweenService:Create(
		group,
		TweenInfo.new(PULSE, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ GroupTransparency = 0.15 }
	)
	tween:Play()
	return group, tween
end

local function buildFooter(parent)
	local row = make("Frame", {
		Name = "Inputs",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.94),
		Size = UDim2.fromScale(0.5, 0.035),
		ZIndex = 5,
		Parent = parent,
	})
	Layout.bindListPadding(
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = row,
		}),
		36
	)
	for i, text in INPUTS do
		local item = make("Frame", {
			Name = "Input" .. i,
			BackgroundTransparency = 1,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromScale(0, 1),
			LayoutOrder = i,
			ZIndex = 5,
			Parent = row,
		})
		Layout.bindListPadding(
			make("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Parent = item,
			}),
			10
		)
		-- a small outlined box standing in for the device icon
		local box = make("Frame", {
			Name = "Icon",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(0.75, 0.75),
			SizeConstraint = Enum.SizeConstraint.RelativeYY,
			LayoutOrder = 1,
			ZIndex = 5,
			Parent = item,
		})
		make("UICorner", { CornerRadius = UDim.new(0.25, 0), Parent = box })
		Layout.bindStroke(make("UIStroke", { Color = T.Muted, Parent = box }), 2)
		label("Label", item, {
			Text = text,
			Font = T.BlackFont,
			TextXAlignment = Enum.TextXAlignment.Left,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromScale(0, 1),
			LayoutOrder = 2,
		}, 22)
	end
	local left, right = MenuModels.titleLabels(ClientState.serverNow())
	label("Season", parent, {
		Text = left,
		TextXAlignment = Enum.TextXAlignment.Left,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0.02, 0.955),
		Size = UDim2.fromScale(0.3, 0.035),
	}, 22)
	label("Count", parent, {
		Text = right,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(0.98, 0.955),
		Size = UDim2.fromScale(0.3, 0.035),
	}, 22)
end

-- Shows the title screen (once per join); any input moves the phase to "Menu".
function TitleScreen.show()
	if shownOnce then
		ClientState.setPhase("Menu")
		return
	end
	shownOnce = true
	local backGui = Layout.screenGui("SkybrawlTitleBack", 39, "Full")
	local gui = Layout.screenGui("SkybrawlTitle", 40, "Safe")
	local back, groups = buildBack(backGui)
	local front = make("Frame", {
		Name = "Front",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = gui,
	})
	buildLogo(front)
	local prompt, pulse = buildPrompt(front)
	buildFooter(front)
	local catcher = make("TextButton", {
		Name = "AnyClick",
		BackgroundTransparency = 1,
		Text = "",
		Size = UDim2.fromScale(1, 1),
		ZIndex = 50,
		Parent = gui,
	})

	local shownAt = os.clock()
	local dismissed = false
	local connections = {}

	local function dismiss()
		if dismissed or os.clock() - shownAt < GRACE then
			return
		end
		dismissed = true
		for _, conn in connections do
			conn:Disconnect()
		end
		Sound.play("MenuConfirm", 0.5)
		pulse:Cancel()
		fadeOut(back)
		fadeOut(front)
		TweenService:Create(prompt, TweenInfo.new(FADE), { GroupTransparency = 1 }):Play()
		task.delay(FADE, function()
			for _, group in groups do
				group.destroy()
			end
			backGui:Destroy()
			gui:Destroy()
		end)
		-- after every other handler of this input (Focus's too), so the key can't also act in the menu
		task.defer(ClientState.setPhase, "Menu")
	end

	table.insert(connections, catcher.Activated:Connect(dismiss))
	table.insert(
		connections,
		UserInputService.InputBegan:Connect(function(input, gameProcessed)
			if gameProcessed then
				return
			end
			local inputType = input.UserInputType
			local keyboard = inputType == Enum.UserInputType.Keyboard
			local gamepad = string.sub(inputType.Name, 1, 7) == "Gamepad"
			local stick = input.KeyCode == Enum.KeyCode.Thumbstick1 or input.KeyCode == Enum.KeyCode.Thumbstick2
			if (keyboard or gamepad) and not stick then
				dismiss()
			end
		end)
	)
end

return TitleScreen
