-- Crack a Geode! server bootstrap.
-- Creates remotes + SoundGroups, defines the shared remote validator (S.Guard),
-- requires all service modules (children of this script), initializes in dependency order.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local existing = ReplicatedStorage:FindFirstChild("Remotes")
if existing then existing:Destroy() end
local remotes = Instance.new("Folder")
remotes.Name = "Remotes"

for _, name in ipairs({ "Announce", "CrackFX", "StatsChanged", "MeteorState", "OrbitSync", "GoldenHour", "StreakShow", "CrackRequest", "DailyPopup", "StarterPopup",
	"Cheer", "ServerGoal", "SetSettings" }) do
	local r = Instance.new("RemoteEvent")
	r.Name = name
	r.Parent = remotes
end
for _, name in ipairs({ "GetState", "Buy", "Purchase", "HarvestGarden", "ClaimDaily", "EquipPet", "FusePet", "ClaimAchievement",
	"GetProfile", "GetLeaderboard" }) do
	local r = Instance.new("RemoteFunction")
	r.Name = name
	r.Parent = remotes
end
remotes.Parent = ReplicatedStorage

local S = {}
S.Config = require(ReplicatedStorage:WaitForChild("Config"))
S.Remotes = remotes

-- Bootstrap watchdog: every Init below runs synchronously, so one untimed
-- WaitForChild inside a module parks the whole boot and S.Ready never flips.
-- Scheduled BEFORE the Inits so it fires even if the main thread is stuck.
task.delay(15, function()
	if not S.Ready then
		warn("[CrackAGeode] Bootstrap watchdog: S.Ready is still false after 15 s — a module Init is stuck (look for an untimed WaitForChild, e.g. PickaxeTemplate)")
	end
end)

-- ===== SoundGroups (created before any Init so server Sounds can set .SoundGroup) =====
-- GeodeMusic: the client's playlist; GeodeSFX: every crack/gem/boom sound, server or
-- client. Each client's Audio module scales the group volumes locally from its settings.
do
	local defaults = (S.Config.Social and S.Config.Social.SettingsDefault) or { music = 22, sfx = 100 }
	local function ensureGroup(name, volume)
		local g = SoundService:FindFirstChild(name)
		if g and g:IsA("SoundGroup") then return g end
		if g then
			warn(("[CrackAGeode] SoundService.%s exists but is a %s, not a SoundGroup — creating the group beside it"):format(name, g.ClassName))
		end
		g = Instance.new("SoundGroup")
		g.Name = name
		g.Volume = volume
		g.Parent = SoundService
		return g
	end
	S.MusicGroup = ensureGroup("GeodeMusic", math.clamp((tonumber(defaults.music) or 22) / 100, 0, 1))
	S.SFXGroup = ensureGroup("GeodeSFX", math.clamp((tonumber(defaults.sfx) or 100) / 100, 0, 1))
end

-- ===== Shared remote validation =====

-- A well-formed Roblox user id: finite positive integer below 2^53. In Studio only,
-- "Test -> Local Server" players carry UserIds -1, -2, ... so negative integers are
-- accepted there too (otherwise Cheer / GetProfile / GiftBoost and every feed-row
-- userId are rejected in the multi-client Studio test). Never widened live.
local IS_STUDIO = RunService:IsStudio()
function S.IsUserId(x)
	if type(x) ~= "number" or x ~= x or x ~= math.floor(x) or x >= 2 ^ 53 or x <= -(2 ^ 53) then return false end
	if x > 0 then return true end
	return IS_STUDIO and x < 0
end

-- S.Guard(remote, {
--   gap    = 0.25,                 -- per-player min seconds between ACCEPTED calls (0 = none)
--   args   = { "string", ... },    -- per position: "string"|"number"|"int"|"userId"|"table"|"boolean";
--                                  --   suffix "?" = optional (nil allowed). nil args = no type checks.
--   reject = "table",              -- RemoteFunction reply on rejection: "table" -> {ok=false, err=...}
--                                  --   | "nil" -> nil (GetState only). RemoteEvents always drop silently.
--   fn     = function(player, ...) end,
-- })
-- Order of checks: S.Ready ("Starting up…") -> arg types ("Bad request"; numbers must
-- also be x == x) -> per-player os.clock gap ("Slow down!") -> pcall(fn) (warn +
-- "Something went wrong"). Per-player gap state is cleared on PlayerRemoving.
-- `remote` may be the Instance or its name in S.Remotes. Returns the remote, or nil
-- when it could not bind.
local guardLast = {}   -- [player] = { [remoteName] = os.clock() of the last accepted call }

local function guardCheckArg(spec, v)
	if type(spec) ~= "string" then return true end
	local optional = spec:sub(-1) == "?"
	local kind = optional and spec:sub(1, -2) or spec
	if v == nil then return optional end
	if kind == "string" then return type(v) == "string" end
	if kind == "table" then return type(v) == "table" end
	if kind == "boolean" then return type(v) == "boolean" end
	if kind == "number" then return type(v) == "number" and v == v end
	if kind == "int" then
		return type(v) == "number" and v == v and math.abs(v) ~= math.huge and math.floor(v) == v
	end
	if kind == "userId" then return S.IsUserId(v) end
	-- unknown spec: be strict so a typo never widens the surface
	return false
end

function S.Guard(remote, opts)
	if type(remote) == "string" then remote = remotes:FindFirstChild(remote) end
	if typeof(remote) ~= "Instance" then
		warn("[CrackAGeode] S.Guard: unknown remote " .. tostring(remote))
		return nil
	end
	opts = opts or {}
	local fn = opts.fn
	if type(fn) ~= "function" then
		warn("[CrackAGeode] S.Guard: " .. remote.Name .. " has no fn")
		return nil
	end
	local name = remote.Name
	local gap = tonumber(opts.gap)
	if gap == nil then gap = 0.25 end
	local argSpec = opts.args
	local rejectMode = opts.reject or "table"
	local isFunction = remote:IsA("RemoteFunction")

	local function reject(err)
		if not isFunction or rejectMode == "nil" then return nil end
		return { ok = false, err = err }
	end

	local function handle(player, ...)
		if not S.Ready then return reject("Starting up…") end
		if argSpec then
			-- declared positions are type-checked; undeclared trailing args pass through
			-- untouched (handlers only read what they name), so an older client that sends
			-- an extra value is never rejected for it
			local packed = { ... }
			for i = 1, #argSpec do
				if not guardCheckArg(argSpec[i], packed[i]) then
					return reject("Bad request")
				end
			end
		end
		if gap > 0 then
			if player.Parent ~= Players then return reject("Bad request") end
			local mine = guardLast[player]
			if not mine then
				mine = {}
				guardLast[player] = mine
			end
			local now = os.clock()
			local last = mine[name]
			if last and now - last < gap then return reject("Slow down!") end
			mine[name] = now
		end
		local ok, res = pcall(fn, player, ...)
		if not ok then
			warn(("[CrackAGeode] %s handler failed for %s: %s"):format(name, player.Name, tostring(res)))
			return reject("Something went wrong")
		end
		return res
	end

	if isFunction then
		remote.OnServerInvoke = handle
	elseif remote:IsA("RemoteEvent") then
		remote.OnServerEvent:Connect(function(player, ...) handle(player, ...) end)
	else
		warn("[CrackAGeode] S.Guard: " .. name .. " is neither a RemoteEvent nor a RemoteFunction")
		return nil
	end
	return remote
end

Players.PlayerRemoving:Connect(function(player)
	guardLast[player] = nil
end)

-- ===== Service modules =====
-- Social and ServerGoals are OPTIONAL during the Phase-0/1 rollout: a missing (or
-- broken) file only warns and the server still boots without them.
local OPTIONAL = { Social = true, ServerGoals = true }
for _, name in ipairs({ "Data", "Buffs", "Econ", "Social", "ServerGoals", "Geodes", "Garden", "Monetize", "Meteor", "Boards", "Pickaxe", "Onboarding", "Dailies", "Pets", "Regions", "Decor", "Stations", "Shards", "CollectPets", "Achievements" }) do
	if OPTIONAL[name] then
		local mod = script:FindFirstChild(name)
		if not mod then
			warn(("[CrackAGeode] optional module %s not present — skipped (features that depend on it stay dark)"):format(name))
		else
			local ok, res = pcall(require, mod)
			if ok and type(res) == "table" then
				S[name] = res
			else
				warn(("[CrackAGeode] optional module %s failed to load — skipped: %s"):format(name, tostring(res)))
			end
		end
	else
		S[name] = require(script:WaitForChild(name))
	end
end

-- If Social did not load (or its Init failed), install a stand-in with the same
-- messaging surface so every module can call S.Social.* unconditionally: it keeps the
-- wire shape (kind / text / colorRGB / flags — never a Color3) but has no presence,
-- feed history or join rows.
local function socialShim()
	local function rgb(c)
		if typeof(c) == "Color3" then
			return { math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5) }
		end
		if type(c) == "table" and type(c[1]) == "number" and type(c[2]) == "number" and type(c[3]) == "number" then
			return { c[1], c[2], c[3] }
		end
		return nil
	end
	local function build(kind, payload, extra)
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
		out.colorRGB = rgb(out.colorRGB) or rgb(out.color)
		out.color = nil
		out.t = os.time()
		return out
	end
	local shim = {}
	function shim.Tell(player, kind, payload, extra)
		if typeof(player) ~= "Instance" or player.Parent ~= Players then return nil end
		local d = build(kind, payload, extra)
		d.personal = true
		d.feedOnly = nil
		if d.userId == nil then d.userId = player.UserId end
		remotes.Announce:FireClient(player, d)
		return d
	end
	function shim.Broadcast(kind, payload)
		remotes.Announce:FireAllClients(build(kind, payload))
		return true
	end
	function shim.Recent() return {} end
	function shim.SettingsFor()
		local out = {}
		for k, v in pairs((S.Config.Social and S.Config.Social.SettingsDefault) or {}) do out[k] = v end
		return out
	end
	function shim.SyncPresence() end
	function shim.SetZone() end
	function shim.OnJoin() end
	function shim.OnLeave() end
	local function unavailable() return { ok = false, err = "Social features unavailable" } end
	shim.Cheer, shim.Profile, shim.Settings = unavailable, unavailable, shim.SettingsFor
	shim.IsShim = true
	return shim
end

if not S.Social then
	warn("[CrackAGeode] Social unavailable — messages still flow through a minimal stand-in; presence attributes and the feed ring stay dark")
	S.Social = socialShim()
end

-- Init an optional module when it loaded; its errors warn instead of killing the boot.
local function initOptional(name)
	local mod = S[name]
	if not (mod and type(mod.Init) == "function") then return end
	local ok, err = pcall(mod.Init, S)
	if not ok then
		warn(("[CrackAGeode] %s.Init failed — continuing without it: %s"):format(name, tostring(err)))
		if name == "Social" then S.Social = socialShim() end -- its Remotes/Data locals never got set
	end
end

-- With the stand-in in place, GetProfile has no OnServerInvoke, and an unbound
-- RemoteFunction leaves the caller waiting forever: bind a reject-only handler so the
-- Players panel gets its { ok = false } and stays usable. (Cheer / SetSettings are
-- RemoteEvents — silently dropped is already the right degrade.)
local function bindSocialFallbacks()
	if not (S.Social and S.Social.IsShim) then return end
	S.Guard("GetProfile", {
		gap = 1, args = { "userId" },
		fn = function() return { ok = false, err = "Profiles unavailable" } end,
	})
end

-- init order: Data first (profiles), then buffs/econ, then the social spine
-- (Social presence/feed, ServerGoals before Geodes because node ClickDetectors go
-- live in Geodes.Init), then world systems
S.Data.Init(S)
S.Buffs.Init(S)
S.Econ.Init(S)
initOptional("Social")
bindSocialFallbacks()
initOptional("ServerGoals")
S.Geodes.Init(S)
S.Regions.Init(S) -- biome arenas + Warp Nexus (reads the same Config.Regions)
S.Decor.Init(S)   -- hub environment detail (crystals, stalagmites, veins, dust)
S.Stations.Init(S) -- station legibility: bright boards, color identities, crater beacon
S.Garden.Init(S)
S.Monetize.Init(S)
S.Meteor.Init(S)
S.Boards.Init(S)
S.Pickaxe.Init(S)
S.Onboarding.Init(S)
S.Dailies.Init(S)
S.Pets.Init(S)
S.Shards.Init(S) -- explorer-gate hidden shards in Zone 1
S.CollectPets.Init(S) -- Phase 3: collectible pets (fusion + variants)
S.Achievements.Init(S) -- Phase 3: achievements board

-- Base world lighting: push the shared StyleGuide mood onto the Lighting service
-- once at startup (Brightness / Exposure / Bloom threshold + creates the Geode
-- atmosphere/bloom/color-correction effects). Per-zone atmosphere/color/bloom is
-- then themed per-client by RegionFX as players travel between biomes.
local StyleGuide = require(ReplicatedStorage:WaitForChild("StyleGuide"))
StyleGuide.applyLighting(game:GetService("Lighting"))

-- All modules initialized: only now may client-facing remote handlers run, so a
-- request that arrives mid-bootstrap can't call into a module before its Init.
S.Ready = true

do
	local placeholders = 0
	for _, item in ipairs(S.Config.GamePasses) do
		if item.id == 0 then placeholders += 1 end
	end
	for _, item in ipairs(S.Config.DevProducts) do
		if item.id == 0 then placeholders += 1 end
	end
	if placeholders > 0 then
		-- All ids should be live; a zero id here means a catalog regression.
		warn(("[CrackAGeode] Server started — %d catalog item(s) unexpectedly have id=0 (StudioTestMode fallback in effect for those)"):format(placeholders))
	else
		print("[CrackAGeode] Server started — all catalog ids live; real purchase prompts active")
	end
end

-- Studio-only test/debug hook: lets the command bar (a separate Luau VM) drive the
-- live services. Never active outside Studio.
if IS_STUDIO then
	local hook = Instance.new("BindableFunction")
	hook.Name = "TestHook"
	hook.OnInvoke = function(action, ...)
		local args = { ... }
		local player = Players:GetPlayers()[1]
		if not player then return "no player" end
		local p = S.Data.WaitFor(player, 5)
		if not p then return "no profile" end
		if action == "profile" then
			local out = {}
			for k, v in pairs(p) do
				if type(v) ~= "table" then out[k] = v end
			end
			return out
		elseif action == "addGems" then
			p.gems += args[1]
			p.totalGems += args[1]
			S.Econ.Push(player)
			return p.gems
		elseif action == "crack" then
			S.Geodes.TryCrack(player, args[1] or 1)
			return { gems = p.gems, cracks = p.cracks }
		elseif action == "buy" then
			return S.Econ.Buy(player, args[1])
		elseif action == "pass" then
			p.testPasses[args[1]] = true
			S.Monetize.OnPassGranted(player, args[1])
			return S.Monetize.Owns(player, args[1])
		elseif action == "product" then
			return S.Monetize.GrantProduct(player, args[1], args[2])
		elseif action == "harvest" then
			return S.Garden.Harvest(player)
		elseif action == "gardenAge" then
			p.lastHarvest = os.time() - args[1]
			S.Garden.Refresh(player)
			S.Econ.Push(player)
			return S.Garden.Value(player)
		elseif action == "meteorDamage" then
			S.Meteor.Damage(player, args[1] or 1)
			return S.Meteor.IsActive()
		elseif action == "meteorActive" then
			return S.Meteor.IsActive()
		elseif action == "golden" then
			local handle = S.Geodes.SpawnGolden(player, false)
			task.wait(0.25)
			handle.Open(player)
			return true
		elseif action == "snapshot" then
			return S.Econ.Snapshot(player)
		elseif action == "grantPet" then
			return S.CollectPets.Grant(player, args[1], args[2])
		elseif action == "fusePet" then
			return S.CollectPets.Fuse(player, args[1], args[2])
		elseif action == "grantVip" then
			return S.CollectPets.GrantVIP(player, args[1])
		elseif action == "maybeVip" then
			return S.CollectPets.MaybeVIP(player, args[1])
		elseif action == "zoneUnlocked" then
			return S.Config.Zones.IsUnlocked(S.Config.Zones.Get(args[1]), S.Config.Zones.StatsFor(p))
		elseif action == "claimAch" then
			return S.Achievements.Claim(player, args[1])
		-- ===== social / co-op actions (every branch returns a table or boolean) =====
		elseif action == "cheer" then
			-- cheer(idx): first player cheers the second player online (same checks + limits as the remote)
			if not (S.Social and S.Social.Cheer) then return { ok = false, err = "Social unavailable" } end
			local target
			for _, other in ipairs(Players:GetPlayers()) do
				if other ~= player then target = other break end
			end
			if not target then return { ok = false, err = "needs a second player online" } end
			local res = S.Social.Cheer(player, target.UserId, args[1] or 1)
			if type(res) == "table" then return res end
			return { ok = res ~= false, target = target.DisplayName }
		elseif action == "goal" then
			-- goal(n): advance the live server goal by n (no contributor) and echo its state
			if not (S.ServerGoals and S.ServerGoals.Advance) then return { ok = false, err = "ServerGoals unavailable" } end
			local res = S.ServerGoals.Advance(args[1] or 1)
			if type(res) == "table" then return res end
			return { ok = true, state = S.ServerGoals.State(player) }
		elseif action == "goalComplete" then
			-- force-completes the live goal: exactly one AddServerGift; `gems` lets the
			-- caller assert the balance did not move
			if not (S.ServerGoals and S.ServerGoals.Complete) then return { ok = false, err = "ServerGoals unavailable" } end
			local res = S.ServerGoals.Complete()
			if type(res) ~= "table" then res = { ok = res ~= false } end
			res.gems = p.gems
			return res
		elseif action == "lb" then
			-- lb(kind): the GetLeaderboard reply for "gems" | "rebirths"
			if not (S.Boards and S.Boards.Get) then return { ok = false, err = "Boards unavailable" } end
			local res = S.Boards.Get(player, args[1] or "gems")
			if type(res) == "table" then return res end
			return { ok = false, err = "no reply" }
		elseif action == "presence" then
			-- the first player's replicated attributes (Rebirths, PetName, Zone, ...)
			return player:GetAttributes()
		elseif action == "feed" then
			return (S.Social and S.Social.Recent) and S.Social.Recent() or {}
		elseif action == "settings" then
			-- settings(tbl): apply through the validated handler, then echo the merged view
			if type(args[1]) == "table" then
				if not (S.Social and S.Social.Settings) then return { ok = false, err = "Social unavailable" } end
				S.Social.Settings(player, args[1])
			end
			return (S.Social and S.Social.SettingsFor) and S.Social.SettingsFor(player) or {}
		elseif action == "meteorState" then
			-- last 10 MeteorState payloads as { phase, at = os.clock() }
			return (S.Meteor.RecentStates and S.Meteor.RecentStates()) or {}
		end
		return "unknown action: " .. tostring(action)
	end
	hook.Parent = game:GetService("ServerStorage")
end