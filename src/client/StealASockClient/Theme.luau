-- Theme: the one place for the UI look (docs/concept/ui_style.png) - cream candy panels with thick
-- plum outlines, coral titles, a gold cash pill, glossy candy buttons - plus the small factories
-- every screen builds from, so the HUD, the menus and the pop-ups all match. Procedural: no image
-- assets (emoji stand in for icons until painted ones arrive).
--
-- Sizes are in "reference pixels" for a 720 px tall screen: every ScreenGui made by Theme.screen()
-- has a Root frame with a UIScale that fits the real screen (phones ~0.72, big monitors up to 1.1)
-- times the player's UI size setting. Build everything inside Root.
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local RarityConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("RarityConfig"))

local Theme = {}

Theme.IsTouch = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

Theme.Font = Enum.Font.FredokaOne -- titles, numbers, buttons
Theme.FontBody = Enum.Font.GothamBold -- descriptions and small print

local rgb = Color3.fromRGB
Theme.Color = {
	Panel = rgb(246, 233, 210),
	Panel2 = rgb(236, 214, 180),
	Inset = rgb(255, 248, 236), -- rows and cards inside a panel
	InsetDark = rgb(228, 206, 174), -- empty / locked cards
	Stroke = rgb(74, 42, 94), -- the plum outline
	Text = rgb(70, 44, 30),
	Muted = rgb(150, 128, 116),
	Title = rgb(232, 112, 90), -- coral
	Gold = rgb(240, 192, 96),
	Gold2 = rgb(216, 154, 58),
	Money = rgb(40, 150, 80), -- income / prices you can afford
	Bad = rgb(214, 70, 84),
	White = Color3.new(1, 1, 1),
	Ink = rgb(34, 22, 48), -- text outlines
	Backdrop = rgb(24, 14, 40),
	Night = rgb(62, 58, 110),
}

-- Candy styles: gradient top/bottom, outline, text. Buttons, pills and ribbons all take one by name.
export type Style = { top: Color3, bottom: Color3, stroke: Color3, text: Color3 }
Theme.Styles = {
	green = { top = rgb(126, 224, 120), bottom = rgb(58, 170, 82), stroke = rgb(28, 98, 52), text = Theme.Color.White },
	gold = { top = rgb(255, 218, 96), bottom = rgb(255, 168, 48), stroke = rgb(176, 108, 22), text = rgb(70, 40, 8) },
	blue = { top = rgb(116, 194, 255), bottom = rgb(58, 128, 232), stroke = rgb(28, 66, 150), text = Theme.Color.White },
	red = { top = rgb(255, 124, 124), bottom = rgb(222, 60, 82), stroke = rgb(136, 28, 48), text = Theme.Color.White },
	purple = { top = rgb(196, 136, 255), bottom = rgb(128, 70, 222), stroke = rgb(68, 30, 128), text = Theme.Color.White },
	coral = { top = rgb(255, 150, 120), bottom = rgb(232, 100, 84), stroke = rgb(140, 50, 50), text = Theme.Color.White },
	cream = { top = Theme.Color.Panel, bottom = Theme.Color.Panel2, stroke = Theme.Color.Stroke, text = Theme.Color.Text },
	grey = { top = rgb(204, 198, 210), bottom = rgb(160, 152, 170), stroke = rgb(98, 90, 110), text = rgb(248, 246, 250) },
} :: { [string]: Style }

Theme.Robux = utf8.char(0xE002) -- Roblox draws this private-use character as the Robux icon

-- Light text (white-ish) gets a dark outline on candy buttons; dark text doesn't need one.
function Theme.IsLight(c: Color3): boolean
	return c.R * 0.299 + c.G * 0.587 + c.B * 0.114 > 0.75
end

function Theme.RarityColor(rarity: string): Color3
	local tier = RarityConfig.Tiers[rarity]
	return if tier then tier.color else Theme.Color.Muted
end

function Theme.RarityName(rarity: string): string
	local tier = RarityConfig.Tiers[rarity]
	return if tier then tier.display else rarity
end

-- ---------- building blocks ----------

function Theme.corner(inst: Instance, radius: number | UDim): UICorner
	local c = Instance.new("UICorner")
	c.CornerRadius = if typeof(radius) == "UDim" then radius else UDim.new(0, radius :: number)
	c.Parent = inst
	return c
end

function Theme.stroke(inst: Instance, color: Color3?, thickness: number?, transparency: number?): UIStroke
	local s = Instance.new("UIStroke")
	s.Color = color or Theme.Color.Stroke
	s.Thickness = thickness or 3
	s.Transparency = transparency or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.LineJoinMode = Enum.LineJoinMode.Round
	s.Parent = inst
	return s
end

-- Outline on the letters themselves (chunky white text with a dark rim, like the concept's "$1,250").
function Theme.textStroke(label: TextLabel | TextButton, color: Color3?, thickness: number?): UIStroke
	local s = Instance.new("UIStroke")
	s.Color = color or Theme.Color.Ink
	s.Thickness = thickness or 2
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	s.LineJoinMode = Enum.LineJoinMode.Round
	s.Parent = label
	return s
end

function Theme.gradient(inst: Instance, top: Color3, bottom: Color3, rotation: number?): UIGradient
	local g = Instance.new("UIGradient")
	g.Rotation = rotation or 90
	g.Color = ColorSequence.new(top, bottom)
	g.Parent = inst
	return g
end

function Theme.padding(inst: Instance, left: number, top: number?, right: number?, bottom: number?): UIPadding
	local p = Instance.new("UIPadding")
	p.PaddingLeft = UDim.new(0, left)
	p.PaddingTop = UDim.new(0, top or left)
	p.PaddingRight = UDim.new(0, right or left)
	p.PaddingBottom = UDim.new(0, bottom or top or left)
	p.Parent = inst
	return p
end

function Theme.list(inst: Instance, gap: number, horizontal: boolean?, align: Enum.HorizontalAlignment?): UIListLayout
	local l = Instance.new("UIListLayout")
	l.Padding = UDim.new(0, gap)
	l.FillDirection = if horizontal then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical
	l.HorizontalAlignment = align or Enum.HorizontalAlignment.Center
	l.VerticalAlignment = if horizontal then Enum.VerticalAlignment.Center else Enum.VerticalAlignment.Top
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.Parent = inst
	return l
end

-- A transparent text label (centred, no wrap). Size it yourself.
function Theme.label(parent: Instance?, text: string, size: number, color: Color3?, font: Enum.Font?): TextLabel
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Font = font or Theme.Font
	t.TextSize = size
	t.TextColor3 = color or Theme.Color.Text
	t.Text = text
	t.Size = UDim2.new(1, 0, 0, size + 6)
	t.TextXAlignment = Enum.TextXAlignment.Center
	t.TextYAlignment = Enum.TextYAlignment.Center
	t.Parent = parent
	return t
end

-- A frame with the candy look: rounded, outlined, vertical gradient.
function Theme.candy(frame: GuiObject, style: string?, radius: number?, strokeThickness: number?)
	local st = Theme.Styles[style or "cream"] or Theme.Styles.cream
	frame.BackgroundColor3 = Theme.Color.White
	frame.BackgroundTransparency = 0
	frame.BorderSizePixel = 0
	Theme.corner(frame, radius or 14)
	Theme.stroke(frame, st.stroke, strokeThickness or 3)
	Theme.gradient(frame, st.top, st.bottom)
end

-- A glossy highlight across the top half of a candy button/pill (the concept's shine).
function Theme.gloss(frame: GuiObject, radius: number?)
	local g = Instance.new("Frame")
	g.Name = "Gloss"
	g.BackgroundColor3 = Theme.Color.White
	g.BackgroundTransparency = 0.72
	g.BorderSizePixel = 0
	g.AnchorPoint = Vector2.new(0.5, 0)
	g.Position = UDim2.new(0.5, 0, 0, 3)
	g.Size = UDim2.new(1, -10, 0.42, -2)
	g.ZIndex = frame.ZIndex + 1
	g.Parent = frame
	Theme.corner(g, (radius or 14) - 3)
	local fade = Instance.new("UIGradient")
	fade.Rotation = 90
	fade.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
	fade.Parent = g
	return g
end

-- The standard cream panel (used for HUD blocks; menus use Theme.modal through Menu).
function Theme.panel(parent: Instance?, name: string, size: UDim2): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.Size = size
	Theme.candy(f, "cream", 18)
	f.Parent = parent
	return f
end

-- A candy button. `style` = a Theme.Styles key. Hook Anim.button(btn) for the press springs
-- (Theme can't require Anim: Anim plays sounds and sounds read settings).
-- A UIGradient tints its own object's text as well as its background, so the button's own text
-- stays invisible and a child "Label" shows it: set btn.Text / TextColor3 / TextSize / Font as
-- usual and the label follows.
local MIRRORED = { "Text", "TextColor3", "TextSize", "Font", "TextWrapped", "TextScaled" }

function Theme.button(parent: Instance?, text: string, style: string?, size: UDim2?, textSize: number?): TextButton
	local st = Theme.Styles[style or "green"] or Theme.Styles.green
	local b = Instance.new("TextButton")
	b.Name = "Button"
	b.AutoButtonColor = false
	b.Size = size or UDim2.fromOffset(160, 56)
	b.Font = Theme.Font
	b.Text = text
	b.TextSize = textSize or 24
	b.TextColor3 = st.text
	b.TextWrapped = true
	b.TextTransparency = 1
	Theme.candy(b, style or "green", 16, 3)
	Theme.gloss(b, 16)
	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.new(1, -10, 1, -4)
	label.ZIndex = b.ZIndex + 2 -- over the gloss
	for _, prop in ipairs(MIRRORED) do
		(label :: any)[prop] = (b :: any)[prop]
		b:GetPropertyChangedSignal(prop):Connect(function()
			(label :: any)[prop] = (b :: any)[prop]
		end)
	end
	Theme.textStroke(label, st.stroke, 2).Enabled = Theme.IsLight(st.text)
	label.Parent = b
	b.Parent = parent
	return b
end

-- Recolours a candy button/frame made by Theme.button / Theme.candy to another style.
function Theme.restyle(frame: GuiObject, style: string)
	local st = Theme.Styles[style] or Theme.Styles.green
	local stroke = frame:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = st.stroke
	end
	local grad = frame:FindFirstChildOfClass("UIGradient")
	if grad then
		grad.Color = ColorSequence.new(st.top, st.bottom)
	end
	if frame:IsA("TextButton") or frame:IsA("TextLabel") then
		(frame :: any).TextColor3 = st.text
		-- the text outline sits on the button's Label (Theme.button) or on the frame itself
		local label = frame:FindFirstChild("Label")
		for _, holder in ipairs({ frame, label }) do
			for _, child in ipairs(holder:GetChildren()) do
				if child:IsA("UIStroke") and child.ApplyStrokeMode == Enum.ApplyStrokeMode.Contextual then
					child.Color = st.stroke
					child.Enabled = Theme.IsLight(st.text)
				end
			end
		end
	end
end

-- A round emoji badge (icons until painted ones arrive).
function Theme.icon(parent: Instance?, emoji: string, size: number, color: Color3?): Frame
	local f = Instance.new("Frame")
	f.Name = "Icon"
	f.Size = UDim2.fromOffset(size, size)
	f.BackgroundColor3 = color or Theme.Color.Inset
	f.BorderSizePixel = 0
	Theme.corner(f, UDim.new(0.5, 0))
	Theme.stroke(f, Theme.Color.Stroke, 2.5)
	local t = Theme.label(f, emoji, math.floor(size * 0.58), Theme.Color.White)
	t.Name = "Glyph"
	t.Size = UDim2.fromScale(1, 1)
	f.Parent = parent
	return f
end

-- A coral title ribbon that sits across the top edge of a panel.
function Theme.ribbon(parent: Instance, text: string, style: string?, width: number?): Frame
	local r = Instance.new("Frame")
	r.Name = "Ribbon"
	r.AnchorPoint = Vector2.new(0.5, 0.5)
	r.Position = UDim2.new(0.5, 0, 0, 0)
	r.Size = UDim2.fromOffset(width or 260, 52)
	r.ZIndex = 5
	Theme.candy(r, style or "coral", 18, 3)
	Theme.gloss(r, 18)
	local t = Theme.label(r, text, 30, Theme.Color.White)
	t.Name = "Title"
	t.Size = UDim2.fromScale(1, 1)
	t.ZIndex = 7
	Theme.textStroke(t, (Theme.Styles[style or "coral"] or Theme.Styles.coral).stroke, 2.5)
	r.Parent = parent
	return r
end

-- The round red X used by every panel.
function Theme.closeButton(parent: Instance): TextButton
	local b = Theme.button(parent, "✕", "red", UDim2.fromOffset(48, 48), 26)
	b.Name = "Close"
	b.AnchorPoint = Vector2.new(0.5, 0.5)
	b.Position = UDim2.new(1, -6, 0, 6)
	b.ZIndex = 8
	local c = b:FindFirstChildOfClass("UICorner")
	if c then
		c.CornerRadius = UDim.new(0.5, 0)
	end
	return b
end

-- "R$ 199" with the Robux glyph.
function Theme.robux(price: number): string
	return Theme.Robux .. " " .. tostring(price)
end

-- ---------- screens and scale ----------

local REFERENCE_HEIGHT = 720
local roots = {} :: { Frame }
local userScale = 1

local function autoScale(): number
	local camera = workspace.CurrentCamera
	local viewport = if camera then camera.ViewportSize else Vector2.new(1280, 720)
	local inset = GuiService:GetGuiInset()
	return math.clamp((viewport.Y - inset.Y) / REFERENCE_HEIGHT, 0.72, 1.1)
end

local function applyScale(root: Frame)
	local s = autoScale() * userScale
	local ui = root:FindFirstChild("SettingsScale") :: UIScale?
	if ui then
		ui.Scale = s
	end
	root.Size = UDim2.fromScale(1 / s, 1 / s) -- after scaling it fills the screen exactly
end

-- A ScreenGui (below the top bar) with a scaled Root frame. Returns (gui, root).
function Theme.screen(name: string, displayOrder: number?): (ScreenGui, Frame)
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = displayOrder or 0
	local root = Instance.new("Frame")
	root.Name = "Root"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = gui
	local ui = Instance.new("UIScale")
	ui.Name = "SettingsScale"
	ui.Parent = root
	table.insert(roots, root)
	applyScale(root)
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	return gui, root
end

-- The current reference-px -> screen-px factor (for effects drawn in raw pixels).
function Theme.Scale(): number
	return autoScale() * userScale
end

-- UI size setting ("Small" / "Normal" / "Large" -> 0.85 / 1 / 1.15).
function Theme.SetUserScale(scale: number)
	userScale = scale
	for _, root in ipairs(roots) do
		applyScale(root)
	end
end

local function watchViewport()
	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			for _, root in ipairs(roots) do
				applyScale(root)
			end
		end)
	end
end
watchViewport()
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchViewport)

return Theme
