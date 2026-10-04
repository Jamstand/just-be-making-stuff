--[[
    Custom rooms:
      Browse   room list with filters (mode, map, win rule, hide full,
               hide in-match, my skill range, friends' rooms, search) and
               join-by-code
      Create   host form: mode, players, stocks/timed, map, weapons,
               damage multiplier, friendly fire, private, friends only,
               skill range
      Room     the room you're in: members, teams, bots, start/leave
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Maps = require(Shared.Maps)
local Weapons = require(Shared.Weapons)
local Util = require(Shared.Util)
local Net = require(Shared.Net)

local UIKit = require(script.Parent.UIKit)
local ClientState = require(script.Parent.Parent.ClientState)

local T = UIKit.Theme
local make = UIKit.make

local RoomsPanel = {}

local player = Players.LocalPlayer

local function request(action, payload)
	local ok, a, b = pcall(function()
		return Net.get("RoomRequest"):InvokeServer(action, payload)
	end)
	if not ok then
		return false, "Couldn't reach the server."
	end
	return a, b
end

local function mapName(id)
	if id == "Random" then
		return "Random map"
	end
	local map = Maps.get(id)
	return map and map.Name or id
end

local function modeName(mode)
	return Config.Modes[mode] and Config.Modes[mode].Label or mode
end

local function summary(s)
	local parts = { modeName(s.mode) }
	if s.winRule == "Timed" then
		table.insert(parts, "Timed " .. Util.formatTime(s.timeLimit))
	else
		table.insert(parts, s.stocks .. (s.stocks == 1 and " stock" or " stocks"))
	end
	table.insert(parts, mapName(s.mapId))
	local weaponCount = 0
	for _ in s.weapons or {} do
		weaponCount += 1
	end
	table.insert(parts, weaponCount == #Weapons.Order and "All weapons" or (weaponCount .. " weapons"))
	if s.damageMultiplier and s.damageMultiplier ~= 1 then
		table.insert(parts, "x" .. s.damageMultiplier .. " damage")
	end
	if s.friendlyFire then
		table.insert(parts, "Friendly fire")
	end
	return table.concat(parts, "  ·  ")
end

local function defaultForm()
	local weapons = {}
	for _, id in Weapons.Order do
		weapons[id] = true
	end
	return {
		name = player.DisplayName .. "'s Room",
		mode = "FFA",
		maxPlayers = 4,
		winRule = "Stocks",
		stocks = 3,
		timeLimit = 180,
		mapId = "Random",
		weapons = weapons,
		damageMultiplier = 1,
		friendlyFire = false,
		private = false,
		friendsOnly = false,
		skillRange = false,
		minRating = 800,
		maxRating = 1400,
	}
end

function RoomsPanel.create(gui, close)
	local window, body = UIKit.window(gui, "Custom Rooms", close)

	local tabBar, selectTab -- created once the views exist (bottom of this function)

	local content = make("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 46),
		Size = UDim2.new(1, 0, 1, -46),
		Parent = body,
	})

	local views = {}
	local currentView = nil
	local editing = false

	local function show(name)
		currentView = name
		for viewName, view in views do
			view.frame.Visible = viewName == name
		end
		if tabBar then
			tabBar.Visible = name ~= "Room"
		end
		content.Position = UDim2.fromOffset(0, name == "Room" and 0 or 46)
		content.Size = UDim2.new(1, 0, 1, name == "Room" and 0 or -46)
		if views[name].onShow then
			views[name].onShow()
		end
	end

	-- Browse --------------------------------------------------------------

	do
		local frame = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = content })
		local filters = { mode = "Any", mapId = "Any", winRule = "Any", hideFull = false, hideInMatch = false, eligibleOnly = false, friendsOnly = false, search = "" }
		local refresh

		local filterBar = make("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 74),
			Parent = frame,
		}, {
			make("UIGridLayout", {
				CellSize = UDim2.new(0.25, -6, 0, 32),
				CellPadding = UDim2.fromOffset(6, 6),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		})
		local modeOptions = { { value = "Any", label = "Any" }, { value = "1v1", label = "1v1" }, { value = "2v2", label = "2v2" }, { value = "FFA", label = "FFA" } }
		local mapOptions = { { value = "Any", label = "Any" }, { value = "Random", label = "Random" } }
		for _, id in Maps.Order do
			table.insert(mapOptions, { value = id, label = Maps.get(id).Name })
		end
		local ruleOptions = { { value = "Any", label = "Any" }, { value = "Stocks", label = "Stocks" }, { value = "Timed", label = "Timed" } }

		local function onFilter(key)
			return function(value)
				filters[key] = value
				refresh()
			end
		end
		local chips = {
			(UIKit.cycleChip("Mode", modeOptions, "Any", onFilter("mode"))),
			(UIKit.cycleChip("Map", mapOptions, "Any", onFilter("mapId"))),
			(UIKit.cycleChip("Rule", ruleOptions, "Any", onFilter("winRule"))),
			(UIKit.chip("Hide full", false, onFilter("hideFull"))),
			(UIKit.chip("Hide in match", false, onFilter("hideInMatch"))),
			(UIKit.chip("My skill range", false, onFilter("eligibleOnly"))),
			(UIKit.chip("Friends' rooms", false, onFilter("friendsOnly"))),
		}
		for i, chip in chips do
			chip.LayoutOrder = i
			chip.Size = UDim2.new(1, 0, 1, 0)
			chip.TextScaled = false
			chip.Parent = filterBar
		end
		UIKit.button("Refresh", "secondary", function()
			refresh()
		end, { LayoutOrder = 8, Parent = filterBar })

		local searchRow = make("Frame", {
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(0, 80),
			Size = UDim2.new(1, 0, 0, 38),
			Parent = frame,
		})
		local search = UIKit.textbox("Search room names", { Size = UDim2.new(0.5, -6, 1, 0), Parent = searchRow })
		search.FocusLost:Connect(function()
			filters.search = search.Text
			refresh()
		end)
		local code = UIKit.textbox("Room code", {
			Position = UDim2.new(0.5, 6, 0, 0),
			Size = UDim2.new(0.3, -6, 1, 0),
			Parent = searchRow,
		})
		UIKit.button("Join code", "primary", function()
			local ok, result = request("JoinCode", code.Text)
			if not ok then
				ClientState.toast(result or "Couldn't join.", "error")
			end
		end, {
			Position = UDim2.new(0.8, 6, 0, 0),
			Size = UDim2.new(0.2, -6, 1, 0),
			Parent = searchRow,
		})

		local list = UIKit.scroll({
			Position = UDim2.fromOffset(0, 126),
			Size = UDim2.new(1, 0, 1, -126),
			Parent = frame,
		})
		UIKit.list(Enum.FillDirection.Vertical, 8).Parent = list
		local emptyLabel = UIKit.label("No rooms match. Make one in the Create tab!", 16, {
			TextColor3 = T.Muted,
			TextXAlignment = Enum.TextXAlignment.Center,
			Size = UDim2.new(1, 0, 0, 60),
			Visible = false,
			Parent = list,
		})

		local refreshToken = 0
		refresh = function()
			refreshToken += 1
			local token = refreshToken
			local ok, rooms = request("List", filters)
			if token ~= refreshToken or not ok or type(rooms) ~= "table" then
				return
			end
			for _, child in list:GetChildren() do
				if child:IsA("Frame") and child ~= emptyLabel then
					child:Destroy()
				end
			end
			emptyLabel.Visible = #rooms == 0
			for i, room in rooms do
				local row = UIKit.panel({
					LayoutOrder = i,
					Size = UDim2.new(1, -8, 0, 70),
					BackgroundColor3 = T.Panel,
					Parent = list,
				})
				UIKit.padding(12, 8).Parent = row
				UIKit.heading(room.name, 19, {
					Size = UDim2.new(1, -130, 0, 24),
					TextTruncate = Enum.TextTruncate.AtEnd,
					TextWrapped = false,
					Parent = row,
				})
				local tags = { "Host: " .. room.hostName, string.format("%d/%d players", room.players, room.maxPlayers) }
				if room.isFriend then
					table.insert(tags, "Friend")
				end
				if room.friendsOnly then
					table.insert(tags, "Friends only")
				end
				if room.minRating or room.maxRating then
					table.insert(tags, string.format("Skill %s-%s", room.minRating or "0", room.maxRating or "any"))
				end
				if room.inMatch then
					table.insert(tags, "In match")
				end
				UIKit.label(table.concat(tags, "  ·  "), 13, {
					Position = UDim2.fromOffset(0, 24),
					Size = UDim2.new(1, -130, 0, 16),
					TextColor3 = T.Gold,
					Font = T.BoldFont,
					Parent = row,
				})
				UIKit.label(summary({
					mode = room.mode,
					winRule = room.winRule,
					stocks = room.stocks,
					timeLimit = room.timeLimit,
					mapId = room.mapId,
					damageMultiplier = room.damageMultiplier,
					weapons = table.create(room.weaponCount, true),
				}), 13, {
					Position = UDim2.fromOffset(0, 40),
					Size = UDim2.new(1, -130, 0, 16),
					TextColor3 = T.Muted,
					Parent = row,
				})
				local canJoin = room.eligible and not room.inMatch and room.players < room.maxPlayers
				local join = UIKit.button(canJoin and "Join" or (room.inMatch and "Busy" or (room.eligible and "Full" or "Locked")), canJoin and "primary" or "ghost", function()
					local okJoin, result = request("Join", room.id)
					if not okJoin then
						ClientState.toast(result or "Couldn't join.", "error")
						refresh()
					end
				end, {
					AnchorPoint = Vector2.new(1, 0.5),
					Position = UDim2.new(1, 0, 0.5, 0),
					Size = UDim2.fromOffset(110, 40),
					Parent = row,
				})
				UIKit.setEnabled(join, canJoin)
			end
		end

		views.Browse = {
			frame = frame,
			onShow = function()
				task.spawn(refresh)
			end,
		}
		task.spawn(function()
			while true do
				task.wait(6)
				if window.Visible and currentView == "Browse" then
					refresh()
				end
			end
		end)
	end

	-- Create / edit -----------------------------------------------------

	local form = defaultForm()
	local formSetters = {}
	local submitButton

	do
		local frame = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, Parent = content })
		local scroll = UIKit.scroll({ Size = UDim2.new(1, 0, 1, -54), Parent = frame })
		UIKit.list(Enum.FillDirection.Vertical, 6).Parent = scroll
		local order = 0
		local function add(row)
			order += 1
			row.LayoutOrder = order
			row.Size = UDim2.new(1, -10, 0, row.Size.Y.Offset)
			row.Parent = scroll
			return row
		end
		local visibility = {}

		local nameRow = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 40) })
		local nameBox = UIKit.textbox("Room name", { Text = form.name, Size = UDim2.fromScale(1, 1), Parent = nameRow })
		nameBox.FocusLost:Connect(function()
			form.name = nameBox.Text
		end)
		add(nameRow)
		formSetters.name = function(v)
			nameBox.Text = v
		end

		local function refreshVisibility()
			for row, predicate in visibility do
				row.Visible = predicate()
			end
		end

		local rowMode, setMode = UIKit.cycle("Mode", {
			{ value = "1v1", label = "1v1" },
			{ value = "2v2", label = "2v2" },
			{ value = "FFA", label = "Free-for-all" },
		}, form.mode, function(v)
			form.mode = v
			refreshVisibility()
		end)
		add(rowMode)
		formSetters.mode = setMode

		local rowMax, setMax = UIKit.stepper("Max players", 2, 4, 1, form.maxPlayers, nil, function(v)
			form.maxPlayers = v
		end)
		add(rowMax)
		visibility[rowMax] = function()
			return form.mode == "FFA"
		end
		formSetters.maxPlayers = setMax

		local rowRule, setRule = UIKit.cycle("Win rule", {
			{ value = "Stocks", label = "Stocks (lives)" },
			{ value = "Timed", label = "Timed (most KOs)" },
		}, form.winRule, function(v)
			form.winRule = v
			refreshVisibility()
		end)
		add(rowRule)
		formSetters.winRule = setRule

		local rowStocks, setStocks = UIKit.stepper("Stocks", Config.Rooms.StocksMin, Config.Rooms.StocksMax, 1, form.stocks, nil, function(v)
			form.stocks = v
		end)
		add(rowStocks)
		visibility[rowStocks] = function()
			return form.winRule == "Stocks"
		end
		formSetters.stocks = setStocks

		local rowTime, setTime = UIKit.stepper("Time limit", Config.Rooms.TimeMin, Config.Rooms.TimeMax, 30, form.timeLimit, Util.formatTime, function(v)
			form.timeLimit = v
		end)
		add(rowTime)
		visibility[rowTime] = function()
			return form.winRule == "Timed"
		end
		formSetters.timeLimit = setTime

		local mapOptions = { { value = "Random", label = "Random" } }
		for _, id in Maps.Order do
			table.insert(mapOptions, { value = id, label = Maps.get(id).Name })
		end
		local rowMap, setMap = UIKit.cycle("Map", mapOptions, form.mapId, function(v)
			form.mapId = v
		end)
		add(rowMap)
		formSetters.mapId = setMap

		local weaponsRow = UIKit.panel({ BackgroundColor3 = T.Panel, BackgroundTransparency = 0.2, Size = UDim2.new(1, 0, 0, 100) })
		UIKit.padding(12, 8).Parent = weaponsRow
		UIKit.label("Weapons that drop", 16, { Font = T.BoldFont, Size = UDim2.new(1, 0, 0, 20), Parent = weaponsRow })
		local weaponGrid = make("Frame", {
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(0, 26),
			Size = UDim2.new(1, 0, 0, 66),
			Parent = weaponsRow,
		}, {
			make("UIGridLayout", {
				CellSize = UDim2.new(1 / 3, -6, 0, 30),
				CellPadding = UDim2.fromOffset(6, 6),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		})
		local weaponSetters = {}
		for i, id in Weapons.Order do
			local chip, set = UIKit.chip(Weapons.get(id).Name, form.weapons[id], function(on)
				form.weapons[id] = on or nil
			end)
			chip.LayoutOrder = i
			chip.Size = UDim2.fromScale(1, 1)
			chip.Parent = weaponGrid
			weaponSetters[id] = set
		end
		add(weaponsRow)
		formSetters.weapons = function(map)
			for id, set in weaponSetters do
				set(map[id] == true)
			end
		end

		local rowDamage, setDamage = UIKit.stepper("Damage", Config.Rooms.DamageMultMin, Config.Rooms.DamageMultMax, 0.25, form.damageMultiplier, function(v)
			return "x" .. v
		end, function(v)
			form.damageMultiplier = v
		end)
		add(rowDamage)
		formSetters.damageMultiplier = setDamage

		local rowFF, setFF = UIKit.toggle("Friendly fire", form.friendlyFire, function(v)
			form.friendlyFire = v
		end)
		add(rowFF)
		visibility[rowFF] = function()
			return form.mode == "2v2"
		end
		formSetters.friendlyFire = setFF

		local rowPrivate, setPrivate = UIKit.toggle("Private (join with code only)", form.private, function(v)
			form.private = v
		end)
		add(rowPrivate)
		formSetters.private = setPrivate

		local rowFriends, setFriends = UIKit.toggle("Friends only", form.friendsOnly, function(v)
			form.friendsOnly = v
		end)
		add(rowFriends)
		formSetters.friendsOnly = setFriends

		local rowSkill, setSkill = UIKit.toggle("Skill range", form.skillRange, function(v)
			form.skillRange = v
			refreshVisibility()
		end)
		add(rowSkill)
		formSetters.skillRange = setSkill

		local rowMin, setMin = UIKit.stepper("Min rating", 0, 3000, 50, form.minRating, nil, function(v)
			form.minRating = v
		end)
		add(rowMin)
		visibility[rowMin] = function()
			return form.skillRange
		end
		formSetters.minRating = setMin

		local rowMaxR, setMaxR = UIKit.stepper("Max rating", 0, 3000, 50, form.maxRating, nil, function(v)
			form.maxRating = v
		end)
		add(rowMaxR)
		visibility[rowMaxR] = function()
			return form.skillRange
		end
		formSetters.maxRating = setMaxR

		refreshVisibility()

		local footer = make("Frame", {
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.new(1, 0, 0, 46),
			Parent = frame,
		})
		submitButton = UIKit.button("Create Room", "primary", function()
			form.name = nameBox.Text
			local payload = {
				name = form.name,
				mode = form.mode,
				maxPlayers = form.maxPlayers,
				winRule = form.winRule,
				stocks = form.stocks,
				timeLimit = form.timeLimit,
				mapId = form.mapId,
				weapons = form.weapons,
				damageMultiplier = form.damageMultiplier,
				friendlyFire = form.friendlyFire,
				private = form.private,
				friendsOnly = form.friendsOnly,
				minRating = form.skillRange and form.minRating or false,
				maxRating = form.skillRange and form.maxRating or false,
			}
			local wasEditing = editing
			local ok, result = request(wasEditing and "Update" or "Create", payload)
			if ok then
				editing = false
				ClientState.toast(wasEditing and "Room updated." or "Room ready!", "good")
				show("Room")
			else
				ClientState.toast(result or "Couldn't save the room.", "error")
			end
		end, {
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.fromScale(1, 1),
			Size = UDim2.fromOffset(180, 44),
			Parent = footer,
		})
		local cancelEdit = UIKit.button("Back to room", "ghost", function()
			editing = false
			show("Room")
		end, {
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.fromOffset(160, 44),
			Visible = false,
			Parent = footer,
		})

		views.Create = {
			frame = frame,
			onShow = function()
				submitButton.Text = editing and "Save Changes" or "Create Room"
				cancelEdit.Visible = editing
				refreshVisibility()
			end,
		}
	end

	local function loadForm(room)
		local s = room.settings
		form.name = room.name
		form.mode = s.mode
		form.maxPlayers = s.maxPlayers
		form.winRule = s.winRule
		form.stocks = s.stocks
		form.timeLimit = s.timeLimit
		form.mapId = s.mapId
		form.weapons = table.clone(s.weapons or {})
		form.damageMultiplier = s.damageMultiplier
		form.friendlyFire = s.friendlyFire
		form.private = s.private
		form.friendsOnly = s.friendsOnly
		form.skillRange = s.minRating ~= nil or s.maxRating ~= nil
		form.minRating = s.minRating or 800
		form.maxRating = s.maxRating or 1400
		for key, set in formSetters do
			set(form[key])
		end
	end

	-- Room view -----------------------------------------------------------

	do
		local frame = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, Parent = content })
		local title = UIKit.heading("", 24, {
			Size = UDim2.new(1, -230, 0, 30),
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextWrapped = false,
			Parent = frame,
		})
		local codeBox = UIKit.textbox("", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			Size = UDim2.fromOffset(220, 34),
			TextEditable = false,
			Font = T.HeadFont,
			TextXAlignment = Enum.TextXAlignment.Center,
			Parent = frame,
		})
		local info = UIKit.label("", 14, {
			Position = UDim2.fromOffset(0, 34),
			Size = UDim2.new(1, 0, 0, 36),
			TextColor3 = T.Muted,
			TextYAlignment = Enum.TextYAlignment.Top,
			Parent = frame,
		})
		local members = UIKit.scroll({
			Position = UDim2.fromOffset(0, 74),
			Size = UDim2.new(1, 0, 1, -130),
			Parent = frame,
		})
		UIKit.list(Enum.FillDirection.Vertical, 6).Parent = members

		local footer = make("Frame", {
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.new(1, 0, 0, 46),
			Parent = frame,
		}, { UIKit.list(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center) })

		local botDifficulty = "Normal"
		local leaveButton = UIKit.button("Leave", "danger", function()
			request("Leave")
		end, { LayoutOrder = 1, Size = UDim2.fromOffset(100, 42), Parent = footer })
		local diffButton
		diffButton = UIKit.button("Bot: Normal", "ghost", function()
			local order = Config.Bots.DifficultyOrder
			local index = table.find(order, botDifficulty) or 1
			botDifficulty = order[index % #order + 1]
			diffButton.Text = "Bot: " .. botDifficulty
		end, { LayoutOrder = 2, Size = UDim2.fromOffset(120, 42), Parent = footer })
		local addBot = UIKit.button("Add bot", "secondary", function()
			local ok, result = request("AddBot", { difficulty = botDifficulty })
			if not ok then
				ClientState.toast(result, "error")
			end
		end, { LayoutOrder = 3, Size = UDim2.fromOffset(110, 42), Parent = footer })
		local edit = UIKit.button("Edit rules", "secondary", function()
			if ClientState.room then
				editing = true
				loadForm(ClientState.room)
				show("Create")
			end
		end, { LayoutOrder = 4, Size = UDim2.fromOffset(120, 42), Parent = footer })
		local start = UIKit.button("Start Match", "good", function()
			local ok, result = request("Start")
			if not ok then
				ClientState.toast(result, "error")
			end
		end, { LayoutOrder = 5, Size = UDim2.fromOffset(150, 42), Parent = footer })

		local function render(room)
			if not room then
				return
			end
			local isHost = room.hostUserId == player.UserId
			local open = room.state == "Open"
			title.Text = room.name
			codeBox.Text = "Code: " .. room.code
			local extras = {}
			if room.settings.private then
				table.insert(extras, "Private")
			end
			if room.settings.friendsOnly then
				table.insert(extras, "Friends only")
			end
			if room.settings.minRating or room.settings.maxRating then
				table.insert(extras, string.format("Skill %s-%s", room.settings.minRating or 0, room.settings.maxRating or "any"))
			end
			if not open then
				table.insert(extras, "Match in progress")
			end
			info.Text = summary(room.settings) .. (#extras > 0 and ("\n" .. table.concat(extras, "  ·  ")) or "")

			for _, child in members:GetChildren() do
				if child:IsA("Frame") then
					child:Destroy()
				end
			end
			local teams = room.settings.mode ~= "FFA"
			for i, m in room.members do
				local row = UIKit.panel({
					LayoutOrder = i,
					Size = UDim2.new(1, -8, 0, 50),
					BackgroundColor3 = T.Panel,
					Parent = members,
				})
				make("Frame", {
					BackgroundColor3 = Config.TeamColors[m.team] or T.Stroke,
					BorderSizePixel = 0,
					Size = UDim2.new(0, 8, 1, 0),
					Parent = row,
				}, { UIKit.corner(4) })
				local label = m.name
				if m.isHost then
					label = label .. "  (Host)"
				end
				UIKit.heading(label, 18, {
					Position = UDim2.fromOffset(20, 4),
					Size = UDim2.new(1, -300, 0, 22),
					TextTruncate = Enum.TextTruncate.AtEnd,
					TextWrapped = false,
					Parent = row,
				})
				local detail = m.isBot and (m.difficulty .. " bot") or string.format("Level %s  ·  %s rating", m.level or "?", m.rating or "?")
				if teams then
					detail = "Team " .. m.team .. "  ·  " .. detail
				end
				UIKit.label(detail, 13, {
					Position = UDim2.fromOffset(20, 26),
					Size = UDim2.new(1, -300, 0, 18),
					TextColor3 = T.Muted,
					Parent = row,
				})
				local actions = make("Frame", {
					BackgroundTransparency = 1,
					AnchorPoint = Vector2.new(1, 0.5),
					Position = UDim2.new(1, -8, 0.5, 0),
					Size = UDim2.fromOffset(260, 36),
					Parent = row,
				}, { UIKit.list(Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center) })
				local isMe = m.userId == player.UserId
				if teams and open and (isHost or isMe) then
					UIKit.button("Switch team", "ghost", function()
						local ok, result = request("SetTeam", { memberId = m.id, team = m.team == 1 and 2 or 1 })
						if not ok then
							ClientState.toast(result, "error")
						end
					end, { Size = UDim2.fromOffset(120, 34), TextSize = 15, Parent = actions })
				end
				if isHost and open and not isMe then
					UIKit.button(m.isBot and "Remove" or "Kick", "danger", function()
						request(m.isBot and "RemoveBot" or "Kick", m.id)
					end, { Size = UDim2.fromOffset(90, 34), TextSize = 15, Parent = actions })
				end
			end

			diffButton.Visible = isHost
			addBot.Visible = isHost
			edit.Visible = isHost
			start.Visible = isHost
			UIKit.setEnabled(addBot, open)
			UIKit.setEnabled(edit, open)
			UIKit.setEnabled(start, open)
			leaveButton.Visible = true
		end

		views.Room = {
			frame = frame,
			onShow = function()
				render(ClientState.room)
			end,
		}
		ClientState.RoomChanged:Connect(function(room)
			if room then
				render(room)
			end
		end)
	end

	-- Switching -------------------------------------------------------------

	local function syncView()
		if ClientState.room then
			if not editing then
				show("Room")
			end
		else
			editing = false
			if currentView == "Room" or currentView == nil then
				selectTab("Browse")
			end
		end
	end

	tabBar, selectTab = UIKit.tabs({
		{ id = "Browse", label = "Browse" },
		{ id = "Create", label = "Create" },
	}, function(id)
		if id == "Create" and not editing then
			form = defaultForm()
			for key, set in formSetters do
				set(form[key])
			end
		end
		show(id)
	end)
	tabBar.Parent = body

	ClientState.RoomChanged:Connect(function()
		if window.Visible then
			syncView()
		end
	end)

	return {
		window = window,
		open = function()
			window.Visible = true
			syncView()
		end,
		close = function()
			window.Visible = false
		end,
	}
end

return RoomsPanel
