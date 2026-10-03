-- Towel: everyone's defense, slot 1 of the item bar (Items.luau gives the tool and runs UseItem's
-- checks and cooldown). A snap hits the nearest THIEF in the cone in front of you first: full
-- knockback, a short stun, a tumble, and the sock arcs straight back to its owner's drawer.
-- With no thief in reach it shoves the nearest other player (ItemConfig.ShoveMult of the knockback,
-- no stun, ShoveGrace before they can be pushed again). Reach and knockback come from Upgrades
-- (Towel Snap levels, Golden Towel pass). The towel's look follows the Towel Snap level
-- (ItemConfig.TowelLooks: Plain -> Champion); the Golden Towel pass shows the Royal Towel.
local Players = game:GetService("Players")

local Towel = {}
local S

local SHOVE_TUMBLE = 0.45 -- seconds a shoved (not stunned) player stumbles on the clients

function Towel.Init(s)
	S = s
end

-- ItemConfig.TowelLooks[Towel Snap level + 1], or ItemConfig.TowelRoyal with the Golden Towel pass.
function Towel.Look(player: Player): string
	local Item = S.Config.Item
	if S.Monetize and S.Monetize.Owns(player, "GoldenTowel") then
		return Item.TowelRoyal
	end
	local level = if S.Upgrades then S.Upgrades.Level(player, "Towel") else 0
	return Item.TowelLooks[level + 1] or Item.TowelLooks[#Item.TowelLooks]
end

-- Re-skins the player's towel (Golden Towel pass bought or found on join, a Towel Snap level).
function Towel.Refresh(player: Player)
	if S.Items then
		S.Items.RefreshTowel(player)
	end
end

function Towel.OnPlayerRemoving(_player: Player)
	-- nothing kept per player any more (Items keeps the cooldowns)
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function alive(player: Player): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

-- One snap toward `facing` (a horizontal unit vector: where the player aims, else where they face).
-- Every client sees the swing ("swing"); a hit adds the comic burst ("snap") and the tumble.
-- Returns the player it hit, or nil.
function Towel.Snap(player: Player, facing: Vector3?): Player?
	local Item = S.Config.Item
	local Eco = S.Config.Economy
	local myRoot = rootOf(player)
	if not myRoot then
		return nil
	end
	local dir = facing
	if not dir then
		local look = myRoot.CFrame.LookVector
		dir = if Vector3.new(look.X, 0, look.Z).Magnitude > 1e-3 then Vector3.new(look.X, 0, look.Z).Unit else Vector3.new(0, 0, -1)
	end
	local aim = dir :: Vector3
	local range = S.Upgrades.TowelRange(player)
	local carriers = S.Steal.Carriers()
	local thief, thiefDist = nil, math.huge
	local other, otherDist = nil, math.huge
	for _, p in ipairs(Players:GetPlayers()) do
		local theirRoot = rootOf(p)
		if p ~= player and theirRoot and alive(p) then
			local offset = theirRoot.Position - myRoot.Position
			local dist = offset.Magnitude
			local flat = Vector3.new(offset.X, 0, offset.Z)
			local inCone = flat.Magnitude < 1 or aim:Dot(flat.Unit) >= Item.TowelCone
			if dist <= range and inCone then
				if carriers[p] then
					if dist < thiefDist then
						thief, thiefDist = p, dist
					end
				elseif dist < otherDist and S.Items.CanShove(p) then
					other, otherDist = p, dist
				end
			end
		end
	end
	local target = thief or other
	local look = Towel.Look(player)
	S.Items.FX("swing", { player = player, key = "Towel", look = look, hit = target ~= nil })
	if not target then
		return nil
	end
	local theirRoot = rootOf(target)
	if not theirRoot then
		return nil
	end
	local position = theirRoot.Position
	local away = Vector3.new(position.X - myRoot.Position.X, 0, position.Z - myRoot.Position.Z)
	local push = if away.Magnitude > 1e-3 then away.Unit else aim
	local knock = Eco.TowelKnockback * S.Upgrades.TowelKnockbackMult(player)
	S.FX("snap", position, Color3.fromRGB(255, 255, 255)) -- the socks nearby flinch (SockAnim)
	S.Items.PopOut(target, "snap") -- a hidden player can still be snapped: the basket pops
	S.Items.FX("snap", { position = position, by = player, target = target, thief = thief ~= nil, look = look })
	if thief then
		S.Items.SendSockHome(target, "snapped")
		S.Items.Knock(target, push, knock, Eco.TowelKnockUp)
		S.Items.Stun(target, Eco.TowelStunSeconds)
		S.Items.FX("tumble", { player = target, dir = push, seconds = Eco.TowelStunSeconds + 0.35 })
		S.Toast(player, "SNAP! You got " .. target.DisplayName .. "! 🏓", "good")
	else
		S.Items.Knock(target, push, knock * Item.ShoveMult, Eco.TowelKnockUp * Item.ShoveMult)
		S.Items.FX("tumble", { player = target, dir = push, seconds = SHOVE_TUMBLE, soft = true })
	end
	return target
end

return Towel
