--[[
    On-screen controls for phones and tablets during a match:
    a floating joystick on the left half of the screen and five action
    buttons on the right (Light, Heavy, Jump, Dodge, Throw).
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local UIKit = require(script.Parent.UIKit)
local Controllers = script.Parent.Parent:WaitForChild("Controllers")
local Input = require(Controllers.Input)
local Settings = require(Controllers.Settings)

local T = UIKit.Theme
local make = UIKit.make

local MobileControls = {}

local gui = nil
local connections = {}
local JOYSTICK_RADIUS = 70

local BUTTONS = {
	-- action, label, position (from bottom-right), size, color
	{ "Light", "LIGHT", Vector2.new(-150, -70), 92, T.Gold },
	{ "Heavy", "HEAVY", Vector2.new(-60, -150), 92, T.Danger },
	{ "Jump", "JUMP", Vector2.new(-60, -50), 76, T.Teal },
	{ "Dodge", "DODGE", Vector2.new(-240, -50), 66, T.PanelLight },
	{ "Throw", "THROW", Vector2.new(-150, -190), 62, T.PanelLight },
}

local function buildJoystick(parent)
	local area = make("Frame", {
		Name = "JoystickArea",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(0.45, 0.75),
		Position = UDim2.fromScale(0, 0.25),
		Active = true,
		Parent = parent,
	})
	local base = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(JOYSTICK_RADIUS * 2, JOYSTICK_RADIUS * 2),
		Position = UDim2.new(0, 130, 1, -130),
		BackgroundColor3 = T.PanelDark,
		BackgroundTransparency = 0.45,
		Parent = area,
	}, { UIKit.corner(JOYSTICK_RADIUS), UIKit.stroke(T.Stroke, 2, 0.3) })
	local knob = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(60, 60),
		Position = UDim2.fromScale(0.5, 0.5),
		BackgroundColor3 = T.Text,
		BackgroundTransparency = 0.2,
		Parent = base,
	}, { UIKit.corner(30) })

	local activeInput = nil
	local center = Vector2.zero
	local restPosition = base.Position

	local function release()
		activeInput = nil
		Input.mobile.moveX = 0
		Input.mobile.moveY = 0
		knob.Position = UDim2.fromScale(0.5, 0.5)
		base.Position = restPosition
	end

	area.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.Touch or activeInput then
			return
		end
		activeInput = input
		local pos = Vector2.new(input.Position.X, input.Position.Y)
		center = pos
		local areaPos = area.AbsolutePosition
		base.Position = UDim2.fromOffset(pos.X - areaPos.X, pos.Y - areaPos.Y)
	end)
	table.insert(connections, UserInputService.TouchMoved:Connect(function(input)
		if input ~= activeInput then
			return
		end
		local delta = Vector2.new(input.Position.X, input.Position.Y) - center
		if delta.Magnitude > JOYSTICK_RADIUS then
			delta = delta.Unit * JOYSTICK_RADIUS
		end
		knob.Position = UDim2.new(0.5, delta.X, 0.5, delta.Y)
		local x = delta.X / JOYSTICK_RADIUS
		local y = -delta.Y / JOYSTICK_RADIUS
		Input.mobile.moveX = math.abs(x) > 0.25 and x or 0
		Input.mobile.moveY = math.abs(y) > 0.35 and y or 0
	end))
	table.insert(connections, UserInputService.TouchEnded:Connect(function(input)
		if input == activeInput then
			release()
		end
	end))
	return release
end

local function buildButtons(parent)
	local holder = make("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -10, 1, -10),
		Size = UDim2.fromOffset(1, 1),
		Parent = parent,
	})
	local scale = make("UIScale", { Scale = Settings.get("MobileButtonScale") or 1, Parent = holder })
	for _, spec in BUTTONS do
		local action, label, offset, size, color = spec[1], spec[2], spec[3], spec[4], spec[5]
		local button = make("TextButton", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(offset.X, offset.Y),
			Size = UDim2.fromOffset(size, size),
			BackgroundColor3 = color,
			BackgroundTransparency = 0.25,
			Text = label,
			Font = T.HeadFont,
			TextSize = math.floor(size / 5),
			TextColor3 = Color3.new(1, 1, 1),
			TextStrokeTransparency = 0.4,
			AutoButtonColor = false,
			Parent = holder,
		}, { UIKit.corner(size // 2), UIKit.stroke(Color3.new(1, 1, 1), 2, 0.5) })
		button.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
				Input.mobile.held[action] = true
				Input.pressMobile(action)
				button.BackgroundTransparency = 0
			end
		end)
		button.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
				Input.mobile.held[action] = false
				button.BackgroundTransparency = 0.25
			end
		end)
	end
	table.insert(connections, Settings.Changed:Connect(function(key, value)
		if key == "MobileButtonScale" then
			scale.Scale = value
		end
	end))
end

function MobileControls.show()
	MobileControls.hide()
	gui = make("ScreenGui", {
		Name = "SkybrawlTouch",
		ResetOnSpawn = false,
		DisplayOrder = 12,
		Parent = Players.LocalPlayer:WaitForChild("PlayerGui"),
	})
	buildJoystick(gui)
	buildButtons(gui)
end

function MobileControls.hide()
	for _, connection in connections do
		connection:Disconnect()
	end
	connections = {}
	if gui then
		gui:Destroy()
		gui = nil
	end
	Input.mobile.moveX = 0
	Input.mobile.moveY = 0
	Input.mobile.held = {}
end

function MobileControls.init() end

return MobileControls
