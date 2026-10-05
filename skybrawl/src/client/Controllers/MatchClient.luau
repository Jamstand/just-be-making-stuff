--[[
    Runs your fighter during a match.

    Each frame: read input -> FighterSim.step -> move your character ->
    report attacks/dodges/throws to the server -> check your active
    hitbox against other fighters and report hits. The server answers with
    "Hit" events (including knockback when you're the one hit), KOs,
    respawns, weapon changes, projectiles and the final results.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Maps = require(Shared.Maps)
local Weapons = require(Shared.Weapons)
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

local UI = script.Parent.Parent:WaitForChild("UI")
local MatchHUD = require(UI.MatchHUD)
local ResultsScreen = require(UI.ResultsScreen)
local MobileControls = require(UI.MobileControls)

local MatchClient = {}

local player = Players.LocalPlayer
local fighterAction = Net.get("FighterAction")
local STEP_NAME = "SkybrawlFighter"
local GRAVEYARD_Y = 600
local rng = Random.new()

local match = nil
local hitboxPart = nil

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

local function setDefaultControls(enabled)
	pcall(function()
		local playerModule = require(player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule"))
		local controls = playerModule:GetControls()
		if enabled then
			controls:Enable()
		else
			controls:Disable()
		end
	end)
	pcall(function()
		GuiService.TouchControlsEnabled = enabled
	end)
	pcall(function()
		StarterGui:SetCore("ResetButtonCallback", enabled)
	end)
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, enabled)
	end)
end

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
	drawHitbox(m, x1, y1, x2, y2)
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
					if os.clock() < (f.invulnUntil or 0) then
						continue
					end
					-- Predict the server's hit-stop so the freeze and the combo
					-- window start right away.
					local charge = FighterSim.chargeFraction(sim)
					local dmg = Combat.damage(move, charge, m.info.damageMultiplier)
					local _, _, force = Combat.knockback(move, (f.damage or 0) + dmg, charge, sim.facing, fx - sim.x)
					local stop = Combat.hitstop(force)
					FighterSim.onHitConfirm(sim, stop)
					FighterAnimator.hitstop(m.character, stop)
					if f.model then
						FighterAnimator.hitstop(f.model, stop)
					end
					Visuals.hitSpark(
						(math.max(x1, hx1) + math.min(x2, hx2)) / 2,
						(math.max(y1, hy1) + math.min(y2, hy2)) / 2,
						heavy,
						0
					)
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
		local move = Weapons.getAttack(m.weapon, ev.slot)
		local heavy = move and move.Kind == "Heavy"
		Sound.play(heavy and "HeavySwing" or "Swing", heavy and 0.45 or 0.35, rng:NextNumber(0.9, 1.15))
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
	end
end

local function step(dt)
	local m = match
	if not m then
		return
	end
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
		}
		local events = FighterSim.step(sim, input, dt, ctx)
		for _, ev in events do
			handleSimEvent(m, ev)
		end
		detectHits(m)
		if Maps.isOutOfBounds(m.world, sim.x, sim.y) then
			-- Hold here until the server confirms the KO.
			sim.frozen = true
			m.waitingKO = os.clock()
		end
	elseif m.waitingKO and os.clock() - m.waitingKO > 3 and m.me.alive then
		sim.frozen = false
		m.waitingKO = nil
	end

	applyTransform(m)
	local anim = (sim.frozen and m.me.alive) and "Idle" or FighterSim.animState(sim)
	if sim.wallSide ~= 0 and not sim.grounded then
		anim = "WallSlide"
	end
	FighterAnimator.setLocomotion(
		m.character,
		anim,
		anim == "Run" and math.clamp(math.abs(sim.vx) / Config.Physics.RunSpeed, 0.6, 1.4) or 1
	)
end

-- Server events -----------------------------------------------------------

local function cleanup()
	local m = match
	if not m then
		return
	end
	match = nil
	RunService:UnbindFromRenderStep(STEP_NAME)
	Input.setEnabled(false)
	CameraController.stop()
	Visuals.stopMatch()
	FighterAnimator.stopMatch()
	SkyBackdrop.stop()
	CharacterAnimator.setMatchMode(false)
	MatchHUD.hide()
	MobileControls.hide()
	ResultsScreen.hide()
	if hitboxPart then
		hitboxPart:Destroy()
		hitboxPart = nil
	end
	restoreCharacter(m)
	setDefaultControls(true)
	ClientState.setInMatch(false)
end

local function onStart(info)
	cleanup()
	local character = player.Character or player.CharacterAdded:Wait()
	character:WaitForChild("HumanoidRootPart", 5)

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
			damage = 0,
			weapon = "Unarmed",
			alive = true,
			eliminated = false,
			left = false,
		}
		f.feetOffset = fi.model and Util.feetOffset(fi.model) or 3
		f.root = fi.model and fi.model:FindFirstChild("HumanoidRootPart")
		m.fighters[f.id] = f
		table.insert(m.order, f)
	end
	m.me = m.fighters[info.you]
	if not m.me or not prepareCharacter(m) then
		warn("[MatchClient] couldn't set up your fighter")
		return
	end
	m.me.model = m.character
	m.me.root = m.root
	m.legend = m.me.legend or "Avatar"
	m.sim = FighterSim.newState(info.spawn.x, info.spawn.y, info.spawn.facing)
	m.sim.frozen = true
	match = m
	applyTransform(m)

	ClientState.setInMatch(true)
	setDefaultControls(false)
	Input.setEnabled(true)
	CameraController.start(info.origin, m.world)
	CameraController.setProvider(cameraData)
	Visuals.startMatch(info.origin)
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

	-- UI last, and never allowed to block the fight itself.
	local ok, err = pcall(MatchHUD.show, m)
	if not ok then
		warn("[MatchClient] HUD failed:", err)
	end
	if UserInputService.TouchEnabled then
		ok, err = pcall(MobileControls.show)
		if not ok then
			warn("[MatchClient] touch controls failed:", err)
		end
	end
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
		Visuals.onAttack(f.model, d.weapon, d.slot, d.seq)
	elseif d.kind == "Release" then
		Visuals.releaseCharge(f.model, d.seq)
	elseif d.kind == "Dodge" then
		local P = Config.Physics
		local invuln = ({ Spot = P.SpotDodgeTime, AirSpot = P.SpotDodgeTime, Air = P.AirDodgeInvuln })[d.dodgeKind]
		if invuln then
			f.invulnUntil = math.max(f.invulnUntil or 0, os.clock() + invuln)
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
	end
	-- Your own melee hits already sparked locally; ranged hits are server-side.
	if attacker ~= match.me or d.ranged then
		Visuals.hitSpark(d.x, d.y, d.heavy, d.force)
		Sound.play("Hit", d.heavy and 0.8 or 0.5, d.heavy and 0.8 or 1.1)
	end
	Visuals.damageNumber(d.x, d.y, d.damage, Combat.damageColor(d.total))
	if victim == match.me then
		FighterSim.applyHit(match.sim, d.kbx, d.kby, d.hitstun, d.hitstop)
		CameraController.shake(0.4 + d.force * 0.012)
		Visuals.hurt(match.character, d.hitstun + (d.hitstop or 0), d.force)
		FighterAnimator.hitstop(match.character, d.hitstop)
	elseif victim and victim.model then
		Visuals.hurt(victim.model, d.hitstun + (d.hitstop or 0), d.force)
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
	end
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
	f.damage = 0
	f.respawnInvulnUntil = os.clock() + (d.invuln or 0)
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

function handlers.End(d)
	match.phase = "Ended"
	match.sim.frozen = true
	Input.setEnabled(false)
	MobileControls.hide()
	MatchHUD.ended()
	ResultsScreen.show(d, match)
end

function handlers.Leave()
	cleanup()
end

function MatchClient.isActive()
	return match ~= nil
end

function MatchClient.init()
	Net.get("MatchEvent").OnClientEvent:Connect(function(kind, data)
		if kind == "Start" then
			onStart(data)
			return
		end
		if not match then
			return
		end
		local handler = handlers[kind]
		if handler then
			local ok, err = pcall(handler, data or {})
			if not ok then
				warn("[MatchClient]", kind, err)
			end
		end
	end)

	-- A new character means we're back in the lobby (match over, or you
	-- forfeited / reset).
	player.CharacterAdded:Connect(function()
		if match then
			cleanup()
		end
	end)
end

return MatchClient
