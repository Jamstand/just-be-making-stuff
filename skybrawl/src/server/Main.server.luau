--[[
    Server entry point. Requires every service, wires them together, then
    starts them. Services talk to each other through the shared `services`
    table passed to init(), which avoids circular requires.
]]

local Services = script.Parent:WaitForChild("Services")

local ORDER = {
	-- CharacterService registers collision groups that ArenaService's parts use.
	"CharacterService",
	"ArenaService",
	"DataService",
	"LeaderboardService",
	"ProgressionService",
	"ShopService",
	"MatchService",
	"QueueService",
	"RoomService",
}

local services = {}
for _, name in ORDER do
	services[name] = require(Services:WaitForChild(name))
end

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
