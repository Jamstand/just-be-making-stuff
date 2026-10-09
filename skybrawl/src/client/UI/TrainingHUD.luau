--[[
    The training room's screen (menus design 5.11, mockup f), built by
    TrainingClient for one training match: SkybrawlTraining (DisplayOrder
    15, safe area).

      top centre   chips: TRAINING ROOM, SLOW-MO 0.5x (below 1x), HITBOXES ON
      left         the panel (a cut panel; its body scrolls when it doesn't
                   fit): YOU (legend, weapon), DUMMY (legend, behaviour,
                   bot level), DUMMY DAMAGE (stepper, RESET, keep after KO),
                   DISPLAY (hitboxes, frame data, combo readout; speed),
                   WEAPON SPAWNER, then RESET POSITIONS and LEAVE TRAINING
      right        readouts: COMBO, FRAME DATA (a cell per frame), DUMMY
      bottom       hints (tappable): CHANGE, PANEL / HIDE PANEL, RESET
                   POSITIONS, SPAWN WEAPON; a hotkey that clashes with one
                   of your fight keybinds has no hint

    The panel starts shown, so you can fight at once with it in view, except
    on touch screens, where it would cover the thumbstick: there it starts
    hidden behind a PANEL button where its top-left corner goes. Phone: a
    row of buttons top-left (PANEL, RESET, SPAWN: the hints' actions, as
    phones have no hint bar), the panel below that row (laid out from where
    clearTop put the row, so the two never overlap), every row of controls
    at least 44 px tall, and the readouts as two chips top-right (combo,
    dummy).

    Every control is registered with Focus and works with clicks and taps
    too. Up / Down / Left / Right follow explicit links (FrameData.panelLinks)
    so a short row is never skipped; the cycle rows and the damage stepper
    use Left / Right for their value. A focused control turns red (gold
    stays gold) with a white ring inside its black outline and a red glow
    (menus design 5.3). The HUD never sends anything itself and never
    touches fight input: controls call ctx.request / ctx callbacks,
    TrainingClient owns the panel's Focus layer (Focus turns fight input off
    while it is open). The panel and readout roots are Active, so a click on
    them never reaches the fighter Input as an attack.

    Frame data: STARTUP is the frame the hitbox first comes out on (so it
    counts that frame; FrameData), which the strip shows as the first red
    cell after the green ones, and the line under the move name says so
    ("HITS ON FRAME 7").
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Legends = require(Shared.Legends)
local Weapons = require(Shared.Weapons)
local FrameData = require(Shared.FrameData)

local UIKit = require(script.Parent.UIKit)
local Focus = require(script.Parent.Focus)
local Layout = require(script.Parent.Layout)
local Shapes = require(script.Parent.Shapes)

local TrainingHUD = {}
TrainingHUD.__index = TrainingHUD

local T = UIKit.Theme
local make = UIKit.make
local WHITE = Color3.new(1, 1, 1)
local DARK = { T.ButtonTop, T.ButtonBottom }
local RED = { T.RedLight, T.RedDark }
local GOLD = { T.GoldLight, T.GoldDeep }

local OUTLINE, RING, GLOW = 2, 3, 6 -- design px: a control's black outline, the focused white ring, the red glow
local GLOW_TRANSPARENCY = 0.6
local TOUCH_MIN = 44 -- px: the smallest touch target (phone rows of controls)
local MODE_LABELS = FrameData.MODE_LABELS
local PHASE_COLORS = { Startup = T.Startup, Active = T.Active, Recovery = T.Recovery }

-- Wide layout (fractions of the safe area, mockup f).
local WIDE = {
	panel = { 0.015, 0.078, 0.224, 0.874 },
	button = { 0.015, 0.078, 0.08, 0.05 }, -- PANEL, while the panel is hidden
	combo = { 0.761, 0.078, 0.224, 0.278 },
	frames = { 0.761, 0.372, 0.224, 0.324 },
	dummy = { 0.761, 0.713, 0.224, 0.167 },
}
-- Phone: the button row top-left, the panel under it (to panelBottom), the readouts as two chips top-right.
local PHONE = {
	bar = { 0.01, 0.02, 0.5, 0.12 },
	panelX = 0.01,
	panelW = 0.47,
	panelBottom = 0.98,
	chips = { 0.69, 0.02, 0.3, 0.1 },
}

local function rect(r)
	return UDim2.fromScale(r[1], r[2]), UDim2.fromScale(r[3], r[4])
end

local function legendLabel(id)
	return string.upper(Legends.get(id).Name)
end

local function weaponLabel(id)
	return if id == "Unarmed" then "UNARMED" else string.upper(Weapons.get(id).Name)
end

local function speedLabel(scale)
	return (if scale == math.floor(scale) then string.format("%d", scale) else tostring(scale)) .. "x"
end

local function hex(color)
	local function byte(v)
		return math.clamp(math.floor(v * 255 + 0.5), 0, 255)
	end
	return string.format("#%02X%02X%02X", byte(color.R), byte(color.G), byte(color.B))
end

-- "LABEL <value>" with the value in white (RichText).
local function pair(label, value)
	return string.format('%s  <font color="%s">%s</font>', label, hex(T.Text), tostring(value))
end

local function text(parent, props, size)
	local label = make("TextLabel", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Font = T.BlackFont,
		TextColor3 = T.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 3,
	})
	for key, value in props do
		label[key] = value
	end
	label.Parent = parent
	Layout.bindText(label, size)
	return label
end

-- Icons for the weapon spawner, drawn from frames (no uploads).
local function weaponIcon(weaponId, parent, color)
	local holder = make("Frame", {
		Name = "Icon",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.7, 0.7),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		ZIndex = 3,
		Parent = parent,
	})
	local parts = {}
	local function bar(x, y, w, h, rotation, round)
		local frame = make("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(x, y),
			Size = UDim2.fromScale(w, h),
			Rotation = rotation or 0,
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			ZIndex = 4,
			Parent = holder,
		})
		if round then
			make("UICorner", { CornerRadius = UDim.new(round, 0), Parent = frame })
		end
		table.insert(parts, frame)
		return frame
	end
	if weaponId == "Sword" then
		bar(0.56, 0.44, 0.1, 0.78, 45)
		bar(0.3, 0.7, 0.1, 0.34, -45)
	elseif weaponId == "Hammer" then
		bar(0.44, 0.56, 0.08, 0.78, 45)
		bar(0.68, 0.32, 0.22, 0.44, -45, 0.1)
	elseif weaponId == "Spear" then
		bar(0.48, 0.52, 0.07, 0.92, 45)
		bar(0.8, 0.2, 0.18, 0.18, 45)
	elseif weaponId == "Gauntlets" then
		bar(0.5, 0.42, 0.56, 0.46, 0, 0.25)
		bar(0.5, 0.76, 0.4, 0.16, 0, 0.1)
	elseif weaponId == "Scythe" then
		bar(0.46, 0.56, 0.07, 0.86, 18)
		bar(0.64, 0.2, 0.5, 0.1, -18, 0.5)
		bar(0.84, 0.3, 0.1, 0.22, 30, 0.5)
	elseif weaponId == "Bow" then
		local clip = make("Frame", {
			BackgroundTransparency = 1,
			ClipsDescendants = true,
			Size = UDim2.fromScale(0.5, 1),
			ZIndex = 4,
			Parent = holder,
		})
		local arc = make("Frame", {
			BackgroundTransparency = 1,
			Position = UDim2.fromScale(0.2, 0),
			Size = UDim2.fromScale(1.6, 1),
			ZIndex = 4,
			Parent = clip,
		})
		make("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = arc })
		local stroke = make("UIStroke", { Color = color, Parent = arc })
		Layout.bindStroke(stroke, 3)
		bar(0.5, 0.5, 0.05, 0.82)
		bar(0.56, 0.5, 0.66, 0.06)
		table.insert(parts, stroke)
	end
	return function(newColor)
		for _, part in parts do
			if part:IsA("UIStroke") then
				part.Color = newColor
			else
				part.BackgroundColor3 = newColor
			end
		end
	end
end

-- Building ---------------------------------------------------------------------------------

--[[
    ctx = {
      settings      { legend, weapon, dummyLegend, dummyMode, difficulty, keepDamage, speed }
      display       { Hitboxes, FrameData, Combo } (TrainingClient's, kept for the session)
      spawnWeapon   the weapon the spawner drops
      hotkeys       FrameData.hotkeys(...) (free hotkeys per device)
      request(action, payload)     a TrainingRequest
      onDisplay(name, on)          a DISPLAY toggle
      onSpawn(weaponId)            a spawner button (selects and drops it)
      onTogglePanel()              the PANEL button and the PANEL hint
      onReset(), onLeave()
    }
]]
function TrainingHUD.new(ctx)
	local self = setmetatable({}, TrainingHUD)
	self.ctx = ctx
	self.settings = table.clone(ctx.settings)
	self.connections = {}
	self.rows = {} -- [row] = { height (design px), touch (a row of controls: at least TOUCH_MIN on phones) }
	self.pxFns = {} -- re-run on every layout change
	self.focusables = {} -- everything registered with Focus (unregistered by destroy)
	-- a touch screen starts with the panel hidden: it would sit over the thumbstick
	self.shown = Layout.mode() ~= "Phone" and Focus.mode() ~= "Touch"
	self.open = false
	self.damage = 0

	local gui = Layout.screenGui("SkybrawlTraining", 15, "Safe")
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	self.gui = gui

	self:buildChips()
	self:buildPanel()
	self:buildReadouts()
	self:buildBar()
	self:buildPhoneChips()
	self:buildHints()

	table.insert(
		self.connections,
		Focus.ModeChanged:Connect(function()
			self:renderHints()
		end)
	)
	self:setSettings(self.settings)
	self:setDisplay(ctx.display)
	self:setCombo(nil)
	self:setFrameData(nil)
	self:setDummy(nil, 0)
	-- now and whenever the safe area changes (after Layout has measured it, so px() is current)
	Layout.bindApply(gui, function()
		self:relayout()
	end)
	return self
end

-- Runs fn now and again whenever the layout (px scale) changes.
function TrainingHUD:bindPx(fn)
	table.insert(self.pxFns, fn)
	fn()
end

-- A panel row's height in px now.
local function rowHeight(entry)
	local px = Layout.px(entry.height)
	if entry.touch and Layout.mode() == "Phone" then
		return math.max(px, TOUCH_MIN)
	end
	return px
end

function TrainingHUD:relayout()
	local phone = Layout.mode() == "Phone"
	for row, entry in self.rows do
		if row.Parent then
			row.Size = UDim2.new(1, 0, 0, rowHeight(entry))
		end
	end
	for _, fn in self.pxFns do
		fn()
	end
	-- the button row: PANEL alone on Wide (while the panel is hidden), PANEL / RESET / SPAWN on phones
	local position, size = rect(if phone then PHONE.bar else WIDE.button)
	self.bar.Size = size
	Layout.clearTop(self.bar, position)
	for i, button in { self.panelButton, self.resetButton, self.spawnButton } do
		button.Visible = phone or i == 1
		button.Position = UDim2.fromScale(if phone then (i - 1) * 0.34 else 0, 0)
		button.Size = UDim2.fromScale(if phone then 0.32 else 1, 1)
	end
	if phone then
		self:placePhonePanel()
	else
		position, size = rect(WIDE.panel)
		self.panel.Size = size
		Layout.clearTop(self.panel, position)
	end
	for name, readout in self.readouts do
		position, size = rect(WIDE[name])
		readout.Position = position
		readout.Size = size
	end
	position, size = rect(PHONE.chips)
	self.phoneChips.Size = size
	Layout.clearTop(self.phoneChips, position)
	self:setDisplay(self.ctx.display)
	self:setPanel(self.shown, self.open)
end

-- Phone: the panel starts just below the button row (wherever clearTop put it) and runs to panelBottom.
function TrainingHUD:placePhonePanel()
	if Layout.mode() ~= "Phone" or not self.panel then
		return
	end
	local gui, bar = self.gui, self.bar
	local top = bar.AbsolutePosition.Y + bar.AbsoluteSize.Y - gui.AbsolutePosition.Y + Layout.px(6)
	local bottom = gui.AbsoluteSize.Y * PHONE.panelBottom
	self.panel.Size = UDim2.new(PHONE.panelW, 0, 0, math.max(0, math.floor(bottom - top)))
	-- (below the button row it is clear of the top bar already; clearTop keeps it so if the bar changes)
	Layout.clearTop(self.panel, UDim2.new(PHONE.panelX, 0, 0, math.ceil(top)))
end

-- A row in the panel's list, `height` design px tall; `touch`: a row of controls (at least TOUCH_MIN on phones).
function TrainingHUD:row(className, name, height, touch)
	self.order += 1
	local entry = { height = height, touch = touch == true }
	local row = make(className, {
		Name = name,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		LayoutOrder = self.order,
		Size = UDim2.new(1, 0, 0, rowHeight(entry)),
		ZIndex = 2,
		Parent = self.list,
	})
	if className == "TextButton" then
		row.AutoButtonColor = false
		row.Text = ""
	end
	self.rows[row] = entry
	return row
end

-- Registers a control with Focus (and remembers it, so destroy can let go of it).
function TrainingHUD:register(obj, spec)
	Focus.register(obj, spec)
	table.insert(self.focusables, obj)
end

--[[
    The slanted face of a control filling `holder` (menus design 5.3): a
    2 px black outline; focused, a copy (built the first time it is needed)
    with a white ring inside the outline and a red glow behind it. Returns
    content (a frame for the label or icon; it moves to whichever face is
    showing) and paint(fill, focused).
]]
function TrainingHUD:face(holder, fill)
	local plain = UIKit.slantFrame({ parent = holder, name = "Face", fill = fill, outline = OUTLINE, zIndex = 2 })
	local content = make("Frame", {
		Name = "Inner",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 1,
		Parent = plain:FindFirstChild("Content"),
	})
	local focusFace, glow = nil, nil
	local function build()
		glow = UIKit.slantFrame({
			parent = holder,
			name = "Glow",
			fill = T.Red,
			transparency = GLOW_TRANSPARENCY,
			zIndex = 1,
		})
		focusFace = UIKit.slantFrame({
			parent = holder,
			name = "Focused",
			fill = fill,
			outline = OUTLINE,
			ring = RING,
			zIndex = 2,
		})
		-- the glow: the same shape grown GLOW px past the focused outline (Shapes.outset keeps it even all round)
		local function placeGlow()
			local size = holder.AbsoluteSize
			local box = Shapes.outset(size.X, size.Y, T.Slant, Layout.px(RING + OUTLINE + GLOW))
			glow.Position = UDim2.fromOffset(box.x, box.y)
			glow.Size = UDim2.fromOffset(box.w, box.h)
		end
		table.insert(self.connections, holder:GetPropertyChangedSignal("AbsoluteSize"):Connect(placeGlow))
		self:bindPx(placeGlow)
	end
	return content,
		function(newFill, focused)
			local show = focused and Focus.mode() ~= "Touch"
			if show and not focusFace then
				build()
			end
			if focusFace then
				focusFace.Visible = show
				glow.Visible = show
			end
			plain.Visible = not show
			local face = if show then focusFace else plain
			UIKit.setSlantFill(face, newFill)
			content.Parent = face:FindFirstChild("Content")
		end
end

-- A slanted chip button: dark, gold when selected, red with a white ring when focused (gold stays gold).
-- opts = { text?, textSize?, icon? (weapon id), tone? ("danger"), position, size, parent }.
function TrainingHUD:chip(opts, onClick)
	local button = make("TextButton", {
		Name = opts.name or opts.text or "Chip",
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Text = "",
		Position = opts.position or UDim2.new(),
		Size = opts.size or UDim2.fromScale(1, 1),
		ZIndex = 2,
		Parent = opts.parent,
	})
	local content, paint = self:face(button, DARK)
	local label, paintIcon
	if opts.icon then
		paintIcon = weaponIcon(opts.icon, content, T.Text)
	else
		label = text(content, {
			Text = opts.text or "",
			Font = T.HeadFont,
			TextXAlignment = Enum.TextXAlignment.Center,
		}, opts.textSize or 26)
	end
	local state = { selected = false, focused = false }
	local function render()
		local fill, ink = DARK, T.Text
		if state.selected then
			fill, ink = GOLD, T.GoldDark
		elseif state.focused then
			fill = RED
		elseif opts.tone == "danger" then
			ink = T.RedLight
		end
		paint(fill, state.focused)
		if label then
			label.TextColor3 = ink
		end
		if paintIcon then
			paintIcon(ink)
		end
	end
	UIKit.onActivate(button, onClick)
	self:register(button, {
		key = "Training:" .. button.Name,
		onFocus = function(on)
			state.focused = on
			render()
		end,
	})
	render()
	return button,
		{
			setSelected = function(on)
				state.selected = on == true
				render()
			end,
			setText = function(value)
				if label then
					label.Text = value
				end
			end,
		}
end

--[[
    "LABEL  ◀ VALUE ▶": Left / Right (and the arrows) step it, Confirm steps
    right. opts = { label, onStep(delta), key? (Focus key, default label),
    parent? (a frame to fill instead of a list row), caption? (false: no
    label), valueColor? (the value's colour when not focused) }. Returns
    row, setText(text, dim?).
]]
function TrainingHUD:cycleRow(opts)
	local row
	if opts.parent then
		row = make("TextButton", {
			Name = opts.label,
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			Text = "",
			Size = UDim2.fromScale(1, 1),
			ZIndex = 2,
			Parent = opts.parent,
		})
	else
		row = self:row("TextButton", opts.label, 46, true)
	end
	local captioned = opts.caption ~= false
	if captioned then
		text(row, {
			Text = string.upper(opts.label),
			TextColor3 = T.Muted,
			Size = UDim2.fromScale(0.3, 1),
		}, 15)
	end
	local holder = make("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(if captioned then 0.3 else 0, 0.08),
		Size = UDim2.fromScale(if captioned then 0.7 else 1, 0.84),
		ZIndex = 2,
		Parent = row,
	})
	local content, paint = self:face(holder, DARK)
	local value = text(content, {
		Text = "",
		Font = T.HeadFont,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromScale(0.2, 0),
		Size = UDim2.fromScale(0.6, 1),
	}, 30)
	local function step(delta)
		opts.onStep(delta)
	end
	for i, glyph in { "◀", "▶" } do
		-- (a fifth of the face each: a thumb-sized target on phones)
		local arrow = make("TextButton", {
			Name = if i == 1 then "Left" else "Right",
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			Text = glyph,
			Font = T.BlackFont,
			TextColor3 = T.Muted,
			AnchorPoint = Vector2.new(if i == 1 then 0 else 1, 0),
			Position = UDim2.fromScale(if i == 1 then 0 else 1, 0),
			Size = UDim2.fromScale(0.2, 1),
			ZIndex = 4,
			Parent = content,
		})
		Layout.bindText(arrow, 16)
		arrow.Activated:Connect(function()
			step(if i == 1 then -1 else 1)
		end)
	end
	local dimmed = false
	local focused = false
	local function render()
		paint(if focused then RED else DARK, focused)
		if focused then
			value.TextColor3 = T.Text
		elseif dimmed then
			value.TextColor3 = T.Dim
		else
			value.TextColor3 = opts.valueColor or T.Text
		end
	end
	UIKit.onActivate(row, function()
		step(1)
	end)
	self:register(row, {
		key = "Training:" .. (opts.key or opts.label),
		onFocus = function(on)
			focused = on
			render()
		end,
		onLeft = function()
			step(-1)
			return true
		end,
		onRight = function()
			step(1)
			return true
		end,
	})
	render()
	return row, function(valueText, dim)
		value.Text = valueText
		dimmed = dim == true
		render()
	end
end

-- "Label ......... [switch]"; Confirm or a click flips it. Returns row, set(on).
function TrainingHUD:toggleRow(label, onChange)
	local row = self:row("TextButton", label, 32, true)
	text(row, {
		Text = label,
		Font = T.BoldFont,
		Size = UDim2.fromScale(0.78, 1),
	}, 18)
	local holder = make("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromScale(0.16, 0.74),
		ZIndex = 2,
		Parent = row,
	})
	local content, paint = self:face(holder, T.Raised)
	local knob = make("Frame", {
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromScale(0.36, 0.6),
		ZIndex = 4,
		Parent = content,
	})
	local on, focused = false, false
	local function render()
		paint(if on then T.Good else T.Raised, focused)
		knob.Position = UDim2.fromScale(if on then 0.72 else 0.28, 0.5)
		knob.BackgroundColor3 = if on then WHITE else T.Dim
	end
	UIKit.onActivate(row, function()
		on = not on
		render()
		onChange(on)
	end)
	self:register(row, {
		key = "Training:" .. label,
		onFocus = function(value)
			focused = value
			render()
		end,
	})
	render()
	return row, function(value)
		on = value == true
		render()
	end
end

function TrainingHUD:section(title)
	local row = self:row("Frame", title, 40)
	UIKit.header(title, { parent = row, size = 32 })
	return row
end

function TrainingHUD:buildPanel()
	local ctx = self.ctx
	local panel, body = UIKit.cutPanel({ parent = self.gui, name = "Panel", zIndex = 2 })
	panel.Active = true -- clicks on the panel never reach the fighter Input
	self.panel = panel
	local scroll = make("ScrollingFrame", {
		Name = "Scroll",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarImageColor3 = T.Stroke,
		ZIndex = 2,
		Parent = body,
	})
	local padding = make("UIPadding", { Parent = scroll })
	Layout.bindPadding(padding, 18, 12)
	local list = make("UIListLayout", {
		FillDirection = Enum.FillDirection.Vertical,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = scroll,
	})
	self:bindPx(function()
		list.Padding = UDim.new(0, Layout.px(5))
		scroll.ScrollBarThickness = math.max(2, Layout.px(4))
	end)
	self.list = scroll
	self.order = 0
	self.controls = {}
	local c = self.controls
	-- the controls row by row with their horizontal extent, for the explicit Focus links (FrameData.panelLinks)
	local nav = {}
	local function whole(control)
		table.insert(nav, { { id = control, x = 0, w = 1 } })
	end

	-- YOU
	self:section("YOU")
	local legends = Legends.Order
	c.legendRow, c.setLegend = self:cycleRow({
		label = "Legend",
		onStep = function(delta)
			local index = table.find(legends, self.settings.legend) or 1
			local id = legends[(index - 1 + delta) % #legends + 1]
			self.settings.legend = id
			self.settings.weapon = "Unarmed"
			self:renderSettings()
			ctx.request("SetLegend", { legend = id })
		end,
	})
	whole(c.legendRow)
	c.weaponRow, c.setWeapon = self:cycleRow({
		label = "Weapon",
		onStep = function(delta)
			local options = FrameData.weaponOptions(self.settings.legend)
			local index = table.find(options, self.settings.weapon) or 1
			local id = options[(index - 1 + delta) % #options + 1]
			self.settings.weapon = id
			self:renderSettings()
			ctx.request("SetWeapon", { weapon = id })
		end,
	})
	whole(c.weaponRow)

	-- DUMMY
	self:section("DUMMY")
	local roster = {}
	for _, id in Legends.Order do
		if id ~= "Avatar" then
			table.insert(roster, id)
		end
	end
	c.dummyRow, c.setDummyLegend = self:cycleRow({
		label = "Legend",
		key = "DummyLegend",
		onStep = function(delta)
			local index = table.find(roster, self.settings.dummyLegend) or 1
			local id = roster[(index - 1 + delta) % #roster + 1]
			self.settings.dummyLegend = id
			self:renderSettings()
			ctx.request("SetDummyLegend", { legend = id })
		end,
	})
	whole(c.dummyRow)
	c.modes = {}
	local function setMode(mode)
		self.settings.dummyMode = mode
		self:renderSettings()
		ctx.request("SetDummyMode", { mode = mode, difficulty = self.settings.difficulty })
	end
	local modeRows = { { "Stand", "Jump", "Dodge" }, { "Block", "Fight" } }
	for r, modes in modeRows do
		local row = self:row("Frame", "Modes" .. r, 44, true)
		local navRow = {}
		local x = 0
		for _, mode in modes do
			local width = if mode == "Fight" then 0.64 else 0.32
			local button, api = self:chip({
				parent = row,
				name = "Mode" .. mode,
				text = MODE_LABELS[mode],
				position = UDim2.fromScale(x, 0.06),
				size = UDim2.fromScale(width, 0.88),
			}, function()
				setMode(mode)
			end)
			c.modes[mode] = api
			table.insert(navRow, { id = button, x = x, w = width })
			x += width + 0.02
		end
		table.insert(nav, navRow)
	end
	local levels = Config.Bots.DifficultyOrder
	c.levelRow, c.setLevel = self:cycleRow({
		label = "Bot level",
		onStep = function(delta)
			local index = table.find(levels, self.settings.difficulty) or 1
			local level = levels[math.clamp(index + delta, 1, #levels)]
			if level == self.settings.difficulty then
				return
			end
			self.settings.difficulty = level
			self:renderSettings()
			ctx.request("SetDummyMode", { mode = self.settings.dummyMode, difficulty = level })
		end,
	})
	whole(c.levelRow)

	-- DUMMY DAMAGE
	self:section("DUMMY DAMAGE")
	local damageRow = self:row("Frame", "Damage", 46, true)
	local stepBox = make("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(0.66, 1),
		ZIndex = 2,
		Parent = damageRow,
	})
	local stepper, setDamageText = self:cycleRow({
		label = "Damage",
		parent = stepBox,
		caption = false,
		valueColor = T.DamageHot,
		onStep = function(delta)
			local step = Config.Training.DamageStep
			local current = self.damage
			local value = if delta > 0
				then math.floor(current / step) * step + step
				else math.ceil(current / step) * step - step
			value = math.clamp(value, 0, Config.Combat.MaxDamage)
			self:showDamage(value)
			ctx.request("SetDamage", { value = value })
		end,
	})
	self.setDamageText = setDamageText
	local resetDamage = self:chip({
		parent = damageRow,
		name = "ResetDamage",
		text = "RESET",
		position = UDim2.fromScale(0.68, 0.08),
		size = UDim2.fromScale(0.32, 0.84),
	}, function()
		self:showDamage(0)
		ctx.request("SetDamage", { value = 0 })
	end)
	-- the stepper's Left / Right step its value, so RESET is the next stop down rather than to its right
	table.insert(nav, { { id = stepper, x = 0, w = 0.66 } })
	table.insert(nav, { { id = resetDamage, x = 0.68, w = 0.32 } })
	c.keepRow, c.setKeep = self:toggleRow("Keep damage after KO", function(on)
		self.settings.keepDamage = on
		ctx.request("KeepDamage", { on = on })
	end)
	whole(c.keepRow)

	-- DISPLAY
	self:section("DISPLAY")
	c.display = {}
	for _, entry in { { "Hitboxes", "Hitboxes" }, { "FrameData", "Frame data" }, { "Combo", "Combo readout" } } do
		local row, set = self:toggleRow(entry[2], function(on)
			ctx.onDisplay(entry[1], on)
		end)
		c.display[entry[1]] = set
		whole(row)
	end
	local speedRow = self:row("Frame", "Speed", 44, true)
	text(speedRow, { Text = "SPEED", TextColor3 = T.Muted, Size = UDim2.fromScale(0.28, 1) }, 15)
	c.speeds = {}
	local speeds = Config.Training.Speeds
	local speedNav = {}
	for i, scale in speeds do
		local width = 0.7 / #speeds
		local x = 0.3 + (i - 1) * (width + 0.003)
		local button, api = self:chip({
			parent = speedRow,
			name = "Speed" .. i,
			text = speedLabel(scale),
			position = UDim2.fromScale(x, 0.06),
			size = UDim2.fromScale(width - 0.01, 0.88),
		}, function()
			self.settings.speed = scale
			self:renderSettings()
			ctx.request("SetSpeed", { scale = scale })
		end)
		c.speeds[scale] = api
		table.insert(speedNav, { id = button, x = x, w = width - 0.01 })
	end
	table.insert(nav, speedNav)

	-- WEAPON SPAWNER
	self:section("WEAPON SPAWNER")
	local weaponsRow = self:row("Frame", "Weapons", 50, true)
	c.spawn = {}
	local spawnNav = {}
	for i, weaponId in Weapons.Order do
		local width = 1 / #Weapons.Order
		local button, api = self:chip({
			parent = weaponsRow,
			name = "Spawn" .. weaponId,
			icon = weaponId,
			position = UDim2.fromScale((i - 1) * width, 0.04),
			size = UDim2.fromScale(width - 0.015, 0.92),
		}, function()
			ctx.onSpawn(weaponId)
		end)
		c.spawn[weaponId] = api
		table.insert(spawnNav, { id = button, x = (i - 1) * width, w = width - 0.015 })
	end
	table.insert(nav, spawnNav)
	local captionRow = self:row("Frame", "SpawnCaption", 24)
	self.spawnCaption = text(captionRow, { Text = "", Font = T.BoldFont, TextColor3 = T.Muted }, 15)

	-- RESET POSITIONS / LEAVE TRAINING
	local endRow = self:row("Frame", "End", 46, true)
	local resetPositions = self:chip({
		parent = endRow,
		name = "ResetPositions",
		text = "RESET POSITIONS",
		textSize = 22,
		position = UDim2.fromScale(0, 0.08),
		size = UDim2.fromScale(0.49, 0.84),
	}, function()
		ctx.onReset()
	end)
	local leave = self:chip({
		parent = endRow,
		name = "Leave",
		text = "LEAVE TRAINING",
		textSize = 22,
		tone = "danger",
		position = UDim2.fromScale(0.51, 0.08),
		size = UDim2.fromScale(0.49, 0.84),
	}, function()
		ctx.onLeave()
	end)
	table.insert(nav, { { id = resetPositions, x = 0, w = 0.49 }, { id = leave, x = 0.51, w = 0.49 } })
	self:setSpawnWeapon(ctx.spawnWeapon)

	for control, links in FrameData.panelLinks(nav) do
		for dir, target in links do
			Focus.link(control, dir, target)
		end
	end
	-- RESET's Left goes back to the stepper beside it (the stepper's own Left / Right step the value)
	Focus.link(resetDamage, "Left", stepper)
end

function TrainingHUD:buildChips()
	local holder = make("Frame", {
		Name = "Chips",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromScale(0.6, 0.037),
		ZIndex = 2,
		Parent = self.gui,
	})
	local list = make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = holder,
	})
	self:bindPx(function()
		list.Padding = UDim.new(0, Layout.px(10))
	end)
	Layout.clearTop(holder, UDim2.fromScale(0.5, 0.026))
	self.chipHolder = holder
	self.titleChip = UIKit.tag("TRAINING ROOM", {
		parent = holder,
		fill = T.Backdrop,
		size = 22,
		layoutOrder = 1,
	})
	self.hitboxChip = UIKit.tag("HITBOXES ON", { parent = holder, fill = T.Red, size = 22, layoutOrder = 3 })
	self.chipSpeed = nil
end

function TrainingHUD:buildReadouts()
	local gui = self.gui
	self.readouts = {}
	local function readout(name)
		local panel, body = UIKit.cutPanel({ parent = gui, name = name, zIndex = 2 })
		panel.Active = true
		self.readouts[name] = panel
		return body
	end
	local function header(parent, title, x, y, w, h)
		local holder = make("Frame", {
			BackgroundTransparency = 1,
			Position = UDim2.fromScale(x, y),
			Size = UDim2.fromScale(w, h),
			ZIndex = 3,
			Parent = parent,
		})
		UIKit.header(title, { parent = holder, size = 34 })
	end
	local r = {}
	self.r = r

	-- COMBO
	local body = readout("combo")
	header(body, "COMBO", 0.05, 0.05, 0.5, 0.15)
	r.hits = text(body, {
		Font = T.LogoFont,
		Text = "0",
		Position = UDim2.fromScale(0.05, 0.2),
		Size = UDim2.fromScale(0.3, 0.5),
	}, 160)
	r.hitsLabel = text(body, {
		Font = T.HeadFont,
		Text = "HITS",
		Position = UDim2.fromScale(0.32, 0.38),
		Size = UDim2.fromScale(0.3, 0.26),
	}, 60)
	text(body, {
		Text = "COMBO DMG",
		TextColor3 = T.Muted,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.fromScale(0.55, 0.08),
		Size = UDim2.fromScale(0.4, 0.09),
	}, 15)
	r.comboDamage = text(body, {
		Font = T.LogoFont,
		Text = "0",
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.fromScale(0.55, 0.16),
		Size = UDim2.fromScale(0.4, 0.24),
	}, 56)
	r.lastHit = text(body, {
		Text = "",
		RichText = true,
		TextColor3 = T.Muted,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.fromScale(0.45, 0.44),
		Size = UDim2.fromScale(0.5, 0.1),
	}, 16)
	local function comboTag(label, x, w)
		local tag = UIKit.slantFrame({
			parent = body,
			fill = T.Raised,
			outline = 2,
			position = UDim2.fromScale(x, 0.7),
			size = UDim2.fromScale(w, 0.18),
			zIndex = 3,
		})
		local tagText = text(tag:FindFirstChild("Content"), {
			Text = label,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextColor3 = T.Muted,
		}, 20)
		return tag, tagText
	end
	r.trueTag, r.trueText = comboTag("TRUE COMBO", 0.05, 0.46)
	r.stringTag, r.stringText = comboTag("STRING", 0.53, 0.3)

	-- FRAME DATA
	body = readout("frames")
	header(body, "FRAME DATA", 0.05, 0.03, 0.6, 0.12)
	text(body, {
		Text = "60 FPS",
		TextColor3 = T.Muted,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.fromScale(0.62, 0.05),
		Size = UDim2.fromScale(0.33, 0.08),
	}, 15)
	r.moveName = text(body, {
		Font = T.HeadFont,
		Text = "",
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromScale(0.05, 0.16),
		Size = UDim2.fromScale(0.62, 0.13),
	}, 44)
	r.note = text(body, {
		Text = "",
		TextColor3 = T.Gold,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.fromScale(0.6, 0.19),
		Size = UDim2.fromScale(0.35, 0.08),
	}, 14)
	r.subtitle = text(body, {
		Text = "",
		TextColor3 = T.Muted,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromScale(0.05, 0.29),
		Size = UDim2.fromScale(0.9, 0.07),
	}, 15)
	r.strip = make("Frame", {
		Name = "Strip",
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(0.05, 0.4),
		Size = UDim2.fromScale(0.9, 0.1),
		ZIndex = 3,
		Parent = body,
	})
	r.cells = {}
	r.cursor = make("Frame", {
		Name = "Cursor",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 0.5),
		Visible = false,
		ZIndex = 5,
		Parent = r.strip,
	})
	local cursorStroke = make("UIStroke", { Color = WHITE, Parent = r.cursor })
	Layout.bindStroke(cursorStroke, 2)
	r.boxes = {}
	local boxSpecs = {
		{ "startup", "STARTUP", T.Startup },
		{ "active", "ACTIVE", T.Active },
		{ "recovery", "RECOVERY", T.Recovery },
		{ "total", "TOTAL", T.Text },
	}
	for i, spec in boxSpecs do
		local box = make("Frame", {
			Name = spec[2],
			BackgroundColor3 = T.Raised,
			BorderSizePixel = 0,
			Position = UDim2.fromScale(0.05 + (i - 1) * 0.23, 0.55),
			Size = UDim2.fromScale(0.21, 0.24),
			ZIndex = 3,
			Parent = body,
		})
		r.boxes[spec[1]] = text(box, {
			Font = T.LogoFont,
			Text = "-",
			TextColor3 = spec[3],
			TextXAlignment = Enum.TextXAlignment.Center,
			Position = UDim2.fromScale(0, 0.06),
			Size = UDim2.fromScale(1, 0.6),
		}, 36)
		text(box, {
			Text = spec[2],
			TextColor3 = T.Muted,
			TextXAlignment = Enum.TextXAlignment.Center,
			Position = UDim2.fromScale(0, 0.66),
			Size = UDim2.fromScale(1, 0.28),
		}, 12)
	end
	r.stats = text(body, {
		Text = "",
		RichText = true,
		TextColor3 = T.Muted,
		Position = UDim2.fromScale(0.05, 0.84),
		Size = UDim2.fromScale(0.9, 0.1),
	}, 16)

	-- DUMMY
	body = readout("dummy")
	header(body, "DUMMY", 0.05, 0.06, 0.5, 0.24)
	r.dummyDamage = text(body, {
		Font = T.LogoFont,
		Text = "0%",
		TextColor3 = T.DamageHot,
		Position = UDim2.fromScale(0.05, 0.34),
		Size = UDim2.fromScale(0.44, 0.58),
	}, 90)
	r.dummyLines = {}
	for i = 1, 3 do
		r.dummyLines[i] = text(body, {
			Text = "",
			RichText = true,
			TextColor3 = T.Muted,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromScale(0.52, 0.3 + (i - 1) * 0.2),
			Size = UDim2.fromScale(0.46, 0.18),
		}, 16)
	end
end

--[[
    The button row top-left: PANEL (shows / hides the panel; on Wide only
    while the panel is hidden) and, on phones, RESET and SPAWN (what the
    hint bar does elsewhere). Active, above the panel.
]]
function TrainingHUD:buildBar()
	local bar = make("Frame", {
		Name = "Buttons",
		BackgroundTransparency = 1,
		ZIndex = 3,
		Parent = self.gui,
	})
	self.bar = bar
	local ctx = self.ctx
	local function button(name, label, onClick)
		local chip = self:chip({ parent = bar, name = name, text = label, textSize = 26 }, onClick)
		chip.Active = true
		return chip
	end
	self.panelButton = button("PanelButton", "PANEL", function()
		ctx.onTogglePanel()
	end)
	self.resetButton = button("ResetButton", "RESET", function()
		ctx.onReset()
	end)
	self.spawnButton = button("SpawnButton", "SPAWN", function()
		ctx.onSpawn(self.spawnWeapon)
	end)
	-- the phone panel hangs under the row: follow it when clearTop moves it
	for _, property in { "AbsolutePosition", "AbsoluteSize" } do
		table.insert(
			self.connections,
			bar:GetPropertyChangedSignal(property):Connect(function()
				self:placePhonePanel()
			end)
		)
	end
end

-- Phone: the two readout chips top-right (combo, dummy).
function TrainingHUD:buildPhoneChips()
	local holder = make("Frame", {
		Name = "PhoneChips",
		BackgroundTransparency = 1,
		ZIndex = 2,
		Parent = self.gui,
	})
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Vertical,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0.1, 0),
		Parent = holder,
	})
	self.phoneChips = holder
	local function chip(order)
		local frame = UIKit.slantFrame({
			parent = holder,
			fill = T.Panel,
			outline = 2,
			size = UDim2.fromScale(1, 1),
			layoutOrder = order,
			zIndex = 2,
		})
		local label = text(frame:FindFirstChild("Content"), {
			Text = "",
			RichText = true,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, 18)
		return frame, label
	end
	self.phoneCombo, self.phoneComboText = chip(1)
	self.phoneDummy, self.phoneDummyText = chip(2)
end

--[[
    A hotkey glyph (not a Focus action), styled like UIKit.glyph (menus
    design 5.3): a 34 px white circle with the key's letter (Bangers), or a
    pill with a longer key name (GothamBlack 14), or the gamepad button's
    image; hidden on Touch.
]]
local function keyGlyph(parent, keyboardKey, gamepadKey, order)
	local frame = make("Frame", {
		Name = "Glyph",
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
		LayoutOrder = order,
		ZIndex = 3,
		Parent = parent,
	})
	local corner = make("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = frame })
	local label = make("TextLabel", {
		BackgroundTransparency = 1,
		Font = T.HeadFont,
		TextColor3 = Color3.new(0, 0, 0),
		Size = UDim2.fromScale(1, 1),
		ZIndex = 4,
		Parent = frame,
	})
	local image = make("ImageLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = 4,
		Parent = frame,
	})
	local long = false
	local function resize()
		local side = Layout.px(34)
		local width = side
		if long then
			width = math.max(side, label.TextBounds.X + Layout.px(14))
		end
		frame.Size = UDim2.fromOffset(width, side)
	end
	local function render()
		local mode = Focus.mode()
		frame.Visible = mode ~= "Touch"
		local key = if mode == "Gamepad" then gamepadKey else keyboardKey
		local imageId = nil
		if mode == "Gamepad" and key then
			local ok, result = pcall(function()
				return UserInputService:GetImageForKeyCode(Enum.KeyCode[key])
			end)
			imageId = if ok and type(result) == "string" and result ~= "" then result else nil
		end
		image.Visible = imageId ~= nil
		image.Image = imageId or ""
		frame.BackgroundTransparency = if imageId then 1 else 0
		local short = key and string.gsub(string.gsub(key, "^Button", ""), "Select", "VIEW") or ""
		label.Text = if imageId then "" else string.upper(short)
		-- one letter in a circle, longer key names (TAB, R3) in a pill
		long = #label.Text > 1
		label.Font = if long then T.BlackFont else T.HeadFont
		Layout.bindText(label, if long then 14 else 22)
		corner.CornerRadius = UDim.new(if long then 0.3 else 0.5, 0)
		resize()
	end
	label:GetPropertyChangedSignal("TextBounds"):Connect(resize)
	Layout.bindApply(frame, resize)
	render()
	return frame, render
end

function TrainingHUD:buildHints()
	local bar = make("Frame", {
		Name = "Hints",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.958),
		Size = UDim2.fromScale(0.7, 0.036),
		ZIndex = 2,
		Parent = self.gui,
	})
	local list = make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = bar,
	})
	self:bindPx(function()
		list.Padding = UDim.new(0, Layout.px(30))
	end)
	self.hintBar = bar
	self.hints = {}
	local hotkeys = self.ctx.hotkeys
	local function item(id, order, glyphFn, onClick)
		local button = make("TextButton", {
			Name = "Hint" .. id,
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			Text = "",
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromScale(0, 1),
			LayoutOrder = order,
			ZIndex = 2,
			Parent = bar,
		})
		local inner = make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = button,
		})
		self:bindPx(function()
			inner.Padding = UDim.new(0, Layout.px(10))
		end)
		local render = glyphFn(button)
		local label = make("TextLabel", {
			Name = "Label",
			BackgroundTransparency = 1,
			Font = T.BlackFont,
			TextColor3 = T.Text,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromScale(0, 1),
			LayoutOrder = 2,
			ZIndex = 3,
			Parent = button,
		})
		Layout.bindText(label, 20)
		if onClick then
			button.Activated:Connect(onClick)
		end
		self.hints[id] = { button = button, label = label, render = render }
	end
	item("Confirm", 1, function(button)
		UIKit.glyph("Confirm", { parent = button, size = 34, layoutOrder = 1, zIndex = 3 })
		return nil
	end, nil)
	item("Panel", 2, function(button)
		local _, render = keyGlyph(button, hotkeys.Keyboard.Panel, hotkeys.Gamepad.Panel, 1)
		return render
	end, function()
		self.ctx.onTogglePanel()
	end)
	item("Reset", 3, function(button)
		local _, render = keyGlyph(button, hotkeys.Keyboard.Reset, hotkeys.Gamepad.Reset, 1)
		return render
	end, function()
		self.ctx.onReset()
	end)
	item("Spawn", 4, function(button)
		local _, render = keyGlyph(button, hotkeys.Keyboard.Spawn, hotkeys.Gamepad.Spawn, 1)
		return render
	end, function()
		self.ctx.onSpawn(self.spawnWeapon)
	end)
	self.hints.Confirm.label.Text = "CHANGE"
	self.hints.Reset.label.Text = "RESET POSITIONS"
	self.hints.Spawn.label.Text = "SPAWN WEAPON"
end

-- Which hints show: per input mode, a hotkey that is off for that device has none.
function TrainingHUD:renderHints()
	if not self.hints then
		return
	end
	local mode = Focus.mode()
	-- phones have the button row instead
	self.hintBar.Visible = Layout.mode() ~= "Phone"
	local hotkeys = self.ctx.hotkeys
	local device = if mode == "Gamepad" then "Gamepad" else "Keyboard"
	for _, id in { "Panel", "Reset", "Spawn" } do
		local hint = self.hints[id]
		-- on Touch the hints are plain tappable labels
		hint.button.Visible = mode == "Touch" or hotkeys[device][id] ~= nil
		if hint.render then
			hint.render()
		end
	end
	self.hints.Confirm.button.Visible = self.open and mode ~= "Touch"
	-- what the hint does: Tab / View opens the panel's layer, then closes and hides it; a tap shows or hides it
	local hides = if mode == "Touch" then self.shown else self.open
	self.hints.Panel.label.Text = if hides then "HIDE PANEL" else "PANEL"
	self:renderCaption()
end

-- Updates ---------------------------------------------------------------------------------

-- The panel's controls from settings (any of the fields: what the server confirmed, or what was just picked).
function TrainingHUD:setSettings(settings)
	for key, value in settings do
		if key ~= "kind" then
			self.settings[key] = value
		end
	end
	self:renderSettings()
end

function TrainingHUD:renderSettings()
	local s, c = self.settings, self.controls
	c.setLegend(legendLabel(s.legend))
	c.setWeapon(weaponLabel(s.weapon))
	c.setDummyLegend(legendLabel(s.dummyLegend))
	for mode, api in c.modes do
		api.setSelected(mode == s.dummyMode)
	end
	-- the bot level only matters when the dummy fights back (and for its recovery)
	c.setLevel(string.upper(s.difficulty), s.dummyMode ~= "Fight")
	c.setKeep(s.keepDamage)
	for scale, api in c.speeds do
		api.setSelected(scale == s.speed)
	end
	self:setSpeedChip(s.speed)
end

function TrainingHUD:setSpeedChip(speed)
	if speed == self.chipSpeedValue then
		return
	end
	self.chipSpeedValue = speed
	if self.chipSpeed then
		self.chipSpeed:Destroy()
		self.chipSpeed = nil
	end
	if speed and speed < 1 then
		self.chipSpeed = UIKit.tag("SLOW-MO", {
			parent = self.chipHolder,
			fill = T.Warning,
			textColor = T.GoldDark,
			size = 22,
			layoutOrder = 2,
		})
		-- UIKit.tag writes caps; the speed keeps its small x ("SLOW-MO 0.5x", as the speed chips say it)
		local content = self.chipSpeed:FindFirstChild("Content")
		local label = content and content:FindFirstChild("Text")
		if label and label:IsA("TextLabel") then
			label.Text = "SLOW-MO " .. speedLabel(speed)
		end
	end
end

-- Readout visibility from the DISPLAY toggles (and the layout).
function TrainingHUD:setDisplay(display)
	local phone = Layout.mode() == "Phone"
	for name, set in self.controls.display do
		set(display[name])
	end
	self.readouts.combo.Visible = not phone and display.Combo
	self.readouts.frames.Visible = not phone and display.FrameData
	self.readouts.dummy.Visible = not phone
	self.phoneChips.Visible = phone
	self.phoneCombo.Visible = display.Combo
	self.hitboxChip.Visible = display.Hitboxes
	self.titleChip.Visible = not phone
end

-- shown: the panel is on screen; open: its Focus layer is (keyboard / gamepad are in it).
function TrainingHUD:setPanel(shown, open)
	self.shown = shown
	self.open = open
	self.panel.Visible = shown
	self.bar.Visible = Layout.mode() == "Phone" or not shown
	self:renderHints()
end

function TrainingHUD:defaultFocus()
	return self.controls.legendRow
end

function TrainingHUD:setSpawnWeapon(weaponId)
	self.spawnWeapon = weaponId
	for id, api in self.controls.spawn do
		api.setSelected(id == weaponId)
	end
	self:renderCaption()
end

-- "Drops a Scythe at your feet · V" (the key for the current input mode; none on Touch).
function TrainingHUD:renderCaption()
	if not self.spawnCaption or not self.spawnWeapon then
		return
	end
	local name = Weapons.get(self.spawnWeapon).Name
	local article = if self.spawnWeapon == "Gauntlets" then "" else "a "
	local caption = "Drops " .. article .. name .. " at your feet"
	local mode = Focus.mode()
	local key = if mode == "Gamepad"
		then self.ctx.hotkeys.Gamepad.Spawn
		elseif mode == "Keyboard" then self.ctx.hotkeys.Keyboard.Spawn
		else nil
	if key then
		caption ..= " · " .. string.gsub(key, "^Button", "")
	end
	self.spawnCaption.Text = caption
end

-- The dummy's damage on the stepper (also used right after a change, before the server confirms it).
function TrainingHUD:showDamage(damage)
	self.damage = math.floor(damage + 0.5)
	self.setDamageText(self.damage .. "%")
	self.r.dummyDamage.Text = self.damage .. "%"
end

-- The DUMMY readout: snapshot = the latest "Dummy" TrainingEvent (or nil), damage = its damage now.
function TrainingHUD:setDummy(snapshot, damage)
	self:showDamage(damage or 0)
	local lines = self.r.dummyLines
	local state = if snapshot then snapshot.stateLabel else "-"
	local mode = MODE_LABELS[if snapshot then snapshot.mode else self.settings.dummyMode] or "-"
	lines[1].Text = pair("STATE", state)
	lines[2].Text = pair("BEHAVIOR", mode)
	lines[3].Text = pair("KOs", if snapshot then snapshot.kos else 0)
	self.phoneDummyText.Text = string.format('<font color="%s">%d%%</font>  %s', hex(T.DamageHot), self.damage, state)
end

-- The COMBO readout: view = FrameData combo:get(), or nil for none yet.
function TrainingHUD:setCombo(view)
	local r = self.r
	local hits = if view then view.hits else 0
	r.hits.Text = tostring(hits)
	r.hitsLabel.Text = if hits == 1 then "HIT" else "HITS"
	r.comboDamage.Text = tostring(if view then view.damage else 0)
	r.lastHit.Text = if view and hits > 0 then pair("LAST HIT", "+" .. view.lastHit) else ""
	local combo = hits >= 2
	local isTrue = combo and view.isTrue
	UIKit.setSlantFill(r.trueTag, if isTrue then T.Good else T.Raised)
	r.trueText.TextColor3 = if isTrue then T.Text else T.Dim
	UIKit.setSlantFill(r.stringTag, if combo and not isTrue then T.Stroke else T.Raised)
	r.stringText.TextColor3 = if combo and not isTrue then T.Text else T.Dim
	local tag = if not combo then "" elseif isTrue then "  TRUE" else "  STRING"
	self.phoneComboText.Text = string.format("%d HITS · %d%s", hits, if view then view.damage else 0, tag)
end

--[[
    The FRAME DATA readout from a meter view (FrameData meter:view(), nil
    before your first attack) and the "SWORD · GROUND" subtitle. Rebuilds
    the strip only when the attack changes; otherwise moves the cursor.
]]
function TrainingHUD:setFrameData(view, subtitle)
	local r = self.r
	local summary = view and view.summary
	if not summary then
		r.moveName.Text = "ATTACK!"
		r.subtitle.Text = "Your attacks show their frames here"
		r.note.Text = ""
		for _, label in r.boxes do
			label.Text = "-"
		end
		r.stats.Text = ""
		self:renderStrip({}, 0)
		return
	end
	r.moveName.Text = string.upper(summary.name)
	-- STARTUP counts the frame the hitbox comes out on: say which one it is
	local hitsOn = "HITS ON FRAME " .. summary.startup
	r.subtitle.Text = if subtitle then subtitle .. " · " .. hitsOn else hitsOn
	r.note.Text = if view.charging
		then "CHARGING"
		elseif view.cancelled then "CANCELLED"
		elseif view.interrupted then "INTERRUPTED"
		else ""
	r.boxes.startup.Text = summary.startup .. "F"
	r.boxes.active.Text = summary.active .. "F"
	r.boxes.recovery.Text = summary.recovery .. "F"
	r.boxes.total.Text = summary.total .. "F"
	r.stats.Text = table.concat({
		pair("DMG", summary.damage),
		pair("KB", summary.kbBase .. " + " .. summary.kbScaling),
		pair("ANGLE", summary.angle .. "°"),
	}, "      ")
	self:renderStrip(view.cells, view.current)
end

-- One solid cell per frame in its phase's colour, a white outline on the current one (mockup f).
function TrainingHUD:renderStrip(cells, current)
	local r = self.r
	local n = #cells
	local gap = math.max(1, Layout.px(2))
	for i = 1, math.max(n, #r.cells) do
		local cell = r.cells[i]
		if i <= n then
			if not cell then
				cell = make("Frame", { BorderSizePixel = 0, ZIndex = 4, Parent = r.strip })
				r.cells[i] = cell
			end
			cell.Visible = true
			cell.BackgroundColor3 = PHASE_COLORS[cells[i]] or T.Dim
			cell.Position = UDim2.fromScale((i - 1) / n, 0)
			cell.Size = UDim2.new(1 / n, -gap, 1, 0)
		elseif cell then
			cell.Visible = false
		end
	end
	r.cursor.Visible = current >= 1 and current <= n
	if r.cursor.Visible then
		r.cursor.Position = UDim2.fromScale((current - 1) / n, 0.5)
		r.cursor.Size = UDim2.new(1 / n, -gap, 1.3, 0)
	end
end

function TrainingHUD:destroy()
	for _, connection in self.connections do
		connection:Disconnect()
	end
	self.connections = {}
	-- let Focus go of every control before the gui goes (it would also on Destroying)
	for _, obj in self.focusables do
		Focus.unregister(obj)
	end
	self.focusables = {}
	if self.gui then
		self.gui:Destroy()
		self.gui = nil
	end
end

return TrainingHUD
