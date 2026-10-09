--[[
    The DAILY MISSIONS panel (menus design 5.7): the reset countdown and one
    row per mission (MenuModels.missionRows): text, progress bar (red; gold
    when done), "p/g" or DONE, the rewards (coins, +XP), REROLL while the
    free reroll is unused, the mission isn't done and its day hasn't run
    out, and CLAIM once it is done. Rows are keyed by mission index and updated in place on every
    ProfileUpdate, never rebuilt, so focus stays put. Each row is a focus
    stop (key "Mission<index>"): Confirm claims, X rerolls (a per-object
    action, set only while the row can be rerolled, so then it wins over
    the main menu's X = INVITE and otherwise X still invites). Both call
    MissionRequest with the list's day (the server refuses a press on a
    list that has changed) and toast its answer. rowState(button) tells the main
    menu what a focused row's Confirm and X do, for its hints. While the
    profile is still loading it says "Loading missions...".

    The main menu shows it compact; the Missions screen embeds it with
    compact = false (bigger rows). opts.mini (the phone main menu) keeps
    only each mission's short text and bar.

    Mission text is one line that gets the row's width (0.9) unless REROLL
    shares its line: compact, that is a bare X glyph like mockup b's icon
    (0.82 left for the text), and with its label (full size, and on touch,
    where glyphs are hidden) 0.7. It is 18 design px compact (mockup b),
    21 x 1.25 full size and 22 mini, and shrinks a few px to fit
    (Layout.bindFitText) before the end is cut ("...").
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)

local Client = script.Parent.Parent
local ClientState = require(Client:WaitForChild("ClientState"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))
local Focus = require(script.Parent:WaitForChild("Focus"))
local Layout = require(script.Parent:WaitForChild("Layout"))
local MenuModels = require(script.Parent:WaitForChild("MenuModels"))

local T = UIKit.Theme
local make = UIKit.make

local MissionsWidget = {}

local function text(name, parent, props, size)
	local label = make("TextLabel", {
		Name = name,
		BackgroundTransparency = 1,
		Text = "",
		Font = T.BoldFont,
		TextColor3 = T.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = parent.ZIndex + 1,
		Parent = parent,
	})
	for key, value in props do
		label[key] = value
	end
	Layout.bindText(label, size)
	return label
end

local function send(action, index)
	local missions = ClientState.profile and ClientState.profile.Missions
	local day = if type(missions) == "table" and type(missions.day) == "number" then missions.day else nil
	local ok, success, message = pcall(function()
		return Net.get("MissionRequest"):InvokeServer(action, index, day)
	end)
	if not ok then
		ClientState.toast("Something went wrong.", "error")
	elseif type(message) == "string" then
		ClientState.toast(message, if success == true then "good" else "error")
	end
end

--[[
    opts = { compact: boolean?, mini: boolean?, onChanged: (() -> ())? } &
    Common. onChanged runs after a redraw that no profile change caused
    (the day ran out: REROLL goes), so the screen can refresh its hints.
    Returns { frame, focusables() -> { GuiObject }, rowState(obj),
    destroy() }.
]]
function MissionsWidget.new(parent, opts)
	opts = opts or {}
	local compact = opts.compact ~= false
	local mini = opts.mini == true
	local scale = if compact then 1 else 1.25
	-- mission text (design px) and how far it may shrink to fit
	local missionTextSize = if mini then 22 elseif compact then 18 else 21 * scale
	local missionTextMin = if mini then 18 elseif compact then 14 else 18
	local frame, body = UIKit.cutPanel({
		cut = 18,
		title = if mini then "MISSIONS" else "DAILY MISSIONS",
		titleSize = if mini then 32 else 36 * scale,
		zIndex = opts.zIndex or 1,
	})
	frame.Name = opts.name or "MissionsWidget"
	frame.Position = opts.position or frame.Position
	if typeof(opts.size) == "UDim2" then
		frame.Size = opts.size
	end
	frame.AnchorPoint = opts.anchor or frame.AnchorPoint
	frame.LayoutOrder = opts.layoutOrder or 0
	frame.Parent = parent or opts.parent
	local zIndex = body.ZIndex + 1

	local countdown = text("Reset", frame, {
		TextColor3 = T.Muted,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(0.95, 0.025),
		Size = UDim2.fromScale(0.35, 0.08),
		ZIndex = frame.ZIndex + 3,
	}, 18 * scale)
	local loading = text("Loading", body, {
		Text = "Loading missions...",
		TextColor3 = T.Muted,
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(1, 0.3),
		Position = UDim2.fromScale(0, 0.3),
		ZIndex = zIndex,
	}, 20 * scale)
	local footer = nil
	if not mini then
		footer = text("Footer", body, {
			TextColor3 = T.Muted,
			Position = UDim2.fromScale(0.05, 0.9),
			Size = UDim2.fromScale(0.9, 0.08),
			ZIndex = zIndex,
		}, 17 * scale)
	end

	local rows = {} -- [index] = row
	local renderedExpired = false -- whether the last render was past the list's reset (no REROLL)
	local rowArea = if mini then { top = 0.02, height = 0.94 } else { top = 0.0, height = 0.88 }

	local function newRow(index)
		local row = { index = index, data = nil }
		local button = make("TextButton", {
			Name = "Mission" .. index,
			BackgroundColor3 = T.Raised,
			BorderSizePixel = 0,
			AutoButtonColor = false,
			Text = "",
			ZIndex = zIndex,
			Parent = body,
		})
		row.button = button
		local accent = make("Frame", {
			Name = "Accent",
			BackgroundColor3 = T.Red,
			BorderSizePixel = 0,
			ZIndex = zIndex + 1,
			Parent = button,
		})
		Layout.bindApply(accent, function()
			accent.Size = UDim2.new(0, math.max(2, Layout.px(5)), 1, 0)
		end)
		row.accent = accent
		row.textWidth = 0.9 -- (narrower while REROLL shares the line: renderRow)
		row.text = text("Text", button, {
			Position = UDim2.fromScale(0.05, if mini then 0.05 else 0.06),
			Size = UDim2.fromScale(row.textWidth, if mini then 0.5 else 0.3),
		}, missionTextSize)
		Layout.bindFitText(row.text, missionTextSize, missionTextMin)
		local bar, setBar = UIKit.progressBar({
			parent = button,
			position = UDim2.fromScale(0.05, if mini then 0.62 else 0.44),
			size = UDim2.fromScale(if mini then 0.9 else 0.72, if mini then 0.14 else 0.1),
			zIndex = zIndex + 1,
		})
		row.bar, row.setBar = bar, setBar
		if not mini then
			row.status = text("Status", button, {
				Font = T.BlackFont,
				TextXAlignment = Enum.TextXAlignment.Right,
				Position = UDim2.fromScale(0.78, 0.36),
				Size = UDim2.fromScale(0.18, 0.26),
			}, 18 * scale)
			row.coin = make("Frame", {
				Name = "Coin",
				BackgroundColor3 = T.Gold,
				BorderSizePixel = 0,
				Position = UDim2.fromScale(0.05, 0.7),
				Size = UDim2.fromScale(0.18, 0.18),
				SizeConstraint = Enum.SizeConstraint.RelativeYY,
				ZIndex = zIndex + 1,
				Parent = button,
			})
			make("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = row.coin })
			row.coins = text("Coins", button, {
				Font = T.BlackFont,
				TextColor3 = T.Gold,
				Position = UDim2.fromScale(0.11, 0.64),
				Size = UDim2.fromScale(0.16, 0.3),
			}, 17 * scale)
			row.xp = text("XP", button, {
				Font = T.BlackFont,
				TextColor3 = T.XP,
				Position = UDim2.fromScale(0.27, 0.64),
				Size = UDim2.fromScale(0.3, 0.3),
			}, 17 * scale)
			local claimHolder = make("Frame", {
				Name = "ClaimHolder",
				BackgroundTransparency = 1,
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.fromScale(0.97, 0.64),
				Size = UDim2.fromScale(0.3, 0.28),
				ZIndex = zIndex + 1,
				Parent = button,
			})
			make("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				HorizontalAlignment = Enum.HorizontalAlignment.Right,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Parent = claimHolder,
			})
			row.claimHolder = claimHolder
			-- (its width is set by renderRow: the bare glyph's, or room for the label; never over the text)
			row.reroll = make("TextButton", {
				Name = "Reroll",
				BackgroundTransparency = 1,
				AutoButtonColor = false,
				Text = "",
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.fromScale(0.97, 0.06),
				Size = UDim2.fromScale(0.22, 0.26),
				ZIndex = zIndex + 1,
				Parent = button,
			})
			Layout.bindListPadding(
				make("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					HorizontalAlignment = Enum.HorizontalAlignment.Right,
					VerticalAlignment = Enum.VerticalAlignment.Center,
					SortOrder = Enum.SortOrder.LayoutOrder,
					Parent = row.reroll,
				}),
				6
			)
			local glyphHolder = make("Frame", {
				Name = "GlyphHolder",
				BackgroundTransparency = 1,
				Size = UDim2.fromScale(1, 1),
				SizeConstraint = Enum.SizeConstraint.RelativeYY,
				LayoutOrder = 1,
				ZIndex = zIndex + 2,
				Parent = row.reroll,
			})
			UIKit.glyph("X", { parent = glyphHolder, zIndex = zIndex + 2 })
			row.rerollGlyph = glyphHolder
			local rerollText = text("Label", row.reroll, {
				Text = "REROLL",
				Font = T.BlackFont,
				TextColor3 = T.Muted,
				AutomaticSize = Enum.AutomaticSize.X,
				Size = UDim2.fromScale(0, 1),
				LayoutOrder = 2,
			}, 14 * scale)
			rerollText.TextTruncate = Enum.TextTruncate.None
			row.rerollLabel = rerollText
		end

		local function claim()
			if row.data and row.data.claimable then
				send("Claim", row.index)
			end
		end
		local function reroll()
			if row.data and row.data.rerollable then
				send("Reroll", row.index)
			end
		end
		row.rerollActions = { X = reroll }
		UIKit.onActivate(button, claim)
		Focus.register(button, { key = "Mission" .. index, actions = {} })
		if row.reroll then
			UIKit.onActivate(row.reroll, reroll)
			-- the small REROLL control is reached through X on the row, not as its own focus stop
			Focus.unregister(row.reroll)
		end
		return row
	end

	local function renderRow(row, data)
		row.data = data
		-- X rerolls only a row that can be rerolled; otherwise it falls through to the layer (INVITE)
		Focus.register(row.button, { actions = if data.rerollable then row.rerollActions else {} })
		row.text.Text = if mini then data.short else data.text
		local touch = Focus.mode() == "Touch"
		-- compact REROLL is a bare glyph (mockup b's icon); full size, and on touch (no glyphs), its label
		local glyphOnly = compact and not touch
		local width = 0.9
		if data.rerollable and not mini then
			-- (REROLL shares the text's line, at 0.97 - its width)
			width = if glyphOnly then 0.82 else 0.7
		end
		if row.textWidth ~= width then
			row.textWidth = width
			Layout.setSize(row.text, UDim2.fromScale(width, 0.3))
		end
		local color = if data.barColor == "Gold" then T.Gold else T.Red
		row.accent.BackgroundColor3 = color
		row.setBar(data.fraction, color)
		if row.status then
			row.status.Text = data.status
			row.status.TextColor3 = if data.done then T.Gold else T.Text
			row.coins.Text = tostring(data.coins)
			row.xp.Text = string.format("+%d XP", data.xp)
			row.reroll.Visible = data.rerollable
			row.reroll.Size = UDim2.fromScale(if glyphOnly then 0.08 else 0.22, 0.26)
			-- the glyph is hidden on touch (UIKit.glyph), so the label is the control there
			row.rerollGlyph.Visible = not touch
			row.rerollLabel.Visible = not glyphOnly
			local wantTag = data.tag
			if row.tag ~= wantTag then
				row.tag = wantTag
				for _, child in row.claimHolder:GetChildren() do
					if child:IsA("GuiObject") then
						child:Destroy()
					end
				end
				if wantTag then
					local holder = make("Frame", {
						Name = "TagHolder",
						BackgroundTransparency = 1,
						Size = UDim2.fromScale(1, 1),
						ZIndex = row.claimHolder.ZIndex,
						Parent = row.claimHolder,
					})
					UIKit.tag(wantTag, {
						parent = holder,
						fill = if wantTag == "CLAIM" then T.Gold else T.Raised,
						textColor = if wantTag == "CLAIM" then T.GoldDark else T.Dim,
						size = 15 * scale,
						zIndex = holder.ZIndex,
					})
				end
			end
		end
		row.button.BackgroundTransparency = if data.claimed then 0.45 else 0
	end

	local function layoutRows(count)
		local gap = 0.025
		local height = (rowArea.height - gap * math.max(0, count - 1)) / math.max(count, 3)
		local i = 0
		for index = 1, 99 do
			local row = rows[index]
			if row then
				row.button.Position = UDim2.fromScale(0.04, rowArea.top + i * (height + gap))
				row.button.Size = UDim2.fromScale(0.92, height)
				i += 1
			end
		end
	end

	local function render()
		local view =
			MenuModels.missionRows(ClientState.profile and ClientState.profile.Missions, ClientState.serverNow())
		renderedExpired = view.expired
		loading.Visible = view.loading
		countdown.Text = view.resetIn
		if footer then
			footer.Text = if view.loading then "" else view.footer
		end
		local seen = {}
		for _, data in view.rows do
			seen[data.index] = true
			local row = rows[data.index]
			if not row then
				row = newRow(data.index)
				rows[data.index] = row
			end
			renderRow(row, data)
		end
		for index, row in rows do
			if not seen[index] then
				Focus.unregister(row.button)
				row.button:Destroy()
				rows[index] = nil
			end
		end
		layoutRows(#view.rows)
	end

	render()
	local profileConn = ClientState.ProfileChanged:Connect(render)
	-- (touch swaps the REROLL glyph for its label, which changes the text's width)
	local modeConn = Focus.ModeChanged:Connect(render)
	local acc = 0
	local tick = RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc >= 1 and frame.Parent then
			acc = 0
			local missions = ClientState.profile and ClientState.profile.Missions
			if missions then
				local now = ClientState.serverNow()
				countdown.Text = MenuModels.timeLeft((missions.resetAt or 0) - now)
				-- the day ran out before the new list arrived: draw again, without REROLL
				if renderedExpired ~= (type(missions.resetAt) == "number" and now >= missions.resetAt) then
					render()
					if opts.onChanged then
						opts.onChanged()
					end
				end
			end
		end
	end)

	return {
		frame = frame,
		focusables = function()
			local list = {}
			for index = 1, 99 do
				if rows[index] then
					table.insert(list, rows[index].button)
				end
			end
			return list
		end,
		-- { claimable, rerollable } for one of this widget's row buttons, else nil
		rowState = function(obj)
			for _, row in rows do
				if row.button == obj and row.data then
					return { claimable = row.data.claimable == true, rerollable = row.data.rerollable == true }
				end
			end
			return nil
		end,
		destroy = function()
			profileConn.Disconnect()
			modeConn.Disconnect()
			tick:Disconnect()
			for _, row in rows do
				Focus.unregister(row.button)
			end
			frame:Destroy()
		end,
	}
end

return MissionsWidget
