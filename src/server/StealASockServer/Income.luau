-- Income: the one server loop that pays every drawer once per second and pushes each player's
-- StateView to their client. Nothing else ticks per sock.
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

function Income.RateOf(record): number
	local profile = record.player and S.Data.Get(record.player)
	local rebirths = if profile then profile.Data.rebirths else 0
	local total = 0
	for _, sock in pairs(S.Base.SlotSocks(record)) do
		total += S.Registry.IncomeOf(sock, rebirths)
	end
	return total
end

function Income.Tick()
	for i = 1, 8 do
		local record = S.Base.ByIndex(i)
		if record and record.player then
			local rate = Income.RateOf(record)
			record.rate = rate
			record.uncollected += rate * S.Config.Economy.IncomeTickSeconds
			S.Base.UpdatePad(record)
			Income.Push(record.player)
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
	local slots = {}
	for i, sock in pairs(S.Base.SlotSocks(record)) do
		local t = S.Registry.Type(sock)
		slots[i] = {
			uid = sock.uid,
			typeId = sock.typeId,
			name = t.name,
			side = sock.side,
			rarity = t.rarity,
			mutation = sock.mutation,
			stink = sock.stink,
			paired = sock.paired or (t.alwaysPaired == true),
			perfect = sock.perfect,
			income = S.Registry.IncomeOf(sock, rebirths),
		}
	end
	local carry = S.Steal.CarryView(player)
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
	})
end

return Income
