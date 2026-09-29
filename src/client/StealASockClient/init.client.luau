-- Steal a Sock - client bootstrap. Builds the HUD, listens to the server's remotes and hides
-- the Steal prompt on the player's own socks (the server still validates every steal).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local player = Players.LocalPlayer
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local HUD = require(script:WaitForChild("HUD"))

HUD.Init()

Remotes:WaitForChild("State").OnClientEvent:Connect(function(state)
	HUD.SetState(state)
end)
Remotes:WaitForChild("Toast").OnClientEvent:Connect(function(text, kind)
	HUD.Toast(text, kind)
end)
Remotes:WaitForChild("Announce").OnClientEvent:Connect(function(text, color)
	HUD.Announce(text, color)
end)
Remotes:WaitForChild("Carry").OnClientEvent:Connect(function(view)
	HUD.SetCarry(view)
end)

-- Own-sock prompt hiding. The server toggles prompt.Enabled too, so re-apply on every change.
local function applyOwnPrompt(model: Instance)
	local leg = model:FindFirstChild("Leg")
	local prompt = leg and leg:FindFirstChild("StealPrompt")
	if prompt and prompt:IsA("ProximityPrompt") and model:GetAttribute("OwnerId") == player.UserId then
		prompt.Enabled = false
	end
end

local function watchSock(model: Instance)
	applyOwnPrompt(model)
	model:GetAttributeChangedSignal("OwnerId"):Connect(function()
		applyOwnPrompt(model)
	end)
	model.DescendantAdded:Connect(function(desc)
		if desc:IsA("ProximityPrompt") and desc.Name == "StealPrompt" then
			applyOwnPrompt(model)
			desc:GetPropertyChangedSignal("Enabled"):Connect(function()
				applyOwnPrompt(model)
			end)
		end
	end)
	local leg = model:FindFirstChild("Leg")
	local prompt = leg and leg:FindFirstChild("StealPrompt")
	if prompt then
		prompt:GetPropertyChangedSignal("Enabled"):Connect(function()
			applyOwnPrompt(model)
		end)
	end
end

for _, model in ipairs(CollectionService:GetTagged("Sock")) do
	watchSock(model)
end
CollectionService:GetInstanceAddedSignal("Sock"):Connect(watchSock)
