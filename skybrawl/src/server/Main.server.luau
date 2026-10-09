--[[
    Server entry point. Requires every service, wires them together, then
    starts them. Services talk to each other through the shared `services`
    table passed to init(), which avoids circular requires.

    Players.PlayerRemoving has ONE connection, here: it calls each service's
    onPlayerRemoving(player) in REMOVAL_ORDER, so a leaver is taken out of
    select, match, queue, room and party before their profile is saved
    (DataService last; its save is deferred). Handlers never yield and
    services never connect PlayerRemoving themselves.
]]

local Players = game:GetService("Players")

local Services = script.Parent:WaitForChild("Services")

local ORDER = {
	-- CharacterService registers collision groups that ArenaService's parts use.
	"CharacterService",
	"ArenaService",
	"DataService",
	"LeaderboardService",
	"ProgressionService",
	"MissionService",
	"ShopService",
	"MatchService",
	"SelectService",
	"PartyService",
	"QueueService",
	"RoomService",
	"TrainingService",
}

local REMOVAL_ORDER = {
	"SelectService",
	"MatchService",
	"QueueService",
	"RoomService",
	"PartyService",
	"LeaderboardService",
	"FriendCache",
	"CharacterService",
	"DataService",
}

local services = {}
for _, name in ORDER do
	services[name] = require(Services:WaitForChild(name))
end
-- A plain module, not a service (no init/start), but it takes part in the PlayerRemoving coordinator.
services.FriendCache = require(Services:WaitForChild("FriendCache"))

for _, name in ORDER do
	local service = services[name]
	if service.init then
		service.init(services)
	end
end

for _, name in ORDER do
	local service = services[name]
	if service.start then
		task.spawn(service.start)
	end
end

Players.PlayerRemoving:Connect(function(player)
	for _, name in REMOVAL_ORDER do
		local service = services[name]
		if service and service.onPlayerRemoving then
			local ok, err = pcall(service.onPlayerRemoving, player)
			if not ok then
				warn("[Main] " .. name .. ".onPlayerRemoving failed:", err)
			end
		end
	end
end)
