--[[
    Menu screen "Invite" (menus design 5.8): everyone else on this server,
    friends first (Models.inviteRows), from PartyRequest("List") on show,
    every 5 s while open and on Y (REFRESH). Rows are keyed by userId and
    updated in place: headshot, name, @username, level, FRIEND tag, a
    status chip ("In a match", "Searching"...) and the INVITE state.

    Confirm on a row = PartyRequest("Invite", userId); the server's message
    is toasted ("Invite sent. <name> will see it after their match." for a
    busy player: busy players can be invited, the invite waits for them).
    Only a solo player or the party leader can invite.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Party = require(Shared.Party)

local UIKit = require(script.Parent.Parent.UIKit)
local Focus = require(script.Parent.Parent.Focus)
local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Common = require(script.Parent.Common)
local Models = require(script.Parent.Models)

local T = UIKit.Theme
local make = UIKit.make

local Screen = {
	id = "Invite",
	title = "INVITE",
}

local REFRESH_SECONDS = 5
local ROW_HEIGHT = 92 -- design px

function Screen.build(host)
	local root = Common.root(host, "Invite")
	local sizer = Common.sizer(root)
	local bag = Common.bag()

	local container, list, status, partyLabel, emptyLabel
	local rows = {} -- [userId] = row parts
	local ordered = {} -- row buttons in list order
	local views = {} -- [userId] = Models.inviteRows entry
	local candidates = {}
	local shown = false
	local listToken = 0
	local pollToken = 0
	local errorText = nil -- the last List failure

	local function canManage()
		local size, leader = Common.partyInfo()
		return size == 1 or leader
	end

	local rewireTop
	local refreshList -- PartyRequest("List") -> render (defined below)

	local function buildRow(userId)
		local button = make("TextButton", {
			Name = "Player" .. userId,
			AutoButtonColor = false,
			Text = "",
			BackgroundColor3 = T.Raised,
			BorderSizePixel = 0,
			Parent = list,
		})
		sizer.height(button, ROW_HEIGHT)
		local headshot = make("ImageLabel", {
			Name = "Headshot",
			BackgroundColor3 = T.PanelLight,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.fromScale(0.012, 0.5),
			Size = UDim2.fromScale(0.2, 0.8),
			Parent = button,
		})
		make("UIAspectRatioConstraint", { AspectRatio = 1, Parent = headshot })
		Common.headshot(headshot, userId)
		local name = Common.text("", 30, {
			Name = "PlayerName",
			Font = T.BlackFont,
			Position = UDim2.fromScale(0.09, 0.1),
			Size = UDim2.fromScale(0.34, 0.45),
			TextWrapped = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = button,
		})
		local username = Common.text("", 20, {
			Name = "Username",
			TextColor3 = T.Muted,
			Position = UDim2.fromScale(0.09, 0.55),
			Size = UDim2.fromScale(0.34, 0.35),
			TextWrapped = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = button,
		})
		local level = Common.tag("", {
			name = "Level",
			anchor = Vector2.new(0, 0.5),
			position = UDim2.fromScale(0.44, 0.5),
			size = UDim2.fromScale(0.07, 0.42),
			parent = button,
		})
		local friend = Common.tag("FRIEND", {
			name = "Friend",
			anchor = Vector2.new(0, 0.5),
			position = UDim2.fromScale(0.52, 0.5),
			size = UDim2.fromScale(0.09, 0.42),
			fill = T.Good,
			textColor = T.Backdrop,
			parent = button,
		})
		local chip = Common.tag("", {
			name = "Status",
			anchor = Vector2.new(0, 0.5),
			position = UDim2.fromScale(0.62, 0.5),
			size = UDim2.fromScale(0.15, 0.42),
			parent = button,
		})
		local action = UIKit.slantFrame({
			name = "Invite",
			slant = T.Slant,
			gradient = { T.RedLight, T.RedDark },
			outline = 4,
			anchor = Vector2.new(1, 0.5),
			position = UDim2.fromScale(0.985, 0.5),
			size = UDim2.fromScale(0.19, 0.62),
			parent = button,
		})
		local actionText = Common.text("INVITE", 30, {
			Name = "Label",
			Font = T.HeadFont,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextWrapped = false,
			Parent = action:FindFirstChild("Content") or action,
		})
		local row = {
			button = button,
			name = name,
			username = username,
			level = level,
			friend = friend,
			chip = chip,
			action = action,
			actionText = actionText,
		}
		Common.focusable(button, { key = "Invite" .. userId }, function()
			local view = views[userId]
			if not view then
				return
			end
			if not canManage() then
				host.toast("Only the party leader can invite players.", "error")
				return
			end
			if not view.enabled then
				host.toast(
					if view.button == "INVITED" then "Already invited." else view.reason or "You can't invite them now.",
					"error"
				)
				return
			end
			local ok, message = Common.invoke("PartyRequest", "Invite", userId)
			host.toast(
				message or (if ok then "Invite sent." else "Couldn't send the invite."),
				ok and "good" or "error"
			)
			-- the row now reads INVITED
			task.spawn(refreshList)
		end)
		return row
	end

	local function renderRow(row, view, index)
		row.button.LayoutOrder = index
		row.name.Text = view.name
		row.username.Text = view.username
		Common.setTag(row.level, view.level, { fill = T.Raised, textColor = T.Muted })
		row.friend.Visible = view.friend
		row.chip.Visible = view.status ~= nil
		if view.status then
			Common.setTag(row.chip, view.status, { fill = T.PanelLight, textColor = T.Warning })
		end
		row.actionText.Text = view.button
		row.actionText.TextColor3 = if view.enabled then T.Text else T.Dim
		if row.action:GetAttribute("Enabled") ~= view.enabled then
			row.action:SetAttribute("Enabled", view.enabled)
			UIKit.setSlantFill(row.action, if view.enabled then { T.RedLight, T.RedDark } else T.PanelLight)
		end
	end

	local function render()
		if not list then
			return
		end
		local manage = canManage()
		local seen = {}
		table.clear(ordered)
		for index, view in Models.inviteRows(candidates, manage) do
			seen[view.userId] = true
			views[view.userId] = view
			local row = rows[view.userId] or buildRow(view.userId)
			rows[view.userId] = row
			renderRow(row, view, index)
			table.insert(ordered, row.button)
		end
		for userId, row in rows do
			if not seen[userId] then
				row.button:Destroy()
				rows[userId] = nil
				views[userId] = nil
			end
		end
		Focus.linkColumn(ordered)
		emptyLabel.Visible = #ordered == 0
		local party = ClientState.party
		local size = if party and party.members then #party.members else 1
		partyLabel.Text = string.format("PARTY %d/%d", size, (party and party.maxSize) or Party.MaxSize)
		status.Text = errorText
			or (
				if manage
					then "Friends first. Players in a match get your invite when they're back."
					else "Only the party leader can invite players."
			)
		if rewireTop then
			rewireTop()
		end
	end

	function refreshList()
		listToken += 1
		local token = listToken
		local ok, result = Common.invoke("PartyRequest", "List")
		if token ~= listToken or not shown then
			return
		end
		if ok and type(result) == "table" then
			candidates = result.players or {}
			errorText = nil
		else
			errorText = if type(result) == "string" then result else "Couldn't load the players."
		end
		render()
	end

	local function build()
		if container then
			container:Destroy()
		end
		for _, row in rows do
			row.button:Destroy()
		end
		table.clear(rows)
		table.clear(ordered)
		local phone = Common.isPhone()
		container = Common.region(root)
		Common.header("PLAYERS ON THIS SERVER", {
			position = UDim2.fromScale(0, 0),
			size = UDim2.fromScale(0.6, if phone then 0.12 else 0.08),
			parent = container,
		})
		partyLabel = Common.text("", 26, {
			Name = "Party",
			Font = T.HeadFont,
			TextXAlignment = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			Size = UDim2.fromScale(0.3, if phone then 0.12 else 0.08),
			Parent = container,
		})
		status = Common.text("", 22, {
			Name = "Status",
			TextColor3 = T.Muted,
			Position = UDim2.fromScale(0, if phone then 0.13 else 0.09),
			Size = UDim2.fromScale(1, if phone then 0.1 else 0.06),
			Parent = container,
		})
		local top = if phone then 0.25 else 0.17
		list = Common.list(container, {
			Position = UDim2.fromScale(0, top),
			Size = UDim2.fromScale(1, 1 - top),
		})
		emptyLabel = Common.text("Nobody else is on this server yet.", 26, {
			Name = "Empty",
			TextColor3 = T.Muted,
			TextXAlignment = Enum.TextXAlignment.Center,
			Position = UDim2.fromScale(0, top + 0.05),
			Size = UDim2.fromScale(1, 0.1),
			Visible = false,
			Parent = container,
		})
		render()
	end
	build()

	rewireTop = Common.linkTop(host, function()
		return { ordered[1] }
	end)
	Common.onModeChange(root, function()
		build()
		host.refresh()
	end)

	return {
		root = root,
		show = function()
			shown = true
			pollToken += 1
			local poll = pollToken
			bag.add(ClientState.PartyChanged:Connect(function()
				render()
				task.spawn(refreshList)
			end))
			task.spawn(refreshList)
			task.spawn(function()
				while shown and pollToken == poll do
					task.wait(REFRESH_SECONDS)
					if shown and pollToken == poll then
						refreshList()
					end
				end
			end)
		end,
		hide = function()
			shown = false
			bag.clear()
		end,
		defaultFocus = function()
			return ordered[1]
		end,
		actions = {
			Y = function()
				task.spawn(refreshList)
			end,
		},
		hints = function()
			return {
				{ action = "Confirm", label = "INVITE" },
				{
					action = "Y",
					label = "REFRESH",
					onClick = function()
						task.spawn(refreshList)
					end,
				},
				{ action = "Back", label = "BACK" },
			}
		end,
	}
end

return Screen
