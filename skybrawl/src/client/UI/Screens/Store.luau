-- STUB (owner: C2): replace the body, keep the exports.
--[[
    Menu screen "Store" (menus design 5.8): weapon colors, trails, KO effects and titles.
    A screen module returns { id, title, build(host) -> ScreenInstance }
    (design 3.8). Until C2 lands it is an empty frame.
]]

local Screen = {
	id = "Store",
	title = "STORE",
}

function Screen.build(host)
	local root = Instance.new("Frame")
	root.Name = "Store"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = host.content
	return { root = root }
end

return Screen
