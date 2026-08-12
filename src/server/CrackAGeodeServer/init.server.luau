-- Crack a Geode! server bootstrap.
-- Creates remotes, requires all service modules (children of this script), initializes in dependency order.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local existing = ReplicatedStorage:FindFirstChild("Remotes")
if existing then existing:Destroy() end
local remotes = Instance.new("Folder")
remotes.Name = "Remotes"

for _, name in ipairs({ "Announce", "CrackFX", "StatsChanged", "MeteorState", "OrbitSync", "GoldenHour", "StreakShow", "CrackRequest", "DailyPopup", "StarterPopup" }) do
	local r = Instance.new("RemoteEvent")
	r.Name = name
	r.Parent = remotes
end
for _, name in ipairs({ "GetState", "Buy", "Purchase", "HarvestGarden", "ClaimDaily", "EquipPet" }) do
	local r = Instance.new("RemoteFunction")
	r.Name = name
	r.Parent = remotes
end
remotes.Parent = ReplicatedStorage

local S = {}
S.Config = require(ReplicatedStorage:WaitForChild("Config"))
S.Remotes = remotes

for _, name in ipairs({ "Data", "Buffs", "Econ", "Geodes", "Garden", "Monetize", "Meteor", "Boards", "Pickaxe", "Onboarding", "Dailies", "Pets" }) do
	S[name] = require(script:WaitForChild(name))
end

-- init order: Data first (profiles), then buffs/econ, then world systems
S.Data.Init(S)
S.Buffs.Init(S)
S.Econ.Init(S)
S.Geodes.Init(S)
S.Garden.Init(S)
S.Monetize.Init(S)
S.Meteor.Init(S)
S.Boards.Init(S)
S.Pickaxe.Init(S)
S.Onboarding.Init(S)
S.Dailies.Init(S)
S.Pets.Init(S)

-- All modules initialized: only now may client-facing remote handlers run, so a
-- request that arrives mid-bootstrap can't call into a module before its Init.
S.Ready = true

print("[CrackAGeode] Server started — StudioTestMode purchases active until real product IDs are set in ReplicatedStorage.Config")

-- Studio-only test/debug hook: lets the command bar (a separate Luau VM) drive the
-- live services. Never active outside Studio.
local RunService = game:GetService("RunService")
if RunService:IsStudio() then
	local Players = game:GetService("Players")
	local hook = Instance.new("BindableFunction")
	hook.Name = "TestHook"
	hook.OnInvoke = function(action, ...)
		local args = { ... }
		local player = Players:GetPlayers()[1]
		if not player then return "no player" end
		local p = S.Data.WaitFor(player, 5)
		if not p then return "no profile" end
		if action == "profile" then
			local out = {}
			for k, v in pairs(p) do
				if type(v) ~= "table" then out[k] = v end
			end
			return out
		elseif action == "addGems" then
			p.gems += args[1]
			p.totalGems += args[1]
			S.Econ.Push(player)
			return p.gems
		elseif action == "crack" then
			S.Geodes.TryCrack(player, args[1] or 1)
			return { gems = p.gems, cracks = p.cracks }
		elseif action == "buy" then
			return S.Econ.Buy(player, args[1])
		elseif action == "pass" then
			p.testPasses[args[1]] = true
			S.Monetize.OnPassGranted(player, args[1])
			return S.Monetize.Owns(player, args[1])
		elseif action == "product" then
			return S.Monetize.GrantProduct(player, args[1], args[2])
		elseif action == "harvest" then
			return S.Garden.Harvest(player)
		elseif action == "gardenAge" then
			p.lastHarvest = os.time() - args[1]
			S.Garden.Refresh(player)
			S.Econ.Push(player)
			return S.Garden.Value(player)
		elseif action == "meteorDamage" then
			S.Meteor.Damage(player, args[1] or 1)
			return S.Meteor.IsActive()
		elseif action == "meteorActive" then
			return S.Meteor.IsActive()
		elseif action == "golden" then
			local handle = S.Geodes.SpawnGolden(player, false)
			task.wait(0.25)
			handle.Open(player)
			return true
		elseif action == "snapshot" then
			return S.Econ.Snapshot(player)
		end
		return "unknown action: " .. tostring(action)
	end
	hook.Parent = game:GetService("ServerStorage")
end
