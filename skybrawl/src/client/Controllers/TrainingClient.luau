--[[
    Client side of the training room (menus design 5.11). MatchClient calls
    these hooks during a training match; TrainingHUD (UI) is the screen.

      start(m)              builds the HUD and the hitbox overlays
      step(m, dt)           each frame (dt already slowed by the time scale):
                            the frame meter follows your sim, the readouts
                            and overlays update
      onOwnAttack / onOwnAttackEnd   your sim's attacks start / end a meter
                            (FrameData), so cancels show as a shorter strip
      onHit(m, d)           server Hit events you landed feed the combo readout
      onServer(m, d)        MatchEvent "Training": the dummy's 20 Hz snapshot,
                            or the room's settings (the panel re-renders)
      stop()                tears it all down (also pops the panel's layer)

    Panel focus has one toggle path: with the panel's Focus layer closed,
    the Panel hotkey (Tab / View, read from UserInputService.InputBegan, not
    game-processed) opens it; while it is open that handler ignores the
    hotkey and the layer's Menu action closes it (and hides the panel). Back
    closes the layer but keeps the panel on screen. Opening and closing wait
    (task.defer) until every InputBegan handler has seen the press, because
    Roblox runs them in no set order: otherwise Focus could read the Tab
    that just opened the layer as the layer's Menu (close), or Input could
    read the gamepad B that closed it as a Heavy once fight input is back
    on. (Focus also ignores a press in the frame a layer was pushed.) Fight
    input is off while the layer is open because Focus owns
    Input.setEnabled (an inMatch layer); nothing here touches it. The other
    hotkeys (reset positions, spawn weapon) work while fighting. A hotkey
    that is also one of your fight keybinds is off (FrameData.hotkeys) and
    has no hint.

    Every control sends TrainingRequest. Settings go through one queue per
    group (your legend and weapon share one, so a weapon picked for a new
    legend never reaches the server before that legend): one request in
    flight, and a newer pick for the same setting replaces the one still
    waiting. The panel keeps showing your picks while their requests are
    going, then what the server last sent ("Settings"); a refusal ("Wait
    for the countdown." during 3-2-1) is toasted and that setting goes
    back. Your legend and weapon also change without a "Settings" (a
    pickup, a throw, a KO): step() follows the match's. RESET POSITIONS,
    SPAWN WEAPON and LEAVE go one at a time, at most one every REPEAT_GAP,
    so a mashed hotkey can't use up the server's rate limit.

    The DISPLAY toggles and the spawner's weapon are remembered for the
    session (this module stays loaded between matches). Overlays (when
    Hitboxes is on) are local parts in workspace.SkybrawlTrainingDebug, in
    front of the fighters (z + 2): both hurtboxes as blue outlines, your
    active hitbox (exact, from your sim) and the dummy's (from its
    snapshot, so it can trail by one) in red with an "ACTIVE a/b" tag, the
    dummy's damage above it and "YOU" / "DUMMY · <mode>" tags.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Legends = require(Shared.Legends)
local Weapons = require(Shared.Weapons)
local FighterSim = require(Shared.FighterSim)
local FrameData = require(Shared.FrameData)
local Net = require(Shared.Net)

local ClientState = require(script.Parent.Parent.ClientState)
local Settings = require(script.Parent.Settings)

local UI = script.Parent.Parent:WaitForChild("UI")
local UIKit = require(UI.UIKit)
local Focus = require(UI.Focus)
local Layout = require(UI.Layout)
local TrainingHUD = require(UI.TrainingHUD)

local TrainingClient = {}

local T = UIKit.Theme
local OVERLAY_Z = 2 -- studs in front of the fighters
local SNAPSHOT_STALE = 0.25 -- the dummy's hitbox is hidden when its last snapshot is older than this
local DAMAGE_HOLD = 1 -- seconds a damage you just set shows before the server's value replaces it
local PANEL_REPRESS = 0.15 -- a Panel key press this soon after Menu closed the layer is that same press
local REPEAT_GAP = 0.15 -- RESET POSITIONS / SPAWN WEAPON / LEAVE: at most one request this often
-- The settings requests' queues: requests in one queue reach the server in the order they were made.
local CHANNELS = {
	SetLegend = "You",
	SetWeapon = "You",
	SetDummyLegend = "DummyLegend",
	SetDummyMode = "DummyMode",
	SetDamage = "Damage",
	KeepDamage = "KeepDamage",
	SetSpeed = "Speed",
}
-- The requests that change each "Settings" field (a new legend also puts your weapon away).
local FIELD_ACTIONS = {
	legend = { "SetLegend" },
	weapon = { "SetWeapon", "SetLegend" },
	dummyLegend = { "SetDummyLegend" },
	dummyMode = { "SetDummyMode" },
	difficulty = { "SetDummyMode" },
	keepDamage = { "KeepDamage" },
	speed = { "SetSpeed" },
}
local SETTING_TYPES = {
	legend = "string",
	weapon = "string",
	dummyLegend = "string",
	dummyMode = "string",
	difficulty = "string",
	keepDamage = "boolean",
	speed = "number",
}

-- Remembered for the play session.
local display = { Hitboxes = true, FrameData = true, Combo = true }
local spawnWeapon = Weapons.Order[1]

local session = nil

-- Requests --------------------------------------------------------------------------------

-- True while a request of `action` is in flight or waiting in its queue.
local function busy(s, action)
	local channel = s.channels[CHANNELS[action]]
	if not channel then
		return false
	end
	if channel.inflight == action then
		return true
	end
	for _, entry in channel.queue do
		if entry.action == action then
			return true
		end
	end
	return false
end

-- The panel shows the server's settings, except the ones with a request still going (they keep your pick).
local function showConfirmed(s)
	local view = {}
	for field, actions in FIELD_ACTIONS do
		local held = false
		for _, action in actions do
			held = held or busy(s, action)
		end
		if not held then
			view[field] = s.settings[field]
		end
	end
	s.hud:setSettings(view)
end

-- One TrainingRequest (yields); a refusal is toasted. True when the server took it.
local function invoke(s, action, payload)
	local remote = Net.get("TrainingRequest")
	local ok, result, message = pcall(remote.InvokeServer, remote, action, payload)
	if session ~= s then
		return false
	end
	if not ok then
		warn("[TrainingClient] " .. action .. " failed:", result)
		ClientState.toast("Couldn't reach the server.", "error")
		return false
	elseif result ~= true then
		ClientState.toast(if type(message) == "string" then message else "That didn't work.", "error")
		return false
	end
	return true
end

-- Sends a queue's requests in order, one at a time (started when the queue was idle).
local function drain(s, channel)
	while session == s and #channel.queue > 0 do
		local entry = table.remove(channel.queue, 1)
		channel.inflight = entry.action
		local ok = invoke(s, entry.action, entry.payload)
		if session ~= s then
			return
		end
		channel.inflight = nil
		if not ok then
			if entry.action == "SetDamage" and not busy(s, "SetDamage") then
				s.damageHold = nil
			end
			-- back to what the server last confirmed (a newer pick for it still waiting keeps showing)
			showConfirmed(s)
		end
	end
	channel.inflight = nil
	if session == s then
		showConfirmed(s)
	end
end

local function request(action, payload)
	local s = session
	if not s then
		return
	end
	payload = payload or {}
	local channelName = CHANNELS[action]
	if channelName then
		if action == "SetDamage" then
			-- the value you set shows until the server's Damage event confirms it (or DAMAGE_HOLD passes)
			s.damageHold = { value = payload.value, untilTime = os.clock() + DAMAGE_HOLD }
		end
		local channel = s.channels[channelName]
		if not channel then
			channel = { inflight = nil, queue = {} }
			s.channels[channelName] = channel
		end
		-- the newest pick goes last; one still waiting for the same setting (or made stale by it) is dropped
		for i = #channel.queue, 1, -1 do
			local waiting = channel.queue[i].action
			if waiting == action or (action == "SetLegend" and waiting == "SetWeapon") then
				table.remove(channel.queue, i)
			end
		end
		table.insert(channel.queue, { action = action, payload = payload })
		if not channel.inflight then
			task.spawn(drain, s, channel)
		end
		return
	end
	-- the rest: one at a time, at most one every REPEAT_GAP (a mashed R / V, a double-clicked LEAVE)
	local now = os.clock()
	if s.sending[action] or now - (s.sentAt[action] or -math.huge) < REPEAT_GAP then
		return
	end
	s.sending[action] = true
	s.sentAt[action] = now
	task.spawn(function()
		invoke(s, action, payload)
		s.sending[action] = nil
	end)
end

-- Panel ---------------------------------------------------------------------------------------

-- Runs fn(...) once every InputBegan handler has seen the current press, if this session still runs.
local function afterInput(s, fn, ...)
	task.defer(function(...)
		if session == s then
			fn(...)
		end
	end, ...)
end

local function closePanel(s, hide)
	if s.layer then
		Focus.popLayer(s.layer)
		s.layer = nil
		s.closedAt = os.clock()
	end
	if hide then
		s.shown = false
	end
	s.hud:setPanel(s.shown, false)
end

local function openPanel(s)
	if s.layer then
		return
	end
	s.shown = true
	s.hud:setPanel(true, true)
	s.layer = Focus.pushLayer({
		name = "TrainingPanel",
		roots = { s.hud.panel },
		band = "overlay",
		inMatch = true,
		defaultFocus = function()
			return s.hud:defaultFocus()
		end,
		-- (deferred, so the HUD and the layer close after every handler has seen the B / Tab; Focus also turns
		-- fight input back on one task.defer later, so that key never reaches Input)
		onBack = function()
			afterInput(s, closePanel, s, false)
		end,
		actions = {
			Menu = function()
				afterInput(s, closePanel, s, true)
			end,
		},
	})
end

-- The PANEL button / hint (mouse and touch): shows or hides the panel.
local function togglePanel()
	local s = session
	if not s then
		return
	end
	if s.layer then
		closePanel(s, true)
	else
		s.shown = not s.shown
		s.hud:setPanel(s.shown, false)
	end
end

local function spawnPressed(weaponId)
	if not table.find(Weapons.Order, weaponId) then
		return
	end
	spawnWeapon = weaponId
	local s = session
	if s then
		s.hud:setSpawnWeapon(weaponId)
		request("SpawnWeapon", { weapon = weaponId })
	end
end

local function setDisplay(name, on)
	display[name] = on == true
	local s = session
	if s then
		s.hud:setDisplay(display)
		s.frameDirty = true
		s.comboDirty = true
		s.folder.Parent = if display.Hitboxes then workspace else nil
	end
end

-- Another inMatch layer (the pause menu) is on top: hotkeys wait.
local function otherLayerOnTop(s)
	local top = Focus.topLayer()
	return top ~= nil and top ~= s.layer and type(top) == "table" and top.inMatch == true
end

local function onInputBegan(input, gameProcessed)
	local s = session
	if not s or gameProcessed then
		return
	end
	local inputType = input.UserInputType
	local device = nil
	if inputType == Enum.UserInputType.Keyboard then
		device = "Keyboard"
	elseif string.sub(inputType.Name, 1, 7) == "Gamepad" then
		device = "Gamepad"
	end
	if not device or UserInputService:GetFocusedTextBox() or otherLayerOnTop(s) then
		return
	end
	local keys = s.hotkeys[device]
	local name = input.KeyCode.Name
	if name == keys.Panel then
		if s.layer or os.clock() - s.closedAt < PANEL_REPRESS then
			return
		end
		-- (deferred: Focus must not see this same Tab / View as the new layer's Menu, which closes it)
		afterInput(s, function()
			if not s.layer then
				openPanel(s)
			end
		end)
	elseif name == keys.Reset then
		request("ResetPositions")
	elseif name == keys.Spawn then
		spawnPressed(spawnWeapon)
	end
end

-- Overlays ------------------------------------------------------------------------------------

local function overlayPart(folder, name, color, transparency)
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.Color = color
	part.Transparency = transparency
	part.Size = Vector3.new(1, 1, 0.1)
	part.Parent = folder
	return part
end

-- A tag over a part: a BillboardGui with one label. Returns the label.
local function tagOn(part, props)
	local gui = Instance.new("BillboardGui")
	gui.Name = props.name
	gui.Adornee = part
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 1000
	gui.StudsOffsetWorldSpace = props.offset
	gui.Parent = part
	Layout.bindPxSize(gui, props.width, props.height) -- (re-applied when the safe area changes)
	local label = Instance.new("TextLabel")
	label.BackgroundColor3 = props.fill or T.Backdrop
	label.BackgroundTransparency = if props.fill then 0 else 1
	label.BorderSizePixel = 0
	label.Font = props.font or T.BlackFont
	label.TextColor3 = props.color or T.Text
	label.Text = props.text or ""
	label.Size = UDim2.fromScale(1, 1)
	label.Parent = gui
	Layout.bindText(label, props.textSize)
	return label
end

local function hurtboxPart(folder, name)
	local part = overlayPart(folder, name, T.Hurtbox, 1)
	local box = Instance.new("SelectionBox")
	box.Adornee = part
	box.Color3 = T.Hurtbox
	box.LineThickness = 0.08
	box.SurfaceTransparency = 1
	box.Parent = part
	return part
end

local function buildOverlays(s)
	local folder = Instance.new("Folder")
	folder.Name = "SkybrawlTrainingDebug"
	s.folder = folder
	local o = {}
	s.overlays = o
	local top = Config.Physics.FighterHeight / 2
	o.myHurt = hurtboxPart(folder, "YourHurtbox")
	tagOn(o.myHurt, {
		name = "You",
		text = "YOU",
		fill = T.Red,
		width = 64,
		height = 24,
		textSize = 16,
		offset = Vector3.new(0, top + 0.9, 0),
	})
	o.dummyHurt = hurtboxPart(folder, "DummyHurtbox")
	o.dummyTag = tagOn(o.dummyHurt, {
		name = "Dummy",
		text = "DUMMY",
		fill = T.Backdrop,
		width = 170,
		height = 24,
		textSize = 15,
		offset = Vector3.new(0, top + 0.9, 0),
	})
	o.dummyDamage = tagOn(o.dummyHurt, {
		name = "Damage",
		text = "0%",
		font = T.LogoFont,
		color = T.DamageHot,
		width = 140,
		height = 54,
		textSize = 46,
		offset = Vector3.new(0, top + 2.6, 0),
	})
	o.myHit = overlayPart(folder, "YourHitbox", T.Hitbox, 0.7)
	o.myHitTag = tagOn(o.myHit, {
		name = "Active",
		fill = T.Red,
		width = 170,
		height = 24,
		textSize = 14,
		offset = Vector3.new(0, 0, 0),
	})
	o.dummyHit = overlayPart(folder, "DummyHitbox", T.Hitbox, 0.7)
	o.dummyHitTag = tagOn(o.dummyHit, {
		name = "Active",
		fill = T.Red,
		width = 170,
		height = 24,
		textSize = 14,
		offset = Vector3.new(0, 0, 0),
	})
	folder.Parent = if display.Hitboxes then workspace else nil
end

-- Puts an overlay part over the arena rect (x1, y1)-(x2, y2); nil hides it.
local function placeBox(m, part, x1, y1, x2, y2)
	if not x1 then
		part.Parent = nil
		return
	end
	part.Size = Vector3.new(math.max(0.05, x2 - x1), math.max(0.05, y2 - y1), 0.1)
	part.CFrame = CFrame.new(m.origin + Vector3.new((x1 + x2) / 2, (y1 + y2) / 2, OVERLAY_Z))
end

-- "HITBOX · ACTIVE a/b" for an attack on frame `frame` of `summary`.
local function activeText(summary, frame)
	if not summary then
		return "HITBOX"
	end
	local a = math.clamp(frame - summary.startup + 1, 1, summary.active)
	return string.format("HITBOX · ACTIVE %d/%d", a, summary.active)
end

local function updateOverlays(s, m)
	if not display.Hitboxes then
		return
	end
	local o = s.overlays
	local folder = s.folder
	local function show(part, on)
		part.Parent = if on then folder else nil
	end
	-- you: from your own sim (exact)
	local sim = m.sim
	local alive = m.me.alive
	show(o.myHurt, alive)
	if alive then
		placeBox(m, o.myHurt, FighterSim.hurtbox(sim.x, sim.y))
	end
	local x1, y1, x2, y2 = FighterSim.activeHitbox(sim)
	show(o.myHit, alive and x1 ~= nil)
	if alive and x1 then
		placeBox(m, o.myHit, x1, y1, x2, y2)
		local view = s.meter:view()
		o.myHitTag.Text = activeText(view.summary, view.current)
		o.myHitTag.Parent.StudsOffsetWorldSpace = Vector3.new(0, -(y2 - y1) / 2 - 0.7, 0)
	end
	-- the dummy: its model each frame, its hitbox from the latest snapshot
	local dummy = s.dummy
	local snap = s.snapshot
	local dummyAlive = dummy ~= nil and dummy.alive ~= false
	local dx, dy = nil, nil
	if dummyAlive and dummy.root and dummy.root.Parent then
		local p = dummy.root.Position - m.origin
		dx, dy = p.X, p.Y - (dummy.feetOffset or 3)
	elseif dummyAlive and snap then
		dx, dy = snap.x, snap.y
	end
	show(o.dummyHurt, dx ~= nil)
	if dx then
		placeBox(m, o.dummyHurt, FighterSim.hurtbox(dx, dy))
		local mode = if snap then snap.mode else s.settings.dummyMode
		o.dummyTag.Text = "DUMMY · " .. (FrameData.MODE_LABELS[mode] or string.upper(tostring(mode)))
		o.dummyDamage.Text = math.floor((dummy.damage or 0) + 0.5) .. "%"
	end
	local box = snap and snap.hitbox
	local fresh = snap ~= nil and os.clock() - s.snapshotAt < SNAPSHOT_STALE
	local showHit = dummyAlive and fresh and type(box) == "table" and #box == 4
	show(o.dummyHit, showHit)
	if showHit then
		placeBox(m, o.dummyHit, box[1], box[2], box[3], box[4])
		local move = snap.slot and Legends.getAttack(snap.legend, snap.weapon, snap.slot)
		o.dummyHitTag.Text = activeText(move and FrameData.summary(move), snap.actionFrame or 0)
		o.dummyHitTag.Parent.StudsOffsetWorldSpace = Vector3.new(0, -(box[4] - box[2]) / 2 - 0.7, 0)
	end
end

-- Hooks ----------------------------------------------------------------------------------------

-- In onStart after MatchHUD.show, when m.info.source == "Training".
function TrainingClient.start(m)
	TrainingClient.stop()
	local dummy = nil
	for _, f in m.order do
		if f ~= m.me and f.isBot then
			dummy = f
		end
	end
	local s = {
		m = m,
		dummy = dummy,
		meter = FrameData.newMeter(),
		combo = FrameData.newCombo(),
		snapshot = nil,
		snapshotAt = -math.huge,
		settings = {
			legend = m.legend,
			weapon = m.weapon,
			dummyLegend = if dummy then dummy.legend else Config.Training.DummyLegend,
			dummyMode = Config.Training.DefaultMode,
			difficulty = Config.Training.DefaultDifficulty,
			keepDamage = false,
			speed = m.timeScale or 1,
		},
		hotkeys = FrameData.hotkeys(Settings.getBinds),
		channels = {}, -- [queue name] = { inflight = action?, queue = { { action, payload } } }
		sending = {}, -- [action] = true while a RESET POSITIONS / SPAWN WEAPON / LEAVE is in flight
		sentAt = {},
		damageHold = nil,
		layer = nil,
		closedAt = -math.huge,
		connections = {},
		frameDirty = true,
		comboDirty = true,
		subtitle = nil,
		shownFrame = -1,
		shownDummy = nil,
	}
	session = s
	buildOverlays(s)
	local ok, hud = pcall(TrainingHUD.new, {
		settings = s.settings,
		display = display,
		spawnWeapon = spawnWeapon,
		hotkeys = s.hotkeys,
		request = request,
		onDisplay = setDisplay,
		onSpawn = spawnPressed,
		onTogglePanel = togglePanel,
		onReset = function()
			request("ResetPositions")
		end,
		onLeave = function()
			request("Leave")
		end,
	})
	if not ok then
		-- no half-built room: the hooks go quiet (MatchClient reports the error once)
		TrainingClient.stop()
		error(hud, 0)
	end
	s.hud = hud
	s.shown = hud.shown
	table.insert(s.connections, UserInputService.InputBegan:Connect(onInputBegan))
end

-- In cleanup (always; a no-op when not training).
function TrainingClient.stop()
	local s = session
	if not s then
		return
	end
	session = nil
	if s.layer then
		Focus.popLayer(s.layer)
		s.layer = nil
	end
	for _, connection in s.connections do
		connection:Disconnect()
	end
	if s.hud then
		s.hud:destroy()
	end
	if s.folder then
		-- a hidden overlay is out of the folder: destroy each one (Layout lets go of their tags on Destroying)
		for _, name in { "myHurt", "dummyHurt", "myHit", "dummyHit" } do
			local overlay = s.overlays and s.overlays[name]
			if overlay then
				overlay:Destroy()
			end
		end
		s.folder:Destroy()
	end
end

-- End of MatchClient's step(), training only; dt already scaled.
function TrainingClient.step(m, _dt)
	local s = session
	if not s or s.m ~= m or not s.hud then
		return
	end
	local hud = s.hud
	-- frame data: the meter follows your sim
	local view = s.meter:observe(m.sim)
	if s.frameDirty or view.current ~= s.shownFrame then
		s.frameDirty = false
		s.shownFrame = view.current
		if display.FrameData then
			hud:setFrameData(if view.summary then view else nil, s.subtitle)
		end
	end
	if s.comboDirty then
		s.comboDirty = false
		hud:setCombo(s.combo:get())
	end
	-- your legend and weapon change without a "Settings" too (a pickup, a throw, a KO): follow the match's
	local you = s.channels.You
	if not (you and (you.inflight or #you.queue > 0)) then
		local changed = nil
		for _, field in { "legend", "weapon" } do
			local value = m[field]
			if type(value) == "string" and value ~= s.settings[field] then
				s.settings[field] = value
				changed = changed or {}
				changed[field] = value
			end
		end
		if changed then
			hud:setSettings(changed)
		end
	end
	-- the dummy: damage from Hit / Respawn / Damage events (a value you just set shows until they confirm it)
	local damage = if s.dummy then s.dummy.damage or 0 else 0
	local hold = s.damageHold
	if hold then
		if damage ~= hold.value and os.clock() < hold.untilTime then
			damage = hold.value
		else
			s.damageHold = nil
		end
	end
	if damage ~= s.shownDamage or s.snapshot ~= s.shownDummy then
		s.shownDamage = damage
		s.shownDummy = s.snapshot
		hud:setDummy(s.snapshot, damage)
	end
	if not busy(s, "SetSpeed") then
		-- (while a speed change is going, the chip shows your pick)
		hud:setSpeedChip(m.timeScale)
	end
	updateOverlays(s, m)
end

-- handleSimEvent "Attack", training only.
function TrainingClient.onOwnAttack(m, ev, move)
	local s = session
	if not s or s.m ~= m or not move then
		return
	end
	s.meter:start(move, ev.seq)
	s.subtitle = FrameData.subtitle(m.weapon, move)
	s.frameDirty = true
end

-- handleSimEvent "AttackEnd", training only.
function TrainingClient.onOwnAttackEnd(m, ev)
	local s = session
	if not s or s.m ~= m then
		return
	end
	s.meter:finish(ev.seq, m.sim)
	s.frameDirty = true
end

-- End of the Hit handler, training only.
function TrainingClient.onHit(m, d)
	local s = session
	if not s or s.m ~= m or type(d) ~= "table" then
		return
	end
	if d.attackerId ~= nil and d.attackerId == m.me.id then
		s.combo:onHit(d)
		s.comboDirty = true
	end
end

-- MatchEvent "Training".
function TrainingClient.onServer(m, d)
	local s = session
	if not s or s.m ~= m or not s.hud or type(d) ~= "table" then
		return
	end
	if d.kind == "Dummy" then
		s.snapshot = d
		s.snapshotAt = os.clock()
	elseif d.kind == "Settings" then
		for key, kind in SETTING_TYPES do
			if type(d[key]) == kind then
				s.settings[key] = d[key]
			end
		end
		showConfirmed(s)
	end
end

return TrainingClient
