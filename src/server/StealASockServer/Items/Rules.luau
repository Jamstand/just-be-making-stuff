-- Items.Rules: what each bar item does on the server, and the world objects it leaves behind
-- (all in workspace.StealASock.Items, all server-made so everyone sees them). Numbers come from
-- ItemConfig; docs/ITEMS.md describes every item.
--   Towel           Towel.Snap: a thief in the cone first, else a shove for the nearest player
--   SlipperDash     the client dashes; the server approves it and tells everyone ("dash")
--   BananaPeel      one peel per player on the floor; the next other player on it slips
--   BubbleBlaster   a bubble the server flies; a thief inside floats up and the sock goes home
--   DuckAlarm       one duck per player, only in your own drawer; quacks at intruders
--   SoftenerCloud   a cloud in front of you: everyone else inside is slow (thieves slowest)
--   StaticBalloon   ZAP: everyone else near you is shoved, hair on end; thieves drop the sock
--   LaundryBasket   hide under it (only the basket shows), shuffle slowly; use again to pop out
--   Glider          only in the air: a dryer-sheet canopy; the client glides, the server times it
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

type Peel = { model: Model, pos: Vector3, untilTime: number }
type Duck = { model: Model, pos: Vector3, record: any, inside: { [Player]: boolean }, lastQuack: number, alerted: { [Player]: number } }
type Cloud = { owner: Player, centre: Vector3, radius: number, untilTime: number, model: Model, fading: boolean }
type Bubble = { id: number, owner: Player, pos: Vector3, dir: Vector3, speed: number, left: number }

local folder: Instance? = nil
local rayParams: RaycastParams? = nil
local peels: { [Player]: Peel } = {}
local ducks: { [Player]: Duck } = {}
local clouds: { Cloud } = {}
local bubbles: { Bubble } = {}
local nextBubble = 0

-- ---------- helpers ----------

local function now(): number
	return workspace:GetServerTimeNow()
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

local function flat(v: Vector3): Vector3?
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 1e-3 then f.Unit else nil
end

-- A frame at `pos` whose +Z (an item model's front) points along the horizontal `dir`.
local function facing(pos: Vector3, dir: Vector3): CFrame
	return CFrame.lookAt(pos, pos - dir)
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

local function floorNear(player: Player, spot: Vector3, extra: number): Vector3
	local depth = feetDepth(player)
	return floorBelow(spot + Vector3.new(0, 2, 0), depth + extra) or (spot - Vector3.new(0, depth, 0))
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

-- ---------- Banana Peel ----------

local function removePeel(owner: Player)
	local peel = peels[owner]
	if peel then
		peels[owner] = nil
		peel.model:Destroy()
		Items.SetActive(owner, "BananaPeel", false)
	end
end

local function slip(victim: Player, owner: Player, peel: Peel)
	local vst = Items.State(victim)
	removePeel(owner)
	Items.FX("slip", { player = victim, position = peel.pos, seconds = Cfg.Banana.slipSeconds })
	Items.PopOut(victim, "slip")
	if vst then
		Rules.Stop(victim, vst, "Glider", "slip")
	end
	Items.SendSockHome(victim, "slipped")
	Items.Stun(victim, Cfg.Banana.slipSeconds)
	S.Toast(victim, "Whoa! You slipped on " .. owner.DisplayName .. "'s banana peel! 🍌", "bad")
	S.Toast(owner, victim.DisplayName .. " slipped on your banana peel! 🍌", "good")
end

local function tickPeels(t: number)
	local B = Cfg.Banana
	for owner, peel in pairs(peels) do
		if t >= peel.untilTime or owner.Parent ~= Players then
			removePeel(owner)
		else
			for _, p in ipairs(Players:GetPlayers()) do
				local r = rootOf(p)
				if p ~= owner and r and peels[owner] == peel and Items.CanShove(p) then
					local off = r.Position - peel.pos
					if Vector3.new(off.X, 0, off.Z).Magnitude <= B.radius and off.Y > -1 and off.Y < 5 then
						slip(p, owner, peel)
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

local function encase(victim: Player)
	local st = Items.State(victim)
	local root = rootOf(victim)
	if not st or not root or st.encase then
		return
	end
	local B = Cfg.Bubble
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
	lift.VectorVelocity = Vector3.new(0, B.floatHeight / FLOAT_RISE, 0)
	lift.Parent = root
	local t = now()
	st.encase = { ball = ball, att = att, lift = lift, risingUntil = t + FLOAT_RISE, untilTime = t + B.floatSeconds }
	st.graceUntil = math.max(st.graceUntil, t + B.floatSeconds + Cfg.ShoveGrace)
	if victim.Character then
		victim.Character:SetAttribute("Encased", true)
	end
	Items.FX("encase", { player = victim, seconds = B.floatSeconds })
	Items.RefreshSpeed(victim)
end

local function bubbleHit(b: Bubble, victim: Player)
	local root = rootOf(victim)
	if not root then
		return
	end
	if S.Steal.IsCarrying(victim) then
		Items.PopOut(victim, "bubble")
		Items.SendSockHome(victim, "bubbled")
		encase(victim)
		if b.owner.Parent == Players then
			S.Toast(b.owner, "Bubbled " .. victim.DisplayName .. "! The sock floats home. 🫧", "good")
		end
	elseif Items.CanShove(victim) then
		local Eco = S.Config.Economy
		local B = Cfg.Bubble
		local away = flat(root.Position - b.pos) or b.dir
		Items.Knock(victim, away, Eco.TowelKnockback * B.bounceMult, Eco.TowelKnockUp * B.bounceMult)
		Items.FX("tumble", { player = victim, dir = away, seconds = 0.4, soft = true })
	end
end

-- Moves every bubble (each Heartbeat). A bubble pops on the first player or wall in its way.
function Rules.Step(dt: number)
	if #bubbles == 0 then
		return
	end
	local reach = Cfg.Bubble.radius + BUBBLE_BODY
	for i = #bubbles, 1, -1 do
		local b = bubbles[i]
		local move = math.min(b.speed * dt, b.left)
		local to = b.pos + b.dir * move
		local victim: Player? = nil
		local nearest = math.huge
		for _, p in ipairs(Players:GetPlayers()) do
			local r = rootOf(p)
			if p ~= b.owner and r and alive(p) then
				local d, u = segmentDistance(b.pos, to, r.Position)
				if d <= reach and u < nearest then
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
				popAt = hit.Position
			end
		end
		b.left -= move
		b.pos = to
		if popAt or b.left <= 1e-3 then
			table.remove(bubbles, i)
			Items.FX("bubblepop", { id = b.id, position = popAt or to })
			if victim then
				bubbleHit(b, victim)
			end
		end
	end
end

-- ---------- Rubber Duck Alarm ----------

local function removeDuck(owner: Player)
	local duck = ducks[owner]
	if duck then
		ducks[owner] = nil
		duck.model:Destroy()
		Items.SetActive(owner, "DuckAlarm", false)
	end
end

local function tickDucks(t: number)
	local D = Cfg.Duck
	for owner, duck in pairs(ducks) do
		if owner.Parent ~= Players or S.Base.Get(owner) ~= duck.record then
			removeDuck(owner)
		else
			for _, p in ipairs(Players:GetPlayers()) do
				if p ~= owner then
					local r = rootOf(p)
					local inside = r ~= nil and alive(p) and S.Base.IsInside(duck.record, r.Position)
					if inside and not duck.inside[p] then
						duck.inside[p] = true
						if t - duck.lastQuack >= D.quackGap then
							duck.lastQuack = t
							Items.FX("quack", { position = duck.pos, owner = owner })
						end
						if t - (duck.alerted[p] or -math.huge) >= D.quackGap then
							duck.alerted[p] = t
							S.Toast(owner, "🦆 QUACK! " .. p.DisplayName .. " sneaked into your drawer!", "bad")
							Items.FX("intruder", { player = p, seconds = D.highlightSeconds }, owner)
						end
					elseif not inside then
						duck.inside[p] = nil
					end
				end
			end
		end
	end
end

-- ---------- Softener Cloud ----------

local function fadeCloud(cloud: Cloud)
	cloud.fading = true
	local info = TweenInfo.new(CLOUD_FADE, Enum.EasingStyle.Sine, Enum.EasingDirection.In)
	for _, d in ipairs(cloud.model:GetDescendants()) do
		if d:IsA("BasePart") and d.Transparency < 1 then
			TweenService:Create(d, info, { Transparency = 1 }):Play()
		end
	end
end

local function soften(p: Player, pst, t: number)
	pst.softUntil = t + SOFT_LINGER
	local character = p.Character
	if character then
		local shown = character:GetAttribute("SoftenedUntil")
		if type(shown) ~= "number" or shown - t < 0.25 then
			character:SetAttribute("SoftenedUntil", t + 0.6)
		end
	end
end

local function tickClouds(t: number)
	for i = #clouds, 1, -1 do
		local cloud = clouds[i]
		if t >= cloud.untilTime then
			table.remove(clouds, i)
			cloud.model:Destroy()
		else
			if not cloud.fading and cloud.untilTime - t <= CLOUD_FADE then
				fadeCloud(cloud)
			end
			for p, pst in pairs(Items.All()) do
				local r = rootOf(p)
				if p ~= cloud.owner and r then
					local off = r.Position - cloud.centre
					if Vector3.new(off.X, 0, off.Z).Magnitude <= cloud.radius and off.Y > -2 and off.Y < cloud.radius then
						soften(p, pst, t)
					end
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
		Items.SetCooldown(player, "LaundryBasket", now() + Cfg.Items.LaundryBasket.cooldown)
		Items.RefreshSpeed(player)
		local root = rootOf(player)
		Items.FX("use", { player = player, key = "LaundryBasket", out = true, position = if root then root.Position else nil })
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
		Items.SetCooldown(player, "Glider", now() + Cfg.Items.Glider.cooldown)
	end
end

local function tickGliders(t: number)
	for player, st in pairs(Items.All()) do
		local glide = st.glide
		if glide then
			if t >= glide.untilTime then
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

type Use = (player: Player, st: any, dir: Vector3) -> (boolean, string?, string?)
local USES: { [string]: Use } = {}

USES.Towel = function(player, _st, dir)
	S.Towel.Snap(player, dir)
	return true
end

USES.SlipperDash = function(player)
	Items.FX("dash", { player = player })
	return true
end

USES.BananaPeel = function(player, _st, dir)
	local root = rootOf(player)
	if not root then
		return false
	end
	local spot = floorNear(player, root.Position - dir * 2.5, 8)
	removePeel(player)
	local model, point = Items.Looks.World("BananaPeel", true)
	Items.Looks.Place(model, point, CFrame.new(spot) * CFrame.Angles(0, math.random() * math.pi * 2, 0))
	model.Name = "BananaPeel_" .. player.UserId
	model:SetAttribute("OwnerId", player.UserId)
	model.Parent = newFolder()
	peels[player] = { model = model, pos = spot, untilTime = now() + Cfg.Banana.lifetime }
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
	local B = Cfg.Bubble
	nextBubble += 1
	table.insert(bubbles, { id = nextBubble, owner = player, pos = from, dir = dir, speed = B.speed, left = B.range })
	Items.FX("use", { player = player, key = "BubbleBlaster" })
	Items.FX("bubble", { id = nextBubble, from = from, dir = dir, speed = B.speed, range = B.range, by = player })
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
	removeDuck(player)
	local model, point = Items.Looks.World("AlarmDuck", true)
	local out = flat(record.cf.ZVector) or Vector3.new(0, 0, 1) -- watching the drawer's opening
	Items.Looks.Place(model, point, facing(spot, out))
	model.Name = "AlarmDuck_" .. player.UserId
	model:SetAttribute("OwnerId", player.UserId)
	model.Parent = newFolder()
	ducks[player] = { model = model, pos = spot, record = record, inside = {}, lastQuack = -math.huge, alerted = {} }
	Items.SetActive(player, "DuckAlarm", true)
	Items.FX("use", { player = player, key = "DuckAlarm", position = spot })
	return true
end

USES.SoftenerCloud = function(player, _st, dir)
	local root = rootOf(player)
	if not root then
		return false
	end
	local O = Cfg.Softener
	local centre = floorNear(player, root.Position + dir * O.distance, 10)
	local model = Instance.new("Model")
	model.Name = "SoftenerCloud_" .. player.UserId
	local ring = O.radius * 0.55
	for i = 0, 6 do
		local scale = if i == 0 then 1.5 else 1.1 + math.random() * 0.3
		local puff, point = Items.Looks.World("SoftenerPuff", true, scale)
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
	model.Parent = newFolder()
	table.insert(clouds, { owner = player, centre = centre, radius = O.radius, untilTime = now() + O.lifetime, model = model, fading = false })
	Items.FX("spray", { player = player, position = centre, radius = O.radius, seconds = O.lifetime })
	return true
end

USES.StaticBalloon = function(player, _st, dir)
	local root = rootOf(player)
	if not root then
		return false
	end
	local L = Cfg.Balloon
	local Eco = S.Config.Economy
	local knock = Eco.TowelKnockback * S.Upgrades.TowelKnockbackMult(player) * Cfg.ShoveMult
	local up = Eco.TowelKnockUp * Cfg.ShoveMult
	local t = now()
	Items.FX("zap", { player = player, position = root.Position, radius = L.radius })
	local zapped = 0
	for _, p in ipairs(Players:GetPlayers()) do
		local r = rootOf(p)
		if p ~= player and r and alive(p) and (r.Position - root.Position).Magnitude <= L.radius then
			zapped += 1
			Items.PopOut(p, "zap")
			if p.Character then
				p.Character:SetAttribute("HairUpUntil", t + L.hairSeconds)
			end
			Items.SendSockHome(p, "zapped")
			if Items.CanShove(p) then
				local away = flat(r.Position - root.Position) or dir
				Items.Knock(p, away, knock, up)
				Items.FX("tumble", { player = p, dir = away, seconds = 0.45, soft = true })
			end
		end
	end
	if zapped > 0 then
		return true, nil, "ZAP! " .. zapped .. (if zapped == 1 then " player" else " players") .. " got a shock ⚡"
	end
	return true
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
	local model, point = Items.Looks.World("LaundryBasket", false)
	Items.Looks.Attach(model, root, CFrame.new(0, -feetDepth(player), 0), point, "BasketJoint")
	model.Name = "Basket_" .. player.UserId
	model.Parent = newFolder()
	st.basket = {
		model = model,
		restore = restore,
		untilTime = now() + Cfg.Basket.maxSeconds,
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
	if grounded(player) then
		return false, "Jump off something first, then glide!"
	end
	local model, point = Items.Looks.World("DryerSheet", false)
	Items.Looks.Attach(model, root, CFrame.new(0, CANOPY_Y, 0), point, nil)
	model.Name = "Glider_" .. player.UserId
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
	st.glide = { model = model, restore = restore, untilTime = t + Cfg.Glider.maxSeconds, started = t, landedAt = nil }
	character:SetAttribute("Gliding", true)
	Items.SetActive(player, "Glider", true)
	Items.FX("use", { player = player, key = "Glider" })
	return true
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

-- Runs the item's rule. Returns ok, err (shown to the player), msg.
function Rules.Use(player: Player, st, key: string, dir: Vector3): (boolean, string?, string?)
	local use = USES[key]
	if not use then
		return false, "Bad request"
	end
	return use(player, st, dir)
end

-- Items that are switched on and off: the second use ends them, and their cooldown starts then.
function Rules.CooldownAtEnd(key: string): boolean
	return key == "Glider" or key == "LaundryBasket"
end

function Rules.IsActive(_player: Player, st, key: string): boolean
	if key == "Glider" then
		return st.glide ~= nil
	elseif key == "LaundryBasket" then
		return st.basket ~= nil
	end
	return false
end

-- Ends a switched-on item (the glide, the basket); other items have nothing to stop.
function Rules.Stop(player: Player, st, key: string, why: string)
	if key == "Glider" then
		stopGlide(player, st, why)
	elseif key == "LaundryBasket" then
		popOut(player, st, why)
	end
end

-- Ten times a second: peels, ducks, clouds, glides, bubbles' floaters, basket timers.
function Rules.Tick(t: number)
	tickPeels(t)
	tickDucks(t)
	tickClouds(t)
	tickGliders(t)
end

-- why: "died" | "respawn" (the character's own things end) | "left" | "shutdown" (everything goes)
function Rules.Cleanup(player: Player, st, why: string)
	stopGlide(player, st, why)
	popOut(player, st, why)
	endEncase(player, st)
	st.stunUntil = 0
	st.softUntil = 0
	if why == "left" or why == "shutdown" then
		removePeel(player)
		removeDuck(player)
		for i = #clouds, 1, -1 do
			if clouds[i].owner == player then
				clouds[i].model:Destroy()
				table.remove(clouds, i)
			end
		end
		for i = #bubbles, 1, -1 do
			if bubbles[i].owner == player then
				table.remove(bubbles, i)
			end
		end
		for _, duck in pairs(ducks) do
			duck.inside[player] = nil
			duck.alerted[player] = nil
		end
	end
end

-- Counts for tests and the docs' Studio checklist.
function Rules.Counts(): { [string]: number }
	local n = { peels = 0, ducks = 0 }
	for _ in pairs(peels) do
		n.peels += 1
	end
	for _ in pairs(ducks) do
		n.ducks += 1
	end
	n.clouds = #clouds
	n.bubbles = #bubbles
	return n
end

return Rules
