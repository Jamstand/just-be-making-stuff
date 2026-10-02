-- Menu: the left-side button column (Drawer, Shop, Store, Sockdex, Settings) and the
-- one-panel-at-a-time manager every screen opens through.
--
-- Opening a panel dims and blurs the game behind it and springs the panel in; the X, the backdrop,
-- the same column button or the gamepad B button closes it. Pop-ups that belong on top of a panel
-- (the sock card over the Sockdex, a confirm box) use Menu.ShowOverlay / Menu.HideOverlay.
--
-- Screen layout (reference px, see Theme): HUD cash pill top-left, this column under it starting
-- at Menu.ColumnTop, HUD side panels start at Menu.ColumnRight + 8, panels centred.
local Lighting = game:GetService("Lighting")
local UserInputService = game:GetService("UserInputService")

local Theme = require(script.Parent:WaitForChild("Theme"))
local Anim = require(script.Parent:WaitForChild("Anim"))
local UISound = require(script.Parent:WaitForChild("UISound"))

local Menu = {}

Menu.ColumnTop = 120 -- y of the first column button
Menu.ColumnLeft = 12
Menu.ColumnRight = 12 + 76 -- x just right of the column (HUD side panels start here + 8)

type Entry = {
	key: string,
	button: TextButton?,
	badge: Frame?,
	badgeShown: boolean?, -- what SetBadge last asked for (Visible lags behind while it pops out)
	panel: Frame?,
	onOpen: (() -> ())?,
	onClose: (() -> ())?,
}

local entries = {} :: { [string]: Entry }
local current: string? = nil
local column: Frame
local layer: Frame
local backdrop: TextButton
local overlayBackdrop: TextButton
local overlay: GuiObject? = nil
local overlayClose: (() -> ())? = nil
local blur: BlurEffect

local function entry(key: string): Entry
	local e = entries[key]
	if not e then
		e = { key = key }
		entries[key] = e
	end
	return e
end

local function makeBackdrop(name: string, z: number): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.Text = ""
	b.AutoButtonColor = false
	b.BackgroundColor3 = Theme.Color.Backdrop
	b.BackgroundTransparency = 1
	b.BorderSizePixel = 0
	b.AnchorPoint = Vector2.new(0.5, 0.5)
	b.Position = UDim2.fromScale(0.5, 0.5)
	b.Size = UDim2.fromScale(3, 3) -- covers the top bar strip and any rounding at the edges
	b.ZIndex = z
	b.Visible = false
	b.Parent = layer
	return b
end

function Menu.Init()
	local _, menuRoot = Theme.screen("SockMenu", 10)
	column = Instance.new("Frame")
	column.Name = "Column"
	column.BackgroundTransparency = 1
	column.Position = UDim2.fromOffset(Menu.ColumnLeft, Menu.ColumnTop)
	column.Size = UDim2.new(0, 72, 1, -Menu.ColumnTop - 12)
	column.Parent = menuRoot
	local list = Theme.list(column, 8)
	list.HorizontalAlignment = Enum.HorizontalAlignment.Left

	local _, modalRoot = Theme.screen("SockModal", 20)
	layer = modalRoot
	backdrop = makeBackdrop("Backdrop", 1)
	backdrop.Activated:Connect(function()
		Menu.Close()
	end)
	overlayBackdrop = makeBackdrop("OverlayBackdrop", 40)
	overlayBackdrop.Activated:Connect(function()
		Menu.HideOverlay()
	end)

	blur = Instance.new("BlurEffect")
	blur.Name = "MenuBlur"
	blur.Size = 0
	blur.Enabled = false
	blur.Parent = Lighting

	-- short screens (phones in landscape) get smaller column tiles so all five fit
	local function fitColumn()
		local refHeight = menuRoot.AbsoluteSize.Y / math.max(Theme.Scale(), 0.01)
		local tile = if refHeight < 600 then 60 else 72
		for _, e in pairs(entries) do
			local cell = e.button and e.button.Parent
			if cell and cell:IsA("Frame") then
				cell.Size = UDim2.fromOffset(tile, tile)
			end
		end
		column.Size = UDim2.new(0, tile, 1, -Menu.ColumnTop - 12)
	end
	menuRoot:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitColumn)
	task.defer(fitColumn)

	UserInputService.InputBegan:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.ButtonB then
			if overlay then
				Menu.HideOverlay()
			elseif current then
				Menu.Close()
			end
		end
	end)
end

-- The modal layer (above the HUD). Screens parent their panels here via Menu.Panel.
function Menu.Layer(): Frame
	return layer
end

-- A column button: candy tile with an emoji and a small label. Without `onClick` it toggles the
-- panel registered under the same key.
function Menu.AddButton(key: string, icon: string, label: string, style: string, order: number, onClick: (() -> ())?): TextButton
	local e = entry(key)
	-- the list places the cell; the tile sits centred in it so its pops and hovers grow from the middle
	local cell = Instance.new("Frame")
	cell.Name = key .. "Cell"
	cell.BackgroundTransparency = 1
	cell.Size = UDim2.fromOffset(72, 72)
	cell.LayoutOrder = order
	cell.Parent = column
	local tile = Theme.button(cell, "", style, UDim2.fromScale(1, 1))
	tile.Name = key .. "Button"
	tile.AnchorPoint = Vector2.new(0.5, 0.5)
	tile.Position = UDim2.fromScale(0.5, 0.5)
	local glyph = Theme.label(tile, icon, 34, Theme.Color.White)
	glyph.Name = "Glyph"
	glyph.ZIndex = tile.ZIndex + 3 -- over the gloss
	glyph.Position = UDim2.new(0, 0, 0, 4)
	glyph.Size = UDim2.new(1, 0, 0.62, 0)
	glyph.TextScaled = true
	local glyphMax = Instance.new("UITextSizeConstraint")
	glyphMax.MaxTextSize = 34
	glyphMax.Parent = glyph
	local name = Theme.label(tile, label, 14, Theme.Color.White)
	name.Name = "Caption"
	name.ZIndex = tile.ZIndex + 3
	name.AnchorPoint = Vector2.new(0, 1)
	name.Position = UDim2.new(0, 0, 1, -5)
	name.Size = UDim2.new(1, 0, 0, 16)
	Theme.textStroke(name, (Theme.Styles[style] or Theme.Styles.green).stroke, 2)
	-- notification bubble (Menu.SetBadge)
	local badge = Instance.new("Frame")
	badge.Name = "Badge"
	badge.AnchorPoint = Vector2.new(0.5, 0.5)
	badge.Position = UDim2.new(1, -6, 0, 6)
	badge.Size = UDim2.fromOffset(28, 28)
	badge.ZIndex = 6
	badge.Visible = false
	Theme.candy(badge, "red", 14, 2)
	local badgeText = Theme.label(badge, "!", 16, Theme.Color.White)
	badgeText.Name = "Text"
	badgeText.Size = UDim2.fromScale(1, 1)
	badgeText.ZIndex = 7
	badge.Parent = tile
	e.button = tile
	e.badge = badge
	Anim.button(tile, "click")
	tile.Activated:Connect(function()
		if onClick then
			onClick()
		else
			Menu.Toggle(key)
		end
	end)
	Anim.popIn(tile, 0.15 + order * 0.06)
	return tile
end

-- Shows a small red bubble on a column button ("!", "3", "NEW"); nil hides it.
function Menu.SetBadge(key: string, text: string?)
	local e = entries[key]
	local badge = e and e.badge
	if not badge then
		return
	end
	local label = badge:FindFirstChild("Text") :: TextLabel?
	if text then
		if label then
			label.Text = text
		end
		badge.Size = UDim2.fromOffset(math.max(28, 12 + #text * 10), 28)
		if not e.badgeShown then
			e.badgeShown = true
			Anim.popIn(badge)
			Anim.sway(badge, 8, 1.2)
			UISound.Play("pop")
		end
	elseif e.badgeShown then
		e.badgeShown = false
		Anim.stop(badge, "sway")
		Anim.popOut(badge)
	end
end

-- A standard menu panel: cream candy card with a title ribbon and a close X, hidden until opened.
-- `size` is the most it takes (reference px); on short screens it shrinks to 86% of the height,
-- so put scrolling content in a ScrollingFrame. Returns (panel, content).
function Menu.Panel(key: string, title: string, size: Vector2, ribbonStyle: string?, onOpen: (() -> ())?, onClose: (() -> ())?): (Frame, Frame)
	local e = entry(key)
	local panel = Instance.new("Frame")
	panel.Name = "Panel_" .. key
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.new(0.5, 0, 0.5, 14) -- a touch low: the ribbon sticks out of the top
	panel.Size = UDim2.fromScale(0.94, 0.86) -- capped at `size` below; narrow (portrait) screens get 94%
	panel.ZIndex = 10
	panel.Visible = false
	panel.Active = true -- taps on blank parts stop here instead of reaching the closing backdrop
	Theme.candy(panel, "cream", 22, 4)
	local maxSize = Instance.new("UISizeConstraint")
	maxSize.MaxSize = size
	maxSize.Parent = panel
	local ribbon = Theme.ribbon(panel, title, ribbonStyle or "coral", math.min(size.X - 120, 320))
	ribbon.ZIndex = 15
	ribbon.Active = true -- it sticks out above the panel
	Anim.sway(ribbon, 1.2, 3)
	local close = Theme.closeButton(panel)
	close.ZIndex = 16
	Anim.button(close, "close")
	close.Activated:Connect(function()
		Menu.Close()
	end)
	local content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.Position = UDim2.fromOffset(18, 38)
	content.Size = UDim2.new(1, -36, 1, -56)
	content.ZIndex = 11
	content.Parent = panel
	panel.Parent = layer
	e.panel = panel
	e.onOpen = onOpen
	e.onClose = onClose
	return panel, content
end

local function setActive(key: string?, on: boolean)
	local e = key and entries[key]
	local button = e and e.button
	if button then
		local stroke = button:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Thickness = if on then 5 else 3
		end
		Anim.bump(button, if on then 1.1 else 1.04)
	end
end

local function showBackdrop(b: TextButton, on: boolean, strength: number)
	if on then
		b.Visible = true
		Anim.tween(b, 0.25, { BackgroundTransparency = 1 - strength }, Enum.EasingStyle.Quad)
	else
		local tw = Anim.tween(b, 0.2, { BackgroundTransparency = 1 }, Enum.EasingStyle.Quad)
		tw.Completed:Once(function()
			if b.BackgroundTransparency >= 0.99 then
				b.Visible = false
			end
		end)
	end
end

function Menu.Current(): string?
	return current
end

function Menu.IsOpen(key: string): boolean
	return current == key
end

-- Opens a registered panel (closing any other one first).
function Menu.Open(key: string)
	local e = entries[key]
	local panel = e and e.panel
	if not panel or current == key then
		return
	end
	local previous = current
	if previous then
		local pe = entries[previous]
		if pe and pe.panel then
			pe.panel.Visible = false
		end
		setActive(previous, false)
		if pe and pe.onClose then
			task.spawn(pe.onClose)
		end
	else
		showBackdrop(backdrop, true, 0.45)
		blur.Enabled = true
		Anim.tween(blur, 0.3, { Size = 12 }, Enum.EasingStyle.Quad)
	end
	current = key
	setActive(key, true)
	Anim.popIn(panel)
	UISound.Play("open")
	if e.onOpen then
		task.spawn(e.onOpen)
	end
end

-- Closes the open panel (and any overlay on it).
function Menu.Close()
	local key = current
	if not key then
		return
	end
	Menu.HideOverlay()
	current = nil
	local e = entries[key]
	setActive(key, false)
	if e and e.panel then
		Anim.popOut(e.panel)
	end
	showBackdrop(backdrop, false, 0)
	local tw = Anim.tween(blur, 0.25, { Size = 0 }, Enum.EasingStyle.Quad)
	tw.Completed:Once(function(playbackState)
		-- a panel or overlay opened meanwhile cancels this tween: keep the blur then
		if playbackState == Enum.PlaybackState.Completed and not current and not overlay then
			blur.Enabled = false
		end
	end)
	UISound.Play("close")
	if e and e.onClose then
		task.spawn(e.onClose)
	end
end

function Menu.Toggle(key: string)
	if current == key then
		Menu.Close()
	else
		Menu.Open(key)
	end
end

-- Shows `frame` (already parented to Menu.Layer(), ZIndex 41+) on top of everything with its own
-- backdrop; tapping the backdrop or Menu.HideOverlay() closes it and calls onClose.
function Menu.ShowOverlay(frame: GuiObject, onClose: (() -> ())?)
	if overlay and overlay ~= frame then
		Menu.HideOverlay()
	end
	overlay = frame
	overlayClose = onClose
	showBackdrop(overlayBackdrop, true, 0.35)
	if not current then
		blur.Enabled = true
		Anim.tween(blur, 0.3, { Size = 12 }, Enum.EasingStyle.Quad)
	end
	Anim.popIn(frame)
	UISound.Play("pop")
end

function Menu.HideOverlay()
	local frame = overlay
	if not frame then
		return
	end
	overlay = nil
	local cb = overlayClose
	overlayClose = nil
	Anim.popOut(frame)
	showBackdrop(overlayBackdrop, false, 0)
	if not current then
		local tw = Anim.tween(blur, 0.25, { Size = 0 }, Enum.EasingStyle.Quad)
		tw.Completed:Once(function(playbackState)
			if playbackState == Enum.PlaybackState.Completed and not current and not overlay then
				blur.Enabled = false
			end
		end)
	end
	if cb then
		task.spawn(cb)
	end
end

return Menu
