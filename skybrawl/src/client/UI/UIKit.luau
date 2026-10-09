--[[
    Small helpers for building the UI in code with one consistent look:
    dark navy panels, gold accents, rounded corners.

    Controls use click-to-cycle and ◀ ▶ steppers instead of drag sliders
    so they work the same with mouse, touch and gamepad.
]]

local TweenService = game:GetService("TweenService")

local UIKit = {}

UIKit.Theme = {
	Backdrop = Color3.fromRGB(8, 10, 24),
	Panel = Color3.fromRGB(26, 32, 62),
	PanelLight = Color3.fromRGB(40, 48, 92),
	PanelDark = Color3.fromRGB(18, 22, 44),
	Stroke = Color3.fromRGB(86, 104, 180),
	Text = Color3.fromRGB(245, 247, 255),
	Muted = Color3.fromRGB(165, 175, 215),
	Gold = Color3.fromRGB(255, 198, 70),
	GoldDark = Color3.fromRGB(60, 40, 10),
	Teal = Color3.fromRGB(80, 210, 230),
	Danger = Color3.fromRGB(232, 78, 90),
	Good = Color3.fromRGB(110, 220, 130),
	HeadFont = Enum.Font.FredokaOne,
	BodyFont = Enum.Font.GothamMedium,
	BoldFont = Enum.Font.GothamBold,

	-- Menus palette (menus design 3.8). C1 restyles the keys above with it.
	Raised = Color3.fromRGB(24, 27, 34),
	Outline = Color3.fromRGB(0, 0, 0),
	Dim = Color3.fromRGB(107, 114, 130),
	Red = Color3.fromRGB(236, 47, 59),
	RedLight = Color3.fromRGB(255, 75, 85),
	RedDark = Color3.fromRGB(207, 21, 32),
	GoldLight = Color3.fromRGB(255, 215, 105),
	GoldDeep = Color3.fromRGB(226, 160, 24),
	XP = Color3.fromRGB(143, 211, 255),
	Warning = Color3.fromRGB(255, 154, 46),
	ButtonTop = Color3.fromRGB(39, 43, 52),
	ButtonBottom = Color3.fromRGB(22, 24, 30),
	Hurtbox = Color3.fromRGB(73, 180, 255),
	Hitbox = Color3.fromRGB(255, 59, 70),
	DamageHot = Color3.fromRGB(255, 138, 42),
	Startup = Color3.fromRGB(47, 191, 92),
	Active = Color3.fromRGB(236, 47, 59),
	Recovery = Color3.fromRGB(63, 140, 255),
	VsRed = { Color3.fromRGB(61, 6, 12), Color3.fromRGB(143, 16, 24) },
	VsBlue = { Color3.fromRGB(11, 42, 96), Color3.fromRGB(18, 63, 138) },
	LogoGradient = { Color3.fromRGB(255, 255, 255), Color3.fromRGB(255, 210, 63), Color3.fromRGB(242, 134, 15) },
	LogoFont = Enum.Font.LuckiestGuy,
	BlackFont = Enum.Font.GothamBlack,
	Slant = 14, -- degrees
	CardSlant = 6,
	SlotSlant = 10,
	Cut = 22, -- design px
}

local T = UIKit.Theme

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

function UIKit.corner(radius)
	return make("UICorner", { CornerRadius = UDim.new(0, radius or 10) })
end

function UIKit.stroke(color, thickness, transparency)
	return make("UIStroke", {
		Color = color or T.Stroke,
		Thickness = thickness or 1.5,
		Transparency = transparency or 0.3,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

function UIKit.padding(x, y)
	y = y or x
	return make("UIPadding", {
		PaddingLeft = UDim.new(0, x),
		PaddingRight = UDim.new(0, x),
		PaddingTop = UDim.new(0, y),
		PaddingBottom = UDim.new(0, y),
	})
end

function UIKit.list(direction, spacing, hAlign, vAlign)
	return make("UIListLayout", {
		FillDirection = direction or Enum.FillDirection.Vertical,
		Padding = UDim.new(0, spacing or 8),
		HorizontalAlignment = hAlign or Enum.HorizontalAlignment.Left,
		VerticalAlignment = vAlign or Enum.VerticalAlignment.Top,
		SortOrder = Enum.SortOrder.LayoutOrder,
	})
end

function UIKit.label(text, size, props)
	local label = make("TextLabel", {
		BackgroundTransparency = 1,
		Text = text or "",
		TextSize = size or 16,
		Font = T.BodyFont,
		TextColor3 = T.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		TextWrapped = true,
		Size = UDim2.new(1, 0, 0, (size or 16) + 6),
	})
	for key, value in props or {} do
		label[key] = value
	end
	return label
end

function UIKit.heading(text, size, props)
	local label = UIKit.label(text, size or 24, props)
	label.Font = T.HeadFont
	return label
end

local BUTTON_STYLES = {
	primary = { bg = T.Gold, text = T.GoldDark, stroke = Color3.fromRGB(255, 230, 150) },
	secondary = { bg = T.PanelLight, text = T.Text, stroke = T.Stroke },
	danger = { bg = T.Danger, text = Color3.new(1, 1, 1), stroke = Color3.fromRGB(255, 160, 170) },
	ghost = { bg = T.Panel, text = T.Muted, stroke = T.Stroke },
	good = { bg = T.Good, text = Color3.fromRGB(10, 40, 20), stroke = Color3.fromRGB(190, 255, 200) },
}

function UIKit.styleButton(button, style)
	local s = BUTTON_STYLES[style] or BUTTON_STYLES.secondary
	button.BackgroundColor3 = s.bg
	button.TextColor3 = s.text
	local stroke = button:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = s.stroke
	end
	button:SetAttribute("Style", style)
end

function UIKit.button(text, style, onClick, props)
	local button = make("TextButton", {
		AutoButtonColor = false,
		Text = text,
		Font = T.HeadFont,
		TextSize = 18,
		Size = UDim2.new(0, 140, 0, 38),
		BorderSizePixel = 0,
	}, {
		UIKit.corner(10),
		UIKit.stroke(nil, 1.5, 0.35),
	})
	UIKit.styleButton(button, style or "secondary")
	for key, value in props or {} do
		button[key] = value
	end
	local scale = make("UIScale", { Parent = button })
	button.MouseEnter:Connect(function()
		TweenService:Create(scale, TweenInfo.new(0.08), { Scale = 1.04 }):Play()
	end)
	button.MouseLeave:Connect(function()
		TweenService:Create(scale, TweenInfo.new(0.08), { Scale = 1 }):Play()
	end)
	if onClick then
		-- Handlers often wait on the server; ignore clicks until they finish
		-- so a double-click can't send the same request twice.
		local running = false
		button.Activated:Connect(function()
			if running or button:GetAttribute("Disabled") then
				return
			end
			running = true
			local ok, err = pcall(onClick, button)
			running = false
			if not ok then
				warn("[UIKit] button handler failed:", err)
			end
		end)
	end
	return button
end

function UIKit.setEnabled(button, enabled)
	button:SetAttribute("Disabled", not enabled)
	button.AutoButtonColor = false
	button.BackgroundTransparency = enabled and 0 or 0.55
	button.TextTransparency = enabled and 0 or 0.45
end

function UIKit.panel(props)
	local frame = make("Frame", {
		BackgroundColor3 = T.Panel,
		BorderSizePixel = 0,
	}, {
		UIKit.corner(14),
		UIKit.stroke(nil, 1.5, 0.4),
	})
	for key, value in props or {} do
		frame[key] = value
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

-- A centered modal window. Returns window, body.
function UIKit.window(parent, title, onClose)
	local window = UIKit.panel({
		Name = title,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.49),
		Size = UDim2.fromScale(0.94, 0.78),
		BackgroundColor3 = T.PanelDark,
		Visible = false,
		Parent = parent,
	})
	make("UISizeConstraint", { MaxSize = Vector2.new(940, 640), Parent = window })
	local header = make("Frame", {
		Name = "Header",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 52),
		Parent = window,
	}, { UIKit.padding(16, 8) })
	UIKit.heading(title, 28, { Size = UDim2.new(1, -60, 1, 0), Parent = header })
	UIKit.button("X", "ghost", onClose, {
		Name = "Close",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(38, 38),
		Parent = header,
	})
	local body = make("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 52),
		Size = UDim2.new(1, 0, 1, -52),
		Parent = window,
	}, { UIKit.padding(16, 10) })
	return window, body
end

-- Horizontal tab strip. tabs = { {id, label} }. Returns frame, select(id).
function UIKit.tabs(tabs, onSelect)
	local frame = make("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 38),
	}, { UIKit.list(Enum.FillDirection.Horizontal, 8) })
	local buttons = {}
	local function selectTab(id)
		for tabId, button in buttons do
			UIKit.styleButton(button, tabId == id and "primary" or "ghost")
		end
		onSelect(id)
	end
	for i, tab in tabs do
		buttons[tab.id] = UIKit.button(tab.label, "ghost", function()
			selectTab(tab.id)
		end, { LayoutOrder = i, Size = UDim2.fromOffset(math.max(96, #tab.label * 11 + 24), 36), Parent = frame })
	end
	return frame, selectTab, buttons
end

local function settingRow(text, height)
	local row = make("Frame", {
		BackgroundColor3 = T.Panel,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, height or 46),
	}, {
		UIKit.corner(10),
		UIKit.padding(12, 4),
	})
	UIKit.label(text, 16, {
		Name = "Title",
		Size = UDim2.new(0.5, 0, 1, 0),
		Font = T.BoldFont,
		Parent = row,
	})
	return row
end

-- On/off switch row. Returns row, set(value).
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
		switch.BackgroundColor3 = current and T.Good or T.PanelLight
		knob.Position = current and UDim2.new(1, -27, 0.5, 0) or UDim2.new(0, 3, 0.5, 0)
	end
	switch.Activated:Connect(function()
		current = not current
		render()
		onChange(current)
	end)
	render()
	return row, function(v)
		current = v == true
		render()
	end
end

-- ◀ value ▶ picker over a list of { value, label }. Returns row, set(value).
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
	local valueLabel = UIKit.label("", 16, {
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
	UIKit.button("<", "ghost", function()
		shift(-1)
	end, { Size = UDim2.fromOffset(34, 34), Parent = holder })
	UIKit.button(">", "ghost", function()
		shift(1)
	end, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(34, 34),
		Parent = holder,
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

function UIKit.textbox(placeholder, props)
	local box = make("TextBox", {
		BackgroundColor3 = T.PanelLight,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		PlaceholderText = placeholder or "",
		PlaceholderColor3 = T.Muted,
		Text = "",
		TextColor3 = T.Text,
		Font = T.BodyFont,
		TextSize = 16,
		Size = UDim2.new(1, 0, 0, 38),
		TextXAlignment = Enum.TextXAlignment.Left,
	}, {
		UIKit.corner(10),
		UIKit.padding(10, 0),
		UIKit.stroke(nil, 1.2, 0.5),
	})
	for key, value in props or {} do
		box[key] = value
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
	end, { TextSize = 15, Size = UDim2.fromOffset(120, 32) })
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
	end, { TextSize = 15, Size = UDim2.fromOffset(150, 32) })
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

-- Menus builders ------------------------------------------------------------
--[[
    STUB (owner: C1): the menus' builders (menus design 3.8), as thin
    fallbacks over the builders above so callers type-check and run before
    C1 lands: slantButton is a plain button, cutPanel a panel, tabBar wraps
    tabs, assetId is real, the rest are plain frames and no-op setters.
    Common opts for every builder: parent, position, size, anchor, zIndex,
    layoutOrder, name (Scale preferred). Replace the bodies, keep the
    signatures.
]]

local function applyCommon(obj, opts)
	if not opts then
		return obj
	end
	if opts.position then
		obj.Position = opts.position
	end
	if opts.size then
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

local function plainFrame(name, opts)
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Size = UDim2.fromScale(1, 1)
	return applyCommon(frame, opts)
end

local function textInside(frame, text, size)
	UIKit.label(text, size or 16, {
		Name = "Text",
		Size = UDim2.fromScale(1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = frame,
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

-- opts = { slant?, fill?, gradient?, outline?, shadow?, transparency? } & Common. Children go in root.Content.
function UIKit.slantFrame(opts)
	opts = opts or {}
	local root = plainFrame("SlantFrame", opts)
	root.BackgroundTransparency = opts.transparency or 0
	root.BackgroundColor3 = opts.fill or (opts.gradient and opts.gradient[1]) or T.Panel
	plainFrame("Content", { parent = root })
	return root
end

function UIKit.setSlantFill(root, fill)
	root.BackgroundColor3 = if typeof(fill) == "Color3" then fill else fill[1]
end

-- opts = { style?, icon?, textSize?, badge?, sublabel?, glyph?, nudge?, slant? } & Common.
function UIKit.slantButton(text, opts, onClick)
	local button = UIKit.button(text, "primary", onClick)
	applyCommon(button, opts)
	return button
end

function UIKit.setBadge(_button, _text) end

-- opts = { cut?, fill?, border?, title?, titleSize? } & Common. Returns panel, body.
function UIKit.cutPanel(opts)
	opts = opts or {}
	local panel = UIKit.panel({ BackgroundColor3 = opts.fill or T.Panel })
	applyCommon(panel, opts)
	local body = plainFrame("Body", { parent = panel })
	return panel, body
end

-- opts = { size?, accent? } & Common.
function UIKit.header(text, opts)
	local frame = plainFrame("Header", opts)
	textInside(frame, text, opts and opts.size)
	return frame
end

-- opts = { fill?, textColor?, size? } & Common.
function UIKit.tag(text, opts)
	local frame = plainFrame("Tag", opts)
	textInside(frame, text, opts and opts.size)
	return frame
end

-- opts = { size? } & Common.
function UIKit.glyph(_action, opts)
	return plainFrame("Glyph", opts)
end

-- items = { { action, label, onClick? } }; opts = { anchor?, position? }. Returns bar, setItems(items).
function UIKit.hintBar(parent, _items, opts)
	local bar = plainFrame("Hints", opts)
	bar.Parent = parent
	return bar, function(_newItems) end
end

-- tabs = { { id, label } }; opts = { style?, onSelect } & Common. Returns frame, select(id), current(), cycle(delta).
function UIKit.tabBar(tabs, opts)
	opts = opts or {}
	local currentId = tabs[1] and tabs[1].id
	local frame, selectTab = UIKit.tabs(tabs, function(id)
		currentId = id
		if opts.onSelect then
			opts.onSelect(id)
		end
	end)
	applyCommon(frame, opts)
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
			selectTab(nextTab.id)
		end
	end
	return frame, selectTab, current, cycle
end

-- opts = { slant?, accent?, onClick? } & Common. Returns card, body.
function UIKit.card(opts)
	opts = opts or {}
	local card = Instance.new("TextButton")
	card.Name = "Card"
	card.Text = ""
	card.AutoButtonColor = false
	card.BorderSizePixel = 0
	card.BackgroundColor3 = T.Panel
	card.Size = UDim2.fromScale(1, 1)
	applyCommon(card, opts)
	local body = plainFrame("Body", { parent = card })
	if opts.onClick then
		UIKit.onActivate(card, function()
			opts.onClick()
		end)
	end
	return card, body
end

-- opts = { fill?, back? } & Common. Returns bar, set(fraction, fill?).
function UIKit.progressBar(opts)
	opts = opts or {}
	local bar = plainFrame("ProgressBar", opts)
	bar.BackgroundTransparency = 0
	bar.BackgroundColor3 = opts.back or T.PanelDark
	local fillFrame = plainFrame("Fill", { parent = bar })
	fillFrame.BackgroundTransparency = 0
	fillFrame.BackgroundColor3 = opts.fill or T.Gold
	local function set(fraction, fill)
		fillFrame.Size = UDim2.fromScale(math.clamp(fraction, 0, 1), 1)
		if fill then
			fillFrame.BackgroundColor3 = fill
		end
	end
	set(0)
	return bar, set
end

-- opts = { fill? } & Common. Returns frame, set(filled).
function UIKit.pips(_total, _filled, opts)
	return plainFrame("Pips", opts), function(_newFilled) end
end

-- opts = { fill?, textSize? } & Common. Returns frame, set(fraction, text).
function UIKit.ring(opts)
	local frame = plainFrame("Ring", opts)
	textInside(frame, "", opts and opts.textSize)
	local label = frame:FindFirstChild("Text")
	return frame, function(_fraction, text)
		if label then
			label.Text = text
		end
	end
end

-- opts = { size? } & Common.
function UIKit.tierBadge(tierName, opts)
	local frame = plainFrame("TierBadge", opts)
	textInside(frame, tierName, opts and opts.size)
	return frame
end

-- opts = { title, body, confirm, cancel?, onConfirm, onCancel? }. Returns close().
function UIKit.dialog(_opts)
	return function() end
end

-- Runs fn(button) on activation, ignoring presses while a previous fn is still running.
function UIKit.onActivate(button, fn)
	local running = false
	button.Activated:Connect(function()
		if running or button:GetAttribute("Disabled") then
			return
		end
		running = true
		local ok, err = pcall(fn, button)
		running = false
		if not ok then
			warn("[UIKit] activate handler failed:", err)
		end
	end)
end

return UIKit
