--[[
    Tests for the client shell's pure logic (menus design 6.5): focus
    navigation (FocusNav), the layout maths (Layout's pure helpers), the
    slanted / cut shapes and the countdown ring (Shapes), Focus's bindings
    and glyphs, and the main menu's view models (MenuModels).
    Run from the skybrawl folder with:  lune run tests/ui
]]

local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local h = require("./harness")

local Enum = roblox.Enum
local Vector2 = roblox.Vector2

local Config = h.require("Config")
local Events = h.require("Events")

local FocusNav = h.requireClientFile("UI/FocusNav")
local Layout = h.requireClientFile("UI/Layout")
local Shapes = h.requireClientFile("UI/Shapes")
local MenuModels = h.requireClientFile("UI/MenuModels")

-- 2026-10-12 12:00 UTC: inside the Shadow Week event (Oct 9-16) and Season 1.
local NOW = Events.parse("2026-10-12T12:00:00Z")

local function deepEqual(a, b)
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b
	end
	for k, v in a do
		if not deepEqual(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function describeValue(value)
	if type(value) == "table" then
		return serde.encode("json", value)
	end
	return tostring(value)
end

local function expectEqual(got, want, what)
	h.expect(deepEqual(got, want), string.format("%s: got %s, want %s", what, describeValue(got), describeValue(want)))
end

local function rect(id, x, y, w, hh)
	return { id = id, x = x, y = y, w = w or 100, h = hh or 40 }
end

-- FocusNav ---------------------------------------------------------------------

h.test("FocusNav follows explicit neighbours first", function()
	local from = rect("a", 0, 0)
	local near = rect("near", 0, 60)
	local far = rect("far", 0, 400)
	from.next = { Down = "far" }
	expectEqual(FocusNav.resolve(from, "Down", { near, far }), "far", "explicit Down")
	-- an explicit neighbour that can't take focus (not a candidate) falls back to the nearest
	from.next = { Down = "gone" }
	expectEqual(FocusNav.resolve(from, "Down", { near, far }), "near", "missing explicit neighbour")
	from.next = nil
	expectEqual(FocusNav.resolve(from, "Down", { near, far }), "near", "no explicit neighbour")
end)

h.test("FocusNav picks the nearest node in the pressed direction", function()
	local from = rect("from", 200, 200)
	local candidates = {
		rect("right", 400, 200),
		rect("rightFar", 700, 200),
		rect("rightBelow", 360, 300), -- closer along, but off-axis: 160 + 2 * 100 > 200
		rect("left", 0, 200),
		rect("up", 200, 0),
		rect("down", 200, 420),
	}
	expectEqual(FocusNav.nearest(candidates, from, "Right"), "right", "Right")
	expectEqual(FocusNav.nearest(candidates, from, "Left"), "left", "Left")
	expectEqual(FocusNav.nearest(candidates, from, "Up"), "up", "Up")
	expectEqual(FocusNav.nearest(candidates, from, "Down"), "down", "Down")
end)

h.test("FocusNav ignores nodes outside the cone", function()
	local from = rect("from", 0, 0)
	-- 300 right but 400 down: outside the Right cone, inside the Down cone
	local diagonal = rect("diagonal", 300, 400)
	h.expect(not FocusNav.inCone(from, diagonal, "Right"), "diagonal counted as Right")
	h.expect(FocusNav.inCone(from, diagonal, "Down"), "diagonal not counted as Down")
	expectEqual(FocusNav.nearest({ diagonal }, from, "Right"), nil, "Right past the cone")
	-- the source itself is never a candidate
	expectEqual(FocusNav.nearest({ rect("self", 0, 0) }, from, "Down"), nil, "the node itself")
end)

h.test("FocusNav returns nil at the edge instead of wrapping", function()
	local column = { rect(1, 0, 0), rect(2, 0, 60), rect(3, 0, 120) }
	expectEqual(FocusNav.nearest(column, column[3], "Down"), nil, "Down from the last row")
	expectEqual(FocusNav.nearest(column, column[1], "Up"), nil, "Up from the first row")
	expectEqual(FocusNav.nearest(column, column[1], "Down"), 2, "Down from the first row")
	expectEqual(FocusNav.resolve(column[3], "Down", column), nil, "resolve Down from the last row")
end)

h.test("FocusNav orders layers by band, then push order", function()
	local layers = {
		{ band = "modal", seq = 1 },
		{ band = "screen", seq = 2 },
		{ band = "overlay", seq = 3 },
		{ band = "screen", seq = 4 },
		{ band = "modal", seq = 5 },
	}
	expectEqual(FocusNav.order(layers), { 2, 4, 3, 1, 5 }, "order")
	expectEqual(FocusNav.order({}), {}, "no layers")
end)

h.test("input mode ignores TextInput, Gyro and Focus events", function()
	for _, name in { "TextInput", "Gyro", "Focus", "Accelerometer", "None" } do
		expectEqual(FocusNav.modeFor(name, "Gamepad"), "Gamepad", name .. " from Gamepad")
		expectEqual(FocusNav.modeFor(name, "Touch"), "Touch", name .. " from Touch")
	end
	for _, name in { "Keyboard", "MouseButton1", "MouseButton2", "MouseMovement", "MouseWheel" } do
		expectEqual(FocusNav.modeFor(name, "Gamepad"), "Keyboard", name)
	end
	expectEqual(FocusNav.modeFor("Gamepad1", "Keyboard"), "Gamepad", "Gamepad1")
	expectEqual(FocusNav.modeFor("Gamepad8", "Touch"), "Gamepad", "Gamepad8")
	expectEqual(FocusNav.modeFor("Touch", "Keyboard"), "Touch", "Touch")
	-- the stick reads a direction only past the threshold, on its stronger axis
	expectEqual(FocusNav.stickDir(0.3, 0.2), nil, "stick inside the threshold")
	expectEqual(FocusNav.stickDir(0.7, 0.2), "Right", "stick right")
	expectEqual(FocusNav.stickDir(0.2, -0.9), "Down", "stick down (y is up)")
	expectEqual(FocusNav.stickDir(-0.4, 0.6), "Up", "stick up")
end)

h.test("presses in the frame a layer appeared are ignored", function()
	-- pushed in frame 10 (during an input event: the key that pushed it reaches Focus in that same frame)
	local layer = { pushedFrame = 10, pushedAt = 100, confirmDelay = 0 }
	expectEqual(FocusNav.pressCounts(layer, 10), false, "same frame")
	expectEqual(FocusNav.pressCounts(layer, 11), true, "next frame")
	expectEqual(FocusNav.pressCounts(nil, 10), true, "no layer")
	expectEqual(FocusNav.confirmCounts(layer, 10, 100), false, "Confirm in the same frame")
	expectEqual(FocusNav.confirmCounts(layer, 11, 100), true, "Confirm next frame")
	-- a confirmDelay (results, legend select, prompts, dialogs) also holds Confirm back
	local grace = { pushedFrame = 10, pushedAt = 100, confirmDelay = 0.6 }
	expectEqual(FocusNav.confirmCounts(grace, 11, 100.5), false, "inside the grace")
	expectEqual(FocusNav.confirmCounts(grace, 40, 100.6), true, "after the grace")
end)

-- Layout -------------------------------------------------------------------------

h.test("Layout.modeFor picks Phone for short or narrow safe areas", function()
	expectEqual(Layout.modeFor(Vector2.new(1920, 1080)), "Wide", "1080p")
	expectEqual(Layout.modeFor(Vector2.new(1280, 720)), "Wide", "720p")
	expectEqual(Layout.modeFor(Vector2.new(750, 369)), "Phone", "phone landscape")
	expectEqual(Layout.modeFor(Vector2.new(1400, 480)), "Phone", "short window")
	expectEqual(Layout.modeFor(Vector2.new(880, 700)), "Phone", "narrow window")
	expectEqual(Layout.modeFor(Vector2.new(900, 500)), "Wide", "exactly at the limits")
end)

h.test("Layout.pxFor scales with height and enlarges text on phones", function()
	expectEqual(Layout.pxFor(54, 1080, "Wide"), 54, "1080p")
	expectEqual(Layout.pxFor(54, 2160, "Wide"), 108, "4K")
	expectEqual(Layout.pxFor(54, 720, "Wide"), 36, "720p")
	-- phone: 54 * 369 / 1080 = 18.45, times 1.6 = 29.52
	expectEqual(Layout.pxFor(54, 369, "Phone"), 30, "phone")
	h.expect(Layout.pxFor(54, 369, "Phone") > Layout.pxFor(54, 369, "Wide"), "phone text isn't larger")
end)

h.test("text above 100 px uses a UIScale", function()
	local size, scale = Layout.textFit(54)
	expectEqual({ size, scale }, { 54, 1 }, "54 px")
	size, scale = Layout.textFit(100)
	expectEqual({ size, scale }, { 100, 1 }, "100 px")
	size, scale = Layout.textFit(250)
	expectEqual({ size, scale }, { 100, 2.5 }, "the logo (250 px)")
	size, scale = Layout.textFit(Layout.pxFor(110, 2160, "Wide"))
	expectEqual({ size, scale }, { 100, 2.2 }, "a screen title at 4K")
end)

h.test("elements under the top bar are pushed below it", function()
	local boxes = { { x = 0, y = 0, w = 120, h = 58 }, { x = 1800, y = 0, w = 120, h = 58 } }
	-- the main menu logo at (63, 40) overlaps the left box: its top moves to 58 + 8
	expectEqual(Layout.pushFor({ x = 63, y = 40, w = 330, h = 90 }, boxes, 8), 26, "logo")
	-- an element between the boxes stays
	expectEqual(Layout.pushFor({ x = 640, y = 20, w = 640, h = 76 }, boxes, 8), 0, "queue banner")
	-- an element already below the bar stays
	expectEqual(Layout.pushFor({ x = 63, y = 80, w = 330, h = 90 }, boxes, 8), 0, "below the bar")
	-- a zero-sized box (no top bar) never pushes
	expectEqual(Layout.pushFor({ x = 0, y = 0, w = 100, h = 100 }, { { x = 0, y = 0, w = 0, h = 58 } }, 8), 0, "no bar")
end)

h.test("phone mockup rects convert inside the safe area", function()
	-- ONLINE PLAY on the 844 x 390 phone mockup: (86, 50) 296 x 54
	local x, y, w, hh = Layout.phoneRect(86, 50, 296, 54)
	h.near(x, 39 / 750, 1e-9, "x")
	h.near(y, 50 / 369, 1e-9, "y")
	h.near(w, 296 / 750, 1e-9, "w")
	h.near(hh, 54 / 369, 1e-9, "h")
	-- the right column (x 640 - 796) stays inside the safe area (47 px insets)
	local rx, _, rw = Layout.phoneRect(640, 0, 156, 0)
	h.expect(rx >= 0 and rx + rw <= 1, "right column leaves the safe area")
	-- the party slots at y 318 (52 tall) end at the home indicator (within a pixel)
	local _, py, _, ph = Layout.phoneRect(0, 318, 0, 52)
	h.expect(py + ph <= 1 + 1 / 369 + 1e-9, "party slots run under the home indicator")
end)

-- Shapes -------------------------------------------------------------------------

h.test("Shapes.slant pieces tile the parallelogram without gaps or overlap", function()
	for _, case in { { 540, 70, 14 }, { 300, 120, 6 }, { 200, 90, -10 }, { 51, 33, 14 } } do
		local w, hh, deg = case[1], case[2], case[3]
		local shape = Shapes.slant(w, hh, deg)
		local what = string.format("%dx%d at %d", w, hh, deg)
		local s = shape.s
		expectEqual(s, math.floor(hh * math.tan(math.rad(math.abs(deg))) + 0.5), what .. " offset")
		local pieces = { shape.left, shape.middle, shape.right }
		local x = 0
		for i, piece in pieces do
			expectEqual(piece.x, x, what .. " piece " .. i .. " starts where the last ended")
			expectEqual({ piece.y, piece.h }, { 0, hh }, what .. " piece " .. i .. " height")
			for _, v in { piece.x, piece.w } do
				h.expect(v == math.floor(v), what .. " non-integer offset")
			end
			x += piece.w
		end
		expectEqual(x, w, what .. " total width")
		-- each wedge's square edge runs along the slanted edge through the box's corners
		for _, wedge in { shape.left, shape.right } do
			local rad = math.rad(wedge.rotation)
			local nx, ny = math.cos(rad), math.sin(rad)
			local cornerA = if deg >= 0 then { 0, hh } else { 0, 0 }
			local cornerB = if deg >= 0 then { s, 0 } else { s, hh }
			for _, corner in { cornerA, cornerB } do
				local distance = math.abs((corner[1] - wedge.cx) * nx + (corner[2] - wedge.cy) * ny)
				h.near(distance, wedge.size / 2, 1, what .. " square edge on the corner")
			end
		end
	end
end)

h.test("slant wedge gradients match the middle piece at the seams", function()
	-- The engine rule: a UIGradient on an element rotated r with gradient rotation g spans the element's
	-- projection on the screen direction r + g, centred on the element. Recompute the colour of the wedge
	-- squares at the seam (x = s for the left wedge, x = 0 for the right one) from that rule.
	local top, bottom = 39, 22 -- ButtonTop / ButtonBottom red channel
	for _, case in { { 540, 70, 14 }, { 260, 160, 6 }, { 300, 80, -10 } } do
		local w, hh, deg = case[1], case[2], case[3]
		local shape = Shapes.slant(w, hh, deg)
		for name, wedge in { left = shape.left, right = shape.right } do
			local window = if name == "left" then shape.leftWindow else shape.rightWindow
			local seamX = if name == "left" then shape.s else 0
			local g = math.rad(wedge.rotation + shape.gradientRotation) -- screen direction of the gradient
			h.near(math.deg(g), 90, 1e-9, name .. " gradient isn't vertical on screen")
			local a = math.rad(math.abs(wedge.rotation))
			local span = wedge.size * (math.cos(a) + math.sin(a))
			for y = 0, hh, hh / 8 do
				local t = ((seamX - wedge.cx) * math.cos(g) + (y - wedge.cy) * math.sin(g)) / span + 0.5
				local u = math.clamp((t - window.t0) / (window.t1 - window.t0), 0, 1)
				local wedgeColor = top + (bottom - top) * u
				local middleColor = top + (bottom - top) * (y / hh)
				h.near(
					wedgeColor,
					middleColor,
					1,
					string.format("%s seam at y %.1f (%dx%d, %d deg)", name, y, w, hh, deg)
				)
			end
			h.expect(window.t0 > 0 and window.t1 < 1 and window.t0 < window.t1, name .. " window outside 0..1")
		end
	end
end)

h.test("outlines are equally thick on slanted and straight edges", function()
	for _, case in { { 540, 70, 14, 4 }, { 540, 70, 14, 8 }, { 300, 120, 6, 16 }, { 200, 90, -10, 4 } } do
		local w, hh, deg, o = case[1], case[2], case[3], case[4]
		local box = Shapes.outset(w, hh, deg, o)
		local what = string.format("%dx%d at %d, outline %d", w, hh, deg, o)
		expectEqual({ box.y, box.h }, { -o, hh + 2 * o }, what .. " top and bottom")
		expectEqual(box.x + box.w / 2, w / 2, what .. " centred")
		-- the outer shape's left slanted edge, drawn with Shapes.slant at the outset box
		local outer = Shapes.slant(box.w, box.h, deg)
		local inner = Shapes.slant(w, hh, deg)
		local a = math.rad(math.abs(deg))
		-- signed distance from the inner left edge's line to a point, measured outward
		local function lineDistance(px, py, ax, ay)
			-- the edge leans by a; its outward normal points left (and up / down with the lean)
			local nx, ny = -math.cos(a), if deg >= 0 then -math.sin(a) else math.sin(a)
			return (px - ax) * nx + (py - ay) * ny
		end
		local innerAnchor = if deg >= 0 then { 0, hh } else { 0, 0 }
		local outerCorner = if deg >= 0 then { box.x, box.y + box.h } else { box.x, box.y }
		local outerOther = if deg >= 0 then { box.x + outer.s, box.y } else { box.x + outer.s, box.y + box.h }
		for _, p in { outerCorner, outerOther } do
			h.near(lineDistance(p[1], p[2], innerAnchor[1], innerAnchor[2]), o, 1, what .. " slanted edge")
		end
		h.expect(inner.s >= 0, what .. " inner shape")
	end
	-- cut panels: the border's diagonal is b away from the panel's diagonal
	for _, case in { { 22, 2 }, { 22, 4 }, { 12, 3 } } do
		local c, b = case[1], case[2]
		local outer = Shapes.cutBorder(c, b)
		-- inner diagonal x - y = W - c; outer (box grown by b): x - y = (W + b - outer) + b
		h.near(((2 * b - outer) - -c) / math.sqrt(2), b, 1e-9, string.format("cut %d border %d", c, b))
	end
end)

h.test("Shapes.cut corners are 45 degrees and the given size", function()
	local w, hh, c = 460, 420, 22
	local shape = Shapes.cut(w, hh, c)
	expectEqual(shape.c, c, "cut")
	local area = 0
	for _, r in shape.rects do
		area += r.w * r.h
	end
	for _, wedge in shape.wedges do
		expectEqual({ wedge.w, wedge.h, wedge.rotation }, { c, c, 45 }, "wedge box")
		area += c * c / 2
		-- the square's edge is the box's diagonal from (0, 0) to (c, c)
		local nx, ny = math.cos(math.rad(45)), -math.sin(math.rad(45))
		for _, corner in { { 0, 0 }, { c, c } } do
			local distance = math.abs((corner[1] - wedge.cx) * nx + (corner[2] - wedge.cy) * ny)
			h.near(distance, wedge.size / 2, 1e-9, "square edge on the diagonal")
		end
	end
	h.near(area, w * hh - c * c, 1e-9, "filled area")
	expectEqual({ shape.wedges[1].x, shape.wedges[1].y }, { w - c, 0 }, "top-right corner")
	expectEqual({ shape.wedges[2].x, shape.wedges[2].y }, { 0, hh - c }, "bottom-left corner")
	-- the cut never eats more than half the panel
	expectEqual(Shapes.cut(30, 20, 22).c, 10, "clamped cut")
end)

h.test("the ring fills clockwise from 12 o'clock", function()
	-- A half shows a point at angle q (clockwise from 12) when the point is on its side of the centre and
	-- the gradient (rotation r) is opaque there: the transparent side is the direction (cos r, sin r).
	local function shown(fraction, q)
		local right, left = Shapes.ringRotations(fraction)
		local px, py = math.sin(math.rad(q)), -math.cos(math.rad(q))
		local r = if px >= 0 then right else left
		return px * math.cos(math.rad(r)) + py * math.sin(math.rad(r)) < 0
	end
	for _, fraction in { 0.1, 0.25, 0.4, 0.6, 0.75, 0.9 } do
		for q = 5, 355, 10 do
			local want = q < fraction * 360
			h.expect(
				shown(fraction, q) == want,
				string.format("fraction %.2f, angle %d: shown = %s", fraction, q, tostring(not want))
			)
		end
	end
	expectEqual({ Shapes.ringRotations(0) }, { 0, 180 }, "empty")
	expectEqual({ Shapes.ringRotations(0.5) }, { 180, 180 }, "half")
	expectEqual({ Shapes.ringRotations(1) }, { 180, 360 }, "full")
	expectEqual({ Shapes.ringRotations(2) }, { 180, 360 }, "clamped")
end)

-- Focus ----------------------------------------------------------------------------

h.test("every Focus action has a keyboard and a gamepad binding and a glyph, and Escape is not bound", function()
	local Focus = h.requireClientFile("UI/Focus")
	local names = { "Confirm", "Back", "X", "Y", "L1", "R1", "L2", "R2", "Menu", "Up", "Down", "Left", "Right" }
	for _, action in names do
		local binding = Focus.ACTIONS[action]
		h.expect(binding ~= nil, action .. " has no binding")
		h.expect(#binding.Keyboard > 0 and #binding.Gamepad > 0, action .. " lacks a keyboard or gamepad key")
		for _, mode in { "Keyboard", "Gamepad" } do
			local glyph = Focus.glyphFor(action, mode)
			h.expect(type(glyph.text) == "string" and glyph.text ~= "", action .. " has no " .. mode .. " glyph")
		end
		for _, device in { "Keyboard", "Gamepad" } do
			for _, key in binding[device] do
				h.expect(key ~= "Escape", action .. " is bound to Escape")
				h.expect(Enum.KeyCode[key] ~= nil, action .. ": unknown key " .. key)
			end
		end
	end
	expectEqual(Focus.glyphFor("Confirm", "Keyboard").text, "ENTER", "keyboard Confirm")
	expectEqual(Focus.glyphFor("Back", "Keyboard").text, "BKSP", "keyboard Back")
	expectEqual(Focus.glyphFor("Back", "Gamepad").text, "B", "gamepad Back")
	-- Escape and gamepad Start belong to Roblox
	for _, binding in Focus.ACTIONS do
		h.expect(not table.find(binding.Gamepad, "ButtonStart"), "ButtonStart is bound")
	end
end)

-- MenuModels ---------------------------------------------------------------------

h.test("featured tiles list active events before news", function()
	local tiles = MenuModels.featuredTiles(NOW)
	expectEqual(tiles[1].id, "ShadowWeek", "first tile")
	expectEqual(tiles[1].kind, "Event", "first tile kind")
	expectEqual(tiles[1].screen, "Legends", "event screen")
	expectEqual(tiles[1].params, { legend = "Vex" }, "event screen params")
	h.near(tiles[1].endsIn, Events.parse("2026-10-16T00:00:00Z") - NOW, 1e-9, "event time left")
	for i, news in Config.News do
		expectEqual(tiles[1 + i].id, news.Id, "news tile " .. i)
		expectEqual(tiles[1 + i].kind, "News", "news tile kind " .. i)
	end
	expectEqual(#tiles, 1 + #Config.News, "tile count")
	-- before the events start only the news shows; during Launch Weekend it leads
	expectEqual(#MenuModels.featuredTiles(Events.parse("2026-10-01T00:00:00Z")), #Config.News, "before events")
	expectEqual(MenuModels.featuredTiles(Events.parse("2026-10-17T00:00:00Z"))[1].id, "LaunchCoins", "launch weekend")
end)

h.test("mission rows show DONE, CLAIM and the reroll state", function()
	local missions = {
		day = 20738,
		resetAt = NOW + 7 * 3600 + 42 * 60,
		rerollAvailable = true,
		claimable = 1,
		list = {
			{
				index = 1,
				id = "OnlineWins",
				text = "Win 2 online matches",
				progress = 1,
				goal = 2,
				coins = 120,
				xp = 150,
				done = false,
				claimed = false,
			},
			{
				index = 2,
				id = "WeaponDamage",
				text = "Deal 1,500 damage with a Sword",
				progress = 1500,
				goal = 1500,
				coins = 100,
				xp = 120,
				done = true,
				claimed = false,
			},
			{
				index = 3,
				id = "KOs",
				text = "KO 8 opponents",
				progress = 8,
				goal = 8,
				coins = 70,
				xp = 90,
				done = true,
				claimed = true,
			},
		},
	}
	local view = MenuModels.missionRows(missions, NOW)
	expectEqual(view.loading, false, "loading")
	expectEqual(view.resetIn, "7h 42m", "reset countdown")
	expectEqual(view.footer, "1 free reroll left today", "footer")
	local r1, r2, r3 = view.rows[1], view.rows[2], view.rows[3]
	expectEqual(
		{ r1.status, r1.tag, r1.rerollable, r1.claimable, r1.barColor },
		{ "1/2", nil, true, false, "Red" },
		"row 1"
	)
	h.near(r1.fraction, 0.5, 1e-9, "row 1 bar")
	expectEqual(
		{ r2.status, r2.tag, r2.rerollable, r2.claimable, r2.barColor },
		{ "DONE", "CLAIM", false, true, "Gold" },
		"row 2"
	)
	expectEqual({ r3.status, r3.tag, r3.rerollable, r3.claimable }, { "DONE", "CLAIMED", false, false }, "row 3")
	expectEqual(r2.index, 2, "rows keep the mission index")
	missions.rerollAvailable = false
	view = MenuModels.missionRows(missions, NOW)
	expectEqual(view.footer, "Reroll used", "footer after the reroll")
	expectEqual(view.rows[1].rerollable, false, "no reroll icon after the reroll")
	-- no profile yet: the loading state
	local loading = MenuModels.missionRows(nil, NOW)
	expectEqual({ loading.loading, #loading.rows }, { true, 0 }, "loading state")
end)

h.test("queue banner text shows the window only for ranked", function()
	local ranked = {
		queue = "Ranked1v1",
		label = "Ranked 1v1",
		waited = 20,
		inQueue = 3,
		waitingForArena = false,
		window = 240,
		partySize = 1,
		leaderUserId = 1,
	}
	local line = MenuModels.queueLine(ranked, 3.4)
	expectEqual(
		{ line.title, line.label, line.timer, line.count, line.window },
		{ "SEARCHING", "Ranked 1v1", "0:23", "3 in queue", "±240 rating" },
		"ranked"
	)
	ranked.window = nil
	expectEqual(MenuModels.queueLine(ranked, 0).window, nil, "ranked once anyone is allowed")
	local ffa = {
		queue = "FFA",
		label = "Free-for-all",
		waited = 65,
		inQueue = 2,
		waitingForArena = true,
		window = 300,
		partySize = 1,
		leaderUserId = 1,
	}
	line = MenuModels.queueLine(ffa, 0)
	expectEqual({ line.title, line.timer, line.window }, { "WAITING FOR AN ARENA", "1:05", nil }, "FFA")
end)

h.test("chat is hidden in title, select and vs", function()
	for phase, want in { Title = false, Select = false, Vs = false, Menu = true, Results = true, Match = true } do
		expectEqual(MenuModels.chatEnabled(phase), want, phase)
	end
end)

h.test("party slots put you first, then members, invites and INVITE slots", function()
	local you = { userId = 1, name = "SkyRunner_07", legend = "Kestrel" }
	local solo = MenuModels.partySlots(nil, {}, you)
	expectEqual(#solo, Config.Party.MaxSize, "slot count")
	expectEqual(
		{ solo[1].kind, solo[2].kind, solo[2].label, solo[3].label },
		{ "You", "Invite", "INVITE", "+" },
		"solo"
	)
	local party = {
		id = 7,
		leaderUserId = 2,
		maxSize = 4,
		members = {
			{ userId = 2, name = "pixelbrawler", level = 3, legend = "Vex", isLeader = true, status = "Menu" },
			{ userId = 1, name = "SkyRunner_07", level = 27, legend = "Kestrel", isLeader = false, status = "Menu" },
		},
		pending = { { userId = 3, name = "zeroframe", waiting = true } },
	}
	local slots = MenuModels.partySlots(party, {}, you)
	expectEqual(
		{ slots[1].kind, slots[2].kind, slots[2].name, slots[3].kind, slots[3].label, slots[4].kind },
		{ "You", "Member", "pixelbrawler", "Invited", "INVITED · IN A MATCH", "Empty" },
		"member view"
	)
	expectEqual(MenuModels.canInvite(party, 1), false, "members can't invite")
	expectEqual(MenuModels.canInvite(party, 2), true, "the leader can")
	-- every slot has a key that follows its person, so a slot's instance never shows someone else
	expectEqual({ slots[1].key, slots[2].key, slots[3].key }, { "p1", "p2", "i3" }, "slot keys")
	-- focus on a slot whose person left: an INVITE slot now there, else your own slot, never another person
	local led = MenuModels.partySlots({
		id = 8,
		leaderUserId = 1,
		maxSize = 4,
		members = {
			{ userId = 1, name = "SkyRunner_07", legend = "Kestrel", isLeader = true, status = "Menu" },
			{ userId = 4, name = "lastone", legend = "Sol", isLeader = false, status = "Menu" },
		},
		pending = {},
	}, {}, you)
	expectEqual(MenuModels.partyFocusAfter(led, 3), 3, "an INVITE slot took the place")
	expectEqual(MenuModels.partyFocusAfter(led, 2), 1, "another member took the place")
	expectEqual(MenuModels.partyFocusAfter(led, 9), 1, "past the end")
end)

h.test("the main menu hints follow the queue and the invite rule", function()
	local function actions(list)
		local out = {}
		for _, item in list do
			table.insert(out, item.action .. " " .. item.label)
		end
		return out
	end
	expectEqual(actions(MenuModels.mainHints(false, true)), { "Confirm SELECT", "X INVITE", "Y CHANGE" }, "idle")
	expectEqual(
		actions(MenuModels.mainHints(true, false)),
		{ "Confirm SELECT", "Back CANCEL SEARCH", "Y CHANGE" },
		"searching in someone else's party"
	)
end)

h.test("the main menu hints say CLAIM and REROLL on a focused mission row", function()
	local function actions(list)
		local out = {}
		for _, item in list do
			table.insert(out, item.action .. " " .. item.label)
		end
		return out
	end
	-- a row that can be rerolled: its own X wins over INVITE, so the hint says REROLL
	expectEqual(
		actions(MenuModels.mainHints(false, true, { claimable = false, rerollable = true })),
		{ "Confirm SELECT", "X REROLL", "Y CHANGE" },
		"rerollable row"
	)
	expectEqual(
		actions(MenuModels.mainHints(true, true, { claimable = true, rerollable = false })),
		{ "Confirm CLAIM", "Back CANCEL SEARCH", "X INVITE", "Y CHANGE" },
		"claimable row while searching"
	)
	-- a row with nothing to do: X still invites
	expectEqual(
		actions(MenuModels.mainHints(false, true, { claimable = false, rerollable = false })),
		{ "Confirm SELECT", "X INVITE", "Y CHANGE" },
		"finished row"
	)
	expectEqual(
		actions(MenuModels.mainHints(false, false, { claimable = false, rerollable = true })),
		{ "Confirm SELECT", "X REROLL", "Y CHANGE" },
		"rerollable row for a party member"
	)
end)

h.test("invite prompts skip invites still waiting and expired ones", function()
	local waiting = { partyId = 1, fromName = "a", size = 2, expiresAt = nil }
	local expired = { partyId = 2, fromName = "b", size = 2, expiresAt = NOW - 1 }
	local live = { partyId = 3, fromName = "c", size = 3, expiresAt = NOW + 20 }
	expectEqual(MenuModels.promptInvite({ waiting, expired, live }, NOW), live, "the live one")
	expectEqual(MenuModels.promptInvite({ waiting, expired }, NOW), nil, "none running")
	expectEqual(MenuModels.promptInvite({ live, { partyId = 4, expiresAt = NOW + 5 } }, NOW), live, "the first one")
	expectEqual(MenuModels.promptInvite({ { partyId = 5, expiresAt = NOW } }, NOW), nil, "expiring now")
	expectEqual(MenuModels.promptInvite(nil, NOW), nil, "no invites")
end)

h.test("countdowns, the backdrop map and the title labels", function()
	expectEqual(MenuModels.timeLeft(7 * 3600 + 42 * 60 + 5), "7h 42m", "hours")
	expectEqual(MenuModels.timeLeft(3 * 86400 + 4 * 3600), "3d 4h", "days")
	expectEqual(MenuModels.timeLeft(125), "2m", "minutes")
	expectEqual(MenuModels.timeLeft(-5), "0s", "past")
	expectEqual(MenuModels.backdropMap("SkyShip", h.Random.new(1)), "SkyShip", "a map")
	expectEqual(MenuModels.backdropMap("Nowhere", h.Random.new(1)), "SkyShip", "an unknown map")
	-- no painted skies are uploaded yet: Random falls back to the Sky-Ship
	expectEqual(MenuModels.backdropMap("Random", h.Random.new(1)), "SkyShip", "Random without painted skies")
	local left, right = MenuModels.titleLabels(NOW)
	expectEqual(left, "SEASON 1 · v" .. Config.GameVersion, "season label")
	expectEqual(right, "6 LEGENDS · 8 MAPS", "roster label")
end)

h.test("every client shell module loads", function()
	for _, path in
		{
			"UI/Layout",
			"UI/Focus",
			"UI/UIKit",
			"UI/Toasts",
			"UI/LegendView",
			"UI/MissionsWidget",
			"UI/FeaturedPanel",
			"UI/PlayerCard",
			"UI/QueueBanner",
			"UI/PartyBar",
			"UI/MainMenu",
			"UI/MenuShell",
			"UI/TitleScreen",
			"Controllers/Controls",
			"Controllers/Music",
		}
	do
		local ok, err = pcall(h.requireClientFile, path)
		h.expect(ok, path .. " failed to load: " .. tostring(err))
	end
	local LegendView = h.requireClientFile("UI/LegendView")
	expectEqual(LegendView.weaponFor("Brann"), "Gauntlets", "Brann's menu weapon")
	expectEqual(LegendView.weaponFor("Kestrel"), "Sword", "Kestrel's menu weapon")
	expectEqual(LegendView.weaponFor("Avatar"), nil, "Avatar holds nothing")
	-- a Full-framed view: 0.66 of it is body, the feet 4% above its bottom
	local position, size = LegendView.fullFrame(0.565, 0.88, 0.56)
	-- (UDim scales are 32-bit floats)
	h.near(size.Y.Scale, 0.56 / 0.66, 1e-5, "frame height")
	h.near(size.X.Scale, 0.8 * 0.56 / 0.66, 1e-5, "frame width")
	h.near(position.Y.Scale - 0.04 * size.Y.Scale, 0.88, 1e-5, "feet")
end)

h.finish()
