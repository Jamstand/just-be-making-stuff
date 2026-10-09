--[[
    Menu screen "Missions" (menus design 5.8; the phone main menu's
    MISSIONS button): a header ("3 NEW MISSIONS A DAY" and the time to the
    reset; the widget's own panel is titled DAILY MISSIONS) and the full
    MissionsWidget (compact = false), whose rows claim on Confirm and
    reroll on X, plus the rules in a side panel. The widget updates its
    rows in place from ClientState.profile.Missions and calls
    MissionRequest itself.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local UIKit = require(script.Parent.Parent.UIKit)
local Focus = require(script.Parent.Parent.Focus)
local MissionsWidget = require(script.Parent.Parent.MissionsWidget)
local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Common = require(script.Parent.Common)
local Models = require(script.Parent.Models)

local T = UIKit.Theme

local Screen = {
	id = "Missions",
	title = "MISSIONS",
}

local RULES = {
	"Three new missions every day at 00:00 UTC.",
	"One free reroll a day: press X on a mission you haven't finished.",
	"CLAIM pays the coins and XP. Rewards you forget to claim are paid at the reset.",
	"Online matches count fully. Bots and custom rooms count damage at half; Easy bots, boosted custom "
		.. "damage and the Training Room never count.",
}

local PHONE_HEIGHT = 1150

function Screen.build(host)
	local root = Common.root(host, "Missions")
	local sizer = Common.sizer(root)
	local bag = Common.bag()
	local container = nil
	local widget = nil
	local resetLabel = nil
	local shown = false
	local showToken = 0

	local function renderReset()
		if resetLabel then
			resetLabel.Text = Models.missionsReset(ClientState.serverNow())
		end
	end

	local function build()
		if widget then
			widget.destroy()
			widget = nil
		end
		if container then
			container:Destroy()
		end
		local phone = Common.isPhone()
		local canvas
		if phone then
			local scroller
			canvas, scroller = Common.body(root, sizer, { phoneHeight = PHONE_HEIGHT })
			container = scroller
		else
			canvas = Common.body(root, sizer)
			container = canvas
		end
		local listWidth = if phone then 1 else 0.55
		local headerHeight = if phone then 0.05 else 0.08
		Common.header(string.format("%d NEW MISSIONS A DAY", Config.Missions.PerDay), {
			name = "Header",
			position = UDim2.fromScale(0, 0),
			size = UDim2.fromScale(listWidth * 0.62, headerHeight),
			parent = canvas,
		})
		resetLabel = Common.text("", 22, {
			Name = "Reset",
			Font = T.BlackFont,
			TextColor3 = T.Muted,
			TextXAlignment = Enum.TextXAlignment.Right,
			Position = UDim2.fromScale(listWidth * 0.62, 0),
			Size = UDim2.fromScale(listWidth * 0.38, headerHeight),
			TextWrapped = false,
			Parent = canvas,
		})
		renderReset()
		widget = MissionsWidget.new(canvas, {
			compact = false,
			name = "Missions",
			position = UDim2.fromScale(0, if phone then 0.06 else 0.1),
			size = UDim2.fromScale(listWidth, if phone then 0.55 else 0.88),
		})
		local _, rules = Common.cutPanel({
			name = "Rules",
			title = "HOW MISSIONS WORK",
			position = if phone then UDim2.fromScale(0, 0.63) else UDim2.fromScale(0.6, 0.1),
			size = if phone then UDim2.fromScale(1, 0.37) else UDim2.fromScale(0.4, 0.88),
			parent = canvas,
		})
		for i, line in RULES do
			local row = Common.fill(T.Raised, {
				Name = "Rule" .. i,
				Position = UDim2.fromScale(0, (i - 1) * 0.24 + 0.02),
				Size = UDim2.fromScale(1, 0.21),
				Parent = rules,
			})
			Common.fill(T.Red, { Size = UDim2.fromScale(0.012, 1), Parent = row })
			Common.text(line, 22, {
				TextColor3 = T.Muted,
				Position = UDim2.fromScale(0.04, 0),
				Size = UDim2.fromScale(0.93, 1),
				Parent = row,
			})
		end
	end
	build()

	local function rows()
		return if widget then widget.focusables() else {}
	end
	local rewireTop = Common.linkTop(host, function()
		local list = rows()
		return { list[1] }
	end)
	local function relink()
		Focus.linkColumn(rows())
		rewireTop()
	end

	Common.onModeChange(root, function()
		build()
		relink()
		host.refresh()
	end)

	return {
		root = root,
		show = function()
			shown = true
			relink()
			-- the widget builds its rows when the profile arrives
			bag.add(ClientState.ProfileChanged:Connect(function()
				task.defer(relink)
			end))
			renderReset()
			showToken += 1
			local token = showToken
			task.spawn(function()
				-- the reset countdown
				while shown and showToken == token do
					task.wait(30)
					if shown and showToken == token then
						renderReset()
					end
				end
			end)
		end,
		hide = function()
			shown = false
			bag.clear()
		end,
		defaultFocus = function()
			return rows()[1]
		end,
		hints = function()
			return {
				{ action = "Confirm", label = "CLAIM" },
				{ action = "X", label = "REROLL" },
				{ action = "Back", label = "BACK" },
			}
		end,
		destroy = function()
			if widget then
				widget.destroy()
			end
		end,
	}
end

return Screen
