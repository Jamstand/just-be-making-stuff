--[[
    Short messages at the top of the screen (purchases, errors, level ups).
    Shown in the lobby and during matches.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local UIKit = require(script.Parent.UIKit)
local ClientState = require(script.Parent.Parent.ClientState)

local T = UIKit.Theme

local Toasts = {}

local KIND_COLORS = {
	info = T.Teal,
	good = T.Good,
	warn = T.Gold,
	error = T.Danger,
}

local holder = nil

local function show(text, kind)
	if not holder then
		return
	end
	local color = KIND_COLORS[kind] or T.Teal
	local toast = UIKit.panel({
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = T.PanelDark,
		BackgroundTransparency = 0.05,
		Parent = holder,
	})
	toast:FindFirstChildOfClass("UIStroke").Color = color
	UIKit.padding(14, 10).Parent = toast
	local label = UIKit.label(text, 17, {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextXAlignment = Enum.TextXAlignment.Center,
		Font = T.BoldFont,
		Parent = toast,
	})
	task.delay(3.2, function()
		if toast.Parent then
			TweenService:Create(toast, TweenInfo.new(0.3), { BackgroundTransparency = 1 }):Play()
			TweenService:Create(label, TweenInfo.new(0.3), { TextTransparency = 1 }):Play()
			task.wait(0.32)
			toast:Destroy()
		end
	end)
end

function Toasts.init()
	local gui = UIKit.make("ScreenGui", {
		Name = "SkybrawlToasts",
		ResetOnSpawn = false,
		DisplayOrder = 50,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = Players.LocalPlayer:WaitForChild("PlayerGui"),
	})
	holder = UIKit.make("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 64),
		Size = UDim2.new(0.6, 0, 0.5, 0),
		Parent = gui,
	}, {
		UIKit.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Center),
		UIKit.make("UISizeConstraint", { MaxSize = Vector2.new(520, math.huge) }),
	})
	ClientState.Toast:Connect(show)
end

return Toasts
