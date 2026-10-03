-- ItemBarLayout: where the item bar sits on this screen. Plain maths, no Roblox calls, so ItemBar
-- (which places the bar) and the HUD (which keeps the carry banner and the drawer list above it)
-- always agree, and it can be checked outside Studio.
--
-- Sizes are reference px (Theme: a 720 px tall screen). The bar is a cream tray along the bottom
-- centre with the towel slot (biggest: the main action on phones) and LoadoutSize item slots.
-- Touch screens: the slots stay at least 44 real px whatever the UI size setting (the bar grows
-- past its normal size for that if it must); when the centred bar would reach the touch jump button
-- (bottom-right) it is lifted above it, and when it would run under the left menu column it shrinks
-- a little to fit below it, or moves right of it.
local ItemBarLayout = {}

ItemBarLayout.Towel = 84 -- the towel slot
ItemBarLayout.Slot = 68 -- an item slot (68 x 0.72 = 49 real px on a phone)
ItemBarLayout.Gap = 8 -- between item slots
ItemBarLayout.TowelGap = 14 -- between the towel and the first item slot
ItemBarLayout.Pad = 10 -- the tray's padding left and right
ItemBarLayout.TrayInset = 6 -- the tray reaches this far above and below the item slots
ItemBarLayout.Top = 4 -- room above the towel slot for its outline
ItemBarLayout.Edge = 12 -- least gap to the sides of the screen
ItemBarLayout.Bottom = 10 -- gap under the bar
ItemBarLayout.ColumnGap = 6 -- least gap to the menu column
ItemBarLayout.MinFit = 0.75 -- under the column the bar shrinks this far before it moves beside it
ItemBarLayout.MinTouch = 44 -- real px: the smallest an item slot gets on a touch screen
ItemBarLayout.CarryGap = 14 -- between the bar's top and the HUD's carry banner

-- Roblox's touch jump button, as a keep-out corner measured from the bottom-right in real px
-- (PlayerModule TouchJump: a 70 px button at (W - 95, H - 90) when the screen's short side is
-- <= 500 px, else 120 px at (W - 170, H - 210)); rounded up.
ItemBarLayout.JumpSmall = { right = 120, top = 120 }
ItemBarLayout.JumpLarge = { right = 180, top = 220 }
ItemBarLayout.JumpMargin = 8 -- real px between the jump button and a lifted bar

export type Layout = {
	width: number, -- the bar's own size (before `fit`)
	height: number,
	fit: number, -- the bar's UIScale on narrow screens (1 = full size)
	x: number, -- the bar's centre, from the left edge
	bottom: number, -- gap from the bottom edge to the bar
	top: number, -- from the bottom edge to the bar's top (bottom + height * fit)
	left: number, -- the bar's x range after `fit`
	right: number,
	lifted: boolean, -- moved above the jump button
	besideColumn: boolean, -- moved right of the menu column
}

function ItemBarLayout.Size(slots: number): (number, number)
	local L = ItemBarLayout
	local width = 2 * L.Pad + L.Towel + L.TowelGap + slots * L.Slot + math.max(slots - 1, 0) * L.Gap
	local height = L.Top + L.Towel + L.TrayInset
	return width, height
end

-- refWidth / refHeight: the screen in reference px; scale: reference -> real px (Theme.Scale());
-- touch: phone / tablet controls; slots: item slots next to the towel; column: the menu column's
-- right edge and bottom (reference px), when it is on screen.
function ItemBarLayout.Compute(refWidth: number, refHeight: number, scale: number, touch: boolean, slots: number, column: { right: number, bottom: number }?): Layout
	local L = ItemBarLayout
	local s = math.max(scale, 0.01)
	local width, height = L.Size(slots)
	local minX, maxX = L.Edge, refWidth - L.Edge
	-- touch: never smaller than MinTouch real px a slot (while the screen is wide enough for that)
	local minFit = if touch then math.min(L.MinTouch / (L.Slot * s), (maxX - minX) / width) else 0

	local function place(lo: number, hi: number): (number, number, number, number)
		local fit = math.max(math.clamp((hi - lo) / width, 0.05, 1), minFit)
		local x = (lo + hi) / 2
		local half = width * fit / 2
		return fit, x, x - half, x + half
	end

	-- the jump button: lift the bar above it when the centred bar would reach its corner
	local function lift(right: number): (number, boolean)
		if not touch then
			return L.Bottom, false
		end
		local realW, realH = refWidth * s, refHeight * s
		local zone = if math.min(realW, realH) <= 500 then L.JumpSmall else L.JumpLarge
		if right * s > realW - zone.right then
			return math.max(L.Bottom, (zone.top + L.JumpMargin) / s), true
		end
		return L.Bottom, false
	end

	local fit, x, left, right = place(minX, maxX)
	local bottom, lifted = lift(right)
	local besideColumn = false
	if column and left < column.right + L.ColumnGap then
		-- under the column: a little smaller still fits below it (centred), else move right of it
		local room = refHeight - bottom - (column.bottom + L.ColumnGap)
		if height * fit > room then
			if room / height >= math.max(L.MinFit, minFit) then
				fit = room / height
				left, right = x - width * fit / 2, x + width * fit / 2
			else
				besideColumn = true
				fit, x, left, right = place(column.right + L.ColumnGap, maxX)
				bottom, lifted = lift(right)
			end
		end
	end
	return {
		width = width,
		height = height,
		fit = fit,
		x = x,
		bottom = bottom,
		top = bottom + height * fit,
		left = left,
		right = right,
		lifted = lifted,
		besideColumn = besideColumn,
	}
end

return ItemBarLayout
