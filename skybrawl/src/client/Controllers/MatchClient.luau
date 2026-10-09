--[[
    Runs your fighter during a match.

    Each frame: read input -> FighterSim.step -> move your character ->
    report attacks/dodges/throws/blocks to the server -> check your active
    hitbox against other fighters and report hits. The server answers with
    "Hit" events (including knockback when you're the one hit), blocked
    hits and guard breaks, awakenings, KOs, respawns, weapon changes,
    projectiles and the final results.

    Phases (menus design 5.13): "Start" sets the phase to "Match" (the VS
    splash fades), "End" shows the results screen after
    Config.Menu.ResultsDelay (phase "Results"; training and requeued dodges
    skip it), and cleanup returns a match that ends without results to the
    menu. Every MatchEvent carries matchId: events of any other match are
    dropped, and an End / Leave of the VS match before its "Start" returns
    the VS splash to the menu (UI/Match/Models.phaseAfter decides).

    Characters exist only for matches: the server destroys yours when you
    leave one, so CharacterRemoving before "End" (forfeit, server error)
    also returns you to the menu. Roblox's own controls stay off for good
    (Controls.set(false)); Focus owns fight input (Focus.setFightInput).

    Training matches (info.training) scale the sim, input and animation dt
    by the match's time scale and call TrainingClient's hooks. Combat
    timers (invulnerability, awakening, guard regen, the KO wait) run on
    the match clock (m.clock: the scaled dt summed), as the server's do, so
    slow motion stretches them too.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Maps = require(Shared.Maps)
local Weapons = require(Shared.Weapons)
local Legends = require(Shared.Legends)
local FighterSim = require(Shared.FighterSim)
local Combat = require(Shared.Combat)
local Util = require(Shared.Util)
local Net = require(Shared.Net)

local ClientState = require(script.Parent.Parent.ClientState)
local Settings = require(script.Parent.Settings)
local Input = require(script.Parent.Input)
local CameraController = require(script.Parent.CameraController)
local Visuals = require(script.Parent.Visuals)
local FighterAnimator = require(script.Parent.FighterAnimator)
local SkyBackdrop = require(script.Parent.SkyBackdrop)
local CharacterAnimator = require(script.Parent.CharacterAnimator)
local Sound = require(script.Parent.Sound)
local BattleFX = require(script.Parent.BattleFX)
local Controls = require(script.Parent.Controls)
local TrainingClient = require(script.Parent.TrainingClient)

local UI = script.Parent.Parent:WaitForChild("UI")
local MatchHUD = require(UI.MatchHUD)
local ResultsScreen = require(UI.ResultsScreen)
local MobileControls = require(UI.MobileControls)
local Focus = require(UI.Focus)
local Models = require(UI:WaitForChild("Match"):WaitForChild("Models"))

local MatchClient = {}

local player = Players.LocalPlayer
local fighterAction = Net.get("FighterAction")
local STEP_NAME = "SkybrawlFighter"
local GRAVEYARD_Y = 600
local CHARACTER_WAIT = 5 -- seconds onStart waits for your (already loaded) character to replicate
local LEGEND_RETRACK = 0.25 -- a legend change re-tracks the model again after this, once the new rig has replicated
local rng = Random.new()

local match = nil
local hitboxPart = nil
local startSeq = 0 -- bumped by every "Start": an older onStart still waiting for its character gives up
local endedEarly = {} -- [matchId] = true: its End / Leave came while no match ran (before its fighter was set up)

-- Calls TrainingClient[name](...) without letting a training error break the match.
local function trainingHook(name, ...)
	local ok, err = pcall(TrainingClient[name], ...)
	if not ok then
		warn("[MatchClient] TrainingClient." .. name .. " failed:", err)
	end
end

-- What Models.phaseAfter needs to know about the client right now.
local function phaseState()
	local vs = ClientState.vs
	return {
		phase = ClientState.phase,
		vsId = vs and vs.id,
		vsMatchId = vs and vs.matchId,
		matchId = match and match.info.matchId,
	}
end

-- Applies a Models.phaseAfter decision: its toast, then the phase.
local function applyPhase(result)
	if not result then
		return
	end
	if result.toast then
		ClientState.toast(result.toast, result.toastKind)
	end
	ClientState.setPhase(result.phase)
end

local B = Config.Battle
local GOLD = Color3.fromRGB(255, 205, 70)
local RED = Color3.fromRGB(255, 80, 70)
-- invulnerability a downed fighter gets (matches the server)
local DOWN_INVULN = {
	Knockdown = B.KnockdownTime + B.GetUpTime,
	GetUp = B.GetUpTime,
	Tech = B.TechRollTime,
}

local DISABLED_STATES = {
	Enum.HumanoidStateType.FallingDown,
	Enum.HumanoidStateType.Ragdoll,
	Enum.HumanoidStateType.GettingUp,
	Enum.HumanoidStateType.Climbing,
	Enum.HumanoidStateType.Swimming,
	Enum.HumanoidStateType.Seated,
	Enum.HumanoidStateType.Jumping,
	Enum.HumanoidStateType.Freefall,
	Enum.HumanoidStateType.Running,
	Enum.HumanoidStateType.Landed,
	Enum.HumanoidStateType.Flying,
	Enum.HumanoidStateType.StrafingNoPhysics,
}

local function prepareCharacter(m)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root then
		return false
	end
	m.character = character
	m.humanoid = humanoid
	m.root = root
	m.feetOffset = Util.feetOffset(character)
	humanoid.AutoRotate = false
	for _, state in DISABLED_STATES do
		humanoid:SetStateEnabled(state, false)
	end
	humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	return true
end

local function restoreCharacter(m)
	local humanoid = m.humanoid
	if humanoid and humanoid.Parent and humanoid.Health > 0 then
		for _, state in DISABLED_STATES do
			humanoid:SetStateEnabled(state, true)
		end
		humanoid.AutoRotate = true
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	end
end

local function fighterPosition(m, f)
	if f == m.me then
		return m.sim.x, m.sim.y
	end
	local root = f.root
	if not root or not root.Parent then
		return nil
	end
	local p = root.Position - m.origin
	return p.X, p.Y - f.feetOffset
end

local function facingOf(m, f)
	if f == m.me then
		return m.sim.facing
	end
	local root = f.root
	if root and root.Parent then
		return root.CFrame.LookVector.X >= 0 and 1 or -1
	end
	return 1
end

-- What the ultimate button does for you right now (the server decides;
-- this just keeps you from asking when it would say no).
local function ultimateState(m)
	local me = m.me
	if me.awakened then
		return not me.ultUsed and "Attack" or nil
	end
	if (me.ult or 0) >= B.UltMax and os.clock() > (me.awakenAsked or 0) + 0.5 then
		return "Awaken"
	end
	return nil
end

-- The camera cuts in on a fighter's ultimate move.
local function ultimateCutIn(m, f, move)
	local facing = facingOf(m, f)
	CameraController.focus(function()
		local x, y = fighterPosition(m, f)
		if not x then
			return nil
		end
		return x + facing * 3, y + 3.5
	end, 20, 0.75, 26 * facing)
	MatchHUD.announce(string.upper(move and move.Signature or "Ultimate"), GOLD, 1.2)
	BattleFX.speedLines(0.6)
	Sound.play("HeavySwing", 0.8, 0.7)
end

local function setBlocking(f, on)
	f.blocking = on
	if f.model and f ~= (match and match.me) then
		FighterAnimator.setHeld(f.model, on and "Block" or nil)
	end
end

-- Guard refill and the awakening countdown, for the HUD meters.
local function stepMeters(m, dt)
	local now = m.clock
	for _, f in m.order do
		local dirty = false
		if f.awakened then
			local left = (f.awakenEnds or now) - now
			f.awakenFrac = math.clamp(left / B.AwakenTime, 0, 1)
			if left < -1 then
				-- the server's AwakenEnd went missing
				f.awakened = false
				BattleFX.endAwaken(f.model)
			end
			dirty = true
		end
		if f.guard < B.GuardMax and not f.blocking and now - (f.lastGuardHit or 0) > B.GuardRegenDelay then
			f.guard = math.min(B.GuardMax, f.guard + B.GuardRegen * dt)
			dirty = true
		end
		if dirty then
			MatchHUD.updateMeters(f)
		end
	end
end

local function applyTransform(m)
	local root = m.root
	if not root or not root.Parent then
		return
	end
	local sim = m.sim
	if m.me.alive then
		root.CFrame = Util.fighterCFrame(m.origin, sim.x, sim.y, m.feetOffset, sim.facing)
		root.AssemblyLinearVelocity = Vector3.new(sim.vx, sim.vy, 0)
	else
		root.CFrame = Util.fighterCFrame(m.origin, 0, GRAVEYARD_Y, m.feetOffset, 1)
		root.AssemblyLinearVelocity = Vector3.zero
	end
end

local function findPickup(m, x, y)
	local folder = m.arena and m.arena:FindFirstChild("Pickups")
	if not folder then
		return nil
	end
	for _, model in folder:GetChildren() do
		if model:IsA("Model") and model:GetAttribute("PickupId") then
			local p = model:GetPivot().Position - m.origin
			local px, py = p.X, p.Y - 1
			if
				math.abs(px - x) <= Config.WeaponDrops.PickupRange
				and py >= y - 3
				and py <= y + Config.Physics.FighterHeight + 1
			then
				return model
			end
		end
	end
	return nil
end

local function cameraData()
	local m = match
	if not m then
		return nil
	end
	local fighters = {}
	for _, f in m.order do
		if f.alive and not f.left then
			local x, y = fighterPosition(m, f)
			if x and not Maps.isOutOfBounds(m.world, x, y) then
				table.insert(fighters, { x = x, y = y, alive = true, enemy = f.team ~= m.me.team })
			end
		end
	end
	local sim = m.sim
	return {
		me = {
			x = sim.x,
			y = sim.y,
			vx = sim.vx,
			vy = sim.vy,
			facing = sim.facing,
			alive = m.me.alive and not Maps.isOutOfBounds(m.world, sim.x, sim.y),
		},
		fighters = fighters,
	}
end

-- Debug overlay for hitboxes (Settings > Gameplay > Show hitboxes).
local function drawHitbox(m, x1, y1, x2, y2)
	if not Settings.get("ShowHitboxes") or not x1 then
		if hitboxPart then
			hitboxPart.Transparency = 1
		end
		return
	end
	if not hitboxPart or not hitboxPart.Parent then
		hitboxPart = Instance.new("Part")
		hitboxPart.Name = "HitboxDebug"
		hitboxPart.Anchored = true
		hitboxPart.CanCollide = false
		hitboxPart.CanQuery = false
		hitboxPart.CanTouch = false
		hitboxPart.Material = Enum.Material.Neon
		hitboxPart.Color = Color3.fromRGB(255, 60, 60)
		hitboxPart.Parent = workspace
	end
	hitboxPart.Transparency = 0.5
	hitboxPart.Size = Vector3.new(x2 - x1, y2 - y1, 1)
	hitboxPart.CFrame = CFrame.new(m.origin + Vector3.new((x1 + x2) / 2, (y1 + y2) / 2, 2))
end

local function detectHits(m)
	local sim = m.sim
	local x1, y1, x2, y2 = FighterSim.activeHitbox(sim)
	if not m.training then
		-- (TrainingClient draws its own hitbox overlays)
		drawHitbox(m, x1, y1, x2, y2)
	end
	if not x1 then
		return
	end
	local log = m.hitLog[sim.seq]
	if not log then
		log = {}
		m.hitLog[sim.seq] = log
	end
	for _, f in m.order do
		if f ~= m.me and f.alive and not f.left and not log[f.id] and (m.info.friendlyFire or f.team ~= m.me.team) then
			local fx, fy = fighterPosition(m, f)
			if fx then
				local hx1, hy1, hx2, hy2 = FighterSim.hurtbox(fx, fy)
				if FighterSim.overlaps(x1, y1, x2, y2, hx1, hy1, hx2, hy2) then
					log[f.id] = true
					fighterAction:FireServer("Hit", { seq = sim.seq, target = f.id })
					local move = sim.move
					local heavy = move and move.Kind == "Heavy"
					-- The server will reject hits on a dodging/respawning target;
					-- don't spark or open the combo window for those.
					if m.clock < (f.invulnUntil or 0) then
						continue
					end
					-- Predict the server's hit-stop so the freeze and the combo
					-- window start right away.
					local charge = FighterSim.chargeFraction(sim)
					local dmg = Combat.damage(move, charge, m.info.damageMultiplier)
					local cx = (math.max(x1, hx1) + math.min(x2, hx2)) / 2
					local cy = (math.max(y1, hy1) + math.min(y2, hy2)) / 2
					local blocking = f.blocking and not (move and move.Unblockable)
					if blocking and (sim.x - fx) * facingOf(m, f) >= -0.5 then
						local stop = Combat.hitstop(dmg * 3)
						FighterSim.onHitConfirm(sim, stop)
						FighterAnimator.hitstop(m.character, stop)
						BattleFX.block(fx, cy, facingOf(m, f))
						Sound.play("Hit", 0.4, 1.7)
						continue
					end
					local _, _, force = Combat.knockback(move, (f.damage or 0) + dmg, charge, sim.facing, fx - sim.x)
					local stop = Combat.hitstop(force)
					FighterSim.onHitConfirm(sim, stop)
					FighterAnimator.hitstop(m.character, stop)
					if f.model then
						FighterAnimator.hitstop(f.model, stop)
					end
					Visuals.hitSpark(cx, cy, heavy, 0)
					local ultimate = move ~= nil and move.Ultimate == true
					BattleFX.impact(cx, cy, force, { big = ultimate })
					if ultimate or force >= B.RagdollForce * 1.6 then
						BattleFX.impactFrame({ m.character, f.model }, ultimate and 0.2 or 0.12)
					end
					Sound.play("Hit", heavy and 0.8 or 0.55, heavy and 0.8 or 1.15)
				end
			end
		end
	end
end

local function handleSimEvent(m, ev)
	local kind = ev.type
	if kind == "Attack" then
		fighterAction:FireServer("Attack", { slot = ev.slot, seq = ev.seq, facing = ev.facing })
		m.hitLog[ev.seq] = {}
		m.hitLog[ev.seq - 12] = nil
		Visuals.onAttack(m.character, m.weapon, ev.slot, ev.seq)
		local move = Legends.getAttack(m.legend, m.weapon, ev.slot)
		local heavy = move and move.Kind == "Heavy"
		Sound.play(heavy and "HeavySwing" or "Swing", heavy and 0.45 or 0.35, rng:NextNumber(0.9, 1.15))
		m.me.blocking = false
		if ev.slot == "Ultimate" then
			m.me.ultUsed = true
			ultimateCutIn(m, m.me, move)
		end
		if m.training then
			trainingHook("onOwnAttack", m, ev, move)
		end
	elseif kind == "Release" then
		fighterAction:FireServer("Release", { seq = ev.seq, charge = ev.charge })
		Visuals.releaseCharge(m.character, ev.seq)
	elseif kind == "Fire" then
		fighterAction:FireServer("Fire", { seq = ev.seq })
	elseif kind == "Dodge" then
		fighterAction:FireServer("Dodge", { kind = ev.kind })
		Visuals.dodge(m.character, ev.kind)
		if ev.kind ~= "Dash" and ev.kind ~= "Chase" then
			Visuals.flicker(
				m.character,
				ev.kind == "Air" and Config.Physics.AirDodgeInvuln or Config.Physics.SpotDodgeTime
			)
		end
	elseif kind == "Throw" then
		fighterAction:FireServer("Throw", { dirY = ev.dirY, facing = ev.facing })
		m.weapon = "Unarmed"
		m.me.weapon = "Unarmed"
		Visuals.playPose(m.character, "Throw")
		Sound.play("Swing", 0.5, 0.8)
		MatchHUD.updateFighter(m.me)
	elseif kind == "Pickup" then
		fighterAction:FireServer("Pickup", {})
	elseif kind == "Jump" then
		Sound.play("Jump", 0.25, ev.kind == "Air" and 1.15 or 1)
		if ev.cancel then
			FighterAnimator.stopAction(m.character)
		end
		if ev.kind ~= "Ground" then
			FighterAnimator.airJump(m.character)
			fighterAction:FireServer("Jump", { kind = ev.kind })
		end
	elseif kind == "Land" then
		Sound.play("Land", 0.2)
		FighterAnimator.landed(m.character)
		FighterAnimator.land(m.character)
	elseif kind == "AttackEnd" then
		FighterAnimator.endAttack(m.character, ev.seq)
		if m.training then
			trainingHook("onOwnAttackEnd", m, ev)
		end
	elseif kind == "Block" then
		m.me.blocking = ev.on
		fighterAction:FireServer("Block", { on = ev.on, facing = ev.facing })
	elseif kind == "Awaken" then
		m.me.awakenAsked = os.clock()
		fighterAction:FireServer("Awaken", {})
	elseif kind == "Knockdown" or kind == "Tech" or kind == "GetUp" then
		fighterAction:FireServer("Down", { kind = kind, dir = ev.dir })
		FighterAnimator.down(m.character, kind, ev.dir)
		if kind == "Knockdown" then
			BattleFX.slam(m.sim.x, m.sim.y, 1)
			CameraController.shake(0.6)
			Sound.play("Land", 0.6, 0.7)
		elseif kind == "Tech" then
			BattleFX.dust(m.sim.x, m.sim.y, 3)
			Sound.play("Land", 0.4, 1.3)
		end
	end
end

local function step(dt)
	local m = match
	if not m then
		return
	end
	-- match time: slower than real time in a slowed-down training room
	dt *= m.timeScale
	m.clock += dt
	local sim = m.sim
	-- During hit-stop the sim is frozen, so buffered presses wait for it
	-- (otherwise a cancel pressed on the hit could expire before its window).
	local input = Input.update((sim and sim.hitstop > 0) and 0 or dt)
	if not m.root or not m.root.Parent then
		return
	end

	if m.me.alive and not sim.frozen then
		local ctx = {
			world = m.world,
			weapon = m.weapon,
			legend = m.legend,
			armed = Weapons.isWeapon(m.weapon),
			nearPickup = findPickup(m, sim.x, sim.y) ~= nil,
			ultimate = ultimateState(m),
			awakened = m.me.awakened == true,
		}
		local events = FighterSim.step(sim, input, dt, ctx)
		for _, ev in events do
			handleSimEvent(m, ev)
		end
		detectHits(m)
		if Maps.isOutOfBounds(m.world, sim.x, sim.y) then
			-- Hold here until the server confirms the KO.
			sim.frozen = true
			m.waitingKO = m.clock
		end
	elseif m.waitingKO and m.clock - m.waitingKO > 3 and m.me.alive then
		sim.frozen = false
		m.waitingKO = nil
	end

	applyTransform(m)
	stepMeters(m, dt)
	-- a ragdoll that ended in the air (jumped out, or off the stage): stop
	-- flailing as soon as you have control again
	if m.tumbling and not sim.tumble and sim.action == nil then
		FighterAnimator.stopAction(m.character)
	end
	m.tumbling = sim.tumble
	local anim = (sim.frozen and m.me.alive) and "Idle" or FighterSim.animState(sim)
	if sim.wallSide ~= 0 and not sim.grounded then
		anim = "WallSlide"
	end
	FighterAnimator.setLocomotion(
		m.character,
		anim,
		anim == "Run" and math.clamp(math.abs(sim.vx) / Config.Physics.RunSpeed, 0.6, 1.4) or 1
	)
	if m.training then
		trainingHook("step", m, dt)
	end
end

-- Server events -----------------------------------------------------------

--[[
    Tears the match down. Roblox's own controls stay off (Controls.set(false)
    for good) and the results screen, if any, outlives the match. A match
    that ends without results (training leave, a requeued dodge, a forfeit,
    an abandoned match) goes back to the menu, unless keepPhase (a new
    "Start" is replacing it).
]]
local function cleanup(keepPhase)
	local m = match
	if not m then
		return
	end
	match = nil
	RunService:UnbindFromRenderStep(STEP_NAME)
	Focus.setFightInput(false)
	CameraController.stop()
	Visuals.stopMatch()
	BattleFX.stopMatch()
	FighterAnimator.stopMatch()
	FighterAnimator.setTimeScale(1)
	SkyBackdrop.stop()
	CharacterAnimator.setMatchMode(false)
	trainingHook("stop")
	MatchHUD.hide()
	MobileControls.hide()
	if hitboxPart then
		hitboxPart:Destroy()
		hitboxPart = nil
	end
	restoreCharacter(m)
	ClientState.setInMatch(false)
	if not keepPhase then
		applyPhase(Models.phaseAfter({ type = "Cleanup" }, phaseState()))
	end
end

-- Your character for this match: the server loaded it before "Start", but its replication may trail the event.
local function waitForCharacter()
	local deadline = os.clock() + CHARACTER_WAIT
	while not player.Character and os.clock() < deadline do
		task.wait(0.05)
	end
	return player.Character
end

-- The match couldn't be set up here: forfeit (the server releases your character) and go back to the menu.
local function setupFailed(reason)
	warn("[MatchClient] couldn't set up your fighter:", reason)
	cleanup(true)
	fighterAction:FireServer("Forfeit", {})
	applyPhase(Models.phaseAfter({ type = "SetupFailed" }, phaseState()))
end

local function onStart(info, seq)
	cleanup(true)
	ClientState.select = nil
	local character = waitForCharacter()
	if character then
		character:WaitForChild("HumanoidRootPart", 5)
	end
	if seq ~= startSeq or endedEarly[info.matchId] then
		-- a newer "Start" took over, or this match ended while its fighter loaded (a pre-fight dodge): the router
		-- already handled that, so there is nothing to set up, forfeit or toast
		return
	end

	local m = {
		info = info,
		world = Maps.getWorld(info.mapId),
		origin = info.origin,
		arena = info.arena,
		fighters = {},
		order = {},
		hitLog = {},
		weapon = "Unarmed",
		legend = "Avatar",
		phase = "Countdown",
		character = nil,
		humanoid = nil,
		root = nil,
		feetOffset = 3,
		timeScale = if type(info.timeScale) == "number" and info.timeScale > 0 then info.timeScale else 1,
		clock = 0, -- match time (see the header)
		training = info.training == true or info.source == "Training",
	}
	for _, fi in info.fighters do
		local f = {
			id = fi.id,
			name = fi.name,
			userId = fi.userId,
			isBot = fi.isBot,
			team = fi.team,
			color = fi.color,
			model = fi.model,
			level = fi.level,
			title = fi.title,
			rating = fi.rating,
			stocks = fi.stocks,
			score = fi.score,
			legend = fi.legend,
			ownLook = fi.ownLook == true,
			damage = 0,
			ult = fi.ult or 0,
			guard = fi.guard or B.GuardMax,
			blocking = false,
			awakened = false,
			weapon = "Unarmed",
			-- (a fighter can be out already: one who left on the VS splash, a bot whose model couldn't be built)
			alive = fi.alive ~= false,
			eliminated = fi.eliminated == true,
			left = fi.left == true,
		}
		f.feetOffset = fi.model and Util.feetOffset(fi.model) or 3
		f.root = fi.model and fi.model:FindFirstChild("HumanoidRootPart")
		m.fighters[f.id] = f
		table.insert(m.order, f)
	end
	m.me = m.fighters[info.you]
	if not character or not m.me or not prepareCharacter(m) then
		setupFailed(if character then "no fighter or humanoid" else "no character")
		return
	end
	m.me.model = m.character
	m.me.root = m.root
	m.legend = m.me.legend or "Avatar"
	m.sim = FighterSim.newState(info.spawn.x, info.spawn.y, info.spawn.facing)
	m.sim.frozen = true
	match = m
	table.clear(endedEarly)
	applyTransform(m)

	ClientState.setInMatch(true)
	Controls.set(false)
	Focus.setFightInput(true)
	FighterAnimator.setTimeScale(m.timeScale)
	CameraController.start(info.origin, m.world)
	CameraController.setProvider(cameraData)
	Visuals.startMatch(info.origin)
	BattleFX.startMatch(info.origin)
	CharacterAnimator.setMatchMode(true)
	FighterAnimator.startMatch(info.mapId, info.origin)
	SkyBackdrop.start(info.mapId, info.origin)
	for _, f in m.order do
		if f.model then
			FighterAnimator.track(f.model, { isMe = f == m.me, legend = f.legend })
		end
	end
	RunService:BindToRenderStep(STEP_NAME, Enum.RenderPriority.Input.Value + 1, step)
	fighterAction:FireServer("Ready")
	-- the arena is in place: the VS splash fades out, the menu music fades
	applyPhase(Models.phaseAfter({ type = "Start" }, phaseState()))

	-- UI last, and never allowed to block the fight itself.
	local ok, err = pcall(MatchHUD.show, m)
	if not ok then
		warn("[MatchClient] HUD failed:", err)
	end
	if m.training then
		trainingHook("start", m)
	end
	if UserInputService.TouchEnabled then
		ok, err = pcall(MobileControls.show)
		if not ok then
			warn("[MatchClient] touch controls failed:", err)
		end
	end
end

-- What the results screen needs from the match once it is gone (after "Leave").
local function summaryOf(m)
	local fighters = {}
	for id, f in m.fighters do
		fighters[id] = {
			name = f.name,
			legend = f.legend,
			ownLook = f.ownLook == true,
			userId = f.userId,
			team = f.team,
			isBot = f.isBot == true,
		}
	end
	return {
		mapId = m.info.mapId,
		mode = m.info.mode,
		source = m.info.source,
		ranked = m.info.ranked == true,
		queueType = m.info.queueType,
		you = m.me.id,
		legend = m.legend,
		ownLook = m.me.ownLook == true,
		fighters = fighters,
	}
end

local handlers = {}

function handlers.Countdown(d)
	MatchHUD.countdown(d.n)
	Sound.play("Swing", 0.3, 0.6)
end

function handlers.Go(d)
	match.phase = "Playing"
	match.sim.frozen = false
	Input.clearBuffer()
	MatchHUD.go(d.endsAt)
	Sound.play("HeavySwing", 0.5, 1.2)
end

function handlers.Action(d)
	local f = match.fighters[d.fighterId]
	if not f or f == match.me or not f.model then
		return
	end
	if d.kind == "Attack" then
		-- attacking out of an air spot dodge (gravity cancel) ends its invulnerability
		f.invulnUntil = math.min(f.invulnUntil or 0, f.respawnInvulnUntil or 0)
		setBlocking(f, false)
		Visuals.onAttack(f.model, d.weapon, d.slot, d.seq)
		if d.slot == "Ultimate" then
			f.ultUsed = true
			ultimateCutIn(match, f, Legends.getAttack(f.legend or "Avatar", d.weapon, d.slot))
		end
	elseif d.kind == "Block" then
		setBlocking(f, d.on == true)
	elseif d.kind == "Down" then
		local invuln = DOWN_INVULN[d.downKind]
		if invuln then
			f.invulnUntil = math.max(f.invulnUntil or 0, match.clock + invuln)
		end
		setBlocking(f, false)
		FighterAnimator.down(f.model, d.downKind, d.dir)
		local x, y = fighterPosition(match, f)
		if x and d.downKind == "Knockdown" then
			BattleFX.slam(x, y, 1)
			Sound.play("Land", 0.5, 0.7)
		elseif x and d.downKind == "Tech" then
			BattleFX.dust(x, y, 3)
		end
	elseif d.kind == "Release" then
		Visuals.releaseCharge(f.model, d.seq)
	elseif d.kind == "Dodge" then
		setBlocking(f, false)
		local P = Config.Physics
		local invuln = ({ Spot = P.SpotDodgeTime, AirSpot = P.SpotDodgeTime, Air = P.AirDodgeInvuln })[d.dodgeKind]
		if invuln then
			f.invulnUntil = math.max(f.invulnUntil or 0, match.clock + invuln)
		end
		Visuals.dodge(f.model, d.dodgeKind)
		if d.dodgeKind ~= "Dash" and d.dodgeKind ~= "Chase" then
			Visuals.flicker(f.model, 0.3)
		end
	elseif d.kind == "Jump" then
		FighterAnimator.airJump(f.model)
	end
end

function handlers.Hit(d)
	local victim = match.fighters[d.victimId]
	local attacker = d.attackerId and match.fighters[d.attackerId]
	if victim then
		victim.damage = d.total
		victim.ult = d.victimUlt or victim.ult
		setBlocking(victim, false)
	end
	if attacker then
		attacker.ult = d.attackerUlt or attacker.ult
	end
	-- Your own melee hits already sparked locally; ranged hits are server-side.
	if attacker ~= match.me or d.ranged then
		Visuals.hitSpark(d.x, d.y, d.heavy, d.force)
		BattleFX.impact(d.x, d.y, d.force, { big = d.ultimate })
		if d.ultimate or d.force >= B.RagdollForce * 1.6 then
			BattleFX.impactFrame({ attacker and attacker.model, victim and victim.model }, d.ultimate and 0.2 or 0.12)
		end
		Sound.play("Hit", d.heavy and 0.8 or 0.5, d.heavy and 0.8 or 1.1)
	end
	Visuals.damageNumber(d.x, d.y, d.damage, Combat.damageColor(d.total))
	if victim == match.me then
		FighterSim.applyHit(match.sim, d.kbx, d.kby, d.hitstun, d.hitstop, d.ragdoll)
		CameraController.shake(0.4 + d.force * 0.012)
		Visuals.hurt(match.character, d.hitstun + (d.hitstop or 0), d.force, d.ragdoll)
		FighterAnimator.hitstop(match.character, d.hitstop)
	elseif victim and victim.model then
		Visuals.hurt(victim.model, d.hitstun + (d.hitstop or 0), d.force, d.ragdoll)
		FighterAnimator.hitstop(victim.model, d.hitstop)
		if d.heavy then
			CameraController.shake(0.2 + d.force * 0.005)
		end
	end
	if attacker and attacker ~= match.me and attacker.model then
		FighterAnimator.hitstop(attacker.model, d.hitstop)
	end
	if attacker == match.me and (d.combo or 0) >= 2 then
		MatchHUD.combo(d.combo, d.trueCombo == true)
	elseif victim == match.me and (d.combo or 0) >= 2 then
		MatchHUD.comboTaken(d.combo, d.trueCombo == true)
	end
	if victim then
		MatchHUD.updateFighter(victim)
		MatchHUD.updateMeters(victim)
	end
	if attacker then
		MatchHUD.updateMeters(attacker)
	end
	if match.training then
		trainingHook("onHit", match, d)
	end
end

-- A hit landed on someone's guard.
function handlers.Blocked(d)
	local victim = match.fighters[d.victimId]
	local attacker = d.attackerId and match.fighters[d.attackerId]
	if victim then
		victim.guard = d.guard
		victim.ult = d.ult or victim.ult
		victim.lastGuardHit = match.clock
		MatchHUD.updateMeters(victim)
	end
	-- your own blocked hits already flashed locally
	if attacker ~= match.me and victim then
		BattleFX.block(d.x, d.y, facingOf(match, victim))
		Sound.play("Hit", 0.4, 1.7)
	end
	if victim == match.me then
		FighterSim.applyBlock(match.sim, d.pushX, d.stun, d.hitstop)
		FighterAnimator.hitstop(match.character, d.hitstop)
		CameraController.shake(0.25)
	elseif victim and victim.model then
		FighterAnimator.hitstop(victim.model, d.hitstop)
	end
	if attacker and attacker ~= match.me and attacker.model then
		FighterAnimator.hitstop(attacker.model, d.hitstop)
	end
end

-- Someone's guard ran out: they're dazed and wide open.
function handlers.GuardBreak(d)
	local victim = match.fighters[d.victimId]
	local attacker = d.attackerId and match.fighters[d.attackerId]
	if not victim then
		return
	end
	victim.guard = 0
	victim.ult = d.ult or victim.ult
	victim.lastGuardHit = match.clock
	setBlocking(victim, false)
	BattleFX.guardBreak(d.x, d.y)
	BattleFX.impactFrame({ attacker and attacker.model, victim.model }, 0.12)
	Sound.play("KO", 0.6, 1.4)
	if victim == match.me then
		FighterSim.applyGuardBreak(match.sim, d.stun)
		CameraController.shake(1.2)
		MatchHUD.announce("GUARD BROKEN", RED, 0.9)
	else
		CameraController.shake(0.6)
		if attacker == match.me then
			MatchHUD.announce("GUARD BREAK!", GOLD, 0.9)
		end
	end
	if victim.model then
		FighterAnimator.hitstop(victim.model, d.hitstop)
		FighterAnimator.stunned(victim.model, d.stun)
	end
	MatchHUD.updateMeters(victim)
end

-- Someone spent a full meter: everyone freezes for the cut-in, then they
-- fight awakened for a while.
function handlers.Awaken(d)
	local f = match.fighters[d.fighterId]
	if not f then
		return
	end
	local now = match.clock
	f.awakened = true
	f.ult = 0
	f.ultUsed = false
	f.awakenEnds = now + d.freeze + d.duration
	f.invulnUntil = math.max(f.invulnUntil or 0, now + d.freeze)
	setBlocking(f, false)
	if f == match.me then
		FighterSim.awaken(match.sim, d.freeze)
	else
		FighterSim.freeze(match.sim, d.freeze)
	end
	for _, other in match.order do
		if other ~= f and other.model then
			FighterAnimator.hitstop(other.model, d.freeze)
		end
	end
	if f.model then
		FighterAnimator.awaken(f.model, d.freeze)
		BattleFX.awaken(f.model, d.freeze + d.duration)
	end
	local facing = facingOf(match, f)
	CameraController.focus(function()
		local x, y = fighterPosition(match, f)
		if not x then
			return nil
		end
		return x, y + 3.2
	end, 15, d.freeze, 22 * facing)
	CameraController.shake(1.0)
	BattleFX.impactFrame({ f.model }, 0.16)
	MatchHUD.announce(f == match.me and "AWAKENED!" or string.upper(f.name .. " awakened"), GOLD, 1.3)
	Sound.play("HeavySwing", 0.9, 0.55)
	MatchHUD.updateMeters(f)
end

function handlers.AwakenEnd(d)
	local f = match.fighters[d.fighterId]
	if not f then
		return
	end
	f.awakened = false
	f.awakenFrac = nil
	BattleFX.endAwaken(f.model)
	MatchHUD.updateMeters(f)
end

function handlers.Weapon(d)
	local f = match.fighters[d.fighterId]
	if not f then
		return
	end
	f.weapon = d.weapon
	if f.model then
		FighterAnimator.setWeapon(f.model, d.weapon)
	end
	if f == match.me then
		match.weapon = d.weapon
		if Weapons.isWeapon(d.weapon) then
			Sound.play("Pickup", 0.5)
		end
	end
	MatchHUD.updateFighter(f)
end

function handlers.KO(d)
	local f = match.fighters[d.victimId]
	local attacker = d.attackerId and match.fighters[d.attackerId]
	if not f then
		return
	end
	f.alive = false
	f.stocks = d.stocks
	f.score = d.score
	f.eliminated = d.eliminated
	f.weapon = "Unarmed"
	f.awakened = false
	f.guard = B.GuardMax
	setBlocking(f, false)
	BattleFX.endAwaken(f.model)
	if attacker and d.attackerScore then
		attacker.score = d.attackerScore
	end
	Visuals.koEffect(d.x, d.y, d.koEffect, match.world.camera)
	Sound.play("KO", 0.9, 0.6)
	CameraController.shake(1.8)
	if f.model then
		Visuals.stopPose(f.model)
	end
	if f == match.me then
		match.sim.frozen = true
		match.waitingKO = nil
		match.weapon = "Unarmed"
		Input.clearBuffer()
	end
	MatchHUD.ko(f, attacker)
	MatchHUD.updateFighter(f)
	MatchHUD.updateMeters(f)
	if attacker then
		MatchHUD.updateFighter(attacker)
	end
end

function handlers.Respawn(d)
	local f = match.fighters[d.fighterId]
	if not f then
		return
	end
	f.alive = true
	-- 0 normally; training can keep the damage over a KO, and placing a fighter keeps it
	f.damage = if type(d.damage) == "number" then d.damage else 0
	f.respawnInvulnUntil = match.clock + (d.invuln or 0)
	f.invulnUntil = math.max(f.invulnUntil or 0, f.respawnInvulnUntil)
	if f == match.me then
		FighterSim.respawn(match.sim, d.x, d.y, d.facing, d.invuln)
		match.waitingKO = nil
		Input.clearBuffer()
	end
	if f.model then
		Visuals.shimmer(f.model, d.invuln)
	end
	MatchHUD.updateFighter(f)
end

function handlers.Projectile(d)
	Visuals.spawnProjectile(d)
end

function handlers.ProjectileEnd(d)
	Visuals.endProjectile(d.id, d.x, d.y)
end

function handlers.Left(d)
	local f = match.fighters[d.fighterId]
	if f then
		f.left = true
		f.alive = false
		f.eliminated = true
		MatchHUD.updateFighter(f)
	end
end

-- Slow motion (training): the sim, input and animation run on match time.
function handlers.TimeScale(d)
	local scale = d.scale
	if type(scale) ~= "number" or scale ~= scale or scale <= 0 or scale == math.huge then
		return
	end
	match.timeScale = scale
	FighterAnimator.setTimeScale(scale)
end

-- A fighter's legend changed (training): re-track the model so the animator binds the new rig.
function handlers.Legend(d)
	local m = match
	local f = m.fighters[d.fighterId]
	if not f or not Legends.isValid(d.legend) then
		return
	end
	f.legend = d.legend
	f.ownLook = d.ownLook == true
	if f == m.me then
		m.legend = d.legend
	end
	local function retrack()
		if match == m and f.model and f.model.Parent and f.legend == d.legend then
			-- (the weapon too: the server's "Weapon" for a weapon the new legend keeps came before this "Legend")
			FighterAnimator.untrack(f.model)
			FighterAnimator.track(f.model, { isMe = f == m.me, legend = d.legend, weapon = f.weapon })
		end
	end
	retrack()
	-- the server swaps the rig before it broadcasts, but bind again once the swap has surely replicated
	task.delay(LEGEND_RETRACK, retrack)
	MatchHUD.updateFighter(f)
end

-- Damage set outside a hit (training).
function handlers.Damage(d)
	local f = match.fighters[d.fighterId]
	if not f or type(d.total) ~= "number" then
		return
	end
	f.damage = d.total
	MatchHUD.updateFighter(f)
end

function handlers.Training(d)
	trainingHook("onServer", match, d)
end

function handlers.End(d)
	local m = match
	m.phase = "Ended"
	m.sim.frozen = true
	Focus.setFightInput(false)
	MobileControls.hide()
	MatchHUD.ended()
	if m.training or d.source == "Training" or d.requeued then
		-- no results: the following "Leave" returns you to the menu
		if d.requeued then
			ClientState.toast(Models.requeuedToast(d.note))
		end
		return
	end
	local summary = summaryOf(m)
	task.delay(Config.Menu.ResultsDelay, function()
		-- (a match whose "Leave" came first is back in the menu: the results still show over it)
		if ClientState.phase ~= "Match" and ClientState.phase ~= "Menu" then
			return
		end
		local ok, shown = pcall(ResultsScreen.show, d, summary)
		if not ok or not shown then
			-- no results: "Leave" (or the menu you're already in) takes over
			warn("[MatchClient] results failed:", if ok then "not shown" else shown)
			return
		end
		ClientState.setPhase("Results")
	end)
end

function handlers.Leave()
	cleanup()
end

function MatchClient.isActive()
	return match ~= nil
end

function MatchClient.init()
	Net.get("MatchEvent").OnClientEvent:Connect(function(kind, data)
		data = if type(data) == "table" then data else {}
		local route = Models.routeMatchEvent(kind, data, match and match.info.matchId, match ~= nil)
		if route == "start" then
			startSeq += 1
			local seq = startSeq
			local ok, err = pcall(onStart, data, seq)
			if not ok and seq == startSeq and not endedEarly[data.matchId] then
				setupFailed(err)
			end
			return
		elseif route == "orphan" then
			-- no match here: an End / Leave of the VS match means it died before "Start" (or while its fighter
			-- loaded: onStart then gives up)
			if kind == "End" or kind == "Leave" then
				if data.matchId ~= nil then
					endedEarly[data.matchId] = true
				end
				applyPhase(Models.phaseAfter({
					type = "MatchEnd",
					matchId = data.matchId,
					requeued = data.requeued == true,
					note = data.note,
				}, phaseState()))
			end
			return
		elseif route == "ignore" then
			-- a late event of another match
			return
		end
		local handler = handlers[kind]
		if handler then
			local ok, err = pcall(handler, data)
			if not ok then
				warn("[MatchClient]", kind, err)
			end
		end
	end)

	-- Characters exist only in matches: losing yours before the end (a forfeit, a server error) means you're out.
	-- The server takes it with `Character = nil` and Destroy (no LoadCharacterAsync), so the Character property going
	-- nil is watched too. [Studio check: whether CharacterRemoving fires on the client for that.]
	local function characterGone()
		if match and match.phase ~= "Ended" then
			cleanup()
		end
	end
	player.CharacterRemoving:Connect(characterGone)
	player:GetPropertyChangedSignal("Character"):Connect(function()
		if player.Character == nil then
			characterGone()
		end
	end)

	-- Leaving an ended match's screen before its "Leave" (MENU on the results): the HUD (GAME!, the cards; it
	-- draws above the menu) goes at once
	ClientState.PhaseChanged:Connect(function(phase)
		if match and match.phase == "Ended" and phase ~= "Match" then
			MatchHUD.hide()
		end
	end)
end

return MatchClient
