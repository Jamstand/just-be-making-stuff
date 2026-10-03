-- SockAnim: every sock is alive. Bone-driven procedural animation, all on the client (Bone.Transform
-- and the root part's CFrame are never replicated), from ONE RenderStepped loop.
--
-- Layers, added together every frame (docs/ANIMATION.md has the full picture):
--   1. the situation: standing in a drawer / in a menu (the personality's idle loop), hanging on the
--      clothesline (its hang style: kicks, wiggles, swings; it perks up near a player who could buy
--      it), carried on a thief's head (struggling, reaching back toward home)
--   2. fidgets every few seconds and, for rarer socks, show-offs (SockAnimConfig.Rarity)
--   3. the mutation's flavour (SockAnimConfig.Mutations)
--   4. reactions: looks at the nearest player, panics when a thief is in YOUR drawer, paired socks
--      turn to each other and bop, flinches at Towel Snaps, cheers at big buys, dozes off when
--      nobody comes by (and wakes with a start)
--   5. moments: bought, stolen, home, land (claimed by a thief), paired, goodbye, cheer, flinch, wake
--
-- How bones are driven: every pose is written as rotations in the SOCK's own axes (up = toward the
-- cuff, face = +Z where the eyes look, toe = +X on a right sock / -X on a left one, so L and R are
-- mirrored for free) about each bone's rest pivot, then converted per Bone through its rest frame
-- (Transform = rest^-1 * pivotRotation * rest), so bone roll never matters. Every Bone with the same
-- name gets the same motion (the body and its _Outline hull may each carry a copy of the armature).
-- Standing, the Foot keeps its own rotation whatever Leg1 does (planted) and the Root bone shifts so
-- the foot stays put; hanging, forward kinematics finds where the clothespin point went and the Root
-- bone shifts it back, so the cuff stays pinned and the foot swings.
-- Socks with no bones (Part-built ones, an old place), or farther than Perf.BoneRange from the
-- camera, get the same layers folded into whole-body motion of the root part.
--
-- API (the menus use it; every call is safe before Init):
--   SockAnim.Init()
--   SockAnim.Attach(model, "ui", { typeId, side?, rarity?, mutation? }?) -> { Destroy: (self) -> () }
--   SockAnim.Moment(model, kind)  "bought" | "stolen" | "home" | "paired" | "goodbye" | "cheer" |
--                                 "flinch" | "showoff" (and any fidget name)
--   SockAnim.Goodbye(uid)         the drawer sock waves and poofs (a local copy) as it is sold
local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local ConfigFolder = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local Config = require(ConfigFolder:WaitForChild("SockAnimConfig"))
local SockConfig = require(ConfigFolder:WaitForChild("SockConfig"))
local RarityConfig = require(ConfigFolder:WaitForChild("RarityConfig"))

-- Settings are optional (the 3D world must keep moving without the UI kit): until ClientSettings
-- loads every setting reads as its default.
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

-- The rig agent's generated bone roles (optional; bones are found by name without it).
local RigConfig: any = nil
-- SockFX, once Init hands the sock motion over (it keeps the clothesline maths)
local fxMod: any = nil
-- a whole-day epoch keeps the clock small (precise) and the same on every client
local epoch = 0

local SockAnim = {}

-- ---------- small maths ----------

local PI = math.pi
local TAU = math.pi * 2
local WORLD_UP = Vector3.yAxis -- a local: selene errors on Vector3.yAxis:Cross() (it reads :Cross as a missing std field)
local sin, cos, abs, exp, sqrt = math.sin, math.cos, math.abs, math.exp, math.sqrt
local clamp, max, min, floor = math.clamp, math.max, math.min, math.floor
local atan2 = math.atan2

-- 0 outside [a, b], a smooth 0 -> 1 -> 0 hump inside
local function bump(u: number, a: number, b: number): number
	if u <= a or u >= b then
		return 0
	end
	return sin(PI * (u - a) / (b - a))
end

-- 0 before a, 1 after b, eased in between
local function ramp(u: number, a: number, b: number): number
	if u <= a then
		return 0
	elseif u >= b then
		return 1
	end
	local x = (u - a) / (b - a)
	return x * x * (3 - 2 * x)
end

-- a jump arc: 0 -> 1 -> 0 over [a, b]
local function arc(u: number, a: number, b: number): number
	if u <= a or u >= b then
		return 0
	end
	local x = (u - a) / (b - a)
	return 4 * x * (1 - x)
end

local function approach(x: number, target: number, rate: number, dt: number): number
	return x + (target - x) * (1 - exp(-rate * dt))
end

-- deterministic noise in -1..1 for step n of a stream
local function hash(n: number): number
	local v = sin(n * 12.9898 + 78.233) * 43758.5453
	return (v - floor(v)) * 2 - 1
end

local function between(range: { number }?, fallback: number): number
	if range and range[1] and range[2] then
		return range[1] + math.random() * (range[2] - range[1])
	end
	return fallback
end

local function endsWith(name: string, suffix: string): boolean
	return #name >= #suffix and string.sub(name, -#suffix) == suffix
end

-- chain weight profiles: where along the leg a bend happens
local BASE, LOW, EVEN, HIGH, TOP = 1, 2, 3, 4, 5
local PROFILE_K = { -1, -0.5, 0, 0.5, 1 }
local RIGID = 0.55 -- share of a leg bend that becomes whole-body tilt when the bones aren't driven

-- ---------- types ----------

type Slot = {
	name: string,
	role: string, -- root | leg | cuff | foot | toe | digit | eye | hat | jaw | pogo | tentacle | neck | head | fly | hump | tail | ground | accessory
	index: number, -- Leg number, or the segment's place in its chain
	depth: number,
	parent: Slot?,
	rootLevel: boolean, -- its Bone sits directly under a part (gets the Root shift)
	insts: { Bone },
	rest: { CFrame }, -- rest frame of each instance in sock space
	restInv: { CFrame },
	shared: boolean, -- every instance has the same rest frame: solve once
	p: Vector3, -- rest pivot in sock space (studs)
	segH: number, -- height above its parent's pivot (for squash)
	rx: number, -- this frame's rotation, sock-space Euler (YXZ)
	ry: number,
	rz: number,
	ox: number, -- this frame's offset, sock space (studs)
	oy: number,
	oz: number,
	rl: number, -- this frame's roll about `axis` (googly eyes)
	axis: Vector3, -- the bone's own axis that points most toward the face (sock space)
	ga: number, -- googly pupil angle / speed (eyes)
	gv: number,
	slideMax: number, -- jaw: studs it may slide down (at sock scale 1) / radians it may turn
	turnMax: number,
	R: CFrame,
	L: CFrame, -- this frame's motion (sock space), parents first
	moved: boolean, -- its Transform isn't identity
}

type Rig = {
	model: Model,
	root: BasePart?,
	mode: string, -- "world" | "ui" | "goodbye"
	uid: number,
	typeId: string,
	side: string,
	dir: number, -- +1 toe toward +X (right / single), -1 left
	rarity: string,
	rank: number,
	mutation: string,
	pers: any,
	energy: any,
	mut: any,
	tint: Color3,
	unit: number, -- studs per sock unit
	frame: CFrame, -- sock frame (world: the root part; ui / goodbye: fixed at attach)
	pivotOffset: CFrame, -- ui without bones: sock frame -> model pivot
	baseS: Vector3, -- floor point, sock space
	pinS: Vector3, -- clothespin point
	ropeS: Vector3, -- where the line holds it (SockFX's pin offset)
	midS: Vector3,
	eyeS: Vector3,
	slots: { Slot },
	chain: { Slot }, -- Leg1..LegN + Cuff, bottom to top
	prof: { { number } },
	necks: { Slot },
	nprof: { { number } },
	cuff: Slot?,
	foot: Slot?,
	toe: Slot?,
	jaws: { Slot },
	hats: { Slot },
	pogos: { Slot },
	heads: { Slot },
	extras: { Slot },
	eyes: { Slot },
	digits: { Slot },
	critters: { Slot }, -- flies, humps, tails: always busy
	grounds: { Slot }, -- stay on the floor whatever the sock does
	bendMax: number, -- per leg joint (SockAnimConfig.Limits)
	hatMax: number,
	pupil0: number, -- where the pupil sits in the googly eye at rest (angle in the face plane)
	eyeW: number, -- this frame: how much the pupils look at someone, and where
	eyeYaw: number,
	eyePitch: number,
	gy: number, -- googly eyes: last body height / speed
	gvy: number,
	tents: { { Slot } },
	tentKX: { number },
	tentKZ: { number },
	hasBones: boolean,
	bonesOn: boolean,
	bonesDirty: boolean,
	hulls: { BasePart },
	fadeParts: { BasePart }?,
	fade: number,
	fadeShown: number,
	phase: number,
	reduce: boolean,
	-- situation
	state: string,
	rest: CFrame?,
	placedAt: number,
	ownerId: number,
	carryOwner: number,
	paired: boolean,
	pairUid: number,
	created: number,
	lineProgress: number,
	fellSqueak: boolean,
	camDist: number,
	curFrame: CFrame, -- the frame the root was placed from this frame (rest / line / root)
	-- body this frame (sock space; offsets in studs)
	bx: number,
	by: number,
	bz: number,
	brx: number,
	bry: number,
	brz: number,
	spin: number,
	flip: number,
	squash: number,
	-- clips
	actName: string?,
	actT0: number,
	actDur: number,
	actPrev: number,
	actRnd: number,
	momName: string?,
	momT0: number,
	momDur: number,
	momPrio: number,
	momPrev: number,
	momX: number,
	momZ: number,
	momYaw: number,
	momPitch: number,
	actYaw: number,
	actPitch: number,
	queued: string?,
	cheerAt: number,
	cheerVoice: boolean,
	nextFidget: number,
	nextShow: number,
	nextZap: number,
	zapT0: number,
	nextGold: number,
	goldT0: number,
	nextFlail: number,
	-- reactions
	lookW: number,
	lookYaw: number,
	lookPitch: number,
	tLookW: number,
	tLookYaw: number,
	tLookPitch: number,
	lookWho: number,
	noticeAt: number,
	perk: number,
	tPerk: number,
	perkSide: number,
	panic: number,
	tPanic: number,
	awayX: number,
	awayZ: number,
	pairW: number,
	tPairW: number,
	pairYaw: number,
	sleep: number,
	asleep: boolean,
	lastNear: number,
	nextSnore: number,
	nextZzz: number,
	homeX: number,
	homeZ: number,
	homePos: Vector3?,
	nextScan: number,
	lastT: number,
	-- outputs
	sounds: { [string]: Sound },
	soundAt: { [string]: number },
	sparkle: ParticleEmitter?,
	zzz: BillboardGui?,
	zzzLabels: { TextLabel },
	zzzIndex: number,
	conns: { RBXScriptConnection },
	failed: boolean,
	hidden: boolean,
	lastBody: CFrame,
	lastPivot: CFrame?,
	visible: boolean,
	nextVis: number,
	rebuildAt: number,
	onDone: (() -> ())?,
	dead: boolean,
}

-- ---------- registry ----------

local rigList = {} :: { Rig }
local rigsByModel = {} :: { [Model]: Rig }
local rigsByUid = {} :: { [number]: Rig }
local warned = {} :: { [string]: boolean }

local localPlayer = Players.LocalPlayer
local myId = if localPlayer then localPlayer.UserId else 0

-- per-frame globals (refreshed by the loop)
local clockNow = 0 -- server-synced seconds (same beat on every client)
local camPos = Vector3.zero
local reduceMotion = false
local lowGraphics = false
local hideOthers = false
local sfxVolume = 0.8
local uiActive = 0
-- adaptive bone range: shrinks while more than Perf.MaxBoneSocks socks are bone-animated
local boneScale = 1
local boneCount = 0

local function warnOnce(key: string, text: string)
	if not warned[key] then
		warned[key] = true
		warn("[SockAnim] " .. text)
	end
end

-- ---------- channels: what the moves write into ----------

-- the leg (Leg1..LegN + Cuff), sock-space Euler, spread by a profile; whole body when no bones
local function chainS(r: Rig, rx: number, ry: number, rz: number, prof: number)
	local list = r.chain
	if r.bonesOn and #list > 0 then
		local w = r.prof[prof]
		for i, s in ipairs(list) do
			local k = w[i]
			s.rx += rx * k
			s.ry += ry * k
			s.rz += rz * k
		end
	else
		r.brx += rx * RIGID
		r.bry += ry * RIGID
		r.brz += rz * RIGID
	end
end

-- nod: + bows toward the face; lean: + tips toward the toe; twist: + turns the face toward the toe
local function chain(r: Rig, nod: number, lean: number, twist: number, prof: number)
	chainS(r, nod, twist * r.dir, -lean * r.dir, prof)
end

-- bends the leg so its top tips toward (vx, vz) in sock space (a unit-ish direction)
local function bendToward(r: Rig, vx: number, vz: number, amount: number, prof: number)
	chainS(r, amount * vz, 0, -amount * vx, prof)
end

local function slotRot(s: Slot, dir: number, nod: number, lean: number, twist: number)
	s.rx += nod
	s.ry += twist * dir
	s.rz -= lean * dir
end

local function cuff(r: Rig, nod: number, lean: number, twist: number)
	if r.bonesOn then
		local s = r.cuff or r.chain[#r.chain]
		if s then
			slotRot(s, r.dir, nod, lean, twist)
		end
	else
		r.brx += nod * 0.15
		r.bry += twist * r.dir * 0.15
		r.brz -= lean * r.dir * 0.15
	end
end

-- pitch: + lifts the toe; yaw: + swings the toe toward the face; roll: about the foot's length
local function foot(r: Rig, pitch: number, yaw: number, roll: number)
	local s = r.foot
	if r.bonesOn and s then
		s.rz += pitch * r.dir
		s.ry -= yaw * r.dir
		s.rx += roll * r.dir
	end
end

-- + curls the toes down
local function toe(r: Rig, curl: number)
	if not r.bonesOn then
		return
	end
	local s = r.toe
	if s then
		s.rz -= curl * r.dir
	elseif r.foot then
		r.foot.rz -= curl * 0.3 * r.dir
	end
	for _, d in ipairs(r.digits) do
		d.rz -= curl * 0.6 * r.dir
	end
end

-- whole-body offset in sock units: x toward the toe, y up, z toward the face
local function body(r: Rig, x: number, y: number, z: number)
	r.bx += x * r.dir * r.unit
	r.by += y * r.unit
	r.bz += z * r.unit
end

-- whole-body offset in sock space (not mirrored), sock units
local function bodyS(r: Rig, x: number, y: number, z: number)
	r.bx += x * r.unit
	r.by += y * r.unit
	r.bz += z * r.unit
end

local function bodyRot(r: Rig, nod: number, lean: number, twist: number)
	r.brx += nod
	r.bry += twist * r.dir
	r.brz -= lean * r.dir
end

-- full turns (never scaled by an envelope: a spin must end on a whole turn)
local function spin(r: Rig, angle: number)
	if not r.reduce then
		r.spin += angle
	end
end

local function flip(r: Rig, angle: number)
	if not r.reduce then
		r.flip += angle
	end
end

-- + squashes the leg down, - stretches it
local function squash(r: Rig, amount: number)
	r.squash += amount
end

-- the jaw only (nothing when there is none). open 0..1: mostly a slide down, a little turn, both
-- within the rig's own limits (SockRigConfig `slide` / `turn`: the skin stays clean inside them)
local function jaw(r: Rig, open: number)
	if r.bonesOn then
		local o = clamp(open, 0, 1)
		local share = Config.Limits.JawTurn
		for _, s in ipairs(r.jaws) do
			s.oy -= o * s.slideMax * r.unit
			s.rx += o * s.turnMax * share
		end
	end
end

-- talking: the jaw, or the top of the leg flapping like a sock puppet's
local function talk(r: Rig, open: number, A: number)
	if r.bonesOn and #r.jaws > 0 then
		jaw(r, open)
	else
		chain(r, open * 0.22 * A, 0, 0, TOP)
	end
end

local function hat(r: Rig, nod: number, lean: number, lift: number)
	if r.bonesOn and #r.hats > 0 then
		for _, s in ipairs(r.hats) do
			slotRot(s, r.dir, nod, lean, 0)
			s.oy += lift * r.unit
		end
	else
		cuff(r, nod * 0.6, lean * 0.6, 0)
	end
end

local function pogo(r: Rig, compress: number)
	if r.bonesOn then
		for _, s in ipairs(r.pogos) do
			s.oy += compress * r.unit
		end
	end
end

-- the long neck (Sock Ness), or the top of the leg
local function neck(r: Rig, nod: number, lean: number, twist: number, prof: number)
	local list = r.necks
	if r.bonesOn and #list > 0 then
		local w = r.nprof[prof]
		for i, s in ipairs(list) do
			slotRot(s, r.dir, nod * w[i], lean * w[i], twist * w[i])
		end
	else
		chain(r, nod, lean, twist, TOP)
	end
end

local function head(r: Rig, nod: number, lean: number, twist: number)
	if r.bonesOn and #r.heads > 0 then
		for _, s in ipairs(r.heads) do
			slotRot(s, r.dir, nod, lean, twist)
		end
	else
		neck(r, nod * 0.5, lean * 0.5, twist * 0.5, TOP)
	end
end

-- turns the upper body / head to a yaw and pitch in sock space (yaw + = toward +X, pitch + = up)
local function lookAt(r: Rig, yaw: number, pitch: number, w: number)
	local list = r.necks
	if r.bonesOn and #list > 0 then
		local pw = r.nprof[TOP]
		for i, s in ipairs(list) do
			s.ry += yaw * w * pw[i] * 0.7
			s.rx -= pitch * w * pw[i] * 0.6
		end
		for _, s in ipairs(r.heads) do
			s.ry += yaw * w * 0.3
			s.rx -= pitch * w * 0.4
		end
	else
		chainS(r, -pitch * w, yaw * w, 0, TOP)
	end
end

-- a wave travelling up the leg (lean), phase `ph`, `lag` radians per segment
local function wave(r: Rig, ampLean: number, ampNod: number, ph: number, lag: number)
	local list = r.chain
	if r.bonesOn and #list > 0 then
		for i, s in ipairs(list) do
			local a = ph - i * lag
			slotRot(s, r.dir, ampNod * sin(a * 0.8), ampLean * sin(a), 0)
		end
	else
		bodyRot(r, ampNod * sin(ph) * 0.5, ampLean * sin(ph) * 0.6, 0)
	end
end

-- the same along the neck
local function neckWave(r: Rig, ampLean: number, ampNod: number, ph: number, lag: number)
	local list = r.necks
	if r.bonesOn and #list > 0 then
		for i, s in ipairs(list) do
			local a = ph - i * lag
			slotRot(s, r.dir, ampNod * sin(a * 0.8), ampLean * sin(a), 0)
		end
	else
		wave(r, ampLean * 0.6, ampNod * 0.6, ph, lag)
	end
end

-- hanging: the foot end swings (side: + toward the toe, face: + toward the viewer) while the cuff
-- keeps its angle; the pin compensation keeps the cuff on the line
local function hangSwing(r: Rig, side: number, face: number)
	local list = r.chain
	local n = #list
	if r.bonesOn and n > 0 then
		slotRot(list[1], r.dir, -face, -side, 0)
		if n > 1 then
			local share = 1 / (n - 1)
			for i = 2, n do
				slotRot(list[i], r.dir, face * share, side * share, 0)
			end
		end
	else
		bodyRot(r, -face * 0.7, -side * 0.7, 0)
	end
end

-- tentacles: curl (+ = in / under, like a jellyfish pulse) with a wave down each, and swirl
local function tentacles(r: Rig, ph: number, curl: number, swirl: number, lag: number)
	if not r.bonesOn or #r.tents == 0 then
		return
	end
	local n = #r.tents
	for c, list in ipairs(r.tents) do
		local kx, kz = r.tentKX[c], r.tentKZ[c]
		local off = c / n * PI
		for j, s in ipairs(list) do
			local a = ph - j * lag + off * 0.3
			local th = curl * sin(a)
			s.rx += th * kx
			s.rz += th * kz
			s.ry += swirl * sin(a * 0.7 + off) / max(j, 1)
		end
	end
end

-- secondary motion on accessories (beard, monocle, bills, cape, stink cloud, question mark ...)
local function jiggle(r: Rig, t: number, amount: number)
	if not r.bonesOn then
		return
	end
	for i, s in ipairs(r.extras) do
		local name = s.name
		if name == "Bills" then
			s.ry += 0.6 * sin(t * 1.7)
			s.rx += amount * 2 * sin(t * 7.3)
		elseif name == "Question" then
			s.oy += 0.08 * r.unit * sin(t * 1.4)
			s.rz += 0.12 * sin(t * 0.9)
		elseif name == "Cape" or name == "Stink" then
			s.rx += amount * 3 * sin(t * 3.1 + i)
			s.rz += amount * 2 * sin(t * 2.3 + i)
		elseif name == "Monocle" then
			s.rz += amount * 3 * sin(t * 2.3)
		else
			s.rx += amount * sin(t * 4.1 + i * 1.7)
			s.rz += amount * sin(t * 3.3 + i * 2.3)
		end
	end
	for i, s in ipairs(r.hats) do
		s.rx += amount * 0.5 * sin(t * 3.6 + i)
	end
end

-- the never-still bits: Toe-Toe's five toes, Stinkolino's flies, the Sock Ness humps and tail
local function critters(r: Rig, t: number, A: number)
	if not r.bonesOn then
		return
	end
	for k, s in ipairs(r.digits) do
		s.rz -= (0.12 + 0.18 * A) * sin(t * 9 + k * 0.9) * r.dir
	end
	local u = r.unit
	for k, s in ipairs(r.critters) do
		if s.role == "fly" then
			s.ox += 0.35 * u * sin(t * 6.3 + k * 2.1)
			s.oy += 0.25 * u * sin(t * 8.1 + k)
			s.oz += 0.35 * u * cos(t * 5.7 + k * 1.3)
			s.ry += 0.8 * sin(t * 4 + k)
		elseif s.role == "hump" then
			s.rx += 0.12 * sin(t * 1.3 - k)
			s.oy += 0.05 * u * sin(t * 1.3 - k)
		else
			s.ry += 0.35 * sin(t * 2.1)
			s.rz += 0.1 * sin(t * 1.5)
		end
	end
end

-- Keeps every joint inside the skin's clean range (SockAnimConfig.Limits): leg twist beyond it turns
-- the whole sock, half of any leg bend beyond it tilts the whole sock; hats and tentacles just stop.
local function limitJoints(r: Rig)
	if not r.bonesOn then
		return
	end
	local L = Config.Limits
	local bendMax, twistMax = r.bendMax, L.Twist
	for _, s in ipairs(r.chain) do
		local x = clamp(s.rx, -bendMax, bendMax)
		local z = clamp(s.rz, -bendMax, bendMax)
		local y = clamp(s.ry, -twistMax, twistMax)
		r.brx += (s.rx - x) * 0.5
		r.brz += (s.rz - z) * 0.5
		r.bry += s.ry - y
		s.rx, s.ry, s.rz = x, y, z
	end
	local hatMax = r.hatMax
	for _, s in ipairs(r.hats) do
		s.rx = clamp(s.rx, -hatMax, hatMax)
		s.rz = clamp(s.rz, -hatMax, hatMax)
	end
	local tentMax = L.Tentacle
	for _, list in ipairs(r.tents) do
		for _, s in ipairs(list) do
			s.rx = clamp(s.rx, -tentMax, tentMax)
			s.rz = clamp(s.rz, -tentMax, tentMax)
		end
	end
end

local function wrapAngle(a: number): number
	return (a + PI) % TAU - PI
end

-- googly pupils: each rolls round its eye on a loose spring, staying "down" as the face tips and
-- rattling when the sock hops; when the sock looks at someone the pupils swing toward them
local function googly(r: Rig, dt: number)
	local eyes = r.eyes
	if not r.bonesOn or #eyes == 0 then
		return
	end
	local tilt = r.brz
	for _, s in ipairs(r.chain) do
		if s ~= r.cuff then
			tilt += s.rz
		end
	end
	for _, s in ipairs(r.necks) do
		tilt += s.rz
	end
	local target = -tilt
	if r.eyeW > 0.01 then
		local px, py = sin(r.eyeYaw), sin(r.eyePitch)
		local mag = sqrt(px * px + py * py)
		if mag > 1e-3 then
			local k = clamp(mag / 0.25, 0, 1) * r.eyeW
			target = target * (1 - k) + wrapAngle(atan2(py, px) - r.pupil0) * k
		end
	end
	local h = max(dt, 1 / 240)
	local vy = (r.by - r.gy) / h
	local kick = clamp((vy - r.gvy) * 0.08, -6, 6)
	r.gy = r.by
	r.gvy = vy
	local n = min(4, max(1, math.ceil(dt * 60)))
	local sub = dt / n
	for i, s in ipairs(eyes) do
		local k = 60 + 20 * i
		s.gv += kick * (if i % 2 == 0 then 1 else -1)
		for _ = 1, n do
			s.gv += ((target - s.ga) * k - s.gv * 3.5) * sub
			s.ga += s.gv * sub
		end
		s.ga = clamp(s.ga, -2.5, 2.5)
		s.rl += s.ga
	end
end

-- ---------- sounds and sparkles ----------

local soundTokens = 6
local soundRefill = 0

local function playSound(r: Rig, name: string)
	if r.mode == "ui" or r.hidden then
		return
	end
	local spec = Config.Sounds[name]
	local root = r.root
	if not spec or spec.id == "" or not root or sfxVolume <= 0 or r.camDist > Config.SoundRange then
		return
	end
	local nowc = os.clock()
	if nowc - (r.soundAt[name] or -1e9) < spec.gap then
		return
	end
	local perSecond = Config.SoundsPerSecond
	soundTokens = min(perSecond, soundTokens + (nowc - soundRefill) * perSecond)
	soundRefill = nowc
	if soundTokens < 1 then
		return
	end
	soundTokens -= 1
	r.soundAt[name] = nowc
	local s = r.sounds[name]
	if not s or s.Parent ~= root then
		s = Instance.new("Sound")
		s.Name = "SockAnim_" .. name
		s.SoundId = spec.id
		s.RollOffMode = Enum.RollOffMode.InverseTapered
		s.RollOffMinDistance = Config.SoundRollOff[1]
		s.RollOffMaxDistance = Config.SoundRollOff[2]
		s.Parent = root
		r.sounds[name] = s
	end
	local snd = s :: Sound
	snd.Volume = spec.volume * sfxVolume
	snd.PlaybackSpeed = spec.pitch * (r.pers.voice or 1) * (0.95 + math.random() * 0.1)
	snd.TimePosition = 0
	snd:Play()
end

-- plays a sound once when the clip passes `at` (pu = progress last frame, u = now)
local function cue(r: Rig, pu: number, u: number, at: number, name: string)
	if pu < at and u >= at then
		playSound(r, name)
	end
end

local function sparkle(r: Rig, count: number, color: Color3?)
	local root = r.root
	if r.mode == "ui" or r.hidden or not root or count <= 0 or r.camDist > 120 then
		return
	end
	if hideOthers and r.ownerId ~= myId and r.camDist > 30 then
		return
	end
	local n = if lowGraphics then floor(count * 0.5) else count
	if n <= 0 then
		return
	end
	local e = r.sparkle
	if not e or not e.Parent then
		local att = Instance.new("Attachment")
		att.Name = "SockAnimSparkle"
		att.Position = r.midS
		att.Parent = root
		local pe = Instance.new("ParticleEmitter")
		pe.Rate = 0
		pe.Lifetime = NumberRange.new(0.5, 0.9)
		pe.Speed = NumberRange.new(4, 9)
		pe.SpreadAngle = Vector2.new(180, 180)
		pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.25, 0.45), NumberSequenceKeypoint.new(1, 0) })
		pe.LightEmission = 1
		pe.LightInfluence = 0
		pe.Drag = 3
		pe.Acceleration = Vector3.new(0, 2, 0)
		pe.Parent = att
		r.sparkle = pe
		e = pe
	end
	local emitter = e :: ParticleEmitter
	emitter.Color = ColorSequence.new(color or r.tint)
	emitter:Emit(n)
end

-- a puff of white smoke where a sock used to be (the goodbye poof), with its pop
local function poofAt(position: Vector3, color: Color3)
	local holder = Instance.new("Part")
	holder.Name = "SockAnimPoof"
	holder.Size = Vector3.new(0.2, 0.2, 0.2)
	holder.Transparency = 1
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.CFrame = CFrame.new(position)
	local e = Instance.new("ParticleEmitter")
	e.Rate = 0
	e.Lifetime = NumberRange.new(0.5, 0.9)
	e.Speed = NumberRange.new(5, 11)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.2), NumberSequenceKeypoint.new(1, 0) })
	e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
	e.Color = ColorSequence.new(Color3.new(1, 1, 1), color)
	e.Drag = 4
	e.LightEmission = 0.3
	e.Parent = holder
	local spec = Config.Sounds.poof
	if spec and spec.id ~= "" and sfxVolume > 0 and (position - camPos).Magnitude <= Config.SoundRange then
		local snd = Instance.new("Sound")
		snd.SoundId = spec.id
		snd.Volume = spec.volume * sfxVolume
		snd.PlaybackSpeed = spec.pitch
		snd.RollOffMode = Enum.RollOffMode.InverseTapered
		snd.RollOffMinDistance = Config.SoundRollOff[1]
		snd.RollOffMaxDistance = Config.SoundRollOff[2]
		snd.Parent = holder
		snd:Play()
	end
	holder.Parent = workspace.CurrentCamera
	e:Emit(if lowGraphics then 10 else 24)
	Debris:AddItem(holder, 3)
end

-- "Zzz": three letters floating up and fading, one every ~1.2 s
local function zzz(r: Rig)
	local root = r.root
	if not root or r.mode ~= "world" or r.camDist > Config.Perf.ZzzRange or (hideOthers and r.ownerId ~= myId) then
		return
	end
	local gui = r.zzz
	if not gui or not gui.Parent then
		local g = Instance.new("BillboardGui")
		g.Name = "SockAnimZzz"
		g.Size = UDim2.fromOffset(70, 90)
		g.StudsOffset = r.pinS + Vector3.new(0.5 * r.unit, 0.6 * r.unit, 0)
		g.LightInfluence = 0
		g.MaxDistance = Config.Perf.ZzzRange
		g.Adornee = root
		table.clear(r.zzzLabels)
		for i = 1, 3 do
			local label = Instance.new("TextLabel")
			label.Name = "Z" .. i
			label.AnchorPoint = Vector2.new(0.5, 1)
			label.Size = UDim2.fromOffset(18 + i * 5, 18 + i * 5)
			label.BackgroundTransparency = 1
			label.Font = Enum.Font.FredokaOne
			label.TextScaled = true
			label.Text = if i == 1 then "z" else "Z"
			label.TextColor3 = Color3.fromRGB(235, 230, 255)
			label.TextStrokeColor3 = Color3.fromRGB(40, 30, 70)
			label.TextStrokeTransparency = 0.3
			label.TextTransparency = 1
			label.Parent = g
			table.insert(r.zzzLabels, label)
		end
		g.Parent = root
		r.zzz = g
	end
	r.zzzIndex = r.zzzIndex % 3 + 1
	local label = r.zzzLabels[r.zzzIndex]
	if label then
		label.Position = UDim2.fromScale(0.25, 1)
		label.Rotation = -10
		label.TextTransparency = 0
		TweenService:Create(label, TweenInfo.new(2.4, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {
			Position = UDim2.fromScale(0.8, 0.15),
			Rotation = 15,
			TextTransparency = 1,
		}):Play()
	end
end

-- ---------- moves ----------
-- IDLES / HANGS: loops, (r, t, A, beat): t = scaled time + phase, A = amplitude (energy x weight),
-- beat = server-synced seconds (shared rhythms). CLIPS: one-shots, fn(r, u, A, pu): u = 0..1
-- progress, pu = last frame's (for cues). suppress = how much of the idle the clip replaces.

type Loop = (r: Rig, t: number, A: number, beat: number) -> ()
type Clip = { dur: number, suppress: number, fn: (r: Rig, u: number, A: number, pu: number) -> () }

local IDLES: { [string]: Loop } = {}

IDLES.mope = function(r, t, A)
	local sway = sin(t * 0.9)
	chain(r, 0.12 * A + 0.05 * A * sin(t * 0.45), 0.1 * A * sway, 0.05 * A * sin(t * 0.45 + 1), TOP)
	cuff(r, 0.1 * A, 0.06 * A * sin(t * 0.9 - 0.8), 0)
	bodyRot(r, 0, 0.03 * A * sway, 0)
	squash(r, 0.03 * A * (0.5 + 0.5 * sin(t * 0.7)))
end

IDLES.chomp = function(r, t, A)
	local b = abs(sin(t * 3.4))
	body(r, 0, 0.16 * A * b, 0)
	bodyRot(r, 0, 0.05 * A * sin(t * 1.7), 0)
	local snap = max(0, sin(t * 6.8)) ^ 3
	chain(r, 0.12 * A * snap, 0, 0, TOP)
	jaw(r, 0.6 * snap)
	foot(r, 0.15 * A * (1 - b), 0, 0)
end

IDLES.stiff = function(r, t, A)
	local raw = sin(t * 0.8)
	local q = floor(raw * 3 + 0.5) / 3 -- seven creaky levels
	local s = q + (raw - q) * 0.2
	chain(r, 0.02 * A, 0.1 * A * s, 0, BASE)
	bodyRot(r, 0, 0.02 * A * s, 0)
end

IDLES.pump = function(r, t, A)
	local c = 0.5 - 0.5 * cos(t * 2.4)
	squash(r, 0.08 * A * c)
	chain(r, 0.1 * A * c, 0.03 * A * sin(t * 1.2), 0, LOW)
	body(r, 0, 0.05 * A * (1 - c), 0)
end

IDLES.posh = function(r, t, A)
	chain(r, -0.04 * A + 0.03 * A * sin(t * 0.6), 0.02 * A * sin(t * 0.4), 0.18 * A * sin(t * 0.25), TOP)
	squash(r, -0.02 * A)
end

IDLES.wiggle = function(r, t, A)
	toe(r, 0.35 * A * sin(t * 11))
	foot(r, 0.06 * A * sin(t * 5.5), 0, 0)
	local b = sin(t * 2.6)
	chain(r, 0, 0.1 * A * b, 0, EVEN)
	body(r, 0, 0.08 * A * abs(b), 0)
end

IDLES.ponder = function(r, t, A)
	chain(r, 0.1 * A * sin(t * 0.9), 0.08 * A * sin(t * 0.3), 0.06 * A * sin(t * 0.45), TOP)
end

IDLES.noodle = function(r, t, A)
	wave(r, 0.09 * A, 0.04 * A, t * 1.8, 0.9)
end

IDLES.skate = function(r, t, A)
	local g = sin(t * 1.2)
	body(r, 0.45 * A * g, 0, 0)
	chain(r, 0, 0.12 * A * cos(t * 1.2), 0, BASE)
	bodyRot(r, 0, 0, 0.08 * A * g)
end

IDLES.tense = function(r, t, A)
	local j = sin(t * 37) * 0.6 + sin(t * 23) * 0.4
	chain(r, 0.012 * A * j, 0.02 * A * sin(t * 41), 0, EVEN)
	local crunch = max(0, sin(t * 0.7)) ^ 6
	squash(r, 0.12 * A * crunch)
	chain(r, 0.15 * A * crunch, 0, 0, TOP)
end

IDLES.pogo = function(r, t, A)
	local cyc = (t * 1.5) % 1
	local h = sin(cyc * PI)
	body(r, 0, 0.5 * A * h, 0)
	bodyRot(r, 0, 0.04 * A * sin(t * 0.75), 0)
	local land = max(0, 1 - min(cyc, 1 - cyc) / 0.12)
	squash(r, 0.12 * A * land - 0.05 * A * h)
	pogo(r, 0.25 * land)
	chain(r, -0.05 * A * h, 0, 0, TOP)
end

IDLES.bop = function(r, _t, A, beat)
	local b = beat * 2 -- 120 BPM, the same beat on every client
	local hit = exp(-(b % 1) * 6)
	chain(r, 0.16 * A * hit, 0.06 * A * sin(b * PI), 0, TOP)
	body(r, 0, 0.1 * A * hit, 0)
	bodyRot(r, 0, 0, 0.1 * A * sin(b * PI * 0.5))
end

IDLES.swim = function(r, t, A)
	local s = sin(t * 1.6)
	body(r, 0, 0.18 * A * (0.5 + 0.5 * s), 0)
	bodyRot(r, 0.04 * A * cos(t * 1.6), 0, 0)
	tentacles(r, t * 2.2, 0.35 * A, 0.15 * A, 0.7)
	if #r.tents == 0 or not r.bonesOn then
		squash(r, 0.05 * A * s)
	end
end

IDLES.attention = function(r, t, A)
	squash(r, -0.03 * A + 0.02 * A * sin(t * 1.2))
	chain(r, -0.03 * A, 0.015 * A * sin(t * 0.5), 0.04 * A * sin(t * 0.35), TOP)
end

IDLES.slouch = function(r, t, A)
	chain(r, -0.1 * A, 0.16 * A + 0.05 * A * sin(t * 0.5), 0.05 * A * sin(t * 0.3), TOP)
	cuff(r, 0.12 * A, 0.05 * A * sin(t * 0.5 - 0.5), 0)
	squash(r, 0.04 * A)
end

IDLES.serpent = function(r, t, A)
	neckWave(r, 0.12 * A, 0.05 * A, t * 0.9, 0.6)
	head(r, 0.05 * A * sin(t * 0.7), 0, 0.35 * A * sin(t * 0.4))
	chain(r, 0, 0.03 * A * sin(t * 0.6), 0, BASE)
end

IDLES.jitter = function(r, t, A)
	local n1 = sin(t * 53) * sin(t * 7.3)
	chain(r, 0.03 * A * n1, 0.04 * A * sin(t * 61) * sin(t * 3.1), 0, EVEN)
	body(r, 0.02 * A * sin(t * 71), 0.02 * A * abs(sin(t * 47)), 0)
	local j = (t * 0.33) % 1
	if j < 0.05 then
		local k = sin(j / 0.05 * PI)
		squash(r, -0.12 * A * k)
		chain(r, 0.1 * A * k * hash(floor(t * 0.33)), 0.12 * A * k, 0, EVEN)
	end
end

IDLES.regal = function(r, t, A)
	chain(r, -0.05 * A, 0.05 * A * sin(t * 0.5), 0.08 * A * sin(t * 0.25), TOP)
	bodyRot(r, 0, 0.02 * A * sin(t * 0.5), 0)
	squash(r, -0.03 * A)
end

IDLES.strut = function(r, t, A)
	local b = t * 1.6
	local hitch = abs(sin(b * PI))
	body(r, 0, 0.1 * A * hitch, 0)
	bodyRot(r, 0, 0.05 * A * sin(b * PI), 0)
	chain(r, -0.06 * A, 0.08 * A * sin(b * PI), 0.08 * A * sin(b * PI * 0.5), TOP)
	hat(r, 0.04 * A * sin(b * TAU), 0, 0)
end

IDLES.haunt = function(r, t, A)
	bodyS(r, 0, 0.35 + 0.15 * sin(t * 0.8), 0)
	r.bry += 0.35 * sin(t * 0.15)
	bodyRot(r, 0.03 * sin(t * 0.5), 0, 0)
	chain(r, 0.05 * A * sin(t * 0.7), 0.06 * A * sin(t * 0.53), 0, EVEN)
end

IDLES.talk = function(r, t, A)
	local talking = if (t * 0.2) % 1 < 0.6 then 1 else 0
	local syll = max(0, sin(t * 9)) * (0.5 + 0.5 * sin(t * 1.7)) * talking
	talk(r, 0.6 * syll, A)
	chain(r, 0.04 * A * sin(t * 1.1), 0.1 * A * sin(t * 0.8), 0.08 * A * sin(t * 0.6), TOP)
	body(r, 0, 0.06 * A * abs(sin(t * 2.2)), 0)
end

-- hanging on the line: (r, t, A, beat); r.perk (0..1) is how excited it is about a nearby player
local HANGS: { [string]: Loop } = {}

HANGS.limp = function(r, t, A)
	local P = 1 + r.perk
	hangSwing(r, 0.12 * A * P * sin(t * 1.3), 0.05 * A * sin(t * 0.9))
	foot(r, 0.15 * A * P * sin(t * 1.3 - 0.9), 0, 0)
end

HANGS.kick = function(r, t, A)
	local P = 1 + r.perk
	hangSwing(r, 0.08 * A * P * sin(t * 2.2), 0.03 * A * sin(t * 1.4))
	foot(r, 0.35 * A * P * sin(t * (4.4 + r.perk * 2)), 0, 0)
	toe(r, 0.2 * A * sin(t * 6))
end

HANGS.stiff = function(r, t, A)
	bodyRot(r, 0, 0.06 * A * (1 + r.perk) * sin(t * 1.1), 0)
end

HANGS.posh = function(r, t, A)
	hangSwing(r, 0.05 * A * (1 + r.perk) * sin(t * 0.8), 0)
	foot(r, -0.2 * A, 0, 0)
	bodyRot(r, 0, 0, 0.1 * A * sin(t * 0.4))
end

HANGS.noodle = function(r, t, A)
	wave(r, 0.12 * A * (1 + r.perk), 0.04 * A, t * 2.2, 0.9)
	foot(r, 0.15 * A * sin(t * 2.2 - 2), 0, 0)
end

HANGS.bounce = function(r, t, A)
	squash(r, 0.12 * A * (1 + r.perk) * sin(t * 5))
	hangSwing(r, 0.05 * A * sin(t * 1.7), 0)
	foot(r, 0.2 * A * sin(t * 5 - 1), 0, 0)
	pogo(r, 0.1 * max(0, sin(t * 5)))
end

HANGS.tentacles = function(r, t, A)
	tentacles(r, t * 1.6, 0.3 * A * (1 + r.perk), 0.2 * A, 0.6)
	bodyRot(r, 0, 0.05 * A * sin(t * 0.9), 0)
end

HANGS.float = function(r, t, A)
	r.bry += 0.4 * sin(t * 0.3)
	chain(r, 0.05 * A * sin(t * 0.7), 0.04 * A * sin(t * 0.5), 0, EVEN)
	hangSwing(r, 0.04 * A * sin(t * 0.6), 0.03 * A * sin(t * 0.45))
end

HANGS.jitter = function(r, t, A)
	hangSwing(r, 0.04 * A * sin(t * 31), 0.03 * A * sin(t * 27))
	foot(r, 0.08 * A * sin(t * 37) + 0.3 * A * r.perk * sin(t * 8), 0, 0)
end

HANGS.groove = function(r, _t, A, beat)
	local b = beat * 2
	hangSwing(r, 0.1 * A * (1 + r.perk) * sin(b * PI), 0)
	foot(r, 0.3 * A * exp(-(b % 1) * 6), 0, 0)
end

HANGS.serpent = function(r, t, A)
	neckWave(r, 0.14 * A * (1 + r.perk), 0.06 * A, t * 0.9, 0.6)
	head(r, 0, 0, 0.3 * A * sin(t * 0.5))
	hangSwing(r, 0.04 * A * sin(t * 0.8), 0)
end

HANGS.skate = function(r, t, A)
	hangSwing(r, 0.22 * A * (1 + r.perk * 0.5) * sin(t * 1.6), 0.05 * A * sin(t * 0.8))
	foot(r, 0.1 * A * sin(t * 1.6 - 1), 0, 0)
end

HANGS.ponder = function(r, t, A)
	hangSwing(r, 0.06 * A * (1 + r.perk) * sin(t * 0.7), 0)
	foot(r, 0.18 * A * max(0, sin(t * 2)) ^ 4, 0, 0)
	chain(r, 0.04 * A * sin(t * 0.9), 0, 0, TOP)
end

local CLIPS: { [string]: Clip } = {}

-- fidgets

CLIPS.sigh = { dur = 2.4, suppress = 0.6, fn = function(r, u, A)
	local inhale = bump(u, 0, 0.4)
	local exhale = bump(u, 0.3, 1)
	squash(r, (-0.07 * inhale + 0.12 * exhale) * A)
	chain(r, (-0.12 * inhale + 0.4 * exhale) * A, 0, 0, TOP)
	cuff(r, 0.25 * exhale * A, 0, 0)
end }

CLIPS.droop = { dur = 2.2, suppress = 0.7, fn = function(r, u, A)
	local k = ramp(u, 0, 0.3) * (1 - ramp(u, 0.75, 1))
	chain(r, 0.5 * k * A, 0.12 * k * A, 0, HIGH)
	cuff(r, 0.3 * k * A, 0, 0)
	squash(r, 0.08 * k * A)
end }

CLIPS.chomp = { dur = 1.0, suppress = 0.5, fn = function(r, u, A)
	local s = max(bump(u, 0.05, 0.25), bump(u, 0.35, 0.55), bump(u, 0.65, 0.85))
	chain(r, 0.35 * s * A, 0, 0, TOP)
	jaw(r, s)
	body(r, 0, 0, 0.08 * s * A)
end }

CLIPS.lunge = { dur = 1.1, suppress = 0.8, fn = function(r, u, A)
	local wind = bump(u, 0, 0.35)
	local go = bump(u, 0.3, 0.75)
	local snap = bump(u, 0.5, 0.65)
	chain(r, (-0.15 * wind + 0.45 * go) * A, 0, 0, EVEN)
	chain(r, 0.25 * snap * A, 0, 0, TOP)
	body(r, 0, 0.1 * go * A, 0.35 * go * A)
end }

CLIPS.wiggle = { dur = 1.2, suppress = 0.4, fn = function(r, u, A)
	local k = bump(u, 0, 1)
	chain(r, 0, 0.18 * sin(u * TAU * 4) * k * A, 0.1 * sin(u * TAU * 3) * k * A, EVEN)
	foot(r, 0.2 * sin(u * TAU * 4) * k * A, 0, 0)
	tentacles(r, u * TAU * 4, 0.3 * k * A, 0.2 * k * A, 0.8)
end }

-- creaky steps: the level jumps, it doesn't glide
local function creakLevel(u: number): number
	if u < 0.1 then
		return 0
	elseif u < 0.25 then
		return 0.33
	elseif u < 0.4 then
		return 0.66
	elseif u < 0.75 then
		return 1
	elseif u < 0.9 then
		return 0.5
	end
	return 0
end

CLIPS.creak = { dur = 1.8, suppress = 0.7, fn = function(r, u, A)
	local lvl = creakLevel(u)
	chain(r, 0.03 * lvl * A, 0.25 * lvl * A, 0, BASE)
end }

CLIPS.creakturn = { dur = 2.0, suppress = 0.7, fn = function(r, u, A)
	local lvl = creakLevel(u)
	chain(r, 0, 0, 0.35 * lvl * A, BASE)
	bodyRot(r, 0, 0, 0.1 * lvl * A)
end }

CLIPS.nod = { dur = 1.6, suppress = 0.5, fn = function(r, u, A)
	chain(r, 0.25 * max(0, sin(u * TAU * 2)) * A, 0, 0, TOP)
end }

CLIPS.lookaround = { dur = 3.0, suppress = 0.6, fn = function(r, u, A)
	local yaw = 0.55 * (ramp(u, 0.05, 0.25) - 2 * ramp(u, 0.4, 0.6) + ramp(u, 0.75, 0.95))
	lookAt(r, yaw * A, 0.05 * A, 1)
end }

CLIPS.flex = { dur = 2.0, suppress = 0.85, fn = function(r, u, A)
	local pose = ramp(u, 0, 0.2) * (1 - ramp(u, 0.8, 1))
	local strain = sin(u * TAU * 9) * bump(u, 0.25, 0.75)
	chain(r, -0.1 * pose * A, (0.25 * pose + 0.03 * strain) * A, 0, BASE)
	chain(r, 0.2 * pose * A, -0.55 * pose * A, 0, TOP)
	squash(r, 0.1 * pose * A)
end }

CLIPS.squats = { dur = 2.4, suppress = 0.8, fn = function(r, u, A)
	local c = (1 - cos(u * TAU * 3)) / 2
	squash(r, 0.25 * c * A)
	chain(r, 0.18 * c * A, 0, 0, EVEN)
end }

CLIPS.wipe = { dur = 1.3, suppress = 0.5, fn = function(r, u, A)
	local k = bump(u, 0, 1)
	cuff(r, 0.15 * k * A, 0, 0.4 * sin(u * TAU * 2.5) * k * A)
	chain(r, 0.12 * k * A, 0, 0, TOP)
end }

CLIPS.monocle = { dur = 1.5, suppress = 0.6, fn = function(r, u, A)
	local k = bump(u, 0, 1)
	chain(r, -0.12 * k * A, 0.06 * sin(u * TAU * 6) * k * A, 0.18 * k * A, TOP)
	jiggle(r, u * 20, 0.08 * k)
end }

-- a deep bow toward whoever it is looking at
CLIPS.bow = { dur = 2.4, suppress = 0.9, fn = function(r, u, A)
	local k = ramp(u, 0.05, 0.35) * (1 - ramp(u, 0.7, 0.95))
	local turn = ramp(u, 0, 0.2) * (1 - ramp(u, 0.85, 1))
	lookAt(r, r.lookYaw * turn * 0.8, 0, 1)
	chain(r, 0.7 * k * A, 0, 0, EVEN)
	cuff(r, 0.2 * k * A, 0, 0)
	hat(r, 0.2 * k * A, 0, 0.1 * k)
end }

CLIPS.toewiggle = { dur = 1.6, suppress = 0.4, fn = function(r, u, A)
	local k = bump(u, 0, 1)
	toe(r, 0.4 * sin(u * TAU * 8) * k * A)
	foot(r, 0.08 * sin(u * TAU * 4) * k * A, 0, 0.1 * sin(u * TAU * 6) * k * A)
	chain(r, 0, 0.06 * sin(u * TAU * 4) * k * A, 0, BASE)
end }

CLIPS.tiptoe = { dur = 2.6, suppress = 0.85, fn = function(r, u, A, pu)
	local up = ramp(u, 0, 0.15) * (1 - ramp(u, 0.85, 1))
	foot(r, -0.55 * up * A, 0, 0)
	body(r, 0.25 * sin(u * TAU * 2) * up * A, (0.25 + 0.06 * abs(sin(u * TAU * 4))) * up * A, 0)
	chain(r, 0, 0.12 * sin(u * TAU * 2 + 0.6) * up * A, 0.2 * sin(u * TAU) * up * A, EVEN)
	toe(r, 0.3 * sin(u * TAU * 8) * up * A)
	spin(r, TAU * ramp(u, 0.35, 0.65))
	cue(r, pu, u, 0.35, "whoosh")
end }

CLIPS.ponder = { dur = 2.8, suppress = 0.6, fn = function(r, u, A)
	local k = ramp(u, 0, 0.25) * (1 - ramp(u, 0.75, 1))
	chain(r, (0.12 + 0.05 * sin(u * TAU * 3)) * k * A, 0.28 * k * A, 0.2 * k * A, TOP)
	jiggle(r, u * 12, 0.06 * k)
end }

CLIPS.eureka = { dur = 1.8, suppress = 0.9, fn = function(r, u, A, pu)
	local crouch = bump(u, 0, 0.3)
	local air = arc(u, 0.25, 0.65)
	local land = bump(u, 0.62, 0.8)
	squash(r, (0.18 * crouch - 0.22 * air + 0.15 * land) * A)
	chain(r, (0.2 * crouch - 0.35 * air) * A, 0, 0, TOP)
	body(r, 0, 1.0 * air * A, 0)
	cue(r, pu, u, 0.25, "boing")
	if pu < 0.4 and u >= 0.4 then
		sparkle(r, 12, Color3.fromRGB(255, 240, 150))
	end
end }

CLIPS.noodlewave = { dur = 2.4, suppress = 0.7, fn = function(r, u, A)
	local k = bump(u, 0, 1)
	wave(r, 0.3 * k * A, 0.1 * k * A, u * TAU * 2, 1.0)
end }

CLIPS.skatespin = { dur = 2.0, suppress = 0.9, fn = function(r, u, A, pu)
	body(r, 0.6 * sin(u * TAU) * A, 0, 0)
	spin(r, TAU * 2 * ramp(u, 0.3, 0.8))
	chain(r, -0.1 * bump(u, 0.3, 0.8) * A, 0, 0, EVEN)
	cue(r, pu, u, 0.3, "whoosh")
end }

CLIPS.glide = { dur = 1.8, suppress = 0.6, fn = function(r, u, A)
	body(r, 0.7 * sin(u * TAU) * A, 0, 0)
	chain(r, 0, 0.18 * cos(u * TAU) * bump(u, 0, 1) * A, 0, BASE)
end }

CLIPS.crunch = { dur = 1.4, suppress = 0.8, fn = function(r, u, A)
	local c = ramp(u, 0, 0.3) * (1 - ramp(u, 0.6, 0.75))
	local pop = bump(u, 0.65, 0.95)
	local sh = sin(u * TAU * 14) * c
	squash(r, (0.28 * c - 0.15 * pop) * A)
	chain(r, (0.4 * c + 0.03 * sh) * A, 0.03 * sh * A, 0, TOP)
	body(r, 0, 0.3 * pop * A, 0)
end }

CLIPS.crunchpop = { dur = 2.0, suppress = 0.95, fn = function(r, u, A, pu)
	local c = ramp(u, 0, 0.35) * (1 - ramp(u, 0.45, 0.5))
	local air = arc(u, 0.48, 0.85)
	local sh = sin(u * TAU * 16) * c
	squash(r, (0.32 * c - 0.25 * air + 0.12 * bump(u, 0.83, 0.95)) * A)
	chain(r, (0.45 * c + 0.03 * sh) * A, 0.04 * sh * A, 0, TOP)
	body(r, 0, 1.2 * air * A, 0)
	spin(r, TAU * ramp(u, 0.5, 0.82))
	cue(r, pu, u, 0.48, "boing")
end }

CLIPS.shiverburst = { dur = 1.0, suppress = 0.5, fn = function(r, u, A)
	local k = bump(u, 0, 1)
	chain(r, 0.05 * sin(u * TAU * 18) * k * A, 0.06 * sin(u * TAU * 23) * k * A, 0, EVEN)
	body(r, 0.03 * sin(u * TAU * 29) * k * A, 0, 0)
end }

CLIPS.doublebounce = { dur = 1.4, suppress = 0.8, fn = function(r, u, A, pu)
	local air = arc(u, 0.05, 0.45) + arc(u, 0.5, 0.95) * 1.2
	local land = bump(u, 0.42, 0.55) + bump(u, 0.92, 1)
	body(r, 0, 0.9 * air * A, 0)
	squash(r, (0.15 * land - 0.1 * air) * A)
	pogo(r, 0.25 * land)
	cue(r, pu, u, 0.05, "boing")
	cue(r, pu, u, 0.5, "boing")
end }

CLIPS.pogoflip = { dur = 1.6, suppress = 1, fn = function(r, u, A, pu)
	local air = arc(u, 0.1, 0.85)
	body(r, 0, 1.8 * air * A, 0)
	flip(r, TAU * ramp(u, 0.2, 0.75) * r.dir)
	squash(r, (0.15 * bump(u, 0, 0.12) - 0.12 * air + 0.15 * bump(u, 0.85, 1)) * A)
	pogo(r, 0.3 * (bump(u, 0, 0.12) + bump(u, 0.85, 1)))
	cue(r, pu, u, 0.1, "boing")
	cue(r, pu, u, 0.2, "whoosh")
end }

CLIPS.scratch = { dur = 1.6, suppress = 0.5, fn = function(r, u, A)
	local k = bump(u, 0, 1)
	cuff(r, 0.1 * k * A, 0, 0.5 * sin(u * TAU * 6) * k * A)
	chain(r, 0.12 * max(0, sin(u * TAU * 4)) * k * A, 0, 0, TOP)
end }

CLIPS.headbang = { dur = 1.6, suppress = 0.7, fn = function(r, u, A)
	local k = bump(u, 0, 1)
	local hb = max(0, sin(u * TAU * 6)) ^ 2
	chain(r, 0.4 * hb * k * A, 0, 0, TOP)
	body(r, 0, 0.08 * hb * k * A, 0)
end }

CLIPS.scratchspin = { dur = 2.2, suppress = 0.9, fn = function(r, u, A, pu)
	local k = bump(u, 0, 0.55)
	cuff(r, 0.1 * k * A, 0, 0.5 * sin(u * TAU * 8) * k * A)
	chain(r, 0.12 * max(0, sin(u * TAU * 6)) * k * A, 0, 0, TOP)
	body(r, 0, 0.4 * arc(u, 0.55, 0.9) * A, 0)
	spin(r, TAU * ramp(u, 0.55, 0.9))
	cue(r, pu, u, 0.55, "whoosh")
end }

CLIPS.swimstroke = { dur = 2.0, suppress = 0.7, fn = function(r, u, A)
	local pulse = bump(u, 0, 0.5) - 0.6 * bump(u, 0.45, 1)
	tentacles(r, u * TAU, 0, 0, 0.5)
	if r.bonesOn then
		for c, list in ipairs(r.tents) do
			for j, s in ipairs(list) do
				local th = 0.6 * pulse * A / j
				s.rx += th * r.tentKX[c]
				s.rz += th * r.tentKZ[c]
			end
		end
	end
	body(r, 0, 0.5 * arc(u, 0.3, 1) * A, 0)
	squash(r, 0.08 * pulse * A)
end }

CLIPS.swirl = { dur = 2.4, suppress = 0.9, fn = function(r, u, A, pu)
	local k = bump(u, 0, 1)
	body(r, 0, 0.6 * k * A, 0)
	spin(r, TAU * ramp(u, 0.15, 0.85))
	tentacles(r, u * TAU * 3, 0.5 * k * A, 0.5 * k * A, 0.9)
	cue(r, pu, u, 0.15, "whoosh")
end }

CLIPS.salute = { dur = 2.2, suppress = 0.85, fn = function(r, u, A)
	local up = ramp(u, 0, 0.12) * (1 - ramp(u, 0.85, 1))
	squash(r, -0.08 * up * A)
	cuff(r, -0.15 * up * A, 0.35 * up * A, 0)
	hat(r, -0.1 * up * A, 0.25 * up * A, 0)
	chain(r, (-0.06 + 0.02 * sin(u * TAU * 12)) * up * A, 0, 0, TOP)
end }

CLIPS.march = { dur = 2.6, suppress = 0.8, fn = function(r, u, A, pu)
	local k = bump(u, 0, 1)
	local st = sin(u * TAU * 2)
	body(r, 0, 0.15 * abs(sin(u * TAU * 4)) * k * A, 0)
	chain(r, 0, 0.1 * st * k * A, 0, BASE)
	foot(r, 0.25 * max(0, st) * k * A, 0, 0)
	hat(r, 0.05 * sin(u * TAU * 4) * k, 0, 0)
	cue(r, pu, u, 0.125, "boing")
end }

CLIPS.waft = { dur = 2.2, suppress = 0.8, fn = function(r, u, A)
	local k = bump(u, 0, 1)
	chain(r, -0.15 * k * A, 0, 0.4 * sin(u * TAU * 3) * k * A, TOP)
	cuff(r, 0, 0.2 * sin(u * TAU * 3 + 0.5) * k * A, 0)
	squash(r, -0.05 * k * A)
end }

CLIPS.slouch = { dur = 2.4, suppress = 0.7, fn = function(r, u, A)
	local k = ramp(u, 0, 0.3) * (1 - ramp(u, 0.75, 1))
	chain(r, -0.2 * k * A, 0.25 * k * A, 0, TOP)
	squash(r, 0.1 * k * A)
end }

CLIPS.yawn = { dur = 2.2, suppress = 0.8, fn = function(r, u, A)
	local stretch = bump(u, 0, 0.6)
	chain(r, -0.35 * stretch * A, 0, 0, TOP)
	squash(r, -0.12 * stretch * A)
	jaw(r, stretch)
	chain(r, 0, 0.08 * sin(u * TAU * 3) * bump(u, 0.6, 1) * A, 0, EVEN)
end }

CLIPS.dip = { dur = 2.4, suppress = 0.7, fn = function(r, u, A)
	local k = bump(u, 0, 1)
	neck(r, 0.6 * k * A, 0, 0, HIGH)
	head(r, -0.3 * k * A, 0, 0)
end }

CLIPS.rise = { dur = 3.0, suppress = 0.9, fn = function(r, u, A, pu)
	local k = ramp(u, 0, 0.2) * (1 - ramp(u, 0.85, 1))
	neck(r, -0.3 * k * A, 0, 0, EVEN)
	squash(r, -0.15 * k * A)
	lookAt(r, 0.6 * sin(u * TAU * 1.5) * k, 0.1 * k, 1)
	body(r, 0, 0.3 * k * A, 0)
	if pu < 0.2 and u >= 0.2 then
		sparkle(r, 14, nil)
	end
end }

-- an electric jolt; r.actRnd / r.momX pick its direction
local function jolt(r: Rig, u: number, A: number, seed: number)
	local decay = exp(-u * 6) * (1 - ramp(u, 0.85, 1))
	squash(r, -0.2 * decay * A)
	chain(r, 0.25 * decay * hash(seed) * A, 0.3 * decay * hash(seed + 1) * A, 0.25 * decay * hash(seed + 2) * A, EVEN)
	body(r, 0.08 * decay * sin(u * TAU * 15) * A, 0.15 * decay * A, 0)
	foot(r, 0.4 * decay * hash(seed + 3) * A, 0, 0)
end

CLIPS.jolt = { dur = 0.6, suppress = 0.6, fn = function(r, u, A, pu)
	jolt(r, u, A, r.actRnd * 100)
	if pu <= 0 and u > 0 then
		sparkle(r, 10, Color3.fromRGB(150, 230, 255))
		playSound(r, "zap")
	end
end }

CLIPS.overload = { dur = 2.2, suppress = 1, fn = function(r, u, A, pu)
	for i = 0, 2 do
		local a = i * 0.22
		if u >= a and u < a + 0.3 then
			jolt(r, (u - a) / 0.3, A, r.actRnd * 100 + i * 7)
		end
		if pu < a and u >= a then
			sparkle(r, 8, Color3.fromRGB(150, 230, 255))
			playSound(r, "zap")
		end
	end
	body(r, 0, 0.6 * arc(u, 0.6, 0.95) * A, 0)
	spin(r, TAU * ramp(u, 0.6, 0.92))
	cue(r, pu, u, 0.6, "whoosh")
end }

CLIPS.toeraise = { dur = 2.2, suppress = 0.7, fn = function(r, u, A)
	local k = ramp(u, 0.05, 0.3) * (1 - ramp(u, 0.75, 0.95))
	foot(r, 0.6 * k * A, 0, 0)
	chain(r, -0.15 * k * A, -0.1 * k * A, 0, TOP)
end }

CLIPS.decree = { dur = 3.0, suppress = 0.9, fn = function(r, u, A, pu)
	local k = ramp(u, 0.05, 0.25) * (1 - ramp(u, 0.8, 0.95))
	foot(r, 0.6 * k * A, 0, 0)
	chain(r, -0.15 * k * A, -0.1 * k * A, 0, TOP)
	hat(r, -0.05 * k, 0, 0.05 * k)
	spin(r, TAU * ramp(u, 0.25, 0.8))
	body(r, 0, 0.15 * k * A, 0)
	cue(r, pu, u, 0.25, "whoosh")
end }

CLIPS.hattip = { dur = 1.8, suppress = 0.8, fn = function(r, u, A)
	local k = bump(u, 0.1, 0.8)
	hat(r, 0.45 * k * A, 0.1 * k * A, 0.25 * k)
	chain(r, 0.2 * k * A, 0, 0, TOP)
	jiggle(r, u * 15, 0.06 * k)
end }

-- glitchy twitch: jumps between frozen offsets at ~12 steps a second
CLIPS.glitch = { dur = 0.8, suppress = 0.7, fn = function(r, u, A)
	local q = floor(u * 10)
	local k = (1 - ramp(u, 0.8, 1)) * (if q % 2 == 0 then 1 else 0.3)
	local seed = r.actRnd * 100 + q
	local g = if r.reduce then 0.3 else 1
	bodyS(r, 0.25 * hash(seed) * k * g, 0, 0.2 * hash(seed + 1) * k * g)
	r.bry += 0.4 * hash(seed + 2) * k * g
	chain(r, 0.2 * hash(seed + 3) * k * A, 0.2 * hash(seed + 4) * k * A, 0, EVEN)
end }

-- slowly turns to stare (at you, or at the menu's camera)
CLIPS.stare = { dur = 3.2, suppress = 1, fn = function(r, u, A)
	local k = ramp(u, 0, 0.35) * (1 - ramp(u, 0.8, 1))
	lookAt(r, r.actYaw * k, r.actPitch * k, 1)
	r.bry += r.actYaw * 0.3 * k
	chain(r, 0, 0.15 * bump(u, 0.5, 0.75) * A, 0, TOP)
end }

-- The Lost Sock's signature: twitch, flicker out, stare
CLIPS.phase = { dur = 2.6, suppress = 1, fn = function(r, u, A)
	if u < 0.3 then
		CLIPS.glitch.fn(r, u / 0.3, A, 0)
	end
	r.fade = max(r.fade, 0.75 * abs(sin(u * TAU * 7)) * bump(u, 0.25, 0.6))
	if u > 0.45 then
		CLIPS.stare.fn(r, (u - 0.45) / 0.55, A, 0)
	end
end }

CLIPS.gesture = { dur = 1.8, suppress = 0.6, fn = function(r, u, A)
	local k = bump(u, 0, 1)
	chain(r, 0.15 * sin(u * TAU * 2) * k * A, 0.3 * sin(u * TAU * 1.5) * k * A, 0.25 * sin(u * TAU) * k * A, TOP)
	jaw(r, 0.5 * max(0, sin(u * TAU * 5)) * k)
end }

CLIPS.chatter = { dur = 1.6, suppress = 0.5, fn = function(r, u, A)
	local k = bump(u, 0, 1)
	local j = max(0, sin(u * TAU * 9))
	talk(r, 0.8 * j * k, A)
	body(r, 0, 0.05 * j * k * A, 0)
end }

CLIPS.monologue = { dur = 3.4, suppress = 0.9, fn = function(r, u, A, pu)
	local talking = 1 - ramp(u, 0.68, 0.75)
	local j = max(0, sin(u * TAU * 12)) * talking
	talk(r, 0.8 * j, A)
	chain(r, 0.1 * sin(u * TAU * 2) * talking * A, 0.35 * sin(u * TAU * 1.3) * talking * A, 0.3 * sin(u * TAU * 0.9) * talking * A, TOP)
	chain(r, 0.6 * bump(u, 0.75, 1) * A, 0, 0, EVEN)
	if pu < 0.75 and u >= 0.75 then
		sparkle(r, 12, nil)
	end
end }

CLIPS.mopespin = { dur = 3.0, suppress = 0.9, fn = function(r, u, A)
	spin(r, TAU * ramp(u, 0.1, 0.7))
	chain(r, (0.3 * bump(u, 0, 0.75) + 0.35 * bump(u, 0.7, 1)) * A, 0, 0, TOP)
	squash(r, 0.1 * bump(u, 0.7, 1) * A)
end }

CLIPS.chompspin = { dur = 1.6, suppress = 0.9, fn = function(r, u, A, pu)
	spin(r, TAU * ramp(u, 0.1, 0.8))
	body(r, 0, 0.5 * arc(u, 0.1, 0.8) * A, 0)
	chain(r, 0.3 * max(0, sin(u * TAU * 4)) ^ 2 * A, 0, 0, TOP)
	cue(r, pu, u, 0.1, "boing")
end }

CLIPS.stiffbow = { dur = 2.6, suppress = 0.9, fn = function(r, u, A)
	local lvl = if u < 0.1 then 0 elseif u < 0.2 then 0.33 elseif u < 0.3 then 0.66 elseif u < 0.7 then 1 elseif u < 0.85 then 0.5 else 0
	chain(r, 0.6 * lvl * A, 0, 0, BASE)
end }

-- rarity flair (generic show-offs)

CLIPS.spin = { dur = 1.4, suppress = 0.9, fn = function(r, u, A, pu)
	local air = arc(u, 0.1, 0.8)
	body(r, 0, 0.8 * air * A, 0)
	spin(r, TAU * ramp(u, 0.15, 0.75))
	squash(r, (0.12 * bump(u, 0, 0.15) - 0.12 * air + 0.12 * bump(u, 0.78, 0.95)) * A)
	cue(r, pu, u, 0.1, "boing")
	cue(r, pu, u, 0.15, "whoosh")
end }

CLIPS.flip = { dur = 1.5, suppress = 1, fn = function(r, u, A, pu)
	local air = arc(u, 0.1, 0.85)
	body(r, 0, 1.4 * air * A, 0)
	flip(r, TAU * ramp(u, 0.2, 0.75) * r.dir)
	squash(r, (0.15 * bump(u, 0, 0.12) - 0.1 * air + 0.15 * bump(u, 0.85, 1)) * A)
	cue(r, pu, u, 0.1, "boing")
	cue(r, pu, u, 0.2, "whoosh")
end }

CLIPS.pose = { dur = 2.0, suppress = 0.85, fn = function(r, u, A)
	local k = ramp(u, 0, 0.15) * (1 - ramp(u, 0.8, 1))
	lookAt(r, r.lookYaw * k, 0.1 * k, 1)
	chain(r, -0.1 * k * A, 0.3 * k * A, 0.25 * k * A, EVEN)
	foot(r, 0.35 * k * A, 0, 0)
	squash(r, -0.06 * k * A)
	hat(r, 0, 0.15 * k * A, 0)
end }

-- in your drawer while a thief is in there
CLIPS.flail = { dur = 0.9, suppress = 0.7, fn = function(r, u, A, pu)
	local k = bump(u, 0, 1)
	chain(r, 0.25 * sin(u * TAU * 5) * k * A, 0.35 * sin(u * TAU * 6 + 1) * k * A, 0, EVEN)
	foot(r, 0.4 * sin(u * TAU * 7) * k * A, 0, 0)
	cue(r, pu, u, 0.05, "squeak")
end }

-- on the clothesline now and then
CLIPS.hangwiggle = { dur = 1.6, suppress = 0.5, fn = function(r, u, A)
	local k = bump(u, 0, 1)
	hangSwing(r, 0.15 * sin(u * TAU * 3) * k * A, 0.05 * sin(u * TAU * 2) * k * A)
	foot(r, 0.4 * sin(u * TAU * 5) * k * A, 0.1 * sin(u * TAU * 3) * k * A, 0)
	toe(r, 0.3 * sin(u * TAU * 7) * k * A)
	tentacles(r, u * TAU * 3, 0.3 * k * A, 0.2 * k * A, 0.8)
end }

-- moments (prio decides what may interrupt what)

local MOMENTS: { [string]: number } = { goodbye = 6, stolen = 5, bought = 4, home = 4, land = 4, paired = 3, wake = 2, flinch = 2, cheer = 1 }

-- bought: the server tweens it off the line (bones only for LandDelay), then a happy hop and spin
CLIPS.bought = { dur = 2.0, suppress = 1, fn = function(r, u, A, pu)
	local fly = bump(u, 0, 0.3)
	squash(r, -0.18 * fly * A)
	chain(r, -0.2 * fly * A, 0, 0, EVEN)
	foot(r, 0.4 * sin(u * TAU * 6) * fly * A, 0, 0)
	squash(r, 0.22 * bump(u, 0.27, 0.42) * A)
	local air = arc(u, 0.42, 0.72)
	body(r, 0, 0.9 * air * A, 0)
	spin(r, TAU * ramp(u, 0.44, 0.7))
	squash(r, (-0.12 * air + 0.12 * bump(u, 0.72, 0.82)) * A)
	chain(r, 0, 0.12 * sin(u * TAU * 4) * bump(u, 0.72, 1) * A, 0, EVEN)
	cue(r, pu, u, 0.42, "boing")
	cue(r, pu, u, 0.45, "whoosh")
end }

CLIPS.stolen = { dur = 1.4, suppress = 1, fn = function(r, u, A, pu)
	local k = 1 - ramp(u, 0.8, 1)
	chain(r, 0.35 * sin(u * TAU * 5) * k * A, 0.45 * sin(u * TAU * 6.5 + 1) * k * A, 0.2 * sin(u * TAU * 4) * k * A, EVEN)
	foot(r, 0.5 * sin(u * TAU * 8) * k * A, 0, 0)
	squash(r, -0.1 * bump(u, 0, 0.3) * A)
	tentacles(r, u * TAU * 5, 0.5 * k * A, 0.3 * k * A, 0.8)
	cue(r, pu, u, 0.02, "squeak")
	cue(r, pu, u, 0.5, "squeak")
end }

-- back home: a relieved sigh-droop, then a happy bounce
CLIPS.home = { dur = 2.4, suppress = 1, fn = function(r, u, A, pu)
	local d = bump(u, 0, 0.45)
	squash(r, 0.15 * d * A)
	chain(r, 0.45 * d * A, 0, 0, TOP)
	cuff(r, 0.3 * d * A, 0, 0)
	local air = arc(u, 0.48, 0.68) + arc(u, 0.7, 0.88) * 0.7
	body(r, 0, 0.6 * air * A, 0)
	squash(r, (-0.1 * air + 0.1 * (bump(u, 0.66, 0.72) + bump(u, 0.86, 0.94))) * A)
	chain(r, -0.15 * air * A, 0, 0, TOP)
	cue(r, pu, u, 0.48, "boing")
	cue(r, pu, u, 0.7, "boing")
end }

-- landed in a thief's drawer: a little dizzy
CLIPS.land = { dur = 1.6, suppress = 1, fn = function(r, u, A)
	squash(r, 0.2 * bump(u, 0.3, 0.45) * A)
	local wob = bump(u, 0.45, 1)
	chainS(r, 0.15 * sin(u * TAU * 3) * wob * A, 0, 0.15 * cos(u * TAU * 3) * wob * A, EVEN)
	body(r, 0, 0.25 * arc(u, 0.5, 0.65) * A, 0)
end }

-- a new pair: turn to each other, bop three times together, hop and spin
CLIPS.paired = { dur = 2.6, suppress = 0.9, fn = function(r, u, A, pu)
	local turn = ramp(u, 0, 0.15) * (1 - ramp(u, 0.85, 1))
	chainS(r, 0, r.momYaw * turn, 0, TOP)
	local hit = bump(u, 0.15, 0.25) + bump(u, 0.3, 0.4) + bump(u, 0.45, 0.55)
	chain(r, 0.2 * hit * A, 0, 0, TOP)
	squash(r, 0.1 * hit * A)
	body(r, 0, 0.12 * hit * A, 0)
	local air = arc(u, 0.6, 0.85)
	body(r, 0, 0.7 * air * A, 0)
	spin(r, TAU * ramp(u, 0.62, 0.83))
	tentacles(r, u * TAU * 3, 0.3 * A * bump(u, 0, 1), 0.2 * A, 0.8)
	cue(r, pu, u, 0.1, "chirp")
	cue(r, pu, u, 0.6, "boing")
	if pu < 0.6 and u >= 0.6 then
		sparkle(r, 10, Color3.fromRGB(120, 255, 160))
	end
end }

-- sold: wave, a little bow, then up, round and poof
CLIPS.goodbye = { dur = 2.6, suppress = 1, fn = function(r, u, A, pu)
	local wav = bump(u, 0, 0.6)
	chain(r, 0, 0.4 * sin(u * TAU * 4.5) * wav * A, 0, TOP)
	cuff(r, 0, 0.3 * sin(u * TAU * 4.5 - 0.6) * wav * A, 0)
	foot(r, 0.2 * wav * A, 0, 0)
	chain(r, 0.45 * bump(u, 0.55, 0.75) * A, 0, 0, EVEN)
	local up = ramp(u, 0.75, 1)
	bodyS(r, 0, 1.6 * up, 0)
	spin(r, TAU * 2 * up)
	r.fade = max(r.fade, ramp(u, 0.8, 1))
	cue(r, pu, u, 0.02, "goodbye")
	cue(r, pu, u, 0.75, "whoosh")
end }

CLIPS.cheer = { dur = 1.6, suppress = 0.8, fn = function(r, u, A, pu)
	local air = arc(u, 0.05, 0.4) + arc(u, 0.45, 0.8)
	body(r, 0, 0.55 * air * A, 0)
	squash(r, -0.12 * air * A)
	chain(r, -0.2 * air * A, 0.2 * sin(u * TAU * 3) * bump(u, 0, 1) * A, 0, TOP)
	foot(r, 0.3 * air * A, 0, 0)
	tentacles(r, u * TAU * 4, 0.4 * A * bump(u, 0, 1), 0.3 * A, 0.8)
	if r.cheerVoice then
		cue(r, pu, u, 0.05, "cheer")
	end
end }

-- a Towel Snap nearby: jerk away from it (momX / momZ = away, sock space)
CLIPS.flinch = { dur = 0.9, suppress = 0.9, fn = function(r, u, A, pu)
	local k = exp(-u * 4) * (1 - ramp(u, 0.85, 1))
	if r.state == "line" then
		hangSwing(r, 0.4 * r.momX * r.dir * k * A, 0.4 * r.momZ * k * A)
	else
		bendToward(r, r.momX, r.momZ, 0.45 * k * A, EVEN)
	end
	squash(r, 0.15 * k * A)
	chain(r, 0.04 * sin(u * TAU * 12) * k * A, 0, 0, EVEN)
	if r.cheerVoice then
		cue(r, pu, u, 0.02, "oof")
	end
end }

-- someone came near a dozing sock: a startled hop
CLIPS.wake = { dur = 1.2, suppress = 0.9, fn = function(r, u, A, pu)
	local air = arc(u, 0, 0.4)
	body(r, 0, 0.7 * air * A, 0)
	squash(r, (-0.18 * air + 0.12 * bump(u, 0.38, 0.5)) * A)
	chain(r, -0.2 * air * A, 0, 0, TOP)
	chain(r, 0, 0.12 * sin(u * TAU * 6) * bump(u, 0.45, 1) * A, 0, EVEN)
	cue(r, pu, u, 0.01, "squeak")
end }

local function clipFor(name: string?): Clip?
	if not name then
		return nil
	end
	local c = CLIPS[name]
	if not c then
		warnOnce("clip:" .. name, "no move called '" .. name .. "' - check SockAnimConfig")
	end
	return c
end

-- ---------- mutation flavour ----------

local function mutationLayer(r: Rig, t: number, beat: number, A: number, hanging: boolean, carried: boolean)
	local m = r.mut
	if not m then
		return
	end
	local a = (m.amp or 1) * A
	local f = m.freq or 1
	local style = m.style
	if style == "wobble" then
		wave(r, 0.045 * a, 0.035 * a, t * f, 0.8)
	elseif style == "jitter" then
		chainS(r, 0.012 * a * sin(t * f * 1.1), 0.012 * a * sin(t * f * 1.2), 0.012 * a * sin(t * f), EVEN)
		if clockNow >= r.nextZap then
			r.nextZap = clockNow + between(m.every, 6)
			r.zapT0 = clockNow
			sparkle(r, 8, Color3.fromRGB(150, 230, 255))
			playSound(r, "zap")
		end
		local z = clockNow - r.zapT0
		if z < 0.35 then
			jolt(r, z / 0.35, 0.5 * a, r.zapT0)
		end
	elseif style == "float" then
		if not hanging and not carried then
			local lift = m.lift or 0.15
			body(r, 0, lift + lift * 0.4 * sin(t * f), 0)
		end
		squash(r, 0.035 * a * sin(t * f))
	elseif style == "flutter" then
		local gust = 0.5 + 0.5 * sin(t * 0.7) * sin(t * 1.9)
		cuff(r, 0.05 * gust * a * sin(t * f), 0.06 * gust * a * sin(t * f * 0.9 + 1), 0)
		chain(r, 0, 0.02 * gust * a * sin(t * f * 0.7), 0, TOP)
		jiggle(r, t * 2, 0.03 * gust * a)
	elseif style == "proud" then
		chain(r, -0.07 * a, 0, 0, TOP)
		squash(r, -0.03 * a)
		if clockNow >= r.nextGold then
			r.nextGold = clockNow + between(m.every, 9)
			r.goldT0 = clockNow
		end
		local g = bump(clockNow - r.goldT0, 0, 1.2)
		chain(r, -0.15 * g * a, 0, 0, TOP)
		hat(r, -0.05 * g, 0, 0)
	elseif style == "groove" then
		local b = beat * (m.bpm or 110) / 60
		local hit = exp(-(b % 1) * 5)
		if not hanging and not carried then
			body(r, 0, 0.06 * hit * a, 0)
		end
		chain(r, 0.04 * hit * a, 0.07 * sin(b * PI) * a, 0, EVEN)
		bodyRot(r, 0, 0, 0.06 * sin(b * PI * 0.5) * a)
	elseif style == "orbit" then
		if not hanging and not carried then
			local rad = m.radius or 0.12
			bodyS(r, rad * cos(t * f), 0.05 * sin(t * f * 0.5), rad * sin(t * f))
		end
		r.bry += 0.15 * sin(t * 0.3) * a
		chain(r, 0.03 * sin(t * f) * a, 0.03 * cos(t * f) * a, 0, EVEN)
	end
end

-- ---------- solving: bones and the root part ----------

local function resetBones(r: Rig)
	for _, s in ipairs(r.slots) do
		if s.moved then
			for _, b in ipairs(s.insts) do
				b.Transform = CFrame.identity
			end
			s.moved = false
		end
	end
	r.bonesDirty = false
end

local function clearChannels(r: Rig)
	for _, s in ipairs(r.slots) do
		s.rx, s.ry, s.rz = 0, 0, 0
		s.ox, s.oy, s.oz = 0, 0, 0
		s.rl = 0
	end
	r.bx, r.by, r.bz = 0, 0, 0
	r.brx, r.bry, r.brz = 0, 0, 0
	r.spin, r.flip, r.squash = 0, 0, 0
	r.fade = 0
end

-- the whole-body transform in sock space: flip about the middle, turn about `pivot`, then offset
local function bodyCFrame(r: Rig, pivot: Vector3): CFrame
	local rb = CFrame.fromEulerAnglesYXZ(r.brx, r.bry + r.spin, r.brz)
	local cf = CFrame.new(r.bx, r.by, r.bz) * (rb + (pivot - rb * pivot))
	if r.flip ~= 0 then
		local rf = CFrame.Angles(0, 0, r.flip)
		cf = cf * (rf + (r.midS - rf * r.midS))
	end
	return cf
end

-- Writes every Bone.Transform. `standing`: the foot is planted; else the clothespin point is.
-- `pre` (menus): the body motion, carried by the root-level bones. `bodyWorld`: the body motion the
-- root part got this frame (the Sock Ness lake undoes it to stay on the floor).
local function solveBones(r: Rig, standing: boolean, pre: CFrame?, bodyWorld: CFrame?)
	local slots = r.slots
	-- squash / stretch: every leg bone above Leg1 slides down its share
	local sq = r.squash
	if sq ~= 0 then
		local list = r.chain
		for i = 2, #list do
			local s = list[i]
			s.oy -= sq * s.segH
		end
		for _, s in ipairs(r.necks) do
			s.oy -= sq * 0.5 * s.segH
		end
	end
	for _, s in ipairs(slots) do
		if s.rx == 0 and s.ry == 0 and s.rz == 0 and s.rl == 0 then
			s.R = CFrame.identity
		else
			local rot = CFrame.fromEulerAnglesYXZ(s.rx, s.ry, s.rz)
			if s.rl ~= 0 then
				rot = rot * CFrame.fromAxisAngle(s.axis, s.rl)
			end
			s.R = rot
		end
	end
	-- planted foot: undo what the bones above it turned
	local ft = r.foot
	if standing and ft then
		local q = CFrame.identity
		local a = ft.parent
		while a do
			q = a.R * q
			if a.rootLevel then
				break
			end
			a = a.parent
		end
		ft.R = q:Inverse() * ft.R
	end
	-- forward kinematics of the anchor (foot or clothespin), then shift the root back by the miss
	local anchor: Slot? = if standing then ft else (r.cuff or r.chain[#r.chain])
	local shift = Vector3.zero
	if anchor then
		local x0 = if standing then anchor.p else r.pinS
		local x = x0
		local s: Slot? = anchor
		while s do
			x = s.p + s.R * (x - s.p) + Vector3.new(s.ox, s.oy, s.oz)
			if s.rootLevel then
				break
			end
			s = s.parent
		end
		shift = x0 - x
	end
	local head0: CFrame? = pre
	if shift.Magnitude > 1e-5 then
		head0 = (pre or CFrame.identity) * CFrame.new(shift)
	end
	for _, s in ipairs(slots) do
		local R = s.R
		local still = R == CFrame.identity and s.ox == 0 and s.oy == 0 and s.oz == 0
		local L = if still then CFrame.identity else R + (Vector3.new(s.ox, s.oy, s.oz) + s.p - R * s.p)
		if s.role == "ground" then
			-- stays on the floor: undo everything above it, and the root part's own motion
			local above = CFrame.identity
			local a = s.parent
			while a do
				above = a.L * above
				if a.rootLevel then
					break
				end
				a = a.parent
			end
			L = above:Inverse() * (if bodyWorld then bodyWorld:Inverse() else CFrame.identity) * L
		elseif s.rootLevel and head0 then
			L = head0 * L
		end
		s.L = L
		if L == CFrame.identity then
			if s.moved then
				for _, b in ipairs(s.insts) do
					b.Transform = CFrame.identity
				end
				s.moved = false
			end
		else
			if s.shared then
				local T = s.restInv[1] * L * s.rest[1]
				for _, b in ipairs(s.insts) do
					b.Transform = T
				end
			else
				for i, b in ipairs(s.insts) do
					b.Transform = s.restInv[i] * L * s.rest[i]
				end
			end
			s.moved = true
		end
	end
	r.bonesDirty = true
end

-- the Lost Sock's flicker / the goodbye fade: LocalTransparencyModifier on its visible parts
local function applyFade(r: Rig)
	if abs(r.fade - r.fadeShown) < 0.02 then
		return
	end
	local parts = r.fadeParts
	if not parts then
		local list = {}
		for _, d in ipairs(r.model:GetDescendants()) do
			if d:IsA("BasePart") and d.Transparency < 1 then
				table.insert(list, d)
			end
		end
		r.fadeParts = list
		parts = list
	end
	for _, p in ipairs(parts :: { BasePart }) do
		p.LocalTransparencyModifier = r.fade
	end
	r.fadeShown = r.fade
end

-- ---------- building a rig ----------

local HAT_WORDS = { "hat", "crown", "helm", "hair", "mop", "plume", "headphone", "laurel", "halo" }

-- role from the bone's name: core names first, then common words
local function roleFromName(name: string): (string, number)
	if name == "Root" then
		return "root", 0
	end
	local legN = string.match(name, "^Leg(%d+)$")
	if legN then
		return "leg", tonumber(legN) or 1
	end
	if name == "Cuff" then
		return "cuff", 0
	elseif name == "Foot" then
		return "foot", 0
	elseif name == "Toe" or name == "Toes" then
		return "toe", 0
	elseif name == "Lake" then
		return "ground", 0
	elseif name == "Tail" then
		return "tail", 0
	end
	local digit = string.match(name, "^Toe(%d+)$")
	if digit then
		return "digit", tonumber(digit) or 1
	end
	local eye = string.match(name, "^Eye(%d*)$")
	if eye then
		return "eye", tonumber(eye) or 1
	end
	local fly = string.match(name, "^Fly(%d*)$")
	if fly then
		return "fly", tonumber(fly) or 1
	end
	local hump = string.match(name, "^Hump(%d*)$")
	if hump then
		return "hump", tonumber(hump) or 1
	end
	local _, seg = string.match(name, "^Tent(%d+)_(%d+)$")
	if seg then
		return "tentacle", tonumber(seg) or 1
	end
	local lower = string.lower(name)
	for _, word in ipairs(HAT_WORDS) do
		if string.find(lower, word, 1, true) then
			return "hat", 0
		end
	end
	if string.find(lower, "jaw", 1, true) or string.find(lower, "mouth", 1, true) then
		return "jaw", 0
	elseif string.find(lower, "neck", 1, true) then
		return "neck", tonumber(string.match(name, "(%d+)$")) or 0
	elseif lower == "head" or string.match(lower, "^head%d*$") then
		return "head", 0
	elseif string.find(lower, "pogo", 1, true) then
		return "pogo", 0
	elseif string.find(lower, "tent", 1, true) then
		return "tentacle", tonumber(string.match(name, "(%d+)$")) or 0
	end
	return "accessory", 0
end

local KNOWN_ROLES = {
	root = true, leg = true, cuff = true, foot = true, toe = true, digit = true, eye = true, hat = true, jaw = true,
	pogo = true, tentacle = true, neck = true, head = true, fly = true, hump = true, tail = true, ground = true, accessory = true,
}

local function normaliseRole(v: any): string?
	if type(v) ~= "string" then
		return nil
	end
	local word = string.lower(string.match(v, "^%a+") or "")
	if KNOWN_ROLES[word] then
		return word
	end
	if string.sub(word, -1) == "s" and KNOWN_ROLES[string.sub(word, 1, -2)] then
		return string.sub(word, 1, -2) -- "tentacles" -> "tentacle"
	end
	return nil
end

-- This type's table in the generated SockRigConfig (Types["<id>_<side>"] or Types["<id>"]), or nil.
local function rigEntry(typeId: string, side: string): any
	local cfg = RigConfig
	if type(cfg) ~= "table" then
		return nil
	end
	for _, key in ipairs({ "Types", "ByType", "Socks", "Rigs", "Roles" }) do
		local t = cfg[key]
		if type(t) == "table" then
			local entry = t[typeId .. "_" .. side] or t[typeId]
			if type(entry) == "table" then
				return entry
			end
		end
	end
	local entry = cfg[typeId .. "_" .. side] or cfg[typeId]
	return if type(entry) == "table" then entry else nil
end

-- Bone roles from the SockRigConfig entry: the generated shape { Bone = { role = "..." } }, or
-- (tolerant) any (bone name, role) pair it holds, e.g. { hat = "Hat" } or { tentacle = { ... } }.
-- Only names of bones this model really has count.
local function rolesFromConfig(entry: any, names: { [string]: boolean }): { [string]: string }
	local out = {} :: { [string]: string }
	if type(entry) ~= "table" then
		return out
	end
	local direct = false
	for k, v in pairs(entry) do
		if type(k) == "string" and type(v) == "table" and type(v.role) == "string" then
			direct = true
			local role = normaliseRole(v.role)
			if names[k] and role then
				out[k] = role
			end
		end
	end
	if direct then
		return out
	end
	local function roleKey(k: any): string?
		if type(k) ~= "string" then
			return nil
		end
		local lower = string.lower(k)
		if KNOWN_ROLES[lower] then
			return lower
		elseif string.sub(lower, -1) == "s" and KNOWN_ROLES[string.sub(lower, 1, -2)] then
			return string.sub(lower, 1, -2)
		end
		return nil
	end
	local function visit(tbl: any, depth: number, hint: string?)
		if depth > 5 then
			return
		end
		for k, v in pairs(tbl) do
			local keyRole = roleKey(k)
			if type(v) == "string" then
				local valueRole = normaliseRole(v)
				if type(k) == "string" and names[k] and valueRole then
					out[k] = valueRole
				elseif names[v] and (keyRole or hint) then
					out[v] = (keyRole or hint) :: string
				end
			elseif type(v) == "table" then
				local nm = v.name or v.bone or v.Name
				local rl = normaliseRole(v.role or v.Role or v.kind)
				if type(nm) == "string" and names[nm] and rl then
					out[nm] = rl
				end
				visit(v, depth + 1, keyRole or hint)
			end
		end
	end
	visit(entry, 0, nil)
	return out
end

local function restWorld(bone: Bone): CFrame?
	local cf = bone.CFrame
	local p = bone.Parent
	while p and p:IsA("Bone") do
		cf = p.CFrame * cf
		p = p.Parent
	end
	if p and p:IsA("BasePart") then
		return p.CFrame * cf
	end
	return nil
end

-- how a bend spreads along a chain, for each PROFILE_K: shaped by k (base-heavy .. top-heavy)
-- and by each segment's length, so a tiny segment (Ankle Biter's Leg2 / Leg3) bends little
local function profiles(lens: { number }): { { number } }
	local n = #lens
	local mean = 0
	for i = 1, n do
		mean += lens[i] / n
	end
	local out = {}
	for pi, k in ipairs(PROFILE_K) do
		local w = {}
		local sum = 0
		for i = 1, n do
			local x = max(0.05, 1 + k * (2 * (i - 0.5) / n - 1)) * clamp(lens[i] / max(mean, 1e-3), 0.2, 2.5)
			w[i] = x
			sum += x
		end
		for i = 1, n do
			w[i] /= max(sum, 1e-6)
		end
		out[pi] = w
	end
	return out
end

-- each chain segment's length: to the next pivot, the last one to `tip` (or as long as the one before)
local function segmentLengths(list: { Slot }, tip: Vector3?): { number }
	local lens = {}
	for i, s in ipairs(list) do
		local nextP = if list[i + 1] then list[i + 1].p else tip
		lens[i] = if nextP then max((nextP - s.p).Magnitude, 0.05) else (lens[i - 1] or 1)
	end
	return lens
end

local function underClothespin(inst: Instance, model: Model): boolean
	local p = inst.Parent
	while p and p ~= model do
		if p.Name == "Clothespin" then
			return true
		end
		p = p.Parent
	end
	return false
end

local function onOutline(b: Instance): boolean
	local part = b:FindFirstAncestorWhichIsA("BasePart")
	return part ~= nil and endsWith(part.Name, "_Outline")
end

local function isMarkerName(name: string): boolean
	return endsWith(name, "_Base") or endsWith(name, "_Unit") or endsWith(name, "_Pin")
end

local function findMarker(model: Model, suffix: string): BasePart?
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and endsWith(d.Name, suffix) and not string.find(d.Name, "Clothespin", 1, true) and not underClothespin(d, model) then
			return d
		end
	end
	return nil
end

-- the sock frame, sizes, marker points, bones and their roles. Safe to run again (streaming).
local function buildRig(r: Rig, ropeOffset: number?)
	local model = r.model
	if r.bonesDirty then
		resetBones(r)
	end
	local root = model.PrimaryPart
	if r.mode == "world" then
		local leg = model:FindFirstChild("Leg")
		root = if leg and leg:IsA("BasePart") then leg else model.PrimaryPart
	elseif not root then
		-- a menu copy may have no PrimaryPart: any visible part will do (sounds / nil checks only)
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") and not isMarkerName(d.Name) then
				root = d
				break
			end
		end
	end
	r.root = root
	local baseM = findMarker(model, "_Base")
	local unitM = findMarker(model, "_Unit")
	local pinM = findMarker(model, "_Pin")
	-- the sock frame
	if r.mode == "world" or r.mode == "goodbye" then
		if root then
			r.frame = root.CFrame
		end
	elseif baseM and unitM then
		local front = unitM.Position - baseM.Position
		local flat = Vector3.new(front.X, 0, front.Z)
		if flat.Magnitude > 1e-4 then
			local fz = flat.Unit
			r.frame = CFrame.fromMatrix(baseM.Position, WORLD_UP:Cross(fz), WORLD_UP)
		else
			r.frame = model:GetPivot()
		end
	else
		r.frame = model:GetPivot()
	end
	r.pivotOffset = r.frame:ToObjectSpace(model:GetPivot())
	-- size: studs per sock unit
	if baseM and unitM then
		r.unit = max((unitM.Position - baseM.Position).Magnitude, 0.05)
	else
		local ok, scale = pcall(function()
			return model:GetScale()
		end)
		r.unit = if ok and type(scale) == "number" and scale > 0 then scale else 1
	end
	-- floor and clothespin points
	local inv = r.frame:Inverse()
	if baseM then
		r.baseS = inv * baseM.Position
	elseif root and r.mode ~= "ui" then
		r.baseS = Vector3.new(0, -(root.Size.Y / 2 + 0.65 * r.unit), 0)
	else
		r.baseS = Vector3.zero
	end
	if pinM then
		r.pinS = inv * pinM.Position
	elseif root and r.mode ~= "ui" then
		r.pinS = Vector3.new(0, root.Size.Y / 2 + 0.55 * r.unit, 0)
	else
		r.pinS = r.baseS + Vector3.new(0, 4.2 * r.unit, 0)
	end
	r.ropeS = Vector3.new(0, ropeOffset or r.pinS.Y, 0)
	r.midS = (r.baseS + r.pinS) / 2
	r.eyeS = r.baseS + (r.pinS - r.baseS) * 0.75

	-- bones, grouped by name (the body and its outline hull may each have a copy)
	local groups = {} :: { [string]: { Bone } }
	local order = {} :: { string }
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Bone") and not underClothespin(d, model) then
			local g = groups[d.Name]
			if not g then
				g = {}
				groups[d.Name] = g
				table.insert(order, d.Name)
			end
			table.insert(g, d)
		end
	end
	local names = {} :: { [string]: boolean }
	for _, name in ipairs(order) do
		names[name] = true
	end
	local entry = rigEntry(r.typeId, r.side)
	local cfgRoles = rolesFromConfig(entry, names)

	local slots = {} :: { Slot }
	local byName = {} :: { [string]: Slot }
	for _, name in ipairs(order) do
		local insts = groups[name]
		-- the body's copy leads (not the outline's); a copied pose starts from rest
		table.sort(insts, function(a, b)
			return (not onOutline(a)) and onOutline(b)
		end)
		for _, b in ipairs(insts) do
			b.Transform = CFrame.identity
		end
		local rests, invs = {}, {}
		local okAll = true
		for i, b in ipairs(insts) do
			local w = restWorld(b)
			if not w then
				okAll = false
				break
			end
			rests[i] = inv * w
			invs[i] = rests[i]:Inverse()
		end
		if okAll and #insts > 0 then
			local role, index = roleFromName(name)
			local fromCfg = cfgRoles[name]
			if fromCfg and role ~= "root" and role ~= "leg" and role ~= "cuff" and role ~= "foot" and role ~= "toe" then
				role = fromCfg
			end
			local shared = true
			for i = 2, #rests do
				local a, b = rests[1], rests[i]
				if (a.Position - b.Position).Magnitude > 1e-3 or (a.LookVector - b.LookVector).Magnitude > 1e-3 or (a.UpVector - b.UpVector).Magnitude > 1e-3 then
					shared = false
					break
				end
			end
			local depth = 0
			local p = insts[1].Parent
			while p and p:IsA("Bone") do
				depth += 1
				p = p.Parent
			end
			local slot: Slot = {
				name = name,
				role = role,
				index = index,
				depth = depth,
				parent = nil,
				rootLevel = depth == 0,
				insts = insts,
				rest = rests,
				restInv = invs,
				shared = shared,
				p = rests[1].Position,
				segH = 0,
				rx = 0,
				ry = 0,
				rz = 0,
				ox = 0,
				oy = 0,
				oz = 0,
				rl = 0,
				axis = Vector3.zAxis,
				ga = 0,
				gv = 0,
				slideMax = 0.1,
				turnMax = math.rad(6),
				R = CFrame.identity,
				L = CFrame.identity,
				moved = false,
			}
			-- the jaw's clean range, from the rig's own tests
			local info = if type(entry) == "table" then entry[name] else nil
			if type(info) == "table" then
				if type(info.slide) == "number" then
					slot.slideMax = info.slide
				end
				if type(info.turn) == "number" then
					slot.turnMax = math.rad(info.turn)
				end
			end
			table.insert(slots, slot)
			byName[name] = slot
		end
	end
	for _, s in ipairs(slots) do
		local p = s.insts[1].Parent
		if p and p:IsA("Bone") then
			s.parent = byName[p.Name]
		end
		if s.parent == nil then
			s.rootLevel = true
		end
		s.segH = if s.parent then max(s.p.Y - (s.parent :: Slot).p.Y, 0) else 0
	end
	table.sort(slots, function(a, b)
		if a.depth ~= b.depth then
			return a.depth < b.depth
		end
		return a.name < b.name
	end)

	-- roles -> lists
	local legs, necks = {}, {}
	r.jaws, r.hats, r.pogos, r.heads, r.extras = {}, {}, {}, {}, {}
	r.eyes, r.digits, r.critters, r.grounds = {}, {}, {}, {}
	r.cuff, r.foot, r.toe = nil, nil, nil
	local tentByRoot = {} :: { [string]: { Slot } }
	local tentRoots = {} :: { string }
	for _, s in ipairs(slots) do
		local role = s.role
		if role == "leg" then
			table.insert(legs, s)
		elseif role == "cuff" then
			r.cuff = s
		elseif role == "foot" then
			r.foot = s
		elseif role == "toe" then
			r.toe = s
		elseif role == "jaw" then
			table.insert(r.jaws, s)
		elseif role == "hat" then
			table.insert(r.hats, s)
		elseif role == "pogo" then
			table.insert(r.pogos, s)
		elseif role == "neck" then
			table.insert(necks, s)
		elseif role == "head" then
			table.insert(r.heads, s)
		elseif role == "eye" then
			-- the pupil rolls about whichever of the bone's own axes points out of the face
			local rest = s.rest[1]
			local best, bestDot = Vector3.zAxis, -1
			for _, ax in ipairs({ rest.XVector, rest.YVector, rest.ZVector }) do
				local d = abs(ax.Z)
				if d > bestDot then
					bestDot = d
					best = if ax.Z >= 0 then ax else -ax
				end
			end
			s.axis = best
			table.insert(r.eyes, s)
		elseif role == "digit" then
			table.insert(r.digits, s)
		elseif role == "fly" or role == "hump" or role == "tail" then
			table.insert(r.critters, s)
		elseif role == "ground" then
			table.insert(r.grounds, s)
		elseif role == "tentacle" then
			local top = s
			while top.parent and (top.parent :: Slot).role == "tentacle" do
				top = top.parent :: Slot
			end
			local list = tentByRoot[top.name]
			if not list then
				list = {}
				tentByRoot[top.name] = list
				table.insert(tentRoots, top.name)
			end
			table.insert(list, s)
		elseif role ~= "root" then
			table.insert(r.extras, s)
		end
	end
	table.sort(legs, function(a, b)
		return a.index < b.index
	end)
	table.sort(r.digits, function(a, b)
		return a.index < b.index
	end)
	table.sort(necks, function(a, b)
		if a.depth ~= b.depth then
			return a.depth < b.depth
		end
		return a.index < b.index
	end)
	local chainList = legs
	if r.cuff then
		table.insert(chainList, r.cuff)
	end
	r.chain = chainList
	r.prof = profiles(segmentLengths(chainList, r.pinS))
	r.necks = necks
	r.nprof = profiles(segmentLengths(necks, if #necks > 0 and r.heads[1] then r.heads[1].p else nil))
	-- tentacles: each chain root -> tip, and its curl axis (horizontal, across its outward line)
	table.sort(tentRoots)
	r.tents, r.tentKX, r.tentKZ = {}, {}, {}
	local cx, cz = 0, 0
	for _, rootName in ipairs(tentRoots) do
		local list = tentByRoot[rootName]
		table.sort(list, function(a, b)
			return a.depth < b.depth
		end)
		cx += list[1].p.X
		cz += list[1].p.Z
	end
	local nT = #tentRoots
	if nT > 0 then
		cx /= nT
		cz /= nT
	end
	for c, rootName in ipairs(tentRoots) do
		local list = tentByRoot[rootName]
		local first = list[1].p
		local out = Vector3.new(first.X - cx, 0, first.Z - cz)
		if out.Magnitude < 1e-3 then
			out = Vector3.new(cos(c / nT * TAU), 0, sin(c / nT * TAU))
		end
		local k = WORLD_UP:Cross(out.Unit)
		table.insert(r.tents, list)
		table.insert(r.tentKX, k.X)
		table.insert(r.tentKZ, k.Z)
	end
	r.slots = slots
	r.hasBones = #slots > 0
	-- outline hulls (OutlineMode "highlight" hides them)
	r.hulls = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and endsWith(d.Name, "_Outline") then
			table.insert(r.hulls, d)
			if Config.OutlineMode == "highlight" then
				d.Transparency = 1
			end
		end
	end
	r.fadeParts = nil
end

local function newRig(model: Model, mode: string, typeId: string, side: string, rarity: string, mutation: string, uid: number): Rig
	local pers = Config.Personalities[typeId]
	if not pers then
		warnOnce("pers:" .. typeId, "no personality for sock type '" .. typeId .. "' - using the default")
		pers = Config.Default
	end
	local tier = RarityConfig.Tiers[rarity]
	local tint = if tier then tier.color else Color3.new(1, 1, 1)
	if rarity == "Secret" then
		tint = Color3.fromRGB(170, 150, 255) -- SECRET's own colour is near black
	end
	local r: Rig = {
		model = model,
		root = nil,
		mode = mode,
		uid = uid,
		typeId = typeId,
		side = side,
		dir = if side == "L" then -1 else 1,
		rarity = rarity,
		rank = if tier then tier.rank else 1,
		mutation = mutation,
		pers = pers,
		energy = Config.Rarity[rarity] or Config.Rarity.Common,
		mut = Config.Mutations[mutation],
		tint = tint,
		unit = 1,
		frame = CFrame.identity,
		pivotOffset = CFrame.identity,
		baseS = Vector3.zero,
		pinS = Vector3.zero,
		ropeS = Vector3.zero,
		midS = Vector3.zero,
		eyeS = Vector3.zero,
		slots = {},
		chain = {},
		prof = {},
		necks = {},
		nprof = {},
		cuff = nil,
		foot = nil,
		toe = nil,
		jaws = {},
		hats = {},
		pogos = {},
		heads = {},
		extras = {},
		eyes = {},
		digits = {},
		critters = {},
		grounds = {},
		bendMax = if type(pers.bend) == "number" then pers.bend elseif side == "S" then Config.Limits.BendSingle else Config.Limits.Bend,
		hatMax = if type(pers.hatTilt) == "number" then pers.hatTilt else Config.Limits.HatTilt,
		-- the Blender kit draws each pupil down and toward the toe: (0.26 x toe side, -0.46)
		pupil0 = atan2(-0.46, 0.26 * (if side == "L" then -1 elseif side == "R" then 1 else 0)),
		eyeW = 0,
		eyeYaw = 0,
		eyePitch = 0,
		gy = 0,
		gvy = 0,
		tents = {},
		tentKX = {},
		tentKZ = {},
		hasBones = false,
		bonesOn = false,
		bonesDirty = false,
		hulls = {},
		fadeParts = nil,
		fade = 0,
		fadeShown = 0,
		phase = if uid > 0 then (uid * 0.618) % 1 * TAU else math.random() * TAU,
		reduce = false,
		state = if mode == "world" then "gone" else mode,
		rest = nil,
		placedAt = 0,
		ownerId = 0,
		carryOwner = 0,
		paired = false,
		pairUid = 0,
		created = clockNow,
		lineProgress = 0,
		fellSqueak = false,
		camDist = 0,
		curFrame = CFrame.identity,
		bx = 0,
		by = 0,
		bz = 0,
		brx = 0,
		bry = 0,
		brz = 0,
		spin = 0,
		flip = 0,
		squash = 0,
		actName = nil,
		actT0 = 0,
		actDur = 1,
		actPrev = 0,
		actRnd = 0,
		momName = nil,
		momT0 = 0,
		momDur = 1,
		momPrio = 0,
		momPrev = 0,
		momX = 0,
		momZ = 0,
		momYaw = 0,
		momPitch = 0,
		actYaw = 0,
		actPitch = 0,
		queued = nil,
		cheerAt = 0,
		cheerVoice = false,
		nextFidget = clockNow + 1 + math.random() * 5,
		nextShow = 0,
		nextZap = clockNow + math.random() * 6,
		zapT0 = -100,
		nextGold = clockNow + math.random() * 9,
		goldT0 = -100,
		nextFlail = 0,
		lookW = 0,
		lookYaw = 0,
		lookPitch = 0,
		tLookW = 0,
		tLookYaw = 0,
		tLookPitch = 0,
		lookWho = 0,
		noticeAt = -100,
		perk = 0,
		tPerk = 0,
		perkSide = 1,
		panic = 0,
		tPanic = 0,
		awayX = 0,
		awayZ = 1,
		pairW = 0,
		tPairW = 0,
		pairYaw = 0,
		sleep = 0,
		asleep = false,
		lastNear = clockNow - math.random() * 20,
		nextSnore = 0,
		nextZzz = 0,
		homeX = 0,
		homeZ = -1,
		homePos = nil,
		nextScan = clockNow + math.random() * 0.2,
		lastT = clockNow,
		sounds = {},
		soundAt = {},
		sparkle = nil,
		zzz = nil,
		zzzLabels = {},
		zzzIndex = 0,
		conns = {},
		failed = false,
		hidden = false,
		lastBody = CFrame.identity,
		lastPivot = nil,
		visible = true,
		nextVis = 0,
		rebuildAt = 0,
		onDone = nil,
		dead = false,
	}
	local show = r.energy.showEvery
	r.nextShow = if show then clockNow + between(show, 30) * (0.3 + math.random() * 0.7) else math.huge
	return r
end

local function addRig(r: Rig)
	table.insert(rigList, r)
	rigsByModel[r.model] = r
	if r.mode == "world" and r.uid ~= 0 then
		rigsByUid[r.uid] = r
	end
end

local function removeRig(r: Rig)
	if r.dead then
		return
	end
	r.dead = true
	for _, c in ipairs(r.conns) do
		c:Disconnect()
	end
	table.clear(r.conns)
	pcall(resetBones, r)
	if r.fadeShown ~= 0 then
		r.fade = 0
		pcall(applyFade, r)
	end
	for _, s in pairs(r.sounds) do
		s:Destroy()
	end
	local sp = r.sparkle
	local att = sp and sp.Parent
	if att then
		att:Destroy()
	end
	local z = r.zzz
	if z then
		z:Destroy()
	end
	if rigsByModel[r.model] == r then
		rigsByModel[r.model] = nil
	end
	if rigsByUid[r.uid] == r then
		rigsByUid[r.uid] = nil
	end
	local i = table.find(rigList, r)
	if i then
		rigList[i] = rigList[#rigList]
		rigList[#rigList] = nil
	end
end

-- ---------- clips: starting and stopping ----------

local function startAct(r: Rig, name: string, show: boolean)
	local c = clipFor(name)
	if not c then
		return
	end
	r.actName = name
	r.actT0 = clockNow
	r.actDur = c.dur
	r.actPrev = -1e-6
	r.actRnd = math.random()
	r.actYaw = r.lookYaw
	r.actPitch = r.lookPitch
	if show and r.energy.sparkle > 0 then
		sparkle(r, r.energy.sparkle, r.tint)
	end
	if name == "stare" or name == "phase" then
		-- stare at the camera (in a menu: it already faces it)
		local cam = workspace.CurrentCamera
		if r.mode == "world" and cam then
			local v = r.curFrame:PointToObjectSpace(cam.CFrame.Position) - r.eyeS
			r.actYaw = clamp(atan2(v.X, v.Z), -1.2, 1.2)
			r.actPitch = clamp(atan2(v.Y, sqrt(v.X * v.X + v.Z * v.Z)), -0.4, 0.4)
		else
			r.actYaw = 0
			r.actPitch = 0
		end
	end
end

local function startShowoff(r: Rig)
	local e = r.energy
	local name = r.pers.showoff or "spin"
	local flair = e.flair
	if flair and #flair > 0 and math.random() < (e.flairChance or 0) then
		local pick = flair[math.random(#flair)]
		if not (r.reduce and (pick == "spin" or pick == "flip")) then
			name = pick
		end
	end
	startAct(r, name, true)
end

local function startMoment(r: Rig, name: string, x: number?, z: number?)
	local prio = MOMENTS[name] or 1
	if r.momName and prio < r.momPrio then
		if name == "paired" then
			r.queued = name -- dance once the bigger moment is over
		end
		return
	end
	local c = clipFor(name)
	if not c then
		return
	end
	r.momName = name
	r.momT0 = clockNow
	r.momDur = c.dur
	r.momPrio = prio
	r.momPrev = -1e-6
	r.momX = x or 0
	r.momZ = z or 0
	r.actName = nil -- a moment interrupts any fidget
	if name == "paired" then
		r.momYaw = if r.pairW > 0.1 then r.pairYaw * Config.Reactions.PairTurn else 0
	end
end

-- ---------- the world: players, drawers, intruders ----------

type PlayerEntry = { player: Player, pos: Vector3, valid: boolean }
local pcache = {} :: { PlayerEntry }
local myFloor: BasePart? = nil
local intruderPos: Vector3? = nil

local function addPlayer(p: Player)
	for _, e in ipairs(pcache) do
		if e.player == p then
			return
		end
	end
	table.insert(pcache, { player = p, pos = Vector3.zero, valid = false })
end

local function removePlayer(p: Player)
	for i, e in ipairs(pcache) do
		if e.player == p then
			pcache[i] = pcache[#pcache]
			pcache[#pcache] = nil
			return
		end
	end
end

local function refreshPlayers()
	for _, e in ipairs(pcache) do
		local ch = e.player.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") then
			e.pos = hrp.Position
			e.valid = true
		else
			e.valid = false
		end
	end
end

local function floorOf(ownerId: number): BasePart?
	if ownerId == 0 then
		return nil
	end
	for _, base in ipairs(CollectionService:GetTagged("Base")) do
		if base:GetAttribute("OwnerId") == ownerId then
			local f = base:FindFirstChild("Floor")
			if f and f:IsA("BasePart") then
				return f
			end
		end
	end
	return nil
end

local function insideDrawer(f: BasePart, pos: Vector3): boolean
	local p = f.CFrame:PointToObjectSpace(pos)
	return abs(p.X) <= f.Size.X / 2 and abs(p.Z) <= f.Size.Z / 2 and p.Y >= -2 and p.Y <= 16
end

local function scanIntruders()
	intruderPos = nil
	local f = myFloor
	if not f or not f.Parent then
		return
	end
	local bestD = math.huge
	for _, e in ipairs(pcache) do
		if e.valid and e.player ~= localPlayer and insideDrawer(f, e.pos) then
			local d = (e.pos - f.Position).Magnitude
			if d < bestD then
				bestD = d
				intruderPos = e.pos
			end
		end
	end
end

-- yaw / pitch (sock space) from the sock's eyes to a world point
local function aim(r: Rig, frame: CFrame, point: Vector3): (number, number)
	local v = frame:PointToObjectSpace(point) - r.eyeS
	local yaw = atan2(v.X, v.Z)
	local pitch = atan2(v.Y, sqrt(v.X * v.X + v.Z * v.Z))
	return yaw, pitch
end

-- every ScanEvery: who is near, where home is, whom to look at
local function scan(r: Rig, frame: CFrame, pos: Vector3, hanging: boolean, carried: boolean)
	local R = Config.Reactions
	local best: PlayerEntry? = nil
	local bestD = R.LookRange
	local near = false
	for _, e in ipairs(pcache) do
		if e.valid then
			local d = (e.pos - pos).Magnitude
			if d < R.SleepRange then
				near = true
			end
			if d < bestD then
				best = e
				bestD = d
			end
		end
	end
	if near or r.state ~= "drawer" then
		r.lastNear = clockNow
	end
	-- look at the nearest player (eye contact: aim at the head)
	if best and not carried then
		local yaw, pitch = aim(r, frame, best.pos + Vector3.new(0, 1.5, 0))
		local back = clamp((2.6 - abs(yaw)) / 0.8, 0, 1) -- right behind it: don't break its neck
		r.tLookYaw = clamp(yaw, -R.LookMaxYaw, R.LookMaxYaw)
		r.tLookPitch = clamp(pitch, -R.LookMaxPitch, R.LookMaxPitch)
		r.tLookW = back
		local who = best.player.UserId
		if who ~= r.lookWho then
			if r.lookWho == 0 and not r.momName and not r.actName then
				r.noticeAt = clockNow
			end
			r.lookWho = who
		end
		-- clothesline: perk up toward someone who could buy it
		if hanging and bestD <= R.PerkRange then
			r.tPerk = 1
			local v = frame:PointToObjectSpace(best.pos)
			r.perkSide = if v.X * r.dir >= 0 then 1 else -1
		else
			r.tPerk = 0
		end
	else
		r.tLookW = 0
		r.tPerk = 0
		r.lookWho = 0
	end
	-- carried: which way is home
	if carried then
		if not r.homePos then
			local f = floorOf(r.carryOwner)
			r.homePos = if f then f.Position else nil
		end
		local root = r.root
		if r.homePos and root then
			local v = root.CFrame:VectorToObjectSpace((r.homePos :: Vector3) - root.Position)
			local flat = Vector3.new(v.X, 0, v.Z)
			if flat.Magnitude > 1e-3 then
				r.homeX = flat.Unit.X
				r.homeZ = flat.Unit.Z
			end
		end
	end
	-- a thief in YOUR drawer: your socks panic
	if r.state == "drawer" and r.ownerId == myId and myId ~= 0 and intruderPos then
		r.tPanic = 1
		local v = frame:PointToObjectSpace(intruderPos :: Vector3)
		local flat = Vector3.new(-v.X, 0, -v.Z)
		if flat.Magnitude > 1e-3 then
			r.awayX = flat.Unit.X
			r.awayZ = flat.Unit.Z
		end
	else
		r.tPanic = 0
	end
	-- paired in the same drawer: turn toward the other half
	r.tPairW = 0
	if r.paired and r.pairUid ~= 0 and r.state == "drawer" then
		local other = rigsByUid[r.pairUid]
		local oroot = other and other.root
		if other and oroot and other.state == "drawer" and other.ownerId == r.ownerId then
			local yaw = aim(r, frame, oroot.Position + Vector3.new(0, r.eyeS.Y - r.baseS.Y, 0))
			r.pairYaw = clamp(yaw, -1.1, 1.1)
			r.tPairW = 1
		end
	end
end

-- ---------- one frame of one sock ----------

local function update(r: Rig, dt: number, beat: number)
	local model = r.model
	local root = r.root
	if not root or root.Parent == nil then
		return
	end
	local mode = r.mode
	local state = r.state
	local R = Config.Reactions

	-- the situation: where the root goes, and what stays planted
	local frame: CFrame? = nil
	local canMove = false
	local hanging = false
	local carried = false
	if mode == "world" then
		if state == "line" then
			hanging = true
			local fx = fxMod
			if fx then
				local po = fx.PinOffset()
				if type(po) == "number" and po ~= r.ropeS.Y then
					r.ropeS = Vector3.new(0, po, 0)
				end
				local pin, progress = fx.LinePin(model)
				if pin then
					frame = pin * CFrame.new(-r.ropeS)
					canMove = true
					r.lineProgress = progress or 0
				end
			end
		elseif state == "drawer" then
			if r.rest then
				frame = r.rest
				canMove = clockNow - r.placedAt > Config.Perf.LandDelay
			end
		elseif state == "carried" then
			carried = true
		end
		frame = frame or root.CFrame
		-- never move a root that is welded to someone (a thief's head)
		canMove = canMove and root.Anchored
	else
		frame = r.frame
		canMove = true
	end
	local f = frame :: CFrame
	r.curFrame = f

	-- clocks, energy, settings
	r.reduce = reduceMotion
	local pers = r.pers
	local energy = r.energy
	local E = (energy.energy or 1) * (pers.amp or 1) * (if reduceMotion then Config.ReduceMotionScale else 1)
	local t = clockNow * (pers.tempo or 1) * (energy.tempo or 1) + r.phase
	clearChannels(r)

	-- reactions (world socks only), smoothed toward what the last scan saw
	if mode == "world" then
		if clockNow >= r.nextScan then
			r.nextScan = clockNow + R.ScanEvery * (0.8 + math.random() * 0.4)
			scan(r, f, root.Position, hanging, carried)
		end
		local lookRate = if clockNow - r.noticeAt < 0.3 then R.LookSpeed * 2.5 else R.LookSpeed
		r.lookW = approach(r.lookW, r.tLookW, lookRate, dt)
		r.lookYaw = approach(r.lookYaw, r.tLookYaw, lookRate, dt)
		r.lookPitch = approach(r.lookPitch, r.tLookPitch, lookRate, dt)
		r.perk = approach(r.perk, r.tPerk, 3, dt)
		r.panic = approach(r.panic, r.tPanic, if r.tPanic > r.panic then 8 else 2, dt)
		r.pairW = approach(r.pairW, r.tPairW, 2, dt)
		local wantSleep = state == "drawer" and clockNow - r.lastNear > R.SleepAfter
		if r.sleep > 0.5 then
			r.asleep = true
		end
		if r.asleep and not wantSleep then
			r.asleep = false
			if state == "drawer" then
				startMoment(r, "wake")
			end
		end
		r.sleep = approach(r.sleep, if wantSleep then 1 else 0, if wantSleep then 0.5 else 6, dt)
	end

	-- moment / fidget bookkeeping
	if r.momName and clockNow - r.momT0 >= r.momDur then
		local was = r.momName
		r.momName = nil
		r.momPrio = 0
		if was == "goodbye" and r.onDone then
			local done = r.onDone
			r.onDone = nil
			task.defer(done)
			return
		end
		if r.queued then
			local q = r.queued
			r.queued = nil
			startMoment(r, q :: string)
		end
	end
	if r.actName and clockNow - r.actT0 >= r.actDur then
		r.actName = nil
	end
	if r.cheerAt > 0 and clockNow >= r.cheerAt then
		r.cheerAt = 0
		startMoment(r, "cheer")
	end
	local calm = not r.momName and r.sleep < 0.3 and r.panic < 0.3
	if calm and not r.actName and not carried then
		if hanging then
			if clockNow >= r.nextFidget then
				startAct(r, "hangwiggle", false)
				r.nextFidget = clockNow + between(energy.fidgetEvery, 8) * 1.4
			end
		elseif clockNow >= r.nextShow then
			startShowoff(r)
			r.nextShow = clockNow + between(energy.showEvery, 40)
			r.nextFidget = max(r.nextFidget, clockNow + r.actDur + 1)
		elseif clockNow >= r.nextFidget then
			local list = pers.fidgets
			if list and #list > 0 then
				startAct(r, list[math.random(#list)], false)
			end
			r.nextFidget = clockNow + r.actDur + between(energy.fidgetEvery, 8)
		end
	end
	-- a thief in your drawer: flail now and then
	if r.panic > 0.5 and not r.momName and not r.actName and clockNow >= r.nextFlail then
		r.nextFlail = clockNow + between(R.PanicFlailEvery, 2)
		startAct(r, "flail", false)
	end

	-- LOD: bones near the camera, whole-body motion beyond
	local wantBones = r.hasBones
	if mode == "world" then
		local range = (if lowGraphics then Config.Perf.LowGraphicsBoneRange else Config.Perf.BoneRange) * boneScale
		-- a little hysteresis, so a sock right on the edge doesn't flick between the two
		wantBones = wantBones and r.camDist <= (if r.bonesOn then range * 1.15 else range)
		if wantBones then
			boneCount += 1
		end
	end
	if r.bonesOn and not wantBones then
		resetBones(r)
	end
	r.bonesOn = wantBones

	-- weights of the clips playing now
	local momW, actW = 0, 0
	local momClip = clipFor(r.momName)
	local actClip = clipFor(r.actName)
	local mu, au = 0, 0
	if momClip then
		mu = clamp((clockNow - r.momT0) / r.momDur, 0, 1)
		momW = ramp(mu, 0, 0.06) * (1 - ramp(mu, 0.92, 1))
	end
	if actClip then
		au = clamp((clockNow - r.actT0) / r.actDur, 0, 1)
		actW = ramp(au, 0, 0.1) * (1 - ramp(au, 0.88, 1))
	end
	local idleW = 1 - max(if momClip then momClip.suppress * momW else 0, if actClip then actClip.suppress * actW else 0)
	idleW *= 1 - 0.85 * r.sleep
	idleW *= 1 - 0.6 * r.panic

	-- 1. the situation loop
	local A = E * idleW
	if carried then
		local reach = R.CarryReach * (0.75 + 0.25 * sin(t * 1.3))
		bendToward(r, r.homeX, r.homeZ, reach * E, TOP)
		local fl = sin(t * 9.3) * 0.6 + sin(t * 13.1) * 0.4
		chain(r, R.CarryFlail * 0.5 * fl * E, R.CarryFlail * sin(t * 7.7) * E, 0, EVEN)
		foot(r, 0.45 * sin(t * 11) * E, 0.1 * sin(t * 5) * E, 0)
		toe(r, 0.3 * sin(t * 14) * E)
		tentacles(r, t * 6, 0.4 * E, 0.3 * E, 0.8)
		if clockNow >= r.nextFlail then
			r.nextFlail = clockNow + 2.5 + math.random() * 2.5
			playSound(r, "squeak")
		end
	elseif hanging then
		local hang = HANGS[pers.hang] or HANGS.kick
		hang(r, t, A, beat)
		-- perked up: kick and swing toward the player
		if r.perk > 0.01 then
			hangSwing(r, r.perk * 0.12 * E * r.perkSide * (0.6 + 0.4 * sin(t * 7)), 0)
			foot(r, r.perk * 0.35 * sin(t * 9) * E, 0, 0)
		end
		-- the end of the line: into the Lint Trap, flailing
		if r.lineProgress > 0.955 then
			local k = ramp(r.lineProgress, 0.955, 0.975)
			chain(r, 0.3 * sin(t * 30) * k * E, 0.4 * sin(t * 37) * k * E, 0, EVEN)
			foot(r, 0.5 * sin(t * 41) * k * E, 0, 0)
			if not r.fellSqueak then
				r.fellSqueak = true
				playSound(r, "squeak")
			end
		end
	else
		local idle = IDLES[pers.idle]
		if not idle then
			warnOnce("idle:" .. tostring(pers.idle), "no idle called '" .. tostring(pers.idle) .. "'")
			idle = IDLES.mope
		end
		idle(r, t, A, beat)
	end
	jiggle(r, t, 0.03 * A)

	-- 2. the mutation's flavour
	mutationLayer(r, clockNow + r.phase, beat, E * max(idleW, 0.4), hanging, carried)

	-- 3. reactions
	r.eyeW = 0
	if mode == "world" and not carried then
		local lw = r.lookW * (pers.look or 1) * (1 - r.sleep) * (1 - 0.7 * momW)
		if lw > 0.001 then
			lookAt(r, r.lookYaw, r.lookPitch, lw)
		end
		-- the pupils look too (more than the head does)
		r.eyeW = r.lookW * (1 - r.sleep)
		r.eyeYaw = r.lookYaw
		r.eyePitch = r.lookPitch
		local k = clockNow - r.noticeAt
		if k < 0.45 and not hanging then
			local n = sin(PI * k / 0.45)
			body(r, 0, R.NoticeHop * n * E, 0)
			chain(r, -0.1 * n * E, 0, 0, TOP)
		end
		if r.pairW > 0.001 then
			chainS(r, 0, r.pairYaw * R.PairTurn * r.pairW * (1 - 0.7 * lw), 0, TOP)
			local pb = beat * R.PairBopBpm / 60 + (min(r.uid, r.pairUid) % 7) * 0.13
			local hit = exp(-(pb % 1) * 7)
			chain(r, 0.07 * hit * r.pairW * E * idleW, 0, 0, TOP)
			squash(r, 0.04 * hit * r.pairW * E * idleW)
		end
		if r.panic > 0.001 then
			local p = r.panic
			bendToward(r, r.awayX, r.awayZ, R.PanicLean * p * E, EVEN)
			chain(r, R.PanicShiver * p * sin(clockNow * 31), R.PanicShiver * p * sin(clockNow * 27 + 1), 0, EVEN)
			squash(r, 0.05 * p)
			tentacles(r, clockNow * 9, 0.25 * p, 0.2 * p, 0.8)
		end
		if r.sleep > 0.001 then
			local sl = r.sleep
			local breath = sin(clockNow * TAU / 4.5 + r.phase)
			chain(r, 0.35 * sl, 0.08 * sl, 0, TOP)
			cuff(r, 0.3 * sl, 0, 0)
			squash(r, 0.05 * sl * (0.6 + breath))
			if sl > 0.6 then
				if clockNow >= r.nextZzz then
					r.nextZzz = clockNow + 1.2 + math.random() * 0.4
					zzz(r)
				end
				-- snore on the breath out
				if clockNow >= r.nextSnore and breath < -0.95 then
					r.nextSnore = clockNow + 3
					if r.camDist < 30 then
						playSound(r, "snore")
					end
				end
			end
		end
	end

	-- 4. the fidget / show-off, then the moment on top
	if actClip then
		actClip.fn(r, au, E * actW, r.actPrev)
		r.actPrev = au
	end
	if momClip then
		momClip.fn(r, mu, E * max(momW, 0.001), r.momPrev)
		r.momPrev = mu
	end

	if r.actName == "stare" or r.actName == "phase" then
		r.eyeW = actW
		r.eyeYaw = r.actYaw
		r.eyePitch = r.actPitch
	end

	-- 5. apply
	critters(r, t, A)
	limitJoints(r)
	googly(r, dt)
	local standing = not hanging
	local pivot = if hanging then r.ropeS else r.baseS
	local bodyCF = bodyCFrame(r, pivot)
	if mode == "world" or mode == "goodbye" then
		local moveRoot = canMove and not carried
		if r.bonesOn then
			solveBones(r, standing, nil, if moveRoot then bodyCF else nil)
		end
		if moveRoot then
			root.CFrame = f * bodyCF
		end
	elseif r.bonesOn then
		solveBones(r, standing, bodyCF, nil)
	else
		-- a menu sock without bones: move the model, unless someone else moved it since
		local current = model:GetPivot()
		if r.lastPivot and (current.Position - (r.lastPivot :: CFrame).Position).Magnitude > 1e-3 then
			r.frame = current * r.pivotOffset:Inverse() * r.lastBody:Inverse()
		end
		local target = r.frame * bodyCF * r.pivotOffset
		model:PivotTo(target)
		r.lastPivot = target
		r.lastBody = bodyCF
	end
	if r.fade ~= r.fadeShown then
		applyFade(r)
	end
end

-- ---------- tracking world socks ----------

local function readRigAttributes(r: Rig)
	local model = r.model
	local rest = model:GetAttribute("RestCFrame")
	r.rest = if typeof(rest) == "CFrame" then rest else nil
	local placed = model:GetAttribute("PlacedAt")
	r.placedAt = if type(placed) == "number" then placed - epoch else 0
	local owner = model:GetAttribute("OwnerId")
	r.ownerId = if type(owner) == "number" then owner else 0
	local paired = model:GetAttribute("Paired")
	r.paired = paired == true
	local pu = model:GetAttribute("PairUid")
	r.pairUid = if type(pu) == "number" then pu else 0
end

local function onStateChanged(r: Rig)
	local s = r.model:GetAttribute("State")
	local newState = if type(s) == "string" then s else "gone"
	local old = r.state
	if newState == old then
		return
	end
	r.state = newState
	r.homePos = nil
	-- let the rest of this replication batch (OwnerId, RestCFrame, PlacedAt) land first
	task.defer(function()
		if r.dead then
			return
		end
		readRigAttributes(r)
		if clockNow - r.created < 1 then
			return -- just streamed in: no fanfare
		end
		if old == "line" and newState == "drawer" then
			startMoment(r, "bought")
		elseif old == "drawer" and newState == "carried" then
			r.carryOwner = r.ownerId
			startMoment(r, "stolen")
		elseif old == "carried" and newState == "drawer" then
			startMoment(r, if r.ownerId == r.carryOwner then "home" else "land")
		end
		r.lastNear = clockNow
	end)
end

local function onPairChanged(r: Rig)
	task.defer(function()
		if r.dead then
			return
		end
		local wasUid = r.pairUid
		local was = r.paired
		readRigAttributes(r)
		if clockNow - r.created < 1.5 or r.state ~= "drawer" then
			return
		end
		if r.paired and r.pairUid ~= 0 and (not was or r.pairUid ~= wasUid) then
			-- face the new other half for the dance
			local other = rigsByUid[r.pairUid]
			local oroot = other and other.root
			if oroot and r.rest then
				local yaw = aim(r, r.rest :: CFrame, oroot.Position + Vector3.new(0, r.eyeS.Y - r.baseS.Y, 0))
				r.pairYaw = clamp(yaw, -1.1, 1.1)
				r.pairW = 1
			end
			startMoment(r, "paired")
		end
	end)
end

local function trackSock(inst: Instance)
	if not inst:IsA("Model") or rigsByModel[inst] then
		return
	end
	local model = inst :: Model
	local typeId = model:GetAttribute("TypeId")
	local function attr(name: string, fallback: any): any
		local v = model:GetAttribute(name)
		return if v ~= nil then v else fallback
	end
	local r = newRig(
		model,
		"world",
		if type(typeId) == "string" then typeId else "",
		tostring(attr("Side", "R")),
		tostring(attr("Rarity", "Common")),
		tostring(attr("Mutation", "None")),
		tonumber(attr("Uid", 0)) or 0
	)
	local ok, err = pcall(buildRig, r, if fxMod then fxMod.PinOffset() else nil)
	if not ok then
		warnOnce("build:" .. r.typeId, "couldn't rig " .. model:GetFullName() .. ": " .. tostring(err))
		return
	end
	readRigAttributes(r)
	local s = model:GetAttribute("State")
	r.state = if type(s) == "string" then s else "gone"
	r.carryOwner = r.ownerId -- streamed in mid-steal: the owner is still the victim
	addRig(r)
	table.insert(r.conns, model:GetAttributeChangedSignal("State"):Connect(function()
		onStateChanged(r)
	end))
	for _, name in ipairs({ "RestCFrame", "PlacedAt", "OwnerId" }) do
		table.insert(r.conns, model:GetAttributeChangedSignal(name):Connect(function()
			readRigAttributes(r)
		end))
	end
	for _, name in ipairs({ "Paired", "PairUid" }) do
		table.insert(r.conns, model:GetAttributeChangedSignal(name):Connect(function()
			onPairChanged(r)
		end))
	end
	-- parts and bones can stream in after the model: rig again a moment after the last one
	table.insert(r.conns, model.DescendantAdded:Connect(function(d)
		if d:IsA("Bone") or d:IsA("BasePart") then
			r.rebuildAt = os.clock() + 0.5
		end
	end))
	table.insert(r.conns, model.Destroying:Connect(function()
		removeRig(r)
	end))
end

local function untrackSock(inst: Instance)
	if inst:IsA("Model") then
		local r = rigsByModel[inst :: Model]
		if r and r.mode == "world" then
			removeRig(r)
		end
	end
end

-- ---------- the loop ----------

local looping = false
local frameNo = 0
local lastSettings = 0
local lastPlayers = 0
local lastIntruders = 0
local lastFloor = -100

-- which menu viewport the model sits in, and whether it's on screen
local function uiVisible(model: Model): boolean
	local p: Instance? = model.Parent
	local sawGui = false
	while p do
		if p:IsA("GuiObject") then
			sawGui = true
			if not p.Visible then
				return false
			end
		elseif p:IsA("LayerCollector") then
			sawGui = true
			if not p.Enabled then
				return false
			end
		elseif p:IsA("PlayerGui") then
			return true
		elseif p == workspace then
			return true
		end
		p = p.Parent
	end
	return not sawGui and model.Parent ~= nil
end

local function perfMaxBones(): number
	local n = Config.Perf.MaxBoneSocks
	return if type(n) == "number" and n > 0 then n else 40
end

local function step(dtFrame: number)
	frameNo += 1
	local nowServer = workspace:GetServerTimeNow()
	clockNow = nowServer - epoch
	local beat = clockNow
	local cam = workspace.CurrentCamera
	if cam then
		camPos = cam.CFrame.Position
	end
	local wall = os.clock()
	if wall - lastSettings > 0.5 then
		lastSettings = wall
		reduceMotion = ClientSettings.Get("reduceMotion") == true
		lowGraphics = ClientSettings.Get("lowGraphics") == true
		hideOthers = ClientSettings.Get("hideOthersFX") == true
		local v = ClientSettings.Get("sfxVolume")
		sfxVolume = if type(v) == "number" then clamp(v, 0, 1) else 0.8
	end
	if wall - lastPlayers > 0.1 then
		lastPlayers = wall
		refreshPlayers()
	end
	if wall - lastFloor > 2 then
		lastFloor = wall
		myFloor = floorOf(myId)
	end
	if wall - lastIntruders > 0.25 then
		lastIntruders = wall
		scanIntruders()
	end
	-- too many socks bending at once (a crowd of drawers on screen): pull the bone range in a little
	-- each frame until it fits, and let it out again when there's room
	local maxBones = perfMaxBones()
	if boneCount > maxBones then
		boneScale = max(0.25, boneScale * 0.97)
	elseif boneCount < maxBones * 0.75 then
		boneScale = min(1, boneScale * 1.004)
	end
	boneCount = 0
	-- menus with many socks on screen: every other frame
	uiActive = 0
	for _, r in ipairs(rigList) do
		if r.mode == "ui" and r.visible then
			uiActive += 1
		end
	end
	local perf = Config.Perf
	for i = #rigList, 1, -1 do
		local r = rigList[i]
		if r and not r.failed and not r.dead then
			local go = true
			local root = r.root
			if r.rebuildAt > 0 and wall >= r.rebuildAt then
				r.rebuildAt = 0
				pcall(buildRig, r, if fxMod then fxMod.PinOffset() else nil)
				root = r.root
			end
			if r.mode == "ui" then
				if wall >= r.nextVis then
					r.nextVis = wall + 0.25
					r.visible = uiVisible(r.model)
				end
				go = r.visible and (uiActive <= perf.UIFullRate or (frameNo + i) % 2 == 0)
				r.camDist = 0
			elseif root then
				local d = (root.Position - camPos).Magnitude
				r.camDist = d
				if d > perf.FarRange then
					go = (frameNo + r.uid) % 4 == 0
				elseif d > perf.HalfRateRange then
					go = (frameNo + r.uid) % 2 == 0
				end
			else
				go = false
			end
			if go then
				local dt = clamp(clockNow - r.lastT, 0, 0.25)
				r.lastT = clockNow
				local ok, err = pcall(update, r, if dt > 0 then dt else dtFrame, beat)
				if not ok then
					r.failed = true
					warnOnce("run:" .. r.typeId, "stopped animating a " .. r.typeId .. " (" .. tostring(err) .. ") - SockFX takes it over")
					pcall(resetBones, r)
				end
			end
		end
	end
end

local function ensureLoop()
	if looping then
		return
	end
	looping = true
	epoch = floor(workspace:GetServerTimeNow() / 86400) * 86400
	clockNow = workspace:GetServerTimeNow() - epoch
	RunService.RenderStepped:Connect(function(dt)
		step(dt)
	end)
end

-- ---------- the FX remote: flinch at snaps, cheer at big buys ----------

local function rankFromColor(color: Color3): number
	for _, tier in pairs(RarityConfig.Tiers) do
		local c = tier.color
		if abs(c.R - color.R) < 0.01 and abs(c.G - color.G) < 0.01 and abs(c.B - color.B) < 0.01 then
			return tier.rank
		end
	end
	return 0
end

local function onFX(kind: any, position: any, color: any)
	if typeof(position) ~= "Vector3" then
		return
	end
	local R = Config.Reactions
	if kind == "snap" then
		local nearest: Rig? = nil
		local nearestD = math.huge
		for _, r in ipairs(rigList) do
			local root = r.root
			if r.mode == "world" and root and r.state ~= "carried" then
				local d = (root.Position - position).Magnitude
				if d <= R.FlinchRange then
					local v = r.curFrame:VectorToObjectSpace(root.Position - position)
					local flat = Vector3.new(v.X, 0, v.Z)
					local away = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, 1)
					r.cheerVoice = false
					startMoment(r, "flinch", away.X, away.Z)
					if r.camDist < nearestD then
						nearest = r
						nearestD = r.camDist
					end
				end
			end
		end
		if nearest and nearest.momName == "flinch" then
			nearest.cheerVoice = true
		end
	elseif (kind == "buy" or kind == "claim") and typeof(color) == "Color3" then
		if rankFromColor(color) < R.CheerFromRank then
			return
		end
		-- everyone near the camera cheers, a ripple; the two nearest make the noise
		local a: Rig?, b: Rig? = nil, nil
		for _, r in ipairs(rigList) do
			if r.mode == "world" and r.root and r.camDist <= R.CheerRange and r.state ~= "line" then
				r.cheerAt = clockNow + math.random() * R.CheerDelay
				r.cheerVoice = false
				if not a or r.camDist < a.camDist then
					b = a
					a = r
				elseif not b or r.camDist < b.camDist then
					b = r
				end
			end
		end
		if a then
			a.cheerVoice = true
		end
		if b then
			b.cheerVoice = true
		end
	end
end

-- ---------- API ----------

local inited = false

function SockAnim.Init()
	if inited then
		return
	end
	inited = true
	ensureLoop()
	-- take the sock motion over from SockFX (which keeps it for any sock we can't animate)
	local fxModule = script.Parent:FindFirstChild("SockFX")
	if fxModule and fxModule:IsA("ModuleScript") then
		local ok, fx = pcall(require, fxModule)
		if ok and type(fx) == "table" and type(fx.SetDriver) == "function" and type(fx.LinePin) == "function" then
			fxMod = fx
			fx.SetDriver(function(model: Model): boolean
				local r = rigsByModel[model]
				return r ~= nil and not r.failed and not r.dead
			end)
		else
			warn("[SockAnim] SockFX has no hand-off (SetDriver / LinePin) - line socks keep SockFX's motion")
		end
	end
	for _, p in ipairs(Players:GetPlayers()) do
		addPlayer(p)
	end
	Players.PlayerAdded:Connect(addPlayer)
	Players.PlayerRemoving:Connect(removePlayer)
	-- the rig agent's bone roles, when the file exists (bones are found by name without it)
	task.spawn(function()
		local module = ConfigFolder:FindFirstChild("SockRigConfig") or ConfigFolder:WaitForChild("SockRigConfig", 10)
		if module and module:IsA("ModuleScript") then
			local ok, loaded = pcall(require, module)
			if ok and type(loaded) == "table" then
				RigConfig = loaded
				for _, r in ipairs(rigList) do
					r.rebuildAt = os.clock() + math.random() * 0.5
				end
			else
				warn("[SockAnim] SockRigConfig didn't load: " .. tostring(loaded))
			end
		end
	end)
	for _, model in ipairs(CollectionService:GetTagged("Sock")) do
		trackSock(model)
	end
	CollectionService:GetInstanceAddedSignal("Sock"):Connect(trackSock)
	CollectionService:GetInstanceRemovedSignal("Sock"):Connect(untrackSock)
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("Remotes", 30)
		local fxRemote = remotes and remotes:WaitForChild("FX", 30)
		if fxRemote and fxRemote:IsA("RemoteEvent") then
			fxRemote.OnClientEvent:Connect(function(kind, position, color)
				local ok, err = pcall(onFX, kind, position, color)
				if not ok then
					warnOnce("fx", "FX reaction failed: " .. tostring(err))
				end
			end)
		end
	end)
end

-- the type / side from a template name like "Argylo_L"
local function infoFromName(model: Model): (string, string)
	local name = model.Name
	local typeId, side = string.match(name, "^(.-)_([LRS])$")
	if typeId and SockConfig.ById[typeId] then
		return typeId, side :: string
	end
	return name, "R"
end

-- Animates a standalone sock model (a menu's ViewportFrame copy): its personality idle and the
-- odd show-off, no reactions. Returns a handle; :Destroy() stops it and resets the pose.
function SockAnim.Attach(model: Model, mode: string?, info: { [string]: any }?)
	ensureLoop()
	local old = rigsByModel[model]
	if old then
		removeRig(old)
	end
	local i = info or {}
	local nameType, nameSide = infoFromName(model)
	local attrType = model:GetAttribute("TypeId")
	local typeId: string = if type(i.typeId) == "string" then i.typeId elseif type(attrType) == "string" then attrType else nameType
	local sockType = SockConfig.ById[typeId]
	local side: string = if type(i.side) == "string" then i.side elseif sockType and sockType.single then "S" else nameSide
	local rarity: string = if type(i.rarity) == "string" then i.rarity elseif sockType then sockType.rarity else "Common"
	local mutation: string = if type(i.mutation) == "string" then i.mutation else "None"
	local r = newRig(model, if mode == "goodbye" then "goodbye" else "ui", typeId, side, rarity, mutation, 0)
	local built, err = pcall(buildRig, r, nil)
	if not built then
		warnOnce("attach:" .. typeId, "couldn't rig the menu " .. typeId .. ": " .. tostring(err))
		return nil
	end
	-- an Animator would overwrite Bone.Transform every frame
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Animator") or d:IsA("AnimationController") then
			d:Destroy()
		end
	end
	addRig(r)
	table.insert(r.conns, model.Destroying:Connect(function()
		removeRig(r)
	end))
	local handle = {}
	function handle.Destroy(_self: any)
		if r.dead then
			return
		end
		removeRig(r)
		if not r.hasBones and r.lastPivot and model.Parent then
			pcall(function()
				model:PivotTo(r.frame * r.pivotOffset)
			end)
		end
	end
	return handle
end

-- Plays a one-shot on a sock (a world sock or an attached menu model).
function SockAnim.Moment(model: Model, kind: string)
	local r = rigsByModel[model]
	if not r or r.dead or type(kind) ~= "string" then
		return
	end
	if kind == "showoff" then
		r.actName = nil
		if r.momName and r.momPrio > 1 then
			return
		end
		r.momName = nil
		startAct(r, r.pers.showoff or "spin", true)
		r.nextFidget = clockNow + r.actDur + 2
	elseif MOMENTS[kind] then
		if kind == "paired" then
			r.pairYaw = 0
		end
		r.cheerVoice = r.mode ~= "ui"
		startMoment(r, kind)
	elseif CLIPS[kind] then
		startAct(r, kind, false)
	end
end

-- The drawer sock waves goodbye and poofs as it is sold: a local copy plays it while the real one
-- (removed by the server a moment later) is hidden. If it is still there after a few seconds (the
-- sale failed) it comes back.
function SockAnim.Goodbye(uid: number)
	local r = rigsByUid[uid]
	if not r or r.dead or r.hidden then
		return
	end
	local model = r.model
	local root = r.root
	if not root or not model.Parent then
		return
	end
	local ok, copy = pcall(function()
		return model:Clone()
	end)
	if not ok or not copy then
		return
	end
	local clone = copy :: Model
	CollectionService:RemoveTag(clone, "Sock")
	clone:SetAttribute("State", "goodbye")
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("ProximityPrompt") or d:IsA("BillboardGui") or d:IsA("Beam") or d:IsA("Highlight") or d:IsA("Sound") or d.Name == "SockAnimSparkle" or d.Name == "CarryWeld" then
			d:Destroy()
		end
	end
	clone.Parent = workspace
	local copyRig = newRig(clone, "goodbye", r.typeId, r.side, r.rarity, r.mutation, 0)
	copyRig.ownerId = r.ownerId
	local built = pcall(buildRig, copyRig, nil)
	if not built or not copyRig.root then
		clone:Destroy()
		return
	end
	copyRig.camDist = r.camDist
	addRig(copyRig)
	local copyRoot = copyRig.root :: BasePart
	copyRoot.Anchored = true
	-- hide the real one (locally) while the copy says goodbye
	r.hidden = true
	model:SetAttribute("AnimHidden", true)
	local restore = {} :: { [Instance]: any }
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			restore[d] = d.LocalTransparencyModifier
			d.LocalTransparencyModifier = 1
		elseif d:IsA("BillboardGui") or d:IsA("Beam") or d:IsA("ParticleEmitter") or d:IsA("Light") or d:IsA("Highlight") then
			local toggle: any = d
			restore[d] = toggle.Enabled
			toggle.Enabled = false
		end
	end
	startMoment(copyRig, "goodbye")
	copyRig.onDone = function()
		local where = if copyRig.root then (copyRig.root :: BasePart).CFrame * copyRig.midS else root.Position
		poofAt(where, r.tint)
		removeRig(copyRig)
		task.delay(1, function()
			clone:Destroy()
		end)
	end
	task.delay(8, function()
		if model.Parent then
			-- still here: the sale didn't happen
			for inst, v in pairs(restore) do
				if inst.Parent then
					if inst:IsA("BasePart") then
						inst.LocalTransparencyModifier = v
					else
						(inst :: any).Enabled = v
					end
				end
			end
			model:SetAttribute("AnimHidden", nil)
			r.hidden = false
		end
	end)
end

return SockAnim
