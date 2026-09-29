-- Steal: hold E on a sock in someone else's open drawer, carry it on your head (slower by
-- rarity), reach your own drawer's claim zone to keep it. Dying, leaving, a Towel Snap or a
-- slammed drawer sends it home. The victim's save keeps the sock until the thief claims it.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Steal = {}
local S

local carriers = {} -- Player -> { sock = Sock, victimBase = record, lastFullToast = number }
local diedConns = {} -- Player -> RBXScriptConnection

function Steal.Init(s)
	S = s
	RunService.Heartbeat:Connect(Steal.Tick)
end

local function root(player: Player): BasePart?
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart")
end

local function humanoid(player: Player): Humanoid?
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

-- WalkSpeed for the player's current state (carrying or not).
function Steal.ApplySpeed(player: Player)
	local h = humanoid(player)
	if not h then
		return
	end
	local carry = carriers[player]
	local base = S.Config.Economy.BaseWalkSpeed
	if carry then
		h.WalkSpeed = base * S.Registry.Tier(carry.sock).carrySpeed
	else
		h.WalkSpeed = base
	end
end

function Steal.CarryView(player: Player)
	local carry = carriers[player]
	if not carry then
		return nil
	end
	local t = S.Registry.Type(carry.sock)
	return { name = S.Registry.DisplayName(carry.sock), side = carry.sock.side, rarity = t.rarity }
end

function Steal.IsCarrying(player: Player): boolean
	return carriers[player] ~= nil
end

function Steal.Carriers()
	return carriers
end

local function attach(player: Player, sock)
	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	local model = sock.model
	local leg = model and model.PrimaryPart
	if not head or not leg then
		return false
	end
	local prompt = leg:FindFirstChild("StealPrompt")
	if prompt then
		prompt.Enabled = false
	end
	leg.Anchored = false
	model:PivotTo(head.CFrame * CFrame.new(0, S.Config.Economy.CarryHeightOffset, 0))
	local weld = Instance.new("WeldConstraint")
	weld.Name = "CarryWeld"
	weld.Part0 = head
	weld.Part1 = leg
	weld.Parent = leg
	model:SetAttribute("CarrierId", player.UserId)
	model:SetAttribute("State", "carried")
	model.Parent = S.Map.Folders.Carried
	return true
end

local function detach(sock)
	local model = sock.model
	if model then
		S.Factory.Ground(model)
		model:SetAttribute("CarrierId", 0)
	end
	sock.carrierId = nil
end

function Steal.Setup(player: Player)
	local function hook(character)
		local h = character:WaitForChild("Humanoid", 5)
		if h then
			if diedConns[player] then
				diedConns[player]:Disconnect()
			end
			diedConns[player] = h.Died:Connect(function()
				Steal.Return(player, "died")
			end)
		end
	end
	player.CharacterAdded:Connect(hook)
	if player.Character then
		task.spawn(hook, player.Character)
	end
end

function Steal.TryPickup(player: Player, sock)
	if not S.Ready or not S.RateLimit.Check(player, "steal", S.Config.Economy.PromptRateLimit) then
		return
	end
	if sock.state ~= "drawer" or sock.ownerId == player.UserId then
		return
	end
	if carriers[player] then
		S.Toast(player, "You're already carrying a sock!", "bad")
		return
	end
	local victimBase = S.Base.ByOwnerId(sock.ownerId)
	if not victimBase or not victimBase.player then
		return
	end
	if S.Base.IsLocked(victimBase) then
		S.Toast(player, "That drawer is slammed shut!", "bad")
		return
	end
	local r = root(player)
	local leg = sock.model and sock.model.PrimaryPart
	local h = humanoid(player)
	if not r or not leg or not h or h.Health <= 0 then
		return
	end
	if (r.Position - leg.Position).Magnitude > S.Config.Economy.StealRange then
		return
	end

	local wasPaired = sock.paired
	local victim = victimBase.player
	S.Base.RemoveFromSlot(victimBase, sock)
	victimBase.away[sock.uid] = true
	sock.state = "carried"
	sock.carrierId = player.UserId
	if not attach(player, sock) then
		-- character vanished mid-prompt; put it straight back
		victimBase.away[sock.uid] = nil
		local slot = S.Base.FirstEmptySlot(victimBase) or sock.homeSlot
		S.Base.PlaceInSlot(victimBase, sock, slot, false)
		return
	end
	carriers[player] = { sock = sock, victimBase = victimBase, lastFullToast = 0 }
	Steal.ApplySpeed(player)
	S.Pair.Recompute(victimBase)
	S.Base.SyncToProfile(victimBase)

	local name = S.Registry.DisplayName(sock)
	local tier = S.Registry.Tier(sock)
	S.FX("steal", leg.Position, tier.color)
	S.Toast(player, "Grabbed " .. name .. "! Run home! 🏃", "good")
	S.Toast(victim, player.DisplayName .. " is stealing your " .. name .. "! Snap them with your towel!", "bad")
	if wasPaired and tier.rank >= S.Config.Rarity.AnnounceFromRank then
		S.Announce(player.DisplayName .. " just broke " .. victim.DisplayName .. "'s " .. S.Registry.Type(sock).name .. " pair! 💔", tier.color)
	end
	S.Remotes.Carry:FireClient(player, Steal.CarryView(player))
	S.Income.Push(player)
	S.Income.Push(victim)
end

function Steal.Tick()
	for player, carry in pairs(carriers) do
		local h = humanoid(player)
		local r = root(player)
		if not h or not r or h.Health <= 0 or player.Parent ~= Players then
			Steal.Return(player, "died")
		else
			local myBase = S.Base.Get(player)
			if myBase and S.Base.InClaimZone(myBase, r.Position) then
				Steal.Claim(player)
			end
		end
	end
end

function Steal.Claim(player: Player)
	local carry = carriers[player]
	if not carry then
		return
	end
	local myBase = S.Base.Get(player)
	local sock = carry.sock
	local slot = S.Base.FirstEmptySlot(myBase)
	if not slot then
		local now = os.clock()
		if now - carry.lastFullToast >= S.Config.Economy.ClaimFullToastGap then
			carry.lastFullToast = now
			S.Toast(player, "Your drawer is full! Make room to keep this sock.", "bad")
		end
		return
	end
	local victimBase = carry.victimBase
	carriers[player] = nil
	detach(sock)
	victimBase.away[sock.uid] = nil
	local victim = victimBase.player
	if victim then
		local vp = S.Data.Get(victim)
		if vp then
			vp.Data.stats.socksLost += 1
		end
		S.Base.SyncToProfile(victimBase)
	end
	sock.ownerId = player.UserId
	S.Base.PlaceInSlot(myBase, sock, slot, true)
	S.Base.SyncToProfile(myBase)
	S.Pair.Recompute(myBase)
	S.Base.SyncToProfile(myBase)
	local profile = S.Data.Get(player)
	if profile then
		profile.Data.stats.socksStolen += 1
	end
	Steal.ApplySpeed(player)
	S.Remotes.Carry:FireClient(player, nil)
	local name = S.Registry.DisplayName(sock)
	local tier = S.Registry.Tier(sock)
	S.FX("claim", S.Base.SlotCFrame(myBase, slot).Position, tier.color)
	S.Toast(player, "Kept " .. name .. "! It's yours now. 🧦", "good")
	if victim then
		S.Toast(victim, player.DisplayName .. " got away with your " .. name .. "!", "bad")
		S.Income.Push(victim)
	end
	if tier.rank >= S.Config.Rarity.AnnounceFromRank then
		S.Announce(player.DisplayName .. " stole a " .. name .. (if victim then " from " .. victim.DisplayName else "") .. "! 😈", tier.color)
	end
	S.Income.Push(player)
end

-- Sends the carried sock back to its owner's drawer. reason: "died" | "left" | "snapped" | "ejected" | "dropped"
function Steal.Return(player: Player, reason: string)
	local carry = carriers[player]
	if not carry then
		return
	end
	carriers[player] = nil
	local sock = carry.sock
	local victimBase = carry.victimBase
	detach(sock)
	if victimBase.player and S.Registry.Get(sock.uid) then
		victimBase.away[sock.uid] = nil
		local slot = if sock.homeSlot and victimBase.slots[sock.homeSlot] == nil then sock.homeSlot else S.Base.FirstEmptySlot(victimBase)
		if slot then
			S.Base.PlaceInSlot(victimBase, sock, slot, true)
			S.Pair.Recompute(victimBase)
		else
			-- Drawer filled up meanwhile: the sock stays in the owner's save and reappears next join.
			victimBase.away[sock.uid] = true
			if sock.model then
				sock.model:Destroy()
				sock.model = nil
			end
		end
		S.Base.SyncToProfile(victimBase)
		if reason ~= "left" then
			S.Toast(victimBase.player, "Your " .. S.Registry.DisplayName(sock) .. " came back home!", "good")
		end
		S.Income.Push(victimBase.player)
	else
		S.Registry.Destroy(sock.uid)
	end
	if player.Parent == Players then
		Steal.ApplySpeed(player)
		S.Remotes.Carry:FireClient(player, nil)
		if reason == "snapped" then
			S.Toast(player, "SNAPPED! You dropped the sock.", "bad")
		elseif reason == "ejected" then
			S.Toast(player, "The drawer slammed - you dropped the sock.", "bad")
		elseif reason == "died" then
			S.Toast(player, "You dropped the sock.", "bad")
		end
		S.Income.Push(player)
	end
end

function Steal.DropCarried(player: Player, reason: string)
	Steal.Return(player, reason)
end

function Steal.OnPlayerRemoving(player: Player)
	-- 1) They were carrying something: it goes home.
	Steal.Return(player, "left")
	-- 2) Their own socks are being carried by others: those steals fail. The models go away;
	--    the socks stay in this player's save (Base.Unassign writes slots + away).
	for thief, carry in pairs(carriers) do
		if carry.sock.ownerId == player.UserId then
			carriers[thief] = nil
			detach(carry.sock)
			carry.sock.state = "gone"
			if carry.sock.model then
				carry.sock.model:Destroy()
				carry.sock.model = nil
			end
			if thief.Parent == Players then
				Steal.ApplySpeed(thief)
				S.Remotes.Carry:FireClient(thief, nil)
				S.Toast(thief, "The owner left - the sock vanished with them.", "bad")
				S.Income.Push(thief)
			end
		end
	end
	if diedConns[player] then
		diedConns[player]:Disconnect()
		diedConns[player] = nil
	end
end

return Steal
