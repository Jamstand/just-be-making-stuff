-- CollectPetsService: collectible pets with fusion + Golden/Rainbow variants.
-- Each zone has ONE exclusive collectible pet (defined in Zones). Cracking a geode
-- has a small chance to drop the CURRENT zone's pet, rolled Normal / Golden /
-- Rainbow on escalating odds. Duplicates stack; fuse 3 identical (same pet + same
-- variant) into 1 of the next variant. Your best-owned collectible pet's bonus
-- (base bonus × variant multiplier) folds into income — fusing is a real upgrade.
-- The collectibles are earnable by playing; there is no purchase path for them.
-- Each zone ALSO has one prestige "VIP pet": VIP-pass owners earn it fast, everyone
-- else rarely but surely (all earnable). Its bonus ADDS on top of the collectibles.

local CollectPets = {}
local S, Zones

CollectPets.VARIANTS = { "Normal", "Golden", "Rainbow" }
local VARIANT_MULT = { 1, 2.5, 6 }          -- bonus multiplier per variant (escalating)
local VARIANT_ODDS = { 0.92, 0.07, 0.01 }   -- Normal / Golden / Rainbow when a pet drops
local DROP_CHANCE = 0.03                     -- chance per crack to drop a pet
local FUSE_NEED = 3
local VIP_PET_CHANCE_PASS = 0.06            -- per crack: VIP-pass owners earn the zone VIP pet fast
local VIP_PET_CHANCE_FREE = 0.004           -- per crack: everyone else — rare, but still earnable
CollectPets.VariantMult = VARIANT_MULT

local function invKey(zoneKey, variant) return zoneKey .. "_" .. variant end
CollectPets.InvKey = invKey

function CollectPets.RollVariant()
	local r = math.random()
	if r < VARIANT_ODDS[3] then return 3            -- Rainbow (rarest)
	elseif r < VARIANT_ODDS[3] + VARIANT_ODDS[2] then return 2  -- Golden
	else return 1 end                               -- Normal
end

function CollectPets.Grant(player, zoneKey, forceVariant)
	local p = S.Data.Cache[player]
	if not p then return end
	local zone = Zones.Get(zoneKey)
	if not (zone and zone.exclusivePet) then return end
	local variant = forceVariant or CollectPets.RollVariant()
	p.petInv = p.petInv or {}
	local k = invKey(zoneKey, variant)
	p.petInv[k] = (p.petInv[k] or 0) + 1
	if S.Data.SaveSoon then S.Data.SaveSoon(player) end
	S.Econ.Push(player)
	local vlabel = CollectPets.VARIANTS[variant]
	S.Remotes.Announce:FireClient(player, {
		kind = "pet",
		text = (variant > 1 and ("✨ " .. vlabel .. " ") or "🐾 ") .. zone.exclusivePet.emoji .. " "
			.. zone.exclusivePet.name .. " pet found!",
		color = zone.exclusivePet.color,
	})
	return variant
end

-- called on each crack; small chance to drop the current zone's exclusive pet,
-- plus an independent roll for the zone's prestige VIP pet
function CollectPets.MaybeDrop(player, zoneKey)
	if math.random() < DROP_CHANCE then
		CollectPets.Grant(player, zoneKey)
	end
	CollectPets.MaybeVIP(player, zoneKey)
end

-- Zone-exclusive VIP pet: ONE prestige pet per zone, owned once (no variants).
-- Its bonus ADDS on top of the collectible-pet bonus and stacks across zones.
function CollectPets.GrantVIP(player, zoneKey)
	local p = S.Data.Cache[player]
	if not p then return false end
	local zone = Zones.Get(zoneKey)
	if not (zone and zone.vipPet) then return false end
	p.zoneVipPets = p.zoneVipPets or {}
	if p.zoneVipPets[zoneKey] then return false end
	p.zoneVipPets[zoneKey] = true
	if S.Data.SaveSoon then S.Data.SaveSoon(player) end
	S.Econ.Push(player)
	S.Remotes.Announce:FireClient(player, {
		kind = "pet",
		text = "👑 VIP EXCLUSIVE! " .. zone.vipPet.emoji .. " " .. zone.vipPet.name .. " joined you!",
		color = zone.vipPet.color,
	})
	return true
end

-- per-crack VIP-pet roll: fast for VIP-pass owners, rare (but nonzero) for everyone
function CollectPets.MaybeVIP(player, zoneKey)
	local p = S.Data.Cache[player]
	if not p then return end
	local zone = Zones.Get(zoneKey)
	if not (zone and zone.vipPet) then return end
	p.zoneVipPets = p.zoneVipPets or {}
	if p.zoneVipPets[zoneKey] then return end -- already owned
	local isVIP = S.Monetize and S.Monetize.Owns(player, "VIP")
	local chance = isVIP and VIP_PET_CHANCE_PASS or VIP_PET_CHANCE_FREE
	if math.random() < chance then
		CollectPets.GrantVIP(player, zoneKey)
	end
end

-- best-owned collectible pet bonus (base bonus × variant multiplier)
function CollectPets.Bonus(player)
	local p = S.Data.Cache[player]
	if not p then return 0 end
	-- collectible layer: your single BEST owned collectible (base bonus × variant mult)
	local best = 0
	if p.petInv then
		for _, zone in ipairs(Zones.list) do
			if zone.exclusivePet then
				for v = 1, 3 do
					if (p.petInv[invKey(zone.key, v)] or 0) > 0 then
						local b = zone.exclusivePet.bonus * VARIANT_MULT[v]
						if b > best then best = b end
					end
				end
			end
		end
	end
	-- prestige layer: every owned zone VIP pet ADDS its bonus (stacks across zones)
	local vipSum = 0
	if p.zoneVipPets then
		for _, zone in ipairs(Zones.list) do
			if zone.vipPet and p.zoneVipPets[zone.key] then
				vipSum += zone.vipPet.bonus
			end
		end
	end
	return best + vipSum
end

function CollectPets.Fuse(player, zoneKey, variant)
	local p = S.Data.Cache[player]
	if not p then return { ok = false, err = "Loading…" } end
	if type(variant) ~= "number" or variant < 1 or variant >= 3 then
		return { ok = false, err = "Can't fuse further" }
	end
	local zone = Zones.Get(zoneKey)
	if not (zone and zone.exclusivePet) then return { ok = false, err = "Unknown pet" } end
	p.petInv = p.petInv or {}
	local k = invKey(zoneKey, variant)
	if (p.petInv[k] or 0) < FUSE_NEED then return { ok = false, err = "Need 3 to fuse" } end
	p.petInv[k] -= FUSE_NEED
	if p.petInv[k] <= 0 then p.petInv[k] = nil end
	local nk = invKey(zoneKey, variant + 1)
	p.petInv[nk] = (p.petInv[nk] or 0) + 1
	if S.Data.SaveSoon then S.Data.SaveSoon(player) end
	S.Econ.Push(player)
	S.Remotes.Announce:FireAllClients({
		kind = "pet",
		text = "✨ " .. player.DisplayName .. " fused a " .. CollectPets.VARIANTS[variant + 1] .. " "
			.. zone.exclusivePet.emoji .. " " .. zone.exclusivePet.name .. "!",
		color = Color3.fromRGB(255, 220, 120),
	})
	return { ok = true, variant = variant + 1 }
end

-- per-client snapshot: inventory + the active bonus + a compact per-pet summary
function CollectPets.Snapshot(player)
	local p = S.Data.Cache[player]
	if not p then return nil end
	local pets = {}
	for _, zone in ipairs(Zones.list) do
		if zone.exclusivePet then
			local counts = {}
			for v = 1, 3 do counts[v] = (p.petInv and p.petInv[invKey(zone.key, v)]) or 0 end
			if counts[1] + counts[2] + counts[3] > 0 then
				pets[#pets + 1] = {
					zone = zone.key, name = zone.exclusivePet.name, emoji = zone.exclusivePet.emoji,
					color = { zone.exclusivePet.color.R * 255, zone.exclusivePet.color.G * 255, zone.exclusivePet.color.B * 255 },
					baseBonus = zone.exclusivePet.bonus, counts = counts,
				}
			end
		end
	end
	local vip = {}
	for _, zone in ipairs(Zones.list) do
		if zone.vipPet then
			vip[#vip + 1] = {
				zone = zone.key, name = zone.vipPet.name, emoji = zone.vipPet.emoji,
				color = { zone.vipPet.color.R * 255, zone.vipPet.color.G * 255, zone.vipPet.color.B * 255 },
				bonus = zone.vipPet.bonus,
				owned = (p.zoneVipPets and p.zoneVipPets[zone.key]) == true,
			}
		end
	end
	return { pets = pets, bonus = CollectPets.Bonus(player), vip = vip }
end

function CollectPets.Init(services)
	S = services
	Zones = S.Config.Zones
	S.Remotes.FusePet.OnServerInvoke = function(player, zoneKey, variant)
		if not S.Ready then return { ok = false, err = "Starting up…" } end
		if type(zoneKey) ~= "string" then return { ok = false, err = "Bad request" } end
		return CollectPets.Fuse(player, zoneKey, variant)
	end
end

return CollectPets
