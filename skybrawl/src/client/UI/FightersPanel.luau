--[[
    Fighter select: the roster on the left, the chosen legend on the right
    with a live 3D preview (its imported rig, animated by FighterAnimator),
    stats, weapons and signature moves. "My Avatar" previews your own avatar.
    The choice is saved to your profile and used from your next match.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Legends = require(Shared.Legends)
local LegendRig = require(Shared.LegendRig)
local WeaponModels = require(Shared.WeaponModels)
local Weapons = require(Shared.Weapons)
local Net = require(Shared.Net)

local UIKit = require(script.Parent.UIKit)
local ClientState = require(script.Parent.Parent.ClientState)
local FighterAnimator = require(script.Parent.Parent.Controllers.FighterAnimator)

local T = UIKit.Theme
local make = UIKit.make

local FightersPanel = {}

local STAT_COLORS = {
	Strength = Color3.fromRGB(255, 120, 90),
	Dexterity = Color3.fromRGB(110, 210, 255),
	Defense = Color3.fromRGB(150, 220, 120),
	Speed = Color3.fromRGB(255, 210, 90),
}

local function statBar(name, value, order, parent)
	local row = make("Frame", {
		BackgroundTransparency = 1,
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 22),
		Parent = parent,
	})
	UIKit.label(name, 15, { Size = UDim2.new(0, 92, 1, 0), Font = T.BoldFont, Parent = row })
	local track = make("Frame", {
		BackgroundColor3 = T.PanelLight,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(96, 6),
		Size = UDim2.new(1, -130, 0, 10),
		Parent = row,
	}, { UIKit.corner(5) })
	make("Frame", {
		BackgroundColor3 = STAT_COLORS[name],
		BorderSizePixel = 0,
		Size = UDim2.fromScale(value / 10, 1),
		Parent = track,
	}, { UIKit.corner(5) })
	UIKit.label(tostring(value), 15, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0, 28, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Right,
		Font = T.BoldFont,
		Parent = row,
	})
end

-- Preview -----------------------------------------------------------------

local function clearPreview(world)
	for _, child in world:GetChildren() do
		FighterAnimator.untrack(child)
		child:Destroy()
	end
end

local function holdWeapon(rig, legendId)
	local legend = Legends.get(legendId)
	local weaponId = legend.Weapons and legend.Weapons[1]
	if not weaponId then
		return nil
	end
	local weapon = Weapons.get(weaponId)
	local side = weapon.Hand == "Left" and "Left" or "Right"
	local hand = rig:FindFirstChild(side .. "Hand")
	if not hand then
		return nil
	end
	local folder = Instance.new("Folder")
	folder.Name = "EquippedWeapon"
	local sides = weapon.Hand == "Both" and { "Right", "Left" } or { side }
	for _, s in sides do
		local h = rig:FindFirstChild(s .. "Hand")
		local model = WeaponModels.build(weaponId, nil, Legends.weaponSkin(legendId, weaponId))
		model.Name = s
		local c0 = WeaponModels.gripC0(h)
		model:PivotTo(h.CFrame * c0)
		local weld = Instance.new("Weld")
		weld.Name = "GripWeld"
		weld.Part0 = h
		weld.Part1 = model.PrimaryPart
		weld.C0 = c0
		weld.Parent = model.PrimaryPart
		model.Parent = folder
	end
	folder.Parent = rig
	return weaponId
end

local function showModel(viewport, world, camera, model, height)
	model.Parent = world
	model:PivotTo(CFrame.Angles(0, math.rad(-35), 0))
	camera.CFrame = CFrame.lookAt(Vector3.new(0, height * 0.55, -height * 1.6), Vector3.new(0, height * 0.5, 0))
	camera.FieldOfView = 40
	viewport.CurrentCamera = camera
end

local function preview(viewport, world, camera, placeholder, legendId)
	clearPreview(world)
	placeholder.Visible = false

	if Legends.usesAvatar(legendId) then
		-- A copy of your own character (in the lobby it's your plain avatar).
		local character = Players.LocalPlayer.Character
		local model = nil
		if character and character:FindFirstChild("HumanoidRootPart") then
			local archivable = character.Archivable
			character.Archivable = true
			local ok, copy = pcall(function()
				return character:Clone()
			end)
			character.Archivable = archivable
			model = ok and copy or nil
		end
		if not model then
			placeholder.Visible = true
			return
		end
		for _, d in model:GetDescendants() do
			if d:IsA("LuaSourceContainer") or d:IsA("BillboardGui") or d:IsA("Trail") or d:IsA("Sound") then
				d:Destroy()
			elseif d:IsA("BasePart") then
				d.Anchored = d.Name == "HumanoidRootPart"
				d.LocalTransparencyModifier = 0
			end
		end
		model.PrimaryPart = model:FindFirstChild("HumanoidRootPart")
		local feet = model:FindFirstChildOfClass("Humanoid") and model.PrimaryPart.Size.Y / 2 + model:FindFirstChildOfClass("Humanoid").HipHeight or 3
		showModel(viewport, world, camera, model, 5.2)
		model:PivotTo(CFrame.new(0, feet, 0) * CFrame.Angles(0, math.rad(-35), 0))
		FighterAnimator.track(model, { preview = true, legend = "Avatar" })
		FighterAnimator.setLocomotion(model, "Idle")
		return
	end

	local rig = LegendRig.build(legendId, 5.6)
	if not rig then
		placeholder.Visible = true
		return
	end
	rig.PrimaryPart.Anchored = true
	local weaponId = holdWeapon(rig, legendId)
	showModel(viewport, world, camera, rig, 5.6)
	FighterAnimator.track(rig, { preview = true, legend = legendId, weapon = weaponId })
	FighterAnimator.setLocomotion(rig, "Idle")
end

-- Panel -------------------------------------------------------------------

function FightersPanel.create(gui, close)
	local window, body = UIKit.window(gui, "Fighters", close)
	local selected = nil

	local list = UIKit.scroll({ Size = UDim2.new(0.36, -8, 1, 0), Parent = body })
	make("UIGridLayout", {
		CellSize = UDim2.new(0.5, -6, 0, 84),
		CellPadding = UDim2.fromOffset(8, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = list,
	})

	local detail = UIKit.panel({
		BackgroundColor3 = T.Panel,
		Position = UDim2.new(0.36, 4, 0, 0),
		Size = UDim2.new(0.64, -4, 1, 0),
		Parent = body,
	})

	local viewport = make("ViewportFrame", {
		BackgroundColor3 = T.PanelLight,
		BackgroundTransparency = 0.2,
		Size = UDim2.new(0.45, 0, 1, -16),
		Position = UDim2.fromOffset(8, 8),
		Ambient = Color3.fromRGB(170, 170, 185),
		LightColor = Color3.fromRGB(255, 250, 240),
		LightDirection = Vector3.new(-0.4, -1, 0.6),
		Parent = detail,
	}, { UIKit.corner(10) })
	local world = make("WorldModel", { Parent = viewport })
	local camera = make("Camera", { Parent = viewport })
	local placeholder = UIKit.heading("", 22, {
		Size = UDim2.fromScale(1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextWrapped = true,
		Visible = false,
		Parent = viewport,
	})

	local info = make("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.new(0.45, 16, 0, 8),
		Size = UDim2.new(0.55, -24, 1, -16),
		Parent = detail,
	})

	UIKit.list(Enum.FillDirection.Vertical, 6).Parent = info

	local function renderDetail()
		UIKit.clear(info)
		local legend = Legends.get(selected)
		UIKit.heading(legend.Name, 30, { LayoutOrder = 1, Size = UDim2.new(1, 0, 0, 34), TextColor3 = legend.Color, Parent = info })
		UIKit.label(legend.Title, 16, { LayoutOrder = 2, Size = UDim2.new(1, 0, 0, 20), Font = T.BoldFont, Parent = info })
		UIKit.label(legend.Description, 15, {
			LayoutOrder = 3,
			Size = UDim2.new(1, 0, 0, 40),
			TextWrapped = true,
			TextYAlignment = Enum.TextYAlignment.Top,
			Parent = info,
		})
		for i, name in Legends.StatNames do
			statBar(name, legend.Stats[name], 3 + i, info)
		end
		local weaponsText = legend.Weapons and (legend.Weapons[1] .. "  +  " .. legend.Weapons[2]) or "Any weapon you pick up"
		UIKit.heading("Weapons: " .. weaponsText, 17, { LayoutOrder = 10, Size = UDim2.new(1, 0, 0, 24), Parent = info })
		if legend.Weapons then
			local lines = {}
			for _, weapon in legend.Weapons do
				local sigs = {}
				for _, slot in Legends.SignatureSlots do
					table.insert(sigs, Legends.signatureName(legend.Id, weapon, slot) or "?")
				end
				table.insert(lines, weapon .. ": " .. table.concat(sigs, ", "))
			end
			UIKit.label("Signatures\n" .. table.concat(lines, "\n"), 14, {
				LayoutOrder = 11,
				Size = UDim2.new(1, 0, 0, 58),
				TextWrapped = true,
				TextYAlignment = Enum.TextYAlignment.Top,
				Parent = info,
			})
		end
		local profile = ClientState.profile
		local current = profile and profile.Legend == legend.Id
		local button = UIKit.button(current and "Selected" or "Select", current and "ghost" or "primary", function()
			local ok, message = Net.get("SelectLegend"):InvokeServer(legend.Id)
			if ok then
				ClientState.toast(legend.Name .. " selected for your next match.", "good")
			else
				ClientState.toast(message or "Couldn't select that fighter.", "error")
			end
		end, { LayoutOrder = 12, Size = UDim2.new(1, 0, 0, 40), TextSize = 18, Parent = info })
		if current then
			UIKit.setEnabled(button, false)
		end
		placeholder.Text = legend.Id == "Avatar" and "Your avatar"
			or (legend.Name .. "\n\n(3D model not imported yet: see art/IMPORTING.md)")
		placeholder.TextColor3 = legend.Color
	end

	local function choose(id)
		selected = id
		renderDetail()
		preview(viewport, world, camera, placeholder, id)
	end

	local function renderList()
		UIKit.clear(list, { "UIGridLayout" })
		local profile = ClientState.profile
		for i, id in Legends.Order do
			local legend = Legends.List[id]
			local card = UIKit.button("", "secondary", function()
				choose(id)
			end, { LayoutOrder = i, Parent = list })
			make("Frame", {
				BackgroundColor3 = legend.Color,
				BorderSizePixel = 0,
				Size = UDim2.new(0, 6, 1, -16),
				Position = UDim2.fromOffset(8, 8),
				Parent = card,
			}, { UIKit.corner(3) })
			UIKit.heading(legend.Name, 18, { Position = UDim2.fromOffset(22, 10), Size = UDim2.new(1, -28, 0, 22), Parent = card })
			UIKit.label(legend.Title, 13, { Position = UDim2.fromOffset(22, 34), Size = UDim2.new(1, -28, 0, 18), Parent = card })
			if profile and profile.Legend == id then
				UIKit.label("SELECTED", 12, {
					Position = UDim2.fromOffset(22, 54),
					Size = UDim2.new(1, -28, 0, 16),
					TextColor3 = T.Gold,
					Font = T.BoldFont,
					Parent = card,
				})
			end
		end
	end

	ClientState.ProfileChanged:Connect(function()
		if window.Visible then
			renderList()
			if selected then
				renderDetail()
			end
		end
	end)

	return {
		window = window,
		open = function()
			window.Visible = true
			renderList()
			local profile = ClientState.profile
			choose((profile and profile.Legend) or Legends.Default)
		end,
		close = function()
			window.Visible = false
			clearPreview(world)
		end,
	}
end

return FightersPanel
