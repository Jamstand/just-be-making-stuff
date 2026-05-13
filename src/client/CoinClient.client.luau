--[[
    Plays a pickup sound when the server tells us a coin was collected,
    with a louder/sparklier sound on rare (Diamond) pickups.

    Asset IDs below are public freesounds chosen to be safe-ish defaults.
    If a SoundId 404s in Studio, swap it for one from the Roblox Toolbox.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local CoinCollected = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CoinCollected")

local commonSound = Instance.new("Sound")
commonSound.SoundId = "rbxassetid://3997235257"
commonSound.Volume = 0.6
commonSound.Parent = SoundService

local rareSound = Instance.new("Sound")
rareSound.SoundId = "rbxassetid://9120144122"
rareSound.Volume = 0.9
rareSound.Parent = SoundService

CoinCollected.OnClientEvent:Connect(function(tier, isRare)
	if isRare then
		rareSound:Play()
	else
		commonSound:Play()
	end
end)
