--[[
    Settings: Camera (mode, look, zoom, smoothing, shake), Controls
    (rebinding for keyboard and gamepad, tap jump, mouse attacks, mobile
    button size), Gameplay and Audio.

    SettingsPanel.cameraRows() is reused by the in-match pause menu so the
    camera can be changed mid-fight.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local UIKit = require(script.Parent.UIKit)
local Controllers = script.Parent.Parent:WaitForChild("Controllers")
local Settings = require(Controllers.Settings)
local Input = require(Controllers.Input)

local T = UIKit.Theme
local make = UIKit.make

local SettingsPanel = {}

local bindsConnection = nil

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

local function describeLabel(parent, order)
	return UIKit.label("", 13, {
		LayoutOrder = order,
		Size = UDim2.new(1, -10, 0, 18),
		TextColor3 = T.Muted,
		Parent = parent,
	})
end

-- Adds the camera setting rows to `parent` (a frame with a UIListLayout).
function SettingsPanel.cameraRows(parent, startOrder)
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
	modeRow.Size = UDim2.new(1, -10, 0, 46)
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
	lookRow.Size = UDim2.new(1, -10, 0, 46)
	lookRow.Parent = parent
	lookHint = describeLabel(parent, nextOrder())
	lookHint.Text = lookDescriptions[Settings.get("CameraLook")] or ""

	local zoomRow = UIKit.stepper("Zoom", 0.6, 1.6, 0.1, Settings.get("CameraZoom"), function(v)
		return string.format("%d%%", math.floor(v * 100 + 0.5))
	end, function(v)
		Settings.set("CameraZoom", v)
	end)
	zoomRow.LayoutOrder = nextOrder()
	zoomRow.Size = UDim2.new(1, -10, 0, 46)
	zoomRow.Parent = parent

	local smoothRow = UIKit.stepper("Smoothing", 0, 1, 0.1, Settings.get("CameraSmoothing"), function(v)
		return v == 0 and "Snappy" or (v >= 1 and "Floaty" or string.format("%d%%", math.floor(v * 100 + 0.5)))
	end, function(v)
		Settings.set("CameraSmoothing", v)
	end)
	smoothRow.LayoutOrder = nextOrder()
	smoothRow.Size = UDim2.new(1, -10, 0, 46)
	smoothRow.Parent = parent

	local shakeRow = UIKit.toggle("Screen shake", Settings.get("ScreenShake"), function(v)
		Settings.set("ScreenShake", v)
	end)
	shakeRow.LayoutOrder = nextOrder()
	shakeRow.Size = UDim2.new(1, -10, 0, 46)
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
	effectsRow.Size = UDim2.new(1, -10, 0, 46)
	effectsRow.Parent = parent
	effectsHint = describeLabel(parent, nextOrder())
	effectsHint.Text = effectDescriptions[Settings.get("Effects")] or ""

	local cinemaRow = UIKit.toggle("Ultimate camera cut-ins", Settings.get("Cinematics"), function(v)
		Settings.set("Cinematics", v)
	end)
	cinemaRow.LayoutOrder = nextOrder()
	cinemaRow.Size = UDim2.new(1, -10, 0, 46)
	cinemaRow.Parent = parent
	return order
end

local function newPage(body)
	local page = UIKit.scroll({
		Position = UDim2.fromOffset(0, 48),
		Size = UDim2.new(1, 0, 1, -48),
		Visible = false,
		Parent = body,
	})
	UIKit.list(Enum.FillDirection.Vertical, 6).Parent = page
	return page
end

local function addRow(page, row, order)
	row.LayoutOrder = order
	row.Size = UDim2.new(1, -10, 0, row.Size.Y.Offset)
	row.Parent = page
end

local function buildControls(page)
	local order = 0
	local function o()
		order += 1
		return order
	end
	addRow(page, (UIKit.toggle("Tap jump (Up also jumps)", Settings.get("TapJump"), function(v)
		Settings.set("TapJump", v)
	end)), o())
	addRow(page, (UIKit.toggle("Mouse attacks (left = light, right = heavy)", Settings.get("MouseAttacks"), function(v)
		Settings.set("MouseAttacks", v)
	end)), o())
	addRow(page, (UIKit.stepper("Mobile button size", 0.7, 1.5, 0.1, Settings.get("MobileButtonScale"), function(v)
		return string.format("%d%%", math.floor(v * 100 + 0.5))
	end, function(v)
		Settings.set("MobileButtonScale", v)
	end)), o())

	local header =
		make("Frame", { BackgroundTransparency = 1, LayoutOrder = o(), Size = UDim2.new(1, -10, 0, 30), Parent = page })
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
			Size = UDim2.new(1, -10, 0, 44),
			Parent = page,
		}, { UIKit.corner(10), UIKit.padding(10, 4) })
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
				button.Text = "Press..."
				UIKit.styleButton(button, "primary")
				Input.capture(slot.device, function(keyName)
					if keyName == "Backspace" or keyName == "Delete" then
						Settings.setBind(slot.device, action, slot.index, nil)
					elseif keyName then
						Settings.setBind(slot.device, action, slot.index, keyName)
					end
					renderBinds()
				end)
			end, {
				Position = UDim2.fromScale(slot.x, 0.1),
				Size = UDim2.new(slot.w, -6, 0.8, 0),
				TextSize = 15,
				Parent = row,
			})
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

	local hint = UIKit.label("Click a slot, then press a key or button. Esc cancels, Backspace clears.", 13, {
		LayoutOrder = o(),
		Size = UDim2.new(1, -10, 0, 20),
		TextColor3 = T.Muted,
		Parent = page,
	})
	hint.TextWrapped = true
	UIKit.button("Reset to defaults", "danger", function()
		Settings.resetBinds()
		renderBinds()
	end, { LayoutOrder = o(), Size = UDim2.fromOffset(200, 40), Parent = page })

	if bindsConnection then
		bindsConnection:Disconnect()
	end
	bindsConnection = Settings.Changed:Connect(function(key)
		if key == "Keybinds" then
			renderBinds()
		end
	end)
	renderBinds()
end

function SettingsPanel.create(gui, close)
	local window, body = UIKit.window(gui, "Settings", function()
		Input.cancelCapture()
		close()
	end)

	local pages = {
		Camera = newPage(body),
		Controls = newPage(body),
		Gameplay = newPage(body),
		Audio = newPage(body),
	}

	local function buildPages()
		for _, page in pages do
			UIKit.clear(page)
		end
		SettingsPanel.cameraRows(pages.Camera, 0)
		buildControls(pages.Controls)
		addRow(pages.Gameplay, (UIKit.toggle("Damage numbers", Settings.get("DamageNumbers"), function(v)
			Settings.set("DamageNumbers", v)
		end)), 1)
		addRow(pages.Gameplay, (UIKit.toggle("Show my hitboxes (practice)", Settings.get("ShowHitboxes"), function(v)
			Settings.set("ShowHitboxes", v)
		end)), 2)
		addRow(pages.Gameplay, (UIKit.toggle("Use my avatar's look", Settings.get("FightAsAvatar"), function(v)
			Settings.set("FightAsAvatar", v)
		end)), 3)
		describeLabel(pages.Gameplay, 4).Text = "Your avatar's look with your legend's moves, stats and weapons."
		addRow(pages.Audio, (UIKit.stepper("Sound effects", 0, 1, 0.1, Settings.get("SfxVolume"), function(v)
			return string.format("%d%%", math.floor(v * 100 + 0.5))
		end, function(v)
			Settings.set("SfxVolume", v)
		end)), 1)
	end
	buildPages()
	-- Saved settings arrive shortly after joining; rebuild to show them.
	Settings.Loaded:Connect(buildPages)

	local tabBar, selectTab = UIKit.tabs({
		{ id = "Camera", label = "Camera" },
		{ id = "Controls", label = "Controls" },
		{ id = "Gameplay", label = "Gameplay" },
		{ id = "Audio", label = "Audio" },
	}, function(id)
		Input.cancelCapture()
		for name, page in pages do
			page.Visible = name == id
		end
	end)
	tabBar.Parent = body
	selectTab("Camera")

	return {
		window = window,
		open = function()
			-- Rebuild so values changed elsewhere (e.g. the in-match menu) show.
			buildPages()
			window.Visible = true
		end,
		close = function()
			Input.cancelCapture()
			window.Visible = false
		end,
	}
end

return SettingsPanel
