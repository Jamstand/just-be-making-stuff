--[[
    Menu screen "OnlinePlay" (menus design 5.8, mockup c): Ranked 1v1,
    Ranked 2v2 and Free-for-all as three slanted cards. Each card shows
    still portraits on its colour, the mode, its rules, the party size it
    takes, the map count, your rating (ranked) and how many players are
    searching. The focused card grows and shows FIND MATCH (or CANCEL
    SEARCH on the queue you are in).

    A card your party can't start (Party.canStart) is "greyscale" with a
    striped SOLO ONLY / LEADER QUEUES band; Confirm on it toasts why. What
    each card says comes from Models.onlineCards (tested).

    Confirm = QueueRequest("Join", queueType) or ("Leave"). X opens the
    Invite screen for a solo player or the party leader. Phone: the rules
    text is hidden and the cards scroll.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Ranks = require(Shared.Ranks)

local UIKit = require(script.Parent.Parent.UIKit)
local Focus = require(script.Parent.Parent.Focus)
local LegendView = require(script.Parent.Parent.LegendView)
local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Common = require(script.Parent.Common)
local Models = require(script.Parent.Models)

local T = UIKit.Theme
local make = UIKit.make

local Screen = {
	id = "OnlinePlay",
	title = "ONLINE PLAY",
}

-- Card art: still portraits on the card's colour (the mockup's line-ups).
local ART = {
	Ranked1v1 = { legends = { "Yuki", "Vex" }, colors = { T.Raised, T.Backdrop }, vs = true },
	Ranked2v2 = { legends = { "Kestrel", "Sol", "Brann", "Moss" }, colors = { T.RedLight, T.RedDark }, vs = true },
	FFA = { legends = { "Yuki", "Brann", "Sol", "Moss" }, colors = { T.GoldLight, T.GoldDeep }, vs = false },
}

-- Card centres and sizes (fractions of the canvas on Wide, of the scrolling canvas on Phone).
local WIDE = {
	centers = { 0.078 + 0.13, 0.365 + 0.13, 0.661 + 0.13 },
	y = 0.243 + 0.565 / 2,
	size = Vector2.new(0.26, 0.565),
	focused = Vector2.new(0.27, 0.64),
}
local PHONE = {
	centers = { 1 / 6, 0.5, 5 / 6 },
	y = 0.5,
	size = Vector2.new(0.31, 0.9),
	focused = Vector2.new(0.32, 0.96),
}
local PHONE_HEIGHT = 760 -- design px of the scrolling canvas

local GREY = Color3.new(0.45, 0.45, 0.45)
local GROW = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Greys (or restores) every ViewportFrame / ImageLabel in a portrait; images the portrait adds later follow.
local function tintImage(obj, grey)
	if obj:IsA("ViewportFrame") or obj:IsA("ImageLabel") then
		local base = obj:GetAttribute("BaseImageColor")
		if base == nil then
			base = obj.ImageColor3
			obj:SetAttribute("BaseImageColor", base)
		end
		obj.ImageColor3 = if grey then GREY else base
	end
end

local function greyPortrait(frame, grey)
	if frame:GetAttribute("Grey") == grey then
		return
	end
	frame:SetAttribute("Grey", grey)
	tintImage(frame, grey)
	for _, obj in frame:GetDescendants() do
		tintImage(obj, grey)
	end
end

local function watchPortrait(frame)
	frame.DescendantAdded:Connect(function(obj)
		tintImage(obj, frame:GetAttribute("Grey") == true)
	end)
end

-- Diagonal stripes (alternating Raised / Backdrop, hard steps, at most 20 keypoints) for the locked band.
local function stripes(parent)
	local keypoints = { ColorSequenceKeypoint.new(0, T.Raised) }
	local bands = 9
	for i = 1, bands - 1 do
		local t = i / bands
		local before = if i % 2 == 1 then T.Raised else T.Backdrop
		local after = if i % 2 == 1 then T.Backdrop else T.Raised
		table.insert(keypoints, ColorSequenceKeypoint.new(t - 0.002, before))
		table.insert(keypoints, ColorSequenceKeypoint.new(t, after))
	end
	table.insert(keypoints, ColorSequenceKeypoint.new(1, if bands % 2 == 1 then T.Raised else T.Backdrop))
	make("UIGradient", { Color = ColorSequence.new(keypoints), Rotation = 60, Parent = parent })
end

-- A simple padlock drawn from frames (no uploads).
local function padlock(parent, zIndex)
	local box = make("Frame", {
		Name = "Lock",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0.035, 0.5),
		Size = UDim2.fromScale(0.07, 0.55),
		ZIndex = zIndex,
		Parent = parent,
	})
	make("UIAspectRatioConstraint", { AspectRatio = 0.8, Parent = box })
	local shackle = make("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromScale(0.62, 0.6),
		ZIndex = zIndex,
		Parent = box,
	}, { UIKit.corner(100) })
	Common.stroke(shackle, T.Text, 4)
	Common.fill(T.Text, {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromScale(1, 0.58),
		ZIndex = zIndex + 1,
		Parent = box,
	})
end

function Screen.build(host)
	local root = Common.root(host, "OnlinePlay")
	local sizer = Common.sizer(root)
	local bag = Common.bag()
	local inst
	local cards = {} -- [queueType] = card parts
	local order = {} -- card buttons in screen order
	local typeOf = {} -- [card button] = queueType
	local views = {} -- [queueType] = Models.onlineCard view
	local focusedType = nil
	local geometry = WIDE

	local function canManage()
		local size, leader = Common.partyInfo()
		return size == 1 or leader
	end

	local function activate(queueType)
		local view = views[queueType]
		if not view then
			return
		end
		if view.locked then
			host.toast(view.lockReason or "You can't queue for this right now.", "error")
			return
		end
		if view.queued then
			Common.invoke("QueueRequest", "Leave")
			return
		end
		local ok, message = Common.invoke("QueueRequest", "Join", queueType)
		if not ok then
			host.toast(message or "Couldn't join the queue.", "error")
		end
	end

	local function sizeOf(queueType)
		local grow = focusedType == queueType and Focus.mode() ~= "Touch"
		local s = if grow then geometry.focused else geometry.size
		return UDim2.fromScale(s.X, s.Y)
	end

	local function render()
		local state = {
			party = ClientState.party,
			userId = Players.LocalPlayer.UserId,
			queue = ClientState.queue,
			profile = ClientState.profile,
			stats = ClientState.queueStats,
		}
		local touch = Focus.mode() == "Touch"
		for _, view in Models.onlineCards(state) do
			views[view.queueType] = view
			local c = cards[view.queueType]
			if c then
				local locked = view.locked
				local textColor = if locked then T.Dim else T.Text
				Common.setTag(c.tag, view.tag, {
					fill = if view.ranked then T.Gold else T.Raised,
					textColor = if view.ranked then T.GoldDark else T.Text,
				})
				c.name.Text = view.name
				c.name.TextColor3 = textColor
				c.rules.Text = view.rules
				c.rules.TextColor3 = if locked then T.Dim else T.Muted
				Common.setTag(c.partyChip, (view.partyFits and "✓ " or "") .. view.party, {
					fill = if view.partyFits and not locked then T.Good else T.Raised,
					textColor = if view.partyFits and not locked then T.Backdrop else textColor,
				})
				Common.setTag(c.mapsChip, view.maps, { fill = T.Raised, textColor = if locked then T.Dim else T.Muted })
				c.ratingRow.Visible = view.rating ~= nil
				if view.rating then
					Common.setTierBadge(c.tierBadge, view.tier)
					c.rating.Text = string.format("%s  %d", string.upper(view.tier), view.rating)
					c.rating.TextColor3 = if locked then T.Dim else Ranks.tier(view.rating).Color
				end
				c.searching.Text = view.searching
				c.searching.TextColor3 = if locked then T.Dim else T.Muted
				c.overlay.Visible = locked
				for _, portrait in c.portraits do
					greyPortrait(portrait.frame, locked)
				end
				c.band.Visible = locked
				c.bandTitle.Text = view.lockTitle or ""
				c.bandReason.Text = view.lockReason or ""
				-- FIND MATCH / CANCEL SEARCH: on the focused card, the queue you are in, and every open card on touch
				local showAction = not locked and (view.queued or focusedType == view.queueType or touch)
				c.action.Visible = showAction
				c.actionText.Text = view.action
				if c.action:GetAttribute("Queued") ~= view.queued then
					c.action:SetAttribute("Queued", view.queued)
					UIKit.setSlantFill(
						c.action,
						if view.queued then { T.ButtonTop, T.ButtonBottom } else { T.RedLight, T.RedDark }
					)
				end
			end
		end
	end

	-- Card sizes without a tween (after a rebuild or an input mode change).
	local function resize()
		for queueType, c in cards do
			c.button.Size = sizeOf(queueType)
		end
	end

	local function focusCard(queueType)
		if focusedType == queueType then
			return
		end
		local old = focusedType
		focusedType = queueType
		for _, id in { old, queueType } do
			local c = id and cards[id]
			if c then
				TweenService:Create(c.button, GROW, { Size = sizeOf(id) }):Play()
				c.button.ZIndex = if id == queueType then 3 else 2
			end
		end
		render()
	end

	local function buildCard(parent, index, info)
		local queueType = info.queueType
		local art = ART[queueType]
		local phone = geometry == PHONE
		local button, body = UIKit.card({
			slant = -T.CardSlant,
			name = queueType,
			anchor = Vector2.new(0.5, 0.5),
			position = UDim2.fromScale(geometry.centers[index], geometry.y),
			size = UDim2.fromScale(geometry.size.X, geometry.size.Y),
			zIndex = 2,
			parent = parent,
			onClick = function()
				activate(queueType)
			end,
		})
		button:SetAttribute("FocusKey", "Online" .. queueType)
		local z = button.ZIndex + 1

		-- art: still portraits on the card's colour
		local artFrame = Common.fill(art.colors[1], {
			Name = "Art",
			Size = UDim2.fromScale(1, 0.44),
			ClipsDescendants = true,
			ZIndex = z,
			Parent = body,
		})
		Common.gradient(artFrame, art.colors[1], art.colors[2], 115)
		-- busts standing on the art's foot, sized by the art's height and overlapping like a line-up
		-- (portrait backgrounds cleared so the card colour shows between them)
		local portraits = {}
		local count = #art.legends
		local bustHeight = if count == 2 then 0.95 else 0.78
		for i, legend in art.legends do
			local slot = make("Frame", {
				Name = "Slot" .. i,
				BackgroundTransparency = 1,
				AnchorPoint = Vector2.new(0.5, 1),
				Position = UDim2.fromScale((i - 0.5) / count, 1),
				Size = UDim2.fromScale(1, bustHeight),
				ZIndex = z + i,
				Parent = artFrame,
			})
			make("UIAspectRatioConstraint", {
				AspectRatio = 1,
				DominantAxis = Enum.DominantAxis.Height,
				Parent = slot,
			})
			local portrait = LegendView.portrait(slot, { legend = legend }, { zIndex = z + i })
			portrait.frame.BackgroundTransparency = 1
			watchPortrait(portrait.frame)
			table.insert(portraits, portrait)
		end
		if art.vs then
			local vs = Common.text("VS", 64, {
				Name = "VS",
				Font = T.LogoFont,
				TextXAlignment = Enum.TextXAlignment.Center,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.32),
				Size = UDim2.fromScale(0.4, 0.4),
				ZIndex = z + count + 2,
				Parent = artFrame,
			})
			Common.textStroke(vs, T.Outline, 4)
		end
		local overlay = Common.fill(T.Dim, {
			Name = "Grey",
			BackgroundTransparency = 0.4,
			Size = UDim2.fromScale(1, 1),
			ZIndex = z + count + 3,
			Visible = false,
			Parent = artFrame,
		})

		local tag = Common.tag("", {
			name = "ModeTag",
			position = UDim2.fromScale(0.05, 0.47),
			size = UDim2.fromScale(0.3, 0.045),
			zIndex = z,
			parent = body,
		})
		-- the body is only the card's middle rectangle (about 370 px wide at 1080p): long names get a smaller size
		local name = Common.text(info.name, if #info.name > 8 then 62 else 72, {
			Name = "ModeName",
			Font = T.HeadFont,
			Position = UDim2.fromScale(0.05, 0.52),
			Size = UDim2.fromScale(0.92, 0.1),
			TextWrapped = false,
			ZIndex = z,
			Parent = body,
		})
		-- three lines of 20 px fit in 0.125 of the card
		local rules = Common.text(info.rules, 20, {
			Name = "Rules",
			Font = T.BodyFont,
			TextColor3 = T.Muted,
			TextYAlignment = Enum.TextYAlignment.Top,
			Position = UDim2.fromScale(0.05, 0.625),
			Size = UDim2.fromScale(0.9, 0.125),
			Visible = not phone,
			ZIndex = z,
			Parent = body,
		})
		local chipsY = if phone then 0.64 else 0.76
		local partyChip = Common.tag("", {
			name = "PartyChip",
			position = UDim2.fromScale(0.05, chipsY),
			size = UDim2.fromScale(0.44, 0.045),
			zIndex = z,
			parent = body,
		})
		local mapsChip = Common.tag("", {
			name = "MapsChip",
			position = UDim2.fromScale(0.52, chipsY),
			size = UDim2.fromScale(0.24, 0.045),
			zIndex = z,
			parent = body,
		})
		local infoY = chipsY + 0.065
		local ratingRow = make("Frame", {
			Name = "Rating",
			BackgroundTransparency = 1,
			Position = UDim2.fromScale(0.05, infoY),
			Size = UDim2.fromScale(0.5, 0.045),
			ZIndex = z,
			Parent = body,
		})
		local tierBadge = Common.tierBadge("Tin", {
			size = UDim2.fromScale(0.2, 1),
			zIndex = z,
			parent = ratingRow,
		})
		local rating = Common.text("", 22, {
			Font = T.BlackFont,
			Position = UDim2.fromScale(0.2, 0),
			Size = UDim2.fromScale(0.8, 1),
			TextWrapped = false,
			ZIndex = z,
			Parent = ratingRow,
		})
		local searching = Common.text("", 20, {
			Name = "Searching",
			Font = T.BoldFont,
			TextColor3 = T.Muted,
			TextXAlignment = if info.ranked then Enum.TextXAlignment.Right else Enum.TextXAlignment.Left,
			Position = if info.ranked then UDim2.fromScale(0.55, infoY) else UDim2.fromScale(0.05, infoY),
			Size = UDim2.fromScale(0.4, 0.045),
			TextWrapped = false,
			ZIndex = z,
			Parent = body,
		})

		-- FIND MATCH / CANCEL SEARCH (a visual: the whole card is the button)
		local action = UIKit.slantFrame({
			name = "Action",
			slant = T.Slant,
			gradient = { T.RedLight, T.RedDark },
			outline = 4,
			position = UDim2.fromScale(0.04, 0.88),
			size = UDim2.fromScale(0.92, 0.09),
			zIndex = z,
			parent = body,
		})
		local content = action:FindFirstChild("Content") or action
		Common.glyph("Confirm", {
			anchor = Vector2.new(0, 0.5),
			position = UDim2.fromScale(0.16, 0.5),
			size = UDim2.fromScale(0.12, 0.7),
			zIndex = z + 2,
			parent = content,
		})
		local actionText = Common.text("FIND MATCH", 44, {
			Name = "Label",
			Font = T.HeadFont,
			TextXAlignment = Enum.TextXAlignment.Center,
			Position = UDim2.fromScale(0.2, 0),
			Size = UDim2.fromScale(0.7, 1),
			TextWrapped = false,
			ZIndex = z + 2,
			Parent = content,
		})

		-- the locked band: a plain rotated rectangle (no clipping under rotation), striped, across the art's foot
		local band = Common.fill(Color3.new(1, 1, 1), {
			Name = "LockBand",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.42),
			Size = UDim2.fromScale(1.1, 0.16),
			Rotation = -8,
			ZIndex = z + 6,
			Visible = false,
			Parent = button,
		})
		stripes(band)
		Common.stroke(band, T.Outline, 3)
		padlock(band, z + 7)
		local bandTitle = Common.text("", 52, {
			Name = "Title",
			Font = T.HeadFont,
			Position = UDim2.fromScale(0.14, 0.04),
			Size = UDim2.fromScale(0.84, 0.56),
			TextWrapped = false,
			ZIndex = z + 7,
			Parent = band,
		})
		local bandReason = Common.text("", 18, {
			Name = "Reason",
			Font = T.BoldFont,
			Position = UDim2.fromScale(0.14, 0.58),
			Size = UDim2.fromScale(0.84, 0.38),
			TextYAlignment = Enum.TextYAlignment.Top,
			ZIndex = z + 7,
			Parent = band,
		})

		cards[queueType] = {
			button = button,
			tag = tag,
			name = name,
			rules = rules,
			partyChip = partyChip,
			mapsChip = mapsChip,
			ratingRow = ratingRow,
			tierBadge = tierBadge,
			rating = rating,
			searching = searching,
			overlay = overlay,
			portraits = portraits,
			band = band,
			bandTitle = bandTitle,
			bandReason = bandReason,
			action = action,
			actionText = actionText,
		}
		table.insert(order, button)
		typeOf[button] = queueType
	end

	-- Built for the current layout mode; rebuilt when it changes (phone <-> wide).
	local container = nil
	local function build()
		if container then
			container:Destroy()
		end
		table.clear(cards)
		table.clear(order)
		table.clear(typeOf)
		local parent
		if Common.isPhone() then
			geometry = PHONE
			local canvas, scroller = Common.body(root, sizer, { phoneHeight = PHONE_HEIGHT })
			parent, container = canvas, scroller
		else
			-- Wide: the cards sit at canvas fractions from the mockup
			geometry = WIDE
			container = make("Frame", {
				Name = "Body",
				BackgroundTransparency = 1,
				Size = UDim2.fromScale(1, 1),
				Parent = root,
			})
			parent = container
		end
		for i, info in Models.ONLINE do
			buildCard(parent, i, info)
		end
		Focus.linkRow(order)
		render()
		resize()
	end
	build()

	local rewireTop = Common.linkTop(host, function()
		return order
	end)

	Common.onModeChange(root, function()
		build()
		rewireTop()
		host.refresh()
	end)

	local function openInvite()
		if canManage() then
			host.push("Invite")
		else
			host.toast("Only the party leader can invite players.", "error")
		end
	end

	inst = {
		root = root,
		show = function()
			bag.add(ClientState.PartyChanged:Connect(render))
			bag.add(ClientState.QueueChanged:Connect(render))
			bag.add(ClientState.ProfileChanged:Connect(render))
			bag.add(ClientState.QueueStatsChanged:Connect(render))
			bag.add(Focus.ModeChanged:Connect(function()
				render()
				resize()
			end))
			bag.add(Focus.Changed:Connect(function(new)
				focusCard(new and typeOf[new])
			end))
			render()
			rewireTop()
		end,
		hide = function()
			bag.clear()
			focusedType = nil
			resize()
		end,
		defaultFocus = function()
			for _, view in
				Models.onlineCards({
					party = ClientState.party,
					userId = Players.LocalPlayer.UserId,
					queue = ClientState.queue,
				})
			do
				if view.queued then
					return cards[view.queueType] and cards[view.queueType].button
				end
			end
			for _, button in order do
				local view = views[typeOf[button]]
				if view and not view.locked then
					return button
				end
			end
			return order[1]
		end,
		actions = {
			X = openInvite,
		},
		hints = function()
			local items = {
				{ action = "Confirm", label = "FIND MATCH" },
				{ action = "Back", label = "BACK" },
			}
			if canManage() then
				table.insert(items, { action = "X", label = "INVITE", onClick = openInvite })
			end
			return items
		end,
	}
	return inst
end

return Screen
