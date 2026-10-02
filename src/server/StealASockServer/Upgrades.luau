-- Upgrades: the Item Shop (ShopConfig) - permanent upgrades bought with in-game cash. Levels live
-- in profile.Data.upgrades; every effect is computed here so the rest of the server asks one place.
-- API other modules use (all safe before a profile loads: they fall back to the base game):
--   Upgrades.Level(player, key) -> number
--   Upgrades.TowelRange(player) -> studs        Upgrades.TowelKnockbackMult(player) -> number
--   Upgrades.WalkSpeed(player) -> number        Upgrades.CarrySpeedMult(player, tierCarrySpeed) -> number
--   Upgrades.LockSeconds(player) -> seconds     Upgrades.LockCooldown(player) -> seconds
--   Upgrades.CollectMult(player) -> number      Upgrades.AutoCollect(player) -> boolean
-- Remote: BuyUpgrade(key) -> Types.Result
local Upgrades = {}
local S

local BUY_GAP = 0.25 -- seconds between BuyUpgrade calls per player

-- Current level of one upgrade (0 = not bought), clamped to the levels the config has.
function Upgrades.Level(player: Player, key: string): number
	local upgrade = S.Config.Shop.Upgrades[key]
	local profile = player and S.Data.Get(player)
	if not upgrade or not profile then
		return 0
	end
	local levels = profile.Data.upgrades
	local level = if type(levels) == "table" then levels[key] else nil
	if type(level) ~= "number" then
		return 0
	end
	return math.clamp(math.floor(level), 0, #upgrade.levels)
end

-- What the current level gives (ShopConfig `value`), or nil at level 0.
local function valueOf(player: Player, key: string): number?
	local level = Upgrades.Level(player, key)
	if level < 1 then
		return nil
	end
	return S.Config.Shop.Upgrades[key].levels[level].value
end

local function hasGoldenTowel(player: Player): boolean
	return S.Monetize ~= nil and S.Monetize.Owns(player, "GoldenTowel")
end

-- ---------- effects ----------

function Upgrades.TowelRange(player: Player): number
	local range = valueOf(player, "Towel") or S.Config.Economy.TowelRange
	if hasGoldenTowel(player) then
		range *= S.Config.Store.GoldenTowelMult
	end
	return range
end

function Upgrades.TowelKnockbackMult(player: Player): number
	local mult = 1 + S.Config.Shop.TowelKnockbackPerLevel * Upgrades.Level(player, "Towel")
	if hasGoldenTowel(player) then
		mult *= S.Config.Store.GoldenTowelMult
	end
	return mult
end

function Upgrades.WalkSpeed(player: Player): number
	return S.Config.Economy.BaseWalkSpeed + (valueOf(player, "Speed") or 0)
end

-- WalkSpeed multiplier while carrying a sock whose tier has `tierCarrySpeed`: each Speed level
-- takes away a share of the slowdown.
function Upgrades.CarrySpeedMult(player: Player, tierCarrySpeed: number): number
	local relief = math.clamp(S.Config.Shop.SpeedCarryRelief * Upgrades.Level(player, "Speed"), 0, 1)
	return tierCarrySpeed + (1 - tierCarrySpeed) * relief
end

function Upgrades.LockSeconds(player: Player): number
	local Eco = S.Config.Economy
	local profile = player and S.Data.Get(player)
	local rebirths = if profile then profile.Data.rebirths else 0
	return Eco.LockSeconds + rebirths * Eco.LockSecondsPerRebirth + (valueOf(player, "Lock") or 0)
end

function Upgrades.LockCooldown(player: Player): number
	local cut = S.Config.Shop.LockCooldownCut * Upgrades.Level(player, "Lock")
	return math.max(5, S.Config.Economy.LockCooldownSeconds - cut)
end

function Upgrades.CollectMult(player: Player): number
	return 1 + (valueOf(player, "Collect") or 0) / 100
end

function Upgrades.AutoCollect(player: Player): boolean
	return Upgrades.Level(player, "Collect") >= S.Config.Shop.AutoCollectLevel
end

-- ---------- BuyUpgrade remote ----------

local function buy(player: Player, key: any)
	if not S.Ready then
		return { ok = false, err = "Starting up…" }
	end
	if type(key) ~= "string" or S.Config.Shop.Upgrades[key] == nil then
		return { ok = false, err = "Bad request" }
	end
	if not S.RateLimit.Check(player, "buyUpgrade", BUY_GAP) then
		return { ok = false, err = "Slow down a little!" }
	end
	local profile = S.Data.Get(player)
	if not profile then
		return { ok = false, err = "Your drawer isn't ready yet" }
	end
	local upgrade = S.Config.Shop.Upgrades[key]
	local level = Upgrades.Level(player, key)
	if level >= #upgrade.levels then
		return { ok = false, err = "Already maxed" }
	end
	local nextLevel = level + 1
	if not S.Data.TrySpend(player, upgrade.levels[nextLevel].price) then
		return { ok = false, err = "Not enough cash" }
	end
	if type(profile.Data.upgrades) ~= "table" then
		profile.Data.upgrades = {}
	end
	profile.Data.upgrades[key] = nextLevel

	-- effects that live on instances (the rest is read from Upgrades when it is needed)
	if key == "Speed" then
		S.Steal.ApplySpeed(player)
	elseif key == "Lock" then
		local record = S.Base.Get(player)
		if record then
			S.Base.UpdateSlamPrompt(record)
		end
	end

	S.Celebrate(player, "upgrade", { key = key, level = nextLevel })
	S.Income.Push(player)
	return { ok = true, level = nextLevel, msg = upgrade.display .. " is now level " .. nextLevel .. "!" }
end

function Upgrades.Init(s)
	S = s
	S.Remotes.BuyUpgrade.OnServerInvoke = function(player: Player, key: any)
		local ok, result = pcall(buy, player, key)
		if not ok then
			warn("[Upgrades] BuyUpgrade failed: " .. tostring(result))
			return { ok = false, err = "Something went wrong - try again" }
		end
		return result
	end
end

return Upgrades
