-- EconomyService: rarity/mutation rolls with pity, gem awarding, upgrades,
-- rebirth/ascension/perks, collection index bitmask, leaderstats, state snapshots.

local Players = game:GetService("Players")

local Econ = {}
local S, Config, Remotes, Data

local function profile(player)
	return Data.WaitFor(player, 5)
end

function Econ.OwnsPass(player, key)
	return S.Monetize ~= nil and S.Monetize.Owns(player, key)
end

function Econ.CompletedRows(p)
	local rows = 0
	for r = 0, 6 do
		local full = true
		for m = 0, 3 do
			if bit32.band(p.indexMask, bit32.lshift(1, r * 4 + m)) == 0 then
				full = false
				break
			end
		end
		if full then rows += 1 end
	end
	return rows
end

function Econ.IncomeMult(player)
	local p = Data.Cache[player]
	if not p then return 1 end
	local mult = (Config.Balance.RebirthMultBase ^ p.rebirths) * (Config.Balance.AscendMult ^ p.ascensions)
	if Econ.OwnsPass(player, "DoubleGems") then mult *= 2 end
	if S.Pets then mult *= (1 + S.Pets.Bonus(player)) end -- equipped pet's permanent bonus
	return mult
end

function Econ.LuckFactor(player)
	local p = Data.Cache[player]
	if not p then return 1 end
	local now = os.time()
	local f = 1 + Config.Balance.LuckWeightPerLevel * p.luck
	if Econ.OwnsPass(player, "DoubleLuck") then f *= 2 end
	if p.boostUntil > now then f *= 2 end
	if p.streakLuckUntil > now then f *= 2 end
	f *= 1 + S.Buffs.ServerLuckPct()
	if S.Buffs.GoldenHourActive() then f *= 1.5 end
	f *= 1 + 0.1 * Econ.CompletedRows(p)
	return f
end

function Econ.RollRarity(player)
	local p = Data.Cache[player]
	local f = Econ.LuckFactor(player)
	local weights, total = {}, 0
	for i, r in ipairs(Config.Rarities) do
		local w = r.weight
		if i >= Config.LuckyTierIndex then w *= f end
		weights[i] = w
		total += w
	end
	local roll, acc, idx = math.random() * total, 0, 1
	for i, w in ipairs(weights) do
		acc += w
		if roll <= acc then idx = i break end
	end
	-- pity system
	local pityMult = p.perks.PityDown and 0.8 or 1
	p.cracks += 1
	if p.cracks == Config.Balance.PityFirstTopaz and p.bestRarity < 3 and idx < 3 then idx = 3 end
	if idx >= 5 then p.pityRuby = 0 else p.pityRuby += 1 end
	if idx >= 6 then p.pityStar = 0 else p.pityStar += 1 end
	if p.pityRuby >= math.floor(Config.Balance.PityRuby * pityMult) then
		idx, p.pityRuby = 5, 0
	end
	if p.pityStar >= math.floor(Config.Balance.PityStar * pityMult) then
		idx, p.pityStar = 6, 0
	end
	return idx
end

function Econ.RollMutation(player)
	local p = Data.Cache[player]
	local celBonus = (p and p.perks.CelestialUp) and 0.25 or 0
	local weights, total = {}, 0
	for i, m in ipairs(Config.Mutations) do
		local w = m.weight
		if m.key == "Celestial" then w += celBonus end
		weights[i] = w
		total += w
	end
	local roll, acc = math.random() * total, 0
	for i, w in ipairs(weights) do
		acc += w
		if roll <= acc then return i end
	end
	return 1
end

local function syncLeaderstats(player, p)
	local ls = player:FindFirstChild("leaderstats")
	if ls then
		ls.Gems.Value = p.gems
		ls.Rebirths.Value = p.rebirths
	end
end

-- multiplied award (crack/meteor payouts)
function Econ.AwardGems(player, amount)
	local p = Data.Cache[player]
	if not p then return 0 end
	local final = math.floor(amount * Econ.IncomeMult(player) + 0.5)
	p.gems += final
	p.totalGems += final
	syncLeaderstats(player, p)
	return final
end

-- raw award (garden payouts — savedEarnRate already includes the multiplier)
function Econ.AwardRaw(player, amount)
	local p = Data.Cache[player]
	if not p then return 0 end
	local final = math.floor(amount + 0.5)
	p.gems += final
	p.totalGems += final
	syncLeaderstats(player, p)
	return final
end

function Econ.RegisterFind(player, rarityIdx, mutIdx)
	local p = Data.Cache[player]
	if not p then return 0, false end
	local base = Config.Rarities[rarityIdx].value * Config.Mutations[mutIdx].mult
	local gained = Econ.AwardGems(player, base)
	if rarityIdx > p.bestRarity then p.bestRarity = rarityIdx end
	local bitIndex = (rarityIdx - 1) * 4 + (mutIdx - 1)
	local newEntry = bit32.band(p.indexMask, bit32.lshift(1, bitIndex)) == 0
	if newEntry then
		p.indexMask = bit32.bor(p.indexMask, bit32.lshift(1, bitIndex))
		Remotes.OrbitSync:FireAllClients({ userId = player.UserId, mask = p.indexMask, best = p.bestRarity })
	end
	Econ.RecomputeRate(player)
	return gained, newEntry
end

function Econ.RecomputeRate(player)
	local p = Data.Cache[player]
	if not p then return end
	local f = 1 + Config.Balance.LuckWeightPerLevel * p.luck
	local total, ev = 0, 0
	for i, r in ipairs(Config.Rarities) do
		local w = r.weight * (i >= Config.LuckyTierIndex and f or 1)
		total += w
		ev += w * r.value
	end
	ev = (ev / total) * 1.275 * Econ.IncomeMult(player)
	p.savedEarnRate = math.max(5, ev / Config.Cooldown(p.power))
end

function Econ.Buy(player, what)
	local p = profile(player)
	if not p then return { ok = false, err = "Still loading" } end
	if what == "Power" then
		local cost = Config.PowerCost(p.power)
		if p.gems < cost then return { ok = false, err = "Not enough Gems" } end
		p.gems -= cost
		p.power += 1
		if S.Dailies then S.Dailies.Event(player, "upgrade", 1) end
	elseif what == "Luck" then
		local cost = Config.LuckCost(p.luck)
		if p.gems < cost then return { ok = false, err = "Not enough Gems" } end
		p.gems -= cost
		p.luck += 1
		if S.Dailies then S.Dailies.Event(player, "upgrade", 1) end
	elseif what == "Rebirth" then
		local cost = Config.RebirthCost(p.rebirths)
		if p.gems < cost then return { ok = false, err = "Not enough Gems" } end
		p.gems, p.power, p.luck = 0, 0, 0
		p.rebirths += 1
		Remotes.Announce:FireAllClients({ kind = "rebirth", text = "🔄 " .. player.DisplayName .. " Recrystallized! (Rebirth " .. p.rebirths .. ")", colorRGB = { 190, 130, 255 } })
		if S.Pickaxe then S.Pickaxe.Refresh(player) end
		if S.Pets then S.Pets.OnRebirth(player) end
		if S.Dailies then S.Dailies.Event(player, "rebirth", 1) end
		Data.SaveSoon(player) -- persist the milestone immediately, not on the next autosave
	elseif what == "Ascend" then
		if p.rebirths < Config.Balance.AscensionAtRebirth then
			return { ok = false, err = "Requires Rebirth " .. Config.Balance.AscensionAtRebirth }
		end
		p.gems, p.power, p.luck, p.rebirths = 0, 0, 0, 0
		p.ascensions += 1
		p.shards += 1
		Remotes.Announce:FireAllClients({ kind = "ascend", text = "🌌 " .. player.DisplayName .. " ASCENDED! Base multiplier x" .. Config.Fmt(Config.Balance.AscendMult ^ p.ascensions) .. " forever!", colorRGB = { 255, 210, 90 } })
		if S.Pickaxe then S.Pickaxe.Refresh(player) end
		Data.SaveSoon(player)
	elseif string.sub(what, 1, 5) == "Perk:" then
		local key = string.sub(what, 6)
		local valid = false
		for _, perk in ipairs(Config.Perks) do
			if perk.key == key then valid = true break end
		end
		if not valid then return { ok = false, err = "Unknown perk" } end
		if p.perks[key] then return { ok = false, err = "Already owned" } end
		if p.shards < 1 then return { ok = false, err = "Need an Ascension Shard" } end
		p.shards -= 1
		p.perks[key] = true
		Data.SaveSoon(player)
	else
		return { ok = false, err = "Unknown action" }
	end
	syncLeaderstats(player, p)
	Econ.RecomputeRate(player)
	Econ.Push(player)
	return { ok = true }
end

function Econ.Snapshot(player)
	local p = Data.Cache[player]
	if not p then return nil end
	local passes = {}
	for _, pass in ipairs(Config.GamePasses) do
		passes[pass.key] = Econ.OwnsPass(player, pass.key)
	end
	return {
		gems = p.gems, totalGems = p.totalGems, power = p.power, luck = p.luck,
		rebirths = p.rebirths, ascensions = p.ascensions, shards = p.shards, perks = p.perks,
		indexMask = p.indexMask, cracks = p.cracks, bestRarity = p.bestRarity,
		mult = Econ.IncomeMult(player), luckFactor = Econ.LuckFactor(player),
		cooldown = Config.Cooldown(p.power), rate = p.savedEarnRate,
		powerCost = Config.PowerCost(p.power), luckCost = Config.LuckCost(p.luck),
		rebirthCost = Config.RebirthCost(p.rebirths),
		boostUntil = p.boostUntil, streakLuckUntil = p.streakLuckUntil, streakDay = p.streakDay,
		serverLuckPct = S.Buffs.ServerLuckPct(),
		goldenHour = S.Buffs.GoldenHourActive(),
		passes = passes,
		gardenValue = S.Garden.Value(player),
		gardenOvergrown = S.Garden.IsOvergrown(player),
		gardenPlots = S.Garden.PlotCount(player),
		onboard = (S.Onboarding and S.Onboarding.SnapshotData(player)) or nil,
		daily = (S.Dailies and S.Dailies.State(player)) or nil,
		pets = (S.Pets and S.Pets.Snapshot(player)) or nil,
		starterOffered = (S.Monetize and S.Monetize.StarterOffered(player)) or false,
		now = os.time(),
	}
end

function Econ.Push(player)
	local snap = Econ.Snapshot(player)
	if snap then
		Remotes.StatsChanged:FireClient(player, snap)
	end
end

local function setup(player)
	if player:FindFirstChild("leaderstats") then return end
	task.spawn(function()
		local p = Data.WaitFor(player)
		if not p then return end
		local ls = Instance.new("Folder")
		ls.Name = "leaderstats"
		local g = Instance.new("IntValue")
		g.Name = "Gems"; g.Value = p.gems; g.Parent = ls
		local r = Instance.new("IntValue")
		r.Name = "Rebirths"; r.Value = p.rebirths; r.Parent = ls
		ls.Parent = player
		Econ.RecomputeRate(player)
		Econ.Push(player)
	end)
end

function Econ.Init(services)
	S = services
	Config, Remotes, Data = S.Config, S.Remotes, S.Data

	Players.PlayerAdded:Connect(setup)
	task.defer(function()
		for _, p in ipairs(Players:GetPlayers()) do setup(p) end
	end)

	-- GetState is read-only; serve a short-lived cache so invocation-spam can't
	-- burn frame time rebuilding snapshots or re-running the orbit fan-out.
	local lastFullSync, lastState, cachedSnap, lastBuy = {}, {}, {}, {}
	Remotes.GetState.OnServerInvoke = function(player)
		if not S.Ready then return nil end -- server still booting; client falls back to StatsChanged push
		local now = os.clock()
		if lastState[player] and now - lastState[player] < 0.5 and cachedSnap[player] then
			return cachedSnap[player]
		end
		lastState[player] = now
		local snap = Econ.Snapshot(player)
		cachedSnap[player] = snap
		if not lastFullSync[player] or now - lastFullSync[player] > 2 then
			lastFullSync[player] = now
			for other, prof in pairs(Data.Cache) do
				Remotes.OrbitSync:FireClient(player, { userId = other.UserId, mask = prof.indexMask, best = prof.bestRarity })
			end
		end
		return snap
	end

	Remotes.Buy.OnServerInvoke = function(player, what)
		if not S.Ready then return { ok = false, err = "Starting up…" } end
		if type(what) ~= "string" then return { ok = false, err = "Bad request" } end
		local now = os.clock()
		if lastBuy[player] and now - lastBuy[player] < 0.1 then
			return { ok = false, err = "Slow down!" }
		end
		lastBuy[player] = now
		return Econ.Buy(player, what)
	end

	Players.PlayerRemoving:Connect(function(player)
		lastFullSync[player] = nil
		lastState[player] = nil
		cachedSnap[player] = nil
		lastBuy[player] = nil
	end)
end

return Econ
