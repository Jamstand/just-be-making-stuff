-- PickaxeService: gives every player a pickaxe tool, recolored by rebirth tier.
-- The tier ladder is the visible status symbol the spec's 'pickaxe recolor' called for.

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

local Pickaxe = {}
local S
local template

local TIERS = {
	{ min = 15, name = "Void",      color = Color3.fromRGB(190, 120, 255), material = Enum.Material.Neon },
	{ min = 12, name = "Starstone", color = Color3.fromRGB(100, 190, 255), material = Enum.Material.Neon },
	{ min = 8,  name = "Ruby",      color = Color3.fromRGB(255, 80, 100),  material = Enum.Material.Neon },
	{ min = 5,  name = "Emerald",   color = Color3.fromRGB(70, 245, 140),  material = Enum.Material.Neon },
	{ min = 3,  name = "Gold",      color = Color3.fromRGB(255, 200, 60),  material = Enum.Material.Metal },
	{ min = 1,  name = "Bronze",    color = Color3.fromRGB(205, 130, 70),  material = Enum.Material.Metal },
	{ min = 0,  name = "Steel",     color = Color3.fromRGB(170, 175, 190), material = Enum.Material.Metal },
}

local function tierFor(p)
	if p.ascensions > 0 then return TIERS[1] end
	for _, tier in ipairs(TIERS) do
		if p.rebirths >= tier.min then return tier end
	end
	return TIERS[#TIERS]
end

function Pickaxe.Refresh(player)
	task.spawn(function()
		local p = S.Data.WaitFor(player, 10)
		local char = player.Character
		if not (p and char) then return end
		local backpack = player:FindFirstChild("Backpack")
		for _, container in ipairs({ backpack, char }) do
			if container then
				local oldTool = container:FindFirstChild("Pickaxe")
				if oldTool then oldTool:Destroy() end
			end
		end
		if not backpack then return end
		local tier = tierFor(p)
		local tool = template:Clone()
		tool.Name = "Pickaxe"
		tool.ToolTip = tier.name .. " Pickaxe"
		for _, name in ipairs({ "Head", "SpikeA", "SpikeB", "TipA", "TipB" }) do
			local part = tool:FindFirstChild(name)
			if part then
				part.Color = tier.color
				if name == "TipA" or name == "TipB" then
					part.Material = Enum.Material.Neon
				else
					part.Material = tier.material
				end
			end
		end
		tool.Parent = backpack
		local humanoid = char:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 then
			humanoid:EquipTool(tool)
		end
	end)
end

function Pickaxe.Init(services)
	S = services
	template = ServerStorage:WaitForChild("PickaxeTemplate")
	local function watch(player)
		player.CharacterAdded:Connect(function()
			task.wait(0.4)
			Pickaxe.Refresh(player)
		end)
		if player.Character then Pickaxe.Refresh(player) end
	end
	Players.PlayerAdded:Connect(watch)
	for _, p in ipairs(Players:GetPlayers()) do watch(p) end
end

return Pickaxe
