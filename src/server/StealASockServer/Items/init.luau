-- Items: the item bar. Everyone has the Towel Snap (Towel.luau) in slot 1; the eight items in
-- ItemConfig are unlocked for good with cash (BuyItem) or Robux (Monetize -> Items.Unlock), and up
-- to ItemConfig.LoadoutSize of them ride in the bar next to the towel (SetLoadout). Every use goes
-- through UseItem: the server checks the item, the bar, the cooldown (server clock) and the
-- player's state, runs the item's rule (Items.Rules) and tells every client what to show through
-- the ItemFX remote (StealASockClient.ItemFX). The client only asks.
--
-- Children: Looks (every item's model, from ReplicatedStorage.ItemMeshes or a Part build),
-- Rules (what each item does, and the world objects it leaves: peels, ducks, clouds, bubbles ...).
-- Saved: profile.Data.items (key -> true), profile.Data.loadout ({ LoadoutSize keys }, "" = empty)
-- and profile.Data.itemLevels (key -> upgrade level 1..ItemConfig.MaxLevel; absent = 0).
-- Every item number is read at the owner's level: Items.Stat(player, key, name) =
-- ItemConfig.Stat(key, Items.Level(player, key), name) (cooldowns too). The last level is golden.
-- What clients read (replicated attributes):
--   player:    CD_<key> (server time that item is ready again), Active_<key> (a glide / basket /
--              duck / peel is out), Lv_<key> (upgrade level of every unlocked item)
--   character: Item (held key), Gliding, InBasket, HairUpUntil, SoftenedUntil, StunUntil, Encased,
--              ChargeStart (rubbing the Static Balloon since), Napping (asleep in a cloud until)
--   tools and world objects: Level, Gold (true at the golden level)
-- API for other modules:
--   Items.Setup(player) / Items.OnPlayerRemoving(player)
--   Items.IsUnlocked(player, key) -> boolean     Items.Unlock(player, key) -> newly unlocked?
--   Items.Level(player, key) -> 0..MaxLevel      Items.Stat(player, key, name) -> number
--   Items.View(player) -> { items, loadout, towelLook, itemLevels }   (Income.Push: the StateView)
--   Items.SpeedMult(player) -> number            (Steal.ApplySpeed multiplies WalkSpeed by it)
--   Items.RefreshTowel(player)                   (Towel.Refresh: new Towel Snap level / Royal Towel)
--   Items.OnCarryChanged(player)                 (Steal: a sock picked up / claimed / sent home)
--   Items.Knock / Stun / Shove / Slide / CanShove / SendSockHome / PopOut / FX / Moment
--                                                (used by Towel and the rules)
--   Items.TowelHeld(player) -> boolean           (Towel: is this snap part of a held loop? for the swing FX)
--   Items.TowelCombo(player) -> (combo, finisher) (Towel: this snap's place in a held combo)
-- Remotes: UseItem(key, aim?, held?), BuyItem(key), SetLoadout(keys), UpgradeItem(key) -> Types.Result
--   held, per item (docs/ITEMS.md): Towel true = part of a held loop (the combo; a tap resets it);
--   StaticBalloon true = start rubbing it, false = zap now; Glider true = a press (glide, or SLAM
--   while gliding), false = "I landed"; LaundryBasket: a press while hidden pops out with a pounce;
--   anything else: a press uses it once (a release does nothing).
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local Items = {}
local S
local Cfg -- ItemConfig
local Looks
local Rules

local USE_GAP = 0.12 -- seconds between UseItem calls per player and item (cooldowns do the rest; releases count apart)
local MENU_GAP = 0.25 -- seconds between BuyItem / SetLoadout / UpgradeItem calls per player
local TICK = 0.1 -- seconds between rule checks (peels, clouds, ducks, timers)
local BAD = { ok = false, err = "Bad request" }

export type PlayerState = {
	cooldowns: { [string]: number }, -- key -> server time it's ready again
	stunUntil: number,
	graceUntil: number, -- can't be pushed again before this (ItemConfig.ShoveGrace)
	softUntil: number, -- inside someone's Softener Cloud until this
	softMult: number, -- that cloud's slowMult / thiefSlowMult (the slowest cloud you're in)
	softThiefMult: number,
	honkUntil: number, -- slowed by a guard duck's honk until this
	honkMult: number, -- (its honkSlow)
	napUntil: number, -- napping in a Softener Cloud until this (character attribute Napping)
	appliedMult: number, -- the SpeedMult that Steal.ApplySpeed last used
	conns: { RBXScriptConnection },
	charConns: { RBXScriptConnection },
	basket: any?, -- Rules: hiding under the Laundry Basket
	glide: any?, -- Rules: gliding on the dryer sheet (slamming down after a second press)
	glideEnded: number, -- server time the last glide ended
	encase: any?, -- Rules: floating in a bubble
	charge: any?, -- Rules: rubbing the Static Balloon (ChargeStart)
	dash: any?, -- Rules: a Slipper Dash in progress (bumps whoever it runs into)
	dashChain: any?, -- Rules: air dashes still allowed after a dash
	towelHeld: boolean, -- the last Towel use came with the button held down
	combo: number, -- held Towel uses in a row (ItemConfig.TowelCombo), 0 after a tap
	comboAt: number, -- server time of the last one
	comboShown: number, -- this snap's place in the combo, 1..TowelCombo.count (the swing FX)
	finisher: boolean, -- this snap is a combo finisher
}

local states: { [Player]: PlayerState } = {}

local function now(): number
	return workspace:GetServerTimeNow()
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function alive(player: Player): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0 and rootOf(player) ~= nil
end

local function finite(n: number): boolean
	return n == n and n > -1e6 and n < 1e6 -- NaN fails the first check, inf the others
end

-- ---------- profile ----------

local function itemsOf(profile): { [string]: boolean }
	local items = profile.Data.items
	if type(items) ~= "table" then
		items = {}
		profile.Data.items = items
	end
	return items
end

-- The saved loadout, cleaned: exactly LoadoutSize strings, only unlocked items, no repeats.
local function loadoutOf(profile): { string }
	local size = Cfg.LoadoutSize
	local loadout = profile.Data.loadout
	if type(loadout) ~= "table" then
		loadout = {}
		profile.Data.loadout = loadout
	end
	local items = itemsOf(profile)
	local seen = {}
	for i = 1, size do
		local key = loadout[i]
		if type(key) ~= "string" or (key ~= "" and (Cfg.Items[key] == nil or key == "Towel" or items[key] ~= true or seen[key])) then
			loadout[i] = ""
		elseif key ~= "" then
			seen[key] = true
		end
	end
	for i = #loadout, size + 1, -1 do
		table.remove(loadout, i)
	end
	return loadout
end

local function levelsOf(profile): { [string]: number }
	local levels = profile.Data.itemLevels
	if type(levels) ~= "table" then
		levels = {}
		profile.Data.itemLevels = levels
	end
	return levels
end

function Items.IsUnlocked(player: Player, key: string): boolean
	if key == "Towel" then
		return true
	end
	local profile = S.Data.Get(player)
	return profile ~= nil and Cfg.Items[key] ~= nil and itemsOf(profile)[key] == true
end

-- The highest upgrade level an item has (ItemConfig.Levels, at most MaxLevel); 0 for the towel.
local function maxLevel(key: string): number
	local levels = Cfg.Levels[key]
	return if levels then math.min(Cfg.MaxLevel, #levels) else 0
end

-- An item's upgrade level (0 = not upgraded, also for locked items and the towel).
function Items.Level(player: Player, key: string): number
	local top = maxLevel(key)
	local profile = S.Data.Get(player)
	if top == 0 or not profile or itemsOf(profile)[key] ~= true then
		return 0
	end
	local level = levelsOf(profile)[key]
	if type(level) ~= "number" or level ~= level then
		return 0
	end
	return math.clamp(math.floor(level), 0, top)
end

-- One of an item's numbers at the player's level (ItemConfig.Stat; "cooldown" too).
function Items.Stat(player: Player, key: string, name: string): number
	return Cfg.Stat(key, Items.Level(player, key), name)
end

-- Player attributes Lv_<key> for every unlocked item (the client reads its numbers with them).
local function publishLevels(player: Player)
	local profile = S.Data.Get(player)
	if not profile then
		return
	end
	for key, on in pairs(itemsOf(profile)) do
		if on == true and maxLevel(key) > 0 then
			player:SetAttribute("Lv_" .. key, Items.Level(player, key))
		end
	end
end

-- The keys in the player's bar right now: the towel, then the loadout.
local function barKeys(player: Player): { string }
	local keys = { "Towel" }
	local profile = S.Data.Get(player)
	if profile then
		for _, key in ipairs(loadoutOf(profile)) do
			if key ~= "" then
				table.insert(keys, key)
			end
		end
	end
	return keys
end

function Items.InBar(player: Player, key: string): boolean
	return table.find(barKeys(player), key) ~= nil
end

-- What the StateView carries (Shared.Types: items, loadout, towelLook, itemLevels).
function Items.View(player: Player)
	local items = { Towel = true }
	local loadout = {}
	local itemLevels = {}
	local profile = S.Data.Get(player)
	if profile then
		for key, on in pairs(itemsOf(profile)) do
			if on == true and Cfg.Items[key] then
				items[key] = true
				if maxLevel(key) > 0 then
					itemLevels[key] = Items.Level(player, key)
				end
			end
		end
		for i, key in ipairs(loadoutOf(profile)) do
			loadout[i] = key
		end
	else
		for i = 1, Cfg.LoadoutSize do
			loadout[i] = ""
		end
	end
	return { items = items, loadout = loadout, towelLook = S.Towel.Look(player), itemLevels = itemLevels }
end

-- ---------- tools ----------

-- Gives the player one Tool per bar item (Backpack), removes tools that left the bar,
-- re-skins the towel when its look changed and an item when it turned golden (attributes Level, Gold).
function Items.SyncTools(player: Player)
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return
	end
	local keys = barKeys(player)
	local want = {}
	for _, key in ipairs(keys) do
		want[key] = true
	end
	local have = {}
	for _, container in ipairs({ backpack, player.Character }) do
		for _, child in ipairs(container:GetChildren()) do
			local key = child:GetAttribute("ItemKey")
			if child:IsA("Tool") and type(key) == "string" then
				if want[key] and not have[key] then
					have[key] = child
				else
					child:Destroy() -- left the bar (or a second copy)
				end
			end
		end
	end
	local look = S.Towel.Look(player)
	for _, key in ipairs(keys) do
		local tool = have[key]
		local level = Items.Level(player, key)
		if not tool then
			local built = Looks.BuildTool(key, if key == "Towel" then look else nil, level)
			built.Parent = backpack
		elseif key == "Towel" then
			if tool:GetAttribute("Look") ~= look then
				Looks.Dress(tool, key, look)
			end
		elseif (tool:GetAttribute("Gold") == true) ~= Cfg.IsGold(level) then
			Looks.Dress(tool, key, nil, level) -- turned golden: <model>_Gold
		else
			tool:SetAttribute("Level", level)
		end
	end
end

function Items.RefreshTowel(player: Player)
	if states[player] then
		Items.SyncTools(player)
	end
end

-- An item's level changed: Lv_<key>, its tool (golden at the last level) and every world object of
-- it that's out (Rules.Restyle: the golden look, and the new level's numbers).
function Items.RefreshItem(player: Player, key: string)
	local st = states[player]
	if not st then
		return
	end
	local level = Items.Level(player, key)
	player:SetAttribute("Lv_" .. key, level)
	Items.SyncTools(player)
	Rules.Restyle(player, st, key, level)
end

-- The held tool's key on the character (the clients pose and animate from it).
local function updateHeld(character: Model)
	local held = nil
	for _, child in ipairs(character:GetChildren()) do
		local key = child:GetAttribute("ItemKey")
		if child:IsA("Tool") and type(key) == "string" then
			held = key
		end
	end
	character:SetAttribute("Item", held)
end

-- ---------- state shared by the rules ----------

function Items.State(player: Player): PlayerState?
	return states[player]
end

function Items.All(): { [Player]: PlayerState }
	return states
end

function Items.FX(kind: string, data: { [string]: any }, only: Player?)
	local remote = S.Remotes:FindFirstChild("ItemFX")
	if not remote then
		return
	end
	if only then
		if only.Parent == Players then
			remote:FireClient(only, kind, data)
		end
	else
		remote:FireAllClients(kind, data)
	end
end

function Items.SetCooldown(player: Player, key: string, untilTime: number)
	local st = states[player]
	if st then
		st.cooldowns[key] = untilTime
	end
	player:SetAttribute("CD_" .. key, untilTime)
end

function Items.SetActive(player: Player, key: string, on: boolean)
	player:SetAttribute("Active_" .. key, if on then true else nil)
end

-- A big moment ("big and dramatic"): every client shows the burst; `by` and each target also get
-- the hit-stop, slow-motion feel and shake (ItemFX). strength 0..1.
function Items.Moment(kind: string, position: Vector3, by: Player?, targets: { Player }, strength: number)
	Items.FX("moment", { kind = kind, position = position, by = by, targets = targets, strength = math.clamp(strength, 0, 1) })
end

-- Was this Towel snap asked for with the button held down? (the swing FX tells every client to loop it)
function Items.TowelHeld(player: Player): boolean
	local st = states[player]
	return st ~= nil and st.towelHeld
end

-- This Towel snap's place in a held combo (1..TowelCombo.count) and whether it's the finisher.
function Items.TowelCombo(player: Player): (number, boolean)
	local st = states[player]
	if not st then
		return 1, false
	end
	return st.comboShown, st.finisher
end

-- Held towel uses within TowelCombo.window s of the last one count up; every count-th is a
-- finisher; a tap resets the count.
local function countCombo(st: PlayerState, isHeld: boolean, t: number)
	local combo = Cfg.TowelCombo
	if isHeld and st.combo > 0 and t - st.comboAt <= combo.window then
		st.combo += 1
	elseif isHeld then
		st.combo = 1
	else
		st.combo = 0
	end
	st.comboAt = t
	st.comboShown = if st.combo > 0 then (st.combo - 1) % combo.count + 1 else 1
	st.finisher = st.combo > 0 and st.combo % combo.count == 0
end

-- WalkSpeed multiplier from items: stunned / floating in a bubble = 0, a Softener Cloud slows
-- (thieves more), a guard duck's honk slows, the Laundry Basket shuffles.
function Items.SpeedMult(player: Player): number
	local st = states[player]
	if not st then
		return 1
	end
	local t = now()
	if st.stunUntil > t or st.encase then
		return 0
	end
	local mult = 1
	if st.softUntil > t then
		mult *= if S.Steal.IsCarrying(player) then st.softThiefMult else st.softMult
	end
	if st.honkUntil > t then
		mult *= st.honkMult
	end
	if st.basket then
		mult *= Items.Stat(player, "LaundryBasket", "speedMult")
	end
	return mult
end

function Items.RefreshSpeed(player: Player)
	local st = states[player]
	if st then
		st.appliedMult = Items.SpeedMult(player)
	end
	S.Steal.ApplySpeed(player)
end

-- May `target` be pushed now? (alive, and not pushed within ShoveGrace)
function Items.CanShove(target: Player): boolean
	local st = states[target]
	return st ~= nil and st.graceUntil <= now() and not st.encase and alive(target)
end

-- A short push: `dir` horizontal (unit), `speed` studs/s, `up` studs/s. Starts the target's
-- ShoveGrace and ends a glide. The target's own client simulates it (it owns its character).
function Items.Knock(target: Player, dir: Vector3, speed: number, up: number)
	local root = rootOf(target)
	local st = states[target]
	if not root or not st or st.encase then
		return
	end
	st.graceUntil = math.max(st.graceUntil, now() + Cfg.ShoveGrace)
	Rules.Stop(target, st, "Glider", "knocked")
	local attachment = Instance.new("Attachment")
	attachment.Name = "ItemKnock"
	attachment.Parent = root
	local push = Instance.new("LinearVelocity")
	push.Name = "ItemKnock"
	push.Attachment0 = attachment
	push.MaxForce = math.huge
	push.RelativeTo = Enum.ActuatorRelativeTo.World
	push.VectorVelocity = dir * speed + Vector3.new(0, up, 0)
	push.Parent = root
	Debris:AddItem(push, 0.2)
	Debris:AddItem(attachment, 0.3)
end

-- The push of a towel shove from `owner` (their Towel Snap knockback x ShoveMult): speed, up.
function Items.ShoveSpeed(owner: Player?): (number, number)
	local Eco = S.Config.Economy
	local mult = if owner then S.Upgrades.TowelKnockbackMult(owner) else 1
	return Eco.TowelKnockback * mult * Cfg.ShoveMult, Eco.TowelKnockUp * Cfg.ShoveMult
end

-- `mult` x a towel shove from `owner` along `dir`, unless the target is inside ShoveGrace; the
-- target tumbles softly on every client. Returns true when they were pushed.
function Items.Shove(owner: Player?, target: Player, dir: Vector3, mult: number, seconds: number?): boolean
	if mult <= 0 or not Items.CanShove(target) then
		return false
	end
	local speed, up = Items.ShoveSpeed(owner)
	Items.Knock(target, dir, speed * mult, up * mult)
	Items.FX("tumble", { player = target, dir = dir, seconds = seconds or 0.45, soft = true })
	return true
end

-- A slide along the floor (peel bowling): `dir` horizontal, `speed` studs/s for `seconds`; gravity
-- still works. The target's own client simulates it (it owns its character). A new slide replaces one.
function Items.Slide(target: Player, dir: Vector3, speed: number, seconds: number)
	local root = rootOf(target)
	if not root then
		return
	end
	for _, child in ipairs(root:GetChildren()) do
		if child.Name == "ItemSlide" then
			child:Destroy()
		end
	end
	local attachment = Instance.new("Attachment")
	attachment.Name = "ItemSlide"
	attachment.Parent = root
	local slide = Instance.new("LinearVelocity")
	slide.Name = "ItemSlide"
	slide.Attachment0 = attachment
	slide.MaxForce = math.huge
	slide.RelativeTo = Enum.ActuatorRelativeTo.World
	slide.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	slide.PrimaryTangentAxis = Vector3.new(1, 0, 0)
	slide.SecondaryTangentAxis = Vector3.new(0, 0, 1)
	slide.PlaneVelocity = Vector2.new(dir.X * speed, dir.Z * speed)
	slide.Parent = root
	Debris:AddItem(slide, seconds)
	Debris:AddItem(attachment, seconds + 0.1)
end

-- Can't walk for `seconds` (a new stun never shortens one that's running), and can't be pushed
-- or stunned again until ShoveGrace after it ends, so nothing can stun-lock anyone.
function Items.Stun(target: Player, seconds: number)
	local st = states[target]
	if not st then
		return
	end
	st.stunUntil = math.max(st.stunUntil, now() + seconds)
	st.graceUntil = math.max(st.graceUntil, st.stunUntil + Cfg.ShoveGrace)
	local character = target.Character
	if character then
		character:SetAttribute("StunUntil", st.stunUntil)
	end
	Items.RefreshSpeed(target)
end

-- Sends a thief's sock home (Steal.Return) and flies it there on an arc on every client.
-- Returns true when they were carrying one.
function Items.SendSockHome(thief: Player, reason: string): boolean
	local carry = S.Steal.Carriers()[thief]
	if not carry then
		return false
	end
	local sock = carry.sock
	local leg = sock.model and sock.model.PrimaryPart
	local root = rootOf(thief)
	local from = if leg then leg.Position elseif root then root.Position + Vector3.new(0, 5, 0) else nil
	S.Steal.Return(thief, reason)
	if from and sock.state == "drawer" and sock.slot then
		local record = S.Base.ByOwnerId(sock.ownerId)
		if record then
			Items.FX("sockhome", {
				from = from,
				to = S.Base.SlotCFrame(record, sock.slot, sock.model).Position,
				color = S.Registry.Tier(sock).color,
				uid = sock.uid,
			})
		end
	end
	return true
end

-- Out of the Laundry Basket (snapped, zapped, slipped, another item, a sock picked up ...).
function Items.PopOut(player: Player, why: string)
	local st = states[player]
	if st and st.basket then
		Rules.Stop(player, st, "LaundryBasket", why)
	end
end

function Items.OnCarryChanged(player: Player)
	Items.PopOut(player, "carry")
end

-- ---------- unlocking ----------

-- Unlocks an item for good (BuyItem, or a Robux unlock through Monetize.GrantProduct). It fills the
-- first empty bar slot. Returns false when it was already unlocked (a second Robux grant: fine).
-- Errors only for an unknown key or a missing profile (ProcessReceipt then tries again later).
function Items.Unlock(player: Player, key: string): boolean
	local item = Cfg.Items[key]
	if not item or key == "Towel" then
		error("not an unlockable item: " .. tostring(key))
	end
	local profile = S.Data.Get(player)
	if not profile then
		error("profile not loaded")
	end
	local items = itemsOf(profile)
	if items[key] == true then
		return false
	end
	items[key] = true
	local loadout = loadoutOf(profile)
	if not table.find(loadout, key) then
		local free = table.find(loadout, "")
		if free then
			loadout[free] = key
		end
	end
	-- the unlock has happened: nothing below may undo it by erroring
	local ok, err = pcall(function()
		publishLevels(player)
		Items.SyncTools(player)
		S.Celebrate(player, "item", { key = key, display = item.display })
		S.Income.Push(player)
	end)
	if not ok then
		warn("[Items] after-unlock step failed: " .. tostring(err))
	end
	return true
end

-- ---------- remotes ----------

local function validAim(aim: any): boolean
	if typeof(aim) ~= "Vector3" then
		return false
	end
	local v = aim :: Vector3
	return finite(v.X) and finite(v.Y) and finite(v.Z) and Vector3.new(v.X, 0, v.Z).Magnitude > 1e-3
end

-- The cooldown end to tell the client: the running one, or 0 when it's ready.
local function cooldownOf(st: PlayerState, key: string, t: number): number
	local untilTime = st.cooldowns[key] or 0
	return if untilTime > t then untilTime else 0
end

local function useItem(player: Player, key: any, aim: any, held: any)
	if not S.Ready then
		return { ok = false, err = "Starting up…" }
	end
	if type(key) ~= "string" or Cfg.Items[key] == nil then
		return BAD
	end
	if aim ~= nil and not validAim(aim) then
		return BAD
	end
	if held ~= nil and type(held) ~= "boolean" then
		return BAD
	end
	-- a release (held = false) counts apart: a quick tap is a press and a release within USE_GAP
	local release = held == false and key ~= "Towel"
	if not S.RateLimit.Check(player, "useItem:" .. key .. (if release then ":up" else ""), USE_GAP) then
		return { ok = false, err = "Slow down a little!" }
	end
	local st = states[player]
	if not st or not S.Data.Get(player) then
		return { ok = false, err = "Your drawer isn't ready yet" }
	end
	local t = now()
	if release then
		-- the balloon zaps, the glider has landed; the other items have nothing to do on a release
		local ok, err, msg = Rules.Release(player, st, key)
		return { ok = ok, err = err, msg = msg, cooldownUntil = cooldownOf(st, key, t) }
	end
	if not Items.IsUnlocked(player, key) then
		return { ok = false, err = "Unlock it in the Item Shop first" }
	end
	if not Items.InBar(player, key) then
		return { ok = false, err = "Put it in your item bar first" }
	end
	local root = rootOf(player)
	if not root or not alive(player) then
		return { ok = false, err = "You can't do that right now" }
	end
	-- a second press while gliding SLAMS down (an old-style use without `held` ends the glide); a
	-- press while hidden pops you out with a pounce - whatever the cooldown says
	if Rules.IsActive(player, st, key) then
		Rules.Toggle(player, st, key, held == true)
		return { ok = true, cooldownUntil = cooldownOf(st, key, t) }
	end
	if key == "Glider" and held == nil and t - st.glideEnded < 1.5 then
		-- an old-style "landed" use, just after we ended the glide ourselves: already done
		return { ok = true, cooldownUntil = cooldownOf(st, key, t) }
	end
	if key == "StaticBalloon" and held == true and st.charge then
		return { ok = true, cooldownUntil = 0 } -- already rubbing it
	end
	local ready = st.cooldowns[key] or 0
	local free = false -- an air dash: the cooldown that's running stays as it is
	if t < ready then
		if key == "SlipperDash" and Rules.CanAirDash(player, st, t) then
			free = true
		else
			return { ok = false, err = "Not ready yet", cooldownUntil = ready }
		end
	end
	if st.stunUntil > t or st.encase then
		return { ok = false, err = "You're too dizzy!", cooldownUntil = cooldownOf(st, key, t) }
	end
	if key ~= "LaundryBasket" then
		Items.PopOut(player, "item")
	end
	local dir: Vector3
	if aim ~= nil then
		dir = Vector3.new(aim.X, 0, aim.Z).Unit
	else
		local look = root.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		dir = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
	end
	if key == "Towel" then
		st.towelHeld = held == true
		countCombo(st, held == true, t)
	end
	local ok, err, msg = Rules.Use(player, st, key, dir, held, free)
	if not ok then
		return { ok = false, err = err or "You can't do that right now", cooldownUntil = cooldownOf(st, key, t) }
	end
	if not free and not Rules.CooldownAtEnd(key) then
		Items.SetCooldown(player, key, t + Items.Stat(player, key, "cooldown"))
	end
	return { ok = true, cooldownUntil = cooldownOf(st, key, t), msg = msg }
end

local function buyItem(player: Player, key: any)
	if not S.Ready then
		return { ok = false, err = "Starting up…" }
	end
	if type(key) ~= "string" or key == "Towel" or Cfg.Items[key] == nil then
		return BAD
	end
	if not S.RateLimit.Check(player, "buyItem", MENU_GAP) then
		return { ok = false, err = "Slow down a little!" }
	end
	if not S.Data.Get(player) then
		return { ok = false, err = "Your drawer isn't ready yet" }
	end
	local item = Cfg.Items[key]
	if Items.IsUnlocked(player, key) then
		return { ok = false, err = "Already unlocked" }
	end
	if not S.Data.TrySpend(player, item.price) then
		return { ok = false, err = "Not enough cash" }
	end
	Items.Unlock(player, key)
	return { ok = true, msg = item.display .. " unlocked!" }
end

-- UpgradeItem(key): the item's next level (ItemConfig.Levels) for cash; the last one turns it golden.
local function upgradeItem(player: Player, key: any)
	if not S.Ready then
		return { ok = false, err = "Starting up…" }
	end
	if type(key) ~= "string" or Cfg.Items[key] == nil or maxLevel(key) == 0 then
		return BAD
	end
	if not S.RateLimit.Check(player, "upgradeItem", MENU_GAP) then
		return { ok = false, err = "Slow down a little!" }
	end
	local profile = S.Data.Get(player)
	if not profile or not states[player] then
		return { ok = false, err = "Your drawer isn't ready yet" }
	end
	if not Items.IsUnlocked(player, key) then
		return { ok = false, err = "Unlock it in the Item Shop first" }
	end
	local level = Items.Level(player, key)
	if level >= maxLevel(key) then
		return { ok = false, err = "Already golden!" }
	end
	local nextLevel = level + 1
	if not S.Data.TrySpend(player, Cfg.Levels[key][nextLevel].price) then
		return { ok = false, err = "Not enough cash" }
	end
	levelsOf(profile)[key] = nextLevel
	local item = Cfg.Items[key]
	local gold = Cfg.IsGold(nextLevel)
	-- the upgrade has happened: nothing below may undo it by erroring
	local ok, err = pcall(function()
		Items.RefreshItem(player, key)
		Items.FX("upgrade", { player = player, key = key, level = nextLevel, gold = gold })
		S.Celebrate(player, "itemUpgrade", { key = key, display = item.display, level = nextLevel, gold = gold })
		S.Income.Push(player)
	end)
	if not ok then
		warn("[Items] after-upgrade step failed: " .. tostring(err))
	end
	local msg = if gold then item.display .. " is GOLDEN! ✨" else item.display .. " is now level " .. nextLevel .. "!"
	return { ok = true, level = nextLevel, msg = msg }
end

local function setLoadout(player: Player, keys: any)
	if not S.Ready then
		return { ok = false, err = "Starting up…" }
	end
	if type(keys) ~= "table" then
		return BAD
	end
	if not S.RateLimit.Check(player, "setLoadout", MENU_GAP) then
		return { ok = false, err = "Slow down a little!" }
	end
	local profile = S.Data.Get(player)
	local st = states[player]
	if not profile or not st then
		return { ok = false, err = "Your drawer isn't ready yet" }
	end
	local size = Cfg.LoadoutSize
	local count = 0
	for k, v in pairs(keys) do
		count += 1
		if count > size or type(k) ~= "number" or k ~= math.floor(k) or k < 1 or k > size or type(v) ~= "string" then
			return BAD
		end
	end
	local clean = {}
	local seen = {}
	for i = 1, size do
		local key = keys[i] or ""
		if key ~= "" then
			if key == "Towel" or Cfg.Items[key] == nil then
				return BAD
			end
			if not Items.IsUnlocked(player, key) then
				return { ok = false, err = "Unlock it in the Item Shop first" }
			end
			if seen[key] then
				return { ok = false, err = "That item is already in your bar" }
			end
			seen[key] = true
		end
		clean[i] = key
	end
	-- items that leave the bar stop what they're doing (a glide ends, the basket pops)
	for _, old in ipairs(loadoutOf(profile)) do
		if old ~= "" and not seen[old] then
			Rules.Stop(player, st, old, "loadout")
		end
	end
	profile.Data.loadout = clean
	Items.SyncTools(player)
	S.Income.Push(player)
	return { ok = true }
end

local QUIET = { ["Bad request"] = true, ["Slow down a little!"] = true, ["Starting up…"] = true }

local function guarded(name: string, fn: (...any) -> any, toast: boolean)
	return function(player: Player, ...)
		local ok, result = pcall(fn, player, ...)
		if not ok then
			warn("[Items] " .. name .. " failed: " .. tostring(result))
			return { ok = false, err = "Something went wrong - try again" }
		end
		-- the item bar only shakes: say why in a toast (at most one a second)
		if toast and type(result) == "table" and result.ok == false and type(result.err) == "string" and not QUIET[result.err]
			and S.RateLimit.Check(player, "itemToast", 1) then
			S.Toast(player, result.err, "bad")
		end
		return result
	end
end

-- ---------- lifecycle ----------

local function disconnectAll(list: { RBXScriptConnection })
	for _, c in ipairs(list) do
		c:Disconnect()
	end
	table.clear(list)
end

local function onCharacter(player: Player, st: PlayerState, character: Model)
	Rules.Cleanup(player, st, "respawn") -- whatever the old character had going
	disconnectAll(st.charConns)
	st.stunUntil = 0
	st.softUntil = 0
	st.honkUntil = 0
	st.napUntil = 0
	st.appliedMult = 1
	local humanoid = character:WaitForChild("Humanoid", 5)
	if states[player] ~= st or player.Character ~= character then
		return
	end
	if humanoid and humanoid:IsA("Humanoid") then
		table.insert(st.charConns, humanoid.Died:Connect(function()
			Rules.Cleanup(player, st, "died")
		end))
	end
	table.insert(st.charConns, character.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then
			updateHeld(character)
		end
	end))
	table.insert(st.charConns, character.ChildRemoved:Connect(function(child)
		if child:IsA("Tool") then
			updateHeld(character)
		end
	end))
	player:WaitForChild("Backpack", 5)
	if states[player] == st and player.Character == character then
		Items.SyncTools(player)
		updateHeld(character)
	end
end

function Items.Setup(player: Player)
	if states[player] then
		return
	end
	local st: PlayerState = {
		cooldowns = {},
		stunUntil = 0,
		graceUntil = 0,
		softUntil = 0,
		softMult = 1,
		softThiefMult = 1,
		honkUntil = 0,
		honkMult = 1,
		napUntil = 0,
		appliedMult = 1,
		conns = {},
		charConns = {},
		basket = nil,
		glide = nil,
		glideEnded = 0,
		encase = nil,
		charge = nil,
		dash = nil,
		dashChain = nil,
		towelHeld = false,
		combo = 0,
		comboAt = 0,
		comboShown = 1,
		finisher = false,
	}
	states[player] = st
	publishLevels(player)
	table.insert(st.conns, player.CharacterAdded:Connect(function(character)
		onCharacter(player, st, character)
	end))
	if player.Character then
		task.spawn(onCharacter, player, st, player.Character)
	end
end

function Items.OnPlayerRemoving(player: Player)
	local st = states[player]
	if not st then
		return
	end
	local ok, err = pcall(Rules.Cleanup, player, st, "left")
	if not ok then
		warn("[Items] cleanup failed: " .. tostring(err))
	end
	disconnectAll(st.conns)
	disconnectAll(st.charConns)
	states[player] = nil
end

-- Server shutting down: everyone out of baskets and bubbles, charges dropped, world objects gone.
function Items.Shutdown()
	for player, st in pairs(states) do
		pcall(Rules.Cleanup, player, st, "shutdown")
	end
end

local warned = {}
local function safely(name: string, fn: (...any) -> (), ...: any)
	local ok, err = pcall(fn, ...)
	if not ok and not warned[name] then
		warned[name] = true
		warn("[Items] " .. name .. " failed: " .. tostring(err))
	end
end

local function tick()
	local t = now()
	safely("rules", Rules.Tick, t)
	for player, st in pairs(states) do
		local character = player.Character
		if character and st.stunUntil > 0 and st.stunUntil <= t then
			st.stunUntil = 0
			character:SetAttribute("StunUntil", nil)
		end
		if character and st.napUntil > 0 and st.napUntil <= t then
			st.napUntil = 0
			character:SetAttribute("Napping", nil)
		end
		if Items.SpeedMult(player) ~= st.appliedMult then
			safely("speed", Items.RefreshSpeed, player)
		end
	end
end

function Items.Init(s)
	S = s
	Cfg = S.Config.Item
	Looks = require(script:WaitForChild("Looks"))
	Rules = require(script:WaitForChild("Rules"))
	Items.Looks = Looks
	Looks.Init(S)
	Rules.Init(S, Items)
	S.Remotes.UseItem.OnServerInvoke = guarded("UseItem", useItem, true)
	S.Remotes.BuyItem.OnServerInvoke = guarded("BuyItem", buyItem, false) -- the Item Shop shows its own errors
	S.Remotes.SetLoadout.OnServerInvoke = guarded("SetLoadout", setLoadout, false)
	S.Remotes.UpgradeItem.OnServerInvoke = guarded("UpgradeItem", upgradeItem, false) -- the Items tab shows its own errors
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		safely("bubbles", Rules.Step, dt)
		acc += dt
		if acc >= TICK then
			acc = 0
			tick()
		end
	end)
	game:BindToClose(Items.Shutdown)
end

return Items
