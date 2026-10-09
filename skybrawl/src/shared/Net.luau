--[[
    Remote lookup. The remotes themselves are declared in
    default.project.json under ReplicatedStorage.Remotes. Payload types
    (QueueStatus, PartyUpdate, SelectState, RankingsData...) are spelled out
    in the menus design (section 3.1).

    RemoteEvents
      Toast            S->C  (text, kind)
      ProfileUpdate    S->C  (profile snapshot)
      SaveSettings     C->S  (settings table)
      QueueUpdate      S->C  (queue status or nil)
      QueueStats       S->C  (players searching per queue)
      RoomUpdate       S->C  (room state or nil)
      MatchEvent       S->C  (kind, data); data.matchId on every event
      FighterAction    C->S  (kind, data)
      PartyUpdate      S->C  ({ party, invites }): your whole party state
      SelectEvent      S->C  (kind: Begin/Update/Vs/Cancel, data)
      SelectAction     C->S  (kind: Hover/Lock/Unlock/Look/Vote, data)

    RemoteFunctions
      GetProfile       C->S  () -> snapshot
      QueueRequest     C->S  (action, queueType, options) -> ok, message
      RoomRequest      C->S  (action, payload) -> ok, result
      ShopRequest      C->S  (action, itemId) -> ok, message
      SelectLegend     C->S  (legendId) -> ok, message
      PartyRequest     C->S  (action, payload) -> ok, result
      MissionRequest   C->S  (action: Reroll/Claim, index) -> ok, message
      GetRankings      C->S  ({ mode, scope, season? }) -> ok, rankings data or message
      TrainingRequest  C->S  (action, payload) -> ok, message
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local folder = ReplicatedStorage:WaitForChild("Remotes")

local Net = {}

function Net.get(name)
	return folder:WaitForChild(name)
end

return Net
