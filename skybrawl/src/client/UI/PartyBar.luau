--[[
    The party bar at the bottom-left of the menus (menus design 5.7) and
    the party invite prompts.

    Bar: "PARTY n/4" and Config.Party.MaxSize slots (MenuModels.partySlots):
    you first (crown and LEADER when you lead), then the other members (a
    still portrait of their legend, name, status chip), your party's
    pending invites ("INVITED...", or "INVITED · IN A MATCH" while the
    invitee is busy), then empty slots: INVITE for a solo player or the
    leader (opens the Invite screen), a disabled "+" for other members.
    Confirm on your own slot in a party asks "Leave party?"; the leader's
    Confirm on a member asks "Kick <name>?". Each slot instance belongs to
    one slot key (a person's userId, or an empty position): it is updated
    in place while that key stays and moves when the order changes, and a
    key that leaves takes its instance with it. Focus on a slot whose
    person left goes to the INVITE slot now in that place, else to your own
    slot, never to someone else. A slot's still portrait is made the first
    time it shows a person. On phones: four 52 px slots and an INVITE
    button.

    Prompts: each incoming invite with a running countdown shows as a card
    at the top of SkybrawlPrompts, "<name> invited you to their party
    (n/4)", with ACCEPT (Confirm) and DECLINE (Back) and a bar counting down
    to expiresAt, one at a time, in a modal Focus layer that ignores
    Confirm for Config.Menu.InputGrace. Prompts show only in phases Menu and
    Results; leaving them hides the card (its countdown keeps running) and
    it comes back afterwards if the invite hasn't expired. An answered
    invite isn't prompted again, unless the answer failed (the request was
    refused) or the party sent it again (a new expiresAt).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Legends = require(Shared.Legends)
local Net = require(Shared.Net)

local Client = script.Parent.Parent
local ClientState = require(Client:WaitForChild("ClientState"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))
local Focus = require(script.Parent:WaitForChild("Focus"))
local Layout = require(script.Parent:WaitForChild("Layout"))
local LegendView = require(script.Parent:WaitForChild("LegendView"))
local MenuModels = require(script.Parent:WaitForChild("MenuModels"))

local T = UIKit.Theme
local make = UIKit.make

local PartyBar = {}

local PROMPT_PHASES = { Menu = true, Results = true }

local player = Players.LocalPlayer

-- PartyRequest -> (ok, result); a failed call toasts and returns false.
local function request(action, payload)
	local ok, result, message = pcall(function()
		return Net.get("PartyRequest"):InvokeServer(action, payload)
	end)
	if not ok then
		ClientState.toast("Something went wrong.", "error")
		return false, nil
	end
	return result, message
end

local function text(name, parent, props, size)
	local label = make("TextLabel", {
		Name = name,
		BackgroundTransparency = 1,
		Text = "",
		Font = T.BlackFont,
		TextColor3 = T.Text,
		ZIndex = parent.ZIndex + 2,
		Parent = parent,
	})
	for key, value in props do
		label[key] = value
	end
	Layout.bindText(label, size)
	return label
end

-- One slot button for slot key `key`; returns { button, render(slot), data(), destroy() }.
local function newSlot(parent, key, onActivate)
	local button = make("TextButton", {
		Name = "Slot_" .. key,
		BackgroundColor3 = T.Panel,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = "",
		ClipsDescendants = true,
		ZIndex = parent.ZIndex + 1,
		Parent = parent,
	})
	local stroke = make("UIStroke", { ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = button })
	Layout.bindStroke(stroke, 2)
	local portrait = nil -- made the first time the slot shows a person
	local strip = make("Frame", {
		Name = "Strip",
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
		Position = UDim2.fromScale(0, 0.7),
		Size = UDim2.fromScale(1, 0.3),
		ZIndex = button.ZIndex + 3,
		Parent = button,
	})
	local bottom = text("Bottom", strip, { Size = UDim2.fromScale(1, 1), TextTruncate = Enum.TextTruncate.AtEnd }, 15)
	local top = text("Top", button, {
		Font = T.BoldFont,
		Position = UDim2.fromScale(0, 0.04),
		Size = UDim2.fromScale(1, 0.28),
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = button.ZIndex + 3,
	}, 15)
	local centre = make("Frame", {
		Name = "Centre",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = button.ZIndex + 3,
		Parent = button,
	})
	Layout.bindListPadding(
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = centre,
		}),
		8
	)
	local glyphHolder = make("Frame", {
		Name = "GlyphHolder",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(0.34, 0.34),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		LayoutOrder = 1,
		ZIndex = centre.ZIndex,
		Parent = centre,
	})
	UIKit.glyph("X", { parent = glyphHolder, zIndex = centre.ZIndex })
	local centreText = text("Text", centre, {
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromScale(0, 0.4),
		LayoutOrder = 2,
		ZIndex = centre.ZIndex,
	}, 18)

	local current = nil
	UIKit.onActivate(button, function()
		if current then
			onActivate(current)
		end
	end)
	Focus.register(button, { key = "PartySlot:" .. key })

	local function render(slot)
		current = slot
		local filled = slot.kind == "You" or slot.kind == "Member"
		if filled then
			local spec = { legend = slot.legend or Legends.Default, userId = slot.userId }
			if portrait then
				portrait.set(spec)
			else
				portrait = LegendView.portrait(button, spec, { zIndex = button.ZIndex + 1 })
			end
		end
		if portrait then
			portrait.frame.Visible = filled
		end
		strip.Visible = filled or slot.kind == "Invited"
		top.Visible = slot.kind == "Member" or slot.kind == "Invited"
		centre.Visible = slot.kind == "Invite" or slot.kind == "Empty"
		glyphHolder.Visible = slot.kind == "Invite" and slot.label == "INVITE"
		stroke.Color = if filled then T.Outline else T.Stroke
		stroke.Transparency = if filled then 0 else 0.3
		button.BackgroundColor3 = if filled then T.Panel else T.Backdrop
		button.BackgroundTransparency = if filled then 0 else 0.35
		button:SetAttribute("Disabled", slot.kind == "Empty")
		bottom.TextColor3 = T.Text
		if slot.kind == "You" then
			bottom.Text = if slot.isLeader then "♛ YOU · LEADER" else "YOU"
			bottom.TextColor3 = if slot.isLeader then T.Gold else T.Text
		elseif slot.kind == "Member" then
			top.Text = MenuModels.statusText(slot.status)
			top.TextColor3 = T.Warning
			bottom.Text = (if slot.isLeader then "♛ " else "") .. (slot.name or "")
		elseif slot.kind == "Invited" then
			top.Text = slot.name or ""
			top.TextColor3 = T.Text
			bottom.Text = slot.label
			bottom.TextColor3 = T.Gold
		else
			centreText.Text = slot.label
			centreText.TextColor3 = if slot.kind == "Invite" then T.Text else T.Dim
		end
	end

	return {
		key = key,
		button = button,
		render = render,
		data = function()
			return current
		end,
		destroy = function()
			if portrait then
				portrait.destroy()
			end
			button:Destroy()
		end,
	}
end

-- Prompts ------------------------------------------------------------------------------

-- An invite's identity for `answered`: the same party sending it again (a new expiresAt) prompts again.
local function answerKey(invite)
	return tostring(invite.partyId) .. ":" .. tostring(invite.expiresAt)
end

local function newPrompts()
	local answered = {} -- [answerKey] = true once you pressed ACCEPT / DECLINE
	local shownFor = nil -- partyId of the card on screen
	local card, layer, setBar, message = nil, nil, nil, nil

	local function close()
		if layer then
			Focus.popLayer(layer)
			layer = nil
		end
		if card then
			card:Destroy()
			card = nil
		end
		shownFor = nil
	end

	local function answer(invite, accept)
		local key = answerKey(invite)
		answered[key] = true
		close()
		local action = if accept then "Accept" else "Decline"
		task.spawn(function()
			local ok, reply = request(action, invite.partyId)
			if ok ~= true then
				-- refused (still busy, the party is full...) or failed: the invite may stay, so it can prompt again
				answered[key] = nil
				if type(reply) == "string" then
					ClientState.toast(reply, "error")
				end
			elseif accept and type(reply) == "string" then
				ClientState.toast(reply, "good")
			end
		end)
	end

	local function open(invite)
		close()
		shownFor = invite.partyId
		local phone = Layout.mode() == "Phone"
		local gui = UIKit.promptsGui()
		local panel, body = UIKit.cutPanel({
			parent = gui,
			name = "InvitePrompt",
			anchor = Vector2.new(0.5, 0),
			size = if phone then UDim2.fromScale(0.62, 0.42) else UDim2.fromScale(0.34, 0.17),
			zIndex = 40,
			title = "PARTY INVITE",
			titleSize = 40,
		})
		card = panel
		Layout.clearTop(panel, UDim2.fromScale(0.5, 0.11))
		message = text("Message", body, {
			Font = T.BoldFont,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			Position = UDim2.fromScale(0.05, 0),
			Size = UDim2.fromScale(0.9, 0.34),
		}, 24)
		local _, set = UIKit.progressBar({
			parent = body,
			fill = T.Red,
			position = UDim2.fromScale(0.05, 0.38),
			size = UDim2.fromScale(0.9, 0.06),
			zIndex = body.ZIndex + 2,
		})
		setBar = set
		local accept = UIKit.slantButton("ACCEPT", {
			parent = body,
			name = "Accept",
			style = "primary",
			textSize = 30,
			position = UDim2.fromScale(0.05, 0.54),
			size = UDim2.fromScale(0.43, 0.36),
			zIndex = body.ZIndex + 2,
		}, function()
			answer(invite, true)
		end)
		local decline = UIKit.slantButton("DECLINE", {
			parent = body,
			name = "Decline",
			style = "dark",
			textSize = 30,
			glyph = "Back",
			anchor = Vector2.new(1, 0),
			position = UDim2.fromScale(0.95, 0.54),
			size = UDim2.fromScale(0.43, 0.36),
			zIndex = body.ZIndex + 2,
		}, function()
			answer(invite, false)
		end)
		Focus.linkRow({ accept, decline })
		layer = Focus.pushLayer({
			name = "InvitePrompt",
			roots = { panel },
			band = "modal",
			defaultFocus = function()
				return accept
			end,
			onBack = function()
				answer(invite, false)
			end,
			confirmDelay = Config.Menu.InputGrace,
		})
	end

	local function update()
		local invite = nil
		if PROMPT_PHASES[ClientState.phase] then
			local pending = {}
			local invites: { any } = ClientState.invites or {}
			for _, candidate in invites do
				if not answered[answerKey(candidate)] then
					table.insert(pending, candidate)
				end
			end
			invite = MenuModels.promptInvite(pending, ClientState.serverNow())
		end
		if not invite then
			close()
			return
		end
		if shownFor ~= invite.partyId then
			open(invite)
		end
		local left = invite.expiresAt - ClientState.serverNow()
		message.Text = string.format(
			"%s invited you to their party (%d/%d)",
			invite.fromName or "Someone",
			invite.size or 1,
			Config.Party.MaxSize
		)
		setBar(left / Config.Party.InviteSeconds)
	end

	ClientState.PartyChanged:Connect(function(_, invites)
		-- forget answers for invites that are gone (a new invite from the same party can come later)
		local live = {}
		for _, invite in invites or {} do
			live[answerKey(invite)] = true
		end
		for key in answered do
			if not live[key] then
				answered[key] = nil
			end
		end
		update()
	end)
	ClientState.PhaseChanged:Connect(update)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc >= 0.2 then
			acc = 0
			if shownFor or #(ClientState.invites or {}) > 0 then
				update()
			end
		end
	end)
	update()
end

-- Bar ---------------------------------------------------------------------------------

-- Returns { root, setVisible(on), slots() (the slot buttons in bar order, then the phone INVITE button) }.
function PartyBar.new(canvas, host)
	local root = make("Frame", {
		Name = "PartyBar",
		BackgroundTransparency = 1,
		ZIndex = 12,
		Parent = canvas,
	})
	local slots = {} -- slot objects in bar order
	local byKey = {} -- [slot key] = slot object
	local inviteButton = nil
	local countLabel = nil
	local wanted = true

	local function you()
		local profile = ClientState.profile
		return { userId = player.UserId, name = player.DisplayName, legend = profile and profile.Legend }
	end

	local function onSlot(slot)
		local party = ClientState.party
		if slot.kind == "Invite" then
			host.push("Invite")
		elseif slot.kind == "You" and party then
			UIKit.dialog({
				title = "LEAVE PARTY?",
				body = "You'll leave the party. You can be invited again.",
				confirm = "LEAVE",
				cancel = "STAY",
				onConfirm = function()
					local ok, message = request("Leave")
					if ok ~= true and type(message) == "string" then
						ClientState.toast(message, "error")
					end
				end,
			})
		elseif slot.kind == "Member" and party and party.leaderUserId == player.UserId then
			UIKit.dialog({
				title = string.upper("Kick " .. (slot.name or "player") .. "?"),
				body = (slot.name or "They") .. " will be removed from your party.",
				confirm = "KICK",
				cancel = "CANCEL",
				onConfirm = function()
					local ok, message = request("Kick", slot.userId)
					if ok ~= true and type(message) == "string" then
						ClientState.toast(message, "error")
					end
				end,
			})
		end
	end

	-- Where the slot at list position i sits (fractions of the bar).
	local function place(button, i)
		if Layout.mode() == "Phone" then
			button.Position = UDim2.fromScale((i - 1) * 60 / 321, 0)
			button.Size = UDim2.fromScale(52 / 321, 1)
		else
			button.Position = UDim2.fromScale((0.046 + (i - 1) * 0.072) / 0.33, 0)
			button.Size = UDim2.fromScale(0.065 / 0.33, 1)
		end
		button.LayoutOrder = i
	end

	local function render()
		local party = ClientState.party
		local list = MenuModels.partySlots(party, ClientState.invites, you())
		local focusedButton = Focus.get()
		local nextByKey, ordered = {}, {}
		for i, data in list do
			local slot = byKey[data.key] or newSlot(root, data.key, onSlot)
			nextByKey[data.key] = slot
			ordered[i] = slot
			place(slot.button, i)
			if Layout.mode() == "Phone" and data.kind == "Invite" then
				data = table.clone(data)
				data.label = "+"
			end
			slot.render(data)
		end
		-- a key that left (a member left, an empty place filled) takes its instance with it
		local lostAt = nil
		for i, slot in slots do
			if nextByKey[slot.key] ~= slot then
				if slot.button == focusedButton then
					lostAt = i
				end
				slot.destroy()
			end
		end
		byKey, slots = nextByKey, ordered
		if lostAt then
			-- never onto someone else: the INVITE slot now in that place, else your own slot
			Focus.set(slots[MenuModels.partyFocusAfter(list, lostAt)].button)
		end
		if countLabel then
			countLabel.Text = string.format("%d / %d", if party then #party.members else 1, Config.Party.MaxSize)
		end
		if inviteButton then
			UIKit.setEnabled(inviteButton, MenuModels.canInvite(party, player.UserId))
		end
	end

	local function build()
		for _, slot in slots do
			slot.destroy()
		end
		if inviteButton then
			Focus.unregister(inviteButton)
			inviteButton = nil
		end
		for _, child in root:GetChildren() do
			child:Destroy()
		end
		table.clear(slots)
		table.clear(byKey)
		countLabel = nil
		if Layout.mode() == "Phone" then
			local x, y, w, h = Layout.phoneRect(57, 318, 321, 52)
			root.Position = UDim2.fromScale(x, y)
			root.Size = UDim2.fromScale(w, h)
			inviteButton = UIKit.slantButton("INVITE", {
				parent = root,
				name = "PartyInvite",
				style = "dark",
				textSize = 32,
				glyph = "X",
				position = UDim2.fromScale(243 / 321, 0.06),
				size = UDim2.fromScale(78 / 321, 0.88),
				zIndex = root.ZIndex + 1,
			}, function()
				host.push("Invite")
			end)
		else
			root.Position = UDim2.fromScale(0.029, 0.88)
			root.Size = UDim2.fromScale(0.33, 0.078)
			text("Party", root, {
				Font = T.HeadFont,
				Text = "PARTY",
				TextXAlignment = Enum.TextXAlignment.Left,
				Size = UDim2.fromScale(0.13, 0.55),
				Position = UDim2.fromScale(0, 0.08),
			}, 40)
			countLabel = text("Count", root, {
				Font = T.BoldFont,
				TextColor3 = T.Muted,
				TextXAlignment = Enum.TextXAlignment.Left,
				Size = UDim2.fromScale(0.13, 0.3),
				Position = UDim2.fromScale(0, 0.62),
			}, 18)
		end
		root.Visible = wanted
		render()
	end

	build()
	Layout.Changed:Connect(build)
	ClientState.PartyChanged:Connect(render)
	ClientState.ProfileChanged:Connect(render)
	newPrompts()

	return {
		root = root,
		setVisible = function(on)
			wanted = on
			root.Visible = on
		end,
		slots = function()
			local list = {}
			for _, slot in slots do
				table.insert(list, slot.button)
			end
			if inviteButton then
				table.insert(list, inviteButton)
			end
			return list
		end,
	}
end

return PartyBar
