--[[
    The player card in the menus' top-right corner (menus design 5.7):
    headshot, display name, level chip and XP bar, 1v1 tier and rating,
    coins. While the profile is still loading it shows the name and
    headshot with grey bars and "Loading..." where the numbers go. On
    phones it is one chip (headshot, LV, tier rating, coins).
]]

local Players = game:GetService("Players")

local Client = script.Parent.Parent
local ClientState = require(Client:WaitForChild("ClientState"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))
local Layout = require(script.Parent:WaitForChild("Layout"))
local MenuModels = require(script.Parent:WaitForChild("MenuModels"))

local T = UIKit.Theme
local make = UIKit.make

local PlayerCard = {}

local player = Players.LocalPlayer

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

local function coinIcon(parent, props)
	local coin = make("Frame", {
		Name = "Coin",
		BackgroundColor3 = T.Gold,
		BorderSizePixel = 0,
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		ZIndex = parent.ZIndex + 1,
		Parent = parent,
	})
	for key, value in props do
		coin[key] = value
	end
	make("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = coin })
	make("UIGradient", {
		Color = ColorSequence.new(T.GoldLight, T.GoldDeep),
		Rotation = 90,
		Parent = coin,
	})
	return coin
end

local function headshot(image)
	task.spawn(function()
		local ok, content = pcall(function()
			return Players:GetUserThumbnailAsync(
				player.UserId,
				Enum.ThumbnailType.HeadShot,
				Enum.ThumbnailSize.Size150x150
			)
		end)
		if ok and image.Parent then
			image.Image = content
		end
	end)
end

-- Wide: the cut panel at (0.704, 0.024), 0.276 x 0.11.
local function buildWide(root)
	local panel, body = UIKit.cutPanel({ parent = root, cut = 18, fill = T.Panel, border = T.Stroke })
	panel.ZIndex = root.ZIndex
	local zIndex = body.ZIndex
	local avatar = make("ImageLabel", {
		Name = "Headshot",
		BackgroundColor3 = T.Raised,
		BorderSizePixel = 0,
		Position = UDim2.fromScale(0.035, 0.13),
		Size = UDim2.fromScale(0.74, 0.74),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		ZIndex = zIndex,
		Parent = body,
	})
	headshot(avatar)
	local name = text("Name", body, {
		Text = player.DisplayName,
		Position = UDim2.fromScale(0.31, 0.1),
		Size = UDim2.fromScale(0.66, 0.3),
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, 30)
	local levelHolder = make("Frame", {
		Name = "Level",
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(0.31, 0.47),
		Size = UDim2.fromScale(0.15, 0.2),
		ZIndex = zIndex,
		Parent = body,
	})
	local level = UIKit.tag("LV 1", { parent = levelHolder, fill = T.Raised, size = 16, zIndex = zIndex })
	local barBack, setBar = UIKit.progressBar({
		parent = body,
		fill = T.XP, -- (design 5.7: the XP colour; mockup b drew it gold)
		position = UDim2.fromScale(0.47, 0.535),
		size = UDim2.fromScale(0.37, 0.07),
		zIndex = zIndex,
	})
	local percent = text("Percent", body, {
		Font = T.BoldFont,
		TextColor3 = T.Muted,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.fromScale(0.85, 0.46),
		Size = UDim2.fromScale(0.12, 0.22),
	}, 16)
	local tierHolder = make("Frame", {
		Name = "Tier",
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(0.31, 0.7),
		Size = UDim2.fromScale(0.24, 0.24),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		ZIndex = zIndex,
		Parent = body,
	})
	local tierBadge = nil
	local tierText = text("TierText", body, {
		Position = UDim2.fromScale(0.37, 0.69),
		Size = UDim2.fromScale(0.3, 0.26),
		TextColor3 = T.Gold,
	}, 20)
	local coin = coinIcon(body, {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(0.73, 0.82),
		Size = UDim2.fromScale(0.22, 0.22),
	})
	local coins = text("Coins", body, {
		Font = T.LogoFont,
		TextColor3 = T.Gold,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(0.97, 0.82),
		Size = UDim2.fromScale(0.23, 0.3),
	}, 34)

	local lastTier = nil
	return function(view)
		name.Text = player.DisplayName
		if not view then
			level.Content.Text.Text = "LV"
			setBar(0)
			barBack.BackgroundColor3 = T.Raised
			percent.Text = ""
			tierText.Text = "Loading..."
			tierText.TextColor3 = T.Dim
			coins.Text = ""
			coin.Visible = false
			return
		end
		level.Content.Text.Text = view.level
		barBack.BackgroundColor3 = T.Backdrop
		setBar(view.xpFraction)
		percent.Text = view.xpPercent
		tierText.Text = view.tierUpper .. "  " .. view.rating
		tierText.TextColor3 = view.tierColor
		coins.Text = view.coins
		coin.Visible = true
		if view.tier ~= lastTier then
			lastTier = view.tier
			if tierBadge then
				tierBadge:Destroy()
			end
			tierBadge = UIKit.tierBadge(view.tier, { parent = tierHolder, zIndex = zIndex })
		end
	end
end

-- Phone: one chip (headshot, LV, tier rating, coins).
local function buildPhone(root)
	local chip = UIKit.slantFrame({ parent = root, fill = T.Panel, outline = 3 })
	local content = chip.Content
	local zIndex = content.ZIndex
	local avatar = make("ImageLabel", {
		Name = "Headshot",
		BackgroundColor3 = T.Raised,
		BorderSizePixel = 0,
		Position = UDim2.fromScale(0, 0.1),
		Size = UDim2.fromScale(0.8, 0.8),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		ZIndex = zIndex + 1,
		Parent = content,
	})
	headshot(avatar)
	local row = make("Frame", {
		Name = "Row",
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(0.2, 0),
		Size = UDim2.fromScale(0.8, 1),
		ZIndex = zIndex + 1,
		Parent = content,
	})
	Layout.bindListPadding(
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = row,
		}),
		10
	)
	local function part(name, order, props, size)
		local label = text(name, row, props, size)
		label.AutomaticSize = Enum.AutomaticSize.X
		label.Size = UDim2.fromScale(0, 0.8)
		label.LayoutOrder = order
		return label
	end
	local level = part("Level", 1, {}, 22)
	local tierHolder = make("Frame", {
		Name = "Tier",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(0.62, 0.62),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		LayoutOrder = 2,
		ZIndex = zIndex + 1,
		Parent = row,
	})
	local rating = part("Rating", 3, { TextColor3 = T.Gold }, 22)
	coinIcon(row, { Size = UDim2.fromScale(0.55, 0.55), LayoutOrder = 4 })
	local coins = part("Coins", 5, { Font = T.LogoFont, TextColor3 = T.Gold }, 24)
	local tierBadge, lastTier = nil, nil
	return function(view)
		if not view then
			level.Text = "Loading..."
			rating.Text = ""
			coins.Text = ""
			return
		end
		level.Text = view.level
		rating.Text = view.rating
		rating.TextColor3 = view.tierColor
		coins.Text = view.coins
		if view.tier ~= lastTier then
			lastTier = view.tier
			if tierBadge then
				tierBadge:Destroy()
			end
			tierBadge = UIKit.tierBadge(view.tier, { parent = tierHolder, zIndex = zIndex + 1 })
		end
	end
end

-- Returns { root, setVisible(on) }; rebuilds itself when the layout switches between Wide and Phone.
function PlayerCard.new(canvas)
	local root = make("Frame", {
		Name = "PlayerCard",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		ZIndex = 12,
		Parent = canvas,
	})
	local render = nil
	local wanted = true

	local function build()
		for _, child in root:GetChildren() do
			child:Destroy()
		end
		if Layout.mode() == "Phone" then
			local x, y, w, h = Layout.phoneRect(583, 9, 207, 32)
			root.Size = UDim2.fromScale(w, h)
			Layout.clearTop(root, UDim2.fromScale(x + w, y))
			render = buildPhone(root)
		else
			root.Size = UDim2.fromScale(0.276, 0.11)
			Layout.clearTop(root, UDim2.fromScale(0.98, 0.024))
			render = buildWide(root)
		end
		render(MenuModels.playerCard(ClientState.profile))
	end

	build()
	ClientState.ProfileChanged:Connect(function(profile)
		render(MenuModels.playerCard(profile))
	end)
	Layout.Changed:Connect(build)

	return {
		root = root,
		setVisible = function(on)
			wanted = on
			root.Visible = wanted
		end,
	}
end

return PlayerCard
