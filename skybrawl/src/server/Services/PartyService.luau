-- STUB (owner: S1): replace the body, keep the exports.
--[[
    Parties and invites (menus design 4.1). Until S1 lands everyone is solo:
    no party, always their own leader, and PartyRequest answers "Not ready."
    ("List" returns nobody).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)

local PartyService = {}

function PartyService.getParty(_player)
	return nil
end

-- True when solo too.
function PartyService.isLeader(_player)
	return true
end

-- { player } when solo; leader first otherwise.
function PartyService.membersOf(player)
	return { player }
end

-- "Menu" | "Queue" | "Select" | "Match" | "Training" | "Room"
function PartyService.statusOf(_player)
	return "Menu"
end

-- PartyUpdate to every member and every pending invitee.
function PartyService.push(_party) end

function PartyService.pushPlayer(_player) end

function PartyService.onPlayerRemoving(_player) end

function PartyService.init(_services) end

function PartyService.start()
	Net.get("PartyRequest").OnServerInvoke = function(_player, action)
		if action == "List" then
			return true, { players = {} }
		end
		return false, "Not ready."
	end
end

return PartyService
