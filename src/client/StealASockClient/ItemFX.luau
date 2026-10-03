-- ItemFX: everything players see and hear from the item bar, on every client. The server says
-- what happened through the ItemFX remote (kind, data) - Items.luau lists the kinds - and this plays
-- it: the body moves and the towel's whip (ItemRig), the comic SNAP! burst with stars and a shockwave
-- (and a tiny screen shake for the snapper), the sock flying home on an arc, bubbles, slips, quacks,
-- the intruder highlight (the duck's owner only), sleepy softener clouds, static hair, dash trails.
-- The player's own uses are predicted (ItemClient calls Predict at once), so their own "swing" /
-- "use" / "dash" echoes from the server are skipped.
-- Persistent looks come from replicated attributes, polled 5 times a second for nearby characters:
-- Gliding, InBasket, SoftenedUntil, HairUpUntil, Item (a held towel droops and sways).
-- Settings (ClientSettings): Reduce motion (no screen shake, no somersaults), Low graphics (half the
-- particles, no lights), Hide others' effects (no bursts from other players farther than 30 studs),
-- Sound effects volume. Everything is pooled: no instances per frame.
-- Sounds: Roblox's own audio (creator Roblox, public domain, checked on economy.roblox.com
-- 2026-10-03), listed with their asset names in docs/ITEMS.md. "" = silent.
local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local ItemRig = require(script.Parent:WaitForChild("ItemRig"))
local ItemConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("ItemConfig"))

local ItemFX = {}

-- Settings are optional (the world must keep moving without the UI kit): defaults until it loads.
local ClientSettings: any = {
	Get = function(_key: string): any
		return nil
	end,
}
task.spawn(function()
	local module = script.Parent:WaitForChild("ClientSettings", 15)
	if module then
		local ok, loaded = pcall(require, module)
		if ok and type(loaded) == "table" then
			ClientSettings = loaded
		end
	end
end)

-- id, volume (x Sound effects), pitch. Swap any id here ("" = silent); docs/ITEMS.md has the list.
ItemFX.Sounds = {
	swing = { id = "rbxassetid://12222200", volume = 0.35, pitch = 1.1 }, -- every towel swing (swoosh.wav)
	crack = { id = "rbxassetid://12222140", volume = 0.5, pitch = 1 }, -- a towel hit on a thief (snap.wav)
	bop = { id = "rbxassetid://12222046", volume = 0.3, pitch = 1.3 }, -- a shove (hit.wav)
	boing = { id = "rbxassetid://12222124", volume = 0.25, pitch = 1 }, -- tumbling / slipping (Short spring sound.wav)
	whooshSoft = { id = "rbxassetid://15675024286", volume = 0.2, pitch = 1 }, -- the sock flies home, the glider opens (Roblox_UI_Whoosh_01)
	pop = { id = "rbxassetid://15675055424", volume = 0.3, pitch = 1.1 }, -- the sock lands home, bubbles pop, out of the basket (Roblox_UI_Cute_Pop)
	thunk = { id = "rbxassetid://12222054", volume = 0.3, pitch = 1 }, -- a peel / duck / basket set down (Kerplunk.wav)
	splat = { id = "rbxassetid://12222152", volume = 0.35, pitch = 0.9 }, -- slipping on a peel (splat.wav)
	blow = { id = "rbxassetid://17208204604", volume = 0.3, pitch = 0.8 }, -- a bubble blown (Roblox GUI - Bubble)
	blub = { id = "rbxassetid://17208204604", volume = 0.35, pitch = 0.55 }, -- a thief caught in a bubble (Roblox GUI - Bubble, low)
	quack = { id = "rbxassetid://79205036324023", volume = 0.35, pitch = 0.9 }, -- the alarm duck's squeaky quack (BirdHello_01)
	alarm = { id = "rbxassetid://12221990", volume = 0.25, pitch = 1 }, -- your duck saw someone (owner only, not positional) (electronicpingshort.wav)
	spray = { id = "rbxassetid://17208402198", volume = 0.3, pitch = 1.1 }, -- the softener spray (Roblox GUI - Spraypaint)
	zap = { id = "rbxassetid://16480558943", volume = 0.3, pitch = 1 }, -- the static balloon (Audio/Roblox_Pinball_Joystick_Buzz_Release_01)
	dash = { id = "rbxassetid://15675012262", volume = 0.3, pitch = 1 }, -- Slipper Dash (Roblox_UI_Whoosh_04)
	glideLoop = { id = "rbxassetid://15675021174", volume = 0.12, pitch = 1 }, -- wind while you glide (Roblox_UI_Loop_Air_Whooshes)
} :: { [string]: { id: string, volume: number, pitch: number } }

local SOUND_RANGE = 70 -- studs from the camera
local SOUNDS_PER_SECOND = 10
local HIDE_OTHERS_RANGE = 30
local POLL = 0.2 -- seconds between attribute polls
local CRACK_T = 0.22 -- seconds into a swing when the towel cracks (the burst waits for it)
local HELD_WAIT = ItemConfig.Items.Towel.cooldown + 0.35 -- another player's held loop stays up this long for their next crack
local FONT = Enum.Font.FredokaOne
local INK = Color3.fromRGB(40, 22, 60)
local YELLOW = Color3.fromRGB(255, 225, 60)
local SPARKLES = "rbxasset://textures/particles/sparkles_main.dds"

-- burst colours per towel look (the comic word stays yellow; stars and ring take the look)
local LOOK_COLORS: { [string]: Color3 } = {
	Plain = Color3.fromRGB(130, 200, 255),
	Striped = Color3.fromRGB(255, 110, 120),
	Beach = Color3.fromRGB(60, 210, 200),
	Spa = Color3.fromRGB(255, 170, 210),
	Sports = Color3.fromRGB(110, 220, 120),
	Champion = Color3.fromRGB(255, 205, 70),
	Royal = Color3.fromRGB(200, 140, 255),
}

local me = Players.LocalPlayer
local reduceMotion, lowGraphics, hideOthers, sfxVolume = false, false, false, 0.8
local lastSettings = -1

local holder: Part? = nil -- one invisible anchored part in the camera: sounds, bursts, emitters hang off it
local remoteConn: RBXScriptConnection? = nil

local function settingsTick()
	local t = os.clock()
	if t - lastSettings < 0.5 then
		return
	end
	lastSettings = t
	reduceMotion = ClientSettings.Get("reduceMotion") == true
	lowGraphics = ClientSettings.Get("lowGraphics") == true
	hideOthers = ClientSettings.Get("hideOthersFX") == true
	local v = ClientSettings.Get("sfxVolume")
	sfxVolume = if type(v) == "number" then math.clamp(v, 0, 1) else 0.8
	ItemRig.SetReduced(reduceMotion)
end

local function getHolder(): Part
	local h = holder
	if h and h.Parent then
		return h
	end
	local part = Instance.new("Part")
	part.Name = "ItemFX"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.CFrame = CFrame.identity
	part.Parent = workspace.CurrentCamera or workspace
	holder = part
	return part
end

local function camPos(): Vector3
	local cam = workspace.CurrentCamera
	return if cam then cam.CFrame.Position else Vector3.zero
end

local function playerOf(v: any): Player?
	if typeof(v) == "Instance" and v:IsA("Player") and v.Parent == Players then
		return v
	end
	return nil
end

local function vec(v: any): Vector3?
	return if typeof(v) == "Vector3" then v else nil
end

local function num(v: any, fallback: number): number
	return if type(v) == "number" and v == v then v else fallback
end

local function rootOf(player: Player?): BasePart?
	local character = player and player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function rootPos(player: Player?): Vector3?
	local root = rootOf(player)
	return if root then root.Position else nil
end

local function headOf(character: Model?): BasePart?
	local head = character and character:FindFirstChild("Head")
	return if head and head:IsA("BasePart") then head else nil
end

-- "Hide others' effects": only effects near you (or yours) show
local function shown(position: Vector3?, mine: boolean): boolean
	if mine or not hideOthers then
		return true
	end
	local root = rootOf(me)
	return position ~= nil and root ~= nil and (root.Position - position).Magnitude <= HIDE_OTHERS_RANGE
end

-- ---------- sounds ----------

type SoundSlot = { att: Attachment, sounds: { [string]: Sound } }
local soundSlots: { SoundSlot } = {}
local nextSlot = 0
local soundTokens = SOUNDS_PER_SECOND
local soundRefill = 0

local function takeToken(): boolean
	local t = os.clock()
	soundTokens = math.min(SOUNDS_PER_SECOND, soundTokens + (t - soundRefill) * SOUNDS_PER_SECOND)
	soundRefill = t
	if soundTokens < 1 then
		return false
	end
	soundTokens -= 1
	return true
end

-- A positional sound at a world point (pooled: 12 points, one Sound per name each).
function ItemFX.PlayAt(name: string, position: Vector3?, pitch: number?)
	local spec = ItemFX.Sounds[name]
	if not spec or spec.id == "" or not position or sfxVolume <= 0 then
		return
	end
	if (position - camPos()).Magnitude > SOUND_RANGE or not takeToken() then
		return
	end
	nextSlot = nextSlot % 12 + 1
	local slot = soundSlots[nextSlot]
	if not slot or not slot.att.Parent then
		local att = Instance.new("Attachment")
		att.Name = "Sound" .. nextSlot
		att.Parent = getHolder()
		slot = { att = att, sounds = {} }
		soundSlots[nextSlot] = slot
	end
	local s = slot.sounds[name]
	if not s then
		s = Instance.new("Sound")
		s.Name = name
		s.SoundId = spec.id
		s.RollOffMode = Enum.RollOffMode.InverseTapered
		s.RollOffMinDistance = 8
		s.RollOffMaxDistance = SOUND_RANGE
		s.Parent = slot.att
		slot.sounds[name] = s
	end
	slot.att.Position = position -- the holder sits at the origin: local = world
	local snd = s :: Sound
	snd.Volume = spec.volume * sfxVolume
	snd.PlaybackSpeed = (pitch or 1) * spec.pitch * (0.95 + math.random() * 0.1)
	snd.TimePosition = 0
	snd:Play()
end

-- A sound for this player only, not positional (the duck's alarm).
local function playFlat(name: string)
	local spec = ItemFX.Sounds[name]
	if not spec or spec.id == "" or sfxVolume <= 0 then
		return
	end
	local s = Instance.new("Sound")
	s.SoundId = spec.id
	s.Volume = spec.volume * sfxVolume
	s.PlaybackSpeed = spec.pitch
	s.Parent = SoundService
	s.Ended:Once(function()
		s:Destroy()
	end)
	Debris:AddItem(s, 5)
	s:Play()
end

-- ---------- particles ----------

local emitters: { [string]: ParticleEmitter } = {}
local emitAtt: Attachment? = nil

-- one pooled emitter per look, moved to where it bursts
local function emitter(kind: string): ParticleEmitter
	local e = emitters[kind]
	if e and e.Parent then
		return e
	end
	local att = emitAtt
	if not att or not att.Parent then
		local a = Instance.new("Attachment")
		a.Name = "Emit"
		a.Parent = getHolder()
		emitAtt = a
		att = a
	end
	local pe = Instance.new("ParticleEmitter")
	pe.Name = kind
	pe.Rate = 0
	pe.LightInfluence = 0
	pe.SpreadAngle = Vector2.new(180, 180)
	pe.Drag = 3
	if kind == "stars" then
		pe.Texture = SPARKLES
		pe.Lifetime = NumberRange.new(0.35, 0.7)
		pe.Speed = NumberRange.new(10, 20)
		pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.9), NumberSequenceKeypoint.new(1, 0) })
		pe.LightEmission = 1
		pe.RotSpeed = NumberRange.new(-300, 300)
		pe.Rotation = NumberRange.new(0, 360)
	elseif kind == "puff" then
		pe.Lifetime = NumberRange.new(0.6, 1.1)
		pe.Speed = NumberRange.new(3, 7)
		pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.2), NumberSequenceKeypoint.new(1, 2.6) })
		pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) })
		pe.LightEmission = 0.2
		pe.Acceleration = Vector3.new(0, 2, 0)
	elseif kind == "bits" then
		pe.Lifetime = NumberRange.new(0.5, 0.9)
		pe.Speed = NumberRange.new(8, 14)
		pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(1, 0.1) })
		pe.Acceleration = Vector3.new(0, -30, 0)
		pe.EmissionDirection = Enum.NormalId.Top
		pe.SpreadAngle = Vector2.new(60, 60)
		pe.RotSpeed = NumberRange.new(-200, 200)
	else -- "sparks"
		pe.Texture = SPARKLES
		pe.Lifetime = NumberRange.new(0.15, 0.35)
		pe.Speed = NumberRange.new(14, 26)
		pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 0) })
		pe.LightEmission = 1
	end
	pe.Parent = att
	emitters[kind] = pe
	return pe
end

local function emit(kind: string, position: Vector3, count: number, color: Color3?)
	local e = emitter(kind)
	local att = e.Parent
	if att and att:IsA("Attachment") then
		att.Position = position
	end
	e.Color = ColorSequence.new(color or Color3.new(1, 1, 1))
	local n = if lowGraphics then math.max(1, math.floor(count * 0.5)) else count
	e:Emit(n)
end

-- ---------- the comic burst: a word, a shockwave ring and stars ----------

type Burst = { att: Attachment, gui: BillboardGui, word: TextLabel, wordStroke: UIStroke, ring: Frame, ringStroke: UIStroke, stars: { TextLabel }, angles: { number }, t0: number, dur: number, scale: number, rot: number }
local bursts: { Burst } = {}
local activeBursts: { Burst } = {}

local function newBurst(): Burst
	local att = Instance.new("Attachment")
	att.Name = "Burst"
	att.Parent = getHolder()
	local gui = Instance.new("BillboardGui")
	gui.Name = "ItemBurst"
	gui.Adornee = att
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 150
	gui.Size = UDim2.new(4, 120, 4, 120) -- grows a little with distance, stays readable on a phone
	gui.ResetOnSpawn = false
	gui.Enabled = false
	local ring = Instance.new("Frame")
	ring.Name = "Ring"
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.BackgroundTransparency = 1
	ring.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = ring
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 5
	stroke.Color = Color3.new(1, 1, 1)
	stroke.Parent = ring
	local stars = {}
	for i = 1, 6 do
		local star = Instance.new("TextLabel")
		star.Name = "Star" .. i
		star.AnchorPoint = Vector2.new(0.5, 0.5)
		star.Size = UDim2.fromScale(0.16, 0.16)
		star.BackgroundTransparency = 1
		star.Font = FONT
		star.Text = "★"
		star.TextScaled = true
		star.TextStrokeTransparency = 0.2
		star.TextStrokeColor3 = INK
		star.Parent = gui
		table.insert(stars, star)
	end
	local word = Instance.new("TextLabel")
	word.Name = "Word"
	word.AnchorPoint = Vector2.new(0.5, 0.5)
	word.Position = UDim2.fromScale(0.5, 0.5)
	word.BackgroundTransparency = 1
	word.Font = FONT
	word.TextScaled = true
	word.TextColor3 = YELLOW
	word.Parent = gui
	local wordStroke = Instance.new("UIStroke")
	wordStroke.Thickness = 3
	wordStroke.Color = INK
	wordStroke.Parent = word
	gui.Parent = getHolder()
	return { att = att, gui = gui, word = word, wordStroke = wordStroke, ring = ring, ringStroke = stroke, stars = stars, angles = {}, t0 = 0, dur = 0.7, scale = 1, rot = 0 }
end

-- A comic word with a ring and flying stars at `position` (scale 1 = a thief snap).
function ItemFX.Burst(position: Vector3, text: string, color: Color3, scale: number, starCount: number)
	local b: Burst? = nil
	for _, candidate in ipairs(bursts) do
		if not candidate.gui.Enabled then
			b = candidate
			break
		end
	end
	if not b then
		if #bursts >= 5 then
			b = table.remove(activeBursts, 1) -- the oldest one makes room
		else
			local fresh = newBurst()
			table.insert(bursts, fresh)
			b = fresh
		end
	end
	local burst = b :: Burst
	local i = table.find(activeBursts, burst)
	if i then
		table.remove(activeBursts, i)
	end
	burst.att.Position = position
	burst.word.Text = text
	burst.word.TextColor3 = if text == "ZAP!" or text == "BLUB!" then Color3.fromRGB(150, 235, 255) else YELLOW
	burst.ringStroke.Color = color
	burst.scale = scale
	burst.rot = (math.random() - 0.5) * 24
	burst.t0 = os.clock()
	burst.dur = 0.75
	for k, star in ipairs(burst.stars) do
		star.Visible = k <= starCount
		star.TextColor3 = if k % 2 == 0 then color else YELLOW
		burst.angles[k] = (k / math.max(starCount, 1)) * math.pi * 2 + math.random() * 0.6
	end
	burst.gui.Enabled = true
	table.insert(activeBursts, burst)
	if not lowGraphics then
		emit("stars", position, math.floor(10 * scale), color)
	end
end

local function updateBursts(t: number)
	for i = #activeBursts, 1, -1 do
		local b = activeBursts[i]
		local u = (t - b.t0) / b.dur
		if u >= 1 then
			b.gui.Enabled = false
			table.remove(activeBursts, i)
		else
			local pop = if u < 0.18 then (u / 0.18) * 1.25 elseif u < 0.3 then 1.25 - (u - 0.18) / 0.12 * 0.25 else 1
			local fade = if u > 0.6 then (u - 0.6) / 0.4 else 0
			local s = b.scale
			b.word.Size = UDim2.fromScale(0.62 * s * pop, 0.3 * s * pop)
			b.word.Position = UDim2.fromScale(0.5, 0.5 - u * 0.12)
			b.word.Rotation = b.rot
			b.word.TextTransparency = fade
			b.wordStroke.Transparency = fade
			local r = (0.25 + u * 0.85) * s
			b.ring.Size = UDim2.fromScale(r, r)
			b.ringStroke.Transparency = math.min(1, u * 1.6)
			for k, star in ipairs(b.stars) do
				if star.Visible then
					local a = b.angles[k] or 0
					local d = 0.12 + u * 0.38 * s
					star.Position = UDim2.fromScale(0.5 + math.cos(a) * d, 0.5 + math.sin(a) * d)
					star.Rotation = u * 360 * (if k % 2 == 0 then 1 else -1)
					star.TextTransparency = fade
					star.TextStrokeTransparency = math.max(0.2, fade)
				end
			end
		end
	end
end

-- ---------- screen shake (the snapper's own camera; never with Reduce motion) ----------

local shakeUntil, shakeStart, shakeAmp = 0, 0, 0
local shaking = false

function ItemFX.Shake(amount: number)
	if reduceMotion then
		return
	end
	local t = os.clock()
	shakeAmp = math.max(if t < shakeUntil then shakeAmp else 0, amount)
	shakeStart = t
	shakeUntil = t + 0.2
end

local function updateShake(t: number)
	local character = me and me.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	if t < shakeUntil then
		local k = 1 - (t - shakeStart) / (shakeUntil - shakeStart)
		local a = shakeAmp * k
		humanoid.CameraOffset = Vector3.new(math.sin(t * 90) * a, math.cos(t * 77) * a * 0.6, 0)
		shaking = true
	elseif shaking then
		shaking = false
		humanoid.CameraOffset = Vector3.zero
	end
end

-- ---------- per-character extras: dizzy stars, Zzz, static hair, dash trail ----------

type Extras = {
	dizzy: BillboardGui?,
	dizzyStars: { TextLabel },
	dizzyUntil: number,
	zzz: BillboardGui?,
	zzzLabels: { TextLabel },
	spikes: { BasePart },
	trail: Trail?,
	trailUntil: number,
	highlight: Highlight?,
}
local extras: { [Model]: Extras } = {}

local function extrasOf(character: Model): Extras
	local e = extras[character]
	if not e then
		e = { dizzy = nil, dizzyStars = {}, dizzyUntil = 0, zzz = nil, zzzLabels = {}, spikes = {}, trail = nil, trailUntil = 0, highlight = nil }
		extras[character] = e
	end
	return e
end

local function headGui(character: Model, name: string, height: number): BillboardGui?
	local head = headOf(character)
	if not head then
		return nil
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = name
	gui.Adornee = head
	gui.Size = UDim2.new(2.6, 0, 1.4, 0)
	gui.StudsOffset = Vector3.new(0, height, 0)
	gui.LightInfluence = 0
	gui.MaxDistance = 90
	gui.ResetOnSpawn = false
	gui.Parent = getHolder()
	return gui
end

-- dizzy stars circling the head after a snap or a slip
local function dizzy(character: Model?, seconds: number)
	if not character then
		return
	end
	local e = extrasOf(character)
	if not e.dizzy then
		local gui = headGui(character, "ItemDizzy", 1.6)
		if not gui then
			return
		end
		for i = 1, 3 do
			local star = Instance.new("TextLabel")
			star.Name = "Star" .. i
			star.AnchorPoint = Vector2.new(0.5, 0.5)
			star.Size = UDim2.fromScale(0.28, 0.5)
			star.BackgroundTransparency = 1
			star.Font = FONT
			star.Text = "★"
			star.TextScaled = true
			star.TextColor3 = YELLOW
			star.TextStrokeColor3 = INK
			star.TextStrokeTransparency = 0.3
			star.Parent = gui
			table.insert(e.dizzyStars, star)
		end
		e.dizzy = gui
	end
	e.dizzyUntil = math.max(e.dizzyUntil, os.clock() + seconds)
	local gui = e.dizzy :: BillboardGui
	gui.Enabled = true
end

local function setZzz(character: Model, on: boolean)
	local e = extrasOf(character)
	if on and not e.zzz then
		local gui = headGui(character, "ItemZzz", 2)
		if not gui then
			return
		end
		for i, text in ipairs({ "z", "Z", "z" }) do
			local z = Instance.new("TextLabel")
			z.Name = "Z" .. i
			z.AnchorPoint = Vector2.new(0.5, 0.5)
			z.Size = UDim2.fromScale(0.25 + i * 0.05, 0.45)
			z.BackgroundTransparency = 1
			z.Font = FONT
			z.Text = text
			z.TextScaled = true
			z.TextColor3 = Color3.fromRGB(235, 200, 255)
			z.TextStrokeColor3 = INK
			z.TextStrokeTransparency = 0.4
			z.Parent = gui
			table.insert(e.zzzLabels, z)
		end
		e.zzz = gui
	elseif not on and e.zzz then
		e.zzz:Destroy()
		e.zzz = nil
		e.zzzLabels = {}
	end
end

local function setSpikes(character: Model, on: boolean)
	local e = extrasOf(character)
	if on and #e.spikes == 0 then
		for i = 1, 7 do
			local spike = Instance.new("Part")
			spike.Name = "StaticHair" .. i
			spike.Anchored = true
			spike.CanCollide = false
			spike.CanQuery = false
			spike.CanTouch = false
			spike.CastShadow = false
			spike.Material = Enum.Material.Neon
			spike.Color = if i % 2 == 0 then Color3.fromRGB(255, 240, 150) else Color3.fromRGB(190, 240, 255)
			spike.Size = Vector3.new(0.08, 0.75, 0.08)
			spike.Parent = getHolder()
			table.insert(e.spikes, spike)
		end
	elseif not on and #e.spikes > 0 then
		for _, spike in ipairs(e.spikes) do
			spike:Destroy()
		end
		e.spikes = {}
	end
end

-- the Slipper Dash's trail and dust (also predicted for your own dash)
function ItemFX.DashFX(player: Player)
	local character = player.Character
	local root = rootOf(player)
	if not character or not root then
		return
	end
	ItemRig.Play(character, "dash")
	ItemFX.PlayAt("dash", root.Position)
	if not shown(root.Position, player == me) then
		return
	end
	local e = extrasOf(character)
	if not e.trail or not e.trail.Parent then
		local a0 = Instance.new("Attachment")
		a0.Name = "ItemTrailTop"
		a0.Position = Vector3.new(0, 1.2, 0)
		a0.Parent = root
		local a1 = Instance.new("Attachment")
		a1.Name = "ItemTrailBottom"
		a1.Position = Vector3.new(0, -1.6, 0)
		a1.Parent = root
		local trail = Instance.new("Trail")
		trail.Name = "ItemDashTrail"
		trail.Attachment0 = a0
		trail.Attachment1 = a1
		trail.Lifetime = 0.25
		trail.LightEmission = 0.6
		trail.Color = ColorSequence.new(Color3.fromRGB(205, 180, 255), Color3.fromRGB(255, 255, 255))
		trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1) })
		trail.Enabled = false
		trail.Parent = root
		e.trail = trail
	end
	local trail = e.trail :: Trail
	trail.Enabled = true
	e.trailUntil = os.clock() + 0.4
	emit("puff", root.Position - Vector3.new(0, 2.6, 0), 10, Color3.fromRGB(235, 225, 255))
end

local function releaseExtras(character: Model)
	local e = extras[character]
	if not e then
		return
	end
	if e.dizzy then
		e.dizzy:Destroy()
	end
	if e.zzz then
		e.zzz:Destroy()
	end
	for _, spike in ipairs(e.spikes) do
		spike:Destroy()
	end
	if e.highlight then
		e.highlight:Destroy()
	end
	extras[character] = nil
end

local function updateExtras(t: number)
	for character, e in pairs(extras) do
		if character.Parent == nil then
			releaseExtras(character)
		else
			if e.dizzy then
				if t >= e.dizzyUntil then
					e.dizzy.Enabled = false
				else
					for i, star in ipairs(e.dizzyStars) do
						local a = t * 7 + i * (math.pi * 2 / 3)
						star.Position = UDim2.fromScale(0.5 + math.cos(a) * 0.38, 0.5 + math.sin(a) * 0.18)
					end
				end
			end
			for i, z in ipairs(e.zzzLabels) do
				local u = (t * 0.6 + i / 3) % 1
				z.Position = UDim2.fromScale(0.35 + u * 0.4, 0.9 - u * 0.8)
				z.TextTransparency = u
			end
			if #e.spikes > 0 then
				local head = headOf(character)
				if head then
					for i, spike in ipairs(e.spikes) do
						local a = (i - 4) * 0.32
						local jitter = math.sin(t * 50 + i * 2) * 0.12
						spike.CFrame = head.CFrame * CFrame.Angles(0, i * 0.9, a + jitter) * CFrame.new(0, head.Size.Y * 0.5 + 0.35, 0)
					end
				end
			end
			if e.trail and t >= e.trailUntil and e.trail.Enabled then
				e.trail.Enabled = false
			end
		end
	end
end

-- ---------- the sock flying home on an arc ----------

type Ghost = { model: Model?, ball: Part?, rot: CFrame, from: Vector3, to: Vector3, height: number, t0: number, dur: number, real: Model?, hidden: { [Instance]: any }, color: Color3 }
local ghosts: { Ghost } = {}

local function findSock(uid: number): Model?
	for _, model in ipairs(CollectionService:GetTagged("Sock")) do
		if model:IsA("Model") and model:GetAttribute("Uid") == uid then
			return model
		end
	end
	return nil
end

-- a look-alike of the sock: visible parts only, anchored, local
local function ghostOf(real: Model): Model?
	local ok, copy = pcall(function()
		return real:Clone()
	end)
	if not ok or not copy then
		return nil
	end
	for _, d in ipairs(copy:GetDescendants()) do
		if d:IsA("ProximityPrompt") or d:IsA("BillboardGui") or d:IsA("Sound") or d:IsA("ParticleEmitter") or d:IsA("Highlight") or d:IsA("Beam") or d:IsA("Light") or d:IsA("LuaSourceContainer") or d.Name == "CarryWeld" then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		end
	end
	copy.Name = "ItemGhost"
	CollectionService:RemoveTag(copy, "Sock")
	return copy
end

local function arcHome(from: Vector3, to: Vector3, color: Color3, uid: number?)
	local dist = (to - from).Magnitude
	local g: Ghost = { model = nil, ball = nil, rot = CFrame.identity, from = from, to = to, height = 5 + dist * 0.22, t0 = os.clock(), dur = math.clamp(dist / 45, 0.45, 0.9), real = nil, hidden = {}, color = color }
	local real = if uid then findSock(uid) else nil
	local copy = if real then ghostOf(real) else nil
	if real and copy then
		-- the real sock waits, hidden, in its slot while its copy flies there
		for _, d in ipairs(real:GetDescendants()) do
			if d:IsA("BasePart") then
				g.hidden[d] = d.LocalTransparencyModifier
				d.LocalTransparencyModifier = 1
			elseif d:IsA("BillboardGui") and d.Enabled then
				g.hidden[d] = true
				d.Enabled = false
			end
		end
		g.real = real
		g.rot = copy:GetPivot().Rotation
		copy:PivotTo(CFrame.new(from) * g.rot)
		copy.Parent = workspace.CurrentCamera
		g.model = copy
	else
		local ball = Instance.new("Part")
		ball.Name = "ItemGhostBall"
		ball.Shape = Enum.PartType.Ball
		ball.Size = Vector3.new(1.4, 1.4, 1.4)
		ball.Material = Enum.Material.Neon
		ball.Color = color
		ball.Anchored = true
		ball.CanCollide = false
		ball.CanQuery = false
		ball.CanTouch = false
		ball.CFrame = CFrame.new(from)
		ball.Parent = workspace.CurrentCamera
		g.ball = ball
	end
	table.insert(ghosts, g)
	ItemFX.PlayAt("whooshSoft", from)
end

local function land(g: Ghost)
	if g.model then
		g.model:Destroy()
	end
	if g.ball then
		g.ball:Destroy()
	end
	for inst, value in pairs(g.hidden) do
		if inst.Parent then
			if inst:IsA("BasePart") then
				inst.LocalTransparencyModifier = value
			elseif inst:IsA("BillboardGui") then
				inst.Enabled = true
			end
		end
	end
	ItemFX.PlayAt("pop", g.to)
	emit("stars", g.to, 12, g.color)
end

local function updateGhosts(t: number)
	for i = #ghosts, 1, -1 do
		local g = ghosts[i]
		local u = (t - g.t0) / g.dur
		if u >= 1 or (g.real and g.real.Parent == nil) then
			table.remove(ghosts, i)
			land(g)
		else
			local p = g.from:Lerp(g.to, u) + Vector3.new(0, g.height * 4 * u * (1 - u), 0)
			local spin = CFrame.Angles(0, u * math.pi * 3, math.sin(u * math.pi) * 0.6)
			if g.model then
				g.model:PivotTo(CFrame.new(p) * spin * g.rot)
			elseif g.ball then
				g.ball.CFrame = CFrame.new(p)
			end
			if not lowGraphics and math.random() < 0.5 then
				emit("sparks", p, 1, g.color)
			end
		end
	end
end

-- ---------- bubbles (each client flies its own copy; the server decides the hits) ----------

type BubbleFX = { part: Part, from: Vector3, dir: Vector3, speed: number, range: number, t0: number }
local bubbles: { [number]: BubbleFX } = {}
local spareBubbles: { Part } = {}

local function bubblePart(): Part
	local p = table.remove(spareBubbles)
	if p then
		return p
	end
	local part = Instance.new("Part")
	part.Name = "ItemBubble"
	part.Shape = Enum.PartType.Ball
	part.Material = Enum.Material.Glass
	part.Color = Color3.fromRGB(190, 235, 255)
	part.Transparency = 0.45
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	return part
end

local function removeBubble(id: number)
	local b = bubbles[id]
	if b then
		bubbles[id] = nil
		b.part.Parent = nil
		table.insert(spareBubbles, b.part)
	end
end

local function updateBubbles(t: number)
	for id, b in pairs(bubbles) do
		local age = t - b.t0
		local travelled = age * b.speed
		if travelled > b.range + 2 then
			removeBubble(id)
		else
			local wob = 1 + math.sin(age * 18) * 0.06
			local pos = b.from + b.dir * travelled + Vector3.new(0, math.sin(age * 6) * 0.3, 0)
			b.part.Size = Vector3.new(5 * wob, 5 / wob, 5 * wob)
			b.part.CFrame = CFrame.new(pos)
		end
	end
end

-- ---------- the Static Balloon's ring along the floor ----------

local rings: { { part: Part, t0: number, radius: number } } = {}

local function updateRings(t: number)
	for i = #rings, 1, -1 do
		local r = rings[i]
		local u = (t - r.t0) / 0.35
		if u >= 1 or not r.part.Parent then
			table.remove(rings, i)
			r.part:Destroy()
		else
			local d = 2 + (r.radius * 2 - 2) * u
			r.part.Size = Vector3.new(0.2, d, d)
			r.part.Transparency = 0.4 + 0.6 * u
		end
	end
end

-- ---------- the remote's kinds ----------

local USE_POSE: { [string]: string } = { BananaPeel = "place", DuckAlarm = "place", BubbleBlaster = "shoot", SoftenerCloud = "spray", StaticBalloon = "zap" }
local lastSwing: { [Player]: number } = {}

local HANDLERS: { [string]: (data: { [string]: any }) -> () } = {}

HANDLERS.swing = function(data)
	local p = playerOf(data.player)
	if not p or p == me then
		return -- your own swing was predicted the moment you pressed
	end
	lastSwing[p] = os.clock()
	-- a held swing: the towel goes back up over the shoulder for the next crack, which should come
	-- one cooldown later; if it doesn't (they let go), it drops a moment after that
	ItemRig.SetWhipHold(p.Character, data.held == true, HELD_WAIT)
	ItemRig.Play(p.Character, "swing")
	ItemFX.PlayAt("swing", rootPos(p))
end

HANDLERS.snap = function(data)
	local position = vec(data.position)
	if not position then
		return
	end
	local by = playerOf(data.by)
	local target = playerOf(data.target)
	local thief = data.thief == true
	local look = if type(data.look) == "string" then data.look else "Plain"
	-- wait for the towel to crack (the swing started a moment ago)
	local since = if by then os.clock() - (lastSwing[by] or 0) else 1
	local delay = math.clamp(CRACK_T - since, 0, CRACK_T)
	task.delay(delay, function()
		ItemFX.PlayAt(if thief then "crack" else "bop", position)
		if shown(position, by == me or target == me) then
			ItemFX.Burst(position + Vector3.new(0, 1.5, 0), if thief then "SNAP!" else "BOP!", LOOK_COLORS[look] or LOOK_COLORS.Plain, if thief then 1 else 0.7, if thief then 6 else 3)
		end
		if by == me then
			ItemFX.Shake(if thief then 0.35 else 0.18)
		end
	end)
end

HANDLERS.tumble = function(data)
	local p = playerOf(data.player)
	if not p then
		return
	end
	local soft = data.soft == true
	local seconds = num(data.seconds, 0.6)
	ItemRig.Play(p.Character, "tumble", { dir = vec(data.dir), seconds = seconds, soft = soft })
	ItemFX.PlayAt("boing", rootPos(p), if soft then 1.25 else 1)
	if not soft then
		dizzy(p.Character, seconds + 0.5)
	end
end

HANDLERS.sockhome = function(data)
	local from, to = vec(data.from), vec(data.to)
	if from and to then
		arcHome(from, to, if typeof(data.color) == "Color3" then data.color else YELLOW, if type(data.uid) == "number" then data.uid else nil)
	end
end

HANDLERS.use = function(data)
	local p = playerOf(data.player)
	local key = data.key
	if not p or type(key) ~= "string" then
		return
	end
	local position = vec(data.position) or rootPos(p)
	if key == "LaundryBasket" then
		if data.out then
			ItemFX.PlayAt("pop", position, 0.9)
			if position and shown(position, p == me) then
				emit("puff", position, 14, Color3.fromRGB(255, 255, 255))
			end
		else
			ItemFX.PlayAt("thunk", position, 0.8)
		end
		return
	end
	if key == "Glider" then
		ItemFX.PlayAt("whooshSoft", position, 1.2)
		return
	end
	if p ~= me then
		local pose = USE_POSE[key]
		if pose and pose ~= "spray" and pose ~= "zap" then -- those two come with their own kinds
			ItemRig.Play(p.Character, pose)
		end
		if key == "BubbleBlaster" then
			ItemFX.PlayAt("blow", position)
		end
	end
	if (key == "BananaPeel" or key == "DuckAlarm") and vec(data.position) then
		ItemFX.PlayAt("thunk", position)
		if position and shown(position, p == me) then
			emit("puff", position, 6, Color3.fromRGB(255, 250, 230))
		end
	end
end

HANDLERS.dash = function(data)
	local p = playerOf(data.player)
	if p and p ~= me then
		ItemFX.DashFX(p)
	end
end

HANDLERS.slip = function(data)
	local p = playerOf(data.player)
	if not p then
		return
	end
	local position = vec(data.position) or rootPos(p)
	local seconds = num(data.seconds, 1.2)
	ItemRig.Play(p.Character, "slip", { seconds = seconds })
	ItemFX.PlayAt("splat", position)
	ItemFX.PlayAt("boing", position, 0.8)
	dizzy(p.Character, seconds)
	if position and shown(position, p == me) then
		ItemFX.Burst(position + Vector3.new(0, 3, 0), "WHOA!", Color3.fromRGB(255, 214, 80), 0.8, 4)
		emit("bits", position, 10, Color3.fromRGB(255, 220, 70))
	end
	if p == me then
		ItemFX.Shake(0.2)
	end
end

HANDLERS.bubble = function(data)
	local id, from, dir = data.id, vec(data.from), vec(data.dir)
	if type(id) ~= "number" or not from or not dir then
		return
	end
	if playerOf(data.by) ~= me then
		ItemFX.PlayAt("blow", from)
	end
	if not shown(from, playerOf(data.by) == me) then
		return
	end
	removeBubble(id)
	local part = bubblePart()
	part.CFrame = CFrame.new(from)
	part.Size = Vector3.new(5, 5, 5)
	part.Parent = workspace.CurrentCamera
	bubbles[id] = { part = part, from = from, dir = dir, speed = num(data.speed, 40), range = num(data.range, 40), t0 = os.clock() }
end

HANDLERS.bubblepop = function(data)
	local position = vec(data.position)
	if type(data.id) == "number" then
		removeBubble(data.id)
	end
	if position then
		ItemFX.PlayAt("pop", position, 1.3)
		if shown(position, false) then
			emit("sparks", position, 14, Color3.fromRGB(190, 235, 255))
		end
	end
end

HANDLERS.encase = function(data)
	local p = playerOf(data.player)
	if not p then
		return
	end
	local seconds = num(data.seconds, 2)
	ItemRig.Play(p.Character, "float", { seconds = seconds })
	local position = rootPos(p)
	ItemFX.PlayAt("blub", position)
	if position and shown(position, p == me) then
		ItemFX.Burst(position + Vector3.new(0, 4, 0), "BLUB!", Color3.fromRGB(150, 235, 255), 0.75, 0)
	end
end

-- the duck's siren light blinks for a second (its _Glow parts)
local flashes: { [BasePart]: number } = {}

local function flashDuck(owner: Player?)
	local root = workspace:FindFirstChild("StealASock")
	local folder = root and root:FindFirstChild("Items")
	local duck = owner and folder and folder:FindFirstChild("AlarmDuck_" .. owner.UserId)
	if not duck then
		return
	end
	for _, d in ipairs(duck:GetDescendants()) do
		if d:IsA("BasePart") and string.sub(d.Name, -5) == "_Glow" then
			flashes[d] = os.clock() + 1
		end
	end
end

local function updateFlashes(t: number)
	for part, untilTime in pairs(flashes) do
		if t >= untilTime or not part.Parent then
			flashes[part] = nil
			part.LocalTransparencyModifier = 0
		else
			part.LocalTransparencyModifier = if math.floor((untilTime - t) / 0.12) % 2 == 0 then 0.7 else 0
		end
	end
end

HANDLERS.quack = function(data)
	local position = vec(data.position)
	if not position then
		return
	end
	local owner = playerOf(data.owner)
	ItemFX.PlayAt("quack", position)
	if shown(position, owner == me) then
		ItemFX.Burst(position + Vector3.new(0, 3, 0), "QUACK!", Color3.fromRGB(255, 120, 90), 0.7, 3)
	end
	flashDuck(owner)
end

-- the duck's owner sees the intruder glow red for a few seconds
HANDLERS.intruder = function(data)
	local p = playerOf(data.player)
	local character = p and p.Character
	if not character then
		return
	end
	local e = extrasOf(character)
	if e.highlight then
		e.highlight:Destroy()
	end
	local h = Instance.new("Highlight")
	h.Name = "ItemIntruder"
	h.FillColor = Color3.fromRGB(255, 70, 70)
	h.FillTransparency = 0.6
	h.OutlineColor = Color3.fromRGB(255, 60, 60)
	h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	h.Adornee = character
	h.Parent = character
	e.highlight = h
	Debris:AddItem(h, num(data.seconds, 6))
	playFlat("alarm")
	task.delay(0.25, playFlat, "alarm")
end

HANDLERS.spray = function(data)
	local p = playerOf(data.player)
	local position = vec(data.position)
	if not p or not position then
		return
	end
	if p ~= me then
		ItemRig.Play(p.Character, "spray")
		ItemFX.PlayAt("spray", rootPos(p))
	end
	if not shown(position, p == me) then
		return
	end
	local radius = num(data.radius, 8)
	local pink = Color3.fromRGB(255, 190, 230)
	emit("puff", position + Vector3.new(0, 1.5, 0), math.floor(10 + radius * 2), pink)
	local from = rootPos(p)
	if from then
		-- a mist from the bottle to the cloud
		for k = 1, 4 do
			emit("puff", from:Lerp(position, k / 5) + Vector3.new(0, 1.5 - k * 0.3, 0), 3, pink)
		end
	end
end

HANDLERS.zap = function(data)
	local p = playerOf(data.player)
	local position = vec(data.position)
	if not p or not position then
		return
	end
	if p ~= me then
		ItemRig.Play(p.Character, "zap")
	end
	ItemFX.PlayAt("zap", position)
	if not shown(position, p == me) then
		return
	end
	local radius = num(data.radius, 12)
	ItemFX.Burst(position + Vector3.new(0, 4, 0), "ZAP!", Color3.fromRGB(150, 235, 255), 0.9, 5)
	-- a quick electric ring along the floor
	local ring = Instance.new("Part")
	ring.Name = "ItemZapRing"
	ring.Shape = Enum.PartType.Cylinder
	ring.Material = Enum.Material.Neon
	ring.Color = Color3.fromRGB(170, 240, 255)
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Transparency = 0.4
	ring.Size = Vector3.new(0.2, 2, 2)
	ring.CFrame = CFrame.new(position - Vector3.new(0, 2.6, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	ring.Parent = workspace.CurrentCamera
	table.insert(rings, { part = ring, t0 = os.clock(), radius = radius })
	for _ = 1, if lowGraphics then 4 else 8 do
		local a = math.random() * math.pi * 2
		local r = math.random() * radius
		emit("sparks", position + Vector3.new(math.cos(a) * r, -1.5, math.sin(a) * r), 3, Color3.fromRGB(200, 245, 255))
	end
end

-- ---------- polling the attributes (5 times a second) ----------

local gliding = false
local glideSound: Sound? = nil

local function setGlideSound(on: boolean)
	if on and not glideSound then
		local spec = ItemFX.Sounds.glideLoop
		if spec.id == "" then
			return
		end
		local s = Instance.new("Sound")
		s.Name = "ItemGlideWind"
		s.SoundId = spec.id
		s.Looped = true
		s.Volume = spec.volume * sfxVolume
		s.Parent = SoundService
		s:Play()
		glideSound = s
	elseif not on and glideSound then
		glideSound:Destroy()
		glideSound = nil
	end
end

-- The towels have no outline mesh (Roblox's moderation misread the old one's bare silhouette), so
-- their cartoon ink line is a Highlight, on the towels held nearest the camera only (Highlights are
-- limited, and the socks may use some).
local TOWEL_INK = Color3.fromRGB(42, 24, 56) -- the kit's ink colour
local TOWEL_INK_RANGE = 70
local TOWEL_INK_MAX = 6 -- 3 with Low graphics (Roblox draws 31 Highlights at most; Part socks may use 22)
local towelInk: { [Instance]: Highlight } = {}

local function updateTowelInk(cam: Vector3)
	local held = {}
	for _, p in ipairs(Players:GetPlayers()) do
		local character = p.Character
		local tool = character and character:FindFirstChild("Item_Towel")
		local r = rootOf(p)
		if tool and r then
			local d = (r.Position - cam).Magnitude
			if d <= TOWEL_INK_RANGE then
				table.insert(held, { tool = tool, d = d })
			end
		end
	end
	table.sort(held, function(a, b)
		return a.d < b.d
	end)
	local keep = {}
	for i = 1, math.min(#held, if lowGraphics then math.floor(TOWEL_INK_MAX / 2) else TOWEL_INK_MAX) do
		keep[held[i].tool] = true
	end
	for tool, h in pairs(towelInk) do
		if not keep[tool] or tool.Parent == nil then
			h:Destroy()
			towelInk[tool] = nil
		end
	end
	for tool in pairs(keep) do
		if not towelInk[tool] then
			local h = Instance.new("Highlight")
			h.Name = "TowelInk"
			h.FillTransparency = 1
			h.OutlineColor = TOWEL_INK
			h.OutlineTransparency = 0
			h.DepthMode = Enum.HighlightDepthMode.Occluded
			h.Adornee = tool
			h.Parent = tool
			towelInk[tool] = h
		end
	end
end

local function poll()
	local now = workspace:GetServerTimeNow()
	local cam = camPos()
	updateTowelInk(cam)
	local root = workspace:FindFirstChild("StealASock")
	local itemFolder = root and root:FindFirstChild("Items")
	for _, p in ipairs(Players:GetPlayers()) do
		local character = p.Character
		local r = rootOf(p)
		if character and r and (r.Position - cam).Magnitude <= 160 then
			ItemRig.Play(character, "glide", { on = character:GetAttribute("Gliding") == true })
			local soft = character:GetAttribute("SoftenedUntil")
			local sleepy = type(soft) == "number" and soft > now
			ItemRig.Play(character, "sleepy", { on = sleepy })
			setZzz(character, sleepy and shown(r.Position, p == me))
			local hair = character:GetAttribute("HairUpUntil")
			local static = type(hair) == "number" and hair > now
			ItemRig.Play(character, "static", { on = static })
			setSpikes(character, static and (r.Position - cam).Magnitude <= 80)
			local basket: Motor6D? = nil
			if character:GetAttribute("InBasket") == true and itemFolder then
				local model = itemFolder:FindFirstChild("Basket_" .. p.UserId)
				local joint = model and model:FindFirstChild("BasketJoint", true)
				basket = if joint and joint:IsA("Motor6D") then joint else nil
			end
			if basket or character:GetAttribute("Item") == "Towel" then
				ItemRig.Watch(character, basket)
			end
		end
	end
	local mine = me and me.Character
	local nowGliding = mine ~= nil and mine:GetAttribute("Gliding") == true
	if nowGliding ~= gliding then
		gliding = nowGliding
		setGlideSound(gliding)
	end
end

-- ---------- API ----------

-- Your towel button is held down (ItemClient repeats the snap): the towel loops overhead cracks.
function ItemFX.SetHold(on: boolean)
	local character = me and me.Character
	if character then
		ItemRig.SetWhipHold(character, on)
	end
end

-- The player's own use, the moment they press (ItemClient). Shows what will happen right away.
function ItemFX.Predict(key: string)
	local character = me and me.Character
	if not character then
		return
	end
	local position = rootPos(me)
	if key == "Towel" then
		lastSwing[me] = os.clock()
		ItemRig.Play(character, "swing")
		ItemFX.PlayAt("swing", position)
	elseif key == "SlipperDash" then
		ItemFX.DashFX(me)
	elseif key == "BubbleBlaster" then
		ItemRig.Play(character, "shoot")
		ItemFX.PlayAt("blow", position)
	elseif key == "SoftenerCloud" then
		ItemRig.Play(character, "spray")
		ItemFX.PlayAt("spray", position)
	else
		local pose = USE_POSE[key]
		if pose then
			ItemRig.Play(character, pose)
		end
	end
end

-- Handles one ItemFX remote message (also what the tests call).
function ItemFX.Handle(kind: any, data: any)
	if type(kind) ~= "string" or type(data) ~= "table" then
		return
	end
	local handler = HANDLERS[kind]
	if handler then
		settingsTick()
		handler(data)
	end
end

-- Counts for the tests: { bursts, ghosts, bubbles, rigs }
function ItemFX.Counts(): { [string]: number }
	local n = 0
	for _ in pairs(bubbles) do
		n += 1
	end
	return { bursts = #activeBursts, ghosts = #ghosts, bubbles = n, rigs = ItemRig.Count() }
end

local started = false
local lastPoll = 0

-- Starts listening (ItemClient calls it once).
function ItemFX.Start()
	if started then
		return
	end
	started = true
	ItemRig.Start()
	RunService.RenderStepped:Connect(function()
		local ok, err = pcall(function()
			local t = os.clock()
			settingsTick()
			updateBursts(t)
			updateGhosts(t)
			updateBubbles(t)
			updateRings(t)
			updateFlashes(t)
			updateExtras(t)
			updateShake(t)
			if t - lastPoll >= POLL then
				lastPoll = t
				poll()
			end
		end)
		if not ok then
			warn("[ItemFX] " .. tostring(err))
		end
	end)
	Players.PlayerRemoving:Connect(function(p)
		lastSwing[p] = nil
		if p.Character then
			releaseExtras(p.Character)
		end
	end)
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("Remotes", 30)
		local remote = remotes and remotes:WaitForChild("ItemFX", 30)
		if remote and remote:IsA("RemoteEvent") then
			remoteConn = remote.OnClientEvent:Connect(function(kind, data)
				local ok, err = pcall(ItemFX.Handle, kind, data)
				if not ok then
					warn("[ItemFX] " .. tostring(kind) .. " failed: " .. tostring(err))
				end
			end)
		else
			warn("[ItemFX] no ItemFX remote - item effects are off")
		end
	end)
end

function ItemFX.Connected(): boolean
	return remoteConn ~= nil
end

return ItemFX
