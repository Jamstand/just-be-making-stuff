--[[
    Your stats (the menus' PROFILE screen, menus design 5.8): a header
    (headshot, name, level and XP bar, coins), last season's badge
    ("SEASON 1 · GOLD 1v1 · SILVER 2v2" with tier badges), one card per
    ranked mode (tier, rating, peak, this season's W-L, placements) and
    the lifetime totals.

    ProfilePanel.mount(parent, host) builds it as a menu screen
    (Screens/Profile). It is read-only: its scrolling body is the one
    focus stop (no highlight, no hover) and Up / Down scroll it 80 design
    px per press. At the top, Up goes on to the queue banner's CANCEL
    while you are queued. (Focus only calls a layer's onDirection from a
    focused object, so a screen with nothing focusable would never get
    it.) The badge row shows only when you have a SeasonBadge.
    ProfilePanel.create(gui, close) is the old window around it, kept
    while LobbyUI exists.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = require(Shared.Util)

local UIKit = require(script.Parent.UIKit)
local ClientState = require(script.Parent.Parent.ClientState)
local Common = require(script.Parent.Screens.Common)
local Models = require(script.Parent.Screens.Models)

local T = UIKit.Theme
local make = UIKit.make

local ProfilePanel = {}

local STATS = {
	{ key = "Matches", label = "MATCHES" },
	{ key = "Wins", label = "WINS" },
	{ key = "WinRate", label = "WIN RATE" },
	{ key = "KOs", label = "KOS" },
	{ key = "Falls", label = "FALLS" },
	{ key = "DamageDealt", label = "DAMAGE DEALT" },
}

local PHONE_HEIGHT = 1300
local SCROLL_STEP = 80 -- design px per Up / Down press

local function rankCard(parent, title, position, size)
	local panel, body =
		Common.cutPanel({ name = title, title = title, position = position, size = size, parent = parent })
	local card = { panel = panel }
	card.badge = Common.tierBadge("Tin", {
		anchor = Vector2.new(0, 0.5),
		position = UDim2.fromScale(0.04, 0.42),
		size = UDim2.fromScale(0.2, 0.6),
		parent = body,
	})
	card.tier = Common.text("", 56, {
		Font = T.HeadFont,
		Position = UDim2.fromScale(0.27, 0.08),
		Size = UDim2.fromScale(0.45, 0.32),
		TextWrapped = false,
		Parent = body,
	})
	card.rating = Common.text("", 56, {
		Font = T.LogoFont,
		Position = UDim2.fromScale(0.27, 0.4),
		Size = UDim2.fromScale(0.4, 0.3),
		TextWrapped = false,
		Parent = body,
	})
	card.peak = Common.text("", 20, {
		Font = T.BlackFont,
		TextColor3 = T.Muted,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.fromScale(0.6, 0.12),
		Size = UDim2.fromScale(0.36, 0.2),
		TextWrapped = false,
		Parent = body,
	})
	card.season = Common.text("", 22, {
		Font = T.BoldFont,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.fromScale(0.5, 0.42),
		Size = UDim2.fromScale(0.46, 0.22),
		TextWrapped = false,
		Parent = body,
	})
	card.note = Common.text("", 20, {
		TextColor3 = T.Muted,
		Position = UDim2.fromScale(0.04, 0.76),
		Size = UDim2.fromScale(0.92, 0.2),
		TextWrapped = false,
		Parent = body,
	})
	return card
end

local function renderRank(card, profile, mode)
	local view = Models.profileRank(profile, mode)
	Common.setTierBadge(card.badge, view.tierName)
	card.tier.Text = view.tier
	card.tier.TextColor3 = view.tierColor
	card.rating.Text = view.rating
	card.peak.Text = view.peak
	card.season.Text = view.season
	card.note.Text = view.note
end

-- Builds the profile as a menu screen inside `parent`. Returns the ScreenInstance (menus design 3.8).
function ProfilePanel.mount(parent, host)
	local root = Common.root({ content = parent }, "Profile")
	local sizer = Common.sizer(root)
	local bag = Common.bag()
	local player = Players.LocalPlayer

	local canvas, scroller
	local parts: { [string]: any } = {}

	local function render(profile)
		if not parts.name then
			return
		end
		parts.name.Text = player.DisplayName
		if not profile then
			parts.level.Text = "Loading..."
			return
		end
		parts.level.Text = string.format("LV %d", profile.Level)
		parts.xpText.Text = if profile.XPForNext > 0
			then string.format("%s / %s XP", Util.formatNumber(profile.XPInLevel), Util.formatNumber(profile.XPForNext))
			else "MAX LEVEL"
		parts.setXP(if profile.XPForNext > 0 then profile.XPInLevel / profile.XPForNext else 1)
		parts.coins.Text = Util.formatNumber(profile.Coins)
		parts.saving.Text = if profile.Saving
			then "Progress saves automatically."
			else "Progress isn't saving right now (Studio without API access, or a DataStore outage)."

		-- the badge row only when there is a badge; the cards and stats move up into its place otherwise
		local badgeText = Models.seasonBadgeText(profile.SeasonBadge)
		parts.badgeRow.Visible = badgeText ~= nil
		parts.badgeText.Text = badgeText or ""
		local shift = if badgeText then 0 else parts.badgeShift
		for _, entry in parts.shifted do
			local base = entry.base
			entry.obj.Position = UDim2.new(base.X, UDim.new(base.Y.Scale - shift, base.Y.Offset))
		end
		local tiers = Models.seasonBadgeTiers(profile.SeasonBadge)
		for i, box in parts.badges do
			local entry = tiers[i]
			box.Visible = entry ~= nil
			if entry then
				Common.setTierBadge(box, entry.tier)
			end
		end

		renderRank(parts.rank1, profile, "1v1")
		renderRank(parts.rank2, profile, "2v2")

		local decided = profile.Wins + profile.Losses
		local values = {
			Matches = Util.formatNumber(profile.Matches),
			Wins = Util.formatNumber(profile.Wins),
			WinRate = if decided > 0
				then string.format("%d%%", math.floor(profile.Wins / decided * 100 + 0.5))
				else "—",
			KOs = Util.formatNumber(profile.KOs),
			Falls = Util.formatNumber(profile.Falls),
			DamageDealt = Util.formatNumber(profile.DamageDealt),
		}
		for key, label in parts.stats do
			label.Text = values[key]
		end
	end

	local function build()
		if scroller then
			scroller:Destroy()
		end
		local phone = Common.isPhone()
		canvas, scroller = Common.body(root, sizer, { scroll = true, phoneHeight = PHONE_HEIGHT })
		table.clear(parts)

		-- header: headshot, name, level + XP, coins
		local _, header = Common.cutPanel({
			name = "Header",
			position = UDim2.fromScale(0, 0),
			size = UDim2.fromScale(1, if phone then 0.2 else 0.24),
			parent = canvas,
		})
		local headshot = make("ImageLabel", {
			Name = "Headshot",
			BackgroundColor3 = T.PanelLight,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.fromScale(0.01, 0.5),
			Size = UDim2.fromScale(0.3, 0.86),
			Parent = header,
		})
		make("UIAspectRatioConstraint", { AspectRatio = 1, Parent = headshot })
		Common.headshot(headshot, player.UserId)
		parts.name = Common.text(player.DisplayName, 44, {
			Font = T.BlackFont,
			Position = UDim2.fromScale(0.1, 0.06),
			Size = UDim2.fromScale(0.55, 0.36),
			TextWrapped = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = header,
		})
		parts.level = Common.text("", 24, {
			Font = T.BlackFont,
			TextColor3 = T.XP,
			Position = UDim2.fromScale(0.1, 0.46),
			Size = UDim2.fromScale(0.08, 0.2),
			TextWrapped = false,
			Parent = header,
		})
		local _, setXP = UIKit.progressBar({
			name = "XP",
			fill = T.XP,
			back = T.Backdrop,
			position = UDim2.fromScale(0.19, 0.5),
			size = UDim2.fromScale(0.3, 0.12),
			parent = header,
		})
		parts.setXP = setXP
		parts.xpText = Common.text("", 20, {
			Font = T.BoldFont,
			TextColor3 = T.Muted,
			Position = UDim2.fromScale(0.5, 0.46),
			Size = UDim2.fromScale(0.2, 0.2),
			TextWrapped = false,
			Parent = header,
		})
		parts.saving = Common.text("", 18, {
			TextColor3 = T.Muted,
			Position = UDim2.fromScale(0.1, 0.72),
			Size = UDim2.fromScale(0.6, 0.2),
			TextWrapped = false,
			Parent = header,
		})
		local coinIcon = Common.fill(T.Gold, {
			Name = "Coin",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.fromScale(0.8, 0.32),
			Size = UDim2.fromScale(0.04, 0.3),
			Parent = header,
		})
		make("UIAspectRatioConstraint", { AspectRatio = 1, Parent = coinIcon })
		make("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = coinIcon })
		parts.coins = Common.text("", 44, {
			Font = T.LogoFont,
			TextColor3 = T.Gold,
			Position = UDim2.fromScale(0.81, 0.12),
			Size = UDim2.fromScale(0.18, 0.4),
			TextWrapped = false,
			Parent = header,
		})

		-- last season's badge
		local badgeY = if phone then 0.22 else 0.27
		local badgeHeight = if phone then 0.07 else 0.1
		local badgeRow = Common.fill(T.Raised, {
			Name = "SeasonBadge",
			Position = UDim2.fromScale(0, badgeY),
			Size = UDim2.fromScale(1, badgeHeight),
			Visible = false,
			Parent = canvas,
		})
		parts.badgeRow = badgeRow
		Common.fill(T.Gold, { Size = UDim2.fromScale(0.005, 1), Parent = badgeRow })
		parts.badges = {}
		for i = 1, 2 do
			parts.badges[i] = Common.tierBadge("Tin", {
				anchor = Vector2.new(0, 0.5),
				position = UDim2.fromScale(0.015 + (i - 1) * 0.04, 0.5),
				size = UDim2.fromScale(0.04, 0.75),
				parent = badgeRow,
			})
		end
		parts.badgeText = Common.text("", 34, {
			Font = T.HeadFont,
			Position = UDim2.fromScale(0.11, 0),
			Size = UDim2.fromScale(0.88, 1),
			TextWrapped = false,
			Parent = badgeRow,
		})

		-- one card per ranked mode
		local ranksY = if phone then 0.31 else 0.4
		parts.badgeShift = ranksY - badgeY -- how far everything below moves up without a badge
		if phone then
			parts.rank1 = rankCard(canvas, "RANKED 1V1", UDim2.fromScale(0, ranksY), UDim2.fromScale(1, 0.16))
			parts.rank2 = rankCard(canvas, "RANKED 2V2", UDim2.fromScale(0, ranksY + 0.17), UDim2.fromScale(1, 0.16))
		else
			parts.rank1 = rankCard(canvas, "RANKED 1V1", UDim2.fromScale(0, ranksY), UDim2.fromScale(0.49, 0.3))
			parts.rank2 = rankCard(canvas, "RANKED 2V2", UDim2.fromScale(0.51, ranksY), UDim2.fromScale(0.49, 0.3))
		end

		-- lifetime totals
		local statsY = if phone then 0.66 else 0.74
		local columns = if phone then 3 else 6
		local cellHeight = if phone then 0.15 else 0.26
		parts.shifted = {}
		for _, card in { parts.rank1, parts.rank2 } do
			table.insert(parts.shifted, { obj = card.panel, base = card.panel.Position })
		end
		parts.stats = {}
		for i, stat in STATS do
			local column = (i - 1) % columns
			local row = math.floor((i - 1) / columns)
			local cell = Common.fill(T.Raised, {
				Name = stat.key,
				Position = UDim2.fromScale(column / columns + 0.003, statsY + row * (cellHeight + 0.015)),
				Size = UDim2.fromScale(1 / columns - 0.006, cellHeight),
				Parent = canvas,
			})
			Common.stroke(cell, T.Stroke, 2)
			table.insert(parts.shifted, { obj = cell, base = cell.Position })
			Common.text(stat.label, 16, {
				Font = T.BlackFont,
				TextColor3 = T.Muted,
				TextXAlignment = Enum.TextXAlignment.Center,
				Position = UDim2.fromScale(0, 0.62),
				Size = UDim2.fromScale(1, 0.3),
				TextWrapped = false,
				Parent = cell,
			})
			parts.stats[stat.key] = Common.text("0", 44, {
				Font = T.LogoFont,
				TextXAlignment = Enum.TextXAlignment.Center,
				Position = UDim2.fromScale(0, 0.08),
				Size = UDim2.fromScale(1, 0.55),
				TextWrapped = false,
				Parent = cell,
			})
		end

		-- the focus stop: the scrolling body itself (see the header)
		Common.focusable(scroller, {
			key = "ProfileBody",
			highlight = false,
			hover = false,
			onUp = function()
				return Common.scrollBy(scroller, -SCROLL_STEP)
			end,
			onDown = function()
				return Common.scrollBy(scroller, SCROLL_STEP)
			end,
		})
		render(ClientState.profile)
	end
	build()

	local rewireTop = Common.linkTop(host, function()
		return { scroller }
	end)
	Common.onModeChange(root, function()
		build()
		rewireTop()
		host.refresh()
	end)

	return {
		root = root,
		show = function()
			bag.add(ClientState.ProfileChanged:Connect(render))
			render(ClientState.profile)
			scroller.CanvasPosition = Vector2.zero
			rewireTop()
		end,
		hide = function()
			bag.clear()
		end,
		defaultFocus = function()
			return scroller
		end,
		-- (kept for a Focus that calls onDirection with nothing focused; the body's onUp / onDown do the work)
		onDirection = function(dir)
			if dir == "Up" then
				return Common.scrollBy(scroller, -SCROLL_STEP)
			elseif dir == "Down" then
				return Common.scrollBy(scroller, SCROLL_STEP)
			end
			return false
		end,
		hints = function()
			return {
				{ action = "Back", label = "BACK" },
			}
		end,
	}
end

-- The old Profile window (LobbyUI). TODO(I): delete once LobbyUI is gone (menus design 5.8).
function ProfilePanel.create(gui, close)
	return Common.legacyWindow(gui, "Profile", close, ProfilePanel.mount)
end

return ProfilePanel
