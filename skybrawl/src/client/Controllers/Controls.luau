--[[
    Roblox's default controls, core UI and chat window outside the fight
    (menus design section 2 item 5).

    Controls.set(false) turns off the PlayerModule controls, the touch
    thumbstick / jump button, the reset button and the player list. Nothing
    in the game turns them back on: the fighter has its own Input, and
    there is no character outside a match. Each part runs in its own
    task.spawn so the PlayerModule WaitForChild never holds up the client's
    init chain; SetCore("ResetButtonCallback") is retried every 0.5 s for up
    to 10 s, because it errors until the CoreScripts have registered it.

    Chat (TextChatService): the window and input bar are hidden on the
    title screen, legend select and VS splash, and shown in the menus,
    results and matches. On the first visit to the menu the window starts
    collapsed behind the top bar's chat button (SetCore "ChatActive"); after
    that the player's own choice is kept. Where "ChatActive" isn't supported
    the window shows at its default spot.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local TextChatService = game:GetService("TextChatService")

local Client = script.Parent.Parent
local ClientState = require(Client:WaitForChild("ClientState"))
local MenuModels = require(Client:WaitForChild("UI"):WaitForChild("MenuModels"))

local Controls = {}

local RETRY_EVERY = 0.5
local RETRY_FOR = 10

local player = Players.LocalPlayer
local resetToken = 0
local chatCollapsed = false

-- Retries a SetCore until it succeeds, gives up after RETRY_FOR s, or stops once isLatest() is false.
local function setCoreWhenReady(name, value, isLatest)
	local deadline = os.clock() + RETRY_FOR
	while isLatest() do
		local ok = pcall(StarterGui.SetCore, StarterGui, name, value)
		if ok or os.clock() >= deadline then
			return ok
		end
		task.wait(RETRY_EVERY)
	end
	return false
end

function Controls.set(enabled)
	task.spawn(function()
		pcall(function()
			-- (cast: the PlayerModule only exists at run time, so the type checker can't resolve it)
			local module = player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule")
			local playerModule = (require :: any)(module)
			local controls = playerModule:GetControls()
			if enabled then
				controls:Enable()
			else
				controls:Disable()
			end
		end)
	end)
	task.spawn(function()
		pcall(function()
			GuiService.TouchControlsEnabled = enabled
		end)
	end)
	resetToken += 1
	local token = resetToken
	task.spawn(setCoreWhenReady, "ResetButtonCallback", enabled, function()
		return token == resetToken
	end)
	task.spawn(function()
		pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, enabled)
		end)
	end)
end

local function setChat(phase)
	local enabled = MenuModels.chatEnabled(phase)
	pcall(function()
		local window = TextChatService:FindFirstChildOfClass("ChatWindowConfiguration")
		if window then
			window.Enabled = enabled
		end
		local inputBar = TextChatService:FindFirstChildOfClass("ChatInputBarConfiguration")
		if inputBar then
			inputBar.Enabled = enabled
		end
	end)
	if phase == "Menu" and not chatCollapsed then
		chatCollapsed = true
		-- after the window is enabled again; only on the first menu visit, so the player's choice sticks
		task.defer(function()
			pcall(StarterGui.SetCore, StarterGui, "ChatActive", false)
		end)
	end
end

function Controls.init()
	Controls.set(false)
	setChat(ClientState.phase)
	ClientState.PhaseChanged:Connect(setChat)
end

return Controls
