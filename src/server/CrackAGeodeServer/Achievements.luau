-- AchievementsService: a board of tiered achievements. Each achievement tracks a
-- player stat and has escalating goal->reward tiers you claim one at a time. Pure
-- data-driven config (ACHS) so adding an achievement or tier is just an entry.

local Achievements = {}
local S, Zones

local ACHS = {
	{ key = "cracker", name = "Geode Cracker", icon = "⛏️", stat = "cracks",
	  tiers = { { goal = 100, gems = 2000 }, { goal = 1000, gems = 15000 }, { goal = 10000, gems = 150000 } } },
	{ key = "reborn", name = "Reborn", icon = "🔄", stat = "rebirths",
	  tiers = { { goal = 1, gems = 5000 }, { goal = 5, gems = 40000 }, { goal = 15, gems = 300000 } } },
	{ key = "explorer", name = "Shard Seeker", icon = "🐚", stat = "shards",
	  tiers = { { goal = 1, gems = 3000 }, { goal = 5, gems = 25000 } } },
	{ key = "collector", name = "Collector", icon = "📖", stat = "indexPct100",
	  tiers = { { goal = 25, gems = 10000 }, { goal = 50, gems = 50000 }, { goal = 100, gems = 500000 } } },
	{ key = "traveler", name = "Traveler", icon = "🌀", stat = "zonesUnlocked",
	  tiers = { { goal = 2, gems = 8000 }, { goal = 5, gems = 80000 } } },
	{ key = "tamer", name = "Pet Tamer", icon = "🐾", stat = "petsOwned",
	  tiers = { { goal = 1, gems = 4000 }, { goal = 10, gems = 30000 }, { goal = 50, gems = 200000 } } },
}

local function statsFor(p)
	local totalShards = 0
	for _, n in pairs(p.zoneShards or {}) do totalShards += n end
	local bits = 0
	for i = 0, 27 do if bit32.band(p.indexMask or 0, bit32.lshift(1, i)) ~= 0 then bits += 1 end end
	local zst = Zones.StatsFor(p)
	local zonesUnlocked = 0
	for _, z in ipairs(Zones.list) do if Zones.IsUnlocked(z, zst) then zonesUnlocked += 1 end end
	local petsOwned = 0
	for _, c in pairs(p.petInv or {}) do petsOwned += c end
	return {
		cracks = p.cracks or 0, rebirths = p.rebirths or 0, shards = totalShards,
		indexPct100 = math.floor(bits / 28 * 100), zonesUnlocked = zonesUnlocked, petsOwned = petsOwned,
	}
end

function Achievements.State(player)
	local p = S.Data.Cache[player]
	if not p then return nil end
	p.achClaimed = p.achClaimed or {}
	local st = statsFor(p)
	local out = {}
	for _, a in ipairs(ACHS) do
		local cur = st[a.stat] or 0
		local claimedTier = p.achClaimed[a.key] or 0
		local tiers, claimable = {}, false
		for i, t in ipairs(a.tiers) do
			local done = cur >= t.goal
			local claimed = i <= claimedTier
			if done and not claimed then claimable = true end
			tiers[i] = { goal = t.goal, gems = t.gems, done = done, claimed = claimed }
		end
		out[#out + 1] = { key = a.key, name = a.name, icon = a.icon, cur = cur, tiers = tiers, claimable = claimable }
	end
	return out
end

function Achievements.Claim(player, key)
	local p = S.Data.Cache[player]
	if not p then return { ok = false, err = "Loading…" } end
	local ach
	for _, a in ipairs(ACHS) do if a.key == key then ach = a break end end
	if not ach then return { ok = false, err = "Unknown" } end
	p.achClaimed = p.achClaimed or {}
	local nextTier = (p.achClaimed[ach.key] or 0) + 1
	local t = ach.tiers[nextTier]
	if not t then return { ok = false, err = "All claimed" } end
	local cur = statsFor(p)[ach.stat] or 0
	if cur < t.goal then return { ok = false, err = "Not yet" } end
	p.achClaimed[ach.key] = nextTier
	S.Econ.AwardRaw(player, t.gems)
	if S.Data.SaveSoon then S.Data.SaveSoon(player) end
	S.Econ.Push(player)
	S.Remotes.Announce:FireClient(player, {
		kind = "ach",
		text = "🏅 " .. ach.name .. " — Tier " .. nextTier .. "!  +" .. S.Config.Fmt(t.gems) .. " 💎",
		color = Color3.fromRGB(255, 210, 90),
	})
	return { ok = true, gems = t.gems }
end

function Achievements.Init(services)
	S = services
	Zones = S.Config.Zones
	S.Remotes.ClaimAchievement.OnServerInvoke = function(player, key)
		if not S.Ready then return { ok = false, err = "Starting up…" } end
		if type(key) ~= "string" then return { ok = false, err = "Bad request" } end
		return Achievements.Claim(player, key)
	end
end

return Achievements
