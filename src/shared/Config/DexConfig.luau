--!strict
-- DexConfig: Sockdex rewards. Finding a sock type for the first time (either half) pays
-- `NewReward` for its rarity at once; filling the book pays the milestones, claimed by tapping
-- them in the Sockdex. Progress = types found / every type in SockConfig.List.
export type Milestone = {
	key: string, -- saved in profile.dexClaimed - never rename
	percent: number,
	cash: number,
	display: string,
}

local DexConfig = {
	NewReward = {
		Common = 50,
		Rare = 500,
		Epic = 5000,
		Legendary = 50000,
		Mythic = 500000,
		SockGod = 5000000,
		Secret = 50000000,
	} :: { [string]: number },
	Milestones = {
		{ key = "M25",  percent = 25,  cash = 5000,      display = "Sock Spotter" },
		{ key = "M50",  percent = 50,  cash = 100000,    display = "Drawer Detective" },
		{ key = "M75",  percent = 75,  cash = 2500000,   display = "Laundry Legend" },
		{ key = "M100", percent = 100, cash = 100000000, display = "Sock Master" },
	} :: { Milestone },
}

return DexConfig
