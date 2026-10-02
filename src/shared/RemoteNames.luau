--!strict
-- Names of the remotes the server creates under ReplicatedStorage.Remotes.
-- Buying off the line, stealing and slamming still use ProximityPrompts, collecting a touch pad and
-- the Towel Snap a Tool. The menus (shop, store, Sockdex, settings) talk through the RemoteFunctions
-- below; every handler checks S.Ready, validates its arguments and rate-limits per player.
return {
	Folder = "Remotes",
	Events = {
		"State", -- server -> client: full StateView for that player
		"Toast", -- server -> client: short message for one player {text, kind}
		"Announce", -- server -> all: banner text + color
		"Carry", -- server -> client: carry started/ended {name, side, rarity} or nil
		"FX", -- server -> all: one-shot effect {kind, position, color} (buy, pair, steal, claim, snap)
		"Celebrate", -- server -> client: a big UI moment {kind, data} (see Types.CelebrateKind)
	},
	Functions = {
		"BuyUpgrade", -- (key: string) -> Result: Item Shop level up (Upgrades.luau)
		"StorePurchase", -- (kind: "pass" | "product", key: string) -> Result: Robux Store (Monetize.luau)
		"SellSock", -- (uid: number) -> Result: sell a drawer sock back (Purchase.luau)
		"SaveSettings", -- (settings: {[string]: any}) -> Result: changed settings (Data.luau)
		"ClaimDex", -- (milestoneKey: string) -> Result: Sockdex milestone reward (Dex.luau)
	},
}
