--[[
    Client-side copies of server state (profile, queue, room) plus
    signals that UI modules listen to.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = require(Shared.Util)
local Net = require(Shared.Net)

local ClientState = {
	profile = nil,
	queue = nil,
	room = nil,
	inMatch = false,

	ProfileChanged = Util.Signal.new(),
	QueueChanged = Util.Signal.new(),
	RoomChanged = Util.Signal.new(),
	MatchChanged = Util.Signal.new(),
	Toast = Util.Signal.new(),
	OpenPanel = Util.Signal.new(),
}

function ClientState.setInMatch(value)
	if ClientState.inMatch ~= value then
		ClientState.inMatch = value
		ClientState.MatchChanged:Fire(value)
	end
end

function ClientState.toast(text, kind)
	ClientState.Toast:Fire(text, kind or "info")
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
