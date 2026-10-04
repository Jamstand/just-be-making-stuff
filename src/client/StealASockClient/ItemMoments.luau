-- ItemMoments: the item bar's "big and dramatic" moments, on this client only. The server sends
-- the ItemFX kind "moment" { kind, position, by, targets, strength } for a towel finisher hit, a towel
-- snap on a thief, a bubble catching a thief, a cloud nap, a golden slam or honk stun, a full-charge
-- zap on a thief, a peel bowling chain of 2+ and a pounce that drops a sock. ItemFX shows everyone
-- the burst; on the screens of the player who landed it (`by`) and of each target this adds:
--   * a hit-stop: the item animations on this screen freeze for ~0.1 s (ItemRig.SetTimeScale(0)),
--   * a "slow-motion" feel for ~0.6 s: the camera's FieldOfView punches in and eases back, a blur
--     and a colour pulse (a BlurEffect and a ColorCorrectionEffect of our own in Lighting), the
--     item effects and animations run slower and catch up, a deep whoosh,
--   * a stronger camera shake, stronger for the victim.
-- Reduce motion: none of that, only a quick soft flash. Nothing here touches anyone's physics; the
-- FieldOfView is put back exactly when a moment ends (unless something else changed it meanwhile).
-- Also small "kicks" for a towel snap on a thief: a short hit-stop and a little FieldOfView kick.
-- API (ItemFX drives it): ItemMoments.Init(env), ItemMoments.Play(role, strength, reduced),
--   ItemMoments.Kick(amount, reduced), ItemMoments.HitStop(seconds), ItemMoments.Update(dt),
--   ItemMoments.TimeScale() -> the effects' time scale, ItemMoments.Active() -> boolean
local Lighting = game:GetService("Lighting")

local ItemMoments = {}

local HIT_STOP = 0.1 -- seconds the animations freeze
local SLOW = 0.6 -- seconds of slow motion after it
local RIG_SLOW = 0.4 -- the animations' speed when the slow motion starts (eases back to 1)
local FX_SLOW = 0.35 -- the effects' speed when the slow motion starts
local FX_STOP = 0.1 -- the effects' speed during the hit-stop (nearly frozen)
local FOV_PUNCH = 9 -- degrees the camera zooms in at strength 1
local BLUR = 12 -- BlurEffect.Size at strength 1
local FLASH = 0.16 -- seconds of the Reduce motion flash
local KICK = 0.18 -- seconds of a snap's FieldOfView kick

type Env = {
	rig: any?, -- ItemRig (SetTimeScale)
	shake: ((amount: number, seconds: number?) -> ())?,
	sound: ((name: string, pitch: number?) -> ())?,
}

local env: Env = {}
local moment: { t0: number, strength: number, flashOnly: boolean }? = nil
local kick: { t0: number, amount: number }? = nil
local stopUntil = 0
local baseFov: number? = nil -- the camera's FieldOfView before we touched it
local wroteFov: number? = nil
local blur: BlurEffect? = nil
local color: ColorCorrectionEffect? = nil
local fxScale = 1

local function ease(u: number): number
	u = math.clamp(u, 0, 1)
	return u * u * (3 - 2 * u)
end

local function effects(): (BlurEffect, ColorCorrectionEffect)
	local b = blur
	if not b or b.Parent == nil then
		local made = Instance.new("BlurEffect")
		made.Name = "ItemMomentBlur"
		made.Size = 0
		made.Enabled = false
		made.Parent = Lighting
		blur = made
		b = made
	end
	local c = color
	if not c or c.Parent == nil then
		local made = Instance.new("ColorCorrectionEffect")
		made.Name = "ItemMomentColor"
		made.Enabled = false
		made.Parent = Lighting
		color = made
		c = made
	end
	return b :: BlurEffect, c :: ColorCorrectionEffect
end

local function camera(): Camera?
	return workspace.CurrentCamera
end

-- remember the FieldOfView before the first change
local function grabFov()
	local cam = camera()
	if cam and baseFov == nil then
		baseFov = cam.FieldOfView
	end
end

local function setFov(value: number)
	local cam = camera()
	if cam then
		cam.FieldOfView = value
		wroteFov = value
	end
end

-- did something else change the FieldOfView since we wrote it? (it's stored as a float: a tolerance)
local function fovChanged(cam: Camera): boolean
	return wroteFov ~= nil and math.abs(cam.FieldOfView - (wroteFov :: number)) > 0.01
end

local function releaseFov()
	local cam = camera()
	local base = baseFov
	if cam and base and wroteFov ~= nil and not fovChanged(cam) then
		cam.FieldOfView = base -- (something else changed it meanwhile: that wins)
	end
	baseFov = nil
	wroteFov = nil
end

function ItemMoments.Init(e: Env)
	env = e
end

-- A big moment on this screen. role: "by" (you landed it) or "target" (it landed on you); strength
-- 0..1. reduced (Reduce motion): only a quick flash.
function ItemMoments.Play(role: string, strength: number?, reduced: boolean?)
	local s = math.clamp(if type(strength) == "number" and strength == strength then strength else 0.6, 0, 1)
	local t = os.clock()
	if moment and t - moment.t0 < HIT_STOP + SLOW then
		s = math.max(s, moment.strength) -- a second one while the first plays: the stronger wins
	end
	moment = { t0 = t, strength = s, flashOnly = reduced == true }
	if reduced then
		return
	end
	grabFov()
	stopUntil = math.max(stopUntil, t + HIT_STOP * (0.6 + 0.4 * s))
	if env.shake then
		local amount = if role == "target" then 0.3 + 0.5 * s else 0.18 + 0.32 * s
		env.shake(amount, 0.45)
	end
	if env.sound then
		env.sound("whooshDeep", 1 - 0.15 * s)
	end
end

-- A little FieldOfView kick (a towel snap landing on a thief). Not during a moment or Reduce motion.
function ItemMoments.Kick(amount: number, reduced: boolean?)
	if reduced or (moment and not moment.flashOnly) then
		return
	end
	grabFov()
	kick = { t0 = os.clock(), amount = math.clamp(amount, 0, 1) }
end

-- Freezes the item animations on this screen for a moment (a hit landing).
function ItemMoments.HitStop(seconds: number)
	stopUntil = math.max(stopUntil, os.clock() + math.clamp(seconds, 0, 0.2))
end

function ItemMoments.TimeScale(): number
	return fxScale
end

function ItemMoments.Active(): boolean
	return moment ~= nil or kick ~= nil or os.clock() < stopUntil
end

-- Every frame (ItemFX): the time scales, the camera, the blur and the colour.
function ItemMoments.Update(_dt: number)
	local t = os.clock()
	local rigScale, fx = 1, 1
	local fovOffset = 0
	local m = moment
	if m then
		local age = t - m.t0
		if m.flashOnly then
			local _, c = effects()
			if age < FLASH then
				c.Enabled = true
				c.Brightness = 0.16 * (1 - age / FLASH)
				c.Saturation = 0
				c.Contrast = 0
			else
				c.Enabled = false
				c.Brightness = 0
				moment = nil
			end
		elseif age < HIT_STOP + SLOW then
			local s = m.strength
			local k: number
			if age < HIT_STOP then
				k = math.min(age / 0.05, 1)
				rigScale, fx = 0, FX_STOP
			else
				local u = ease((age - HIT_STOP) / SLOW)
				k = 1 - u
				rigScale = RIG_SLOW + (1 - RIG_SLOW) * u
				fx = FX_SLOW + (1 - FX_SLOW) * u
			end
			fovOffset -= FOV_PUNCH * s * k
			local b, c = effects()
			b.Enabled = true
			b.Size = BLUR * s * k
			c.Enabled = true
			c.Saturation = 0.3 * s * k
			c.Contrast = 0.12 * s * k
			c.Brightness = 0.05 * s * k
		else
			local b, c = effects()
			b.Enabled = false
			b.Size = 0
			c.Enabled = false
			c.Saturation = 0
			c.Contrast = 0
			c.Brightness = 0
			moment = nil
		end
	end
	local kk = kick
	if kk then
		local age = t - kk.t0
		if age < KICK then
			local k = if age < 0.04 then age / 0.04 else 1 - ease((age - 0.04) / (KICK - 0.04))
			fovOffset -= 4 * kk.amount * k
		else
			kick = nil
		end
	end
	if t < stopUntil then
		rigScale = 0
		fx = math.min(fx, FX_STOP)
	end
	fxScale = fx
	if env.rig then
		env.rig.SetTimeScale(rigScale)
	end
	local base = baseFov
	if base then
		local cam = camera()
		if cam and fovChanged(cam) then
			-- something else changed the FieldOfView meanwhile: it wins, we stop touching it
			baseFov = nil
			wroteFov = nil
		elseif moment or kick then
			setFov(base + fovOffset)
		else
			releaseFov()
		end
	end
end

-- Ends everything at once and puts the camera back (tests, a respawn).
function ItemMoments.Reset()
	moment = nil
	kick = nil
	stopUntil = 0
	fxScale = 1
	releaseFov()
	if blur then
		blur.Enabled = false
		blur.Size = 0
	end
	if color then
		color.Enabled = false
	end
	if env.rig then
		env.rig.SetTimeScale(1)
	end
end

return ItemMoments
