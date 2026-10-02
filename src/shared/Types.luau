--!strict
-- Shared type definitions. `require` this for annotations only; it holds no data.
export type Side = "L" | "R" | "S" -- S = single unit (no halves)

-- What gets saved for each owned sock.
export type SockData = {
	typeId: string,
	side: Side,
	mutation: string,
	stink: number,
}

export type SockState = "line" | "drawer" | "carried" | "gone"

-- A live sock in this server (server only).
export type Sock = {
	uid: number,
	typeId: string,
	side: Side,
	mutation: string,
	stink: number,
	state: SockState,
	ownerId: number?, -- UserId of the drawer owner (stays the victim's while carried)
	slot: number?, -- slot index while in a drawer
	homeSlot: number?, -- where it goes back to if a steal fails
	carrierId: number?, -- UserId of the thief while carried
	model: Model?,
	paired: boolean,
	perfect: boolean,
	pairWith: number?, -- uid of the other half while paired
	lineStart: number?, -- os.clock() when it started riding the clothesline
}

-- What the client receives every second (and on every change).
export type SlotView = {
	uid: number,
	typeId: string,
	name: string,
	side: Side,
	rarity: string,
	mutation: string,
	stink: number,
	paired: boolean,
	perfect: boolean,
	income: number,
	sellPrice: number, -- what SellSock pays for it right now
}

-- Sockdex entry per sock type (profile.sockdex[typeId]); a type is "found" once it has an entry.
export type DexEntry = {
	L: boolean?,
	R: boolean?,
	S: boolean?, -- single-unit types
	paired: boolean?,
	perfect: boolean?,
}

export type StateView = {
	cash: number,
	rate: number,
	uncollected: number,
	rebirths: number,
	slotCount: number,
	slots: { SlotView }, -- index = slot number; empty slots are absent
	lockedUntil: number, -- workspace:GetServerTimeNow() timestamp, 0 when open
	lockCooldownUntil: number,
	baseIndex: number,
	carrying: { name: string, side: Side, rarity: string }?,
	maxSlots: number, -- slot parts the drawer has (slots slotCount+1..maxSlots are the locked back row)
	upgrades: { [string]: number }, -- ShopConfig key -> level (0 = not bought)
	passes: { [string]: boolean }, -- StoreConfig.Passes key -> owned
	luckUntil: number, -- server time Server Luck ends (0 = none); same for everyone
	dex: { [string]: DexEntry }, -- typeId -> entry (absent = not found yet)
	dexClaimed: { [string]: boolean }, -- DexConfig milestone key -> claimed
	pendingDrops: number, -- Rare Sock Drops waiting for a free slot
	settings: { [string]: any }, -- SettingsConfig key -> value (only the changed ones)
}

-- What every menu RemoteFunction returns. `err` is shown to the player when ok is false.
export type Result = {
	ok: boolean,
	err: string?,
	msg: string?,
	cash: number?, -- SellSock / ClaimDex: cash paid
	level: number?, -- BuyUpgrade: the new level
	prompted: boolean?, -- StorePurchase: Roblox's purchase prompt is now showing
	simulated: boolean?, -- StorePurchase: Studio test purchase, granted at once
}

-- Celebrate remote kinds and their data:
--   "dexNew"    { typeId, name, rarity, reward }   first time you get a sock type
--   "pass"      { key, display }                   a game pass was granted
--   "product"   { key, display, cash? }            a developer product was granted
--   "milestone" { key, display, cash }             a Sockdex milestone was claimed
--   "rareDrop"  { name, rarity }                   a Rare Sock Drop landed in your drawer
--   "upgrade"   { key, level }                     an Item Shop upgrade was bought
export type CelebrateKind = "dexNew" | "pass" | "product" | "milestone" | "rareDrop" | "upgrade"

return {}
