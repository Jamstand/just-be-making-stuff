-- ItemClient: the item bar's engine on this client. ItemBar draws the bar and calls this; the
-- server decides everything (Items.luau) and this only asks, predicts and shows.
-- API (the contract with ItemBar; docs/ITEMS.md):
--   ItemClient.Use(key)             a quick press + release (the towel: one tap-snap, which resets its combo)
--   ItemClient.Press(key, source?) / ItemClient.Release(key, source?)
--                                   a button / key / click going down and up (`source` tells holds apart: a
--                                   key, a touch's InputObject, "mouse", "tool" for a click in the world).
--                                   Per item (UseItem's `held` flag, docs/ITEMS.md):
--                                     Towel          keeps snapping while any source is held (an overhead-crack
--                                                    loop, one snap per cooldown, held = true: the combo)
--                                     StaticBalloon  Press starts rubbing it (held = true), Release zaps with the
--                                                    charge (held = false); the server zaps by itself when full
--                                     Glider         Press glides (whenever you're in the air) or, gliding, SLAMS
--                                                    down (held = true); landing sends held = false
--                                     SlipperDash    Press dashes; after a dash, Dash.airDashes more in the air
--                                     LaundryBasket  Press hides; hidden, Press pops out with a pounce
--                                     the rest       Press uses it once
--                                   A press that does nothing (cooling down, busy) stays silent.
--   ItemClient.Hold(key?)           hold that item's tool (nil = put it away); a click / tap in the world then uses it
--   ItemClient.Held(): string?
--   ItemClient.CooldownUntil(key): number   workspace:GetServerTimeNow() it's ready again (0 = ready)
--   ItemClient.CooldownLength(key): number  seconds of that cooldown at the item's level (for the ring)
--   ItemClient.IsActive(key): boolean       Glider gliding, Basket hiding, a Duck or Peel out, the Balloon charging
--   ItemClient.Charge(key): number          0..1 while the Static Balloon charges, else 0 (the bar's charge ring)
--   ItemClient.Level(key): number           the item's upgrade level (player attribute Lv_<key>), 0 = none
--   ItemClient.Changed: RBXScriptSignal     (key) cooldown / active / held / charge / level changed
--   ItemClient.Failed: RBXScriptSignal      (key, err) the server or a local check said no (the server toasts why)
--   ItemClient.SetState(state)              the StateView (init.client passes it: the towel's reach)
-- Requiring it starts it (and ItemFX, the effects). It also moves the player for their own
-- movement items, as Roblox characters are moved by their own client: the Slipper Dash (a short
-- LinearVelocity burst along the floor) and the Dryer-Sheet Glider (fall slowly, fly forward, steer
-- with the move keys / thumbstick, the slam drives you down; landing ends it and tells the server).
-- Towel aiming (ItemAim): on touch screens and gamepads a snap turns to the nearest target in reach
-- (a thief first); while you hold the towel, a faint arc on the floor shows its cone and reach.
-- Cooldowns: the server's own time per item arrives as the player attribute CD_<key>; a use is
-- predicted at once and corrected by the server's answer.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local ItemConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("ItemConfig"))
local ItemFX = require(script.Parent:WaitForChild("ItemFX"))

-- the aiming help is optional: without it the towel simply aims where you face (it sits next to
-- this module, so it's there when this runs: no waiting)
local ItemAim: any = nil
do
	local module = script.Parent:FindFirstChild("ItemAim")
	if module then
		local ok, loaded = pcall(require, module)
		if ok and type(loaded) == "table" then
			ItemAim = loaded
		else
			warn("[ItemClient] ItemAim failed to load: " .. tostring(loaded))
		end
	end
end

local ItemClient = {}

local changedEvent = Instance.new("BindableEvent")
local failedEvent = Instance.new("BindableEvent")
ItemClient.Changed = changedEvent.Event
ItemClient.Failed = failedEvent.Event

local TOGGLES: { [string]: boolean } = { LaundryBasket = true } -- a press while it's on ends it (with a pounce)
local FACE_AIM: { [string]: boolean } = { Towel = true, BubbleBlaster = true, SoftenerCloud = true } -- a click turns you to it
local AIR_DASH_WINDOW = 1.2 -- seconds after a dash in which the air dashes are allowed (the server's too)
local CRACK_FINISHER = 0.32 -- seconds into the finisher swing when the towel cracks (the arc pulses)
local SLAM_MAX = 1.5 -- seconds a slam drives you down at most
local BALLOON = "StaticBalloon"

local me = Players.LocalPlayer
local predicted: { [string]: number } = {} -- key -> ready time we expect (server clock) until the server answers
local predictedActive: { [string]: boolean? } = {}
local busy: { [string]: boolean } = {}
local queued: { [string]: () -> () } = {} -- key -> what to send once the answer in flight is back
local held: string? = nil
local towelSources: { [any]: boolean } = {} -- whatever is holding the towel button down right now
local towelLoop = 0 -- bumped to stop the current loop
local towelFromClick = false -- a held click in the world aims each snap at the mouse
local towelAssist = false -- a touch / gamepad holds the towel: each snap turns to the nearest target
local towelFresh = false -- this press hasn't snapped yet: its first snap goes as a tap (held = false)
local towelToldDizzy = false -- this press already said "too dizzy" (once per press)
local hooked: { [Instance]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local combo = { count = 0, last = -math.huge } -- the towel combo as predicted here (the server's count corrects it)

local function now(): number
	return workspace:GetServerTimeNow()
end

local function changed(key: string?)
	if key then
		changedEvent:Fire(key)
	end
end

local function fail(key: string, result: any)
	local err = if type(result) == "table" and type(result.err) == "string" then result.err else "Couldn't reach the server - try again"
	failedEvent:Fire(key, err)
end

local function remote(): RemoteFunction?
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local fn = remotes and remotes:FindFirstChild("UseItem")
	return if fn and fn:IsA("RemoteFunction") then fn else nil
end

local function body(): (Model?, Humanoid?, BasePart?)
	local character = me and me.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if character and humanoid and root and root:IsA("BasePart") and humanoid.Health > 0 then
		return character, humanoid, root
	end
	return nil, nil, nil
end

local function flat(v: Vector3): Vector3?
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 1e-3 then f.Unit else nil
end

local function airborne(humanoid: Humanoid): boolean
	return humanoid.FloorMaterial == Enum.Material.Air
end

-- Am I carrying a sock? (the dash is shorter then)
local function carrying(): boolean
	local root = workspace:FindFirstChild("StealASock")
	local carried = root and root:FindFirstChild("Carried")
	if not carried then
		return false
	end
	for _, model in ipairs(carried:GetChildren()) do
		if model:GetAttribute("CarrierId") == me.UserId then
			return true
		end
	end
	return false
end

-- ---------- reading ----------

function ItemClient.Level(key: string): number
	if type(key) ~= "string" or not me then
		return 0
	end
	local level = me:GetAttribute("Lv_" .. key)
	return if type(level) == "number" and level == level then math.clamp(math.floor(level), 0, ItemConfig.MaxLevel) else 0
end

-- one of the item's numbers at your level (ItemConfig.Stat)
local function stat(key: string, name: string): number
	return ItemConfig.Stat(key, ItemClient.Level(key), name)
end

function ItemClient.CooldownUntil(key: string): number
	if type(key) ~= "string" then
		return 0
	end
	local server = me:GetAttribute("CD_" .. key)
	local t = math.max(if type(server) == "number" then server else 0, predicted[key] or 0)
	return if t > now() then t else 0
end

function ItemClient.CooldownLength(key: string): number
	local item = type(key) == "string" and ItemConfig.Items[key]
	return if item then stat(key, "cooldown") else 0
end

-- the Static Balloon being rubbed (nil = not)
type Charging = { start: number, answered: boolean, releaseQueued: boolean, fromClick: boolean, source: any }
local charging: Charging? = nil

function ItemClient.IsActive(key: string): boolean
	if type(key) ~= "string" then
		return false
	end
	if key == "StaticBalloon" and charging then
		return true
	end
	local guess = predictedActive[key]
	if guess ~= nil then
		return guess
	end
	return me:GetAttribute("Active_" .. key) == true
end

function ItemClient.Charge(key: string): number
	local c = charging
	if key ~= "StaticBalloon" or not c then
		return 0
	end
	local start = c.start
	local character = me and me.Character
	local server = character and character:GetAttribute("ChargeStart")
	if type(server) == "number" then
		start = server -- the server's own start: the bar shows the charge it will use
	end
	return math.clamp((now() - start) / math.max(stat(key, "chargeSeconds"), 0.1), 0, 1)
end

function ItemClient.Held(): string?
	return held
end

-- fires Changed once the cooldown is over (the bar pops the slot)
local function whenReady(key: string)
	local t = ItemClient.CooldownUntil(key)
	if t > 0 then
		task.delay(t - now() + 0.05, changed, key)
	end
end

-- ---------- the Slipper Dash (your own character) ----------

local dash: { att: Attachment, lv: LinearVelocity, token: number }? = nil
local dashToken = 0
local airDash: { at: number, left: number }? = nil -- the dashes still allowed in the air

local function stopDash()
	local d = dash
	if d then
		dash = nil
		d.lv:Destroy()
		d.att:Destroy()
	end
end

local function canAirDash(humanoid: Humanoid): boolean
	local a = airDash
	return a ~= nil and a.left > 0 and os.clock() - a.at <= AIR_DASH_WINDOW and airborne(humanoid)
end

local function startDash(humanoid: Humanoid, root: BasePart, inAir: boolean)
	stopDash()
	if inAir and airDash then
		airDash.left -= 1
		airDash.at = os.clock()
	else
		airDash = { at = os.clock(), left = math.floor(stat("SlipperDash", "airDashes")) }
	end
	local seconds = math.max(stat("SlipperDash", "seconds"), 0.05)
	local dir = flat(humanoid.MoveDirection) or flat(root.CFrame.LookVector) or Vector3.new(0, 0, -1)
	local speed = stat("SlipperDash", "distance") / seconds * (if carrying() then stat("SlipperDash", "carryMult") else 1)
	local att = Instance.new("Attachment")
	att.Name = "ItemDash"
	att.Parent = root
	local lv = Instance.new("LinearVelocity")
	lv.Name = "ItemDash"
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane -- along the floor; gravity still works
	lv.PrimaryTangentAxis = Vector3.new(1, 0, 0)
	lv.SecondaryTangentAxis = Vector3.new(0, 0, 1)
	lv.PlaneVelocity = Vector2.new(dir.X * speed, dir.Z * speed)
	lv.MaxForce = 1e6
	lv.Parent = root
	dashToken += 1
	local token = dashToken
	dash = { att = att, lv = lv, token = token }
	task.delay(seconds, function()
		if dash and dash.token == token then
			stopDash()
		end
	end)
end

-- ---------- the Dryer-Sheet Glider (your own character) ----------

type Glide = { att: Attachment, lv: LinearVelocity, dir: Vector3, started: number, conn: RBXScriptConnection, slam: number? }
local glide: Glide? = nil
local tellLanding: () -> () = function() end

local function stopGlide(tell: boolean)
	local g = glide
	if not g then
		return
	end
	glide = nil
	g.conn:Disconnect()
	g.lv:Destroy()
	g.att:Destroy()
	if tell then
		tellLanding()
	end
end

local function startGlide(humanoid: Humanoid, root: BasePart): boolean
	if not airborne(humanoid) then
		return false -- on the ground: the server says why
	end
	stopGlide(false)
	local fall = stat("Glider", "fallSpeed")
	local forward = stat("Glider", "forwardSpeed")
	local maxSeconds = stat("Glider", "maxSeconds")
	local slamSpeed = stat("Glider", "slamSpeed")
	local att = Instance.new("Attachment")
	att.Name = "ItemGlide"
	att.Parent = root
	local lv = Instance.new("LinearVelocity")
	lv.Name = "ItemGlide"
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.MaxForce = 1e6
	local dir = flat(humanoid.MoveDirection) or flat(root.CFrame.LookVector) or Vector3.new(0, 0, -1)
	lv.VectorVelocity = dir * forward + Vector3.new(0, -fall, 0)
	lv.Parent = root
	local started = os.clock()
	local g: Glide = { att = att, lv = lv, dir = dir, started = started, conn = nil :: any, slam = nil }
	g.conn = RunService.Heartbeat:Connect(function(dt)
		if glide ~= g then
			return
		end
		local age = os.clock() - started
		local slamAt = g.slam
		if slamAt then
			-- the slam: straight down, fast (a little drift forward)
			lv.VectorVelocity = g.dir * (forward * 0.15) + Vector3.new(0, -slamSpeed, 0)
			if humanoid.Health <= 0 or root.Parent == nil or os.clock() - slamAt > SLAM_MAX then
				stopGlide(false)
			elseif os.clock() - slamAt > 0.05 and not airborne(humanoid) then
				stopGlide(true) -- down: the server makes the shockwave now
			end
			return
		end
		-- steer toward the stick / move keys, always flying forward and sinking slowly
		local want = flat(humanoid.MoveDirection)
		if want then
			g.dir = flat(g.dir:Lerp(want, math.min(1, dt * 4))) or want
		end
		lv.VectorVelocity = g.dir * forward + Vector3.new(0, -fall, 0)
		if humanoid.Health <= 0 or root.Parent == nil or age > maxSeconds + 0.5 then
			stopGlide(false)
		elseif age > 0.25 and not airborne(humanoid) then
			stopGlide(true) -- landed: end it and tell the server
		end
	end)
	glide = g
	return true
end

-- ---------- aiming ----------

-- what kind of input a press came from: "touch", "gamepad", "mouse", "keyboard" or nil
local function classify(inputType: any): string?
	if inputType == nil then
		return nil
	end
	if inputType == Enum.UserInputType.Touch then
		return "touch"
	end
	local s = tostring(inputType)
	if string.find(s, "Gamepad", 1, true) then
		return "gamepad"
	elseif string.find(s, "Mouse", 1, true) then
		return "mouse"
	elseif inputType == Enum.UserInputType.Keyboard then
		return "keyboard"
	end
	return nil
end

local function inputKind(source: any): string?
	if typeof(source) == "Instance" and source:IsA("InputObject") then
		return classify(source.UserInputType)
	elseif type(source) == "table" and source.UserInputType ~= nil then
		return classify(source.UserInputType)
	elseif source == "mouse" then
		return "mouse"
	elseif source ~= nil and (typeof(source) == "EnumItem" or type(source) == "string") then
		local s = tostring(source)
		if string.find(s, "KeyCode.Button", 1, true) or string.find(s, "KeyCode.DPad", 1, true) or string.find(s, "KeyCode.Thumbstick", 1, true) then
			return "gamepad"
		elseif string.find(s, "KeyCode.", 1, true) then
			return "keyboard"
		end
	end
	-- a click / tap in the world ("tool"), the API: whatever was used last
	local ok, last = pcall(function()
		return UserInputService:GetLastInputType()
	end)
	return if ok then classify(last) else nil
end

-- Aim assist only on touch screens and gamepads.
local function assistFor(source: any): boolean
	local kind = inputKind(source)
	if kind == nil then
		return UserInputService.TouchEnabled and not UserInputService.MouseEnabled
	end
	return kind == "touch" or kind == "gamepad"
end

-- Where a use aims: the click in the world, else where you face; the towel with assist turns to
-- the nearest target in reach (ItemAim). Returns the aim and whether it turned to a target.
local function aimFor(root: BasePart, fromClick: boolean, key: string?, assist: boolean?): (Vector3?, boolean)
	local base: Vector3? = nil
	if fromClick then
		local ok, hit = pcall(function()
			return me:GetMouse().Hit.Position
		end)
		if ok and typeof(hit) == "Vector3" then
			local d = Vector3.new(hit.X - root.Position.X, 0, hit.Z - root.Position.Z)
			if d.Magnitude > 1 then
				base = d.Unit
			end
		end
	end
	base = base or flat(root.CFrame.LookVector)
	if key == "Towel" and assist and base and ItemAim then
		local target, dir = ItemAim.Pick(root, base)
		if target and dir then
			return dir, true
		end
	end
	return base, false
end

-- ---------- asking the server ----------

-- UseItem(key, aim, held): `held` goes as it is (true / false / nil, docs/ITEMS.md). Whatever was
-- queued for this key while the answer was out goes next.
local function ask(key: string, aim: Vector3?, heldFlag: boolean?, onAnswer: (boolean, any) -> ())
	local fn = remote()
	if not fn then
		onAnswer(false, nil)
		return
	end
	busy[key] = true
	task.spawn(function()
		local ok, result = pcall(function()
			return fn:InvokeServer(key, aim, heldFlag)
		end)
		busy[key] = nil
		onAnswer(ok and type(result) == "table" and result.ok == true, if ok then result else nil)
		local after = queued[key]
		if after then
			queued[key] = nil
			after()
		end
	end)
end

local function serverUntil(result: any): number
	return if type(result) == "table" and type(result.cooldownUntil) == "number" then result.cooldownUntil else 0
end

-- The towel combo as the server counts it: held uses within TowelCombo.window s of the last one
-- count up, every count-th is a finisher; a tap (every press's first snap) starts a new count at 1.
-- Returns: is this use the finisher?
local function countCombo(heldDown: boolean): boolean
	local C = ItemConfig.TowelCombo
	local t = os.clock()
	if heldDown and combo.count > 0 and t - combo.last <= C.window then
		combo.count += 1
	else
		combo.count = 1
	end
	combo.last = t
	return combo.count > 0 and combo.count % C.count == 0
end

-- would your next held crack be the finisher? (the reach arc opens wider)
local function finisherNext(): boolean
	local C = ItemConfig.TowelCombo
	return next(towelSources) ~= nil and combo.count > 0 and os.clock() - combo.last <= C.window and combo.count % C.count == C.count - 1
end

-- stunned or floating in a bubble: the server refuses every use until it ends
local function dizzy(): boolean
	local character = me and me.Character
	if not character then
		return false
	end
	local stun = character:GetAttribute("StunUntil")
	return (type(stun) == "number" and stun > now()) or character:GetAttribute("Encased") == true
end

-- One use: local prediction + UseItem. Returns whether it asked. Silent when it does nothing.
local function use(key: any, fromClick: boolean, heldFlag: boolean?, assist: boolean?): boolean
	if type(key) ~= "string" or not ItemConfig.Items[key] or busy[key] then
		return false
	end
	local _, humanoid, root = body()
	if not humanoid or not root then
		return false
	end
	local active = ItemClient.IsActive(key)
	local switchingOff = TOGGLES[key] == true and active
	local inAir = false
	if not switchingOff and ItemClient.CooldownUntil(key) > 0 then
		if key == "SlipperDash" and canAirDash(humanoid) then
			inAir = true -- an air dash: the cooldown that's running stays
		else
			return false -- nothing while cooling down (the ring says so)
		end
	end
	ItemClient.Hold(key)
	local aim, turned = aimFor(root, fromClick, key, assist)
	if aim and ((fromClick and FACE_AIM[key]) or turned) then
		root.CFrame = CFrame.lookAt(root.Position, root.Position + aim)
	end
	-- predict: show it now, the server's answer corrects it
	local cooldownAtEnd = key == "Glider" or key == "LaundryBasket"
	local undoCombo: { count: number, last: number }? = nil -- the towel combo before this use
	if TOGGLES[key] then
		predictedActive[key] = not active
		if active then
			ItemFX.Predict("LaundryBasketPounce")
		end
	elseif key == "Glider" then
		predictedActive.Glider = true
		startGlide(humanoid, root)
	else
		local info: { [string]: any }? = nil
		if key == "Towel" then
			undoCombo = { count = combo.count, last = combo.last }
			local finisher = countCombo(heldFlag == true)
			info = { finisher = finisher }
			if finisher and ItemAim then
				task.delay(CRACK_FINISHER, ItemAim.Pulse)
			end
		end
		if not inAir then
			predicted[key] = now() + ItemClient.CooldownLength(key)
		end
		ItemFX.Predict(key, info)
		if key == "SlipperDash" then
			startDash(humanoid, root, inAir)
		end
	end
	changed(key)
	local countedAt = combo.last
	ask(key, aim, heldFlag, function(ok, result)
		predictedActive[key] = nil
		local untilTime = serverUntil(result)
		if ok then
			if not inAir and not cooldownAtEnd then
				predicted[key] = if untilTime > 0 then untilTime else predicted[key]
			end
		else
			if not inAir then
				predicted[key] = nil
			end
			-- the server didn't count a refused snap: neither do we (unless another snap counted since)
			if undoCombo and combo.last == countedAt then
				combo.count, combo.last = undoCombo.count, undoCombo.last
			end
			if key == "Glider" and not active then
				stopGlide(false)
			end
			fail(key, result)
		end
		changed(key)
		whenReady(key)
	end)
	return true
end

-- ---------- the Static Balloon: rub it while held, zap on release ----------

local function endCharge()
	if charging then
		charging = nil
		ItemFX.SetCharging(nil)
		changed("StaticBalloon")
	end
end

local function zapNow()
	local c = charging
	if not c then
		return
	end
	local charge = ItemClient.Charge("StaticBalloon")
	charging = nil
	ItemFX.SetCharging(nil)
	predicted[BALLOON] = now() + ItemClient.CooldownLength("StaticBalloon")
	ItemFX.Predict("StaticBalloon", { charge = charge })
	changed("StaticBalloon")
	local _, _, root = body()
	local aim = if root then aimFor(root, c.fromClick, "StaticBalloon", false) else nil
	ask("StaticBalloon", aim, false, function(ok, result)
		local untilTime = serverUntil(result)
		if ok then
			predicted[BALLOON] = if untilTime > 0 then untilTime else predicted[BALLOON]
		else
			predicted[BALLOON] = nil
			fail("StaticBalloon", result)
		end
		changed("StaticBalloon")
		whenReady("StaticBalloon")
	end)
end

local function startCharge(fromClick: boolean, source: any)
	if charging or busy.StaticBalloon or ItemClient.CooldownUntil("StaticBalloon") > 0 then
		return -- already rubbing it / cooling down: nothing (silently)
	end
	local _, humanoid, root = body()
	if not humanoid or not root then
		return
	end
	ItemClient.Hold("StaticBalloon")
	local aim = aimFor(root, fromClick, "StaticBalloon", false)
	local c: Charging = { start = now(), answered = false, releaseQueued = false, fromClick = fromClick, source = source }
	charging = c
	ItemFX.SetCharging(0)
	changed("StaticBalloon")
	ask("StaticBalloon", aim, true, function(ok, result)
		if charging ~= c then
			return
		end
		if not ok then
			endCharge()
			fail("StaticBalloon", result)
			return
		end
		c.answered = true
		if c.releaseQueued then
			zapNow()
		end
	end)
	-- the server zaps by itself chargeSeconds + 2 s after the start: stop rubbing by then
	task.delay(stat("StaticBalloon", "chargeSeconds") + 2.3, function()
		if charging == c then
			endCharge()
		end
	end)
end

local function releaseCharge()
	local c = charging
	if not c then
		return
	end
	if not c.answered then
		c.releaseQueued = true -- the press is still on its way: zap right after it
		return
	end
	zapNow()
end

-- ---------- the glide slam ----------

local function slam(source: any)
	local g = glide
	local character = me and me.Character
	if g and g.slam then
		return -- already on the way down
	end
	if busy.Glider then
		return
	end
	local _, _, root = body()
	local aim = if root then aimFor(root, source == "tool", "Glider", false) else nil
	if g then
		g.slam = os.clock()
	elseif not (character and character:GetAttribute("Gliding") == true) then
		return
	end
	ItemFX.Predict("GliderSlam")
	changed("Glider")
	ask("Glider", aim, true, function(ok, result)
		if not ok then
			stopGlide(false)
			fail("Glider", result)
		end
		changed("Glider")
		whenReady("Glider")
	end)
end

-- ---------- holding the towel down: an overhead-crack loop ----------

local function towelHeld(): boolean
	return next(towelSources) ~= nil
end

local function stopTowelLoop()
	towelLoop += 1
	table.clear(towelSources)
	towelFromClick = false
	towelAssist = false
	ItemFX.SetHold(false)
end

-- snaps whenever the towel is ready, until every source lets go (the first snap is at once), then
-- checks again when the cooldown ends
local function towelTick(token: number)
	if token ~= towelLoop or not towelHeld() then
		return
	end
	local _, humanoid = body()
	if not humanoid then
		stopTowelLoop()
		return
	end
	if dizzy() then
		-- stunned / in a bubble: no swing (the server would refuse it); held, it cracks the moment
		-- you can again. A fresh press says why once.
		if towelFresh and not towelToldDizzy then
			towelToldDizzy = true
			fail("Towel", { err = "You're too dizzy!" })
		end
		task.delay(0.1, towelTick, token)
		return
	end
	if ItemClient.CooldownUntil("Towel") == 0 and not busy.Towel then
		-- a press's first snap is a tap (held = false: a new combo, others see it settle); the rest
		-- of the hold are held snaps (others see the loop, the combo counts up)
		if use("Towel", towelFromClick, not towelFresh, towelAssist) then
			towelFresh = false
		end
	end
	task.delay(math.clamp(ItemClient.CooldownUntil("Towel") - now(), 0.03, 2), towelTick, token)
end

function ItemClient.Press(key: string, source: any?)
	if type(key) ~= "string" or not ItemConfig.Items[key] then
		return
	end
	local fromClick = source == "tool"
	if key == "StaticBalloon" then
		startCharge(fromClick, source)
		return
	elseif key == "Glider" then
		local character = me and me.Character
		if glide or (character and character:GetAttribute("Gliding") == true) then
			slam(source)
		else
			use("Glider", fromClick, true)
		end
		return
	elseif key == "LaundryBasket" then
		use(key, fromClick, true)
		return
	elseif key ~= "Towel" then
		use(key, fromClick, nil)
		return
	end
	local src = if source ~= nil then source else "api"
	if towelSources[src] then
		return
	end
	local first = not towelHeld()
	towelSources[src] = true
	if src == "tool" then
		towelFromClick = true
	end
	if assistFor(source) then
		towelAssist = true
	end
	if first then
		towelLoop += 1
		towelFresh = true
		towelToldDizzy = false
		ItemFX.SetHold(true)
		towelTick(towelLoop)
	end
end

function ItemClient.Release(key: string, source: any?)
	if key == "StaticBalloon" then
		releaseCharge()
		return
	end
	if key ~= "Towel" then
		return
	end
	local src = if source ~= nil then source else "api"
	towelSources[src] = nil
	if src == "tool" then
		towelFromClick = false
	end
	if not towelHeld() then
		towelLoop += 1 -- the loop ends; the arm settles after the swing that's playing
		towelAssist = false
		ItemFX.SetHold(false)
	end
end

-- A quick press + release. The towel: one tap-snap (it resets the combo; aim assist on touch /
-- gamepad as for a press).
function ItemClient.Use(key: string)
	if key == "Towel" then
		use("Towel", false, nil, assistFor(nil))
		return
	end
	ItemClient.Press(key, "use")
	ItemClient.Release(key, "use")
end

function ItemClient.Hold(key: string?)
	local character, humanoid = body()
	if not character or not humanoid then
		return
	end
	if key == nil then
		humanoid:UnequipTools()
		return
	end
	if type(key) ~= "string" then
		return
	end
	local name = "Item_" .. key
	if character:FindFirstChild(name) then
		return -- already in hand
	end
	local backpack = me:FindFirstChildOfClass("Backpack")
	local tool = backpack and backpack:FindFirstChild(name)
	if tool and tool:IsA("Tool") then
		humanoid:EquipTool(tool)
	end
end

function ItemClient.SetState(state: any)
	if ItemAim and type(state) == "table" then
		ItemAim.SetState(state)
	end
end

-- landing on your own: end the glide on the server too (UseItem held = false; a slam lands now -
-- the server also notices by itself)
tellLanding = function()
	if busy.Glider then
		queued.Glider = tellLanding -- after the answer in flight (a slam press)
		return
	end
	predictedActive.Glider = false
	changed("Glider")
	ask("Glider", nil, false, function()
		predictedActive.Glider = nil
		changed("Glider")
		whenReady("Glider")
	end)
end

-- the server tells us its combo count with each of your swings: keep the prediction in step
ItemFX.OnMyCombo = function(count: number, _finisher: boolean)
	if os.clock() - combo.last < 0.9 then
		combo.count = count
	end
end

-- ---------- tools, the held item, attributes ----------

local function hookTool(tool: Instance)
	if not tool:IsA("Tool") or hooked[tool] then
		return
	end
	local key = tool:GetAttribute("ItemKey")
	if type(key) ~= "string" then
		return
	end
	hooked[tool] = true
	-- a click / tap in the world with the item in hand presses it, aimed at where you clicked (the
	-- towel keeps snapping while the click is held, the balloon charges until it's let go)
	tool.Activated:Connect(function()
		ItemClient.Press(key, "tool")
	end)
	tool.Deactivated:Connect(function()
		ItemClient.Release(key, "tool")
	end)
end

local function updateHeld()
	local character = me.Character
	local key: string? = nil
	if character then
		for _, child in ipairs(character:GetChildren()) do
			local k = child:GetAttribute("ItemKey")
			if child:IsA("Tool") and type(k) == "string" then
				key = k
			end
		end
	end
	if key ~= held then
		local old = held
		held = key
		if old == "Towel" and towelSources.tool then
			ItemClient.Release("Towel", "tool") -- put away mid-click: no Deactivated comes
		end
		if old == "StaticBalloon" and charging then
			releaseCharge() -- put away while rubbing it: it zaps
		end
		changed(old)
		changed(key)
	end
end

local function watchContainer(container: Instance)
	for _, child in ipairs(container:GetChildren()) do
		hookTool(child)
	end
	container.ChildAdded:Connect(function(child)
		hookTool(child)
		if container == me.Character then
			updateHeld()
		end
	end)
	container.ChildRemoved:Connect(function()
		if container == me.Character then
			updateHeld()
		end
	end)
end

local function onCharacter(character: Model)
	stopDash()
	stopGlide(false)
	stopTowelLoop()
	endCharge()
	airDash = nil
	watchContainer(character)
	updateHeld()
	character:GetAttributeChangedSignal("Gliding"):Connect(function()
		if character:GetAttribute("Gliding") ~= true then
			stopGlide(false) -- the server ended it (time, a knock, a slip, the slam landed)
		end
		changed("Glider")
	end)
	character:GetAttributeChangedSignal("InBasket"):Connect(function()
		changed("LaundryBasket")
	end)
	character:GetAttributeChangedSignal("ChargeStart"):Connect(function()
		local c = charging
		if character:GetAttribute("ChargeStart") == nil and c and c.answered and not c.releaseQueued then
			endCharge() -- the server zapped by itself (full charge) or stopped it (a stun)
		end
		changed("StaticBalloon")
	end)
end

-- every frame: the reach arc and the balloon's charge
local function frame(dt: number)
	local character = me and me.Character
	if charging then
		ItemFX.SetCharging(ItemClient.Charge("StaticBalloon"))
	end
	if ItemAim then
		local _, humanoid = body()
		local show = held == "Towel" and humanoid ~= nil and not (character and character:GetAttribute("InBasket") == true)
		ItemAim.SetFinisherNext(finisherNext())
		ItemAim.Update(dt, show)
	end
end

local started = false

function ItemClient.Init()
	if started then
		return
	end
	started = true
	ItemFX.Start()
	if not me then
		return
	end
	me.AttributeChanged:Connect(function(name)
		local key = string.match(name, "^CD_(.+)$") or string.match(name, "^Active_(.+)$")
		if key then
			changed(key)
			whenReady(key)
			return
		end
		local leveled = string.match(name, "^Lv_(.+)$")
		if leveled then
			changed(leveled) -- the bar's level pips (and the cooldown ring's length)
		end
	end)
	for _, child in ipairs(me:GetChildren()) do
		if child:IsA("Backpack") then
			watchContainer(child)
		end
	end
	me.ChildAdded:Connect(function(child)
		if child:IsA("Backpack") then
			watchContainer(child) -- a new one every respawn
		end
	end)
	if me.Character then
		task.spawn(onCharacter, me.Character)
	end
	me.CharacterAdded:Connect(onCharacter)
	-- a hold that never sees its release (the window lost focus mid-press) mustn't snap forever; a
	-- balloon being rubbed zaps
	UserInputService.WindowFocusReleased:Connect(function()
		stopTowelLoop()
		releaseCharge()
	end)
	RunService.RenderStepped:Connect(function(dt)
		local ok, err = pcall(frame, dt)
		if not ok then
			warn("[ItemClient] " .. tostring(err))
		end
	end)
end

ItemClient.Init()

return ItemClient
