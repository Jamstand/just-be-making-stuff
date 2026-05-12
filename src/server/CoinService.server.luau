-- Spawns coins of varying tiers around the map. On pickup, awards coins
-- (with multiplier from upgrades + gamepasses) and occasionally gems.
-- Magnet upgrade pulls in coins within a radius without needing Touched.

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

local function waitForServices()
	while not (_G.PlayerDataService and _G.UpgradeService) do task.wait(0.1) end
end

local tierOrder = {}
local totalWeight = 0
for name, info in GameConfig.CoinTiers do
	table.insert(tierOrder, { Name = name, Info = info })
	totalWeight += info.Weight
end

local function rollTier()
	local roll = rng:NextNumber(0, totalWeight)
	local acc = 0
	for _, entry in tierOrder do
		acc += entry.Info.Weight
		if roll <= acc then return entry.Name, entry.Info end
	end
	return tierOrder[1].Name, tierOrder[1].Info
end

local function randomPosition(): Vector3
	local half = GameConfig.MapHalfSize
	return Vector3.new(rng:NextNumber(-half, half), GameConfig.CoinFloatHeight, rng:NextNumber(-half, half))
end

local function buildCoin(tierName: string, tierInfo): Part
	local coin = Instance.new("Part")
	coin.Name = "Coin_" .. tierName
	coin.Shape = Enum.PartType.Cylinder
	local s = tierInfo.Size
	coin.Size = Vector3.new(0.4, s, s)
	coin.Material = Enum.Material.Neon
	coin.Color = tierInfo.Color
	coin.Anchored = true
	coin.CanCollide = false
	coin.Position = randomPosition()
	coin.CFrame = CFrame.new(coin.Position) * CFrame.Angles(0, 0, math.rad(90))

	coin:SetAttribute("Tier", tierName)
	coin:SetAttribute("Value", tierInfo.Value)
	coin:SetAttribute("GemReward", tierInfo.GemReward or 0)
	coin:SetAttribute("Taken", false)

	local light = Instance.new("PointLight")
	light.Color = tierInfo.Color
	light.Brightness = 2
	light.Range = 10
	light.Parent = coin

	coin.Parent = CoinsFolder
	return coin
end

local collectCoin
local function spawnCoin()
	local name, info = rollTier()
	local coin = buildCoin(name, info)

	local conn
	conn = coin.Touched:Connect(function(hit)
		local character = hit:FindFirstAncestorOfClass("Model")
		if not character then return end
		local player = Players:GetPlayerFromCharacter(character)
		if player then collectCoin(coin, player, conn) end
	end)
	coin:SetAttribute("ConnId", tostring(conn))
end

collectCoin = function(coin: Part, player: Player, conn: RBXScriptConnection?)
	if coin:GetAttribute("Taken") then return end
	coin:SetAttribute("Taken", true)
	if conn then conn:Disconnect() end

	local baseValue = coin:GetAttribute("Value") or 1
	local gemReward = coin:GetAttribute("GemReward") or 0
	local multiplier = _G.UpgradeService.GetCoinMultiplier(player)
	local award = math.floor(baseValue * multiplier + 0.5)

	_G.PlayerDataService.AddCoins(player, award)
	if gemReward > 0 then _G.PlayerDataService.AddGems(player, gemReward) end
	CoinCollected:FireClient(player, coin:GetAttribute("Tier"), award, gemReward)
	coin:Destroy()

	task.delay(GameConfig.CoinRespawnSeconds, spawnCoin)
end

waitForServices()
for _ = 1, GameConfig.TotalCoins do spawnCoin() end

local function magnetSweep()
	for _, player in Players:GetPlayers() do
		local radius = _G.UpgradeService.GetMagnetRadius(player)
		if radius <= 0 then continue end
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then continue end
		local origin = root.Position
		local rSq = radius * radius
		for _, coin in CoinsFolder:GetChildren() do
			if coin:IsA("BasePart") and not coin:GetAttribute("Taken") then
				local d = coin.Position - origin
				if d:Dot(d) <= rSq then
					collectCoin(coin, player)
				end
			end
		end
	end
end

RunService.Heartbeat:Connect(function(dt)
	local spin = GameConfig.CoinSpinSpeed * dt
	for _, coin in CoinsFolder:GetChildren() do
		if coin:IsA("BasePart") then
			coin.CFrame = coin.CFrame * CFrame.Angles(spin, 0, 0)
		end
	end
	magnetSweep()
end)
