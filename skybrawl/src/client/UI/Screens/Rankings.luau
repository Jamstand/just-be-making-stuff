-- STUB (owner: C2): replace the body, keep the exports.
--[[
    Menu screen "Rankings" (menus design 5.8): the ranked ladders for this season.
    Params: { mode = "1v1" | "2v2" }?
    A screen module returns { id, title, build(host) -> ScreenInstance }
    (design 3.8). Until C2 lands it is an empty frame.
]]

local Screen = {
	id = "Rankings",
	title = "RANKINGS",
}

function Screen.build(host)
	local root = Instance.new("Frame")
	root.Name = "Rankings"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = host.content
	return { root = root }
end

return Screen
