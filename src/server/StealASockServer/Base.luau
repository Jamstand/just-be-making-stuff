-- Base: the 8 drawers. Assigns one per player, places socks in slots, runs the Collect pad,
-- the Slam Drawer lock (with a physical shutter the owner can walk through) and keeps the
-- player's profile in sync with what is in the drawer.
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
		prompt.ObjectText = "Locks your drawer for " .. S.Config.Economy.LockSeconds .. "s"
		prompt.HoldDuration = 0.4
		prompt.MaxActivationDistance = 8
		prompt.RequiresLineOfSight = false
		prompt.Parent = model.SlamButton
		prompt.Triggered:Connect(function(player)
			Base.TryLock(player, record)
		end)
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

function Base.SlotCount(record): number
	local profile = record.player and S.Data.Get(record.player)
	local rebirths = if profile then profile.Data.rebirths else 0
	return math.min(#record.slotParts, S.Config.Economy.BaseSlots + rebirths * S.Config.Economy.SlotsPerRebirth)
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
	-- the cushion so the sock sits in it rather than on it
	local footDrop = 0.65 * S.Config.Economy.SockScale - 0.1
	return slotPart.CFrame * CFrame.new(0, 0.3 + halfHeight + footDrop, 0)
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
	profile.Data.socks = out
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
	record.signText.Text = player.DisplayName .. "'s Drawer"
	record.uncollected = 0
	record.rate = 0
	Base.UpdatePad(record)

	-- Restore saved socks
	local profile = S.Data.Get(player)
	if profile then
		for _, data in ipairs(profile.Data.socks) do
			local slot = Base.FirstEmptySlot(record)
			if not slot then
				break
			end
			local sock = S.Registry.FromData(data)
			if sock then
				S.Factory.Build(sock)
				Base.PlaceInSlot(record, sock, slot, false)
			end
		end
		Base.SyncToProfile(record)
	end
	S.Pair.Recompute(record, true)

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
	record.player = nil
	record.ownerId = nil
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
end

-- ---------- collect pad ----------

function Base.UpdatePad(record)
	local gui = record.pad:FindFirstChild("PadGui")
	local text = gui and gui:FindFirstChild("PadText")
	if text then
		text.Text = "COLLECT $" .. S.Util.FormatCash(math.floor(record.uncollected))
	end
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
	local amount = math.floor(record.uncollected)
	if amount < 1 then
		return
	end
	record.uncollected -= amount
	S.Data.AddCash(player, amount)
	Base.UpdatePad(record)
	S.Toast(player, "+$" .. S.Util.FormatCash(amount) .. " collected", "good")
	S.Income.Push(player)
end

-- ---------- lock ----------

function Base.SetShutter(record, closed: boolean)
	local shutter = record.shutter
	if closed then
		shutter.Transparency = 0
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
	local Eco = S.Config.Economy
	local profile = S.Data.Get(player)
	local rebirths = if profile then profile.Data.rebirths else 0
	local seconds = Eco.LockSeconds + rebirths * Eco.LockSecondsPerRebirth
	record.lockedUntil = now + seconds
	record.lockCooldownUntil = record.lockedUntil + Eco.LockCooldownSeconds
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
	S.Toast(player, "Drawer locked for " .. seconds .. "s 🔒", "good")
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

return Base
