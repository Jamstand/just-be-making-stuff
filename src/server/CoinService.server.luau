--[[
    Spawns weighted-rarity coins, awards them on pickup, and runs the
    magnet check on Heartbeat. Honours the player's coin multiplier
    (Multiplier upgrade + DoubleCoins / VIP passes) and the Magnet upgrade
    range (AutoCollect pass overrides if larger).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local CoinCollected = ReplicatedStorage.Remotes.CoinCollected

local function waitForGlobal(name: string)
	local start = os.clock()
	while not (_G.CoinRush and _G.CoinRush[name]) do
		if os.clock() - start > 15 then
			warn(("[CoinService] %s not ready after 15s"):format(name))
			return nil
		end
		task.wait()
	end
	return _G.CoinRush[name]
end

local PlayerData = waitForGlobal("PlayerData")
local UpgradeService = waitForGlobal("UpgradeService")

local CoinsFolder = Instance.new("Folder")
CoinsFolder.Name = "Coins"
CoinsFolder.Parent = Workspace

local rng = Random.new()

local activeCoins = {} -- [Part] = tier table (entry from GameConfig.CoinTiers)

local function pickTier()
	local total = 0
	for _, tier in GameConfig.CoinTiers do
		total += tier.Weight
	end
	local roll = rng:NextNumber(0, total)
	for _, tier in GameConfig.CoinTiers do
		roll -= tier.Weight
		if roll <= 0 then return tier end
	end
	return GameConfig.CoinTiers[1]
end

local SPAWN_PAD_HALF = 4 -- a bit larger than the actual 3x3, gives breathing room
local BEACON_AVOID = 5

local function randomPosition(): Vector3
	local half = GameConfig.MapHalfSize
	local beacon = GameConfig.ShopBeaconPosition
	for _ = 1, 20 do
		local x = rng:NextNumber(-half, half)
		local z = rng:NextNumber(-half, half)
		if math.abs(x) <= SPAWN_PAD_HALF and math.abs(z) <= SPAWN_PAD_HALF then
			continue
		end
		local dx, dz = x - beacon.X, z - beacon.Z
		if (dx * dx + dz * dz) < (BEACON_AVOID * BEACON_AVOID) then
			continue
		end
		return Vector3.new(x, GameConfig.CoinFloatHeight, z)
	end
	return Vector3.new(half - 5, GameConfig.CoinFloatHeight, half - 5)
end

local function createCoin(): Part
	local tier = pickTier()
	local coin = Instance.new("Part")
	coin.Name = "Coin_" .. tier.Name
	coin.Shape = Enum.PartType.Cylinder
	coin.Size = Vector3.new(0.4, 2, 2)
	coin.Material = Enum.Material.Neon
	coin.Color = tier.Color
	coin.Anchored = true
	coin.CanCollide = false
	coin.CFrame = CFrame.new(randomPosition()) * CFrame.Angles(0, 0, math.rad(90))

	local light = Instance.new("PointLight")
	light.Color = tier.Color
	light.Brightness = 1.5
	light.Range = 8
	light.Parent = coin

	-- Tag so the client can distinguish tiers if it ever needs to.
	local tag = Instance.new("StringValue")
	tag.Name = "Tier"
	tag.Value = tier.Name
	tag.Parent = coin

	activeCoins[coin] = tier
	coin.Parent = CoinsFolder
	return coin
end

local bindCoinTouched

local function awardAndRespawn(coin: Part, player: Player)
	local tier = activeCoins[coin]
	if not tier then return end -- raced; already collected this frame
	activeCoins[coin] = nil

	if PlayerData then
		local mult = UpgradeService and UpgradeService.GetCoinMultiplier(player) or 1
		local coinsAwarded = math.floor(tier.Coins * mult + 0.5)
		if coinsAwarded > 0 then
			PlayerData.Increment(player, "Coins", coinsAwarded)
		end
		if tier.Gems > 0 then
			PlayerData.Increment(player, "Gems", tier.Gems)
		end
	end

	CoinCollected:FireClient(player, tier.Name, tier.Rare)
	coin:Destroy()

	task.delay(GameConfig.CoinRespawnSeconds, function()
		bindCoinTouched(createCoin())
	end)
end

bindCoinTouched = function(coin: Part)
	coin.Touched:Connect(function(hit)
		if not activeCoins[coin] then return end
		local character = hit:FindFirstAncestorOfClass("Model")
		if not character then return end
		local player = Players:GetPlayerFromCharacter(character)
		if not player then return end
		awardAndRespawn(coin, player)
	end)
end

for _ = 1, GameConfig.CoinCount do
	bindCoinTouched(createCoin())
end

-- Spin + magnet loop.
RunService.Heartbeat:Connect(function(dt)
	local spin = GameConfig.CoinSpinSpeed * dt
	for coin in pairs(activeCoins) do
		coin.CFrame = coin.CFrame * CFrame.Angles(spin, 0, 0)
	end

	if not UpgradeService then return end

	for _, player in Players:GetPlayers() do
		local character = player.Character
		if not character then continue end
		local root = character:FindFirstChild("HumanoidRootPart")
		if not root or not root:IsA("BasePart") then continue end

		local range = UpgradeService.GetMagnetRange(player)
		if range <= 0 then continue end

		local rootPos = root.Position
		for coin in pairs(activeCoins) do
			if (coin.Position - rootPos).Magnitude <= range then
				awardAndRespawn(coin, player)
			end
		end
	end
end)
