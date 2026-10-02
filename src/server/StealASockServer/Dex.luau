-- Dex: the Sockdex (DexConfig). profile.Data.sockdex[typeId] remembers which halves you have had,
-- and whether you ever paired / perfect-paired them. The first sock of a type pays its rarity's
-- NewReward; milestones (percent of SockConfig.List found) are claimed from the Sockdex menu.
-- API: Dex.Setup(player), Dex.Record(player, sock, quiet?) -> isNew, Dex.FoundPercent(player),
--      Dex.View(player) -> {dex, claimed}
-- Remote: ClaimDex(milestoneKey) -> Types.Result
local Dex = {}
local S

local CLAIM_GAP = 0.5 -- seconds between ClaimDex calls per player
local SIDES = { L = true, R = true, S = true }

local function dexOf(profile)
	if type(profile.Data.sockdex) ~= "table" then
		profile.Data.sockdex = {}
	end
	return profile.Data.sockdex
end

-- Notes a sock the player now has (bought, stolen, dropped, paired). Only ever adds flags.
-- The first sock of a type pays DexConfig.NewReward unless `quiet` (restoring a saved drawer).
-- `sock` may also be saved SockData ({typeId, side}). Returns true when the type is new.
function Dex.Record(player: Player, sock, quiet: boolean?): boolean
	local profile = S.Data.Get(player)
	local t = sock and S.Config.Sock.ById[sock.typeId]
	if not profile or not t then
		return false
	end
	local dex = dexOf(profile)
	local entry = dex[t.id]
	local isNew = entry == nil
	if isNew then
		entry = {}
		dex[t.id] = entry
	end
	if SIDES[sock.side] then
		entry[sock.side] = true
	end
	if sock.paired or t.alwaysPaired then
		entry.paired = true
	end
	if sock.perfect then
		entry.perfect = true
	end
	if isNew and not quiet then
		local reward = S.Config.Dex.NewReward[t.rarity] or 0
		S.Data.AddCash(player, reward)
		S.Celebrate(player, "dexNew", { typeId = t.id, name = t.name, rarity = t.rarity, reward = reward })
	end
	return isNew
end

-- Types found / every type in the roster, 0..100.
function Dex.FoundPercent(player: Player): number
	local profile = S.Data.Get(player)
	local total = #S.Config.Sock.List
	if not profile or total == 0 then
		return 0
	end
	local found = 0
	for typeId in pairs(dexOf(profile)) do
		if S.Config.Sock.ById[typeId] then
			found += 1
		end
	end
	return found / total * 100
end

function Dex.View(player: Player)
	local profile = S.Data.Get(player)
	if not profile then
		return { dex = {}, claimed = {} }
	end
	return { dex = dexOf(profile), claimed = profile.Data.dexClaimed or {} }
end

-- On join: quietly records the socks already in the drawer (no rewards for those).
function Dex.Setup(player: Player)
	local record = S.Base.Get(player)
	if not record then
		return
	end
	for _, sock in pairs(S.Base.SlotSocks(record)) do
		Dex.Record(player, sock, true)
	end
	for _, data in ipairs(record.overflow or {}) do
		Dex.Record(player, data, true)
	end
end

-- ---------- ClaimDex remote ----------

local function claim(player: Player, key: any)
	if not S.Ready then
		return { ok = false, err = "Starting up…" }
	end
	if type(key) ~= "string" then
		return { ok = false, err = "Bad request" }
	end
	local milestone
	for _, m in ipairs(S.Config.Dex.Milestones) do
		if m.key == key then
			milestone = m
			break
		end
	end
	if not milestone then
		return { ok = false, err = "Bad request" }
	end
	if not S.RateLimit.Check(player, "claimDex", CLAIM_GAP) then
		return { ok = false, err = "Slow down a little!" }
	end
	local profile = S.Data.Get(player)
	if not profile then
		return { ok = false, err = "Your drawer isn't ready yet" }
	end
	if type(profile.Data.dexClaimed) ~= "table" then
		profile.Data.dexClaimed = {}
	end
	if profile.Data.dexClaimed[key] then
		return { ok = false, err = "Already claimed" }
	end
	local percent = Dex.FoundPercent(player)
	if percent < milestone.percent then
		return { ok = false, err = "Find " .. milestone.percent .. "% of the socks first (you have " .. math.floor(percent) .. "%)" }
	end
	profile.Data.dexClaimed[key] = true
	S.Data.AddCash(player, milestone.cash)
	S.Celebrate(player, "milestone", { key = key, display = milestone.display, cash = milestone.cash })
	S.Income.Push(player)
	return { ok = true, cash = milestone.cash, msg = milestone.display .. ": +$" .. S.Util.FormatCash(milestone.cash) }
end

function Dex.Init(s)
	S = s
	S.Remotes.ClaimDex.OnServerInvoke = function(player: Player, key: any)
		local ok, result = pcall(claim, player, key)
		if not ok then
			warn("[Dex] ClaimDex failed: " .. tostring(result))
			return { ok = false, err = "Something went wrong - try again" }
		end
		return result
	end
end

return Dex
