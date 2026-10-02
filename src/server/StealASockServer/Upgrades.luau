-- Upgrades: the Item Shop (ShopConfig). STUB - the full module replaces this.
-- API other modules use (all safe before a profile loads: they fall back to the base game):
--   Upgrades.Level(player, key) -> number
--   Upgrades.TowelRange(player) -> studs        Upgrades.TowelKnockbackMult(player) -> number
--   Upgrades.WalkSpeed(player) -> number        Upgrades.CarrySpeedMult(player, tierCarrySpeed) -> number
--   Upgrades.LockSeconds(player) -> seconds     Upgrades.LockCooldown(player) -> seconds
--   Upgrades.CollectMult(player) -> number      Upgrades.AutoCollect(player) -> boolean
-- Remote: BuyUpgrade(key) -> Types.Result
local Upgrades = {}

function Upgrades.Init(_s)
end

return Upgrades
