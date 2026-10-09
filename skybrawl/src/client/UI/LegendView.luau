-- STUB (owner: C1): replace the body, keep the exports.
--[[
    The menus' 3D legends (menus design 5.5): a ViewportFrame showing a
    legend's rig (or your avatar's look from ReplicatedStorage.AvatarModels),
    animated by FighterAnimator as a preview, plus still portraits and the
    title screen's group view. obj:set(spec) never yields.

    Until C1 lands the views are empty frames and set() does nothing;
    weaponFor is the real one.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Legends = require(Shared.Legends)

local LegendView = {}

-- Common opts: parent, position, size, anchor, zIndex, layoutOrder, name.
local function place(obj, parent, opts)
	opts = opts or {}
	obj.BackgroundTransparency = 1
	obj.Position = opts.position or obj.Position
	obj.Size = opts.size or UDim2.fromScale(1, 1)
	obj.AnchorPoint = opts.anchor or obj.AnchorPoint
	obj.ZIndex = opts.zIndex or obj.ZIndex
	obj.LayoutOrder = opts.layoutOrder or obj.LayoutOrder
	obj.Name = opts.name or obj.Name
	obj.Parent = parent or opts.parent
end

--[[
    opts = { framing: "Full" | "Bust" | "Head"?, facing: "Left" | "Right" | "Front"?,
    brightness: number?, animated: boolean? } & Common. Returns
    { frame: ViewportFrame, set(self, spec), clear(self), destroy(self) } with
    spec = { legend, userId?, ownLook?, weapon?, flourish? }.
]]
function LegendView.new(parent, opts)
	local frame = Instance.new("ViewportFrame")
	frame.Name = "LegendView"
	place(frame, parent, opts)
	local view = { frame = frame }
	function view:set(_spec) end
	function view:clear() end
	function view:destroy()
		self.frame:Destroy()
	end
	return view
end

-- A still head-and-shoulders portrait: { frame, set(spec), destroy() }.
function LegendView.portrait(parent, spec, opts)
	local frame = Instance.new("Frame")
	frame.Name = "Portrait"
	place(frame, parent, opts)
	frame.BackgroundTransparency = 0
	frame.BackgroundColor3 = Legends.get(spec and spec.legend).Color
	return {
		frame = frame,
		set = function(newSpec)
			frame.BackgroundColor3 = Legends.get(newSpec and newSpec.legend).Color
		end,
		destroy = function()
			frame:Destroy()
		end,
	}
end

--[[
    Several animated legends in one view (the title screen): entries =
    { { spec, x, height, facing } }. Returns { frame, destroy() }.
]]
function LegendView.group(parent, opts, _entries)
	local frame = Instance.new("ViewportFrame")
	frame.Name = "LegendGroup"
	place(frame, parent, { zIndex = opts and opts.zIndex })
	return {
		frame = frame,
		destroy = function()
			frame:Destroy()
		end,
	}
end

-- The weapon a legend holds in the menus (nil for Avatar).
function LegendView.weaponFor(legendId)
	local menuWeapon = Config.Art.MenuWeapons[legendId]
	if menuWeapon then
		return menuWeapon
	end
	local weapons = Legends.get(legendId).Weapons
	return weapons and weapons[1] or nil
end

return LegendView
