-- STUB (owner: C1): replace the body, keep the exports.
--[[
    The DAILY MISSIONS panel (menus design 5.7): three rows keyed by mission
    index, updated in place from ClientState.profile.Missions, with CLAIM
    and the free reroll. The main menu shows it compact; the Missions screen
    embeds it with compact = false. Until C1 lands it is an empty frame.
]]

local MissionsWidget = {}

-- opts = { compact: boolean? } & Common. Returns { frame, focusables() -> { GuiObject }, destroy() }.
function MissionsWidget.new(parent, opts)
	opts = opts or {}
	local frame = Instance.new("Frame")
	frame.Name = opts.name or "MissionsWidget"
	frame.BackgroundTransparency = 1
	frame.Position = opts.position or UDim2.new()
	frame.Size = opts.size or UDim2.fromScale(1, 1)
	frame.AnchorPoint = opts.anchor or Vector2.zero
	frame.ZIndex = opts.zIndex or 1
	frame.LayoutOrder = opts.layoutOrder or 0
	frame.Parent = parent or opts.parent
	return {
		frame = frame,
		focusables = function()
			return {}
		end,
		destroy = function()
			frame:Destroy()
		end,
	}
end

return MissionsWidget
