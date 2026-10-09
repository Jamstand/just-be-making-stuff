-- STUB (owner: C1): replace the body, keep the exports.
--[[
    Screen layout for the menus (menus design 5.4): one canvas = the device
    safe area, geometry in Scale, text / strokes / paddings in design px at
    1080p through Layout.px (x1.6 on phones), and nothing under the Roblox
    top bar (clearTop). Roblox caps TextSize at 100, so bindText is the only
    way to size text: above 100 px it adds a "TextFit" UIScale.

    Until C1 lands: always "Wide", px(n) = n, bindText clamps to 100, no top
    bar handling. The pure helpers (modeFor, pxFor, textFit, pushFor,
    phoneRect) are the real ones.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = require(Shared.Util)

local Layout = {}

Layout.Changed = Util.Signal.new() -- (mode)
-- engine behaviour: UIScale scales UIStroke thickness (C1 confirms in Studio)
Layout.STROKE_FOLLOWS_UISCALE = true

-- Pure helpers -------------------------------------------------------------

-- Phone when the safe area is under 500 px tall or 900 px wide.
function Layout.modeFor(size)
	if size.Y < 500 or size.X < 900 then
		return "Phone"
	end
	return "Wide"
end

-- Design px (at 1080p) -> px for a safe area `height` tall; text and strokes are 1.6x bigger on phones.
function Layout.pxFor(n, height, mode)
	return math.floor(n * height / 1080 * (if mode == "Phone" then 1.6 else 1) + 0.5)
end

-- (TextSize, scale): Roblox caps TextSize at 100, so bigger text is TextSize 100 scaled up.
function Layout.textFit(px)
	if px <= 100 then
		return px, 1
	end
	return 100, px / 100
end

-- How far down `rect` ({ x, y, w, h }) must move so its top edge clears every box it overlaps, plus `gap`.
function Layout.pushFor(rect, boxes, gap)
	local push = 0
	for _, box in boxes do
		local overlaps = box.w > 0
			and box.h > 0
			and rect.x < box.x + box.w
			and rect.x + rect.w > box.x
			and rect.y < box.y + box.h
			and rect.y + rect.h > box.y
		if overlaps then
			push = math.max(push, box.y + box.h + gap - rect.y)
		end
	end
	return push
end

-- A rect from the 844x390 phone mockup (insets left 47, right 47, bottom 21) as fractions of the safe area.
function Layout.phoneRect(x, y, w, h)
	return (x - 47) / 750, y / 369, w / 750, h / 369
end

-- Live layout ----------------------------------------------------------------

function Layout.init() end

function Layout.mode()
	return "Wide"
end

function Layout.px(n)
	return n
end

function Layout.bindText(obj, size)
	obj.TextSize = math.min(size, 100)
end

function Layout.setSize(obj, size)
	obj.Size = size
end

function Layout.bindStroke(stroke, thickness)
	stroke.Thickness = thickness
end

function Layout.bindPadding(padding, x, y)
	y = y or x
	padding.PaddingLeft = UDim.new(0, x)
	padding.PaddingRight = UDim.new(0, x)
	padding.PaddingTop = UDim.new(0, y)
	padding.PaddingBottom = UDim.new(0, y)
end

-- Pixels the Roblox top bar reserves.
function Layout.topbar()
	return { left = 0, right = 0, height = 0 }
end

-- The boxes the Roblox top bar covers, in `canvas` coordinates: { { x, y, w, h } }.
function Layout.reserved(_canvas)
	return {}
end

function Layout.clearTop(obj, basePosition)
	obj.Position = basePosition
end

-- insets "Full" -> ScreenInsets None, "Safe" (default) -> DeviceSafeInsets. Never touches IgnoreGuiInset.
function Layout.screenGui(name, displayOrder, insets)
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.DisplayOrder = displayOrder
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.ScreenInsets = if insets == "Full" then Enum.ScreenInsets.None else Enum.ScreenInsets.DeviceSafeInsets
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	return gui
end

return Layout
