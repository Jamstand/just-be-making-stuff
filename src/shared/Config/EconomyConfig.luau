--!strict
-- EconomyConfig: every tunable number that is not per-sock, per-rarity or per-mutation.
-- Balance lives here. Game logic never hard-codes these.
local EconomyConfig = {
	StartingCash = 100,
	BaseSlots = 8, -- drawer slots at rebirth 0
	SlotsPerRebirth = 4, -- +4 slots per rebirth (Phase 3)
	RebirthMultPerLevel = 0.5, -- +0.5x income per rebirth (Phase 3)

	-- The Great Dryer and the Clothesline
	DryerSpawnInterval = 2, -- seconds between socks
	MaxSocksOnLine = 24, -- the dryer waits while the line holds this many
	ClotheslineSpeed = 6, -- studs per second
	BuyRange = 16, -- studs; server re-checks the ProximityPrompt distance

	-- Income
	IncomeTickSeconds = 1,
	PairBonus = 2.5, -- both halves of a type in one drawer
	PerfectPairBonus = 2, -- extra when both halves share a mutation
	StinkPerLevel = 0.10, -- +10% income per Stink level (Phase 2)
	StinkMax = 5,
	StinkIntervalSeconds = 300, -- +1 Stink per 5 minutes online (Phase 2)
	CollectDebounce = 0.5,

	-- Stealing
	StealHoldSeconds = 1.5,
	StealRange = 12, -- studs; server re-checks the ProximityPrompt distance
	CarryHeightOffset = 2.6, -- how high the sock rides above the head
	BaseWalkSpeed = 16,
	ClaimFullToastGap = 3, -- seconds between "drawer full" toasts while carrying

	-- Towel Snap
	TowelRange = 10,
	TowelCooldown = 1,
	TowelKnockback = 45, -- horizontal studs per second
	TowelKnockUp = 20,
	TowelStunSeconds = 0.6,

	-- Drawer lock
	LockSeconds = 60,
	LockSecondsPerRebirth = 10, -- (Phase 3)
	LockCooldownSeconds = 20, -- after a lock opens, before it can be slammed again
	EjectDistance = 10, -- studs in front of the drawer

	-- Networking
	StateSyncSeconds = 1,
	PromptRateLimit = 0.25, -- min seconds between prompt actions per player

	-- Special socks
	LostSockMaxPerServer = 1,
}

return EconomyConfig
