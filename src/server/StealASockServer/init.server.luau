-- Steal a Sock - server bootstrap.
-- Creates the Remotes folder, requires every service module, calls Init(S) on each in
-- dependency order, then wires player join/leave. `S` is the shared service table that
-- every module receives; modules talk to each other only through it.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local RemoteNames = require(Shared:WaitForChild("RemoteNames"))

-- Remotes (server -> client only in Phase 1; see RemoteNames.luau)
local remotes = Instance.new("Folder")
remotes.Name = RemoteNames.Folder
for _, name in ipairs(RemoteNames.Events) do
	local event = Instance.new("RemoteEvent")
	event.Name = name
	event.Parent = remotes
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

-- Init order matters: each module may use the ones before it.
local ORDER = {
	"RateLimit", "Data", "Map", "Registry", "Factory", "Base", "Pair",
	"Income", "Clothesline", "Purchase", "Steal", "Towel",
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
	S.Towel.Setup(player)
	S.Income.Push(player)
	S.Toast(player, "Welcome to the laundromat! Buy socks off the clothesline. 🧦", "good")
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

Players.PlayerRemoving:Connect(function(player)
	S.Steal.OnPlayerRemoving(player) -- carried socks go home / steals of their socks fail
	S.Towel.OnPlayerRemoving(player)
	S.Base.Unassign(player) -- writes the drawer into the profile, frees the base
	S.Data.Release(player) -- ends the ProfileStore session (saves)
	S.RateLimit.Clear(player)
end)
