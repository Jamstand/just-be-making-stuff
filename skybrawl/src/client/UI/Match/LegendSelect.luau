--[[
    Legend select + map vote (menus design 5.9, mockup d), shown in phase
    "Select" between "match found" and the VS splash.

    SelectEvent "Begin" builds the screen once (grid tiles, info block, map
    cards, slots), plays MatchFound, sets the phase to "Select", flashes
    "MATCH FOUND" over it (the screen is usable underneath) and pushes an
    overlay Focus layer whose default focus is your current legend's tile.
    "Update" changes everything in place (nothing focusable is destroyed,
    so focus stays). A "Cancel" for this session toasts its reason and
    returns to the menu; "Vs" (VsSplash takes over) or any phase change
    away from "Select" tears the screen down.

    Input: moving across the grid hovers (the preview and info follow at
    once; Hover goes to the server at most every Config.Select.HoverInterval,
    always followed by the latest value). Confirm (or a click) locks the
    focused tile: the tile is tinted at once, LOCKED IN and the LockIn
    sound wait for the server's Update, and a Lock without one within 0.5 s
    is sent once more. Back unlocks, X locks Random, Y toggles your avatar's
    look (also saved as the FightAsAvatar setting), L1 / R1 move your map
    vote; a map card votes on Confirm or a click. Touch: tap a tile to
    hover it, tap it again (or the LOCK IN hint) to lock.

    ScreenGuis SkybrawlSelectBack (19, full bleed: the tinted backdrop and
    the faint huge name) and SkybrawlSelect (20, safe area: everything
    else) are shared with VsSplash; each module only adds and removes its
    own root frames, so the guis stay enabled.

    The slot row's widgets belong to places, not slot keys (a leaver's slot
    a bot takes over is redrawn in place); a bot's slot has a BOT tag.

    Phone: no big preview, a compact info column on the left, grid and maps
    on the right, slots along the bottom; all of it below the Roblox top
    bar (the grid's holder also goes through Layout.clearTop).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Legends = require(Shared.Legends)
local Maps = require(Shared.Maps)
local Net = require(Shared.Net)

local Client = script.Parent.Parent.Parent
local ClientState = require(Client:WaitForChild("ClientState"))
local Controllers = Client:WaitForChild("Controllers")
local Settings = require(Controllers:WaitForChild("Settings"))
local Sound = require(Controllers:WaitForChild("Sound"))
local SkyBackdrop = require(Controllers:WaitForChild("SkyBackdrop"))
local UI = script.Parent.Parent
local UIKit = require(UI:WaitForChild("UIKit"))
local Focus = require(UI:WaitForChild("Focus"))
local Layout = require(UI:WaitForChild("Layout"))
local LegendView = require(UI:WaitForChild("LegendView"))
local Models = require(script.Parent:WaitForChild("Models"))

local LegendSelect = {}

local T = UIKit.Theme
local make = UIKit.make

local player = Players.LocalPlayer
local selectAction = Net.get("SelectAction")

local BACK_TOP = Color3.fromRGB(30, 17, 44)
local BACK_BOTTOM = Color3.fromRGB(11, 8, 17)
local TILE_SLANT = T.CardSlant -- the mockup's tiles lean like its buttons ("/")
local SLOT_SLANT = T.SlotSlant
local STRIP = 0.22 -- the tile's name strip, as a fraction of its height
local LOCK_RESEND = 0.5 -- a Lock without a confirming Update is sent once more after this
local LOCK_GIVE_UP = 1.5 -- then the provisional tint goes away
local OVERRIDE_TTL = 1 -- a Look / Vote the server never showed (a dropped action) stops overriding its value after this
local FLASH_SECONDS = 0.6
local TICK_FROM = 5
local NAME_CHARS = 7 -- the info block's name shrinks past this many characters (MY AVATAR), its title past TITLE_CHARS
local TITLE_CHARS = 14

--[[
    Geometry (fractions of the safe-area canvas; text in design px, which
    Layout.px already enlarges 1.6x on phones). Wide follows mockup d
    (1920x1080); Phone is its own arrangement, everything below the Roblox
    top bar's height (about 0.17 of a phone's safe area).
]]
local WIDE = {
	preview = { x = 0.008, bottom = 1.0, height = 0.91 },
	title = { x = 0.033, y = 0.06, w = 0.42, h = 0.075, size = 80 },
	tags = { y = 0.128, h = 0.032, size = 18 },
	ring = { x = 0.5, y = 0.083, d = 0.13, size = 72 },
	caption = { y = 0.152, h = 0.03, size = 20 },
	info = {
		x = 0.344,
		w = 0.21,
		name = { y = 0.215, h = 0.105, size = 120 },
		title = { y = 0.322, h = 0.03, size = 24 },
		stats = { y = 0.364, step = 0.028, h = 0.02, size = 16 },
		weaponsLabel = { y = 0.484, h = 0.022, size = 15 },
		weapons = { y = 0.51, h = 0.036, size = 20 },
		ultLabel = { y = 0.562, h = 0.022, size = 15 },
		ult = { y = 0.584, h = 0.046, size = 44 },
		look = { y = 0.632, h = 0.034, size = 17 },
	},
	grid = { x = 0.575, y = 0.19, w = 0.091, h = 0.152, dx = 0.099, dy = 0.171, rowShift = -0.009, size = 30 },
	maps = {
		x = 0.578,
		y = 0.548,
		headerH = 0.04,
		header = 40,
		cardY = 0.593,
		w = 0.128,
		h = 0.2,
		dx = 0.1395,
		noteX = 0.985,
		size = 34,
		votes = 15,
		yourVote = 14,
		noteSize = 17,
	},
	slots = { y = 0.815, h = 0.122, xs = { 0.023, 0.252, 0.527, 0.756 }, w = 0.221, name = 22, legend = 40 },
	vs = { size = 70 },
	hints = { y = 0.972 },
	flash = 120,
}

local PHONE = {
	preview = nil,
	title = { x = 0.0, y = 0.17, w = 0.42, h = 0.075, size = 40 },
	tags = { y = 0.25, h = 0.05, size = 18 },
	ring = { x = 0.37, y = 0.1, d = 0.16, size = 40 },
	caption = nil,
	info = {
		x = 0.0,
		w = 0.42,
		name = { y = 0.31, h = 0.1, size = 56 },
		title = { y = 0.41, h = 0.04, size = 20 },
		stats = nil,
		weaponsLabel = { y = 0.465, h = 0.035, size = 16 },
		weapons = { y = 0.5, h = 0.06, size = 18 },
		ultLabel = { y = 0.57, h = 0.035, size = 16 },
		ult = { y = 0.605, h = 0.06, size = 32 },
		look = { y = 0.675, h = 0.065, size = 18 },
	},
	grid = { x = 0.47, y = 0.175, w = 0.112, h = 0.165, dx = 0.126, dy = 0.18, rowShift = -0.006, size = 20 },
	maps = {
		x = 0.47,
		y = 0.535,
		headerH = 0.055,
		header = 26,
		cardY = 0.595,
		w = 0.16,
		h = 0.17,
		dx = 0.172,
		noteX = 0.99,
		size = 20,
		votes = 16,
		yourVote = 15,
	},
	slots = { y = 0.785, h = 0.13, xs = { 0.0, 0.246, 0.52, 0.766 }, w = 0.234, name = 20, legend = 28 },
	vs = { size = 40 },
	hints = { y = 0.965 },
	flash = 56,
}

local session = nil -- the open screen (one select session at a time)

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

local function box(name, parent, x, y, w, h, zIndex)
	return make("Frame", {
		Name = name,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromScale(x, y),
		Size = UDim2.fromScale(w, h),
		ZIndex = zIndex or 1,
		Parent = parent,
	})
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

-- The two shared ScreenGuis (made on first use; VsSplash finds the same ones).
local function selectGuis()
	local playerGui = player:WaitForChild("PlayerGui")
	local back = playerGui:FindFirstChild("SkybrawlSelectBack") or Layout.screenGui("SkybrawlSelectBack", 19, "Full")
	local front = playerGui:FindFirstChild("SkybrawlSelect") or Layout.screenGui("SkybrawlSelect", 20, "Safe")
	return back, front
end

--[[
    A horizontal band of a slanted ("/") frame, from t0 to t1 of its height
    (fractions from the top), as its own slant frame whose edges stay on the
    parent's slanted edges: it starts s * (1 - t1) in and is s * (1 - (t1 -
    t0)) narrower, s being the parent's slant offset. Re-placed whenever the
    host resizes.
]]
local function slantBand(host, t0, t1, fill, deg, zIndex)
	local band = UIKit.slantFrame({
		parent = host,
		slant = deg,
		fill = fill,
		zIndex = zIndex,
		name = "Band",
	})
	local function place()
		local size = host.AbsoluteSize
		if size.Y <= 0 then
			return
		end
		local s = size.Y * math.tan(math.rad(deg))
		band.Position = UDim2.new(0, math.floor(s * (1 - t1) + 0.5), t0, 0)
		band.Size = UDim2.new(1, -math.floor(s * (1 - (t1 - t0)) + 0.5), t1 - t0, 0)
	end
	host:GetPropertyChangedSignal("AbsoluteSize"):Connect(place)
	place()
	return band
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

-- A dice drawn from frames (the Random tile), filling `parent` as a centred square.
local function dice(parent, zIndex)
	local face = make("Frame", {
		Name = "Dice",
		BackgroundColor3 = T.Raised,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.42, 0.42),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		ZIndex = zIndex,
		Parent = parent,
	})
	make("UICorner", { CornerRadius = UDim.new(0.18, 0), Parent = face })
	local stroke = make("UIStroke", { Color = T.Muted, Parent = face })
	Layout.bindStroke(stroke, 4)
	for _, p in { { 0.25, 0.25 }, { 0.75, 0.25 }, { 0.5, 0.5 }, { 0.25, 0.75 }, { 0.75, 0.75 } } do
		local dot = make("Frame", {
			BackgroundColor3 = T.Muted,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(p[1], p[2]),
			Size = UDim2.fromScale(0.17, 0.17),
			ZIndex = zIndex + 1,
			Parent = face,
		})
		make("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = dot })
	end
	return face
end

local function send(kind, data)
	selectAction:FireServer(kind, data)
end

-- State ---------------------------------------------------------------------------------

local function mySlot(s)
	return Models.youSlot(s.state)
end

local function myLocked(s)
	local slot = mySlot(s)
	return slot ~= nil and slot.locked == true
end

-- Your avatar-look choice: a toggle just sent wins until the server shows it.
local function lookOn(s)
	if s.lookOverride ~= nil then
		return s.lookOverride
	end
	local slot = mySlot(s)
	if slot and slot.ownLook ~= nil then
		return slot.ownLook == true
	end
	return Settings.get("FightAsAvatar") == true
end

-- The pick the screen stays on: a Lock just sent, else your server-confirmed lock (nil while free to hover).
local function lockedPick(s)
	if s.provisional then
		return s.provisional
	end
	local slot = mySlot(s)
	if slot and slot.locked and not s.unlockPending then
		return if slot.random then "Random" else slot.legend
	end
	return nil
end

-- Building ------------------------------------------------------------------------------

local function buildBackdrop(s)
	local back = make("Frame", {
		Name = "LegendSelectBack",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = s.backGui,
	})
	s.backGradient = make("UIGradient", { Rotation = 60, Parent = back })
	-- faint diagonal stripes
	local stripes = make("Frame", {
		Name = "Stripes",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0.97,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
		Parent = back,
	})
	local keys = {}
	for i = 0, 18 do
		local t = i / 18
		table.insert(keys, NumberSequenceKeypoint.new(t, if i % 2 == 0 then 0 else 1))
	end
	make("UIGradient", { Rotation = -30, Transparency = NumberSequence.new(keys), Parent = stripes })
	s.bigName = text("", 600, {
		Name = "BigName",
		Font = Enum.Font.Bangers,
		TextTransparency = 0.92,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromScale(0.01, 0.12),
		Size = UDim2.fromScale(0.6, 0.62),
		ZIndex = 3,
		Parent = back,
	})
	-- a dark fade along the bottom, under the slots
	local fade = make("Frame", {
		Name = "Fade",
		BackgroundColor3 = Color3.new(0, 0, 0),
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromScale(1, 0.3),
		ZIndex = 4,
		Parent = back,
	})
	make("UIGradient", {
		Rotation = 90,
		Transparency = NumberSequence.new(1, 0.35),
		Parent = fade,
	})
	s.backRoot = back
end

local function buildHeader(s, L)
	local header = box("Header", s.root, L.title.x, L.title.y, L.title.w, L.tags.y + L.tags.h - L.title.y, 10)
	local title = text("CHOOSE YOUR LEGEND", L.title.size, {
		Name = "Title",
		Font = Enum.Font.Bangers,
		Size = UDim2.fromScale(1, L.title.h / (L.tags.y + L.tags.h - L.title.y)),
		ZIndex = 10,
		Parent = header,
	})
	textStroke(title, 4)
	local tags = make("Frame", {
		Name = "Tags",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromScale(1, L.tags.h / (L.tags.y + L.tags.h - L.title.y)),
		ZIndex = 10,
		Parent = header,
	})
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, Layout.px(10)),
		Parent = tags,
	})
	local st = s.state
	UIKit.tag(string.upper(st.label or ""), {
		parent = tags,
		fill = T.Gold,
		textColor = T.GoldDark,
		size = L.tags.size,
		layoutOrder = 1,
		zIndex = 10,
	})
	UIKit.tag(Models.rulesText(st.rules), {
		parent = tags,
		fill = T.Raised,
		textColor = T.Muted,
		size = L.tags.size,
		layoutOrder = 2,
		zIndex = 10,
	})
	Layout.clearTop(header, header.Position)

	local ring, setRing = UIKit.ring({
		parent = s.root,
		anchor = Vector2.new(0.5, 0.5),
		position = UDim2.fromScale(L.ring.x, L.ring.y),
		size = UDim2.fromScale(L.ring.d, L.ring.d),
		fill = T.Red,
		textSize = L.ring.size,
		zIndex = 10,
	})
	s.ring, s.setRing = ring, setRing
	if L.caption then
		s.caption = text("", L.caption.size, {
			Name = "Caption",
			Font = T.BlackFont,
			TextColor3 = T.Muted,
			TextXAlignment = Enum.TextXAlignment.Center,
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(0.5, L.caption.y),
			Size = UDim2.fromScale(0.4, L.caption.h),
			ZIndex = 10,
			Parent = s.root,
		})
	end
end

local function buildInfo(s, L)
	local I = L.info
	local function line(name, spec, font, color)
		return text("", spec.size, {
			Name = name,
			Font = font,
			TextColor3 = color or T.Text,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromScale(I.x, spec.y),
			Size = UDim2.fromScale(I.w, spec.h),
			ZIndex = 6,
			Parent = s.root,
		})
	end
	s.infoName = line("InfoName", I.name, Enum.Font.Bangers)
	textStroke(s.infoName, 5)
	s.infoTitle = line("InfoTitle", I.title, T.BlackFont)
	s.statRows = {}
	if I.stats then
		for i, stat in Legends.StatNames do
			local y = I.stats.y + (i - 1) * I.stats.step
			text(string.upper(stat), I.stats.size, {
				Name = "Stat" .. stat,
				Font = T.BlackFont,
				TextColor3 = T.Muted,
				Position = UDim2.fromScale(I.x, y),
				Size = UDim2.fromScale(0.06, I.stats.h),
				ZIndex = 6,
				Parent = s.root,
			})
			local pips, setPips = UIKit.pips(9, 0, {
				parent = s.root,
				position = UDim2.fromScale(I.x + 0.062, y + I.stats.h * 0.25),
				size = UDim2.fromScale(0.124, I.stats.h * 0.5),
				zIndex = 6,
			})
			s.statRows[i] = { pips = pips, set = setPips }
		end
	end
	line("WeaponsLabel", I.weaponsLabel, T.BlackFont, T.Muted).Text = "WEAPONS"
	s.weaponsRow = make("Frame", {
		Name = "Weapons",
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(I.x, I.weapons.y),
		Size = UDim2.fromScale(I.w, I.weapons.h),
		ZIndex = 6,
		Parent = s.root,
	})
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, Layout.px(12)),
		Parent = s.weaponsRow,
	})
	line("UltLabel", I.ultLabel, T.BlackFont, T.Muted).Text = "ULTIMATE"
	s.infoUlt = line("InfoUlt", I.ult, Enum.Font.Bangers)
	textStroke(s.infoUlt, 3)

	-- AVATAR LOOK toggle (Y; clicks and taps too)
	local look = make("TextButton", {
		Name = "AvatarLook",
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Text = "",
		Position = UDim2.fromScale(I.x, I.look.y),
		Size = UDim2.fromScale(I.w, I.look.h),
		ZIndex = 6,
		Parent = s.root,
	})
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, Layout.px(10)),
		Parent = look,
	})
	local glyphBox = make("Frame", {
		Name = "GlyphBox",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(0.9, 0.9),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		LayoutOrder = 1,
		ZIndex = 6,
		Parent = look,
	})
	UIKit.glyph("Y", { parent = glyphBox, zIndex = 7 })
	text("AVATAR LOOK", I.look.size, {
		Name = "Label",
		Font = T.BlackFont,
		TextColor3 = T.Muted,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromScale(0, 1),
		LayoutOrder = 2,
		ZIndex = 6,
		Parent = look,
	})
	s.lookValue = make("Frame", {
		Name = "Value",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(0, 0.8),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 3,
		ZIndex = 6,
		Parent = look,
	})
	look.Activated:Connect(function()
		if session == s then
			s.toggleLook()
		end
	end)
end

local function setTileLook(tile)
	local s = tile.session
	local slot = mySlot(s)
	local lockedHere = slot ~= nil and slot.locked and (if slot.random then "Random" else slot.legend) == tile.legend
	local provisional = s.provisional == tile.legend and not lockedHere
	-- the focused tile, the one on screen (touch shows no focus) and your lock are outlined
	local hot = tile.focused or s.hovered == tile.legend or lockedHere or provisional
	tile.glow.Visible = hot
	UIKit.setSlantFill(tile.glow, if lockedHere or provisional then T.Red else Color3.new(1, 1, 1))
	UIKit.setSlantFill(
		tile.strip,
		if lockedHere then { T.RedLight, T.RedDark } elseif provisional then T.RedDark else T.ButtonBottom
	)
end

--[[
    The frame holding the 4 x 2 tiles (the second row starts rowShift
    further left), kept below the Roblox top bar: the tiles are buttons, and
    nothing interactive may sit in its boxes (on phones the grid's top row
    is near the top edge).
]]
local function buildGrid(s, L)
	local G = L.grid
	local x0 = G.x + math.min(0, G.rowShift)
	local grid = {
		x0 = x0,
		y0 = G.y,
		w = 3 * G.dx + G.w + math.abs(G.rowShift),
		h = G.dy + G.h,
	}
	grid.holder = box("Grid", s.root, grid.x0, grid.y0, grid.w, grid.h, 8)
	Layout.clearTop(grid.holder, grid.holder.Position)
	return grid
end

local function buildTile(s, L, grid, legendId, index)
	local G = L.grid
	local col = (index - 1) % 4
	local row = (index - 1) // 4
	local x = G.x + col * G.dx + row * G.rowShift
	local y = G.y + row * G.dy
	local button = make("TextButton", {
		Name = "Tile" .. legendId,
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Text = "",
		Position = UDim2.fromScale((x - grid.x0) / grid.w, (y - grid.y0) / grid.h),
		Size = UDim2.fromScale(G.w / grid.w, G.h / grid.h),
		ZIndex = 8,
		Parent = grid.holder,
	})
	-- focus / lock highlight: a slightly bigger slanted shape behind the tile
	local glow = UIKit.slantFrame({
		parent = button,
		slant = TILE_SLANT,
		fill = T.Red,
		anchor = Vector2.new(0.5, 0.5),
		position = UDim2.fromScale(0.5, 0.5),
		size = UDim2.new(1, Layout.px(14), 1, Layout.px(12)),
		zIndex = 8,
		name = "Glow",
	})
	glow.Visible = false
	local color = if legendId == "Random" then T.Raised else Legends.get(legendId).Color
	local face = UIKit.slantFrame({
		parent = button,
		slant = TILE_SLANT,
		gradient = { color:Lerp(Color3.new(1, 1, 1), 0.12), color:Lerp(Color3.new(0, 0, 0), 0.35) },
		outline = 3,
		shadow = true,
		zIndex = 9,
		name = "Face",
	})
	local content = face:FindFirstChild("Content") or face
	local portrait = nil
	if legendId == "Random" then
		dice(content, 12)
	else
		portrait = LegendView.portrait(content, {
			legend = legendId,
			userId = player.UserId,
			ownLook = false,
		}, {
			size = UDim2.fromScale(1, 1 - STRIP),
			zIndex = 11,
		})
		portrait.frame.BackgroundTransparency = 1
	end
	local strip = slantBand(button, 1 - STRIP, 1, T.ButtonBottom, TILE_SLANT, 14)
	local name = text(Models.legendName(legendId), G.size, {
		Name = "Name",
		Font = Enum.Font.Bangers,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromScale(0, 1 - STRIP),
		Size = UDim2.fromScale(1, STRIP),
		ZIndex = 20,
		Parent = button,
	})
	textStroke(name, 2)
	-- P<n> tags (teammates' hovers and picks)
	local tags = make("Frame", {
		Name = "Tags",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(0.92, 0.06),
		Size = UDim2.fromScale(0.6, 0.15),
		ZIndex = 21,
		Parent = button,
	})
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, Layout.px(4)),
		Parent = tags,
	})
	local tile = {
		session = s,
		legend = legendId,
		button = button,
		glow = glow,
		strip = strip,
		name = name,
		portrait = portrait,
		tags = tags,
		tagText = "",
		focused = false,
	}
	Focus.register(button, {
		key = "Tile" .. legendId,
		onFocus = function(on)
			tile.focused = on
			setTileLook(tile)
		end,
	})
	UIKit.onActivate(button, function()
		if session ~= s then
			return
		end
		if Focus.mode() == "Touch" then
			-- tap = hover, a second tap on the same tile = lock
			if s.tapped == legendId then
				s.lock(legendId)
			else
				s.tapped = legendId
				s.hover(legendId)
			end
			return
		end
		s.lock(legendId)
	end)
	setTileLook(tile)
	return tile
end

local function buildMaps(s, L)
	local M = L.maps
	local headerBox = box("MapHeader", s.root, M.x, M.y, 0.2, M.headerH, 8)
	UIKit.header("VOTE MAP", { parent = headerBox, zIndex = 8, size = M.header })
	if M.noteSize then
		text("Most votes wins · ties are random", M.noteSize, {
			Name = "VoteNote",
			Font = T.BoldFont,
			TextColor3 = T.Muted,
			TextXAlignment = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(M.noteX, M.y + 0.006),
			Size = UDim2.fromScale(0.2, 0.03),
			ZIndex = 8,
			Parent = s.root,
		})
	end
	s.mapCards = {}
	local cards = Models.mapCards(s.state)
	local humans = math.max(1, Models.humanCount(s.state))
	for i, card in cards do
		local fixed = card.fixed == true
		local width = if fixed then M.w * 1.6 else M.w
		local button = make("TextButton", {
			Name = "Map" .. i,
			BackgroundColor3 = T.Panel,
			BorderSizePixel = 0,
			AutoButtonColor = false,
			Text = "",
			Position = UDim2.fromScale(M.x + (i - 1) * M.dx, M.cardY),
			Size = UDim2.fromScale(width, M.h),
			ZIndex = 8,
			Parent = s.root,
		})
		local border = make("UIStroke", {
			Color = T.Stroke,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			LineJoinMode = Enum.LineJoinMode.Miter,
			Parent = button,
		})
		Layout.bindStroke(border, 3)
		local artBox = box("ArtBox", button, 0, 0, 1, 0.7, 9)
		if card.id then
			mapArt(artBox, card.id, 9)
		end
		local nameLabel = text(if fixed then "MAP: " .. string.upper(card.name) else string.upper(card.name), M.size, {
			Name = "MapName",
			Font = Enum.Font.Bangers,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromScale(0.06, 0.66),
			Size = UDim2.fromScale(0.9, 0.18),
			ZIndex = 11,
			Parent = button,
		})
		textStroke(nameLabel, 3)
		local entry = { id = card.id, button = button, border = border, fixed = fixed, focused = false }
		if not fixed then
			local pips, setPips = UIKit.pips(humans, 0, {
				parent = button,
				position = UDim2.fromScale(0.06, 0.88),
				size = UDim2.fromScale(0.38, 0.035),
				fill = T.Gold,
				zIndex = 11,
			})
			entry.pips, entry.setPips = pips, setPips
			entry.votes = text("", M.votes, {
				Name = "Votes",
				Font = T.BlackFont,
				TextXAlignment = Enum.TextXAlignment.Right,
				Position = UDim2.fromScale(0.5, 0.84),
				Size = UDim2.fromScale(0.45, 0.12),
				ZIndex = 11,
				Parent = button,
			})
			entry.yours = make("Frame", {
				Name = "YourVote",
				BackgroundTransparency = 1,
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.fromScale(0.96, 0.05),
				Size = UDim2.fromScale(0.9, 0.13),
				ZIndex = 12,
				Visible = false,
				Parent = button,
			})
			make("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				HorizontalAlignment = Enum.HorizontalAlignment.Right,
				Parent = entry.yours,
			})
			UIKit.tag("✓ YOUR VOTE", {
				parent = entry.yours,
				size = M.yourVote,
				fill = T.Gold,
				textColor = T.GoldDark,
				zIndex = 12,
			})
			Focus.register(button, {
				key = "Map" .. i,
				onFocus = function(on)
					entry.focused = on
					s.renderMaps()
				end,
			})
			UIKit.onActivate(button, function()
				if session == s then
					s.vote(card.id)
				end
			end)
		end
		s.mapCards[i] = entry
	end
end

local function buildSlot(s, L, slot, x, zIndex, index)
	local S = L.slots
	local holder = make("Frame", {
		Name = "Slot" .. index,
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(x, S.y),
		Size = UDim2.fromScale(S.w, S.h),
		ZIndex = zIndex,
		Parent = s.root,
	})
	UIKit.slantFrame({
		parent = holder,
		slant = SLOT_SLANT,
		gradient = { T.ButtonTop, T.Panel },
		outline = 3,
		shadow = true,
		zIndex = zIndex,
		name = "Face",
	})
	local bar = slantBand(holder, 0, 0.06, Config.TeamColors[slot.team] or T.Stroke, SLOT_SLANT, zIndex + 6)
	local inner = make("Frame", {
		Name = "Inner",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = zIndex + 6,
		Parent = holder,
	})
	-- the inner rectangle of the slot (inside its slanted edges), filled again on resize
	local function placeInner()
		local size = holder.AbsoluteSize
		local s0 = math.floor(size.Y * math.tan(math.rad(SLOT_SLANT)) + 0.5)
		inner.Position = UDim2.new(0, s0, 0.06, 0)
		inner.Size = UDim2.new(1, -2 * s0, 0.94, 0)
	end
	holder:GetPropertyChangedSignal("AbsoluteSize"):Connect(placeInner)
	placeInner()
	local portraitBox = make("Frame", {
		Name = "PortraitBox",
		BackgroundColor3 = T.Raised,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Size = UDim2.fromScale(1, 1),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		ZIndex = zIndex + 6,
		Parent = inner,
	})
	local hidden = text("?", 90, {
		Name = "Hidden",
		Font = Enum.Font.Bangers,
		TextColor3 = T.Dim,
		TextXAlignment = Enum.TextXAlignment.Center,
		ZIndex = zIndex + 8,
		Visible = false,
		Parent = portraitBox,
	})
	local portrait = LegendView.portrait(portraitBox, {
		legend = if slot.legend and slot.legend ~= "Random" then slot.legend else "Kestrel",
		userId = slot.userId,
		ownLook = slot.ownLook == true,
	}, { zIndex = zIndex + 7 })
	local textArea = make("Frame", {
		Name = "Text",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = zIndex + 6,
		Parent = inner,
	})
	local function placeText()
		local h = inner.AbsoluteSize.Y
		textArea.Position = UDim2.new(0, h + Layout.px(14), 0, 0)
		textArea.Size = UDim2.new(1, -(h + Layout.px(18)), 1, 0)
	end
	inner:GetPropertyChangedSignal("AbsoluteSize"):Connect(placeText)
	placeText()
	local name = text("", S.name, {
		Name = "PlayerName",
		Font = T.BlackFont,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromScale(0, 0.08),
		Size = UDim2.fromScale(1, 0.26),
		ZIndex = zIndex + 7,
		Parent = textArea,
	})
	local legend = text("", S.legend, {
		Name = "LegendName",
		Font = Enum.Font.Bangers,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromScale(0, 0.32),
		Size = UDim2.fromScale(1, 0.34),
		ZIndex = zIndex + 7,
		Parent = textArea,
	})
	-- the state tag (SELECTING... / LOCKED IN / LEFT), after a BOT tag for bots
	local tagBox = make("Frame", {
		Name = "State",
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(0, 0.7),
		Size = UDim2.fromScale(1, 0.22),
		ZIndex = zIndex + 7,
		Parent = textArea,
	})
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, Layout.px(6)),
		Parent = tagBox,
	})
	return {
		holder = holder,
		bar = bar,
		portrait = portrait,
		hidden = hidden,
		name = name,
		legend = legend,
		tagBox = tagBox,
		tagKey = nil,
		zIndex = zIndex,
		portraitSpec = nil,
	}
end

--[[
    The slot row. Widgets are kept per place (Models.slotPlaces), not per
    slot key: a leaver whose slot a bot takes over (new key, same place) is
    redrawn in place by renderSlots; a different arrangement rebuilds the
    row (slots aren't focusable, so focus never moves).
]]
local function buildSlots(s, L)
	s.slots = {}
	local placement = Models.slotPlaces(s.state)
	s.slotSignature = placement.signature
	local S = L.slots
	if placement.kind ~= "FFA" then
		s.slotsVs = text("VS", L.vs.size, {
			Name = "VS",
			Font = Enum.Font.LuckiestGuy,
			TextXAlignment = Enum.TextXAlignment.Center,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, S.y + S.h / 2),
			Size = UDim2.fromScale(0.06, S.h * 0.7),
			ZIndex = 90,
			Parent = s.root,
		})
		textStroke(s.slotsVs, 4)
	end
	for i, place in placement.places do
		s.slots[i] = buildSlot(s, L, place.slot, S.xs[place.column], 20 + i * 10, i)
	end
end

local function destroySlots(s)
	for _, entry in s.slots or {} do
		entry.portrait.destroy()
		entry.holder:Destroy()
	end
	if s.slotsVs then
		s.slotsVs:Destroy()
	end
	s.slots, s.slotsVs, s.slotSignature = {}, nil, nil
end

local function buildHints(s, L)
	local bar, setItems = UIKit.hintBar(s.root, {}, {
		anchor = Vector2.new(0.5, 0.5),
		position = UDim2.fromScale(0.5, L.hints.y),
	})
	local list = bar:FindFirstChildOfClass("UIListLayout")
	if list then
		list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	end
	bar.ZIndex = 40
	-- (no L1 / R1 VOTE MAP when the map is fixed)
	local items = Models.selectHints(s.state)
	for _, item in items do
		if item.action == "Confirm" then
			item.onClick = function()
				if session == s then
					s.lock(s.hovered)
				end
			end
		end
	end
	setItems(items)
end

local function flash(s, L)
	local group = make("CanvasGroup", {
		Name = "MatchFound",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 100,
		Parent = s.root,
	})
	make("Frame", {
		Name = "Band",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.45),
		Size = UDim2.fromScale(1, 0.16),
		ZIndex = 100,
		Parent = group,
	}, {
		make("UIGradient", { Color = ColorSequence.new(T.RedLight, T.RedDark), Rotation = 90 }),
	})
	local label = text("MATCH FOUND", L.flash, {
		Name = "Text",
		Font = Enum.Font.Bangers,
		TextXAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.45),
		Size = UDim2.fromScale(0.9, 0.14),
		ZIndex = 101,
		Parent = group,
	})
	textStroke(label, 5)
	TweenService:Create(group, TweenInfo.new(FLASH_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		GroupTransparency = 1,
	}):Play()
	task.delay(FLASH_SECONDS + 0.05, function()
		group:Destroy()
	end)
end

-- Rendering -------------------------------------------------------------------------------

local function renderInfo(s, legendId)
	local info = Models.legendInfo(legendId)
	local L = s.layout
	-- (a long name such as MY AVATAR shrinks rather than being cut; the title is letter-spaced, as in mockup d)
	s.infoName.Text = info.name
	Layout.bindText(s.infoName, Models.fitSize(info.name, L.info.name.size, NAME_CHARS))
	s.infoTitle.Text = Models.spaced(info.title)
	Layout.bindText(s.infoTitle, Models.fitSize(info.title, L.info.title.size, TITLE_CHARS))
	local accent = info.color:Lerp(Color3.new(1, 1, 1), 0.35)
	s.infoTitle.TextColor3 = accent
	s.infoUlt.Text = info.ultimate
	s.infoUlt.TextColor3 = accent
	for i, row in s.statRows do
		local stat = info.stats and info.stats[i]
		local value = stat and stat.value or 0
		row.set(value)
		-- the lit pips in the legend's colour (UIKit.pips lights them Gold)
		for p = 1, value do
			local pip = row.pips:FindFirstChild("Pip" .. p)
			if pip then
				pip.BackgroundColor3 = accent
			end
		end
		row.pips.Visible = stat ~= nil
	end
	for _, child in s.weaponsRow:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	for i, weapon in info.weapons do
		UIKit.tag(weapon, {
			parent = s.weaponsRow,
			fill = T.ButtonTop,
			size = L.info.weapons.size,
			layoutOrder = i,
			zIndex = 6,
		})
	end
	s.bigName.Text = info.name
	local top = BACK_TOP:Lerp(info.color, 0.3)
	s.backGradient.Color = ColorSequence.new(top, BACK_BOTTOM)
end

local function renderPreview(s, legendId)
	if not s.preview then
		return
	end
	if legendId == "Random" then
		s.preview:clear()
		return
	end
	s.preview:set({ legend = legendId, userId = player.UserId, ownLook = false })
end

local function renderLook(s)
	local on = lookOn(s)
	if s.lookShown == on then
		return
	end
	s.lookShown = on
	for _, child in s.lookValue:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	UIKit.tag(if on then "ON" else "OFF", {
		parent = s.lookValue,
		fill = if on then T.Good else T.Raised,
		textColor = if on then T.Backdrop else T.Muted,
		size = s.layout.info.look.size,
		zIndex = 7,
	})
end

local TONES = {
	Muted = { T.Raised, T.Muted },
	Good = { T.Good, T.Backdrop },
	Danger = { T.Danger, T.Text },
}

-- A slot's tags: a BOT tag for bots, then the state (SELECTING... / ✓ LOCKED IN / LEFT); rebuilt only on change.
local function setSlotTags(entry, view, size)
	local tone = TONES[view.tone] or TONES.Muted
	local stateText = (if view.tone == "Good" then "✓ " else "") .. view.tag
	local key = stateText .. (if view.bot then "|bot" else "")
	if entry.tagKey == key then
		return
	end
	entry.tagKey = key
	for _, child in entry.tagBox:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local zIndex = entry.zIndex + 8
	if view.bot then
		UIKit.tag("BOT", {
			parent = entry.tagBox,
			fill = T.ButtonTop,
			textColor = T.Text,
			size = size,
			layoutOrder = 1,
			zIndex = zIndex,
		})
	end
	UIKit.tag(stateText, {
		parent = entry.tagBox,
		fill = tone[1],
		textColor = tone[2],
		size = size,
		layoutOrder = 2,
		zIndex = zIndex,
	})
end

local function renderSlots(s)
	local L = s.layout
	local placement = Models.slotPlaces(s.state)
	if placement.signature ~= s.slotSignature then
		-- the arrangement changed (a slot came or went, a team changed)
		destroySlots(s)
		buildSlots(s, L)
	end
	for i, place in placement.places do
		local entry = s.slots[i]
		local slot = place.slot
		if entry then
			local view = Models.slotView(slot)
			entry.name.Text = view.name
			entry.legend.Text = view.legendText
			entry.legend.TextColor3 = if view.legend then T.Text else T.Dim
			local showPortrait = view.legend ~= nil and view.legend ~= "Random"
			entry.hidden.Visible = not showPortrait
			entry.portrait.frame.Visible = showPortrait
			if showPortrait then
				local key = view.legend .. "|" .. tostring(slot.ownLook) .. "|" .. tostring(slot.userId)
				if entry.portraitSpec ~= key then
					entry.portraitSpec = key
					entry.portrait.set({ legend = view.legend, userId = slot.userId, ownLook = slot.ownLook == true })
				end
			end
			setSlotTags(entry, view, math.max(9, L.slots.name * 0.72))
		end
	end
end

local function renderTiles(s)
	local tags = Models.tileTags(s.state)
	for _, tile in s.tiles do
		local list = tags[tile.legend]
		local textValue = if list then table.concat(list, " ") else ""
		if tile.tagText ~= textValue then
			tile.tagText = textValue
			for _, child in tile.tags:GetChildren() do
				if child:IsA("GuiObject") then
					child:Destroy()
				end
			end
			for i, tagText in list or {} do
				UIKit.tag(tagText, { parent = tile.tags, fill = T.Red, size = 14, layoutOrder = i, zIndex = 22 })
			end
		end
		setTileLook(tile)
	end
end

local function renderCountdown(s)
	local seconds, fraction = Models.secondsLeft(s.state.endsAt, ClientState.serverNow())
	if s.setRing then
		s.setRing(fraction, tostring(seconds))
	end
	if seconds ~= s.lastSecond then
		s.lastSecond = seconds
		if seconds >= 1 and seconds <= TICK_FROM then
			Sound.play("Tick", 0.5)
		end
	end
end

local function render(s)
	if s.caption then
		s.caption.Text = Models.lockHint(s.state)
	end
	renderTiles(s)
	renderSlots(s)
	s.renderMaps()
	renderLook(s)
	renderCountdown(s)
end

-- Session -------------------------------------------------------------------------------

local function destroyUI(s)
	if s.layer then
		Focus.popLayer(s.layer)
		s.layer = nil
	end
	if s.preview then
		s.preview:destroy()
		s.preview = nil
	end
	for _, tile in s.tiles or {} do
		if tile.portrait then
			tile.portrait.destroy()
		end
	end
	destroySlots(s)
	for _, rootFrame in { s.root, s.backRoot } do
		if rootFrame then
			rootFrame:Destroy()
		end
	end
	s.root, s.backRoot, s.tiles, s.slots, s.mapCards = nil, nil, {}, {}, {}
	s.lookShown = nil
end

local function tileFor(s, legendId)
	for _, tile in s.tiles do
		if tile.legend == legendId then
			return tile
		end
	end
	return s.tiles[1]
end

local function buildUI(s)
	local L = if Layout.mode() == "Phone" then PHONE else WIDE
	s.layout = L
	s.backGui, s.frontGui = selectGuis()
	buildBackdrop(s)
	s.root = make("Frame", {
		Name = "LegendSelect",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = s.frontGui,
	})
	if L.preview then
		local P = L.preview
		s.preview = LegendView.new(s.root, {
			framing = "Full",
			facing = "Left",
			animated = true,
			anchor = Vector2.new(0, 1),
			position = UDim2.fromScale(P.x, P.bottom),
			size = UDim2.fromScale(P.height * 0.8, P.height),
			zIndex = 2,
		})
	end
	buildHeader(s, L)
	buildInfo(s, L)
	s.tiles = {}
	local rows = { {}, {} }
	local grid = buildGrid(s, L)
	for i, legendId in Models.gridLegends() do
		local tile = buildTile(s, L, grid, legendId, i)
		table.insert(s.tiles, tile)
		table.insert(rows[if i <= 4 then 1 else 2], tile.button)
	end
	buildMaps(s, L)
	buildSlots(s, L)
	buildHints(s, L)

	-- focus graph: the grid, then the map cards under it
	Focus.linkGrid(rows)
	local cardButtons = {}
	for _, entry in s.mapCards do
		if not entry.fixed then
			table.insert(cardButtons, entry.button)
		end
	end
	if #cardButtons > 0 then
		Focus.linkRow(cardButtons)
		for c, tileButton in rows[2] do
			Focus.link(tileButton, "Down", cardButtons[math.min(c, #cardButtons)])
		end
		for i, cardButton in cardButtons do
			Focus.link(cardButton, "Up", rows[2][math.min(i, #rows[2])])
		end
	end
	s.layer = Focus.pushLayer({
		name = "LegendSelect",
		roots = { s.root },
		band = "overlay",
		confirmDelay = Config.Menu.InputGrace,
		defaultFocus = function()
			local slot = mySlot(s)
			local current = slot and (if slot.random then "Random" else slot.legend)
			local tile = tileFor(s, s.hovered or current)
			return tile and tile.button
		end,
		onBack = function()
			s.unlock()
		end,
		actions = {
			X = function()
				s.lock("Random")
			end,
			Y = function()
				s.toggleLook()
			end,
			L1 = function()
				s.voteStep(-1)
			end,
			R1 = function()
				s.voteStep(1)
			end,
		},
	})
	renderInfo(s, s.hovered)
	renderPreview(s, s.hovered)
	render(s)
end

local function teardown()
	local s = session
	if not s then
		return
	end
	session = nil
	destroyUI(s)
end

local function newSession(state)
	local s = {
		id = state.id,
		state = state,
		tiles = {},
		slots = {},
		mapCards = {},
		hovered = nil,
		provisional = nil,
		lockSentAt = nil,
		lockResent = false,
		unlockPending = false,
		unlockAt = nil,
		lookOverride = nil,
		lookOverrideAt = nil,
		localVote = nil,
		localVoteAt = nil,
		tapped = nil,
		lastSecond = nil,
		wasLocked = false,
	}
	local slot = mySlot(s)
	local start = slot and (if slot.random then "Random" else slot.legend)
	if not start or (start ~= "Random" and not Legends.isValid(start)) then
		start = Legends.Default
	end
	s.hovered = start
	s.throttle = Models.newHoverThrottle(Config.Select.HoverInterval, slot and slot.legend)

	-- the info block, the big preview and the backdrop follow the legend on screen
	function s.show(legendId)
		if s.hovered ~= legendId then
			s.hovered = legendId
			renderInfo(s, legendId)
			renderPreview(s, legendId)
			renderTiles(s)
		end
	end

	function s.hover(legendId)
		if session ~= s or not legendId or lockedPick(s) then
			-- locked in: the screen stays on your pick until you unlock
			return
		end
		s.show(legendId)
		local value = s.throttle.push(legendId, os.clock())
		if value then
			send("Hover", { legend = value })
		end
	end

	function s.lock(legendId)
		if session ~= s or not legendId then
			return
		end
		local mine = mySlot(s)
		if mine and mine.locked and not s.unlockPending then
			-- the server ignores a Lock while you're locked: unlock (Back) first
			return
		end
		s.show(legendId)
		s.provisional = legendId
		s.lockSentAt = os.clock()
		s.lockResent = false
		s.throttle.reset(legendId)
		send("Lock", { legend = legendId })
		renderTiles(s)
	end

	function s.unlock()
		if session ~= s or not lockedPick(s) then
			return
		end
		s.provisional = nil
		s.lockSentAt = nil
		if myLocked(s) then
			s.unlockPending = true
			s.unlockAt = os.clock()
			send("Unlock", {})
		end
		local mine = mySlot(s)
		s.throttle.reset(mine and mine.legend)
		renderTiles(s)
		-- free again: the screen follows the focused tile
		local focused = Focus.get()
		for _, tile in s.tiles do
			if tile.button == focused then
				s.hover(tile.legend)
			end
		end
	end

	function s.toggleLook()
		if session ~= s then
			return
		end
		local on = not lookOn(s)
		s.lookOverride = on
		s.lookOverrideAt = os.clock()
		send("Look", { on = on })
		Settings.set("FightAsAvatar", on)
		renderLook(s)
	end

	function s.vote(mapId)
		if session ~= s or not mapId or not s.state.maps then
			return
		end
		s.localVote = mapId
		s.localVoteAt = os.clock()
		send("Vote", { mapId = mapId })
		s.renderMaps()
	end

	function s.voteStep(delta)
		if session ~= s or not s.state.maps then
			return
		end
		local current = s.localVote or s.state.yourVote
		s.vote(Models.nextVote(s.state.maps, current, delta))
	end

	function s.renderMaps()
		local cards = Models.mapCards(s.state, s.localVote)
		for i, card in cards do
			local entry = s.mapCards[i]
			if entry and not entry.fixed then
				entry.setPips(card.votes)
				entry.votes.Text = Models.votesText(card.votes)
				entry.votes.TextColor3 = if card.yours then T.Gold else T.Muted
				entry.yours.Visible = card.yours
				entry.border.Color = if card.yours then T.Gold elseif entry.focused then T.Text else T.Stroke
			end
		end
	end

	return s
end

local function onBegin(data)
	local decision = Models.phaseAfter({ type = "Begin", id = data.id }, { phase = ClientState.phase })
	if not decision then
		return
	end
	teardown()
	local s = newSession(data)
	session = s
	local ok, err = pcall(buildUI, s)
	if not ok then
		warn("[LegendSelect] build failed:", err)
	end
	Sound.play("MatchFound", 0.6)
	ClientState.setPhase(decision.phase)
	if ok and session == s then
		flash(s, s.layout)
	end
end

local function onUpdate(data)
	local s = session
	if not s or data.id ~= s.id then
		return
	end
	s.state = data
	local slot = mySlot(s)
	local locked = slot ~= nil and slot.locked == true
	if locked and not s.wasLocked then
		Sound.play("LockIn", 0.6)
	end
	s.wasLocked = locked
	if locked then
		-- the lock is confirmed (LOCKED IN shows from the slot)
		s.provisional = nil
		s.lockSentAt = nil
		if s.unlockPending and os.clock() - (s.unlockAt or 0) > LOCK_RESEND then
			-- the server refused the unlock (the all-locked delay was over)
			s.unlockPending = false
		end
	else
		s.unlockPending = false
	end
	if s.lookOverride ~= nil and slot and slot.ownLook == s.lookOverride then
		s.lookOverride = nil
	end
	if s.localVote and data.yourVote == s.localVote then
		s.localVote = nil
	end
	local pick = lockedPick(s)
	if pick then
		s.show(pick)
	end
	local ok, err = pcall(render, s)
	if not ok then
		-- (never into the SelectEvent signal: VsSplash listens to it too)
		warn("[LegendSelect] update failed:", err)
	end
end

local function onCancel(data, previousSelect)
	local s = session
	if not s then
		return
	end
	local id = s.id or (previousSelect and previousSelect.id)
	if data.id ~= id then
		return
	end
	local decision = Models.phaseAfter({
		type = "Cancel",
		id = data.id,
		reason = data.reason,
		requeued = data.requeued == true,
	}, { phase = ClientState.phase, selectId = id })
	teardown()
	if decision then
		ClientState.toast(decision.toast, decision.toastKind)
		ClientState.setPhase(decision.phase)
	end
end

-- Every frame while open: the countdown, the Hover follow-up, the Lock re-send and stale Look / Vote overrides.
local function step()
	local s = session
	if not s or not s.root then
		return
	end
	renderCountdown(s)
	local now = os.clock()
	if not lockedPick(s) then
		local value = s.throttle.poll(now)
		if value then
			send("Hover", { legend = value })
		end
	end
	if s.provisional and s.lockSentAt then
		if not s.lockResent and now - s.lockSentAt >= LOCK_RESEND then
			s.lockResent = true
			send("Lock", { legend = s.provisional })
		elseif s.lockResent and now - s.lockSentAt >= LOCK_GIVE_UP then
			-- the server refused it (or the pick phase is over): drop the tint
			s.provisional = nil
			s.lockSentAt = nil
			renderTiles(s)
		end
	end
	-- a Look or Vote the server dropped (its SelectAction rate limit) shows the server's value again
	if s.lookOverride ~= nil and now - (s.lookOverrideAt or 0) > OVERRIDE_TTL then
		s.lookOverride = nil
		renderLook(s)
	end
	if s.localVote ~= nil and now - (s.localVoteAt or 0) > OVERRIDE_TTL then
		s.localVote = nil
		s.renderMaps()
	end
end

function LegendSelect.init()
	ClientState.SelectEvent:Connect(function(kind, data, previousSelect)
		if type(data) ~= "table" then
			return
		end
		if kind == "Begin" then
			onBegin(data)
		elseif kind == "Update" then
			onUpdate(data)
		elseif kind == "Cancel" then
			onCancel(data, previousSelect)
		elseif kind == "Vs" then
			-- VsSplash takes over
			if session and data.id == session.id then
				teardown()
			end
		end
	end)
	ClientState.PhaseChanged:Connect(function(phase)
		if phase ~= "Select" then
			teardown()
		end
	end)
	Focus.Changed:Connect(function(new)
		local s = session
		if not s or not new then
			return
		end
		for _, tile in s.tiles do
			if tile.button == new then
				s.hover(tile.legend)
				return
			end
		end
	end)
	-- a phone <-> wide switch rebuilds the screen (the session's state is kept)
	Layout.Changed:Connect(function()
		local s = session
		if s and s.root then
			destroyUI(s)
			local ok, err = pcall(buildUI, s)
			if not ok then
				warn("[LegendSelect] rebuild failed:", err)
			end
		end
	end)
	RunService.Heartbeat:Connect(step)
end

return LegendSelect
