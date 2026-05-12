local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local ShopCatalog = require(ReplicatedStorage.Shared.ShopCatalog)
local DataUpdated = ReplicatedStorage.Remotes.DataUpdated
local PurchaseUpgrade = ReplicatedStorage.Remotes.PurchaseUpgrade
local PromptProduct = ReplicatedStorage.Remotes.PromptProduct
local PromptGamePass = ReplicatedStorage.Remotes.PromptGamePass

local player = Players.LocalPlayer

local latestData = { Coins = 0, Gems = 0, Upgrades = {}, OwnedPasses = {} }
DataUpdated.OnClientEvent:Connect(function(data) latestData = data end)

local screen = Instance.new("ScreenGui")
screen.Name = "ShopGui"
screen.ResetOnSpawn = false
screen.Enabled = false
screen.IgnoreGuiInset = true
screen.Parent = player:WaitForChild("PlayerGui")

local backdrop = Instance.new("Frame")
backdrop.Size = UDim2.new(1, 0, 1, 0)
backdrop.BackgroundColor3 = Color3.new(0, 0, 0)
backdrop.BackgroundTransparency = 0.5
backdrop.BorderSizePixel = 0
backdrop.Parent = screen

local panel = Instance.new("Frame")
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.new(0.5, 0, 0.5, 0)
panel.Size = UDim2.new(0, 720, 0, 520)
panel.BackgroundColor3 = Color3.fromRGB(25, 25, 35)
panel.BorderSizePixel = 0
panel.Parent = screen
do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 14); c.Parent = panel end

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 50)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBlack
title.TextScaled = true
title.TextColor3 = Color3.fromRGB(255, 215, 0)
title.Text = "Shop"
title.Parent = panel

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 36, 0, 36)
closeBtn.Position = UDim2.new(1, -46, 0, 10)
closeBtn.BackgroundColor3 = Color3.fromRGB(160, 60, 60)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextScaled = true
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.Text = "X"
closeBtn.Parent = panel
do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 8); c.Parent = closeBtn end
closeBtn.MouseButton1Click:Connect(function() screen.Enabled = false end)

-- Tab bar
local tabBar = Instance.new("Frame")
tabBar.Size = UDim2.new(1, -40, 0, 36)
tabBar.Position = UDim2.new(0, 20, 0, 60)
tabBar.BackgroundTransparency = 1
tabBar.Parent = panel

local content = Instance.new("ScrollingFrame")
content.Size = UDim2.new(1, -40, 1, -120)
content.Position = UDim2.new(0, 20, 0, 110)
content.BackgroundTransparency = 1
content.BorderSizePixel = 0
content.ScrollBarThickness = 6
content.CanvasSize = UDim2.new(0, 0, 0, 0)
content.AutomaticCanvasSize = Enum.AutomaticSize.Y
content.Parent = panel

local list = Instance.new("UIListLayout")
list.Padding = UDim.new(0, 8)
list.SortOrder = Enum.SortOrder.LayoutOrder
list.Parent = content

local function clearContent()
	for _, child in content:GetChildren() do
		if child:IsA("Frame") then child:Destroy() end
	end
end

local function makeRow(titleText: string, subText: string, priceText: string, action: () -> (), disabled: boolean?)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, -10, 0, 70)
	row.BackgroundColor3 = Color3.fromRGB(40, 40, 55)
	row.BorderSizePixel = 0
	row.Parent = content
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 8); c.Parent = row

	local titleLbl = Instance.new("TextLabel")
	titleLbl.Size = UDim2.new(0.55, 0, 0.5, 0)
	titleLbl.Position = UDim2.new(0, 12, 0, 6)
	titleLbl.BackgroundTransparency = 1
	titleLbl.Font = Enum.Font.GothamBold
	titleLbl.TextScaled = true
	titleLbl.TextXAlignment = Enum.TextXAlignment.Left
	titleLbl.TextColor3 = Color3.new(1, 1, 1)
	titleLbl.Text = titleText
	titleLbl.Parent = row

	local subLbl = Instance.new("TextLabel")
	subLbl.Size = UDim2.new(0.55, 0, 0.4, 0)
	subLbl.Position = UDim2.new(0, 12, 0.5, 0)
	subLbl.BackgroundTransparency = 1
	subLbl.Font = Enum.Font.Gotham
	subLbl.TextScaled = true
	subLbl.TextXAlignment = Enum.TextXAlignment.Left
	subLbl.TextColor3 = Color3.fromRGB(200, 200, 200)
	subLbl.Text = subText
	subLbl.Parent = row

	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(0, 180, 0, 50)
	btn.AnchorPoint = Vector2.new(1, 0.5)
	btn.Position = UDim2.new(1, -12, 0.5, 0)
	btn.BackgroundColor3 = disabled and Color3.fromRGB(80, 80, 90) or Color3.fromRGB(60, 140, 200)
	btn.Font = Enum.Font.GothamBold
	btn.TextScaled = true
	btn.TextColor3 = Color3.new(1, 1, 1)
	btn.Text = priceText
	btn.AutoButtonColor = not disabled
	btn.Active = not disabled
	btn.Parent = row
	local bc = Instance.new("UICorner"); bc.CornerRadius = UDim.new(0, 8); bc.Parent = btn
	if not disabled then btn.MouseButton1Click:Connect(action) end
	return row
end

local function renderUpgrades()
	clearContent()
	for upgradeName, entry in ShopCatalog.Upgrades do
		local cap = GameConfig.Upgrades[upgradeName]
		local currentTier = (latestData.Upgrades and latestData.Upgrades[upgradeName]) or 0
		local maxed = currentTier >= cap.MaxTier
		local priceText, disabled
		if maxed then
			priceText, disabled = "MAX", true
		else
			local cost = entry.Costs[currentTier + 1]
			priceText = string.format("%s %s", cost, entry.CurrencyType)
			disabled = false
		end
		makeRow(
			string.format("%s [%d/%d]", entry.DisplayName, currentTier, cap.MaxTier),
			entry.Description,
			priceText,
			function() PurchaseUpgrade:InvokeServer(upgradeName) end,
			disabled
		)
	end
end

local function renderGems()
	clearContent()
	for key, info in GameConfig.GemProducts do
		local disabled = info.ProductId == 0
		local priceText = disabled and "Not set" or string.format("R$ %d", info.RobuxPrice)
		makeRow(
			string.format("%s Pack", key),
			string.format("%d Gems", info.Gems),
			priceText,
			function() PromptProduct:FireServer(key) end,
			disabled
		)
	end
end

local function renderPasses()
	clearContent()
	for key, info in GameConfig.GamePasses do
		local owned = latestData.OwnedPasses and latestData.OwnedPasses[key]
		local disabled = owned or info.GamePassId == 0
		local priceText
		if owned then priceText = "OWNED"
		elseif info.GamePassId == 0 then priceText = "Not set"
		else priceText = "Buy"
		end
		local desc
		if key == "DoubleCoins" then desc = "Permanently doubles all coin earnings"
		elseif key == "VIP" then desc = "Trail + 1.5x coin multiplier"
		elseif key == "AutoCollect" then desc = "Always-on coin magnet"
		else desc = "" end
		makeRow(key, desc, priceText, function() PromptGamePass:FireServer(key) end, disabled)
	end
end

local tabs = { { name = "Upgrades", render = renderUpgrades }, { name = "Gems", render = renderGems }, { name = "Passes", render = renderPasses } }

local tabButtons = {}
local currentRender = renderUpgrades

local function setTab(index: number)
	currentRender = tabs[index].render
	for i, btn in tabButtons do
		btn.BackgroundColor3 = (i == index) and Color3.fromRGB(80, 140, 200) or Color3.fromRGB(50, 50, 65)
	end
	currentRender()
end

for i, tab in tabs do
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(0, 140, 1, 0)
	btn.Position = UDim2.new(0, (i - 1) * 150, 0, 0)
	btn.BackgroundColor3 = Color3.fromRGB(50, 50, 65)
	btn.Font = Enum.Font.GothamBold
	btn.TextScaled = true
	btn.TextColor3 = Color3.new(1, 1, 1)
	btn.Text = tab.name
	btn.Parent = tabBar
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = btn
	tabButtons[i] = btn
	btn.MouseButton1Click:Connect(function() setTab(i) end)
end

setTab(1)

-- Re-render the active tab when data updates (prices/states change)
DataUpdated.OnClientEvent:Connect(function() currentRender() end)

-- Shop opens by touching the magenta beacon, or pressing E.
local UserInputService = game:GetService("UserInputService")
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == Enum.KeyCode.E then screen.Enabled = not screen.Enabled end
end)

local function bindBeacon()
	local beacon = Workspace:WaitForChild("ShopBeacon", 10)
	if not beacon then return end
	beacon.Touched:Connect(function(hit)
		local character = hit:FindFirstAncestorOfClass("Model")
		if character and character == player.Character then
			screen.Enabled = true
		end
	end)
end
task.spawn(bindBeacon)
