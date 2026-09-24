-- Client-side juice: floating "+N 💎" text, camera punch, Void Opal cinematic,
-- meteor impact shake and Supernova flash.
--
-- The pickaxe swing animation lives in PickaxeFX (the single RightGrip weld
-- owner). This module only forwards Tool.Activated to CrackRequest — an equipped
-- Tool eats the click before any ClickDetector — and pings Effects.OnCrackInput
-- (assigned by init.client → PickaxeFX.Swing) for the instant swing.
--
-- Two ScreenGuis: GeodeFXWorld (DisplayOrder 5) carries the floating text and is
-- skipped while GeodeHUD.PanelOpen; GeodeFXOverlay (50) carries full-screen
-- flashes. Effects.ApplyReduceFX(true) disables shake / flash / FOV punch.
-- Effects.Meteor scales shake + flash by the player's distance to the crater
-- (full < 60 studs, zero > 150) and shows one "warp home" toast per cycle when
-- the player is far. Every local sound goes through Audio.Play (GeodeSFX group).

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SG = require(ReplicatedStorage:WaitForChild("StyleGuide")) -- fonts / colours from tokens only

local Effects = {}
local Config
local player = Players.LocalPlayer
local worldGui, overlayGui
local reduceFX = false
local hud = nil -- GeodeHUD (built by UI); looked up lazily

-- optional hook, assigned by init.client (nil-safe)
Effects.OnCrackInput = nil

-- ===== audio routing (bounded wait: a missing Audio module must never park boot) =====
local Audio = nil
do
	local m = script.Parent:FindFirstChild("Audio") or script.Parent:WaitForChild("Audio", 5)
	if m then
		local ok, mod = pcall(require, m)
		if ok then Audio = mod else warn("[Effects] Audio failed to load: " .. tostring(mod)) end
	else
		warn("[Effects] Audio module missing — local sounds play ungrouped")
	end
end
local function play(id, volume, speed)
	if Audio then return Audio.Play(id, volume, speed) end
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume or 0.5
	s.PlaybackSpeed = speed or 1
	s.Parent = game:GetService("SoundService")
	s:Play()
	Debris:AddItem(s, 6)
	return s
end

-- ===== UI access (lazy; UI.Toast's kind argument is a string on the new UI and a
-- Color3 on the legacy one, so fall back to a plain toast if the typed call errors) =====
local UI = nil
local function toast(text, kind)
	if not UI then
		local m = script.Parent:FindFirstChild("UI")
		if m then
			local ok, mod = pcall(require, m)
			if ok then UI = mod end
		end
	end
	if not (UI and UI.Toast) then return end
	if not pcall(UI.Toast, text, kind) then pcall(UI.Toast, text) end
end

local function panelOpen()
	if not (hud and hud.Parent) then
		local pg = player:FindFirstChild("PlayerGui")
		hud = pg and pg:FindFirstChild("GeodeHUD")
	end
	return hud ~= nil and hud:GetAttribute("PanelOpen") == true
end

-- ===== Tool.Activated → CrackRequest (the server range-gates as before) =====
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local function onToolActivated()
	if Effects.OnCrackInput then Effects.OnCrackInput() end
	local cr = Remotes:FindFirstChild("CrackRequest")
	if cr then cr:FireServer() end
end

local function watchPickaxe()
	local function hookChar(char)
		char.ChildAdded:Connect(function(child)
			if child:IsA("Tool") and child.Name == "Pickaxe" then
				child.Activated:Connect(onToolActivated)
			end
		end)
		local existing = char:FindFirstChild("Pickaxe")
		if existing and existing:IsA("Tool") then existing.Activated:Connect(onToolActivated) end
	end
	player.CharacterAdded:Connect(hookChar)
	if player.Character then hookChar(player.Character) end
end

function Effects.Init(config)
	Config = config
	local pg = player:WaitForChild("PlayerGui")
	worldGui = Instance.new("ScreenGui")
	worldGui.Name = "GeodeFXWorld"
	worldGui.ResetOnSpawn = false
	worldGui.IgnoreGuiInset = true
	worldGui.DisplayOrder = 5 -- under GeodeHUD (10): floating text never sits on a panel
	worldGui.Parent = pg
	overlayGui = Instance.new("ScreenGui")
	overlayGui.Name = "GeodeFXOverlay"
	overlayGui.ResetOnSpawn = false
	overlayGui.IgnoreGuiInset = true
	overlayGui.DisplayOrder = 50
	overlayGui.Parent = pg
	watchPickaxe()
end

function Effects.ApplyReduceFX(on)
	reduceFX = on == true
end

local function flash(color, transparencyStart, duration)
	if reduceFX or not overlayGui then return end
	if transparencyStart >= 1 then return end
	local f = Instance.new("Frame")
	f.Size = UDim2.fromScale(1, 1)
	f.BackgroundColor3 = color
	f.BackgroundTransparency = transparencyStart
	f.BorderSizePixel = 0
	f.ZIndex = 40
	f.Parent = overlayGui
	TweenService:Create(f, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 1 }):Play()
	Debris:AddItem(f, duration + 0.1)
end

local function shake(intensity, duration)
	if reduceFX or intensity <= 0 then return end
	local cam = workspace.CurrentCamera
	if not cam then return end
	local t0 = os.clock()
	local conn
	conn = RunService.RenderStepped:Connect(function()
		local elapsed = os.clock() - t0
		if elapsed > duration then
			conn:Disconnect()
			return
		end
		local falloff = 1 - elapsed / duration
		local mag = intensity * falloff
		cam.CFrame = cam.CFrame * CFrame.new(
			(math.random() - 0.5) * mag,
			(math.random() - 0.5) * mag,
			0
		)
	end)
end

local function fovPunch(delta, upTime, backTime)
	if reduceFX then return end
	local cam = workspace.CurrentCamera
	if not cam then return end
	local base = cam.FieldOfView
	TweenService:Create(cam, TweenInfo.new(upTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { FieldOfView = base + delta }):Play()
	task.delay(upTime, function()
		TweenService:Create(cam, TweenInfo.new(backTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { FieldOfView = base }):Play()
	end)
end

local function floatingText(worldPos, text, color, big)
	if not worldGui or panelOpen() then return end
	local cam = workspace.CurrentCamera
	if not cam then return end
	local screenPos, onScreen = cam:WorldToViewportPoint(worldPos + Vector3.new(0, 3, 0))
	if not onScreen then return end
	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromOffset(screenPos.X + math.random(-20, 20), screenPos.Y)
	label.Size = UDim2.fromOffset(big and 280 or 160, big and 54 or 32)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.15
	label.TextScaled = true
	label.Font = SG.Font.Display
	label.Parent = worldGui
	TweenService:Create(label, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Position = label.Position - UDim2.fromOffset(0, 90),
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	}):Play()
	Debris:AddItem(label, 1)
end

function Effects.Crack(data, isMine)
	if type(data) ~= "table" then return end
	local rar = Config.Rarities[data.rarity]
	local mut = Config.Mutations[data.mutation]
	if not rar then return end
	local tag = (mut and data.mutation > 1 and (mut.key .. " ") or "")

	if isMine then
		floatingText(data.pos, "+" .. Config.Fmt(data.gained or 0) .. " 💎", rar.color, data.rarity >= 4)
		play(Config.Sounds.Gem, 0.45, 0.95 + data.rarity * 0.03)
		if data.rarity >= 4 then
			fovPunch(4, 0.1, 0.35)
		end
		if data.newEntry then
			floatingText(data.pos + Vector3.new(0, 3, 0), "📖 NEW: " .. tag .. rar.name, SG.Color.GoldSoft, true)
		end
	elseif data.rarity >= 5 then
		floatingText(data.pos, tostring(data.name) .. ": " .. tag .. rar.name .. "!", rar.color, false)
	end

	-- Void Opal cinematic for everyone nearby: rainbow beam to the ceiling
	if data.rarity >= 7 then
		if isMine then
			flash(Color3.fromRGB(255, 255, 255), 0.35, 1.1)
			fovPunch(-12, 0.5, 1.4)
		end
		local beam = Instance.new("Part")
		beam.Anchored = true
		beam.CanCollide = false
		beam.CanQuery = false
		beam.Material = Enum.Material.Neon -- transient light-shaft FX: an intentional emissive
		beam.Color = rar.color or Color3.fromRGB(255, 115, 230)
		beam.Size = Vector3.new(2.4, 70, 2.4)
		beam.CFrame = CFrame.new(data.pos + Vector3.new(0, 35, 0))
		beam.Parent = workspace.CurrentCamera
		local spin = TweenService:Create(beam, TweenInfo.new(1.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = Vector3.new(0.2, 70, 0.2),
			Transparency = 1,
		})
		spin:Play()
		Debris:AddItem(beam, 2)
	end
end

-- ===== meteor: distance-scaled =====
local farToasted = false

local function craterPos()
	local cag = workspace:FindFirstChild("CrackAGeode")
	local fx = cag and cag:FindFirstChild("FX")
	local m = fx and fx:FindFirstChild("MeteorGeode")
	if m then
		if m:IsA("BasePart") then return m.Position end
		if m:IsA("Model") then return m:GetPivot().Position end
	end
	local zones = Config and Config.Zones
	local hub = zones and zones.Get and zones.Get("Cavern")
	return (hub and hub.center) or Vector3.zero
end

-- 1 within 60 studs of the crater, fading to 0 at 150 studs
local function meteorScale()
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then return 1 end
	local d = (hrp.Position - craterPos()).Magnitude
	return 1 - math.clamp((d - 60) / 90, 0, 1)
end

function Effects.Meteor(data)
	if type(data) ~= "table" then return end
	local phase = data.phase
	if phase == "warning" or phase == "dead" then
		farToasted = false
		return
	end
	local k = meteorScale()
	if k <= 0 and not farToasted and (phase == "impact" or phase == "active") then
		farToasted = true
		toast("☄️ Meteor at the crater — warp home", "info")
	end
	if phase == "impact" then
		shake(1.4 * k, 0.7)
		flash(SG.Color.Gold, 1 - 0.45 * k, 0.5)
	elseif phase == "boom" then
		shake(2.2 * k, 1.1)
		flash(Color3.fromRGB(255, 255, 255), 1 - 0.85 * k, 1.2)
		if k > 0 then play(Config.Sounds.Rare, 0.8 * k, 0.9) end
	end
end

return Effects
