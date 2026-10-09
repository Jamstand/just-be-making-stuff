--[[
    The pure geometry behind the menus' slanted and cut shapes (menus design
    5.3). Roblox can't clip to a slanted edge and clipping stops working under
    a rotated ancestor, so every shape is unrotated rectangles plus "wedges":
    an unrotated ClipsDescendants frame holding a rotated square whose edge is
    the slanted (or 45-degree) border. UIKit builds the frames from these
    numbers; tests/ui checks they tile without gaps and that the gradients
    meet at the seams.

    Rects are { x, y, w, h } in pixels inside the shape's own box; a wedge
    adds its square's centre (cx, cy, inside the wedge box), side and
    rotation (degrees, clockwise, like GuiObject.Rotation).

      slant(w, h, deg)       parallelogram "/" (top edge shifted right by
                             s = round(h * tan deg)); a negative deg mirrors
                             it to "\". Pieces: left wedge x in [0, s], middle
                             x in [s, w - s], right wedge x in [w - s, w].
      outset(w, h, deg, o)   the box of the same parallelogram grown by o on
                             every edge (outlines, glows, shadows).
      cut(w, h, c)           panel with its top-right and bottom-left corners
                             cut at 45 degrees by c: three rects + two wedges.
      cutBorder(c, b)        the cut of that panel grown by b, so a border
                             is b thick on the diagonals too.
      ringRotations(f)       the two half-ring gradient rotations that fill
                             a countdown ring clockwise from 12 o'clock.
]]

local Shapes = {}

local SQRT2 = math.sqrt(2)

local function round(x)
	return math.floor(x + 0.5)
end

-- The slant offset s (integer px) of a parallelogram h tall leaning `deg` degrees.
function Shapes.offset(h, deg)
	return round(h * math.tan(math.rad(math.abs(deg))))
end

--[[
    A wedge box `s` wide and `h` tall whose square (side 2h, rotated
    `theta` degrees) has one edge on the box's diagonal through
    (0, h) and (s, 0) ("/") or (0, 0) and (s, h) ("\"). side = 1 fills
    the part right of that edge (left wedge), -1 the part left of it.
    Returns the wedge and its gradient window: the vertical gradient on
    the square spans E = L (cos a + sin a) around the square's centre, so
    the box's band y in [0, h] is the part [t0, t1] of it.
]]
local function wedge(x, s, h, theta, side)
	local rad = math.rad(theta)
	local size = 2 * h
	local cx = round(s / 2 + side * h * math.cos(rad))
	local cy = round(h / 2 + side * h * math.sin(rad))
	local a = math.abs(rad)
	local span = size * (math.cos(a) + math.sin(a))
	local start = cy - span / 2
	return { x = x, y = 0, w = s, h = h, cx = cx, cy = cy, size = size, rotation = theta }, {
		t0 = (0 - start) / span,
		t1 = (h - start) / span,
	}
end

--[[
    Pieces of a w x h parallelogram leaning `deg` degrees (negative = "\"):
    { s, middle, left, right, leftWindow, rightWindow, gradientRotation }.
    gradientRotation is the wedges' UIGradient rotation that makes their
    gradient vertical on screen (the middle piece uses 90).
]]
function Shapes.slant(w, h, deg)
	w, h = math.max(0, round(w)), math.max(0, round(h))
	local sign = if deg < 0 then -1 else 1
	local theta = sign * math.abs(deg)
	local s = math.min(Shapes.offset(h, deg), math.floor(w / 2))
	local left, leftWindow = wedge(0, s, h, theta, 1)
	local right, rightWindow = wedge(w - s, s, h, theta, -1)
	return {
		s = s,
		middle = { x = s, y = 0, w = w - 2 * s, h = h },
		left = left,
		right = right,
		leftWindow = leftWindow,
		rightWindow = rightWindow,
		gradientRotation = 90 - theta,
	}
end

--[[
    The box of the parallelogram grown by o on every edge, relative to the
    original box: the top and bottom edges move o, the slanted edges move o
    perpendicular to themselves (o / cos a sideways, plus o * tan a for the
    taller box), so a ring drawn this way is o thick all round.
]]
function Shapes.outset(w, h, deg, o)
	local a = math.rad(math.abs(deg))
	local dx = round(o / math.cos(a) + o * math.tan(a))
	return { x = -dx, y = -o, w = w + 2 * dx, h = h + 2 * o }
end

--[[
    A w x h panel with its top-right and bottom-left corners cut at 45
    degrees by c: { c, rects = { top, middle, bottom }, wedges = { topRight,
    bottomLeft } }. Each wedge is a c x c box holding a square (side c * sqrt 2,
    rotation 45) centred on one of the box's corners, so its edge is the
    box's diagonal.
]]
function Shapes.cut(w, h, c)
	w, h = math.max(0, round(w)), math.max(0, round(h))
	c = math.max(0, math.min(round(c), math.floor(w / 2), math.floor(h / 2)))
	local size = c * SQRT2
	return {
		c = c,
		rects = {
			{ x = 0, y = 0, w = w - c, h = c },
			{ x = 0, y = c, w = w, h = h - 2 * c },
			{ x = c, y = h - c, w = w - c, h = c },
		},
		wedges = {
			-- top-right: fills below-left of the diagonal (0, 0) - (c, c)
			{ x = w - c, y = 0, w = c, h = c, cx = 0, cy = c, size = size, rotation = 45 },
			-- bottom-left: fills above-right of the same diagonal
			{ x = 0, y = h - c, w = c, h = c, cx = c, cy = 0, size = size, rotation = 45 },
		},
	}
end

-- The cut of a cut panel grown by b on every side, so its diagonal is b away from the original one.
function Shapes.cutBorder(c, b)
	return c + b * (2 - SQRT2)
end

--[[
    Gradient rotations (right half, left half) for a ring filled to
    `fraction` clockwise from 12 o'clock. Each half shows a circle whose
    stroke gradient is opaque on one side of a line through the centre;
    rotation r makes the transparent side the one the vector
    (cos r, sin r) points to (y down), so the opaque edge sits at r
    degrees clockwise from 12 o'clock.
]]
function Shapes.ringRotations(fraction)
	local f = math.clamp(fraction, 0, 1)
	return 360 * math.min(f, 0.5), 360 * math.max(f, 0.5)
end

return Shapes
