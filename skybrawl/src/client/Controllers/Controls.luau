-- STUB (owner: C1): replace the body, keep the exports.
--[[
    Roblox's default controls and core UI (menus design section 2 item 5):
    Controls.set(false) turns off the PlayerModule controls, touch controls,
    the reset button and the player list. Until C1 lands this is the old
    MatchClient toggle (each part spawned so nothing waits on the
    PlayerModule) and init sets nothing up (no chat rules yet).
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")

local Controls = {}

local player = Players.LocalPlayer

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
	pcall(function()
		GuiService.TouchControlsEnabled = enabled
	end)
	pcall(function()
		StarterGui:SetCore("ResetButtonCallback", enabled)
	end)
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, enabled)
	end)
end

function Controls.init() end

return Controls
