--[[
    The VS splash (menus design 5.9, mockup e): shown in phase "Vs" from
    SelectEvent "Vs" until the match's "Start" (MatchClient sets the phase
    to "Match"; the splash then fades out over 0.3 s).

    Team modes: your team on the left in red, the other team on the right
    in blue, split by a white seam leaning 14 degrees (from (0.573, 0) at
    the top to (0.427, 1) at the bottom). The blue side is an oversized
    frame (1.2 x 1.6 of the screen) rotated 14 degrees clockwise whose left
    edge passes through the screen centre; legends and plates are never
    parented under a rotated frame. FFA: four strips in the team colours
    with the same lean, their edges at x 0.25 / 0.5 / 0.75.

    Legends are animated LegendViews (at most 4, front one bigger), with
    name plates (name, legend, rating + tier badge in ranked), the mode tag
    at the top, "VS" in the middle and the map card at the bottom.
    "LOADING..." shows under the map card once startsIn + 0.5 s passed.

    A "Vs" opens the splash only for the select session you are in (the
    SelectEvent's previousSelect): a session already cancelled (the match
    failed as it was created, so "Cancel" came first) is ignored.

    Leaving without a match: a SelectEvent "Cancel" for this session toasts
    its reason and returns to the menu; so does the watchdog when "Start"
    hasn't come startsIn + Config.Match.LoadTimeout +
    Config.Menu.VsWatchdogExtra seconds after the splash opened (MatchClient
    also returns to the menu on an End / Leave of the VS match before
    "Start"). Any phase change away from "Vs" removes the splash.

    Uses the select ScreenGuis (SkybrawlSelectBack 19 / SkybrawlSelect 20,
    shared with LegendSelect; each adds and removes its own roots).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Legends = require(Shared.Legends)
local Maps = require(Shared.Maps)
local Ranks = require(Shared.Ranks)

local Client = script.Parent.Parent.Parent
local ClientState = require(Client:WaitForChild("ClientState"))
local Controllers = Client:WaitForChild("Controllers")
local Sound = require(Controllers:WaitForChild("Sound"))
local SkyBackdrop = require(Controllers:WaitForChild("SkyBackdrop"))
local UI = script.Parent.Parent
local UIKit = require(UI:WaitForChild("UIKit"))
local Layout = require(UI:WaitForChild("Layout"))
local LegendView = require(UI:WaitForChild("LegendView"))
local Models = require(script.Parent:WaitForChild("Models"))

local VsSplash = {}

local T = UIKit.Theme
local make = UIKit.make

local player = Players.LocalPlayer

local LEAN = 14 -- degrees, clockwise
local SEAM = 0.023 -- of the screen width
local SLIDE_SECONDS = 0.25
local POP_SECONDS = 0.2
local FADE_SECONDS = 0.3
local LOADING_AFTER = 0.5 -- seconds past startsIn
local SIDE_RED = Config.TeamColors[1]
local SIDE_BLUE = Config.TeamColors[2]

--[[
    Geometry (fractions of the safe-area canvas). Legends: x of the feet,
    feet y and body height (feet to head top) in canvas heights; a
    Full-framed view is bodyHeight / 0.66 tall and 0.8x as wide, feet 4%
    above its bottom (LegendView 5.5).
]]
local WIDE = {
	front = { body = 0.72, feet = 1.16 },
	back = { body = 0.66, feet = 1.05 },
	ffa = { body = 0.6, feet = 1.06 },
	teamX = { left = { 0.2, 0.34 }, right = { 0.66, 0.83 }, solo = { left = 0.27, right = 0.73 } },
	plates = { ys = { 0.76, 0.83 }, w = 0.245, h = 0.056, x = 0.03, name = 54, legend = 20, rating = 22 },
	ffaPlates = { y = 0.7, w = 0.22, h = 0.056 },
	vs = { y = 0.42, w = 0.34, h = 0.3, size = 300, stroke = 20 },
	tag = { y = 0.035, h = 0.055, size = 34 },
	map = { y = 0.815, w = 0.224, h = 0.139, size = 46, tag = 16 },
	loading = 22,
	showLegendName = true,
}

local PHONE = {
	front = { body = 0.8, feet = 1.2 },
	back = { body = 0.72, feet = 1.1 },
	ffa = { body = 0.62, feet = 1.1 },
	teamX = { left = { 0.2, 0.33 }, right = { 0.67, 0.8 }, solo = { left = 0.27, right = 0.73 } },
	plates = { ys = { 0.68, 0.79 }, w = 0.42, h = 0.095, x = 0.01, name = 40, legend = 16, rating = 20 },
	ffaPlates = { y = 0.66, w = 0.235, h = 0.09 },
	vs = { y = 0.4, w = 0.3, h = 0.32, size = 150, stroke = 10 },
	tag = { y = 0.03, h = 0.08, size = 18 },
	map = { y = 0.86, w = 0.13, h = 0.13, size = 20, tag = 14 },
	loading = 18,
	showLegendName = false,
}

local splash = nil -- the open splash

-- Helpers ------------------------------------------------------------------------------

-- A TextLabel sized through Layout.bindText (size in design px); props first (Size included).
local function text(content, size, props)
	local label = make("TextLabel", {
		BackgroundTransparency = 1,
		Text = content or "",
		Font = T.BodyFont,
		TextColor3 = T.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		Size = UDim2.fromScale(1, 1),
	})
	local parent = nil
	for key, value in props or {} do
		if key == "Parent" then
			parent = value
		else
			label[key] = value
		end
	end
	Layout.bindText(label, size)
	label.Parent = parent
	return label
end

local function textStroke(label, thickness, color)
	local stroke = make("UIStroke", {
		Color = color or T.Outline,
		LineJoinMode = Enum.LineJoinMode.Round,
		Parent = label,
	})
	Layout.bindStroke(stroke, thickness)
	return stroke
end

local function container(name, parent, zIndex, className)
	return make(className or "Frame", {
		Name = name,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = zIndex or 1,
		Parent = parent,
	})
end

-- The two shared ScreenGuis (made on first use; LegendSelect finds the same ones).
local function selectGuis()
	local playerGui = player:WaitForChild("PlayerGui")
	local back = playerGui:FindFirstChild("SkybrawlSelectBack") or Layout.screenGui("SkybrawlSelectBack", 19, "Full")
	local front = playerGui:FindFirstChild("SkybrawlSelect") or Layout.screenGui("SkybrawlSelect", 20, "Safe")
	return back, front
end

-- Faint diagonal stripes over a side.
local function stripes(parent, zIndex)
	local frame = make("Frame", {
		Name = "Stripes",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0.965,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = zIndex,
		Parent = parent,
	})
	local keys = {}
	for i = 0, 18 do
		table.insert(keys, NumberSequenceKeypoint.new(i / 18, if i % 2 == 0 then 0 else 1))
	end
	make("UIGradient", { Rotation = -20, Transparency = NumberSequence.new(keys), Parent = frame })
	return frame
end

--[[
    A frame leaning LEAN degrees whose left edge passes through (edgeX, 0.5)
    of `host` (screen coordinates): 1.2 x 1.6 of the host, rotated about its
    centre, which is placed (w / 2) along the rotated x axis from that
    point. Re-placed whenever the host resizes.
]]
local function leaningFrame(host, edgeX, colors, zIndex)
	local frame = make("Frame", {
		Name = "Leaning",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromScale(1.2, 1.6),
		Rotation = LEAN,
		ZIndex = zIndex,
		Parent = host,
	})
	-- vertical on screen: the gradient's own rotation undoes the frame's
	make("UIGradient", {
		Color = ColorSequence.new(colors[2], colors[1]),
		Rotation = 90 - LEAN,
		Parent = frame,
	})
	local function place()
		local size = host.AbsoluteSize
		local half = size.X * 0.6
		local angle = math.rad(LEAN)
		frame.Position =
			UDim2.new(edgeX, math.floor(half * math.cos(angle) + 0.5), 0.5, math.floor(half * math.sin(angle) + 0.5))
	end
	host:GetPropertyChangedSignal("AbsoluteSize"):Connect(place)
	place()
	return frame
end

-- The white seam (with a black edge either side) along a leaning edge through (edgeX, 0.5).
local function seam(host, edgeX, zIndex)
	local outer = make("Frame", {
		Name = "SeamEdge",
		BackgroundColor3 = T.Outline,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(edgeX, 0.5),
		Size = UDim2.fromScale(SEAM * 1.6, 1.6),
		Rotation = LEAN,
		ZIndex = zIndex,
		Parent = host,
	})
	make("Frame", {
		Name = "Seam",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(edgeX, 0.5),
		Size = UDim2.fromScale(SEAM, 1.6),
		Rotation = LEAN,
		ZIndex = zIndex + 1,
		Parent = host,
	})
	return outer
end

-- A map's sky (its painted Sky image, else its gradient) filling `parent`.
local function mapArt(parent, mapId, zIndex)
	local info = Maps.get(mapId)
	local art = make("Frame", {
		Name = "Art",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Size = UDim2.fromScale(1, 1),
		ZIndex = zIndex,
		Parent = parent,
	})
	local sky = info and info.Sky
	make("UIGradient", {
		Color = ColorSequence.new(sky and sky.Top or T.Raised, sky and sky.Bottom or T.Backdrop),
		Rotation = 90,
		Parent = art,
	})
	local image = UIKit.assetId(SkyBackdrop.images(mapId).Sky)
	if image ~= "" then
		make("ImageLabel", {
			Name = "Sky",
			BackgroundTransparency = 1,
			Image = image,
			ScaleType = Enum.ScaleType.Crop,
			Size = UDim2.fromScale(1, 1),
			ZIndex = zIndex,
			Parent = art,
		})
	end
	return art
end

-- Building --------------------------------------------------------------------------------

local function buildBack(sp, layout)
	local back = container("VsBack", sp.backGui, 1, "CanvasGroup")
	back.BackgroundTransparency = 0
	back.BackgroundColor3 = T.Backdrop
	sp.backRoot = back
	sp.slides = {}
	if layout.kind == "FFA" then
		local strips = container("Strips", back, 1)
		local n = #layout.strips
		for k, strip in layout.strips do
			local color = Config.TeamColors[strip.team] or T.Raised
			local colors = { color:Lerp(Color3.new(0, 0, 0), 0.75), color:Lerp(Color3.new(0, 0, 0), 0.35) }
			if k == 1 then
				local full = make("Frame", {
					Name = "Strip1",
					BackgroundColor3 = Color3.new(1, 1, 1),
					BorderSizePixel = 0,
					Size = UDim2.fromScale(1, 1),
					ZIndex = 1,
					Parent = strips,
				})
				make("UIGradient", { Color = ColorSequence.new(colors[2], colors[1]), Rotation = 90, Parent = full })
			else
				local edge = (k - 1) / n
				leaningFrame(strips, edge, colors, k * 3)
				seam(strips, edge, k * 3 + 1)
			end
		end
		stripes(strips, 40)
		table.insert(sp.slides, { obj = strips, from = UDim2.fromScale(1, 0) })
		return
	end
	local red = container("RedSide", back, 1)
	local redFill = make("Frame", {
		Name = "Fill",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 1,
		Parent = red,
	})
	make("UIGradient", {
		Color = ColorSequence.new(T.VsRed[2], T.VsRed[1]),
		Rotation = 135,
		Parent = redFill,
	})
	stripes(red, 2)
	local blue = container("BlueSide", back, 3)
	local blueFrame = leaningFrame(blue, 0.5, T.VsBlue, 3)
	stripes(blueFrame, 4)
	seam(blue, 0.5, 6)
	table.insert(sp.slides, { obj = red, from = UDim2.fromScale(-1, 0) })
	table.insert(sp.slides, { obj = blue, from = UDim2.fromScale(1, 0) })
end

-- One animated legend whose feet sit at (x, feet) with body height `body` (canvas heights).
local function legendView(sp, parent, fighter, x, spec, facing, zIndex)
	local height = spec.body / 0.66
	local view = LegendView.new(parent, {
		framing = "Full",
		facing = facing,
		animated = true,
		anchor = Vector2.new(0.5, 1),
		position = UDim2.fromScale(x, spec.feet + 0.04 * height),
		size = UDim2.fromScale(height * 0.8, height),
		zIndex = zIndex,
	})
	local legend = if Legends.isValid(fighter.legend) then fighter.legend else Legends.Default
	view:set({
		legend = legend,
		userId = if type(fighter.userId) == "number" and fighter.userId ~= 0 then fighter.userId else player.UserId,
		ownLook = fighter.ownLook == true and not fighter.isBot,
		flourish = true,
	})
	table.insert(sp.views, view)
	return view
end

-- A name plate: accent bar, player name, legend name, and the rating with its tier badge (ranked).
local function plate(sp, parent, fighter, opts)
	local L = sp.layout
	local P = L.plates
	local holder = make("Frame", {
		Name = "Plate" .. fighter.key,
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(if opts.right then 1 else 0, 0),
		Position = UDim2.fromScale(opts.x, opts.y),
		Size = UDim2.fromScale(opts.w, opts.h),
		ZIndex = 20,
		Parent = parent,
	})
	UIKit.slantFrame({
		parent = holder,
		slant = T.Slant,
		fill = T.Backdrop,
		zIndex = 20,
		name = "Face",
	})
	-- the accent bar along the plate's slanted end: a plain rotated rectangle (it decorates nothing below it)
	local accent = make("Frame", {
		Name = "Accent",
		BackgroundColor3 = opts.accent,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Rotation = T.Slant,
		ZIndex = 22,
		Parent = holder,
	})
	local function placeAccent()
		local size = holder.AbsoluteSize
		local s = size.Y * math.tan(math.rad(T.Slant))
		local x = if opts.right then size.X - s / 2 - Layout.px(4) else s / 2 + Layout.px(4)
		accent.Position = UDim2.new(0, math.floor(x + 0.5), 0.5, 0)
		accent.Size =
			UDim2.new(0, math.max(3, Layout.px(10)), 0, math.floor(size.Y / math.cos(math.rad(T.Slant)) + 0.5))
	end
	holder:GetPropertyChangedSignal("AbsoluteSize"):Connect(placeAccent)
	placeAccent()
	local row = make("Frame", {
		Name = "Row",
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(0.08, 0),
		Size = UDim2.fromScale(0.86, 1),
		ZIndex = 23,
		Parent = holder,
	})
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = if opts.right then Enum.HorizontalAlignment.Right else Enum.HorizontalAlignment.Left,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, Layout.px(16)),
		Parent = row,
	})
	local name = text(string.upper(fighter.name or ""), L.plates.name, {
		Name = "PlayerName",
		Font = Enum.Font.Bangers,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromScale(0, 1),
		LayoutOrder = 1,
		ZIndex = 23,
		Parent = row,
	})
	textStroke(name, 3)
	if L.showLegendName then
		text(Models.legendName(fighter.legend), P.legend, {
			Name = "LegendName",
			Font = T.BlackFont,
			TextColor3 = T.Muted,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromScale(0, 0.6),
			LayoutOrder = 2,
			ZIndex = 23,
			Parent = row,
		})
	end
	if sp.vs.ranked and type(fighter.rating) == "number" then
		local badgeBox = make("Frame", {
			Name = "TierBox",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(0.5, 0.5),
			SizeConstraint = Enum.SizeConstraint.RelativeYY,
			LayoutOrder = 3,
			ZIndex = 23,
			Parent = row,
		})
		UIKit.tierBadge(Ranks.tier(fighter.rating).Name, { parent = badgeBox, zIndex = 23 })
		text(tostring(math.floor(fighter.rating)), P.rating, {
			Name = "Rating",
			Font = T.BlackFont,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromScale(0, 0.6),
			LayoutOrder = 4,
			ZIndex = 23,
			Parent = row,
		})
	end
	return holder
end

local function buildFront(sp, layout)
	local L = sp.layout
	-- legends below everything else (their ViewportFrames fade with ImageTransparency, outside any CanvasGroup)
	local legends = container("VsLegends", sp.frontGui, 1)
	sp.legendsRoot = legends
	local overlay = container("VsOverlay", sp.frontGui, 5, "CanvasGroup")
	sp.overlayRoot = overlay
	sp.views = {}

	if layout.kind == "FFA" then
		local n = #layout.strips
		local legendSide = container("FFALegends", legends, 1)
		local plateSide = container("FFAPlates", overlay, 2)
		for k, strip in layout.strips do
			local centre = (k - 0.5) / n
			legendView(sp, legendSide, strip.fighter, centre, L.ffa, if centre < 0.5 then "Right" else "Left", k)
			local P = L.ffaPlates
			plate(sp, plateSide, strip.fighter, {
				x = centre - P.w / 2,
				y = P.y,
				w = P.w,
				h = P.h,
				accent = Config.TeamColors[strip.team] or T.Raised,
			})
		end
		table.insert(sp.slides, { obj = legendSide, from = UDim2.fromScale(1, 0) })
		table.insert(sp.slides, { obj = plateSide, from = UDim2.fromScale(1, 0) })
	else
		for _, side in { "left", "right" } do
			local fighters = layout[side]
			local right = side == "right"
			local legendSide = container(if right then "RightLegends" else "LeftLegends", legends, 1)
			local plateSide = container(if right then "RightPlates" else "LeftPlates", overlay, 2)
			local xs = L.teamX[side]
			local facing = if right then "Left" else "Right"
			-- back fighter first (drawn behind), then the front one
			for i = #fighters, 1, -1 do
				local fighter = fighters[i]
				local x = if #fighters == 1 then L.teamX.solo[side] else xs[math.min(i, 2)]
				legendView(sp, legendSide, fighter, x, if i == 1 then L.front else L.back, facing, 10 - i)
			end
			local P = L.plates
			for i, fighter in fighters do
				plate(sp, plateSide, fighter, {
					right = right,
					x = if right then 1 - P.x - (i - 1) * 0.008 else P.x - (i - 1) * 0.008 + 0.008,
					y = P.ys[math.min(i, #P.ys)],
					w = P.w,
					h = P.h,
					accent = if right then SIDE_BLUE else SIDE_RED,
				})
			end
			local from = UDim2.fromScale(if right then 1 else -1, 0)
			table.insert(sp.slides, { obj = legendSide, from = from })
			table.insert(sp.slides, { obj = plateSide, from = from })
		end
	end

	-- the mode tag, top centre
	local tagHolder = make("Frame", {
		Name = "ModeTag",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, L.tag.y),
		Size = UDim2.fromScale(0.5, L.tag.h),
		ZIndex = 30,
		Parent = overlay,
	})
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		Parent = tagHolder,
	})
	UIKit.tag(
		string.upper(sp.vs.label or ""),
		{ parent = tagHolder, fill = T.Backdrop, size = L.tag.size, zIndex = 30 }
	)
	Layout.clearTop(tagHolder, tagHolder.Position)

	-- VS: a pop-in holder (the labels' own UIScale is Layout's TextFit), a black drop copy and the gradient letters
	local vsHolder = make("Frame", {
		Name = "VS",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, L.vs.y),
		Size = UDim2.fromScale(L.vs.w, L.vs.h),
		ZIndex = 40,
		Parent = overlay,
	}, { make("UIScale", { Scale = 1 }) })
	local drop = text("VS", L.vs.size, {
		Name = "Drop",
		Font = Enum.Font.LuckiestGuy,
		TextColor3 = T.Outline,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.new(0, 0, 0, Layout.px(14)),
		ZIndex = 40,
		Parent = vsHolder,
	})
	textStroke(drop, L.vs.stroke)
	local letters = text("VS", L.vs.size, {
		Name = "Letters",
		Font = Enum.Font.LuckiestGuy,
		TextColor3 = Color3.new(1, 1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
		ZIndex = 41,
		Parent = vsHolder,
	})
	local g = T.LogoGradient
	make("UIGradient", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, g[1]),
			ColorSequenceKeypoint.new(0.5, g[2]),
			ColorSequenceKeypoint.new(1, g[3]),
		}),
		Rotation = 90,
		Parent = letters,
	})
	textStroke(letters, L.vs.stroke)
	sp.vsScale = vsHolder:FindFirstChildOfClass("UIScale")

	-- the map card, bottom centre
	local M = L.map
	local card = make("Frame", {
		Name = "MapCard",
		BackgroundColor3 = T.Backdrop,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, M.y),
		Size = UDim2.fromScale(M.w, M.h),
		ZIndex = 30,
		Parent = overlay,
	})
	local border = make("UIStroke", {
		Color = T.Outline,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		LineJoinMode = Enum.LineJoinMode.Miter,
		Parent = card,
	})
	Layout.bindStroke(border, 4)
	mapArt(card, sp.vs.mapId, 30)
	local shade = make("Frame", {
		Name = "Shade",
		BackgroundColor3 = Color3.new(0, 0, 0),
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromScale(1, 0.6),
		ZIndex = 31,
		Parent = card,
	})
	make("UIGradient", { Rotation = 90, Transparency = NumberSequence.new(1, 0.25), Parent = shade })
	local mapInfo = Maps.get(sp.vs.mapId)
	text("MAP", M.tag, {
		Name = "MapTag",
		Font = T.BlackFont,
		TextColor3 = T.Gold,
		Position = UDim2.fromScale(0.05, 0.5),
		Size = UDim2.fromScale(0.9, 0.16),
		ZIndex = 32,
		Parent = card,
	})
	local mapName = text(string.upper(mapInfo and mapInfo.Name or "?"), M.size, {
		Name = "MapName",
		Font = Enum.Font.Bangers,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromScale(0.05, 0.64),
		Size = UDim2.fromScale(0.9, 0.32),
		ZIndex = 32,
		Parent = card,
	})
	textStroke(mapName, 3)
	sp.loading = text("LOADING...", L.loading, {
		Name = "Loading",
		Font = T.BlackFont,
		TextColor3 = T.Muted,
		TextXAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, M.y + M.h + 0.005),
		Size = UDim2.fromScale(0.3, 0.035),
		Visible = false,
		ZIndex = 32,
		Parent = overlay,
	})
end

-- Halves slide in, then VS pops.
local function entrance(sp)
	local slide = TweenInfo.new(SLIDE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	for _, entry in sp.slides do
		entry.obj.Position = entry.from
		TweenService:Create(entry.obj, slide, { Position = UDim2.fromScale(0, 0) }):Play()
	end
	if sp.vsScale then
		sp.vsScale.Scale = 1.6
		local pop = TweenInfo.new(POP_SECONDS, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		task.delay(SLIDE_SECONDS * 0.6, function()
			if splash == sp and sp.vsScale.Parent then
				TweenService:Create(sp.vsScale, pop, { Scale = 1 }):Play()
			end
		end)
	end
end

-- Session ------------------------------------------------------------------------------------

local function destroy(sp)
	for _, view in sp.views or {} do
		view:destroy()
	end
	for _, root in { sp.backRoot, sp.legendsRoot, sp.overlayRoot } do
		if root then
			root:Destroy()
		end
	end
	sp.views = {}
end

local function teardown()
	local sp = splash
	if not sp then
		return
	end
	splash = nil
	destroy(sp)
end

-- The match started: fade the splash out over the arena.
local function fadeOut()
	local sp = splash
	if not sp then
		return
	end
	splash = nil
	local info = TweenInfo.new(FADE_SECONDS)
	for _, root in { sp.backRoot, sp.overlayRoot } do
		if root then
			TweenService:Create(root, info, { GroupTransparency = 1 }):Play()
		end
	end
	for _, view in sp.views do
		if view.frame and view.frame.Parent then
			TweenService:Create(view.frame, info, { ImageTransparency = 1 }):Play()
		end
	end
	task.delay(FADE_SECONDS + 0.05, function()
		destroy(sp)
	end)
end

local function build(vs)
	local sp = {
		id = vs.id,
		vs = vs,
		openedAt = os.clock(),
		views = {},
		slides = {},
	}
	sp.layout = if Layout.mode() == "Phone" then PHONE else WIDE
	sp.backGui, sp.frontGui = selectGuis()
	local layout = Models.vsLayout(vs, player.UserId)
	buildBack(sp, layout)
	buildFront(sp, layout)
	entrance(sp)
	return sp
end

local function onVs(data, previousSelect)
	if not (previousSelect and previousSelect.id == data.id) then
		-- not the select you're in: it was cancelled first (a match that failed as it was created sends
		-- "Cancel" before "Vs"), or it never reached you
		return
	end
	local decision = Models.phaseAfter({ type = "Vs", id = data.id }, { phase = ClientState.phase })
	if not decision then
		return
	end
	teardown()
	local ok, result = pcall(build, data)
	if ok then
		splash = result
	else
		warn("[VsSplash] build failed:", result)
		-- still a splash (for the cancel / watchdog rules), just an empty one
		splash = { id = data.id, vs = data, openedAt = os.clock(), views = {} }
	end
	Sound.play("MatchFound", 0.6, 1.2)
	ClientState.setPhase(decision.phase)
end

local function onCancel(data, previousVs)
	local sp = splash
	if not sp then
		return
	end
	local id = sp.id or (previousVs and previousVs.id)
	if data.id ~= id then
		return
	end
	local decision = Models.phaseAfter({
		type = "Cancel",
		id = data.id,
		reason = data.reason,
		requeued = data.requeued == true,
	}, { phase = ClientState.phase, vsId = id })
	teardown()
	if decision then
		ClientState.toast(decision.toast, decision.toastKind)
		ClientState.setPhase(decision.phase)
	end
end

-- Every frame while open: LOADING... and the watchdog.
local function step()
	local sp = splash
	if not sp then
		return
	end
	local now = os.clock()
	local startsIn = if type(sp.vs.startsIn) == "number" then sp.vs.startsIn else Config.Select.VsSeconds
	if sp.loading and not sp.loading.Visible and now - sp.openedAt >= startsIn + LOADING_AFTER then
		sp.loading.Visible = true
	end
	if Models.watchdogDue(sp.openedAt, startsIn, now) then
		local decision = Models.phaseAfter({ type = "Watchdog" }, { phase = ClientState.phase })
		teardown()
		if decision then
			ClientState.toast(decision.toast, decision.toastKind)
			ClientState.setPhase(decision.phase)
		end
	end
end

function VsSplash.init()
	ClientState.SelectEvent:Connect(function(kind, data, previousSelect, previousVs)
		if type(data) ~= "table" then
			return
		end
		if kind == "Vs" then
			onVs(data, previousSelect)
		elseif kind == "Cancel" then
			onCancel(data, previousVs)
		end
	end)
	ClientState.PhaseChanged:Connect(function(phase)
		if phase == "Vs" or not splash then
			return
		end
		if phase == "Match" then
			fadeOut()
		else
			teardown()
		end
	end)
	RunService.Heartbeat:Connect(step)
end

return VsSplash
