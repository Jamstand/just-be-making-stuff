--[[
    Top-left HUD: Coins + Gems pills, Daily Reward button, and bottom-center
    toast notifications. Driven by PlayerDataUpdated from the server and
    ShowToast for one-off messages.

    Exposes _G.CoinRush.ClientData so other client scripts (ShopGui) can
    read the latest player data without re-listening to the remote.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local PlayerDataUpdated = Remotes:WaitForChild("PlayerDataUpdated")
local ClaimDailyReward = Remotes:WaitForChild("ClaimDailyReward")
local ShowToast = Remotes:WaitForChild("ShowToast")

_G.CoinRush = _G.CoinRush or {}
local clientUpdated = Instance.new("BindableEvent")
_G.CoinRush.ClientData = {
	data = nil :: any,
	Updated = clientUpdated.Event,
}

-- UI -----------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "CoinRushHud"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

local container = Instance.new("Frame")
container.Name = "TopLeft"
container.AnchorPoint = Vector2.new(0, 0)
container.Position = UDim2.new(0, 16, 0, 16)
container.Size = UDim2.new(0, 220, 0, 160)
container.BackgroundTransparency = 1
container.Parent = gui

local stack = Instance.new("UIListLayout")
stack.FillDirection = Enum.FillDirection.Vertical
stack.Padding = UDim.new(0, 8)
stack.HorizontalAlignment = Enum.HorizontalAlignment.Left
stack.SortOrder = Enum.SortOrder.LayoutOrder
stack.Parent = container

local function makePill(name: string, color: Color3, iconText: string, order: number)
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.Size = UDim2.new(0, 200, 0, 40)
	frame.BackgroundColor3 = Color3.fromRGB(20, 22, 30)
	frame.BackgroundTransparency = 0.15
	frame.BorderSizePixel = 0
	frame.LayoutOrder = order
	frame.Parent = container

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 20)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = 2
	stroke.Transparency = 0.3
	stroke.Parent = frame

	local icon = Instance.new("TextLabel")
	icon.Name = "Icon"
	icon.AnchorPoint = Vector2.new(0, 0.5)
	icon.Position = UDim2.new(0, 12, 0.5, 0)
	icon.Size = UDim2.new(0, 28, 0, 28)
	icon.BackgroundTransparency = 1
	icon.Text = iconText
	icon.TextColor3 = color
	icon.TextSize = 24
	icon.Font = Enum.Font.GothamBold
	icon.Parent = frame

	local value = Instance.new("TextLabel")
	value.Name = "Value"
	value.AnchorPoint = Vector2.new(0, 0.5)
	value.Position = UDim2.new(0, 50, 0.5, 0)
	value.Size = UDim2.new(1, -60, 1, 0)
	value.BackgroundTransparency = 1
	value.Text = "0"
	value.TextColor3 = Color3.fromRGB(245, 245, 250)
	value.TextSize = 22
	value.TextXAlignment = Enum.TextXAlignment.Left
	value.Font = Enum.Font.GothamBold
	value.Parent = frame

	return frame, value
end

local coinsPill, coinsValue = makePill("Coins", Color3.fromRGB(255, 215, 0), "C", 1)
local gemsPill, gemsValue = makePill("Gems", Color3.fromRGB(120, 230, 255), "G", 2)

local dailyButton = Instance.new("TextButton")
dailyButton.Name = "Daily"
dailyButton.Size = UDim2.new(0, 200, 0, 40)
dailyButton.BackgroundColor3 = Color3.fromRGB(80, 130, 220)
dailyButton.BorderSizePixel = 0
dailyButton.Text = "Daily Reward"
dailyButton.TextColor3 = Color3.fromRGB(255, 255, 255)
dailyButton.TextSize = 18
dailyButton.Font = Enum.Font.GothamBold
dailyButton.LayoutOrder = 3
dailyButton.AutoButtonColor = true
dailyButton.Parent = container

local dailyCorner = Instance.new("UICorner")
dailyCorner.CornerRadius = UDim.new(0, 20)
dailyCorner.Parent = dailyButton

-- Toasts -------------------------------------------------------------------

local toastHolder = Instance.new("Frame")
toastHolder.Name = "Toasts"
toastHolder.AnchorPoint = Vector2.new(0.5, 1)
toastHolder.Position = UDim2.new(0.5, 0, 1, -32)
toastHolder.Size = UDim2.new(0, 400, 0, 200)
toastHolder.BackgroundTransparency = 1
toastHolder.Parent = gui

local toastStack = Instance.new("UIListLayout")
toastStack.FillDirection = Enum.FillDirection.Vertical
toastStack.VerticalAlignment = Enum.VerticalAlignment.Bottom
toastStack.HorizontalAlignment = Enum.HorizontalAlignment.Center
toastStack.Padding = UDim.new(0, 6)
toastStack.SortOrder = Enum.SortOrder.LayoutOrder
toastStack.Parent = toastHolder

local toastOrder = 0
local function showToast(message: string)
	toastOrder += 1
	local order = toastOrder
	local toast = Instance.new("TextLabel")
	toast.Name = "Toast"
	toast.Size = UDim2.new(0, 380, 0, 32)
	toast.BackgroundColor3 = Color3.fromRGB(20, 22, 30)
	toast.BackgroundTransparency = 0.1
	toast.BorderSizePixel = 0
	toast.Text = message
	toast.TextColor3 = Color3.fromRGB(245, 245, 250)
	toast.TextSize = 16
	toast.Font = Enum.Font.GothamMedium
	toast.LayoutOrder = order
	toast.Parent = toastHolder

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = toast

	toast.BackgroundTransparency = 1
	toast.TextTransparency = 1
	TweenService:Create(toast, TweenInfo.new(0.2), { BackgroundTransparency = 0.1, TextTransparency = 0 }):Play()
	task.delay(3, function()
		local tween = TweenService:Create(toast, TweenInfo.new(0.4), { BackgroundTransparency = 1, TextTransparency = 1 })
		tween:Play()
		tween.Completed:Wait()
		toast:Destroy()
	end)
end

ShowToast.OnClientEvent:Connect(function(msg)
	if type(msg) == "string" then
		showToast(msg)
	end
end)

-- Value updates ------------------------------------------------------------

local function pulse(frame: Frame)
	local original = frame.Size
	local big = UDim2.new(original.X.Scale, original.X.Offset + 6, original.Y.Scale, original.Y.Offset + 6)
	TweenService:Create(frame, TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = big }):Play()
	task.delay(0.1, function()
		TweenService:Create(frame, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = original }):Play()
	end)
end

local lastCoins, lastGems = -1, -1

local function applyData(data)
	if type(data) ~= "table" then return end
	_G.CoinRush.ClientData.data = data

	local newCoins = math.floor(data.Coins or 0)
	if newCoins ~= lastCoins then
		coinsValue.Text = tostring(newCoins)
		if lastCoins >= 0 and newCoins > lastCoins then
			pulse(coinsPill)
		end
		lastCoins = newCoins
	end

	local newGems = math.floor(data.Gems or 0)
	if newGems ~= lastGems then
		gemsValue.Text = tostring(newGems)
		if lastGems >= 0 and newGems > lastGems then
			pulse(gemsPill)
		end
		lastGems = newGems
	end

	clientUpdated:Fire(data)
end

PlayerDataUpdated.OnClientEvent:Connect(applyData)

-- Daily reward button: enable/countdown -----------------------------------

local function formatRemaining(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local hours = math.floor(seconds / 3600)
	local minutes = math.floor((seconds % 3600) / 60)
	if hours > 0 then
		return ("%dh %dm"):format(hours, minutes)
	end
	return ("%dm"):format(minutes)
end

local function refreshDailyButton()
	local data = _G.CoinRush.ClientData.data
	if not data then
		dailyButton.Text = "Daily Reward"
		dailyButton.BackgroundColor3 = Color3.fromRGB(80, 130, 220)
		return
	end
	local now = os.time()
	local elapsed = now - (data.LastDailyClaim or 0)
	local remaining = GameConfig.DailyCooldownSeconds - elapsed
	if remaining <= 0 then
		dailyButton.Text = "Daily Reward"
		dailyButton.BackgroundColor3 = Color3.fromRGB(80, 130, 220)
	else
		dailyButton.Text = "Daily in " .. formatRemaining(remaining)
		dailyButton.BackgroundColor3 = Color3.fromRGB(70, 75, 95)
	end
end

task.spawn(function()
	while true do
		refreshDailyButton()
		task.wait(15)
	end
end)

clientUpdated.Event:Connect(refreshDailyButton)

dailyButton.MouseButton1Click:Connect(function()
	local ok, result = pcall(function()
		return ClaimDailyReward:InvokeServer()
	end)
	if not ok or not result then
		showToast("Couldn't reach server")
		return
	end
	if not result.ok then
		if result.reason == "Cooldown" then
			showToast("Come back in " .. formatRemaining(result.remaining or 0))
		else
			showToast(result.reason or "Failed")
		end
	end
	refreshDailyButton()
end)
