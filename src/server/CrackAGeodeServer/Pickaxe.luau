-- PickaxeService: gives every player the crystal pickaxe tool. The tool visibly
-- upgrades as POWER tiers rise — edge-glow colour, glow strength, sparkles and a
-- small size step per tier — so upgrade purchases read on the pickaxe itself.
-- (Ascension owns the top-tier look regardless of current power.)

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

local Pickaxe = {}
local S
local template

local TIERS = {
	{ min = 24, name = "Void",      color = Color3.fromRGB(190, 120, 255), glow = 1.6, sparkle = 14, scale = 1.24 },
	{ min = 18, name = "Starstone", color = Color3.fromRGB(100, 190, 255), glow = 1.3, sparkle = 8,  scale = 1.2 },
	{ min = 14, name = "Ruby",      color = Color3.fromRGB(255, 80, 100),  glow = 1.1, sparkle = 5,  scale = 1.16 },
	{ min = 10, name = "Emerald",   color = Color3.fromRGB(70, 245, 140),  glow = 0.9, sparkle = 3,  scale = 1.12 },
	{ min = 6,  name = "Gold",      color = Color3.fromRGB(255, 200, 60),  glow = 0.6, sparkle = 0,  scale = 1.08 },
	{ min = 3,  name = "Bronze",    color = Color3.fromRGB(205, 130, 70),  glow = 0.3, sparkle = 0,  scale = 1.04 },
	{ min = 0,  name = "Steel",     color = Color3.fromRGB(170, 175, 190), glow = 0,   sparkle = 0,  scale = 1 },
}

local function tierFor(p)
	if p.ascensions > 0 then return TIERS[1] end
	for _, tier in ipairs(TIERS) do
		if p.power >= tier.min then return tier end
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
		local handle = tool:FindFirstChild("Handle")
		-- size step: scale the mesh + every welded accent about the handle centre
		if handle and tier.scale ~= 1 then
			local s = tier.scale
			handle.Size = handle.Size * s
			for _, part in ipairs(tool:GetChildren()) do
				if part:IsA("BasePart") and part ~= handle then
					part.Size = part.Size * s
					local w = part:FindFirstChildOfClass("Weld")
					if w then w.C1 = CFrame.new(w.C1.Position * s) * (w.C1 - w.C1.Position) end
				end
			end
			tool.Grip = CFrame.new(tool.Grip.Position * s) * (tool.Grip - tool.Grip.Position)
		end
		-- tier glow accents (colour + strength), light and sparkles
		for _, name in ipairs({ "EdgeGlowA", "EdgeGlowB" }) do
			local part = tool:FindFirstChild(name)
			if part then
				part.Color = tier.color
				part.Transparency = tier.glow > 0 and 0.1 or 0.35
			end
		end
		local light = handle and handle:FindFirstChild("TierLight")
		if light then light.Color = tier.color; light.Brightness = tier.glow end
		local att = handle and handle:FindFirstChild("TierAtt")
		local pe = att and att:FindFirstChild("TierSparkle")
		if pe then pe.Rate = tier.sparkle; pe.Color = ColorSequence.new(tier.color) end
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