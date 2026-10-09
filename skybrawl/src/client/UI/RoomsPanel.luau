--[[
    Custom rooms (the menus' CUSTOM ROOMS screen, menus design 5.8), three
    views on a tab bar (L1/R1):
      BROWSE  room list with filters (mode, map, win rule, hide full,
              hide in-match, my skill range, friends' rooms, search) and
              join-by-code; rows are keyed by room id and updated in place,
              and Confirm on a row joins it
      CREATE  host form: mode, players, stocks/timed, map, weapons,
              damage multiplier, friendly fire, private, friends only,
              skill range (the host of a room edits its rules here)
      ROOM    the room you're in: members (keyed by member id, updated in
              place), teams, bots, start/leave; START begins the legend
              select for everyone in the room

    A party member who isn't the leader sees "Your party leader picks the
    room." and can't join or create (the leader brings the whole party).
    Text boxes capture on Confirm and release on Enter (Focus).

    RoomsPanel.mount(parent, host) builds it as a menu screen
    (Screens/CustomRooms; params { view = "Browse" | "Room" }).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Maps = require(Shared.Maps)
local Weapons = require(Shared.Weapons)
local Util = require(Shared.Util)

local UIKit = require(script.Parent.UIKit)
local Focus = require(script.Parent.Focus)
local Layout = require(script.Parent.Layout)
local ClientState = require(script.Parent.Parent.ClientState)
local Common = require(script.Parent.Screens.Common)

local T = UIKit.Theme
local make = UIKit.make

local RoomsPanel = {}

local player = Players.LocalPlayer

local ROOM_ROW = 96 -- design px
local MEMBER_ROW = 72
local PHONE_MEMBER_ROW = 104 -- with buttons 0.8 of it: 83 design px = 45 px on a 390 px phone
local FORM_ROW = 46
local BROWSE_REFRESH = 6
local PHONE_HEIGHT = 1500 -- design px of the scrolling body on phones

local TABS = {
	{ id = "Browse", label = "BROWSE" },
	{ id = "Create", label = "CREATE" },
	{ id = "Room", label = "ROOM" },
}

local function request(action, payload)
	return Common.invoke("RoomRequest", action, payload)
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

-- Whether you're in a party but not its leader (the leader picks the room).
local function partyBlocked()
	local size, leader = Common.partyInfo()
	return size > 1 and not leader
end

-- Builds the custom rooms screen inside `parent`. Returns the ScreenInstance (menus design 3.8).
function RoomsPanel.mount(parent, host)
	local root = Common.root({ content = parent }, "CustomRooms")
	local sizer = Common.sizer(root)
	local bag = Common.bag()

	local currentView = "Browse"
	local editing = false -- the CREATE tab edits your room's rules (host)
	local shown = false
	local pollToken = 0
	local container, selectTab, partyBanner
	local views = {} -- [id] = { frame, onShow?, defaultFocus? }
	local unwatchBrowse = nil -- the filter grid's px watcher (dropped when the body is rebuilt)
	local lastRoomId = nil -- the room ClientState last reported (ROOM opens only when a room appears)
	local lastParams = nil -- the deep-link params already applied
	local rewireTop = function() end

	local function setView(id)
		currentView = id
		for viewId, v in views do
			v.frame.Visible = viewId == id
		end
		if views[id] and views[id].onShow then
			views[id].onShow()
		end
	end

	-- A view change from code: the state first, then the tab bar's look (its onSelect is a no-op then).
	local function showView(id)
		if id ~= "Create" then
			editing = false
		end
		setView(id)
		if selectTab then
			selectTab(id)
		end
	end

	local function renderParty()
		if partyBanner then
			partyBanner.Visible = partyBlocked()
		end
		for _, v in views do
			if v.onParty then
				v.onParty()
			end
		end
	end

	-- Browse --------------------------------------------------------------------------------

	local function buildBrowse(frame)
		local filters = {
			mode = "Any",
			mapId = "Any",
			winRule = "Any",
			hideFull = false,
			hideInMatch = false,
			eligibleOnly = false,
			friendsOnly = false,
			search = "",
		}
		local refresh
		local rows = {} -- [roomId] = row parts
		local ordered = {}
		local listed = {} -- [roomId] = room entry from List

		local filterBar = make("Frame", {
			Name = "Filters",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0.17),
			Parent = frame,
		})
		local grid = make("UIGridLayout", {
			CellSize = UDim2.new(0.25, -6, 0.5, -6),
			CellPadding = UDim2.fromOffset(6, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = filterBar,
		})
		if unwatchBrowse then
			unwatchBrowse()
		end
		unwatchBrowse = sizer.watch(function()
			local gap = Layout.px(8)
			grid.CellPadding = UDim2.fromOffset(gap, gap)
			grid.CellSize = UDim2.new(0.25, -gap, 0.5, -gap)
		end)
		local modeOptions = {
			{ value = "Any", label = "Any" },
			{ value = "1v1", label = "1v1" },
			{ value = "2v2", label = "2v2" },
			{ value = "FFA", label = "FFA" },
		}
		local mapOptions = { { value = "Any", label = "Any" }, { value = "Random", label = "Random" } }
		for _, id in Maps.Order do
			table.insert(mapOptions, { value = id, label = Maps.get(id).Name })
		end
		local ruleOptions = {
			{ value = "Any", label = "Any" },
			{ value = "Stocks", label = "Stocks" },
			{ value = "Timed", label = "Timed" },
		}
		local function onFilter(key)
			return function(value)
				filters[key] = value
				task.spawn(refresh)
			end
		end
		local chips = {
			(UIKit.cycleChip("Mode", modeOptions, filters.mode, onFilter("mode"))),
			(UIKit.cycleChip("Map", mapOptions, filters.mapId, onFilter("mapId"))),
			(UIKit.cycleChip("Rule", ruleOptions, filters.winRule, onFilter("winRule"))),
			(UIKit.chip("Hide full", false, onFilter("hideFull"))),
			(UIKit.chip("Hide in match", false, onFilter("hideInMatch"))),
			(UIKit.chip("My skill range", false, onFilter("eligibleOnly"))),
			(UIKit.chip("Friends' rooms", false, onFilter("friendsOnly"))),
		}
		for i, chip in chips do
			chip.LayoutOrder = i
			chip.TextScaled = false
			chip:SetAttribute("FocusKey", "RoomFilter" .. i)
			chip.Parent = filterBar
		end
		local refreshButton = UIKit.button("Refresh", "secondary", function()
			refresh()
		end, { LayoutOrder = 8, Parent = filterBar })
		refreshButton:SetAttribute("FocusKey", "RoomFilterRefresh")

		local searchRow = make("Frame", {
			Name = "Search",
			BackgroundTransparency = 1,
			Position = UDim2.fromScale(0, 0.19),
			Size = UDim2.fromScale(1, 0.08),
			Parent = frame,
		})
		local search = UIKit.textbox("Search room names", { Size = UDim2.new(0.5, -6, 1, 0), Parent = searchRow })
		search.FocusLost:Connect(function()
			filters.search = search.Text
			task.spawn(refresh)
		end)
		local code = UIKit.textbox("Room code", {
			Position = UDim2.new(0.5, 6, 0, 0),
			Size = UDim2.new(0.28, -6, 1, 0),
			Parent = searchRow,
		})
		local joinCode = UIKit.button("Join code", "primary", function()
			if partyBlocked() then
				host.toast("Your party leader picks the room.", "error")
				return
			end
			local ok, result = request("JoinCode", code.Text)
			if not ok then
				host.toast(result or "Couldn't join.", "error")
			end
		end, {
			Position = UDim2.new(0.78, 6, 0, 0),
			Size = UDim2.new(0.22, -6, 1, 0),
			Parent = searchRow,
		})

		local list = Common.list(frame, {
			Position = UDim2.fromScale(0, 0.29),
			Size = UDim2.fromScale(1, 0.71),
		})
		local emptyLabel = Common.text("No rooms match. Make one in the CREATE tab!", 24, {
			Name = "Empty",
			TextColor3 = T.Muted,
			TextXAlignment = Enum.TextXAlignment.Center,
			Position = UDim2.fromScale(0, 0.36),
			Size = UDim2.fromScale(1, 0.08),
			Visible = false,
			Parent = frame,
		})

		local function canJoin(room)
			return room.eligible and not room.inMatch and room.players < room.maxPlayers
		end

		local function join(roomId)
			local room = listed[roomId]
			if not room then
				return
			end
			if partyBlocked() then
				host.toast("Your party leader picks the room.", "error")
				return
			end
			if not canJoin(room) then
				local reason = if room.inMatch
					then "That room is in a match. Try again when it's done."
					elseif not room.eligible then "Your rating is outside this room's skill range."
					else "That room is full."
				host.toast(reason, "error")
				return
			end
			local ok, result = request("Join", roomId)
			if not ok then
				host.toast(result or "Couldn't join.", "error")
				task.spawn(refresh)
			end
		end

		local function buildRow(roomId)
			local button = make("TextButton", {
				Name = "Room" .. roomId,
				AutoButtonColor = false,
				Text = "",
				BackgroundColor3 = T.Raised,
				BorderSizePixel = 0,
				Parent = list,
			})
			sizer.height(button, ROOM_ROW)
			local name = Common.text("", 32, {
				Name = "RoomName",
				Font = T.HeadFont,
				Position = UDim2.fromScale(0.02, 0.04),
				Size = UDim2.fromScale(0.74, 0.4),
				TextWrapped = false,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Parent = button,
			})
			local tags = Common.text("", 18, {
				Name = "Tags",
				Font = T.BoldFont,
				TextColor3 = T.Gold,
				Position = UDim2.fromScale(0.02, 0.44),
				Size = UDim2.fromScale(0.74, 0.25),
				TextWrapped = false,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Parent = button,
			})
			local info = Common.text("", 18, {
				Name = "Summary",
				TextColor3 = T.Muted,
				Position = UDim2.fromScale(0.02, 0.69),
				Size = UDim2.fromScale(0.74, 0.25),
				TextWrapped = false,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Parent = button,
			})
			local action = UIKit.slantFrame({
				name = "Join",
				slant = T.Slant,
				gradient = { T.RedLight, T.RedDark },
				outline = 4,
				anchor = Vector2.new(1, 0.5),
				position = UDim2.fromScale(0.985, 0.5),
				size = UDim2.fromScale(0.17, 0.56),
				parent = button,
			})
			local actionText = Common.text("JOIN", 30, {
				Name = "Label",
				Font = T.HeadFont,
				TextXAlignment = Enum.TextXAlignment.Center,
				TextWrapped = false,
				Parent = action:FindFirstChild("Content") or action,
			})
			Common.focusable(button, { key = "Room" .. roomId }, function()
				join(roomId)
			end)
			return {
				button = button,
				name = name,
				tags = tags,
				info = info,
				action = action,
				actionText = actionText,
			}
		end

		local function renderRow(row, room, index)
			row.button.LayoutOrder = index
			row.name.Text = room.name
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
			row.tags.Text = table.concat(tags, "  ·  ")
			row.info.Text = summary({
				mode = room.mode,
				winRule = room.winRule,
				stocks = room.stocks,
				timeLimit = room.timeLimit,
				mapId = room.mapId,
				damageMultiplier = room.damageMultiplier,
				weapons = table.create(room.weaponCount or 0, true),
			})
			local open = canJoin(room) and not partyBlocked()
			row.actionText.Text = if canJoin(room)
				then "JOIN"
				elseif room.inMatch then "BUSY"
				elseif room.eligible then "FULL"
				else "LOCKED"
			row.actionText.TextColor3 = if open then T.Text else T.Dim
			if row.action:GetAttribute("Open") ~= open then
				row.action:SetAttribute("Open", open)
				UIKit.setSlantFill(row.action, if open then { T.RedLight, T.RedDark } else T.PanelLight)
			end
		end

		local function render(rooms)
			local seen = {}
			table.clear(ordered)
			table.clear(listed)
			for index, room in rooms do
				seen[room.id] = true
				listed[room.id] = room
				local row = rows[room.id] or buildRow(room.id)
				rows[room.id] = row
				renderRow(row, room, index)
				table.insert(ordered, row.button)
			end
			for id, row in rows do
				if not seen[id] then
					row.button:Destroy()
					rows[id] = nil
				end
			end
			Focus.linkColumn(ordered)
			emptyLabel.Visible = #ordered == 0
		end

		local refreshToken = 0
		refresh = function()
			refreshToken += 1
			local token = refreshToken
			local ok, rooms = request("List", filters)
			if token ~= refreshToken or not ok or type(rooms) ~= "table" then
				return
			end
			render(rooms)
		end

		views.Browse = {
			frame = frame,
			onShow = function()
				task.spawn(refresh)
			end,
			onParty = function()
				UIKit.setEnabled(joinCode, not partyBlocked())
				for id, row in rows do
					if listed[id] then
						renderRow(row, listed[id], row.button.LayoutOrder)
					end
				end
			end,
			defaultFocus = function()
				return ordered[1] or chips[1]
			end,
			top = function()
				return { chips[1], chips[2], chips[3], chips[4] }
			end,
			refresh = refresh,
		}
	end

	-- Create / edit ------------------------------------------------------------------------

	local form = defaultForm()
	local formSetters = {}

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

	local function resetForm()
		form = defaultForm()
		for key, set in formSetters do
			set(form[key])
		end
	end

	local function buildCreate(frame)
		local scroll = UIKit.scroll({ Size = UDim2.fromScale(1, 0.85), Parent = frame })
		UIKit.list(Enum.FillDirection.Vertical, 6).Parent = scroll
		local order = 0
		local firstRow = nil
		-- rows are sized in design px (they grow with their text at 1440p and up)
		local function add(row, px)
			order += 1
			row.LayoutOrder = order
			sizer.height(row, px or FORM_ROW, UDim.new(1, -10))
			row.Parent = scroll
			return row
		end
		local visibility = {}

		local nameRow = make("Frame", { BackgroundTransparency = 1 })
		local nameBox = UIKit.textbox("Room name", { Text = form.name, Size = UDim2.fromScale(1, 1), Parent = nameRow })
		nameBox.FocusLost:Connect(function()
			form.name = nameBox.Text
		end)
		add(nameRow, 40)
		firstRow = nameBox
		formSetters.name = function(v)
			nameBox.Text = v
		end

		local function refreshVisibility()
			for row, predicate in visibility do
				row.Visible = predicate()
			end
		end

		local rowMode, setMode = UIKit.cycle(
			"Mode",
			{
				{ value = "1v1", label = "1v1" },
				{ value = "2v2", label = "2v2" },
				{ value = "FFA", label = "Free-for-all" },
			},
			form.mode,
			function(v)
				form.mode = v
				refreshVisibility()
			end
		)
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

		local rowRule, setRule = UIKit.cycle(
			"Win rule",
			{
				{ value = "Stocks", label = "Stocks (lives)" },
				{ value = "Timed", label = "Timed (most KOs)" },
			},
			form.winRule,
			function(v)
				form.winRule = v
				refreshVisibility()
			end
		)
		add(rowRule)
		formSetters.winRule = setRule

		local rowStocks, setStocks = UIKit.stepper(
			"Stocks",
			Config.Rooms.StocksMin,
			Config.Rooms.StocksMax,
			1,
			form.stocks,
			nil,
			function(v)
				form.stocks = v
			end
		)
		add(rowStocks)
		visibility[rowStocks] = function()
			return form.winRule == "Stocks"
		end
		formSetters.stocks = setStocks

		local rowTime, setTime = UIKit.stepper(
			"Time limit",
			Config.Rooms.TimeMin,
			Config.Rooms.TimeMax,
			30,
			form.timeLimit,
			Util.formatTime,
			function(v)
				form.timeLimit = v
			end
		)
		add(rowTime)
		visibility[rowTime] = function()
			return form.winRule == "Timed"
		end
		formSetters.timeLimit = setTime

		local mapOptions = { { value = "Random", label = "Random (map vote)" } }
		for _, id in Maps.Order do
			table.insert(mapOptions, { value = id, label = Maps.get(id).Name })
		end
		local rowMap, setMap = UIKit.cycle("Map", mapOptions, form.mapId, function(v)
			form.mapId = v
		end)
		add(rowMap)
		formSetters.mapId = setMap

		-- the weapon chips: 3 a row, 36 design px each under a 30 design px title, all in Scale of the row
		local weaponLines = math.ceil(#Weapons.Order / 3)
		local weaponsPx = 30 + weaponLines * 36 + 16
		local weaponsRow = Common.fill(T.Raised, {})
		Common.padding(weaponsRow, 12, 8)
		UIKit.label("Weapons that drop", 18, {
			Font = T.BoldFont,
			Size = UDim2.fromScale(1, 30 / (weaponsPx - 16)),
			Parent = weaponsRow,
		})
		local weaponGrid = make("Frame", {
			BackgroundTransparency = 1,
			Position = UDim2.fromScale(0, 30 / (weaponsPx - 16)),
			Size = UDim2.fromScale(1, 1 - 30 / (weaponsPx - 16)),
			Parent = weaponsRow,
		}, {
			make("UIGridLayout", {
				CellSize = UDim2.new(1 / 3, -6, 1 / weaponLines, -6),
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
			chip:SetAttribute("FocusKey", "RoomWeapon" .. id)
			chip.Parent = weaponGrid
			weaponSetters[id] = set
		end
		add(weaponsRow, weaponsPx)
		formSetters.weapons = function(map)
			for id, set in weaponSetters do
				set(map[id] == true)
			end
		end

		local rowDamage, setDamage = UIKit.stepper(
			"Damage",
			Config.Rooms.DamageMultMin,
			Config.Rooms.DamageMultMax,
			0.25,
			form.damageMultiplier,
			function(v)
				return "x" .. v
			end,
			function(v)
				form.damageMultiplier = v
			end
		)
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

		local note = Common.text("", 20, {
			Name = "Note",
			Font = T.BoldFont,
			TextColor3 = T.Warning,
			Position = UDim2.fromScale(0, 0.87),
			Size = UDim2.fromScale(0.62, 0.12),
			Parent = frame,
		})
		local submit = Common.slantButton("CREATE ROOM", {
			name = "Submit",
			style = "primary",
			textSize = 34,
			anchor = Vector2.new(1, 1),
			position = UDim2.fromScale(1, 1),
			size = UDim2.fromScale(0.3, 0.12),
			parent = frame,
		}, function()
			if partyBlocked() then
				host.toast("Your party leader picks the room.", "error")
				return
			end
			if ClientState.room and not editing then
				host.toast("Leave your room first to make another one.", "error")
				return
			end
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
				host.toast(wasEditing and "Room updated." or "Room ready!", "good")
				showView("Room")
			else
				host.toast(result or "Couldn't save the room.", "error")
			end
		end)

		local function renderNote()
			local room = ClientState.room
			local text = ""
			if partyBlocked() then
				text = "Your party leader picks the room."
			elseif room and not editing then
				text = "You're in a room. Leave it to make your own."
			elseif editing then
				text = "Editing your room's rules."
			end
			note.Text = text
			Common.setButtonText(submit, if editing then "SAVE CHANGES" else "CREATE ROOM")
			UIKit.setEnabled(submit, not partyBlocked() and (editing or room == nil))
		end

		views.Create = {
			frame = frame,
			onShow = function()
				local room = ClientState.room
				local isHost = room ~= nil and room.hostUserId == player.UserId
				if isHost and room.state == "Open" then
					if not editing then
						editing = true
						loadForm(room)
					end
				elseif editing then
					editing = false
					resetForm()
				end
				refreshVisibility()
				renderNote()
			end,
			onParty = renderNote,
			defaultFocus = function()
				return firstRow
			end,
			top = function()
				return { firstRow }
			end,
		}
	end

	-- Room view ------------------------------------------------------------------------------

	local function buildRoom(frame)
		local roomParts = make("Frame", {
			Name = "InRoom",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Parent = frame,
		})
		local empty = Common.text("You're not in a room. Join one from BROWSE or make one in CREATE.", 26, {
			Name = "Empty",
			TextColor3 = T.Muted,
			TextXAlignment = Enum.TextXAlignment.Center,
			Position = UDim2.fromScale(0, 0.3),
			Size = UDim2.fromScale(1, 0.1),
			Parent = frame,
		})
		local title = Common.text("", 44, {
			Name = "RoomName",
			Font = T.HeadFont,
			Size = UDim2.fromScale(0.66, 0.09),
			TextWrapped = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = roomParts,
		})
		-- the code is read-only: a label (a TextBox would be a focus stop that opens the on-screen keyboard)
		local codeLabel = Common.text("", 30, {
			Name = "Code",
			Font = T.HeadFont,
			TextXAlignment = Enum.TextXAlignment.Center,
			BackgroundTransparency = 0,
			BackgroundColor3 = T.Raised,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			Size = UDim2.fromScale(0.3, 0.08),
			TextWrapped = false,
			Parent = roomParts,
		})
		Common.stroke(codeLabel, T.Stroke, 2)
		local info = Common.text("", 20, {
			Name = "Info",
			TextColor3 = T.Muted,
			TextYAlignment = Enum.TextYAlignment.Top,
			Position = UDim2.fromScale(0, 0.1),
			Size = UDim2.fromScale(1, 0.1),
			Parent = roomParts,
		})
		local members = Common.list(roomParts, {
			Position = UDim2.fromScale(0, 0.21),
			Size = UDim2.fromScale(1, 0.64),
		})

		-- footer: LEAVE, bot difficulty, ADD BOT, EDIT RULES, START (host)
		local botDifficulty = "Normal"
		local footer = make("Frame", {
			Name = "Footer",
			BackgroundTransparency = 1,
			Position = UDim2.fromScale(0, 0.88),
			Size = UDim2.fromScale(1, 0.12),
			Parent = roomParts,
		})
		local function footerButton(text, x, w, style, onClick)
			local button = Common.slantButton(text, {
				name = "Room" .. text,
				style = style,
				glyph = false,
				textSize = 30,
				position = UDim2.fromScale(x, 0),
				size = UDim2.fromScale(w, 1),
				parent = footer,
			}, onClick)
			return button
		end
		local leave = footerButton("LEAVE", 0, 0.14, "dark", function()
			request("Leave")
		end)
		local diffButton
		diffButton = footerButton("BOT: NORMAL", 0.16, 0.18, "dark", function()
			local order = Config.Bots.DifficultyOrder
			local index = table.find(order, botDifficulty) or 1
			botDifficulty = order[index % #order + 1]
			Common.setButtonText(diffButton, "BOT: " .. string.upper(botDifficulty))
		end)
		local addBot = footerButton("ADD BOT", 0.36, 0.14, "dark", function()
			local ok, result = request("AddBot", { difficulty = botDifficulty })
			if not ok then
				host.toast(result or "Couldn't add a bot.", "error")
			end
		end)
		local edit = footerButton("EDIT RULES", 0.52, 0.16, "dark", function()
			showView("Create")
		end)
		local start = footerButton("START MATCH", 0.72, 0.28, "primary", function()
			local ok, result = request("Start")
			if not ok then
				host.toast(result or "Couldn't start the match.", "error")
			end
		end)

		local memberRows = {} -- [member id] = row parts
		local function buildMember(id)
			local phone = Common.isPhone()
			local row = Common.fill(T.Raised, { Name = "Member" .. tostring(id), Parent = members })
			sizer.height(row, if phone then PHONE_MEMBER_ROW else MEMBER_ROW)
			local buttonHeight = if phone then 0.8 else 0.62
			local bar = Common.fill(T.Stroke, { Name = "Team", Size = UDim2.fromScale(0.008, 1), Parent = row })
			local name = Common.text("", 28, {
				Name = "MemberName",
				Font = T.BlackFont,
				Position = UDim2.fromScale(0.02, 0.06),
				Size = UDim2.fromScale(0.5, 0.5),
				TextWrapped = false,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Parent = row,
			})
			local detail = Common.text("", 18, {
				Name = "Detail",
				TextColor3 = T.Muted,
				Position = UDim2.fromScale(0.02, 0.56),
				Size = UDim2.fromScale(0.5, 0.38),
				TextWrapped = false,
				Parent = row,
			})
			local parts = { row = row, bar = bar, name = name, detail = detail, member = nil }
			parts.switch = UIKit.button("Switch team", "secondary", function()
				local m = parts.member
				if not m then
					return
				end
				local ok, result = request("SetTeam", { memberId = m.id, team = m.team == 1 and 2 or 1 })
				if not ok then
					host.toast(result or "Couldn't switch teams.", "error")
				end
			end, {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(0.82, -6, 0.5, 0),
				Size = UDim2.fromScale(0.17, buttonHeight),
				Parent = row,
			})
			parts.switch:SetAttribute("FocusKey", "MemberSwitch" .. tostring(id))
			parts.kick = UIKit.button("Kick", "danger", function()
				local m = parts.member
				if m then
					request(m.isBot and "RemoveBot" or "Kick", m.id)
				end
			end, {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(0.99, 0, 0.5, 0),
				Size = UDim2.fromScale(0.15, buttonHeight),
				Parent = row,
			})
			parts.kick:SetAttribute("FocusKey", "MemberKick" .. tostring(id))
			return parts
		end

		local function render(room)
			roomParts.Visible = room ~= nil
			empty.Visible = room == nil
			if not room then
				for id, parts in memberRows do
					parts.row:Destroy()
					memberRows[id] = nil
				end
				return
			end
			local isHost = room.hostUserId == player.UserId
			local open = room.state == "Open"
			title.Text = room.name
			codeLabel.Text = "CODE: " .. room.code
			local extras = {}
			if room.settings.private then
				table.insert(extras, "Private")
			end
			if room.settings.friendsOnly then
				table.insert(extras, "Friends only")
			end
			if room.settings.minRating or room.settings.maxRating then
				table.insert(
					extras,
					string.format("Skill %s-%s", room.settings.minRating or 0, room.settings.maxRating or "any")
				)
			end
			if not open then
				table.insert(extras, "Match in progress")
			end
			info.Text = summary(room.settings) .. (#extras > 0 and ("\n" .. table.concat(extras, "  ·  ")) or "")

			local teams = room.settings.mode ~= "FFA"
			local seen = {}
			for i, m in room.members do
				seen[m.id] = true
				local parts = memberRows[m.id] or buildMember(m.id)
				memberRows[m.id] = parts
				parts.member = m
				parts.row.LayoutOrder = i
				parts.bar.BackgroundColor3 = Config.TeamColors[m.team] or T.Stroke
				parts.name.Text = m.name .. (if m.isHost then "  (Host)" else "")
				local detail = if m.isBot
					then (tostring(m.difficulty) .. " bot")
					else string.format("Level %s  ·  %s rating", m.level or "?", m.rating or "?")
				if teams then
					detail = "Team " .. m.team .. "  ·  " .. detail
				end
				parts.detail.Text = detail
				local isMe = m.userId == player.UserId
				parts.switch.Visible = teams and open and (isHost or isMe)
				parts.kick.Visible = isHost and open and not isMe
				parts.kick.Text = if m.isBot then "Remove" else "Kick"
			end
			for id, parts in memberRows do
				if not seen[id] then
					parts.row:Destroy()
					memberRows[id] = nil
				end
			end

			diffButton.Visible = isHost
			addBot.Visible = isHost
			edit.Visible = isHost
			start.Visible = isHost
			UIKit.setEnabled(addBot, open)
			UIKit.setEnabled(edit, open)
			UIKit.setEnabled(start, open)
			leave.Visible = true
			-- the top row changes with the members: clear the old Up links, then link the new top row
			for _, parts in memberRows do
				Focus.link(parts.switch, "Up", nil)
				Focus.link(parts.kick, "Up", nil)
			end
			for _, button in { leave, diffButton, addBot, edit, start } do
				Focus.link(button, "Up", nil)
			end
			if currentView == "Room" then
				rewireTop()
			end
		end

		-- The top focusable row: the first member row with buttons, else the footer.
		local function topRow()
			local first, firstOrder = nil, math.huge
			for _, parts in memberRows do
				if (parts.switch.Visible or parts.kick.Visible) and parts.row.LayoutOrder < firstOrder then
					first, firstOrder = parts, parts.row.LayoutOrder
				end
			end
			if first then
				return { first.switch, first.kick }
			end
			return { leave, diffButton, addBot, edit, start }
		end

		views.Room = {
			frame = frame,
			onShow = function()
				render(ClientState.room)
			end,
			render = render,
			defaultFocus = function()
				local room = ClientState.room
				if room and room.hostUserId == player.UserId and room.state == "Open" then
					return start
				end
				return if room then leave else nil
			end,
			top = topRow,
		}
	end

	-- Switching ------------------------------------------------------------------------------

	local function onRoomChanged(room)
		-- ROOM opens when you join or create a room, not on every update of it (a member browsing CREATE stays)
		local appeared = room ~= nil and room.id ~= lastRoomId
		lastRoomId = room and room.id
		if views.Room then
			views.Room.render(room)
		end
		if room then
			if appeared and (currentView == "Browse" or (currentView == "Create" and not editing)) then
				showView("Room")
			end
		elseif currentView ~= "Browse" then
			editing = false
			showView("Browse")
		end
		if views.Create and views.Create.onParty then
			views.Create.onParty()
		end
	end

	local function build()
		if container then
			container:Destroy()
		end
		table.clear(views)
		local phone = Common.isPhone()
		-- phones: the whole body scrolls (the lists inside still scroll on their own)
		local canvas
		if phone then
			local scroller
			canvas, scroller = Common.body(root, sizer, { phoneHeight = PHONE_HEIGHT })
			container = scroller
		else
			container = Common.region(root)
			canvas = container
		end
		local top = if phone then 0.08 else 0.1
		local _, selectFromBar = UIKit.tabBar(TABS, {
			name = "Tabs",
			style = "big",
			position = UDim2.fromScale(0, 0),
			size = UDim2.fromScale(if phone then 0.6 else 0.45, top - 0.02),
			parent = canvas,
			onSelect = function(id)
				if id ~= currentView then
					if id ~= "Create" then
						editing = false
					end
					setView(id)
				end
			end,
		})
		selectTab = selectFromBar
		partyBanner = Common.text("Your party leader picks the room.", 24, {
			Name = "PartyBanner",
			Font = T.BlackFont,
			TextColor3 = T.Warning,
			TextXAlignment = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			Size = UDim2.fromScale(if phone then 0.38 else 0.5, top - 0.02),
			Visible = false,
			Parent = canvas,
		})
		local content = make("Frame", {
			Name = "Views",
			BackgroundTransparency = 1,
			Position = UDim2.fromScale(0, top),
			Size = UDim2.fromScale(1, 1 - top),
			Parent = canvas,
		})
		for _, tab in TABS do
			local frame = make("Frame", {
				Name = tab.id,
				BackgroundTransparency = 1,
				Size = UDim2.fromScale(1, 1),
				Visible = false,
				Parent = content,
			})
			if tab.id == "Browse" then
				buildBrowse(frame)
			elseif tab.id == "Create" then
				buildCreate(frame)
			else
				buildRoom(frame)
			end
		end
		views.Room.render(ClientState.room)
		setView(currentView)
		selectTab(currentView)
		renderParty()
	end
	rewireTop = Common.linkTop(host, function()
		local v = views[currentView]
		return if v and v.top then v.top() else {}
	end)
	lastRoomId = ClientState.room and ClientState.room.id
	build()
	Common.onModeChange(root, function()
		build()
		rewireTop()
		host.refresh()
	end)

	local function cycle(delta)
		local index = 1
		for i, tab in TABS do
			if tab.id == currentView then
				index = i
			end
		end
		local id = TABS[(index - 1 + delta) % #TABS + 1].id
		showView(id)
		rewireTop()
		local v = views[id]
		local target = v and v.defaultFocus and v.defaultFocus()
		if target then
			Focus.set(target)
		end
	end

	return {
		root = root,
		show = function(params)
			shown = true
			pollToken += 1
			local poll = pollToken
			-- the shell re-shows the screen with its last params after every match: a deep link applies once
			local wanted = if params ~= lastParams and type(params) == "table" then params.view else nil
			lastParams = params
			local room = ClientState.room
			lastRoomId = room and room.id
			if wanted == "Room" or (wanted == nil and room and currentView == "Browse") then
				showView("Room")
			elseif wanted == "Browse" or (room == nil and (currentView == "Room" or editing)) then
				-- (the room closed while this screen was hidden)
				showView("Browse")
			else
				setView(currentView)
			end
			bag.add(ClientState.RoomChanged:Connect(onRoomChanged))
			bag.add(ClientState.PartyChanged:Connect(renderParty))
			renderParty()
			rewireTop()
			task.spawn(function()
				while shown and pollToken == poll do
					task.wait(BROWSE_REFRESH)
					if shown and pollToken == poll and currentView == "Browse" and views.Browse then
						views.Browse.refresh()
					end
				end
			end)
		end,
		hide = function()
			shown = false
			bag.clear()
		end,
		back = function()
			if currentView == "Create" and editing then
				showView("Room")
				return true
			end
			return false
		end,
		defaultFocus = function()
			local v = views[currentView]
			return v and v.defaultFocus and v.defaultFocus()
		end,
		actions = {
			L1 = function()
				cycle(-1)
			end,
			R1 = function()
				cycle(1)
			end,
		},
		hints = function()
			return {
				{ action = "Confirm", label = "SELECT" },
				{ action = "L1", label = "" },
				{
					action = "R1",
					label = "TABS",
					onClick = function()
						cycle(1)
					end,
				},
				{ action = "Back", label = "BACK" },
			}
		end,
	}
end

return RoomsPanel
