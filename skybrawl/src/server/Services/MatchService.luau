--[[
    Creates matches, routes fighter actions to them, and knows who is busy.
    SelectService (after legend select), TrainingService and nothing else
    call MatchService.startMatch().

    Match config (menus design 3.7):
      mode              "1v1" | "2v2" | "FFA"
      source            "Ranked" | "Casual" | "Custom" | "Bots" | "Training"
      ranked            boolean
      mapId             Maps id (the select phase fills it in)
      winRule           "Stocks" | "Timed"
      stocks            lives per fighter (Stocks)
      timeLimit         seconds (0 = none; "Timed" with 0 never ends)
      weapons           { [weaponId] = true } allowed drops (nil = all)
      damageMultiplier  number
      friendlyFire      boolean
      participants      list of { player = Player, team = n, legend?, ownLook? }
                        or { bot = true, difficulty = "Normal", team = n, name?, legend?, dummy? }
      roomId            set for custom rooms
      queueType         "Ranked1v1" | "Ranked2v2" | "FFA" | "Bots" (results: QUEUE AGAIN / REMATCH)
      botOptions        { format, difficulty, mapId? } (bots REMATCH)
      units             the queue units ({ players, joined, partyId }), re-queued after a ranked dodge
      selectId          the select session that created the match
      training          the TrainingRoom hook object (training matches only)
      autoWeapons       false = no automatic weapon drops
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)

local Match = require(script.Parent.Match)

local MatchService = {}
local services

local matches = {} -- [id] = Match
local playerMatch = {} -- [Player] = Match
local nextId = 0

function MatchService.init(s)
	services = s
end

function MatchService.getMatchOf(player)
	return playerMatch[player]
end

-- Why the player can't start anything else right now; nil when free.
function MatchService.busyReason(player)
	local match = playerMatch[player]
	if match then
		return match.training and "You're in the training room." or "You're in a match."
	end
	if services.SelectService.getSessionOf(player) then
		return "You're picking a legend."
	end
	return nil
end

-- A free slot in the "Match" pool (training rooms have their own).
function MatchService.hasFreeArena()
	return services.ArenaService.freeSlots("Match") > 0
end

local function finished(match)
	matches[match.id] = nil
	for player, m in playerMatch do
		if m == match then
			playerMatch[player] = nil
		end
	end
	if match.config.roomId then
		services.RoomService.onMatchFinished(match.config.roomId)
	end
end

--[[
    Builds the match and adds every participant, then starts it in the
    background (deferred). reserved = { slot, origin, startAt? }: an arena slot the
    caller already holds (it stays the caller's if this fails). Without it a
    "Match" slot is acquired here. Every player is marked as in this match
    before it returns. A Start that throws abandons the match at once; before
    the fight its queue units go back in their queue.
]]
function MatchService.startMatch(config, reserved)
	if not reserved and not MatchService.hasFreeArena() then
		return nil, "All arenas are busy. Try again in a moment."
	end
	nextId += 1
	local id = nextId
	local match
	local ok, err = pcall(function()
		match = Match.new(id, config, services, reserved)
		for _, p in config.participants do
			if p.player then
				match:AddPlayer(p.player, p.team, { legend = p.legend, ownLook = p.ownLook })
			elseif p.bot then
				match:AddBot(p.difficulty, p.team, p.name, p.legend, { dummy = p.dummy })
			end
		end
	end)
	if not ok then
		warn("[MatchService] couldn't create match:", err)
		if match then
			-- Match.new succeeded, adding failed: undo what it built
			if match.folder then
				pcall(function()
					match.folder:Destroy()
				end)
				match.folder = nil
			end
			if match.ownsSlot then
				services.ArenaService.release(match.slot)
			end
		end
		return nil, "The match couldn't start."
	end
	match.onFinished = finished
	match.onPlayerLeft = function(player)
		if playerMatch[player] == match then
			playerMatch[player] = nil
		end
	end
	matches[id] = match
	for _, p in config.participants do
		if p.player then
			playerMatch[p.player] = match
		end
	end

	-- Deferred: Start runs only after the caller is done (SelectService sends "Vs" first), so nothing Start sends
	-- (a Cancel when it fails at once) can arrive before it.
	task.defer(function()
		local started, startErr = pcall(match.Start, match)
		if not started then
			warn("[MatchService] match failed to start:", startErr)
			-- Our failure, not a dodge: before the fight, queue players go back in their queue with their joined
			-- time (as on a select error). Bots, custom and training matches have no queue to go back to.
			local queueType = config.queueType
			local ended, finishErr = pcall(match.Finish, match, "Abandoned", 0, {
				requeue = match.phase ~= "Playing" and queueType ~= nil and queueType ~= "Bots",
				reason = "The match couldn't start.",
			})
			if not ended then
				warn("[MatchService] couldn't end the match:", finishErr)
			end
		end
	end)
	return match
end

-- Called by Main.server's PlayerRemoving coordinator. Never yields.
function MatchService.onPlayerRemoving(player)
	local match = playerMatch[player]
	if match then
		match:RemovePlayer(player)
		playerMatch[player] = nil
	end
end

function MatchService.start()
	Net.get("FighterAction").OnServerEvent:Connect(function(player, kind, data)
		local match = playerMatch[player]
		if match and type(kind) == "string" then
			match:OnAction(player, kind, data)
		end
	end)
end

return MatchService
