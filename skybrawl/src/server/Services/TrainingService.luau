--[[
    Training rooms (menus design 4.11). TrainingRequest(action, payload):
      Start   an idle player (not searching, not in a custom room, not busy)
              gets a slot from the "Training" arena pool (training never
              blocks matchmaking) and a match against the dummy, with no
              legend select: their own legend (or payload.legend) on team 1,
              the dummy on team 2. "Timed" with no time limit never ends on
              its own; leaving ends it.
      the rest go to the player's TrainingRoom (Services/TrainingRoom.luau,
              the hook object their training Match carries): Leave, and the
              panel's controls (refused until the countdown ends)

    Every call but Leave is rate limited (token bucket,
    Config.Training.RequestsPerSecond a second, burst 10), so a player who
    mashed a hotkey can still get out at once; every call is wrapped in a
    pcall, so a bad payload can never throw. Unknown actions get false,
    "Bad request.".
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Legends = require(Shared.Legends)
local Net = require(Shared.Net)

local TrainingRoom = require(script.Parent.TrainingRoom)

local TrainingService = {}
local services

local BURST = 10
local BAD = "Bad request."

local buckets = setmetatable({}, { __mode = "k" }) -- [Player] = { tokens, at }
local starting = setmetatable({}, { __mode = "k" }) -- [Player] = true while a Start is building the match

local function takeToken(player)
	local now = os.clock()
	local bucket = buckets[player]
	if not bucket then
		bucket = { tokens = BURST, at = now }
		buckets[player] = bucket
	end
	bucket.tokens = math.min(BURST, bucket.tokens + (now - bucket.at) * Config.Training.RequestsPerSecond)
	bucket.at = now
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

-- The match config of a training room (4.11).
function TrainingService.buildConfig(player, profile, payload, room)
	local legend = if Legends.isValid(payload.legend) then payload.legend else profile.Legend
	local dummyLegend = Config.Training.DummyLegend
	if Legends.isValid(payload.dummyLegend) and payload.dummyLegend ~= "Avatar" then
		dummyLegend = payload.dummyLegend
	end
	return {
		mode = "1v1",
		source = "Training",
		ranked = false,
		mapId = Config.Training.MapId,
		winRule = "Timed",
		stocks = 0,
		timeLimit = 0,
		weapons = nil,
		damageMultiplier = 1,
		friendlyFire = false,
		autoWeapons = false,
		training = room,
		participants = {
			{
				player = player,
				team = 1,
				legend = legend,
				ownLook = profile.Settings.FightAsAvatar == true,
			},
			{
				bot = true,
				dummy = true,
				difficulty = room.difficulty,
				team = 2,
				name = Config.Training.DummyName,
				legend = dummyLegend,
			},
		},
	}
end

local function start(player, payload)
	if starting[player] then
		return false, "The training room is already loading."
	end
	local profile = services.DataService.get(player)
	if not profile then
		return false, "Your profile is still loading."
	end
	local busy = services.MatchService.busyReason(player)
	if busy then
		return false, busy
	end
	if services.QueueService.isQueued(player) then
		return false, "Cancel your search first."
	end
	if services.RoomService.getRoomOf(player) then
		return false, "Leave your custom room first."
	end

	local slot, origin = services.ArenaService.acquire("Training")
	if not slot then
		return false, "The training rooms are full. Try again in a moment."
	end
	local room = TrainingRoom.new(player)
	starting[player] = true
	local ok, match, err =
		pcall(services.MatchService.startMatch, TrainingService.buildConfig(player, profile, payload, room), {
			slot = slot,
			origin = origin,
		})
	starting[player] = nil
	if not ok or not match then
		-- a reserved slot stays ours when the match couldn't be built
		services.ArenaService.release(slot)
		if not ok then
			warn("[TrainingService] couldn't start a training room:", match)
		end
		return false, (ok and err) or "Couldn't start the training room."
	end
	return true, "Loading the training room..."
end

local function handle(player, action, payload)
	if not services then
		-- bound before init (never in Main.server's order): nothing to start a room with yet
		return false, "Not ready."
	end
	if type(action) ~= "string" or (action ~= "Start" and action ~= "Leave" and not TrainingRoom.ACTIONS[action]) then
		return false, BAD
	end
	if action ~= "Leave" and not takeToken(player) then
		return false, "Slow down."
	end
	payload = if type(payload) == "table" then payload else {}
	if action == "Start" then
		return start(player, payload)
	end
	local match = services.MatchService.getMatchOf(player)
	local room = match and match.training
	if type(room) ~= "table" or getmetatable(room) ~= TrainingRoom or room.player ~= player then
		-- (the controls' answer whenever you aren't playing in your own room, 3.1)
		return false, if action == "Leave" then "You're not in the training room." else "Wait for the countdown."
	end
	return room:Control(action, payload)
end

function TrainingService.init(s)
	services = s
end

function TrainingService.start()
	Net.get("TrainingRequest").OnServerInvoke = function(player, action, payload)
		local ok, result, message = pcall(handle, player, action, payload)
		if not ok then
			warn("[TrainingService] request failed:", result)
			return false, "Something went wrong."
		end
		return result, message
	end
end

return TrainingService
