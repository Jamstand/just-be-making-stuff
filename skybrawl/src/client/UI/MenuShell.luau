--[[
    The menu shell (menus design 5.1): the painted backdrop, the screen
    stack, the chrome and phase handling.

    ScreenGuis: SkybrawlMenuBack (DisplayOrder 2, full bleed: sky layers,
    dim, the main menu's slab) and SkybrawlMenu (5, DeviceSafeInsets: the
    screens and the chrome). Both show only in phase "Menu".

    Backdrop: the map Config.Menu.BackdropMap (a random painted map for
    "Random", picked once per session) as full-bleed image layers (Sky,
    Landmarks, Haze from SkyBackdrop.images), or, without a Sky image, its
    Sky.Top -> Sky.Bottom gradient with soft cloud blobs; then a black dim
    and a fade at the bottom. buildBackdrop is also the opaque back of the
    results screen (C3), tinted by the result.

    Stack: MainMenu at the root; push(id) builds Screens/<id> once (cached),
    hides the current top (hide(), its Focus layer popped) and shows the new
    one (show(params), a Focus layer named after the screen whose roots are
    the screen, the queue banner and, when it shows, the party bar). Focus
    remembers each layer's last focused object by name, so coming back
    lands on the button the player came from. back() asks the screen first
    (its back() returns true when it closed a sub-view), else pops.
    ClientState.OpenScreen(id, params) pops to the root and pushes.

    Chrome: the player card, queue banner, party bar and hint bar, plus the
    breadcrumb and big title on every screen but the main menu. A screen's
    `chrome` table turns the card or the party bar off and moves the hints
    to the left; its hints() fill the bar (every hint bar has a tappable
    BACK).

    Phase: leaving "Menu" hides the top screen (views destroyed), pops its
    layer and releases a captured TextBox; the stack is kept, so after a
    match the player is back where they were. Coming back calls the top
    screen's show(lastParams) again. The camera is parked (Scriptable,
    looking at empty sky) whenever the phase isn't "Match", including after
    MatchClient's cleanup reset it to Custom.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Maps = require(Shared.Maps)

local Client = script.Parent.Parent
local ClientState = require(Client:WaitForChild("ClientState"))
local SkyBackdrop = require(Client:WaitForChild("Controllers"):WaitForChild("SkyBackdrop"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))
local Focus = require(script.Parent:WaitForChild("Focus"))
local Layout = require(script.Parent:WaitForChild("Layout"))
local MenuModels = require(script.Parent:WaitForChild("MenuModels"))
local PlayerCard = require(script.Parent:WaitForChild("PlayerCard"))
local QueueBanner = require(script.Parent:WaitForChild("QueueBanner"))
local PartyBar = require(script.Parent:WaitForChild("PartyBar"))
local MainMenu = require(script.Parent:WaitForChild("MainMenu"))

local T = UIKit.Theme
local make = UIKit.make

local MenuShell = {}

local SKY_LAYERS = { "Sky", "Landmarks", "Haze" }
local TITLE_HEIGHT = 0.095
local CLOUDS = {
	{ 0.06, 0.74, 0.3 },
	{ 0.24, 0.8, 0.26 },
	{ 0.43, 0.72, 0.34 },
	{ 0.6, 0.82, 0.28 },
	{ 0.78, 0.75, 0.32 },
	{ 0.95, 0.8, 0.26 },
}

local backdropMap = nil

-- The session's backdrop map (picked once).
function MenuShell.backdropMap()
	if not backdropMap then
		backdropMap = MenuModels.backdropMap(Config.Menu.BackdropMap, Random.new())
	end
	return backdropMap
end

local function fullFrame(name, parent, zIndex)
	return make("Frame", {
		Name = name,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = zIndex or 1,
		Parent = parent,
	})
end

--[[
    The menu sky alone: the map's painted layers (full-bleed ImageLabels,
    ScaleType Crop) or its gradient with cloud blobs, every layer at
    `brightness` (ImageColor3 / colours scaled). Returns the frame.
]]
function MenuShell.buildSky(parent, brightness)
	brightness = brightness or 1
	local mapId = MenuShell.backdropMap()
	local frame = fullFrame("Sky", parent)
	frame.ClipsDescendants = true
	local images = SkyBackdrop.images(mapId)
	local dimmed = Color3.new(brightness, brightness, brightness)
	if UIKit.assetId(images.Sky) ~= "" then
		for order, layer in SKY_LAYERS do
			local id = UIKit.assetId(images[layer])
			if id ~= "" then
				make("ImageLabel", {
					Name = layer,
					BackgroundTransparency = 1,
					Image = id,
					ImageColor3 = dimmed,
					ScaleType = Enum.ScaleType.Crop,
					Size = UDim2.fromScale(1, 1),
					ZIndex = order,
					Parent = frame,
				})
			end
		end
		return frame
	end
	-- no painted sky: the map's gradient and a few soft clouds
	local map = Maps.get(mapId) or Maps.get("SkyShip")
	local sky = map.Sky
	local gradient = fullFrame("Gradient", frame, 1)
	gradient.BackgroundTransparency = 0
	gradient.BackgroundColor3 = dimmed
	make("UIGradient", {
		Color = ColorSequence.new(sky.Top, sky.Bottom),
		Rotation = 90,
		Parent = gradient,
	})
	for i, cloud in CLOUDS do
		local blob = make("Frame", {
			Name = "Cloud" .. i,
			BackgroundColor3 = dimmed,
			BackgroundTransparency = 0.85,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(cloud[1], cloud[2]),
			Size = UDim2.fromScale(cloud[3], cloud[3] * 0.32),
			ZIndex = 2,
			Parent = frame,
		})
		make("UICorner", { CornerRadius = UDim.new(1, 0), Parent = blob })
	end
	return frame
end

--[[
    The menu sky layers (or gradient fallback) plus the dim layer and the
    bottom fade, optionally tinted (results: gold / red / grey). Returns
    the backdrop frame.
]]
function MenuShell.buildBackdrop(parent, tint)
	local frame = fullFrame("Backdrop", parent)
	frame.BackgroundTransparency = 0
	frame.BackgroundColor3 = T.Backdrop
	frame.ClipsDescendants = true
	MenuShell.buildSky(frame, 1).ZIndex = 1
	if tint then
		local tinted = fullFrame("Tint", frame, 2)
		tinted.BackgroundTransparency = 0.72
		tinted.BackgroundColor3 = tint
	end
	local dim = fullFrame("Dim", frame, 3)
	dim.BackgroundTransparency = 0.45
	dim.BackgroundColor3 = Color3.new(0, 0, 0)
	local fade = make("Frame", {
		Name = "BottomFade",
		BackgroundColor3 = Color3.new(0, 0, 0),
		BorderSizePixel = 0,
		Position = UDim2.fromScale(0, 0.75),
		Size = UDim2.fromScale(1, 0.25),
		ZIndex = 4,
		Parent = frame,
	})
	make("UIGradient", {
		Rotation = 90,
		Transparency = NumberSequence.new(1, 0.2),
		Parent = fade,
	})
	return frame
end

-- Shell ------------------------------------------------------------------------------

local backGui, gui = nil, nil
local backCanvas, canvas, content = nil, nil, nil
local stack = {} -- entries, root first
local entries = {} -- [id] = { id, module, inst, params, layer, shown }
local active = false
local host = nil
local card, banner, party = nil, nil, nil
local hintBar, setHints = nil, nil
local breadcrumb, title, underline = nil, nil, nil

local function parkCamera()
	local camera = workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame = CFrame.lookAt(Vector3.new(0, 4000, 0), Vector3.new(0, 4100, 1))
	end
end

local function call(what, fn, ...)
	if not fn then
		return nil
	end
	local ok, result = pcall(fn, ...)
	if not ok then
		warn("[MenuShell] " .. what .. " failed:", result)
		return nil
	end
	return result
end

local function top()
	return stack[#stack]
end

local function chromeOf(entry)
	return (entry and entry.inst and entry.inst.chrome) or {}
end

local function showsPartyBar(entry)
	return entry.id == "MainMenu" or chromeOf(entry).partyBar ~= false
end

local function rootsFor(entry)
	local roots = { entry.inst.root, banner.root }
	if showsPartyBar(entry) then
		table.insert(roots, party.root)
	end
	local extra = call("extraRoots", entry.inst.extraRoots)
	for _, root in extra or {} do
		table.insert(roots, root)
	end
	return roots
end

local back -- forward declaration (the layers' onBack)

local function hintsFor(entry)
	local items = call("hints", entry.inst.hints) or {}
	local out, hasBack = {}, false
	for _, item in items do
		table.insert(out, item)
		if item.action == "Back" then
			hasBack = true
		end
	end
	if entry.id ~= "MainMenu" and not hasBack then
		table.insert(out, { action = "Back", label = "BACK" })
	end
	for i, item in out do
		if item.action == "Back" and not item.onClick then
			out[i] = { action = item.action, label = item.label, onClick = back }
		end
	end
	return out
end

local function applyChrome()
	local entry = top()
	if not entry then
		return
	end
	local chrome = chromeOf(entry)
	card.setVisible(chrome.playerCard ~= false)
	party.setVisible(showsPartyBar(entry))
	banner.setRoot(entry.id == "MainMenu")
	local left = chrome.hints == "Left"
	-- on phones the bar (44 px tall there, for touch) sits on the safe area's bottom edge
	local phone = Layout.mode() == "Phone"
	local anchorY, y = if phone then 1 else 0.5, if phone then 1 else 0.946
	hintBar.AnchorPoint = Vector2.new(if left then 0 else 1, anchorY)
	hintBar.Position = UDim2.fromScale(if left then 0.02 else 0.98, y)
	local list = hintBar:FindFirstChildOfClass("UIListLayout")
	if list then
		list.HorizontalAlignment = if left then Enum.HorizontalAlignment.Left else Enum.HorizontalAlignment.Right
	end
	setHints(hintsFor(entry))
	local isRoot = entry.id == "MainMenu"
	-- the phone main menu has no hint bar (mockup i): its legend's nameplate sits there
	hintBar.Visible = not (isRoot and Layout.mode() == "Phone")
	breadcrumb.Visible = not isRoot and Layout.mode() ~= "Phone"
	title.Visible = not isRoot
	underline.Visible = not isRoot
	if not isRoot then
		title.Text = entry.module.title or entry.id
		Layout.bindText(title, if Layout.mode() == "Phone" then 70 else 110)
	end
end

local function showEntry(entry)
	if entry.shown then
		return
	end
	entry.shown = true
	entry.inst.root.Visible = true
	call(entry.id .. ".show", entry.inst.show, entry.params)
	entry.layer = Focus.pushLayer({
		name = entry.id,
		roots = rootsFor(entry),
		defaultFocus = entry.inst.defaultFocus,
		onBack = back,
		actions = entry.inst.actions,
		onDirection = entry.inst.onDirection,
	})
	applyChrome()
end

local function hideEntry(entry)
	if not entry.shown then
		return
	end
	entry.shown = false
	if entry.layer then
		Focus.popLayer(entry.layer)
		entry.layer = nil
	end
	call(entry.id .. ".hide", entry.inst.hide)
	entry.inst.root.Visible = false
end

local function entryFor(id)
	if entries[id] then
		return entries[id]
	end
	local screens = script.Parent:FindFirstChild("Screens")
	local moduleScript = screens and screens:FindFirstChild(id)
	if not moduleScript then
		warn("[MenuShell] unknown screen", id)
		return nil
	end
	local ok, module = pcall(require, moduleScript)
	if not ok or type(module) ~= "table" or type(module.build) ~= "function" then
		warn("[MenuShell] can't load screen", id, module)
		return nil
	end
	local built, inst = pcall(module.build, host)
	if not built or type(inst) ~= "table" or not inst.root then
		warn("[MenuShell] can't build screen", id, inst)
		return nil
	end
	inst.root.Visible = false
	local entry = { id = id, module = module, inst = inst, params = nil, layer = nil, shown = false }
	entries[id] = entry
	return entry
end

local function push(id, params)
	local entry = entryFor(id)
	if not entry then
		return
	end
	local current = top()
	if current == entry then
		entry.params = params
		if active then
			hideEntry(entry)
			showEntry(entry)
		end
		return
	end
	local index = table.find(stack, entry)
	if index then
		table.remove(stack, index)
	end
	if current and active then
		hideEntry(current)
	end
	entry.params = params
	table.insert(stack, entry)
	if active then
		showEntry(entry)
	end
end

local function pop()
	if #stack <= 1 then
		return
	end
	local entry = table.remove(stack)
	if active then
		hideEntry(entry)
		showEntry(top())
	end
end

local function replace(id, params)
	if #stack > 1 then
		local entry = table.remove(stack)
		if active then
			hideEntry(entry)
		end
	end
	push(id, params)
	if active and not top().shown then
		showEntry(top())
	end
end

-- Pops every screen above the main menu (without showing the ones in between).
local function popToRoot()
	while #stack > 1 do
		local entry = table.remove(stack)
		if active then
			hideEntry(entry)
		end
	end
end

local function openScreen(id, params)
	popToRoot()
	if id == "MainMenu" or id == nil then
		if active then
			showEntry(top())
		end
		return
	end
	if active and not entries[id] then
		-- build it first, so the main menu doesn't flash while the screen is made
		entryFor(id)
	end
	push(id, params)
	if active and not top().shown then
		showEntry(top())
	end
end

function back()
	local entry = top()
	if not entry then
		return
	end
	if call(entry.id .. ".back", entry.inst.back) == true then
		return
	end
	pop()
end

local function refresh()
	local entry = top()
	if not entry or not entry.shown then
		return
	end
	if entry.layer then
		Focus.setRoots(entry.layer, rootsFor(entry))
	end
	applyChrome()
end

local function onPhase(phase)
	local nowActive = phase == "Menu"
	gui.Enabled = nowActive
	backGui.Enabled = nowActive
	if phase ~= "Match" then
		parkCamera()
	end
	if nowActive == active then
		return
	end
	active = nowActive
	local entry = top()
	if active then
		if entry then
			showEntry(entry)
		end
	else
		if entry then
			hideEntry(entry)
		end
		local box = UserInputService:GetFocusedTextBox()
		if box then
			box:ReleaseFocus()
		end
	end
end

local function buildTitle()
	breadcrumb = make("TextLabel", {
		Name = "Breadcrumb",
		BackgroundTransparency = 1,
		Text = "MAIN MENU  /",
		Font = T.HeadFont,
		TextColor3 = T.Muted,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.fromScale(0.4, 0.03),
		ZIndex = 10,
		Visible = false,
		Parent = canvas,
	})
	Layout.bindText(breadcrumb, 30)
	Layout.clearTop(breadcrumb, UDim2.fromScale(0.033, 0.062))
	title = make("TextLabel", {
		Name = "Title",
		BackgroundTransparency = 1,
		Text = "",
		Font = T.HeadFont,
		TextColor3 = T.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		Size = UDim2.fromScale(0.6, TITLE_HEIGHT),
		ZIndex = 10,
		Visible = false,
		Parent = canvas,
	})
	Layout.bindText(title, 110)
	local stroke = make("UIStroke", {
		Color = T.Outline,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		Parent = title,
	})
	Layout.bindStroke(stroke, 4)
	Layout.clearTop(title, UDim2.fromScale(0.033, 0.095))
	underline = make("Frame", {
		Name = "Underline",
		BackgroundColor3 = T.Red,
		BorderSizePixel = 0,
		Size = UDim2.new(0.22, 0, 0, 6),
		ZIndex = 10,
		Visible = false,
		Parent = canvas,
	})
	local function placeUnderline()
		underline.Size = UDim2.new(0.22, 0, 0, math.max(2, Layout.px(6)))
		-- (the title's design height: its Size is divided by its TextFit scale)
		underline.Position = title.Position + UDim2.new(0, 0, TITLE_HEIGHT, Layout.px(4))
	end
	title:GetPropertyChangedSignal("Position"):Connect(placeUnderline)
	canvas:GetPropertyChangedSignal("AbsoluteSize"):Connect(placeUnderline)
	placeUnderline()
end

function MenuShell.init()
	backGui = Layout.screenGui("SkybrawlMenuBack", 2, "Full")
	backGui.Enabled = false
	MenuShell.buildBackdrop(backGui)
	backCanvas = fullFrame("Canvas", backGui, 10)
	gui = Layout.screenGui("SkybrawlMenu", 5, "Safe")
	gui.Enabled = false
	canvas = fullFrame("Canvas", gui)
	content = fullFrame("Screens", canvas, 1)

	host = {
		content = content,
		push = function(id, params)
			push(id, params)
		end,
		pop = function()
			pop()
		end,
		replace = function(id, params)
			replace(id, params)
		end,
		refresh = function()
			refresh()
		end,
		toast = function(text, kind)
			ClientState.toast(text, kind)
		end,
		cancelButton = function()
			return banner.cancelButton()
		end,
		-- shell internals for the main menu (not part of the screen contract)
		backdrop = backCanvas,
		chrome = {},
	}

	card = PlayerCard.new(canvas)
	banner = QueueBanner.new(canvas, host)
	party = PartyBar.new(canvas, host)
	host.chrome.playerCard = card
	host.chrome.queueBanner = banner
	host.chrome.partyBar = party
	hintBar, setHints = UIKit.hintBar(canvas, {})
	buildTitle()

	local inst = MainMenu.build(host)
	inst.root.Visible = false
	local root = { id = "MainMenu", module = MainMenu, inst = inst, params = nil, layer = nil, shown = false }
	entries.MainMenu = root
	stack = { root }

	ClientState.PhaseChanged:Connect(onPhase)
	ClientState.MatchChanged:Connect(function(inMatch)
		if not inMatch and ClientState.phase ~= "Match" then
			parkCamera()
		end
	end)
	ClientState.OpenScreen:Connect(openScreen)
	-- the hints and links follow the queue and the party
	ClientState.QueueChanged:Connect(function()
		task.defer(refresh)
	end)
	ClientState.PartyChanged:Connect(function()
		task.defer(refresh)
	end)
	Layout.Changed:Connect(function()
		task.defer(refresh)
	end)
	parkCamera()
	onPhase(ClientState.phase)
end

return MenuShell
