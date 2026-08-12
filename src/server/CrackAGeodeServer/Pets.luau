-- PetsService: exclusive companion pets unlocked at Rebirth tiers. Each pet adds
-- a PERMANENT income bonus (on top of the rebirth multiplier) and follows the
-- player. Tiers are spaced so there is always a visible next goal to chase.

local Players = game:GetService("Players")

local Pets = {}
local S, Config, Data, Econ, Remotes

-- req = rebirths needed; bonus = permanent income multiplier add (0.05 = +5%)
local TIERS = {
	{ req = 1,  name = "Rock Sprite",      emoji = "🪨", color = { 150, 140, 175 }, bonus = 0.05 },
	{ req = 2,  name = "Crystal Cub",      emoji = "💠", color = { 120, 210, 255 }, bonus = 0.10 },
	{ req = 3,  name = "Amethyst Imp",     emoji = "🔮", color = { 180, 120, 255 }, bonus = 0.18 },
	{ req = 5,  name = "Topaz Tortoise",   emoji = "🐢", color = { 255, 195, 70 },  bonus = 0.30 },
	{ req = 8,  name = "Emerald Drake",    emoji = "🐉", color = { 70, 245, 140 },  bonus = 0.50 },
	{ req = 12, name = "Ruby Phoenix",     emoji = "🔥", color = { 255, 80, 100 },  bonus = 0.80 },
	{ req = 16, name = "Starstone Owl",    emoji = "🦉", color = { 100, 190, 255 }, bonus = 1.20 },
	{ req = 20, name = "Void Wyrm",        emoji = "🌌", color = { 190, 120, 255 }, bonus = 1.70 },
	{ req = 25, name = "Prismatic Fox",    emoji = "🦊", color = { 255, 150, 220 }, bonus = 2.40 },
	{ req = 30, name = "Celestial Dragon", emoji = "✨", color = { 255, 235, 140 }, bonus = 3.50 },
	-- VIP-exclusive pet: unlocked by owning the VIP game pass (not by rebirthing)
	{ vip = true, name = "Royal Crystal Golem", emoji = "👑", color = { 255, 215, 90 }, bonus = 0.25 },
	-- Starter Pack exclusive pet (unlocked by buying the one-time Starter Pack)
	{ starter = true, name = "Starter Sprite", emoji = "⭐", color = { 255, 225, 120 }, bonus = 0.15 },
}

local function tierUnlocked(player, p, t)
	if t.starter then return p.starterPackBought == true end
	if t.vip then
		return S ~= nil and S.Monetize ~= nil and S.Monetize.Owns(player, "VIP")
	end
	return (p.rebirths or 0) >= (t.req or math.huge)
end

-- highest-bonus unlocked tier index (0 if none)
local function bestIndex(player, p)
	local best, bestBonus = 0, -1
	for i, t in ipairs(TIERS) do
		if tierUnlocked(player, p, t) and t.bonus > bestBonus then
			best, bestBonus = i, t.bonus
		end
	end
	return best
end

local function equippedIndex(player, p)
	local eq = p.equippedPet or 0
	if eq >= 1 and eq <= #TIERS and tierUnlocked(player, p, TIERS[eq]) then
		return eq
	end
	return bestIndex(player, p) -- default to the strongest unlocked pet
end

-- permanent income factor from the equipped pet (0 if none). Folded into IncomeMult.
function Pets.Bonus(player)
	if not Data then return 0 end
	local p = Data.Cache[player]
	if not p then return 0 end
	local i = equippedIndex(player, p)
	return i > 0 and TIERS[i].bonus or 0
end

-- called from Econ right after a rebirth increments p.rebirths
function Pets.OnRebirth(player)
	local p = Data.Cache[player]
	if not p then return end
	for _, t in ipairs(TIERS) do
		if t.req and p.rebirths == t.req then
			Remotes.Announce:FireAllClients({
				kind = "pet",
				text = "🐾 " .. player.DisplayName .. " unlocked the " .. t.emoji .. " " .. t.name
					.. " pet!  (+" .. math.floor(t.bonus * 100) .. "% Gems forever)",
				color = Color3.fromRGB(t.color[1], t.color[2], t.color[3]),
			})
			return
		end
	end
end

function Pets.Snapshot(player)
	if not (Data and Config) then return nil end
	local p = Data.Cache[player]
	if not p then return nil end
	local best = bestIndex(player, p)
	local eq = equippedIndex(player, p)
	local tiers = {}
	for i, t in ipairs(TIERS) do
		tiers[i] = {
			name = t.name, emoji = t.emoji, color = t.color, req = t.req,
			vip = t.vip == true, starter = t.starter == true,
			bonusPct = math.floor(t.bonus * 100), unlocked = tierUnlocked(player, p, t), equipped = (i == eq),
		}
	end
	-- next REBIRTH pet goal (VIP pet is a separate unlock); tiers are ascending by req
	local nextReq, nextName
	for _, t in ipairs(TIERS) do
		if t.req and (p.rebirths or 0) < t.req then
			nextReq, nextName = t.req, t.name
			break
		end
	end
	return {
		equipped = eq, best = best, rebirths = p.rebirths or 0,
		nextReq = nextReq, nextName = nextName,
		active = (eq > 0) and { name = TIERS[eq].name, emoji = TIERS[eq].emoji, color = TIERS[eq].color } or nil,
		tiers = tiers,
	}
end

function Pets.Equip(player, i)
	local p = Data.Cache[player]
	if not p then return { ok = false, err = "Loading…" } end
	if type(i) ~= "number" then return { ok = false, err = "Bad request" } end
	if i < 1 or i > #TIERS or not tierUnlocked(player, p, TIERS[i]) then
		return { ok = false, err = "Not unlocked yet" }
	end
	p.equippedPet = i
	if Data.SaveSoon then Data.SaveSoon(player) end
	Econ.Push(player)
	return { ok = true }
end

function Pets.Init(services)
	S = services
	Config, Data, Econ, Remotes = S.Config, S.Data, S.Econ, S.Remotes
	Remotes.EquipPet.OnServerInvoke = function(player, i)
		return Pets.Equip(player, i)
	end
end

return Pets
