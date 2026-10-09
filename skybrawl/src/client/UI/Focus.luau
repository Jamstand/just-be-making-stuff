--[[
    Keyboard / gamepad / mouse / touch focus and navigation for the menus
    (menus design 5.2). We never use the engine's selection
    (GuiService.GuiNavigationEnabled = false): every focusable object is
    registered here with a spec, and keyboard and gamepad input is read from
    UserInputService (InputBegan / InputChanged / InputEnded, never
    ContextActionService, so nothing is sunk from the fighter Input).

    Layers: a stack ordered by band (screen < overlay < modal), then push
    order. Only the top layer gets input and focus never leaves it; a layer
    may span several roots (a screen + the queue banner + the party bar).
    Each layer remembers, by name, the object it last had focused and gets
    it back when it is pushed again. A focused object that disappears is
    replaced by the layer's object with the same key (a re-rendered row),
    else by the layer's default focus.

    The registry holds its objects strongly: an object leaves it through
    Focus.unregister or when it is destroyed (its Destroying event, which
    also fires when an ancestor is destroyed). An object that is only
    unparented and dropped stays registered, so destroy what you discard.

    Input is read only while not suspended (key rebinding) and, in phase
    "Match", only when the top layer is an inMatch one (pause menu,
    training panel). Game-processed keyboard / gamepad events are ignored
    (Roblox chat, the Roblox menu, Escape), and keyboard input while a
    TextBox has focus. Escape is not bound at all: Roblox owns it, so Back
    is Backspace / gamepad B (every hint bar also has a tappable BACK).
    A key press that arrives in the frame the top layer was pushed is
    ignored (FocusNav.pressCounts): it began before the layer appeared, as
    when the key that dismissed the title, or opened the pause menu, reaches
    Focus after the handler that pushed the layer.

    A direction press runs the focused object's onUp/onDown/... handler
    (consumed when it returns true), then follows its NextSelection<Dir>
    when that can take focus, else moves to the nearest object in that
    direction (FocusNav), else calls the layer's onDirection. With nothing
    focused, the first direction or Confirm press only focuses the default.

    Input mode follows UserInputService.LastInputTypeChanged ("Keyboard",
    which includes the mouse, "Gamepad" or "Touch"); glyphs follow it and
    Touch hides the focus highlight (the focus itself is kept). Mouse hover
    moves focus. An object without its own onFocus gets the generic
    highlight: a white 3 px stroke, a 1.04 scale and a red 6 px left bar
    (no bar on an object that lays out its children with a UIListLayout or
    UIGridLayout, where the bar would take a slot).

    Focus also owns fight input during a match: MatchClient says what it
    wants (setFightInput) and Focus applies Input.setEnabled(wanted and no
    inMatch layer is open).
]]

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = require(Shared.Util)

local Client = script.Parent.Parent
local Controllers = Client:WaitForChild("Controllers")
local Input = require(Controllers:WaitForChild("Input"))
local Sound = require(Controllers:WaitForChild("Sound"))
local ClientState = require(Client:WaitForChild("ClientState"))
local FocusNav = require(script.Parent:WaitForChild("FocusNav"))
local Layout = require(script.Parent:WaitForChild("Layout"))

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
	Up = "UP",
	Down = "DOWN",
	Left = "LEFT",
	Right = "RIGHT",
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
	Up = "UP",
	Down = "DOWN",
	Left = "LEFT",
	Right = "RIGHT",
}
local DIRECTIONS = { Up = true, Down = true, Left = true, Right = true }

local TEXTBOX_GRACE = 0.1 -- a Confirm this soon after a TextBox lets go is the same Enter
local HOVER_VOLUME, CONFIRM_VOLUME, BACK_VOLUME = 0.25, 0.5, 0.45
local HIGHLIGHT = Color3.new(1, 1, 1)
local HIGHLIGHT_BAR = Color3.fromRGB(236, 47, 59)

local registry = {} -- [GuiObject] = spec (strong: cleared by unregister and Destroying)
local memory = setmetatable({}, { __mode = "v" }) -- [layer name] = last focused object
local layers = {}
local layerSeq = 0
local frameCount = 0 -- counts up once per frame (RenderStepped); a layer remembers the frame it was pushed in
local lost = nil -- { key, layer, frame }: the focused object left the registry; its same-key successor gets focus
local LOST_FRAMES = 2 -- frames to wait for that successor (a re-rendered row) before the default focus
local focused = nil
local focusedLayer = nil
local shown = nil -- the object whose highlight is on
local currentMode = "Keyboard"
local suspended = 0
local fightWanted = false
local fightApplied = nil
local lastTextRelease = -math.huge
local held = {} -- [KeyCode | "Stick"] = { dir, nextAt }
local stickDir = nil
local keyboardActions = {} -- [Enum.KeyCode] = action
local gamepadActions = {}
local HIDDEN_STROKE = "FocusHidden" -- attribute on a UIStroke the generic highlight turned off

-- Layers -----------------------------------------------------------------------------

local function topLayer()
	local order = FocusNav.order(layers)
	local index = order[#order]
	return if index then layers[index] else nil
end

local function reading()
	if suspended > 0 then
		return false
	end
	if ClientState.phase == "Match" then
		local top = topLayer()
		return top ~= nil and top.inMatch
	end
	return true
end

local function insideRoots(obj, layer)
	for _, root in layer.roots do
		if typeof(root) == "Instance" and (obj == root or obj:IsDescendantOf(root)) then
			return true
		end
	end
	return false
end

-- Visible all the way up to an enabled ScreenGui.
local function onScreen(obj)
	local node = obj
	while node do
		if node:IsA("LayerCollector") then
			return node.Enabled
		elseif node:IsA("GuiObject") and not node.Visible then
			return false
		end
		node = node.Parent
	end
	return false
end

local function navigable(obj, layer)
	if obj == nil or layer == nil or registry[obj] == nil or obj.Parent == nil then
		return false
	end
	if not obj.Selectable or obj:GetAttribute("Disabled") then
		return false
	end
	local size = obj.AbsoluteSize
	if size.X <= 0 or size.Y <= 0 then
		return false
	end
	return onScreen(obj) and insideRoots(obj, layer)
end

local function keyOf(obj)
	local spec = registry[obj]
	return (spec and spec.key) or obj:GetAttribute("FocusKey")
end

local function candidatesOf(layer)
	local list = {}
	for obj in registry do
		if navigable(obj, layer) then
			local pos, size = obj.AbsolutePosition, obj.AbsoluteSize
			table.insert(list, { id = obj, x = pos.X, y = pos.Y, w = size.X, h = size.Y })
		end
	end
	return list
end

-- Highlight ----------------------------------------------------------------------------

-- The generic highlight for objects without their own onFocus (legacy buttons, rows, plain registrations).
local function genericHighlight(obj, on)
	local stroke = obj:FindFirstChild("FocusStroke")
	local bar = obj:FindFirstChild("FocusBar")
	local scale = obj:FindFirstChild("FocusScale")
	if on then
		for _, child in obj:GetChildren() do
			if child:IsA("UIStroke") and child ~= stroke and child.Enabled then
				child.Enabled = false
				child:SetAttribute(HIDDEN_STROKE, true)
			end
		end
		if not stroke then
			local newStroke = Instance.new("UIStroke")
			newStroke.Name = "FocusStroke"
			newStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
			newStroke.Color = HIGHLIGHT
			newStroke.Parent = obj
			Layout.bindApply(newStroke, function()
				newStroke.Thickness = math.max(2, Layout.px(3))
			end)
		end
		if not scale and not obj:FindFirstChildWhichIsA("UIScale") then
			scale = Instance.new("UIScale")
			scale.Name = "FocusScale"
			scale.Scale = 1.04
			scale.Parent = obj
		end
		-- a list or grid layout would place the bar as one of its items
		if not bar and not obj:FindFirstChildWhichIsA("UIGridStyleLayout") then
			local newBar = Instance.new("Frame")
			newBar.Name = "FocusBar"
			newBar.BorderSizePixel = 0
			newBar.BackgroundColor3 = HIGHLIGHT_BAR
			newBar.ZIndex = obj.ZIndex + 1
			newBar.Parent = obj
			Layout.bindApply(newBar, function()
				newBar.Size = UDim2.new(0, math.max(3, Layout.px(6)), 1, 0)
			end)
		end
	else
		for _, child in obj:GetChildren() do
			if child:IsA("UIStroke") and child:GetAttribute(HIDDEN_STROKE) then
				child.Enabled = true
				child:SetAttribute(HIDDEN_STROKE, nil)
			end
		end
		for _, part in { stroke, bar, scale } do
			if part then
				part:Destroy()
			end
		end
	end
end

local function setShown(obj, on)
	local spec = registry[obj]
	if not spec or obj.Parent == nil then
		return
	end
	if not spec._style and not spec.onFocus then
		genericHighlight(obj, on)
		return
	end
	-- _style is a UIKit builder's own look; onFocus is the caller's
	for _, name in { "_style", "onFocus" } do
		local fn = spec[name]
		if fn then
			local ok, err = pcall(fn, on)
			if not ok then
				warn("[Focus] " .. name .. " failed:", err)
			end
		end
	end
end

local function refreshShown()
	local want = if currentMode ~= "Touch" then focused else nil
	if want == shown then
		return
	end
	local old = shown
	shown = want
	if old then
		setShown(old, false)
	end
	if want then
		setShown(want, true)
	end
end

-- Keeps a focused object inside a ScrollingFrame fully visible (8 px margin).
local function scrollIntoView(obj)
	local scroller = obj:FindFirstAncestorWhichIsA("ScrollingFrame")
	if not scroller then
		return
	end
	local margin = Layout.px(8)
	local canvas = scroller.CanvasPosition
	local window = scroller.AbsoluteWindowSize
	local rel = obj.AbsolutePosition - scroller.AbsolutePosition + canvas
	local size = obj.AbsoluteSize
	local function axis(pos, length, current, view)
		if pos - margin < current then
			return pos - margin
		elseif pos + length + margin > current + view then
			return pos + length + margin - view
		end
		return current
	end
	local x = axis(rel.X, size.X, canvas.X, window.X)
	local y = axis(rel.Y, size.Y, canvas.Y, window.Y)
	local maxX = math.max(0, scroller.AbsoluteCanvasSize.X - window.X)
	local maxY = math.max(0, scroller.AbsoluteCanvasSize.Y - window.Y)
	scroller.CanvasPosition = Vector2.new(math.clamp(x, 0, maxX), math.clamp(y, 0, maxY))
end

-- Focus changes ------------------------------------------------------------------------

-- cause: "input" or "hover" play the hover sound; nil (programmatic) is silent.
local function setFocus(obj, layer, cause)
	if obj == focused then
		focusedLayer = layer
		return
	end
	local old = focused
	focused = obj
	focusedLayer = layer
	if obj then
		lost = nil
	end
	if obj and layer then
		memory[layer.name] = obj
	end
	refreshShown()
	if obj then
		scrollIntoView(obj)
		if cause and currentMode ~= "Touch" then
			Sound.play("MenuHover", HOVER_VOLUME)
		end
	end
	Focus.Changed:Fire(obj, old)
end

-- Focuses the layer's remembered object, else its default. False when neither can take focus (yet).
local function focusDefault(layer, cause)
	local remembered = memory[layer.name]
	if navigable(remembered, layer) then
		setFocus(remembered, layer, cause)
		return true
	end
	local ok, obj = pcall(function()
		return if layer.defaultFocus then layer.defaultFocus() else nil
	end)
	if ok and navigable(obj, layer) then
		setFocus(obj, layer, cause)
		return true
	end
	return false
end

-- A new top layer: focus its remembered / default object (not on Touch, where focus never shows).
local function enterLayer(layer)
	setFocus(nil, nil)
	layer.pending = true
	if currentMode ~= "Touch" and focusDefault(layer) then
		layer.pending = false
	end
end

local function findByKey(layer, key)
	for obj in registry do
		if keyOf(obj) == key and navigable(obj, layer) then
			return obj
		end
	end
	return nil
end

local function applyFightInput(force)
	local inMatchLayer = false
	for _, layer in layers do
		if layer.inMatch then
			inMatchLayer = true
		end
	end
	local want = fightWanted and not inMatchLayer
	if force or want ~= fightApplied then
		fightApplied = want
		Input.setEnabled(want)
	end
end

-- Actions -------------------------------------------------------------------------------

local function run(fn, ...)
	task.spawn(function(...)
		local ok, err = pcall(fn, ...)
		if not ok then
			warn("[Focus] handler failed:", err)
		end
	end, ...)
end

local function activate(obj)
	if obj:IsA("TextBox") then
		Sound.play("MenuConfirm", CONFIRM_VOLUME)
		-- next frame, so the key that confirmed isn't typed into the box
		task.delay(0, function()
			if obj.Parent then
				obj:CaptureFocus()
			end
		end)
		return
	end
	local spec = registry[obj]
	if spec and spec.onActivate then
		Sound.play("MenuConfirm", CONFIRM_VOLUME)
		run(spec.onActivate)
	end
end

local function move(dir)
	local top = topLayer()
	if not top then
		return
	end
	if focusedLayer ~= top or not navigable(focused, top) then
		-- nothing focused: the first press only focuses
		if focusDefault(top, "input") then
			top.pending = false
		end
		return
	end
	local spec = registry[focused]
	local handler = spec and spec["on" .. dir]
	if handler then
		local ok, consumed = pcall(handler)
		if not ok then
			warn("[Focus] on" .. dir .. " failed:", consumed)
		elseif consumed then
			return
		end
	end
	local pos, size = focused.AbsolutePosition, focused.AbsoluteSize
	local from = { x = pos.X, y = pos.Y, w = size.X, h = size.Y, next = { [dir] = focused["NextSelection" .. dir] } }
	local target = FocusNav.resolve(from, dir, candidatesOf(top))
	if target then
		setFocus(target, top, "input")
	elseif top.onDirection then
		local ok, err = pcall(top.onDirection, dir)
		if not ok then
			warn("[Focus] onDirection failed:", err)
		end
	end
end

-- Runs an action as if its key was pressed (also used by the hint bars' tappable items).
function Focus.press(action)
	if DIRECTIONS[action] then
		move(action)
		return
	end
	local top = topLayer()
	if action == "Confirm" then
		if not top then
			return
		end
		local now = os.clock()
		if now < top.pushedAt + top.confirmDelay or now - lastTextRelease < TEXTBOX_GRACE then
			return
		end
		if focusedLayer ~= top or not navigable(focused, top) then
			if currentMode ~= "Touch" and focusDefault(top, "input") then
				top.pending = false
			end
			return
		end
		activate(focused)
	elseif action == "Back" then
		if top and top.onBack then
			Sound.play("MenuBack", BACK_VOLUME)
			run(top.onBack)
		end
	else
		local spec = if focusedLayer == top and focused then registry[focused] else nil
		local handler = (spec and spec.actions and spec.actions[action])
			or (top and top.actions and top.actions[action])
		if handler then
			run(handler)
		end
		Focus.Action:Fire(action)
	end
end

-- Input -------------------------------------------------------------------------------------

local function isGamepad(inputType)
	return string.sub(inputType.Name, 1, 7) == "Gamepad"
end

local function onInputBegan(input, gameProcessed)
	local keyboard = input.UserInputType == Enum.UserInputType.Keyboard
	if not keyboard and not isGamepad(input.UserInputType) then
		return
	end
	if gameProcessed or not reading() then
		return
	end
	if keyboard and UserInputService:GetFocusedTextBox() then
		return
	end
	local action = (if keyboard then keyboardActions else gamepadActions)[input.KeyCode]
	if not action then
		return
	end
	if not FocusNav.pressCounts(topLayer(), frameCount) then
		-- the key that pushed this layer, seen after the handler that pushed it (no repeat either)
		return
	end
	if DIRECTIONS[action] then
		held[input.KeyCode] = { dir = action, nextAt = os.clock() + FocusNav.REPEAT_DELAY }
	end
	Focus.press(action)
end

local function onInputChanged(input, gameProcessed)
	if input.KeyCode ~= Enum.KeyCode.Thumbstick1 or not isGamepad(input.UserInputType) then
		return
	end
	local dir = nil
	if not gameProcessed and reading() then
		dir = FocusNav.stickDir(input.Position.X, input.Position.Y)
	end
	if dir == stickDir then
		return
	end
	stickDir = dir
	held.Stick = nil
	if dir and FocusNav.pressCounts(topLayer(), frameCount) then
		held.Stick = { dir = dir, nextAt = os.clock() + FocusNav.REPEAT_DELAY }
		move(dir)
	end
end

local function onInputEnded(input)
	held[input.KeyCode] = nil
end

local function setMode(mode)
	if mode == currentMode then
		return
	end
	currentMode = mode
	if mode == "Touch" then
		table.clear(held)
		stickDir = nil
	end
	refreshShown()
	Focus.ModeChanged:Fire(mode)
end

-- Every frame while Focus reads input: key repeat, and replacing a focused object that went away.
local function step()
	frameCount += 1
	if not reading() then
		return
	end
	local now = os.clock()
	for _, entry in held do
		if now >= entry.nextAt then
			entry.nextAt = now + FocusNav.REPEAT_EVERY
			move(entry.dir)
		end
	end
	local top = topLayer()
	if not top then
		if focused then
			setFocus(nil, nil)
		end
		return
	end
	if focused then
		if focusedLayer ~= top or not navigable(focused, top) then
			local key = if focusedLayer == top then keyOf(focused) else nil
			local successor = if key ~= nil then findByKey(top, key) else nil
			if successor then
				setFocus(successor, top)
			else
				enterLayer(top)
			end
		end
	elseif top.pending and currentMode ~= "Touch" then
		if lost and lost.layer == top and lost.key ~= nil then
			local successor = findByKey(top, lost.key)
			if successor then
				setFocus(successor, top)
				top.pending = false
				return
			elseif frameCount - lost.frame <= LOST_FRAMES then
				return
			end
		end
		lost = nil
		if focusDefault(top) then
			top.pending = false
		end
	end
end

-- API -------------------------------------------------------------------------------------------

function Focus.init()
	pcall(function()
		GuiService.GuiNavigationEnabled = false
		GuiService.AutoSelectGuiEnabled = false
		GuiService.SelectedObject = nil
	end)
	-- the engine's own selection is never used (the \ key or a gamepad could still turn it on)
	GuiService:GetPropertyChangedSignal("SelectedObject"):Connect(function()
		if GuiService.SelectedObject ~= nil then
			GuiService.SelectedObject = nil
		end
	end)
	for action, binding in Focus.ACTIONS do
		for _, name in binding.Keyboard do
			keyboardActions[Enum.KeyCode[name]] = action
		end
		for _, name in binding.Gamepad do
			gamepadActions[Enum.KeyCode[name]] = action
		end
	end
	local default = if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
		then "Touch"
		else "Keyboard"
	currentMode = FocusNav.modeFor(UserInputService:GetLastInputType().Name, default)

	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputChanged:Connect(onInputChanged)
	UserInputService.InputEnded:Connect(onInputEnded)
	UserInputService.LastInputTypeChanged:Connect(function(inputType)
		setMode(FocusNav.modeFor(inputType.Name, currentMode))
	end)
	UserInputService.TextBoxFocusReleased:Connect(function()
		lastTextRelease = os.clock()
	end)
	ClientState.PhaseChanged:Connect(function()
		table.clear(held)
		stickDir = nil
	end)
	RunService.RenderStepped:Connect(step)
	applyFightInput(true)
end

-- "Keyboard" | "Gamepad" | "Touch" (mouse counts as Keyboard).
function Focus.mode()
	return currentMode
end

-- { text, image? }: keyboard key text, or the connected gamepad's button image (text as a fallback).
function Focus.glyphFor(action, mode)
	mode = mode or currentMode
	if mode == "Gamepad" then
		local binding = Focus.ACTIONS[action]
		local image = nil
		if binding then
			local ok, result = pcall(function()
				return UserInputService:GetImageForKeyCode(Enum.KeyCode[binding.Gamepad[1]])
			end)
			if ok and type(result) == "string" and result ~= "" then
				image = result
			end
		end
		return { text = GAMEPAD_TEXT[action] or action, image = image }
	end
	return { text = KEYBOARD_TEXT[action] or action, image = nil }
end

local forget -- forward declaration (the Destroying hook below)

--[[
    spec = { onActivate?, onFocus?(on), onLeft/onRight/onUp/onDown? (return
    true when consumed), actions? ({ [action] = fn }, checked before the
    layer's), key? (stable identity across rebuilds; also the "FocusKey"
    attribute), hover? (false = mouse hover doesn't move focus) }.
    Registering again merges the new fields into the spec. Sets Selectable.
    The object is unregistered by itself when it (or an ancestor) is
    destroyed.
]]
function Focus.register(obj, spec)
	local existing = registry[obj]
	if existing then
		for key, value in spec or {} do
			existing[key] = value
		end
		return
	end
	local entry = table.clone(spec or {})
	registry[obj] = entry
	obj.Selectable = true
	entry._destroying = obj.Destroying:Connect(function()
		forget(obj, true)
	end)
	entry._hover = obj.MouseEnter:Connect(function()
		local current = registry[obj]
		if not current or current.hover == false or focused == obj or not reading() then
			return
		end
		local top = topLayer()
		if navigable(obj, top) then
			setFocus(obj, top, "hover")
		end
	end)
end

-- Drops `obj` from the registry; `silent` (it is being destroyed) skips turning its highlight off.
function forget(obj, silent)
	local spec = registry[obj]
	if not spec then
		return
	end
	if focused == obj then
		lost = { key = keyOf(obj), layer = focusedLayer, frame = frameCount }
	end
	if shown == obj then
		if not silent then
			setShown(obj, false)
		end
		shown = nil
	end
	for _, name in { "_hover", "_destroying" } do
		if spec[name] then
			spec[name]:Disconnect()
		end
	end
	registry[obj] = nil
	if focused == obj then
		setFocus(nil, nil)
		local top = topLayer()
		if top then
			top.pending = true
		end
	end
end

-- Registered objects also leave the registry by themselves when they (or an ancestor) are destroyed.
function Focus.unregister(obj)
	forget(obj, false)
end

--[[
    opts = { name, roots, band? ("screen" | "overlay" | "modal"), defaultFocus?,
    onBack?, actions?, onDirection?, inMatch?, confirmDelay? }. Inserted on top
    of its band; returns the layer.
]]
function Focus.pushLayer(opts)
	layerSeq += 1
	local layer = {
		name = opts.name or ("Layer" .. layerSeq),
		roots = opts.roots or {},
		band = opts.band or "screen",
		defaultFocus = opts.defaultFocus,
		onBack = opts.onBack,
		actions = opts.actions,
		onDirection = opts.onDirection,
		inMatch = opts.inMatch == true,
		confirmDelay = opts.confirmDelay or 0,
		pushedAt = os.clock(),
		pushedFrame = frameCount,
		seq = layerSeq,
		pending = false,
	}
	table.insert(layers, layer)
	if topLayer() == layer then
		enterLayer(layer)
	end
	applyFightInput(false)
	return layer
end

-- Removes any layer (not only the top one); the new top layer gets its focus back.
function Focus.popLayer(layer)
	local index = table.find(layers, layer)
	if not index then
		return
	end
	local wasTop = topLayer() == layer
	table.remove(layers, index)
	if wasTop or focusedLayer == layer then
		local top = topLayer()
		if top then
			enterLayer(top)
		else
			setFocus(nil, nil)
		end
	end
	applyFightInput(false)
end

function Focus.setRoots(layer, roots)
	layer.roots = roots or {}
end

function Focus.topLayer()
	return topLayer()
end

-- Focuses `obj` (no sound). An object of a lower layer becomes that layer's remembered focus instead.
function Focus.set(obj)
	if obj == nil then
		setFocus(nil, nil)
		return
	end
	local top = topLayer()
	if top and insideRoots(obj, top) then
		setFocus(obj, top)
		return
	end
	for _, layer in layers do
		if insideRoots(obj, layer) then
			memory[layer.name] = obj
		end
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
function Focus.suspend()
	suspended += 1
	table.clear(held)
	stickDir = nil
end

function Focus.resume()
	suspended = math.max(0, suspended - 1)
end

-- The only caller of Input.setEnabled during a match (MatchClient says what it wants).
function Focus.setFightInput(wanted)
	fightWanted = wanted == true
	applyFightInput(true)
end

-- False while `obj`'s layer is inside its confirmDelay (UIKit.onActivate ignores clicks then too).
function Focus.accepts(obj)
	local top = topLayer()
	if top and insideRoots(obj, top) then
		return FocusNav.confirmCounts(top, frameCount, os.clock())
	end
	return true
end

return Focus
