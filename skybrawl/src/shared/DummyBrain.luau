--[[
    The training dummy's brain (menus design 4.11): a FighterSim input table
    each frame, like BotBrain's, for the behaviour picked in the training
    panel.

      Stand   no input at all
      Jump    on the ground, jumps every Config.Training.JumpInterval
      Dodge   spot-dodges when the other team's fighter attacks within
              Config.Training.DodgeRange
      Block   turns to face that fighter (a frame of movement toward it),
              then holds block; FighterSim blocks only on the ground and
              only hits from the front
      Fight   the bot brain (`fight`) fights back

    Knocked off the stage, a dummy recovers through the bot brain when
    Config.Training.DummyRecovers is on (Fight always does), so it comes
    back to be hit again.

    Pure: no services, no clocks. `match` is read the way BotBrain reads it
    (fighters, GetPosition, IsAttacking, SameTeam); `fight` is anything with
    Update(dt) and isOffstage(state) (and optionally Wake()), normally a
    BotBrain.
]]

local Config = require(script.Parent.Config)

local DummyBrain = {}
DummyBrain.__index = DummyBrain

DummyBrain.MODES = { "Stand", "Jump", "Dodge", "Block", "Fight" }

local function sign(x)
	if x > 0 then
		return 1
	elseif x < 0 then
		return -1
	end
	return 0
end

local function isMode(mode)
	return type(mode) == "string" and table.find(DummyBrain.MODES, mode) ~= nil
end

function DummyBrain.new(fighter, match, opts)
	opts = opts or {}
	local self = setmetatable({}, DummyBrain)
	self.fighter = fighter
	self.match = match
	self.fight = opts.fight
	self.mode = if isMode(opts.mode) then opts.mode else Config.Training.DefaultMode
	self.input = {
		moveX = 0,
		moveY = 0,
		jumpHeld = false,
		heavyHeld = false,
		blockHeld = false,
		buffer = { Jump = 0, Light = 0, Heavy = 0, Dodge = 0, Throw = 0, Ultimate = 0 },
	}
	self.jumpTimer = Config.Training.JumpInterval
	self.recovering = false
	return self
end

-- Switches behaviour (ignored when `mode` isn't one of MODES); presses still buffered are dropped.
function DummyBrain:setMode(mode)
	if not isMode(mode) or mode == self.mode then
		return
	end
	self.mode = mode
	self.jumpTimer = Config.Training.JumpInterval
	for action in self.input.buffer do
		self.input.buffer[action] = 0
	end
end

function DummyBrain:setFight(fight)
	self.fight = fight
end

-- The nearest fighter of another team that is still in the fight.
function DummyBrain:target()
	local match, me = self.match, self.fighter
	local s = me.state
	local best, bestDist
	for _, other in match.fighters do
		if other ~= me and other.alive and not other.eliminated and not match:SameTeam(me, other) then
			local ox, oy = match:GetPosition(other)
			local d = math.abs(ox - s.x) + math.abs(oy - s.y)
			if not best or d < bestDist then
				best, bestDist = other, d
			end
		end
	end
	return best
end

function DummyBrain:Update(dt)
	local input = self.input
	local buffer = input.buffer
	for action, remaining in buffer do
		buffer[action] = math.max(0, remaining - dt)
	end
	input.moveX, input.moveY = 0, 0
	input.jumpHeld, input.heavyHeld, input.blockHeld = false, false, false

	local s = self.fighter.state
	if not s then
		return input
	end
	local fight = self.fight
	if fight and (self.mode == "Fight" or (Config.Training.DummyRecovers and fight:isOffstage(s))) then
		if self.mode ~= "Fight" and not self.recovering and fight.Wake then
			-- decide at once: the bot brain may still be waiting out a decision from long ago
			fight:Wake()
		end
		self.recovering = self.mode ~= "Fight"
		return fight:Update(dt)
	end
	self.recovering = false

	if self.mode == "Jump" then
		self.jumpTimer -= dt
		input.jumpHeld = true -- full jumps
		if s.grounded and self.jumpTimer <= 0 then
			buffer.Jump = Config.InputBufferTime
			self.jumpTimer = Config.Training.JumpInterval
		end
	elseif self.mode == "Dodge" then
		local target = self:target()
		if target then
			local tx, ty = self.match:GetPosition(target)
			local dx, dy = tx - s.x, ty - s.y
			if dx * dx + dy * dy <= Config.Training.DodgeRange ^ 2 and self.match:IsAttacking(target) then
				buffer.Dodge = Config.InputBufferTime -- moveX stays 0: a spot dodge
			end
		end
	elseif self.mode == "Block" then
		local target = self:target()
		local dir = 0
		if target then
			dir = sign(self.match:GetPosition(target) - s.x)
		end
		if s.grounded and dir ~= 0 and s.facing ~= dir then
			-- block only stops hits from the front: let go and turn this frame, block from the next
			input.moveX = dir
		else
			input.blockHeld = true
		end
	end
	return input
end

return DummyBrain
