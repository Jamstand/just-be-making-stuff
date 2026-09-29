--!strict
-- EventConfig: server events (Phase 3). Data only in Phase 1 so balancing can start early.
local EventConfig = {
	IntervalSeconds = 900, -- one event roughly every 15 minutes
	MinDuration = 180,
	MaxDuration = 300,
	Events = {
		LaundryDay  = { display = "Laundry Day",  desc = "The Dryer spawns 2x faster!",             spawnRateMult = 2 },
		StaticStorm = { display = "Static Storm", desc = "Static mutation chance x5!",             mutationBoost = { Static = 5 } },
		SockSwap    = { display = "Sock Swap",    desc = "Socks that complete your pairs drop more!", matchBoost = 3 },
		LostFound   = { display = "Lost & Found", desc = "A free Epic+ sock dropped mid-map! First one home keeps it.", minRank = 3 },
		StinkBomb   = { display = "Stink Bomb",   desc = "Every sock gains +1 Stink!",              stinkAll = 1 },
		Blackout    = { display = "Blackout",     desc = "Lights out! Glow chance x5.",             mutationBoost = { Glow = 5 }, blackout = true },
	},
}

return EventConfig
