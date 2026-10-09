-- STUB (owner: T): replace the body, keep the exports.
--[[
    Training rooms (menus design 4.11): TrainingRequest starts a training
    match against a dummy and changes its settings. Until T lands the
    request answers "Not ready.".
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)

local TrainingService = {}

function TrainingService.init(_services) end

function TrainingService.start()
	Net.get("TrainingRequest").OnServerInvoke = function()
		return false, "Not ready."
	end
end

return TrainingService
