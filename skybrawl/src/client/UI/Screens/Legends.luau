--[[
    Menu screen "Legends" (menus design 5.8): the roster grid, the legend
    in 3D, its stats, weapons, signatures and ultimate, the avatar-look
    toggle (Y) and SELECT, mounted from FightersPanel.
    Params: { legend = id }? preselects a legend (featured tiles, CHANGE).
]]

local FightersPanel = require(script.Parent.Parent.FightersPanel)

local Screen = {
	id = "Legends",
	title = "LEGENDS",
}

function Screen.build(host)
	return FightersPanel.mount(host.content, host)
end

return Screen
