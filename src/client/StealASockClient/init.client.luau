-- Steal a Sock - client bootstrap. Builds the UI (HUD, the left menu column and its panels),
-- listens to the server's remotes and hides prompts that aren't for this player (the server still
-- validates everything).
--
-- UI modules: Theme (look + factories), Anim (all motion), UISound (all UI sounds), ClientSettings
-- (the player's settings), Menu (column + panel manager), HUD, ShopUI, StoreUI, DexUI, SockCard,
-- SettingsUI, Performance (the settings that change the 3D world), ItemBar (the item bar that
-- replaces Roblox's hotbar; ItemBarLayout and ItemIcon are its helpers), MainMenu (the title
-- screen you land on: it hides the others until PLAY). Every screen gets SetState(state) with the
-- StateView (Shared.Types) once a second.
-- Items: ItemClient is the item bar's engine (using items, cooldowns; it starts ItemFX, the item
-- effects, itself). It loads on its own thread, so a slow or broken start can't hold up the menus.
-- 3D: SockFX (clothesline, dryer, fan, forcefield, bursts, outlines) and SockAnim (every sock's
-- bone animation, personality and reactions; it takes the sock motion over from SockFX).
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local player = Players.LocalPlayer
local Remotes = ReplicatedStorage:WaitForChild("Remotes")

-- Every module loads and starts on its own: one that is missing or errors prints a warning and
-- is skipped, instead of stopping everything after it (the 3D effects start first for that reason).
local function load(name: string): any
	local module = script:WaitForChild(name, 15)
	if not module then
		warn("[StealASockClient] ModuleScript " .. name .. " is missing - copy src/client/StealASockClient/" .. name .. ".luau into the place")
		return nil
	end
	local ok, result = pcall(require, module)
	if not ok then
		warn("[StealASockClient] " .. name .. " failed to load: " .. tostring(result))
		return nil
	end
	return result
end

local function run(name: string, mod: any, fn: string, ...: any)
	if mod and type(mod[fn]) == "function" then
		local ok, err = pcall(mod[fn], ...)
		if not ok then
			warn("[StealASockClient] " .. name .. "." .. fn .. " failed: " .. tostring(err))
		end
	end
end

-- 3D effects first (clothesline socks, dryer, ceiling fan, forcefield hexes); Init waits for the map
local SockFX = load("SockFX")
task.spawn(run, "SockFX", SockFX, "Init")
-- living socks: personalities, bones, reactions (after SockFX, which it takes the motion over from)
local SockAnim = load("SockAnim")
task.spawn(run, "SockAnim", SockAnim, "Init")

-- the UI kit first: every screen requires these (with an endless WaitForChild), so if one is
-- missing the screens are skipped instead of hanging the whole script
local Theme = load("Theme")
local Anim = load("Anim")
local UISound = load("UISound")
local ClientSettings = load("ClientSettings")
local kit = Theme ~= nil and Anim ~= nil and UISound ~= nil and ClientSettings ~= nil
if not kit then
	warn("[StealASockClient] the UI kit (Theme, Anim, UISound, ClientSettings) is incomplete - the menus and HUD are skipped")
end
local function screen(name: string): any
	return if kit then load(name) else nil
end
local Menu = screen("Menu")
local HUD = screen("HUD")
local ShopUI = screen("ShopUI")
local StoreUI = screen("StoreUI")
local DexUI = screen("DexUI")
local SockCard = screen("SockCard")
local SettingsUI = screen("SettingsUI")
local Performance = screen("Performance")
local ItemBar = screen("ItemBar")
local MainMenu = screen("MainMenu")

run("Menu", Menu, "Init")
run("HUD", HUD, "Init")
-- the left column, top to bottom; each screen registers its own panel in Init
if Menu and HUD then
	run("Menu", Menu, "AddButton", "Drawer", "🧦", "Drawer", "gold", 1, HUD.ToggleDrawer)
end
run("ShopUI", ShopUI, "Init") -- "Shop" button, order 2
run("StoreUI", StoreUI, "Init") -- "Store" button, order 3
run("DexUI", DexUI, "Init") -- "Sockdex" button, order 4
run("SettingsUI", SettingsUI, "Init") -- "Settings" button, order 5
run("SockCard", SockCard, "Init")
run("Performance", Performance, "Init") -- Low graphics / Hide others' effects / Sock name tags (ClientSettings)
run("ItemBar", ItemBar, "Init") -- bottom-centre; hides Roblox's hotbar (it stays if the bar can't load)
run("ItemBar", ItemBar, "SetShopOpener", function() -- an empty "+" slot opens the Item Shop's Items tab
	if ShopUI and type(ShopUI.OpenItems) == "function" then
		run("ShopUI", ShopUI, "OpenItems")
	elseif Menu then
		run("Menu", Menu, "Open", "Shop")
	end
end)
run("UISound", UISound, "Preload")
-- the title screen last: it hides the screens above until PLAY (its music starts with the State)
run("MainMenu", MainMenu, "Show")

local screens = { HUD = HUD, ShopUI = ShopUI, StoreUI = StoreUI, DexUI = DexUI, SockCard = SockCard, ItemBar = ItemBar }
local latestState: any = nil
local ItemClient: any = nil

-- the item bar's engine: on its own thread (it may wait for its remotes); the bar works without it
task.spawn(function()
	local mod = load("ItemClient")
	if not mod then
		return
	end
	ItemClient = mod
	run("ItemClient", mod, "Init")
	run("ItemBar", ItemBar, "SetClient", mod)
	if latestState then
		run("ItemClient", mod, "SetState", latestState)
	end
end)

local musicStarted = false
Remotes:WaitForChild("State").OnClientEvent:Connect(function(state)
	if type(state) ~= "table" then
		return
	end
	-- the server sends slots with string keys (a gappy array could be cut short); screens index by number
	local slots = {}
	for k, view in pairs(if type(state.slots) == "table" then state.slots else {}) do
		local i = tonumber(k)
		if i then
			slots[i] = view
		end
	end
	state.slots = slots
	run("ClientSettings", ClientSettings, "Load", state.settings)
	if not musicStarted then
		musicStarted = true -- after the saved Music volume is applied, so a muted player hears nothing
		run("UISound", UISound, "StartMusic") -- the title screen's loop while it shows, else the game's
	end
	for name, screen in pairs(screens) do
		run(name, screen, "SetState", state)
	end
	latestState = state
	if ItemClient then
		run("ItemClient", ItemClient, "SetState", state)
	end
end)
Remotes:WaitForChild("Toast").OnClientEvent:Connect(function(text, kind)
	run("HUD", HUD, "Toast", text, kind)
end)
Remotes:WaitForChild("Announce").OnClientEvent:Connect(function(text, color)
	run("HUD", HUD, "Announce", text, color)
end)
Remotes:WaitForChild("Carry").OnClientEvent:Connect(function(view)
	run("HUD", HUD, "SetCarry", view)
end)
Remotes:WaitForChild("Celebrate").OnClientEvent:Connect(function(kind, data)
	if type(kind) == "string" and type(data) == "table" then
		run("HUD", HUD, "Celebrate", kind, data)
	end
end)
Remotes:WaitForChild("FX").OnClientEvent:Connect(function(kind, position, color)
	if typeof(position) == "Vector3" then
		run("SockFX", SockFX, "Burst", kind, position, color)
	end
end)

-- The padlocked back row of a drawer: its prompt opens the Store (only on your own drawer).
ProximityPromptService.PromptTriggered:Connect(function(prompt)
	if prompt.Name == "UnlockSlotsPrompt" then
		run("Menu", Menu, "Open", "Store")
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
