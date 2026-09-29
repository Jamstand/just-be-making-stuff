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
}

return {}
