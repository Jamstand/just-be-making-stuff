--[[
    Cosmetic shop: weapon colors, trails, KO effects and titles, bought
    with coins earned from matches.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Cosmetics = require(Shared.Cosmetics)
local Util = require(Shared.Util)
local Net = require(Shared.Net)

local UIKit = require(script.Parent.UIKit)
local ClientState = require(script.Parent.Parent.ClientState)

local T = UIKit.Theme
local make = UIKit.make

local ShopPanel = {}

local function swatch(item)
	local frame = make("Frame", {
		BackgroundColor3 = T.PanelLight,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 56),
	}, { UIKit.corner(10) })
	if item.Category == "WeaponColor" then
		frame.BackgroundColor3 = item.Primary
		make("Frame", {
			BackgroundColor3 = item.Secondary,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.fromScale(1, 1),
			Size = UDim2.fromScale(0.3, 0.45),
			Parent = frame,
		}, { UIKit.corner(8) })
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
			UIKit.heading(item.Style, 18, {
				Size = UDim2.fromScale(1, 1),
				TextXAlignment = Enum.TextXAlignment.Center,
				TextColor3 = Color3.fromRGB(30, 30, 50),
				Parent = frame,
			})
		end
	elseif item.Category == "Title" then
		UIKit.heading(item.Name, 20, {
			Size = UDim2.fromScale(1, 1),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextColor3 = Color3.fromRGB(255, 225, 140),
			Parent = frame,
		})
	end
	return frame
end

function ShopPanel.create(gui, close)
	local window, body = UIKit.window(gui, "Shop", close)
	local category = Cosmetics.Categories[1]

	local tabs = {}
	for _, id in Cosmetics.Categories do
		table.insert(tabs, { id = id, label = Cosmetics.CategoryNames[id] })
	end

	local grid = UIKit.scroll({
		Position = UDim2.fromOffset(0, 48),
		Size = UDim2.new(1, 0, 1, -48),
		Parent = body,
	})
	make("UIGridLayout", {
		CellSize = UDim2.fromOffset(196, 150),
		CellPadding = UDim2.fromOffset(10, 10),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = grid,
	})

	local function render()
		for _, child in grid:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
		local profile = ClientState.profile
		for i, item in Cosmetics.inCategory(category) do
			local owned = profile and profile.Owned[item.Id]
			local equipped = profile and profile.Equipped[item.Category] == item.Id
			local cardFrame = UIKit.panel({ LayoutOrder = i, BackgroundColor3 = T.Panel, Parent = grid })
			UIKit.padding(10, 8).Parent = cardFrame
			UIKit.list(Enum.FillDirection.Vertical, 6).Parent = cardFrame
			local sw = swatch(item)
			sw.LayoutOrder = 1
			sw.Parent = cardFrame
			UIKit.heading(item.Name, 17, { LayoutOrder = 2, Size = UDim2.new(1, 0, 0, 20), Parent = cardFrame })
			local text, style
			if equipped then
				text, style = "Equipped", "ghost"
			elseif owned then
				text, style = "Equip", "secondary"
			else
				text, style = Util.formatNumber(item.Price) .. " coins", "primary"
			end
			local button = UIKit.button(text, style, function()
				local action = owned and "Equip" or "Buy"
				local ok, message = Net.get("ShopRequest"):InvokeServer(action, item.Id)
				ClientState.toast(message or "", ok and "good" or "error")
			end, { LayoutOrder = 3, Size = UDim2.new(1, 0, 0, 34), TextSize = 16, Parent = cardFrame })
			if equipped then
				UIKit.setEnabled(button, false)
			elseif not owned and profile and profile.Coins < item.Price then
				button.BackgroundTransparency = 0.4
			end
		end
	end

	local tabBar, selectTab = UIKit.tabs(tabs, function(id)
		category = id
		render()
	end)
	tabBar.Parent = body

	ClientState.ProfileChanged:Connect(function()
		if window.Visible then
			render()
		end
	end)

	return {
		window = window,
		open = function()
			window.Visible = true
			selectTab(category)
		end,
		close = function()
			window.Visible = false
		end,
	}
end

return ShopPanel
