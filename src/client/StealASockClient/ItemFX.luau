-- ItemFX: everything players see and hear from the item bar, on every client. The server says
-- what happened through the ItemFX remote (kind, data) - Items.luau lists the kinds - and this plays
-- it: the body moves and the towel's whip (ItemRig), the comic SNAP! burst with stars and a shockwave
-- (and a tiny screen shake for the snapper), the sock flying home on an arc, bubbles, slips, quacks,
-- the intruder highlight (the duck's owner only), sleepy softener clouds, static hair, dash trails.
-- Items v2 adds: the towel's bigger crack (a ring shockwave on the floor, cloth-fibre sparks, a
-- hit-stop and a camera kick on a thief), a crack effect per towel look (Plain water droplets,
-- Striped red / blue streamers, Beach sand, Spa soap bubbles, Sports confetti, Champion gold stars,
-- Royal a gold sparkle trail on the swing and tiny crowns), the combo finisher (a bigger swing and a
-- SUPER SNAP!), every twist's effect (bump, bowl, bubble bounces and splashes, honks, the owner-only
-- reveal, naps, slams, pounces, charged and chained zaps), the item models' moving parts and the
-- golden sparkle auras (ItemBones), the big moments (ItemMoments) and an upgrade sparkle.
-- The player's own uses are predicted (ItemClient calls Predict at once), so their own "swing" /
-- "use" / "dash" echoes from the server are skipped.
-- Persistent looks come from replicated attributes, polled 5 times a second for nearby characters:
-- Gliding, InBasket, SoftenedUntil, HairUpUntil, ChargeStart (rubbing the balloon), Napping, Item
-- (a held towel droops and sways; a held item's bones move); tools and world objects carry Level /
-- Gold (golden: an aura, and their effects turn gold).
-- Settings (ClientSettings): Reduce motion (no screen shake, no somersaults, big moments are a flash),
-- Low graphics (half the particles and auras), Hide others' effects (no bursts from other players
-- farther than 30 studs), Sound effects volume. Everything is pooled: no instances per frame.
-- Sounds: Roblox's own audio (creator Roblox, public domain, checked on economy.roblox.com
-- 2026-10-03 / 2026-10-04), listed with their asset names in docs/ITEMS.md. "" = silent.
local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local ItemRig = require(script.Parent:WaitForChild("ItemRig"))
local ItemConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("ItemConfig"))

-- The helpers are optional: one that is missing or broken only loses its own effects. (They sit
-- next to this module, so they're there when it runs: no waiting.)
local function optional(name: string): any
	local module = script.Parent:FindFirstChild(name)
	if module then
		local ok, loaded = pcall(require, module)
		if ok and type(loaded) == "table" then
			return loaded
		end
		warn("[ItemFX] " .. name .. " failed to load: " .. tostring(loaded))
	end
	return nil
end
local ItemBones: any = optional("ItemBones")
local ItemMoments: any = optional("ItemMoments")

local ItemFX = {}

-- Set by ItemClient: called with (combo, finisher) when the server counts your towel combo.
ItemFX.OnMyCombo = nil :: ((number, boolean) -> ())?

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
	slam = { id = "rbxassetid://16480557599", volume = 0.35, pitch = 1 }, -- the glide slam's shockwave (Audio/Roblox_Pinball_Joystick_Slam_01)
	bump = { id = "rbxassetid://16480574637", volume = 0.3, pitch = 1 }, -- a dash bump (Audio/Roblox_Pinball_Bumper_Full_01)
	slide = { id = "rbxassetid://16480576404", volume = 0.3, pitch = 1 }, -- bowled along by a slipping peel (Audio/Roblox_Pinball_Ball_Plastic_Slide_01)
	charge = { id = "rbxassetid://16480578169", volume = 0.18, pitch = 1 }, -- rubbing the Static Balloon (Audio/Roblox_Pinball_8Bit_Riser_01)
	honk = { id = "rbxassetid://99631809815420", volume = 0.35, pitch = 0.75 }, -- the guard duck's honk (BirdHello_02, lowered)
	sparkle = { id = "rbxassetid://17208327798", volume = 0.25, pitch = 1 }, -- an item upgraded / turned golden (Roblox GUI - Aura)
	nap = { id = "rbxassetid://15675081158", volume = 0.25, pitch = 0.8 }, -- a thief nods off in the cloud (Roblox_UI_Cute_Goodbye, lowered)
	whooshDeep = { id = "rbxassetid://15675028888", volume = 0.3, pitch = 0.55 }, -- a big moment's slow-motion whoosh (Roblox_UI_Whoosh_02, low)
	bounce = { id = "rbxassetid://16480568821", volume = 0.25, pitch = 1.2 }, -- a bubble bounces off a wall (Audio/Roblox_Pinball_Bumper_Soft_Click_01)
	stinger = { id = "rbxassetid://15675043410", volume = 0.2, pitch = 1 }, -- the towel's combo finisher (Roblox_UI_Tonal_Stinger)
} :: { [string]: { id: string, volume: number, pitch: number } }

local SOUND_RANGE = 70 -- studs from the camera
local SOUNDS_PER_SECOND = 10
local HIDE_OTHERS_RANGE = 30
local POLL = 0.2 -- seconds between attribute polls
local CRACK_T = 0.22 -- seconds into a swing when the towel cracks (the burst waits for it)
local CRACK_FINISHER = 0.32 -- the same for the combo finisher (ItemRig's CRACK_F)
local HELD_WAIT = ItemConfig.Items.Towel.cooldown + 0.35 -- another player's held loop stays up this long for their next crack
local PROP_RANGE = 80 -- studs: items in hands / on the floor move their parts and sparkle this close
local FONT = Enum.Font.FredokaOne
local INK = Color3.fromRGB(40, 22, 60)
local YELLOW = Color3.fromRGB(255, 225, 60)
local GOLD = Color3.fromRGB(255, 205, 70)
local ZAP_BLUE = Color3.fromRGB(150, 235, 255)
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
local fxClock = os.clock() -- the effects' own time: real time, slowed by big moments
local fxScale = 1

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
	if ItemBones then
		ItemBones.SetLow(lowGraphics)
	end
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

-- Is that player's item golden (its upgrade level, the player attribute Lv_<key>)?
local function goldOf(player: Player?, key: string): boolean
	local level = player and player:GetAttribute("Lv_" .. key)
	return type(level) == "number" and ItemConfig.IsGold(level)
end

-- The floor under a point (a few studs down), else the point itself.
local floorParams: RaycastParams? = nil
local function groundAt(position: Vector3): Vector3
	local params = floorParams
	if not params then
		params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { workspace.CurrentCamera }
		floorParams = params
	end
	local hit = workspace:Raycast(position + Vector3.new(0, 1, 0), Vector3.new(0, -7, 0), params)
	return if hit then hit.Position + Vector3.new(0, 0.08, 0) else position
end

local function itemFolder(): Instance?
	local root = workspace:FindFirstChild("StealASock")
	return root and root:FindFirstChild("Items")
end

-- A player's held item model (the tool's "Visual") and its Handle.
local function heldVisual(player: Player?, key: string): (Model?, BasePart?)
	local character = player and player.Character
	local tool = character and character:FindFirstChild("Item_" .. key)
	local visual = tool and tool:FindFirstChild("Visual")
	local handle = tool and tool:FindFirstChild("Handle")
	return if visual and visual:IsA("Model") then visual else nil, if handle and handle:IsA("BasePart") then handle else nil
end

-- The nearest world object called `prefix`_... to a point (peels and ducks have no id in the FX).
local function worldNear(prefix: string, position: Vector3, within: number): Model?
	local folder = itemFolder()
	if not folder then
		return nil
	end
	local best, bestD = nil, within
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("Model") and string.sub(child.Name, 1, #prefix + 1) == prefix .. "_" then
			local d = (child:GetPivot().Position - position).Magnitude
			if d <= bestD then
				best, bestD = child, d
			end
		end
	end
	return best
end

local function kick(model: Model?, event: string, data: { [string]: any }?)
	if ItemBones and model then
		ItemBones.Kick(model, event, data)
	end
end

-- ---------- sounds ----------

-- every sound name has up to VOICES positional voices (an Attachment with one Sound each), reused
-- round-robin: the same sound can overlap a little, and nothing grows once each is made
type Voice = { att: Attachment, sound: Sound }
local voices: { [string]: { list: { Voice }, last: number } } = {}
local VOICES = 3
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

-- A positional sound at a world point (pooled per name).
function ItemFX.PlayAt(name: string, position: Vector3?, pitch: number?)
	local spec = ItemFX.Sounds[name]
	if not spec or spec.id == "" or not position or sfxVolume <= 0 then
		return
	end
	if (position - camPos()).Magnitude > SOUND_RANGE or not takeToken() then
		return
	end
	local pool = voices[name]
	if not pool then
		pool = { list = {}, last = 0 }
		voices[name] = pool
	end
	local p = pool :: { list: { Voice }, last: number }
	p.last = p.last % VOICES + 1
	local v = p.list[p.last]
	if not v or not v.att.Parent then
		local att = Instance.new("Attachment")
		att.Name = "Sound_" .. name
		att.Parent = getHolder()
		local s = Instance.new("Sound")
		s.Name = name
		s.RollOffMode = Enum.RollOffMode.InverseTapered
		s.RollOffMinDistance = 8
		s.RollOffMaxDistance = SOUND_RANGE
		s.Parent = att
		v = { att = att, sound = s }
		p.list[p.last] = v
	end
	local voice = v :: Voice
	voice.att.Position = position -- the holder sits at the origin: local = world
	local snd = voice.sound
	snd.SoundId = spec.id -- (ItemFX.Sounds may be changed while playing)
	snd.Volume = spec.volume * sfxVolume
	snd.PlaybackSpeed = (pitch or 1) * spec.pitch * (0.95 + math.random() * 0.1)
	snd.TimePosition = 0
	snd:Play()
end

-- A sound for this player only, not positional (the duck's alarm, a big moment's whoosh).
local function playFlat(name: string, pitch: number?)
	local spec = ItemFX.Sounds[name]
	if not spec or spec.id == "" or sfxVolume <= 0 then
		return
	end
	local s = Instance.new("Sound")
	s.SoundId = spec.id
	s.Volume = spec.volume * sfxVolume
	s.PlaybackSpeed = spec.pitch * (pitch or 1)
	s.Parent = SoundService
	s.Ended:Once(function()
		s:Destroy()
	end)
	Debris:AddItem(s, 5)
	s:Play()
end
ItemFX.PlayFlat = playFlat

-- ---------- particles ----------

local emitters: { [string]: ParticleEmitter } = {}
local emitAtt: Attachment? = nil

-- the emitters that always keep their own colour
local FIXED_COLOR: { [string]: Color3 } = {
	drops = Color3.fromRGB(170, 225, 255),
	streamerA = Color3.fromRGB(240, 70, 80),
	streamerB = Color3.fromRGB(70, 130, 245),
	sand = Color3.fromRGB(240, 210, 150),
	soap = Color3.fromRGB(255, 225, 245),
	confettiA = Color3.fromRGB(255, 120, 185),
	confettiB = Color3.fromRGB(255, 220, 80),
	confettiC = Color3.fromRGB(90, 210, 255),
	goldStars = GOLD,
	dust = Color3.fromRGB(225, 212, 190),
}

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
	if kind == "stars" or kind == "goldStars" then
		pe.Texture = SPARKLES
		pe.Lifetime = NumberRange.new(0.35, 0.7)
		pe.Speed = NumberRange.new(10, 20)
		local size = if kind == "goldStars" then 1.1 else 0.9
		pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size), NumberSequenceKeypoint.new(1, 0) })
		pe.LightEmission = 1
		pe.RotSpeed = NumberRange.new(-300, 300)
		pe.Rotation = NumberRange.new(0, 360)
	elseif kind == "puff" or kind == "dust" then
		pe.Lifetime = NumberRange.new(0.6, 1.1)
		pe.Speed = if kind == "dust" then NumberRange.new(6, 11) else NumberRange.new(3, 7)
		pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.2), NumberSequenceKeypoint.new(1, if kind == "dust" then 3.2 else 2.6) })
		pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) })
		pe.LightEmission = 0.2
		pe.Acceleration = Vector3.new(0, 2, 0)
		if kind == "dust" then
			pe.Drag = 4
			pe.SpreadAngle = Vector2.new(100, 15)
		end
	elseif kind == "bits" or kind == "sand" or kind == "drops" then
		pe.Lifetime = NumberRange.new(0.5, 0.9)
		pe.Speed = NumberRange.new(8, 14)
		local size = if kind == "sand" then 0.2 elseif kind == "drops" then 0.32 else 0.45
		pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size), NumberSequenceKeypoint.new(1, size * 0.3) })
		pe.Acceleration = Vector3.new(0, if kind == "drops" then -40 else -30, 0)
		pe.EmissionDirection = Enum.NormalId.Top
		pe.SpreadAngle = Vector2.new(60, 60)
		pe.RotSpeed = NumberRange.new(-200, 200)
		if kind == "drops" then
			pe.LightEmission = 0.4
			pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.15), NumberSequenceKeypoint.new(1, 0.6) })
		elseif kind == "sand" then
			pe.Drag = 1
		end
	elseif kind == "streamerA" or kind == "streamerB" then
		pe.Lifetime = NumberRange.new(0.6, 1.0)
		pe.Speed = NumberRange.new(10, 16)
		pe.Size = NumberSequence.new(0.35)
		pe.Squash = NumberSequence.new(1.6) -- long thin ribbons
		pe.Orientation = Enum.ParticleOrientation.VelocityParallel
		pe.Acceleration = Vector3.new(0, -12, 0)
		pe.RotSpeed = NumberRange.new(-260, 260)
	elseif kind == "confettiA" or kind == "confettiB" or kind == "confettiC" then
		pe.Lifetime = NumberRange.new(1.0, 1.6)
		pe.Speed = NumberRange.new(8, 14)
		pe.Size = NumberSequence.new(0.3)
		pe.Squash = NumberSequence.new(-0.5) -- flat little cards
		pe.Acceleration = Vector3.new(0, -10, 0)
		pe.Drag = 2.5
		pe.RotSpeed = NumberRange.new(-400, 400)
		pe.Rotation = NumberRange.new(0, 360)
	elseif kind == "soap" then
		pe.Texture = SPARKLES
		pe.Lifetime = NumberRange.new(0.4, 0.8)
		pe.Speed = NumberRange.new(2, 5)
		pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(1, 0) })
		pe.LightEmission = 0.6
	elseif kind == "fibres" then
		-- cloth fibres flying off the crack: short bright streaks
		pe.Texture = SPARKLES
		pe.Lifetime = NumberRange.new(0.15, 0.32)
		pe.Speed = NumberRange.new(18, 30)
		pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.16), NumberSequenceKeypoint.new(1, 0.04) })
		pe.Squash = NumberSequence.new(2.4)
		pe.Orientation = Enum.ParticleOrientation.VelocityParallel
		pe.LightEmission = 0.5
		pe.Drag = 5
	else -- "sparks"
		pe.Texture = SPARKLES
		pe.Lifetime = NumberRange.new(0.15, 0.35)
		pe.Speed = NumberRange.new(14, 26)
		pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 0) })
		pe.LightEmission = 1
	end
	pe.TimeScale = fxScale
	pe.Parent = att
	emitters[kind] = pe
	return pe
end

local function emit(kind: string, position: Vector3, count: number, color: Color3?)
	if count < 1 then
		return
	end
	local e = emitter(kind)
	local att = e.Parent
	if att and att:IsA("Attachment") then
		att.Position = position
	end
	e.Color = ColorSequence.new(color or FIXED_COLOR[kind] or Color3.new(1, 1, 1))
	local n = if lowGraphics then math.max(1, math.floor(count * 0.5)) else count
	e:Emit(n)
end

-- big moments slow the effects down: every pooled emitter follows
local function setEmitterScale(scale: number)
	for _, e in pairs(emitters) do
		e.TimeScale = scale
	end
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
	for i = 1, 8 do
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

-- A comic word with a ring and flying stars at `position` (scale 1 = a thief snap). `wordColor`:
-- the word's colour (default yellow; ZAP! and BLUB! are light blue).
function ItemFX.Burst(position: Vector3, text: string, color: Color3, scale: number, starCount: number, wordColor: Color3?)
	local b: Burst? = nil
	for _, candidate in ipairs(bursts) do
		if not candidate.gui.Enabled then
			b = candidate
			break
		end
	end
	if not b then
		if #bursts >= 6 then
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
	burst.word.TextColor3 = wordColor or (if text == "ZAP!" or text == "BLUB!" then ZAP_BLUE else YELLOW)
	burst.ringStroke.Color = color
	burst.scale = scale
	burst.rot = (math.random() - 0.5) * 24
	burst.t0 = fxClock
	burst.dur = 0.75
	local n = math.min(starCount, #burst.stars)
	for k, star in ipairs(burst.stars) do
		star.Visible = k <= n
		star.TextColor3 = if k % 2 == 0 then color else YELLOW
		burst.angles[k] = (k / math.max(n, 1)) * math.pi * 2 + math.random() * 0.6
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

-- ---------- ring shockwaves on the floor (pooled) ----------
-- A flat invisible part with a SurfaceGui circle outline on top that grows and fades.

type Ring = { part: Part, stroke: UIStroke, t0: number, dur: number, radius: number }
local ringPool: { Ring } = {}
local activeRings: { Ring } = {}
local RINGS_MAX = 12

local function newRing(): Ring
	local part = Instance.new("Part")
	part.Name = "ItemRing"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(1, 0.05, 1)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Ring"
	gui.Face = Enum.NormalId.Top
	gui.LightInfluence = 0
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize = Vector2.new(256, 256)
	gui.Parent = part
	local circle = Instance.new("Frame")
	circle.Name = "Circle"
	circle.Size = UDim2.fromScale(1, 1)
	circle.BackgroundTransparency = 1
	circle.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = circle
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 14
	stroke.Color = Color3.new(1, 1, 1)
	stroke.Parent = circle
	return { part = part, stroke = stroke, t0 = 0, dur = 0.4, radius = 4 }
end

-- A ring on the floor at `position` that grows to `radius` studs in `dur` seconds.
local function floorRing(position: Vector3, radius: number, color: Color3, dur: number, name: string?)
	local r = table.remove(ringPool)
	if not r then
		if #activeRings >= RINGS_MAX then
			r = table.remove(activeRings, 1)
		else
			r = newRing()
		end
	end
	local ring = r :: Ring
	ring.part.Name = name or "ItemRing"
	ring.part.CFrame = CFrame.new(position)
	ring.part.Size = Vector3.new(0.6, 0.05, 0.6)
	ring.stroke.Color = color
	ring.stroke.Transparency = 0
	ring.t0 = fxClock
	ring.dur = math.max(dur, 0.1)
	ring.radius = math.max(radius, 0.5)
	ring.part.Parent = workspace.CurrentCamera
	table.insert(activeRings, ring)
end
ItemFX.Ring = floorRing

local function updateRings(t: number)
	for i = #activeRings, 1, -1 do
		local r = activeRings[i]
		local u = (t - r.t0) / r.dur
		if u >= 1 or not r.part then
			table.remove(activeRings, i)
			r.part.Parent = nil
			table.insert(ringPool, r)
		else
			local grow = 1 - (1 - u) * (1 - u)
			local d = math.max(0.6, r.radius * 2 * grow)
			r.part.Size = Vector3.new(d, 0.05, d)
			r.stroke.Transparency = u * u
			r.stroke.Thickness = 14 * (1 - 0.5 * u)
		end
	end
end

-- ---------- lightning arcs (the chained zap) ----------

type Arc = { parts: { Part }, from: Vector3, to: Vector3, t0: number, dur: number, nextJitter: number }
local arcPool: { Part } = {}
local arcs: { Arc } = {}
local ARC_SEGMENTS = 6
local ARC_MAX = 6
local arcPoints: { Vector3 } = {}

local function arcPart(): Part
	local p = table.remove(arcPool)
	if p then
		return p
	end
	local part = Instance.new("Part")
	part.Name = "ItemZapArc"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Size = Vector3.new(0.14, 0.14, 1)
	return part
end

local function jitterArc(a: Arc)
	local span = a.to - a.from
	local len = span.Magnitude
	if len < 1e-3 then
		return
	end
	local side = span:Cross(Vector3.new(0, 1, 0))
	side = if side.Magnitude > 1e-3 then side.Unit else Vector3.new(1, 0, 0)
	local up = side:Cross(span.Unit)
	arcPoints[1] = a.from
	for i = 1, ARC_SEGMENTS - 1 do
		local wobble = math.min(0.9, len * 0.08)
		arcPoints[i + 1] = a.from + span * (i / ARC_SEGMENTS) + side * ((math.random() - 0.5) * 2 * wobble) + up * ((math.random() - 0.5) * 2 * wobble)
	end
	arcPoints[ARC_SEGMENTS + 1] = a.to
	for i, part in ipairs(a.parts) do
		local p0, p1 = arcPoints[i], arcPoints[i + 1]
		local d = (p1 - p0).Magnitude
		part.Size = Vector3.new(0.14, 0.14, math.max(0.05, d))
		part.CFrame = CFrame.lookAt((p0 + p1) / 2, p1)
	end
end

-- A crackling lightning arc between two points for `dur` seconds.
local function zapArc(from: Vector3, to: Vector3, color: Color3, dur: number)
	if #arcs >= ARC_MAX then
		return
	end
	local a: Arc = { parts = {}, from = from, to = to, t0 = fxClock, dur = dur, nextJitter = 0 }
	for _ = 1, ARC_SEGMENTS do
		local part = arcPart()
		part.Color = color
		part.Transparency = 0
		part.Parent = workspace.CurrentCamera
		table.insert(a.parts, part)
	end
	jitterArc(a)
	table.insert(arcs, a)
end

local function updateArcs(t: number)
	for i = #arcs, 1, -1 do
		local a = arcs[i]
		local u = (t - a.t0) / a.dur
		if u >= 1 then
			table.remove(arcs, i)
			for _, part in ipairs(a.parts) do
				part.Parent = nil
				table.insert(arcPool, part)
			end
		else
			if t >= a.nextJitter then
				a.nextJitter = t + 0.05
				jitterArc(a)
			end
			for _, part in ipairs(a.parts) do
				part.Transparency = u * 0.8
			end
		end
	end
end

-- ---------- floaties: soap bubbles (the Spa towel) and tiny crowns (the Royal towel) ----------

type Floaty = { part: BasePart?, gui: BillboardGui?, label: TextLabel?, pos: Vector3, vel: Vector3, t0: number, dur: number, size: number }
local soapPool: { Part } = {}
local crownPool: { BillboardGui } = {}
local floaties: { Floaty } = {}
local FLOATIES_MAX = 24

local function soapBubble(): Part
	local p = table.remove(soapPool)
	if p then
		return p
	end
	local part = Instance.new("Part")
	part.Name = "ItemSoapBubble"
	part.Shape = Enum.PartType.Ball
	part.Material = Enum.Material.Glass
	part.Color = Color3.fromRGB(235, 225, 255)
	part.Transparency = 0.55
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	return part
end

local function crownGui(): BillboardGui
	local g = table.remove(crownPool)
	if g then
		return g
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "ItemCrown"
	gui.Size = UDim2.new(0.9, 14, 0.9, 14)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 90
	gui.ResetOnSpawn = false
	local label = Instance.new("TextLabel")
	label.Name = "Crown"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = "👑"
	label.TextScaled = true
	label.Font = FONT
	label.TextColor3 = GOLD
	label.Parent = gui
	return gui
end

local function floatSoap(position: Vector3, count: number)
	local n = if lowGraphics then math.ceil(count / 2) else count
	for _ = 1, n do
		if #floaties >= FLOATIES_MAX then
			return
		end
		local part = soapBubble()
		local size = 0.45 + math.random() * 0.45
		part.Size = Vector3.new(size, size, size)
		part.CFrame = CFrame.new(position)
		part.Parent = workspace.CurrentCamera
		local a = math.random() * math.pi * 2
		table.insert(floaties, { part = part, gui = nil, label = nil, pos = position, vel = Vector3.new(math.cos(a) * 3, 3 + math.random() * 3, math.sin(a) * 3), t0 = fxClock, dur = 0.7 + math.random() * 0.5, size = size })
	end
end

local function floatCrowns(position: Vector3, count: number)
	local n = if lowGraphics then math.ceil(count / 2) else count
	for _ = 1, n do
		if #floaties >= FLOATIES_MAX then
			return
		end
		local gui = crownGui()
		local label = gui:FindFirstChild("Crown")
		local att = getHolder()
		gui.Adornee = att
		gui.StudsOffsetWorldSpace = position
		gui.Parent = att
		local a = math.random() * math.pi * 2
		table.insert(floaties, {
			part = nil,
			gui = gui,
			label = if label and label:IsA("TextLabel") then label else nil,
			pos = position,
			vel = Vector3.new(math.cos(a) * 4, 5 + math.random() * 3, math.sin(a) * 4),
			t0 = fxClock,
			dur = 0.8,
			size = 1,
		})
	end
end

local function updateFloaties(t: number, dt: number)
	for i = #floaties, 1, -1 do
		local f = floaties[i]
		local u = (t - f.t0) / f.dur
		if u >= 1 then
			table.remove(floaties, i)
			if f.part then
				local part = f.part :: Part
				part.Parent = nil
				table.insert(soapPool, part)
				if not lowGraphics then
					emit("soap", f.pos, 2)
				end
			elseif f.gui then
				local gui = f.gui :: BillboardGui
				gui.Parent = nil
				table.insert(crownPool, gui)
			end
		else
			f.vel = Vector3.new(f.vel.X * (1 - math.min(1, dt * 2)), f.vel.Y - dt * (if f.part then 1 else 9), f.vel.Z * (1 - math.min(1, dt * 2)))
			f.pos += f.vel * dt
			if f.part then
				local wob = 1 + math.sin((t - f.t0) * 20) * 0.08
				f.part.Size = Vector3.new(f.size * wob, f.size / wob, f.size * wob)
				f.part.CFrame = CFrame.new(f.pos)
			elseif f.gui then
				f.gui.StudsOffsetWorldSpace = f.pos
				if f.label then
					f.label.TextTransparency = if u > 0.6 then (u - 0.6) / 0.4 else 0
					f.label.Rotation = math.sin(u * 12) * 15
				end
			end
		end
	end
end

-- ---------- screen shake (your own camera; never with Reduce motion) ----------

local shakeUntil, shakeStart, shakeAmp = 0, 0, 0
local shaking = false

function ItemFX.Shake(amount: number, seconds: number?)
	if reduceMotion then
		return
	end
	local t = os.clock()
	shakeAmp = math.max(if t < shakeUntil then shakeAmp else 0, amount)
	shakeStart = t
	shakeUntil = t + (seconds or 0.2)
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
	napUntil: number,
	spikes: { BasePart },
	trail: Trail?,
	trailUntil: number,
	highlight: Highlight?,
}
local extras: { [Model]: Extras } = {}

local function extrasOf(character: Model): Extras
	local e = extras[character]
	if not e then
		e = { dizzy = nil, dizzyStars = {}, dizzyUntil = 0, zzz = nil, zzzLabels = {}, napUntil = 0, spikes = {}, trail = nil, trailUntil = 0, highlight = nil }
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

-- the Slipper Dash's trail and dust (also predicted for your own dash); golden slippers leave a
-- sparkling gold trail
function ItemFX.DashFX(player: Player)
	local character = player.Character
	local root = rootOf(player)
	if not character or not root then
		return
	end
	ItemRig.Play(character, "dash")
	ItemFX.PlayAt("dash", root.Position)
	local slippers = heldVisual(player, "SlipperDash")
	kick(slippers, "dash")
	if not shown(root.Position, player == me) then
		return
	end
	local gold = goldOf(player, "SlipperDash")
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
		trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1) })
		trail.Enabled = false
		trail.Parent = root
		e.trail = trail
	end
	local trail = e.trail :: Trail
	trail.Color = if gold then ColorSequence.new(GOLD, Color3.fromRGB(255, 250, 220)) else ColorSequence.new(Color3.fromRGB(205, 180, 255), Color3.fromRGB(255, 255, 255))
	trail.Enabled = true
	e.trailUntil = os.clock() + 0.4
	emit("puff", root.Position - Vector3.new(0, 2.6, 0), 10, Color3.fromRGB(235, 225, 255))
	if gold then
		emit("goldStars", root.Position, 8)
	end
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

-- ---------- the towel: where it cracks, its look's crack, the Royal / finisher trail ----------

-- where a player's towel cracks: the tool's Tip (the far end of the towel), else in front of them
local function crackPoint(p: Player?): Vector3?
	local character = p and p.Character
	local root = rootOf(p)
	if not character or not root then
		return nil
	end
	local tool = character:FindFirstChild("Item_Towel")
	local handle = tool and tool:FindFirstChild("Handle")
	local tip = handle and handle:FindFirstChild("Tip")
	if tip and tip:IsA("Attachment") then
		local at = tip.WorldPosition
		if (at - root.Position).Magnitude < 8 then
			return at
		end
	end
	return root.Position + root.CFrame.LookVector * 4 + Vector3.new(0, 0.5, 0)
end

local function towelLookOf(p: Player?): string
	local character = p and p.Character
	local tool = character and character:FindFirstChild("Item_Towel")
	local look = tool and tool:GetAttribute("Look")
	return if type(look) == "string" and look ~= "" then look else "Plain"
end

-- The look's crack: Plain water droplets, Striped red / blue streamers, Beach a sand spray, Spa
-- soap bubbles, Sports confetti, Champion gold stars, Royal tiny crowns and gold sparkles.
local function lookCrack(look: string, position: Vector3, scale: number, mine: boolean)
	if not shown(position, mine) then
		return
	end
	local function n(k: number): number
		return math.floor(k * scale + 0.5)
	end
	emit("sparks", position, n(5), Color3.new(1, 1, 1))
	if look == "Striped" then
		emit("streamerA", position, n(7))
		emit("streamerB", position, n(7))
	elseif look == "Beach" then
		emit("sand", position, n(24))
	elseif look == "Spa" then
		floatSoap(position, n(5))
		emit("soap", position, n(8))
	elseif look == "Sports" then
		emit("confettiA", position, n(6))
		emit("confettiB", position, n(6))
		emit("confettiC", position, n(6))
	elseif look == "Champion" then
		emit("goldStars", position, n(14))
	elseif look == "Royal" then
		floatCrowns(position, n(3))
		emit("goldStars", position, n(8))
	else
		emit("drops", position, n(16))
	end
end
ItemFX.LookCrack = lookCrack

-- A hit's bigger crack: a ring shockwave on the floor and cloth fibres flying off.
local function bigCrack(position: Vector3, look: string, finisher: boolean, thief: boolean)
	local color = LOOK_COLORS[look] or LOOK_COLORS.Plain
	local k = if finisher then 1.6 else 1
	floorRing(groundAt(position), (if thief then 4 else 2.8) * k, color, if finisher then 0.5 else 0.35)
	emit("fibres", position, math.floor((if thief then 16 else 9) * k), color)
	emit("fibres", position, math.floor(6 * k), Color3.new(1, 1, 1))
end

-- The Royal Towel leaves a gold sparkle trail on every swing; any look leaves a streak on the
-- finisher. Two attachments at the towel's tip and a Trail, made once per towel.
type TowelTrail = { trail: Trail, sparkle: ParticleEmitter, untilT: number }
local towelTrails: { [Instance]: TowelTrail } = setmetatable({}, { __mode = "k" }) :: any

local function towelTrail(p: Player?, look: string, finisher: boolean)
	if look ~= "Royal" and not finisher then
		return
	end
	local character = p and p.Character
	local tool = character and character:FindFirstChild("Item_Towel")
	local handle = tool and tool:FindFirstChild("Handle")
	if not tool or not handle or not handle:IsA("BasePart") or not shown(handle.Position, p == me) then
		return
	end
	local tt = towelTrails[tool]
	if not tt then
		-- made for this towel before (kept on its Handle): reuse it
		local trail = handle:FindFirstChild("ItemTowelTrail")
		local a0 = handle:FindFirstChild("ItemTrailA")
		local sparkle = a0 and a0:FindFirstChild("ItemTowelSparkle")
		if trail and trail:IsA("Trail") and sparkle and sparkle:IsA("ParticleEmitter") then
			tt = { trail = trail, sparkle = sparkle, untilT = 0 }
			towelTrails[tool] = tt
		end
	end
	if not tt or not tt.trail.Parent then
		local tip = handle:FindFirstChild("Tip")
		local at = if tip and tip:IsA("Attachment") then tip.Position else Vector3.new(0, 0, 3)
		local a0 = Instance.new("Attachment")
		a0.Name = "ItemTrailA"
		a0.Position = at
		a0.Parent = handle
		local a1 = Instance.new("Attachment")
		a1.Name = "ItemTrailB"
		a1.Position = at * 0.55
		a1.Parent = handle
		local trail = Instance.new("Trail")
		trail.Name = "ItemTowelTrail"
		trail.Attachment0 = a0
		trail.Attachment1 = a1
		trail.Lifetime = 0.22
		trail.LightEmission = 0.8
		trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(1, 1) })
		trail.Enabled = false
		trail.Parent = handle
		local sparkle = Instance.new("ParticleEmitter")
		sparkle.Name = "ItemTowelSparkle"
		sparkle.Texture = SPARKLES
		sparkle.Rate = 0
		sparkle.Lifetime = NumberRange.new(0.3, 0.6)
		sparkle.Speed = NumberRange.new(0.5, 2)
		sparkle.SpreadAngle = Vector2.new(180, 180)
		sparkle.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 0) })
		sparkle.LightEmission = 1
		sparkle.LightInfluence = 0
		sparkle.Color = ColorSequence.new(GOLD)
		sparkle.Enabled = false
		sparkle.Parent = a0
		tt = { trail = trail, sparkle = sparkle, untilT = 0 }
		towelTrails[tool] = tt
	end
	local t2 = tt :: TowelTrail
	local color = if look == "Royal" then GOLD else (LOOK_COLORS[look] or Color3.new(1, 1, 1))
	t2.trail.Color = ColorSequence.new(color, Color3.new(1, 1, 1))
	t2.trail.Enabled = true
	t2.sparkle.Rate = if look == "Royal" then (if lowGraphics then 20 else 40) else 0
	t2.sparkle.Enabled = look == "Royal"
	t2.untilT = os.clock() + (if finisher then 0.6 else 0.45)
end

local function updateTowelTrails(t: number)
	for _, tt in pairs(towelTrails) do
		if tt.trail.Enabled and t >= tt.untilT then
			tt.trail.Enabled = false
			tt.sparkle.Enabled = false
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

-- ---------- bubbles (each client flies its own copy; the server decides the hits and bounces) ----------

type BubbleFX = { part: Part, from: Vector3, dir: Vector3, speed: number, range: number, t0: number, squashT: number }
local bubbles: { [number]: BubbleFX } = {}
local spareBubbles: { Part } = {}
local BUBBLE_COLOR = Color3.fromRGB(190, 235, 255)
local BUBBLE_GOLD = Color3.fromRGB(255, 230, 150)

local function bubblePart(): Part
	local p = table.remove(spareBubbles)
	if p then
		return p
	end
	local part = Instance.new("Part")
	part.Name = "ItemBubble"
	part.Shape = Enum.PartType.Ball
	part.Material = Enum.Material.Glass
	part.Color = BUBBLE_COLOR
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
			local sq = t - b.squashT
			local hit = if sq < 0.4 then 0.25 * math.exp(-sq * 8) * math.cos(sq * 30) else 0
			local wob = 1 + math.sin(age * 18) * 0.06 + hit
			local pos = b.from + b.dir * travelled + Vector3.new(0, math.sin(age * 6) * 0.3, 0)
			b.part.Size = Vector3.new(5 * wob, 5 / wob, 5 * wob)
			b.part.CFrame = CFrame.new(pos)
		end
	end
end

-- ---------- the remote's kinds ----------

local USE_POSE: { [string]: string } = { BananaPeel = "place", DuckAlarm = "place", BubbleBlaster = "shoot", SoftenerCloud = "spray", StaticBalloon = "zap" }
local lastSwing: { [Player]: number } = {}
local lastPounce = 0 -- your own predicted pounce (its echo doesn't pose you again)

local HANDLERS: { [string]: (data: { [string]: any }) -> () } = {}

HANDLERS.swing = function(data)
	local p = playerOf(data.player)
	if not p then
		return
	end
	local finisher = data.finisher == true
	if p == me then
		-- your own swing was predicted the moment you pressed; the server's count keeps the
		-- predicted combo in step, and a finisher that missed still gets its SUPER SNAP!
		local hook = ItemFX.OnMyCombo
		if type(data.combo) == "number" and hook then
			hook(data.combo, finisher)
		end
		if finisher and data.hit ~= true then
			local since = os.clock() - (lastSwing[me] or 0)
			task.delay(math.clamp(CRACK_FINISHER - since, 0, CRACK_FINISHER), function()
				local at = crackPoint(me)
				if at then
					ItemFX.Burst(at + Vector3.new(0, 1, 0), "SUPER SNAP!", LOOK_COLORS[towelLookOf(me)] or YELLOW, 1.1, 6)
					floorRing(groundAt(at), 3.5, LOOK_COLORS[towelLookOf(me)] or YELLOW, 0.4)
				end
			end)
		end
		return
	end
	lastSwing[p] = os.clock()
	-- a held swing: the towel goes back up over the shoulder for the next crack, which should come
	-- one cooldown later; if it doesn't (they let go), it drops a moment after that
	ItemRig.SetWhipHold(p.Character, data.held == true, HELD_WAIT)
	ItemRig.Play(p.Character, "swing", { finisher = finisher })
	ItemFX.PlayAt("swing", rootPos(p), if finisher then 0.8 else 1)
	local look = if type(data.look) == "string" then data.look else towelLookOf(p)
	towelTrail(p, look, finisher)
	task.delay(if finisher then CRACK_FINISHER else CRACK_T, function()
		local at = crackPoint(p)
		if not at then
			return
		end
		lookCrack(look, at, if finisher then 1.6 else 1, false)
		if finisher and data.hit ~= true and shown(at, false) then
			ItemFX.Burst(at + Vector3.new(0, 1, 0), "SUPER SNAP!", LOOK_COLORS[look] or YELLOW, 1.1, 6)
			floorRing(groundAt(at), 3.5, LOOK_COLORS[look] or YELLOW, 0.4)
		end
	end)
end

HANDLERS.snap = function(data)
	local position = vec(data.position)
	if not position then
		return
	end
	local by = playerOf(data.by)
	local target = playerOf(data.target)
	local thief = data.thief == true
	local finisher = data.finisher == true
	local look = if type(data.look) == "string" then data.look else "Plain"
	-- wait for the towel to crack (the swing started a moment ago)
	local crackT = if finisher then CRACK_FINISHER else CRACK_T
	local since = if by then os.clock() - (lastSwing[by] or 0) else 1
	local delay = math.clamp(crackT - since, 0, crackT)
	task.delay(delay, function()
		ItemFX.PlayAt(if thief then "crack" else "bop", position, if finisher then 0.85 else 1)
		if finisher then
			ItemFX.PlayAt("stinger", position)
		end
		if shown(position, by == me or target == me) then
			local word = if finisher then "SUPER SNAP!" elseif thief then "SNAP!" else "BOP!"
			local scale = (if thief then 1 else 0.7) * (if finisher then 1.35 else 1)
			ItemFX.Burst(position + Vector3.new(0, 1.5, 0), word, LOOK_COLORS[look] or LOOK_COLORS.Plain, scale, (if thief then 6 else 3) + (if finisher then 2 else 0))
			bigCrack(position, look, finisher, thief)
		end
		if by == me then
			ItemFX.Shake((if thief then 0.35 else 0.18) + (if finisher then 0.1 else 0))
			if thief and ItemMoments then
				-- a thief snap lands hard: a hit-stop and a little camera kick
				ItemMoments.HitStop(0.06)
				ItemMoments.Kick(if finisher then 0.9 else 0.6, reduceMotion)
			end
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
			kick((heldVisual(p, "BubbleBlaster")), "shot")
		end
	end
	if (key == "BananaPeel" or key == "DuckAlarm") and vec(data.position) then
		ItemFX.PlayAt("thunk", position)
		if position then
			if shown(position, p == me) then
				emit("puff", position, 6, Color3.fromRGB(255, 250, 230))
			end
			-- the new peel / duck lands with a flop
			task.delay(0.05, function()
				kick(worldNear(if key == "BananaPeel" then "BananaPeel" else "AlarmDuck", position, 4), "drop")
			end)
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
	if position then
		kick(worldNear("BananaPeel", position, 4), "slip")
		if shown(position, p == me) then
			ItemFX.Burst(position + Vector3.new(0, 3, 0), "WHOA!", Color3.fromRGB(255, 214, 80), 0.8, 4)
			emit("bits", position, 10, Color3.fromRGB(255, 220, 70))
		end
	end
	if p == me then
		ItemFX.Shake(0.2)
	end
end

-- Peel bowling: a slipper slides from -> to and knocks others over (each one stumbling gets one).
HANDLERS.bowl = function(data)
	local p = playerOf(data.player)
	local from, to = vec(data.from), vec(data.to)
	if not p or not from or not to then
		return
	end
	local dist = (to - from).Magnitude
	local seconds = math.clamp(dist / 18, 0.5, 1.4)
	ItemRig.Play(p.Character, "bowl", { seconds = seconds })
	ItemFX.PlayAt("slide", from)
	dizzy(p.Character, seconds + 0.3)
	kick(worldNear("BananaPeel", from, 5), "slip")
	if p == me then
		ItemFX.Shake(0.2)
	end
	if not shown(from, p == me) then
		return
	end
	local yellow = Color3.fromRGB(255, 225, 110)
	local fromG, toG = groundAt(from), groundAt(to)
	for k = 1, 6 do
		task.delay(seconds * k / 6, function()
			emit("dust", fromG:Lerp(toG, k / 6), 3, yellow)
		end)
	end
	task.delay(seconds * 0.85, function()
		ItemFX.PlayAt("boing", to, 0.9)
		ItemFX.Burst(to + Vector3.new(0, 3, 0), "BOWLED!", yellow, 0.8, 4)
	end)
end

HANDLERS.bump = function(data)
	local p = playerOf(data.player)
	local target = playerOf(data.target)
	local position = vec(data.position) or rootPos(target)
	if not position then
		return
	end
	ItemFX.PlayAt("bump", position)
	if shown(position, p == me or target == me) then
		local gold = goldOf(p, "SlipperDash")
		local color = if gold then GOLD else Color3.fromRGB(200, 170, 255)
		ItemFX.Burst(position + Vector3.new(0, 2, 0), "BUMP!", color, 0.75, 4)
		emit("puff", position, 8, Color3.fromRGB(235, 225, 255))
		floorRing(groundAt(position), 2.5, color, 0.3)
	end
	if target == me then
		ItemFX.Shake(0.25)
	elseif p == me then
		ItemFX.Shake(0.15)
	end
end

HANDLERS.bubble = function(data)
	local id, from, dir = data.id, vec(data.from), vec(data.dir)
	if type(id) ~= "number" or not from or not dir then
		return
	end
	local by = playerOf(data.by)
	local existing = bubbles[id]
	if existing then
		-- a path update for a bubble already flying
		existing.from = from
		existing.dir = dir
		existing.speed = num(data.speed, existing.speed)
		existing.range = num(data.range, existing.range)
		existing.t0 = fxClock
		return
	end
	if by ~= me then
		ItemFX.PlayAt("blow", from)
	end
	if not shown(from, by == me) then
		return
	end
	local part = bubblePart()
	part.Color = if goldOf(by, "BubbleBlaster") then BUBBLE_GOLD else BUBBLE_COLOR
	part.CFrame = CFrame.new(from)
	part.Size = Vector3.new(5, 5, 5)
	part.Parent = workspace.CurrentCamera
	bubbles[id] = { part = part, from = from, dir = dir, speed = num(data.speed, 40), range = num(data.range, 40), t0 = fxClock, squashT = -math.huge }
end

-- a bubble bounced off a wall (or, `steer`, turned toward a thief): it flies on from there
HANDLERS.bubblebounce = function(data)
	local id, position, dir = data.id, vec(data.position), vec(data.dir)
	if type(id) ~= "number" or not position or not dir then
		return
	end
	local b = bubbles[id]
	if b then
		local travelled = (fxClock - b.t0) * b.speed
		b.range = math.max(0, b.range - travelled)
		b.from = position
		b.dir = dir
		b.t0 = fxClock
	end
	if data.steer ~= true then
		if b then
			b.squashT = fxClock
		end
		ItemFX.PlayAt("bounce", position)
		if shown(position, false) then
			emit("sparks", position, 6, BUBBLE_COLOR)
		end
	end
end

HANDLERS.bubblepop = function(data)
	local position = vec(data.position)
	if type(data.id) == "number" then
		removeBubble(data.id)
	end
	if position then
		ItemFX.PlayAt("pop", position, 1.3)
		if shown(position, false) then
			emit("sparks", position, 14, BUBBLE_COLOR)
			local splash = num(data.splash, 0)
			if splash > 0 then
				-- the pop splashes everyone near: a soapy ring and droplets
				floorRing(groundAt(position), splash, Color3.fromRGB(170, 225, 255), 0.4)
				emit("drops", position, 18)
			end
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
		ItemFX.Burst(position + Vector3.new(0, 4, 0), "BLUB!", ZAP_BLUE, 0.75, 0)
	end
end

-- the duck's siren light blinks for a second (its _Glow parts)
local flashes: { [BasePart]: number } = {}

local function flashModel(duck: Instance?)
	if not duck then
		return
	end
	for _, d in ipairs(duck:GetDescendants()) do
		if d:IsA("BasePart") and string.sub(d.Name, -5) == "_Glow" then
			flashes[d] = os.clock() + 1
		end
	end
end

local function flashDuck(owner: Player?)
	local folder = itemFolder()
	if not owner or not folder then
		return
	end
	local name = "AlarmDuck_" .. owner.UserId
	for _, child in ipairs(folder:GetChildren()) do
		if child.Name == name then
			flashModel(child)
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
	kick(worldNear("AlarmDuck", position, 4), "quack")
end

-- the guard duck honks at an intruder: its bill opens, its head turns to them, a sound wave
HANDLERS.honk = function(data)
	local position = vec(data.position)
	if not position then
		return
	end
	local target = playerOf(data.target)
	local duck = if typeof(data.duck) == "Instance" and data.duck:IsA("Model") then data.duck else worldNear("AlarmDuck", position, 4)
	local ownerId = duck and duck:GetAttribute("OwnerId")
	local mine = target == me or (me ~= nil and ownerId == me.UserId)
	local towards = rootPos(target)
	ItemFX.PlayAt("honk", position)
	kick(duck, "honk", { target = towards })
	flashModel(duck)
	if shown(position, mine) then
		local gold = duck ~= nil and duck:GetAttribute("Gold") == true
		local color = if gold then GOLD else Color3.fromRGB(255, 150, 70)
		ItemFX.Burst(position + Vector3.new(0, 2.5, 0), "HONK!", color, 0.8, 3)
		local ground = groundAt(position)
		floorRing(ground, 3, color, 0.35)
		task.delay(0.12, floorRing, ground, 4.5, color, 0.35)
	end
	if target then
		ItemRig.Play(target.Character, "startle")
		if target == me then
			ItemFX.Shake(0.15)
		end
	end
end

-- the duck's owner sees the intruder glow red for a few seconds
local function highlightFor(p: Player?, name: string, fill: Color3, outline: Color3, seconds: number): boolean
	local character = p and p.Character
	if not character then
		return false
	end
	local e = extrasOf(character)
	if e.highlight then
		e.highlight:Destroy()
	end
	local h = Instance.new("Highlight")
	h.Name = name
	h.FillColor = fill
	h.FillTransparency = 0.6
	h.OutlineColor = outline
	h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	h.Adornee = character
	h.Parent = character
	e.highlight = h
	Debris:AddItem(h, seconds)
	return true
end

HANDLERS.intruder = function(data)
	local p = playerOf(data.player)
	if not highlightFor(p, "ItemIntruder", Color3.fromRGB(255, 70, 70), Color3.fromRGB(255, 60, 60), num(data.seconds, 6)) then
		return
	end
	playFlat("alarm")
	task.delay(0.25, playFlat, "alarm")
end

-- your guard duck honked at a thief: you see them through walls for a few seconds (owner only)
HANDLERS.reveal = function(data)
	local p = playerOf(data.target)
	if not highlightFor(p, "ItemReveal", Color3.fromRGB(255, 200, 60), Color3.fromRGB(255, 235, 130), num(data.seconds, 5)) then
		return
	end
	playFlat("alarm", 1.2)
	local position = rootPos(p)
	if position then
		ItemFX.Burst(position + Vector3.new(0, 4, 0), "SPOTTED!", Color3.fromRGB(255, 200, 60), 0.7, 2)
	end
end

-- a thief nodded off in a Softener Cloud
HANDLERS.nap = function(data)
	local p = playerOf(data.player)
	local character = p and p.Character
	if not p or not character then
		return
	end
	local seconds = num(data.seconds, 1.5)
	ItemRig.Play(character, "nap", { seconds = seconds })
	local e = extrasOf(character)
	e.napUntil = os.clock() + seconds
	local position = rootPos(p)
	ItemFX.PlayAt("nap", position)
	if position and shown(position, p == me) then
		setZzz(character, true)
		local lilac = Color3.fromRGB(225, 195, 255)
		ItemFX.Burst(position + Vector3.new(0, 4, 0), "Zzz...", lilac, 0.8, 0, lilac)
		emit("puff", position, 10, lilac)
	end
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
		kick((heldVisual(p, "SoftenerCloud")), "spray")
	end
	if not shown(position, p == me) then
		return
	end
	local radius = num(data.radius, 8)
	local pink = if goldOf(p, "SoftenerCloud") then Color3.fromRGB(255, 225, 160) else Color3.fromRGB(255, 190, 230)
	emit("puff", position + Vector3.new(0, 1.5, 0), math.floor(10 + radius * 2), pink)
	local from = rootPos(p)
	if from then
		-- a mist from the bottle to the cloud
		for k = 1, 4 do
			emit("puff", from:Lerp(position, k / 5) + Vector3.new(0, 1.5 - k * 0.3, 0), 3, pink)
		end
	end
end

-- the glide slam lands: a shockwave ring at the feet (gold: the golden sheet's stunning one)
HANDLERS.slam = function(data)
	local position = vec(data.position)
	if not position then
		return
	end
	local p = playerOf(data.player)
	local radius = num(data.radius, 9)
	local gold = data.gold == true or goldOf(p, "Glider")
	ItemFX.PlayAt("slam", position)
	if p then
		ItemRig.Stop(p.Character, "dive")
		ItemRig.Play(p.Character, "land")
	end
	local myRoot = rootOf(me)
	if p == me then
		ItemFX.Shake(0.35, 0.3)
	elseif myRoot and (myRoot.Position - position).Magnitude <= radius then
		ItemFX.Shake(0.22, 0.25)
	end
	if not shown(position, p == me) then
		return
	end
	local color = if gold then GOLD else Color3.fromRGB(200, 230, 255)
	local ground = groundAt(position)
	floorRing(ground, radius, color, 0.45)
	floorRing(ground, radius * 0.55, Color3.new(1, 1, 1), 0.3)
	for k = 1, 8 do
		local a = k / 8 * math.pi * 2
		emit("dust", ground + Vector3.new(math.cos(a), 0, math.sin(a)) * radius * 0.45, 2)
	end
	ItemFX.Burst(position + Vector3.new(0, 3, 0), "SLAM!", color, 1.1, 5)
	if gold then
		emit("goldStars", position, 16)
	end
end

-- out of the basket with a pounce: everyone near jumps back
HANDLERS.pounce = function(data)
	local p = playerOf(data.player)
	local position = vec(data.position) or rootPos(p)
	if not position then
		return
	end
	local radius = num(data.radius, 8)
	ItemFX.PlayAt("boing", position, 1.3)
	ItemFX.PlayAt("pop", position, 0.8)
	if p and not (p == me and os.clock() - lastPounce < 1) then
		ItemRig.Play(p.Character, "pounce")
	end
	if p then
		local folder = itemFolder()
		local basket = folder and folder:FindFirstChild("Basket_" .. p.UserId)
		kick(if basket and basket:IsA("Model") then basket else nil, "pounce")
	end
	local myRoot = rootOf(me)
	if p ~= me and myRoot and (myRoot.Position - position).Magnitude <= radius then
		ItemFX.Shake(0.18)
	end
	if not shown(position, p == me) then
		return
	end
	local color = if goldOf(p, "LaundryBasket") then GOLD else Color3.fromRGB(255, 215, 150)
	floorRing(groundAt(position), radius, color, 0.4)
	ItemFX.Burst(position + Vector3.new(0, 3, 0), "POUNCE!", color, 0.9, 4)
	emit("puff", position, 12, Color3.fromRGB(255, 250, 235))
end

HANDLERS.zap = function(data)
	local p = playerOf(data.player)
	local position = vec(data.position)
	if not p or not position then
		return
	end
	local charge = math.clamp(num(data.charge, 0), 0, 1)
	local radius = num(data.radius, 12)
	local gold = goldOf(p, "StaticBalloon")
	local color = if gold then GOLD else Color3.fromRGB(170, 240, 255)
	if p ~= me then
		ItemRig.Play(p.Character, "charge", { on = false })
		ItemRig.Play(p.Character, "zap", { charge = charge })
		kick((heldVisual(p, "StaticBalloon")), "zap")
	end
	ItemFX.PlayAt("zap", position, 1.1 - 0.3 * charge)
	if not shown(position, p == me) then
		return
	end
	local full = charge >= 0.95
	ItemFX.Burst(position + Vector3.new(0, 4, 0), if full then "MEGA ZAP!" else "ZAP!", color, 0.8 + 0.5 * charge, 5 + math.floor(3 * charge), if gold then GOLD else ZAP_BLUE)
	-- a quick electric ring along the floor (as wide as the zap)
	floorRing(groundAt(position - Vector3.new(0, 2, 0)), radius, color, 0.35 + 0.15 * charge, "ItemZapRing")
	local sparks = (if lowGraphics then 4 else 8) + math.floor(6 * charge)
	for _ = 1, sparks do
		local a = math.random() * math.pi * 2
		local r = math.random() * radius
		emit("sparks", position + Vector3.new(math.cos(a) * r, -1.5, math.sin(a) * r), 3, Color3.fromRGB(200, 245, 255))
	end
	-- the golden balloon's chain: arcs to the players just outside
	local chain = data.chain
	if type(chain) == "table" then
		local from = position + Vector3.new(0, 1.5, 0)
		for _, v in ipairs(chain) do
			local to = rootPos(playerOf(v))
			if to then
				zapArc(from, to, color, 0.35)
				emit("sparks", to, 6, color)
				from = to
			end
		end
	end
end

-- a big moment: everyone sees a starburst; the player who landed it and the targets also get the
-- hit-stop, the slow-motion feel and a strong shake (ItemMoments; Reduce motion: a flash)
HANDLERS.moment = function(data)
	local position = vec(data.position)
	local by = playerOf(data.by)
	local strength = math.clamp(num(data.strength, 0.6), 0, 1)
	local target = false
	if type(data.targets) == "table" then
		for _, v in ipairs(data.targets) do
			if v == me then
				target = true
			end
		end
	end
	local mine = by == me or target
	if position and shown(position, mine) then
		emit("goldStars", position, math.floor(10 + 14 * strength))
		emit("stars", position, math.floor(8 + 10 * strength), YELLOW)
		floorRing(groundAt(position), 4 + 6 * strength, GOLD, 0.5)
	end
	if ItemMoments and mine then
		ItemMoments.Play(if target then "target" else "by", strength, reduceMotion)
	end
end

-- an item upgraded: a sparkle on that player's held item (a big gold one when it turns golden)
HANDLERS.upgrade = function(data)
	local p = playerOf(data.player)
	local key = data.key
	if not p or type(key) ~= "string" then
		return
	end
	local level = num(data.level, 1)
	local gold = data.gold == true or ItemConfig.IsGold(level)
	local _, handle = heldVisual(p, key)
	local position = if handle then handle.Position else rootPos(p)
	if not position then
		return
	end
	ItemRig.Play(p.Character, "cheer")
	ItemFX.PlayAt("sparkle", position, if gold then 0.9 else 1.15)
	if not shown(position, p == me) then
		return
	end
	emit("goldStars", position, if gold then 24 else 10)
	emit("stars", position, if gold then 14 else 6, if gold then GOLD else Color3.new(1, 1, 1))
	if gold then
		floorRing(groundAt(position - Vector3.new(0, 2, 0)), 5, GOLD, 0.5)
		ItemFX.Burst(position + Vector3.new(0, 2, 0), "GOLDEN!", GOLD, 1, 6)
	else
		ItemFX.Burst(position + Vector3.new(0, 2, 0), "LEVEL " .. math.floor(level) .. "!", Color3.fromRGB(140, 255, 160), 0.7, 3)
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

-- the balloon charging: your own (ItemClient says) or anyone's ChargeStart attribute
local myCharge: number? = nil
local chargers: { [Player]: number } = {}
local lastCrackle = 0

local function chargeOf(p: Player, character: Model, now: number): number?
	if p == me then
		return myCharge -- yours is predicted (the attribute lags behind a release)
	end
	local start = character:GetAttribute("ChargeStart")
	if type(start) ~= "number" then
		return nil
	end
	local level = p:GetAttribute("Lv_StaticBalloon")
	local seconds = ItemConfig.Stat("StaticBalloon", if type(level) == "number" then level else 0, "chargeSeconds")
	return math.clamp((now - start) / math.max(seconds, 0.1), 0, 1)
end

-- the held item's moving parts and aura (ItemBones)
local function trackHeld(p: Player, character: Model, charge: number?)
	if not ItemBones then
		return
	end
	for _, tool in ipairs(character:GetChildren()) do
		local key = tool:GetAttribute("ItemKey")
		if tool:IsA("Tool") and type(key) == "string" and key ~= "Towel" then
			local item = ItemConfig.Items[key]
			local visual = tool:FindFirstChild("Visual")
			local handle = tool:FindFirstChild("Handle")
			if item and item.model and visual and visual:IsA("Model") then
				local level = tool:GetAttribute("Level")
				local gold = tool:GetAttribute("Gold") == true or (type(level) == "number" and ItemConfig.IsGold(level)) or goldOf(p, key)
				local hidden = character:GetAttribute("InBasket") == true or (key == "Glider" and character:GetAttribute("Gliding") == true)
				ItemBones.Track(visual, item.model, { frame = handle, inHand = true, gold = gold, hidden = hidden, charge = if key == "StaticBalloon" then (charge or 0) else nil })
			end
		end
	end
end

-- the world objects' moving parts and auras (peels, ducks, the canopy, the basket)
local function trackWorld(cam: Vector3)
	local folder = itemFolder()
	if not ItemBones or not folder then
		return
	end
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("Model") then
			local kind = ItemBones.KindOf(child.Name)
			if kind and (child:GetPivot().Position - cam).Magnitude <= PROP_RANGE then
				local level = child:GetAttribute("Level")
				local gold = child:GetAttribute("Gold") == true or (type(level) == "number" and ItemConfig.IsGold(level))
				ItemBones.Track(child, kind, { gold = gold })
			end
		end
	end
end

local function poll()
	local now = workspace:GetServerTimeNow()
	local cam = camPos()
	updateTowelInk(cam)
	local folder = itemFolder()
	for _, p in ipairs(Players:GetPlayers()) do
		local character = p.Character
		local r = rootOf(p)
		if character and r and (r.Position - cam).Magnitude <= 160 then
			ItemRig.Play(character, "glide", { on = character:GetAttribute("Gliding") == true })
			local soft = character:GetAttribute("SoftenedUntil")
			local sleepy = type(soft) == "number" and soft > now
			ItemRig.Play(character, "sleepy", { on = sleepy })
			local napping = character:GetAttribute("Napping")
			local nap = type(napping) == "number" and napping > now
			local e = extras[character]
			if nap and not ItemRig.Has(character, "nap") then
				ItemRig.Play(character, "nap", { seconds = math.clamp(napping - now, 0.3, 6) })
			end
			local napLocal = e ~= nil and e.napUntil > os.clock()
			setZzz(character, (sleepy or nap or napLocal) and shown(r.Position, p == me))
			local hair = character:GetAttribute("HairUpUntil")
			local static = type(hair) == "number" and hair > now
			ItemRig.Play(character, "static", { on = static })
			setSpikes(character, static and (r.Position - cam).Magnitude <= 80)
			-- rubbing the balloon (others: ChargeStart; you: ItemClient's own)
			local charge = chargeOf(p, character, now)
			if charge then
				ItemRig.Play(character, "charge", { on = true, charge = charge })
				if not chargers[p] then
					ItemFX.PlayAt("charge", r.Position)
				end
				chargers[p] = charge
			elseif chargers[p] then
				chargers[p] = nil
				ItemRig.Play(character, "charge", { on = false })
			end
			local basket: Motor6D? = nil
			if character:GetAttribute("InBasket") == true and folder then
				local model = folder:FindFirstChild("Basket_" .. p.UserId)
				local joint = model and model:FindFirstChild("BasketJoint", true)
				basket = if joint and joint:IsA("Motor6D") then joint else nil
			end
			-- a towel in the hand: the arm rests lower and the towel hangs and sways (the tool itself,
			-- not only the server's Item attribute, so it starts the moment it's equipped)
			if basket or character:GetAttribute("Item") == "Towel" or character:FindFirstChild("Item_Towel") then
				ItemRig.Watch(character, basket)
			end
			if (r.Position - cam).Magnitude <= PROP_RANGE then
				trackHeld(p, character, charge)
			end
		end
	end
	for p in pairs(chargers) do
		if p.Parent == nil then
			chargers[p] = nil
		end
	end
	trackWorld(cam)
	if ItemBones then
		ItemBones.Sweep()
	end
	local mine = me and me.Character
	local nowGliding = mine ~= nil and mine:GetAttribute("Gliding") == true
	if nowGliding ~= gliding then
		gliding = nowGliding
		setGlideSound(gliding)
	end
end

-- crackling sparks around every charging balloon (a few times a second)
local function updateCrackle(t: number)
	if t - lastCrackle < 0.12 then
		return
	end
	lastCrackle = t
	for p, charge in pairs(chargers) do
		local _, handle = heldVisual(p, "StaticBalloon")
		local at = if handle then handle.Position + Vector3.new(0, 2.5, 0) else rootPos(p)
		if at and shown(at, p == me) then
			emit("sparks", at, 1 + math.floor(3 * charge), if goldOf(p, "StaticBalloon") then GOLD else ZAP_BLUE)
		end
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

-- You are rubbing the Static Balloon (ItemClient, every frame while it charges): charge 0..1, or
-- nil when it stops.
local myChargeOpts = { on = true, charge = 0 } -- (reused every frame)
function ItemFX.SetCharging(charge: number?)
	local character = me and me.Character
	local was = myCharge
	myCharge = if type(charge) == "number" then math.clamp(charge, 0, 1) else nil
	if not character then
		return
	end
	if myCharge then
		myChargeOpts.charge = myCharge
		ItemRig.Play(character, "charge", myChargeOpts)
		if was == nil then
			chargers[me] = myCharge
			ItemFX.PlayAt("charge", rootPos(me))
		else
			chargers[me] = myCharge
		end
		local visual = heldVisual(me, "StaticBalloon")
		if ItemBones and visual then
			ItemBones.SetCharge(visual, myCharge)
		end
	elseif was ~= nil then
		chargers[me] = nil
		ItemRig.Play(character, "charge", { on = false })
	end
end

-- The player's own use, the moment they press (ItemClient). Shows what will happen right away.
-- info: Towel { finisher }, StaticBalloon { charge }; key "GliderSlam" = the slam press,
-- "LaundryBasketPounce" = popping out of the basket with a pounce.
function ItemFX.Predict(key: string, info: { [string]: any }?)
	local character = me and me.Character
	if not character then
		return
	end
	local opts = info or {}
	local position = rootPos(me)
	if key == "Towel" then
		local finisher = opts.finisher == true
		lastSwing[me] = os.clock()
		ItemRig.Play(character, "swing", { finisher = finisher })
		ItemFX.PlayAt("swing", position, if finisher then 0.8 else 1)
		local look = towelLookOf(me)
		towelTrail(me, look, finisher)
		task.delay(if finisher then CRACK_FINISHER else CRACK_T, function()
			local at = crackPoint(me)
			if at then
				lookCrack(look, at, if finisher then 1.6 else 1, true)
			end
		end)
	elseif key == "SlipperDash" then
		ItemFX.DashFX(me)
	elseif key == "BubbleBlaster" then
		ItemRig.Play(character, "shoot")
		ItemFX.PlayAt("blow", position)
		kick((heldVisual(me, "BubbleBlaster")), "shot")
	elseif key == "SoftenerCloud" then
		ItemRig.Play(character, "spray")
		ItemFX.PlayAt("spray", position)
		kick((heldVisual(me, "SoftenerCloud")), "spray")
	elseif key == "StaticBalloon" then
		ItemFX.SetCharging(nil)
		ItemRig.Play(character, "zap", { charge = num(opts.charge, 0) })
		kick((heldVisual(me, "StaticBalloon")), "zap")
	elseif key == "GliderSlam" then
		ItemRig.Play(character, "dive", { seconds = 1.2 })
		ItemFX.PlayAt("whooshSoft", position, 0.7)
	elseif key == "LaundryBasketPounce" then
		lastPounce = os.clock()
		ItemRig.Play(character, "pounce")
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

-- Counts for the tests: { bursts, ghosts, bubbles, rigs, rings, arcs, floaties, props, auras }
function ItemFX.Counts(): { [string]: number }
	local n = 0
	for _ in pairs(bubbles) do
		n += 1
	end
	return {
		bursts = #activeBursts,
		ghosts = #ghosts,
		bubbles = n,
		rigs = ItemRig.Count(),
		rings = #activeRings,
		arcs = #arcs,
		floaties = #floaties,
		props = if ItemBones then ItemBones.Count() else 0,
		auras = if ItemBones then ItemBones.Auras() else 0,
	}
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
	if ItemMoments then
		ItemMoments.Init({ rig = ItemRig, shake = ItemFX.Shake, sound = playFlat })
	end
	RunService.RenderStepped:Connect(function(dt)
		local ok, err = pcall(function()
			local t = os.clock()
			settingsTick()
			if ItemMoments then
				ItemMoments.Update(dt)
				local scale = ItemMoments.TimeScale()
				if scale ~= fxScale then
					fxScale = scale
					setEmitterScale(scale)
				end
			end
			local fdt = dt * fxScale
			fxClock += fdt
			updateBursts(fxClock)
			updateRings(fxClock)
			updateArcs(fxClock)
			updateFloaties(fxClock, fdt)
			updateGhosts(t)
			updateBubbles(fxClock)
			updateFlashes(t)
			updateExtras(t)
			updateTowelTrails(t)
			updateCrackle(t)
			updateShake(t)
			if ItemBones then
				ItemBones.Step(fdt, camPos(), dt)
			end
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
		chargers[p] = nil
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
