--[[
    Lobby screen: profile card, coins, the bottom menu, queue/room banners,
    and the panels (Play, Custom Rooms, Fighters, Shop, Profile, Settings).
    Hidden while you're in a match.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Ranks = require(Shared.Ranks)
local Util = require(Shared.Util)
local Net = require(Shared.Net)

local UIKit = require(script.Parent.UIKit)
local ClientState = require(script.Parent.Parent.ClientState)
local PlayPanel = require(script.Parent.PlayPanel)
local RoomsPanel = require(script.Parent.RoomsPanel)
local ShopPanel = require(script.Parent.ShopPanel)
local FightersPanel = require(script.Parent.FightersPanel)
local ProfilePanel = require(script.Parent.ProfilePanel)
local SettingsPanel = require(script.Parent.SettingsPanel)

local T = UIKit.Theme
local make = UIKit.make

local LobbyUI = {}

local player = Players.LocalPlayer
local gui = nil
local panels = {}
local openName = nil
local refreshBanners = function() end

local function closeAll()
	for _, panel in panels do
		panel.close()
	end
	openName = nil
	refreshBanners()
end

function LobbyUI.open(name)
	if ClientState.inMatch then
		return
	end
	local panel = panels[name]
	if not panel then
		return
	end
	if openName == name then
		closeAll()
		return
	end
	closeAll()
	openName = name
	panel.open()
	refreshBanners()
end

local function buildTopBar()
	local card = UIKit.panel({
		Name = "ProfileCard",
		Position = UDim2.fromOffset(12, 12),
		Size = UDim2.fromOffset(300, 74),
		BackgroundColor3 = T.PanelDark,
		BackgroundTransparency = 0.1,
		Parent = gui,
	})
	local avatar = make("ImageLabel", {
		BackgroundColor3 = T.PanelLight,
		Position = UDim2.fromOffset(10, 10),
		Size = UDim2.fromOffset(54, 54),
		Image = "",
		Parent = card,
	}, { UIKit.corner(27) })
	task.spawn(function()
		local ok, image = pcall(function()
			return Players:GetUserThumbnailAsync(
				player.UserId,
				Enum.ThumbnailType.HeadShot,
				Enum.ThumbnailSize.Size100x100
			)
		end)
		if ok then
			avatar.Image = image
		end
	end)
	local name = UIKit.heading(player.DisplayName, 20, {
		Position = UDim2.fromOffset(74, 8),
		Size = UDim2.new(1, -84, 0, 24),
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextWrapped = false,
		Parent = card,
	})
	local levelText = UIKit.label("Level 1", 13, {
		Position = UDim2.fromOffset(74, 32),
		Size = UDim2.new(1, -84, 0, 16),
		Font = T.BoldFont,
		TextColor3 = T.Gold,
		Parent = card,
	})
	local barBack = make("Frame", {
		BackgroundColor3 = T.PanelLight,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(74, 52),
		Size = UDim2.new(1, -86, 0, 10),
		Parent = card,
	}, { UIKit.corner(5) })
	local barFill = make("Frame", {
		BackgroundColor3 = T.Gold,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(0, 1),
		Parent = barBack,
	}, { UIKit.corner(5) })

	local coins = UIKit.panel({
		Name = "Coins",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 12),
		Size = UDim2.fromOffset(160, 44),
		BackgroundColor3 = T.PanelDark,
		BackgroundTransparency = 0.1,
		Parent = gui,
	})
	local coinIcon = make("Frame", {
		BackgroundColor3 = T.Gold,
		Position = UDim2.fromOffset(10, 10),
		Size = UDim2.fromOffset(24, 24),
		Parent = coins,
	}, { UIKit.corner(12), UIKit.stroke(Color3.fromRGB(255, 240, 180), 2, 0) })
	coinIcon.BorderSizePixel = 0
	local coinText = UIKit.heading("0", 22, {
		Position = UDim2.fromOffset(42, 0),
		Size = UDim2.new(1, -50, 1, 0),
		Parent = coins,
	})

	local function render(profile)
		if not profile then
			return
		end
		local tier = Ranks.tier(profile.Rating1v1)
		levelText.Text = string.format("Level %d  ·  %s %d", profile.Level, tier.Name, profile.Rating1v1)
		barFill.Size = UDim2.fromScale(profile.XPForNext > 0 and profile.XPInLevel / profile.XPForNext or 1, 1)
		coinText.Text = Util.formatNumber(profile.Coins)
		name.Text = player.DisplayName
	end
	ClientState.ProfileChanged:Connect(render)
	render(ClientState.profile)
end

local function buildMenu()
	local bar = make("Frame", {
		Name = "Menu",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -14),
		Size = UDim2.new(0.96, 0, 0, 56),
		BackgroundTransparency = 1,
		Parent = gui,
	}, {
		UIKit.list(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center),
		make("UISizeConstraint", { MaxSize = Vector2.new(900, 56) }),
	})
	local items = {
		{ "Play", "PLAY", "primary" },
		{ "Rooms", "CUSTOM", "secondary" },
		{ "Fighters", "FIGHTERS", "secondary" },
		{ "Shop", "SHOP", "secondary" },
		{ "Profile", "PROFILE", "secondary" },
		{ "Settings", "SETTINGS", "secondary" },
	}
	for i, item in items do
		UIKit.button(item[2], item[3], function()
			LobbyUI.open(item[1])
		end, {
			LayoutOrder = i,
			Size = UDim2.new(1 / #items, -8, 1, 0),
			TextSize = 20,
			TextScaled = false,
			Parent = bar,
		})
	end
end

local function buildBanners()
	local queueBanner = UIKit.panel({
		Name = "QueueBanner",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 96),
		Size = UDim2.fromOffset(420, 50),
		BackgroundColor3 = T.PanelDark,
		Visible = false,
		Parent = gui,
	})
	local queueText = UIKit.label("", 16, {
		Position = UDim2.fromOffset(14, 0),
		Size = UDim2.new(1, -130, 1, 0),
		Font = T.BoldFont,
		Parent = queueBanner,
	})
	UIKit.button("Cancel", "danger", function()
		Net.get("QueueRequest"):InvokeServer("Leave")
	end, {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.fromOffset(100, 34),
		Parent = queueBanner,
	})

	local dots = 0
	local function renderQueue(status)
		queueBanner.Visible = status ~= nil and not ClientState.inMatch
		if status then
			dots = dots % 3 + 1
			local extra = status.waitingForArena and "  ·  waiting for a free arena"
				or string.format("  ·  %d in queue", status.inQueue)
			queueText.Text = string.format(
				"Searching %s%s  %s%s",
				status.label,
				string.rep(".", dots),
				Util.formatTime(status.waited),
				extra
			)
		end
	end
	ClientState.QueueChanged:Connect(renderQueue)

	local roomBanner = UIKit.panel({
		Name = "RoomBanner",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 96),
		Size = UDim2.fromOffset(420, 50),
		BackgroundColor3 = T.PanelDark,
		Visible = false,
		Parent = gui,
	})
	local roomText = UIKit.label("", 16, {
		Position = UDim2.fromOffset(14, 0),
		Size = UDim2.new(1, -150, 1, 0),
		Font = T.BoldFont,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextWrapped = false,
		Parent = roomBanner,
	})
	UIKit.button("Open room", "primary", function()
		LobbyUI.open("Rooms")
	end, {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.fromOffset(120, 34),
		Parent = roomBanner,
	})
	local function renderRoom(room)
		roomBanner.Visible = room ~= nil and openName ~= "Rooms" and not ClientState.inMatch
		if room then
			local maxPlayers = room.settings.maxPlayers or Config.Modes[room.settings.mode].MaxPlayers
			roomText.Text = string.format("In room: %s (%d/%d)", room.name, #room.members, maxPlayers)
		end
	end
	ClientState.RoomChanged:Connect(renderRoom)
	return function()
		renderQueue(ClientState.queue)
		renderRoom(ClientState.room)
	end
end

function LobbyUI.init()
	gui = make("ScreenGui", {
		Name = "SkybrawlLobby",
		ResetOnSpawn = false,
		DisplayOrder = 5,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = player:WaitForChild("PlayerGui"),
	})

	buildTopBar()
	buildMenu()
	refreshBanners = buildBanners()

	local function closer(name)
		return function()
			if openName == name then
				closeAll()
			end
		end
	end
	panels.Play = PlayPanel.create(gui, closer("Play"))
	panels.Rooms = RoomsPanel.create(gui, closer("Rooms"))
	panels.Shop = ShopPanel.create(gui, closer("Shop"))
	panels.Fighters = FightersPanel.create(gui, closer("Fighters"))
	panels.Profile = ProfilePanel.create(gui, closer("Profile"))
	panels.Settings = SettingsPanel.create(gui, closer("Settings"))

	ClientState.OpenPanel:Connect(LobbyUI.open)
	ClientState.MatchChanged:Connect(function(inMatch)
		gui.Enabled = not inMatch
		if inMatch then
			closeAll()
		end
		refreshBanners()
	end)

	ProximityPromptService.PromptTriggered:Connect(function(prompt)
		local panel = prompt:GetAttribute("Panel")
		if panel and openName ~= panel then
			LobbyUI.open(panel)
		end
	end)
end

return LobbyUI
