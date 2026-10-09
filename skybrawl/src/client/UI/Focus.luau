-- STUB (owner: C1): replace the body, keep the exports.
--[[
    Keyboard / gamepad / touch focus and navigation for the menus (menus
    design 5.2): layers in bands (screen < overlay < modal), explicit
    neighbours, actions (Confirm, Back, X, Y, L1, R1, L2, R2, Menu) and
    fight input ownership during matches. Escape is not bound: Roblox owns
    it, so Back is Backspace / gamepad B.

    Until C1 lands this reads no input: layers are only kept in a list,
    links are written, and setFightInput passes straight to
    Input.setEnabled so MatchClient works.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = require(Shared.Util)

local Controllers = script.Parent.Parent:WaitForChild("Controllers")
local Input = require(Controllers:WaitForChild("Input"))

local Focus = {}

Focus.ACTIONS = {
	Confirm = { Keyboard = { "Return", "KeypadEnter", "Space" }, Gamepad = { "ButtonA" } },
	Back = { Keyboard = { "Backspace" }, Gamepad = { "ButtonB" } },
	X = { Keyboard = { "X" }, Gamepad = { "ButtonX" } },
	Y = { Keyboard = { "Y" }, Gamepad = { "ButtonY" } },
	L1 = { Keyboard = { "Q" }, Gamepad = { "ButtonL1" } },
	R1 = { Keyboard = { "E" }, Gamepad = { "ButtonR1" } },
	L2 = { Keyboard = { "Z" }, Gamepad = { "ButtonL2" } },
	R2 = { Keyboard = { "C" }, Gamepad = { "ButtonR2" } },
	Menu = { Keyboard = { "Tab" }, Gamepad = { "ButtonSelect" } },
	Up = { Keyboard = { "Up", "W" }, Gamepad = { "DPadUp" } }, -- + Thumbstick1
	Down = { Keyboard = { "Down", "S" }, Gamepad = { "DPadDown" } },
	Left = { Keyboard = { "Left", "A" }, Gamepad = { "DPadLeft" } },
	Right = { Keyboard = { "Right", "D" }, Gamepad = { "DPadRight" } },
}

Focus.Changed = Util.Signal.new() -- (new, old)
Focus.ModeChanged = Util.Signal.new() -- (mode)
Focus.Action = Util.Signal.new() -- (action)

local KEYBOARD_TEXT = {
	Confirm = "ENTER",
	Back = "BKSP",
	X = "X",
	Y = "Y",
	L1 = "Q",
	R1 = "E",
	L2 = "Z",
	R2 = "C",
	Menu = "TAB",
}
local GAMEPAD_TEXT = {
	Confirm = "A",
	Back = "B",
	X = "X",
	Y = "Y",
	L1 = "LB",
	R1 = "RB",
	L2 = "LT",
	R2 = "RT",
	Menu = "VIEW",
}

local layers = {}
local focused = nil

function Focus.init() end

-- "Keyboard" | "Gamepad" | "Touch" (mouse counts as Keyboard).
function Focus.mode()
	return "Keyboard"
end

function Focus.glyphFor(action, mode)
	local texts = if (mode or Focus.mode()) == "Gamepad" then GAMEPAD_TEXT else KEYBOARD_TEXT
	return { text = texts[action] or action, image = nil }
end

-- spec = { onActivate?, onFocus?, onLeft/onRight/onUp/onDown?, actions?, key?, hover? }
function Focus.register(_obj, _spec) end

function Focus.unregister(_obj) end

--[[
    opts = { name, roots, band?, defaultFocus?, onBack?, actions?, onDirection?,
    inMatch?, confirmDelay? }. Returns the layer.
]]
function Focus.pushLayer(opts)
	local layer = { name = opts.name, opts = opts }
	table.insert(layers, layer)
	return layer
end

function Focus.popLayer(layer)
	local index = table.find(layers, layer)
	if index then
		table.remove(layers, index)
	end
end

function Focus.setRoots(_layer, _roots) end

function Focus.topLayer()
	return layers[#layers]
end

function Focus.set(obj)
	local old = focused
	focused = obj
	if old ~= obj then
		Focus.Changed:Fire(obj, old)
	end
end

function Focus.get()
	return focused
end

-- Writes a.NextSelection<Dir> ("Up" | "Down" | "Left" | "Right").
function Focus.link(a, dir, b)
	a["NextSelection" .. dir] = b
end

function Focus.linkColumn(list, wrap)
	for i, obj in list do
		local up = list[i - 1] or (wrap and list[#list] or nil)
		local down = list[i + 1] or (wrap and list[1] or nil)
		Focus.link(obj, "Up", up)
		Focus.link(obj, "Down", down)
	end
end

function Focus.linkRow(list, wrap)
	for i, obj in list do
		local left = list[i - 1] or (wrap and list[#list] or nil)
		local right = list[i + 1] or (wrap and list[1] or nil)
		Focus.link(obj, "Left", left)
		Focus.link(obj, "Right", right)
	end
end

function Focus.linkGrid(rows)
	for r, row in rows do
		Focus.linkRow(row)
		for c, obj in row do
			local above, below = rows[r - 1], rows[r + 1]
			Focus.link(obj, "Up", above and (above[c] or above[#above]) or nil)
			Focus.link(obj, "Down", below and (below[c] or below[#below]) or nil)
		end
	end
end

-- Counted: while suspended Focus reads no input (key rebinding).
function Focus.suspend() end

function Focus.resume() end

-- The only caller of Input.setEnabled during a match (MatchClient says what it wants).
function Focus.setFightInput(wanted)
	Input.setEnabled(wanted)
end

return Focus
