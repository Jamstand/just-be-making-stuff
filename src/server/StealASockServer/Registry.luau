-- Registry: every live sock in this server, by uid. Rolls new socks, computes income and price,
-- and converts to/from the saved SockData shape. Owns no models (Factory builds, Registry destroys).
local Registry = {}
local S

local socks = {} -- uid -> Sock (see Shared.Types)
local nextUid = 0
local countByType = {} -- typeId -> live copies in this server

function Registry.Init(s)
	S = s
end

local function isCapped(t): boolean
	local cap = t.maxPerServer
	if t.id == "LostSock" then
		cap = S.Config.Economy.LostSockMaxPerServer
	end
	if not cap then
		return false
	end
	return (countByType[t.id] or 0) >= cap
end

-- Rolls rarity -> type -> side. Returns typeId, side.
function Registry.RollType(): (string, string)
	local Rarity = S.Config.Rarity
	local weights = {}
	for _, key in ipairs(Rarity.Order) do
		weights[key] = Rarity.Tiers[key].weight
	end
	local rarity = S.Util.WeightedPick(weights, Rarity.Order)
	local pool = {}
	for _, t in ipairs(S.Config.Sock.List) do
		if t.rarity == rarity and not isCapped(t) then
			table.insert(pool, t)
		end
	end
	if #pool == 0 then
		for _, t in ipairs(S.Config.Sock.List) do
			if t.rarity == "Common" then
				table.insert(pool, t)
			end
		end
	end
	local t = pool[math.random(#pool)]
	local side = if t.single then "S" else (if math.random() < 0.5 then "L" else "R")
	return t.id, side
end

function Registry.RollMutation(): string
	local Mutation = S.Config.Mutation
	local r = math.random()
	local acc = 0
	for _, key in ipairs(Mutation.Order) do
		acc += Mutation.Table[key].chance
		if r <= acc then
			return key
		end
	end
	return "None"
end

function Registry.Create(typeId: string, side: string, mutation: string, stink: number?)
	nextUid += 1
	local sock = {
		uid = nextUid,
		typeId = typeId,
		side = side,
		mutation = mutation,
		stink = stink or 0,
		state = "gone",
		ownerId = nil,
		slot = nil,
		homeSlot = nil,
		carrierId = nil,
		model = nil,
		paired = false,
		perfect = false,
		pairWith = nil,
		lineStart = nil,
	}
	socks[nextUid] = sock
	countByType[typeId] = (countByType[typeId] or 0) + 1
	return sock
end

function Registry.FromData(data)
	local t = S.Config.Sock.ById[data.typeId]
	if not t then
		return nil -- type removed from the roster; the save keeps it but it can't be shown
	end
	local mutation = if S.Config.Mutation.Table[data.mutation] then data.mutation else "None"
	return Registry.Create(data.typeId, data.side, mutation, data.stink)
end

function Registry.ToData(sock)
	return { typeId = sock.typeId, side = sock.side, mutation = sock.mutation, stink = sock.stink }
end

function Registry.Get(uid: number)
	return socks[uid]
end

function Registry.All()
	return socks
end

function Registry.Destroy(uid: number)
	local sock = socks[uid]
	if not sock then
		return
	end
	sock.state = "gone"
	if sock.model then
		sock.model:Destroy()
		sock.model = nil
	end
	countByType[sock.typeId] = math.max(0, (countByType[sock.typeId] or 1) - 1)
	socks[uid] = nil
end

function Registry.Type(sock)
	return S.Config.Sock.ById[sock.typeId]
end

function Registry.Tier(sock)
	return S.Config.Rarity.Tiers[Registry.Type(sock).rarity]
end

function Registry.DisplayName(sock): string
	local t = Registry.Type(sock)
	if sock.side == "S" then
		return t.name
	end
	return t.name .. " (" .. sock.side .. ")"
end

-- Final income = base x mutation x pair bonus x perfect bonus x stink bonus x rebirth multiplier
function Registry.IncomeOf(sock, rebirths: number): number
	local Eco = S.Config.Economy
	local t = Registry.Type(sock)
	local m = S.Config.Mutation.Table[sock.mutation] or S.Config.Mutation.Table.None
	local v = t.income * m.mult
	if sock.paired or t.alwaysPaired then
		v *= Eco.PairBonus
	end
	if sock.perfect then
		v *= Eco.PerfectPairBonus
	end
	v *= 1 + (sock.stink or 0) * Eco.StinkPerLevel
	v *= 1 + (rebirths or 0) * Eco.RebirthMultPerLevel
	return v
end

-- Clothesline price: base income x payback (mutation makes it pricier too)
function Registry.PriceOf(sock): number
	local t = Registry.Type(sock)
	local tier = S.Config.Rarity.Tiers[t.rarity]
	local m = S.Config.Mutation.Table[sock.mutation] or S.Config.Mutation.Table.None
	return math.floor(t.income * m.mult * tier.payback)
end

return Registry
