--[[
    Legend select for the menus' LEGENDS screen (menus design 5.8): a 4x2
    grid of legend tiles (still portraits, the current one tagged
    SELECTED) on the left, the legend in 3D (LegendView, animated) in the
    middle, and its name, title, stats as pips, weapons, signature moves,
    ultimate, the "Use my avatar's look" toggle (Y) and SELECT on the right.
    "My Avatar" previews your own avatar.

    Moving over a tile previews it; Confirm (or a click on the previewed
    tile, a second tap on touch) or SELECT saves it with SelectLegend: it
    is your legend from the next match on, and you can still pick another
    one before each match. "Use my avatar's look" (the FightAsAvatar
    setting) fights with the legend's moves, stats and weapons in your own
    avatar's look; the preview shows that look.

    The signature heavies get their own panel under the grid (Wide): with
    the name at 100 px the info column has no room for them.

    FightersPanel.mount(parent, host) builds it as a menu screen
    (Screens/Legends). It opens on your current legend, or on params
    { legend } the first time a deep link brings them (the shell re-shows
    a screen with its last params after every match), and focuses that
    tile, so the tile Focus remembers from the last visit can't win. The
    3D view is created in show and destroyed in hide.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Legends = require(Shared.Legends)
local Weapons = require(Shared.Weapons)

local UIKit = require(script.Parent.UIKit)
local Focus = require(script.Parent.Focus)
local LegendView = require(script.Parent.LegendView)
local ClientState = require(script.Parent.Parent.ClientState)
local Settings = require(script.Parent.Parent.Controllers.Settings)
local Common = require(script.Parent.Screens.Common)

local T = UIKit.Theme
local make = UIKit.make

local FightersPanel = {}

local STAT_COLORS = {
	Strength = Color3.fromRGB(255, 120, 90),
	Dexterity = Color3.fromRGB(110, 210, 255),
	Defense = Color3.fromRGB(150, 220, 120),
	Speed = Color3.fromRGB(255, 210, 90),
}

local COLUMNS = 4
local PHONE_HEIGHT = 1500

-- Wide layout (fractions of the canvas) and phone layout (fractions of the scrolling canvas).
local WIDE = {
	grid = { x = 0.03, y = 0.21, w = 0.37, h = 0.33 },
	signatures = { x = 0.03, y = 0.57, w = 0.37, h = 0.29 },
	view = { x = 0.4, y = 0.15, w = 0.24, h = 0.74 },
	info = { x = 0.645, y = 0.2, w = 0.325, h = 0.67 },
}
local PHONE = {
	grid = { x = 0, y = 0, w = 0.55, h = 0.22 },
	view = { x = 0.56, y = 0, w = 0.44, h = 0.32 },
	info = { x = 0, y = 0.34, w = 1, h = 0.44 },
	signatures = { x = 0, y = 0.8, w = 1, h = 0.2 },
}

local function rect(r)
	return UDim2.fromScale(r.x, r.y), UDim2.fromScale(r.w, r.h)
end

local function weaponName(id)
	local weapon = Weapons.get(id)
	return weapon and weapon.Name or id
end

-- Builds the legends screen inside `parent`. Returns the ScreenInstance (menus design 3.8).
function FightersPanel.mount(parent, host)
	local root = Common.root({ content = parent }, "Legends")
	local sizer = Common.sizer(root)
	local bag = Common.bag()
	local player = Players.LocalPlayer

	local previewed = (ClientState.profile and ClientState.profile.Legend) or Legends.Default
	local container, viewHolder, view
	local opening = false -- between show and its deferred focus: tile focus doesn't preview
	local lastParams = nil -- the deep-link params already applied
	local tiles = {} -- [legendId] = tile parts
	local order = {} -- tile buttons in grid order
	local info: { [string]: any } = {}

	local function current()
		return ClientState.profile and ClientState.profile.Legend
	end

	local function ownLook(legendId)
		return Settings.get("FightAsAvatar") == true and legendId ~= "Avatar"
	end

	local function selectLegend(legendId)
		local legend = Legends.get(legendId)
		if current() == legendId then
			host.toast(legend.Name .. " is already your legend.", "info")
			return
		end
		local ok, message = Common.invoke("SelectLegend", legendId)
		if ok then
			host.toast(legend.Name .. " is your legend now. You can still pick another one before each match.", "good")
		else
			host.toast(message or "Couldn't select that legend.", "error")
		end
	end

	local function renderTiles()
		local mine = current()
		for id, tile in tiles do
			tile.selected.Visible = id == mine
			tile.strip.BackgroundColor3 = if id == previewed then T.Red else T.Backdrop
		end
	end

	local function renderInfo()
		if not info.name then
			return
		end
		local legend = Legends.get(previewed)
		info.name.Text = string.upper(legend.Name)
		info.name.TextColor3 = legend.Color
		info.title.Text = string.upper(legend.Title)
		info.title.TextColor3 = legend.Color:Lerp(Color3.new(1, 1, 1), 0.35)
		info.description.Text = legend.Description
		for _, statName in Legends.StatNames do
			info.pips[statName](legend.Stats[statName])
		end
		local weapons = legend.Weapons
		for i, chip in info.weapons do
			local id = weapons and weapons[i]
			chip.Visible = id ~= nil or (i == 1 and weapons == nil)
			if id then
				Common.setTag(chip, string.upper(weaponName(id)), { fill = T.Raised, textColor = T.Text })
			elseif i == 1 then
				Common.setTag(chip, "ANY WEAPON", { fill = T.Raised, textColor = T.Text })
			end
		end
		info.ultimate.Text = string.upper(legend.Ultimate and legend.Ultimate.Name or "")
		info.ultimate.TextColor3 = legend.Color:Lerp(Color3.new(1, 1, 1), 0.35)
		info.lookRow.Visible = legend.Id ~= "Avatar"
		info.setLook(Settings.get("FightAsAvatar") == true)
		local mine = current() == legend.Id
		Common.setButtonText(info.select, if mine then "SELECTED" else "SELECT")
		-- signatures
		if legend.Weapons then
			local lines = {}
			for _, weapon in legend.Weapons do
				local names = {}
				for _, slot in Legends.SignatureSlots do
					table.insert(names, Legends.signatureName(legend.Id, weapon, slot) or "?")
				end
				table.insert(lines, string.upper(weaponName(weapon)) .. ":  " .. table.concat(names, "  ·  "))
			end
			info.signatures.Text = table.concat(lines, "\n")
		else
			info.signatures.Text = "Picks up any weapon and uses the shared heavies."
		end
	end

	local function renderView(flourish)
		if view then
			view:set({ legend = previewed, userId = player.UserId, ownLook = ownLook(previewed), flourish = flourish })
		end
	end

	local function renderGlow()
		if not viewHolder then
			return
		end
		local color = Legends.get(previewed).Color
		for _, child in viewHolder:GetChildren() do
			if child.Name:sub(1, 4) == "Glow" then
				child.BackgroundColor3 = color
			end
		end
	end

	local function preview(legendId)
		if previewed == legendId then
			return
		end
		previewed = legendId
		renderTiles()
		renderInfo()
		renderGlow()
		renderView(false)
		if info.select and tiles[legendId] then
			Focus.link(info.select, "Left", tiles[legendId].button)
		end
	end

	local function buildTile(gridFrame, index, legendId)
		local legend = Legends.get(legendId)
		local column = (index - 1) % COLUMNS
		local row = math.floor((index - 1) / COLUMNS)
		local button = make("TextButton", {
			Name = legendId,
			AutoButtonColor = false,
			Text = "",
			BackgroundColor3 = legend.Color,
			BorderSizePixel = 0,
			Position = UDim2.fromScale(column * 0.25 + 0.006 - row * 0.012, row * 0.5 + 0.01),
			Size = UDim2.fromScale(0.238, 0.47),
			ClipsDescendants = true,
			Parent = gridFrame,
		})
		Common.gradient(button, legend.Color, legend.Color:Lerp(Color3.new(0, 0, 0), 0.45))
		Common.stroke(button, T.Outline, 3)
		local portraitBox = make("Frame", {
			Name = "Portrait",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0.8),
			Parent = button,
		})
		LegendView.portrait(portraitBox, { legend = legendId, userId = player.UserId }, {})
		local strip = Common.fill(T.Backdrop, {
			Name = "Strip",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.fromScale(1, 0.24),
			BackgroundTransparency = 0.15,
			Parent = button,
		})
		Common.text(string.upper(legend.Name), 32, {
			Font = T.HeadFont,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextWrapped = false,
			Parent = strip,
		})
		local selected = Common.tag("SELECTED", {
			name = "Selected",
			position = UDim2.fromScale(0.04, 0.04),
			size = UDim2.fromScale(0.62, 0.14),
			fill = T.Gold,
			textColor = T.GoldDark,
			zIndex = 3,
			parent = button,
		})
		tiles[legendId] = { button = button, strip = strip, selected = selected }
		table.insert(order, button)
		Common.focusable(button, {
			key = "Legend" .. legendId,
			onFocus = function(on)
				if on and not opening then
					preview(legendId)
				end
			end,
		}, function()
			if previewed == legendId then
				selectLegend(legendId)
			else
				preview(legendId)
			end
		end)
	end

	local function buildInfo(frame)
		info.name = Common.text("", 100, {
			Name = "LegendName",
			Font = T.HeadFont,
			Size = UDim2.fromScale(1, 0.15),
			TextWrapped = false,
			Parent = frame,
		})
		info.title = Common.text("", 24, {
			Name = "Title",
			Font = T.BlackFont,
			Position = UDim2.fromScale(0, 0.15),
			Size = UDim2.fromScale(1, 0.05),
			TextWrapped = false,
			Parent = frame,
		})
		info.description = Common.text("", 22, {
			Name = "Description",
			TextColor3 = T.Muted,
			TextYAlignment = Enum.TextYAlignment.Top,
			Position = UDim2.fromScale(0, 0.21),
			Size = UDim2.fromScale(1, 0.09),
			Parent = frame,
		})
		info.pips = {}
		for i, statName in Legends.StatNames do
			local y = 0.31 + (i - 1) * 0.055
			Common.text(string.upper(statName), 18, {
				Font = T.BlackFont,
				TextColor3 = T.Muted,
				Position = UDim2.fromScale(0, y),
				Size = UDim2.fromScale(0.3, 0.045),
				TextWrapped = false,
				Parent = frame,
			})
			local _, setPips = UIKit.pips(9, 0, {
				name = statName,
				fill = STAT_COLORS[statName],
				position = UDim2.fromScale(0.32, y + 0.008),
				size = UDim2.fromScale(0.66, 0.03),
				parent = frame,
			})
			info.pips[statName] = setPips
		end
		Common.text("WEAPONS", 18, {
			Font = T.BlackFont,
			TextColor3 = T.Muted,
			Position = UDim2.fromScale(0, 0.54),
			Size = UDim2.fromScale(1, 0.04),
			TextWrapped = false,
			Parent = frame,
		})
		info.weapons = {}
		for i = 1, 2 do
			info.weapons[i] = Common.tag("", {
				name = "Weapon" .. i,
				position = UDim2.fromScale((i - 1) * 0.34, 0.585),
				size = UDim2.fromScale(0.32, 0.05),
				parent = frame,
			})
		end
		Common.text("ULTIMATE", 18, {
			Font = T.BlackFont,
			TextColor3 = T.Muted,
			Position = UDim2.fromScale(0, 0.65),
			Size = UDim2.fromScale(1, 0.04),
			TextWrapped = false,
			Parent = frame,
		})
		info.ultimate = Common.text("", 44, {
			Name = "Ultimate",
			Font = T.HeadFont,
			Position = UDim2.fromScale(0, 0.69),
			Size = UDim2.fromScale(1, 0.07),
			TextWrapped = false,
			Parent = frame,
		})
		local lookRow, setLook = UIKit.toggle("Use my avatar's look", Settings.get("FightAsAvatar"), function(v)
			Settings.set("FightAsAvatar", v)
		end)
		lookRow.Name = "AvatarLook"
		lookRow:SetAttribute("FocusKey", "LegendsAvatarLook")
		lookRow.Position = UDim2.fromScale(0, 0.77)
		lookRow.Size = UDim2.fromScale(1, 0.08)
		lookRow.Parent = frame
		info.lookRow, info.setLook = lookRow, setLook
		info.select = Common.slantButton("SELECT", {
			name = "Select",
			style = "primary",
			glyph = "Confirm",
			textSize = 40,
			position = UDim2.fromScale(0, 0.875),
			size = UDim2.fromScale(0.62, 0.11),
			parent = frame,
		}, function()
			selectLegend(previewed)
		end)
		info.select:SetAttribute("FocusKey", "LegendsSelect")
	end

	local layout = WIDE
	local function build()
		if container then
			container:Destroy()
		end
		table.clear(tiles)
		table.clear(order)
		table.clear(info)
		local phone = Common.isPhone()
		layout = if phone then PHONE else WIDE
		local canvas
		if phone then
			local scroller
			canvas, scroller = Common.body(root, sizer, { phoneHeight = PHONE_HEIGHT })
			container = scroller
		else
			container = make("Frame", {
				Name = "Body",
				BackgroundTransparency = 1,
				Size = UDim2.fromScale(1, 1),
				Parent = root,
			})
			canvas = container
		end

		local position, size = rect(layout.grid)
		local grid = make("Frame", {
			Name = "Grid",
			BackgroundTransparency = 1,
			Position = position,
			Size = size,
			Parent = canvas,
		})
		for i, id in Legends.Order do
			buildTile(grid, i, id)
		end
		local rows = {}
		for i, button in order do
			local r = math.floor((i - 1) / COLUMNS) + 1
			rows[r] = rows[r] or {}
			table.insert(rows[r], button)
		end
		Focus.linkGrid(rows)

		position, size = rect(layout.signatures)
		local _, sigBody = Common.cutPanel({
			name = "Signatures",
			title = "SIGNATURE HEAVIES",
			position = position,
			size = size,
			parent = canvas,
		})
		local signatures = Common.text("", 22, {
			Name = "List",
			TextYAlignment = Enum.TextYAlignment.Top,
			TextColor3 = T.Muted,
			Position = UDim2.fromScale(0.03, 0.05),
			Size = UDim2.fromScale(0.94, 0.9),
			Parent = sigBody,
		})

		position, size = rect(layout.view)
		viewHolder = make("Frame", {
			Name = "View",
			BackgroundTransparency = 1,
			Position = position,
			Size = size,
			Parent = canvas,
		})
		for i, transparency in { 0.75, 0.85, 0.92 } do
			local glow = Common.fill(T.Gold, {
				Name = "Glow" .. i,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.62),
				Size = UDim2.fromScale(0.5 + i * 0.2, 0.35 + i * 0.12),
				BackgroundTransparency = transparency,
				Parent = viewHolder,
			})
			make("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = glow })
		end

		position, size = rect(layout.info)
		local infoFrame = make("Frame", {
			Name = "Info",
			BackgroundTransparency = 1,
			Position = position,
			Size = size,
			Parent = canvas,
		})
		buildInfo(infoFrame)
		info.signatures = signatures
		renderTiles()
		renderInfo()
		Focus.link(info.select, "Left", tiles[previewed] and tiles[previewed].button)
	end
	build()

	local function openView()
		if view or not viewHolder then
			return
		end
		-- feet on the holder's bottom edge, centred (the view keeps its own aspect inside the holder)
		view = LegendView.new(viewHolder, {
			framing = "Full",
			facing = "Left",
			animated = true,
			zIndex = 2,
			anchor = Vector2.new(0.5, 1),
			position = UDim2.fromScale(0.5, 1),
			size = UDim2.fromScale(1, 1),
		})
		renderView(true)
	end

	local function closeView()
		if view then
			view:destroy()
			view = nil
		end
	end

	local rewireTop = Common.linkTop(host, function()
		local top = {}
		for i = 1, math.min(COLUMNS, #order) do
			table.insert(top, order[i])
		end
		return top
	end)
	Common.onModeChange(root, function()
		local wasOpen = view ~= nil
		closeView()
		build()
		if wasOpen then
			openView()
		end
		rewireTop()
		host.refresh()
	end)

	local function toggleLook()
		if previewed == "Avatar" then
			return
		end
		Settings.set("FightAsAvatar", not (Settings.get("FightAsAvatar") == true))
	end

	return {
		root = root,
		show = function(params)
			-- your legend, or a deep link's legend the first time it arrives
			local target = current() or previewed
			if params ~= lastParams and type(params) == "table" and Legends.isValid(params.legend) then
				target = params.legend
			end
			lastParams = params
			preview(target)
			-- the shell pushes the Focus layer right after show and Focus restores the tile it remembers:
			-- that tile mustn't preview, and focus then moves to the target's tile
			opening = true
			task.defer(function()
				opening = false
				local tile = tiles[target]
				if tile then
					Focus.set(tile.button)
				end
			end)
			bag.add(ClientState.ProfileChanged:Connect(function()
				renderTiles()
				renderInfo()
			end))
			bag.add(Settings.Changed:Connect(function(key)
				if key == "FightAsAvatar" then
					renderInfo()
					renderView(true)
				end
			end))
			openView()
			renderGlow()
			renderTiles()
			renderInfo()
			rewireTop()
		end,
		hide = function()
			bag.clear()
			closeView()
		end,
		defaultFocus = function()
			local tile = tiles[previewed] or tiles[current() or Legends.Default]
			return tile and tile.button or order[1]
		end,
		actions = {
			Y = toggleLook,
		},
		hints = function()
			return {
				{ action = "Confirm", label = "SELECT" },
				{ action = "Y", label = "AVATAR LOOK", onClick = toggleLook },
				{ action = "Back", label = "BACK" },
			}
		end,
		destroy = function()
			closeView()
		end,
	}
end

return FightersPanel
