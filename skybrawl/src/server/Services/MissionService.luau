-- STUB (owner: S2): replace the body, keep the exports.
--[[
    Daily missions on the server (menus design 4.8): MissionRequest
    (Reroll / Claim), the UTC rollover and season rollover loop, and match
    progress through onMatch. Until S2 lands, MissionRequest and
    GetRankings answer "Not ready." and matches move no missions
    (DataService still rolls each day's missions when a profile loads).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)

local MissionService = {}

-- Called by ProgressionService inside its DataService.update closure. Returns the missions the match moved
-- ({ MissionProgress }?) and what a day rollover paid ({ coins, xp, count }?).
function MissionService.onMatch(_profile, _info, _entry)
	return nil, nil
end

function MissionService.init(_services)
	-- Placeholder so InvokeServer never hangs before S2 lands. Bound in init, so LeaderboardService's real
	-- handler (bound in its start) replaces it. S2: delete this once LeaderboardService answers GetRankings.
	Net.get("GetRankings").OnServerInvoke = function()
		return false, "Not ready."
	end
end

function MissionService.start()
	Net.get("MissionRequest").OnServerInvoke = function()
		return false, "Not ready."
	end
end

return MissionService
