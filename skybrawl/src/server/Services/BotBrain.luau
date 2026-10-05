--[[
    AI for bot fighters. Each frame it produces an input table for
    FighterSim, exactly like a player's controller would.

    It re-decides every `Reaction` seconds (faster while recovering), so
    difficulty mostly comes from reaction time, how often it dodges, and
    how well it gets back to the stage.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Maps = require(Shared.Maps)
local Weapons = require(Shared.Weapons)

local BotBrain = {}
BotBrain.__index = BotBrain

local function sign(x)
	if x > 0 then
		return 1
	elseif x < 0 then
		return -1
	end
	return 0
end

function BotBrain.new(fighter, match, difficulty)
	local self = setmetatable({}, BotBrain)
	self.fighter = fighter
	self.match = match
	self.difficulty = Config.Bots.Difficulties[difficulty] and difficulty or "Normal"
	self.skill = Config.Bots.Difficulties[self.difficulty]
	self.rng = Random.new()
	self.thinkTimer = 0
	self.input = {
		moveX = 0,
		moveY = 0,
		jumpHeld = true,
		heavyHeld = false,
		buffer = { Jump = 0, Light = 0, Heavy = 0, Dodge = 0, Throw = 0 },
	}
	-- The main stage: the widest solid platform.
	local best
	for _, p in match.world.platforms do
		if not p.soft and (not best or p.maxX - p.minX > best.maxX - best.minX) then
			best = p
		end
	end
	self.mainStage = best
	return self
end

function BotBrain:press(action)
	self.input.buffer[action] = Config.InputBufferTime
end

function BotBrain:groundAhead(x, y, dir, distance)
	return Maps.groundBelow(self.match.world, x + dir * distance, y + 0.5) ~= nil
end

-- Nearest solid platform edge to aim for when off stage.
function BotBrain:recoveryTarget(s)
	local bestX, bestY, bestDist
	for _, p in self.match.world.platforms do
		if not p.soft then
			local tx = math.clamp(s.x, p.minX + 3, p.maxX - 3)
			local ty = p.maxY
			local d = math.abs(tx - s.x) + math.max(0, ty - s.y) * 0.5
			if not bestDist or d < bestDist then
				bestX, bestY, bestDist = tx, ty, d
			end
		end
	end
	return bestX or 0, bestY or 0
end

function BotBrain:isOffstage(s)
	if s.grounded then
		return false
	end
	return Maps.groundBelow(self.match.world, s.x, s.y + 0.1) == nil
end

function BotBrain:recover(s)
	local input = self.input
	local tx, ty = self:recoveryTarget(s)
	local dx = tx - s.x
	input.moveX = sign(dx)
	input.moveY = 0
	self.thinkTimer = 0.06

	if self.rng:NextNumber() > self.skill.Recovery then
		return
	end
	local below = s.y < ty + 4
	if s.wallTouch ~= 0 and s.wallJumps > 0 and s.vy < 4 then
		input.moveX = s.wallTouch
		self:press("Jump")
	elseif below and s.vy < 6 and s.action == nil then
		if s.airJumps > 0 then
			self:press("Jump")
		elseif not s.recoveryUsed and math.abs(dx) < 22 then
			input.moveY = 1
			self:press("Heavy")
		elseif not s.airDodgeUsed and s.dodgeCooldown <= 0 and math.abs(dx) < 30 then
			input.moveY = 0.7
			self:press("Dodge")
		end
	end
end

function BotBrain:pickTarget(s)
	local best, bestDist
	for _, other in self.match.fighters do
		if
			other ~= self.fighter
			and other.alive
			and not other.eliminated
			and not self.match:SameTeam(self.fighter, other)
		then
			local ox, oy = self.match:GetPosition(other)
			local d = math.abs(ox - s.x) + math.abs(oy - s.y) * 0.7
			if not best or d < bestDist then
				best, bestDist = other, d
			end
		end
	end
	return best
end

function BotBrain:nearestPickup(s)
	local best, bestDist
	for _, pickup in self.match.pickups do
		if not pickup.falling then
			local d = math.abs(pickup.x - s.x) + math.abs(pickup.y - s.y)
			if d < 30 and (not best or d < bestDist) then
				best, bestDist = pickup, d
			end
		end
	end
	return best, bestDist
end

function BotBrain:fight(s, target)
	local input = self.input
	local rng = self.rng
	local skill = self.skill
	local tx, ty = self.match:GetPosition(target)
	local dx, dy = tx - s.x, ty - s.y
	local dist = math.abs(dx)
	local weaponId = self.fighter.weapon
	local armed = Weapons.isWeapon(weaponId)
	local reach = armed and 6 or 4
	if weaponId == "Spear" then
		reach = 8
	end

	input.moveX = 0
	input.moveY = 0

	-- Dodge incoming attacks.
	if self.match:IsAttacking(target) and dist < 9 and math.abs(dy) < 7 and rng:NextNumber() < skill.DodgeChance then
		if s.grounded and rng:NextNumber() < 0.5 then
			input.moveX = -sign(dx)
		end
		self:press("Dodge")
		return
	end

	-- Bows shoot from range.
	if
		weaponId == "Bow"
		and dist > 8
		and dist < 40
		and math.abs(dy) < 4
		and rng:NextNumber() < skill.Aggression * 0.6
	then
		input.moveX = sign(dx) * 0.5
		self:press("Light")
		return
	end

	if dist <= reach and math.abs(dy) < 5 and rng:NextNumber() < skill.Aggression then
		local heavy = rng:NextNumber() < skill.HeavyChance * (target.damage > 90 and 1.6 or 0.6)
		if rng:NextNumber() > skill.Accuracy then
			-- Sloppy: random direction.
			input.moveX = rng:NextInteger(-1, 1)
			input.moveY = rng:NextInteger(-1, 0)
		elseif dy > 3 then
			input.moveY = 1
		elseif dy < -2.5 and not s.grounded then
			input.moveY = -1
		else
			input.moveX = sign(dx)
		end
		if heavy and s.grounded then
			self:press("Heavy")
		else
			self:press("Light")
		end
		return
	end

	-- Close the distance, but don't run off the stage.
	local dir = sign(dx)
	if dist > reach * 0.7 then
		if s.grounded and not self:groundAhead(s.x, s.y, dir, 3) and ty < s.y - 1 then
			input.moveX = 0
		else
			input.moveX = dir
		end
	end
	local groundJump = dy > 5 and s.grounded and rng:NextNumber() < 0.7
	local airJump = dy > 7 and not s.grounded and s.vy < 0 and s.airJumps > 0
	if groundJump or airJump then
		self:press("Jump")
	elseif dy < -4 and s.onSoft and rng:NextNumber() < 0.5 then
		input.moveY = -1
	end
end

function BotBrain:Decide()
	local fighter = self.fighter
	local s = fighter.state
	local input = self.input
	input.jumpHeld = true
	input.heavyHeld = false

	if self:isOffstage(s) then
		self:recover(s)
		return
	end

	self.thinkTimer = self.skill.Reaction * (0.6 + self.rng:NextNumber() * 0.8)

	local target = self:pickTarget(s)

	if not Weapons.isWeapon(fighter.weapon) then
		local pickup, pickupDist = self:nearestPickup(s)
		local targetClose = target and math.abs(self.match:GetPosition(target) - s.x) < 6
		if pickup and not targetClose then
			local dx = pickup.x - s.x
			input.moveY = 0
			if math.abs(dx) < Config.WeaponDrops.PickupRange - 1 and math.abs(pickup.y - s.y) < 4 then
				input.moveX = 0
				self:press("Throw")
			else
				input.moveX = sign(dx)
				if pickup.y > s.y + 4 and s.grounded then
					self:press("Jump")
				end
			end
			self.thinkTimer = math.min(self.thinkTimer, 0.15)
			if pickupDist then
				return
			end
		end
	end

	if target then
		self:fight(s, target)
	else
		input.moveX = 0
		input.moveY = 0
	end
end

function BotBrain:Update(dt)
	local buffer = self.input.buffer
	for action, remaining in buffer do
		buffer[action] = math.max(0, remaining - dt)
	end
	self.thinkTimer -= dt
	if self.thinkTimer <= 0 then
		self:Decide()
	end
	return self.input
end

return BotBrain
