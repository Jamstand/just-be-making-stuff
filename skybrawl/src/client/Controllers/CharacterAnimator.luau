--[[
    Locomotion animations for your own character outside the fight: it
    follows the Humanoid's state like Roblox's default Animate script.
    There is no lobby, so this only covers a character loaded for a match
    while it waits on the spawn pad (the VS splash); once the match starts
    it stops, and FighterAnimator animates every fighter instead.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Locomotion = require(Shared.Locomotion)

local CharacterAnimator = {}

local player = Players.LocalPlayer
local locomotion = nil
local humanoid = nil
local matchMode = false

local function onCharacter(character)
	if locomotion then
		locomotion:Destroy()
		locomotion = nil
	end
	matchMode = false
	humanoid = character:WaitForChild("Humanoid", 10)
	if not humanoid then
		return
	end
	locomotion = Locomotion.new(humanoid, false)
	locomotion:Play("Idle")
end

local function lobbyUpdate()
	if matchMode or not locomotion or not humanoid or humanoid.Health <= 0 then
		return
	end
	local state = humanoid:GetState()
	local S = Enum.HumanoidStateType
	if state == S.Jumping then
		locomotion:Play("Jump")
	elseif state == S.Freefall then
		locomotion:Play("Fall")
	elseif state == S.Climbing then
		locomotion:Play(
			"Climb",
			math.max(0.4, humanoid.RootPart and humanoid.RootPart.AssemblyLinearVelocity.Magnitude / 12 or 1)
		)
	elseif state == S.Seated then
		locomotion:Play("Sit")
	elseif state == S.Swimming then
		locomotion:Play("Swim")
	else
		local root = humanoid.RootPart
		local speed = root and Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z).Magnitude
			or 0
		if speed > 0.75 and humanoid.MoveDirection.Magnitude > 0 then
			locomotion:Play("Run", math.max(0.5, speed / 16))
		else
			locomotion:Play("Idle")
		end
	end
end

-- In matches FighterAnimator drives every joint, so Roblox's tracks stop.
function CharacterAnimator.setMatchMode(value)
	matchMode = value
	if value and locomotion then
		locomotion:Stop()
	end
end

function CharacterAnimator.setState(name, speed)
	if locomotion and not matchMode then
		locomotion:Play(name, speed)
	end
end

function CharacterAnimator.init()
	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		task.spawn(onCharacter, player.Character)
	end
	RunService.Heartbeat:Connect(lobbyUpdate)
end

return CharacterAnimator
