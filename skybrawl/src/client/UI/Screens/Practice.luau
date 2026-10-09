--[[
    Menu screen "Practice" (menus design 5.8): two cut panels.

      VS BOTS        Format / Difficulty / Map rows and START (the party
                     leader starts it for the whole party; formats follow
                     the party size, Models.botFormats). START sends
                     QueueRequest("Join", "Bots", { format, difficulty, mapId })
                     (mapId nil = map vote); the legend select follows.
      TRAINING ROOM  ENTER sends TrainingRequest("Start", {}) and reads
                     LOADING... until the match starts (phase "Match"), an
                     error toast arrives, or Config.Match.LoadTimeout + 5 s
                     pass. Party members may enter it alone.

    The chosen options are remembered for the session. Phone: the panels
    stack and scroll.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local UIKit = require(script.Parent.Parent.UIKit)
local Focus = require(script.Parent.Parent.Focus)
local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Common = require(script.Parent.Common)
local Models = require(script.Parent.Models)

local T = UIKit.Theme
local make = UIKit.make

local Screen = {
	id = "Practice",
	title = "PRACTICE",
}

-- remembered for the session
local options = { format = "Duel", difficulty = "Normal", map = "Vote" }

local PHONE_HEIGHT = 1250 -- design px of the scrolling canvas (both panels stacked)

function Screen.build(host)
	local root = Common.root(host, "Practice")
	local sizer = Common.sizer(root)
	local bag = Common.bag()
	local inst

	local container = nil
	local rows = {} -- format, difficulty, map rows (top to bottom)
	local formatRow, startButton, reasonLabel, enterButton
	local formatSize = nil -- the party size the Format row was built for

	-- Training ENTER: LOADING... until the match starts, an error toast, or the timeout.
	local loading = false
	local loadToken = 0
	local function setLoading(on)
		loading = on
		if enterButton then
			Common.setButtonText(enterButton, if on then "LOADING..." else "ENTER")
		end
	end
	ClientState.Toast:Connect(function(_text, kind)
		if loading and kind == "error" then
			setLoading(false)
		end
	end)
	ClientState.PhaseChanged:Connect(function(phase)
		if loading and phase == "Match" then
			setLoading(false)
		end
	end)

	local function enterTraining()
		if loading then
			return
		end
		setLoading(true)
		loadToken += 1
		local token = loadToken
		local ok, message = Common.invoke("TrainingRequest", "Start", {})
		if not ok then
			if token == loadToken then
				setLoading(false)
			end
			host.toast(message or "Couldn't start the training room.", "error")
			return
		end
		task.delay(Config.Match.LoadTimeout + 5, function()
			if token == loadToken and loading then
				setLoading(false)
			end
		end)
	end

	local function startBots()
		local size, leader = Common.partyInfo()
		local ok, reason = Models.botsStart(options.format, size, leader)
		if not ok then
			host.toast(reason or "You can't start this right now.", "error")
			return
		end
		local joined, message = Common.invoke("QueueRequest", "Join", "Bots", {
			format = options.format,
			difficulty = options.difficulty,
			mapId = if options.map ~= "Vote" then options.map else nil,
		})
		if not joined then
			host.toast(message or "Couldn't start the match.", "error")
		end
	end

	-- The START reason line (who may start, and whether the party fits the format).
	local function renderStart()
		if not reasonLabel then
			return
		end
		local size, leader = Common.partyInfo()
		local ok, reason = Models.botsStart(options.format, size, leader)
		reasonLabel.Text = if ok then "" else (reason or "")
	end

	local function rowSize(row)
		row.Size = UDim2.fromScale(1, 0.12)
	end

	local rewireTop = function() end

	local function linkRows()
		local column = { rows[1], rows[2], rows[3], startButton }
		Focus.linkColumn(column)
		for _, obj in column do
			Focus.link(obj, "Right", enterButton)
		end
		Focus.link(enterButton, "Left", startButton)
		-- linkColumn cleared the top row's Up link to CANCEL (the Format row is rebuilt when the party changes)
		rewireTop()
	end

	-- The Format row lists the formats for your party size, so it is rebuilt when the size changes.
	local function buildFormatRow(parent)
		local size = Common.partyInfo()
		formatSize = size
		options.format = Models.pickBotFormat(options.format, size)
		local choices = {}
		for _, option in Models.botFormats(size) do
			table.insert(choices, { value = option.value, label = option.label })
		end
		if formatRow then
			formatRow:Destroy()
		end
		formatRow = UIKit.cycle("Format", choices, options.format, function(value)
			options.format = value
			renderStart()
		end)
		formatRow.Name = "Format"
		formatRow:SetAttribute("FocusKey", "PracticeFormat")
		rowSize(formatRow)
		formatRow.Position = UDim2.fromScale(0, 0.14)
		formatRow.Parent = parent
		rows[1] = formatRow
	end

	local formatParent = nil
	local function onParty()
		if Common.partyInfo() ~= formatSize and formatParent then
			buildFormatRow(formatParent)
			linkRows()
		end
		renderStart()
	end

	local function buildBots(parent, position, size)
		local _, body = Common.cutPanel({
			name = "VsBots",
			title = "VS BOTS",
			position = position,
			size = size,
			parent = parent,
		})
		Common.text("Start right away against AI fighters. Rewards are reduced.", 22, {
			Name = "Blurb",
			TextColor3 = T.Muted,
			Position = UDim2.fromScale(0, 0.02),
			Size = UDim2.fromScale(1, 0.1),
			Parent = body,
		})
		formatParent = body
		buildFormatRow(body)

		local difficulties = {}
		for _, d in Config.Bots.DifficultyOrder do
			table.insert(difficulties, { value = d, label = d })
		end
		local diffRow = UIKit.cycle("Difficulty", difficulties, options.difficulty, function(value)
			options.difficulty = value
		end)
		diffRow.Name = "Difficulty"
		diffRow:SetAttribute("FocusKey", "PracticeDifficulty")
		rowSize(diffRow)
		diffRow.Position = UDim2.fromScale(0, 0.28)
		diffRow.Parent = body
		rows[2] = diffRow
		Common.text("Easy bots don't count for missions.", 20, {
			Name = "MissionsNote",
			TextColor3 = T.Muted,
			Position = UDim2.fromScale(0.02, 0.405),
			Size = UDim2.fromScale(0.96, 0.06),
			Parent = body,
		})

		local mapRow = UIKit.cycle("Map", Models.botMaps(), options.map, function(value)
			options.map = value
		end)
		mapRow.Name = "Map"
		mapRow:SetAttribute("FocusKey", "PracticeMap")
		rowSize(mapRow)
		mapRow.Position = UDim2.fromScale(0, 0.48)
		mapRow.Parent = body
		rows[3] = mapRow
		Common.text("Vote: pick from three maps with everyone in the match.", 20, {
			Name = "MapNote",
			TextColor3 = T.Muted,
			Position = UDim2.fromScale(0.02, 0.605),
			Size = UDim2.fromScale(0.96, 0.06),
			Parent = body,
		})

		startButton = Common.slantButton("START", {
			name = "Start",
			style = "primary",
			glyph = "Confirm",
			textSize = 44,
			position = UDim2.fromScale(0, 0.72),
			size = UDim2.fromScale(0.6, 0.13),
			parent = body,
		}, startBots)
		startButton:SetAttribute("FocusKey", "PracticeStart")
		reasonLabel = Common.text("", 20, {
			Name = "Reason",
			Font = T.BoldFont,
			TextColor3 = T.Warning,
			Position = UDim2.fromScale(0, 0.87),
			Size = UDim2.fromScale(1, 0.12),
			TextYAlignment = Enum.TextYAlignment.Top,
			Parent = body,
		})
		renderStart()
	end

	local function buildTraining(parent, position, size)
		local _, body = Common.cutPanel({
			name = "Training",
			title = "TRAINING ROOM",
			position = position,
			size = size,
			parent = parent,
		})
		Common.text(
			"Frame data, hitboxes, a dummy that blocks, dodges or fights back. "
				.. "Nothing here counts for missions, XP or rating.",
			24,
			{
				Name = "Blurb",
				TextColor3 = T.Muted,
				TextYAlignment = Enum.TextYAlignment.Top,
				Position = UDim2.fromScale(0, 0.02),
				Size = UDim2.fromScale(1, 0.4),
				Parent = body,
			}
		)
		local chips = make("Frame", {
			Name = "Features",
			BackgroundTransparency = 1,
			Position = UDim2.fromScale(0, 0.44),
			Size = UDim2.fromScale(1, 0.2),
			Parent = body,
		})
		for i, text in { "FRAME DATA", "HITBOXES", "SLOW-MO", "WEAPON SPAWNER" } do
			Common.tag(text, {
				position = UDim2.fromScale(((i - 1) % 2) * 0.5, if i <= 2 then 0 else 0.55),
				size = UDim2.fromScale(0.47, 0.4),
				fill = T.Raised,
				textColor = T.Muted,
				parent = chips,
			})
		end
		enterButton = Common.slantButton(if loading then "LOADING..." else "ENTER", {
			name = "Enter",
			style = "primary",
			glyph = "Confirm",
			textSize = 44,
			position = UDim2.fromScale(0, 0.72),
			size = UDim2.fromScale(0.8, 0.13),
			parent = body,
		}, enterTraining)
		enterButton:SetAttribute("FocusKey", "PracticeEnter")
	end

	local function build()
		if container then
			container:Destroy()
		end
		formatRow = nil
		table.clear(rows)
		if Common.isPhone() then
			local canvas, scroller = Common.body(root, sizer, { phoneHeight = PHONE_HEIGHT })
			container = scroller
			buildBots(canvas, UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.6))
			buildTraining(canvas, UDim2.fromScale(0, 0.63), UDim2.fromScale(1, 0.37))
		else
			container = Common.body(root, sizer)
			buildBots(container, UDim2.fromScale(0, 0), UDim2.fromScale(0.54, 0.97))
			buildTraining(container, UDim2.fromScale(0.57, 0), UDim2.fromScale(0.43, 0.97))
		end
		linkRows()
	end
	build()

	rewireTop = Common.linkTop(host, function()
		return { rows[1], enterButton }
	end)
	Common.onModeChange(root, function()
		build()
		rewireTop()
		host.refresh()
	end)

	inst = {
		root = root,
		show = function()
			bag.add(ClientState.PartyChanged:Connect(onParty))
			onParty()
			rewireTop()
		end,
		hide = function()
			bag.clear()
		end,
		defaultFocus = function()
			return startButton
		end,
		hints = function()
			return {
				{ action = "Confirm", label = "SELECT" },
				{ action = "Back", label = "BACK" },
			}
		end,
	}
	return inst
end

return Screen
