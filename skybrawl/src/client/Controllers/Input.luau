--[[
    Reads keyboard, mouse, gamepad and the on-screen mobile controls and
    turns them into the input table FighterSim expects.

    Presses are buffered for Config.InputBufferTime so an attack pressed a
    moment before the previous one ends still comes out.
]]

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local Settings = require(script.Parent.Settings)

local Input = {}

local PRESS_ACTIONS = { Jump = true, Light = true, Heavy = true, Dodge = true, Throw = true }
local STICK_DEADZONE = 0.3

Input.state = {
	moveX = 0,
	moveY = 0,
	jumpHeld = false,
	heavyHeld = false,
	buffer = { Jump = 0, Light = 0, Heavy = 0, Dodge = 0, Throw = 0 },
}

-- Written by MobileControls.
Input.mobile = {
	moveX = 0,
	moveY = 0,
	held = {},
}

local enabled = false
local captureCallback = nil
local captureDevice = nil
local lastDevice = "Keyboard"

local keyboardMap = {} -- [KeyCode] = { actions }
local gamepadMap = {}

local function rebuildMaps()
	keyboardMap = {}
	gamepadMap = {}
	for _, action in Config.InputActions do
		for _, name in Settings.getBinds("Keyboard", action) do
			local ok, code = pcall(function()
				return Enum.KeyCode[name]
			end)
			if ok and code then
				keyboardMap[code] = keyboardMap[code] or {}
				table.insert(keyboardMap[code], action)
			end
		end
		for _, name in Settings.getBinds("Gamepad", action) do
			local ok, code = pcall(function()
				return Enum.KeyCode[name]
			end)
			if ok and code then
				gamepadMap[code] = gamepadMap[code] or {}
				table.insert(gamepadMap[code], action)
			end
		end
	end
end

local function press(action)
	if PRESS_ACTIONS[action] then
		Input.state.buffer[action] = Config.InputBufferTime
	end
	if action == "Up" and Settings.get("TapJump") then
		Input.state.buffer.Jump = Config.InputBufferTime
	end
end

-- Called by MobileControls buttons.
function Input.pressMobile(action)
	lastDevice = "Touch"
	press(action)
end

local function isGamepad(inputType)
	return inputType == Enum.UserInputType.Gamepad1
		or inputType == Enum.UserInputType.Gamepad2
		or inputType == Enum.UserInputType.Gamepad3
		or inputType == Enum.UserInputType.Gamepad4
end

local function onInputBegan(input, gameProcessed)
	if captureCallback then
		local callback = captureCallback
		if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.ButtonSelect then
			captureCallback = nil
			callback(nil)
			return
		end
		local isKey = captureDevice == "Keyboard" and input.UserInputType == Enum.UserInputType.Keyboard
		local isPad = captureDevice == "Gamepad"
			and isGamepad(input.UserInputType)
			and input.KeyCode ~= Enum.KeyCode.Thumbstick1
			and input.KeyCode ~= Enum.KeyCode.Thumbstick2
		if isKey or isPad then
			captureCallback = nil
			callback(input.KeyCode.Name)
		end
		return
	end

	if not enabled or gameProcessed then
		return
	end
	local actions
	if input.UserInputType == Enum.UserInputType.Keyboard then
		lastDevice = "Keyboard"
		actions = keyboardMap[input.KeyCode]
	elseif isGamepad(input.UserInputType) then
		lastDevice = "Gamepad"
		actions = gamepadMap[input.KeyCode]
		if not actions then
			if input.KeyCode == Enum.KeyCode.DPadUp then
				actions = { "Up" }
			end
		end
	elseif Settings.get("MouseAttacks") then
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			actions = { "Light" }
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			actions = { "Heavy" }
		end
	end
	if actions then
		for _, action in actions do
			press(action)
		end
	end
end

local stickUpWasHeld = false

local function keyboardHeld(action)
	for _, name in Settings.getBinds("Keyboard", action) do
		local ok, code = pcall(function()
			return Enum.KeyCode[name]
		end)
		if ok and code and UserInputService:IsKeyDown(code) then
			return true
		end
	end
	return false
end

local function gamepadHeld(action)
	for _, name in Settings.getBinds("Gamepad", action) do
		local ok, code = pcall(function()
			return Enum.KeyCode[name]
		end)
		if ok and code and UserInputService:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, code) then
			return true
		end
	end
	return false
end

local function mouseHeld(action)
	if not Settings.get("MouseAttacks") then
		return false
	end
	if action == "Heavy" then
		return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
	end
	return false
end

local function readStick()
	local x, y = 0, 0
	if not UserInputService.GamepadEnabled then
		return x, y
	end
	local ok, states = pcall(function()
		return UserInputService:GetGamepadState(Enum.UserInputType.Gamepad1)
	end)
	if ok then
		for _, state in states do
			if state.KeyCode == Enum.KeyCode.Thumbstick1 then
				local p = state.Position
				if p.Magnitude > STICK_DEADZONE then
					x, y = p.X, p.Y
				end
			end
		end
	end
	local pad = Enum.UserInputType.Gamepad1
	if UserInputService:IsGamepadButtonDown(pad, Enum.KeyCode.DPadLeft) then
		x = -1
	elseif UserInputService:IsGamepadButtonDown(pad, Enum.KeyCode.DPadRight) then
		x = 1
	end
	if UserInputService:IsGamepadButtonDown(pad, Enum.KeyCode.DPadUp) then
		y = 1
	elseif UserInputService:IsGamepadButtonDown(pad, Enum.KeyCode.DPadDown) then
		y = -1
	end
	return x, y
end

-- Call once per frame while fighting; returns the input table.
function Input.update(dt)
	local state = Input.state
	for action, remaining in state.buffer do
		state.buffer[action] = math.max(0, remaining - dt)
	end
	if not enabled then
		state.moveX, state.moveY = 0, 0
		state.jumpHeld, state.heavyHeld = false, false
		return state
	end

	local typing = UserInputService:GetFocusedTextBox() ~= nil
	local kx, ky = 0, 0
	if not typing then
		if keyboardHeld("Right") then
			kx += 1
		end
		if keyboardHeld("Left") then
			kx -= 1
		end
		if keyboardHeld("Up") then
			ky += 1
		end
		if keyboardHeld("Down") then
			ky -= 1
		end
	end
	local gx, gy = readStick()
	local mobile = Input.mobile

	-- Use whichever device is pushed hardest.
	local mx, my = kx, ky
	if math.abs(gx) + math.abs(gy) > math.abs(mx) + math.abs(my) then
		mx, my = gx, gy
	end
	if math.abs(mobile.moveX) + math.abs(mobile.moveY) > math.abs(mx) + math.abs(my) then
		mx, my = mobile.moveX, mobile.moveY
	end
	state.moveX, state.moveY = mx, my

	-- Tap jump from the stick: flick up to jump.
	local stickUp = gy > 0.7 or (mobile.moveY > 0.75 and Settings.get("TapJump"))
	if stickUp and not stickUpWasHeld and Settings.get("TapJump") then
		state.buffer.Jump = Config.InputBufferTime
	end
	stickUpWasHeld = stickUp

	local tapJump = Settings.get("TapJump")
	state.jumpHeld = (not typing and keyboardHeld("Jump"))
		or gamepadHeld("Jump")
		or mobile.held.Jump == true
		or (tapJump and (ky > 0 or gy > 0.5 or mobile.moveY > 0.6))
	state.heavyHeld = (not typing and keyboardHeld("Heavy")) or gamepadHeld("Heavy") or mouseHeld("Heavy") or mobile.held.Heavy == true
	return state
end

function Input.clearBuffer()
	for action in Input.state.buffer do
		Input.state.buffer[action] = 0
	end
end

function Input.setEnabled(value)
	enabled = value
	Input.clearBuffer()
	Input.mobile.moveX, Input.mobile.moveY = 0, 0
	Input.mobile.held = {}
end

function Input.isEnabled()
	return enabled
end

function Input.lastDevice()
	return lastDevice
end

-- Waits for the next key/button on `device` ("Keyboard" | "Gamepad").
-- callback(keyName or nil if cancelled with Escape).
function Input.capture(device, callback)
	captureDevice = device
	captureCallback = callback
end

function Input.cancelCapture()
	local callback = captureCallback
	captureCallback = nil
	if callback then
		callback(nil)
	end
end

function Input.init()
	rebuildMaps()
	Settings.Changed:Connect(function(key)
		if key == "Keybinds" then
			rebuildMaps()
		end
	end)
	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.LastInputTypeChanged:Connect(function(inputType)
		if isGamepad(inputType) then
			lastDevice = "Gamepad"
		elseif inputType == Enum.UserInputType.Touch then
			lastDevice = "Touch"
		elseif inputType == Enum.UserInputType.Keyboard or inputType == Enum.UserInputType.MouseButton1 then
			lastDevice = "Keyboard"
		end
	end)
end

return Input
