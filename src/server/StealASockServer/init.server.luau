-- Steal a Sock - server bootstrap.
-- Creates the Remotes folder, requires every service module, calls Init(S) on each in
-- dependency order, then wires player join/leave. `S` is the shared service table that
-- every module receives; modules talk to each other only through it.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local RemoteNames = require(Shared:WaitForChild("RemoteNames"))

-- Remotes (see RemoteNames.luau). The menu RemoteFunctions get their handlers in the modules
-- that own them (Upgrades, Monetize, Purchase, Data, Dex, Items).
local remotes = Instance.new("Folder")
remotes.Name = RemoteNames.Folder
for _, name in ipairs(RemoteNames.Events) do
	local event = Instance.new("RemoteEvent")
	event.Name = name
	event.Parent = remotes
end
for _, name in ipairs(RemoteNames.Functions) do
	local fn = Instance.new("RemoteFunction")
	fn.Name = name
	fn.Parent = remotes
end
remotes.Parent = ReplicatedStorage

local S = {
	Ready = false,
	Remotes = remotes,
	Util = require(Shared:WaitForChild("Util")),
	Config = {
		Economy = require(ConfigFolder:WaitForChild("EconomyConfig")),
		Rarity = require(ConfigFolder:WaitForChild("RarityConfig")),
		Mutation = require(ConfigFolder:WaitForChild("MutationConfig")),
		Sock = require(ConfigFolder:WaitForChild("SockConfig")),
		Event = require(ConfigFolder:WaitForChild("EventConfig")),
		Shop = require(ConfigFolder:WaitForChild("ShopConfig")),
		Store = require(ConfigFolder:WaitForChild("StoreConfig")),
		Settings = require(ConfigFolder:WaitForChild("SettingsConfig")),
		Dex = require(ConfigFolder:WaitForChild("DexConfig")),
		Item = require(ConfigFolder:WaitForChild("ItemConfig")),
	},
}

-- Short message for one player. kind: "info" | "good" | "bad"
function S.Toast(player: Player, text: string, kind: string?)
	if player.Parent == Players then
		remotes.Toast:FireClient(player, text, kind or "info")
	end
end

-- Server-wide banner.
function S.Announce(text: string, color: Color3?)
	remotes.Announce:FireAllClients(text, color)
end

-- One-shot particle effect at a world position, played by every client (see StealASockClient.SockFX).
function S.FX(kind: string, position: Vector3, color: Color3?)
	remotes.FX:FireAllClients(kind, position, color)
end

-- A big UI moment for one player: confetti, a banner, a sound (see Types.CelebrateKind).
function S.Celebrate(player: Player, kind: string, data: { [string]: any }?)
	if player.Parent == Players then
		remotes.Celebrate:FireClient(player, kind, data or {})
	end
end

-- Init order matters: each module may use the ones before it.
local ORDER = {
	"RateLimit", "Data", "Lighting", "Map", "Registry", "Factory", "Base", "Pair",
	"Income", "Clothesline", "Purchase", "Steal", "Towel", "Upgrades", "Dex", "Monetize", "Items",
}
for _, name in ipairs(ORDER) do
	S[name] = require(script:WaitForChild(name))
end
for _, name in ipairs(ORDER) do
	S[name].Init(S)
end
S.Ready = true
print("[StealASock] server ready")

local function onPlayerAdded(player: Player)
	if not S.Data.Load(player) then
		return -- kicked with a message
	end
	if player.Parent ~= Players then
		S.Data.Release(player)
		return
	end
	if not S.Base.Assign(player) then
		player:Kick("This server is full - no free drawer. Please try another server!")
		S.Data.Release(player)
		return
	end
	S.Steal.Setup(player)
	S.Items.Setup(player) -- the item bar: Towel Snap + loadout tools on every spawn
	S.Dex.Setup(player) -- records the socks already in the drawer (no rewards for those)
	S.Monetize.Setup(player) -- game pass ownership, VIP tag, Golden Towel, slot row, pending drops
	S.Income.Push(player)
	S.Toast(player, "Welcome to the laundromat! Buy socks off the clothesline. 🧦", "good")
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

Players.PlayerRemoving:Connect(function(player)
	S.Items.OnPlayerRemoving(player) -- out of the basket / bubble, their peel, duck and clouds go
	S.Steal.OnPlayerRemoving(player) -- carried socks go home / steals of their socks fail
	S.Towel.OnPlayerRemoving(player)
	S.Monetize.OnPlayerRemoving(player)
	S.Base.Unassign(player) -- writes the drawer into the profile, frees the base
	S.Data.Release(player) -- ends the ProfileStore session (saves)
	S.RateLimit.Clear(player)
end)
