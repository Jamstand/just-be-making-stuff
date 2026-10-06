--[[
    FighterSim: deterministic 2D platform-fighter movement.

    The same code drives your own fighter on your client and every bot on
    the server. It knows nothing about Instances: state is plain numbers in
    arena-local coordinates (x/y is the fighter's feet), and the caller
    copies the result onto the character each frame.

    Input table:
      moveX, moveY   -1..1 (moveY +1 is up)
      jumpHeld, heavyHeld, blockHeld
      buffer         { Jump, Light, Heavy, Dodge, Throw, Ultimate } seconds
                     left on a buffered press; the sim zeroes an entry when
                     it uses it

    Context table:
      world          from Maps.getWorld
      weapon         weapon id ("Unarmed" when empty-handed)
      legend         legend id (signatures, Dexterity timing, Speed stat)
      armed          true when holding a weapon
      nearPickup     true when a weapon pickup is in reach
      ultimate       "Awaken" when the ultimate meter is full, "Attack" while
                     awakened with the ultimate move unused, else nil
      awakened       true while awakened (faster)

    Combo flow: the caller reports landed hits with onHitConfirm(); that
    opens the chase window (next dodge is a chase dodge), lets a light
    attack be cancelled into a jump or chase dodge once its active frames
    end, and starts the attacker's hit-stop. An air spot dodge allows ground
    light attacks in the air while it lasts (gravity cancel).

    Battlegrounds combat (Config.Battle): a neutral ground light starts a
    4-hit punch chain; holding block on the ground blocks hits from the
    front (the caller decides what's blocked and calls applyBlock or
    applyGuardBreak); strong hits tumble the fighter (applyHit's ragdoll),
    and landing while tumbling knocks them down unless they tech by pressing
    dodge just before landing; the ultimate button awakens or uses the
    ultimate move, depending on ctx.ultimate.

    step() appends events to the list it returns:
      { type = "Attack", slot, seq, facing }
      { type = "Release", seq, charge }       heavy charge released (0..1)
      { type = "Fire", seq, slot, charge, facing }  projectile moves
      { type = "Dodge", kind }                "Spot" | "Dash" | "Air" | "AirSpot" | "Chase"
      { type = "Jump", kind, cancel }         "Ground" | "Air" | "Wall"; cancel = out of an attack
      { type = "Throw", dirY, facing }
      { type = "Pickup" }
      { type = "Land" }
      { type = "AttackEnd", seq }
      { type = "Block", on, facing }          started or stopped blocking
      { type = "Knockdown" } / { type = "GetUp" } / { type = "Tech", dir }
      { type = "Awaken" }                     asked to awaken (the caller asks the server)
]]

local Config = require(script.Parent.Config)
local Legends = require(script.Parent.Legends)

local P = Config.Physics
local C = Config.Combat
local B = Config.Battle
local MAX_STEP = 1 / 60
local AXIS_DEADZONE = 0.35

local FighterSim = {}

local function sign(x)
	if x > 0 then
		return 1
	elseif x < 0 then
		return -1
	end
	return 0
end

local function approach(value, target, delta)
	if value < target then
		return math.min(value + delta, target)
	end
	return math.max(value - delta, target)
end

function FighterSim.newState(x, y, facing)
	return {
		x = x,
		y = y,
		vx = 0,
		vy = 0,
		facing = facing or 1,

		grounded = false,
		onSoft = false,
		wallTouch = 0, -- side of a wall we're pressed against (-1/1)
		wallSide = 0, -- side we're clinging to

		airJumps = P.MaxAirJumps,
		wallJumps = P.MaxWallJumps,
		recoveryUsed = false,
		groundPoundUsed = false,
		airDodgeUsed = false,
		dodgeCooldown = 0,
		dashCooldown = 0,

		action = nil, -- nil | "Attack" | "Dodge" | "Dash" | "Throw" | "Hitstun"
		actionTime = 0,
		actionDuration = 0,
		dodgeKind = nil,
		dodgeVX = 0,
		dodgeVY = 0,

		slot = nil,
		move = nil,
		seq = 0,
		charge = 0,
		charging = false,
		attackAir = false,
		motionTime = -1,
		fired = false,

		invuln = 0,
		hitstun = 0,
		hitstop = 0,
		hitConfirmSeq = -1, -- seq of the latest attack that landed a hit
		chaseTimer = 0,
		gcTimer = 0,
		gcAttack = false,
		dropThrough = 0,
		landLag = 0,
		fastFall = false,
		jumpTime = -1,
		prevMoveY = 0,
		lastMoveX = 0,
		frozen = false,

		chain = 0, -- last punch-chain hit started (1..3), 0 when not chaining
		chainTimer = 0, -- time left to continue the chain
		blockstun = 0,
		tumble = false, -- launched limp by a strong hit
		tumbleAir = 0, -- time airborne since the tumbling hit
		tumbleHold = 0, -- time spent limp after the hitstun ran out
		techTimer = 0, -- tech pressed this recently
		techDir = 0,
	}
end

local function emit(events, event)
	table.insert(events, event)
end

local function endAttack(s, events)
	if s.action == "Attack" then
		emit(events, { type = "AttackEnd", seq = s.seq })
		local chain = s.move and s.move.Chain
		if chain and chain < 4 then
			s.chain = chain
			s.chainTimer = B.ChainWindow
		else
			s.chain = 0
		end
	end
	s.action = nil
	s.move = nil
	s.slot = nil
	s.charging = false
	s.motionTime = -1
	s.gcAttack = false
end

local function chooseSlot(s, moveX, moveY, heavy)
	local side = math.abs(moveX) > AXIS_DEADZONE
	local down = moveY < -0.5
	if s.grounded or (s.gcTimer > 0 and not heavy) then
		if heavy then
			if down then
				return "DHeavy"
			elseif side then
				return "SHeavy"
			end
			return "NHeavy"
		end
		if down then
			return "DLight"
		elseif side then
			return "SLight"
		end
		-- neutral: the punch chain, ending in the neutral light
		if s.chain >= 1 and s.chainTimer > 0 then
			return s.chain >= 3 and "NLight" or "Chain" .. (s.chain + 1)
		end
		return "Chain1"
	end
	if heavy then
		if down then
			return "GroundPound"
		end
		return "Recovery"
	end
	if down then
		return "DAir"
	elseif side then
		return "SAir"
	end
	return "NAir"
end

local function startAttack(s, slot, ctx, moveX, events)
	local move = Legends.getAttack(ctx.legend, ctx.weapon, slot)
	if not move then
		return
	end
	if math.abs(moveX) > AXIS_DEADZONE then
		s.facing = sign(moveX)
	end
	s.action = "Attack"
	s.slot = slot
	s.move = move
	s.actionTime = 0
	s.charge = 0
	s.charging = (move.Charge or 0) > 0 and s.grounded
	s.attackAir = not s.grounded
	s.gcAttack = not s.grounded and not move.Air
	s.motionTime = -1
	s.fired = false
	s.fastFall = false
	s.chain = 0
	s.chainTimer = 0
	s.seq += 1
	if slot == "Recovery" then
		s.recoveryUsed = true
	elseif slot == "GroundPound" then
		s.groundPoundUsed = true
	end
	emit(events, { type = "Attack", slot = slot, seq = s.seq, facing = s.facing })
end

-- A light attack that hit can be cut short once its active frames are over.
local function cancelable(s)
	local move = s.move
	return s.action == "Attack"
		and move ~= nil
		and move.Kind == "Light"
		and s.hitConfirmSeq == s.seq
		and not s.charging
		and s.actionTime >= move.Startup + move.Active
end

local function speedMult(ctx)
	if not ctx then
		return 1
	end
	return Legends.speedMult(ctx.legend) * (ctx.awakened and B.AwakenSpeedMult or 1)
end

local function stat(ctx, name)
	if name == "speed" then
		return speedMult(ctx)
	end
	return Legends.dodgeCooldownMult(ctx.legend)
end

local function getUp(s, events)
	s.action = "GetUp"
	s.actionTime = 0
	s.actionDuration = B.GetUpTime
	s.invuln = math.max(s.invuln, B.GetUpTime)
	emit(events, { type = "GetUp" })
end

-- What a fighter that's blocking, stunned, down or awakening may do this
-- frame; returns true when it can't do anything else.
local function busy(s, input, moveX, events)
	local buf = input.buffer
	local action = s.action
	if action == "Knockdown" then
		local pressed = buf.Jump > 0 or buf.Dodge > 0 or buf.Light > 0 or buf.Heavy > 0
		if s.actionTime >= B.KnockdownMinTime and (pressed or math.abs(moveX) > 0.5) then
			buf.Jump, buf.Dodge, buf.Light, buf.Heavy = 0, 0, 0, 0
			getUp(s, events)
		end
		return true
	elseif action == "Stunned" or action == "GetUp" or action == "TechRoll" or action == "Awakening" then
		return true
	elseif action == "Block" then
		if s.blockstun > 0 then
			return true
		end
		if not input.blockHeld or buf.Dodge > 0 or not s.grounded then
			-- let go (or dodged out of it)
			s.action = nil
			emit(events, { type = "Block", on = false, facing = s.facing })
			return false
		end
		return true
	end
	return false
end

local function tryActions(s, input, moveX, moveY, ctx, events)
	local buf = input.buffer
	if busy(s, input, moveX, events) then
		return
	end

	-- Punch chain: the next hit can cut the last one's recovery short.
	local m = s.move
	local neutral = math.abs(moveX) <= AXIS_DEADZONE and moveY >= -0.5
	if
		s.action == "Attack"
		and m ~= nil
		and m.Chain ~= nil
		and m.Chain < 4
		and not s.charging
		and s.actionTime >= m.Startup + m.Active
		and buf.Light > 0
		and buf.Heavy <= 0
		and neutral
		and s.grounded
	then
		endAttack(s, events)
	end

	local canMove = (s.action == nil or s.action == "Dash") and s.landLag <= 0
	local cancel = cancelable(s)

	-- Ultimate: awaken (the caller asks the server), or the ultimate move.
	if (buf.Ultimate or 0) > 0 and canMove and ctx.ultimate then
		buf.Ultimate = 0
		if ctx.ultimate == "Attack" then
			s.action = nil
			startAttack(s, "Ultimate", ctx, moveX, events)
		else
			emit(events, { type = "Awaken" })
		end
		return
	end

	-- Block: hold on the ground. Attacks and jumps wait; a dodge breaks out.
	if input.blockHeld and s.grounded and canMove and buf.Dodge <= 0 then
		s.action = "Block"
		s.actionTime = 0
		s.blockstun = 0
		s.chain = 0
		s.chainTimer = 0
		buf.Jump, buf.Light, buf.Heavy = 0, 0, 0
		emit(events, { type = "Block", on = true, facing = s.facing })
		return
	end

	-- Jump (also cancels a dash, or a light attack that hit)
	if buf.Jump > 0 and (s.action == nil or s.action == "Dash" or cancel) then
		local jumped = false
		if s.grounded then
			s.action = nil
			s.vy = P.JumpVelocity
			s.grounded = false
			s.jumpTime = 0
			jumped = true
			emit(events, { type = "Jump", kind = "Ground", cancel = cancel })
		elseif s.wallSide ~= 0 and s.wallJumps > 0 then
			s.vy = P.WallJumpY
			s.vx = -s.wallSide * P.WallJumpX
			s.facing = -s.wallSide
			s.wallJumps -= 1
			s.wallSide = 0
			s.fastFall = false
			s.jumpTime = -1
			jumped = true
			emit(events, { type = "Jump", kind = "Wall", cancel = cancel })
		elseif s.airJumps > 0 then
			s.vy = P.AirJumpVelocity
			s.airJumps -= 1
			s.fastFall = false
			s.jumpTime = -1
			if math.abs(moveX) > AXIS_DEADZONE then
				s.vx = moveX * P.AirSpeed * stat(ctx, "speed")
				s.facing = sign(moveX)
			end
			jumped = true
			emit(events, { type = "Jump", kind = "Air", cancel = cancel })
		end
		if jumped then
			buf.Jump = 0
			if cancel then
				endAttack(s, events)
				cancel = false
			end
		end
	end

	-- Chase dodge: right after landing a hit, dodge becomes a quick burst
	-- toward where you're pointing. No invulnerability, no cooldown.
	if buf.Dodge > 0 and s.chaseTimer > 0 and (canMove or cancel) and s.landLag <= 0 then
		if cancel then
			endAttack(s, events)
		end
		local dx, dy = moveX, moveY
		if math.abs(dx) <= AXIS_DEADZONE and math.abs(dy) <= AXIS_DEADZONE then
			dx, dy = s.facing, 0
		end
		local len = math.sqrt(dx * dx + dy * dy)
		dx, dy = dx / len, dy / len
		s.action = "Dodge"
		s.dodgeKind = "Chase"
		s.actionTime = 0
		s.actionDuration = C.ChaseDodgeTime
		s.dodgeVX = dx * C.ChaseDodgeSpeed
		s.dodgeVY = dy * C.ChaseDodgeSpeed
		if math.abs(dx) > 0.2 then
			s.facing = sign(dx)
		end
		if dy > 0.3 then
			s.grounded = false
		end
		s.fastFall = false
		s.chaseTimer = 0
		buf.Dodge = 0
		emit(events, { type = "Dodge", kind = "Chase" })
		return
	end

	-- Dodge / dash
	local dodgeCd = stat(ctx, "dodge")
	if buf.Dodge > 0 and canMove and s.dodgeCooldown <= 0 then
		local sideways = math.abs(moveX) > AXIS_DEADZONE
		if s.grounded then
			if sideways then
				if s.dashCooldown <= 0 then
					s.action = "Dash"
					s.actionTime = 0
					s.actionDuration = P.DashTime
					s.facing = sign(moveX)
					s.vx = s.facing * P.DashSpeed * stat(ctx, "speed")
					s.dashCooldown = P.DashCooldown * dodgeCd
					buf.Dodge = 0
					emit(events, { type = "Dodge", kind = "Dash" })
				end
			else
				s.action = "Dodge"
				s.dodgeKind = "Spot"
				s.actionTime = 0
				s.actionDuration = P.SpotDodgeTime
				s.invuln = math.max(s.invuln, P.SpotDodgeTime)
				s.dodgeCooldown = P.SpotDodgeCooldown * dodgeCd
				buf.Dodge = 0
				emit(events, { type = "Dodge", kind = "Spot" })
			end
		elseif not s.airDodgeUsed then
			s.airDodgeUsed = true
			s.fastFall = false
			s.actionTime = 0
			s.action = "Dodge"
			if sideways or math.abs(moveY) > AXIS_DEADZONE then
				local len = math.sqrt(moveX * moveX + moveY * moveY)
				local dx, dy = moveX / len, moveY / len
				s.dodgeKind = "Air"
				s.dodgeVX = dx * P.AirDodgeSpeed
				s.dodgeVY = dy * P.AirDodgeSpeed
				s.actionDuration = P.AirDodgeTime
				s.invuln = math.max(s.invuln, P.AirDodgeInvuln)
				if math.abs(dx) > 0.2 then
					s.facing = sign(dx)
				end
				emit(events, { type = "Dodge", kind = "Air" })
			else
				s.dodgeKind = "AirSpot"
				s.actionDuration = P.SpotDodgeTime
				s.invuln = math.max(s.invuln, P.SpotDodgeTime)
				s.gcTimer = P.SpotDodgeTime + C.GravityCancelGrace
				s.vx *= 0.3
				s.vy = math.max(s.vy, 0) * 0.3
				emit(events, { type = "Dodge", kind = "AirSpot" })
			end
			s.dodgeCooldown = P.AirDodgeCooldown * dodgeCd
			buf.Dodge = 0
		end
	end

	canMove = (s.action == nil or s.action == "Dash") and s.landLag <= 0
	-- Gravity cancel: a light attack out of an air spot dodge.
	local gravityCancel = s.action == "Dodge" and s.dodgeKind == "AirSpot" and s.gcTimer > 0 and buf.Light > 0
	if gravityCancel then
		s.action = nil
		s.dodgeKind = nil
		s.invuln = 0
		canMove = true
	end

	-- Attacks (heavy wins if both are buffered)
	if canMove and (buf.Heavy > 0 or buf.Light > 0) then
		local heavy = buf.Heavy > 0 and not gravityCancel
		if heavy then
			buf.Heavy = 0
		else
			buf.Light = 0
		end
		if not heavy and ctx.nearPickup and not ctx.armed and not gravityCancel then
			emit(events, { type = "Pickup" })
		else
			local slot = chooseSlot(s, moveX, moveY, heavy)
			local spent = (slot == "Recovery" and s.recoveryUsed) or (slot == "GroundPound" and s.groundPoundUsed)
			if spent then
				slot = nil
			end
			if slot then
				s.action = nil
				startAttack(s, slot, ctx, moveX, events)
			end
		end
		canMove = false
	end

	-- Throw / pick up
	if buf.Throw > 0 and canMove then
		buf.Throw = 0
		if ctx.armed then
			if math.abs(moveX) > AXIS_DEADZONE then
				s.facing = sign(moveX)
			end
			s.action = "Throw"
			s.actionTime = 0
			s.actionDuration = Config.WeaponDrops.ThrowRecovery
			local dirY = 0
			if moveY > 0.5 then
				dirY = 1
			elseif moveY < -0.5 then
				dirY = -1
			end
			emit(events, { type = "Throw", dirY = dirY, facing = s.facing })
		elseif ctx.nearPickup then
			emit(events, { type = "Pickup" })
		end
	end
end

local function motionActive(s)
	local move = s.move
	return s.action == "Attack"
		and move ~= nil
		and move.Motion ~= nil
		and s.motionTime >= 0
		and s.motionTime < move.Motion.Duration
end

local function updateAction(s, input, dt, events)
	if s.action == "Attack" then
		local move = s.move
		if s.charging then
			if input.heavyHeld and s.charge < move.Charge then
				s.charge = math.min(move.Charge, s.charge + dt)
			else
				s.charging = false
				emit(events, { type = "Release", seq = s.seq, charge = FighterSim.chargeFraction(s) })
			end
		else
			s.actionTime += dt
		end

		local mo = move.Motion
		if mo then
			if s.motionTime < 0 and not s.charging and s.actionTime >= mo.At then
				s.motionTime = 0
			end
			if s.motionTime >= 0 and s.motionTime < mo.Duration then
				s.motionTime += dt
				s.vx = mo.VX * s.facing
				s.vy = mo.VY
				if mo.VY > 0 then
					s.grounded = false
				end
			end
		end

		if move.Projectile and not s.fired and not s.charging and s.actionTime >= move.Startup then
			s.fired = true
			emit(events, {
				type = "Fire",
				seq = s.seq,
				slot = s.slot,
				charge = FighterSim.chargeFraction(s),
				facing = s.facing,
			})
		end

		if s.actionTime >= move.Startup + move.Active + move.Recovery then
			endAttack(s, events)
		end
	elseif
		s.action == "Dodge"
		or s.action == "Dash"
		or s.action == "Throw"
		or s.action == "Stunned"
		or s.action == "Knockdown"
		or s.action == "GetUp"
		or s.action == "TechRoll"
		or s.action == "Awakening"
	then
		s.actionTime += dt
		if s.actionTime >= s.actionDuration then
			if s.action == "Dodge" and (s.dodgeKind == "Air" or s.dodgeKind == "Chase") then
				s.vx *= 0.35
				s.vy *= 0.35
			end
			if s.action == "Knockdown" then
				getUp(s, events)
				return
			end
			s.action = nil
			s.dodgeKind = nil
		end
	elseif s.action == "Block" then
		s.actionTime += dt
	end
end

local function updateMovement(s, input, moveX, moveY, dt, ctx)
	-- Short hop: let go of jump early for a smaller hop.
	if s.jumpTime >= 0 then
		s.jumpTime += dt
		if not input.jumpHeld and s.vy > 0 then
			if s.jumpTime <= P.ShortHopWindow then
				s.vy *= P.ShortHopMult
			end
			s.jumpTime = -1
		elseif s.jumpTime > P.ShortHopWindow then
			s.jumpTime = -1
		end
	end

	local airDodging = s.action == "Dodge" and (s.dodgeKind == "Air" or s.dodgeKind == "Chase")
	local moving = motionActive(s)
	local speed = speedMult(ctx)

	-- Horizontal
	if s.action == "Dash" then
		s.vx = s.facing * P.DashSpeed * speed
	elseif s.action == "TechRoll" then
		s.vx = s.techDir * B.TechRollSpeed * (1 - 0.5 * s.actionTime / B.TechRollTime)
	elseif airDodging then
		s.vx = s.dodgeVX
		s.vy = s.dodgeVY
	elseif not moving then
		local control = 1
		if s.action == "Attack" then
			control = s.grounded and 0 or s.move.AirDrift
		elseif s.action == "Dodge" or s.action == "Throw" then
			control = s.grounded and 0 or 0.5
		elseif s.action ~= nil or s.landLag > 0 then
			control = 0 -- blocking, stunned, down, getting up, awakening
		end

		local wants = math.abs(moveX) > 0.1 and control > 0
		if s.grounded then
			if wants then
				s.vx = approach(s.vx, moveX * P.RunSpeed * speed, P.GroundAccel * control * dt)
			else
				s.vx = approach(s.vx, 0, P.GroundDecel * dt)
			end
		else
			local airSpeed = P.AirSpeed * speed
			local over = math.abs(s.vx) > airSpeed
			if over and (not wants or sign(moveX) == sign(s.vx)) then
				-- Keep knockback momentum; bleed it off slowly.
				s.vx = approach(s.vx, sign(s.vx) * airSpeed, P.OverspeedDecel * dt)
			elseif wants then
				local accel = P.AirAccel * control
				if over then
					accel *= 0.5
				end
				s.vx = approach(s.vx, moveX * airSpeed, accel * dt)
			else
				s.vx = approach(s.vx, 0, P.AirDecel * dt)
			end
		end

		if s.action == nil and math.abs(moveX) > AXIS_DEADZONE then
			s.facing = sign(moveX)
		end
	end

	-- Wall cling: airborne, pressing into a wall.
	s.wallSide = 0
	if not s.grounded and s.wallTouch ~= 0 and s.action == nil and moveX * s.wallTouch > AXIS_DEADZONE then
		s.wallSide = s.wallTouch
		s.facing = -s.wallTouch
	end

	-- Fast fall
	if not s.grounded and moveY <= -0.6 and s.vy < 8 then
		if s.action == nil or (s.action == "Attack" and s.move.Air and not moving) then
			s.fastFall = true
		end
	end

	-- Gravity
	if not airDodging and not moving then
		local g = P.Gravity
		if s.fastFall then
			g *= P.FastFallGravityMult
		elseif s.action == "Dodge" and s.dodgeKind == "AirSpot" then
			g *= 0.25
		end
		s.vy -= g * dt
		local maxFall = s.fastFall and P.FastFallSpeed or P.MaxFallSpeed
		if s.wallSide ~= 0 then
			maxFall = P.WallSlideSpeed
		end
		if s.vy < -maxFall then
			s.vy = approach(s.vy, -maxFall, 300 * dt)
		end
	end
end

-- Highest platform top under (x, y), if any.
local function groundUnder(world, x, y)
	local best
	for _, p in world.platforms do
		if x >= p.minX and x <= p.maxX and p.maxY <= y + 0.01 and (best == nil or p.maxY > best) then
			best = p.maxY
		end
	end
	return best
end

local function updateHitstun(s, input, moveX, dt, ctx)
	s.hitstun -= dt
	if not s.grounded then
		s.tumbleAir += dt
	end
	s.vy -= P.Gravity * P.HitstunGravityScale * dt
	s.vx += moveX * P.DIAccel * dt
	local drag = math.exp(-P.KnockbackDrag * dt)
	s.vx *= drag
	if s.vy > 0 then
		s.vy *= drag
	end
	if s.grounded then
		s.vx = approach(s.vx, 0, P.GroundDecel * 0.5 * dt)
	end
	if s.hitstun <= 0 then
		s.hitstun = 0
		-- Ragdolled over the stage: stay limp until landing (knockdown), or
		-- jump out of it. Off the stage, control comes back to recover.
		if
			s.tumble
			and not s.grounded
			and s.tumbleHold < B.TumbleHold
			and (input.buffer.Jump or 0) <= 0
			and groundUnder(ctx.world, s.x, s.y)
		then
			s.tumbleHold += dt
			return
		end
		s.action = nil
		s.tumble = false
	end
end

-- Landing while tumbling: tech if dodge was pressed just before, else go
-- down (invulnerable while down and getting back up).
local function landTumble(s, events)
	s.tumble = false
	s.hitstun = 0
	if s.techTimer > 0 then
		s.techTimer = 0
		s.action = "TechRoll"
		s.actionTime = 0
		s.actionDuration = B.TechRollTime
		s.techDir = math.abs(s.lastMoveX) > AXIS_DEADZONE and sign(s.lastMoveX) or 0
		if s.techDir ~= 0 then
			s.facing = s.techDir -- the roll animation always rolls forward
		end
		s.invuln = math.max(s.invuln, B.TechRollTime)
		emit(events, { type = "Tech", dir = s.techDir })
	else
		s.action = "Knockdown"
		s.actionTime = 0
		s.actionDuration = B.KnockdownTime
		s.vx *= 0.3
		s.invuln = math.max(s.invuln, B.KnockdownTime + B.GetUpTime)
		emit(events, { type = "Knockdown" })
	end
end

local function onLanded(s, events)
	s.airJumps = P.MaxAirJumps
	s.wallJumps = P.MaxWallJumps
	s.recoveryUsed = false
	s.groundPoundUsed = false
	s.airDodgeUsed = false
	s.fastFall = false
	s.wallSide = 0
	if s.action == "Hitstun" and s.tumble and s.tumbleAir > 0.05 then
		landTumble(s, events)
	elseif s.action == "Attack" then
		local move = s.move
		if move.EndsOnLand then
			if s.actionTime < move.Startup + move.Active then
				s.actionTime = move.Startup + move.Active
			end
			s.motionTime = math.huge
		elseif s.attackAir and not s.gcAttack and not move.Ultimate then
			endAttack(s, events)
			s.landLag = P.LandingLag * 2
		end
	elseif s.action == "Dodge" and s.dodgeKind ~= "Spot" and s.dodgeKind ~= "Chase" then
		s.action = nil
		s.dodgeKind = nil
	end
	emit(events, { type = "Land" })
end

-- Axis-separated swept AABB against the arena's platforms.
local function integrate(s, dt, world, events)
	local halfW = P.FighterWidth / 2
	local height = P.FighterHeight
	local dx = s.vx * dt
	local dy = s.vy * dt
	local steps = math.max(1, math.ceil(math.max(math.abs(dx), math.abs(dy)) / 0.8))
	dx /= steps
	dy /= steps

	local wasGrounded = s.grounded
	local grounded = false
	local onSoft = false
	local wallTouch = 0
	local x, y = s.x, s.y

	for _ = 1, steps do
		-- X axis: solid platforms only
		local nx = x + dx
		if dx ~= 0 then
			for _, p in world.platforms do
				if not p.soft and y + height > p.minY + 0.01 and y < p.maxY - 0.01 then
					if nx + halfW > p.minX and nx - halfW < p.maxX then
						if dx > 0 and x + halfW <= p.minX + 0.05 then
							nx = p.minX - halfW
							wallTouch = 1
							s.vx = math.min(s.vx, 0)
						elseif dx < 0 and x - halfW >= p.maxX - 0.05 then
							nx = p.maxX + halfW
							wallTouch = -1
							s.vx = math.max(s.vx, 0)
						end
					end
				end
			end
		end
		x = nx

		-- Y axis
		local ny = y + dy
		for _, p in world.platforms do
			if x + halfW > p.minX + 0.01 and x - halfW < p.maxX - 0.01 then
				if dy <= 0 and y >= p.maxY - 0.05 and ny <= p.maxY then
					if not p.soft or s.dropThrough <= 0 then
						ny = p.maxY
						grounded = true
						onSoft = p.soft
					end
				elseif dy > 0 and not p.soft and y + height <= p.minY + 0.05 and ny + height > p.minY then
					ny = p.minY - height
					s.vy = math.min(s.vy, 0)
					dy = 0
				end
			end
		end
		if grounded then
			dy = 0
		end
		y = ny
	end

	s.x, s.y = x, y
	s.grounded = grounded
	s.onSoft = onSoft
	s.wallTouch = wallTouch
	if grounded then
		s.vy = 0
		if not wasGrounded then
			onLanded(s, events)
		end
	end
end

local function stepOnce(s, input, dt, ctx, events)
	-- Hit-stop freezes the fighter in place (buffered inputs wait).
	if s.hitstop > 0 then
		s.hitstop = math.max(0, s.hitstop - dt)
		return
	end
	s.chaseTimer = math.max(0, s.chaseTimer - dt)
	s.gcTimer = math.max(0, s.gcTimer - dt)
	s.invuln = math.max(0, s.invuln - dt)
	s.dodgeCooldown = math.max(0, s.dodgeCooldown - dt)
	s.dashCooldown = math.max(0, s.dashCooldown - dt)
	s.dropThrough = math.max(0, s.dropThrough - dt)
	s.landLag = math.max(0, s.landLag - dt)
	s.chainTimer = math.max(0, s.chainTimer - dt)
	s.blockstun = math.max(0, s.blockstun - dt)
	s.techTimer = math.max(0, s.techTimer - dt)

	local moveX = math.clamp(input.moveX or 0, -1, 1)
	local moveY = math.clamp(input.moveY or 0, -1, 1)
	local downPressed = moveY <= -0.6 and s.prevMoveY > -0.6
	s.prevMoveY = moveY
	s.lastMoveX = moveX

	if s.action == "Hitstun" then
		-- dodge just before landing from a tumble: tech
		if s.tumble and input.buffer.Dodge > 0 then
			input.buffer.Dodge = 0
			s.techTimer = B.TechWindow
		end
		updateHitstun(s, input, moveX, dt, ctx)
	else
		-- Drop through a soft platform by tapping down.
		if downPressed and s.grounded and s.onSoft and s.action == nil then
			s.dropThrough = P.DropThroughTime
			s.grounded = false
			s.y -= 0.05
		end
		tryActions(s, input, moveX, moveY, ctx, events)
		updateAction(s, input, dt, events)
		updateMovement(s, input, moveX, moveY, dt, ctx)
	end

	integrate(s, dt, ctx.world, events)
end

function FighterSim.step(s, input, dt, ctx, events)
	events = events or {}
	if s.frozen or dt <= 0 then
		return events
	end
	dt = math.min(dt, 0.1)
	local steps = math.ceil(dt / MAX_STEP - 1e-6)
	local sub = dt / steps
	for _ = 1, steps do
		stepOnce(s, input, sub, ctx, events)
	end
	return events
end

-- Your attack landed (reported by the caller once it detects the hit).
function FighterSim.onHitConfirm(s, hitstop)
	if s.action == "Attack" then
		s.hitConfirmSeq = s.seq
	end
	s.chaseTimer = C.ChaseWindow
	s.hitstop = math.max(s.hitstop, hitstop or 0)
end

-- Called when a hit lands on this fighter. `ragdoll` (a strong hit) sends
-- them tumbling limp: landing before the hitstun ends knocks them down.
function FighterSim.applyHit(s, kbx, kby, hitstun, hitstop, ragdoll)
	if s.action == "Attack" then
		s.move = nil
		s.slot = nil
		s.charging = false
	end
	s.action = "Hitstun"
	s.tumble = ragdoll == true
	s.tumbleAir = 0
	s.tumbleHold = 0
	s.techTimer = 0
	s.chain = 0
	s.chainTimer = 0
	s.blockstun = 0
	s.dodgeKind = nil
	s.hitstun = hitstun
	s.hitstop = hitstop or 0
	s.chaseTimer = 0
	s.gcTimer = 0
	s.gcAttack = false
	s.vx = kbx
	s.vy = kby
	if s.grounded and kby < 0 then
		s.vy = math.abs(kby) * 0.4
	end
	if s.vy > 0 then
		s.grounded = false
	end
	s.motionTime = -1
	s.fastFall = false
	s.wallSide = 0
	s.jumpTime = -1
	-- Getting hit gives your recovery tools back.
	s.recoveryUsed = false
	s.groundPoundUsed = false
	s.airDodgeUsed = false
	if s.airJumps < 1 then
		s.airJumps = 1
	end
end

-- A hit was blocked: stay in block, pushed back, for `blockstun`.
function FighterSim.applyBlock(s, pushX, blockstun, hitstop)
	if s.action ~= "Block" then
		if s.action == "Attack" then
			s.move = nil
			s.slot = nil
			s.charging = false
		end
		s.action = "Block"
		s.actionTime = 0
	end
	s.blockstun = math.max(s.blockstun, blockstun)
	s.hitstop = math.max(s.hitstop, hitstop or 0)
	s.vx = pushX
end

-- The guard broke: stunned in place, open to anything.
function FighterSim.applyGuardBreak(s, stun)
	if s.action == "Attack" then
		s.move = nil
		s.slot = nil
		s.charging = false
	end
	s.action = "Stunned"
	s.actionTime = 0
	s.actionDuration = stun
	s.blockstun = 0
	s.vx = 0
	s.chain = 0
end

-- Awakening: a short invulnerable power-up pose while everyone else freezes.
function FighterSim.awaken(s, duration)
	if s.action == "Attack" then
		s.move = nil
		s.slot = nil
		s.charging = false
	end
	s.action = "Awakening"
	s.actionTime = 0
	s.actionDuration = duration
	s.invuln = math.max(s.invuln, duration)
	s.vx = 0
	if s.vy > 0 then
		s.vy = 0
	end
end

-- Freezes a fighter in place (someone else's awakening cut-in).
function FighterSim.freeze(s, duration)
	s.hitstop = math.max(s.hitstop, duration)
end

function FighterSim.isBlocking(s)
	return s.action == "Block"
end

function FighterSim.respawn(s, x, y, facing, invuln)
	-- Attack sequence numbers keep counting so the server never sees one reused.
	local seq = s.seq
	local fresh = FighterSim.newState(x, y, facing)
	for k in s do
		s[k] = nil
	end
	for k, v in fresh do
		s[k] = v
	end
	s.seq = seq or 0
	s.invuln = invuln or 0
	return s
end

function FighterSim.chargeFraction(s)
	local move = s.move
	if not move or not move.Charge or move.Charge <= 0 then
		return 0
	end
	return math.clamp(s.charge / move.Charge, 0, 1)
end

function FighterSim.isInvulnerable(s)
	return s.invuln > 0
end

-- Melee hitbox for the current attack frame, or nil.
function FighterSim.activeHitbox(s)
	if s.action ~= "Attack" or s.charging then
		return nil
	end
	local move = s.move
	local box = move.Hitbox
	if not box then
		return nil
	end
	local t = s.actionTime
	if t < move.Startup or t >= move.Startup + move.Active then
		return nil
	end
	local cx = s.x + box.X * s.facing
	local cy = s.y + box.Y
	return cx - box.W / 2, cy - box.H / 2, cx + box.W / 2, cy + box.H / 2
end

function FighterSim.hurtbox(x, y)
	local halfW = P.FighterWidth / 2
	return x - halfW, y, x + halfW, y + P.FighterHeight
end

function FighterSim.overlaps(ax1, ay1, ax2, ay2, bx1, by1, bx2, by2)
	return ax1 < bx2 and ax2 > bx1 and ay1 < by2 and ay2 > by1
end

-- Locomotion animation name for the current state.
function FighterSim.animState(s)
	if s.action == "Hitstun" then
		return (s.tumble and s.hitstun <= 0) and "Tumble" or "Fall"
	elseif s.action == "Block" or s.action == "Stunned" or s.action == "Knockdown" then
		return s.action
	end
	if s.grounded then
		if s.action == nil and math.abs(s.vx) > 2 then
			return "Run"
		elseif s.action == "Dash" then
			return "Run"
		end
		return "Idle"
	end
	if s.vy > 4 then
		return "Jump"
	end
	return "Fall"
end

return FighterSim
