-- Crack a Geode! client bootstrap: wires remotes to UI / Effects / Orbit modules.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local UI = require(script:WaitForChild("UI"))
local Effects = require(script:WaitForChild("Effects"))
local Orbit = require(script:WaitForChild("Orbit"))
local Quality = require(script:WaitForChild("Quality"))
local PetView = require(script:WaitForChild("PetView"))

local player = Players.LocalPlayer
local state = nil

UI.Init(Config, Remotes)
Effects.Init(Config)
Orbit.Init(Config)
PetView.Init()
task.spawn(Quality.Init)

-- VIP chat tag: prepend a gold [VIP] to messages from players who own the VIP pass
-- (server sets the IsVIP attribute; this client-side hook formats incoming chat).
local TextChatService = game:GetService("TextChatService")
pcall(function()
	TextChatService.OnIncomingMessage = function(message)
		local props = Instance.new("TextChatMessageProperties")
		local src = message.TextSource
		if src then
			local sender = Players:GetPlayerByUserId(src.UserId)
			if sender and sender:GetAttribute("IsVIP") then
				props.PrefixText = "<font color='#FFD24D'>[VIP]</font> " .. message.PrefixText
			end
		end
		return props
	end
end)

Remotes.StatsChanged.OnClientEvent:Connect(function(snap)
	state = snap
	UI.Update(snap)
	PetView.Set(snap.pets and snap.pets.active)
end)

Remotes.Announce.OnClientEvent:Connect(function(data)
	UI.Banner(data)
end)

Remotes.CrackFX.OnClientEvent:Connect(function(data)
	Effects.Crack(data, data.userId == player.UserId)
	UI.OnCrack(data)
end)

Remotes.MeteorState.OnClientEvent:Connect(function(data)
	UI.Meteor(data)
	Effects.Meteor(data)
end)

Remotes.GoldenHour.OnClientEvent:Connect(function(data)
	UI.GoldenHour(data)
end)

Remotes.StreakShow.OnClientEvent:Connect(function(data)
	UI.Streak(data)
end)

Remotes.OrbitSync.OnClientEvent:Connect(function(data)
	Orbit.Sync(data)
end)

Remotes.DailyPopup.OnClientEvent:Connect(function()
	UI.ShowPanel("Daily") -- auto-open the daily panel on join when a reward is waiting
end)

Remotes.StarterPopup.OnClientEvent:Connect(function()
	UI.Toast("⭐ Starter Pack offer in the Shop — first session only!", Color3.fromRGB(255, 222, 130))
end)

task.spawn(function()
	local snap = Remotes.GetState:InvokeServer()
	if snap then
		state = snap
		UI.Update(snap)
		PetView.Set(snap.pets and snap.pets.active)
	end
end)

-- pedestal & altar clicks open the upgrade panel locally
task.spawn(function()
	local map = workspace:WaitForChild("CrackAGeode"):WaitForChild("Map")
	local ped = map:WaitForChild("UpgradePedestal", 20)
	if ped then
		local cd = ped:FindFirstChildOfClass("ClickDetector")
		if cd then cd.MouseClick:Connect(function() UI.TogglePanel("Upgrades") end) end
	end
	local altar = map:WaitForChild("AscensionAltar", 20)
	if altar then
		local cd = altar:FindFirstChildOfClass("ClickDetector")
		if cd then cd.MouseClick:Connect(function() UI.TogglePanel("Upgrades") end) end
	end
end)
