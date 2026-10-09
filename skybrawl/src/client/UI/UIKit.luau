--[[
    Helpers for building the UI in code with one look: the Brawlhalla-style
    menus' near-black panels, red focus, gold accents, Bangers / Gotham text
    (menus design 3.8 and 5.3).

    Every text size goes through Layout.bindText (design px at 1080p; Roblox
    caps TextSize at 100, bindText scales bigger text with a UIScale), and
    every interactive builder registers with Focus: buttons activate on
    Confirm, toggles flip on Confirm, cycle / stepper rows are one focusable
    row that steps with Left / Right and Confirm. Objects without their own
    focus look get Focus's generic highlight.

    Shapes: Roblox can't clip to a slanted edge (and clipping stops working
    under a rotated ancestor), so slanted and cut shapes are unrotated
    rectangles plus wedges, laid out from Shapes' pure numbers with integer
    offsets every time the shape's AbsoluteSize changes. Gradient fills put
    a vertical UIGradient on the middle piece and a windowed one on each
    wedge so the colour matches across the seams. A composite shape that
    needs transparency (shadows, glows, the disabled dim, the main menu
    slab) is drawn opaque inside its own CanvasGroup that carries it, so no
    seam ever shows. Those groups hold plain shape pieces only: a button's
    or card's content (text, icons, the portraits C2 puts on cards) is
    never inside a CanvasGroup, and groups are never nested.

    Slant shapes are tracked by their root in a strong table that drops a
    root when it is destroyed; Focus likewise forgets destroyed objects.

    Common opts for the menus builders: parent, position, size, anchor,
    zIndex, layoutOrder, name (Scale preferred). Builders whose own `size`
    is a number (header, tag, glyph, tierBadge) take a UDim2 `size` as the
    common one, and without either fill their parent.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Ranks = require(Shared.Ranks)

local Client = script.Parent.Parent
local ClientState = require(Client:WaitForChild("ClientState"))
local Sound = require(Client:WaitForChild("Controllers"):WaitForChild("Sound"))
local Focus = require(script.Parent:WaitForChild("Focus"))
local Layout = require(script.Parent:WaitForChild("Layout"))
local Shapes = require(script.Parent:WaitForChild("Shapes"))

local UIKit = {}

local function rgb(hex)
	return Color3.fromRGB(bit32.rshift(hex, 16), bit32.band(bit32.rshift(hex, 8), 0xFF), bit32.band(hex, 0xFF))
end

UIKit.Theme = {
	Backdrop = rgb(0x0A0B0E),
	Panel = rgb(0x0D0E12),
	PanelLight = rgb(0x181B22),
	PanelDark = rgb(0x0A0B0E),
	Stroke = rgb(0x3B404C),
	Text = rgb(0xFFFFFF),
	Muted = rgb(0xAAB0BF),
	Gold = rgb(0xFFC53D),
	GoldDark = rgb(0x2A1C00),
	Teal = rgb(0x8FD3FF),
	Danger = rgb(0xEC2F3B),
	Good = rgb(0x4FE07A),
	HeadFont = Enum.Font.Bangers,
	BodyFont = Enum.Font.GothamMedium,
	BoldFont = Enum.Font.GothamBold,

	Raised = rgb(0x181B22),
	Outline = rgb(0x000000),
	Dim = rgb(0x6B7282),
	Red = rgb(0xEC2F3B),
	RedLight = rgb(0xFF4B55),
	RedDark = rgb(0xCF1520),
	GoldLight = rgb(0xFFD769),
	GoldDeep = rgb(0xE2A018),
	XP = rgb(0x8FD3FF),
	Warning = rgb(0xFF9A2E),
	ButtonTop = rgb(0x272B34),
	ButtonBottom = rgb(0x16181E),
	Hurtbox = rgb(0x49B4FF),
	Hitbox = rgb(0xFF3B46),
	DamageHot = rgb(0xFF8A2A),
	Startup = rgb(0x2FBF5C),
	Active = rgb(0xEC2F3B),
	Recovery = rgb(0x3F8CFF),
	VsRed = { rgb(0x3D060C), rgb(0x8F1018) },
	VsBlue = { rgb(0x0B2A60), rgb(0x123F8A) },
	LogoGradient = { rgb(0xFFFFFF), rgb(0xFFD23F), rgb(0xF2860F) },
	LogoFont = Enum.Font.LuckiestGuy,
	BlackFont = Enum.Font.GothamBlack,
	Slant = 14, -- degrees
	CardSlant = 6,
	SlotSlant = 10,
	Cut = 22, -- design px
}

local T = UIKit.Theme

local FOCUS_SECONDS = 0.12 -- the focus nudge: 0.12 s, Quad Out
local CONFIRM_VOLUME = 0.5

function UIKit.make(className, props, children)
	local inst = Instance.new(className)
	local parent = nil
	for key, value in props or {} do
		if key == "Parent" then
			parent = value
		else
			inst[key] = value
		end
	end
	for _, child in children or {} do
		child.Parent = inst
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local make = UIKit.make

local function round(x)
	return math.floor(x + 0.5)
end

-- Legacy builders (restyled) -------------------------------------------------------

function UIKit.corner(radius)
	return make("UICorner", { CornerRadius = UDim.new(0, radius or 4) })
end

function UIKit.stroke(color, thickness, transparency)
	local stroke = make("UIStroke", {
		Color = color or T.Stroke,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
	Layout.bindStroke(stroke, thickness or 1.5)
	return stroke
end

function UIKit.padding(x, y)
	local padding = make("UIPadding", {})
	Layout.bindPadding(padding, x, y)
	return padding
end

function UIKit.list(direction, spacing, hAlign, vAlign)
	local list = make("UIListLayout", {
		FillDirection = direction or Enum.FillDirection.Vertical,
		HorizontalAlignment = hAlign or Enum.HorizontalAlignment.Left,
		VerticalAlignment = vAlign or Enum.VerticalAlignment.Top,
		SortOrder = Enum.SortOrder.LayoutOrder,
	})
	Layout.bindListPadding(list, spacing or 8)
	return list
end

-- A TextLabel; `size` (or props.TextSize) is design px, applied through Layout.bindText.
function UIKit.label(text, size, props)
	size = size or 16
	local label = make("TextLabel", {
		BackgroundTransparency = 1,
		Text = text or "",
		Font = T.BodyFont,
		TextColor3 = T.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		TextWrapped = true,
		Size = UDim2.new(1, 0, 0, Layout.px(size) + 6),
	})
	local textSize = size
	for key, value in props or {} do
		if key == "TextSize" then
			textSize = value
		elseif key ~= "Parent" then
			label[key] = value
		end
	end
	Layout.bindText(label, textSize)
	if props and props.Parent then
		label.Parent = props.Parent
	end
	return label
end

function UIKit.heading(text, size, props)
	local label = UIKit.label(text, size or 24, props)
	if not (props and props.Font) then
		label.Font = T.HeadFont
	end
	return label
end

local BUTTON_STYLES = {
	primary = { gradient = { T.RedLight, T.RedDark }, text = T.Text, stroke = T.Outline },
	secondary = { gradient = { T.ButtonTop, T.ButtonBottom }, text = T.Text, stroke = T.Outline },
	danger = { fill = T.Red, text = T.Text, stroke = T.Outline },
	ghost = { fill = T.Raised, text = T.Muted, stroke = T.Stroke },
	good = { fill = T.Good, text = Color3.fromRGB(10, 40, 20), stroke = T.Outline },
	gold = { gradient = { T.GoldLight, T.GoldDeep }, text = T.GoldDark, stroke = T.Outline },
}

function UIKit.styleButton(button, style)
	local s = BUTTON_STYLES[style] or BUTTON_STYLES.secondary
	local gradient = button:FindFirstChild("StyleGradient")
	if s.gradient then
		if not gradient then
			gradient = make("UIGradient", { Name = "StyleGradient", Rotation = 90, Parent = button })
		end
		gradient.Color = ColorSequence.new(s.gradient[1], s.gradient[2])
		gradient.Enabled = true
		button.BackgroundColor3 = Color3.new(1, 1, 1)
	else
		if gradient then
			gradient.Enabled = false
		end
		button.BackgroundColor3 = s.fill
	end
	button.TextColor3 = s.text
	for _, child in button:GetChildren() do
		if child:IsA("UIStroke") and child.Name ~= "FocusStroke" then
			child.Color = s.stroke
		end
	end
	button:SetAttribute("Style", style)
end

-- A plain button that isn't registered with Focus (the arrows inside a cycle row).
local function plainButton(text, style, onClick, props)
	local button = make("TextButton", {
		AutoButtonColor = false,
		Text = text,
		Font = T.HeadFont,
		Size = UDim2.new(0, 140, 0, 38),
		BorderSizePixel = 0,
	}, {
		UIKit.corner(4),
		UIKit.stroke(T.Outline, 2, 0),
	})
	UIKit.styleButton(button, style or "secondary")
	local textSize = 22
	for key, value in props or {} do
		if key == "TextSize" then
			textSize = value
		elseif key ~= "Parent" then
			button[key] = value
		end
	end
	Layout.bindText(button, textSize)
	if onClick then
		button.Activated:Connect(function()
			if not button:GetAttribute("Disabled") then
				onClick(button)
			end
		end)
	end
	if props and props.Parent then
		button.Parent = props.Parent
	end
	return button
end

-- A rectangular button; with onClick it activates on clicks, taps and Confirm (registered with Focus).
function UIKit.button(text, style, onClick, props)
	local button = plainButton(text, style, nil, props)
	if onClick then
		UIKit.onActivate(button, onClick)
	end
	return button
end

local slantStates = {} -- [slant root / button] = state (strong; dropped when the root is destroyed)

local function rememberSlant(root, state)
	if slantStates[root] == nil then
		root.Destroying:Connect(function()
			slantStates[root] = nil
		end)
	end
	slantStates[root] = state
end

function UIKit.setEnabled(button, enabled)
	button:SetAttribute("Disabled", not enabled)
	if button:GetAttribute("UIKitKind") then
		-- slant buttons and cards fade their visual (they listen to the attribute)
		return
	end
	if button:IsA("GuiButton") then
		button.AutoButtonColor = false
	end
	button.BackgroundTransparency = enabled and 0 or 0.55
	if button:IsA("TextButton") or button:IsA("TextLabel") or button:IsA("TextBox") then
		button.TextTransparency = enabled and 0 or 0.45
	end
end

function UIKit.panel(props)
	local frame = make("Frame", {
		BackgroundColor3 = T.Panel,
		BorderSizePixel = 0,
	}, {
		UIKit.corner(4),
		UIKit.stroke(T.Stroke, 2, 0),
	})
	for key, value in props or {} do
		if key ~= "Parent" then
			frame[key] = value
		end
	end
	if props and props.Parent then
		frame.Parent = props.Parent
	end
	return frame
end

function UIKit.scroll(props)
	local scroll = make("ScrollingFrame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = T.Stroke,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Size = UDim2.fromScale(1, 1),
	})
	for key, value in props or {} do
		scroll[key] = value
	end
	return scroll
end

local function settingRow(text, height)
	local row = make("Frame", {
		BackgroundColor3 = T.Raised,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, height or 46),
	}, {
		UIKit.corner(4),
		UIKit.padding(12, 4),
	})
	UIKit.label(text, 18, {
		Name = "Title",
		Size = UDim2.new(0.5, 0, 1, 0),
		Font = T.BoldFont,
		Parent = row,
	})
	return row
end

-- On/off switch row (Confirm or a click on the switch flips it). Returns row, set(value).
function UIKit.toggle(text, value, onChange)
	local row = settingRow(text)
	local switch = make("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(64, 30),
		AutoButtonColor = false,
		Text = "",
		BorderSizePixel = 0,
		Parent = row,
	}, { UIKit.corner(15) })
	local knob = make("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Size = UDim2.fromOffset(24, 24),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Parent = switch,
	}, { UIKit.corner(12) })
	local current = value == true
	local function render()
		switch.BackgroundColor3 = current and T.Good or T.Stroke
		knob.Position = current and UDim2.new(1, -27, 0.5, 0) or UDim2.new(0, 3, 0.5, 0)
	end
	local function flip()
		current = not current
		render()
		onChange(current)
	end
	switch.Activated:Connect(flip)
	Focus.register(row, { key = "Toggle:" .. text, onActivate = flip })
	render()
	return row, function(v)
		current = v == true
		render()
	end
end

-- ◀ value ▶ picker over a list of { value, label }; the row steps with Left / Right and Confirm. Returns row,
-- set(value).
function UIKit.cycle(text, options, value, onChange)
	local row = settingRow(text)
	local holder = make("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.new(0.5, 0, 0, 34),
		BackgroundTransparency = 1,
		Parent = row,
	})
	local index = 1
	for i, option in options do
		if option.value == value then
			index = i
		end
	end
	local valueLabel = UIKit.label("", 22, {
		Position = UDim2.fromOffset(38, 0),
		Size = UDim2.new(1, -76, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Center,
		Font = T.HeadFont,
		TextColor3 = T.Gold,
		Parent = holder,
	})
	local function render()
		valueLabel.Text = options[index].label
	end
	local function shift(delta)
		index = (index - 1 + delta) % #options + 1
		render()
		onChange(options[index].value)
	end
	plainButton("<", "ghost", function()
		shift(-1)
	end, { Size = UDim2.fromOffset(34, 34), Parent = holder })
	plainButton(">", "ghost", function()
		shift(1)
	end, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(34, 34),
		Parent = holder,
	})
	Focus.register(row, {
		key = "Cycle:" .. text,
		onActivate = function()
			shift(1)
		end,
		onLeft = function()
			shift(-1)
			return true
		end,
		onRight = function()
			shift(1)
			return true
		end,
	})
	render()
	return row,
		function(v)
			for i, option in options do
				if option.value == v then
					index = i
				end
			end
			render()
		end
end

-- Numeric ◀ value ▶ stepper. Returns row, set(value).
function UIKit.stepper(text, min, max, step, value, format, onChange)
	local options = {}
	local n = math.floor((max - min) / step + 0.5)
	for i = 0, n do
		local v = min + i * step
		v = math.floor(v * 1000 + 0.5) / 1000
		table.insert(options, { value = v, label = format and format(v) or tostring(v) })
	end
	local nearest = options[1].value
	for _, option in options do
		if math.abs(option.value - (value or min)) < math.abs(nearest - (value or min)) then
			nearest = option.value
		end
	end
	local row, set = UIKit.cycle(text, options, nearest, onChange)
	return row,
		function(v)
			local best = options[1].value
			for _, option in options do
				if math.abs(option.value - v) < math.abs(best - v) then
					best = option.value
				end
			end
			set(best)
		end
end

-- A text box; Confirm captures it (Focus), Enter releases it.
function UIKit.textbox(placeholder, props)
	local box = make("TextBox", {
		BackgroundColor3 = T.Raised,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		PlaceholderText = placeholder or "",
		PlaceholderColor3 = T.Dim,
		Text = "",
		TextColor3 = T.Text,
		Font = T.BodyFont,
		Size = UDim2.new(1, 0, 0, 38),
		TextXAlignment = Enum.TextXAlignment.Left,
	}, {
		UIKit.corner(4),
		UIKit.padding(10, 0),
		UIKit.stroke(T.Stroke, 1.5, 0),
	})
	local textSize = 18
	for key, value in props or {} do
		if key == "TextSize" then
			textSize = value
		elseif key ~= "Parent" then
			box[key] = value
		end
	end
	Layout.bindText(box, textSize)
	Focus.register(box, { key = "TextBox:" .. (placeholder or "") })
	if props and props.Parent then
		box.Parent = props.Parent
	end
	return box
end

-- A chip that toggles on click (used for filters and weapon pickers).
function UIKit.chip(text, value, onChange, props)
	local current = value == true
	local chip
	chip = UIKit.button(text, "ghost", function()
		current = not current
		UIKit.styleButton(chip, current and "primary" or "ghost")
		onChange(current)
	end, { TextSize = 18, Size = UDim2.fromOffset(120, 32) })
	UIKit.styleButton(chip, current and "primary" or "ghost")
	for key, v in props or {} do
		chip[key] = v
	end
	return chip, function(v)
		current = v == true
		UIKit.styleButton(chip, current and "primary" or "ghost")
	end
end

-- A chip that cycles through options on click. Returns chip, set(value).
function UIKit.cycleChip(prefix, options, value, onChange, props)
	local index = 1
	for i, option in options do
		if option.value == value then
			index = i
		end
	end
	local chip
	local function render()
		chip.Text = prefix .. ": " .. options[index].label
		UIKit.styleButton(chip, index == 1 and "ghost" or "primary")
	end
	chip = UIKit.button("", "ghost", function()
		index = index % #options + 1
		render()
		onChange(options[index].value)
	end, { TextSize = 18, Size = UDim2.fromOffset(150, 32) })
	for key, v in props or {} do
		chip[key] = v
	end
	render()
	return chip,
		function(v)
			for i, option in options do
				if option.value == v then
					index = i
				end
			end
			render()
		end
end

function UIKit.clear(frame, keepClasses)
	for _, child in frame:GetChildren() do
		local keep = false
		for _, className in keepClasses or { "UIListLayout", "UIGridLayout", "UIPadding", "UICorner", "UIStroke" } do
			if child:IsA(className) then
				keep = true
			end
		end
		if not keep then
			child:Destroy()
		end
	end
end

-- Menus builders ------------------------------------------------------------------

local function applyCommon(obj, opts)
	if not opts then
		return obj
	end
	if opts.position then
		obj.Position = opts.position
	end
	if typeof(opts.size) == "UDim2" then
		obj.Size = opts.size
	end
	if opts.anchor then
		obj.AnchorPoint = opts.anchor
	end
	if opts.zIndex then
		obj.ZIndex = opts.zIndex
	end
	if opts.layoutOrder then
		obj.LayoutOrder = opts.layoutOrder
	end
	if opts.name then
		obj.Name = opts.name
	end
	if opts.parent then
		obj.Parent = opts.parent
	end
	return obj
end

local function holderFrame(name, zIndex, parent)
	return make("Frame", {
		Name = name,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = zIndex or 1,
		Parent = parent,
	})
end

-- "123", 123 or "rbxassetid://123" -> "rbxassetid://123"; "" / nil -> "". Other URLs pass through.
function UIKit.assetId(id)
	if type(id) == "number" then
		-- (not a NaN, fraction, infinity or past the exact integer range)
		if id ~= id or id <= 0 or id ~= math.floor(id) or id >= 2 ^ 53 then
			return ""
		end
		return "rbxassetid://" .. string.format("%d", id)
	end
	if type(id) ~= "string" then
		return ""
	end
	local trimmed = string.match(id, "^%s*(.-)%s*$")
	if trimmed == "" then
		return ""
	end
	if string.match(trimmed, "^%d+$") then
		return "rbxassetid://" .. trimmed
	end
	return trimmed
end

-- Colours as a list (one colour = a flat fill).
local function colorList(fill)
	if typeof(fill) == "Color3" then
		return { fill }
	elseif type(fill) == "table" and #fill > 0 then
		return fill
	end
	return { T.Panel }
end

-- `colors` spread over [t0, t1] of a gradient, flat outside it.
local function windowSequence(colors, t0, t1)
	local keys = {}
	if t0 > 0 then
		table.insert(keys, ColorSequenceKeypoint.new(0, colors[1]))
	end
	for i, color in colors do
		local t = math.clamp(t0 + (t1 - t0) * (i - 1) / (#colors - 1), 0, 1)
		table.insert(keys, ColorSequenceKeypoint.new(t, color))
	end
	if t1 < 1 then
		table.insert(keys, ColorSequenceKeypoint.new(1, colors[#colors]))
	end
	return ColorSequence.new(keys)
end

local function piece(name, parent, zIndex)
	return make("Frame", {
		Name = name,
		BorderSizePixel = 0,
		ZIndex = zIndex,
		Parent = parent,
	})
end

--[[
    A slanted parallelogram drawn into `holder` (a transparent frame the
    caller sizes): the middle rectangle plus two clipped wedges. Returns
    { layout(w, h), setColors(colors) }; layout returns the slant offset s.
]]
local function slantShape(holder, deg, colors)
	local zIndex = holder.ZIndex
	local middle = piece("Middle", holder, zIndex)
	local clips, squares = {}, {}
	for _, side in { "Left", "Right" } do
		local clip = piece(side, holder, zIndex)
		clip.BackgroundTransparency = 1
		clip.ClipsDescendants = true
		clips[side] = clip
		local square = piece("Square", clip, zIndex)
		square.AnchorPoint = Vector2.new(0.5, 0.5)
		squares[side] = square
	end
	local gradients = {}
	local geometry = nil
	local shape = {}

	local function paint()
		local gradient = #colors > 1
		for name, obj in { Middle = middle, Left = squares.Left, Right = squares.Right } do
			obj.BackgroundColor3 = if gradient then Color3.new(1, 1, 1) else colors[1]
			local g = gradients[name]
			if gradient and not g then
				g = make("UIGradient", { Parent = obj })
				gradients[name] = g
			end
			if g then
				g.Enabled = gradient
			end
		end
		if gradient then
			gradients.Middle.Rotation = 90
			gradients.Middle.Color = windowSequence(colors, 0, 1)
			if geometry then
				gradients.Left.Rotation = geometry.gradientRotation
				gradients.Right.Rotation = geometry.gradientRotation
				gradients.Left.Color = windowSequence(colors, geometry.leftWindow.t0, geometry.leftWindow.t1)
				gradients.Right.Color = windowSequence(colors, geometry.rightWindow.t0, geometry.rightWindow.t1)
			end
		end
	end

	function shape.layout(w, h)
		geometry = Shapes.slant(w, h, deg)
		local m = geometry.middle
		middle.Position = UDim2.fromOffset(m.x, m.y)
		middle.Size = UDim2.fromOffset(m.w, m.h)
		for side, wedge in { Left = geometry.left, Right = geometry.right } do
			clips[side].Position = UDim2.fromOffset(wedge.x, wedge.y)
			clips[side].Size = UDim2.fromOffset(wedge.w, wedge.h)
			squares[side].Position = UDim2.fromOffset(wedge.cx, wedge.cy)
			squares[side].Size = UDim2.fromOffset(wedge.size, wedge.size)
			squares[side].Rotation = wedge.rotation
		end
		paint()
		return geometry.s
	end

	function shape.setColors(newColors)
		colors = newColors
		paint()
	end

	paint()
	return shape
end

-- A cut-corner shape (Shapes.cut) drawn into `holder` in one colour. Returns { layout(w, h, c), setColor(color) }.
local function cutShape(holder, color)
	local zIndex = holder.ZIndex
	local rects, squares = {}, {}
	for i = 1, 3 do
		rects[i] = piece("Rect" .. i, holder, zIndex)
	end
	local clips = {}
	for i = 1, 2 do
		local clip = piece("Corner" .. i, holder, zIndex)
		clip.BackgroundTransparency = 1
		clip.ClipsDescendants = true
		clips[i] = clip
		local square = piece("Square", clip, zIndex)
		square.AnchorPoint = Vector2.new(0.5, 0.5)
		square.Rotation = 45
		squares[i] = square
	end
	local shape = {}
	function shape.setColor(newColor)
		for _, obj in rects do
			obj.BackgroundColor3 = newColor
		end
		for _, obj in squares do
			obj.BackgroundColor3 = newColor
		end
	end
	function shape.layout(w, h, c)
		local geometry = Shapes.cut(w, h, c)
		for i, r in geometry.rects do
			rects[i].Position = UDim2.fromOffset(r.x, r.y)
			rects[i].Size = UDim2.fromOffset(r.w, r.h)
		end
		for i, wedge in geometry.wedges do
			clips[i].Position = UDim2.fromOffset(wedge.x, wedge.y)
			clips[i].Size = UDim2.fromOffset(wedge.w, wedge.h)
			squares[i].Position = UDim2.fromOffset(wedge.cx, wedge.cy)
			local side = math.ceil(wedge.size)
			squares[i].Size = UDim2.fromOffset(side, side)
		end
	end
	shape.setColor(color)
	return shape
end

--[[
    The pieces of a slanted frame inside `root` (sized by the caller):
    shadow, outline, an optional white ring and the fill, plus Content, the
    inner rectangle. Returns a state with setFill, setOutline(o), setRing(on)
    and relayout(); relayout runs whenever root's AbsoluteSize changes.
]]
local function buildSlant(root, opts)
	local deg = opts.slant or T.Slant
	local state = {
		root = root,
		deg = deg,
		outline = opts.outline or 0,
		ring = opts.ring or 0,
		colors = colorList(opts.gradient or opts.fill),
	}
	if opts.shadow then
		state.shadowGroup = make("CanvasGroup", {
			Name = "Shadow",
			BackgroundTransparency = 1,
			GroupTransparency = 0.4,
			ZIndex = 1,
			Parent = root,
		})
		state.shadow = slantShape(holderFrame("Shape", 1, state.shadowGroup), deg, { T.Outline })
	end
	state.outlineHolder = holderFrame("Outline", 2, root)
	state.outlineShape = slantShape(state.outlineHolder, deg, { T.Outline })
	state.ringHolder = holderFrame("Ring", 3, root)
	state.ringShape = slantShape(state.ringHolder, deg, { Color3.new(1, 1, 1) })
	state.fillHolder = holderFrame("Fill", 4, root)
	state.fill = slantShape(state.fillHolder, deg, state.colors)
	state.content = holderFrame("Content", 5, root)

	local function place(holder, shape, box)
		holder.Position = UDim2.fromOffset(box.x, box.y)
		holder.Size = UDim2.fromOffset(box.w, box.h)
		shape.layout(box.w, box.h)
	end

	function state.relayout()
		local size = root.AbsoluteSize
		local w, h = round(size.X), round(size.Y)
		if w <= 0 or h <= 0 then
			return
		end
		local s = state.fill.layout(w, h)
		state.fillHolder.Size = UDim2.fromOffset(w, h)
		state.content.Position = UDim2.fromOffset(s, 0)
		state.content.Size = UDim2.new(1, -2 * s, 1, 0)
		local outline = Layout.px(state.outline)
		local ring = Layout.px(state.ring)
		local outer = { x = 0, y = 0, w = w, h = h }
		state.ringHolder.Visible = ring > 0
		if ring > 0 then
			outer = Shapes.outset(w, h, deg, ring)
			place(state.ringHolder, state.ringShape, outer)
		end
		state.outlineHolder.Visible = outline > 0
		if outline > 0 then
			outer = Shapes.outset(w, h, deg, ring + outline)
			place(state.outlineHolder, state.outlineShape, outer)
		end
		if state.shadowGroup then
			local d = Layout.px(7)
			state.shadowGroup.Position = UDim2.fromOffset(outer.x + d, outer.y + d)
			state.shadowGroup.Size = UDim2.fromOffset(outer.w, outer.h)
			state.shadow.layout(outer.w, outer.h)
		end
	end

	function state.setFill(fill)
		state.colors = colorList(fill)
		state.fill.setColors(state.colors)
	end

	function state.setOutline(o)
		state.outline = o
		state.relayout()
	end

	function state.setRing(px)
		state.ring = px
		state.relayout()
	end

	root:GetPropertyChangedSignal("AbsoluteSize"):Connect(state.relayout)
	state.relayout()
	task.defer(state.relayout)
	return state
end

--[[
    A slanted frame (parallelogram leaning `slant` degrees, default 14; a
    negative slant mirrors it). opts = { slant?, fill?, gradient? (top ->
    bottom), outline? (design px, black), ring? (design px, a white ring
    inside the outline: the focused look), shadow?, transparency? } & Common.
    Put children in root.Content (the inner rectangle; the wedges are solid
    fill). With `transparency` the root is a CanvasGroup carrying it (its
    outline would be clipped and its shadow group nested: use them without
    transparency; don't put 3D views in such a frame either).
]]
function UIKit.slantFrame(opts)
	opts = opts or {}
	local root = make(if opts.transparency ~= nil then "CanvasGroup" else "Frame", {
		Name = "SlantFrame",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
	})
	if opts.transparency ~= nil then
		root.GroupTransparency = opts.transparency
	end
	applyCommon(root, opts)
	rememberSlant(root, buildSlant(root, opts))
	return root
end

-- A new fill (one colour or a top -> bottom gradient) for a slantFrame.
function UIKit.setSlantFill(root, fill)
	local state = slantStates[root]
	if state and state.setFill then
		state.setFill(fill)
	end
end

-- Icons -----------------------------------------------------------------------------

-- A white line icon drawn from frames (no uploads) filling `parent`.
local function drawIcon(kind, parent, color)
	color = color or T.Text
	local zIndex = parent.ZIndex + 1
	local function box(x, y, w, h, props)
		local frame = make("Frame", {
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(x, y),
			Size = UDim2.fromScale(w, h),
			ZIndex = zIndex,
			Parent = parent,
		})
		for key, value in props or {} do
			frame[key] = value
		end
		return frame
	end
	local function ring(x, y, d, thickness)
		local frame = box(x, y, d, d, { BackgroundTransparency = 1 })
		make("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = frame })
		local stroke =
			make("UIStroke", { Color = color, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = frame })
		Layout.bindStroke(stroke, thickness or 3)
		return frame
	end
	local function outlineBox(x, y, w, h)
		local frame = box(x, y, w, h, { BackgroundTransparency = 1 })
		local stroke =
			make("UIStroke", { Color = color, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = frame })
		Layout.bindStroke(stroke, 3)
		return frame
	end
	if kind == "swords" then
		box(0.5, 0.5, 0.12, 0.95, { Rotation = 45 })
		box(0.5, 0.5, 0.12, 0.95, { Rotation = -45 })
		box(0.24, 0.62, 0.32, 0.1, { Rotation = 45 })
		box(0.76, 0.62, 0.32, 0.1, { Rotation = -45 })
	elseif kind == "target" then
		ring(0.5, 0.5, 0.82)
		ring(0.5, 0.5, 0.42)
		make("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = box(0.5, 0.5, 0.16, 0.16) })
	elseif kind == "grid" then
		for _, p in { { 0.28, 0.28 }, { 0.72, 0.28 }, { 0.28, 0.72 }, { 0.72, 0.72 } } do
			outlineBox(p[1], p[2], 0.32, 0.32)
		end
	elseif kind == "person" then
		ring(0.5, 0.3, 0.38)
		local body = outlineBox(0.5, 0.78, 0.7, 0.34)
		make("UICorner", { CornerRadius = UDim.new(0.4, 0), Parent = body })
	elseif kind == "bag" then
		outlineBox(0.5, 0.62, 0.72, 0.62)
		local handle = ring(0.5, 0.28, 0.36)
		handle.Size = UDim2.fromScale(0.36, 0.3)
	elseif kind == "trophy" then
		local cup = outlineBox(0.5, 0.33, 0.6, 0.46)
		make("UICorner", { CornerRadius = UDim.new(0.35, 0), Parent = cup })
		box(0.5, 0.68, 0.12, 0.24)
		box(0.5, 0.88, 0.5, 0.1)
	elseif kind == "card" then
		outlineBox(0.5, 0.5, 0.9, 0.66)
		outlineBox(0.3, 0.5, 0.2, 0.26)
		box(0.66, 0.42, 0.32, 0.08)
		box(0.66, 0.6, 0.32, 0.08)
	elseif kind == "gear" then
		for i = 0, 3 do
			box(0.5, 0.5, 0.14, 0.96, { Rotation = i * 45 })
		end
		local hub = box(0.5, 0.5, 0.62, 0.62, { BackgroundColor3 = T.ButtonBottom })
		make("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = hub })
		ring(0.5, 0.5, 0.5)
	else
		local label = make("TextLabel", {
			BackgroundTransparency = 1,
			Text = kind,
			Font = T.HeadFont,
			TextColor3 = color,
			TextScaled = false,
			Size = UDim2.fromScale(1, 1),
			ZIndex = zIndex,
			Parent = parent,
		})
		Layout.bindText(label, 40)
	end
end

-- Glyphs, tags, headers --------------------------------------------------------------

--[[
    An input glyph for `action` that follows Focus.mode(): keyboard text
    (Bangers for one letter, GothamBlack in a pill for ENTER / BKSP / TAB),
    the gamepad's button image (or its letter), hidden on Touch. opts =
    { size: number? (design px, default 34) } & Common; without a size it
    fills its parent (square).
]]
function UIKit.glyph(action, opts)
	opts = opts or {}
	local frame = make("Frame", {
		Name = "Glyph",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
	})
	local designSize = if type(opts.size) == "number" then opts.size else nil
	if opts.size == nil then
		-- fills its parent's height as a square
		frame.SizeConstraint = Enum.SizeConstraint.RelativeYY
	end
	applyCommon(frame, opts)
	local zIndex = frame.ZIndex
	local face = make("Frame", {
		Name = "Face",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = zIndex,
		Parent = frame,
	})
	local faceCorner = make("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = face })
	local letter = make("TextLabel", {
		Name = "Key",
		BackgroundTransparency = 1,
		TextColor3 = Color3.new(0, 0, 0),
		Size = UDim2.fromScale(1, 1),
		ZIndex = zIndex + 1,
		Parent = face,
	})
	local image = make("ImageLabel", {
		Name = "Image",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = zIndex + 1,
		Visible = false,
		Parent = frame,
	})

	local function resize()
		if not designSize then
			return
		end
		local side = Layout.px(designSize)
		local width = side
		if face.Visible and #letter.Text > 1 then
			width = math.max(side, letter.TextBounds.X + Layout.px(14))
		end
		frame.Size = UDim2.fromOffset(width, side)
	end

	local function render()
		local mode = Focus.mode()
		frame.Visible = mode ~= "Touch"
		local glyph = Focus.glyphFor(action, mode)
		local long = #(glyph.text or "") > 1
		image.Visible = glyph.image ~= nil
		face.Visible = glyph.image == nil
		if glyph.image then
			image.Image = glyph.image
		end
		letter.Text = glyph.text or ""
		letter.Font = if long then T.BlackFont else T.HeadFont
		faceCorner.CornerRadius = if long and mode == "Keyboard" then UDim.new(0.3, 0) else UDim.new(0.5, 0)
		Layout.bindText(letter, (designSize or 34) * (if long then 14 / 34 else 22 / 34))
		resize()
	end

	local conn = Focus.ModeChanged:Connect(render)
	frame.Destroying:Connect(function()
		conn.Disconnect()
	end)
	letter:GetPropertyChangedSignal("TextBounds"):Connect(resize)
	render()
	if designSize then
		-- its px size follows the safe area
		Layout.bindApply(frame, resize)
	end
	return frame
end

--[[
    A small slanted chip with GothamBlack caps ("RANKED", "6 MAPS", "LOCKED
    IN"). opts = { fill? (default Red), textColor?, size? (text, design px,
    default 18) } & Common. Without a UDim2 size it is as tall as its parent
    and as wide as its text. Its label is tag.Content.Text.
]]
function UIKit.tag(text, opts)
	opts = opts or {}
	local textSize = if type(opts.size) == "number" then opts.size else 18
	local root = make("Frame", {
		Name = "Tag",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
	})
	local autoWidth = typeof(opts.size) ~= "UDim2"
	applyCommon(root, opts)
	local state = buildSlant(root, { slant = T.Slant, fill = opts.fill or T.Red })
	local label = make("TextLabel", {
		Name = "Text",
		BackgroundTransparency = 1,
		Text = string.upper(text),
		Font = T.BlackFont,
		TextColor3 = opts.textColor or T.Text,
		Size = UDim2.fromScale(1, 1),
		ZIndex = state.content.ZIndex + 1,
		Parent = state.content,
	})
	Layout.bindText(label, textSize)
	if autoWidth then
		local function fit()
			local height = root.AbsoluteSize.Y
			if height <= 0 then
				return
			end
			local s = Shapes.offset(height, T.Slant)
			root.Size = UDim2.new(0, label.TextBounds.X + 2 * s + Layout.px(14), 1, 0)
		end
		label:GetPropertyChangedSignal("TextBounds"):Connect(fit)
		root:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			task.defer(fit)
		end)
		fit()
	end
	rememberSlant(root, state)
	return root
end

-- A section header: a red slanted bar and Bangers text. opts = { size? (text, default 40), accent? } & Common.
function UIKit.header(text, opts)
	opts = opts or {}
	local frame = make("Frame", {
		Name = "Header",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
	})
	applyCommon(frame, opts)
	local bar = make("Frame", {
		Name = "Bar",
		BackgroundColor3 = opts.accent or T.Red,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Rotation = T.Slant,
		ZIndex = frame.ZIndex,
		Parent = frame,
	})
	local label = make("TextLabel", {
		Name = "Text",
		BackgroundTransparency = 1,
		Text = text,
		Font = T.HeadFont,
		TextColor3 = T.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Size = UDim2.fromScale(1, 1),
		ZIndex = frame.ZIndex,
		Parent = frame,
	})
	local function relayout()
		local h = frame.AbsoluteSize.Y
		bar.Size = UDim2.fromOffset(math.max(3, round(h * 0.16)), round(h * 0.72))
		label.Position = UDim2.fromOffset(round(h * 0.45), 0)
		label.Size = UDim2.new(1, -round(h * 0.45), 1, 0)
	end
	frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayout)
	relayout()
	Layout.bindText(label, if type(opts.size) == "number" then opts.size else 40)
	return frame
end

-- Hint bar ----------------------------------------------------------------------------

--[[
    Glyph + label hints ("Ⓐ SELECT  Ⓑ BACK"). items = { { action, label,
    onClick? } }; every item is a tappable button (never registered with
    Focus): onClick, else it does what the action's key does (Focus.press,
    which runs the focused object's own action first, so a hint for a
    layer action should pass onClick). On touch a Confirm hint without
    onClick is hidden (again on every input mode change): touch shows no
    focus and focuses no default, so it would do nothing, or confirm
    whatever was tapped last; the player taps the item itself instead. A
    Confirm hint that must stay on touch passes its own onClick (legend
    select's LOCK IN). On phones the bar is at least 44 px tall and every
    item has side padding, so each is a 44 px touch target. opts =
    { anchor?, position? } (default bottom-right). Returns bar,
    setItems(items).
]]
function UIKit.hintBar(parent, items, opts)
	opts = opts or {}
	local anchor = opts.anchor or Vector2.new(1, 0.5)
	local bar = make("Frame", {
		Name = "Hints",
		BackgroundTransparency = 1,
		AnchorPoint = anchor,
		Position = opts.position or UDim2.fromScale(0.98, 0.946),
		Size = UDim2.fromScale(0.94, 0.05),
		ZIndex = 20,
		Parent = parent,
	})
	local list = make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = if anchor.X >= 0.5 then Enum.HorizontalAlignment.Right else Enum.HorizontalAlignment.Left,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = bar,
	})
	Layout.bindListPadding(list, 30)
	-- touch targets: at least 44 px tall on phones (the bar is 0.05 of a ~370 px safe area there)
	local minSize = make("UISizeConstraint", { Parent = bar })
	Layout.bindApply(minSize, function()
		minSize.MinSize = Vector2.new(0, if Layout.mode() == "Phone" then 44 else 0)
	end)

	local function setItems(newItems)
		for _, child in bar:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		for i, item in newItems or {} do
			local button = make("TextButton", {
				Name = "Hint" .. item.action,
				BackgroundTransparency = 1,
				AutoButtonColor = false,
				Text = "",
				AutomaticSize = Enum.AutomaticSize.X,
				Size = UDim2.fromScale(0, 1),
				LayoutOrder = i,
				ZIndex = bar.ZIndex,
				Parent = bar,
			})
			local inner = make("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Parent = button,
			})
			Layout.bindListPadding(inner, 10)
			local side = make("UIPadding", { Parent = button })
			Layout.bindApply(side, function()
				-- (on phones the glyph is hidden: the label alone would be a narrow target)
				local x = UDim.new(0, if Layout.mode() == "Phone" then 12 else 0)
				side.PaddingLeft, side.PaddingRight = x, x
			end)
			UIKit.glyph(item.action, { size = 34, parent = button, layoutOrder = 1, zIndex = bar.ZIndex + 1 })
			local label = make("TextLabel", {
				Name = "Label",
				BackgroundTransparency = 1,
				Text = string.upper(item.label),
				Font = T.BlackFont,
				TextColor3 = T.Text,
				AutomaticSize = Enum.AutomaticSize.X,
				Size = UDim2.fromScale(0, 1),
				LayoutOrder = 2,
				ZIndex = bar.ZIndex + 1,
				Parent = button,
			})
			Layout.bindText(label, 22)
			if item.action == "Confirm" and not item.onClick then
				-- (hidden on touch: see above; UIListLayout closes the gap)
				local function fit()
					button.Visible = Focus.mode() ~= "Touch"
				end
				local conn = Focus.ModeChanged:Connect(fit)
				button.Destroying:Connect(function()
					conn.Disconnect()
				end)
				fit()
			end
			button.Activated:Connect(function()
				if item.onClick then
					item.onClick()
				else
					Focus.press(item.action)
				end
			end)
		end
	end
	setItems(items)
	return bar, setItems
end

-- Tabs ----------------------------------------------------------------------------------

--[[
    Slanted tabs switched by clicks and taps (screens bind L1/R1 or L2/R2 to
    cycle; the tabs aren't focus stops). opts = { style? ("big": Bangers
    40, "small": GothamBlack 18 chips), onSelect(id) } & Common. Returns
    frame, select(id) (calls onSelect), current(), cycle(delta).
]]
function UIKit.tabBar(tabs, opts)
	opts = opts or {}
	local big = opts.style ~= "small"
	local frame = make("Frame", {
		Name = "Tabs",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
	})
	applyCommon(frame, opts)
	local list = make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = frame,
	})
	Layout.bindListPadding(list, if big then 10 else 6)
	local currentId = tabs[1] and tabs[1].id
	local entries = {}
	local function render()
		for id, entry in entries do
			local on = id == currentId
			entry.state.setFill(if on then { T.RedLight, T.RedDark } else { T.ButtonTop, T.ButtonBottom })
			entry.state.setRing(if on and big then 3 else 0)
			entry.label.TextColor3 = if on or big then T.Text else T.Muted
			entry.label.TextTransparency = if on or not big then 0 else 0.25
		end
	end
	local function selectTab(id)
		currentId = id
		render()
		if opts.onSelect then
			opts.onSelect(id)
		end
	end
	for i, tab in tabs do
		local button = make("TextButton", {
			Name = tab.id,
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			Text = "",
			Size = UDim2.fromScale(if big then 1 / math.max(#tabs, 2) else 0.5 / math.max(#tabs, 1), 1),
			LayoutOrder = i,
			ZIndex = frame.ZIndex,
			Parent = frame,
		})
		local state = buildSlant(button, { slant = T.Slant, outline = if big then 3 else 0 })
		local label = make("TextLabel", {
			Name = "Label",
			BackgroundTransparency = 1,
			Text = string.upper(tab.label),
			Font = if big then T.HeadFont else T.BlackFont,
			TextColor3 = T.Text,
			Size = UDim2.fromScale(1, 1),
			ZIndex = state.content.ZIndex + 1,
			Parent = state.content,
		})
		Layout.bindText(label, if big then 40 else 18)
		entries[tab.id] = { button = button, state = state, label = label }
		button.Activated:Connect(function()
			Sound.play("MenuConfirm", CONFIRM_VOLUME)
			selectTab(tab.id)
		end)
	end
	render()
	local function current()
		return currentId
	end
	local function cycle(delta)
		local index = 1
		for i, tab in tabs do
			if tab.id == currentId then
				index = i
			end
		end
		local nextTab = tabs[(index - 1 + delta) % #tabs + 1]
		if nextTab then
			Sound.play("MenuHover", 0.35)
			selectTab(nextTab.id)
		end
	end
	return frame, selectTab, current, cycle
end

-- Buttons and cards ------------------------------------------------------------------

--[[
    The visual of a slanted button or card inside its hit area: a plain
    frame (it slides and widens with the focus nudge) holding the slanted
    shape and two red glows behind it. Focused: red fill (gold stays gold),
    a white ring inside a thicker black outline and the glows, 8 and 16 px
    beyond the outline. Disabled: a Backdrop-coloured copy of the shape at
    0.5 over the fill and the content (made on first use). The content
    (state.content) sits in no CanvasGroup: only the shadow, the glows and
    the dim are groups, and each holds plain shape pieces.
]]
local function slantVisual(button, opts)
	local deg = opts.slant or T.Slant
	local nudge = opts.nudge == true
	local visual = make("Frame", {
		Name = "Visual",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = button.ZIndex,
		Parent = button,
	})
	local glows = {}
	local shapeRoot = holderFrame("Shape", button.ZIndex + 1, visual)
	local state = buildSlant(shapeRoot, {
		slant = deg,
		gradient = opts.colors,
		outline = 4,
		shadow = true,
	})
	local visualState = { state = state, visual = visual, active = false, disabled = false }
	local dim = nil -- { group, shape }

	local function geometry(active)
		local nudgePx = if nudge then Layout.px(46) else 0
		local widen = if nudge then Layout.px(15) else 0
		local x = if active and nudge then nudgePx else 0
		local extra = if active and nudge then widen else 0
		return UDim2.fromOffset(x, 0), UDim2.new(1, -nudgePx + extra, 1, 0)
	end

	-- A group holding one opaque slanted shape in `color` (glows sit behind the shape, the dim above its content).
	local function shapeGroup(name, parent, zIndex, transparency, color)
		local group = make("CanvasGroup", {
			Name = name,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			GroupTransparency = transparency,
			ZIndex = zIndex,
			Visible = false,
			Parent = parent,
		})
		return group, slantShape(holderFrame("Shape", zIndex, group), deg, { color })
	end

	local function makeGlow(index, outset, transparency)
		local group, shape = shapeGroup("Glow" .. index, visual, button.ZIndex, transparency, T.Red)
		glows[index] = { group = group, shape = shape, outset = outset }
	end

	local function layoutShapes()
		local size = shapeRoot.AbsoluteSize
		local w, h = round(size.X), round(size.Y)
		if w <= 0 or h <= 0 then
			return
		end
		for _, glow in glows do
			local box = Shapes.outset(w, h, deg, Layout.px(glow.outset))
			glow.group.Position = UDim2.fromOffset(box.x, box.y)
			glow.group.Size = UDim2.fromOffset(box.w, box.h)
			glow.shape.layout(box.w, box.h)
		end
		if dim then
			dim.shape.layout(w, h)
		end
	end

	local function place(animate)
		local position, size = geometry(visualState.active and not visualState.disabled)
		if animate then
			local info = TweenInfo.new(FOCUS_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			TweenService:Create(visual, info, { Position = position, Size = size }):Play()
		else
			visual.Position = position
			visual.Size = size
		end
	end

	function visualState.render(animate)
		local active = visualState.active and not visualState.disabled
		if active and opts.focusColors then
			state.setFill(opts.focusColors)
		else
			state.setFill(opts.colors)
		end
		state.ring = if active then 4 else 0
		state.outline = 4
		state.relayout()
		if active and #glows == 0 then
			-- 8 and 16 px beyond the focused outline (ring 4 + outline 4)
			makeGlow(1, 16, 0.6)
			makeGlow(2, 24, 0.82)
			layoutShapes()
		end
		for _, glow in glows do
			glow.group.Visible = active
		end
		if visualState.disabled and not dim then
			local group, shape = shapeGroup("Disabled", shapeRoot, state.content.ZIndex + 1, 0.5, T.Backdrop)
			group.Size = UDim2.fromScale(1, 1)
			dim = { group = group, shape = shape }
			layoutShapes()
		end
		if dim then
			dim.group.Visible = visualState.disabled
		end
		place(animate)
	end

	shapeRoot:GetPropertyChangedSignal("AbsoluteSize"):Connect(layoutShapes)
	-- the nudge is px: follow the safe area
	Layout.bindApply(visual, function()
		place(false)
	end)
	return visualState
end

local SLANT_STYLES = {
	dark = { colors = { T.ButtonTop, T.ButtonBottom }, focus = { T.RedLight, T.RedDark }, text = T.Text },
	primary = { colors = { T.RedLight, T.RedDark }, focus = { T.RedLight, T.RedDark }, text = T.Text },
	gold = { colors = { T.GoldLight, T.GoldDeep }, focus = { T.GoldLight, T.GoldDeep }, text = T.GoldDark },
	ghost = { colors = { T.Raised }, focus = { T.RedLight, T.RedDark }, text = T.Muted },
}

--[[
    A slanted button (menus design 5.3). The TextButton is the hit area and
    focus target and never moves; its size is the unfocused size plus the
    nudge. opts = { style? ("dark" default, "primary", "gold", "ghost"),
    icon? (a line icon: "swords", "target", "grid", "person", "bag",
    "trophy", "card", "gear", or any text), textSize? (design px, default 34),
    badge?, sublabel?, glyph? (the action whose glyph shows at the right end
    when focused, default "Confirm"), nudge? (slide right when focused),
    slant? } & Common. onClick runs on clicks, taps and Confirm.
]]
function UIKit.slantButton(text, opts, onClick)
	opts = opts or {}
	local style = SLANT_STYLES[opts.style or "dark"] or SLANT_STYLES.dark
	local button = make("TextButton", {
		Name = "SlantButton",
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Text = "",
		Size = UDim2.fromScale(0.26, 0.065),
	})
	applyCommon(button, opts)
	button:SetAttribute("UIKitKind", "SlantButton")
	local visual = slantVisual(button, {
		slant = opts.slant,
		nudge = opts.nudge,
		colors = style.colors,
		focusColors = style.focus,
	})
	local content = visual.state.content
	local zIndex = content.ZIndex + 1
	local textSize = opts.textSize or 34

	local left = make("Frame", {
		Name = "Main",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = zIndex,
		Parent = content,
	})
	local leftList = make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = left,
	})
	if opts.icon then
		local icon = make("Frame", {
			Name = "Icon",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(0.5, 0.5),
			SizeConstraint = Enum.SizeConstraint.RelativeYY,
			LayoutOrder = 1,
			ZIndex = zIndex,
			Parent = left,
		})
		drawIcon(opts.icon, icon, style.text)
	end
	local textBox = make("Frame", {
		Name = "TextBox",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(0.8, 1),
		LayoutOrder = 2,
		ZIndex = zIndex,
		Parent = left,
	})
	local label = make("TextLabel", {
		Name = "Label",
		BackgroundTransparency = 1,
		Text = text,
		Font = T.HeadFont,
		TextColor3 = style.text,
		TextXAlignment = if opts.icon then Enum.TextXAlignment.Left else Enum.TextXAlignment.Center,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Size = UDim2.fromScale(1, if opts.sublabel then 0.66 else 1),
		ZIndex = zIndex,
		Parent = textBox,
	})
	Layout.bindText(label, textSize)
	if opts.sublabel then
		local sub = make("TextLabel", {
			Name = "Sublabel",
			BackgroundTransparency = 1,
			Text = opts.sublabel,
			Font = T.BoldFont,
			TextColor3 = T.Muted,
			TextXAlignment = label.TextXAlignment,
			Position = UDim2.fromScale(0, 0.62),
			Size = UDim2.fromScale(1, 0.32),
			ZIndex = zIndex,
			Parent = textBox,
		})
		Layout.bindText(sub, math.max(14, textSize * 0.42))
	end

	local right = make("Frame", {
		Name = "Right",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromScale(1, 1),
		ZIndex = zIndex,
		Parent = content,
	})
	local rightList = make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = right,
	})
	Layout.bindListPadding(rightList, 10)
	local glyphHolder = make("Frame", {
		Name = "GlyphHolder",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(0.58, 0.58),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		LayoutOrder = 2,
		ZIndex = zIndex,
		Visible = false,
		Parent = right,
	})
	if opts.glyph ~= false then
		UIKit.glyph(if type(opts.glyph) == "string" then opts.glyph else "Confirm", {
			parent = glyphHolder,
			zIndex = zIndex,
		})
	end

	local function spacing()
		leftList.Padding = UDim.new(0, Layout.px(18))
		local iconWidth = if opts.icon then content.AbsoluteSize.Y * 0.5 + Layout.px(18) else 0
		textBox.Size = UDim2.new(1, -math.ceil(iconWidth), 1, 0)
	end
	content:GetPropertyChangedSignal("AbsoluteSize"):Connect(spacing)
	spacing()

	local function render(animate)
		visual.disabled = button:GetAttribute("Disabled") == true
		visual.render(animate)
		glyphHolder.Visible = visual.active and not visual.disabled
	end
	button:GetAttributeChangedSignal("Disabled"):Connect(function()
		render(true)
	end)
	rememberSlant(button, { badgeParent = right, zIndex = zIndex })
	Focus.register(button, {
		key = opts.name or text,
		_style = function(on)
			visual.active = on
			render(true)
		end,
	})
	if onClick then
		UIKit.onActivate(button, onClick)
	end
	if opts.badge then
		UIKit.setBadge(button, opts.badge)
	end
	render(false)
	return button
end

-- Shows a small tag ("NEW", "2 OPEN", a count) at the right end of a slant button or card; nil hides it.
function UIKit.setBadge(button, text)
	local state = slantStates[button]
	local parent = if state and state.badgeParent then state.badgeParent else button
	local old = parent:FindFirstChild("Badge")
	if old then
		old:Destroy()
	end
	if text == nil or text == "" then
		return
	end
	local holder = make("Frame", {
		Name = "Badge",
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromScale(0, 0.44),
		LayoutOrder = 1,
		ZIndex = if state then state.zIndex else button.ZIndex + 1,
		Parent = parent,
	})
	if not (state and state.badgeParent) then
		holder.AnchorPoint = Vector2.new(1, 0)
		holder.Position = UDim2.fromScale(0.98, 0.06)
	end
	UIKit.tag(text, { parent = holder, zIndex = holder.ZIndex, size = 16 })
end

--[[
    A cut-corner panel: top-right and bottom-left corners cut at 45 degrees
    by `cut` (design px, default 22), a 2 px border (Stroke) that is 2 px on
    the diagonals too, an opaque fill (Panel). opts = { cut?, fill?, border?,
    title?, titleSize? } & Common. Returns panel, body (below the title
    header when there is one).
]]
function UIKit.cutPanel(opts)
	opts = opts or {}
	local panel = make("Frame", {
		Name = "CutPanel",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
	})
	applyCommon(panel, opts)
	local zIndex = panel.ZIndex
	local borderHolder = holderFrame("Border", zIndex, panel)
	local fillHolder = holderFrame("Fill", zIndex, panel)
	local border = cutShape(borderHolder, opts.border or T.Stroke)
	local fill = cutShape(fillHolder, opts.fill or T.Panel)
	local function relayout()
		local size = panel.AbsoluteSize
		local w, h = round(size.X), round(size.Y)
		if w <= 0 or h <= 0 then
			return
		end
		local c = Layout.px(opts.cut or T.Cut)
		local b = math.max(1, Layout.px(2))
		fill.layout(w, h, c)
		borderHolder.Position = UDim2.fromOffset(-b, -b)
		borderHolder.Size = UDim2.fromOffset(w + 2 * b, h + 2 * b)
		border.layout(w + 2 * b, h + 2 * b, round(Shapes.cutBorder(c, b)))
	end
	panel:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayout)
	relayout()
	task.defer(relayout)

	local body = holderFrame("Body", zIndex + 1, panel)
	if opts.title then
		local titleSize = opts.titleSize or 40
		UIKit.header(opts.title, {
			parent = panel,
			name = "Title",
			size = titleSize,
			position = UDim2.new(0, 0, 0, 0),
			zIndex = zIndex + 1,
		})
		local title = panel:FindFirstChild("Title")
		local function placeTitle()
			local px = Layout.px(titleSize)
			local pad = Layout.px(18)
			title.Position = UDim2.fromOffset(pad, pad * 0.6)
			title.Size = UDim2.new(1, -2 * pad, 0, px + 4)
			body.Position = UDim2.fromOffset(0, px + pad)
			body.Size = UDim2.new(1, 0, 1, -(px + pad))
		end
		placeTitle()
		panel:GetPropertyChangedSignal("AbsoluteSize"):Connect(placeTitle)
	end
	return panel, body
end

--[[
    A focusable card (Online Play): a slanted panel (6 degrees) with a black
    outline, shadow and an accent strip; focused it gets the white ring and
    red glow. opts = { slant?, accent?, onClick? } & Common. Returns card
    (the TextButton hit area), body (the inner rectangle).
]]
function UIKit.card(opts)
	opts = opts or {}
	local card = make("TextButton", {
		Name = "Card",
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Text = "",
		Size = UDim2.fromScale(1, 1),
	})
	applyCommon(card, opts)
	card:SetAttribute("UIKitKind", "Card")
	local visual = slantVisual(card, {
		slant = opts.slant or T.CardSlant,
		colors = { T.Panel },
	})
	local body = visual.state.content
	if opts.accent then
		local accent = make("Frame", {
			Name = "Accent",
			BackgroundColor3 = opts.accent,
			BorderSizePixel = 0,
			ZIndex = body.ZIndex + 1,
			Parent = body,
		})
		Layout.bindApply(accent, function()
			accent.Size = UDim2.new(1, 0, 0, Layout.px(6))
		end)
	end
	local function render(animate)
		visual.disabled = card:GetAttribute("Disabled") == true
		visual.render(animate)
	end
	card:GetAttributeChangedSignal("Disabled"):Connect(function()
		render(true)
	end)
	rememberSlant(card, { badgeParent = nil, zIndex = body.ZIndex + 2 })
	Focus.register(card, {
		key = opts.name,
		_style = function(on)
			visual.active = on
			render(true)
		end,
	})
	if opts.onClick then
		UIKit.onActivate(card, function()
			opts.onClick()
		end)
	end
	render(false)
	return card, body
end

-- Bars, pips, ring, tier badge ---------------------------------------------------------

-- A thin bar. opts = { fill? (default Red), back? } & Common. Returns bar, set(fraction, fill?).
function UIKit.progressBar(opts)
	opts = opts or {}
	local bar = make("Frame", {
		Name = "ProgressBar",
		BackgroundColor3 = opts.back or T.Backdrop,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ClipsDescendants = true,
	})
	applyCommon(bar, opts)
	local fillFrame = make("Frame", {
		Name = "Fill",
		BackgroundColor3 = opts.fill or T.Red,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(0, 1),
		ZIndex = bar.ZIndex,
		Parent = bar,
	})
	local function set(fraction, fill)
		fraction = if type(fraction) == "number" and fraction == fraction then fraction else 0
		fillFrame.Size = UDim2.fromScale(math.clamp(fraction, 0, 1), 1)
		if fill then
			fillFrame.BackgroundColor3 = fill
		end
	end
	set(0)
	return bar, set
end

-- A row of `total` pips, `filled` of them lit. opts = { fill? (default Gold) } & Common. Returns frame, set(filled).
function UIKit.pips(total, filled, opts)
	opts = opts or {}
	local frame = make("Frame", {
		Name = "Pips",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
	})
	applyCommon(frame, opts)
	local gap = 0.18 -- of a pip's width
	local pips = {}
	for i = 1, total do
		local width = 1 / (total + (total - 1) * gap)
		pips[i] = make("Frame", {
			Name = "Pip" .. i,
			BorderSizePixel = 0,
			Position = UDim2.fromScale((i - 1) * width * (1 + gap), 0),
			Size = UDim2.fromScale(width, 1),
			ZIndex = frame.ZIndex,
			Parent = frame,
		})
	end
	local function set(count)
		for i, pip in pips do
			pip.BackgroundColor3 = if i <= count then opts.fill or T.Gold else T.Raised
		end
	end
	set(filled or 0)
	return frame, set
end

--[[
    A countdown ring: a dark track and a ring that fills clockwise from 12
    o'clock (two clipped half frames whose circles' stroke gradients are
    rotated by Shapes.ringRotations), with a LuckiestGuy number in the
    middle. opts = { fill? (default Red), textSize? (default 64) } & Common
    (square; keeps its aspect). Returns frame, set(fraction, text).
]]
function UIKit.ring(opts)
	opts = opts or {}
	local frame = make("Frame", {
		Name = "Ring",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
	})
	applyCommon(frame, opts)
	make("UIAspectRatioConstraint", { AspectRatio = 1, Parent = frame })
	local zIndex = frame.ZIndex
	local circles = {}
	-- A transparent circle whose stroke is the ring. `x` / `width` are in its holder's widths: the track holder is
	-- the whole square; a half holder is half of it, so its circle is 2 wide and the right half's starts at -1.
	local function circle(holder, color, x, width)
		local c = make("Frame", {
			Name = "Circle",
			BackgroundTransparency = 1,
			ZIndex = zIndex,
			Parent = holder,
		})
		make("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = c })
		local stroke = make("UIStroke", {
			Color = color,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Parent = c,
		})
		table.insert(circles, { frame = c, stroke = stroke, x = x, width = width })
		return stroke
	end
	local track = make("Frame", {
		Name = "Track",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = zIndex,
		Parent = frame,
	})
	circle(track, T.Raised, 0, 1)
	local gradients = {}
	for _, side in { "Right", "Left" } do
		local half = make("Frame", {
			Name = side,
			BackgroundTransparency = 1,
			ClipsDescendants = true,
			Position = UDim2.fromScale(if side == "Right" then 0.5 else 0, 0),
			Size = UDim2.fromScale(0.5, 1),
			ZIndex = zIndex,
			Parent = frame,
		})
		local stroke = circle(half, opts.fill or T.Red, if side == "Right" then -1 else 0, 2)
		gradients[side] = make("UIGradient", {
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0),
				NumberSequenceKeypoint.new(0.5, 0),
				NumberSequenceKeypoint.new(0.501, 1),
				NumberSequenceKeypoint.new(1, 1),
			}),
			Parent = stroke,
		})
	end
	local label = make("TextLabel", {
		Name = "Number",
		BackgroundTransparency = 1,
		Text = "",
		Font = T.LogoFont,
		TextColor3 = T.Text,
		Size = UDim2.fromScale(1, 1),
		ZIndex = zIndex + 1,
		Parent = frame,
	})
	Layout.bindText(label, opts.textSize or 64)

	local function relayout()
		local side = frame.AbsoluteSize.X
		if side <= 0 then
			return
		end
		local thickness = math.max(2, round(side * 0.085))
		for _, c in circles do
			-- a border stroke is drawn outside its frame, so the circle sits inset by the thickness
			c.frame.Position = UDim2.new(c.x, thickness, 0, thickness)
			c.frame.Size = UDim2.new(c.width, -2 * thickness, 1, -2 * thickness)
			c.stroke.Thickness = thickness
		end
	end
	frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayout)
	relayout()

	local function set(fraction, text)
		local rightRotation, leftRotation = Shapes.ringRotations(fraction or 0)
		gradients.Right.Rotation = rightRotation
		gradients.Left.Rotation = leftRotation
		label.Text = text or ""
	end
	set(0, "")
	return frame, set
end

local function tierInfo(tierName)
	for _, tier in Config.Ranked.Tiers do
		if tier.Name == tierName then
			return tier
		end
	end
	return Ranks.tier(0)
end

--[[
    A rank tier badge: a square rotated 45 degrees (rounded corners) in the
    tier colour with a darker inner square, two white Bangers chevrons on
    top (unrotated siblings), and the tier name beside it when
    opts.withName. opts = { size? (design px) , withName? } & Common;
    without a size it fills its parent.
]]
function UIKit.tierBadge(tierName, opts)
	opts = opts or {}
	local tier = tierInfo(tierName)
	local frame = make("Frame", {
		Name = "TierBadge",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
	})
	applyCommon(frame, opts)
	if type(opts.size) == "number" then
		Layout.bindPxSize(frame, if opts.withName then opts.size * 4 else opts.size, opts.size)
	end
	local zIndex = frame.ZIndex
	local badge = make("Frame", {
		Name = "Badge",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		ZIndex = zIndex,
		Parent = frame,
	})
	local outer = make("Frame", {
		Name = "Outer",
		BackgroundColor3 = tier.Color,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.68, 0.68),
		Rotation = 45,
		ZIndex = zIndex,
		Parent = badge,
	})
	make("UICorner", { CornerRadius = UDim.new(0.18, 0), Parent = outer })
	local inner = make("Frame", {
		Name = "Inner",
		BackgroundColor3 = tier.Color:Lerp(Color3.new(0, 0, 0), 0.4),
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.44, 0.44),
		Rotation = 45,
		ZIndex = zIndex + 1,
		Parent = badge,
	})
	make("UICorner", { CornerRadius = UDim.new(0.18, 0), Parent = inner })
	-- two white chevrons (^), each two bars meeting at the top, drawn over the squares (not inside the rotated
	-- ones). Rotation is clockwise on screen: the left bar turns -38 (its inner end rises), the right one +38.
	for i, y in { 0.4, 0.58 } do
		for _, sideSign in { -1, 1 } do
			make("Frame", {
				Name = "Chevron" .. i,
				BackgroundColor3 = Color3.new(1, 1, 1),
				BorderSizePixel = 0,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5 + sideSign * 0.075, y),
				Size = UDim2.fromScale(0.2, 0.07),
				Rotation = sideSign * 38,
				ZIndex = zIndex + 2,
				Parent = badge,
			})
		end
	end
	if opts.withName then
		local name = make("TextLabel", {
			Name = "TierName",
			BackgroundTransparency = 1,
			Text = string.upper(tier.Name),
			Font = T.BlackFont,
			TextColor3 = tier.Color,
			TextXAlignment = Enum.TextXAlignment.Left,
			AnchorPoint = Vector2.new(0, 0.5),
			Size = UDim2.fromScale(1, 0.6),
			ZIndex = zIndex,
			Parent = frame,
		})
		local function place()
			local side = badge.AbsoluteSize.Y
			name.Position = UDim2.new(0, side * 1.1, 0.5, 0)
			name.Size = UDim2.new(1, -side * 1.1, 0.6, 0)
		end
		badge:GetPropertyChangedSignal("AbsoluteSize"):Connect(place)
		place()
		Layout.bindText(name, if type(opts.size) == "number" then opts.size * 0.55 else 22)
	end
	return frame
end

-- Dialogs -----------------------------------------------------------------------------

-- The SkybrawlPrompts ScreenGui (invite prompts, confirm dialogs), made on first use.
function UIKit.promptsGui()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = playerGui:FindFirstChild("SkybrawlPrompts")
	if not gui then
		gui = Layout.screenGui("SkybrawlPrompts", 45, "Safe")
	end
	return gui
end

local DIALOG_PHASES = { Menu = true, Results = true }

--[[
    A confirm dialog: a centred cut panel in SkybrawlPrompts with CONFIRM
    (red) and CANCEL (dark) in a modal Focus layer (Back = cancel; Confirm
    is ignored for Config.Menu.InputGrace after it opens). opts = { title,
    body, confirm, cancel?, onConfirm, onCancel? }. Dialogs belong to the
    Menu and Results phases: one opened in any other phase is cancelled at
    once, and an open one closes itself as cancelled when the phase changes
    to Select, Vs or Match. Returns close() (closes without calling either
    callback).
]]
function UIKit.dialog(opts)
	local gui = UIKit.promptsGui()
	local closed = false
	local layer, phaseConn = nil, nil
	local shade = make("Frame", {
		Name = "Dialog",
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		Active = true,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 50,
		Parent = gui,
	})
	local function close()
		if closed then
			return
		end
		closed = true
		if phaseConn then
			phaseConn.Disconnect()
		end
		if layer then
			Focus.popLayer(layer)
		end
		shade:Destroy()
	end
	local function cancel()
		if closed then
			return
		end
		close()
		if opts.onCancel then
			task.spawn(opts.onCancel)
		end
	end
	local phone = Layout.mode() == "Phone"
	local _, body = UIKit.cutPanel({
		parent = shade,
		anchor = Vector2.new(0.5, 0.5),
		position = UDim2.fromScale(0.5, 0.5),
		size = if phone then UDim2.fromScale(0.7, 0.62) else UDim2.fromScale(0.36, 0.32),
		zIndex = 51,
		title = opts.title,
		titleSize = 54,
	})
	local text = make("TextLabel", {
		Name = "Text",
		BackgroundTransparency = 1,
		Text = opts.body or "",
		Font = T.BodyFont,
		TextColor3 = T.Muted,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromScale(0.06, 0.04),
		Size = UDim2.fromScale(0.88, 0.5),
		ZIndex = 53,
		Parent = body,
	})
	Layout.bindText(text, 26)
	local buttons = {}
	local confirmButton = UIKit.slantButton(opts.confirm or "CONFIRM", {
		style = "primary",
		parent = body,
		anchor = Vector2.new(0, 1),
		position = UDim2.fromScale(0.06, 0.9),
		size = UDim2.fromScale(if opts.cancel then 0.42 else 0.88, 0.3),
		zIndex = 53,
		name = "Confirm",
	}, function()
		if closed then
			return
		end
		close()
		opts.onConfirm()
	end)
	table.insert(buttons, confirmButton)
	local cancelButton = nil
	if opts.cancel then
		cancelButton = UIKit.slantButton(opts.cancel, {
			style = "dark",
			parent = body,
			anchor = Vector2.new(1, 1),
			position = UDim2.fromScale(0.94, 0.9),
			size = UDim2.fromScale(0.42, 0.3),
			zIndex = 53,
			name = "Cancel",
			glyph = "Back",
		}, cancel)
		table.insert(buttons, cancelButton)
	end
	Focus.linkRow(buttons)
	layer = Focus.pushLayer({
		name = "Dialog",
		roots = { shade },
		band = "modal",
		defaultFocus = function()
			-- the safe choice first: these confirm leaving, kicking...
			return cancelButton or confirmButton
		end,
		onBack = cancel,
		confirmDelay = Config.Menu.InputGrace,
	})
	phaseConn = ClientState.PhaseChanged:Connect(function(phase)
		if not DIALOG_PHASES[phase] then
			cancel()
		end
	end)
	if not DIALOG_PHASES[ClientState.phase] then
		-- (a modal layer in a match would take no input and leave fight input on)
		cancel()
	end
	return close
end

--[[
    Runs fn(button) on Confirm (Focus), clicks and taps, ignoring presses
    while a previous fn is still running (handlers often wait on the server),
    while the button is disabled, and during its layer's confirmDelay.
]]
function UIKit.onActivate(button, fn)
	local running = false
	local function fire()
		if running or button:GetAttribute("Disabled") then
			return
		end
		running = true
		local ok, err = pcall(fn, button)
		running = false
		if not ok then
			warn("[UIKit] activate handler failed:", err)
		end
	end
	Focus.register(button, { onActivate = fire })
	button.Activated:Connect(function()
		if running or button:GetAttribute("Disabled") or not Focus.accepts(button) then
			return
		end
		Sound.play("MenuConfirm", CONFIRM_VOLUME)
		fire()
	end)
end

return UIKit
