-- Steal a Sock - client bootstrap. Builds the UI (HUD, the left menu column and its panels),
-- listens to the server's remotes and hides prompts that aren't for this player (the server still
-- validates everything).
--
-- UI modules: Theme (look + factories), Anim (all motion), UISound (all UI sounds), ClientSettings
-- (the player's settings), Menu (column + panel manager), HUD, ShopUI, StoreUI, DexUI, SockCard,
-- SettingsUI, Performance (the settings that change the 3D world). Every screen gets SetState(state) with the StateView (Shared.Types) once a second.
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local player = Players.LocalPlayer
local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local UISound = require(script:WaitForChild("UISound"))
local ClientSettings = require(script:WaitForChild("ClientSettings"))
local Menu = require(script:WaitForChild("Menu"))
local HUD = require(script:WaitForChild("HUD"))
local ShopUI = require(script:WaitForChild("ShopUI"))
local StoreUI = require(script:WaitForChild("StoreUI"))
local DexUI = require(script:WaitForChild("DexUI"))
local SockCard = require(script:WaitForChild("SockCard"))
local SettingsUI = require(script:WaitForChild("SettingsUI"))
local Performance = require(script:WaitForChild("Performance"))
local SockFX = require(script:WaitForChild("SockFX"))

Menu.Init()
HUD.Init()
-- the left column, top to bottom; each screen registers its own panel in Init
Menu.AddButton("Drawer", "🧦", "Drawer", "gold", 1, HUD.ToggleDrawer)
ShopUI.Init() -- "Shop" button, order 2
StoreUI.Init() -- "Store" button, order 3
DexUI.Init() -- "Sockdex" button, order 4
SettingsUI.Init() -- "Settings" button, order 5
SockCard.Init()
Performance.Init() -- Low graphics / Hide others' effects / Sock name tags (ClientSettings)
SockFX.Init()
UISound.StartMusic()

local screens = { HUD, ShopUI, StoreUI, DexUI, SockCard }
Remotes:WaitForChild("State").OnClientEvent:Connect(function(state)
	ClientSettings.Load(state.settings)
	for _, screen in ipairs(screens) do
		screen.SetState(state)
	end
end)
Remotes:WaitForChild("Toast").OnClientEvent:Connect(function(text, kind)
	HUD.Toast(text, kind)
end)
Remotes:WaitForChild("Announce").OnClientEvent:Connect(function(text, color)
	HUD.Announce(text, color)
end)
Remotes:WaitForChild("Carry").OnClientEvent:Connect(function(view)
	HUD.SetCarry(view)
end)
Remotes:WaitForChild("Celebrate").OnClientEvent:Connect(function(kind, data)
	if type(kind) == "string" and type(data) == "table" then
		HUD.Celebrate(kind, data)
	end
end)
Remotes:WaitForChild("FX").OnClientEvent:Connect(function(kind, position, color)
	if typeof(position) == "Vector3" then
		SockFX.Burst(kind, position, color)
	end
end)

-- The padlocked back row of a drawer: its prompt opens the Store (only on your own drawer).
ProximityPromptService.PromptTriggered:Connect(function(prompt)
	if prompt.Name == "UnlockSlotsPrompt" then
		Menu.Open("Store")
	end
end)

-- Prompts that aren't for this player: Steal on your own socks, Unlock on someone else's drawer.
-- The server toggles prompt.Enabled too, so re-apply on every change.
local function applyOwnPrompt(model: Instance)
	local leg = model:FindFirstChild("Leg")
	local prompt = leg and leg:FindFirstChild("StealPrompt")
	if prompt and prompt:IsA("ProximityPrompt") and model:GetAttribute("OwnerId") == player.UserId then
		prompt.Enabled = false
	end
end

local function watchSock(model: Instance)
	applyOwnPrompt(model)
	model:GetAttributeChangedSignal("OwnerId"):Connect(function()
		applyOwnPrompt(model)
	end)
	model.DescendantAdded:Connect(function(desc)
		if desc:IsA("ProximityPrompt") and desc.Name == "StealPrompt" then
			applyOwnPrompt(model)
			desc:GetPropertyChangedSignal("Enabled"):Connect(function()
				applyOwnPrompt(model)
			end)
		end
	end)
	local leg = model:FindFirstChild("Leg")
	local prompt = leg and leg:FindFirstChild("StealPrompt")
	if prompt then
		prompt:GetPropertyChangedSignal("Enabled"):Connect(function()
			applyOwnPrompt(model)
		end)
	end
end

for _, model in ipairs(CollectionService:GetTagged("Sock")) do
	watchSock(model)
end
CollectionService:GetInstanceAddedSignal("Sock"):Connect(watchSock)

local function watchBase(model: Instance)
	local function apply()
		local mine = model:GetAttribute("OwnerId") == player.UserId
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("ProximityPrompt") and d.Name == "UnlockSlotsPrompt" then
				d.Enabled = mine and d:GetAttribute("Locked") == true
			end
		end
	end
	apply()
	model:GetAttributeChangedSignal("OwnerId"):Connect(apply)
	model.DescendantAdded:Connect(function(desc)
		if desc:IsA("ProximityPrompt") and desc.Name == "UnlockSlotsPrompt" then
			apply()
			desc:GetAttributeChangedSignal("Locked"):Connect(apply)
		end
	end)
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d.Name == "UnlockSlotsPrompt" then
			d:GetAttributeChangedSignal("Locked"):Connect(apply)
		end
	end
end

for _, model in ipairs(CollectionService:GetTagged("Base")) do
	watchBase(model)
end
CollectionService:GetInstanceAddedSignal("Base"):Connect(watchBase)
