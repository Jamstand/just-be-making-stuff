local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local DataUpdated = ReplicatedStorage.Remotes.DataUpdated
local CoinCollected = ReplicatedStorage.Remotes.CoinCollected
local Notify = ReplicatedStorage.Remotes.Notify
local ClaimDailyReward = ReplicatedStorage.Remotes.ClaimDailyReward

local player = Players.LocalPlayer

local screen = Instance.new("ScreenGui")
screen.Name = "HudGui"
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = true
screen.Parent = player:WaitForChild("PlayerGui")

local function makePill(name: string, color: Color3, order: number): (Frame, TextLabel)
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.Size = UDim2.new(0, 180, 0, 44)
	frame.Position = UDim2.new(0, 20, 0, 20 + (order - 1) * 52)
	frame.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
	frame.BackgroundTransparency = 0.15
	frame.BorderSizePixel = 0
	frame.Parent = screen

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10); corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = color; stroke.Thickness = 2; stroke.Parent = frame

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -16, 1, 0)
	label.Position = UDim2.new(0, 8, 0, 0)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = color
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = name .. ": 0"
	label.Parent = frame
	return frame, label
end

local coinFrame, coinLabel = makePill("Coins", Color3.fromRGB(255, 215, 0), 1)
local gemFrame, gemLabel = makePill("Gems", Color3.fromRGB(120, 230, 255), 2)

local function pulse(frame: Frame)
	local original = frame.Size
	local target = UDim2.new(original.X.Scale, original.X.Offset + 16, original.Y.Scale, original.Y.Offset + 6)
	local tween = TweenService:Create(frame, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, true), { Size = target })
	tween:Play()
end

local function setValues(coins: number, gems: number)
	coinLabel.Text = string.format("Coins: %s", coins)
	gemLabel.Text = string.format("Gems: %s", gems)
end

DataUpdated.OnClientEvent:Connect(function(data)
	setValues(data.Coins or 0, data.Gems or 0)
end)

CoinCollected.OnClientEvent:Connect(function(_tier, _award, gemReward)
	pulse(coinFrame)
	if gemReward and gemReward > 0 then pulse(gemFrame) end
end)

-- Daily reward button
local dailyBtn = Instance.new("TextButton")
dailyBtn.Size = UDim2.new(0, 180, 0, 36)
dailyBtn.Position = UDim2.new(0, 20, 0, 130)
dailyBtn.BackgroundColor3 = Color3.fromRGB(60, 140, 80)
dailyBtn.Font = Enum.Font.GothamBold
dailyBtn.TextScaled = true
dailyBtn.TextColor3 = Color3.new(1, 1, 1)
dailyBtn.Text = "Daily Reward"
dailyBtn.AutoButtonColor = true
dailyBtn.Parent = screen
do
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 8); c.Parent = dailyBtn
end

dailyBtn.MouseButton1Click:Connect(function()
	ClaimDailyReward:InvokeServer()
end)

-- Notifications (toast)
local toast = Instance.new("TextLabel")
toast.Size = UDim2.new(0, 360, 0, 44)
toast.AnchorPoint = Vector2.new(0.5, 0)
toast.Position = UDim2.new(0.5, 0, 0, -60)
toast.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
toast.BackgroundTransparency = 0.1
toast.BorderSizePixel = 0
toast.Font = Enum.Font.GothamBold
toast.TextScaled = true
toast.TextColor3 = Color3.fromRGB(255, 255, 255)
toast.Text = ""
toast.Parent = screen
do
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 8); c.Parent = toast
end

local activeTween
Notify.OnClientEvent:Connect(function(message: string)
	toast.Text = message
	if activeTween then activeTween:Cancel() end
	toast.Position = UDim2.new(0.5, 0, 0, -60)
	local show = TweenService:Create(toast, TweenInfo.new(0.25, Enum.EasingStyle.Quad), { Position = UDim2.new(0.5, 0, 0, 20) })
	show:Play()
	activeTween = show
	task.delay(2.5, function()
		if toast.Text == message then
			local hide = TweenService:Create(toast, TweenInfo.new(0.25, Enum.EasingStyle.Quad), { Position = UDim2.new(0.5, 0, 0, -60) })
			hide:Play()
		end
	end)
end)
