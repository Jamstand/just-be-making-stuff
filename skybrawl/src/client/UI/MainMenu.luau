--[[
    The main menu, the root of the menu stack (menus design 5.7; mockups b
    and i). A screen module like Screens/<Id> (id, title, build(host)).

    Wide: the small SKYBRAWL logo, a dark slanted slab behind the button
    stack (in the full-bleed back gui, its red right edge leaning like the
    buttons), eight slanted buttons stepping left down the slab (ONLINE
    PLAY, PRACTICE, CUSTOM ROOMS, LEGENDS, STORE, RANKINGS, PROFILE,
    SETTINGS), the focused button's description under them, your legend in
    3D in the middle with a glow in its colour, its nameplate and CHANGE
    (Y), the FEATURED panel and DAILY MISSIONS on the right. The shell adds
    the player card, queue banner, party bar and hints.

    Phone: ONLINE PLAY across the top, the other buttons plus MISSIONS
    (badge = claimable missions) in two columns, the featured tile and a
    mini missions panel on the right, the legend behind the right half.

    Focus (Wide): the buttons are a column; each one's Right goes to CHANGE,
    whose Left returns to the button you came from and whose Right goes to
    the featured tile; featured Down goes to the missions, whose Left goes
    back to CHANGE; the last button's Down goes to the party bar, whose
    slots form a row (Up to the last button, the last slot's Right to
    CHANGE); while searching, ONLINE PLAY's Up is the banner's CANCEL and
    back. Actions: Y change legend, X invite, R1 / L1 featured, Back
    cancels the search. Phone: a grid (linkGrid) whose rows lead Right to
    the featured tile, then Down through the mini missions to CHANGE.

    Hints: the bar's X INVITE and Y CHANGE run those actions when tapped
    (not the focused object's own X); while a mission row is focused they
    read CLAIM / REROLL where its Confirm / X do that instead.

    The 3D legend is made in show() and destroyed in hide(), and the
    featured panel only turns while the menu shows, so nothing animates or
    builds behind a match or another screen.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Legends = require(Shared.Legends)
local Net = require(Shared.Net)

local Client = script.Parent.Parent
local ClientState = require(Client:WaitForChild("ClientState"))
local Settings = require(Client:WaitForChild("Controllers"):WaitForChild("Settings"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))
local Focus = require(script.Parent:WaitForChild("Focus"))
local Layout = require(script.Parent:WaitForChild("Layout"))
local LegendView = require(script.Parent:WaitForChild("LegendView"))
local MenuModels = require(script.Parent:WaitForChild("MenuModels"))
local FeaturedPanel = require(script.Parent:WaitForChild("FeaturedPanel"))
local MissionsWidget = require(script.Parent:WaitForChild("MissionsWidget"))

local T = UIKit.Theme
local make = UIKit.make

local MainMenu = {
	id = "MainMenu",
	title = "MAIN MENU",
}

local SLAB_TRANSPARENCY = 0.15
local GLOWS = { { 0.24, 0.5, 0.75 }, { 0.32, 0.66, 0.85 }, { 0.42, 0.82, 0.92 } } -- width, height, transparency

-- Phone grid (mockup i, 844 x 390 points): rows of { id, label } at y 112 / 160 / 208 / 256.
local PHONE_ROWS = {
	{ { "Practice", "PRACTICE" }, { "CustomRooms", "CUSTOM ROOMS" } },
	{ { "Legends", "LEGENDS" }, { "Store", "STORE" } },
	{ { "Rankings", "RANKINGS" }, { "Profile", "PROFILE" } },
	{ { "Settings", "SETTINGS" }, { "Missions", "MISSIONS" } },
}

local function legendSpec()
	local profile = ClientState.profile
	local legend = (profile and Legends.isValid(profile.Legend) and profile.Legend) or Legends.Default
	return { legend = legend, ownLook = Settings.get("FightAsAvatar") == true and not Legends.usesAvatar(legend) }
end

function MainMenu.build(host)
	local root = make("Frame", {
		Name = "MainMenu",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
		Parent = host.content,
	})
	local backdrop = host.backdrop
	local chrome = host.chrome or {}

	local shown = false
	local buttons = {} -- in focus order (Wide: the column; Phone: the grid, row by row)
	local buttonIds = {} -- [button] = screen id
	local grid = {} -- phone: rows of buttons
	local change = nil
	local featured = nil
	local missions = nil
	local slab = nil
	local edge = nil
	local description = nil
	local view = nil
	local viewHolder = nil
	local glow = nil
	local plate, plateName, plateTitle = nil, nil, nil
	local missionsButton = nil
	local lastButton = nil
	local backLinks = {} -- what leads Left back to the last focused button (Wide: CHANGE; Phone: the right column)
	local currentSpec = nil
	local built = {} -- everything this layout made (destroyed on a layout switch)

	local function open(id)
		host.push(id)
	end

	-- (a mission row's hints can change without a profile change: the missions' day ran out)
	local function refreshIfShown()
		if shown then
			host.refresh()
		end
	end

	local function canInvite()
		return MenuModels.canInvite(ClientState.party, game:GetService("Players").LocalPlayer.UserId)
	end

	local function track(obj)
		table.insert(built, obj)
		return obj
	end

	-- Slab ------------------------------------------------------------------------------

	-- The dark slab (and its red right edge) from the top of the screen to `bottom`, its right edge at `topX`.
	local function buildSlab(topX, bottom)
		slab = track(UIKit.slantFrame({
			parent = backdrop,
			name = "MenuSlab",
			fill = T.Backdrop,
			transparency = SLAB_TRANSPARENCY,
			position = UDim2.fromScale(-0.4, 0),
			size = UDim2.fromScale(topX + 0.4, bottom),
			zIndex = 1,
		}))
		edge = track(make("Frame", {
			Name = "SlabEdge",
			BackgroundColor3 = T.Red,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Rotation = T.Slant,
			ZIndex = 2,
			Parent = backdrop,
		}))
		local function place()
			local size = backdrop.AbsoluteSize
			local h = bottom * size.Y
			local s = h * math.tan(math.rad(T.Slant))
			local length = h / math.cos(math.rad(T.Slant))
			edge.Size = UDim2.fromOffset(math.max(2, Layout.px(6)), math.ceil(length))
			edge.Position = UDim2.fromOffset(topX * size.X - s / 2, h / 2)
		end
		track(backdrop:GetPropertyChangedSignal("AbsoluteSize"):Connect(place))
		place()
		slab.Visible = shown
		edge.Visible = shown
	end

	-- Legend, glow and nameplate ---------------------------------------------------------------

	local function renderPlate()
		local spec = legendSpec()
		local legend = Legends.get(spec.legend)
		if plate then
			UIKit.setSlantFill(plate, { legend.Color, legend.Color:Lerp(Color3.new(0, 0, 0), 0.35) })
			plateName.Text = string.upper(legend.Name)
			if plateTitle then
				plateTitle.Text = string.upper(legend.Title)
			end
		end
		if glow then
			for _, ellipse in glow:GetChildren() do
				if ellipse:IsA("Frame") then
					ellipse.BackgroundColor3 = legend.Color
				end
			end
		end
	end

	local function setLegend(flourish)
		local spec = legendSpec()
		renderPlate()
		if view then
			local key = spec.legend .. "|" .. tostring(spec.ownLook)
			if key ~= currentSpec then
				currentSpec = key
				view:set({ legend = spec.legend, ownLook = spec.ownLook, flourish = flourish })
			end
		end
	end

	local function buildGlow(x, y, scale)
		glow = track(make("Frame", {
			Name = "Glow",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			ZIndex = 1,
			Parent = root,
		}))
		for i, g in GLOWS do
			local ellipse = make("Frame", {
				Name = "Glow" .. i,
				BorderSizePixel = 0,
				BackgroundTransparency = g[3],
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(x, y),
				Size = UDim2.fromScale(g[1] * scale, g[2] * scale),
				ZIndex = 1,
				Parent = glow,
			})
			make("UICorner", { CornerRadius = UDim.new(1, 0), Parent = ellipse })
		end
	end

	local function buildChange(position, size, anchor)
		change = track(make("TextButton", {
			Name = "Change",
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			Text = "",
			AnchorPoint = anchor,
			Position = position,
			Size = size,
			ZIndex = 6,
			Parent = root,
		}))
		Layout.bindListPadding(
			make("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Parent = change,
			}),
			10
		)
		local glyphHolder = make("Frame", {
			Name = "GlyphHolder",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(0.62, 0.62),
			SizeConstraint = Enum.SizeConstraint.RelativeYY,
			LayoutOrder = 1,
			ZIndex = 6,
			Parent = change,
		})
		UIKit.glyph("Y", { parent = glyphHolder, zIndex = 6 })
		local label = make("TextLabel", {
			Name = "Label",
			BackgroundTransparency = 1,
			Text = "CHANGE",
			Font = T.BlackFont,
			TextColor3 = T.Text,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromScale(0, 0.6),
			LayoutOrder = 2,
			ZIndex = 6,
			Parent = change,
		})
		Layout.bindText(label, 20)
		UIKit.onActivate(change, function()
			open("Legends")
		end)
		Focus.register(change, { key = "Change" })
	end

	local function buildPlate(position, size, nameSize, withTitle)
		plate = track(UIKit.slantFrame({
			parent = root,
			name = "Nameplate",
			fill = T.Raised,
			outline = 4,
			anchor = Vector2.new(0.5, 0.5),
			position = position,
			size = size,
			zIndex = 5,
		}))
		local content = plate.Content
		plateName = make("TextLabel", {
			Name = "LegendName",
			BackgroundTransparency = 1,
			Font = T.HeadFont,
			TextColor3 = T.Text,
			TextXAlignment = if withTitle then Enum.TextXAlignment.Left else Enum.TextXAlignment.Center,
			Position = UDim2.fromScale(0.04, 0),
			Size = UDim2.fromScale(if withTitle then 0.5 else 0.92, 1),
			ZIndex = content.ZIndex + 1,
			Parent = content,
		})
		Layout.bindText(plateName, nameSize)
		local stroke = make("UIStroke", { Color = T.Outline, Parent = plateName })
		Layout.bindStroke(stroke, 2)
		plateTitle = nil
		if withTitle then
			plateTitle = make("TextLabel", {
				Name = "LegendTitle",
				BackgroundTransparency = 1,
				Font = T.BlackFont,
				TextColor3 = T.Text,
				TextTransparency = 0.1,
				TextXAlignment = Enum.TextXAlignment.Left,
				Position = UDim2.fromScale(0.52, 0.3),
				Size = UDim2.fromScale(0.46, 0.5),
				ZIndex = content.ZIndex + 1,
				Parent = content,
			})
			Layout.bindText(plateTitle, 20)
		end
	end

	-- Buttons ------------------------------------------------------------------------------

	local function menuButton(id, label, opts)
		local button = track(UIKit.slantButton(label, {
			parent = root,
			name = id,
			style = "dark",
			icon = opts.icon,
			textSize = opts.textSize,
			nudge = opts.nudge,
			position = opts.position,
			size = opts.size,
			anchor = opts.anchor,
			zIndex = 4,
		}, function()
			open(id)
		end))
		buttonIds[button] = id
		return button
	end

	local function buildWide()
		buildSlab(0.42, 0.85)
		local logo = track(make("TextLabel", {
			Name = "Logo",
			BackgroundTransparency = 1,
			Text = "SKYBRAWL",
			Font = T.LogoFont,
			TextColor3 = Color3.new(1, 1, 1),
			TextXAlignment = Enum.TextXAlignment.Left,
			Rotation = -3,
			Size = UDim2.fromScale(0.26, 0.09),
			ZIndex = 3,
			Parent = root,
		}))
		Layout.bindText(logo, 80)
		make("UIGradient", {
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, T.LogoGradient[1]),
				ColorSequenceKeypoint.new(0.5, T.LogoGradient[2]),
				ColorSequenceKeypoint.new(1, T.LogoGradient[3]),
			}),
			Rotation = 90,
			Parent = logo,
		})
		Layout.bindStroke(make("UIStroke", { Color = T.Outline, Parent = logo }), 6)
		Layout.clearTop(logo, UDim2.fromScale(0.033, 0.06))

		for i, def in MenuModels.BUTTONS do
			local row = i - 1
			local button = menuButton(def.id, def.label, {
				icon = def.icon,
				textSize = 54,
				nudge = true,
				position = UDim2.fromScale(0.115 - 0.0104 * row, 0.176 + 0.076 * row),
				size = UDim2.fromScale(0.284, 0.065),
			})
			table.insert(buttons, button)
		end

		local descriptionHolder = track(make("Frame", {
			Name = "Description",
			BackgroundTransparency = 1,
			Position = UDim2.fromScale(0.034, 0.8),
			Size = UDim2.fromScale(0.3, 0.075),
			ZIndex = 4,
			Parent = root,
		}))
		local descriptionBar = make("Frame", {
			Name = "Bar",
			BackgroundColor3 = T.Red,
			BorderSizePixel = 0,
			Position = UDim2.fromScale(0, 0.08),
			Rotation = T.Slant,
			ZIndex = 4,
			Parent = descriptionHolder,
		})
		Layout.bindApply(descriptionBar, function()
			descriptionBar.Size = UDim2.new(0, math.max(2, Layout.px(6)), 0.32, 0)
		end)
		description = make("TextLabel", {
			Name = "Text",
			BackgroundTransparency = 1,
			Text = MenuModels.DESCRIPTIONS.OnlinePlay,
			Font = T.BodyFont,
			TextColor3 = T.Text,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			Position = UDim2.fromScale(0.06, 0),
			Size = UDim2.fromScale(0.94, 1),
			ZIndex = 4,
			Parent = descriptionHolder,
		})
		Layout.bindText(description, 26)

		buildGlow(0.565, 0.56, 1)
		viewHolder = track(make("Frame", {
			Name = "LegendHolder",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			ZIndex = 2,
			Parent = root,
		}))
		buildPlate(UDim2.fromScale(0.565, 0.906), UDim2.fromScale(0.21, 0.058), 64, true)
		buildChange(UDim2.fromScale(0.68, 0.906), UDim2.fromScale(0.09, 0.05), Vector2.new(0, 0.5))

		featured = FeaturedPanel.new(root, {
			position = UDim2.fromScale(0.741, 0.157),
			size = UDim2.fromScale(0.24, 0.26),
			zIndex = 4,
		})
		missions = MissionsWidget.new(root, {
			compact = true,
			position = UDim2.fromScale(0.741, 0.435),
			size = UDim2.fromScale(0.24, 0.39),
			zIndex = 4,
			onChanged = refreshIfShown,
		})
	end

	local function phoneRect(x, y, w, h, rightAnchored)
		local fx, fy, fw, fh = Layout.phoneRect(x, y, w, h)
		if rightAnchored then
			return UDim2.fromScale(fx + fw, fy), UDim2.fromScale(fw, fh), Vector2.new(1, 0)
		end
		return UDim2.fromScale(fx, fy), UDim2.fromScale(fw, fh), Vector2.zero
	end

	local function buildPhone()
		-- the red edge runs from x 435 at the top to x 345 at the bottom of the 844-point screen
		buildSlab(435 / 844, 1)
		local position, size = phoneRect(86, 50, 296, 54)
		local online = menuButton("OnlinePlay", "ONLINE PLAY", { icon = "swords", textSize = 56, size = size })
		Layout.clearTop(online, position)
		table.insert(buttons, online)
		table.insert(grid, { online })
		for r, row in PHONE_ROWS do
			local y = 112 + (r - 1) * 48
			local left = 82 - (r - 1) * 10
			local gridRow = {}
			for c, def in row do
				local p, s = phoneRect(left + (c - 1) * 152, y, 146, 40)
				local button = menuButton(def[1], def[2], { textSize = 36, position = p, size = s })
				table.insert(buttons, button)
				table.insert(gridRow, button)
				if def[1] == "Missions" then
					missionsButton = button
				end
			end
			table.insert(grid, gridRow)
		end

		buildGlow(0.61, 0.55, 1.3)
		viewHolder = track(make("Frame", {
			Name = "LegendHolder",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			ZIndex = 2,
			Parent = root,
		}))
		local platePosition, plateSize = phoneRect(430, 343, 95, 27)
		buildPlate(platePosition + UDim2.fromScale(plateSize.X.Scale / 2, plateSize.Y.Scale / 2), plateSize, 34, false)
		-- on phones the nameplate itself is the CHANGE button
		local changePosition, changeSize = phoneRect(430, 343, 95, 27)
		buildChange(changePosition, changeSize, Vector2.zero)
		for _, child in change:GetChildren() do
			if child:IsA("GuiObject") then
				child.Visible = false
			end
		end

		local fPosition, fSize, fAnchor = phoneRect(640, 52, 156, 96, true)
		featured = FeaturedPanel.new(root, { compact = true, position = fPosition, size = fSize, zIndex = 4 })
		featured.frame.AnchorPoint = fAnchor
		local mPosition, mSize, mAnchor = phoneRect(640, 155, 156, 150, true)
		missions = MissionsWidget.new(root, {
			compact = true,
			mini = true,
			position = mPosition,
			size = mSize,
			zIndex = 4,
			onChanged = refreshIfShown,
		})
		missions.frame.AnchorPoint = mAnchor
	end

	-- Focus links ------------------------------------------------------------------------------

	local function relink()
		if #buttons == 0 or not change then
			return
		end
		local partySlots = if chrome.partyBar then chrome.partyBar.slots() else {}
		local cancel = host.cancelButton()
		local missionRows = if missions then missions.focusables() else {}
		if Layout.mode() == "Phone" then
			local rows = table.clone(grid)
			if #partySlots > 0 then
				table.insert(rows, partySlots)
			end
			Focus.linkGrid(rows)
			for _, row in grid do
				Focus.link(row[#row], "Right", featured and featured.tile or change)
			end
			-- the right column top to bottom: featured tile, the mini mission rows, CHANGE (the nameplate)
			local column = {}
			if featured then
				table.insert(column, featured.tile)
			end
			for _, row in missionRows do
				table.insert(column, row)
			end
			table.insert(column, change)
			Focus.linkColumn(column)
			backLinks = column
		else
			Focus.linkColumn(buttons)
			for _, button in buttons do
				Focus.link(button, "Right", change)
			end
			backLinks = { change }
			Focus.link(change, "Right", featured and featured.tile or nil)
			if featured then
				Focus.link(featured.tile, "Left", change)
				Focus.link(featured.tile, "Down", missionRows[1])
			end
			Focus.linkColumn(missionRows)
			if featured and missionRows[1] then
				Focus.link(missionRows[1], "Up", featured.tile)
			end
			for _, row in missionRows do
				Focus.link(row, "Left", change)
			end
			if #partySlots > 0 then
				Focus.link(buttons[#buttons], "Down", partySlots[1])
				Focus.linkRow(partySlots)
				for _, slot in partySlots do
					Focus.link(slot, "Up", buttons[#buttons])
				end
				Focus.link(partySlots[#partySlots], "Right", change)
			end
		end
		for _, obj in backLinks do
			Focus.link(obj, "Left", lastButton or buttons[1])
		end
		Focus.link(buttons[1], "Up", cancel)
		if cancel then
			Focus.link(cancel, "Down", buttons[1])
		end
		if missionsButton then
			local claimable = ClientState.profile
				and ClientState.profile.Missions
				and ClientState.profile.Missions.claimable
			UIKit.setBadge(missionsButton, if claimable and claimable > 0 then tostring(claimable) else nil)
		end
	end

	-- Build / rebuild -----------------------------------------------------------------------------

	local function destroyLayout()
		if view then
			view:destroy()
			view = nil
		end
		currentSpec = nil
		if featured then
			featured.destroy()
			featured = nil
		end
		if missions then
			missions.destroy()
			missions = nil
		end
		for _, obj in built do
			if typeof(obj) == "Instance" then
				if obj:IsA("GuiObject") then
					Focus.unregister(obj)
				end
				obj:Destroy()
			elseif typeof(obj) == "RBXScriptConnection" then
				obj:Disconnect()
			end
		end
		table.clear(built)
		table.clear(buttons)
		table.clear(buttonIds)
		table.clear(grid)
		backLinks = {}
		change, slab, edge, glow, plate, missionsButton, lastButton = nil, nil, nil, nil, nil, nil, nil
	end

	-- The focused mission row's { claimable, rerollable } (nil when focus is elsewhere).
	local function focusedMission()
		return if missions and missions.rowState then missions.rowState(Focus.get()) else nil
	end

	local function createView()
		if view or not viewHolder then
			return
		end
		local position, size, anchor
		if Layout.mode() == "Phone" then
			position, size, anchor = LegendView.fullFrame(0.61, 1, 0.58)
		else
			position, size, anchor = LegendView.fullFrame(0.565, 0.88, 0.56)
		end
		view = LegendView.new(viewHolder, {
			framing = "Full",
			facing = "Left",
			animated = true,
			position = position,
			size = size,
			anchor = anchor,
			zIndex = 2,
		})
		currentSpec = nil
		setLegend(false)
	end

	local function buildLayout()
		destroyLayout()
		if Layout.mode() == "Phone" then
			buildPhone()
		else
			buildWide()
		end
		renderPlate()
		if featured then
			featured.setActive(shown)
		end
		if shown then
			slab.Visible, edge.Visible = true, true
			createView()
			relink()
		end
	end

	buildLayout()

	-- Events ---------------------------------------------------------------------------------------

	Focus.Changed:Connect(function(new, old)
		local id = new and buttonIds[new]
		if id then
			lastButton = new
			for _, obj in backLinks do
				if obj.Parent then
					Focus.link(obj, "Left", new)
				end
			end
			if description then
				description.Text = MenuModels.DESCRIPTIONS[id] or ""
			end
		end
		-- the hints say CLAIM / REROLL while a mission row is focused
		if shown and missions and (missions.rowState(new) or missions.rowState(old)) then
			host.refresh()
		end
	end)
	ClientState.ProfileChanged:Connect(function()
		setLegend(true)
		task.defer(relink)
		if shown then
			-- (a claimed or rerolled row changes the hints)
			task.defer(host.refresh)
		end
	end)
	Settings.Changed:Connect(function(key)
		if key == "FightAsAvatar" then
			setLegend(true)
		end
	end)
	ClientState.QueueChanged:Connect(function()
		task.defer(relink)
	end)
	ClientState.PartyChanged:Connect(function()
		task.defer(relink)
	end)
	Layout.Changed:Connect(function()
		buildLayout()
		host.refresh()
	end)

	-- Screen instance ----------------------------------------------------------------------------------

	local function cancelSearch()
		task.spawn(function()
			local ok, message = Net.get("QueueRequest"):InvokeServer("Leave")
			if not ok and message then
				ClientState.toast(message, "error")
			end
		end)
	end

	return {
		root = root,
		show = function()
			shown = true
			if slab then
				slab.Visible, edge.Visible = true, true
			end
			if featured then
				featured.setActive(true)
			end
			createView()
			relink()
		end,
		hide = function()
			shown = false
			if slab then
				slab.Visible, edge.Visible = false, false
			end
			if featured then
				featured.setActive(false)
			end
			if view then
				view:destroy()
				view = nil
			end
			currentSpec = nil
		end,
		defaultFocus = function()
			return buttons[1]
		end,
		back = function()
			if ClientState.queue then
				cancelSearch()
			end
			return true
		end,
		actions = {
			Y = function()
				open("Legends")
			end,
			X = function()
				if canInvite() then
					open("Invite")
				end
			end,
			R1 = function()
				if featured then
					featured.next()
				end
			end,
			L1 = function()
				if featured then
					featured.previous()
				end
			end,
		},
		hints = function()
			local items = MenuModels.mainHints(ClientState.queue ~= nil, canInvite(), focusedMission())
			for _, item in items do
				-- tapping these runs the layer action they name, never a focused row's own X
				if item.action == "X" and item.label == "INVITE" then
					item.onClick = function()
						if canInvite() then
							open("Invite")
						end
					end
				elseif item.action == "Y" then
					item.onClick = function()
						open("Legends")
					end
				end
			end
			return items
		end,
		extraRoots = function()
			return {}
		end,
	}
end

return MainMenu
