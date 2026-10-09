--[[
    Menu music (menus design 5.12): one looping Sound in SoundService with
    Config.Music.Menu (nothing at all when it is ""). Its volume is
    Config.Music.Volume times the MusicVolume setting and follows the
    setting. It plays on the title, menus, legend select, VS splash and
    results; it fades out over Config.Music.FadeSeconds when a match starts
    and back in when the match is over.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local Client = script.Parent.Parent
local ClientState = require(Client:WaitForChild("ClientState"))
local Settings = require(script.Parent:WaitForChild("Settings"))
local UIKit = require(Client:WaitForChild("UI"):WaitForChild("UIKit"))

local Music = {}

local SETTING_FADE = 0.2

local sound = nil
local started = false
local fadeToken = 0

local function targetVolume()
	local setting = Settings.get("MusicVolume")
	setting = if type(setting) == "number" and setting == setting then math.clamp(setting, 0, 1) else 0.5
	return Config.Music.Volume * setting
end

local function apply(seconds)
	if not sound then
		return
	end
	local playing = ClientState.phase ~= "Match"
	local volume = if playing then targetVolume() else 0
	fadeToken += 1
	local token = fadeToken
	if playing and not sound.IsPlaying then
		if started then
			sound:Resume()
		else
			started = true
			sound:Play()
		end
	end
	local tween = TweenService:Create(sound, TweenInfo.new(math.max(seconds, 0.01)), { Volume = volume })
	tween.Completed:Connect(function()
		if token == fadeToken and not playing then
			sound:Pause()
		end
	end)
	tween:Play()
end

function Music.init()
	local id = UIKit.assetId(Config.Music.Menu)
	if id == "" then
		return
	end
	sound = Instance.new("Sound")
	sound.Name = "SkybrawlMenuMusic"
	sound.SoundId = id
	sound.Looped = true
	sound.Volume = 0
	sound.Parent = SoundService
	ClientState.PhaseChanged:Connect(function()
		apply(Config.Music.FadeSeconds)
	end)
	Settings.Changed:Connect(function(key)
		if key == "MusicVolume" then
			apply(SETTING_FADE)
		end
	end)
	apply(Config.Music.FadeSeconds)
end

return Music
