-- Crack a Geode! client bootstrap: wires remotes, hooks and modules (plan §3.11).
-- Anything another owner may not have shipped yet — the new remotes, the new UI
-- hooks, the new client modules — is looked up defensively: a missing piece warns
-- once and is skipped, never errors, so the client boots against an older server
-- or an older UI with zero errors.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local SG = require(ReplicatedStorage:WaitForChild("StyleGuide"))
local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local player = Players.LocalPlayer

-- ===== modules =====
-- Required modules block until they exist (they always do); the new / phase-2
-- ones get a bounded wait and degrade to nil (quiet = expected to be absent
-- until its phase lands, so no warning).
local function load(name, waitSeconds, quiet)
	local m = script:FindFirstChild(name)
	if not m and waitSeconds then m = script:WaitForChild(name, waitSeconds) end
	if not m then
		if not quiet then
			warn(("[CrackAGeode] client module %s not found — its features stay dark"):format(name))
		end
		return nil
	end
	local ok, mod = pcall(require, m)
	if not ok then
		warn(("[CrackAGeode] client module %s failed to load: %s"):format(name, tostring(mod)))
		return nil
	end
	return mod
end

local Quality = require(script:WaitForChild("Quality")) -- flags are set synchronously at require
local UI = require(script:WaitForChild("UI"))
local Effects = require(script:WaitForChild("Effects"))
local Orbit = require(script:WaitForChild("Orbit"))
local PetView = require(script:WaitForChild("PetView"))
local RegionFX = require(script:WaitForChild("RegionFX"))
local NexusFX = require(script:WaitForChild("NexusFX"))
local Signposts = require(script:WaitForChild("Signposts"))
local PickaxeFX = require(script:WaitForChild("PickaxeFX"))
local Audio = load("Audio", 5)
local Nameplates = load("Nameplates", 5)
local Feed = load("Feed", 5)         -- CM-4: activity column (+ chat mirror)
local SocialFX = load("SocialFX", 5) -- CM-5: cheer reactions

-- ===== boot (§3.11 order); one failing Init must not take the rest down =====
local function boot(name, fn, ...)
	if not fn then return end
	local ok, err = pcall(fn, ...)
	if not ok then warn(("[CrackAGeode] %s.Init failed: %s"):format(name, tostring(err))) end
end

boot("UI", UI.Init, Config, Remotes, { quality = Quality })
if Audio then
	boot("Audio", Audio.Init, Config)
	Audio.Apply(Quality.Settings) -- defaults until the first GetState seeds real settings
end
boot("Effects", Effects.Init, Config)
boot("Orbit", Orbit.Init, Config, Quality)
boot("PetView", PetView.Init, Quality)
boot("RegionFX", RegionFX.Init, Config)
boot("NexusFX", NexusFX.Init)
boot("Signposts", Signposts.Init, Quality)
boot("PickaxeFX", PickaxeFX.Init)
if Nameplates then boot("Nameplates", Nameplates.Init, Quality) end
if Feed then boot("Feed", Feed.Init, Config, Quality) end
if SocialFX then boot("SocialFX", SocialFX.Init, Config, Quality) end
task.spawn(Quality.Init)

-- ===== hooks (assigned ONLY here; every callee nil-checks) =====
UI.OnCrackInput = PickaxeFX.Swing        -- CRACK button / hold loop → instant swing
Effects.OnCrackInput = PickaxeFX.Swing   -- Tool.Activated → instant swing (same gate)
PickaxeFX.SetCooldownSource(UI.CrackReadyAt) -- nil on a legacy UI → gate off

if SocialFX and SocialFX.Send then UI.OnCheer = SocialFX.Send end

local function applySettings(s)
	local settings = Quality.ApplySettings(s)
	if Audio then Audio.Apply(settings) end
	if Feed and Feed.SetHidden then Feed.SetHidden(settings.hideFeed == true) end
	if SocialFX and SocialFX.SetEnabled then SocialFX.SetEnabled(settings.socialPings ~= false) end
	Effects.ApplyReduceFX(settings.reduceFx == true)
end
UI.OnSettingsChanged = applySettings

local function openProfile(userId)
	if UI.OpenProfile then UI.OpenProfile(userId) end
end
if Nameplates then Nameplates.OnTap = openProfile end
if Feed then Feed.OnTapUser = openProfile end

RegionFX.OnChanged = function(zoneKey)
	if UI.SetZone then UI.SetZone(zoneKey) end
end

-- ===== chat tags: [R12] / [A2] in the tier colour, then the gold [VIP] =====
-- (server sets the attributes; this client-side hook formats incoming chat)
local tierHex = SG.TierHex or function() return "#FFFFFF" end
pcall(function()
	TextChatService.OnIncomingMessage = function(message)
		local props = Instance.new("TextChatMessageProperties")
		local src = message.TextSource
		if src then
			local sender = Players:GetPlayerByUserId(src.UserId)
			if sender then
				local prefix = ""
				local rebirths = sender:GetAttribute("Rebirths")
				local ascensions = sender:GetAttribute("Ascensions")
				if type(ascensions) == "number" and ascensions > 0 then
					prefix = ("<font color='%s'>[A%d]</font> "):format(tierHex(rebirths, ascensions), math.floor(ascensions))
				elseif type(rebirths) == "number" and rebirths > 0 then
					prefix = ("<font color='%s'>[R%d]</font> "):format(tierHex(rebirths, ascensions), math.floor(rebirths))
				end
				if sender:GetAttribute("IsVIP") then
					prefix = prefix .. "<font color='#FFD24D'>[VIP]</font> "
				end
				if prefix ~= "" then
					props.PrefixText = prefix .. message.PrefixText
				end
			end
		end
		return props
	end
end)

-- ===== remotes =====
local function remote(name, isNew)
	local r = Remotes:FindFirstChild(name)
	if not r and isNew then r = Remotes:WaitForChild(name, 5) end
	if not r then warn(("[CrackAGeode] remote %s missing — skipping its wiring"):format(name)) end
	return r
end
local function on(name, isNew, handler)
	local r = remote(name, isNew)
	if r and r:IsA("RemoteEvent") then r.OnClientEvent:Connect(handler) end
	return r
end

local latestSnap = nil
local settingsSeeded = false

local function onSnapshot(snap, fromGetState)
	latestSnap = snap
	UI.Update(snap)
	PetView.Set(snap.pets and snap.pets.active)
	NexusFX.Update(snap)
	if fromGetState then
		if Feed and Feed.Seed and type(snap.feed) == "table" then Feed.Seed(snap.feed) end
		if UI.ServerGoal and type(snap.serverGoal) == "table" then UI.ServerGoal(snap.serverGoal) end
		if not settingsSeeded then
			settingsSeeded = true
			local s = snap.settings
			if type(s) ~= "table" then s = (Config.Social and Config.Social.SettingsDefault) or {} end
			applySettings(s) -- == UI.OnSettingsChanged(snap.settings), once
		end
	end
end

on("StatsChanged", false, function(snap)
	if type(snap) ~= "table" then return end
	onSnapshot(snap, false)
end)

on("Announce", false, function(data)
	if type(data) ~= "table" then return end
	if Feed and Feed.Push then Feed.Push(data) end
	-- legacy UI.Banner indexes colorRGB as {r,g,b} positional; the new server may
	-- send it keyed. Only the legacy UI (no Announce alias) needs the shim.
	if not UI.Announce and type(data.colorRGB) == "table" and data.colorRGB[1] == nil and data.colorRGB.r then
		data.colorRGB = { data.colorRGB.r, data.colorRGB.g, data.colorRGB.b }
	end
	UI.Banner(data)
end)

on("CrackFX", false, function(data)
	if type(data) ~= "table" then return end
	local isMine = data.userId == player.UserId
	Effects.Crack(data, isMine)
	PickaxeFX.OnCrack(data, isMine) -- impact moment / other players' swings
	UI.OnCrack(data)
end)

on("MeteorState", false, function(data)
	if type(data) ~= "table" then return end
	UI.Meteor(data)
	Effects.Meteor(data)
end)

on("GoldenHour", false, function(data)
	if type(data) ~= "table" then return end
	UI.GoldenHour(data)
end)

on("StreakShow", false, function(data)
	if type(data) ~= "table" then return end
	UI.Streak(data)
end)

on("OrbitSync", false, function(data)
	Orbit.Sync(data)
end)

-- Server payload { returning = (p.onboardDone == true), claimable = true }, fired 3 s after
-- join and only when a reward is claimable. Lead decision B.1: RETURNING players get the
-- Daily panel auto-opened when nothing else is open; first-session players only get the
-- glow + "Open" toast. An older server fires it with no payload: infer from the snapshot.
on("DailyPopup", false, function(payload)
	if not UI.DailyReady then
		UI.ShowPanel("Daily") -- legacy UI: the old auto-open
		return
	end
	UI.DailyReady() -- glow + "Open" toast
	local function autoOpen()
		if UI.AnyPanelOpen and UI.AnyPanelOpen() then return end
		UI.ShowPanel("Daily")
	end
	if type(payload) == "table" then
		if payload.returning == true then autoOpen() end -- already server-timed (3 s after join)
		return
	end
	task.delay(3, function() -- no payload (older server): onboarding done + not the first session
		local s = latestSnap
		if s ~= nil and s.onboard == nil and s.starterOffered ~= true then autoOpen() end
	end)
end)

on("StarterPopup", false, function()
	if UI.StarterReady then
		UI.StarterReady()
	else
		UI.Toast("⭐ Starter Pack offer in the Shop — first session only!", Color3.fromRGB(255, 222, 130))
	end
end)

-- new remotes: bounded waits off the boot thread (an old server has none of them)
task.spawn(function()
	on("Cheer", true, function(data)
		if type(data) ~= "table" then return end
		if SocialFX and SocialFX.OnCheer then SocialFX.OnCheer(data) end
		if Feed and Feed.PushCheer then Feed.PushCheer(data) end
		-- the "X cheered you!" toast honours the same gates as the pop + feed row: a blocked
		-- sender or Social pings off must never reach the target (SocialFX caches the block list)
		if data.toUserId == player.UserId and UI.OnCheerReceived then
			local muted = false
			if SocialFX then
				if SocialFX.IsBlocked and SocialFX.IsBlocked(data.fromUserId) then muted = true end
				if SocialFX.IsEnabled and not SocialFX.IsEnabled() then muted = true end
			end
			if not muted then UI.OnCheerReceived(data) end
		end
	end)
end)
task.spawn(function()
	on("ServerGoal", true, function(data)
		if type(data) ~= "table" then return end
		if UI.ServerGoal then UI.ServerGoal(data) end
	end)
end)

-- initial state: retry up to 3× with 1 s backoff; a reply counts as a snapshot
-- only when it carries gems (S.Guard rejects with nil while the server boots)
task.spawn(function()
	local gs = remote("GetState", false)
	if not (gs and gs:IsA("RemoteFunction")) then return end
	for attempt = 1, 3 do
		local ok, snap = pcall(function() return gs:InvokeServer() end)
		if ok and type(snap) == "table" and snap.gems ~= nil then
			onSnapshot(snap, true)
			return
		end
		if attempt < 3 then task.wait(1) end
	end
	warn("[CrackAGeode] GetState returned no snapshot after 3 attempts — waiting for StatsChanged")
end)

-- pedestal & altar clicks open the upgrade panel locally
task.spawn(function()
	local map = workspace:WaitForChild("CrackAGeode"):WaitForChild("Map")
	local ped = map:WaitForChild("UpgradePedestal", 20)
	if ped then
		local cd = ped:FindFirstChildOfClass("ClickDetector")
		if cd then cd.MouseClick:Connect(function() UI.TogglePanel("Upgrades") end) end
	end
	local altar = map:WaitForChild("AscensionAltar", 20)
	if altar then
		local cd = altar:FindFirstChildOfClass("ClickDetector")
		if cd then cd.MouseClick:Connect(function() UI.TogglePanel("Upgrades") end) end
	end
end)
