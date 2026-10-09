-- STUB (owner: S1): replace the body, keep the exports.
--[[
    One friend set per player, shared by RoomService (friends-only rooms),
    PartyService (invite list) and LeaderboardService (friends rankings).
    A plain module, not a service; Main.server's PlayerRemoving coordinator
    calls onPlayerRemoving. Until S1 lands it asks Roblox each time and
    knows no friend ids.
]]

local FriendCache = {}

function FriendCache.isFriend(player, userId)
	local ok, result = pcall(function()
		return player:IsFriendsWith(userId)
	end)
	return ok and result == true
end

-- The player's friends' user ids ({} while loading).
function FriendCache.friendIds(_player)
	return {}
end

function FriendCache.forget(_player) end

function FriendCache.onPlayerRemoving(_player) end

return FriendCache
