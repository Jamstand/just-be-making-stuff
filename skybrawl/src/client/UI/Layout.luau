--[[
    Screen layout for the menus (menus design 5.4). One canvas = the device
    safe area (ScreenGuis with ScreenInsets DeviceSafeInsets); geometry is
    Scale fractions of it, taken from the 1920x1080 mockups. Text, strokes
    and paddings are design px at 1080p, turned into real px by Layout.px:
    n * safeHeight / 1080, and 1.6x that on phones (a safe area under 500 px
    tall or 900 px wide), so phone text stays readable.

    Roblox caps TextSize (and TextScaled) at 100, so bindText is the only
    way to size text: up to 100 px it sets TextSize; above that it sets
    TextSize = 100 plus a UIScale named "TextFit" (Scale = px / 100) and
    divides the label's Size by that scale, so it keeps its design size on
    screen. A UIScale scales around the element's AnchorPoint, so the label
    stays where it was placed. Bound labels, strokes, paddings, sizes and
    bindApply callbacks are re-applied when the safe area changes. They are
    held in strong tables (a weak Instance key can lose its entry while the
    Instance lives on, when no script holds its userdata) and dropped when
    the object is destroyed (Destroying); something only unparented stays
    bound but is skipped while it has no parent.

    The Roblox top bar overlaps DeviceSafeInsets canvases: clearTop pushes
    an element that would sit under one of its two reserved boxes (from
    GuiService.TopbarInset) down below it, again whenever the viewport or
    the top bar changes. Nothing interactive may sit in those boxes.

    Coordinates: init makes two invisible probe ScreenGuis, one full-screen
    (ScreenInsets None) and one safe-area (DeviceSafeInsets). The safe one's
    AbsoluteSize is the canvas size; the full one's Origin frame tells where
    screen pixel (0, 0) is in AbsolutePosition space, so the top bar boxes
    (screen pixels) can be moved into any canvas's coordinates whatever the
    engine's GuiInset offset is. [Studio check: TopbarInset is in screen
    pixels from the top-left corner of the window.]

    Layout.screenGui makes every new ScreenGui; it sets only ScreenInsets
    and never writes IgnoreGuiInset (writing that legacy property resets
    ScreenInsets).
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = require(Shared.Util)

local Layout = {}

Layout.Changed = Util.Signal.new() -- (mode)
-- Engine behaviour: a UIScale also scales the UIStroke thickness of what it scales, so bindStroke divides by the
-- label's TextFit scale. [Studio check: flip this if a UIScale leaves UIStroke thickness alone.]
Layout.STROKE_FOLLOWS_UISCALE = true

local PHONE_TEXT = 1.6
Layout.PHONE_TEXT = PHONE_TEXT -- how much bigger design px are on phones
local TOP_GAP = 8 -- design px between the top bar and a pushed element

-- Pure helpers -------------------------------------------------------------

-- Phone when the safe area is under 500 px tall or 900 px wide.
function Layout.modeFor(size)
	if size.Y < 500 or size.X < 900 then
		return "Phone"
	end
	return "Wide"
end

-- Design px (at 1080p) -> px for a safe area `height` tall; text and strokes are 1.6x bigger on phones.
function Layout.pxFor(n, height, mode)
	return math.floor(n * height / 1080 * (if mode == "Phone" then PHONE_TEXT else 1) + 0.5)
end

-- (TextSize, scale): Roblox caps TextSize at 100, so bigger text is TextSize 100 scaled up.
function Layout.textFit(px)
	if px <= 100 then
		return px, 1
	end
	return 100, px / 100
end

-- How far down `rect` ({ x, y, w, h }) must move so its top edge clears every box it overlaps, plus `gap`.
function Layout.pushFor(rect, boxes, gap)
	local push = 0
	for _, box in boxes do
		local overlaps = box.w > 0
			and box.h > 0
			and rect.x < box.x + box.w
			and rect.x + rect.w > box.x
			and rect.y < box.y + box.h
			and rect.y + rect.h > box.y
		if overlaps then
			push = math.max(push, box.y + box.h + gap - rect.y)
		end
	end
	return push
end

-- A rect from the 844x390 phone mockup (insets left 47, right 47, bottom 21) as fractions of the safe area.
function Layout.phoneRect(x, y, w, h)
	return (x - 47) / 750, y / 369, w / 750, h / 369
end

-- Live layout ----------------------------------------------------------------

local safeSize = Vector2.new(1920, 1080) -- until init measures the real safe area
local mode = "Wide"
local fullOrigin = nil -- probe frame at screen (0, 0) in a ScreenInsets.None gui
local safeProbe = nil

-- Strong tables, cleared on Destroying (track).
local texts = {} -- [label] = { size, design: UDim2, applied: UDim2?, watch }
local strokes = {} -- [UIStroke] = thickness
local paddings = {} -- [UIPadding] = { x, y }
local boxes = {} -- [GuiObject] = { w, h? } (bindPxSize)
local hooks = {} -- [Instance] = { fn } (bindApply)
local cleared = {} -- [GuiObject] = { base: UDim2, conns } (clearTop; has its own Destroying cleanup)
local tracked = {} -- [Instance] = true once its Destroying hook is connected

function Layout.mode()
	return mode
end

function Layout.px(n)
	return Layout.pxFor(n, safeSize.Y, mode)
end

-- Drops `obj` from every table when it (or an ancestor) is destroyed.
local function track(obj)
	if tracked[obj] then
		return
	end
	tracked[obj] = true
	obj.Destroying:Connect(function()
		tracked[obj] = nil
		texts[obj] = nil
		strokes[obj] = nil
		paddings[obj] = nil
		boxes[obj] = nil
		hooks[obj] = nil
	end)
end

-- The label's TextFit scale (1 without one).
local function fitScale(obj)
	local fit = obj and obj:FindFirstChild("TextFit")
	return if fit and fit:IsA("UIScale") then fit.Scale else 1
end

local function divide(size, scale)
	return UDim2.new(size.X.Scale / scale, size.X.Offset / scale, size.Y.Scale / scale, size.Y.Offset / scale)
end

local applyStroke

local function applyText(obj, entry)
	if not entry.applied then
		-- no TextFit scale is applied, so the label's Size is its design size
		entry.design = obj.Size
	end
	local textSize, scale = Layout.textFit(Layout.px(entry.size))
	obj.TextSize = textSize
	local fit = obj:FindFirstChild("TextFit")
	if scale > 1 then
		if not (fit and fit:IsA("UIScale")) then
			fit = Instance.new("UIScale")
			fit.Name = "TextFit"
			fit.Parent = obj
		end
		fit.Scale = scale
		entry.applied = divide(entry.design, scale)
		if not entry.watch then
			-- someone else resizing the label sets its new design size
			entry.watch = obj:GetPropertyChangedSignal("Size"):Connect(function()
				if entry.applied and obj.Size ~= entry.applied then
					entry.design = obj.Size
					applyText(obj, entry)
				end
			end)
		end
		obj.Size = entry.applied
	else
		if fit then
			fit:Destroy()
		end
		if entry.watch then
			entry.watch:Disconnect()
			entry.watch = nil
		end
		if entry.applied then
			obj.Size = entry.design
		end
		entry.applied = nil
	end
	for _, child in obj:GetChildren() do
		if strokes[child] then
			applyStroke(child, strokes[child])
		end
	end
end

function applyStroke(stroke, thickness)
	local px = Layout.px(thickness)
	if Layout.STROKE_FOLLOWS_UISCALE then
		px /= fitScale(stroke.Parent)
	end
	stroke.Thickness = px
end

local function applyPadding(padding, entry)
	local x, y = Layout.px(entry.x), Layout.px(entry.y)
	padding.PaddingLeft = UDim.new(0, x)
	padding.PaddingRight = UDim.new(0, x)
	padding.PaddingTop = UDim.new(0, y)
	padding.PaddingBottom = UDim.new(0, y)
end

local function applyBox(obj, entry)
	obj.Size = UDim2.fromOffset(Layout.px(entry.w), Layout.px(entry.h or entry.w))
end

--[[
    The only way to size text: `size` is design px at 1080p. Remembers the
    label's Size now as its design size (bind after setting Size; resize
    it later with Layout.setSize, or by setting Size, which is picked up).
]]
function Layout.bindText(obj, size)
	local entry = texts[obj]
	if entry then
		entry.size = size
	else
		entry = { size = size, design = obj.Size, applied = nil, watch = nil }
		texts[obj] = entry
		track(obj)
	end
	applyText(obj, entry)
end

-- Changes a bound label's design size (any other object: just its Size).
function Layout.setSize(obj, size)
	local entry = texts[obj]
	if not entry then
		obj.Size = size
		return
	end
	entry.design = size
	entry.applied = nil
	obj.Size = size
	applyText(obj, entry)
end

-- Thickness in design px; divided by the parent's TextFit scale when STROKE_FOLLOWS_UISCALE.
function Layout.bindStroke(stroke, thickness)
	strokes[stroke] = thickness
	track(stroke)
	applyStroke(stroke, thickness)
end

function Layout.bindPadding(padding, x, y)
	local entry = { x = x, y = y or x }
	paddings[padding] = entry
	track(padding)
	applyPadding(padding, entry)
end

-- A fixed size in design px (UDim2.fromOffset(px(w), px(h))), re-applied with the rest.
function Layout.bindPxSize(obj, w, h)
	local entry = { w = w, h = h }
	boxes[obj] = entry
	track(obj)
	applyBox(obj, entry)
end

--[[
    Runs fn() now and again whenever the safe area changes (while `obj` has
    a parent), for px-based values the other binds don't cover: a list
    layout's Padding, a bar's pixel width. Dropped when `obj` is destroyed.
]]
function Layout.bindApply(obj, fn)
	local list = hooks[obj]
	if not list then
		list = {}
		hooks[obj] = list
		track(obj)
	end
	table.insert(list, fn)
	fn()
end

-- A UIListLayout's Padding as design px, re-applied (Layout.bindApply).
function Layout.bindListPadding(list, n)
	Layout.bindApply(list, function()
		list.Padding = UDim.new(0, Layout.px(n))
	end)
end

-- Pixels the Roblox top bar reserves: the left and right button areas and the bar's height.
function Layout.topbar()
	local inset = GuiService.TopbarInset
	local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.zero
	return {
		left = math.max(0, inset.Min.X),
		right = math.max(0, viewport.X - inset.Max.X),
		height = math.max(0, inset.Max.Y),
	}
end

-- Screen pixel (0, 0) in AbsolutePosition space.
local function screenOrigin()
	return if fullOrigin then fullOrigin.AbsolutePosition else Vector2.zero
end

--[[
    The two boxes the Roblox top bar covers, in `canvas` coordinates (its
    AbsolutePosition subtracted): left = (0, 0) to (TopbarInset.Min.X,
    TopbarInset.Max.Y), right = (TopbarInset.Max.X, 0) to (viewport.X,
    TopbarInset.Max.Y).
]]
function Layout.reserved(canvas)
	local inset = GuiService.TopbarInset
	local camera = workspace.CurrentCamera
	local viewportX = if camera then camera.ViewportSize.X else 0
	local offset = canvas.AbsolutePosition - screenOrigin()
	local height = inset.Max.Y
	return {
		{ x = -offset.X, y = -offset.Y, w = inset.Min.X, h = height },
		{ x = inset.Max.X - offset.X, y = -offset.Y, w = math.max(0, viewportX - inset.Max.X), h = height },
	}
end

-- The element's rect at its base position, in its ScreenGui's coordinates (from its parent's geometry, so a
-- push already applied, or a layout pass that hasn't run yet, doesn't matter).
local function baseRect(obj, base, gui)
	local parent = obj.Parent
	if not parent or not (parent:IsA("GuiObject") or parent:IsA("LayerCollector")) then
		return nil
	end
	local parentPos = parent.AbsolutePosition - gui.AbsolutePosition
	local parentSize = parent.AbsoluteSize
	local size = obj.AbsoluteSize
	local x = parentPos.X + base.X.Scale * parentSize.X + base.X.Offset - obj.AnchorPoint.X * size.X
	local y = parentPos.Y + base.Y.Scale * parentSize.Y + base.Y.Offset - obj.AnchorPoint.Y * size.Y
	return { x = x, y = y, w = size.X, h = size.Y }
end

local function applyClear(obj, entry)
	local gui = obj:FindFirstAncestorWhichIsA("LayerCollector")
	local push = 0
	if gui then
		local rect = baseRect(obj, entry.base, gui)
		if rect and rect.w > 0 and rect.h > 0 then
			push = Layout.pushFor(rect, Layout.reserved(gui), Layout.px(TOP_GAP))
		end
	end
	obj.Position = entry.base + UDim2.fromOffset(0, push)
end

--[[
    Keeps `obj` out of the top bar's boxes: Position = basePosition, pushed
    down so its top edge sits px(8) below the bar when it would overlap a
    box. Re-applied on viewport and top bar changes and when the element or
    its parent moves or resizes. Call again to change the base position.
]]
function Layout.clearTop(obj, basePosition)
	local entry = cleared[obj]
	if entry then
		entry.base = basePosition
	else
		entry = { base = basePosition, conns = {} }
		cleared[obj] = entry
		local function reapply()
			if cleared[obj] == entry then
				applyClear(obj, entry)
			end
		end
		table.insert(entry.conns, obj:GetPropertyChangedSignal("AbsoluteSize"):Connect(reapply))
		table.insert(
			entry.conns,
			obj.AncestryChanged:Connect(function()
				if obj.Parent then
					task.defer(reapply)
				end
			end)
		)
		table.insert(
			entry.conns,
			obj.Destroying:Connect(function()
				for _, conn in entry.conns do
					conn:Disconnect()
				end
				cleared[obj] = nil
			end)
		)
	end
	applyClear(obj, entry)
	-- layout may not have run for a freshly built element yet
	task.defer(function()
		if cleared[obj] == entry and obj.Parent then
			applyClear(obj, entry)
		end
	end)
end

-- insets "Full" -> ScreenInsets None, "Safe" (default) -> DeviceSafeInsets. Never touches IgnoreGuiInset.
function Layout.screenGui(name, displayOrder, insets)
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.DisplayOrder = displayOrder
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.ScreenInsets = if insets == "Full" then Enum.ScreenInsets.None else Enum.ScreenInsets.DeviceSafeInsets
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	return gui
end

local function applyAll()
	for obj, entry in texts do
		if obj.Parent then
			applyText(obj, entry)
		end
	end
	for stroke, thickness in strokes do
		if stroke.Parent then
			applyStroke(stroke, thickness)
		end
	end
	for padding, entry in paddings do
		if padding.Parent then
			applyPadding(padding, entry)
		end
	end
	for obj, entry in boxes do
		if obj.Parent then
			applyBox(obj, entry)
		end
	end
	for obj, list in hooks do
		if obj.Parent then
			for _, fn in list do
				local ok, err = pcall(fn)
				if not ok then
					warn("[Layout] bindApply failed:", err)
				end
			end
		end
	end
	for obj, entry in cleared do
		if obj.Parent then
			applyClear(obj, entry)
		end
	end
end

local function measure()
	local size = safeProbe and safeProbe.AbsoluteSize or Vector2.zero
	if size.X <= 0 or size.Y <= 0 then
		local camera = workspace.CurrentCamera
		size = if camera then camera.ViewportSize else Vector2.new(1920, 1080)
	end
	if size.X < 50 or size.Y < 50 then
		-- not laid out yet (a fresh viewport can briefly be 1 x 1): keep the last size
		return
	end
	local oldMode = mode
	safeSize = size
	mode = Layout.modeFor(size)
	applyAll()
	if mode ~= oldMode then
		Layout.Changed:Fire(mode)
	end
end

function Layout.init()
	local full = Layout.screenGui("SkybrawlLayoutFull", -100, "Full")
	fullOrigin = Instance.new("Frame")
	fullOrigin.Name = "Origin"
	fullOrigin.BackgroundTransparency = 1
	fullOrigin.Size = UDim2.fromOffset(0, 0)
	fullOrigin.Parent = full
	safeProbe = Layout.screenGui("SkybrawlLayoutSafe", -100, "Safe")

	safeProbe:GetPropertyChangedSignal("AbsoluteSize"):Connect(measure)
	full:GetPropertyChangedSignal("AbsoluteSize"):Connect(measure)
	GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(function()
		for obj, entry in cleared do
			if obj.Parent then
				applyClear(obj, entry)
			end
		end
	end)
	measure()
	-- the probes get their sizes on the first layout pass
	task.defer(measure)
end

return Layout
