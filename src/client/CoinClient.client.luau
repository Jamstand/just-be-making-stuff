local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local CoinCollected = ReplicatedStorage.Remotes.CoinCollected

local pickupSound = Instance.new("Sound")
pickupSound.SoundId = "rbxassetid://3997235257"
pickupSound.Volume = 0.6
pickupSound.Parent = SoundService

CoinCollected.OnClientEvent:Connect(function(_newTotal: number)
	pickupSound:Play()
end)
