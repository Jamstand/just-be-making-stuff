--[[
    The pure half of menu navigation (menus design 5.2), kept out of Focus
    so it can be tested under Lune:

      resolve / nearest   which node a direction press moves to: the
                          explicit neighbour when it can take focus, else
                          the nearest node whose centre lies in the
                          90-degree cone of the direction (score = distance
                          along the direction + 2 x the distance across
                          it). Nothing wraps: past the edge the answer is nil.
      modeFor             the input mode ("Keyboard" | "Gamepad" | "Touch")
                          an input type means; mouse counts as Keyboard and
                          types that say nothing about the device (TextInput,
                          Focus, Gyro, Accelerometer, None) keep the mode.
      order               the focus layers sorted by band (screen < overlay <
                          modal), then push order; the last one is on top.
      stickDir            the direction a thumbstick position points.
      pressCounts /       whether a key press reaches a layer: a press that
      confirmCounts       arrives in the frame the layer was pushed began
                          before it appeared (it is the key that opened it,
                          seen by a later handler of the same input event),
                          so it never counts; Confirm also waits out the
                          layer's confirmDelay (Focus holds Back for it too).

    Rects are { x, y, w, h } in screen pixels, y growing downward.
]]

local FocusNav = {}

FocusNav.BANDS = { screen = 1, overlay = 2, modal = 3 }
FocusNav.STICK_THRESHOLD = 0.5
FocusNav.REPEAT_DELAY = 0.35 -- a held direction repeats after this long...
FocusNav.REPEAT_EVERY = 0.09 -- ...then this often

local KEYBOARD_TYPES = {
	Keyboard = true,
	MouseButton1 = true,
	MouseButton2 = true,
	MouseButton3 = true,
	MouseMovement = true,
	MouseWheel = true,
}

local function centre(rect)
	return rect.x + rect.w / 2, rect.y + rect.h / 2
end

-- (along, across): how far `to`'s centre is from `from`'s along `dir` and across it.
local function offsets(from, to, dir)
	local fx, fy = centre(from)
	local tx, ty = centre(to)
	local dx, dy = tx - fx, ty - fy
	if dir == "Right" then
		return dx, math.abs(dy)
	elseif dir == "Left" then
		return -dx, math.abs(dy)
	elseif dir == "Down" then
		return dy, math.abs(dx)
	elseif dir == "Up" then
		return -dy, math.abs(dx)
	end
	return 0, math.huge
end

-- True when `to`'s centre lies in the 90-degree cone of `dir` from `from`'s centre.
function FocusNav.inCone(from, to, dir)
	local along, across = offsets(from, to, dir)
	return along > 0 and across <= along
end

-- The id of the best candidate ({ id, x, y, w, h }) in direction `dir` from `from`, or nil.
function FocusNav.nearest(candidates, from, dir)
	local best, bestScore = nil, math.huge
	for _, candidate in candidates do
		local along, across = offsets(from, candidate, dir)
		if along > 0 and across <= along then
			local score = along + 2 * across
			if score < bestScore then
				best, bestScore = candidate.id, score
			end
		end
	end
	return best
end

--[[
    Where a press of `dir` goes from `from` ({ x, y, w, h, next = { [dir] = id }? }):
    the explicit neighbour from.next[dir] when it is one of the candidates
    (that is, it can take focus now), else FocusNav.nearest.
]]
function FocusNav.resolve(from, dir, candidates)
	local explicit = from.next and from.next[dir]
	if explicit ~= nil then
		for _, candidate in candidates do
			if candidate.id == explicit then
				return explicit
			end
		end
	end
	return FocusNav.nearest(candidates, from, dir)
end

-- The input mode an input type (Enum.UserInputType name) means; `current` for types that don't tell.
function FocusNav.modeFor(inputTypeName, current)
	if KEYBOARD_TYPES[inputTypeName] then
		return "Keyboard"
	elseif string.match(inputTypeName, "^Gamepad%d$") then
		return "Gamepad"
	elseif inputTypeName == "Touch" then
		return "Touch"
	end
	return current
end

-- Indices of `layers` ({ band, seq }) sorted by band, then push order (seq); the last is the top layer.
function FocusNav.order(layers)
	local indices = {}
	for i in layers do
		table.insert(indices, i)
	end
	table.sort(indices, function(a, b)
		local la, lb = layers[a], layers[b]
		local ba, bb = FocusNav.BANDS[la.band] or 1, FocusNav.BANDS[lb.band] or 1
		if ba ~= bb then
			return ba < bb
		end
		return la.seq < lb.seq
	end)
	return indices
end

-- False for a press that arrives in the frame `layer` ({ pushedFrame }) was pushed (frames count up once per frame).
function FocusNav.pressCounts(layer, frame)
	if layer == nil or layer.pushedFrame == nil then
		return true
	end
	return frame > layer.pushedFrame
end

-- pressCounts, and also false until `layer`'s confirmDelay ({ pushedAt, confirmDelay }) has passed at `now`.
function FocusNav.confirmCounts(layer, frame, now)
	if not FocusNav.pressCounts(layer, frame) then
		return false
	end
	return layer == nil or now >= (layer.pushedAt or -math.huge) + (layer.confirmDelay or 0)
end

-- The direction a thumbstick at (x, y) points (y up), or nil inside the threshold.
function FocusNav.stickDir(x, y, threshold)
	threshold = threshold or FocusNav.STICK_THRESHOLD
	if math.max(math.abs(x), math.abs(y)) < threshold then
		return nil
	end
	if math.abs(x) >= math.abs(y) then
		return if x > 0 then "Right" else "Left"
	end
	return if y > 0 then "Up" else "Down"
end

return FocusNav
