-- Towel: everyone's defense. A Towel Snap tool (1s cooldown) knocks back the nearest carrier
-- in front of you and sends the sock straight back to its owner's drawer.
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")

local Towel = {}
local S

local lastSnap = {} -- Player -> os.clock()

local function buildTool(): Tool
	local tool = Instance.new("Tool")
	tool.Name = "Towel Snap"
	tool.ToolTip = "Snap a thief to make them drop the sock"
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.7, 0.7, 3.4)
	handle.Color = Color3.fromRGB(120, 200, 255)
	handle.Material = Enum.Material.Fabric
	handle.CanCollide = false
	handle.Massless = true
	handle.Parent = tool
	local tip = Instance.new("Part")
	tip.Name = "Tip"
	tip.Size = Vector3.new(0.9, 0.9, 0.9)
	tip.Shape = Enum.PartType.Ball
	tip.Color = Color3.fromRGB(255, 255, 255)
	tip.Material = Enum.Material.Fabric
	tip.CanCollide = false
	tip.Massless = true
	tip.CFrame = handle.CFrame * CFrame.new(0, 0, -1.9)
	tip.Parent = tool
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = handle
	weld.Part1 = tip
	weld.Parent = tip
	tool.Grip = CFrame.new(0, 0, 1.2)
	return tool
end

function Towel.Init(s)
	S = s
end

function Towel.Setup(player: Player)
	local function give(character)
		local backpack = player:WaitForChild("Backpack", 5)
		if not backpack then
			return
		end
		if backpack:FindFirstChild("Towel Snap") or character:FindFirstChild("Towel Snap") then
			return
		end
		local tool = buildTool()
		tool.Activated:Connect(function()
			Towel.Snap(player)
		end)
		tool.Parent = backpack
	end
	player.CharacterAdded:Connect(give)
	if player.Character then
		task.spawn(give, player.Character)
	end
end

function Towel.OnPlayerRemoving(player: Player)
	lastSnap[player] = nil
end

function Towel.Snap(player: Player)
	if not S.Ready then
		return
	end
	local now = os.clock()
	if lastSnap[player] and now - lastSnap[player] < S.Config.Economy.TowelCooldown then
		return
	end
	lastSnap[player] = now
	local character = player.Character
	local myRoot = character and character:FindFirstChild("HumanoidRootPart")
	if not myRoot then
		return
	end
	local look = myRoot.CFrame.LookVector
	local best, bestDist = nil, S.Config.Economy.TowelRange
	for thief in pairs(S.Steal.Carriers()) do
		if thief ~= player and thief.Character then
			local theirRoot = thief.Character:FindFirstChild("HumanoidRootPart")
			if theirRoot then
				local offset = theirRoot.Position - myRoot.Position
				local dist = offset.Magnitude
				if dist <= bestDist and dist > 0 and look:Dot(offset.Unit) > 0.1 then
					best, bestDist = thief, dist
				end
			end
		end
	end
	if not best then
		return
	end
	local theirRoot = best.Character:FindFirstChild("HumanoidRootPart")
	local theirHumanoid = best.Character:FindFirstChildOfClass("Humanoid")
	local Eco = S.Config.Economy
	S.Steal.Return(best, "snapped")
	if theirRoot and theirHumanoid then
		local away = (theirRoot.Position - myRoot.Position) * Vector3.new(1, 0, 1)
		local dir = if away.Magnitude > 0 then away.Unit else look
		local attachment = Instance.new("Attachment")
		attachment.Parent = theirRoot
		local push = Instance.new("LinearVelocity")
		push.Attachment0 = attachment
		push.MaxForce = math.huge
		push.RelativeTo = Enum.ActuatorRelativeTo.World
		push.VectorVelocity = dir * Eco.TowelKnockback + Vector3.new(0, Eco.TowelKnockUp, 0)
		push.Parent = theirRoot
		Debris:AddItem(push, 0.2)
		Debris:AddItem(attachment, 0.3)
		theirHumanoid.WalkSpeed = 0
		task.delay(Eco.TowelStunSeconds, function()
			if best.Parent == Players then
				S.Steal.ApplySpeed(best)
			end
		end)
	end
	S.Toast(player, "SNAP! You got " .. best.DisplayName .. "! 🏓", "good")
end

return Towel
