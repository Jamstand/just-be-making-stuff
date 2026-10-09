--[[
    Helpers shared by the menu screens (UI/Screens) and the panels they
    mount (menus design 3.8 / 5.8):

      Common.root(host, name)         the screen's root: the whole canvas, transparent
      Common.body(root, sizer, opts)  the content region; on phones a vertical ScrollingFrame holding a
                                      canvas sized in design px, so 1.6x text never overflows
      Common.sizer(root)              px heights (Layout.px) that follow the safe area
      Common.text(text, size, props)  a TextLabel sized through Layout.bindText (the only way to size text)
      Common.gradient / stroke / textStroke   fills and outlines (a gradient sets a white base colour)
      Common.focusable(btn, spec, fn) a plain button registered with Focus: one guarded handler for
                                      Confirm, clicks and taps, and its own focus highlight
      Common.linkTop(host, getTop)    the top row's Up -> the queue banner's CANCEL while queued (call the
                                      returned rewire() after every linkColumn / linkGrid, which clear it)
      Common.invoke(remote, ...)      a RemoteFunction call that never throws
      Common.bag()                    connections made in show() and dropped in hide()
      Common.tag / header / glyph / tierBadge   the UIKit builders inside a box of a given UDim2 size

    Geometry is in Scale (fractions of the canvas, from the 1920x1080
    mockups); only text, strokes, paddings and the phone canvas use px.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)

local Sound = require(script.Parent.Parent.Parent.Controllers.Sound)

local UIKit = require(script.Parent.Parent.UIKit)
local Focus = require(script.Parent.Parent.Focus)
local Layout = require(script.Parent.Parent.Layout)
local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Models = require(script.Parent.Models)

local T = UIKit.Theme
local make = UIKit.make

local Common = {}

-- Wide screen region (fractions of the canvas): x 0.03-0.97, y 0.20-0.86 (down to 0.95 without the party bar).
Common.REGION = { x0 = 0.03, y0 = 0.2, x1 = 0.97, y1 = 0.86 }
-- Phone: below the breadcrumb and title, above the party bar and hints.
Common.PHONE_REGION = { x0 = 0.02, y0 = 0.27, x1 = 0.98, y1 = 0.86 }

function Common.isPhone()
	return Layout.mode() == "Phone"
end

-- Requests ----------------------------------------------------------------------

-- InvokeServer that never throws: returns the server's two values, or false and a message.
function Common.invoke(remoteName, ...)
	local args = table.pack(...)
	local ok, a, b = pcall(function()
		return Net.get(remoteName):InvokeServer(table.unpack(args, 1, args.n))
	end)
	if not ok then
		warn("[Screens] " .. remoteName .. " failed:", a)
		return false, "Couldn't reach the server."
	end
	return a, b
end

-- Your party size and whether you may manage it (solo players and leaders).
function Common.partyInfo()
	return Models.partyInfo(ClientState.party, Players.LocalPlayer.UserId)
end

-- Connections -------------------------------------------------------------------

-- A bag of connections: add(connection) while shown, clear() on hide.
function Common.bag()
	local items = {}
	local bag = {}
	function bag.add(connection)
		table.insert(items, connection)
		return connection
	end
	function bag.clear()
		for _, connection in items do
			connection:Disconnect()
		end
		table.clear(items)
	end
	return bag
end

-- Layout ------------------------------------------------------------------------

-- The screen root: the whole canvas, transparent, parented to host.content.
function Common.root(host, name)
	return make("Frame", {
		Name = name,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = host.content,
	})
end

--[[
    Heights in design px (Layout.px) that follow the safe area: the root's
    AbsoluteSize changes whenever the canvas does. height(obj, px, x?) sets
    obj.Size = (x or full width, px(px)) now and after every change.
]]
function Common.sizer(root)
	local entries = setmetatable({}, { __mode = "k" })
	local sizer = {}
	local function apply(obj, entry)
		obj.Size = UDim2.new(entry.x, UDim.new(0, Layout.px(entry.px)))
	end
	function sizer.height(obj, px, x)
		local entry = { px = px, x = x or UDim.new(1, 0) }
		entries[obj] = entry
		apply(obj, entry)
		return obj
	end
	local watchers = {}
	-- fn() now and after every change (for px values that aren't a Size, like a grid's CellSize). Returns
	-- unwatch(): a body rebuilt on a layout change drops its old watcher with it.
	function sizer.watch(fn)
		table.insert(watchers, fn)
		fn()
		return function()
			local index = table.find(watchers, fn)
			if index then
				table.remove(watchers, index)
			end
		end
	end
	function sizer.refresh()
		for obj, entry in entries do
			if obj.Parent then
				apply(obj, entry)
			end
		end
		for _, fn in watchers do
			fn()
		end
	end
	-- deferred so Layout has re-read the safe area first
	local pending = false
	local function schedule()
		if pending then
			return
		end
		pending = true
		task.defer(function()
			pending = false
			sizer.refresh()
		end)
	end
	root:GetPropertyChangedSignal("AbsoluteSize"):Connect(schedule)
	Layout.Changed:Connect(schedule)
	return sizer
end

-- A plain Frame over the screen region (Common.REGION, or PHONE_REGION on phones) for screens that scroll inside.
function Common.region(root, opts)
	opts = opts or {}
	local region = if Common.isPhone() then opts.phoneRegion or Common.PHONE_REGION else opts.region or Common.REGION
	return make("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(region.x0, region.y0),
		Size = UDim2.fromScale(region.x1 - region.x0, region.y1 - region.y0),
		Parent = root,
	})
end

-- A vertical ScrollingFrame (rows sized in px, a UIListLayout with `gap` px between them).
function Common.list(parent, props, gap)
	local list = make("ScrollingFrame", {
		Name = "List",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = T.Dim,
		Selectable = false,
		Size = UDim2.fromScale(1, 1),
	})
	for key, value in props or {} do
		list[key] = value
	end
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Vertical,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, Layout.px(gap or 6)),
		Parent = list,
	})
	list.Parent = parent
	return list
end

--[[
    The content region of a screen. opts = { region?, phoneRegion?, phoneHeight?, scroll? }:
      Wide: a Frame over `region` (default Common.REGION); returns (frame, nil).
      Phone, or opts.scroll: a vertical ScrollingFrame over the region holding a canvas
        `phoneHeight` design px tall (default: the region's own height at 1080p, which Layout.px makes 1.6x
        taller on phones). Lay children out in Scale of the returned canvas; returns (canvas, scroller).
]]
function Common.body(root, sizer, opts)
	opts = opts or {}
	local phone = Common.isPhone()
	local region = if phone then opts.phoneRegion or Common.PHONE_REGION else opts.region or Common.REGION
	local position = UDim2.fromScale(region.x0, region.y0)
	local size = UDim2.fromScale(region.x1 - region.x0, region.y1 - region.y0)
	if not phone and not opts.scroll then
		local frame = make("Frame", {
			Name = "Body",
			BackgroundTransparency = 1,
			Position = position,
			Size = size,
			Parent = root,
		})
		return frame, nil
	end
	local scroller = make("ScrollingFrame", {
		Name = "Body",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = position,
		Size = size,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = T.Dim,
		Selectable = false,
		Parent = root,
	})
	local canvas = make("Frame", {
		Name = "Canvas",
		BackgroundTransparency = 1,
		Parent = scroller,
	})
	sizer.height(canvas, opts.phoneHeight or math.floor((region.y1 - region.y0) * 1080 + 0.5))
	return canvas, scroller
end

--[[
    Calls fn() when the layout mode flips between Wide and Phone (the screen
    rebuilds its body). Checked after Layout.Changed and canvas resizes,
    deferred so Layout has updated first.
]]
function Common.onModeChange(root, fn)
	local phone = Common.isPhone()
	local function check()
		task.defer(function()
			if Common.isPhone() ~= phone then
				phone = Common.isPhone()
				fn()
			end
		end)
	end
	Layout.Changed:Connect(check)
	root:GetPropertyChangedSignal("AbsoluteSize"):Connect(check)
end

--[[
    Scrolls `scroller` by `px` design px (Up/Down on read-only screens).
    Returns true when it moved, false when it was already at that end (so
    Focus can move on, e.g. Up to the queue banner's CANCEL).
]]
function Common.scrollBy(scroller, px)
	if not scroller then
		return false
	end
	local maxY = math.max(0, scroller.AbsoluteCanvasSize.Y - scroller.AbsoluteWindowSize.Y)
	local current = scroller.CanvasPosition.Y
	local y = math.clamp(current + Layout.px(px), 0, maxY)
	if math.abs(y - current) < 0.5 then
		return false
	end
	scroller.CanvasPosition = Vector2.new(scroller.CanvasPosition.X, y)
	return true
end

-- Text ----------------------------------------------------------------------------

--[[
    A TextLabel sized through Layout.bindText (`size` in design px at 1080p).
    props are applied first (Size included: bindText remembers it as the
    design size). Defaults: body font, white, left aligned, wrapped, full size.
]]
function Common.text(text, size, props)
	local label = make("TextLabel", {
		BackgroundTransparency = 1,
		Text = text or "",
		Font = T.BodyFont,
		TextColor3 = T.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		TextWrapped = true,
		Size = UDim2.fromScale(1, 1),
	})
	local parent = nil
	for key, value in props or {} do
		if key == "Parent" then
			parent = value
		else
			label[key] = value
		end
	end
	Layout.bindText(label, size)
	if parent then
		label.Parent = parent
	end
	return label
end

-- A plain filled Frame (sharp corners, the menus' look).
function Common.fill(color, props)
	local frame = make("Frame", {
		BackgroundColor3 = color,
		BorderSizePixel = 0,
	})
	local parent = nil
	for key, value in props or {} do
		if key == "Parent" then
			parent = value
		else
			frame[key] = value
		end
	end
	if parent then
		frame.Parent = parent
	end
	return frame
end

--[[
    A vertical UIGradient (top -> bottom) on `obj`. A UIGradient's colours
    multiply the object's own BackgroundColor3, so the background is set to
    white and the fill shows exactly `top` -> `bottom`.
]]
function Common.gradient(obj, top, bottom, rotation)
	if obj:IsA("GuiObject") then
		obj.BackgroundColor3 = Color3.new(1, 1, 1)
	end
	return make("UIGradient", {
		Color = ColorSequence.new(top, bottom),
		Rotation = rotation or 90,
		Parent = obj,
	})
end

-- A UIStroke around `obj`'s box (Border mode), bound through Layout.bindStroke.
function Common.stroke(obj, color, thickness, transparency)
	local stroke = make("UIStroke", {
		Color = color,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		LineJoinMode = Enum.LineJoinMode.Miter,
		Parent = obj,
	})
	Layout.bindStroke(stroke, thickness)
	return stroke
end

-- An outline around the letters of a TextLabel (Contextual mode: Border would draw the label's box).
function Common.textStroke(label, color, thickness)
	local stroke = make("UIStroke", {
		Color = color,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		LineJoinMode = Enum.LineJoinMode.Round,
		Parent = label,
	})
	Layout.bindStroke(stroke, thickness)
	return stroke
end

-- A UIPadding bound through Layout.bindPadding.
function Common.padding(obj, x, y)
	local padding = make("UIPadding", { Parent = obj })
	Layout.bindPadding(padding, x, y)
	return padding
end

-- A cut-corner panel (UIKit.cutPanel) whose body is padded away from the border. Returns panel, body.
function Common.cutPanel(opts, padX, padY)
	local panel, body = UIKit.cutPanel(opts)
	Common.padding(body, padX or 18, padY or 12)
	return panel, body
end

-- A slanted button whose label can change later (Common.setButtonText).
function Common.slantButton(text, opts, onClick)
	local button = UIKit.slantButton(text, opts, onClick)
	button:SetAttribute("ButtonText", text)
	return button
end

local function insideGlyph(obj, stop)
	local node = obj.Parent
	while node and node ~= stop do
		if node.Name == "Glyph" then
			return true
		end
		node = node.Parent
	end
	return false
end

--[[
    Changes a button's label. The UIKit builders draw their label wherever
    they like (the TextButton's Text or an inner TextLabel), so every
    TextLabel showing the old label (outside input glyphs) is updated.
]]
function Common.setButtonText(button, text)
	local old = button:GetAttribute("ButtonText")
	if old == text then
		return
	end
	button:SetAttribute("ButtonText", text)
	if button.Text == old then
		button.Text = text
	end
	for _, obj in button:GetDescendants() do
		if (obj:IsA("TextLabel") or obj:IsA("TextButton")) and obj.Text == old and not insideGlyph(obj, button) then
			obj.Text = text
		end
	end
end

--[[
    A boxed builder: UIKit.header / tag / glyph / tierBadge take `size` as a
    text or glyph size (a number), which clashes with the common UDim2
    `size`, so they are placed inside a box of the wanted size instead and
    left to fill (or auto-size inside) it.
]]
local function box(name, opts)
	return make("Frame", {
		Name = opts.name or name,
		BackgroundTransparency = 1,
		Position = opts.position or UDim2.new(),
		Size = opts.size or UDim2.fromScale(0.3, 0.05),
		AnchorPoint = opts.anchor or Vector2.zero,
		ZIndex = opts.zIndex or 1,
		LayoutOrder = opts.layoutOrder or 0,
		Parent = opts.parent,
	})
end

-- A section header (UIKit.header: red bar + Bangers) inside a box. opts = { accent? } & Common.
function Common.header(text, opts)
	local frame = box("Header", opts)
	UIKit.header(text, { accent = opts.accent, parent = frame, zIndex = opts.zIndex })
	return frame
end

-- An input glyph (UIKit.glyph) inside a square box.
function Common.glyph(action, opts)
	local frame = box("Glyph", opts)
	make("UIAspectRatioConstraint", { AspectRatio = 1, Parent = frame })
	UIKit.glyph(action, { parent = frame, zIndex = opts.zIndex })
	return frame
end

-- A small chip (UIKit.tag) inside a box of the given size (the tag fills or auto-sizes inside it).
function Common.tag(text, opts)
	local frame = box("Tag", opts)
	UIKit.tag(text, { fill = opts.fill, textColor = opts.textColor, parent = frame, zIndex = opts.zIndex })
	frame:SetAttribute("TagState", text .. "|" .. tostring(opts.fill) .. "|" .. tostring(opts.textColor))
	return frame
end

-- Rebuilds a tag's text and colours (UIKit.tag has no setter); nothing happens when they are unchanged.
function Common.setTag(frame, text, opts)
	opts = opts or {}
	local signature = text .. "|" .. tostring(opts.fill) .. "|" .. tostring(opts.textColor)
	if frame:GetAttribute("TagState") == signature then
		return
	end
	frame:SetAttribute("TagState", signature)
	for _, child in frame:GetChildren() do
		child:Destroy()
	end
	UIKit.tag(text, { fill = opts.fill, textColor = opts.textColor, parent = frame, zIndex = frame.ZIndex })
end

-- A tier badge (UIKit.tierBadge) inside a square box.
function Common.tierBadge(tierName, opts)
	local frame = box("TierBadge", opts)
	make("UIAspectRatioConstraint", { AspectRatio = 1, Parent = frame })
	UIKit.tierBadge(tierName, { parent = frame, zIndex = opts.zIndex })
	frame:SetAttribute("Tier", tierName)
	return frame
end

-- Swaps a tier badge for another tier (only when it changed).
function Common.setTierBadge(frame, tierName)
	if frame:GetAttribute("Tier") == tierName then
		return
	end
	for _, child in frame:GetChildren() do
		if not child:IsA("UIAspectRatioConstraint") then
			child:Destroy()
		end
	end
	UIKit.tierBadge(tierName, { parent = frame, zIndex = frame.ZIndex })
	frame:SetAttribute("Tier", tierName)
end

-- Headshots ---------------------------------------------------------------------

local headshots = {}

-- Fills `image` with the user's headshot (fetched once per user, in the background).
function Common.headshot(image, userId)
	image:SetAttribute("HeadshotUser", userId)
	if headshots[userId] then
		image.Image = headshots[userId]
		return
	end
	image.Image = ""
	if type(userId) ~= "number" or userId <= 0 then
		return
	end
	task.spawn(function()
		local ok, content = pcall(function()
			return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
		end)
		if ok and type(content) == "string" then
			headshots[userId] = content
			if image.Parent and image:GetAttribute("HeadshotUser") == userId then
				image.Image = content
			end
		end
	end)
end

-- Focus -----------------------------------------------------------------------------

local highlights = setmetatable({}, { __mode = "k" }) -- [ring Frame] = focused

local function renderHighlight(ring)
	ring.Visible = highlights[ring] == true and Focus.mode() ~= "Touch"
end

Focus.ModeChanged:Connect(function()
	for ring in highlights do
		renderHighlight(ring)
	end
end)

--[[
    The focus highlight for a plain row or card (menus design 5.3, generic
    highlight): a white 3 px outline, a red 6 px bar on the left and a
    UIScale of 1.04, drawn on an overlay so it never fights the object's own
    strokes. Hidden on touch. Returns setFocused(on).

    A UIStroke draws outside its frame, so the overlay is inset by the
    stroke's thickness: the outline stays inside the object and survives
    clipping parents (Legends tiles, scrolling lists). Inside a
    ScrollingFrame the 1.04 grow is skipped, since the list would clip the
    grown edges (full-width rows).
]]
function Common.highlight(obj)
	local ring = make("Frame", {
		Name = "FocusRing",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = obj.ZIndex + 5,
		Visible = false,
		Parent = obj,
	})
	local stroke = Common.stroke(ring, Color3.new(1, 1, 1), 3)
	local bar = Common.fill(T.Red, {
		Name = "Bar",
		ZIndex = obj.ZIndex + 5,
		Parent = ring,
	})
	highlights[ring] = false
	local function place()
		local t = math.ceil(stroke.Thickness)
		ring.Position = UDim2.fromOffset(t, t)
		ring.Size = UDim2.new(1, -2 * t, 1, -2 * t)
		-- the bar covers the object's whole left edge (the ring is inset)
		bar.Position = UDim2.fromOffset(-t, -t)
		bar.Size = UDim2.new(0, math.max(2, Layout.px(6)), 1, 2 * t)
	end
	place()
	return function(on)
		highlights[ring] = on == true
		place()
		renderHighlight(ring)
		local scale = obj:FindFirstChild("FocusGrow")
		local grow = on == true and Focus.mode() ~= "Touch" and not obj:FindFirstAncestorWhichIsA("ScrollingFrame")
		if grow and not scale and not obj:FindFirstChildWhichIsA("UIScale") then
			make("UIScale", { Name = "FocusGrow", Scale = 1.04, Parent = obj })
		elseif not grow and scale then
			scale:Destroy()
		end
	end
end

--[[
    Registers a plain GuiButton (one we build, not a UIKit builder) with
    Focus. spec is a Focus spec (key, actions, onUp/onDown/onLeft/onRight,
    onFocus...). onActivate (optional) runs on Confirm, clicks and taps
    through one handler that ignores presses while a previous one is still
    running (requests wait on the server) or while the button is disabled.
    Adds the focus highlight unless spec.highlight == false.
]]
function Common.focusable(button, spec, onActivate)
	spec = spec or {}
	if onActivate then
		local running = false
		local function run()
			if running or button:GetAttribute("Disabled") then
				return
			end
			running = true
			local ok, err = pcall(onActivate, button)
			running = false
			if not ok then
				warn("[Screens] activate handler failed:", err)
			end
		end
		button.Activated:Connect(function()
			-- (Confirm presses come through Focus, which plays its own sound)
			Sound.play("MenuConfirm", 0.5)
			run()
		end)
		spec.onActivate = run
	end
	if spec.key then
		button:SetAttribute("FocusKey", spec.key)
	end
	local setFocused = if spec.highlight == false then nil else Common.highlight(button)
	local onFocus = spec.onFocus
	spec.onFocus = function(on)
		if setFocused then
			setFocused(on)
		end
		if onFocus then
			onFocus(on)
		end
	end
	spec.highlight = nil
	Focus.register(button, spec)
	return button
end

--[[
    While you are queued, links each object getTop() returns Up to the queue
    banner's CANCEL (host.cancelButton()); when the search ends the links
    are cleared. Returns rewire() to call after the top row was rebuilt.
]]
function Common.linkTop(host, getTop)
	local function rewire()
		local cancel = if ClientState.queue then host.cancelButton() else nil
		for _, obj in getTop() do
			if obj and obj.Parent then
				Focus.link(obj, "Up", cancel)
			end
		end
	end
	ClientState.QueueChanged:Connect(function()
		-- after the banner has shown or hidden its CANCEL
		task.defer(rewire)
	end)
	return rewire
end

return Common
