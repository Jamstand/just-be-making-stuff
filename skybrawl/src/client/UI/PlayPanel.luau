--[[
    Quick play: Ranked 1v1, Ranked 2v2, Free-for-all queue, and vs Bots.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Maps = require(Shared.Maps)
local Ranks = require(Shared.Ranks)
local Net = require(Shared.Net)

local UIKit = require(script.Parent.UIKit)
local ClientState = require(script.Parent.Parent.ClientState)

local T = UIKit.Theme
local make = UIKit.make

local PlayPanel = {}

local function card(parent, order, title, height)
	local frame = UIKit.panel({
		LayoutOrder = order,
		Size = UDim2.new(1, -8, 0, height or 96),
		BackgroundColor3 = T.Panel,
		Parent = parent,
	})
	UIKit.padding(16, 10).Parent = frame
	UIKit.heading(title, 24, {
		Size = UDim2.new(1, -170, 0, 28),
		Parent = frame,
	})
	local subtitle = UIKit.label("", 15, {
		Position = UDim2.fromOffset(0, 28),
		Size = UDim2.new(1, -170, 0, 20),
		Font = T.BoldFont,
		TextColor3 = T.Gold,
		Parent = frame,
	})
	local description = UIKit.label("", 14, {
		Position = UDim2.fromOffset(0, 50),
		Size = UDim2.new(1, -170, 0, 34),
		TextColor3 = T.Muted,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = frame,
	})
	return frame, subtitle, description
end

local function join(queueType, options)
	local ok, message = Net.get("QueueRequest"):InvokeServer("Join", queueType, options)
	ClientState.toast(message or (ok and "Joined!" or "Couldn't join."), ok and "info" or "error")
	return ok
end

local function leave()
	Net.get("QueueRequest"):InvokeServer("Leave")
end

function PlayPanel.create(gui, close)
	local window, body = UIKit.window(gui, "Play", close)
	local scroll = UIKit.scroll({ Parent = body })
	UIKit.list(Enum.FillDirection.Vertical, 10).Parent = scroll

	local queueButtons = {}

	local function queueCard(order, queueType, title, description)
		local frame, subtitle, desc = card(scroll, order, title)
		desc.Text = description
		local button = UIKit.button("Find Match", "primary", function()
			local queue = ClientState.queue
			if queue and queue.queue == queueType then
				leave()
			else
				join(queueType)
			end
		end, {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, 0, 0.5, 0),
			Size = UDim2.fromOffset(150, 44),
			Parent = frame,
		})
		queueButtons[queueType] = button
		return subtitle
	end

	local sub1v1 = queueCard(1, "Ranked1v1", "Ranked 1v1", "3 stocks, matched by your 1v1 rating. Wins raise your rank.")
	local sub2v2 = queueCard(2, "Ranked2v2", "Ranked 2v2", "Team up with another solo player against two others. Teams are balanced by rating.")
	local subFFA = queueCard(3, "FFA", "Free-for-all", "Up to 4 players, everyone for themselves. Bots fill empty spots if it takes a while.")
	subFFA.Text = "Casual · no rating"

	-- vs Bots
	local botFrame, botSub, botDesc = card(scroll, 4, "vs Bots", 250)
	botSub.Text = "Practice · reduced rewards"
	botDesc.Text = "Start right away against AI fighters."
	local options = { format = "Duel", difficulty = "Normal", mapId = "Random" }
	local controls = make("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 92),
		Size = UDim2.new(1, -170, 0, 140),
		Parent = botFrame,
	}, { UIKit.list(Enum.FillDirection.Vertical, 4) })
	local formatRow = UIKit.cycle("Format", {
		{ value = "Duel", label = "1v1 Duel" },
		{ value = "FFA", label = "Free-for-all (3 bots)" },
		{ value = "2v2", label = "2v2 (bot teammate)" },
	}, options.format, function(v)
		options.format = v
	end)
	formatRow.LayoutOrder = 1
	formatRow.Parent = controls
	local difficulties = {}
	for _, d in Config.Bots.DifficultyOrder do
		table.insert(difficulties, { value = d, label = d })
	end
	local diffRow = UIKit.cycle("Difficulty", difficulties, options.difficulty, function(v)
		options.difficulty = v
	end)
	diffRow.LayoutOrder = 2
	diffRow.Parent = controls
	local maps = { { value = "Random", label = "Random" } }
	for _, id in Maps.Order do
		table.insert(maps, { value = id, label = Maps.get(id).Name })
	end
	local mapRow = UIKit.cycle("Map", maps, options.mapId, function(v)
		options.mapId = v
	end)
	mapRow.LayoutOrder = 3
	mapRow.Parent = controls

	UIKit.button("Start", "good", function()
		if join("Bots", { format = options.format, difficulty = options.difficulty, mapId = options.mapId ~= "Random" and options.mapId or nil }) then
			close()
		end
	end, {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(150, 44),
		Parent = botFrame,
	})

	local function refresh()
		local profile = ClientState.profile
		if profile then
			sub1v1.Text = string.format("%s · %d rating · %d played", Ranks.tier(profile.Rating1v1).Name, profile.Rating1v1, profile.Ranked1v1Played)
			sub2v2.Text = string.format("%s · %d rating · %d played", Ranks.tier(profile.Rating2v2).Name, profile.Rating2v2, profile.Ranked2v2Played)
			sub1v1.TextColor3 = Ranks.tier(profile.Rating1v1).Color
			sub2v2.TextColor3 = Ranks.tier(profile.Rating2v2).Color
		end
		local queue = ClientState.queue
		for queueType, button in queueButtons do
			local queued = queue and queue.queue == queueType
			button.Text = queued and "Cancel" or "Find Match"
			UIKit.styleButton(button, queued and "danger" or "primary")
			local inRoom = ClientState.room ~= nil
			UIKit.setEnabled(button, not inRoom)
		end
	end
	ClientState.ProfileChanged:Connect(refresh)
	ClientState.QueueChanged:Connect(refresh)
	ClientState.RoomChanged:Connect(refresh)
	refresh()

	return {
		window = window,
		open = function()
			refresh()
			window.Visible = true
		end,
		close = function()
			window.Visible = false
		end,
	}
end

return PlayPanel
