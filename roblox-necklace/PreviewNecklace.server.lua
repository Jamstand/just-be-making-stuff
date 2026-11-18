-- Wear the Brit necklace WITH real glowing sparkle particles in your own game.
-- (Particles and lights only work in your own games; Roblox doesn't allow them on avatar shop items.)
-- Put this Script in ServerScriptService. Import BritNecklace.obj + texture in Studio,
-- then paste the mesh/texture asset IDs below and press Play.
local MESH_ID    = "rbxassetid://0" -- your uploaded mesh ID
local TEXTURE_ID = "rbxassetid://0" -- your uploaded texture ID
local PINK = Color3.fromRGB(255, 140, 200)

local Players = game:GetService("Players")

local function addGlow(handle)
	-- pendant sits about 0.6 studs below the neck attachment, on the chest
	local spot = Instance.new("Attachment")
	spot.Name = "GlowSpot"
	spot.Position = Vector3.new(0, -0.6, -0.56)
	spot.Parent = handle

	local light = Instance.new("PointLight")
	light.Color = PINK
	light.Brightness = 1.5
	light.Range = 5
	light.Parent = spot

	local sparkles = Instance.new("ParticleEmitter")
	sparkles.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	sparkles.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), PINK)
	sparkles.LightEmission = 1 -- makes them glow
	sparkles.LightInfluence = 0
	sparkles.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.3, 0.18),
		NumberSequenceKeypoint.new(1, 0),
	})
	sparkles.Transparency = NumberSequence.new(0.1, 1)
	sparkles.Lifetime = NumberRange.new(0.6, 1.2)
	sparkles.Rate = 8
	sparkles.Speed = NumberRange.new(0.2, 0.6)
	sparkles.SpreadAngle = Vector2.new(180, 180)
	sparkles.Rotation = NumberRange.new(0, 360)
	sparkles.RotSpeed = NumberRange.new(-90, 90)
	sparkles.Parent = spot
end

local function makeNecklace()
	local acc = Instance.new("Accessory")
	acc.Name = "BritNecklace"
	acc.AccessoryType = Enum.AccessoryType.Neck

	local handle = Instance.new("MeshPart")
	handle.Name = "Handle"
	handle.MeshId = MESH_ID
	handle.TextureID = TEXTURE_ID
	handle.CanCollide = false
	handle.Massless = true
	handle.Parent = acc

	-- NeckAttachment exists on both R6 (Torso) and R15 (UpperTorso)
	local att = Instance.new("Attachment")
	att.Name = "NeckAttachment"
	att.Parent = handle

	addGlow(handle)
	return acc
end

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(char)
		char:WaitForChild("Humanoid"):AddAccessory(makeNecklace())
	end)
end)
