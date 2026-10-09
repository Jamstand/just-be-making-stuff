-- STUB (owner: C2): replace the body, keep the exports.
--[[
    Menu screen "OnlinePlay" (menus design 5.8): Ranked 1v1, Ranked 2v2 and Free-for-all queues.
    A screen module returns { id, title, build(host) -> ScreenInstance }
    (design 3.8). Until C2 lands it is an empty frame.
]]

local Screen = {
	id = "OnlinePlay",
	title = "ONLINE PLAY",
}

function Screen.build(host)
	local root = Instance.new("Frame")
	root.Name = "OnlinePlay"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = host.content
	return { root = root }
end

return Screen
