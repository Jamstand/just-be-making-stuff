--[[
    Menu screen "Store" (menus design 5.8): weapon colors, trails, KO
    effects and titles, mounted from ShopPanel (category tabs on L1/R1,
    focusable item cards, prices in Gold).
]]

local ShopPanel = require(script.Parent.Parent.ShopPanel)

local Screen = {
	id = "Store",
	title = "STORE",
}

function Screen.build(host)
	return ShopPanel.mount(host.content, host)
end

return Screen
