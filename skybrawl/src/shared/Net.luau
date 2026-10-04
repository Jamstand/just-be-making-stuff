--[[
    Remote lookup. The remotes themselves are declared in
    default.project.json under ReplicatedStorage.Remotes.

    RemoteEvents
      Toast            S->C  (text, kind)
      ProfileUpdate    S->C  (profile snapshot)
      SaveSettings     C->S  (settings table)
      QueueUpdate      S->C  (queue status or nil)
      RoomUpdate       S->C  (room state or nil)
      MatchEvent       S->C  (kind, data)
      FighterAction    C->S  (kind, data)

    RemoteFunctions
      GetProfile       C->S  () -> snapshot
      QueueRequest     C->S  (action, queueType, options) -> ok, message
      RoomRequest      C->S  (action, payload) -> ok, result
      ShopRequest      C->S  (action, itemId) -> ok, message
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local folder = ReplicatedStorage:WaitForChild("Remotes")

local Net = {}

function Net.get(name)
	return folder:WaitForChild(name)
end

return Net
