-- Towel: everyone's defense. A Towel Snap tool (1s cooldown) knocks back the nearest carrier
-- in front of you and sends the sock straight back to its owner's drawer. Reach and knockback
-- come from Upgrades (Towel Snap levels, Golden Towel pass); the Golden Towel is also gold.
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")

local Towel = {}
local S

local TOOL_NAME = "Towel Snap"
local GOLD = Color3.fromRGB(255, 200, 60)
local GOLD_TIP = Color3.fromRGB(255, 235, 140)

local lastSnap = {} -- Player -> os.clock()

-- Plain blue towel, or gold (Metal handle, Neon tip) with the Golden Towel pass.
local function skin(tool: Tool, golden: boolean)
	local handle = tool:FindFirstChild("Handle")
	local tip = tool:FindFirstChild("Tip")
	if handle and handle:IsA("BasePart") then
		handle.Color = if golden then GOLD else Color3.fromRGB(120, 200, 255)
		handle.Material = if golden then Enum.Material.Metal else Enum.Material.Fabric
	end
	if tip and tip:IsA("BasePart") then
		tip.Color = if golden then GOLD_TIP else Color3.fromRGB(255, 255, 255)
		tip.Material = if golden then Enum.Material.Neon else Enum.Material.Fabric
	end
	tool.ToolTip = if golden then "Golden Towel: longer reach, harder snap" else "Snap a thief to make them drop the sock"
	tool:SetAttribute("Golden", golden)
end

local function isGolden(player: Player): boolean
	return S.Monetize ~= nil and S.Monetize.Owns(player, "GoldenTowel")
end

local function buildTool(golden: boolean): Tool
	local tool = Instance.new("Tool")
	tool.Name = TOOL_NAME
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.7, 0.7, 3.4)
	handle.CanCollide = false
	handle.Massless = true
	handle.Parent = tool
	local tip = Instance.new("Part")
	tip.Name = "Tip"
	tip.Size = Vector3.new(0.9, 0.9, 0.9)
	tip.Shape = Enum.PartType.Ball
	tip.CanCollide = false
	tip.Massless = true
	tip.CFrame = handle.CFrame * CFrame.new(0, 0, -1.9)
	tip.Parent = tool
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = handle
	weld.Part1 = tip
	weld.Parent = tip
	tool.Grip = CFrame.new(0, 0, 1.2)
	skin(tool, golden)
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
		if backpack:FindFirstChild(TOOL_NAME) or character:FindFirstChild(TOOL_NAME) then
			return
		end
		local tool = buildTool(isGolden(player))
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

-- Re-skins the player's towel (Golden Towel pass bought, or found on join).
function Towel.Refresh(player: Player)
	local golden = isGolden(player)
	local function reskin(container: Instance?)
		local tool = container and container:FindFirstChild(TOOL_NAME)
		if tool and tool:IsA("Tool") then
			skin(tool, golden)
		end
	end
	reskin(player:FindFirstChildOfClass("Backpack"))
	reskin(player.Character) -- an equipped tool sits in the character
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
	local best, bestDist = nil, S.Upgrades.TowelRange(player)
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
	if theirRoot then
		S.FX("snap", theirRoot.Position, Color3.fromRGB(255, 255, 255))
	end
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
		push.VectorVelocity = dir * Eco.TowelKnockback * S.Upgrades.TowelKnockbackMult(player) + Vector3.new(0, Eco.TowelKnockUp, 0)
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
