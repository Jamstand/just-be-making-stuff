--[[
    Tiny SFX player. Sound ids live in Config.Sounds; volume comes from
    the SfxVolume setting.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local Settings = require(script.Parent.Settings)

local Sound = {}

local templates = {}

function Sound.play(name, volume, pitch)
	local id = Config.Sounds[name]
	if not id then
		return
	end
	local template = templates[name]
	if not template then
		template = Instance.new("Sound")
		template.Name = name
		template.SoundId = id
		templates[name] = template
	end
	local sound = template:Clone()
	sound.Volume = (volume or 0.6) * (Settings.get("SfxVolume") or 0.7)
	sound.PlaybackSpeed = pitch or 1
	sound.Parent = SoundService
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	sound:Play()
	task.delay(4, function()
		if sound.Parent then
			sound:Destroy()
		end
	end)
end

return Sound
