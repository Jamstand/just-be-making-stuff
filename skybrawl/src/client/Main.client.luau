--[[
    Client entry point (menus design 5.1). Order matters: state, settings
    and Roblox's default controls first (Controls never blocks: each part
    is spawned), then input / camera / visuals, then the layout and focus
    systems, then the UI that uses them. The full-screen UIs each show in
    their own phase: TitleScreen (Title), MenuShell (Menu), LegendSelect
    (Select), VsSplash (Vs), MatchHUD (Match), ResultsScreen (Results).

    The title screen waits for game.Loaded, so the replicated FighterModels
    and AvatarModels are in place before it builds its legends.
]]

local Client = script.Parent
local Controllers = Client:WaitForChild("Controllers")
local UI = Client:WaitForChild("UI")
local Match = UI:WaitForChild("Match")

local ClientState = require(Client:WaitForChild("ClientState"))
local Settings = require(Controllers.Settings)
local Controls = require(Controllers.Controls)
local Input = require(Controllers.Input)
local CameraController = require(Controllers.CameraController)
local Visuals = require(Controllers.Visuals)
local FighterAnimator = require(Controllers.FighterAnimator)
local CharacterAnimator = require(Controllers.CharacterAnimator)
local Music = require(Controllers.Music)
local MatchClient = require(Controllers.MatchClient)

local Layout = require(UI.Layout)
local Focus = require(UI.Focus)
local Toasts = require(UI.Toasts)
local MenuShell = require(UI.MenuShell)
local LegendSelect = require(Match.LegendSelect)
local VsSplash = require(Match.VsSplash)
local ResultsScreen = require(UI.ResultsScreen)
local MatchHUD = require(UI.MatchHUD)
local TitleScreen = require(UI.TitleScreen)

ClientState.init()
Settings.init()
Controls.init() -- Controls.set(false) (each part spawned, never blocks) + chat rules
Input.init()
CameraController.init()
Visuals.init()
FighterAnimator.init()
CharacterAnimator.init()
Layout.init()
Focus.init()
Music.init()
Toasts.init() -- queues toasts while the phase is "Title"
MenuShell.init() -- builds the menu (hidden until phase "Menu")
LegendSelect.init()
VsSplash.init()
ResultsScreen.init()
MatchHUD.init()
MatchClient.init()
if not game:IsLoaded() then
	game.Loaded:Wait() -- replicated FighterModels / AvatarModels are in place
end
TitleScreen.show() -- the phase stays "Title" until any input
