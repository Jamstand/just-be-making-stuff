--[[
    Settings: Camera (mode, look, zoom, smoothing, shake), Controls
    (rebinding for keyboard and gamepad, tap jump, mouse attacks, mobile
    button size), Gameplay and Audio (sound effects, music).

    SettingsPanel.mount(parent, host) builds it as a menu screen
    (Screens/Settings, menus design 5.8): the four pages are tabs (L1/R1).

    Key rebinding: the menus' Focus is suspended while a key is being
    rebound, so the key you bind (B, Backspace, S, arrows, Enter...) never
    also navigates, goes back or restarts the capture. The capture is armed
    one deferred step after the press that started it, so Input never
    records that same Enter / Space / A. Esc or View cancels; a gamepad's B
    cancels a keyboard slot and Backspace clears a gamepad slot, so neither
    device is ever stuck. With a gamepad in hand, keyboard slots toast
    instead of capturing. Hiding the screen or changing tabs cancels.
    SettingsPanel.create(gui, close) is the old window around it, kept while
    LobbyUI exists.

    Rows are sized in design px (Layout.px, through a Common.sizer) so they
    grow with their text; description lines size themselves to their text.
    SettingsPanel.cameraRows(parent, startOrder, sizer?) is reused by the
    in-match pause menu so the camera can be changed mid-fight (without a
    sizer its rows keep 46 px).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local UIKit = require(script.Parent.UIKit)
local Focus = require(script.Parent.Focus)
local Layout = require(script.Parent.Layout)
local Common = require(script.Parent.Screens.Common)
local Controllers = script.Parent.Parent:WaitForChild("Controllers")
local Settings = require(Controllers.Settings)
local Input = require(Controllers.Input)

local T = UIKit.Theme
local make = UIKit.make

local SettingsPanel = {}

local ACTION_LABELS = {
	Left = "Move left",
	Right = "Move right",
	Up = "Aim up",
	Down = "Aim down / fast fall",
	Jump = "Jump",
	Light = "Light attack",
	Heavy = "Heavy attack",
	Dodge = "Dodge / dash",
	Throw = "Throw / pick up",
}

local KEY_NAMES = {
	LeftShift = "L-Shift",
	RightShift = "R-Shift",
	LeftControl = "L-Ctrl",
	ButtonR2 = "RT",
	ButtonL2 = "LT",
	ButtonR1 = "RB",
	ButtonL1 = "LB",
	ButtonA = "A",
	ButtonB = "B",
	ButtonX = "X",
	ButtonY = "Y",
}

local function prettyKey(name)
	if not name then
		return "-"
	end
	return KEY_NAMES[name] or name
end

local ROW_PX = 46 -- a setting row, design px
local PHONE_TABS = 80 -- the phone tab bar, design px (46 px on a 390 px phone)
local FULL_WIDTH = UDim.new(1, -10)

-- A muted line under a row; its height follows its text (AutomaticSize), at any resolution.
local function describeLabel(parent, order)
	return UIKit.label("", 13, {
		LayoutOrder = order,
		Size = UDim2.new(1, -10, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextColor3 = T.Muted,
		Parent = parent,
	})
end

-- A row's height in design px through `sizer` (Common.sizer), else a fixed `px` (the pause menu).
local function sizeRow(row, px, sizer)
	if sizer then
		sizer.height(row, px, FULL_WIDTH)
	else
		row.Size = UDim2.new(FULL_WIDTH, UDim.new(0, px))
	end
end

-- Adds the camera setting rows to `parent` (a frame with a UIListLayout); `sizer` (optional) sizes them in design px.
function SettingsPanel.cameraRows(parent, startOrder, sizer)
	local order = startOrder or 0
	local function nextOrder()
		order += 1
		return order
	end

	local modeOptions = {}
	local modeDescriptions = {}
	for _, mode in Config.Camera.Modes do
		table.insert(modeOptions, { value = mode.Id, label = mode.Label })
		modeDescriptions[mode.Id] = mode.Description
	end
	local modeHint
	local modeRow = UIKit.cycle("Camera mode", modeOptions, Settings.get("CameraMode"), function(v)
		Settings.set("CameraMode", v)
		modeHint.Text = modeDescriptions[v] or ""
	end)
	modeRow.LayoutOrder = nextOrder()
	sizeRow(modeRow, ROW_PX, sizer)
	modeRow:SetAttribute("FocusKey", "SettingCameraMode")
	modeRow.Parent = parent
	modeHint = describeLabel(parent, nextOrder())
	modeHint.Text = modeDescriptions[Settings.get("CameraMode")] or ""

	local lookOptions = {}
	local lookDescriptions = {}
	for _, look in Config.Camera.Looks do
		table.insert(lookOptions, { value = look.Id, label = look.Label })
		lookDescriptions[look.Id] = look.Description
	end
	local lookHint
	local lookRow = UIKit.cycle("Camera look", lookOptions, Settings.get("CameraLook"), function(v)
		Settings.set("CameraLook", v)
		lookHint.Text = lookDescriptions[v] or ""
	end)
	lookRow.LayoutOrder = nextOrder()
	sizeRow(lookRow, ROW_PX, sizer)
	lookRow:SetAttribute("FocusKey", "SettingCameraLook")
	lookRow.Parent = parent
	lookHint = describeLabel(parent, nextOrder())
	lookHint.Text = lookDescriptions[Settings.get("CameraLook")] or ""

	local zoomRow = UIKit.stepper("Zoom", 0.6, 1.6, 0.1, Settings.get("CameraZoom"), function(v)
		return string.format("%d%%", math.floor(v * 100 + 0.5))
	end, function(v)
		Settings.set("CameraZoom", v)
	end)
	zoomRow.LayoutOrder = nextOrder()
	sizeRow(zoomRow, ROW_PX, sizer)
	zoomRow:SetAttribute("FocusKey", "SettingCameraZoom")
	zoomRow.Parent = parent

	local smoothRow = UIKit.stepper("Smoothing", 0, 1, 0.1, Settings.get("CameraSmoothing"), function(v)
		return v == 0 and "Snappy" or (v >= 1 and "Floaty" or string.format("%d%%", math.floor(v * 100 + 0.5)))
	end, function(v)
		Settings.set("CameraSmoothing", v)
	end)
	smoothRow.LayoutOrder = nextOrder()
	sizeRow(smoothRow, ROW_PX, sizer)
	smoothRow:SetAttribute("FocusKey", "SettingCameraSmoothing")
	smoothRow.Parent = parent

	local shakeRow = UIKit.toggle("Screen shake", Settings.get("ScreenShake"), function(v)
		Settings.set("ScreenShake", v)
	end)
	shakeRow.LayoutOrder = nextOrder()
	sizeRow(shakeRow, ROW_PX, sizer)
	shakeRow:SetAttribute("FocusKey", "SettingScreenShake")
	shakeRow.Parent = parent

	local effectDescriptions = {
		Full = "Impact frames, debris, craters, smoke, speed lines and auras",
		Reduced = "Flashes, rings and auras only",
		Off = "No battle effects",
	}
	local effectsHint
	local effectsRow = UIKit.cycle(
		"Battle effects",
		{
			{ value = "Full", label = "Full" },
			{ value = "Reduced", label = "Reduced" },
			{ value = "Off", label = "Off" },
		},
		Settings.get("Effects"),
		function(v)
			Settings.set("Effects", v)
			effectsHint.Text = effectDescriptions[v] or ""
		end
	)
	effectsRow.LayoutOrder = nextOrder()
	sizeRow(effectsRow, ROW_PX, sizer)
	effectsRow:SetAttribute("FocusKey", "SettingEffects")
	effectsRow.Parent = parent
	effectsHint = describeLabel(parent, nextOrder())
	effectsHint.Text = effectDescriptions[Settings.get("Effects")] or ""

	local cinemaRow = UIKit.toggle("Ultimate camera cut-ins", Settings.get("Cinematics"), function(v)
		Settings.set("Cinematics", v)
	end)
	cinemaRow.LayoutOrder = nextOrder()
	sizeRow(cinemaRow, ROW_PX, sizer)
	cinemaRow:SetAttribute("FocusKey", "SettingCinematics")
	cinemaRow.Parent = parent
	return order
end

local function newPage(parent)
	local page = UIKit.scroll({
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = parent,
	})
	UIKit.list(Enum.FillDirection.Vertical, 6).Parent = page
	return page
end

local function addRow(page, row, order, key, sizer)
	row.LayoutOrder = order
	sizeRow(row, ROW_PX, sizer)
	if key then
		row:SetAttribute("FocusKey", key)
	end
	row.Parent = page
end

local function percentLabel(v)
	return string.format("%d%%", math.floor(v * 100 + 0.5))
end

--[[
    The Controls page. capture(device, callback) runs a key capture with
    the menus' Focus suspended (false when it refused). Returns the
    Settings.Changed connection that keeps the bind buttons current (the
    caller drops it on a rebuild).
]]
local function buildControls(page, capture, sizer)
	local order = 0
	local function o()
		order += 1
		return order
	end
	addRow(page, (UIKit.toggle("Tap jump (Up also jumps)", Settings.get("TapJump"), function(v)
		Settings.set("TapJump", v)
	end)), o(), "SettingTapJump", sizer)
	addRow(page, (UIKit.toggle("Mouse attacks (left = light, right = heavy)", Settings.get("MouseAttacks"), function(v)
		Settings.set("MouseAttacks", v)
	end)), o(), "SettingMouseAttacks", sizer)
	addRow(page, (UIKit.stepper("Mobile button size", 0.7, 1.5, 0.1, Settings.get("MobileButtonScale"), function(v)
		return string.format("%d%%", math.floor(v * 100 + 0.5))
	end, function(v)
		Settings.set("MobileButtonScale", v)
	end)), o(), "SettingMobileButtons", sizer)

	local header = make("Frame", { BackgroundTransparency = 1, LayoutOrder = o(), Parent = page })
	sizeRow(header, 30, sizer)
	UIKit.label(
		"Action",
		14,
		{ Font = T.BoldFont, TextColor3 = T.Muted, Size = UDim2.new(0.34, 0, 1, 0), Parent = header }
	)
	UIKit.label("Keyboard", 14, {
		Font = T.BoldFont,
		TextColor3 = T.Muted,
		Position = UDim2.fromScale(0.34, 0),
		Size = UDim2.new(0.44, 0, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = header,
	})
	UIKit.label("Gamepad", 14, {
		Font = T.BoldFont,
		TextColor3 = T.Muted,
		Position = UDim2.fromScale(0.78, 0),
		Size = UDim2.new(0.22, 0, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = header,
	})

	local bindButtons = {}
	local function renderBinds()
		for _, entry in bindButtons do
			local list = Settings.getBinds(entry.device, entry.action)
			entry.button.Text = prettyKey(list[entry.index])
			UIKit.styleButton(entry.button, "ghost")
		end
	end

	for _, action in Config.InputActions do
		local row = make("Frame", {
			BackgroundColor3 = T.Panel,
			BackgroundTransparency = 0.2,
			BorderSizePixel = 0,
			LayoutOrder = o(),
			Parent = page,
		}, { UIKit.corner(10), UIKit.padding(10, 4) })
		sizeRow(row, 44, sizer)
		UIKit.label(
			ACTION_LABELS[action] or action,
			15,
			{ Font = T.BoldFont, Size = UDim2.new(0.34, 0, 1, 0), Parent = row }
		)
		local slots = {
			{ device = "Keyboard", index = 1, x = 0.34, w = 0.21 },
			{ device = "Keyboard", index = 2, x = 0.56, w = 0.21 },
		}
		local isMovement = action == "Left" or action == "Right" or action == "Up" or action == "Down"
		if not isMovement then
			table.insert(slots, { device = "Gamepad", index = 1, x = 0.78, w = 0.22 })
		end
		for _, slot in slots do
			local button
			button = UIKit.button("-", "ghost", function()
				local started = capture(slot.device, function(keyName)
					if keyName == "Backspace" or keyName == "Delete" then
						Settings.setBind(slot.device, action, slot.index, nil)
					elseif keyName then
						Settings.setBind(slot.device, action, slot.index, keyName)
					end
					renderBinds()
				end)
				if started then
					button.Text = "Press..."
					UIKit.styleButton(button, "primary")
				end
			end, {
				Position = UDim2.fromScale(slot.x, 0.1),
				Size = UDim2.new(slot.w, -6, 0.8, 0),
				TextSize = 15,
				Parent = row,
			})
			button:SetAttribute("FocusKey", "Bind" .. action .. slot.device .. slot.index)
			table.insert(bindButtons, { button = button, device = slot.device, action = action, index = slot.index })
		end
		if isMovement then
			UIKit.label("Stick / D-pad", 13, {
				Position = UDim2.fromScale(0.78, 0),
				Size = UDim2.new(0.22, 0, 1, 0),
				TextColor3 = T.Muted,
				TextXAlignment = Enum.TextXAlignment.Center,
				Parent = row,
			})
		end
	end

	local hint = UIKit.label(
		"Pick a slot, then press a key or button. Esc or View cancels (B too, on a keyboard slot); Backspace clears.",
		13,
		{
			LayoutOrder = o(),
			Size = UDim2.new(1, -10, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			TextColor3 = T.Muted,
			Parent = page,
		}
	)
	hint.TextWrapped = true
	local reset = UIKit.button("Reset to defaults", "danger", function()
		Settings.resetBinds()
		renderBinds()
	end, { LayoutOrder = o(), Parent = page })
	if sizer then
		sizer.height(reset, 40, UDim.new(0.3, 0))
	else
		reset.Size = UDim2.fromOffset(200, 40)
	end
	reset:SetAttribute("FocusKey", "BindReset")

	renderBinds()
	return Settings.Changed:Connect(function(key)
		if key == "Keybinds" then
			renderBinds()
		end
	end)
end

-- The first focusable thing on a page, in list order (the row when its builder registered it, else a button in it).
local function firstFocusable(page)
	local best, bestOrder = nil, math.huge
	for _, child in page:GetChildren() do
		if child:IsA("GuiObject") and child.Visible and child.LayoutOrder < bestOrder then
			local target = nil
			if child.Selectable then
				target = child
			else
				for _, d in child:GetDescendants() do
					if (d:IsA("GuiButton") or d:IsA("TextBox")) and d.Selectable then
						target = d
						break
					end
				end
			end
			if target then
				best, bestOrder = target, child.LayoutOrder
			end
		end
	end
	return best
end

local TABS = {
	{ id = "Camera", label = "CAMERA" },
	{ id = "Controls", label = "CONTROLS" },
	{ id = "Gameplay", label = "GAMEPLAY" },
	{ id = "Audio", label = "AUDIO" },
}

-- Builds the settings as a menu screen inside `parent`. Returns the ScreenInstance (menus design 3.8).
function SettingsPanel.mount(parent, host)
	local root = Common.root({ content = parent }, "Settings")
	local sizer = Common.sizer(root)
	local current = "Camera"
	local container, pages, selectTab
	local bindsConnection = nil
	local unwatchTabs = nil

	--[[
	    Key capture (see the header). Focus is suspended from the press that
	    starts it and resumed one deferred step after the capture ends, so
	    the key that ended it is never also read as a menu press. finish()
	    is the capture's one exit: Input's callback, the cross-device keys
	    and cancelCapture() all go through it, and only the first counts.
	]]
	local suspended = false
	local captureToken = 0
	local currentFinish = nil
	local crossInput = nil
	local function resumeFocus()
		if suspended then
			suspended = false
			task.defer(Focus.resume)
		end
	end
	local function cancelCapture()
		local finish = currentFinish
		if finish then
			finish(nil)
		end
		-- drops Input's callback (our finish, which now ignores it)
		Input.cancelCapture()
	end
	local function capture(device, callback)
		if device == "Keyboard" and Focus.mode() == "Gamepad" then
			host.toast("Use your keyboard to bind keyboard keys.", "info")
			return false
		end
		cancelCapture() -- a capture already running ends first
		suspended = true
		Focus.suspend()
		captureToken += 1
		local token = captureToken
		local function finish(keyName)
			if token ~= captureToken then
				return
			end
			captureToken += 1
			currentFinish = nil
			if crossInput then
				crossInput:Disconnect()
				crossInput = nil
			end
			resumeFocus()
			callback(keyName)
		end
		currentFinish = finish
		-- armed after the press that started it has reached every InputBegan listener (Input's own handler
		-- would otherwise record that Enter / Space / A); a deferred thread runs after the event's handlers
		-- in both signal modes
		task.defer(function()
			if token ~= captureToken then
				return
			end
			Input.capture(device, finish)
			-- Input only cancels on Escape / View: a gamepad's B cancels a keyboard slot, and Backspace or
			-- Delete clears a gamepad slot, so whoever is holding the other device is never stuck
			crossInput = UserInputService.InputBegan:Connect(function(input)
				local fromPad = string.sub(input.UserInputType.Name, 1, 7) == "Gamepad"
				local fromKeys = input.UserInputType == Enum.UserInputType.Keyboard
				local clearKey = input.KeyCode == Enum.KeyCode.Backspace or input.KeyCode == Enum.KeyCode.Delete
				if device == "Keyboard" and fromPad and input.KeyCode == Enum.KeyCode.ButtonB then
					finish(nil)
					Input.cancelCapture()
				elseif device == "Gamepad" and fromKeys and clearKey then
					finish("Backspace")
					Input.cancelCapture()
				end
			end)
		end)
		return true
	end

	local function buildPages()
		for _, page in pages do
			UIKit.clear(page)
		end
		SettingsPanel.cameraRows(pages.Camera, 0, sizer)
		if bindsConnection then
			bindsConnection:Disconnect()
		end
		bindsConnection = buildControls(pages.Controls, capture, sizer)
		addRow(pages.Gameplay, (UIKit.toggle("Damage numbers", Settings.get("DamageNumbers"), function(v)
			Settings.set("DamageNumbers", v)
		end)), 1, "SettingDamageNumbers", sizer)
		addRow(pages.Gameplay, (UIKit.toggle("Show my hitboxes (practice)", Settings.get("ShowHitboxes"), function(v)
			Settings.set("ShowHitboxes", v)
		end)), 2, "SettingHitboxes", sizer)
		addRow(pages.Gameplay, (UIKit.toggle("Use my avatar's look", Settings.get("FightAsAvatar"), function(v)
			Settings.set("FightAsAvatar", v)
		end)), 3, "SettingAvatarLook", sizer)
		describeLabel(pages.Gameplay, 4).Text = "Your avatar's look with your legend's moves, stats and weapons."
		addRow(
			pages.Audio,
			(
				UIKit.stepper("Sound effects", 0, 1, 0.1, Settings.get("SfxVolume"), percentLabel, function(v)
					Settings.set("SfxVolume", v)
				end)
			),
			1,
			"SettingSfx",
			sizer
		)
		addRow(pages.Audio, (UIKit.stepper("Music", 0, 1, 0.1, Settings.get("MusicVolume"), percentLabel, function(v)
			Settings.set("MusicVolume", math.clamp(v, 0, 1))
		end)), 2, "SettingMusic", sizer)
	end

	local function showPage(id)
		cancelCapture()
		current = id
		for name, page in pages do
			page.Visible = name == id
		end
	end

	local function build()
		if container then
			container:Destroy()
		end
		local phone = Common.isPhone()
		-- (phone: the pages are the scrolling lists, so the body itself doesn't scroll; nested scrolling
		-- frames would trap touch drags)
		container = Common.region(root)
		local top = if phone then 0.13 else 0.1
		local tabBar, selectFromBar = UIKit.tabBar(TABS, {
			name = "Tabs",
			style = "big",
			position = UDim2.fromScale(0, 0),
			size = UDim2.fromScale(if phone then 1 else 0.6, top - 0.02),
			parent = container,
			onSelect = function(id)
				if id ~= current then
					showPage(id)
				end
			end,
		})
		selectTab = selectFromBar
		local pageFrame = make("Frame", {
			Name = "Pages",
			BackgroundTransparency = 1,
			Position = UDim2.fromScale(0, top),
			Size = UDim2.fromScale(if phone then 1 else 0.7, 1 - top),
			Parent = container,
		})
		if unwatchTabs then
			unwatchTabs()
			unwatchTabs = nil
		end
		if phone then
			-- tabs at least 44 px tall (PHONE_TABS design px), the pages below them
			sizer.height(tabBar, PHONE_TABS, UDim.new(1, 0))
			unwatchTabs = sizer.watch(function()
				local below = Layout.px(PHONE_TABS + 10)
				pageFrame.Position = UDim2.fromOffset(0, below)
				pageFrame.Size = UDim2.new(1, 0, 1, -below)
			end)
		end
		pages = {}
		for _, tab in TABS do
			pages[tab.id] = newPage(pageFrame)
			pages[tab.id].Name = tab.id
		end
		buildPages()
		showPage(current)
		selectTab(current)
	end
	build()

	local rewireTop = Common.linkTop(host, function()
		return { pages and firstFocusable(pages[current]) }
	end)

	-- Saved settings arrive shortly after joining; rebuild to show them.
	Settings.Loaded:Connect(function()
		buildPages()
		rewireTop()
	end)
	Common.onModeChange(root, function()
		build()
		rewireTop()
		host.refresh()
	end)

	local function cycle(delta)
		local index = 1
		for i, tab in TABS do
			if tab.id == current then
				index = i
			end
		end
		local id = TABS[(index - 1 + delta) % #TABS + 1].id
		showPage(id)
		selectTab(id)
		rewireTop()
		local first = firstFocusable(pages[id])
		if first then
			Focus.set(first)
		end
	end

	return {
		root = root,
		show = function()
			-- values changed elsewhere (the in-match pause menu) show up
			buildPages()
			rewireTop()
		end,
		hide = function()
			cancelCapture()
		end,
		defaultFocus = function()
			return firstFocusable(pages[current])
		end,
		actions = {
			L1 = function()
				cycle(-1)
			end,
			R1 = function()
				cycle(1)
			end,
		},
		hints = function()
			return {
				{ action = "Confirm", label = "CHANGE" },
				{ action = "L1", label = "" },
				{
					action = "R1",
					label = "TABS",
					onClick = function()
						cycle(1)
					end,
				},
				{ action = "Back", label = "BACK" },
			}
		end,
	}
end

-- The old Settings window (LobbyUI). TODO(I): delete once LobbyUI is gone (menus design 5.8).
function SettingsPanel.create(gui, close)
	return Common.legacyWindow(gui, "Settings", close, SettingsPanel.mount)
end

return SettingsPanel
