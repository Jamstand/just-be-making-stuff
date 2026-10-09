-- STUB (owner: C1): replace the body, keep the exports.
--[[
    The menu shell (menus design 5.1): the painted backdrop, the screen
    stack (MainMenu at the root, Screens/<Id> pushed on top), the chrome
    (player card, queue banner, party bar, hints) and phase handling. Until
    C1 lands the old LobbyUI is the menu and this builds nothing.
]]

local MenuShell = {}

function MenuShell.init() end

-- The menu sky (or its gradient fallback) plus the dim layer, optionally tinted. Returns the backdrop frame.
function MenuShell.buildBackdrop(parent, tint)
	local frame = Instance.new("Frame")
	frame.Name = "Backdrop"
	frame.BorderSizePixel = 0
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = tint or Color3.fromRGB(10, 11, 14)
	frame.Parent = parent
	return frame
end

return MenuShell
