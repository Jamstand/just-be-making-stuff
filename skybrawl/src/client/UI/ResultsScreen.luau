--[[
    End-of-match screen: winner, placements, and what you earned (coins,
    XP, level ups, rating change).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local UIKit = require(script.Parent.UIKit)

local T = UIKit.Theme
local make = UIKit.make

local ResultsScreen = {}

local gui = nil

function ResultsScreen.hide()
	if gui then
		gui:Destroy()
		gui = nil
	end
end

function ResultsScreen.show(data, match)
	ResultsScreen.hide()
	gui = make("ScreenGui", {
		Name = "SkybrawlResults",
		ResetOnSpawn = false,
		DisplayOrder = 30,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = Players.LocalPlayer:WaitForChild("PlayerGui"),
	})
	make("Frame", {
		BackgroundColor3 = T.Backdrop,
		BackgroundTransparency = 0.35,
		Size = UDim2.fromScale(1, 1),
		Parent = gui,
	})
	local panel = UIKit.panel({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.92, 0.84),
		BackgroundColor3 = T.PanelDark,
		Parent = gui,
	})
	make("UISizeConstraint", { MaxSize = Vector2.new(720, 600), Parent = panel })
	UIKit.padding(18, 14).Parent = panel

	local me = nil
	for _, r in data.results do
		if r.id == data.you then
			me = r
		end
	end
	local title, color = "MATCH OVER", T.Text
	if data.reason == "Abandoned" then
		title, color = "MATCH ENDED", T.Muted
	elseif data.draw then
		title, color = "DRAW", T.Teal
	elseif me and me.won then
		title, color = "VICTORY!", T.Gold
	elseif me then
		title, color = "DEFEAT", T.Danger
	end
	UIKit.heading(title, 48, {
		Size = UDim2.new(1, 0, 0, 56),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = color,
		Parent = panel,
	})

	local list = UIKit.scroll({
		Position = UDim2.fromOffset(0, 64),
		Size = UDim2.new(1, 0, 0.5, -40),
		Parent = panel,
	})
	UIKit.list(Enum.FillDirection.Vertical, 6).Parent = list
	local sorted = table.clone(data.results)
	table.sort(sorted, function(a, b)
		if a.placement ~= b.placement then
			return a.placement < b.placement
		end
		return a.kos > b.kos
	end)
	for i, r in sorted do
		local row = UIKit.panel({
			LayoutOrder = i,
			Size = UDim2.new(1, -8, 0, 42),
			BackgroundColor3 = r.id == data.you and T.PanelLight or T.Panel,
			Parent = list,
		})
		make("Frame", {
			BackgroundColor3 = Config.TeamColors[r.team] or T.Stroke,
			BorderSizePixel = 0,
			Size = UDim2.new(0, 6, 1, 0),
			Parent = row,
		}, { UIKit.corner(3) })
		UIKit.heading("#" .. r.placement, 20, { Position = UDim2.fromOffset(16, 0), Size = UDim2.new(0, 44, 1, 0), Parent = row })
		UIKit.label(r.name .. (r.isBot and " (Bot)" or "") .. (r.left and " (left)" or ""), 16, {
			Position = UDim2.fromOffset(64, 0),
			Size = UDim2.new(0.45, -64, 1, 0),
			Font = T.BoldFont,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextWrapped = false,
			Parent = row,
		})
		UIKit.label(string.format("%d KOs  ·  %d falls  ·  %d dmg", r.kos, r.falls, r.damageDealt), 14, {
			Position = UDim2.fromScale(0.45, 0),
			Size = UDim2.new(0.55, -12, 1, 0),
			TextXAlignment = Enum.TextXAlignment.Right,
			TextColor3 = T.Muted,
			Parent = row,
		})
	end

	local rewards = data.rewards
	local lines = {}
	if rewards then
		table.insert(lines, string.format("+%d coins     +%d XP", rewards.coins, rewards.xp))
		if rewards.levelAfter > rewards.levelBefore then
			table.insert(lines, "LEVEL UP! You're level " .. rewards.levelAfter)
		end
		if rewards.ratingMode then
			local delta = rewards.ratingAfter - rewards.ratingBefore
			table.insert(lines, string.format("%s rating: %d -> %d (%s%d)", rewards.ratingMode, rewards.ratingBefore, rewards.ratingAfter, delta >= 0 and "+" or "", delta))
			if rewards.tierAfter ~= rewards.tierBefore then
				table.insert(lines, (delta >= 0 and "Promoted to " or "Dropped to ") .. rewards.tierAfter)
			end
		end
		if rewards.coins == 0 and rewards.xp == 0 then
			table.insert(lines, "Match was too short for rewards.")
		end
	elseif data.reason ~= "Abandoned" and match and match.info.source ~= nil then
		table.insert(lines, "No rewards this time.")
	end
	UIKit.label(table.concat(lines, "\n"), 18, {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, -40),
		Size = UDim2.new(1, 0, 0.36, -30),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Center,
		Font = T.HeadFont,
		TextColor3 = T.Gold,
		Parent = panel,
	})

	local countdown = UIKit.label("", 14, {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 24),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = T.Muted,
		Parent = panel,
	})
	local remaining = data.returnIn or Config.Match.ResultsSeconds
	task.spawn(function()
		while gui and gui.Parent and remaining >= 0 do
			countdown.Text = string.format("Returning to the lobby in %d...", remaining)
			task.wait(1)
			remaining -= 1
		end
	end)
end

function ResultsScreen.init() end

return ResultsScreen
