-- Base: the 8 drawers. Assigns one per player, places socks in slots, runs the Collect pad,
-- the Slam Drawer lock (with a physical shutter the owner can walk through) and keeps the
-- player's profile in sync with what is in the drawer. The back row of slots stays padlocked
-- until the +4 Drawer Slots pass opens it; saved socks that don't fit yet wait in
-- record.overflow and stay in the save.
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local PhysicsService = game:GetService("PhysicsService")

local Base = {}
local S

local bases = {} -- index -> record
local byPlayer = {} -- Player -> record
local byOwnerId = {} -- UserId -> record

local SHUTTER_TWEEN = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local function ownerGroup(index: number): string
	return "Owner" .. index
end
local function shutterGroup(index: number): string
	return "Shutter" .. index
end

function Base.Init(s)
	S = s
	local L = S.Map.Layout
	for _, model in ipairs(S.Map.Bases) do
		local index = model:GetAttribute("Index")
		PhysicsService:RegisterCollisionGroup(ownerGroup(index))
		PhysicsService:RegisterCollisionGroup(shutterGroup(index))
		PhysicsService:CollisionGroupSetCollidable(ownerGroup(index), shutterGroup(index), false)
		local shutter = model:FindFirstChild("Shutter")
		shutter.CollisionGroup = shutterGroup(index)
		local closedY = shutter:GetAttribute("ClosedY")
		local closedCF = CFrame.new(shutter.Position.X, closedY, shutter.Position.Z) * (shutter.CFrame - shutter.Position)
		local record = {
			index = index,
			model = model,
			cf = model.PrimaryPart.CFrame * CFrame.new(0, -0.5, 0), -- floor top centre, +Z = out the front
			player = nil,
			ownerId = nil,
			slots = {}, -- slotIndex -> uid
			slotParts = {}, -- slotIndex -> Part
			away = {}, -- uid -> true while a thief carries it (still in the owner's save)
			uncollected = 0,
			rate = 0,
			lockedUntil = 0,
			lockCooldownUntil = 0,
			lockToken = 0,
			shutter = shutter,
			shutterClosedCF = closedCF,
			shutterOpenCF = closedCF - Vector3.new(0, L.WallH + 2, 0),
			pad = model:FindFirstChild("CollectPad"),
			signText = model:FindFirstChild("Sign"):FindFirstChild("SignGui"):FindFirstChildOfClass("TextLabel"),
			lastCollect = 0,
			charConn = nil,
			overflow = {}, -- saved SockData that has no slot yet (kept in the save, placed by RefreshSlots)
			slamPrompt = nil,
		}
		for _, slotPart in ipairs(model.Slots:GetChildren()) do
			record.slotParts[slotPart:GetAttribute("Index")] = slotPart
		end
		bases[index] = record

		record.pad.Touched:Connect(function(hit)
			Base.OnPadTouched(record, hit)
		end)

		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "SlamPrompt"
		prompt.ActionText = "Slam Drawer"
		prompt.HoldDuration = 0.4
		prompt.MaxActivationDistance = 8
		prompt.RequiresLineOfSight = false
		prompt.Parent = model.SlamButton
		prompt.Triggered:Connect(function(player)
			Base.TryLock(player, record)
		end)
		record.slamPrompt = prompt
		model:SetAttribute("OwnerId", 0)
		Base.UpdateSlamPrompt(record)
		Base.RefreshSlots(record)
	end
end

-- ---------- lookups ----------

function Base.Get(player: Player)
	return byPlayer[player]
end

function Base.ByOwnerId(userId: number)
	return byOwnerId[userId]
end

function Base.ByIndex(index: number)
	return bases[index]
end

-- Usable slots: the base rows, + the padlocked back row with the +4 Drawer Slots pass (only the
-- pass opens it). Phase 3 rebirth slots (SlotsPerRebirth) need rows of their own in Map first.
function Base.SlotCount(record): number
	local player = record.player
	local count = S.Config.Economy.BaseSlots
	if player and S.Monetize and S.Monetize.Owns(player, "ExtraSlots") then
		count += S.Config.Store.ExtraSlots
	end
	return math.min(#record.slotParts, count)
end

function Base.FirstEmptySlot(record): number?
	for i = 1, Base.SlotCount(record) do
		if record.slots[i] == nil then
			return i
		end
	end
	return nil
end

function Base.SlotCFrame(record, slotIndex: number, model: Model?): CFrame
	local slotPart = record.slotParts[slotIndex]
	local leg = model and model.PrimaryPart
	local halfHeight = if leg then leg.Size.Y / 2 else 1.6
	-- the foot reaches 0.65 (sock units) below the Leg root, times the sock scale; sink 0.1 into
	-- the cushion so the sock sits in it rather than on it. SeatLift: Map's puffy cushion mesh is
	-- taller than the flat slot part.
	local footDrop = 0.65 * S.Config.Economy.SockScale - 0.1
	local lift = slotPart:GetAttribute("SeatLift") or 0
	return slotPart.CFrame * CFrame.new(0, 0.3 + halfHeight + footDrop + lift, 0)
end

-- Drawer volume (walls included). Used for ejecting on slam.
function Base.IsInside(record, position: Vector3): boolean
	local L = S.Map.Layout
	local p = record.cf:PointToObjectSpace(position)
	return math.abs(p.X) <= L.BaseW / 2 and p.Z >= -L.BaseD / 2 and p.Z <= L.BaseD / 2 and p.Y >= -1 and p.Y <= 14
end

-- Drawer plus the apron in front of it: a thief who reaches this keeps the sock.
function Base.InClaimZone(record, position: Vector3): boolean
	local L = S.Map.Layout
	local p = record.cf:PointToObjectSpace(position)
	return math.abs(p.X) <= L.BaseW / 2 + 2 and p.Z >= -L.BaseD / 2 and p.Z <= L.BaseD / 2 + L.FrontApron and p.Y >= -1 and p.Y <= 14
end

function Base.HomeCFrame(record): CFrame
	local L = S.Map.Layout
	return record.cf * CFrame.new(0, 3, L.BaseD / 2 + 5) * CFrame.Angles(0, math.pi, 0)
end

function Base.EjectCFrame(record): CFrame
	local L = S.Map.Layout
	return record.cf * CFrame.new(0, 3, L.BaseD / 2 + S.Config.Economy.EjectDistance)
end

function Base.IsLocked(record): boolean
	return workspace:GetServerTimeNow() < record.lockedUntil
end

-- ---------- slots ----------

local function ensureStealPrompt(sock)
	local leg = sock.model and sock.model.PrimaryPart
	if not leg then
		return
	end
	local prompt = leg:FindFirstChild("StealPrompt")
	if not prompt then
		prompt = Instance.new("ProximityPrompt")
		prompt.Name = "StealPrompt"
		prompt.ActionText = "Steal"
		prompt.HoldDuration = S.Config.Economy.StealHoldSeconds
		prompt.MaxActivationDistance = S.Config.Economy.StealRange
		prompt.RequiresLineOfSight = false
		prompt.Parent = leg
		prompt.Triggered:Connect(function(player)
			S.Steal.TryPickup(player, sock)
		end)
	end
	prompt.ObjectText = S.Registry.DisplayName(sock)
	prompt.Enabled = true
end

function Base.PlaceInSlot(record, sock, slotIndex: number, animate: boolean)
	record.slots[slotIndex] = sock.uid
	sock.state = "drawer"
	sock.ownerId = record.ownerId
	sock.slot = slotIndex
	sock.homeSlot = slotIndex
	sock.carrierId = nil
	local model = sock.model
	if model then
		S.Factory.Ground(model)
		S.Factory.SetClothespin(model, false)
		S.Factory.SetLabelDistance(model, 60)
		model:SetAttribute("OwnerId", record.ownerId or 0)
		model.Parent = S.Map.Folders.Drawer
		local target = Base.SlotCFrame(record, slotIndex, model)
		-- the client idles the sock around RestCFrame once PlacedAt is ~0.8 s old (see SockFX)
		model:SetAttribute("State", "drawer")
		model:SetAttribute("RestCFrame", target)
		model:SetAttribute("PlacedAt", workspace:GetServerTimeNow())
		if animate and model.PrimaryPart then
			local leg = model.PrimaryPart
			local hop = TweenService:Create(leg, TweenInfo.new(0.55, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { CFrame = target })
			hop:Play()
		else
			model:PivotTo(target)
		end
		ensureStealPrompt(sock)
	end
end

function Base.RemoveFromSlot(record, sock)
	if sock.slot and record.slots[sock.slot] == sock.uid then
		record.slots[sock.slot] = nil
	end
	sock.slot = nil
end

function Base.SlotSocks(record)
	local list = {}
	for i = 1, #record.slotParts do
		local uid = record.slots[i]
		local sock = uid and S.Registry.Get(uid)
		if sock then
			list[i] = sock
		end
	end
	return list
end

-- Writes the drawer (plus socks currently carried away by thieves) into the profile.
function Base.SyncToProfile(record)
	local profile = record.player and S.Data.Get(record.player)
	if not profile then
		return
	end
	local out = {}
	for i = 1, #record.slotParts do
		local uid = record.slots[i]
		local sock = uid and S.Registry.Get(uid)
		if sock then
			table.insert(out, S.Registry.ToData(sock))
		end
	end
	for uid in pairs(record.away) do
		local sock = S.Registry.Get(uid)
		if sock then
			table.insert(out, S.Registry.ToData(sock))
		end
	end
	for _, data in ipairs(record.overflow) do
		table.insert(out, data)
	end
	profile.Data.socks = out
end

-- Places saved socks that had no slot at join (the back row before +4 Slots was known).
local function placeOverflow(record)
	local player = record.player
	if not player or #record.overflow == 0 then
		return
	end
	local keep = {}
	local placed = false
	for _, data in ipairs(record.overflow) do
		local slot = Base.FirstEmptySlot(record)
		local sock = slot and S.Registry.FromData(data)
		if slot and sock then
			S.Factory.Build(sock)
			Base.PlaceInSlot(record, sock, slot, false)
			S.Dex.Record(player, sock, true)
			placed = true
		else
			table.insert(keep, data) -- no room yet, or a type no longer in the roster
		end
	end
	record.overflow = keep
	if placed then
		S.Pair.Recompute(record, true)
		Base.SyncToProfile(record)
	end
end

local function setPadlock(padlock: Instance, shown: boolean)
	local transparency = if shown then 0 else 1
	if padlock:IsA("BasePart") then
		padlock.Transparency = transparency
	end
	for _, d in ipairs(padlock:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Transparency = transparency
		end
	end
end

-- Shows which slots are usable: slots past SlotCount get their padlock, the drawer's LockSign
-- lights up and its UnlockSlotsPrompt gets Locked = true (the client shows it to the owner only).
-- Also places waiting overflow socks. Map builds the padlock parts; an old place without them is fine.
function Base.RefreshSlots(record)
	placeOverflow(record)
	local count = Base.SlotCount(record)
	local anyLocked = false
	for i, slotPart in pairs(record.slotParts) do
		local locked = i > count
		anyLocked = anyLocked or locked
		local padlock = slotPart:FindFirstChild("Padlock")
		if padlock then
			setPadlock(padlock, locked)
		end
	end
	local sign = record.model:FindFirstChild("LockSign")
	local gui = sign and sign:FindFirstChild("LockGui")
	if gui and gui:IsA("BillboardGui") then
		gui.Enabled = anyLocked
	end
	local prompt = record.model:FindFirstChild("UnlockSlotsPrompt", true)
	if prompt and prompt:IsA("ProximityPrompt") then
		prompt:SetAttribute("Locked", anyLocked)
	end
end

-- ---------- assignment ----------

local function setupCharacter(record, character: Model)
	local group = ownerGroup(record.index)
	local function apply(inst)
		if inst:IsA("BasePart") then
			inst.CollisionGroup = group
		end
	end
	for _, d in ipairs(character:GetDescendants()) do
		apply(d)
	end
	character.DescendantAdded:Connect(apply)
	local root = character:WaitForChild("HumanoidRootPart", 5)
	if root then
		task.wait(0.1)
		character:PivotTo(Base.HomeCFrame(record))
	end
end

function Base.Assign(player: Player): boolean
	if byPlayer[player] then
		return true
	end
	local record
	for i = 1, #bases do
		if bases[i].player == nil then
			record = bases[i]
			break
		end
	end
	if not record then
		return false
	end
	record.player = player
	record.ownerId = player.UserId
	byPlayer[player] = record
	byOwnerId[player.UserId] = record
	record.model:SetAttribute("OwnerId", player.UserId)
	record.signText.Text = player.DisplayName .. "'s Drawer"
	record.uncollected = 0
	record.rate = 0
	record.overflow = {}
	Base.UpdatePad(record)

	-- Restore saved socks. The ones that don't fit yet (back-row socks before Monetize.Setup knows
	-- about +4 Slots, or a type no longer in the roster) wait in record.overflow and stay saved.
	local profile = S.Data.Get(player)
	if profile then
		for _, data in ipairs(profile.Data.socks) do
			local slot = Base.FirstEmptySlot(record)
			local sock = slot and S.Registry.FromData(data)
			if slot and sock then
				S.Factory.Build(sock)
				Base.PlaceInSlot(record, sock, slot, false)
			else
				table.insert(record.overflow, data)
			end
		end
		Base.SyncToProfile(record)
	end
	S.Pair.Recompute(record, true)
	Base.RefreshSlots(record)
	Base.UpdateSlamPrompt(record)

	record.charConn = player.CharacterAdded:Connect(function(character)
		setupCharacter(record, character)
	end)
	if player.Character then
		task.spawn(setupCharacter, record, player.Character)
	end
	return true
end

function Base.Unassign(player: Player)
	local record = byPlayer[player]
	if not record then
		return
	end
	Base.SyncToProfile(record)
	if record.charConn then
		record.charConn:Disconnect()
		record.charConn = nil
	end
	for i = 1, #record.slotParts do
		local uid = record.slots[i]
		if uid then
			S.Registry.Destroy(uid)
		end
		record.slots[i] = nil
	end
	for uid in pairs(record.away) do
		S.Registry.Destroy(uid)
	end
	record.away = {}
	record.overflow = {}
	record.player = nil
	record.ownerId = nil
	record.model:SetAttribute("OwnerId", 0)
	record.uncollected = 0
	record.rate = 0
	record.lockToken += 1
	Base.SetShutter(record, false)
	record.lockedUntil = 0
	record.lockCooldownUntil = 0
	record.signText.Text = "Drawer " .. record.index .. " - FREE"
	Base.UpdatePad(record)
	byPlayer[player] = nil
	byOwnerId[player.UserId] = nil
	Base.RefreshSlots(record) -- a free drawer shows the padlocked back row
	Base.UpdateSlamPrompt(record)
end

-- ---------- collect pad ----------

function Base.UpdatePad(record)
	local gui = record.pad:FindFirstChild("PadGui")
	local text = gui and gui:FindFirstChild("PadText")
	if text then
		text.Text = "COLLECT $" .. S.Util.FormatCash(math.floor(record.uncollected))
	end
end

-- Pays out the pad: the whole cash amount waiting x the Coin Magnet bonus. `auto` = Coin Magnet
-- auto-collect from Income.Tick (no toast, and Income pushes the state itself). Returns cash paid.
function Base.Collect(record, auto: boolean?): number
	local player = record.player
	if not player then
		return 0
	end
	local amount = math.floor(record.uncollected)
	if amount < 1 then
		return 0
	end
	record.uncollected -= amount
	local paid = math.floor(amount * S.Upgrades.CollectMult(player))
	S.Data.AddCash(player, paid)
	Base.UpdatePad(record)
	if not auto then
		S.Toast(player, "+$" .. S.Util.FormatCash(paid) .. " collected", "good")
		S.Income.Push(player)
	end
	return paid
end

function Base.OnPadTouched(record, hit: BasePart)
	local character = hit.Parent
	local player = character and Players:GetPlayerFromCharacter(character)
	if not player or record.player ~= player then
		return
	end
	local now = os.clock()
	if now - record.lastCollect < S.Config.Economy.CollectDebounce then
		return
	end
	record.lastCollect = now
	Base.Collect(record, false)
end

-- ---------- lock ----------

function Base.SetShutter(record, closed: boolean)
	local shutter = record.shutter
	if closed then
		-- a shutter with a mesh drawer front welded to it (Map) stays invisible itself
		shutter.Transparency = if shutter:GetAttribute("Skinned") then 1 else 0
		shutter.CanCollide = true
		TweenService:Create(shutter, SHUTTER_TWEEN, { CFrame = record.shutterClosedCF }):Play()
	else
		shutter.CanCollide = false
		local t = TweenService:Create(shutter, SHUTTER_TWEEN, { CFrame = record.shutterOpenCF })
		t.Completed:Connect(function()
			if not Base.IsLocked(record) then
				shutter.Transparency = 1
			end
		end)
		t:Play()
	end
end

-- The Slam prompt says how long the owner's lock lasts (Sturdy Lock and rebirths add time).
function Base.UpdateSlamPrompt(record)
	local prompt = record.slamPrompt
	if not prompt then
		return
	end
	local seconds = if record.player then S.Upgrades.LockSeconds(record.player) else S.Config.Economy.LockSeconds
	prompt.ObjectText = "Locks your drawer for " .. math.floor(seconds) .. "s"
end

-- Shuts the drawer for the owner's full lock time (a running lock restarts) and pushes out
-- everyone else.
local function lockNow(record, player: Player, relocked: boolean)
	local now = workspace:GetServerTimeNow()
	local seconds = S.Upgrades.LockSeconds(player)
	record.lockedUntil = now + seconds
	record.lockCooldownUntil = record.lockedUntil + S.Upgrades.LockCooldown(player)
	record.lockToken += 1
	local token = record.lockToken
	Base.SetShutter(record, true)

	-- Push out anyone who isn't the owner (they drop what they carry)
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player and other.Character then
			local root = other.Character:FindFirstChild("HumanoidRootPart")
			if root and Base.IsInside(record, root.Position) then
				S.Steal.DropCarried(other, "ejected")
				other.Character:PivotTo(Base.EjectCFrame(record))
				S.Toast(other, player.DisplayName .. " slammed the drawer on you!", "bad")
			end
		end
	end
	S.Toast(player, (if relocked then "Drawer re-locked for " else "Drawer locked for ") .. math.floor(seconds) .. "s 🔒", "good")
	S.Income.Push(player)

	task.delay(seconds, function()
		if record.lockToken == token then
			Base.SetShutter(record, false)
			if record.player then
				S.Toast(record.player, "Your drawer is open again", "info")
				S.Income.Push(record.player)
			end
		end
	end)
end

function Base.TryLock(player: Player, record)
	if not S.Ready or record.player ~= player then
		S.Toast(player, "That's not your drawer!", "bad")
		return
	end
	if not S.RateLimit.Check(player, "lock", S.Config.Economy.PromptRateLimit) then
		return
	end
	local now = workspace:GetServerTimeNow()
	if Base.IsLocked(record) then
		return
	end
	if now < record.lockCooldownUntil then
		S.Toast(player, "Drawer needs " .. math.ceil(record.lockCooldownUntil - now) .. "s to reset", "bad")
		return
	end
	lockNow(record, player, false)
end

-- Instant Re-lock (developer product): locks now, ignoring the cooldown; an already locked
-- drawer starts its full lock time again. Returns false when the player has no drawer.
function Base.ForceLock(player: Player): boolean
	local record = byPlayer[player]
	if not record then
		return false
	end
	lockNow(record, player, Base.IsLocked(record))
	return true
end

return Base
