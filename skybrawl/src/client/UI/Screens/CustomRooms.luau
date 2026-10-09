-- STUB (owner: C2): replace the body, keep the exports.
--[[
    Menu screen "CustomRooms" (menus design 5.8): browse, create and join custom rooms.
    Params: { view = "Browse" | "Room" }?
    A screen module returns { id, title, build(host) -> ScreenInstance }
    (design 3.8). Until C2 lands it is an empty frame.
]]

local Screen = {
	id = "CustomRooms",
	title = "CUSTOM ROOMS",
}

function Screen.build(host)
	local root = Instance.new("Frame")
	root.Name = "CustomRooms"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = host.content
	return { root = root }
end

return Screen
