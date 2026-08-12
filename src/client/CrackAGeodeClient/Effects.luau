-- Client-side juice: floating +N gems, camera punch, Void Opal cinematic,
-- meteor impact shake and Supernova flash.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local Effects = {}
local Config
local player = Players.LocalPlayer
local gui

-- ===== pickaxe swing (grip-tween, no uploaded animations needed) =====
local originalGrip = nil
local swinging = false

local function equippedPickaxe()
	local char = player.Character
	return char and char:FindFirstChild("Pickaxe")
end

local function swing()
	local tool = equippedPickaxe()
	if not tool or swinging then return end
	if not originalGrip then originalGrip = tool.Grip end
	swinging = true
	local down = TweenService:Create(tool, TweenInfo.new(0.11, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Grip = originalGrip * CFrame.Angles(math.rad(-100), 0, 0),
	})
	down:Play()
	down.Completed:Wait()
	local back = equippedPickaxe()
	if back then
		TweenService:Create(back, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Grip = originalGrip }):Play()
	end
	task.delay(0.18, function() swinging = false end)
end
Effects.Swing = swing

local function watchPickaxe()
	local function hookChar(char)
		char.ChildAdded:Connect(function(child)
			if child:IsA("Tool") and child.Name == "Pickaxe" then
				child.Activated:Connect(swing)
			end
		end)
		local existing = char:FindFirstChild("Pickaxe")
		if existing then existing.Activated:Connect(swing) end
	end
	player.CharacterAdded:Connect(hookChar)
	if player.Character then hookChar(player.Character) end
end

-- ===== background music playlist =====
local function startMusic()
	local ids = Config.Music
	if not ids or #ids == 0 then return end
	task.spawn(function()
		local SoundService = game:GetService("SoundService")
		local s = Instance.new("Sound")
		s.Name = "GeodeMusic"
		s.Volume = 0.22
		s.Parent = SoundService
		local i = math.random(#ids) - 1
		while true do
			i = (i % #ids) + 1
			s.SoundId = ids[i]
			local t0 = os.clock()
			while not s.IsLoaded and os.clock() - t0 < 8 do task.wait(0.25) end
			if s.IsLoaded and s.TimeLength > 1 then
				s:Play()
				local done = false
				local conn = s.Ended:Connect(function() done = true end)
				local limit = s.TimeLength + 6
				local t1 = os.clock()
				while not done and os.clock() - t1 < limit do task.wait(0.5) end
				conn:Disconnect()
				s:Stop()
				task.wait(1.5)
			else
				task.wait(1) -- track failed to load; move on to the next
			end
		end
	end)
end

function Effects.Init(config)
	Config = config
	gui = Instance.new("ScreenGui")
	gui.Name = "GeodeFX"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 50
	gui.Parent = player:WaitForChild("PlayerGui")
	watchPickaxe()
	startMusic()
end

local function playLocal(id, volume, speed)
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume or 0.5
	s.PlaybackSpeed = speed or 1
	s.Parent = gui
	s:Play()
	Debris:AddItem(s, 4)
end

local function flash(color, transparencyStart, duration)
	local f = Instance.new("Frame")
	f.Size = UDim2.fromScale(1, 1)
	f.BackgroundColor3 = color
	f.BackgroundTransparency = transparencyStart
	f.BorderSizePixel = 0
	f.ZIndex = 40
	f.Parent = gui
	TweenService:Create(f, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 1 }):Play()
	Debris:AddItem(f, duration + 0.1)
end

local function shake(intensity, duration)
	local cam = workspace.CurrentCamera
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
	local cam = workspace.CurrentCamera
	local base = cam.FieldOfView
	TweenService:Create(cam, TweenInfo.new(upTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { FieldOfView = base + delta }):Play()
	task.delay(upTime, function()
		TweenService:Create(cam, TweenInfo.new(backTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { FieldOfView = base }):Play()
	end)
end

local function floatingText(worldPos, text, color, big)
	local cam = workspace.CurrentCamera
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
	label.Font = Enum.Font.GothamBlack
	label.Parent = gui
	TweenService:Create(label, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Position = label.Position - UDim2.fromOffset(0, 90),
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	}):Play()
	Debris:AddItem(label, 1)
end

function Effects.Crack(data, isMine)
	local rar = Config.Rarities[data.rarity]
	local mut = Config.Mutations[data.mutation]
	if not rar then return end
	local tag = (data.mutation > 1 and (mut.key .. " ") or "")

	if isMine then
		task.spawn(swing)
		floatingText(data.pos, "+" .. Config.Fmt(data.gained) .. " 💎", rar.color, data.rarity >= 4)
		playLocal(Config.Sounds.Gem, 0.45, 0.95 + data.rarity * 0.03)
		if data.rarity >= 4 then
			fovPunch(4, 0.1, 0.35)
		end
		if data.newEntry then
			floatingText(data.pos + Vector3.new(0, 3, 0), "📖 NEW: " .. tag .. rar.name, Color3.fromRGB(255, 235, 160), true)
		end
	elseif data.rarity >= 5 then
		floatingText(data.pos, data.name .. ": " .. tag .. rar.name .. "!", rar.color, false)
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
		beam.Material = Enum.Material.Neon
		beam.Color = Color3.fromRGB(255, 115, 230)
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

function Effects.Meteor(data)
	if data.phase == "impact" then
		shake(1.4, 0.7)
		flash(Color3.fromRGB(255, 170, 90), 0.55, 0.5)
	elseif data.phase == "boom" then
		shake(2.2, 1.1)
		flash(Color3.fromRGB(255, 255, 255), 0.15, 1.2)
		playLocal(Config.Sounds.Rare, 0.8, 0.9)
	end
end

return Effects
