-- SocialService: everything other players can SEE, and every message that reaches
-- a client through the Announce remote.
--
--   * Presence — server-set replicated Player attributes, compare-before-set:
--       Rebirths, Ascensions, PetName, PetEmoji, PetColor, IsVIP, Title  (SyncPresence,
--       called at the end of every Econ.Push) and Zone (SetZone, from Regions.Warp +
--       the Regions 1 Hz nearest-centre loop). Clients read them via GetAttribute /
--       AttributeChanged; they are never trusted for value.
--   * Messaging — Social.Tell is the ONLY personal path (FireClient, personal=true,
--       userId defaults to the recipient) and Social.Broadcast the ONLY FireAllClients
--       path: per-kind token bucket (rare 5/10 s, cheer 10/10 s, join 3/10 s, leave
--       3/10 s, zoneFirst 5/10 s, default 10/10 s), overflow coalesced every 10 s into
--       one "+N more" row, and a 30-entry feed ring that late joiners receive through
--       GetState (Social.Recent).
--   * Join / leave feed rows + the welcome toast (OnJoin from Econ.setup, OnLeave on
--       PlayerRemoving).
--   * Cheers — Social.Cheer (Remotes.Cheer via S.Guard): fixed-enum reactions, sender
--       burst cap, per-target display cap, one FireAllClients + one feed row.
--   * Profiles — Social.Profile (Remotes.GetProfile via S.Guard): allow-listed public
--       stats of an ONLINE player, 5 s per-target cache. Never gems / receipts /
--       testPasses / boostUntil / quest state / settings.
--   * Settings — Social.Settings (Remotes.SetSettings via S.Guard): whitelisted keys
--       (Config.Social.SettingsDefault) into p.settings; SettingsFor merges for GetState.
--
--   Wire shape (S->C, both directions of fan-out) — NEVER carries a Color3:
--     { kind, text, colorRGB?={r,g,b}, userId?, personal?, feedOnly?, priority?, t }

local Players = game:GetService("Players")

local Social = {}
local S, Config, Remotes, Data

local WINDOW = 10 -- s: token-bucket window AND the overflow-coalescing cadence
local LIMITS = { rare = 5, cheer = 10, join = 3, leave = 3, zoneFirst = 5 }
local DEFAULT_LIMIT = 10
local OVERFLOW_TEXT = {
	rare = "⭐ +%d more rare finds",
	cheer = "👏 +%d more cheers",
	join = "👋 +%d more miners joined",
	leave = "👋 +%d more miners left",
	zoneFirst = "🗺️ +%d more first visits",
	pet = "🐾 +%d more pet finds",
	rebirth = "🔄 +%d more rebirths",
}

local ring = {}     -- feed history, oldest first, ≤ Config.Social.FeedRing entries
local buckets = {}  -- [kind] = { windowStart = os.clock(), count = n, overflow = n }
local joinedAt = {} -- [player] = os.clock() when OnJoin ran (gates the leave row)

local function social()
	return (Config and Config.Social) or {}
end

-- Per-kind fan-out cap per WINDOW; `join` follows Config.Social.JoinCoalesce.
local function limitFor(kind)
	if kind == "join" then return tonumber(social().JoinCoalesce) or LIMITS.join end
	return LIMITS[kind] or DEFAULT_LIMIT
end

-- Color3 or {r,g,b} -> {r,g,b} integers 0..255; nil when it is neither.
local function toRGB(c)
	if typeof(c) == "Color3" then
		return { math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5) }
	end
	if type(c) == "table" and type(c[1]) == "number" and type(c[2]) == "number" and type(c[3]) == "number" then
		return { math.floor(c[1] + 0.5), math.floor(c[2] + 0.5), math.floor(c[3] + 0.5) }
	end
	return nil
end

-- Build the wire payload from a string or a table (+ optional extra fields).
-- Strips every Color3 (legacy `color` becomes `colorRGB`) and any bad userId.
local function normalize(kind, payload, extra)
	local out = {}
	if type(payload) == "table" then
		for k, v in pairs(payload) do out[k] = v end
	elseif payload ~= nil then
		out.text = tostring(payload)
	end
	if type(extra) == "table" then
		for k, v in pairs(extra) do out[k] = v end
	end
	out.kind = tostring(kind)
	out.text = tostring(out.text or "")
	out.colorRGB = toRGB(out.colorRGB) or toRGB(out.color)
	out.color = nil
	if out.userId ~= nil and not (S and S.IsUserId and S.IsUserId(out.userId)) then
		out.userId = nil
	end
	out.t = os.time()
	return out
end

local function remember(data)
	ring[#ring + 1] = { kind = data.kind, text = data.text, colorRGB = data.colorRGB, userId = data.userId, t = data.t }
	local cap = tonumber(social().FeedRing) or 30
	while #ring > cap do
		table.remove(ring, 1)
	end
end

-- The feed ring, oldest first (a fresh array; the entries themselves are immutable).
function Social.Recent()
	local out = table.create(#ring)
	for i, e in ipairs(ring) do out[i] = e end
	return out
end

-- ===== messaging =====

-- Personal message. `textOrPayload` is a string or { text, colorRGB?, userId?, ... };
-- `extra` merges over it. Always personal=true; userId defaults to the recipient
-- (an explicit userId — the gifter, the Golden Geode owner — wins so the client can
-- offer a one-tap Cheer at that player).
function Social.Tell(player, kind, textOrPayload, extra)
	if typeof(player) ~= "Instance" or player.Parent ~= Players then return nil end
	local data = normalize(kind, textOrPayload, extra)
	data.personal = true
	data.feedOnly = nil
	if data.userId == nil then data.userId = player.UserId end
	Remotes.Announce:FireClient(player, data)
	return data
end

-- Server-wide message. payload = { text, colorRGB?, userId?, feedOnly?, priority? }.
-- Returns true when it went out now, false when it was folded into the next
-- coalesced "+N more" row for its kind.
function Social.Broadcast(kind, payload)
	local data = normalize(kind, payload)
	data.personal = nil
	local now = os.clock()
	local b = buckets[data.kind]
	if not b then
		b = { windowStart = now, count = 0, overflow = 0 }
		buckets[data.kind] = b
	elseif now - b.windowStart >= WINDOW then
		b.windowStart, b.count = now, 0
	end
	if b.count >= limitFor(data.kind) then
		b.overflow += 1
		return false
	end
	b.count += 1
	remember(data)
	Remotes.Announce:FireAllClients(data)
	return true
end

local function flushOverflow()
	for kind, b in pairs(buckets) do
		if b.overflow > 0 then
			local n = b.overflow
			b.overflow = 0
			local fmt = OVERFLOW_TEXT[kind] or ("+%d more " .. kind .. " events")
			local data = { kind = kind, text = string.format(fmt, n), feedOnly = true, t = os.time() }
			remember(data)
			Remotes.Announce:FireAllClients(data)
		end
	end
end

-- ===== presence =====

local function setAttr(player, name, value)
	if player:GetAttribute(name) ~= value then
		player:SetAttribute(name, value)
	end
end

-- Seven compares per push; writes only what changed.
function Social.SyncPresence(player, snap)
	if typeof(player) ~= "Instance" or player.Parent ~= Players or type(snap) ~= "table" then return end
	setAttr(player, "Rebirths", tonumber(snap.rebirths) or 0)
	setAttr(player, "Ascensions", tonumber(snap.ascensions) or 0)
	local active = snap.pets and snap.pets.active
	local petName, petEmoji, petColor = "", "", Color3.new(0, 0, 0)
	if type(active) == "table" then
		petName = tostring(active.name or "")
		petEmoji = tostring(active.emoji or "")
		local c = active.color
		if typeof(c) == "Color3" then
			petColor = c
		elseif type(c) == "table" then
			petColor = Color3.fromRGB(tonumber(c[1]) or 0, tonumber(c[2]) or 0, tonumber(c[3]) or 0)
		end
	end
	setAttr(player, "PetName", petName)
	setAttr(player, "PetEmoji", petEmoji)
	setAttr(player, "PetColor", petColor)
	setAttr(player, "IsVIP", (snap.passes and snap.passes.VIP) == true)
	local gifts = (snap.social and tonumber(snap.social.giftsGiven)) or 0
	local at = tonumber(social().GifterTitleAt) or 3
	setAttr(player, "Title", gifts >= at and "Gifter" or "")
end

-- Zone key (Cavern|Frost|Sunken|Magma|Astral); write on change only.
function Social.SetZone(player, key)
	if typeof(player) ~= "Instance" or player.Parent ~= Players or type(key) ~= "string" then return end
	setAttr(player, "Zone", key)
end

-- ===== settings =====

-- p.settings merged over Config.Social.SettingsDefault; the default keys are the
-- whitelist and each value must keep the default's type. GetState-only.
function Social.SettingsFor(player)
	local defaults = social().SettingsDefault or {}
	local out = {}
	for k, v in pairs(defaults) do out[k] = v end
	local p = Data and Data.Cache[player]
	local mine = p and p.settings
	if type(mine) == "table" then
		for k, v in pairs(mine) do
			if out[k] ~= nil and type(v) == type(out[k]) then out[k] = v end
		end
	end
	return out
end

-- Settings(player, tbl): bound to Remotes.SetSettings through S.Guard (gap = SettingsGap,
-- args { "table" }). The whitelist is the key set of Config.Social.SettingsDefault:
-- numbers must be finite (NaN / inf dropped), then floored and clamped 0..100; booleans
-- must be booleans; unknown keys are dropped. Stored in p.settings + SaveSoon. Nothing
-- is pushed back — the client already applied the change locally. Returns the merged
-- view (the TestHook echoes it).
function Social.Settings(player, tbl)
	local p = Data and Data.Cache[player]
	if not p or type(tbl) ~= "table" then return Social.SettingsFor(player) end
	local defaults = social().SettingsDefault or {}
	if type(p.settings) ~= "table" then p.settings = {} end
	local changed = false
	for k, def in pairs(defaults) do
		local v = tbl[k]
		if v ~= nil then
			local accepted = nil -- nil = rejected (so a boolean `false` still lands)
			if type(def) == "number" then
				if type(v) == "number" and v == v and math.abs(v) ~= math.huge then
					accepted = math.clamp(math.floor(v), 0, 100)
				end
			elseif type(def) == "boolean" then
				if type(v) == "boolean" then accepted = v end
			end
			if accepted ~= nil and p.settings[k] ~= accepted then
				p.settings[k] = accepted
				changed = true
			end
		end
	end
	if changed and Data.SaveSoon then Data.SaveSoon(player) end
	return Social.SettingsFor(player)
end

-- ===== cheers =====

local cheerBurst = {}  -- [player] = { windowStart = os.clock(), count = n }  (sender: CheerBurst per CheerBurstWindow)
local cheerTarget = {} -- [userId] = { windowStart = os.clock(), count = n }  (target: CheerTargetCap per CheerTargetWindow)

local function bucketAllows(map, key, cap, window)
	local now = os.clock()
	local b = map[key]
	if not b or now - b.windowStart >= window then
		b = { windowStart = now, count = 0 }
		map[key] = b
	end
	if b.count >= cap then return false end
	b.count += 1
	return true
end

-- Cheer(player, targetUserId, idx): bound to Remotes.Cheer through S.Guard (gap =
-- CheerGap, args { "userId", "int" }). Reactions are a fixed enum (Config.Social
-- .Reactions) so no free text ever travels. Anything over the sender burst or the
-- per-target display cap is dropped silently (no toast, no counter). One
-- FireAllClients + one feedOnly "cheer" row per accepted cheer. Returns a table (the
-- TestHook echoes it); the RemoteEvent path ignores the return value.
function Social.Cheer(player, targetUserId, idx)
	local cfg = social()
	local reactions = cfg.Reactions or {}
	if typeof(player) ~= "Instance" or player.Parent ~= Players then return { ok = false, err = "Bad request" } end
	if not (S and S.IsUserId and S.IsUserId(targetUserId)) then return { ok = false, err = "Bad request" } end
	if type(idx) ~= "number" or idx ~= idx or math.floor(idx) ~= idx or idx < 1 or idx > #reactions then
		return { ok = false, err = "Bad request" }
	end
	if targetUserId == player.UserId then return { ok = false, err = "You can't cheer yourself" } end
	local target = Players:GetPlayerByUserId(targetUserId)
	if not (target and target.Parent == Players) then return { ok = false, err = "They left" } end
	if not bucketAllows(cheerBurst, player, tonumber(cfg.CheerBurst) or 6, tonumber(cfg.CheerBurstWindow) or 30) then
		return { ok = false, err = "Slow down!" }
	end
	if not bucketAllows(cheerTarget, targetUserId, tonumber(cfg.CheerTargetCap) or 3, tonumber(cfg.CheerTargetWindow) or 10) then
		return { ok = false, err = "They're getting plenty of love already" }
	end
	Remotes.Cheer:FireAllClients({ fromUserId = player.UserId, toUserId = targetUserId, idx = idx, t = os.time() })
	-- cosmetic counters (profile card / "Gifter"-style titles later); never value
	local p = Data and Data.Cache[player]
	if p then p.cheersGiven = (p.cheersGiven or 0) + 1 end
	local tp = Data and Data.Cache[target]
	if tp then tp.cheersReceived = (tp.cheersReceived or 0) + 1 end
	Social.Broadcast("cheer", {
		text = tostring(reactions[idx]) .. " " .. player.DisplayName .. " cheered " .. target.DisplayName,
		userId = player.UserId, feedOnly = true,
	})
	return { ok = true, idx = idx, target = target.DisplayName }
end

-- ===== profiles =====

local profileCache = {} -- [targetUserId] = { at = os.clock(), data = reply }

-- Distinct pets owned: collectible entries with a count, zone VIP pets, unlocked
-- rebirth-tier pets (Pets.Snapshot already applies lifetime-rebirth unlocks).
local function countPets(target, p)
	local n = 0
	for _, c in pairs(p.petInv or {}) do
		if type(c) == "number" and c > 0 then n += 1 end
	end
	for _, owned in pairs(p.zoneVipPets or {}) do
		if owned then n += 1 end
	end
	if S.Pets and S.Pets.Snapshot then
		local ps = S.Pets.Snapshot(target)
		if type(ps) == "table" and type(ps.tiers) == "table" then
			for _, t in ipairs(ps.tiers) do
				if t.unlocked then n += 1 end
			end
		end
	end
	return n
end

-- Profile(player, targetUserId): bound to Remotes.GetProfile through S.Guard (gap =
-- ProfileGap, args { "userId" }). The target must be ONLINE (in Data.Cache) and not
-- the caller. Allow-list only — the reply is built field by field, never from the
-- profile table, so gems / receipts / testPasses / boostUntil / quest state / settings
-- can never leak. Cached ProfileCache seconds per target.
function Social.Profile(player, targetUserId)
	if not (S and S.IsUserId and S.IsUserId(targetUserId)) then return { ok = false, err = "Bad request" } end
	if typeof(player) == "Instance" and targetUserId == player.UserId then return { ok = false, err = "That's you!" } end
	local cached = profileCache[targetUserId]
	if cached and os.clock() - cached.at < (tonumber(social().ProfileCache) or 5) then return cached.data end
	local target = Players:GetPlayerByUserId(targetUserId)
	local p = target and Data and Data.Cache[target]
	if not (target and target.Parent == Players and p) then return { ok = false, err = "That miner isn't here" } end

	local bits, mask = 0, p.indexMask or 0
	for i = 0, 27 do
		if bit32.band(mask, bit32.lshift(1, i)) ~= 0 then bits += 1 end
	end
	local achTiers = 0
	for _, n in pairs(p.achClaimed or {}) do
		if type(n) == "number" then achTiers += n end
	end
	local gifts = p.giftsGiven or 0
	local title = target:GetAttribute("Title")
	if type(title) ~= "string" then
		title = (gifts >= (tonumber(social().GifterTitleAt) or 3)) and "Gifter" or ""
	end
	local rank = {}
	if S.Boards and S.Boards.MyRank then
		local r = S.Boards.MyRank(target)
		if type(r) == "table" then rank = r end
	end
	local zone = target:GetAttribute("Zone")
	local reply = {
		ok = true,
		userId = target.UserId,
		name = target.DisplayName,
		rebirths = p.rebirths or 0,
		ascensions = p.ascensions or 0,
		lifetimeRebirths = (S.Econ and S.Econ.LifetimeRebirths) and S.Econ.LifetimeRebirths(p) or (p.rebirths or 0),
		totalGems = p.totalGems or 0,
		bestRarity = p.bestRarity or 0,
		indexPct = bits / 28,
		petsOwned = countPets(target, p),
		achTiers = achTiers,
		isVIP = target:GetAttribute("IsVIP") == true,
		zone = (type(zone) == "string" and zone ~= "") and zone or "Cavern",
		cheersReceived = p.cheersReceived or 0,
		giftsGiven = gifts,
		title = title,
		rank = rank,
	}
	profileCache[targetUserId] = { at = os.clock(), data = reply }
	return reply
end

-- ===== join / leave =====

-- Called from Econ.setup once the profile is loaded.
function Social.OnJoin(player)
	if typeof(player) ~= "Instance" or player.Parent ~= Players or joinedAt[player] then return end
	joinedAt[player] = os.clock()
	local p = Data and Data.Cache[player]
	local rebirths = (p and p.rebirths) or 0
	Social.Broadcast("join", {
		text = "👋 " .. player.DisplayName .. " joined · Rebirth " .. rebirths,
		userId = player.UserId, feedOnly = true,
	})
	if #Players:GetPlayers() > 1 then
		-- a few seconds late so the joiner's HUD exists to show the toast
		task.delay(4, function()
			if player.Parent ~= Players then return end
			local online = #Players:GetPlayers()
			if online > 1 then
				Social.Tell(player, "welcome", ("Welcome! %d miners online — say hi 👋"):format(online))
			end
		end)
	end
end

function Social.OnLeave(player)
	local t0 = joinedAt[player]
	joinedAt[player] = nil
	if not t0 then return end
	local minSession = tonumber(social().LeaveMinSession) or 20
	if os.clock() - t0 < minSession then return end
	Social.Broadcast("leave", { text = "👋 " .. player.DisplayName .. " left", userId = player.UserId, feedOnly = true })
end

function Social.Init(services)
	S = services
	Config, Remotes, Data = S.Config, S.Remotes, S.Data

	Players.PlayerRemoving:Connect(function(player)
		Social.OnLeave(player)
		cheerBurst[player] = nil
		cheerTarget[player.UserId] = nil
		profileCache[player.UserId] = nil
	end)

	-- C->S handlers: S.Guard does Ready + arg types + per-player gap + pcall; the
	-- handlers above add the enum / online / self / burst checks. RemoteEvents drop
	-- silently on rejection; GetProfile replies { ok = false, err }.
	if S.Guard then
		local cfg = social()
		S.Guard("Cheer", {
			gap = tonumber(cfg.CheerGap) or 2, args = { "userId", "int" },
			fn = function(player, targetUserId, idx)
				Social.Cheer(player, targetUserId, idx)
			end,
		})
		S.Guard("SetSettings", {
			gap = tonumber(cfg.SettingsGap) or 2, args = { "table" },
			fn = function(player, tbl)
				Social.Settings(player, tbl)
			end,
		})
		S.Guard("GetProfile", {
			gap = tonumber(cfg.ProfileGap) or 1, args = { "userId" },
			fn = function(player, targetUserId)
				return Social.Profile(player, targetUserId)
			end,
		})
	end

	-- overflow coalescing: one "+N more" row per kind per window
	task.spawn(function()
		while true do
			task.wait(WINDOW)
			flushOverflow()
		end
	end)
end

return Social
