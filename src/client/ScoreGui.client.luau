local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local CoinCollected = ReplicatedStorage.Remotes.CoinCollected
local player = Players.LocalPlayer

local screen = Instance.new("ScreenGui")
screen.Name = "ScoreGui"
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = true
screen.Parent = player:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 220, 0, 70)
frame.Position = UDim2.new(0, 20, 0, 20)
frame.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
frame.BackgroundTransparency = 0.2
frame.BorderSizePixel = 0
frame.Parent = screen

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 12)
corner.Parent = frame

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(255, 215, 0)
stroke.Thickness = 2
stroke.Parent = frame

local label = Instance.new("TextLabel")
label.Size = UDim2.new(1, 0, 1, 0)
label.BackgroundTransparency = 1
label.Font = Enum.Font.GothamBold
label.TextScaled = true
label.TextColor3 = Color3.fromRGB(255, 215, 0)
label.Text = "Coins: 0"
label.Parent = frame

local function setScore(value: number)
	label.Text = string.format("Coins: %d", value)
	local pulse = TweenService:Create(
		frame,
		TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, true),
		{ Size = UDim2.new(0, 240, 0, 78) }
	)
	pulse:Play()
end

CoinCollected.OnClientEvent:Connect(setScore)

local function bindLeaderstats()
	local leaderstats = player:WaitForChild("leaderstats", 10)
	if not leaderstats then return end
	local coins = leaderstats:WaitForChild("Coins", 10)
	if not coins then return end
	setScore(coins.Value)
	coins:GetPropertyChangedSignal("Value"):Connect(function()
		setScore(coins.Value)
	end)
end

task.spawn(bindLeaderstats)
