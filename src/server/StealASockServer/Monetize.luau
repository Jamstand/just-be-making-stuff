-- Monetize: the Robux Store (StoreConfig). STUB - the full module replaces this.
-- API: Monetize.Setup(player), Monetize.OnPlayerRemoving(player), Monetize.Owns(player, key),
--      Monetize.IncomeMult(player), Monetize.LuckUntil(), Monetize.LuckMult(rank)
-- Remote: StorePurchase(kind, key) -> Types.Result; MarketplaceService.ProcessReceipt lives here.
local Monetize = {}

function Monetize.Init(_s)
end

function Monetize.Setup(_player: Player)
end

function Monetize.OnPlayerRemoving(_player: Player)
end

return Monetize
