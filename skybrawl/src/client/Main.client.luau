--[[
    Client entry point. Order matters a little: state and settings first,
    then input/camera/visuals, then the UI that uses them.
]]

local Client = script.Parent
local Controllers = Client:WaitForChild("Controllers")
local UI = Client:WaitForChild("UI")

local ClientState = require(Client:WaitForChild("ClientState"))
local Settings = require(Controllers.Settings)
local Input = require(Controllers.Input)
local CameraController = require(Controllers.CameraController)
local Visuals = require(Controllers.Visuals)
local FighterAnimator = require(Controllers.FighterAnimator)
local CharacterAnimator = require(Controllers.CharacterAnimator)
local MatchClient = require(Controllers.MatchClient)

local Toasts = require(UI.Toasts)
local LobbyUI = require(UI.LobbyUI)
local MatchHUD = require(UI.MatchHUD)

ClientState.init()
Settings.init()
Input.init()
CameraController.init()
Visuals.init()
FighterAnimator.init()
CharacterAnimator.init()
Toasts.init()
LobbyUI.init()
MatchHUD.init()
MatchClient.init()
