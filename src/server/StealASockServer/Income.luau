-- Income: the one server loop that pays every drawer once per second and pushes each player's
-- StateView to their client. Nothing else ticks per sock. Also runs the Coin Magnet auto-collect
-- and lands Rare Sock Drops that were waiting for a free slot.
local Income = {}
local S

function Income.Init(s)
	S = s
	task.spawn(function()
		while true do
			task.wait(S.Config.Economy.IncomeTickSeconds)
			Income.Tick()
		end
	end)
end

-- Income multiplier from game passes (2x Cash, VIP); 1 before the passes are known.
local function passMult(player: Player?): number
	if player and S.Monetize then
		return S.Monetize.IncomeMult(player)
	end
	return 1
end

function Income.RateOf(record): number
	local profile = record.player and S.Data.Get(record.player)
	local rebirths = if profile then profile.Data.rebirths else 0
	local total = 0
	for _, sock in pairs(S.Base.SlotSocks(record)) do
		total += S.Registry.IncomeOf(sock, rebirths)
	end
	return total * passMult(record.player)
end

local function standsInDrawer(player: Player, record): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root ~= nil and S.Base.IsInside(record, root.Position)
end

function Income.Tick()
	for i = 1, 8 do
		local record = S.Base.ByIndex(i)
		local player = record and record.player
		if player then
			local ok, err = pcall(function()
				local rate = Income.RateOf(record)
				record.rate = rate
				record.uncollected += rate * S.Config.Economy.IncomeTickSeconds
				if S.Upgrades.AutoCollect(player) and standsInDrawer(player, record) then
					S.Base.Collect(record, true)
				end
				S.Base.UpdatePad(record)
				local profile = S.Data.Get(player)
				if profile and (tonumber(profile.Data.pendingDrops) or 0) > 0 and S.Base.FirstEmptySlot(record) then
					S.Monetize.DeliverPending(player)
				end
				Income.Push(player)
			end)
			if not ok then
				warn("[Income] tick failed for drawer " .. i .. ": " .. tostring(err))
			end
		end
	end
end

-- Builds and sends the StateView for one player (see Shared.Types).
function Income.Push(player: Player)
	local record = S.Base.Get(player)
	local profile = S.Data.Get(player)
	if not record or not profile then
		return
	end
	local rebirths = profile.Data.rebirths
	local mult = passMult(player)
	local slots = {} -- string keys: an array with gaps (an empty middle slot) could be cut short by the remote
	for i, sock in pairs(S.Base.SlotSocks(record)) do
		local t = S.Registry.Type(sock)
		slots[tostring(i)] = {
			uid = sock.uid,
			typeId = sock.typeId,
			name = t.name,
			side = sock.side,
			rarity = t.rarity,
			mutation = sock.mutation,
			stink = sock.stink,
			paired = sock.paired or (t.alwaysPaired == true),
			perfect = sock.perfect,
			income = S.Registry.IncomeOf(sock, rebirths) * mult,
			sellPrice = S.Registry.SellPriceOf(sock),
		}
	end
	local upgrades = {}
	for _, key in ipairs(S.Config.Shop.Order) do
		upgrades[key] = S.Upgrades.Level(player, key)
	end
	local passes = {}
	for _, key in ipairs(S.Config.Store.PassOrder) do
		passes[key] = S.Monetize.Owns(player, key)
	end
	local dex = S.Dex.View(player)
	local carry = S.Steal.CarryView(player)
	local items = S.Items.View(player)
	S.Remotes.State:FireClient(player, {
		cash = profile.Data.cash,
		rate = record.rate,
		uncollected = record.uncollected,
		rebirths = rebirths,
		slotCount = S.Base.SlotCount(record),
		slots = slots,
		lockedUntil = record.lockedUntil,
		lockCooldownUntil = record.lockCooldownUntil,
		baseIndex = record.index,
		carrying = carry,
		maxSlots = #record.slotParts,
		upgrades = upgrades,
		passes = passes,
		luckUntil = S.Monetize.LuckUntil(),
		dex = dex.dex,
		dexClaimed = dex.claimed,
		pendingDrops = tonumber(profile.Data.pendingDrops) or 0,
		settings = profile.Data.settings or {},
		items = items.items,
		loadout = items.loadout,
		towelLook = items.towelLook,
	})
end

return Income
