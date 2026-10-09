--[[
    Cosmetic shop (the menus' STORE screen, menus design 5.8): weapon
    colors, trails, KO effects and titles, bought with coins earned from
    matches.

    ShopPanel.mount(parent, host) builds it as a menu screen
    (Screens/Store): category tabs (L1/R1) over a grid of item cards. The
    cards are built once, keyed by item id, and updated in place when your
    profile changes. Confirm (or a click / tap) on an item you own equips
    it; on one you don't, it asks first (UIKit.dialog "Buy for <price>
    coins?"), since coins spent can't come back. Prices are in Gold.
    ShopPanel.create(gui, close) is the old window around it, kept while
    LobbyUI exists.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Cosmetics = require(Shared.Cosmetics)

local UIKit = require(script.Parent.UIKit)
local Focus = require(script.Parent.Focus)
local Layout = require(script.Parent.Layout)
local ClientState = require(script.Parent.Parent.ClientState)
local Common = require(script.Parent.Screens.Common)
local Models = require(script.Parent.Screens.Models)

local T = UIKit.Theme
local make = UIKit.make

local ShopPanel = {}

local CARD_HEIGHT = 270 -- design px
local CARD_GAP = 14
local PHONE_TABS = 80 -- the phone tab bar, design px (46 px on a 390 px phone)

-- The item's look: colours for weapon colors, a gradient for trails and KO effects, the text for titles.
local function swatch(item, parent)
	local frame = Common.fill(T.PanelLight, {
		Name = "Swatch",
		Size = UDim2.fromScale(1, 0.56),
		ClipsDescendants = true,
		Parent = parent,
	})
	if item.Category == "WeaponColor" then
		frame.BackgroundColor3 = item.Primary
		Common.fill(item.Secondary, {
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.fromScale(1, 1),
			Size = UDim2.fromScale(0.3, 0.45),
			Parent = frame,
		})
	elseif item.Category == "Trail" or item.Category == "KOEffect" then
		local colors = item.Colors or (item.Color and { item.Color, item.Color:Lerp(Color3.new(1, 1, 1), 0.5) })
		if colors then
			frame.BackgroundColor3 = Color3.new(1, 1, 1)
			local keypoints = {}
			for i, color in colors do
				table.insert(keypoints, ColorSequenceKeypoint.new(#colors == 1 and 0 or (i - 1) / (#colors - 1), color))
			end
			if #keypoints == 1 then
				table.insert(keypoints, ColorSequenceKeypoint.new(1, colors[1]))
			end
			make("UIGradient", { Color = ColorSequence.new(keypoints), Parent = frame })
		end
		if item.Style then
			Common.text(item.Style, 30, {
				Font = T.HeadFont,
				TextXAlignment = Enum.TextXAlignment.Center,
				TextColor3 = Color3.fromRGB(30, 30, 50),
				TextWrapped = false,
				Parent = frame,
			})
		end
	elseif item.Category == "Title" then
		Common.text(item.Name, 34, {
			Font = T.HeadFont,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextColor3 = Color3.fromRGB(255, 225, 140),
			TextWrapped = false,
			Parent = frame,
		})
	end
	return frame
end

-- Builds the shop as a menu screen inside `parent`. Returns the ScreenInstance (menus design 3.8).
function ShopPanel.mount(parent, host)
	local root = Common.root({ content = parent }, "Store")
	local sizer = Common.sizer(root)
	local bag = Common.bag()

	local category = Cosmetics.Categories[1]
	local container, grid, gridLayout, selectTab
	local cards = {} -- [itemId] = card parts
	local columns = 5
	local closeDialog = nil -- the open "Buy ...?" dialog's close()

	local function request(action, item)
		local ok, message = Common.invoke("ShopRequest", action, item.Id)
		host.toast(message or (if ok then "Done." else "Couldn't do that."), ok and "good" or "error")
	end

	local function buy(item)
		local view = Models.shopItem(item, ClientState.profile)
		if view.state == "Equipped" then
			host.toast(item.Name .. " is equipped.", "info")
			return
		elseif view.state == "Owned" then
			request("Equip", item)
			return
		elseif not view.affordable then
			host.toast("You need " .. view.label .. " coins for " .. item.Name .. ".", "error")
			return
		end
		if closeDialog then
			return
		end
		closeDialog = UIKit.dialog({
			title = string.upper(item.Name),
			body = "Buy " .. item.Name .. " for " .. view.label .. " coins?",
			confirm = "BUY",
			cancel = "CANCEL",
			onConfirm = function()
				closeDialog = nil
				request("Buy", item)
			end,
			onCancel = function()
				closeDialog = nil
			end,
		})
	end

	local rewireTop = function() end
	local setCategory

	local function visibleCards()
		local out = {}
		for i, item in Cosmetics.inCategory(category) do
			local c = cards[item.Id]
			if c then
				out[i] = c.button
			end
		end
		return out
	end

	local function linkCards()
		local list = visibleCards()
		local rows = {}
		for i, button in list do
			local r = math.floor((i - 1) / columns) + 1
			rows[r] = rows[r] or {}
			table.insert(rows[r], button)
		end
		Focus.linkGrid(rows)
	end

	local function renderCard(c)
		local view = Models.shopItem(c.item, ClientState.profile)
		c.price.Text = view.label
		c.coin.Visible = view.state == "Buy"
		c.price.Position = UDim2.fromScale(if view.state == "Buy" then 0.2 else 0.06, 0.8)
		if view.state == "Equipped" then
			c.price.TextColor3 = T.Good
		elseif view.state == "Owned" then
			c.price.TextColor3 = T.Muted
		else
			c.price.TextColor3 = T.Gold
		end
		c.price.TextTransparency = if view.state == "Buy" and not view.affordable then 0.45 else 0
		c.equipped.Visible = view.state == "Equipped"
	end

	local function render()
		for _, c in cards do
			c.button.Visible = c.item.Category == category
			if c.button.Visible then
				renderCard(c)
			end
		end
		linkCards()
		-- linkGrid cleared the top row's Up link to CANCEL
		rewireTop()
	end

	function setCategory(id)
		if id == category then
			return
		end
		category = id
		render()
	end

	local function buildCard(item, order)
		local button = make("TextButton", {
			Name = item.Id,
			AutoButtonColor = false,
			Text = "",
			BackgroundColor3 = T.Raised,
			BorderSizePixel = 0,
			LayoutOrder = order,
			Parent = grid,
		})
		Common.stroke(button, T.Stroke, 2)
		swatch(item, button)
		Common.text(item.Name, 30, {
			Name = "ItemName",
			Font = T.HeadFont,
			Position = UDim2.fromScale(0.06, 0.6),
			Size = UDim2.fromScale(0.88, 0.17),
			TextWrapped = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = button,
		})
		local coin = Common.fill(T.Gold, {
			Name = "Coin",
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.fromScale(0.06, 0.885),
			Size = UDim2.fromScale(0.1, 0.1),
			Parent = button,
		})
		make("UIAspectRatioConstraint", { AspectRatio = 1, Parent = coin })
		make("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = coin })
		local price = Common.text("", 30, {
			Name = "Price",
			Font = T.LogoFont,
			TextColor3 = T.Gold,
			Position = UDim2.fromScale(0.2, 0.8),
			Size = UDim2.fromScale(0.74, 0.17),
			TextWrapped = false,
			Parent = button,
		})
		local equipped = Common.tag("EQUIPPED", {
			name = "EquippedTag",
			anchor = Vector2.new(1, 0),
			position = UDim2.fromScale(0.97, 0.04),
			size = UDim2.fromScale(0.5, 0.1),
			fill = T.Good,
			textColor = T.Backdrop,
			zIndex = 3,
			parent = button,
		})
		cards[item.Id] = { item = item, button = button, price = price, coin = coin, equipped = equipped }
		Common.focusable(button, { key = "Shop" .. item.Id }, function()
			buy(item)
		end)
	end

	-- the grid's cells in px (re-applied when the safe area changes); on phones the grid starts below the tabs
	local function applyCells()
		if gridLayout and gridLayout.Parent then
			local gap = Layout.px(CARD_GAP)
			gridLayout.CellPadding = UDim2.fromOffset(gap, gap)
			gridLayout.CellSize = UDim2.new(1 / columns, -gap, 0, Layout.px(CARD_HEIGHT))
		end
		if grid and grid.Parent and Common.isPhone() then
			local below = Layout.px(PHONE_TABS + 10)
			grid.Position = UDim2.fromOffset(0, below)
			grid.Size = UDim2.new(1, 0, 1, -below)
		end
	end

	local function build()
		if container then
			container:Destroy()
		end
		table.clear(cards)
		local phone = Common.isPhone()
		columns = if phone then 3 else 5
		container = Common.region(root)
		local tabs = {}
		for _, id in Cosmetics.Categories do
			table.insert(tabs, { id = id, label = string.upper(Cosmetics.CategoryNames[id]) })
		end
		-- (phone: the grid is the scrolling list, so the body itself doesn't scroll; nested scrolling frames
		-- would trap touch drags)
		local tabBar, selectFromBar = UIKit.tabBar(tabs, {
			name = "Categories",
			style = "big",
			position = UDim2.fromScale(0, 0),
			size = UDim2.fromScale(if phone then 1 else 0.7, if phone then 0.12 else 0.08),
			parent = container,
			onSelect = setCategory,
		})
		selectTab = selectFromBar
		if phone then
			-- tabs at least 44 px tall
			sizer.height(tabBar, PHONE_TABS, UDim.new(1, 0))
		end
		local top = if phone then 0.15 else 0.11
		grid = make("ScrollingFrame", {
			Name = "Grid",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Position = UDim2.fromScale(0, top),
			Size = UDim2.fromScale(1, 1 - top),
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			ScrollBarThickness = 6,
			ScrollBarImageColor3 = T.Dim,
			Selectable = false,
			Parent = container,
		})
		gridLayout = make("UIGridLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = grid,
		})
		applyCells()
		local order = 0
		for _, id in Cosmetics.Categories do
			for _, item in Cosmetics.inCategory(id) do
				order += 1
				buildCard(item, order)
			end
		end
		render()
		selectFromBar(category)
	end
	build()
	sizer.watch(applyCells)

	rewireTop = Common.linkTop(host, function()
		local list = visibleCards()
		local top = {}
		for i = 1, math.min(columns, #list) do
			table.insert(top, list[i])
		end
		return top
	end)
	Common.onModeChange(root, function()
		build()
		rewireTop()
		host.refresh()
	end)

	local function cycle(delta)
		local index = table.find(Cosmetics.Categories, category) or 1
		local id = Cosmetics.Categories[(index - 1 + delta) % #Cosmetics.Categories + 1]
		setCategory(id)
		selectTab(id)
		local first = visibleCards()[1]
		if first then
			Focus.set(first)
		end
	end

	return {
		root = root,
		show = function()
			bag.add(ClientState.ProfileChanged:Connect(render))
			render()
			rewireTop()
		end,
		hide = function()
			bag.clear()
			if closeDialog then
				closeDialog()
				closeDialog = nil
			end
		end,
		defaultFocus = function()
			return visibleCards()[1]
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
				{ action = "Confirm", label = "BUY / EQUIP" },
				{ action = "L1", label = "" },
				{
					action = "R1",
					label = "CATEGORY",
					onClick = function()
						cycle(1)
					end,
				},
				{ action = "Back", label = "BACK" },
			}
		end,
	}
end

-- The old Shop window (LobbyUI). TODO(I): delete once LobbyUI is gone (menus design 5.8).
function ShopPanel.create(gui, close)
	return Common.legacyWindow(gui, "Shop", close, ShopPanel.mount)
end

return ShopPanel
