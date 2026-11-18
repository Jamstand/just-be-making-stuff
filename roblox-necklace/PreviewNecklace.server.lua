-- Studio-only test: put this Script in ServerScriptService, then press Play.
-- Before running, import BritNecklace.obj (Avatar > Import 3D or Asset Manager),
-- set its texture to BritNecklace_texture.png, and paste the mesh/texture IDs below.
local MESH_ID    = "rbxassetid://0" -- your uploaded mesh ID
local TEXTURE_ID = "rbxassetid://0" -- your uploaded texture ID

local Players = game:GetService("Players")

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

	-- NeckAttachment exists on both R6 (Torso) and R15 (UpperTorso), so this fits both rigs
	local att = Instance.new("Attachment")
	att.Name = "NeckAttachment"
	att.Position = Vector3.new(0, 0, 0) -- nudge Y/Z here if it sits too high/low
	att.Parent = handle
	return acc
end

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(char)
		char:WaitForChild("Humanoid"):AddAccessory(makeNecklace())
	end)
end)
