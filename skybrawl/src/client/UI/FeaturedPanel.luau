--[[
    The FEATURED panel on the main menu (menus design 5.7): the active
    Config.Events (tag, title, body, colour, time left) followed by
    Config.News, one tile at a time, sliding to the next every
    Config.Menu.FeaturedSeconds; page dots and "i / n" show where you are.
    The tile is one focus stop (key "Featured") that keeps its instance
    while its content slides; Confirm, a click or a tap opens the tile's
    screen with its params. R1 / L1 (the main menu's actions) call next /
    previous. A tile with an image (Config image asset id) shows it; an
    event for a legend shows that legend's portrait instead.

    Each tile's page (and its portrait) is built once and kept for the
    panel's life; sliding moves the pages. The panel only turns while it is
    active: the main menu activates it in show() and stops it in hide(), so
    nothing rotates (or builds) behind another screen or a match.

    compact (phones): just the tile, no header or dots.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local Client = script.Parent.Parent
local ClientState = require(Client:WaitForChild("ClientState"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))
local Focus = require(script.Parent:WaitForChild("Focus"))
local Layout = require(script.Parent:WaitForChild("Layout"))
local LegendView = require(script.Parent:WaitForChild("LegendView"))
local MenuModels = require(script.Parent:WaitForChild("MenuModels"))

local T = UIKit.Theme
local make = UIKit.make

local FeaturedPanel = {}

local function slideInfo()
	return TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
end

local function text(name, parent, props, size)
	local label = make("TextLabel", {
		Name = name,
		BackgroundTransparency = 1,
		Text = "",
		Font = T.BlackFont,
		TextColor3 = T.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = parent.ZIndex + 1,
		Parent = parent,
	})
	for key, value in props do
		label[key] = value
	end
	Layout.bindText(label, size)
	return label
end

-- One tile's content (a page that slides in and out). Returns { frame, update(tile), destroy }.
local function page(parent, tile, compact)
	local frame = make("Frame", {
		Name = "Page",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Size = UDim2.fromScale(1, 1),
		ZIndex = parent.ZIndex + 1,
		Parent = parent,
	})
	make("UIGradient", {
		Color = ColorSequence.new(tile.color:Lerp(Color3.new(0, 0, 0), 0.45), tile.color),
		Rotation = 20,
		Parent = frame,
	})
	local zIndex = frame.ZIndex
	local portrait = nil
	local image = UIKit.assetId(tile.image)
	if image ~= "" then
		make("ImageLabel", {
			Name = "Art",
			BackgroundTransparency = 1,
			Image = image,
			ScaleType = Enum.ScaleType.Crop,
			Size = UDim2.fromScale(1, 1),
			ZIndex = zIndex + 1,
			Parent = frame,
		})
	elseif type(tile.params) == "table" and type(tile.params.legend) == "string" then
		portrait = LegendView.portrait(frame, { legend = tile.params.legend }, {
			anchor = Vector2.new(1, 1),
			position = UDim2.fromScale(1, 1),
			size = UDim2.fromScale(0.42, 1),
			zIndex = zIndex + 1,
		})
		portrait.frame.BackgroundTransparency = 1
	end
	if not compact then
		local tagHolder = make("Frame", {
			Name = "TagHolder",
			BackgroundTransparency = 1,
			Position = UDim2.fromScale(0.06, 0.1),
			Size = UDim2.fromScale(0.6, 0.15),
			ZIndex = zIndex + 2,
			Parent = frame,
		})
		UIKit.tag(
			tile.tag,
			{ parent = tagHolder, fill = T.Gold, textColor = T.GoldDark, size = 15, zIndex = zIndex + 2 }
		)
	end
	local title = text("Title", frame, {
		Font = T.HeadFont,
		Text = string.upper(tile.title),
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromScale(0.06, if compact then 0.1 else 0.3),
		Size = UDim2.fromScale(if portrait then 0.6 else 0.88, if compact then 0.8 else 0.46),
		ZIndex = zIndex + 3,
	}, if compact then 40 else 44)
	local stroke = make("UIStroke", { Color = T.Outline, Parent = title })
	Layout.bindStroke(stroke, 2)
	local bodyLabel = nil
	if not compact then
		bodyLabel = text("Body", frame, {
			Font = T.BoldFont,
			TextWrapped = true,
			Position = UDim2.fromScale(0.06, 0.78),
			Size = UDim2.fromScale(0.9, 0.18),
			ZIndex = zIndex + 3,
		}, 17)
	end
	-- the parts that change while the page is kept (the time left)
	local function update(newTile)
		title.Text = string.upper(newTile.title)
		if bodyLabel then
			local body = newTile.body
			if newTile.endsIn then
				body = body .. "  ·  " .. MenuModels.timeLeft(newTile.endsIn) .. " left"
			end
			bodyLabel.Text = body
		end
	end
	update(tile)
	return {
		frame = frame,
		update = update,
		destroy = function()
			if portrait then
				portrait.destroy()
			end
			frame:Destroy()
		end,
	}
end

--[[
    opts = { compact? } & Common. Returns { frame, tile (the focusable
    button), next(), previous(), setActive(on), destroy() }; it starts
    inactive.
]]
function FeaturedPanel.new(parent, opts)
	opts = opts or {}
	local compact = opts.compact == true
	local frame, body
	if compact then
		frame = make("Frame", {
			Name = "Featured",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			ZIndex = opts.zIndex or 1,
		})
		body = frame
	else
		frame, body = UIKit.cutPanel({ cut = 18, title = "FEATURED", titleSize = 36, zIndex = opts.zIndex or 1 })
		frame.Name = "Featured"
	end
	frame.Position = opts.position or frame.Position
	if typeof(opts.size) == "UDim2" then
		frame.Size = opts.size
	end
	frame.AnchorPoint = opts.anchor or frame.AnchorPoint
	frame.Parent = parent or opts.parent

	local zIndex = body.ZIndex + 1
	local counter = nil
	if not compact then
		counter = text("Counter", frame, {
			Font = T.BoldFont,
			TextColor3 = T.Muted,
			TextXAlignment = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(0.95, 0.04),
			Size = UDim2.fromScale(0.3, 0.12),
			ZIndex = frame.ZIndex + 3,
		}, 18)
	end
	local tile = make("TextButton", {
		Name = "Tile",
		BackgroundColor3 = T.Raised,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = "",
		ClipsDescendants = true,
		Position = if compact then UDim2.new() else UDim2.fromScale(0.04, 0),
		Size = if compact then UDim2.fromScale(1, 1) else UDim2.fromScale(0.92, 0.74),
		ZIndex = zIndex,
		Parent = body,
	})
	local tileStroke =
		make("UIStroke", { Color = T.Outline, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = tile })
	Layout.bindStroke(tileStroke, 3)
	local dots = nil
	local hint = nil
	local setHint = nil
	if not compact then
		dots = make("Frame", {
			Name = "Dots",
			BackgroundTransparency = 1,
			Position = UDim2.fromScale(0.04, 0.8),
			Size = UDim2.fromScale(0.5, 0.06),
			ZIndex = zIndex,
			Parent = body,
		})
		Layout.bindListPadding(
			make("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Parent = dots,
			}),
			6
		)
		hint = make("Frame", {
			Name = "NextHint",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(0.96, 0.78),
			Size = UDim2.fromScale(0.4, 0.12),
			ZIndex = zIndex,
			Parent = body,
		})
		local nextHint
		nextHint, setHint = UIKit.hintBar(hint, {}, {
			anchor = Vector2.new(1, 0.5),
			position = UDim2.fromScale(1, 0.5),
		})
		nextHint.Size = UDim2.fromScale(1, 1)
	end

	local tiles = MenuModels.featuredTiles(ClientState.serverNow())
	local index = 1
	local pages = {} -- [tile id] = page, built once
	local current = nil -- the page on screen
	local untilNext = 0
	local active = false
	local destroyed = false

	local function renderDots()
		if counter then
			counter.Text = if #tiles > 0 then string.format("%d / %d", index, #tiles) else ""
		end
		if not dots then
			return
		end
		for _, child in dots:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
		for i = 1, #tiles do
			make("Frame", {
				Name = "Dot" .. i,
				BackgroundColor3 = if i == index then T.Text else T.Dim,
				BorderSizePixel = 0,
				Size = UDim2.fromScale(if i == index then 0.12 else 0.06, 0.4),
				LayoutOrder = i,
				ZIndex = zIndex,
				Parent = dots,
			})
		end
	end

	local function isListed(id)
		for _, t in tiles do
			if t.id == id then
				return true
			end
		end
		return false
	end

	-- Moves a page to x (fraction of the tile), sliding when `animate`; `after` runs once it is there.
	local function slide(p, x, animate, after)
		if p.tween then
			p.tween:Cancel()
			p.tween = nil
		end
		if not animate then
			p.frame.Position = UDim2.fromScale(x, 0)
			if after then
				after()
			end
			return
		end
		local tween = TweenService:Create(p.frame, slideInfo(), { Position = UDim2.fromScale(x, 0) })
		p.tween = tween
		tween.Completed:Connect(function(state)
			if p.tween == tween then
				p.tween = nil
			end
			if state == Enum.PlaybackState.Completed and after then
				after()
			end
		end)
		tween:Play()
	end

	-- A page that left the screen: hidden, or destroyed when its tile is gone.
	local function retire(p, id)
		if p == current or destroyed then
			return
		end
		if isListed(id) then
			p.frame.Visible = false
		else
			p.destroy()
			if pages[id] == p then
				pages[id] = nil
			end
		end
	end

	local function show(newIndex, direction)
		if #tiles == 0 then
			return
		end
		index = (newIndex - 1) % #tiles + 1
		untilNext = 0
		local t = tiles[index]
		local old, oldId = current, nil
		for id, p in pages do
			if p == old then
				oldId = id
			end
		end
		local p = pages[t.id]
		if not p then
			p = page(tile, t, compact)
			pages[t.id] = p
		end
		p.update(t)
		current = p
		p.frame.Visible = true
		if old and old ~= p then
			if direction ~= 0 then
				slide(p, direction, false)
				slide(p, 0, true)
				slide(old, -direction, true, function()
					retire(old, oldId)
				end)
			else
				slide(p, 0, false)
				retire(old, oldId)
			end
		else
			slide(p, 0, false)
		end
		renderDots()
	end

	-- Events start and end: the list is read again on every turn. Returns the shown tile's new index, or nil
	-- when it is gone.
	local function refreshTiles()
		local currentId = tiles[index] and tiles[index].id
		tiles = MenuModels.featuredTiles(ClientState.serverNow())
		local at = nil
		for i, t in tiles do
			if t.id == currentId then
				at = i
			end
		end
		-- drop the kept pages of tiles that are gone (not the one on screen or one still sliding out)
		for id, p in pages do
			if p ~= current and not p.tween and not isListed(id) then
				p.destroy()
				pages[id] = nil
			end
		end
		return at
	end

	local function nextTile()
		local at = refreshTiles()
		-- (the shown tile ended: the first one is next)
		show(if at then at + 1 else 1, 1)
	end

	local function previousTile()
		local at = refreshTiles()
		show(if at then at - 1 else 1, -1)
	end

	local function activate()
		local t = tiles[index]
		if t and t.screen then
			ClientState.OpenScreen:Fire(t.screen, t.params)
		end
	end

	UIKit.onActivate(tile, activate)
	Focus.register(tile, {
		key = "Featured",
		_style = function(on)
			tileStroke.Color = if on then T.Text else T.Outline
		end,
		actions = { R1 = nextTile, L1 = previousTile },
	})

	if setHint then
		setHint({ { action = "R1", label = "NEXT", onClick = nextTile } })
	end
	show(1, 0)
	local conn = RunService.Heartbeat:Connect(function(dt)
		if destroyed or not active or not frame.Parent then
			return
		end
		untilNext += dt
		if untilNext >= Config.Menu.FeaturedSeconds then
			nextTile()
		end
	end)

	return {
		frame = frame,
		tile = tile,
		next = nextTile,
		previous = previousTile,
		-- turning on (the main menu shows) / off (it hides): only an active panel rotates
		setActive = function(on)
			if destroyed or active == (on == true) then
				return
			end
			active = on == true
			if active then
				-- the list may have changed while it was off (an event ended during a match)
				show(refreshTiles() or 1, 0)
			end
		end,
		destroy = function()
			destroyed = true
			conn:Disconnect()
			for _, p in pages do
				p.destroy()
			end
			table.clear(pages)
			current = nil
			frame:Destroy()
		end,
	}
end

return FeaturedPanel
