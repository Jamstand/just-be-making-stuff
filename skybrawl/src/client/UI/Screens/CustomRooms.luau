--[[
    Menu screen "CustomRooms" (menus design 5.8): browse, create and join
    custom rooms, mounted from RoomsPanel (BROWSE / CREATE / ROOM tabs on
    L1/R1). Params: { view = "Browse" | "Room" }? (results REMATCH for a
    non-host opens the Room view).
]]

local RoomsPanel = require(script.Parent.Parent.RoomsPanel)

local Screen = {
	id = "CustomRooms",
	title = "CUSTOM ROOMS",
}

function Screen.build(host)
	return RoomsPanel.mount(host.content, host)
end

return Screen
