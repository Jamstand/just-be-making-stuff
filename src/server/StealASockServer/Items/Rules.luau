-- Items.Rules: what each bar item does on the server, and the world objects it leaves behind
-- (all in workspace.StealASock.Items, all server-made so everyone sees them). Every number is the
-- owner's, at their upgrade level: ItemConfig.Stat(key, level, name) (Items.Stat), and the last
-- level is golden (the world objects use `<model>_Gold`, attributes Level / Gold). docs/ITEMS.md
-- describes every item.
--   Towel           Towel.Snap: a thief in the cone first, else a shove; held: a combo finisher
--   SlipperDash     the client dashes; the server bumps whoever it runs into; air dashes
--   BananaPeel      peels on the floor; a slipper slides on and bowls others over (a chain)
--   BubbleBlaster   bubbles the server flies: they bounce off walls, splash, fan out, home in
--   DuckAlarm       guard ducks in your own drawer: waddle after intruders, honk, reveal, stun
--   SoftenerCloud   a drifting, growing cloud: everyone else inside is slow; a thief nods off
--   StaticBalloon   hold to rub it, let go to ZAP (bigger with the charge; golden: arcs on)
--   LaundryBasket   hide under it (only the basket shows); popping out yourself is a pounce
--   Glider          from any jump: a dryer-sheet canopy; press again to SLAM down
-- The owner is never hit by their own item, and every push / stun respects ShoveGrace.
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Rules = {}
local S
local Items
local Cfg

local CANOPY_Y = 3.6 -- studs above the root part: the glider canopy floats over the head
local BUBBLE_BODY = 1.5 -- studs added to the bubble's radius for the character's body
local FLOAT_RISE = 0.6 -- seconds a bubbled thief takes to float up (then it hovers)
local CLOUD_FADE = 0.8 -- seconds the cloud takes to fade out at the end
local SOFT_LINGER = 0.35 -- seconds the slowness lasts after leaving the cloud
local GLIDE_LAND = 0.25 -- seconds on the ground before the server ends a glide itself
local AIR_EPS = 0.35 -- studs of air under the feet that count as airborne (gliding, air dashes)
local AIR_DASH_WINDOW = 1.2 -- seconds after a dash in which Dash.airDashes more are allowed (airborne)
local DASH_SLACK = 0.15 -- seconds a dash / slide keeps hitting after it ends (its position arrives late)
local SLIDE_SECONDS = 0.55 -- seconds a slipper (or a bowled-over player) slides for
local BUBBLE_FAN = math.rad(12) -- between the bubbles of a fan (Bubble.shots)
local HOMING_TURN = 8 -- how hard Bubble.homing steers toward a thief (per second)
local STEER_UPDATE = math.rad(10) -- a homing bubble tells the clients its new path after turning this much
local DUCK_STOP = 2.2 -- studs a chasing duck stops short of its intruder
local SLAM_WAIT = 0.6 -- seconds after a slam press the shockwave comes even if no landing was seen
local AUTO_ZAP = 2 -- seconds after a full charge the balloon zaps by itself
local CHAIN_HOP = 10 -- studs a golden zap's arc can jump (from the zap's edge or a zapped player)

type Peel = { model: Model, pos: Vector3, cf: CFrame, untilTime: number, level: number }
type Duck = { model: Model, root: BasePart, ap: any, ao: any, home: Vector3, pos: Vector3, dir: Vector3, out: Vector3, lastHonk: number }
type Guard = {
	record: any,
	level: number,
	ducks: { Duck },
	inside: { [Player]: boolean },
	lastQuack: number,
	alerted: { [Player]: number },
	stunAt: { [Player]: number },
	revealAt: { [Player]: number },
	lastStep: number,
}
type Cloud = {
	owner: Player,
	level: number,
	start: Vector3,
	finish: Vector3,
	centre: Vector3,
	r0: number,
	r1: number,
	radius: number,
	born: number,
	untilTime: number,
	model: Model,
	fading: boolean,
	inside: { [Player]: number },
}
type Bubble = {
	id: number,
	owner: Player,
	level: number,
	pos: Vector3,
	dir: Vector3,
	speed: number,
	left: number,
	reach: number,
	bounces: number,
	homing: number,
	sentDir: Vector3,
	sentAt: number,
}
type Chain = { owner: Player, level: number, members: { [Player]: boolean }, count: number, moment: boolean }
type Slide = { player: Player, depth: number, chain: Chain, dir: Vector3, untilTime: number }

local folder: Instance? = nil
local rayParams: RaycastParams? = nil
local peels: { [Player]: { Peel } } = {}
local guards: { [Player]: Guard } = {}
local clouds: { Cloud } = {}
local bubbles: { Bubble } = {}
local slides: { Slide } = {}
local nextBubble = 0

-- ---------- helpers ----------

local function now(): number
	return workspace:GetServerTimeNow()
end

local function stat(key: string, level: number, name: string): number
	return Cfg.Stat(key, level, name)
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function humanoidOf(player: Player): Humanoid?
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

local function alive(player: Player): boolean
	local humanoid = humanoidOf(player)
	return humanoid ~= nil and humanoid.Health > 0 and rootOf(player) ~= nil
end

local function carrying(player: Player): boolean
	return S.Steal.IsCarrying(player)
end

local function flat(v: Vector3): Vector3?
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 1e-3 then f.Unit else nil
end

local function flatDistance(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function lerp(a: number, b: number, k: number): number
	return a + (b - a) * k
end

-- A frame at `pos` whose +Z (an item model's front) points along the horizontal `dir`.
local function facing(pos: Vector3, dir: Vector3): CFrame
	return CFrame.lookAt(pos, pos - dir)
end

-- Level and Gold attributes on a world object.
local function tag(model: Instance, level: number)
	model:SetAttribute("Level", level)
	model:SetAttribute("Gold", if Cfg.IsGold(level) then true else nil)
end

local function isGold(model: Instance): boolean
	return model:GetAttribute("Gold") == true
end

-- Studs from the root part's centre down to the feet.
local function feetDepth(player: Player): number
	local humanoid = humanoidOf(player)
	local root = rootOf(player)
	if not humanoid or not root then
		return 3
	end
	if humanoid.RigType == Enum.HumanoidRigType.R6 then
		return root.Size.Y / 2 + 2
	end
	return humanoid.HipHeight + root.Size.Y / 2
end

-- The floor under a point: the map and the drawers only (never players, socks or items).
local function floorBelow(position: Vector3, depth: number): Vector3?
	local hit = workspace:Raycast(position, Vector3.new(0, -depth, 0), rayParams)
	return if hit then hit.Position else nil
end

local function grounded(player: Player): boolean
	local root = rootOf(player)
	if not root then
		return true
	end
	return floorBelow(root.Position, feetDepth(player) + 1.2) ~= nil
end

-- In the air (any jump counts): rising, or nothing under the feet within AIR_EPS.
local function airborne(player: Player): boolean
	local root = rootOf(player)
	if not root then
		return false
	end
	if root.AssemblyLinearVelocity.Y > 6 then
		return true
	end
	return floorBelow(root.Position, feetDepth(player) + AIR_EPS) == nil
end

local function floorNear(player: Player, spot: Vector3, extra: number): Vector3
	local depth = feetDepth(player)
	return floorBelow(spot + Vector3.new(0, 2, 0), depth + extra) or (spot - Vector3.new(0, depth, 0))
end

-- How far along `dir` (from `from`) before a wall, at most `dist` (minus `margin` at a wall).
local function clearDistance(from: Vector3, dir: Vector3, dist: number, margin: number): number
	if dist <= 0 then
		return 0
	end
	local hit = workspace:Raycast(from, dir * dist, rayParams)
	if hit then
		return math.max(0, flatDistance(hit.Position, from) - margin)
	end
	return dist
end

-- Where an item's effect comes out of the held tool (its Tip attachment), if it's held.
local function tipOf(player: Player, key: string): Vector3?
	local character = player.Character
	local tool = character and character:FindFirstChild("Item_" .. key)
	local handle = tool and tool:FindFirstChild("Handle")
	local tip = handle and handle:FindFirstChild("Tip")
	return if tip and tip:IsA("Attachment") then tip.WorldPosition else nil
end

-- distance from p to the segment a-b, and how far along it (0..1) the closest point is
local function segmentDistance(a: Vector3, b: Vector3, p: Vector3): (number, number)
	local ab = b - a
	local len2 = ab:Dot(ab)
	local u = if len2 > 1e-6 then math.clamp((p - a):Dot(ab) / len2, 0, 1) else 0
	return (a + ab * u - p).Magnitude, u
end

-- The way a player is moving (their velocity, else the move keys, else where they face).
local function moveDir(player: Player): Vector3?
	local root = rootOf(player)
	if not root then
		return nil
	end
	local v = root.AssemblyLinearVelocity
	if Vector3.new(v.X, 0, v.Z).Magnitude > 2 then
		return flat(v)
	end
	local humanoid = humanoidOf(player)
	return (humanoid and flat(humanoid.MoveDirection)) or flat(root.CFrame.LookVector)
end

-- Hides parts / guis and remembers their values; restore() puts every one back exactly.
local function hider(): ((Instance) -> (), () -> ())
	local saved: { [Instance]: any } = {}
	local function hide(inst: Instance)
		if saved[inst] ~= nil then
			return
		end
		local x = inst :: any
		if inst:IsA("BasePart") or inst:IsA("Decal") then
			saved[inst] = x.Transparency
			x.Transparency = 1
		elseif inst:IsA("BillboardGui") or inst:IsA("SurfaceGui") or inst:IsA("ParticleEmitter") or inst:IsA("Trail") or inst:IsA("Beam") then
			saved[inst] = x.Enabled
			x.Enabled = false
		elseif inst:IsA("Humanoid") then
			saved[inst] = x.DisplayDistanceType
			x.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		end
	end
	local function restore()
		for inst, value in pairs(saved) do
			local x = inst :: any
			if inst.Parent then
				if inst:IsA("BasePart") or inst:IsA("Decal") then
					x.Transparency = value
				elseif inst:IsA("Humanoid") then
					x.DisplayDistanceType = value
				else
					x.Enabled = value
				end
			end
		end
		table.clear(saved)
	end
	return hide, restore
end

local function newFolder(): Instance
	if folder and folder.Parent then
		return folder
	end
	local f = Instance.new("Folder")
	f.Name = "Items"
	f.Parent = S.Map.Root or workspace
	folder = f
	return f
end

-- Knocked about by a twist (bump, bowl, nap, slam ...): out of the basket and off the glider.
local function shaken(p: Player, why: string)
	Items.PopOut(p, why)
	local pst = Items.State(p)
	if pst then
		Rules.Stop(p, pst, "Glider", why)
	end
end

-- A thief's sock goes home (Items.SendSockHome) with a toast for them. True when they had one.
local function dropSock(p: Player, reason: string, text: string): boolean
	if Items.SendSockHome(p, reason) then
		S.Toast(p, text, "bad")
		return true
	end
	return false
end

-- ---------- Banana Peel (and peel bowling) ----------

local function removePeel(owner: Player, which: Peel?)
	local list = peels[owner]
	if not list then
		return
	end
	for i = #list, 1, -1 do
		local peel = list[i]
		if which == nil or peel == which then
			table.remove(list, i)
			peel.model:Destroy()
		end
	end
	if #list == 0 then
		peels[owner] = nil
		Items.SetActive(owner, "BananaPeel", false)
	end
end

-- The slipper (depth 1), and everyone they bowl over, slides on: `bowlDistance` studs along `dir`
-- (short of walls). Anyone a slide reaches stumbles and slides on too, `chain` levels deep.
local function startSlide(victim: Player, chain: Chain, depth: number, dir: Vector3)
	local root = rootOf(victim)
	if not root then
		return
	end
	chain.members[victim] = true
	chain.count += 1
	local from = root.Position
	local dist = clearDistance(from, dir, stat("BananaPeel", chain.level, "bowlDistance"), 1.5)
	if dist > 0.5 then
		Items.Slide(victim, dir, dist / SLIDE_SECONDS, SLIDE_SECONDS)
	end
	table.insert(slides, { player = victim, depth = depth, chain = chain, dir = dir, untilTime = now() + SLIDE_SECONDS + DASH_SLACK })
	Items.FX("bowl", { player = victim, from = from, to = from + dir * dist })
end

local function stumble(p: Player, slide: Slide)
	local chain = slide.chain
	local seconds = stat("BananaPeel", chain.level, "stumbleSeconds")
	local r = rootOf(p)
	local sr = rootOf(slide.player)
	local away = if r and sr then flat(r.Position - sr.Position) else nil
	local dir = if away then (flat(slide.dir + away * 0.5) or slide.dir) else slide.dir
	shaken(p, "bowl")
	dropSock(p, "bowled", "Bowled over! You dropped the sock. 🍌") -- a thief anywhere in the chain drops it
	Items.Stun(p, seconds)
	Items.FX("tumble", { player = p, dir = dir, seconds = seconds + 0.3 })
	startSlide(p, chain, slide.depth + 1, dir)
	if chain.count >= 2 and not chain.moment then
		chain.moment = true
		local targets = {}
		for member in pairs(chain.members) do
			table.insert(targets, member)
		end
		Items.Moment("bowl", if r then r.Position else Vector3.zero, chain.owner, targets, 0.6)
		if chain.owner.Parent == Players then
			S.Toast(chain.owner, "🎳 Your banana peel bowled them over!", "good")
		end
	end
end

local function slip(victim: Player, owner: Player, peel: Peel)
	local seconds = stat("BananaPeel", peel.level, "slipSeconds")
	local dir = moveDir(victim) or Vector3.new(0, 0, -1)
	removePeel(owner, peel)
	Items.FX("slip", { player = victim, position = peel.pos, seconds = seconds })
	shaken(victim, "slip")
	Items.SendSockHome(victim, "slipped")
	Items.Stun(victim, seconds)
	-- peel bowling: the slipper slides on and bowls over whoever is in the way
	local chain: Chain = { owner = owner, level = peel.level, members = {}, count = 0, moment = false }
	startSlide(victim, chain, 1, dir)
	S.Toast(victim, "Whoa! You slipped on " .. owner.DisplayName .. "'s banana peel! 🍌", "bad")
	S.Toast(owner, victim.DisplayName .. " slipped on your banana peel! 🍌", "good")
end

local function tickPeels(t: number)
	for owner, list in pairs(peels) do
		if owner.Parent ~= Players then
			removePeel(owner)
		else
			for i = #list, 1, -1 do
				local peel = list[i]
				if t >= peel.untilTime then
					removePeel(owner, peel)
				else
					local radius = stat("BananaPeel", peel.level, "radius")
					for _, p in ipairs(Players:GetPlayers()) do
						local r = rootOf(p)
						if p ~= owner and r and table.find(list, peel) and Items.CanShove(p) then
							local off = r.Position - peel.pos
							if Vector3.new(off.X, 0, off.Z).Magnitude <= radius and off.Y > -1 and off.Y < 5 then
								slip(p, owner, peel)
							end
						end
					end
				end
			end
		end
	end
end

-- Every Heartbeat: a slide bowls over whoever it reaches (not the peel's owner, once per chain).
local function stepSlides(t: number)
	for i = #slides, 1, -1 do
		local slide = slides[i]
		local sr = rootOf(slide.player)
		local chain = slide.chain
		if t > slide.untilTime or not sr or not alive(slide.player) then
			table.remove(slides, i)
		elseif slide.depth < stat("BananaPeel", chain.level, "chain") then
			local radius = stat("BananaPeel", chain.level, "bowlRadius")
			for _, p in ipairs(Players:GetPlayers()) do
				if p ~= chain.owner and not chain.members[p] then
					local r = rootOf(p)
					if r and alive(p) and (r.Position - sr.Position).Magnitude <= radius and Items.CanShove(p) then
						stumble(p, slide)
					end
				end
			end
		end
	end
end

-- ---------- Slipper Dash (bumps) ----------

local function bump(player: Player, p: Player, dash)
	local r = rootOf(p)
	local root = rootOf(player)
	if not r or not root then
		return
	end
	local away = flat(r.Position - root.Position) or dash.dir
	local dir = flat(away + dash.dir * 0.5) or dash.dir
	Items.PopOut(p, "bump")
	local dropped = dropSock(p, "bumped", "Bumped! You dropped the sock. 🥿")
	local pushed = Items.Shove(player, p, dir, stat("SlipperDash", dash.level, "bumpMult"))
	if pushed or dropped then
		Items.FX("bump", { player = player, target = p, position = r.Position })
	end
end

-- Every Heartbeat while a dash lasts: anyone within bumpRadius of the dasher is bumped (once a dash).
local function stepDashes(t: number)
	for player, st in pairs(Items.All()) do
		local dash = st.dash
		if dash then
			local root = rootOf(player)
			if t > dash.untilTime or not root or not alive(player) then
				st.dash = nil
			else
				local radius = stat("SlipperDash", dash.level, "bumpRadius")
				for _, p in ipairs(Players:GetPlayers()) do
					if p ~= player and not dash.hit[p] then
						local r = rootOf(p)
						if r and alive(p) and (r.Position - root.Position).Magnitude <= radius then
							dash.hit[p] = true
							bump(player, p, dash)
						end
					end
				end
			end
		end
	end
end

-- ---------- Bubble Blaster ----------

local function endEncase(player: Player, st)
	local e = st.encase
	if not e then
		return
	end
	st.encase = nil
	e.ball:Destroy()
	e.lift:Destroy()
	e.att:Destroy()
	local character = player.Character
	if character then
		character:SetAttribute("Encased", nil)
	end
	if player.Parent == Players then
		Items.RefreshSpeed(player)
	end
end

local function encase(victim: Player, floatSeconds: number, floatHeight: number)
	local st = Items.State(victim)
	local root = rootOf(victim)
	if not st or not root or st.encase then
		return
	end
	Rules.Stop(victim, st, "Glider", "bubble")
	local ball = Instance.new("Part")
	ball.Name = "Bubble_" .. victim.UserId
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.new(7, 7, 7)
	ball.Material = Enum.Material.Glass
	ball.Color = Color3.fromRGB(170, 225, 255)
	ball.Transparency = 0.6
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CanTouch = false
	ball.Massless = true
	ball.CastShadow = false
	ball.CFrame = root.CFrame
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = ball
	weld.Parent = ball
	ball.Parent = newFolder()
	local att = Instance.new("Attachment")
	att.Name = "ItemFloat"
	att.Parent = root
	local lift = Instance.new("LinearVelocity")
	lift.Name = "ItemFloat"
	lift.Attachment0 = att
	lift.MaxForce = math.huge
	lift.RelativeTo = Enum.ActuatorRelativeTo.World
	lift.VectorVelocity = Vector3.new(0, floatHeight / FLOAT_RISE, 0)
	lift.Parent = root
	local t = now()
	st.encase = { ball = ball, att = att, lift = lift, risingUntil = t + FLOAT_RISE, untilTime = t + floatSeconds }
	st.graceUntil = math.max(st.graceUntil, t + floatSeconds + Cfg.ShoveGrace)
	if victim.Character then
		victim.Character:SetAttribute("Encased", true)
	end
	Items.FX("encase", { player = victim, seconds = floatSeconds })
	Items.RefreshSpeed(victim)
end

local function bubbleHit(b: Bubble, victim: Player)
	local root = rootOf(victim)
	if not root then
		return
	end
	if carrying(victim) then
		Items.PopOut(victim, "bubble")
		Items.SendSockHome(victim, "bubbled")
		encase(victim, stat("BubbleBlaster", b.level, "floatSeconds"), stat("BubbleBlaster", b.level, "floatHeight"))
		Items.Moment("bubble", root.Position, b.owner, { victim }, 0.6)
		if b.owner.Parent == Players then
			S.Toast(b.owner, "Bubbled " .. victim.DisplayName .. "! The sock floats home. 🫧", "good")
		end
	elseif Items.CanShove(victim) then
		local Eco = S.Config.Economy
		local mult = stat("BubbleBlaster", b.level, "bounceMult")
		local away = flat(root.Position - b.pos) or b.dir
		Items.Knock(victim, away, Eco.TowelKnockback * mult, Eco.TowelKnockUp * mult)
		Items.FX("tumble", { player = victim, dir = away, seconds = 0.4, soft = true })
	end
end

-- A bubble pops: the one it hit (if any) gets the bubble, and everyone else around gets splashed.
local function popBubble(b: Bubble, at: Vector3, victim: Player?)
	local splash = stat("BubbleBlaster", b.level, "splashRadius")
	Items.FX("bubblepop", { id = b.id, position = at, splash = splash })
	if victim then
		bubbleHit(b, victim)
	end
	local mult = stat("BubbleBlaster", b.level, "splashMult")
	if splash <= 0 or mult <= 0 then
		return
	end
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= b.owner and p ~= victim then
			local r = rootOf(p)
			if r and alive(p) and (r.Position - at).Magnitude <= splash then
				Items.Shove(b.owner, p, flat(r.Position - at) or b.dir, mult, 0.35)
			end
		end
	end
end

-- The nearest thief ahead of a bubble (homing), or nil.
local function thiefAhead(b: Bubble): Vector3?
	local best: Vector3? = nil
	local bestDist = b.left + 4
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= b.owner and carrying(p) then
			local r = rootOf(p)
			if r and alive(p) then
				local off = r.Position - b.pos
				local dir = flat(off)
				local dist = off.Magnitude
				if dir and dist < bestDist and dir:Dot(b.dir) > 0.2 then
					best, bestDist = r.Position, dist
				end
			end
		end
	end
	return best
end

local function stepBubbles(dt: number, t: number)
	for i = #bubbles, 1, -1 do
		local b = bubbles[i]
		if b.homing > 0 then
			local target = thiefAhead(b)
			local want = if target then flat(target - b.pos) else nil
			if want then
				b.dir = flat(b.dir + want * math.min(1, b.homing * HOMING_TURN * dt)) or b.dir
				if b.dir:Dot(b.sentDir) < math.cos(STEER_UPDATE) and t - b.sentAt >= 0.15 then
					-- a path update for the clients (steer = it turned, it didn't bounce)
					b.sentDir, b.sentAt = b.dir, t
					Items.FX("bubblebounce", { id = b.id, position = b.pos, dir = b.dir, steer = true })
				end
			end
		end
		local move = math.min(b.speed * dt, b.left)
		local to = b.pos + b.dir * move
		local victim: Player? = nil
		local nearest = math.huge
		for _, p in ipairs(Players:GetPlayers()) do
			local r = rootOf(p)
			if p ~= b.owner and r and alive(p) then
				local d, u = segmentDistance(b.pos, to, r.Position)
				if d <= b.reach and u < nearest then
					victim, nearest = p, u
				end
			end
		end
		local popAt: Vector3? = nil
		if victim then
			local r = rootOf(victim)
			popAt = if r then r.Position else to
		else
			local hit = if move > 0 then workspace:Raycast(b.pos, to - b.pos, rayParams) else nil
			if hit then
				local normal = flat(hit.Normal)
				if b.bounces > 0 and normal then
					-- bounce off the wall / furniture: reflect, and tell every client the new path
					b.bounces -= 1
					b.left = math.max(0, b.left - (hit.Position - b.pos).Magnitude)
					b.dir = flat(b.dir - normal * 2 * b.dir:Dot(normal)) or -b.dir
					b.pos = hit.Position + normal * 0.3
					b.sentDir, b.sentAt = b.dir, t
					Items.FX("bubblebounce", { id = b.id, position = hit.Position, dir = b.dir })
					continue
				end
				popAt = hit.Position
			end
		end
		b.left -= move
		b.pos = to
		if popAt or b.left <= 1e-3 then
			table.remove(bubbles, i)
			popBubble(b, popAt or to, victim)
		end
	end
end

-- ---------- Rubber Duck Alarm (guard ducks) ----------

-- A duck: one unanchored assembly the server owns, held on the floor by an AlignPosition and
-- turned by an AlignOrientation, so it waddles smoothly between the server's steps.
local function buildDuck(owner: Player, level: number, pos: Vector3, dir: Vector3): (Model, BasePart, any, any)
	local model, point = Items.Looks.World("AlarmDuck", false, nil, Cfg.IsGold(level))
	local cf = facing(pos, dir)
	local root = Items.Looks.Assemble(model, point, cf)
	local att = Instance.new("Attachment")
	att.Name = "DuckAlign"
	att.Parent = root
	local ap = Instance.new("AlignPosition") :: any
	ap.Name = "DuckWaddle"
	ap.Mode = Enum.PositionAlignmentMode.OneAttachment
	ap.Attachment0 = att
	ap.Position = pos
	ap.MaxForce = 1e6
	ap.MaxVelocity = stat("DuckAlarm", level, "chaseSpeed") * 1.3
	ap.Responsiveness = 30
	ap.Parent = root
	local ao = Instance.new("AlignOrientation") :: any
	ao.Name = "DuckTurn"
	ao.Mode = Enum.OrientationAlignmentMode.OneAttachment
	ao.Attachment0 = att
	ao.CFrame = cf.Rotation
	ao.MaxTorque = 1e6
	ao.Responsiveness = 20
	ao.Parent = root
	model.Name = "AlarmDuck_" .. owner.UserId
	model:SetAttribute("OwnerId", owner.UserId)
	tag(model, level)
	model.Parent = newFolder()
	local body: any = root
	pcall(function()
		body:SetNetworkOwner(nil) -- the server moves it, so it doesn't stutter
	end)
	return model, root, ap, ao
end

local function removeGuard(owner: Player)
	local guard = guards[owner]
	if guard then
		guards[owner] = nil
		for _, duck in ipairs(guard.ducks) do
			duck.model:Destroy()
		end
		Items.SetActive(owner, "DuckAlarm", false)
	end
end

local function honk(owner: Player, guard: Guard, duck: Duck, p: Player, t: number)
	local level = guard.level
	local r = rootOf(p)
	local pst = Items.State(p)
	Items.FX("honk", { duck = duck.model, position = duck.pos, target = p })
	if pst then
		local slow = stat("DuckAlarm", level, "honkSlow")
		pst.honkMult = if pst.honkUntil > t then math.min(pst.honkMult, slow) else slow
		pst.honkUntil = math.max(pst.honkUntil, t + stat("DuckAlarm", level, "honkSeconds"))
		Items.RefreshSpeed(p)
	end
	if not carrying(p) then
		return
	end
	local gap = stat("DuckAlarm", level, "honkGap")
	if t - (guard.revealAt[p] or -math.huge) >= gap * 0.9 then
		guard.revealAt[p] = t -- (two ducks honking together reveal once)
		Items.FX("reveal", { target = p, seconds = stat("DuckAlarm", level, "revealSeconds") }, owner)
	end
	local stun = stat("DuckAlarm", level, "honkStun")
	if stun > 0 and t - (guard.stunAt[p] or -math.huge) >= stat("DuckAlarm", level, "stunGap") and Items.CanShove(p) then
		guard.stunAt[p] = t
		shaken(p, "honk")
		dropSock(p, "honked", "HONK! The golden duck made you drop the sock! 🦆")
		Items.Stun(p, stun)
		Items.FX("tumble", { player = p, dir = (if r then flat(r.Position - duck.pos) else nil) or duck.dir, seconds = stun + 0.3 })
		Items.Moment("honk", duck.pos, owner, { p }, 0.7)
		S.Toast(owner, "🦆 HONK! Your golden duck stopped " .. p.DisplayName .. "!", "good")
	end
end

-- One duck's step: waddle toward the nearest intruder (stopping just short), or back home; honk.
local function stepDuck(owner: Player, guard: Guard, duck: Duck, intruders: { Player }, t: number, dt: number)
	local level = guard.level
	local target: Player? = nil
	local targetPos = Vector3.zero
	local best = math.huge
	for _, p in ipairs(intruders) do
		local r = rootOf(p)
		if r then
			local d = flatDistance(r.Position, duck.pos)
			if d < best then
				target, targetPos, best = p, r.Position, d
			end
		end
	end
	local goal = duck.home
	if target then
		local off = Vector3.new(targetPos.X - duck.pos.X, 0, targetPos.Z - duck.pos.Z)
		local dist = off.Magnitude
		local spot = if dist > DUCK_STOP then duck.pos + off.Unit * (dist - DUCK_STOP) else duck.pos
		spot = Vector3.new(spot.X, duck.home.Y, spot.Z)
		goal = if S.Base.IsInside(guard.record, spot + Vector3.new(0, 1, 0)) then spot else duck.pos
	end
	local off = Vector3.new(goal.X - duck.pos.X, 0, goal.Z - duck.pos.Z)
	local dist = off.Magnitude
	local moved = false
	if dist > 0.05 then
		duck.pos += off.Unit * math.min(dist, stat("DuckAlarm", level, "chaseSpeed") * dt)
		duck.dir = off.Unit
		moved = true
	end
	local look = if target then flat(targetPos - duck.pos) else (if moved then duck.dir else duck.out)
	if look and look:Dot(duck.dir) < 0.999 then
		duck.dir = look
		moved = true
	end
	if moved then
		duck.ap.Position = duck.pos
		duck.ao.CFrame = facing(Vector3.zero, duck.dir)
	end
	if target and flatDistance(targetPos, duck.pos) <= stat("DuckAlarm", level, "honkRange") and math.abs(targetPos.Y - duck.pos.Y) < 8
		and t - duck.lastHonk >= stat("DuckAlarm", level, "honkGap") then
		duck.lastHonk = t
		honk(owner, guard, duck, target, t)
	end
end

local function tickDucks(t: number)
	for owner, guard in pairs(guards) do
		if owner.Parent ~= Players or S.Base.Get(owner) ~= guard.record or #guard.ducks == 0 then
			removeGuard(owner)
		else
			local level = guard.level
			local dt = math.clamp(t - guard.lastStep, 0, 0.5)
			guard.lastStep = t
			local intruders = {}
			for _, p in ipairs(Players:GetPlayers()) do
				if p ~= owner then
					local r = rootOf(p)
					local inside = r ~= nil and alive(p) and S.Base.IsInside(guard.record, r.Position)
					if inside and r then
						table.insert(intruders, p)
						if not guard.inside[p] then
							guard.inside[p] = true
							local gap = stat("DuckAlarm", level, "quackGap")
							if t - guard.lastQuack >= gap then
								guard.lastQuack = t
								local quacker = guard.ducks[1]
								for _, duck in ipairs(guard.ducks) do
									if flatDistance(duck.pos, r.Position) < flatDistance(quacker.pos, r.Position) then
										quacker = duck
									end
								end
								Items.FX("quack", { position = quacker.pos, owner = owner })
							end
							if t - (guard.alerted[p] or -math.huge) >= gap then
								guard.alerted[p] = t
								S.Toast(owner, "🦆 QUACK! " .. p.DisplayName .. " sneaked into your drawer!", "bad")
								Items.FX("intruder", { player = p, seconds = stat("DuckAlarm", level, "highlightSeconds") }, owner)
							end
						end
					else
						guard.inside[p] = nil
					end
				end
			end
			for _, duck in ipairs(guard.ducks) do
				stepDuck(owner, guard, duck, intruders, t, dt)
			end
		end
	end
end

-- ---------- Softener Cloud ----------

-- The cloud's puffs at its centre / radius now, drifting to `finish` and growing to `r1` over the
-- `left` seconds it has (every part tweens on the server; every client sees it).
local function buildCloud(owner: Player, level: number, centre: Vector3, finish: Vector3, radius: number, r0: number, r1: number, left: number): Model
	local model = Instance.new("Model")
	model.Name = "SoftenerCloud_" .. owner.UserId
	local gold = Cfg.IsGold(level)
	local ring = radius * 0.55
	local grown = radius / r0
	for i = 0, 6 do
		local scale = (if i == 0 then 1.5 else 1.1 + math.random() * 0.3) * grown
		local puff, point = Items.Looks.World("SoftenerPuff", true, scale, gold)
		local a = i * math.pi / 3 + math.random() * 0.4
		local at = if i == 0 then centre else centre + Vector3.new(math.cos(a) * ring, 0, math.sin(a) * ring)
		Items.Looks.Place(puff, point, CFrame.new(at + Vector3.new(0, math.random() * 0.6, 0)) * CFrame.Angles(0, math.random() * math.pi * 2, 0))
		for _, d in ipairs(puff:GetDescendants()) do
			if d:IsA("BasePart") and d.Transparency < 0.15 then
				d.Transparency = 0.15 -- soft, a little see-through
			end
		end
		puff.Parent = model
	end
	local grow = r1 / radius
	if left > 0 and ((finish - centre).Magnitude > 0.05 or math.abs(grow - 1) > 1e-3) then
		local info = TweenInfo.new(left, Enum.EasingStyle.Linear)
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") then
				local goal = finish + (d.Position - centre) * grow
				TweenService:Create(d, info, { CFrame = d.CFrame.Rotation + goal, Size = d.Size * grow }):Play()
			end
		end
	end
	model:SetAttribute("OwnerId", owner.UserId)
	tag(model, level)
	model.Parent = newFolder()
	return model
end

local function fadeCloud(cloud: Cloud)
	cloud.fading = true
	local info = TweenInfo.new(CLOUD_FADE, Enum.EasingStyle.Sine, Enum.EasingDirection.In)
	for _, d in ipairs(cloud.model:GetDescendants()) do
		if d:IsA("BasePart") and d.Transparency < 1 then
			TweenService:Create(d, info, { Transparency = 1 }):Play()
		end
	end
end

local function soften(p: Player, pst, t: number, cloud: Cloud)
	if pst.softUntil <= t then
		pst.softMult, pst.softThiefMult = 1, 1 -- a fresh slowdown
	end
	pst.softMult = math.min(pst.softMult, stat("SoftenerCloud", cloud.level, "slowMult"))
	pst.softThiefMult = math.min(pst.softThiefMult, stat("SoftenerCloud", cloud.level, "thiefSlowMult"))
	pst.softUntil = t + SOFT_LINGER
	local character = p.Character
	if character then
		local shown = character:GetAttribute("SoftenedUntil")
		if type(shown) ~= "number" or shown - t < 0.25 then
			character:SetAttribute("SoftenedUntil", t + 0.6)
		end
	end
end

-- A thief inside the cloud for napAfter s nods off: stunned napSeconds, the sock goes home.
local function nap(p: Player, pst, cloud: Cloud, t: number)
	local seconds = stat("SoftenerCloud", cloud.level, "napSeconds")
	local r = rootOf(p)
	shaken(p, "nap")
	dropSock(p, "napped", "Zzz... you nodded off in the cloud and dropped the sock! ☁️")
	Items.Stun(p, seconds)
	pst.napUntil = math.max(pst.napUntil, t + seconds)
	if p.Character then
		p.Character:SetAttribute("Napping", pst.napUntil)
	end
	Items.FX("nap", { player = p, seconds = seconds })
	Items.Moment("nap", if r then r.Position else cloud.centre, cloud.owner, { p }, 0.6)
	if cloud.owner.Parent == Players then
		S.Toast(cloud.owner, "☁️ " .. p.DisplayName .. " nodded off in your cloud!", "good")
	end
end

local function removeCloud(i: number)
	local cloud = clouds[i]
	table.remove(clouds, i)
	cloud.model:Destroy()
end

local function tickClouds(t: number)
	for i = #clouds, 1, -1 do
		local cloud = clouds[i]
		if t >= cloud.untilTime then
			removeCloud(i)
		else
			local k = math.clamp((t - cloud.born) / math.max(1e-3, cloud.untilTime - cloud.born), 0, 1)
			cloud.centre = cloud.start:Lerp(cloud.finish, k)
			cloud.radius = lerp(cloud.r0, cloud.r1, k)
			if not cloud.fading and cloud.untilTime - t <= CLOUD_FADE then
				fadeCloud(cloud)
			end
			local napAfter = stat("SoftenerCloud", cloud.level, "napAfter")
			for p, pst in pairs(Items.All()) do
				local r = rootOf(p)
				local inside = false
				if p ~= cloud.owner and r then
					local off = r.Position - cloud.centre
					inside = Vector3.new(off.X, 0, off.Z).Magnitude <= cloud.radius and off.Y > -2 and off.Y < cloud.radius
				end
				if inside then
					soften(p, pst, t, cloud)
					if carrying(p) and alive(p) then
						local since = cloud.inside[p]
						if not since then
							cloud.inside[p] = t
						elseif t - since >= napAfter - 1e-6 and Items.CanShove(p) then
							cloud.inside[p] = nil
							nap(p, pst, cloud, t)
						end
					else
						cloud.inside[p] = nil
					end
				else
					cloud.inside[p] = nil -- "continuously inside": leaving starts it over
				end
			end
		end
	end
end

-- ---------- Laundry Basket ----------

local function popOut(player: Player, st, why: string)
	local basket = st.basket
	if not basket then
		return
	end
	st.basket = nil
	basket.conn:Disconnect()
	basket.restore()
	basket.model:Destroy()
	local character = player.Character
	if character then
		character:SetAttribute("InBasket", nil)
	end
	if why ~= "shutdown" and why ~= "left" then
		Items.SetActive(player, "LaundryBasket", false)
		Items.SetCooldown(player, "LaundryBasket", now() + Items.Stat(player, "LaundryBasket", "cooldown"))
		Items.RefreshSpeed(player)
		local root = rootOf(player)
		Items.FX("use", { player = player, key = "LaundryBasket", out = true, position = if root then root.Position else nil })
	end
end

-- Popping out yourself: everyone else within pounceRadius jumps back; pounceDrop = 1: thieves drop
-- the sock.
local function pounce(player: Player)
	local root = rootOf(player)
	if not root then
		return
	end
	local level = Items.Level(player, "LaundryBasket")
	local radius = stat("LaundryBasket", level, "pounceRadius")
	local mult = stat("LaundryBasket", level, "pounceMult")
	local drop = stat("LaundryBasket", level, "pounceDrop") >= 1
	local position = root.Position
	Items.FX("pounce", { player = player, position = position, radius = radius })
	local dropped = {}
	for _, p in ipairs(Players:GetPlayers()) do
		local r = rootOf(p)
		if p ~= player and r and alive(p) and (r.Position - position).Magnitude <= radius then
			shaken(p, "pounce")
			if drop and dropSock(p, "pounced", "Pounced! You dropped the sock. 🧺") then
				table.insert(dropped, p)
			end
			Items.Shove(player, p, flat(r.Position - position) or Vector3.new(0, 0, 1), mult)
		end
	end
	if #dropped > 0 then
		Items.Moment("pounce", position, player, dropped, 0.7)
	end
end

-- ---------- Dryer-Sheet Glider ----------

local function stopGlide(player: Player, st, why: string)
	local glide = st.glide
	if not glide then
		return
	end
	st.glide = nil
	st.glideEnded = now()
	glide.model:Destroy()
	glide.restore()
	local character = player.Character
	if character then
		character:SetAttribute("Gliding", nil)
	end
	if why ~= "shutdown" and why ~= "left" then
		Items.SetActive(player, "Glider", false)
		Items.SetCooldown(player, "Glider", now() + Items.Stat(player, "Glider", "cooldown"))
	end
end

-- The slam lands: a shockwave at the feet; slamStun > 0 (golden) also stuns thieves and drops
-- their sock.
local function slamDown(player: Player, st)
	local root = rootOf(player)
	local glide = st.glide
	if not root or not glide then
		return
	end
	local level = glide.level
	local radius = stat("Glider", level, "slamRadius")
	local mult = stat("Glider", level, "slamMult")
	local stun = stat("Glider", level, "slamStun")
	local gold = Cfg.IsGold(level)
	local position = floorNear(player, root.Position, 4)
	Items.FX("slam", { player = player, position = position, radius = radius, gold = gold })
	local hit = {}
	for _, p in ipairs(Players:GetPlayers()) do
		local r = rootOf(p)
		if p ~= player and r and alive(p) and flatDistance(r.Position, position) <= radius and math.abs(r.Position.Y - position.Y) < radius then
			local wasThief = carrying(p)
			local free = Items.CanShove(p)
			shaken(p, "slam")
			local dropped = stun > 0 and wasThief and dropSock(p, "slammed", "SLAM! You dropped the sock.")
			if free then
				Items.Shove(player, p, flat(r.Position - position) or Vector3.new(0, 0, 1), mult)
				if stun > 0 and wasThief then
					Items.Stun(p, stun)
				end
			end
			if free or dropped then
				table.insert(hit, p)
			end
		end
	end
	if gold and #hit > 0 then
		Items.Moment("slam", position, player, hit, 0.8)
	end
end

-- The client says it landed (UseItem held = false): a slam lands now, a glide just ends quietly.
local function landed(player: Player, st)
	local glide = st.glide
	if not glide then
		return
	end
	if glide.slamAt then
		slamDown(player, st)
	end
	stopGlide(player, st, "landed")
end

-- ---------- Static Balloon (charged zap) ----------

local function cancelCharge(player: Player, st)
	if st.charge then
		st.charge = nil
		local character = player.Character
		if character then
			character:SetAttribute("ChargeStart", nil)
		end
	end
end

-- One zapped player: out of the basket, hair on end, a thief drops the sock (zapStun > 0 also
-- stuns them), pushed `push` x a towel shove. Returns true when they were a thief.
local function zapOne(player: Player, p: Player, from: Vector3, dir: Vector3, level: number, push: number, t: number): boolean
	local r = rootOf(p)
	if not r then
		return false
	end
	Items.PopOut(p, "zap")
	if p.Character then
		p.Character:SetAttribute("HairUpUntil", t + stat("StaticBalloon", level, "hairSeconds"))
	end
	local free = Items.CanShove(p)
	local wasThief = Items.SendSockHome(p, "zapped")
	if free then
		local away = flat(r.Position - from) or dir
		Items.Shove(player, p, away, push)
		local stun = stat("StaticBalloon", level, "zapStun")
		if stun > 0 and wasThief then
			Items.Stun(p, stun)
		end
	end
	return wasThief
end

-- ZAP with `charge` 0..1: the radius grows radius -> chargeRadius and the push 1x -> chargeMult;
-- golden: the arc jumps on to `chainJumps` more players just outside. Starts the cooldown.
-- Returns the message for the zapper (nil when nobody was hit).
local function zap(player: Player, st, charge: number, dir: Vector3): string?
	cancelCharge(player, st)
	local t = now()
	local level = Items.Level(player, "StaticBalloon")
	Items.SetCooldown(player, "StaticBalloon", t + stat("StaticBalloon", level, "cooldown"))
	local root = rootOf(player)
	if not root then
		return nil
	end
	charge = math.clamp(charge, 0, 1)
	local radius = lerp(stat("StaticBalloon", level, "radius"), stat("StaticBalloon", level, "chargeRadius"), charge)
	local push = lerp(1, stat("StaticBalloon", level, "chargeMult"), charge)
	local centre = root.Position
	local hit, chain = {}, {}
	local zapped: { [Player]: boolean } = {}
	for _, p in ipairs(Players:GetPlayers()) do
		local r = rootOf(p)
		if p ~= player and r and alive(p) and (r.Position - centre).Magnitude <= radius then
			table.insert(hit, p)
			zapped[p] = true
		end
	end
	for _ = 1, math.floor(stat("StaticBalloon", level, "chainJumps")) do
		local best: Player? = nil
		local bestHop = CHAIN_HOP
		for _, p in ipairs(Players:GetPlayers()) do
			local r = rootOf(p)
			if p ~= player and not zapped[p] and r and alive(p) then
				local hop = (r.Position - centre).Magnitude - radius
				for q in pairs(zapped) do
					local qr = rootOf(q)
					if qr then
						hop = math.min(hop, (r.Position - qr.Position).Magnitude)
					end
				end
				if hop <= bestHop then
					best, bestHop = p, hop
				end
			end
		end
		if not best then
			break
		end
		zapped[best] = true
		table.insert(chain, best)
	end
	Items.FX("zap", { player = player, position = centre, radius = radius, charge = charge, chain = chain })
	local thieves = {}
	for _, list in ipairs({ hit, chain }) do
		for _, p in ipairs(list) do
			if zapOne(player, p, centre, dir, level, push, t) then
				table.insert(thieves, p)
			end
		end
	end
	if charge >= 1 and #thieves > 0 then
		Items.Moment("zap", centre, player, thieves, 0.9)
	end
	local count = #hit + #chain
	if count > 0 then
		return "ZAP! " .. count .. (if count == 1 then " player" else " players") .. " got a shock ⚡"
	end
	return nil
end

-- How full the charge is now (0..1).
local function chargeOf(player: Player, st, t: number): number
	local charge = st.charge
	if not charge then
		return 0
	end
	local seconds = Items.Stat(player, "StaticBalloon", "chargeSeconds")
	return if seconds > 0 then math.clamp((t - charge.start) / seconds, 0, 1) else 1
end

local function tickCharges(t: number)
	for player, st in pairs(Items.All()) do
		local charge = st.charge
		if charge and t - charge.start >= Items.Stat(player, "StaticBalloon", "chargeSeconds") + AUTO_ZAP then
			if st.stunUntil > t or st.encase or not alive(player) then
				cancelCharge(player, st)
			else
				zap(player, st, 1, charge.dir)
			end
		end
	end
end

-- ---------- timers ----------

local function tickGliders(t: number)
	for player, st in pairs(Items.All()) do
		local glide = st.glide
		if glide then
			if glide.slamAt then
				if t - glide.slamAt >= SLAM_WAIT or grounded(player) then
					slamDown(player, st)
					stopGlide(player, st, "slam")
				end
			elseif t >= glide.untilTime then
				stopGlide(player, st, "time")
			elseif t - glide.started > 0.3 and grounded(player) then
				glide.landedAt = glide.landedAt or t
				if t - glide.landedAt >= GLIDE_LAND then
					stopGlide(player, st, "landed")
				end
			else
				glide.landedAt = nil
			end
		end
		local e = st.encase
		if e then
			if e.risingUntil and t >= e.risingUntil then
				e.risingUntil = nil
				e.lift.VectorVelocity = Vector3.zero -- hover at the top
			end
			if t >= e.untilTime then
				endEncase(player, st)
			end
		end
		local basket = st.basket
		if basket and t >= basket.untilTime then
			popOut(player, st, "time")
		end
	end
end

-- ---------- uses ----------

-- (player, st, dir, held, free): `held` is UseItem's flag; `free` = an air dash (no new cooldown)
type Use = (player: Player, st: any, dir: Vector3, held: boolean?, free: boolean) -> (boolean, string?, string?)
local USES: { [string]: Use } = {}

USES.Towel = function(player, _st, dir)
	S.Towel.Snap(player, dir)
	return true
end

USES.SlipperDash = function(player, st, dir, _held, free)
	local level = Items.Level(player, "SlipperDash")
	local t = now()
	if free and st.dashChain then
		st.dashChain.left -= 1
		st.dashChain.untilTime = t + AIR_DASH_WINDOW
	else
		st.dashChain = { left = math.floor(stat("SlipperDash", level, "airDashes")), untilTime = t + AIR_DASH_WINDOW }
	end
	-- while the dash lasts, whoever it runs into is bumped (stepDashes)
	st.dash = { untilTime = t + stat("SlipperDash", level, "seconds") + DASH_SLACK, dir = dir, hit = {}, level = level }
	Items.FX("dash", { player = player })
	return true
end

USES.BananaPeel = function(player, _st, dir)
	local root = rootOf(player)
	if not root then
		return false
	end
	local level = Items.Level(player, "BananaPeel")
	local spot = floorNear(player, root.Position - dir * 2.5, 8)
	local list = peels[player] or {}
	peels[player] = list
	local most = math.max(1, math.floor(stat("BananaPeel", level, "peels")))
	while #list >= most do
		removePeel(player, list[1]) -- the oldest one goes
		list = peels[player] or {}
		peels[player] = list
	end
	local cf = CFrame.new(spot) * CFrame.Angles(0, math.random() * math.pi * 2, 0)
	local model, point = Items.Looks.World("BananaPeel", true, nil, Cfg.IsGold(level))
	Items.Looks.Place(model, point, cf)
	model.Name = "BananaPeel_" .. player.UserId
	model:SetAttribute("OwnerId", player.UserId)
	tag(model, level)
	model.Parent = newFolder()
	table.insert(list, { model = model, pos = spot, cf = cf, untilTime = now() + stat("BananaPeel", level, "lifetime"), level = level })
	Items.SetActive(player, "BananaPeel", true)
	Items.FX("use", { player = player, key = "BananaPeel", position = spot })
	return true
end

USES.BubbleBlaster = function(player, _st, dir)
	local root = rootOf(player)
	if not root then
		return false
	end
	local from = root.Position + dir * 2.5 + Vector3.new(0, 1, 0)
	local tip = tipOf(player, "BubbleBlaster")
	if tip and (tip - root.Position).Magnitude < 8 then
		from = tip
	end
	local level = Items.Level(player, "BubbleBlaster")
	local speed = stat("BubbleBlaster", level, "speed")
	local range = stat("BubbleBlaster", level, "range")
	local bounces = math.floor(stat("BubbleBlaster", level, "bounces"))
	local shots = math.max(1, math.floor(stat("BubbleBlaster", level, "shots")))
	local t = now()
	Items.FX("use", { player = player, key = "BubbleBlaster" })
	for i = 1, shots do
		-- a fan: BUBBLE_FAN between neighbours, centred on the aim
		local d = CFrame.Angles(0, (i - (shots + 1) / 2) * BUBBLE_FAN, 0):VectorToWorldSpace(dir)
		nextBubble += 1
		table.insert(bubbles, {
			id = nextBubble,
			owner = player,
			level = level,
			pos = from,
			dir = d,
			speed = speed,
			left = range,
			reach = stat("BubbleBlaster", level, "radius") + BUBBLE_BODY,
			bounces = bounces,
			homing = stat("BubbleBlaster", level, "homing"),
			sentDir = d,
			sentAt = t,
		})
		Items.FX("bubble", { id = nextBubble, from = from, dir = d, speed = speed, range = range, by = player, bounces = bounces })
	end
	return true
end

USES.DuckAlarm = function(player, _st, dir)
	local record = S.Base.Get(player)
	local root = rootOf(player)
	if not record or not root or not S.Base.IsInside(record, root.Position) then
		return false, "Place it inside your own drawer!"
	end
	local spot = root.Position + dir * 2
	if not S.Base.IsInside(record, spot) then
		spot = root.Position
	end
	spot = floorNear(player, spot, 6)
	local level = Items.Level(player, "DuckAlarm")
	local guard = guards[player]
	if guard and guard.record ~= record then
		removeGuard(player)
		guard = nil
	end
	if not guard then
		guard = {
			record = record,
			level = level,
			ducks = {},
			inside = {},
			lastQuack = -math.huge,
			alerted = {},
			stunAt = {},
			revealAt = {},
			lastStep = now(),
		}
		guards[player] = guard
	end
	local g = guard :: Guard
	g.level = level
	local most = math.max(1, math.floor(stat("DuckAlarm", level, "ducks")))
	while #g.ducks >= most do
		local oldest = table.remove(g.ducks, 1) -- the oldest one goes
		if oldest then
			oldest.model:Destroy()
		end
	end
	local out = flat(record.cf.ZVector) or Vector3.new(0, 0, 1) -- watching the drawer's opening
	local model, duckRoot, ap, ao = buildDuck(player, level, spot, out)
	table.insert(g.ducks, { model = model, root = duckRoot, ap = ap, ao = ao, home = spot, pos = spot, dir = out, out = out, lastHonk = -math.huge })
	Items.SetActive(player, "DuckAlarm", true)
	Items.FX("use", { player = player, key = "DuckAlarm", position = spot })
	return true
end

USES.SoftenerCloud = function(player, _st, dir)
	local root = rootOf(player)
	if not root then
		return false
	end
	local level = Items.Level(player, "SoftenerCloud")
	local centre = floorNear(player, root.Position + dir * stat("SoftenerCloud", level, "distance"), 10)
	local lifetime = stat("SoftenerCloud", level, "lifetime")
	local driftSpeed = stat("SoftenerCloud", level, "driftSpeed")
	-- it drifts the way you aimed (short of walls) and grows from radius to growRadius
	local drift = clearDistance(centre + Vector3.new(0, 1.5, 0), dir, driftSpeed * lifetime, 1)
	local finish = centre + dir * drift
	local r0 = stat("SoftenerCloud", level, "radius")
	local r1 = math.max(r0, stat("SoftenerCloud", level, "growRadius"))
	local t = now()
	table.insert(clouds, {
		owner = player,
		level = level,
		start = centre,
		finish = finish,
		centre = centre,
		r0 = r0,
		r1 = r1,
		radius = r0,
		born = t,
		untilTime = t + lifetime,
		model = buildCloud(player, level, centre, finish, r0, r0, r1, lifetime),
		fading = false,
		inside = {},
	})
	Items.FX("spray", {
		player = player,
		position = centre,
		radius = r0,
		seconds = lifetime,
		dir = dir,
		driftSpeed = driftSpeed,
		to = finish,
		growRadius = r1,
	})
	return true
end

USES.StaticBalloon = function(player, st, dir, held)
	if held == true then
		-- start rubbing it: no cooldown yet; letting go (or AUTO_ZAP after a full charge) zaps
		local t = now()
		st.charge = { start = t, dir = dir }
		if player.Character then
			player.Character:SetAttribute("ChargeStart", t)
		end
		return true
	end
	-- a quick use: zap now (with whatever charge there is)
	return true, nil, zap(player, st, chargeOf(player, st, now()), dir)
end

USES.LaundryBasket = function(player, st, _dir)
	local character = player.Character
	local root = rootOf(player)
	if not character or not root then
		return false
	end
	local hide, restore = hider()
	for _, d in ipairs(character:GetDescendants()) do
		hide(d)
	end
	local carry = S.Steal.Carriers()[player]
	local sockModel = carry and carry.sock.model
	if sockModel then
		for _, d in ipairs(sockModel:GetDescendants()) do
			hide(d)
		end
	end
	local level = Items.Level(player, "LaundryBasket")
	local offset = CFrame.new(0, -feetDepth(player), 0)
	local model, point = Items.Looks.World("LaundryBasket", false, nil, Cfg.IsGold(level))
	Items.Looks.Attach(model, root, offset, point, "BasketJoint")
	model.Name = "Basket_" .. player.UserId
	tag(model, level)
	model.Parent = newFolder()
	st.basket = {
		model = model,
		offset = offset,
		restore = restore,
		untilTime = now() + stat("LaundryBasket", level, "maxSeconds"),
		conn = character.DescendantAdded:Connect(hide), -- a tool equipped meanwhile hides too
	}
	character:SetAttribute("InBasket", true)
	Items.SetActive(player, "LaundryBasket", true)
	Items.RefreshSpeed(player)
	Items.FX("use", { player = player, key = "LaundryBasket" })
	return true
end

USES.Glider = function(player, st, _dir)
	local character = player.Character
	local root = rootOf(player)
	if not character or not root then
		return false
	end
	if not airborne(player) then
		return false, "Jump first, then glide!"
	end
	local level = Items.Level(player, "Glider")
	local model, point = Items.Looks.World("DryerSheet", false, nil, Cfg.IsGold(level))
	Items.Looks.Attach(model, root, CFrame.new(0, CANOPY_Y, 0), point, nil)
	model.Name = "Glider_" .. player.UserId
	tag(model, level)
	model.Parent = newFolder()
	-- the folded sheet in the hand hides while the canopy is up
	local hide, restore = hider()
	local tool = character:FindFirstChild("Item_Glider")
	local visual = tool and tool:FindFirstChild("Visual")
	if visual then
		for _, d in ipairs(visual:GetDescendants()) do
			hide(d)
		end
	end
	local t = now()
	st.glide = {
		model = model,
		hide = hide,
		restore = restore,
		untilTime = t + stat("Glider", level, "maxSeconds"),
		started = t,
		landedAt = nil,
		slamAt = nil, -- a second press: slamming down since
		level = level,
	}
	character:SetAttribute("Gliding", true)
	Items.SetActive(player, "Glider", true)
	Items.FX("use", { player = player, key = "Glider" })
	return true
end

-- ---------- re-skins ----------

-- The owner's item changed level: its world objects that are out take the new level's numbers and
-- turn golden (or back) - rebuilt with the `<model>_Gold` look where needed.
function Rules.Restyle(player: Player, st, key: string, level: number)
	local gold = Cfg.IsGold(level)
	if key == "BananaPeel" then
		for _, peel in ipairs(peels[player] or {}) do
			peel.level = level
			if isGold(peel.model) ~= gold then
				local model, point = Items.Looks.World("BananaPeel", true, nil, gold)
				Items.Looks.Place(model, point, peel.cf)
				model.Name = peel.model.Name
				model:SetAttribute("OwnerId", player.UserId)
				model.Parent = newFolder()
				peel.model:Destroy()
				peel.model = model
			end
			tag(peel.model, level)
		end
	elseif key == "DuckAlarm" then
		local guard = guards[player]
		if guard then
			guard.level = level
			for _, duck in ipairs(guard.ducks) do
				if isGold(duck.model) ~= gold then
					local old = duck.model
					duck.model, duck.root, duck.ap, duck.ao = buildDuck(player, level, duck.pos, duck.dir)
					old:Destroy()
				end
				tag(duck.model, level)
				duck.ap.MaxVelocity = stat("DuckAlarm", level, "chaseSpeed") * 1.3
			end
		end
	elseif key == "SoftenerCloud" then
		local t = now()
		for _, cloud in ipairs(clouds) do
			if cloud.owner == player then
				cloud.level = level
				if isGold(cloud.model) ~= gold then
					local old = cloud.model
					cloud.model = buildCloud(player, level, cloud.centre, cloud.finish, cloud.radius, cloud.r0, cloud.r1, cloud.untilTime - t)
					old:Destroy()
					if cloud.fading then
						fadeCloud(cloud)
					end
				end
				tag(cloud.model, level)
			end
		end
	elseif key == "Glider" then
		local glide = st.glide
		local root = rootOf(player)
		if glide then
			glide.level = level
			if isGold(glide.model) ~= gold and root then
				local model, point = Items.Looks.World("DryerSheet", false, nil, gold)
				Items.Looks.Attach(model, root, CFrame.new(0, CANOPY_Y, 0), point, nil)
				model.Name = glide.model.Name
				model.Parent = newFolder()
				glide.model:Destroy()
				glide.model = model
				-- the re-dressed sheet in the hand hides again
				local tool = player.Character and player.Character:FindFirstChild("Item_Glider")
				local visual = tool and tool:FindFirstChild("Visual")
				if visual then
					for _, d in ipairs(visual:GetDescendants()) do
						glide.hide(d)
					end
				end
			end
			tag(glide.model, level)
		end
	elseif key == "LaundryBasket" then
		local basket = st.basket
		local root = rootOf(player)
		if basket then
			if isGold(basket.model) ~= gold and root then
				local model, point = Items.Looks.World("LaundryBasket", false, nil, gold)
				Items.Looks.Attach(model, root, basket.offset, point, "BasketJoint")
				model.Name = basket.model.Name
				model.Parent = newFolder()
				basket.model:Destroy()
				basket.model = model
			end
			tag(basket.model, level)
			Items.RefreshSpeed(player)
		end
	end
end

-- ---------- API (Items) ----------

function Rules.Init(s, items)
	S = s
	Items = items
	Cfg = S.Config.Item
	local include = {}
	for _, name in ipairs({ "Map", "Bases" }) do
		local f = S.Map.Folders and S.Map.Folders[name]
		if f then
			table.insert(include, f)
		end
	end
	local params = RaycastParams.new()
	if #include > 0 then
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = include
	end
	rayParams = params
end

-- Runs the item's rule (a press). Returns ok, err (shown to the player), msg.
function Rules.Use(player: Player, st, key: string, dir: Vector3, held: boolean?, free: boolean?): (boolean, string?, string?)
	local use = USES[key]
	if not use then
		return false, "Bad request"
	end
	return use(player, st, dir, held, free == true)
end

-- A release (UseItem held = false): the balloon zaps with its charge, the glider has landed.
-- Returns ok, err, msg.
function Rules.Release(player: Player, st, key: string): (boolean, string?, string?)
	if key == "StaticBalloon" then
		local charge = st.charge
		if not charge then
			return true -- nothing charging (already zapped by itself, or the press was refused)
		end
		local t = now()
		if st.stunUntil > t or st.encase or not alive(player) then
			cancelCharge(player, st)
			return false, "You're too dizzy!"
		end
		return true, nil, zap(player, st, chargeOf(player, st, t), charge.dir)
	elseif key == "Glider" then
		landed(player, st)
	end
	return true
end

-- Items whose cooldown starts later than the press: when the glide ends, the basket pops, the
-- balloon zaps.
function Rules.CooldownAtEnd(key: string): boolean
	return key == "Glider" or key == "LaundryBasket" or key == "StaticBalloon"
end

-- After a dash, Dash.airDashes more are allowed while airborne within AIR_DASH_WINDOW s.
function Rules.CanAirDash(player: Player, st, t: number): boolean
	local chain = st.dashChain
	return chain ~= nil and chain.left > 0 and t <= chain.untilTime and airborne(player)
end

function Rules.IsActive(_player: Player, st, key: string): boolean
	if key == "Glider" then
		return st.glide ~= nil
	elseif key == "LaundryBasket" then
		return st.basket ~= nil
	end
	return false
end

-- A press while the item is on: gliding -> SLAM down (`press` false = an old-style second use:
-- the glide just ends); hidden -> pop out with a pounce.
function Rules.Toggle(player: Player, st, key: string, press: boolean)
	if key == "Glider" then
		local glide = st.glide
		if not press then
			stopGlide(player, st, "toggle")
		elseif glide and not glide.slamAt then
			glide.slamAt = now() -- the client drives you down; the shockwave comes on landing
		end
	elseif key == "LaundryBasket" then
		popOut(player, st, "pounce")
		pounce(player)
	end
end

-- Ends a switched-on item (the glide, the basket, a charge); other items have nothing to stop.
-- Every pop-out but your own press (Toggle) is quiet.
function Rules.Stop(player: Player, st, key: string, why: string)
	if key == "Glider" then
		stopGlide(player, st, why)
	elseif key == "LaundryBasket" then
		popOut(player, st, why)
	elseif key == "StaticBalloon" then
		cancelCharge(player, st)
	end
end

-- Every Heartbeat: bubbles fly, dashes bump, slides bowl.
function Rules.Step(dt: number)
	local t = now()
	if #bubbles > 0 then
		stepBubbles(dt, t)
	end
	stepDashes(t)
	if #slides > 0 then
		stepSlides(t)
	end
end

-- Ten times a second: peels, ducks, clouds, glides (and slams), floaters, basket timers, charges.
function Rules.Tick(t: number)
	tickPeels(t)
	tickDucks(t)
	tickClouds(t)
	tickGliders(t)
	tickCharges(t)
end

-- why: "died" | "respawn" (the character's own things end) | "left" | "shutdown" (everything goes)
function Rules.Cleanup(player: Player, st, why: string)
	stopGlide(player, st, why)
	popOut(player, st, why)
	endEncase(player, st)
	cancelCharge(player, st)
	st.dash = nil
	st.dashChain = nil
	st.stunUntil = 0
	st.softUntil = 0
	st.honkUntil = 0
	st.napUntil = 0
	st.combo = 0
	if player.Character then
		player.Character:SetAttribute("Napping", nil)
	end
	for i = #slides, 1, -1 do
		if slides[i].player == player then
			table.remove(slides, i)
		end
	end
	if why == "left" or why == "shutdown" then
		removePeel(player)
		removeGuard(player)
		for i = #clouds, 1, -1 do
			if clouds[i].owner == player then
				removeCloud(i)
			end
		end
		for i = #bubbles, 1, -1 do
			if bubbles[i].owner == player then
				table.remove(bubbles, i)
			end
		end
		for _, guard in pairs(guards) do
			guard.inside[player] = nil
			guard.alerted[player] = nil
			guard.stunAt[player] = nil
			guard.revealAt[player] = nil
		end
		for _, cloud in ipairs(clouds) do
			cloud.inside[player] = nil
		end
		for _, slide in ipairs(slides) do
			slide.chain.members[player] = nil
		end
		for _, other in pairs(Items.All()) do
			if other.dash then
				other.dash.hit[player] = nil
			end
		end
	end
end

-- Counts for tests and the docs' Studio checklist.
function Rules.Counts(): { [string]: number }
	local n = { peels = 0, ducks = 0 }
	for _, list in pairs(peels) do
		n.peels += #list
	end
	for _, guard in pairs(guards) do
		n.ducks += #guard.ducks
	end
	n.clouds = #clouds
	n.bubbles = #bubbles
	n.slides = #slides
	return n
end

-- The live rule state, read-only, for the headless tests.
function Rules.Peek()
	return { peels = peels, guards = guards, clouds = clouds, bubbles = bubbles, slides = slides }
end

return Rules
