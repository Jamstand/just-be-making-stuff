--[[
    Menu screen "Profile" (menus design 5.8): your level, season badge,
    ranked cards and lifetime stats, mounted from ProfilePanel. Read-only:
    Up / Down scroll it.
]]

local ProfilePanel = require(script.Parent.Parent.ProfilePanel)

local Screen = {
	id = "Profile",
	title = "PROFILE",
}

function Screen.build(host)
	return ProfilePanel.mount(host.content, host)
end

return Screen
