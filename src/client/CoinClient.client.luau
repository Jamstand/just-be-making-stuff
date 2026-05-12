local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local CoinCollected = ReplicatedStorage.Remotes.CoinCollected

local function makeSound(id: string, volume: number): Sound
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume
	s.Parent = SoundService
	return s
end

local pickup = makeSound("rbxassetid://3997235257", 0.5)
local pickupRare = makeSound("rbxassetid://9120144122", 0.7)

CoinCollected.OnClientEvent:Connect(function(tierName: string)
	if tierName == "Diamond" or tierName == "Gold" then
		pickupRare:Play()
	else
		pickup:Play()
	end
end)
