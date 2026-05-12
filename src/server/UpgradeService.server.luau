-- Applies upgrade effects on character spawn and exposes lookups for
-- multipliers and magnet radius. GamePass perks stack on top.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local UpgradeService = {}

local function waitForData()
	while not _G.PlayerDataService do task.wait(0.1) end
end

local function getPassMultiplier(data): number
	local m = 1
	if data.OwnedPasses.DoubleCoins then
		m *= GameConfig.GamePasses.DoubleCoins.Multiplier
	end
	if data.OwnedPasses.VIP then
		m *= GameConfig.GamePasses.VIP.Multiplier
	end
	return m
end

function UpgradeService.GetCoinMultiplier(player: Player): number
	local data = _G.PlayerDataService.Get(player)
	if not data then return 1 end
	local tier = data.Upgrades.Multiplier or 0
	local base = GameConfig.Upgrades.Multiplier.Base
	local per = GameConfig.Upgrades.Multiplier.PerTier
	return (base + per * tier) * getPassMultiplier(data)
end

function UpgradeService.GetMagnetRadius(player: Player): number
	local data = _G.PlayerDataService.Get(player)
	if not data then return 0 end
	local tier = data.Upgrades.Magnet or 0
	local r = GameConfig.Upgrades.Magnet.Base + GameConfig.Upgrades.Magnet.PerTier * tier
	if data.OwnedPasses.AutoCollect then
		r = math.max(r, GameConfig.GamePasses.AutoCollect.Radius)
	end
	return r
end

local function applyToCharacter(player: Player, character: Model)
	local data = _G.PlayerDataService.Get(player)
	if not data then return end
	local humanoid = character:WaitForChild("Humanoid", 5)
	if not humanoid then return end

	local speedTier = data.Upgrades.Speed or 0
	humanoid.WalkSpeed = GameConfig.Upgrades.Speed.Base + GameConfig.Upgrades.Speed.PerTier * speedTier

	local jumpTier = data.Upgrades.Jump or 0
	humanoid.JumpPower = GameConfig.Upgrades.Jump.Base + GameConfig.Upgrades.Jump.PerTier * jumpTier
	humanoid.UseJumpPower = true

	if data.OwnedPasses.VIP then
		local root = character:FindFirstChild("HumanoidRootPart")
		if root and not root:FindFirstChild("VIPTrail") then
			local a0 = Instance.new("Attachment")
			a0.Name = "VIPTrailA0"; a0.Position = Vector3.new(0, 1, 0); a0.Parent = root
			local a1 = Instance.new("Attachment")
			a1.Name = "VIPTrailA1"; a1.Position = Vector3.new(0, -1, 0); a1.Parent = root
			local trail = Instance.new("Trail")
			trail.Name = "VIPTrail"
			trail.Attachment0 = a0
			trail.Attachment1 = a1
			trail.Lifetime = 0.6
			trail.Color = ColorSequence.new(Color3.fromRGB(255, 215, 0))
			trail.LightEmission = 0.6
			trail.Parent = root
		end
	end

	-- Expose magnet radius to client via attribute
	player:SetAttribute("MagnetRadius", UpgradeService.GetMagnetRadius(player))
end

function UpgradeService.Reapply(player: Player)
	local character = player.Character
	if character then applyToCharacter(player, character) end
end

local function bind(player: Player)
	if player.Character then applyToCharacter(player, player.Character) end
	player.CharacterAdded:Connect(function(character)
		applyToCharacter(player, character)
	end)
end

waitForData()
Players.PlayerAdded:Connect(bind)
for _, player in Players:GetPlayers() do task.spawn(bind, player) end

_G.UpgradeService = UpgradeService
