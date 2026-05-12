local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local CoinCollected = ReplicatedStorage.Remotes.CoinCollected

local CoinsFolder = Instance.new("Folder")
CoinsFolder.Name = "Coins"
CoinsFolder.Parent = Workspace

local rng = Random.new()

local function randomCoinPosition(): Vector3
	local half = GameConfig.MapHalfSize
	local x = rng:NextNumber(-half, half)
	local z = rng:NextNumber(-half, half)
	return Vector3.new(x, GameConfig.CoinFloatHeight, z)
end

local function createCoin(): Part
	local coin = Instance.new("Part")
	coin.Name = "Coin"
	coin.Shape = Enum.PartType.Cylinder
	coin.Size = Vector3.new(0.4, 2, 2)
	coin.Material = Enum.Material.Neon
	coin.Color = Color3.fromRGB(255, 215, 0)
	coin.Anchored = true
	coin.CanCollide = false
	coin.Position = randomCoinPosition()
	coin.CFrame = CFrame.new(coin.Position) * CFrame.Angles(0, 0, math.rad(90))

	local light = Instance.new("PointLight")
	light.Color = coin.Color
	light.Brightness = 1.5
	light.Range = 8
	light.Parent = coin

	coin.Parent = CoinsFolder
	return coin
end

local function awardPlayer(player: Player)
	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then return end
	local coinsStat = leaderstats:FindFirstChild("Coins")
	if not coinsStat then return end
	coinsStat.Value += GameConfig.CoinValue
	CoinCollected:FireClient(player, coinsStat.Value)
end

local function bindCoin(coin: Part)
	local taken = false
	coin.Touched:Connect(function(hit)
		if taken then return end
		local character = hit:FindFirstAncestorOfClass("Model")
		if not character then return end
		local player = Players:GetPlayerFromCharacter(character)
		if not player then return end
		taken = true
		awardPlayer(player)
		coin:Destroy()
		task.wait(GameConfig.CoinRespawnSeconds)
		local replacement = createCoin()
		bindCoin(replacement)
	end)
end

for _ = 1, GameConfig.CoinCount do
	bindCoin(createCoin())
end

RunService.Heartbeat:Connect(function(dt)
	local spin = GameConfig.CoinSpinSpeed * dt
	for _, coin in CoinsFolder:GetChildren() do
		if coin:IsA("BasePart") then
			coin.CFrame = coin.CFrame * CFrame.Angles(spin, 0, 0)
		end
	end
end)
