-- ItemClient: the item bar's engine on this client. ItemBar draws the bar and calls this; the
-- server decides everything (Items.luau) and this only asks, predicts and shows.
-- API (the contract with ItemBar; docs/ITEMS.md):
--   ItemClient.Use(key)             hold it and use it now: local prediction + UseItem; nothing while cooling down
--   ItemClient.Press(key, source?) / ItemClient.Release(key, source?)
--                                   a button / key / click going down and up. Most items are used once on
--                                   Press; the Towel keeps snapping while any source is held (an overhead-
--                                   crack loop, one snap per cooldown). `source` tells holds apart (a key,
--                                   a touch's InputObject, "tool" for a click in the world).
--   ItemClient.Hold(key?)           hold that item's tool (nil = put it away); a click / tap in the world then uses it
--   ItemClient.Held(): string?
--   ItemClient.CooldownUntil(key): number   workspace:GetServerTimeNow() it's ready again (0 = ready)
--   ItemClient.CooldownLength(key): number  seconds of that cooldown (for the ring)
--   ItemClient.IsActive(key): boolean       Glider gliding, Basket hiding, a Duck or Peel out
--   ItemClient.Changed: RBXScriptSignal     (key) cooldown / active / held changed
--   ItemClient.Failed: RBXScriptSignal      (key, err) the server or a local check said no (the server toasts why)
-- Requiring it starts it (and ItemFX, the effects). It also moves the player for their own
-- movement items, as Roblox characters are moved by their own client: the Slipper Dash (a short
-- LinearVelocity burst along the floor) and the Dryer-Sheet Glider (fall slowly, fly forward, steer
-- with the move keys / thumbstick; landing ends it and tells the server).
-- Cooldowns: the server's own time per item arrives as the player attribute CD_<key>; a use is
-- predicted at once and corrected by the server's answer.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local ItemConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("ItemConfig"))
local ItemFX = require(script.Parent:WaitForChild("ItemFX"))

local ItemClient = {}

local changedEvent = Instance.new("BindableEvent")
local failedEvent = Instance.new("BindableEvent")
ItemClient.Changed = changedEvent.Event
ItemClient.Failed = failedEvent.Event

local TOGGLES: { [string]: boolean } = { Glider = true, LaundryBasket = true } -- a second use switches them off
local FACE_AIM: { [string]: boolean } = { Towel = true, BubbleBlaster = true, SoftenerCloud = true } -- a click turns you to it

local me = Players.LocalPlayer
local predicted: { [string]: number } = {} -- key -> ready time we expect (server clock) until the server answers
local predictedActive: { [string]: boolean? } = {}
local busy: { [string]: boolean } = {}
local held: string? = nil
local towelSources: { [any]: boolean } = {} -- whatever is holding the towel button down right now
local towelLoop = 0 -- bumped to stop the current loop
local towelFromClick = false -- a held click in the world aims each snap at the mouse
local hooked: { [Instance]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function now(): number
	return workspace:GetServerTimeNow()
end

local function changed(key: string?)
	if key then
		changedEvent:Fire(key)
	end
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
	return if item then item.cooldown else 0
end

function ItemClient.IsActive(key: string): boolean
	if type(key) ~= "string" then
		return false
	end
	local guess = predictedActive[key]
	if guess ~= nil then
		return guess
	end
	return me:GetAttribute("Active_" .. key) == true
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

local function stopDash()
	local d = dash
	if d then
		dash = nil
		d.lv:Destroy()
		d.att:Destroy()
	end
end

local function startDash(humanoid: Humanoid, root: BasePart)
	stopDash()
	local D = ItemConfig.Dash
	local dir = flat(humanoid.MoveDirection) or flat(root.CFrame.LookVector) or Vector3.new(0, 0, -1)
	local speed = D.distance / D.seconds * (if carrying() then D.carryMult else 1)
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
	task.delay(D.seconds, function()
		if dash and dash.token == token then
			stopDash()
		end
	end)
end

-- ---------- the Dryer-Sheet Glider (your own character) ----------

local glide: { att: Attachment, lv: LinearVelocity, dir: Vector3, started: number, conn: RBXScriptConnection }? = nil
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
	if humanoid.FloorMaterial ~= Enum.Material.Air then
		return false -- on the ground: the server says why
	end
	stopGlide(false)
	local G = ItemConfig.Glider
	local att = Instance.new("Attachment")
	att.Name = "ItemGlide"
	att.Parent = root
	local lv = Instance.new("LinearVelocity")
	lv.Name = "ItemGlide"
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.MaxForce = 1e6
	local dir = flat(humanoid.MoveDirection) or flat(root.CFrame.LookVector) or Vector3.new(0, 0, -1)
	lv.VectorVelocity = dir * G.forwardSpeed + Vector3.new(0, -G.fallSpeed, 0)
	lv.Parent = root
	local started = os.clock()
	local g = { att = att, lv = lv, dir = dir, started = started, conn = nil :: any }
	g.conn = RunService.Heartbeat:Connect(function(dt)
		if glide ~= g then
			return
		end
		-- steer toward the stick / move keys, always flying forward and sinking slowly
		local want = flat(humanoid.MoveDirection)
		if want then
			g.dir = flat(g.dir:Lerp(want, math.min(1, dt * 4))) or want
		end
		lv.VectorVelocity = g.dir * G.forwardSpeed + Vector3.new(0, -G.fallSpeed, 0)
		local age = os.clock() - started
		if humanoid.Health <= 0 or root.Parent == nil or age > G.maxSeconds + 0.5 then
			stopGlide(false)
		elseif age > 0.25 and humanoid.FloorMaterial ~= Enum.Material.Air then
			stopGlide(true) -- landed: end it and tell the server
		end
	end)
	glide = g
	return true
end

-- ---------- using ----------

local function aimFor(root: BasePart, fromClick: boolean): Vector3?
	if fromClick then
		local ok, hit = pcall(function()
			return me:GetMouse().Hit.Position
		end)
		if ok and typeof(hit) == "Vector3" then
			local d = Vector3.new(hit.X - root.Position.X, 0, hit.Z - root.Position.Z)
			if d.Magnitude > 1 then
				return d.Unit
			end
		end
	end
	return flat(root.CFrame.LookVector)
end

local function ask(key: string, aim: Vector3?, onAnswer: (boolean, any) -> (), heldDown: boolean?)
	local fn = remote()
	if not fn then
		onAnswer(false, nil)
		return
	end
	busy[key] = true
	task.spawn(function()
		local ok, result = pcall(function()
			return fn:InvokeServer(key, aim, if heldDown then true else nil)
		end)
		busy[key] = nil
		onAnswer(ok and type(result) == "table" and result.ok == true, if ok then result else nil)
	end)
end

local function use(key: any, fromClick: boolean, heldDown: boolean?)
	if type(key) ~= "string" or not ItemConfig.Items[key] or busy[key] then
		return
	end
	local _, humanoid, root = body()
	if not humanoid or not root then
		return
	end
	local active = ItemClient.IsActive(key)
	local switchingOff = TOGGLES[key] == true and active
	if not switchingOff and ItemClient.CooldownUntil(key) > 0 then
		return -- nothing while cooling down (the ring says so)
	end
	ItemClient.Hold(key)
	local aim = aimFor(root, fromClick)
	if fromClick and aim and FACE_AIM[key] then
		root.CFrame = CFrame.lookAt(root.Position, root.Position + aim)
	end
	-- predict: show it now, the server's answer corrects it
	if TOGGLES[key] then
		predictedActive[key] = not active
		if key == "Glider" then
			if active then
				stopGlide(false)
			else
				startGlide(humanoid, root)
			end
		end
	else
		predicted[key] = now() + ItemConfig.Items[key].cooldown
		ItemFX.Predict(key)
		if key == "SlipperDash" then
			startDash(humanoid, root)
		end
	end
	changed(key)
	ask(key, aim, function(ok, result)
		predictedActive[key] = nil
		local serverUntil = if type(result) == "table" and type(result.cooldownUntil) == "number" then result.cooldownUntil else 0
		if ok then
			predicted[key] = if serverUntil > 0 then serverUntil else predicted[key]
		else
			predicted[key] = nil
			if key == "Glider" and not active then
				stopGlide(false)
			end
			local err = if type(result) == "table" and type(result.err) == "string" then result.err else "Couldn't reach the server - try again"
			failedEvent:Fire(key, err)
		end
		changed(key)
		whenReady(key)
	end, heldDown)
end

function ItemClient.Use(key: string)
	use(key, false)
end

-- ---------- holding the towel down: an overhead-crack loop ----------

local function towelHeld(): boolean
	return next(towelSources) ~= nil
end

local function stopTowelLoop()
	towelLoop += 1
	table.clear(towelSources)
	towelFromClick = false
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
	if ItemClient.CooldownUntil("Towel") == 0 and not busy.Towel then
		use("Towel", towelFromClick, true)
	end
	task.delay(math.clamp(ItemClient.CooldownUntil("Towel") - now(), 0.03, 2), towelTick, token)
end

function ItemClient.Press(key: string, source: any?)
	if key ~= "Towel" then
		use(key, source == "tool")
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
	if first then
		towelLoop += 1
		ItemFX.SetHold(true)
		towelTick(towelLoop)
	end
end

function ItemClient.Release(key: string, source: any?)
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
		ItemFX.SetHold(false)
	end
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

-- landing on your own: end the glide on the server too (it also notices by itself)
tellLanding = function()
	if busy.Glider then
		return
	end
	predictedActive.Glider = false
	changed("Glider")
	ask("Glider", nil, function()
		predictedActive.Glider = nil
		changed("Glider")
		whenReady("Glider")
	end)
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
	-- a click / tap in the world with the item in hand uses it, aimed at where you clicked (the towel
	-- keeps snapping while the click is held)
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
	watchContainer(character)
	updateHeld()
	character:GetAttributeChangedSignal("Gliding"):Connect(function()
		if character:GetAttribute("Gliding") ~= true then
			stopGlide(false) -- the server ended it (time, a knock, a slip)
		end
		changed("Glider")
	end)
	character:GetAttributeChangedSignal("InBasket"):Connect(function()
		changed("LaundryBasket")
	end)
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
	-- a hold that never sees its release (the window lost focus mid-press) mustn't snap forever
	UserInputService.WindowFocusReleased:Connect(stopTowelLoop)
end

ItemClient.Init()

return ItemClient
