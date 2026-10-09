--[[
    Frame data for the training room (menus design 5.11): an attack's
    numbers, where in it your fighter is right now, and the combo readout.
    Also the training panel's other small pure answers (weapon choices,
    which hotkeys are free).

    Frames are 60 fps frames of the match clock (slow motion stretches them
    in real time, not in frames). FighterSim advances an attack's actionTime
    in the same step that starts it, so after the attack's k-th frame
    actionTime is k / 60, and the hitbox is out while
    Startup <= actionTime < Startup + Active. The numbers follow the usual
    fighting-game convention:
      startup    the frame the hitbox first comes out on (it counts that frame)
      active     frames the hitbox is out
      recovery   frames after that until the attack is over
      total      frames the attack lasts = startup - 1 + active + recovery
    so Avatar's Sword side light (0.107 s / 0.1 s / 0.194 s after its
    Dexterity) is 7 / 6 / 12, 24 frames in all, and its strip has 24 cells:
    6 startup, 6 active, 12 recovery. A charged heavy waits on frame 0 while
    it charges (actionTime doesn't run), and hit-stop holds the frame.
    This is the decided convention (menus design 5.11, README): mockup f's
    25 TOTAL and 7 startup cells count startup as the frames before the
    hitbox, which the sim's 24 frames can't match. The HUD says "HITS ON
    FRAME 7" under the move name, so the two readings can't be confused.

    Meter (one per attack you start): start(move, seq) lays out the strip,
    observe(sim) marks the frame the sim is on, finish(seq, sim) freezes it.
    An attack cut short (a jump or chase dodge out of a light that hit, the
    next punch of a chain) keeps only the frames it played and is marked
    cancelled; one cut short by a hit (hitstun, a guard break) is marked
    interrupted. A grounded jump cancel ends the attack without AttackEnd
    (FighterSim clears the action before its endAttack), so observe tells
    the two apart by the sim's action, not by the missing event. A ground
    pound that lands skips the rest of its active frames and plays its
    recovery to the end: that is the whole attack, not a cancel.

    Combo readout: fed the server's Hit events where you are the attacker
    (the hit's combo count, whether every hit so far linked, its damage).

    Panel helpers: the dummy behaviour labels, the weapons a legend can
    hold, the free hotkeys, and the panel's explicit keyboard / gamepad
    neighbours (panelLinks).
]]

local Config = require(script.Parent.Config)
local Weapons = require(script.Parent.Weapons)
local Legends = require(script.Parent.Legends)

local FrameData = {}

FrameData.FPS = 60
FrameData.PHASES = { "Startup", "Active", "Recovery" }

-- Summed frame times drift by a hair; a frame boundary is never decided by less than this.
local EPSILON = 1e-4

function FrameData.frames(seconds)
	return math.floor(seconds * 60 + 0.5)
end

-- The frame (counted from 1) on which an attack's clock first reaches `seconds`.
local function frameAt(seconds)
	return math.max(0, math.ceil(seconds * 60 - EPSILON))
end

-- "Side Light", or the signature's own name ("Gale Cut"), or the ultimate's.
function FrameData.moveName(move)
	if move.Signature then
		return move.Signature
	end
	return Weapons.SlotNames[move.Slot] or tostring(move.Slot or "Attack")
end

local summaries = setmetatable({}, { __mode = "k" }) -- [move] = summary (moves are frozen and cached)

-- move = Legends.getAttack(...) (already scaled by the legend's Dexterity).
function FrameData.summary(move)
	local cached = summaries[move]
	if cached then
		return cached
	end
	local startEdge = math.max(1, frameAt(move.Startup))
	local activeEdge = math.max(startEdge + 1, frameAt(move.Startup + move.Active))
	local endEdge = math.max(activeEdge, frameAt(move.Startup + move.Active + move.Recovery))
	local summary = {
		name = FrameData.moveName(move),
		startup = startEdge,
		active = activeEdge - startEdge,
		recovery = endEdge - activeEdge,
		total = endEdge - 1,
		charge = FrameData.frames(move.Charge or 0),
		damage = move.Damage,
		kbBase = move.BaseKnockback,
		kbScaling = move.KnockbackScaling,
		angle = move.Angle,
		air = move.Air == true,
		kind = move.Kind,
	}
	summaries[move] = summary
	return summary
end

-- The phase of each frame of a summary, in order (one strip cell per frame).
function FrameData.cells(summary)
	local cells = {}
	for frame = 1, summary.total do
		if frame < summary.startup then
			cells[frame] = "Startup"
		elseif frame < summary.startup + summary.active then
			cells[frame] = "Active"
		else
			cells[frame] = "Recovery"
		end
	end
	return cells
end

--[[
    Where an attack is after `actionTime` seconds of it: "Charge" (frame 0)
    while charging, else "Startup" | "Active" | "Recovery" and the frame
    index (0 before its first frame ran), or "Done" past its last frame.
]]
function FrameData.phaseAt(move, actionTime, charging)
	if charging then
		return "Charge", 0
	end
	local summary = FrameData.summary(move)
	local frame = math.max(0, math.ceil((actionTime or 0) * 60 - EPSILON))
	if frame < summary.startup then
		return "Startup", frame
	elseif frame < summary.startup + summary.active then
		return "Active", frame
	elseif frame <= summary.total then
		return "Recovery", frame
	end
	return "Done", frame
end

-- Meter -----------------------------------------------------------------------

local Meter = {}
Meter.__index = Meter

function FrameData.newMeter()
	local meter = setmetatable({}, Meter)
	meter:reset()
	return meter
end

function Meter:reset()
	self.move = nil
	self.seq = nil
	self.summary = nil
	self.cells = {}
	self.current = 0
	self.charging = false
	self.done = true
	self.cancelled = false
	self.interrupted = false
end

-- What the readout shows: { cells, current, summary?, charging, done, cancelled, interrupted }.
function Meter:view()
	return {
		cells = self.cells,
		current = self.current,
		summary = self.summary,
		charging = self.charging,
		done = self.done,
		cancelled = self.cancelled,
		interrupted = self.interrupted,
	}
end

-- A new attack (your sim's "Attack" event): seq is the sim's attack number.
function Meter:start(move, seq)
	self:reset()
	self.move = move
	self.seq = seq
	self.summary = FrameData.summary(move)
	self.cells = FrameData.cells(self.summary)
	self.done = false
	return self:view()
end

-- Stops the meter where it is; fewer frames than the attack has means it was cut short.
function Meter:freeze(interrupted)
	self.done = true
	self.charging = false
	if self.current < #self.cells then
		self.cancelled = not interrupted
		self.interrupted = interrupted == true
		local cells = {}
		for i = 1, self.current do
			cells[i] = self.cells[i]
		end
		self.cells = cells
	end
end

-- Marks the frame your sim is on (each step, after the sim moved).
function Meter:observe(sim)
	if self.done or not self.move then
		return self:view()
	end
	if sim.seq ~= self.seq or sim.action ~= "Attack" then
		-- the attack ended without its AttackEnd: a hit or a guard break cut it off (interrupted), or the sim
		-- dropped it itself (a grounded jump cancel clears the action before its endAttack can report it)
		self:freeze(sim.action == "Hitstun" or sim.action == "Stunned")
		return self:view()
	end
	local phase, frame = FrameData.phaseAt(self.move, sim.actionTime, sim.charging)
	self.charging = phase == "Charge"
	if frame > self.current then
		self.current = math.min(frame, #self.cells)
	end
	return self:view()
end

--[[
    The sim's "AttackEnd" for attack `seq`. An attack that ran to its end
    has its clock past the last frame; one cancelled before that (or
    replaced by the next attack in the same step) keeps what it played.
]]
function Meter:finish(seq, sim)
	if self.done or seq ~= self.seq then
		return self:view()
	end
	if sim and sim.seq == seq and type(sim.actionTime) == "number" then
		local _, frame = FrameData.phaseAt(self.move, sim.actionTime, false)
		if frame > #self.cells then
			self.current = #self.cells
		elseif frame > self.current then
			self.current = frame
		end
	end
	self:freeze(false)
	return self:view()
end

-- Combo readout -------------------------------------------------------------------

local Combo = {}
Combo.__index = Combo

function FrameData.newCombo()
	return setmetatable({ hits = 0, damage = 0, lastHit = 0, linked = false }, Combo)
end

-- hit = the server's Hit event { combo, trueCombo, damage, total } for a hit you landed.
function Combo:onHit(hit)
	local count = if type(hit.combo) == "number" then math.max(1, math.floor(hit.combo)) else 1
	local damage = if type(hit.damage) == "number" then hit.damage else 0
	if count == 1 or count <= self.hits then
		-- a new combo (one whose first hits never reached us starts over too)
		self.damage = damage
	else
		self.damage += damage
	end
	self.hits = count
	self.lastHit = damage
	self.linked = hit.trueCombo == true
end

-- { hits, damage, lastHit, isTrue }: isTrue while a combo of 2+ hits has had every hit linked.
function Combo:get()
	return {
		hits = self.hits,
		damage = self.damage,
		lastHit = self.lastHit,
		isTrue = self.hits >= 2 and self.linked,
	}
end

function Combo:reset()
	self.hits, self.damage, self.lastHit, self.linked = 0, 0, 0, false
end

-- Training panel ----------------------------------------------------------------------

-- The dummy behaviours as the panel, the DUMMY readout and the overlay tag show them.
FrameData.MODE_LABELS = { Stand = "STAND", Jump = "JUMP", Dodge = "DODGE", Block = "BLOCK", Fight = "FIGHT BACK" }

-- What a legend can hold in the training room: Unarmed + its two weapons (Avatar: every weapon).
function FrameData.weaponOptions(legendId)
	local list = { "Unarmed" }
	local legend = Legends.get(legendId)
	for _, weaponId in legend.Weapons or Weapons.Order do
		table.insert(list, weaponId)
	end
	return list
end

-- "SWORD · GROUND": the weapon an attack came from and where it was done.
function FrameData.subtitle(weaponId, move)
	return string.upper(Weapons.get(weaponId).Name) .. " · " .. (if move and move.Air then "AIR" else "GROUND")
end

--[[
    The training hotkeys (Config.Training.Hotkeys) that are free to use:
    { Keyboard = { Panel?, Reset?, Spawn? }, Gamepad = { ... } } holding the
    key names, without any key that is also one of the player's fight
    keybinds. bindsFor(device, action) -> { keyName } (Settings.getBinds).
]]
function FrameData.hotkeys(bindsFor)
	local result = {}
	for device, keys in Config.Training.Hotkeys do
		local used = {}
		for _, action in Config.InputActions do
			for _, name in bindsFor(device, action) or {} do
				used[name] = true
			end
		end
		result[device] = {}
		for name, key in keys do
			if not used[key] then
				result[device][name] = key
			end
		end
	end
	return result
end

--[[
    Explicit keyboard / gamepad neighbours for the panel's controls (menus
    design 5.2), so Up / Down step through the rows in order and never skip
    a short one. rows = { { { id =, x =, w = } } }: the rows top to bottom,
    each its controls left to right with their horizontal extent (fractions
    of the row's width). Up / Down go to the control of the row above / below
    whose centre is nearest (the left one on a tie); Left / Right to the
    neighbours in the row. Past an edge a control is its own neighbour, so
    focus stays put rather than jumping by distance. Returns
    { [id] = { Up, Down, Left, Right } }.
]]
function FrameData.panelLinks(rows)
	local function centre(item)
		return item.x + item.w / 2
	end
	local function nearest(row, x)
		local best, bestDistance = nil, math.huge
		for _, item in row do
			local distance = math.abs(centre(item) - x)
			if distance < bestDistance - 1e-6 then
				best, bestDistance = item.id, distance
			end
		end
		return best
	end
	local links = {}
	for r, row in rows do
		for c, item in row do
			local id = item.id
			local above, below = rows[r - 1], rows[r + 1]
			links[id] = {
				Up = if above then nearest(above, centre(item)) else id,
				Down = if below then nearest(below, centre(item)) else id,
				Left = if row[c - 1] then row[c - 1].id else id,
				Right = if row[c + 1] then row[c + 1].id else id,
			}
		end
	end
	return links
end

return FrameData
