--[[
    Your stats: level, ranked ratings and tiers, and lifetime totals.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Ranks = require(Shared.Ranks)
local Util = require(Shared.Util)

local UIKit = require(script.Parent.UIKit)
local ClientState = require(script.Parent.Parent.ClientState)

local T = UIKit.Theme
local make = UIKit.make

local ProfilePanel = {}

function ProfilePanel.create(gui, close)
	local window, body = UIKit.window(gui, "Profile", close)
	local scroll = UIKit.scroll({ Parent = body })
	UIKit.list(Enum.FillDirection.Vertical, 10).Parent = scroll

	local header =
		UIKit.panel({ LayoutOrder = 1, Size = UDim2.new(1, -8, 0, 90), BackgroundColor3 = T.Panel, Parent = scroll })
	local name = UIKit.heading(Players.LocalPlayer.DisplayName, 28, {
		Position = UDim2.fromOffset(16, 10),
		Size = UDim2.new(1, -32, 0, 32),
		Parent = header,
	})
	local level = UIKit.label("", 16, {
		Position = UDim2.fromOffset(16, 44),
		Size = UDim2.new(1, -32, 0, 20),
		Font = T.BoldFont,
		TextColor3 = T.Gold,
		Parent = header,
	})
	local saving = UIKit.label("", 13, {
		Position = UDim2.fromOffset(16, 64),
		Size = UDim2.new(1, -32, 0, 18),
		TextColor3 = T.Muted,
		Parent = header,
	})

	local ranks = make("Frame", {
		LayoutOrder = 2,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -8, 0, 120),
		Parent = scroll,
	}, {
		make("UIGridLayout", {
			CellSize = UDim2.new(0.5, -6, 1, 0),
			CellPadding = UDim2.fromOffset(12, 0),
		}),
	})
	local function rankCard(title)
		local card = UIKit.panel({ BackgroundColor3 = T.Panel, Parent = ranks })
		UIKit.padding(14, 10).Parent = card
		UIKit.label(
			title,
			15,
			{ Font = T.BoldFont, TextColor3 = T.Muted, Size = UDim2.new(1, 0, 0, 20), Parent = card }
		)
		local tier =
			UIKit.heading("", 30, { Position = UDim2.fromOffset(0, 22), Size = UDim2.new(1, 0, 0, 36), Parent = card })
		local detail = UIKit.label("", 14, {
			Position = UDim2.fromOffset(0, 62),
			Size = UDim2.new(1, 0, 0, 36),
			TextColor3 = T.Muted,
			TextYAlignment = Enum.TextYAlignment.Top,
			Parent = card,
		})
		return tier, detail
	end
	local tier1, detail1 = rankCard("RANKED 1v1")
	local tier2, detail2 = rankCard("RANKED 2v2")

	local stats = make("Frame", {
		LayoutOrder = 3,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -8, 0, 180),
		Parent = scroll,
	}, {
		make("UIGridLayout", {
			CellSize = UDim2.new(1 / 3, -8, 0, 80),
			CellPadding = UDim2.fromOffset(12, 12),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	local statLabels = {}
	for i, key in { "Matches", "Wins", "Win rate", "KOs", "Falls", "Damage dealt" } do
		local cell = UIKit.panel({ LayoutOrder = i, BackgroundColor3 = T.Panel, Parent = stats })
		UIKit.label(key, 14, {
			Position = UDim2.fromOffset(12, 8),
			Size = UDim2.new(1, -24, 0, 18),
			TextColor3 = T.Muted,
			Font = T.BoldFont,
			Parent = cell,
		})
		statLabels[key] = UIKit.heading(
			"0",
			28,
			{ Position = UDim2.fromOffset(12, 30), Size = UDim2.new(1, -24, 0, 36), Parent = cell }
		)
	end

	local function render(profile)
		if not profile then
			return
		end
		name.Text = Players.LocalPlayer.DisplayName
		level.Text = string.format(
			"Level %d  ·  %d / %d XP  ·  %s coins",
			profile.Level,
			profile.XPInLevel,
			profile.XPForNext,
			Util.formatNumber(profile.Coins)
		)
		saving.Text = profile.Saving and "Progress saves automatically."
			or "Progress isn't saving right now (Studio without API access, or a DataStore outage)."
		local t1, t2 = Ranks.tier(profile.Rating1v1), Ranks.tier(profile.Rating2v2)
		tier1.Text = string.format("%s  %d", t1.Name, profile.Rating1v1)
		tier1.TextColor3 = t1.Color
		detail1.Text = string.format(
			"Peak %d  ·  %d played%s",
			profile.Peak1v1,
			profile.Ranked1v1Played,
			profile.Ranked1v1Played < 10 and "  ·  placements" or ""
		)
		tier2.Text = string.format("%s  %d", t2.Name, profile.Rating2v2)
		tier2.TextColor3 = t2.Color
		detail2.Text = string.format(
			"Peak %d  ·  %d played%s",
			profile.Peak2v2,
			profile.Ranked2v2Played,
			profile.Ranked2v2Played < 10 and "  ·  placements" or ""
		)
		statLabels["Matches"].Text = Util.formatNumber(profile.Matches)
		statLabels["Wins"].Text = Util.formatNumber(profile.Wins)
		local decided = profile.Wins + profile.Losses
		statLabels["Win rate"].Text = decided > 0
				and string.format("%d%%", math.floor(profile.Wins / decided * 100 + 0.5))
			or "-"
		statLabels["KOs"].Text = Util.formatNumber(profile.KOs)
		statLabels["Falls"].Text = Util.formatNumber(profile.Falls)
		statLabels["Damage dealt"].Text = Util.formatNumber(profile.DamageDealt)
	end
	ClientState.ProfileChanged:Connect(render)
	render(ClientState.profile)

	return {
		window = window,
		open = function()
			render(ClientState.profile)
			window.Visible = true
		end,
		close = function()
			window.Visible = false
		end,
	}
end

return ProfilePanel
