--!strict
--[[
    Applies upgrade-tier values + game-pass perks to a player's character.

    Other services call this whenever they mutate Upgrades / Passes so the
    effects (walk speed, jump, magnet range, coin multiplier, VIP trail) are
    re-applied. The CharacterAdded hook here also re-applies on every spawn
    so the new character isn't stuck at base WalkSpeed = 16.

    Public API (via _G.CoinRush.UpgradeService):
      Reapply(player)
      GetCoinMultiplier(player) -> number
      GetMagnetRange(player) -> number
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

_G.CoinRush = _G.CoinRush or {}

local function waitForPlayerData()
	local start = os.clock()
	while not (_G.CoinRush and _G.CoinRush.PlayerData) do
		if os.clock() - start > 15 then
			warn("[UpgradeService] PlayerData not ready after 15s")
			return nil
		end
		task.wait()
	end
	return _G.CoinRush.PlayerData
end

local PlayerData = waitForPlayerData()

local function getUpgradeValue(name: string, tier: number): number
	local config = GameConfig.Upgrades[name]
	if not config then return 0 end
	if tier <= 0 then return config.BaseValue end
	local entry = config.Tiers[tier]
	if not entry then
		entry = config.Tiers[#config.Tiers]
	end
	return entry.Value
end

local UpgradeService = {}

function UpgradeService.GetCoinMultiplier(player: Player): number
	if not PlayerData then return 1 end
	local data = PlayerData.Get(player)
	if not data then return 1 end
	local mult = getUpgradeValue("Multiplier", data.Upgrades.Multiplier or 0)
	if data.Passes.DoubleCoins then
		mult *= GameConfig.GamePasses.DoubleCoins.Multiplier
	end
	if data.Passes.VIP then
		mult *= GameConfig.GamePasses.VIP.Multiplier
	end
	return mult
end

function UpgradeService.GetMagnetRange(player: Player): number
	if not PlayerData then return 0 end
	local data = PlayerData.Get(player)
	if not data then return 0 end
	local range = getUpgradeValue("Magnet", data.Upgrades.Magnet or 0)
	if data.Passes.AutoCollect then
		range = math.max(range, GameConfig.GamePasses.AutoCollect.MagnetRange)
	end
	return range
end

local function ensureVipTrail(character: Model, want: boolean)
	local rightHand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	if not rightHand or not rightHand:IsA("BasePart") then return end
	local existing = rightHand:FindFirstChild("VipTrail")
	if want and not existing then
		local a0 = Instance.new("Attachment")
		a0.Name = "VipA0"
		a0.Position = Vector3.new(0, 0.4, 0)
		a0.Parent = rightHand
		local a1 = Instance.new("Attachment")
		a1.Name = "VipA1"
		a1.Position = Vector3.new(0, -0.4, 0)
		a1.Parent = rightHand
		local trail = Instance.new("Trail")
		trail.Name = "VipTrail"
		trail.Attachment0 = a0
		trail.Attachment1 = a1
		trail.Lifetime = 0.6
		trail.MinLength = 0.05
		trail.Color = ColorSequence.new(Color3.fromRGB(255, 215, 0))
		trail.Parent = rightHand
	elseif (not want) and existing then
		existing:Destroy()
		local a0 = rightHand:FindFirstChild("VipA0")
		local a1 = rightHand:FindFirstChild("VipA1")
		if a0 then a0:Destroy() end
		if a1 then a1:Destroy() end
	end
end

function UpgradeService.Reapply(player: Player)
	if not PlayerData then return end
	local data = PlayerData.Get(player)
	if not data then return end
	local character = player.Character
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = getUpgradeValue("Speed", data.Upgrades.Speed or 0)
		humanoid.JumpPower = getUpgradeValue("Jump", data.Upgrades.Jump or 0)
	end
	ensureVipTrail(character, data.Passes.VIP == true)
end

_G.CoinRush.UpgradeService = UpgradeService

local function onCharacterAdded(player: Player, character: Model)
	-- Humanoid usually exists when CharacterAdded fires, but defend just in case.
	character:WaitForChild("Humanoid", 5)
	UpgradeService.Reapply(player)
end

local function bindPlayer(player: Player)
	if player.Character then
		onCharacterAdded(player, player.Character)
	end
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
end

Players.PlayerAdded:Connect(bindPlayer)
for _, player in Players:GetPlayers() do
	bindPlayer(player)
end
