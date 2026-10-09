--[[
    Menu screen "Settings" (menus design 5.8): camera, controls (key
    rebinding), gameplay and audio (sound effects and music), mounted from
    SettingsPanel with its pages as tabs (L1/R1).
]]

local SettingsPanel = require(script.Parent.Parent.SettingsPanel)

local Screen = {
	id = "Settings",
	title = "SETTINGS",
}

function Screen.build(host)
	return SettingsPanel.mount(host.content, host)
end

return Screen
