--[[
    Menu screen "Rankings" (menus design 5.8, mockup h): the ranked ladders.

      tabs        RANKED 1V1 / RANKED 2V2 (L1/R1), GLOBAL / FRIENDS (L2/R2);
                  X cycles the seasons when there is more than one
      list        Config.Rankings.PageSize rows a page (keyed by their
                  position on the page and updated in place; top 3 tinted
                  gold / silver / bronze), your row pinned at the bottom
                  (rank "—" outside the list; your live profile until the
                  first answer). Down on the last row / Up on the first
                  flips the page, as do the PREV / NEXT buttons (mouse and
                  touch); Y jumps to your page.
      rank card   tier, rating, PEAK (current season), progress to the next
                  tier, #RANK / WINS / LOSSES / WIN RATE and your best legend
                  (a past season shows the stored MAIN, or NOT RANKED)

    Data comes from GetRankings({ mode, scope, season }) on open and on
    every tab change (the server caches; the last answer per tab is shown
    meanwhile). What each row and the card say comes from Models (tested).
    The shell hides the player card and party bar here and puts the hints
    bottom-left. Phone: no MAIN / TIER columns, 6 rows a page, a compact
    card under the list, all in one scrolling body.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Ranks = require(Shared.Ranks)

local Sound = require(script.Parent.Parent.Parent.Controllers.Sound)

local UIKit = require(script.Parent.Parent.UIKit)
local Focus = require(script.Parent.Parent.Focus)
local Layout = require(script.Parent.Parent.Layout)
local LegendView = require(script.Parent.Parent.LegendView)
local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Common = require(script.Parent.Common)
local Models = require(script.Parent.Models)

local T = UIKit.Theme
local make = UIKit.make

local Screen = {
	id = "Rankings",
	title = "RANKINGS",
}

local MEDAL_COLORS = {
	Gold = Color3.fromRGB(255, 197, 61),
	Silver = Color3.fromRGB(200, 205, 215),
	Bronze = Color3.fromRGB(205, 127, 50),
}
local PHONE_PAGE = 6
local PHONE_HEIGHT = 1500

-- List columns (fractions of a row): x, width, alignment.
local COLUMNS = {
	rank = { 0.012, 0.07 },
	name = { 0.092, 0.37 },
	main = { 0.48, 0.045 },
	tier = { 0.586, 0.2 },
	rating = { 0.73, 0.15 },
	record = { 0.886, 0.1 },
}
local PHONE_COLUMNS = {
	rank = { 0.02, 0.1 },
	name = { 0.13, 0.42 },
	rating = { 0.56, 0.2 },
	record = { 0.78, 0.2 },
}

function Screen.build(host)
	local root = Common.root(host, "Rankings")
	local sizer = Common.sizer(root)
	local bag = Common.bag()
	local localPlayer = Players.LocalPlayer

	local state = { mode = "1v1", scope = "Global", season = nil, page = 1 }
	local cache = {} -- ["mode|scope|season"] = RankingsData
	local data = nil
	local statusText = nil -- loading / error line
	local fetchToken = 0
	local shown = false
	local showToken = 0
	local seasonCount = 1

	-- built per layout mode
	local container
	local selectMode, selectScope
	local seasonLabel, dotsLabel, emptyLabel
	local pageButtons = {} -- PREV / NEXT (taps and clicks; Up / Down on the rows do the same)
	local rowParts = {} -- [position on the page] = row parts
	local pinned
	local card
	local pageSize = Config.Rankings.PageSize
	local lastParams = nil -- the deep-link params already applied

	local function keyOf()
		return state.mode .. "|" .. state.scope .. "|" .. tostring(state.season or "current")
	end

	local renderAll
	local rewireTop -- the top row's Up -> CANCEL; linkColumn clears it, so every relink calls this again

	-- Your entry from the live profile (current season) while GetRankings hasn't answered for this tab.
	local function liveYou()
		local profile = ClientState.profile
		if not profile then
			return nil
		end
		local mode = state.mode
		local stats = profile.SeasonStats and profile.SeasonStats[mode] or {}
		return {
			rating = profile["Rating" .. mode],
			tier = profile["Tier" .. mode],
			peak = profile["Peak" .. mode],
			wins = stats.wins or 0,
			losses = stats.losses or 0,
			bestLegend = stats.bestLegend,
		}
	end

	local function fetch()
		fetchToken += 1
		local token = fetchToken
		local key = keyOf()
		data = cache[key]
		statusText = "Loading..."
		renderAll()
		local request = { mode = state.mode, scope = state.scope, season = state.season }
		task.spawn(function()
			local ok, result = Common.invoke("GetRankings", request)
			if token ~= fetchToken then
				return
			end
			if ok and type(result) == "table" then
				cache[key] = result
				data = result
				statusText = nil
			else
				statusText = if type(result) == "string" then result else "Couldn't load the rankings."
			end
			renderAll()
			local count = data and data.seasons and #data.seasons or 1
			if count ~= seasonCount then
				seasonCount = count
				host.refresh()
			end
		end)
	end

	-- Rows ------------------------------------------------------------------------

	local function cell(parent, column, text, size, props)
		props = props or {}
		props.Position = UDim2.fromScale(column[1], 0)
		props.Size = UDim2.fromScale(column[2], 1)
		props.TextWrapped = false
		props.TextTruncate = Enum.TextTruncate.AtEnd
		props.Parent = parent
		return Common.text(text, size, props)
	end

	local function setRow(parts, view)
		parts.rank.Text = view.rank
		parts.rank.TextColor3 = if view.medal then MEDAL_COLORS[view.medal] else T.Text
		parts.name.Text = view.name
		parts.rating.Text = view.rating
		parts.record.Text = view.record
		if parts.tier then
			local tier = Ranks.tier(0)
			for _, t in Config.Ranked.Tiers do
				if t.Name == view.tierName then
					tier = t
				end
			end
			parts.tier.Text = view.tier
			parts.tier.TextColor3 = tier.Color
			Common.setTierBadge(parts.tierBadge, view.tierName)
		end
		if parts.portrait then
			parts.mainBox.Visible = true
			if view.main then
				parts.unknown.Visible = false
				parts.portraitFrame.Visible = true
				-- "Avatar" mains show that player's own headshot
				local spec = view.main .. "|" .. tostring(view.userId)
				if parts.portraitLegend ~= spec then
					parts.portraitLegend = spec
					parts.portrait.set({ legend = view.main, userId = view.userId, ownLook = false })
				end
			else
				parts.unknown.Visible = true
				parts.portraitFrame.Visible = false
			end
		end
		if parts.tint then
			parts.tint.Visible = view.medal ~= nil
			if view.medal then
				parts.tint.BackgroundColor3 = MEDAL_COLORS[view.medal]
			end
		end
	end

	local function buildRow(parent, columns, props)
		local frame = make(if props.button then "TextButton" else "Frame", {
			Name = props.name,
			BackgroundColor3 = props.color or T.Raised,
			BorderSizePixel = 0,
			Position = props.position,
			Size = props.size,
			Parent = parent,
		})
		if props.button then
			frame.AutoButtonColor = false
			frame.Text = ""
		end
		local parts = { frame = frame }
		local tint = Common.fill(Color3.new(1, 1, 1), {
			Name = "Medal",
			Size = UDim2.fromScale(1, 1),
			Visible = false,
			Parent = frame,
		})
		make("UIGradient", {
			Transparency = NumberSequence.new(0.7, 1),
			Parent = tint,
		})
		parts.tint = tint
		parts.rank = cell(frame, columns.rank, "", props.rankSize or 30, { Font = T.LogoFont })
		parts.name = cell(frame, columns.name, "", 22, { Font = T.BlackFont })
		if columns.main then
			local mainBox = make("Frame", {
				Name = "Main",
				BackgroundTransparency = 1,
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.fromScale(columns.main[1], 0.5),
				Size = UDim2.fromScale(columns.main[2], 0.78),
				Parent = frame,
			})
			make("UIAspectRatioConstraint", { AspectRatio = 1, Parent = mainBox })
			parts.mainBox = mainBox
			parts.portrait = LegendView.portrait(mainBox, { legend = "Kestrel" }, {})
			parts.portraitFrame = parts.portrait.frame
			parts.portraitLegend = "Kestrel"
			parts.unknown = Common.text("?", 26, {
				Name = "Unknown",
				Font = T.HeadFont,
				TextColor3 = T.Dim,
				TextXAlignment = Enum.TextXAlignment.Center,
				BackgroundTransparency = 0,
				BackgroundColor3 = T.PanelLight,
				Visible = false,
				Parent = mainBox,
			})
		end
		if columns.tier then
			local tierBox = make("Frame", {
				Name = "Tier",
				BackgroundTransparency = 1,
				Position = UDim2.fromScale(columns.tier[1], 0),
				Size = UDim2.fromScale(columns.tier[2], 1),
				Parent = frame,
			})
			parts.tierBadge = Common.tierBadge("Tin", {
				anchor = Vector2.new(0, 0.5),
				position = UDim2.fromScale(0, 0.5),
				size = UDim2.fromScale(0.2, 0.5),
				parent = tierBox,
			})
			parts.tier = Common.text("", 18, {
				Font = T.BlackFont,
				Position = UDim2.fromScale(0.22, 0),
				Size = UDim2.fromScale(0.78, 1),
				TextWrapped = false,
				Parent = tierBox,
			})
		end
		parts.rating = cell(frame, columns.rating, "", 24, {
			Font = T.LogoFont,
			TextXAlignment = Enum.TextXAlignment.Right,
		})
		parts.record = cell(frame, columns.record, "", 20, {
			Font = T.BoldFont,
			TextColor3 = T.Muted,
			TextXAlignment = Enum.TextXAlignment.Right,
		})
		return parts
	end

	-- Card --------------------------------------------------------------------------

	local function buildCard(parent, position, size, compact)
		local panel, body = Common.cutPanel({
			name = "RankCard",
			position = position,
			size = size,
			parent = parent,
		})
		local c = { panel = panel }
		c.glow = Common.fill(T.Gold, {
			Name = "Glow",
			BackgroundTransparency = 0.82,
			Size = UDim2.fromScale(1, 0.62),
			Parent = body,
		})
		make("UIGradient", { Rotation = 90, Transparency = NumberSequence.new(0, 1), Parent = c.glow })
		Common.header("YOUR RANK", {
			position = UDim2.fromScale(0.04, 0.025),
			size = UDim2.fromScale(0.55, if compact then 0.12 else 0.055),
			parent = body,
		})
		c.modeLabel = Common.text("", 20, {
			Font = T.BoldFont,
			TextColor3 = T.Muted,
			TextXAlignment = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(0.96, 0.025),
			Size = UDim2.fromScale(0.4, if compact then 0.12 else 0.055),
			Parent = body,
		})
		if compact then
			-- phone: badge, tier and rating in one row, then the stat boxes
			c.badge = Common.tierBadge("Tin", {
				position = UDim2.fromScale(0.04, 0.2),
				size = UDim2.fromScale(0.2, 0.3),
				parent = body,
			})
			c.tier = Common.text("", 56, {
				Font = T.HeadFont,
				Position = UDim2.fromScale(0.27, 0.18),
				Size = UDim2.fromScale(0.4, 0.2),
				TextWrapped = false,
				Parent = body,
			})
			c.rating = Common.text("", 56, {
				Font = T.LogoFont,
				Position = UDim2.fromScale(0.27, 0.36),
				Size = UDim2.fromScale(0.35, 0.18),
				TextWrapped = false,
				Parent = body,
			})
			c.peak = Common.text("", 20, {
				Font = T.BlackFont,
				TextColor3 = T.Muted,
				Position = UDim2.fromScale(0.63, 0.36),
				Size = UDim2.fromScale(0.33, 0.18),
				TextWrapped = false,
				Parent = body,
			})
		else
			c.badge = Common.tierBadge("Tin", {
				anchor = Vector2.new(0.5, 0.5),
				position = UDim2.fromScale(0.5, 0.24),
				size = UDim2.fromScale(0.36, 0.27),
				parent = body,
			})
			c.tier = Common.text("", 96, {
				Font = T.HeadFont,
				TextXAlignment = Enum.TextXAlignment.Center,
				Position = UDim2.fromScale(0.05, 0.38),
				Size = UDim2.fromScale(0.9, 0.1),
				TextWrapped = false,
				Parent = body,
			})
			c.rating = Common.text("", 110, {
				Font = T.LogoFont,
				TextXAlignment = Enum.TextXAlignment.Right,
				Position = UDim2.fromScale(0.05, 0.47),
				Size = UDim2.fromScale(0.5, 0.1),
				TextWrapped = false,
				Parent = body,
			})
			c.peak = Common.text("", 22, {
				Font = T.BlackFont,
				TextColor3 = T.Muted,
				Position = UDim2.fromScale(0.58, 0.5),
				Size = UDim2.fromScale(0.38, 0.06),
				TextWrapped = false,
				Parent = body,
			})
		end
		-- progress to the next tier
		local progressY = if compact then 0.56 else 0.6
		c.progress = make("Frame", {
			Name = "Progress",
			BackgroundTransparency = 1,
			Position = UDim2.fromScale(0.06, progressY),
			Size = UDim2.fromScale(0.88, if compact then 0.16 else 0.1),
			Parent = body,
		})
		c.fromLabel = Common.text("", 16, {
			Font = T.BlackFont,
			TextColor3 = T.Muted,
			Size = UDim2.fromScale(0.5, 0.3),
			TextWrapped = false,
			Parent = c.progress,
		})
		c.toLabel = Common.text("", 16, {
			Font = T.BlackFont,
			TextXAlignment = Enum.TextXAlignment.Right,
			Position = UDim2.fromScale(0.5, 0),
			Size = UDim2.fromScale(0.5, 0.3),
			TextWrapped = false,
			Parent = c.progress,
		})
		local bar, setBar = UIKit.progressBar({
			name = "Bar",
			back = T.Backdrop,
			fill = T.Gold,
			position = UDim2.fromScale(0, 0.36),
			size = UDim2.fromScale(1, 0.22),
			parent = c.progress,
		})
		c.bar, c.setBar = bar, setBar
		c.toNext = Common.text("", 18, {
			TextColor3 = T.Muted,
			Position = UDim2.fromScale(0, 0.66),
			Size = UDim2.fromScale(1, 0.34),
			TextWrapped = false,
			Parent = c.progress,
		})
		-- stat boxes
		c.stats = {}
		local statsY = if compact then 0.74 else 0.715
		for i, key in { "rank", "wins", "losses", "winRate" } do
			local boxFrame = Common.fill(T.Backdrop, {
				Name = "Stat" .. i,
				Position = UDim2.fromScale(0.06 + (i - 1) * 0.225, statsY),
				Size = UDim2.fromScale(0.2, if compact then 0.24 else 0.095),
				Parent = body,
			})
			Common.stroke(boxFrame, T.Stroke, 2)
			local value = Common.text("", if compact then 30 else 36, {
				Font = T.LogoFont,
				TextXAlignment = Enum.TextXAlignment.Center,
				Size = UDim2.fromScale(1, 0.62),
				TextWrapped = false,
				TextColor3 = if key == "wins" then T.Good elseif key == "losses" then T.Red else T.Text,
				Parent = boxFrame,
			})
			local label = Common.text("", 14, {
				Font = T.BlackFont,
				TextColor3 = T.Muted,
				TextXAlignment = Enum.TextXAlignment.Center,
				Position = UDim2.fromScale(0, 0.62),
				Size = UDim2.fromScale(1, 0.32),
				TextWrapped = false,
				Parent = boxFrame,
			})
			c.stats[key] = { value = value, label = label }
		end
		c.stats.wins.label.Text = "WINS"
		c.stats.losses.label.Text = "LOSSES"
		c.stats.winRate.label.Text = "WIN RATE"
		-- best legend / main
		if not compact then
			c.legend = Common.fill(T.Raised, {
				Name = "Legend",
				Position = UDim2.fromScale(0.06, 0.845),
				Size = UDim2.fromScale(0.88, 0.12),
				Parent = body,
			})
			Common.fill(T.Teal, { Size = UDim2.fromScale(0.012, 1), Parent = c.legend })
			local portraitBox = make("Frame", {
				BackgroundTransparency = 1,
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.fromScale(0.04, 0.5),
				Size = UDim2.fromScale(0.2, 0.8),
				Parent = c.legend,
			})
			make("UIAspectRatioConstraint", { AspectRatio = 1, Parent = portraitBox })
			c.legendPortrait = LegendView.portrait(portraitBox, { legend = "Kestrel" }, {})
			c.legendShown = "Kestrel"
			c.legendTitle = Common.text("", 16, {
				Font = T.BlackFont,
				TextColor3 = T.Muted,
				Position = UDim2.fromScale(0.27, 0.08),
				Size = UDim2.fromScale(0.7, 0.26),
				TextWrapped = false,
				Parent = c.legend,
			})
			c.legendName = Common.text("", 38, {
				Font = T.HeadFont,
				Position = UDim2.fromScale(0.27, 0.32),
				Size = UDim2.fromScale(0.7, 0.4),
				TextWrapped = false,
				Parent = c.legend,
			})
			c.legendLine = Common.text("", 18, {
				TextColor3 = T.Muted,
				Position = UDim2.fromScale(0.27, 0.7),
				Size = UDim2.fromScale(0.7, 0.26),
				TextWrapped = false,
				Parent = c.legend,
			})
		end
		return c
	end

	local function renderCard()
		if not card then
			return
		end
		-- nothing loaded yet: your live profile for the current season
		local you = data and data.you or liveYou()
		local view = Models.rankCard(you, state.scope)
		card.modeLabel.Text = "Ranked " .. state.mode
		card.badge.Visible = not view.notRanked and you ~= nil
		Common.setTierBadge(card.badge, view.tierName)
		card.tier.Text = if you then view.tier else "..."
		card.tier.TextColor3 = if view.notRanked then T.Muted else view.tierColor
		card.rating.Text = if view.notRanked then "" else view.rating
		card.peak.Text = view.peak or ""
		card.peak.Visible = view.peak ~= nil
		card.glow.BackgroundColor3 = view.tierColor
		card.progress.Visible = view.progress ~= nil
		if view.progress then
			card.fromLabel.Text = view.progress.from
			card.fromLabel.TextColor3 = view.tierColor
			card.toLabel.Text = view.progress.to or ""
			local nextTier = nil
			for _, t in Config.Ranked.Tiers do
				if view.progress.to and string.upper(t.Name) .. " " .. t.Min == view.progress.to then
					nextTier = t
				end
			end
			card.toLabel.TextColor3 = if nextTier then nextTier.Color else T.Muted
			card.setBar(view.progress.fraction, view.tierColor)
			card.toNext.Text = view.progress.toNext
		end
		card.stats.rank.value.Text = view.rank
		card.stats.rank.label.Text = view.rankLabel
		card.stats.wins.value.Text = view.wins
		card.stats.losses.value.Text = view.losses
		card.stats.winRate.value.Text = view.winRate
		if card.legend then
			card.legend.Visible = view.legend ~= nil
			if view.legend then
				if card.legendShown ~= view.legend.id then
					card.legendShown = view.legend.id
					card.legendPortrait.set({ legend = view.legend.id })
				end
				card.legendTitle.Text = view.legend.title
				card.legendName.Text = view.legend.name
				card.legendLine.Text = view.legend.line or ""
			end
		end
	end

	-- Pages ---------------------------------------------------------------------------

	local function visibleRows()
		local out = {}
		for _, parts in rowParts do
			if parts.frame.Visible then
				table.insert(out, parts.frame)
			end
		end
		return out
	end

	local function currentPage()
		-- before this tab's first answer the pinned row shows your live profile
		local source = data or { rows = {}, you = liveYou() }
		return Models.rankingsPage(source, state.page, pageSize, localPlayer.DisplayName, localPlayer.UserId)
	end

	local function renderList()
		if not pinned then
			return
		end
		local page = currentPage()
		state.page = page.page
		for i, parts in rowParts do
			local view = page.rows[i]
			parts.frame.Visible = view ~= nil
			if view then
				setRow(parts, view)
			end
		end
		setRow(pinned, page.pinned)
		Focus.linkColumn(visibleRows())
		if rewireTop then
			rewireTop()
		end
		for dir, button in pageButtons do
			button.Visible = page.pages > 1
			button.TextColor3 = if Models.flipPage(page.page, page.pages, dir) then T.Text else T.Dim
		end
		local rows = data and data.rows or {}
		emptyLabel.Visible = data ~= nil and #rows == 0
		emptyLabel.Text = if state.scope == "Friends"
			then "None of your friends has a rating this season yet."
			else "Nobody is ranked this season yet. Play a ranked match!"
		-- one muted line under the rows: loading / offline / partial, else the page dots
		local line = statusText
		if not line and data then
			if data.status == "unavailable" then
				line = "Rankings are offline here (no DataStores): showing players on this server."
			elseif data.status == "partial" then
				line = "Some ratings couldn't load. Try again in a moment."
			end
		end
		dotsLabel.TextColor3 = if line then T.Muted else T.Dim
		dotsLabel.Text = line
			or (if page.pages > 1 then string.format("•  •  •     PAGE %d / %d", page.page, page.pages) else "")
		pinned.frame.Visible = data ~= nil or ClientState.profile ~= nil
	end

	local function renderSeason()
		if not seasonLabel then
			return
		end
		local season = data and data.season
		if not season and ClientState.profile and ClientState.profile.Season then
			local s = ClientState.profile.Season
			season = { id = s.id, name = s.name, endsAt = s.endsAt, current = true }
		end
		seasonLabel.Text = if season then Models.seasonLabel(season, ClientState.serverNow()) else ""
	end

	function renderAll()
		renderList()
		renderCard()
		renderSeason()
	end

	-- focus = false leaves focus alone (taps on PREV / NEXT: focus never shows on touch)
	local function showPage(page, focusRow, focus)
		state.page = page
		renderList()
		local target = rowParts[focusRow or 1]
		if focus ~= false and target and target.frame.Visible then
			Focus.set(target.frame)
		end
	end

	-- PREV / NEXT: dir "Up" = previous page, "Down" = next page.
	local function tapPage(dir)
		local page = currentPage()
		local target = Models.flipPage(page.page, page.pages, dir)
		if target then
			showPage(target, if dir == "Down" then 1 else pageSize, Focus.mode() ~= "Touch")
		end
	end

	local function setMode(mode)
		if state.mode == mode then
			return
		end
		state.mode = mode
		state.page = 1
		state.season = nil
		fetch()
	end

	local function setScope(scope)
		if state.scope == scope then
			return
		end
		state.scope = scope
		state.page = 1
		fetch()
	end

	-- Tab changes from actions and hints: the state first (fetches), then the tab bar's look.
	local function chooseMode(mode)
		setMode(mode)
		selectMode(mode)
	end

	local function chooseScope(scope)
		setScope(scope)
		selectScope(scope)
	end

	local function otherMode()
		return if state.mode == "1v1" then "2v2" else "1v1"
	end

	local function otherScope()
		return if state.scope == "Global" then "Friends" else "Global"
	end

	local function cycleSeason()
		local seasons = data and data.seasons
		if type(seasons) ~= "table" or #seasons < 2 then
			return
		end
		local currentId = data.season and data.season.id
		local index = 1
		for i, s in seasons do
			if s.id == currentId then
				index = i
			end
		end
		local nextSeason = seasons[index % #seasons + 1]
		state.season = nextSeason.id
		state.page = 1
		fetch()
	end

	local function jumpToMe()
		local page, row = Models.yourPage(data and data.rows, pageSize)
		if not page then
			host.toast(
				if state.scope == "Global"
					then "You're not in the top " .. Config.Rankings.TopSize .. " yet."
					else "You're not on this list yet.",
				"info"
			)
			return
		end
		showPage(page, row)
	end

	-- Build -----------------------------------------------------------------------------

	local function build()
		if container then
			container:Destroy()
		end
		table.clear(rowParts)
		local phone = Common.isPhone()
		pageSize = if phone then PHONE_PAGE else Config.Rankings.PageSize
		local columns = if phone then PHONE_COLUMNS else COLUMNS
		local canvas
		local tabsParent, listPos, listSize, cardPos, cardSize
		if phone then
			local scroller
			canvas, scroller = Common.body(root, sizer, {
				phoneRegion = { x0 = 0.02, y0 = 0.27, x1 = 0.98, y1 = 0.98 },
				phoneHeight = PHONE_HEIGHT,
			})
			container = scroller
			tabsParent = canvas
			listPos, listSize = UDim2.fromScale(0, 0.1), UDim2.fromScale(1, 0.56)
			cardPos, cardSize = UDim2.fromScale(0, 0.68), UDim2.fromScale(1, 0.31)
		else
			container = make("Frame", {
				Name = "Body",
				BackgroundTransparency = 1,
				Size = UDim2.fromScale(1, 1),
				Parent = root,
			})
			canvas = container
			tabsParent = container
			-- mockup h runs the panels down to y 0.946, but the shell's left hint bar is centred at 0.946:
			-- they stop at 0.916 so the hints sit below them
			listPos, listSize = UDim2.fromScale(0.029, 0.196), UDim2.fromScale(0.623, 0.72)
			cardPos, cardSize = UDim2.fromScale(0.672, 0.196), UDim2.fromScale(0.308, 0.72)
		end

		-- tabs and the season label (on phones at least 44 px tall: 78+ design px of the 1.6x canvas)
		local modeTabs, selectModeTab = UIKit.tabBar({
			{ id = "1v1", label = "RANKED 1V1" },
			{ id = "2v2", label = "RANKED 2V2" },
		}, {
			style = "big",
			name = "ModeTabs",
			position = if phone then UDim2.fromScale(0, 0) else UDim2.fromScale(0.281, 0.111),
			size = if phone then UDim2.fromScale(0.62, 0.055) else UDim2.fromScale(0.29, 0.056),
			parent = tabsParent,
			onSelect = setMode,
		})
		modeTabs.ZIndex = 2
		-- small tabs are each 0.5 / #tabs of the bar: 0.23 gives the mockup's 0.057-wide chips
		local scopeTabs, selectScopeTab = UIKit.tabBar({
			{ id = "Global", label = "GLOBAL" },
			{ id = "Friends", label = "FRIENDS" },
		}, {
			style = "small",
			name = "ScopeTabs",
			-- (phone: the chips fill the bar's left half, x 0.64 - 1.0; the transparent rest is clipped)
			position = if phone then UDim2.fromScale(0.64, 0) else UDim2.fromScale(0.632, 0.122),
			size = if phone then UDim2.fromScale(0.72, 0.055) else UDim2.fromScale(0.23, 0.03),
			parent = tabsParent,
			onSelect = setScope,
		})
		scopeTabs.ZIndex = 2
		selectMode = selectModeTab
		selectScope = selectScopeTab
		if not phone then
			for i, action in { "L1", "R1" } do
				Common.glyph(action, {
					position = UDim2.fromScale(0.578 + (i - 1) * 0.024, 0.124),
					size = UDim2.fromScale(0.02, 0.032),
					parent = container,
				})
			end
		end
		seasonLabel = Common.text("", 22, {
			Name = "Season",
			Font = T.BlackFont,
			TextColor3 = T.Muted,
			TextXAlignment = Enum.TextXAlignment.Right,
			AnchorPoint = if phone then Vector2.new(0, 0) else Vector2.new(1, 0.5),
			Position = if phone then UDim2.fromScale(0, 0.06) else UDim2.fromScale(0.977, 0.137),
			Size = if phone then UDim2.fromScale(1, 0.035) else UDim2.fromScale(0.22, 0.04),
			TextWrapped = false,
			Parent = tabsParent,
		})

		-- the list panel
		local list = Common.fill(T.Panel, {
			Name = "List",
			Position = listPos,
			Size = listSize,
			Parent = canvas,
		})
		Common.stroke(list, T.Stroke, 2)
		local header = make("Frame", {
			Name = "Header",
			BackgroundTransparency = 1,
			Position = UDim2.fromScale(0.019, 0.02),
			Size = UDim2.fromScale(0.962, 0.04),
			Parent = list,
		})
		local headers = {
			rank = "#",
			name = "PLAYER",
			main = "MAIN",
			tier = "TIER",
			rating = "RATING",
			record = "W - L",
		}
		for key, column in columns do
			local right = key == "rating" or key == "record"
			Common.text(headers[key], 18, {
				Font = T.BlackFont,
				TextColor3 = T.Muted,
				TextXAlignment = if right then Enum.TextXAlignment.Right else Enum.TextXAlignment.Left,
				Position = UDim2.fromScale(column[1], 0),
				Size = UDim2.fromScale(if key == "main" then 0.08 else column[2], 1),
				TextWrapped = false,
				Parent = header,
			})
		end
		-- Wide: PageSize rows of 58 px (0.0746 of the 778 px panel), 61 px apart, then the page line and your
		-- row; phones: fewer, taller rows (84 design px = 48 px on a 390 px phone)
		local rowStep = if phone then 0.115 else 0.0784
		local rowHeight = if phone then 0.1 else 0.0746
		for i = 1, pageSize do
			local parts = buildRow(list, columns, {
				name = "Row" .. i,
				button = true,
				position = UDim2.fromScale(0.019, 0.067 + (i - 1) * rowStep),
				size = UDim2.fromScale(0.962, rowHeight),
			})
			parts.frame.Visible = false
			rowParts[i] = parts
			Common.focusable(parts.frame, {
				key = "RankRow" .. i,
				onDown = function()
					local visible = visibleRows()
					if parts.frame ~= visible[#visible] then
						return false
					end
					local page = currentPage()
					local nextPage = Models.flipPage(page.page, page.pages, "Down")
					if nextPage then
						showPage(nextPage, 1)
						return true
					end
					return false
				end,
				onUp = function()
					if i ~= 1 then
						return false
					end
					local page = currentPage()
					local prevPage = Models.flipPage(page.page, page.pages, "Up")
					if prevPage then
						showPage(prevPage, pageSize)
						return true
					end
					return false
				end,
			})
		end
		-- the page line: dots / status in the middle, PREV and NEXT for mouse and touch at the sides
		-- (40 design px tall on Wide; 80 design px = 46 px on phones)
		local listBottom = 0.067 + (pageSize - 1) * rowStep + rowHeight
		local lineY = listBottom + 0.008
		local lineHeight = if phone then 0.095 else 0.05
		local buttonWidth = if phone then 0.2 else 0.12
		dotsLabel = Common.text("", 18, {
			Name = "Dots",
			Font = T.BlackFont,
			TextColor3 = T.Dim,
			TextXAlignment = Enum.TextXAlignment.Center,
			Position = UDim2.fromScale(0.019 + buttonWidth + 0.01, lineY),
			Size = UDim2.fromScale(0.962 - 2 * (buttonWidth + 0.01), lineHeight),
			Parent = list,
		})
		table.clear(pageButtons)
		for _, dir in { "Up", "Down" } do
			local button = make("TextButton", {
				Name = if dir == "Up" then "Prev" else "Next",
				BackgroundColor3 = T.Raised,
				BorderSizePixel = 0,
				AutoButtonColor = true,
				Text = if dir == "Up" then "< PREV" else "NEXT >",
				Font = T.BlackFont,
				TextColor3 = T.Text,
				Position = UDim2.fromScale(if dir == "Up" then 0.019 else 0.981 - buttonWidth, lineY),
				Size = UDim2.fromScale(buttonWidth, lineHeight),
				Visible = false,
				Parent = list,
			})
			Layout.bindText(button, 18)
			Common.stroke(button, T.Stroke, 2)
			button.Activated:Connect(function()
				Sound.play("MenuConfirm", 0.5)
				tapPage(dir)
			end)
			pageButtons[dir] = button
		end
		emptyLabel = Common.text("", 24, {
			Name = "Empty",
			TextColor3 = T.Muted,
			TextXAlignment = Enum.TextXAlignment.Center,
			Position = UDim2.fromScale(0.05, 0.3),
			Size = UDim2.fromScale(0.9, 0.1),
			Visible = false,
			Parent = list,
		})
		pinned = buildRow(list, columns, {
			name = "You",
			color = T.Raised,
			rankSize = 34,
			position = UDim2.fromScale(0.019, if phone then 0.86 else 0.913),
			size = UDim2.fromScale(0.962, if phone then 0.11 else 0.0746),
		})
		Common.gradient(pinned.frame, T.RedDark, T.Raised, 0).Transparency = NumberSequence.new(0.35, 0.6)
		Common.fill(T.Red, { Name = "Bar", Size = UDim2.fromScale(0.006, 1), Parent = pinned.frame })
		pinned.frame.Visible = false

		card = buildCard(canvas, cardPos, cardSize, phone)
		renderAll()
		-- the tab bars show the current choice
		selectMode(state.mode)
		selectScope(state.scope)
	end
	rewireTop = Common.linkTop(host, function()
		return { rowParts[1] and rowParts[1].frame }
	end)
	build()
	Common.onModeChange(root, function()
		build()
		rewireTop()
		host.refresh()
	end)

	local inst
	inst = {
		root = root,
		chrome = { playerCard = false, partyBar = false, hints = "Left" },
		show = function(params)
			shown = true
			-- the shell re-shows the screen with its last params after every match: a deep link applies
			-- once, so a tab you switched to afterwards stays
			if params ~= lastParams then
				lastParams = params
				if type(params) == "table" and (params.mode == "1v1" or params.mode == "2v2") then
					state.mode = params.mode
					state.season = nil
					state.page = 1
					selectMode(params.mode)
				end
			end
			bag.add(ClientState.ProfileChanged:Connect(renderAll))
			fetch()
			rewireTop()
			showToken += 1
			local token = showToken
			task.spawn(function()
				-- the season countdown
				while shown and showToken == token do
					task.wait(60)
					if shown and showToken == token then
						renderSeason()
					end
				end
			end)
		end,
		hide = function()
			shown = false
			bag.clear()
		end,
		defaultFocus = function()
			local visible = visibleRows()
			return visible[1]
		end,
		actions = {
			L1 = function()
				chooseMode(otherMode())
			end,
			R1 = function()
				chooseMode(otherMode())
			end,
			L2 = function()
				chooseScope(otherScope())
			end,
			R2 = function()
				chooseScope(otherScope())
			end,
			Y = jumpToMe,
			X = cycleSeason,
		},
		hints = function()
			local items = {
				{ action = "Back", label = "BACK" },
				{ action = "L1", label = "" },
				{
					action = "R1",
					label = "1V1 / 2V2",
					onClick = function()
						chooseMode(otherMode())
					end,
				},
				{ action = "L2", label = "" },
				{
					action = "R2",
					label = "GLOBAL / FRIENDS",
					onClick = function()
						chooseScope(otherScope())
					end,
				},
				{ action = "Y", label = "JUMP TO ME", onClick = jumpToMe },
			}
			if seasonCount > 1 then
				table.insert(items, { action = "X", label = "SEASON", onClick = cycleSeason })
			end
			return items
		end,
	}
	return inst
end

return Screen
