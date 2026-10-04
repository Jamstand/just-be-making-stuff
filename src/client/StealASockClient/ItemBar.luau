-- ItemBar: the candy item bar along the bottom of the screen. It replaces Roblox's hotbar (hidden
-- here, retried until Roblox accepts it): the towel slot first and biggest (on phones it's the main
-- button), showing your towel's current look, then the ItemConfig.LoadoutSize items you picked in
-- the Item Shop. Every slot is a button you press and let go: a finger / click on it, 1-4 (Q also
-- the towel; a gamepad uses Y and the d-pad) go down as ItemClient.Press(key, source) and come up
-- as ItemClient.Release(key, source) - from anywhere, the finger may have slid off - and ItemClient,
-- the bar's engine (prediction, the UseItem remote, cooldowns, effects), decides what that means
-- for the item (the towel keeps snapping while held, the Static Balloon charges until you let go,
-- the glider slams on a second press, ...). An empty slot is a "+" that opens the Item Shop on its
-- Items tab.
--
-- A slot shows the item's 3D model (ItemIcon; its emoji until the model is imported), its key
-- (keyboard / gamepad only), its upgrade level as 3 small pips (StateView itemLevels) - at the
-- max level a gold frame with a soft shimmer and the golden `<model>_Gold` model - a dark sweep with
-- the seconds left while it cools down (a pop and a sound when it's ready again), a ring that fills
-- while it charges (ItemClient.Charge: the Static Balloon), a pulsing glow while it's active
-- (ItemClient.IsActive: gliding, hiding under the basket, a peel or duck out), a raised white rim
-- while you hold it, and a shake with the error sound when ItemClient.Failed says no (the gameplay
-- side already toasts why). When the loadout changes the new slots pop in one by one; a new towel
-- look sparkles in; a level up pops its pip in, and turning golden bursts the gold frame in.
--
-- Placement: ItemBarLayout (shared with the HUD, which keeps the carry banner above the bar).
-- Without ItemClient (still starting, missing or broken) the bar stays and a tap calls the UseItem
-- remote itself. Nothing runs per frame except the sweep of a slot that is cooling down and the
-- ring of a slot that is charging.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local ItemConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("ItemConfig"))

local Theme = require(script.Parent:WaitForChild("Theme"))
local Anim = require(script.Parent:WaitForChild("Anim"))
local UISound = require(script.Parent:WaitForChild("UISound"))
local Menu = require(script.Parent:WaitForChild("Menu"))
local ClientSettings = require(script.Parent:WaitForChild("ClientSettings"))

-- the bar's own helpers load without an endless wait, so a missing file can't hang the client
local function optional(name: string): any
	local module = script.Parent:WaitForChild(name, 5)
	if not module then
		warn("[ItemBar] " .. name .. " is missing - copy src/client/StealASockClient/" .. name .. ".luau into the place")
		return nil
	end
	local ok, result = pcall(require, module)
	if not ok then
		warn("[ItemBar] " .. name .. " failed to load: " .. tostring(result))
		return nil
	end
	return result
end
local ItemBarLayout = optional("ItemBarLayout")
local ItemIcon = optional("ItemIcon")

local ItemBar = {}

local WHITE = Color3.new(1, 1, 1)
local rgb = Color3.fromRGB
local C = Theme.Color
local SLOTS = ItemConfig.LoadoutSize
local LIFT = 8 -- the slot of the item you hold rises this much (reference px)
local SWEEP_COLOR = rgb(24, 14, 40)
local SWEEP_ALPHA = 0.36 -- the cooldown sweep's transparency
local PIP = 9 -- a level pip (reference px)
local PIP_GAP = 3
local PIP_OFF = rgb(104, 84, 124)
local GOLD_PIP = rgb(255, 214, 80)
local GOLD_RIM = rgb(255, 200, 64) -- the max-level frame
local GOLD_TOP, GOLD_BOTTOM = rgb(255, 244, 196), rgb(240, 186, 70) -- ...and its tile
local CHARGE_RING = 7 -- the charge ring shows this far around the tile (reference px)
local CHARGE_TRACK = rgb(74, 42, 94)
local CHARGE_FILL = rgb(255, 232, 92)
local LOUD_READY = 2 -- cooldowns at least this long (s) chime when they end; the towel's quick one doesn't
local POLL_SIGNALLED = 1 -- seconds between safety re-reads of ItemClient (it also signals Changed)
local POLL_UNSIGNALLED = 0.25 -- ...and without a Changed signal
local SHOW_AFTER = 4 -- the bar shows on the first State, or after this many seconds without one
local FAIL_GAP = 0.25 -- least time between two error shakes of one slot

-- keys: 1-4 (and the keypad), Q for the towel; gamepad Y + d-pad
local NUMBER_KEYS = { Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four, Enum.KeyCode.Five, Enum.KeyCode.Six, Enum.KeyCode.Seven, Enum.KeyCode.Eight, Enum.KeyCode.Nine }
local KEYPAD_KEYS = { Enum.KeyCode.KeypadOne, Enum.KeyCode.KeypadTwo, Enum.KeyCode.KeypadThree, Enum.KeyCode.KeypadFour, Enum.KeyCode.KeypadFive, Enum.KeyCode.KeypadSix, Enum.KeyCode.KeypadSeven, Enum.KeyCode.KeypadEight, Enum.KeyCode.KeypadNine }
local PAD_KEYS = { Enum.KeyCode.ButtonY, Enum.KeyCode.DPadLeft, Enum.KeyCode.DPadUp, Enum.KeyCode.DPadRight }
local PAD_GLYPHS = { "Y", "◀", "▲", "▶" }
local TOWEL_KEY = Enum.KeyCode.Q

type Slot = {
	index: number, -- 0 = the towel, 1..SLOTS = the loadout
	key: string, -- ItemConfig key, "" = empty
	size: number,
	radius: number,
	holder: Frame, -- placed in the bar, never animated
	tile: TextButton, -- the candy tile: springs, shakes, lifts
	grad: UIGradient,
	rim: UIStroke,
	picture: Frame,
	icon: any?, -- ItemIcon (nil when that module is missing: `emoji` instead)
	emoji: TextLabel?,
	plus: TextLabel,
	glow: Frame,
	sweep: Frame,
	sweepR: Frame,
	sweepL: Frame,
	gradR: UIGradient,
	gradL: UIGradient,
	seconds: TextLabel,
	keycap: Frame,
	keyText: TextLabel,
	keycapQ: Frame?,
	pips: Frame, -- the level pips' capsule
	pipDots: { Frame },
	goldFrame: Frame, -- the max-level frame
	charge: Frame, -- the charge ring (behind the tile; only its edge shows)
	chargeFill: Frame,
	chargeR: Frame,
	chargeL: Frame,
	chargeGradR: UIGradient,
	chargeGradL: UIGradient,
	cooling: boolean,
	untilT: number,
	length: number,
	shownSecs: number,
	active: boolean,
	held: boolean,
	shakeToken: number,
	failedAt: number,
	level: number,
	levelKey: string, -- the key `level` belongs to ("-": none yet)
	gold: boolean,
	charging: boolean, -- the ring is up
	chargeFull: boolean,
	pointerPressed: boolean, -- a click / finger went down on the tile (its Activated is that press's)
}

local built = false
local shown = false
local root: Frame
local bar: Frame
local fitScale: UIScale
local nameTag: Frame
local nameText: TextLabel
local nameToken = 0
local slots = {} :: { Slot }
local layout: any = nil
local towelLook = ItemConfig.TowelLooks[1]
local itemLevels = {} :: { [string]: number } -- StateView itemLevels
local gotState = false
local inputMode = if Theme.IsTouch then "touch" else "keys" -- "keys" | "pad" | "touch"
local shopOpener: (() -> ())? = nil

-- ItemClient (the bar's engine) and the stand-in when it's missing
local client: any = nil
local clientConns = {} :: { RBXScriptConnection }
local signalled = false
local warned = {} :: { [string]: boolean }
local directUntil = {} :: { [string]: number } -- no ItemClient: server time each item is ready
local directBusy = {} :: { [string]: boolean }

local cooling = {} :: { [Slot]: boolean }
local coolConn: RBXScriptConnection? = nil
local chargeWatch = {} :: { [Slot]: boolean } -- slots whose charge is read every frame (pressed, or charging)
local chargeConn: RBXScriptConnection? = nil
local presses = {} :: { [any]: { slot: Slot, key: string } } -- what each input that is down pressed (source -> slot)

-- ---------- ItemClient, safely ----------

local function clientCall(fn: string, ...: any): any
	local c = client
	if c == nil then
		return nil
	end
	local f = c[fn]
	if type(f) ~= "function" then
		return nil
	end
	local ok, result = pcall(f, ...)
	if not ok then
		if not warned[fn] then
			warned[fn] = true
			warn("[ItemBar] ItemClient." .. fn .. " failed: " .. tostring(result))
		end
		return nil
	end
	return result
end

local function cooldownUntil(key: string): number
	local v = if client then clientCall("CooldownUntil", key) else directUntil[key]
	return if type(v) == "number" and v == v then v else 0
end

local function cooldownLength(key: string): number
	local v = if client then clientCall("CooldownLength", key) else nil
	if type(v) == "number" and v > 0 then
		return v
	end
	local item = ItemConfig.Items[key]
	return if item then item.cooldown else 1
end

local function isActive(key: string): boolean
	return client ~= nil and clientCall("IsActive", key) == true
end

local function heldKey(): string?
	local v = if client then clientCall("Held") else nil
	return if type(v) == "string" then v else nil
end

-- Items that charge while held (they have a `chargeSeconds` number: the Static Balloon).
local function canCharge(key: string): boolean
	return key ~= "" and ItemConfig.Stat(key, 0, "chargeSeconds") > 0
end

-- 0..1 while the item charges (ItemClient.Charge), else 0.
local function chargeOf(key: string): number
	local v = if client and key ~= "" then clientCall("Charge", key) else nil
	return if type(v) == "number" and v == v then math.clamp(v, 0, 1) else 0
end

-- The item's upgrade level: the State's, or ItemClient.Level (the Lv_<key> attribute) when that is
-- newer (levels only go up).
local function levelOf(key: string): number
	if key == "" or key == "Towel" then
		return 0
	end
	local fromState = itemLevels[key]
	local v = if client then clientCall("Level", key) else nil
	local fromClient = if type(v) == "number" and v == v then v else 0
	return math.max(if type(fromState) == "number" and fromState == fromState then fromState else 0, fromClient)
end

-- ---------- small helpers ----------

local function refScale(): number
	return math.max(Theme.Scale(), 0.01)
end

local function tilePos(slot: Slot): UDim2
	return UDim2.new(0.5, 0, 0.5, if slot.held then -LIFT else 0)
end

local function displayName(key: string): string
	local item = ItemConfig.Items[key]
	return if item then item.display else key
end

-- A ring and a few sparkles bursting out of a tile (ready again, a new item, a new towel look).
local function burst(slot: Slot, color: Color3, sparkles: boolean)
	if Anim.Reduced then
		return
	end
	local ring = Instance.new("Frame")
	ring.Name = "Burst"
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.Size = UDim2.fromScale(1, 1)
	ring.BackgroundTransparency = 1
	ring.ZIndex = 8
	Theme.corner(ring, slot.radius)
	local ringStroke = Theme.stroke(ring, color, 4)
	ring.Parent = slot.holder
	local grow = Anim.tween(ring, 0.45, { Size = UDim2.new(1, 26, 1, 26) }, Enum.EasingStyle.Quint)
	Anim.tween(ringStroke, 0.45, { Transparency = 1, Thickness = 1 }, Enum.EasingStyle.Quad)
	grow.Completed:Once(function()
		ring:Destroy()
	end)
	if not sparkles then
		return
	end
	for i = 1, 6 do
		local star = Theme.label(slot.holder, "✦", 18, if i % 2 == 0 then C.Gold else color)
		star.Name = "Sparkle"
		star.AnchorPoint = Vector2.new(0.5, 0.5)
		star.Position = UDim2.fromScale(0.5, 0.5)
		star.Size = UDim2.fromOffset(22, 22)
		star.ZIndex = 9
		local angle = (i / 6) * math.pi * 2 + math.random() * 0.5
		local dist = slot.size * 0.55 + math.random() * 14
		local fly = Anim.tween(star, 0.6, {
			Position = UDim2.new(0.5, math.cos(angle) * dist, 0.5, math.sin(angle) * dist),
			Rotation = math.random(-120, 120),
			TextTransparency = 1,
		}, Enum.EasingStyle.Quint)
		fly.Completed:Once(function()
			star:Destroy()
		end)
	end
end

-- The name above a slot (desktop hover; briefly when an item lands in the bar).
local function showName(slot: Slot?, seconds: number?)
	nameToken += 1
	local token = nameToken
	if not slot or slot.key == "" then
		nameTag.Visible = false
		return
	end
	nameText.Text = displayName(slot.key)
	local width = math.max(90, math.min(220, #nameText.Text * 11 + 30))
	nameTag.Size = UDim2.fromOffset(width, 30)
	-- over the slot, but never past the bar's ends (the bar is on screen; a wide tag might not be)
	local x = math.clamp(slot.holder.Position.X.Offset + slot.size / 2, width / 2, bar.Size.X.Offset - width / 2)
	nameTag.Position = UDim2.fromOffset(x, slot.holder.Position.Y.Offset - 10)
	if not nameTag.Visible then
		Anim.popIn(nameTag)
	end
	if seconds then
		task.delay(seconds, function()
			if nameToken == token then
				nameTag.Visible = false
			end
		end)
	end
end

-- ---------- slot visuals ----------

local function setPicture(slot: Slot)
	local key = slot.key
	if slot.icon then
		slot.icon:Set(if key == "" then nil else key, if key == "Towel" then towelLook else nil, slot.gold)
	elseif slot.emoji then
		local item = ItemConfig.Items[key]
		slot.emoji.Text = if item then item.icon else ""
	end
end

local function paint(slot: Slot)
	local key = slot.key
	local item = if key ~= "" then ItemConfig.Items[key] else nil
	if item and slot.gold then
		slot.grad.Color = ColorSequence.new(GOLD_TOP, GOLD_BOTTOM:Lerp(item.color, 0.25))
		slot.glow.BackgroundColor3 = GOLD_TOP
	elseif item then
		slot.grad.Color = ColorSequence.new(item.color:Lerp(WHITE, 0.55), item.color:Lerp(WHITE, 0.1))
		slot.glow.BackgroundColor3 = item.color:Lerp(WHITE, 0.35)
	else
		slot.grad.Color = ColorSequence.new(C.Inset, C.InsetDark)
	end
	slot.plus.Visible = key == ""
	slot.picture.Visible = key ~= ""
	setPicture(slot)
end

-- One clock-face sweep: the covered part runs from (1 - remaining) of a turn round to 12 o'clock;
-- each half is a full-size tile cut by a hard-edged gradient, turned to the edge's angle.
local function setHalves(right: Frame, left: Frame, gradR: UIGradient, gradL: UIGradient, remaining: number)
	local a = (1 - math.clamp(remaining, 0, 1)) * 360
	if a < 180 then
		right.Visible = true
		gradR.Rotation = a
		left.Visible = true
		gradL.Rotation = 180
	else
		right.Visible = false
		left.Visible = a < 359.5
		gradL.Rotation = a
	end
end

local function setSweep(slot: Slot, remaining: number)
	setHalves(slot.sweepR, slot.sweepL, slot.gradR, slot.gradL, remaining)
end

-- ---------- level pips and the golden look ----------

-- A gentle gold light sweep across the tile (Anim.shine; it rests while Reduce motion is on).
local function setShimmer(slot: Slot, on: boolean)
	local sheen = slot.tile:FindFirstChild("Sheen")
	if on and not sheen then
		Anim.shine(slot.tile, 3.4)
		local s = slot.tile:FindFirstChild("Sheen")
		if s and s:IsA("Frame") then
			s.BackgroundColor3 = rgb(255, 248, 210)
			s.BackgroundTransparency = 0.3 -- soft
			s.ZIndex = 5 -- over the picture, under the seconds
		end
	elseif not on and sheen then
		sheen:Destroy()
	end
end

local function setGold(slot: Slot, on: boolean, animate: boolean)
	if slot.gold == on then
		return
	end
	slot.gold = on
	paint(slot) -- the golden tile and the `<model>_Gold` picture
	setShimmer(slot, on)
	if on and animate then
		Anim.popIn(slot.goldFrame)
		Anim.bump(slot.tile, 1.2)
		burst(slot, GOLD_RIM, true)
		task.delay(0.25, function()
			if slot.gold then
				burst(slot, WHITE, true)
			end
		end)
	else
		slot.goldFrame.Visible = on
	end
end

-- Shows the slot's upgrade level (pips; gold at the max level). A level up pops the new pips in.
local function setLevel(slot: Slot, level: number, animate: boolean)
	local key = slot.key
	local levels = if key ~= "" and key ~= "Towel" then ItemConfig.Levels[key] else nil
	local maxLevel = if levels then #levels else 0
	local lv = math.clamp(math.floor(level), 0, maxLevel)
	if slot.levelKey == key and slot.level == lv then
		return
	end
	local fresh = slot.levelKey ~= key -- a new item in the slot: no level-up show
	local before = if fresh then lv else slot.level
	slot.levelKey, slot.level = key, lv
	local gold = levels ~= nil and maxLevel > 0 and ItemConfig.IsGold(lv)
	local item = ItemConfig.Items[key]
	local on = if item then item.color:Lerp(WHITE, 0.3) else WHITE
	slot.pips.Visible = levels ~= nil
	for i, dot in ipairs(slot.pipDots) do
		dot.Visible = i <= maxLevel
		local filled = i <= lv
		dot.BackgroundColor3 = if gold then GOLD_PIP elseif filled then on else PIP_OFF
		if animate and not fresh and filled and i > before and not Anim.Reduced then
			local s = Anim.scale(dot)
			s.Scale = 0
			Anim.tween(s, 0.4, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, (i - before - 1) * 0.1)
		end
	end
	if animate and not fresh and lv > before then
		Anim.bump(slot.pips, 1.35)
	end
	setGold(slot, gold, animate and not fresh)
end

-- ---------- the charge ring (ItemClient.Charge) ----------

local function hideCharge(slot: Slot)
	if not slot.charging then
		return
	end
	slot.charging = false
	slot.chargeFull = false
	Anim.stop(slot.charge, "pulse")
	Anim.scale(slot.charge).Scale = 1
	slot.charge.Visible = false
	slot.chargeFill.BackgroundColor3 = CHARGE_FILL
	Anim.tween(Anim.scale(slot.picture), 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
end

local function showCharge(slot: Slot, c: number)
	if not slot.charging then
		slot.charging = true
		slot.charge.Visible = true
		slot.charge.Position = tilePos(slot)
	end
	-- the unfilled part (the track) covers from c of a turn round to 12 o'clock
	setHalves(slot.chargeR, slot.chargeL, slot.chargeGradR, slot.chargeGradL, 1 - c)
	if not Anim.Reduced then
		Anim.scale(slot.picture).Scale = 1 + 0.12 * c -- the item swells as it charges
	end
	if c >= 1 and not slot.chargeFull then
		slot.chargeFull = true
		slot.chargeFill.BackgroundColor3 = WHITE
		Anim.pulse(slot.charge, 1.06, 0.35)
		burst(slot, CHARGE_FILL, true)
		UISound.Play("pop", 1.35)
	end
end

local function stepCharge()
	for slot in pairs(chargeWatch) do
		local c = if canCharge(slot.key) then chargeOf(slot.key) else 0
		if c > 0 then
			showCharge(slot, c)
		else
			hideCharge(slot)
			local pressed = false
			for _, p in pairs(presses) do
				if p.slot == slot then
					pressed = true
				end
			end
			if not pressed then
				chargeWatch[slot] = nil -- (a charge started elsewhere is noticed by refreshSlot)
			end
		end
	end
	if next(chargeWatch) == nil and chargeConn then
		chargeConn:Disconnect()
		chargeConn = nil
	end
end

local function watchCharge(slot: Slot)
	if not canCharge(slot.key) then
		return
	end
	chargeWatch[slot] = true
	if not chargeConn then
		chargeConn = RunService.RenderStepped:Connect(stepCharge)
	end
end

local function setActive(slot: Slot, on: boolean)
	if slot.active == on then
		return
	end
	slot.active = on
	if on then
		slot.glow.Visible = true
		Anim.popIn(slot.glow)
		task.delay(0.3, function()
			if slot.active then
				Anim.pulse(slot.glow, 1.08, 0.9)
			end
		end)
	else
		Anim.stop(slot.glow, "pulse")
		Anim.popOut(slot.glow)
	end
end

local function setHeld(slot: Slot, on: boolean)
	if slot.held == on then
		return
	end
	slot.held = on
	slot.rim.Color = if on then WHITE else C.Stroke
	slot.rim.Thickness = if on then 4.5 else 3
	Anim.tween(slot.tile, 0.3, { Position = tilePos(slot) }, Enum.EasingStyle.Back)
	Anim.tween(slot.charge, 0.3, { Position = tilePos(slot) }, Enum.EasingStyle.Back) -- the ring rises with it
end

-- The no-no: a quick side-to-side shake and a red rim (a sideways shake, not a turn, so the
-- cooldown sweep's clipping stays put).
local function shake(slot: Slot)
	local now = os.clock()
	if now - slot.failedAt < FAIL_GAP then
		return
	end
	slot.failedAt = now
	slot.shakeToken += 1
	local token = slot.shakeToken
	UISound.Play("error")
	slot.rim.Color = C.Bad
	task.delay(0.45, function()
		if slot.shakeToken == token then
			slot.rim.Color = if slot.held then WHITE else C.Stroke
		end
	end)
	if Anim.Reduced then
		Anim.bump(slot.tile, 1.06)
		return
	end
	task.spawn(function()
		for _, dx in ipairs({ -7, 6, -4, 3, -1, 0 }) do
			if slot.shakeToken ~= token then
				return
			end
			Anim.tween(slot.tile, 0.045, { Position = tilePos(slot) + UDim2.fromOffset(dx, 0) }, Enum.EasingStyle.Sine).Completed:Wait()
		end
	end)
end

-- ---------- cooldowns ----------

local function finishCooling(slot: Slot, pop: boolean)
	if not slot.cooling then
		return
	end
	slot.cooling = false
	cooling[slot] = nil
	slot.sweep.Visible = false
	slot.seconds.Visible = false
	if pop and slot.key ~= "" then
		Anim.bump(slot.tile, 1.14)
		burst(slot, WHITE, false)
		if slot.length >= LOUD_READY then
			UISound.Play("pop", 1.2)
		end
	end
end

local function stepCooldowns()
	local now = workspace:GetServerTimeNow()
	for slot in pairs(cooling) do
		local left = slot.untilT - now
		if left <= 0 then
			finishCooling(slot, true)
		else
			setSweep(slot, left / slot.length)
			local secs = math.ceil(left)
			if secs ~= slot.shownSecs then
				slot.shownSecs = secs
				slot.seconds.Text = tostring(secs)
			end
		end
	end
	if next(cooling) == nil and coolConn then
		coolConn:Disconnect()
		coolConn = nil
	end
end

local function startCooling(slot: Slot, untilT: number)
	local now = workspace:GetServerTimeNow()
	slot.cooling = true
	slot.untilT = untilT
	slot.length = math.max(cooldownLength(slot.key), untilT - now, 0.1)
	slot.shownSecs = -1
	slot.sweep.Visible = true
	slot.seconds.Visible = true
	cooling[slot] = true
	stepCooldowns()
	if not coolConn and next(cooling) ~= nil then
		coolConn = RunService.RenderStepped:Connect(stepCooldowns)
	end
end

-- Re-reads cooldown, active, held, charge and level for a slot from ItemClient.
local function refreshSlot(slot: Slot)
	local key = slot.key
	if key == "" then
		finishCooling(slot, false)
		setActive(slot, false)
		setHeld(slot, false)
		hideCharge(slot)
		return
	end
	setLevel(slot, levelOf(key), shown)
	if not chargeWatch[slot] and canCharge(key) and chargeOf(key) > 0 then
		watchCharge(slot) -- charging from somewhere else (a click in the world with it in hand)
	end
	local untilT = cooldownUntil(key)
	if untilT > workspace:GetServerTimeNow() + 0.05 then
		if not slot.cooling or math.abs(untilT - slot.untilT) > 0.05 then
			startCooling(slot, untilT)
		end
	elseif slot.cooling then
		finishCooling(slot, true)
	end
	setActive(slot, isActive(key))
	setHeld(slot, heldKey() == key)
end

local function refreshKey(key: any)
	for _, slot in ipairs(slots) do
		if type(key) ~= "string" or slot.key == key then
			refreshSlot(slot)
		end
	end
end

local function refreshAll()
	refreshKey(nil)
end

-- ---------- using ----------

local function onFailed(key: any)
	for _, slot in ipairs(slots) do
		if slot.key ~= "" and slot.key == key then
			shake(slot)
		end
	end
end

local function aimDirection(): Vector3?
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end
	local look = camera.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	return if flat.Magnitude > 1e-3 then flat.Unit else nil
end

-- No ItemClient: ask the server straight away (it checks everything) and time the ring from its answer.
local function directUse(key: string)
	if directBusy[key] then
		return
	end
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	local remote = if folder then folder:FindFirstChild("UseItem") else nil
	if not (remote and remote:IsA("RemoteFunction")) then
		onFailed(key)
		return
	end
	directBusy[key] = true
	task.spawn(function()
		local ok, result = pcall(function()
			return remote:InvokeServer(key, aimDirection())
		end)
		directBusy[key] = nil
		if ok and type(result) == "table" then
			if type(result.cooldownUntil) == "number" then
				directUntil[key] = result.cooldownUntil
			end
			if result.ok ~= true then
				onFailed(key)
			end
		else
			onFailed(key)
		end
		refreshKey(key)
	end)
end

local function openShop()
	UISound.Play("click")
	if shopOpener then
		shopOpener()
	else
		Menu.Open("Shop")
	end
end

-- One quick use (no ItemClient.Press: an older or missing engine; a slot activated without a press,
-- like a gamepad's UI selection). Nothing while it cools down.
local function useSlot(slot: Slot, fromKey: boolean)
	if not built then
		return
	end
	if slot.key == "" then
		Anim.bump(slot.tile, 0.9)
		openShop()
		return
	end
	if fromKey then
		Anim.bump(slot.tile, 0.88) -- (taps get Anim.button's press springs)
	end
	if slot.cooling then
		Anim.bump(slot.seconds, 1.3) -- nothing while it cools down
		return
	end
	if client then
		clientCall("Use", slot.key)
	else
		directUse(slot.key)
	end
	task.defer(refreshKey, slot.key) -- (ItemClient.Changed usually beats this)
end

-- ---------- pressing and letting go (ItemClient.Press / Release, every slot) ----------

local function canPress(): boolean
	return client ~= nil and type(client.Press) == "function" and type(client.Release) == "function"
end

-- An input went down on a slot. ItemClient decides what it does - even while the slot cools down
-- (the towel snaps as soon as it's ready, a dash may still have an air dash), so a cooling slot
-- only nudges its seconds.
local function pressSlot(slot: Slot, source: any, fromKey: boolean)
	if not built or presses[source] then
		return
	end
	local key = slot.key
	if key == "" then
		useSlot(slot, fromKey) -- the "+": the Item Shop
		return
	end
	presses[source] = { slot = slot, key = key }
	if fromKey then
		Anim.bump(slot.tile, 0.88) -- (taps get Anim.button's press springs)
	end
	if slot.cooling then
		Anim.bump(slot.seconds, 1.3)
	end
	clientCall("Press", key, source)
	watchCharge(slot)
	task.defer(refreshKey, key) -- (ItemClient.Changed usually beats this)
end

-- That input came up (anywhere: a finger may have slid off the slot): the item it pressed lets go.
local function releaseSource(source: any)
	local p = presses[source]
	if not p then
		return
	end
	presses[source] = nil
	clientCall("Release", p.key, source)
	task.defer(refreshKey, p.key)
end

local function releaseAll()
	local sources = {}
	for source in pairs(presses) do
		table.insert(sources, source)
	end
	for _, source in ipairs(sources) do
		releaseSource(source)
	end
end

-- ---------- building ----------

local function keycap(parent: Instance, text: string, right: boolean): (Frame, TextLabel)
	local cap = Instance.new("Frame")
	cap.Name = "Key"
	cap.AnchorPoint = Vector2.new(if right then 1 else 0, 0)
	cap.Position = UDim2.new(if right then 1 else 0, if right then 6 else -6, 0, -6)
	cap.Size = UDim2.fromOffset(24, 24)
	cap.ZIndex = 8
	Theme.candy(cap, "purple", 8, 2)
	cap.Parent = parent
	local t = Theme.label(cap, text, 16, WHITE)
	t.Name = "Text"
	t.Size = UDim2.fromScale(1, 1)
	t.ZIndex = 9
	Theme.textStroke(t, Theme.Styles.purple.stroke, 1.5)
	return cap, t
end

local function sweepHalf(sweep: Frame, right: boolean, radius: number, color: Color3?, alpha: number?): (Frame, UIGradient)
	local clip = Instance.new("Frame")
	clip.Name = if right then "Right" else "Left"
	clip.BackgroundTransparency = 1
	clip.ClipsDescendants = true
	clip.Position = UDim2.fromScale(if right then 0.5 else 0, 0)
	clip.Size = UDim2.fromScale(0.5, 1)
	clip.Parent = sweep
	local dark = Instance.new("Frame")
	dark.Name = "Dark"
	dark.BackgroundColor3 = color or SWEEP_COLOR
	dark.BackgroundTransparency = alpha or SWEEP_ALPHA
	dark.BorderSizePixel = 0
	dark.Position = UDim2.fromScale(if right then -1 else 0, 0)
	dark.Size = UDim2.fromScale(2, 1)
	Theme.corner(dark, radius)
	-- opaque on the far side of a line through the centre, at the gradient's rotation
	local g = Instance.new("UIGradient")
	g.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.499, 1),
		NumberSequenceKeypoint.new(0.501, 0),
		NumberSequenceKeypoint.new(1, 0),
	})
	g.Parent = dark
	dark.Parent = clip
	return clip, g
end

local function buildSlot(index: number, size: number): Slot
	local radius = if index == 0 then 22 else 18
	local holder = Instance.new("Frame")
	holder.Name = if index == 0 then "Towel" else "Slot" .. index
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromOffset(size, size)
	holder.Parent = bar

	local glow = Instance.new("Frame")
	glow.Name = "Glow"
	glow.AnchorPoint = Vector2.new(0.5, 0.5)
	glow.Position = UDim2.fromScale(0.5, 0.5)
	glow.Size = UDim2.new(1, 16, 1, 16)
	glow.BackgroundColor3 = C.Gold
	glow.BackgroundTransparency = 0.25
	glow.BorderSizePixel = 0
	glow.Visible = false
	Theme.corner(glow, radius + 8)
	Theme.stroke(glow, WHITE, 3, 0.15)
	glow.Parent = holder

	-- the charge ring: a bright rounded square behind the tile, so only a band round its edge shows;
	-- an opaque track (two half sweeps, like the cooldown) covers the part not charged yet
	local charge = Instance.new("Frame")
	charge.Name = "Charge"
	charge.AnchorPoint = Vector2.new(0.5, 0.5)
	charge.Position = UDim2.fromScale(0.5, 0.5)
	charge.Size = UDim2.new(1, 2 * CHARGE_RING, 1, 2 * CHARGE_RING)
	charge.BackgroundTransparency = 1
	charge.Visible = false
	charge.Parent = holder
	local chargeFill = Instance.new("Frame")
	chargeFill.Name = "Fill"
	chargeFill.Size = UDim2.fromScale(1, 1)
	chargeFill.BackgroundColor3 = CHARGE_FILL
	chargeFill.BorderSizePixel = 0
	Theme.corner(chargeFill, radius + CHARGE_RING)
	chargeFill.Parent = charge
	local track = Instance.new("Frame")
	track.Name = "Track"
	track.BackgroundTransparency = 1
	track.Size = UDim2.fromScale(1, 1)
	track.ZIndex = 2
	track.Parent = charge
	local chargeR, chargeGradR = sweepHalf(track, true, radius + CHARGE_RING, CHARGE_TRACK, 0)
	local chargeL, chargeGradL = sweepHalf(track, false, radius + CHARGE_RING, CHARGE_TRACK, 0)

	local tile = Instance.new("TextButton")
	tile.Name = "Tile"
	tile.Text = ""
	tile.AutoButtonColor = false
	tile.AnchorPoint = Vector2.new(0.5, 0.5)
	tile.Position = UDim2.fromScale(0.5, 0.5)
	tile.Size = UDim2.fromScale(1, 1)
	tile.BackgroundColor3 = WHITE
	tile.BorderSizePixel = 0
	tile.ZIndex = 2
	Theme.corner(tile, radius)
	local rim = Theme.stroke(tile, C.Stroke, 3)
	local grad = Theme.gradient(tile, C.Inset, C.InsetDark)
	Theme.gloss(tile, radius)
	tile.Parent = holder

	local picture = Instance.new("Frame")
	picture.Name = "Picture"
	picture.BackgroundTransparency = 1
	picture.AnchorPoint = Vector2.new(0.5, 0.5)
	picture.Position = UDim2.fromScale(0.5, 0.5)
	picture.Size = UDim2.fromScale(if index == 0 then 0.9 else 0.84, if index == 0 then 0.9 else 0.84)
	picture.ZIndex = 4
	picture.Parent = tile
	local icon = if ItemIcon then ItemIcon.new(picture) else nil
	local emoji: TextLabel? = nil
	if not icon then
		local e = Theme.label(picture, "", 34, WHITE)
		e.Name = "Emoji"
		e.Size = UDim2.fromScale(1, 1)
		e.TextScaled = true
		emoji = e
	end

	local plus = Theme.label(tile, "+", math.floor(size * 0.6), C.Muted)
	plus.Name = "Plus"
	plus.Size = UDim2.fromScale(1, 1)
	plus.ZIndex = 4
	plus.Visible = false

	local sweep = Instance.new("Frame")
	sweep.Name = "Cooldown"
	sweep.BackgroundTransparency = 1
	sweep.Size = UDim2.fromScale(1, 1)
	sweep.ZIndex = 5
	sweep.Visible = false
	sweep.Parent = tile
	local sweepR, gradR = sweepHalf(sweep, true, radius)
	local sweepL, gradL = sweepHalf(sweep, false, radius)

	local seconds = Theme.label(tile, "", if index == 0 then 34 else 30, WHITE)
	seconds.Name = "Seconds"
	seconds.AnchorPoint = Vector2.new(0.5, 0.5)
	seconds.Position = UDim2.fromScale(0.5, 0.5)
	seconds.Size = UDim2.fromScale(1, 0.6)
	seconds.ZIndex = 6
	seconds.Visible = false
	Theme.textStroke(seconds, C.Ink, 2.5)

	local cap, capText = keycap(tile, tostring(index + 1), false)
	local capQ: Frame? = nil
	if index == 0 then
		capQ = keycap(tile, "Q", true)
	end

	-- the max-level frame: a gold band just inside the plum rim
	local goldFrame = Instance.new("Frame")
	goldFrame.Name = "Gold"
	goldFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	goldFrame.Position = UDim2.fromScale(0.5, 0.5)
	goldFrame.Size = UDim2.new(1, -8, 1, -8)
	goldFrame.BackgroundTransparency = 1
	goldFrame.ZIndex = 3
	goldFrame.Visible = false
	Theme.corner(goldFrame, radius - 4)
	local goldStroke = Theme.stroke(goldFrame, GOLD_RIM, 3.5)
	local goldShade = Instance.new("UIGradient") -- a light top edge, a deeper bottom one
	goldShade.Color = ColorSequence.new(WHITE, rgb(214, 190, 150))
	goldShade.Rotation = 90
	goldShade.Parent = goldStroke
	goldFrame.Parent = tile

	-- the upgrade level: up to ItemConfig.MaxLevel pips in a little capsule along the bottom
	local maxPips = ItemConfig.MaxLevel
	local pips = Instance.new("Frame")
	pips.Name = "Level"
	pips.AnchorPoint = Vector2.new(0.5, 1)
	pips.Position = UDim2.new(0.5, 0, 1, -3)
	pips.Size = UDim2.fromOffset(maxPips * PIP + (maxPips - 1) * PIP_GAP + 8, PIP + 6)
	pips.BackgroundColor3 = C.Ink
	pips.BackgroundTransparency = 0.3
	pips.BorderSizePixel = 0
	pips.ZIndex = 7
	pips.Visible = false
	Theme.corner(pips, UDim.new(0.5, 0))
	pips.Parent = tile
	local pipDots = {}
	for i = 1, maxPips do
		local dot = Instance.new("Frame")
		dot.Name = "Pip" .. i
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.Position = UDim2.fromOffset(4 + (i - 1) * (PIP + PIP_GAP) + PIP / 2, 3 + PIP / 2)
		dot.Size = UDim2.fromOffset(PIP, PIP)
		dot.BackgroundColor3 = PIP_OFF
		dot.BorderSizePixel = 0
		dot.ZIndex = 8
		Theme.corner(dot, UDim.new(0.5, 0))
		dot.Parent = pips
		table.insert(pipDots, dot)
	end

	local slot: Slot = {
		index = index,
		key = "",
		size = size,
		radius = radius,
		holder = holder,
		tile = tile,
		grad = grad,
		rim = rim,
		picture = picture,
		icon = icon,
		emoji = emoji,
		plus = plus,
		glow = glow,
		sweep = sweep,
		sweepR = sweepR,
		sweepL = sweepL,
		gradR = gradR,
		gradL = gradL,
		seconds = seconds,
		keycap = cap,
		keyText = capText,
		keycapQ = capQ,
		pips = pips,
		pipDots = pipDots,
		goldFrame = goldFrame,
		charge = charge,
		chargeFill = chargeFill,
		chargeR = chargeR,
		chargeL = chargeL,
		chargeGradR = chargeGradR,
		chargeGradL = chargeGradL,
		cooling = false,
		untilT = 0,
		length = 1,
		shownSecs = -1,
		active = false,
		held = false,
		shakeToken = 0,
		failedAt = -10,
		level = 0,
		levelKey = "-",
		gold = false,
		charging = false,
		chargeFull = false,
		pointerPressed = false,
	}
	Anim.button(tile, "none") -- press springs; using an item makes its own sounds (ItemFX)
	tile.Activated:Connect(function()
		if slot.pointerPressed then
			slot.pointerPressed = false
			return -- it went down on the press (InputBegan) and comes up when that input ends
		end
		useSlot(slot, false) -- the "+", no ItemClient.Press, or an activation without a press
	end)
	tile.InputBegan:Connect(function(input)
		local kind = input.UserInputType
		if kind ~= Enum.UserInputType.MouseButton1 and kind ~= Enum.UserInputType.Touch then
			return
		end
		if not built or slot.key == "" or not canPress() then
			return -- (the tile's Activated handles it)
		end
		local source = if kind == Enum.UserInputType.Touch then input else "mouse"
		if source == "mouse" then
			releaseSource("mouse") -- a click whose button-up got lost
		end
		slot.pointerPressed = true
		pressSlot(slot, source, false)
	end)
	if not Theme.IsTouch then
		tile.MouseEnter:Connect(function()
			showName(slot)
		end)
		tile.MouseLeave:Connect(function()
			showName(nil)
		end)
	end
	return slot
end

-- Key hints: number keys, gamepad glyphs, or nothing on touch screens.
local function applyHints()
	for _, slot in ipairs(slots) do
		local on = inputMode ~= "touch"
		slot.keycap.Visible = on
		slot.keyText.Text = if inputMode == "pad" then (PAD_GLYPHS[slot.index + 1] or "") else tostring(slot.index + 1)
		if inputMode == "pad" and not PAD_GLYPHS[slot.index + 1] then
			slot.keycap.Visible = false
		end
		if slot.keycapQ then
			slot.keycapQ.Visible = inputMode == "keys"
		end
	end
end

local function modeFor(inputType: Enum.UserInputType): string?
	if inputType == Enum.UserInputType.Touch then
		return "touch"
	elseif inputType == Enum.UserInputType.Keyboard or inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.MouseMovement then
		return "keys"
	elseif string.find(inputType.Name, "Gamepad") then
		return "pad"
	end
	return nil
end

local function build()
	local L = ItemBarLayout
	local width, height = L.Size(SLOTS)
	bar = Instance.new("Frame")
	bar.Name = "ItemBar"
	bar.BackgroundTransparency = 1
	bar.AnchorPoint = Vector2.new(0.5, 1) -- the fit scale shrinks it toward the bottom edge
	bar.Size = UDim2.fromOffset(width, height)
	bar.Position = UDim2.new(0.5, 0, 1, height + 40)
	bar.Visible = false
	bar.Parent = root
	fitScale = Instance.new("UIScale")
	fitScale.Name = "FitScale"
	fitScale.Parent = bar

	-- the cream tray the slots sit in (the towel sticks out of its top)
	local trayH = L.Slot + 2 * L.TrayInset
	local tray = Instance.new("Frame")
	tray.Name = "Tray"
	tray.AnchorPoint = Vector2.new(0, 1)
	tray.Position = UDim2.fromScale(0, 1)
	tray.Size = UDim2.new(1, 0, 0, trayH)
	Theme.candy(tray, "cream", trayH / 2, 3)
	Theme.gloss(tray, trayH / 2)
	tray.Parent = bar

	local towel = buildSlot(0, L.Towel)
	towel.holder.Position = UDim2.fromOffset(L.Pad, height - L.TrayInset - L.Towel)
	table.insert(slots, towel)
	for i = 1, SLOTS do
		local slot = buildSlot(i, L.Slot)
		slot.holder.Position = UDim2.fromOffset(L.Pad + L.Towel + L.TowelGap + (i - 1) * (L.Slot + L.Gap), height - L.TrayInset - L.Slot)
		table.insert(slots, slot)
	end
	towel.key = "Towel"
	for _, slot in ipairs(slots) do
		paint(slot)
	end

	nameTag = Instance.new("Frame")
	nameTag.Name = "NameTag"
	nameTag.AnchorPoint = Vector2.new(0.5, 1)
	nameTag.Size = UDim2.fromOffset(140, 30)
	nameTag.ZIndex = 10
	nameTag.Visible = false
	Theme.candy(nameTag, "purple", 15, 2.5)
	nameTag.Parent = bar
	nameText = Theme.label(nameTag, "", 18, WHITE)
	nameText.Size = UDim2.new(1, -12, 1, 0)
	nameText.Position = UDim2.fromOffset(6, 0)
	nameText.ZIndex = 11
	nameText.TextScaled = true
	Theme.textStroke(nameText, Theme.Styles.purple.stroke, 2)
	local maxText = Instance.new("UITextSizeConstraint")
	maxText.MaxTextSize = 18
	maxText.Parent = nameText
end

local function barPos(visible: boolean): UDim2
	if not layout then
		return UDim2.new(0.5, 0, 1, 0)
	end
	if visible then
		return UDim2.new(0, layout.x, 1, -layout.bottom)
	end
	return UDim2.new(0, layout.x, 1, layout.height + 40)
end

local function columnInfo(refHeight: number): { right: number, bottom: number }?
	if type(Menu.ColumnBottom) ~= "function" then
		return nil
	end
	return { right = Menu.ColumnRight, bottom = Menu.ColumnBottom(refHeight) }
end

local function relayout()
	local s = refScale()
	local refW, refH = root.AbsoluteSize.X / s, root.AbsoluteSize.Y / s
	if refW <= 1 or refH <= 1 then
		return
	end
	layout = ItemBarLayout.Compute(refW, refH, s, Theme.IsTouch, SLOTS, columnInfo(refH))
	fitScale.Scale = layout.fit
	bar.Position = barPos(shown)
end

local function show()
	if shown then
		return
	end
	shown = true
	bar.Visible = true
	bar.Position = barPos(false)
	Anim.tween(bar, 0.55, { Position = barPos(true) }, Enum.EasingStyle.Back)
	for i, slot in ipairs(slots) do
		Anim.popIn(slot.tile, 0.12 + (i - 1) * 0.07)
	end
	UISound.Play("whoosh")
end

-- Roblox's own hotbar goes: the bar replaces it. SetCoreGuiEnabled can fail while the core
-- scripts are still starting, so keep trying.
local function hideBackpack()
	task.spawn(function()
		local pause = 0.2
		for _ = 1, 200 do
			local ok = pcall(function()
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
			end)
			if ok then
				return
			end
			task.wait(pause)
			pause = math.min(pause * 1.5, 2)
		end
		warn("[ItemBar] couldn't hide Roblox's hotbar")
	end)
end

-- ---------- API ----------

function ItemBar.Init(itemClient: any?)
	if built then
		return
	end
	if not ItemBarLayout then
		warn("[ItemBar] no ItemBarLayout: the item bar is off (Roblox's hotbar stays)")
		return
	end
	local _, barRoot = Theme.screen("SockItemBar", 6) -- above the HUD (5), under the menus (10+)
	root = barRoot
	build()
	built = true
	applyHints()

	relayout()
	task.defer(relayout)
	root:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayout)
	local uiScale = root:FindFirstChild("SettingsScale")
	if uiScale and uiScale:IsA("UIScale") then
		uiScale:GetPropertyChangedSignal("Scale"):Connect(relayout) -- the UI size setting
	end
	local columnChanged = (Menu :: any).ColumnChanged
	if typeof(columnChanged) == "RBXScriptSignal" then
		columnChanged:Connect(relayout)
	end

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		local code = input.KeyCode
		-- position in `slots` (1 = the towel)
		local at = if code == TOWEL_KEY then 1 else (table.find(NUMBER_KEYS, code) or table.find(KEYPAD_KEYS, code) or table.find(PAD_KEYS, code))
		local slot = if at then slots[at] else nil
		if slot and slot.key ~= "" and canPress() then
			pressSlot(slot, code, true) -- down now, up when the key comes up
		elseif slot then
			useSlot(slot, true)
		end
	end)
	-- letting go (a key, the mouse anywhere, a finger anywhere: it may have slid off the slot)
	UserInputService.InputEnded:Connect(function(input)
		local kind = input.UserInputType
		if kind == Enum.UserInputType.MouseButton1 then
			releaseSource("mouse")
		elseif kind == Enum.UserInputType.Touch then
			releaseSource(input)
		else
			releaseSource(input.KeyCode)
		end
	end)
	-- the window lost focus: its key-ups won't come, so let go of everything now
	pcall(function()
		UserInputService.WindowFocusReleased:Connect(releaseAll)
	end)
	UserInputService.LastInputTypeChanged:Connect(function(inputType)
		local mode = modeFor(inputType)
		if mode and mode ~= inputMode then
			inputMode = mode
			applyHints()
		end
	end)
	ClientSettings.Changed:Connect(function(key)
		if key == "reduceMotion" then
			for _, slot in ipairs(slots) do
				if slot.active then
					Anim.stop(slot.glow, "pulse")
					Anim.scale(slot.glow).Scale = 1
					Anim.pulse(slot.glow, 1.08, 0.9)
				end
			end
		end
	end)

	-- safety re-reads (ItemClient.Changed normally does this at once)
	task.spawn(function()
		while true do
			task.wait(if signalled then POLL_SIGNALLED else POLL_UNSIGNALLED)
			refreshAll()
		end
	end)
	task.delay(SHOW_AFTER, show)
	hideBackpack()
	if itemClient then
		ItemBar.SetClient(itemClient)
	end
end

-- The bar's engine (ItemClient), once it has loaded. Until then a tap calls UseItem itself.
function ItemBar.SetClient(itemClient: any)
	if itemClient == nil or itemClient == client then
		return
	end
	client = itemClient
	for _, conn in ipairs(clientConns) do
		conn:Disconnect()
	end
	clientConns = {}
	signalled = pcall(function()
		table.insert(clientConns, itemClient.Changed:Connect(refreshKey))
	end)
	local okFailed = pcall(function()
		table.insert(clientConns, itemClient.Failed:Connect(onFailed))
	end)
	if not signalled or not okFailed then
		warn("[ItemBar] ItemClient has no Changed / Failed signal: the bar polls it instead")
	end
	if built then
		refreshAll()
	end
end

-- What an empty slot's "+" does (init.client: open the Item Shop on its Items tab).
function ItemBar.SetShopOpener(fn: () -> ())
	shopOpener = fn
end

function ItemBar.SetState(state)
	if not built or type(state) ~= "table" then
		return
	end
	local animate = gotState and shown
	gotState = true
	itemLevels = if type(state.itemLevels) == "table" then state.itemLevels else {}
	local look = if type(state.towelLook) == "string" and state.towelLook ~= "" then state.towelLook else ItemConfig.TowelLooks[1]
	if look ~= towelLook then
		towelLook = look
		local towel = slots[1]
		setPicture(towel)
		if animate then
			Anim.bump(towel.tile, 1.15)
			burst(towel, C.Gold, true)
			UISound.Play("pop")
		end
	end
	local loadout = if type(state.loadout) == "table" then state.loadout else {}
	local changed = 0
	for i = 1, SLOTS do
		local slot = slots[i + 1]
		local key = loadout[i]
		if type(key) ~= "string" or key == "Towel" or not ItemConfig.Items[key] then
			key = ""
		end
		if key ~= slot.key then
			slot.key = key
			finishCooling(slot, false)
			setActive(slot, false)
			setHeld(slot, false)
			hideCharge(slot)
			chargeWatch[slot] = nil
			setLevel(slot, levelOf(key), false) -- (repaints when the golden look changes)
			paint(slot)
			refreshSlot(slot)
			if animate then
				local delay = changed * 0.08
				changed += 1
				Anim.popIn(slot.tile, delay)
				if key ~= "" then
					task.delay(delay + 0.1, function()
						if slot.key == key then
							burst(slot, ItemConfig.Items[key].color, true)
							UISound.Play("pop", 1.1)
							showName(slot, 1.6)
						end
					end)
				end
			end
		else
			setLevel(slot, levelOf(key), animate) -- an upgrade: the pip pops in (and the golden look bursts in)
		end
	end
	show()
end

return ItemBar
