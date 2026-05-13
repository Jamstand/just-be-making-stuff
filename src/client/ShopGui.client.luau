--[[
    Tabbed shop UI (Upgrades / Gems / Passes). Opens when the player walks
    within GameConfig.ShopOpenRadius of the ShopBeacon, or when E is pressed
    while nearby. Closes when the player walks further away or clicks X.

    Upgrades: client invokes PurchaseUpgrade (RemoteFunction) -> server
    validates currency, debits, advances tier.
    Gems: client fires PromptGemProduct -> server opens Robux prompt ->
    ProcessReceipt grants gems.
    Passes: client fires PromptGamePass -> server opens prompt -> ownership
    is reconciled on PromptGamePassPurchaseFinished.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local PlayerDataUpdated = Remotes:WaitForChild("PlayerDataUpdated")
local PurchaseUpgrade = Remotes:WaitForChild("PurchaseUpgrade")
local PromptGemProduct = Remotes:WaitForChild("PromptGemProduct")
local PromptGamePass = Remotes:WaitForChild("PromptGamePass")

_G.CoinRush = _G.CoinRush or {}

local latestData: any = nil

-- Build the UI -------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "CoinRushShop"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.IgnoreGuiInset = true
gui.Enabled = false
gui.Parent = playerGui

local dim = Instance.new("Frame")
dim.Name = "Dim"
dim.Size = UDim2.fromScale(1, 1)
dim.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
dim.BackgroundTransparency = 0.5
dim.BorderSizePixel = 0
dim.Parent = gui

local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.5)
panel.Size = UDim2.new(0, 540, 0, 460)
panel.BackgroundColor3 = Color3.fromRGB(28, 30, 40)
panel.BorderSizePixel = 0
panel.Parent = gui

local panelCorner = Instance.new("UICorner")
panelCorner.CornerRadius = UDim.new(0, 14)
panelCorner.Parent = panel

local panelStroke = Instance.new("UIStroke")
panelStroke.Color = Color3.fromRGB(80, 90, 120)
panelStroke.Thickness = 2
panelStroke.Parent = panel

-- Tab bar
local tabBar = Instance.new("Frame")
tabBar.Name = "TabBar"
tabBar.Size = UDim2.new(1, -16, 0, 44)
tabBar.Position = UDim2.new(0, 8, 0, 8)
tabBar.BackgroundTransparency = 1
tabBar.Parent = panel

local tabLayout = Instance.new("UIListLayout")
tabLayout.FillDirection = Enum.FillDirection.Horizontal
tabLayout.Padding = UDim.new(0, 8)
tabLayout.VerticalAlignment = Enum.VerticalAlignment.Center
tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
tabLayout.Parent = tabBar

local closeButton = Instance.new("TextButton")
closeButton.Name = "Close"
closeButton.AnchorPoint = Vector2.new(1, 0.5)
closeButton.Position = UDim2.new(1, -8, 0.5, 0)
closeButton.Size = UDim2.new(0, 32, 0, 32)
closeButton.BackgroundColor3 = Color3.fromRGB(60, 65, 80)
closeButton.BorderSizePixel = 0
closeButton.Text = "X"
closeButton.TextColor3 = Color3.fromRGB(245, 245, 250)
closeButton.TextSize = 18
closeButton.Font = Enum.Font.GothamBold
closeButton.Parent = tabBar
local closeCorner = Instance.new("UICorner")
closeCorner.CornerRadius = UDim.new(0, 8)
closeCorner.Parent = closeButton

-- Content area (one ScrollingFrame per tab; only one visible)
local contentHolder = Instance.new("Frame")
contentHolder.Name = "Content"
contentHolder.Position = UDim2.new(0, 8, 0, 60)
contentHolder.Size = UDim2.new(1, -16, 1, -68)
contentHolder.BackgroundTransparency = 1
contentHolder.Parent = panel

local currentTab = "Upgrades"
local tabButtons: { [string]: TextButton } = {}
local tabFrames: { [string]: ScrollingFrame } = {}

local function makeTabFrame(name: string): ScrollingFrame
	local frame = Instance.new("ScrollingFrame")
	frame.Name = name
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromRGB(20, 22, 30)
	frame.BackgroundTransparency = 0.4
	frame.BorderSizePixel = 0
	frame.ScrollBarThickness = 6
	frame.CanvasSize = UDim2.new(0, 0, 0, 0)
	frame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	frame.Visible = false
	frame.Parent = contentHolder

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = frame

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 8)
	pad.PaddingBottom = UDim.new(0, 8)
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.Parent = frame

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = frame

	return frame
end

local function setActiveTab(name: string)
	currentTab = name
	for tabName, button in tabButtons do
		local active = tabName == name
		button.BackgroundColor3 = active and Color3.fromRGB(80, 130, 220) or Color3.fromRGB(50, 55, 70)
	end
	for tabName, frame in tabFrames do
		frame.Visible = tabName == name
	end
end

local function makeTabButton(name: string, order: number)
	local button = Instance.new("TextButton")
	button.Name = name .. "Tab"
	button.Size = UDim2.new(0, 110, 1, 0)
	button.BackgroundColor3 = Color3.fromRGB(50, 55, 70)
	button.BorderSizePixel = 0
	button.Text = name
	button.TextColor3 = Color3.fromRGB(245, 245, 250)
	button.TextSize = 16
	button.Font = Enum.Font.GothamBold
	button.LayoutOrder = order
	button.Parent = tabBar

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = button

	button.MouseButton1Click:Connect(function()
		setActiveTab(name)
	end)

	tabButtons[name] = button
end

makeTabButton("Upgrades", 1)
makeTabButton("Gems", 2)
makeTabButton("Passes", 3)

tabFrames.Upgrades = makeTabFrame("Upgrades")
tabFrames.Gems = makeTabFrame("Gems")
tabFrames.Passes = makeTabFrame("Passes")

setActiveTab("Upgrades")

-- Row factory --------------------------------------------------------------

local function makeRow(parent: Instance, title: string, subtitle: string, buttonText: string, order: number)
	local row = Instance.new("Frame")
	row.Name = title
	row.Size = UDim2.new(1, 0, 0, 64)
	row.BackgroundColor3 = Color3.fromRGB(36, 40, 52)
	row.BorderSizePixel = 0
	row.LayoutOrder = order
	row.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = row

	local titleLabel = Instance.new("TextLabel")
	titleLabel.Name = "Title"
	titleLabel.AnchorPoint = Vector2.new(0, 0.5)
	titleLabel.Position = UDim2.new(0, 14, 0.32, 0)
	titleLabel.Size = UDim2.new(1, -160, 0, 22)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Text = title
	titleLabel.TextColor3 = Color3.fromRGB(245, 245, 250)
	titleLabel.TextSize = 18
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.Font = Enum.Font.GothamBold
	titleLabel.Parent = row

	local subtitleLabel = Instance.new("TextLabel")
	subtitleLabel.Name = "Subtitle"
	subtitleLabel.AnchorPoint = Vector2.new(0, 0.5)
	subtitleLabel.Position = UDim2.new(0, 14, 0.7, 0)
	subtitleLabel.Size = UDim2.new(1, -160, 0, 18)
	subtitleLabel.BackgroundTransparency = 1
	subtitleLabel.Text = subtitle
	subtitleLabel.TextColor3 = Color3.fromRGB(180, 185, 200)
	subtitleLabel.TextSize = 14
	subtitleLabel.TextXAlignment = Enum.TextXAlignment.Left
	subtitleLabel.Font = Enum.Font.Gotham
	subtitleLabel.Parent = row

	local button = Instance.new("TextButton")
	button.Name = "Buy"
	button.AnchorPoint = Vector2.new(1, 0.5)
	button.Position = UDim2.new(1, -12, 0.5, 0)
	button.Size = UDim2.new(0, 130, 0, 44)
	button.BackgroundColor3 = Color3.fromRGB(80, 130, 220)
	button.BorderSizePixel = 0
	button.Text = buttonText
	button.TextColor3 = Color3.fromRGB(255, 255, 255)
	button.TextSize = 14
	button.Font = Enum.Font.GothamBold
	button.Parent = row

	local buttonCorner = Instance.new("UICorner")
	buttonCorner.CornerRadius = UDim.new(0, 8)
	buttonCorner.Parent = button

	return row, titleLabel, subtitleLabel, button
end

-- Upgrades tab -------------------------------------------------------------

local upgradeRows: { [string]: { row: Frame, title: TextLabel, subtitle: TextLabel, button: TextButton } } = {}

for order, name in ipairs(GameConfig.UpgradeOrder) do
	local config = GameConfig.Upgrades[name]
	if not config then continue end
	local row, titleLabel, subtitleLabel, button = makeRow(tabFrames.Upgrades, config.Display, "...", "Buy", order)
	upgradeRows[name] = { row = row, title = titleLabel, subtitle = subtitleLabel, button = button }
	button.MouseButton1Click:Connect(function()
		button.AutoButtonColor = false
		button.Active = false
		local ok, result = pcall(function()
			return PurchaseUpgrade:InvokeServer(name)
		end)
		button.AutoButtonColor = true
		button.Active = true
		if not ok or not result then return end
		-- The server pushes new data via PlayerDataUpdated; UI will refresh.
	end)
end

local function refreshUpgrades()
	if not latestData then return end
	for name, parts in upgradeRows do
		local config = GameConfig.Upgrades[name]
		local currentTier = (latestData.Upgrades and latestData.Upgrades[name]) or 0
		local maxTier = #config.Tiers
		parts.title.Text = config.Display .. "  (Tier " .. currentTier .. "/" .. maxTier .. ")"

		if currentTier >= maxTier then
			parts.subtitle.Text = "Maxed out"
			parts.button.Text = "Maxed"
			parts.button.BackgroundColor3 = Color3.fromRGB(60, 65, 80)
			parts.button.Active = false
			parts.button.AutoButtonColor = false
		else
			local entry = config.Tiers[currentTier + 1]
			local currency = config.Currency
			parts.subtitle.Text = ("Tier %d -> %s = %s. Cost %d %s"):format(
				currentTier + 1, config.Display, tostring(entry.Value), entry.Cost, currency:lower()
			)
			local balance = latestData[currency] or 0
			if balance >= entry.Cost then
				parts.button.Text = ("Buy (%d %s)"):format(entry.Cost, currency:lower())
				parts.button.BackgroundColor3 = Color3.fromRGB(80, 130, 220)
				parts.button.Active = true
				parts.button.AutoButtonColor = true
			else
				parts.button.Text = ("Need %d %s"):format(entry.Cost - balance, currency:lower())
				parts.button.BackgroundColor3 = Color3.fromRGB(120, 60, 60)
				parts.button.Active = false
				parts.button.AutoButtonColor = false
			end
		end
	end
end

-- Gems tab -----------------------------------------------------------------

local gemRows: { [string]: { row: Frame, title: TextLabel, subtitle: TextLabel, button: TextButton } } = {}

for order, key in ipairs(GameConfig.GemProductOrder) do
	local product = GameConfig.GemProducts[key]
	if not product then continue end
	local row, titleLabel, subtitleLabel, button = makeRow(tabFrames.Gems, product.Display, "...", "...", order)
	gemRows[key] = { row = row, title = titleLabel, subtitle = subtitleLabel, button = button }
	button.MouseButton1Click:Connect(function()
		PromptGemProduct:FireServer(key)
	end)
end

local function refreshGems()
	for key, parts in gemRows do
		local product = GameConfig.GemProducts[key]
		parts.title.Text = product.Display
		parts.subtitle.Text = ("+%d gems"):format(product.Gems)
		if product.ProductId > 0 then
			parts.button.Text = (product.Robux and (tostring(product.Robux) .. " R$")) or "Buy"
			parts.button.BackgroundColor3 = Color3.fromRGB(50, 170, 90)
			parts.button.Active = true
			parts.button.AutoButtonColor = true
		else
			parts.button.Text = "Not set"
			parts.button.BackgroundColor3 = Color3.fromRGB(60, 65, 80)
			parts.button.Active = false
			parts.button.AutoButtonColor = false
		end
	end
end

-- Passes tab ---------------------------------------------------------------

local passRows: { [string]: { row: Frame, title: TextLabel, subtitle: TextLabel, button: TextButton } } = {}

for order, key in ipairs(GameConfig.GamePassOrder) do
	local pass = GameConfig.GamePasses[key]
	if not pass then continue end
	local row, titleLabel, subtitleLabel, button = makeRow(tabFrames.Passes, pass.Display, pass.Description or "", "...", order)
	passRows[key] = { row = row, title = titleLabel, subtitle = subtitleLabel, button = button }
	button.MouseButton1Click:Connect(function()
		PromptGamePass:FireServer(key)
	end)
end

local function refreshPasses()
	for key, parts in passRows do
		local pass = GameConfig.GamePasses[key]
		parts.title.Text = pass.Display
		parts.subtitle.Text = pass.Description or ""
		local owned = latestData and latestData.Passes and latestData.Passes[key]
		if owned then
			parts.button.Text = "Owned"
			parts.button.BackgroundColor3 = Color3.fromRGB(50, 130, 80)
			parts.button.Active = false
			parts.button.AutoButtonColor = false
		elseif pass.GamePassId > 0 then
			parts.button.Text = "Buy"
			parts.button.BackgroundColor3 = Color3.fromRGB(50, 170, 90)
			parts.button.Active = true
			parts.button.AutoButtonColor = true
		else
			parts.button.Text = "Not set"
			parts.button.BackgroundColor3 = Color3.fromRGB(60, 65, 80)
			parts.button.Active = false
			parts.button.AutoButtonColor = false
		end
	end
end

local function refreshAll()
	refreshUpgrades()
	refreshGems()
	refreshPasses()
end

PlayerDataUpdated.OnClientEvent:Connect(function(data)
	latestData = data
	if gui.Enabled then
		refreshAll()
	end
end)

-- If HudGui has already cached data by the time we get here, use it.
if _G.CoinRush.ClientData and _G.CoinRush.ClientData.data then
	latestData = _G.CoinRush.ClientData.data
end

-- Open / close ------------------------------------------------------------

local isOpen = false

local function openShop()
	if isOpen then return end
	isOpen = true
	gui.Enabled = true
	refreshAll()
end

local function closeShop()
	if not isOpen then return end
	isOpen = false
	gui.Enabled = false
end

closeButton.MouseButton1Click:Connect(closeShop)

-- Proximity detection
local function findBeacon(): BasePart?
	local part = Workspace:FindFirstChild("ShopBeacon")
	if part and part:IsA("BasePart") then return part end
	return nil
end

local OPEN_RADIUS = GameConfig.ShopOpenRadius
local CLOSE_RADIUS = GameConfig.ShopOpenRadius + 4 -- hysteresis

task.spawn(function()
	while true do
		task.wait(0.15)
		local beacon = findBeacon()
		if not beacon then continue end
		local character = player.Character
		if not character then continue end
		local root = character:FindFirstChild("HumanoidRootPart")
		if not root or not root:IsA("BasePart") then continue end
		local distance = (root.Position - beacon.Position).Magnitude
		if not isOpen and distance <= OPEN_RADIUS then
			openShop()
		elseif isOpen and distance > CLOSE_RADIUS then
			closeShop()
		end
	end
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode ~= Enum.KeyCode.E then return end
	local beacon = findBeacon()
	if not beacon then return end
	local character = player.Character
	if not character then return end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then return end
	local distance = (root.Position - beacon.Position).Magnitude
	if isOpen then
		closeShop()
	elseif distance <= OPEN_RADIUS * 2 then
		openShop()
	end
end)
