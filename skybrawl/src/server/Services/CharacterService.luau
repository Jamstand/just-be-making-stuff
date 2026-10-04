--[[
    Character setup shared by players and bots: collision groups,
    nameplates (name, level, title, team color) and cosmetic trails.

    Collision groups:
      Characters  never collide with each other or with arena parts. In
                  matches FighterSim handles all collision; in the lobby
                  characters still stand on Default parts.
      Arena       stage visuals (collision is done in code)
]]

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Cosmetics = require(Shared.Cosmetics)
local Ranks = require(Shared.Ranks)

local CharacterService = {}
local services

local GROUP_CHARACTERS = "Characters"
local GROUP_ARENA = "Arena"
CharacterService.GROUP_ARENA = GROUP_ARENA

local function setupGroups()
	for _, name in { GROUP_CHARACTERS, GROUP_ARENA } do
		pcall(function()
			PhysicsService:RegisterCollisionGroup(name)
		end)
	end
	PhysicsService:CollisionGroupSetCollidable(GROUP_CHARACTERS, GROUP_CHARACTERS, false)
	PhysicsService:CollisionGroupSetCollidable(GROUP_CHARACTERS, GROUP_ARENA, false)
	PhysicsService:CollisionGroupSetCollidable(GROUP_ARENA, GROUP_ARENA, false)
end

local function setGroup(instance)
	if instance:IsA("BasePart") then
		instance.CollisionGroup = GROUP_CHARACTERS
	end
end

-- Nameplate ---------------------------------------------------------------

local function makeLabel(name, parent, size, position, font, textSize)
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Size = size
	label.Position = position
	label.Font = font
	label.TextSize = textSize
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.35
	label.TextStrokeColor3 = Color3.fromRGB(10, 14, 30)
	label.Parent = parent
	return label
end

function CharacterService.setNameplate(character, info)
	local head = character:FindFirstChild("Head")
	if not head then
		return
	end
	local gui = head:FindFirstChild("Nameplate")
	if not gui then
		gui = Instance.new("BillboardGui")
		gui.Name = "Nameplate"
		gui.Size = UDim2.fromOffset(220, 46)
		gui.StudsOffset = Vector3.new(0, 2.4, 0)
		gui.AlwaysOnTop = true
		gui.LightInfluence = 0
		gui.MaxDistance = 100000
		makeLabel("PlayerName", gui, UDim2.new(1, 0, 0, 24), UDim2.fromOffset(0, 0), Enum.Font.FredokaOne, 20)
		makeLabel("Info", gui, UDim2.new(1, 0, 0, 18), UDim2.fromOffset(0, 24), Enum.Font.GothamBold, 13)
		gui.Parent = head
	end
	gui.PlayerName.Text = info.name or character.Name
	gui.PlayerName.TextColor3 = info.color or Color3.new(1, 1, 1)
	local parts = {}
	if info.level then
		table.insert(parts, "Lv " .. info.level)
	end
	if info.title then
		table.insert(parts, info.title)
	end
	gui.Info.Text = table.concat(parts, "  ·  ")
	gui.Info.TextColor3 = Color3.fromRGB(255, 225, 140)
end

local function playerInfo(player)
	local profile = services.DataService.get(player)
	local info = { name = player.DisplayName }
	if profile then
		info.level = Ranks.levelFromXP(profile.XP)
		local title = Cosmetics.resolve("Title", profile.Equipped.Title)
		info.title = title and title.Name
	end
	local character = player.Character
	local teamColor = character and character:GetAttribute("TeamColor")
	if typeof(teamColor) == "Color3" then
		info.color = teamColor
	end
	return info
end

function CharacterService.refreshNameplate(player)
	local character = player.Character
	if character then
		CharacterService.setNameplate(character, playerInfo(player))
	end
end

function CharacterService.setTeamColor(character, color)
	character:SetAttribute("TeamColor", color)
	local player = Players:GetPlayerFromCharacter(character)
	if player then
		CharacterService.refreshNameplate(player)
	else
		local gui = character:FindFirstChild("Head") and character.Head:FindFirstChild("Nameplate")
		if gui then
			gui.PlayerName.TextColor3 = color or Color3.new(1, 1, 1)
		end
	end
end

-- Character setup ---------------------------------------------------------

function CharacterService.setupCharacter(character)
	for _, d in character:GetDescendants() do
		setGroup(d)
	end
	character.DescendantAdded:Connect(setGroup)
	local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
		humanoid.BreakJointsOnDeath = false
	end
end

-- Trails ------------------------------------------------------------------

function CharacterService.applyTrail(character, trailId)
	CharacterService.removeTrail(character)
	local item = Cosmetics.resolve("Trail", trailId)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not item or not item.Colors or not root then
		return
	end
	local a0 = Instance.new("Attachment")
	a0.Name = "CosmeticTrailTop"
	a0.Position = Vector3.new(0, 1.2, 0)
	a0.Parent = root
	local a1 = Instance.new("Attachment")
	a1.Name = "CosmeticTrailBottom"
	a1.Position = Vector3.new(0, -1.6, 0)
	a1.Parent = root

	local keypoints = {}
	local count = #item.Colors
	for i, color in item.Colors do
		table.insert(keypoints, ColorSequenceKeypoint.new(count == 1 and 0 or (i - 1) / (count - 1), color))
	end
	if count == 1 then
		table.insert(keypoints, ColorSequenceKeypoint.new(1, item.Colors[1]))
	end

	local trail = Instance.new("Trail")
	trail.Name = "CosmeticTrail"
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Color = ColorSequence.new(keypoints)
	trail.Transparency = NumberSequence.new(0.2, 1)
	trail.Lifetime = 0.35
	trail.MinLength = 0.1
	trail.LightEmission = 0.5
	trail.FaceCamera = true
	trail.Parent = root
end

function CharacterService.removeTrail(character)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	for _, name in { "CosmeticTrail", "CosmeticTrailTop", "CosmeticTrailBottom" } do
		local existing = root:FindFirstChild(name)
		if existing then
			existing:Destroy()
		end
	end
end

-- Lifecycle ---------------------------------------------------------------

function CharacterService.init(s)
	services = s
	setupGroups()
end

function CharacterService.start()
	local function onPlayer(player)
		player.CharacterAdded:Connect(function(character)
			CharacterService.setupCharacter(character)
			character:WaitForChild("Head", 5)
			CharacterService.refreshNameplate(player)
		end)
		if player.Character then
			CharacterService.setupCharacter(player.Character)
			CharacterService.refreshNameplate(player)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	services.DataService.ProfileLoaded:Connect(function(player)
		CharacterService.refreshNameplate(player)
	end)
end

return CharacterService
