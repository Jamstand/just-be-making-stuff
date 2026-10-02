-- SettingsUI: the Settings panel. Sections and rows come from SettingsConfig (Sections, Order); each
-- row is a label + description and a control:
--  * toggle - a pill track whose knob springs across while the track fills green ("ON") or greys out
--  * slider - track + fill + knob; drag it (mouse or touch) or tap anywhere on it to jump; shows a %
--    and plays its sound when you let go
--  * choice - a segmented pill with a highlight that slides to the picked option
-- Every control writes through ClientSettings.Set and follows ClientSettings.Changed, so the saved
-- values (which arrive with the first State) and resets show up live. "Reset to defaults" asks for a
-- second tap first. Rows stagger in on open; on thin screens the control moves under its text.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local SettingsConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("SettingsConfig"))

local Theme = require(script.Parent:WaitForChild("Theme"))
local Anim = require(script.Parent:WaitForChild("Anim"))
local UISound = require(script.Parent:WaitForChild("UISound"))
local Menu = require(script.Parent:WaitForChild("Menu"))
local ClientSettings = require(script.Parent:WaitForChild("ClientSettings"))

local SettingsUI = {}

local WHITE = Color3.new(1, 1, 1)
local ROW_H = 84
local ROW_H_NARROW = 150
local CONTROL_W = 232
local NARROW_AT = 470 -- reference px of list width below which controls go under the text
local CONFIRM_TIME = 3
local SECTION_ICONS = { Sound = "🔊", Display = "🖥️", Performance = "⚡" } :: { [string]: string }

type Row = {
	cell: Frame,
	name: TextLabel,
	desc: TextLabel,
	control: GuiObject,
}

local panel: Frame
local scroll: ScrollingFrame
local rows = {} :: { Row }
local faces = {} :: { GuiObject } -- what staggers in on open
local controls = {} :: { [string]: (value: any, animate: boolean) -> () }
local dragging = {} :: { [string]: boolean } -- sliders being dragged ignore Changed echoes
local narrow: boolean? = nil

-- ---------- controls ----------

local function knobFrame(parent: Instance, size: number): Frame
	local knob = Instance.new("Frame")
	knob.Name = "Knob"
	knob.Size = UDim2.fromOffset(size, size)
	knob.BackgroundColor3 = WHITE
	knob.BorderSizePixel = 0
	Theme.corner(knob, UDim.new(0.5, 0))
	Theme.stroke(knob, Theme.Color.Stroke, 2.5)
	Theme.gradient(knob, WHITE, Color3.fromRGB(222, 216, 232))
	knob.Parent = parent
	return knob
end

-- Pill switch. The whole control area is the tap target.
local function toggleControl(area: TextButton, key: string)
	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(1, 0.5)
	track.Position = UDim2.new(1, -10, 0.5, 0)
	track.Size = UDim2.fromOffset(104, 52)
	track.BackgroundColor3 = WHITE
	track.BorderSizePixel = 0
	Theme.corner(track, 26)
	Theme.stroke(track, Theme.Color.Stroke, 3)
	Theme.gradient(track, Theme.Styles.grey.top, Theme.Styles.grey.bottom)
	track.Parent = area
	local onFill = Instance.new("Frame")
	onFill.Name = "On"
	onFill.Size = UDim2.fromScale(1, 1)
	onFill.BackgroundColor3 = WHITE
	onFill.BorderSizePixel = 0
	onFill.ZIndex = 1
	Theme.corner(onFill, 26)
	Theme.gradient(onFill, Theme.Styles.green.top, Theme.Styles.green.bottom)
	onFill.Parent = track
	local gloss = Theme.gloss(track, 26)
	gloss.ZIndex = 2
	local word = Theme.label(track, "OFF", 15, WHITE)
	word.ZIndex = 3
	word.Size = UDim2.new(0.55, -8, 1, 0)
	local wordStroke = Theme.textStroke(word, Theme.Styles.grey.stroke, 1.5)
	local knob = knobFrame(track, 42)
	knob.ZIndex = 4

	local function show(value: any, animate: boolean)
		local on = value == true
		local props = {
			AnchorPoint = Vector2.new(if on then 1 else 0, 0.5),
			Position = UDim2.new(if on then 1 else 0, if on then -5 else 5, 0.5, 0),
		}
		word.Text = if on then "ON" else "OFF"
		word.Position = if on then UDim2.fromOffset(8, 0) else UDim2.new(0.45, 0, 0, 0)
		wordStroke.Color = if on then Theme.Styles.green.stroke else Theme.Styles.grey.stroke
		if animate then
			Anim.tween(knob, 0.4, props, Enum.EasingStyle.Back)
			Anim.tween(onFill, 0.22, { BackgroundTransparency = if on then 0 else 1 }, Enum.EasingStyle.Quad)
			Anim.bump(knob, 1.18)
		else
			knob.AnchorPoint = props.AnchorPoint
			knob.Position = props.Position
			onFill.BackgroundTransparency = if on then 0 else 1
		end
	end
	area.Activated:Connect(function()
		ClientSettings.Set(key, not (ClientSettings.Get(key) == true))
		UISound.Play("toggle")
		Anim.bump(track, 1.06)
	end)
	return show
end

-- Slider 0..1: press anywhere on the control to jump there, then drag; plays its sound on release.
local function sliderControl(area: TextButton, key: string)
	local value = Theme.label(area, "0%", 20, Theme.Color.Text)
	value.Name = "Value"
	value.AnchorPoint = Vector2.new(1, 0.5)
	value.Position = UDim2.new(1, -8, 0.5, 0)
	value.Size = UDim2.fromOffset(58, 30)
	value.TextXAlignment = Enum.TextXAlignment.Right
	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0, 0.5)
	track.Position = UDim2.new(0, 24, 0.5, 0)
	track.Size = UDim2.new(1, -24 - 58 - 28, 0, 16)
	track.BackgroundColor3 = Theme.Color.InsetDark
	track.BorderSizePixel = 0
	Theme.corner(track, 8)
	Theme.stroke(track, Theme.Color.Stroke, 2.5)
	track.Parent = area
	local fillBar = Instance.new("Frame")
	fillBar.Name = "Fill"
	fillBar.BackgroundColor3 = WHITE
	fillBar.BorderSizePixel = 0
	fillBar.Size = UDim2.fromScale(0, 1)
	Theme.corner(fillBar, 8)
	Theme.gradient(fillBar, Theme.Styles.blue.top, Theme.Styles.blue.bottom)
	fillBar.Parent = track
	local knob = knobFrame(track, 38)
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.ZIndex = 3
	local pip = Instance.new("Frame")
	pip.AnchorPoint = Vector2.new(0.5, 0.5)
	pip.Position = UDim2.fromScale(0.5, 0.5)
	pip.Size = UDim2.fromOffset(12, 12)
	pip.BackgroundColor3 = Theme.Styles.blue.bottom
	pip.BorderSizePixel = 0
	Theme.corner(pip, UDim.new(0.5, 0))
	pip.Parent = knob
	local knobScale = Anim.scale(knob)

	local function show(v: any, animate: boolean)
		local x = math.clamp(tonumber(v) or 0, 0, 1)
		value.Text = tostring(math.floor(x * 100 + 0.5)) .. "%"
		fillBar.Visible = x > 0.005
		if animate then
			Anim.tween(fillBar, 0.18, { Size = UDim2.fromScale(x, 1) })
			Anim.tween(knob, 0.18, { Position = UDim2.fromScale(x, 0.5) })
		else
			fillBar.Size = UDim2.fromScale(x, 1)
			knob.Position = UDim2.fromScale(x, 0.5)
		end
	end

	local function valueAt(screenX: number): number
		local width = math.max(track.AbsoluteSize.X, 1)
		local x = math.clamp((screenX - track.AbsolutePosition.X) / width, 0, 1)
		return math.floor(x * 100 + 0.5) / 100
	end

	local active: InputObject? = nil -- the mouse button / finger doing the dragging
	local function commit(x: number)
		-- short tweens (not direct sets) so a drag takes over smoothly from the tap-to-jump glide
		value.Text = tostring(math.floor(x * 100 + 0.5)) .. "%"
		fillBar.Visible = x > 0.005
		Anim.tween(fillBar, 0.06, { Size = UDim2.fromScale(x, 1) }, Enum.EasingStyle.Linear)
		Anim.tween(knob, 0.06, { Position = UDim2.fromScale(x, 0.5) }, Enum.EasingStyle.Linear)
		ClientSettings.Set(key, x)
	end
	local function finish()
		active = nil
		dragging[key] = false
		scroll.ScrollingEnabled = true
		Anim.tween(knobScale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
		UISound.Play("toggle")
	end
	area.InputBegan:Connect(function(input)
		local kind = input.UserInputType
		if active or (kind ~= Enum.UserInputType.MouseButton1 and kind ~= Enum.UserInputType.Touch) then
			return
		end
		active = input
		dragging[key] = true
		scroll.ScrollingEnabled = false -- a sideways drag must not scroll the list
		local x = valueAt(input.Position.X)
		show(x, true) -- tap-to-jump glides there
		ClientSettings.Set(key, x)
		Anim.tween(knobScale, 0.15, { Scale = 1.2 }, Enum.EasingStyle.Back)
	end)
	UserInputService.InputChanged:Connect(function(input)
		local current = active
		if not current then
			return
		end
		local moved = if current.UserInputType == Enum.UserInputType.Touch
			then input == current
			else input.UserInputType == Enum.UserInputType.MouseMovement
		if moved then
			commit(valueAt(input.Position.X))
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		local current = active
		if current and (input == current or input.UserInputType == current.UserInputType and input.UserInputType == Enum.UserInputType.MouseButton1) then
			finish()
		end
	end)
	return show
end

-- Segmented choice with a sliding highlight.
local function choiceControl(area: Frame, key: string, choices: { string })
	local n = math.max(#choices, 1)
	local box = Instance.new("Frame")
	box.Name = "Choice"
	box.AnchorPoint = Vector2.new(1, 0.5)
	box.Position = UDim2.new(1, -8, 0.5, 0)
	box.Size = UDim2.fromOffset(CONTROL_W - 16, 60)
	box.BackgroundColor3 = Theme.Color.InsetDark
	box.BorderSizePixel = 0
	Theme.corner(box, 18)
	Theme.stroke(box, Theme.Color.Stroke, 3)
	box.Parent = area
	local highlight = Instance.new("Frame")
	highlight.Name = "Highlight"
	highlight.Size = UDim2.new(1 / n, -8, 1, -8)
	highlight.ZIndex = 1
	Theme.candy(highlight, "blue", 14, 2)
	Theme.gloss(highlight, 14)
	highlight.Parent = box
	local buttons = {} :: { TextButton }
	for i, choice in ipairs(choices) do
		local b = Instance.new("TextButton")
		b.Name = choice
		b.Text = choice
		b.Font = Theme.Font
		b.TextSize = 18
		b.TextColor3 = Theme.Color.Text
		b.AutoButtonColor = false
		b.BackgroundTransparency = 1
		b.AnchorPoint = Vector2.new(0.5, 0.5) -- press springs scale about the centre
		b.Position = UDim2.new((i - 0.5) / n, 0, 0.5, 0)
		b.Size = UDim2.new(1 / n, 0, 1, 0)
		b.ZIndex = 3
		local textStroke = Theme.textStroke(b, Theme.Styles.blue.stroke, 2)
		textStroke.Enabled = false
		b.Parent = box
		Anim.button(b, "toggle")
		b.Activated:Connect(function()
			ClientSettings.Set(key, choice)
		end)
		buttons[i] = b
	end

	local function show(v: any, animate: boolean)
		local index = table.find(choices, v) or 1
		local target = UDim2.new((index - 1) / n, 4, 0, 4)
		if animate then
			Anim.tween(highlight, 0.35, { Position = target }, Enum.EasingStyle.Back)
		else
			highlight.Position = target
		end
		for i, b in ipairs(buttons) do
			local picked = i == index
			b.TextColor3 = if picked then WHITE else Theme.Color.Text
			local s = b:FindFirstChildOfClass("UIStroke")
			if s then
				s.Enabled = picked
			end
		end
	end
	return show
end

-- ---------- rows ----------

local function layoutRow(row: Row, thin: boolean)
	if thin then
		row.cell.Size = UDim2.new(1, 0, 0, ROW_H_NARROW)
		row.name.Position = UDim2.fromOffset(16, 8)
		row.name.Size = UDim2.new(1, -32, 0, 26)
		row.desc.Position = UDim2.fromOffset(16, 34)
		row.desc.Size = UDim2.new(1, -32, 0, 38)
		row.control.AnchorPoint = Vector2.new(0.5, 1)
		row.control.Position = UDim2.new(0.5, 0, 1, -6)
	else
		row.cell.Size = UDim2.new(1, 0, 0, ROW_H)
		row.name.Position = UDim2.fromOffset(16, 9)
		row.name.Size = UDim2.new(1, -(CONTROL_W + 28), 0, 26)
		row.desc.Position = UDim2.fromOffset(16, 36)
		row.desc.Size = UDim2.new(1, -(CONTROL_W + 28), 0, 38)
		row.control.AnchorPoint = Vector2.new(1, 0.5)
		row.control.Position = UDim2.new(1, -4, 0.5, 0)
	end
end

local function applyWidth()
	local s = Theme.Scale() * Anim.scale(panel).Scale
	if s <= 0.01 then
		return
	end
	local w = scroll.AbsoluteSize.X / s
	if w <= 0 then
		return
	end
	local thin = w < NARROW_AT
	if thin == narrow then
		return
	end
	narrow = thin
	for _, row in ipairs(rows) do
		layoutRow(row, thin)
	end
end

local function sectionHeader(section: string, order: number)
	local cell = Instance.new("Frame")
	cell.Name = "Section_" .. section
	cell.BackgroundTransparency = 1
	cell.Size = UDim2.new(1, 0, 0, 36)
	cell.LayoutOrder = order
	cell.Parent = scroll
	local title = Theme.label(cell, (SECTION_ICONS[section] or "⚙️") .. "  " .. string.upper(section), 22, Theme.Color.Title)
	title.AnchorPoint = Vector2.new(0, 0.5)
	title.Position = UDim2.new(0, 6, 0.5, 2)
	title.Size = UDim2.new(1, -12, 0, 30)
	title.TextXAlignment = Enum.TextXAlignment.Left
	table.insert(faces, title)
end

local function settingRow(setting, order: number)
	local cell = Instance.new("Frame")
	cell.Name = setting.key
	cell.BackgroundTransparency = 1
	cell.Size = UDim2.new(1, 0, 0, ROW_H)
	cell.LayoutOrder = order
	cell.Parent = scroll
	local face = Instance.new("Frame")
	face.Name = "Face"
	face.AnchorPoint = Vector2.new(0.5, 0.5) -- pops in from its centre
	face.Position = UDim2.fromScale(0.5, 0.5)
	face.Size = UDim2.fromScale(1, 1)
	face.BackgroundColor3 = Theme.Color.Inset
	face.BorderSizePixel = 0
	Theme.corner(face, 16)
	Theme.stroke(face, Theme.Color.Stroke, 2, 0.55)
	face.Parent = cell
	table.insert(faces, face)

	local name = Theme.label(face, setting.display, 21, Theme.Color.Text)
	name.Name = "Name"
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextScaled = true
	local nameMax = Instance.new("UITextSizeConstraint")
	nameMax.MaxTextSize = 21
	nameMax.Parent = name
	local desc = Theme.label(face, setting.desc, 14, Theme.Color.Muted, Theme.FontBody)
	desc.Name = "Desc"
	desc.TextXAlignment = Enum.TextXAlignment.Left
	desc.TextYAlignment = Enum.TextYAlignment.Top
	desc.TextWrapped = true

	local control: GuiObject
	local show
	if setting.kind == "toggle" or setting.kind == "slider" then
		local area = Instance.new("TextButton")
		area.Text = ""
		area.AutoButtonColor = false
		area.BackgroundTransparency = 1
		control = area
		if setting.kind == "toggle" then
			show = toggleControl(area, setting.key)
		else
			show = sliderControl(area, setting.key)
		end
	else
		local area = Instance.new("Frame")
		area.BackgroundTransparency = 1
		control = area
		show = choiceControl(area, setting.key, setting.choices or {})
	end
	control.Name = "Control"
	control.Size = UDim2.fromOffset(CONTROL_W, 72)
	control.Parent = face
	controls[setting.key] = show
	show(ClientSettings.Get(setting.key), false)

	local row: Row = { cell = cell, name = name, desc = desc, control = control }
	table.insert(rows, row)
	layoutRow(row, false)
end

-- "Reset to defaults": first tap arms it (with a 3 s shrinking timer), the second resets.
local function resetRow(order: number)
	local cell = Instance.new("Frame")
	cell.Name = "Reset"
	cell.BackgroundTransparency = 1
	cell.Size = UDim2.new(1, 0, 0, 86)
	cell.LayoutOrder = order
	cell.Parent = scroll
	local button = Theme.button(cell, "🔄 Reset to defaults", "grey", UDim2.fromOffset(300, 62), 22)
	button.Name = "ResetButton"
	button.AnchorPoint = Vector2.new(0.5, 0.5)
	button.Position = UDim2.fromScale(0.5, 0.5)
	table.insert(faces, button)
	local timer = Instance.new("Frame")
	timer.Name = "Timer"
	timer.AnchorPoint = Vector2.new(0, 1)
	timer.Position = UDim2.new(0, 12, 1, -5)
	timer.Size = UDim2.new(1, -24, 0, 6)
	timer.BackgroundColor3 = WHITE
	timer.BackgroundTransparency = 0.1
	timer.BorderSizePixel = 0
	timer.ZIndex = button.ZIndex + 3
	timer.Visible = false
	Theme.corner(timer, 3)
	timer.Parent = button
	Anim.button(button, "click")

	local armed = false
	local token = 0
	local function idle()
		armed = false
		token += 1
		timer.Visible = false
		Theme.restyle(button, "grey")
		button.Text = "🔄 Reset to defaults"
	end
	button.Activated:Connect(function()
		if not armed then
			armed = true
			token += 1
			local mine = token
			Theme.restyle(button, "red")
			button.Text = "Tap again to reset"
			timer.Size = UDim2.new(1, -24, 0, 6)
			timer.Visible = true
			-- a plain timer: it must last CONFIRM_TIME even with Reduce motion on
			TweenService:Create(timer, TweenInfo.new(CONFIRM_TIME, Enum.EasingStyle.Linear), { Size = UDim2.new(0, 0, 0, 6) }):Play()
			Anim.wiggle(button, 5)
			task.delay(CONFIRM_TIME, function()
				if armed and token == mine then
					idle()
				end
			end)
			return
		end
		armed = false
		token += 1
		local mine = token
		timer.Visible = false
		for _, key in ipairs(SettingsConfig.Order) do
			local setting = SettingsConfig.Settings[key]
			if setting then
				ClientSettings.Set(key, setting.default)
			end
		end
		Theme.restyle(button, "green")
		button.Text = "Done!"
		UISound.Play("success")
		for i, face in ipairs(faces) do
			task.delay(i * 0.025, function()
				Anim.bump(face, 1.04)
			end)
		end
		task.delay(1.4, function()
			if token == mine then
				idle()
			end
		end)
	end)
end

local function onOpen()
	applyWidth()
	Anim.stagger(faces, 0.03)
end

-- ---------- public API ----------

function SettingsUI.Init()
	Menu.AddButton("Settings", "⚙️", "Settings", "grey", 5)
	local content
	panel, content = Menu.Panel("Settings", "SETTINGS", Vector2.new(640, 560), "coral", onOpen)

	scroll = Instance.new("ScrollingFrame")
	scroll.Name = "List"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Size = UDim2.fromScale(1, 1)
	scroll.ScrollBarThickness = 8
	scroll.ScrollBarImageColor3 = Theme.Color.Stroke
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.VerticalScrollBarInset = Enum.ScrollBarInset.Always
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.CanvasSize = UDim2.new()
	scroll.Parent = content
	Theme.padding(scroll, 6, 8, 8, 14)
	local list = Theme.list(scroll, 8)
	list.HorizontalAlignment = Enum.HorizontalAlignment.Left

	local order = 0
	for _, section in ipairs(SettingsConfig.Sections) do
		order += 1
		sectionHeader(section, order)
		for _, key in ipairs(SettingsConfig.Order) do
			local setting = SettingsConfig.Settings[key]
			if setting and setting.section == section then
				order += 1
				settingRow(setting, order)
			end
		end
	end
	order += 1
	resetRow(order)

	ClientSettings.Changed:Connect(function(key, value)
		local show = controls[key]
		if show and not dragging[key] then
			show(value, true)
		end
	end)
	scroll:GetPropertyChangedSignal("AbsoluteSize"):Connect(applyWidth)
	task.defer(applyWidth)
end

-- init.client doesn't push State here (settings arrive through ClientSettings); kept for the API.
function SettingsUI.SetState(_state)
end

return SettingsUI
