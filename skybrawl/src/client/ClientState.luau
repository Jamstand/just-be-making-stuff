--[[
    Client-side copies of server state (profile, queue, room, party, legend
    select) plus signals that UI modules listen to.

    phase drives which full-screen UI shows:
      "Title" -> "Menu" <-> "Select" -> "Vs" -> "Match" -> "Results" -> "Menu"
    Each UI sets the phase it owns (TitleScreen, LegendSelect, VsSplash,
    MatchClient, ResultsScreen) and hides itself on any PhaseChanged away
    from its own.

    select holds the latest SelectEvent "Begin"/"Update" for you (cleared on
    a matching "Cancel" and by MatchClient on MatchEvent "Start"); vs the
    latest "Vs" (cleared on a matching "Cancel" and when the phase leaves
    "Vs"). A Cancel for another session is still relayed but changes nothing.

    SelectEvent fires (kind, data, previousSelect, previousVs) after the
    state is stored: the last two are select and vs as they were before
    this event. On a matching Cancel select and vs are already nil, so a
    listener tells whether a Cancel is for its session by comparing data.id
    with previousSelect.id / previousVs.id (or with the id it kept from
    Begin / Vs), never with ClientState.select / ClientState.vs.

    OpenScreen opens a menu screen from anywhere (deep links). OpenPanel is
    the same Signal under its old name, for LobbyUI until it is gone.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = require(Shared.Util)
local Net = require(Shared.Net)

local PHASES = { Title = true, Menu = true, Select = true, Vs = true, Match = true, Results = true }

local ClientState = {
	profile = nil,
	queue = nil,
	room = nil,
	inMatch = false,
	party = nil, -- PartyState?
	invites = {}, -- { PartyInvite }
	queueStats = { Ranked1v1 = 0, Ranked2v2 = 0, FFA = 0 },
	select = nil, -- SelectState?
	vs = nil, -- VsState?
	phase = "Title",

	ProfileChanged = Util.Signal.new(),
	QueueChanged = Util.Signal.new(),
	RoomChanged = Util.Signal.new(),
	MatchChanged = Util.Signal.new(),
	Toast = Util.Signal.new(),
	OpenScreen = Util.Signal.new(), -- (screenId, params?)
	PartyChanged = Util.Signal.new(), -- (party, invites)
	QueueStatsChanged = Util.Signal.new(), -- (stats)
	SelectEvent = Util.Signal.new(), -- (kind, data, previousSelect, previousVs), relayed after select/vs are stored
	PhaseChanged = Util.Signal.new(), -- (phase, previous)
}
-- TODO(I): remove once LobbyUI is gone.
ClientState.OpenPanel = ClientState.OpenScreen

function ClientState.setInMatch(value)
	if ClientState.inMatch ~= value then
		ClientState.inMatch = value
		ClientState.MatchChanged:Fire(value)
	end
end

function ClientState.toast(text, kind)
	ClientState.Toast:Fire(text, kind or "info")
end

function ClientState.setPhase(phase)
	if not PHASES[phase] then
		warn("[ClientState] unknown phase", phase)
		return
	end
	local previous = ClientState.phase
	if phase == previous then
		return
	end
	ClientState.phase = phase
	if previous == "Vs" then
		ClientState.vs = nil
	end
	ClientState.PhaseChanged:Fire(phase, previous)
end

function ClientState.serverNow()
	return workspace:GetServerTimeNow()
end

local function onSelectEvent(kind, data)
	if type(data) ~= "table" then
		return
	end
	local previousSelect, previousVs = ClientState.select, ClientState.vs
	if kind == "Begin" then
		ClientState.select = data
	elseif kind == "Update" then
		-- an Update only refreshes the session you are in
		if ClientState.select and ClientState.select.id == data.id then
			ClientState.select = data
		end
	elseif kind == "Vs" then
		ClientState.vs = data
	elseif kind == "Cancel" then
		if ClientState.select and ClientState.select.id == data.id then
			ClientState.select = nil
		end
		if ClientState.vs and ClientState.vs.id == data.id then
			ClientState.vs = nil
		end
	else
		return
	end
	ClientState.SelectEvent:Fire(kind, data, previousSelect, previousVs)
end

function ClientState.init()
	Net.get("ProfileUpdate").OnClientEvent:Connect(function(profile)
		ClientState.profile = profile
		ClientState.ProfileChanged:Fire(profile)
	end)
	Net.get("QueueUpdate").OnClientEvent:Connect(function(status)
		ClientState.queue = status
		ClientState.QueueChanged:Fire(status)
	end)
	Net.get("RoomUpdate").OnClientEvent:Connect(function(room)
		ClientState.room = room
		ClientState.RoomChanged:Fire(room)
	end)
	Net.get("Toast").OnClientEvent:Connect(function(text, kind)
		ClientState.toast(text, kind)
	end)
	Net.get("PartyUpdate").OnClientEvent:Connect(function(update)
		if type(update) ~= "table" then
			return
		end
		ClientState.party = update.party
		ClientState.invites = update.invites or {}
		ClientState.PartyChanged:Fire(ClientState.party, ClientState.invites)
	end)
	Net.get("QueueStats").OnClientEvent:Connect(function(stats)
		if type(stats) ~= "table" then
			return
		end
		ClientState.queueStats = stats
		ClientState.QueueStatsChanged:Fire(stats)
	end)
	Net.get("SelectEvent").OnClientEvent:Connect(onSelectEvent)

	task.spawn(function()
		local ok, profile = pcall(function()
			return Net.get("GetProfile"):InvokeServer()
		end)
		if ok and profile and not ClientState.profile then
			ClientState.profile = profile
			ClientState.ProfileChanged:Fire(profile)
		end
	end)
end

return ClientState
