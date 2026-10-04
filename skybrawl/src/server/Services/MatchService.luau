--[[
    Creates matches, routes fighter actions to them, and cleans up when
    players leave. Queue and room services call MatchService.startMatch().

    Match config:
      mode              "1v1" | "2v2" | "FFA"
      source            "Ranked" | "Casual" | "Custom" | "Bots"
      ranked            boolean
      mapId             Maps id
      winRule           "Stocks" | "Timed"
      stocks            lives per fighter (Stocks)
      timeLimit         seconds (0 = none)
      weapons           { [weaponId] = true } allowed drops (nil = all)
      damageMultiplier  number
      friendlyFire      boolean
      participants      list of { player = Player, team = n }
                        or { bot = true, difficulty = "Normal", team = n }
      roomId            set for custom rooms
]]

local Players = game:GetService("Players")
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

function MatchService.hasFreeArena()
	return services.ArenaService.freeSlots() > 0
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

function MatchService.startMatch(config)
	if not MatchService.hasFreeArena() then
		return nil, "All arenas are busy. Try again in a moment."
	end
	nextId += 1
	local ok, match = pcall(Match.new, nextId, config, services)
	if not ok then
		warn("[MatchService] couldn't create match:", match)
		return nil, "Couldn't start the match."
	end
	for _, p in config.participants do
		if p.player then
			match:AddPlayer(p.player, p.team)
			playerMatch[p.player] = match
		elseif p.bot then
			match:AddBot(p.difficulty, p.team, p.name)
		end
	end
	match.onFinished = finished
	match.onPlayerLeft = function(player)
		if playerMatch[player] == match then
			playerMatch[player] = nil
		end
	end
	matches[match.id] = match

	task.spawn(function()
		local started, err = pcall(match.Start, match)
		if not started then
			warn("[MatchService] match failed to start:", err)
			match:Finish("Abandoned")
		end
	end)
	return match
end

function MatchService.start()
	Net.get("FighterAction").OnServerEvent:Connect(function(player, kind, data)
		local match = playerMatch[player]
		if match and type(kind) == "string" then
			match:OnAction(player, kind, data)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		local match = playerMatch[player]
		if match then
			match:RemovePlayer(player)
			playerMatch[player] = nil
		end
	end)
end

return MatchService
