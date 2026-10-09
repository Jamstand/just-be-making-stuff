-- STUB (owner: C1): replace the body, keep the exports.
--[[
    The title screen (menus design 5.6): the logo, six legends and PRESS ANY
    BUTTON, shown once per join; any input moves the phase to "Menu". Until
    C1 lands show() goes straight to the menu.
]]

local ClientState = require(script.Parent.Parent:WaitForChild("ClientState"))

local TitleScreen = {}

function TitleScreen.show()
	ClientState.setPhase("Menu")
end

return TitleScreen
